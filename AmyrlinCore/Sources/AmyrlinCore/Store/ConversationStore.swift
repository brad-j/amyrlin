import Foundation
import Observation

/// A message the user sent that the transcript or inbox does not show yet.
public struct PendingSend: Identifiable, Sendable, Hashable {
	/// The `requestId`, reused for every retry (protocol section 5, `submit`).
	public let id: String
	public let text: String
	public let whenBusy: WhenBusy
	/// Its images and videos, kept for a retry.
	public var images: [ImageUpload] = []
	public var videos: [VideoUpload] = []
	public var submissionId: SubmissionID?
	/// Set when the server refused it or its outcome is unknown; the user can retry.
	public var failure: String?
}

/// One conversation's live state and the commands the UI sends to it.
@MainActor @Observable
public final class ConversationStore {
	public let id: ConversationID
	public private(set) var state = ConversationState()
	public private(set) var outbox: [PendingSend] = []
	/// How long runs take, timed while watching.
	public private(set) var turns = TurnClock()
	/// True between a dropped stream and its fresh snapshot.
	public private(set) var isResyncing = false
	/// Set when the subscription gave up (protocol section 3) or the conversation is gone.
	public private(set) var problem: String?
	/// The last command error, for a transient message in the UI.
	public var lastError: String?

	@ObservationIgnored private let connection: HostConnection
	@ObservationIgnored private var task: Task<Void, Never>?
	@ObservationIgnored private var subscription: Subscription<ConversationEvent>?
	/// Images of the transcript fetched so far; a stored image never changes.
	@ObservationIgnored private var images: [ImageRef: Data] = [:]

	init(id: ConversationID, connection: HostConnection) {
		self.id = id
		self.connection = connection
	}

	public func start() {
		guard task == nil else { return }
		problem = nil
		task = Task { await self.watch() }
	}

	public func stop() {
		task?.cancel()
		task = nil
		if let subscription { Task { await subscription.cancel() } }
		subscription = nil
	}

	// MARK: Commands

	/// Sends a message, with any images and videos. Return sends a follow-up when busy; the steer modifier sends `.steer`.
	public func send(_ text: String, images: [ImageUpload] = [], videos: [VideoUpload] = [], whenBusy: WhenBusy = .followUp) {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty || !images.isEmpty || !videos.isEmpty else { return }
		let pending = PendingSend(id: UUID().uuidString, text: trimmed, whenBusy: whenBusy, images: images, videos: videos)
		outbox.append(pending)
		submit(pending)
	}

	public func retry(_ pending: PendingSend) {
		guard let index = outbox.firstIndex(where: { $0.id == pending.id }) else { return }
		outbox[index].failure = nil
		submit(outbox[index])
	}

	public func discard(_ pending: PendingSend) {
		outbox.removeAll { $0.id == pending.id }
	}

	public func abort() async {
		await run { _ = try await $0.send(Commands.Abort(conversationId: self.id)) }
	}

	public func configure(_ change: SettingsChange) async {
		await run { connection in
			let result = try await connection.send(Commands.Configure(conversationId: self.id, changes: change))
			self.state.settings = result.settings
		}
	}

	public func compact(instructions: String? = nil) async {
		await run { _ = try await $0.send(Commands.Compact(conversationId: self.id, instructions: instructions)) }
	}

	public func reset(handoff: String? = nil) async {
		await run { _ = try await $0.send(Commands.Reset(conversationId: self.id, handoff: handoff)) }
	}

	public func answer(_ approval: Approval, approve: Bool, message: String? = nil) async {
		await run {
			_ = try await $0.send(Commands.AnswerApproval(approvalId: approval.approvalId, decision: approve ? .approve : .deny, message: message))
		}
	}

	/// Loads the page of items before the oldest one shown.
	public func loadEarlier(limit: Int = 100) async {
		guard state.hasEarlier, let oldest = state.items.first?.id else { return }
		await run { connection in
			let page = try await connection.send(Commands.History(conversationId: self.id, before: oldest, limit: limit))
			self.state.prepend(history: page.items, hasEarlier: page.hasEarlier)
		}
	}

	private func run(_ body: (HostConnection) async throws -> Void) async {
		do {
			try await body(connection)
		} catch {
			lastError = Self.describe(error)
		}
	}

	/// An image of the transcript, fetched once from the host.
	public func image(_ ref: ImageRef) async throws -> Data {
		if let cached = images[ref] { return cached }
		let result = try await connection.send(Commands.ConversationImage(conversationId: id, entryId: ref.entryId, index: ref.index))
		guard let data = Data(base64Encoded: result.data) else { throw ProtocolError(code: "internal", message: "The image came back unreadable") }
		images[ref] = data
		return data
	}

	private func submit(_ pending: PendingSend) {
		let command = Commands.Submit(conversationId: id, requestId: pending.id, text: pending.text, whenBusy: pending.whenBusy, images: pending.images, videos: pending.videos)
		Task {
			do {
				let result = try await connection.send(command)
				guard let index = outbox.firstIndex(where: { $0.id == pending.id }) else { return }
				outbox[index].submissionId = result.submission.id
				let entryShown = result.submission.entryId.map { entry in state.items.contains { $0.id == entry } } ?? false
				if entryShown { outbox.remove(at: index) }
				settleOutbox(afterSnapshot: false)
			} catch {
				guard let index = outbox.firstIndex(where: { $0.id == pending.id }) else { return }
				outbox[index].failure = Self.describe(error)
			}
		}
	}

	/// Drops pending sends the state now shows, in the transcript or the inbox.
	private func settleOutbox(afterSnapshot: Bool) {
		outbox.removeAll { pending in
			guard pending.failure == nil else { return false }
			if state.submission(requestId: pending.id) != nil { return true }
			if state.inbox.contains(where: { $0.requestId == pending.id || $0.submissionId == pending.submissionId }) { return true }
			// A snapshot after the response holds the input, in the transcript or the inbox.
			return afterSnapshot && pending.submissionId != nil
		}
	}

	// MARK: Watching

	private func watch() async {
		let subscription = await connection.watchConversation(id)
		self.subscription = subscription
		for await update in subscription.updates {
			switch update {
			case .events(let events):
				isResyncing = false
				if case .needsResync(let reason) = state.apply(events) {
					isResyncing = true
					await subscription.resync(reason: reason)
				}
				turns.observe(state, snapshot: events.first?.isSnapshot == true)
				settleOutbox(afterSnapshot: events.first?.isSnapshot == true)
			case .resyncing:
				isResyncing = true
			case .failed(let reason), .ended(let reason):
				problem = reason
			}
		}
	}

	static func describe(_ error: any Error) -> String {
		switch error {
		case let error as ProtocolError: error.message
		case ConnectionError.outcomeUnknown(let method): "The connection dropped; \(method) may or may not have applied."
		default: String(describing: error)
		}
	}
}
