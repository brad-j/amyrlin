import Foundation

/// Everything the app shows for one conversation, built from a snapshot and the events after it (protocol section 7.3).
public struct ConversationState: Sendable, Hashable {
	public var conversation: ConversationRef?
	/// Ordered by `id`.
	public private(set) var items: [Item] = []
	public var hasEarlier = false
	public var contextStart: EntryID?
	public var run: RunState?
	public var streaming: Streaming?
	public var retry: RetryState?
	/// In call order of their first appearance.
	public var tools: [ToolSlot] = []
	public var inbox: [InboxItem] = []
	public var approvals: [Approval] = []
	public var compactions: [CompactionStatus] = []
	public var settings: ConversationSettings?
	public var spend: Spend = .zero
	public var submissions: [SubmissionID: Submission] = [:]
	/// `task.failed` events since the last snapshot, for display.
	public var failures: [TaskFailure] = []
	/// False until the first snapshot arrives.
	public private(set) var hasSnapshot = false

	public init() {}

	public init(snapshot: ConversationSnapshot) {
		self.init()
		replace(with: snapshot)
	}

	public var isBusy: Bool { run != nil }

	/// The submission that answers a client `requestId`, if the server has reported it.
	public func submission(requestId: String) -> Submission? {
		submissions.values.first { $0.requestId == requestId }
	}

	/// Whether `id` is still in the model's context (protocol section 4.3, context start).
	public func isInContext(_ id: EntryID) -> Bool {
		guard let contextStart else { return true }
		return id >= contextStart
	}

	/// Prepends a `conversation.history` page.
	public mutating func prepend(history: [Item], hasEarlier: Bool) {
		for item in history { insert(item) }
		self.hasEarlier = hasEarlier
	}

	// MARK: - Reducing

	public enum Outcome: Sendable, Hashable {
		case applied
		/// State can no longer be trusted. The subscription must fetch a fresh snapshot.
		case needsResync(reason: String)
	}

	/// Applies one frame's events in order. Stops at the first event that needs a resync.
	@discardableResult
	public mutating func apply(_ events: [ConversationEvent]) -> Outcome {
		for event in events {
			let outcome = apply(event)
			if case .needsResync = outcome { return outcome }
		}
		return .applied
	}

	@discardableResult
	public mutating func apply(_ event: ConversationEvent) -> Outcome {
		if !hasSnapshot {
			guard case .snapshot = event else { return .needsResync(reason: "event before the first snapshot") }
		}
		switch event {
		case .snapshot(let snapshot):
			replace(with: snapshot)
		case .itemAdded(let item):
			insert(item)
			if case .assistant = item.body { streaming = nil }
			if let start = item.contextStart { contextStart = start }
		case .streamStarted(let message):
			streaming = message
		case .streamDelta(let ops):
			guard var message = streaming else { return .applied }
			for op in ops {
				if let failure = Self.apply(op, to: &message.content) {
					return .needsResync(reason: failure)
				}
			}
			streaming = message
		case .toolStarted(let callId, let name, _):
			if let index = slotIndex(callId) {
				tools[index].status = .running
			} else {
				tools.append(ToolSlot(callId: callId, name: name, status: .running))
			}
		case .toolUpdated(let update):
			guard let index = slotIndex(update.callId) else {
				return .needsResync(reason: "tool.updated for unknown call \(update.callId)")
			}
			Self.apply(update, to: &tools[index])
		case .toolEnded(let callId, let resultId):
			if resultId != nil {
				tools.removeAll { $0.callId == callId }
			} else if let index = slotIndex(callId) {
				tools[index].status = .ended
			} else {
				tools.append(ToolSlot(callId: callId, name: "", status: .ended))
			}
		case .runStarted(let inputs):
			run = RunState(inputs: inputs)
		case .runEnded:
			run = nil
			streaming = nil
			retry = nil
			tools.removeAll { $0.status == .ended }
		case .submission(let submission):
			submissions[submission.id] = submission
		case .inboxChanged(let items):
			inbox = items
		case .settingsChanged(let settings):
			self.settings = settings
		case .spendChanged(let spend):
			self.spend = spend
		case .compactionStarted(let status):
			compactions.removeAll { $0.taskId == status.taskId }
			compactions.append(status)
		case .compactionEnded(let taskId):
			compactions.removeAll { $0.taskId == taskId }
		case .retryScheduled(let state):
			retry = state
		case .retryCleared:
			retry = nil
		case .taskFailed(let failure):
			failures.append(failure)
		case .approvalRequested(let approval):
			approvals.removeAll { $0.approvalId == approval.approvalId }
			approvals.append(approval)
		case .approvalResolved(let resolution):
			approvals.removeAll { $0.approvalId == resolution.approvalId }
		case .unknown(let type):
			return .needsResync(reason: "unknown event type \(type)")
		}
		return .applied
	}

	private mutating func replace(with snapshot: ConversationSnapshot) {
		conversation = snapshot.conversation
		items = snapshot.items.sorted { $0.id < $1.id }
		hasEarlier = snapshot.hasEarlier
		contextStart = snapshot.contextStart
		run = snapshot.run
		streaming = snapshot.streaming
		retry = snapshot.retry
		tools = snapshot.tools
		inbox = snapshot.inbox
		approvals = snapshot.approvals
		compactions = snapshot.compactions
		settings = snapshot.settings
		spend = snapshot.spend
		submissions = [:]
		failures = []
		hasSnapshot = true
	}

	/// Inserts in `id` order, replacing an item with the same `id`. Appending is the common case.
	private mutating func insert(_ item: Item) {
		if let last = items.last, last.id < item.id {
			items.append(item)
			return
		}
		var low = 0
		var high = items.count
		while low < high {
			let mid = (low + high) / 2
			if items[mid].id < item.id { low = mid + 1 } else { high = mid }
		}
		if low < items.count, items[low].id == item.id {
			items[low] = item
		} else {
			items.insert(item, at: low)
		}
	}

	private func slotIndex(_ callId: String) -> Int? {
		tools.firstIndex { $0.callId == callId }
	}

	// MARK: - Stream and tool helpers

	/// Returns a failure reason when the op does not fit the message.
	static func apply(_ op: StreamOp, to content: inout [Block]) -> String? {
		switch op {
		case .start(let index, let block), .set(let index, let block):
			if index == content.count {
				content.append(block)
			} else if index < content.count, index >= 0 {
				content[index] = block
			} else {
				return "block index \(index) past \(content.count) blocks"
			}
		case .appendText(let index, let text):
			guard content.indices.contains(index) else { return "appendText at missing block \(index)" }
			switch content[index] {
			case .text(let existing): content[index] = .text(existing + text)
			case .thinking(let existing, let redacted): content[index] = .thinking(existing + text, redacted: redacted)
			default: return "appendText on a non-text block \(index)"
			}
		case .appendArg(let index, let path, let text):
			guard content.indices.contains(index), case .toolCall(var call) = content[index] else {
				return "appendArg at missing tool call \(index)"
			}
			guard call.args.append(text, at: path[...]) else { return "appendArg path \(path) does not fit" }
			content[index] = .toolCall(call)
		case .replace(let blocks):
			content = blocks
		case .unknown(let op):
			return "unknown stream op \(op)"
		}
		return nil
	}

	static func apply(_ update: ToolUpdate, to slot: inout ToolSlot) {
		switch update.output {
		case .set(let output):
			slot.output = output
		case .trimAppend(let trimStart, let append):
			slot.output = trimmingUTF16Prefix(slot.output, count: trimStart) + append
		case nil:
			break
		}
		switch update.details {
		case .unchanged: break
		case .cleared: slot.details = nil
		case .set(let details): slot.details = details
		}
		switch update.diagnostics {
		case .unchanged: break
		case .cleared: slot.diagnostics = []
		case .set(let diagnostics): slot.diagnostics = diagnostics
		}
	}

	/// Drops `count` UTF-16 code units, the unit pi-durable's JavaScript trims by.
	static func trimmingUTF16Prefix(_ string: String, count: Int) -> String {
		guard count > 0 else { return string }
		let utf16 = string.utf16
		guard count < utf16.count else { return "" }
		let index = utf16.index(utf16.startIndex, offsetBy: count)
		// A trim that splits a surrogate pair leaves half a character; String repairs it to U+FFFD.
		return String(decoding: Array(utf16[index...]), as: UTF16.self)
	}
}
