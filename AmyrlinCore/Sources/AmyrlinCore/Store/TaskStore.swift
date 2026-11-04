import Foundation
import Observation

/// A task's result page: the latest `task.result`, read again whenever the summary's `line`, status or sandbox state
/// changes (the host signals a new plan step, a finished answer, checks and shots that way), and its screenshots and
/// code, each fetched once (protocol section 10 item 19).
@MainActor @Observable
public final class TaskStore {
	public let id: ConversationID
	/// Nil before the first read and before any answer; `result.isRunning` while a run goes on.
	public private(set) var result: TaskResult?
	public private(set) var hasRead = false
	/// Why the last read failed, until one succeeds.
	public private(set) var problem: String?
	/// `sandbox/N` against its base, once asked for.
	public private(set) var code: Result<Changes, ProtocolError>?

	@ObservationIgnored private let host: HostStore
	@ObservationIgnored private var shots: [String: Task<Data?, Never>] = [:]
	@ObservationIgnored private var reading: Task<Void, Never>?
	@ObservationIgnored private var lastKey: String?

	init(id: ConversationID, host: HostStore) {
		self.id = id
		self.host = host
	}

	/// What a read depends on: when any of it changes, the result may have.
	public static func key(_ summary: ConversationSummary?) -> String {
		guard let summary else { return "" }
		return [summary.line ?? "", summary.status.rawValue, summary.sandbox?.state.rawValue ?? "", String(summary.pendingApprovals)].joined(separator: "\u{1f}")
	}

	/// Reads the result again if the summary changed in a way that matters, or `force`.
	public func refresh(_ summary: ConversationSummary?, force: Bool = false) {
		let key = Self.key(summary)
		guard force || key != lastKey, lastKey != "preview" else { return }
		lastKey = key
		reading?.cancel()
		reading = Task {
			do {
				let result = try await host.taskResult(id)
				guard !Task.isCancelled else { return }
				// A new answer's code may differ; read it again when asked.
				if result?.at != self.result?.at { code = nil }
				self.result = result
				problem = nil
			} catch let error as ProtocolError {
				guard !Task.isCancelled else { return }
				problem = error.code == "unknown_method" ? nil : error.message
			} catch {
				guard !Task.isCancelled else { return }
				problem = String(describing: error)
			}
			hasRead = true
		}
	}

	#if DEBUG
	/// Shows `result` as if the host had sent it, and stops reading, for checking the page's states by eye.
	public func preview(_ result: TaskResult?) {
		lastKey = "preview"
		reading?.cancel()
		self.result = result
		hasRead = true
	}

	/// True once `preview` was used, so refreshes leave it alone.
	public var isPreview: Bool { lastKey == "preview" }
	#endif

	/// A screenshot's PNG bytes, fetched once; nil when the host no longer has it (past its days).
	public func shot(_ shotID: String) async -> Data? {
		if let task = shots[shotID] { return await task.value }
		let host = host
		let id = id
		let task = Task { @MainActor in try? await host.taskShot(id, shot: shotID) }
		shots[shotID] = task
		return await task.value
	}

	/// Reads the branch's changes against its base, once per answer.
	public func loadCode() async {
		guard code == nil else { return }
		do {
			code = .success(try await host.taskCode(id))
		} catch let error as ProtocolError {
			code = .failure(error)
		} catch {
			code = .failure(ProtocolError(code: "internal", message: String(describing: error)))
		}
	}

	public func diff(_ path: String) async throws -> String {
		try await host.taskCodeDiff(id, path: path)
	}
}

extension HostStore {
	/// The result page's store for a task, created on first use.
	public func task(_ id: ConversationID) -> TaskStore {
		if let store = taskStores[id] { return store }
		let store = TaskStore(id: id, host: self)
		taskStores[id] = store
		return store
	}
}
