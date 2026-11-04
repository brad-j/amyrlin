import Foundation
import Observation

/// A message the user sent that the transcript or inbox does not show yet.
public struct PendingSend: Identifiable, Sendable, Hashable {
	/// The `requestId`, reused for every retry (protocol section 5, `submit`).
	public let id: String
	public let text: String
	public let whenBusy: WhenBusy
	/// Its images, videos and files, kept for a retry.
	public var images: [ImageUpload] = []
	public var videos: [VideoUpload] = []
	public var files: [FileUpload] = []
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
	/// The session's checkpoints, oldest first, read after each snapshot and each run's end (aludra's own). Empty for a
	/// session outside git or one from before checkpoints; nil for a host without them, which answers `unknown_method`.
	public private(set) var checkpoints: [Checkpoint]? = []

	// MARK: The state's parts the chrome shows

	// Copies of parts of `state`, set only when they change. `state` changes with every streamed delta, and a view that
	// reads any of it redraws each time; the header, composer, status line and inspector read these instead, so they
	// redraw only when what they show changes. Only the transcript reads `state`.
	public private(set) var hasSnapshot = false
	public private(set) var isBusy = false
	public private(set) var conversation: ConversationRef?
	public private(set) var approvals: [Approval] = []
	public private(set) var inbox: [InboxItem] = []
	public private(set) var settings: ConversationSettings?
	public private(set) var spend: Spend = .zero
	/// Tokens the newest answer's request sent: what the context holds now.
	public private(set) var contextUsed: Int?

	@ObservationIgnored private let connection: HostConnection
	@ObservationIgnored private var task: Task<Void, Never>?
	@ObservationIgnored private var subscription: Subscription<ConversationEvent>?
	/// Images of the transcript fetched so far; a stored image never changes.
	@ObservationIgnored private var images: [ImageRef: Data] = [:]
	/// Pages fetched so far, or being fetched, by the host's name for them; a published page never changes.
	@ObservationIgnored private var pages: [JSONValue: Task<PublishedPage, any Error>] = [:]
	@ObservationIgnored private var checkpointRead: Task<Void, Never>?
	/// Set when a read is asked for while one runs, so another follows it.
	@ObservationIgnored private var checkpointsStale = false
	/// The `at` of the last user message whose turn the list was read for once something followed it.
	@ObservationIgnored private var checkpointsReadAfter: Int64?

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
		checkpointRead?.cancel()
		checkpointRead = nil
		if let subscription { Task { await subscription.cancel() } }
		subscription = nil
	}

	// MARK: Commands

	/// Sends a message, with any images, videos and files. Return sends a follow-up when busy; the steer modifier sends
	/// `.steer`.
	public func send(_ text: String, images: [ImageUpload] = [], videos: [VideoUpload] = [], files: [FileUpload] = [], whenBusy: WhenBusy = .followUp) {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty || !images.isEmpty || !videos.isEmpty || !files.isEmpty else { return }
		let pending = PendingSend(id: UUID().uuidString, text: trimmed, whenBusy: whenBusy, images: images, videos: videos, files: files)
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
			self.publish()
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
			self.publish()
		}
	}

	// MARK: Checkpoints

	/// The turn checkpoint taken as the user message sent at `at` started its turn.
	public func checkpoint(forMessageAt at: Int64?) -> Checkpoint? {
		guard let at else { return nil }
		return checkpoints?.last { $0.kind == .turn && $0.message == at }
	}

	/// Reads the checkpoints again. `unknown_method` means the host has none to offer; other failures keep the last list.
	public func refreshCheckpoints() async {
		guard checkpoints != nil else { return }
		do {
			checkpoints = try await connection.send(Commands.ListCheckpoints(conversationId: id)).checkpoints
		} catch let error as ProtocolError where error.code == "unknown_method" {
			checkpoints = nil
		} catch {}
	}

	/// What changed over a checkpoint's turn: from it to the next checkpoint, or to now for the latest.
	public func changes(at checkpoint: Int) async throws -> Changes {
		try await connection.send(Commands.CheckpointChanges(conversationId: id, checkpoint: checkpoint)).changes
	}

	/// One file's diff over a checkpoint's turn.
	public func diff(at checkpoint: Int, path: String) async throws -> String {
		try await connection.send(Commands.CheckpointDiff(conversationId: id, checkpoint: checkpoint, path: path)).patch
	}

	/// Puts the project's files back to `checkpoint`; the result's `undo` puts them back as they were. `busy` while the
	/// session runs or waits. The list is read again, since the host records a checkpoint first.
	public func restore(_ checkpoint: Int) async throws -> RestoreResult {
		let result = try await connection.send(Commands.RestoreCheckpoint(conversationId: id, checkpoint: checkpoint))
		await refreshCheckpoints()
		return result
	}

	/// True once for each user message, the first time an item follows it: its turn's request has started by then.
	private func turnAnswered() -> Bool {
		guard let index = state.items.lastIndex(where: { if case .user = $0.body { true } else { false } }),
			let at = state.items[index].at, index < state.items.count - 1, at != checkpointsReadAfter
		else { return false }
		checkpointsReadAfter = at
		return true
	}

	/// Reads the checkpoints once the current read, if any, is done; several asks while one runs make one more read.
	private func readCheckpointsSoon() {
		guard checkpoints != nil else { return }
		guard checkpointRead == nil else {
			checkpointsStale = true
			return
		}
		checkpointRead = Task {
			repeat {
				checkpointsStale = false
				await refreshCheckpoints()
			} while checkpointsStale && !Task.isCancelled
			checkpointRead = nil
		}
	}

	// MARK: Finding an item

	/// The item a search result named, to scroll to; set by `reveal`, cleared by the transcript once it has.
	public var revealing: EntryID?

	/// Pages `conversation.history` back until entry `entry` is loaded, then marks it to scroll to. Gives up after
	/// `maxPages` pages, or when there's nothing earlier, revealing the nearest item loaded.
	public func reveal(_ entry: EntryID, maxPages: Int = 40) async {
		for _ in 0..<maxPages {
			guard let oldest = state.items.first?.id, entry < oldest, state.hasEarlier else { break }
			await loadEarlier(limit: 200)
		}
		revealing = entry
	}

	/// Waits for the first snapshot, up to `timeout`, so a reveal pages from what's shown.
	public func waitForSnapshot(timeout: Duration = .seconds(10)) async {
		let start = ContinuousClock.now
		while !state.hasSnapshot, ContinuousClock.now - start < timeout {
			try? await Task.sleep(for: .milliseconds(50))
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

	/// A page the agent published, fetched once from the host; asks while it's on its way share the one fetch. A failed
	/// fetch isn't kept, so the next ask tries again.
	public func page(_ page: JSONValue) async throws -> PublishedPage {
		if let task = pages[page] { return try await task.value }
		let connection = connection
		let id = id
		let task = Task { try await connection.send(Commands.ConversationPage(conversationId: id, page: page)) }
		pages[page] = task
		do {
			return try await task.value
		} catch {
			pages[page] = nil
			throw error
		}
	}

	private func submit(_ pending: PendingSend) {
		let command = Commands.Submit(conversationId: id, requestId: pending.id, text: pending.text, whenBusy: pending.whenBusy, images: pending.images, videos: pending.videos, files: pending.files)
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
		// Assigned only when one goes: `removeAll` notifies the transcript even when it removes nothing.
		let kept = outbox.filter { pending in
			guard pending.failure == nil else { return true }
			if state.submission(requestId: pending.id) != nil { return false }
			if state.inbox.contains(where: { $0.requestId == pending.id || $0.submissionId == pending.submissionId }) { return false }
			// A snapshot after the response holds the input, in the transcript or the inbox.
			return !(afterSnapshot && pending.submissionId != nil)
		}
		if kept.count != outbox.count { outbox = kept }
	}

	// MARK: Watching

	/// Copies the chrome's parts of `state` that changed.
	private func publish() {
		if hasSnapshot != state.hasSnapshot { hasSnapshot = state.hasSnapshot }
		if isBusy != state.isBusy { isBusy = state.isBusy }
		if conversation != state.conversation { conversation = state.conversation }
		if approvals != state.approvals { approvals = state.approvals }
		if inbox != state.inbox { inbox = state.inbox }
		if settings != state.settings { settings = state.settings }
		if spend != state.spend { spend = state.spend }
		let used = Self.contextUsed(state)
		if contextUsed != used { contextUsed = used }
	}

	static func contextUsed(_ state: ConversationState) -> Int? {
		for item in state.items.reversed() {
			if case .assistant(let answer) = item.body, let spend = answer.spend, spend.input + spend.cacheRead + spend.cacheWrite > 0 {
				return spend.input + spend.cacheRead + spend.cacheWrite
			}
		}
		return nil
	}

	private func watch() async {
		let subscription = await connection.watchConversation(id)
		self.subscription = subscription
		for await update in subscription.updates {
			switch update {
			case .events(let events):
				if isResyncing { isResyncing = false }
				let wasBusy = state.isBusy
				let outcome = state.apply(events)
				publish()
				if case .needsResync(let reason) = outcome {
					isResyncing = true
					await subscription.resync(reason: reason)
				}
				// Assigned only when it changes: assigning, even the same value, redraws whatever reads it.
				var clock = turns
				clock.observe(state, snapshot: events.first?.isSnapshot == true)
				if clock != turns { turns = clock }
				settleOutbox(afterSnapshot: events.first?.isSnapshot == true)
				// A turn's checkpoint is taken as it starts, and its changes are final once it ends. The host takes it just
				// before the turn's first request, which can be after run.started, so it's read again once the newest
				// user message has something after it; a run waiting on an approval would otherwise show none until it
				// ends.
				if events.first?.isSnapshot == true || wasBusy != state.isBusy || turnAnswered() { readCheckpointsSoon() }
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
