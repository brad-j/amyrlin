import Foundation

/// One tool call as the transcript shows it: the model's call joined with its live slot, approval and result.
public struct ToolCallRow: Sendable, Hashable {
	public enum Status: Sendable, Hashable {
		/// Called, not started yet: a later call in a sequential round, or arguments still streaming.
		case waiting
		case needsApproval(Approval)
		case running
		case done
		/// An error result. `code` is the diagnostic code: `blocked`, `aborted`, `interrupted`, or nil for a tool error.
		case failed(code: String?)
		/// The call finished without a result entry (a faulted or orphaned task).
		case ended
		/// No result and no run to produce one, for example after the window cut it off.
		case noResult
	}

	public var callId: String
	public var name: String
	public var args: JSONValue
	public var status: Status
	/// Live output while running, otherwise the result's text.
	public var output: String
	public var result: ToolResultItem?
	/// Images the result returned, such as a screenshot the call read.
	public var images: [ImageRef] = []
}

/// A run of tool calls and the thinking between them, from the first call to whatever the model writes next. It's one
/// row from its first call on, so it folds in place: once the run is over, two or more finished calls fold into one
/// line (aludra's design: "read 4 files · ran 2 commands"), and thinking after the last call stays open below it.
public struct ToolRound: Sendable, Hashable {
	public enum Entry: Sendable, Hashable, Identifiable {
		case call(ToolCallRow)
		case thinking(id: String, text: String, redacted: Bool, streaming: Bool)

		public var id: String {
			switch self {
			case .call(let call): "call-\(call.callId)"
			case .thinking(let id, _, _, _): id
			}
		}
	}

	/// The calls and thinking in order, from the first call on.
	public var entries: [Entry]
	/// The run is over and its calls fold into one line.
	public var folded: Bool

	public init(entries: [Entry], folded: Bool) {
		self.entries = entries
		self.folded = folded
	}

	public var calls: [ToolCallRow] {
		entries.compactMap { if case .call(let call) = $0 { call } else { nil } }
	}

	private var lastCall: Int? {
		entries.lastIndex { if case .call = $0 { true } else { false } }
	}

	/// The calls and the thinking between them: what folds.
	public var body: [Entry] {
		guard let lastCall else { return [] }
		return Array(entries[...lastCall])
	}

	/// Thinking after the last call, shown under the fold: what the model thought before it answered.
	public var trailing: [Entry] {
		guard let lastCall else { return entries }
		return Array(entries[(lastCall + 1)...])
	}

	/// Thinking between the calls, shown when the round is opened.
	public var thinking: [String] {
		body.compactMap { if case .thinking(_, let text, _, _) = $0 { text } else { nil } }
	}

	public var failed: Int {
		calls.filter { if case .failed = $0.status { true } else { false } }.count
	}

	public var durationMs: Int {
		calls.compactMap(\.result?.durationMs).reduce(0, +)
	}

	/// The most telling two kinds of call and a count of the rest: "edited 2 files · ran 3 commands · +4 more".
	/// Changes come first, then commands, other tools and reads last, since reads say least about what a round did.
	/// Files count once however often they were touched. Failed calls count nowhere; the box says how many failed.
	public var summary: String {
		struct Kind {
			var rank: Int
			var first: Int
			var calls = 0
			var paths: Set<String> = []
		}
		var kinds: [String: Kind] = [:]
		for (index, call) in calls.enumerated() {
			if case .failed = call.status { continue }
			var kind = kinds[call.name] ?? Kind(rank: Self.rank(call.name), first: index)
			kind.calls += 1
			if let path = call.args["path"]?.stringValue ?? call.args["file_path"]?.stringValue { kind.paths.insert(path) }
			kinds[call.name] = kind
		}
		let ordered = kinds.sorted { ($0.value.rank, $0.value.first) < ($1.value.rank, $1.value.first) }
		let phrases = ordered.prefix(2).map { name, kind in
			let files = kind.paths.isEmpty ? kind.calls : kind.paths.count
			let noun = files == 1 ? "file" : "files"
			switch name {
			case "bash": return kind.calls == 1 ? "ran 1 command" : "ran \(kind.calls) commands"
			case "read": return "read \(files) \(noun)"
			case "write": return "wrote \(files) \(noun)"
			case "edit": return "edited \(files) \(noun)"
			default: return kind.calls == 1 ? name : "\(name) ×\(kind.calls)"
			}
		}
		let rest = ordered.dropFirst(2).reduce(0) { $0 + $1.value.calls }
		return (phrases + (rest > 0 ? ["+\(rest) more"] : [])).joined(separator: " · ")
	}

	private static func rank(_ name: String) -> Int {
		switch name {
		case "edit", "write": 0
		case "bash": 1
		case "read": 3
		default: 2
		}
	}
}

public enum TranscriptNotice: Sendable, Hashable {
	case stopped
	case error(String)
	case lengthLimit
	case reset(handoff: String?)
	case compaction(summary: String)
	case custom(kind: String)
	case unsupported(type: String)
	case taskFailed(TaskFailure)
}

/// A row of the transcript list. Rows are fine-grained, one per block, so the list redraws only what changed.
public struct TranscriptRow: Identifiable, Sendable, Hashable {
	public enum Kind: Sendable, Hashable {
		case loadEarlier
		/// `at` is the item's time, which a turn checkpoint's `message` matches.
		case user(UserMessage, kind: String?, at: Int64?)
		case text(String, streaming: Bool)
		case thinking(String, redacted: Bool, streaming: Bool)
		case toolCall(ToolCallRow)
		case toolRound(ToolRound)
		case notice(TranscriptNotice)
		case queued(InboxItem)
		case pending(PendingSend)
	}

	public let id: String
	public let kind: Kind
	/// False for items before the model's context start (protocol section 4.3).
	public let inContext: Bool
}

public enum TranscriptLayout {
	public static func rows(state: ConversationState, outbox: [PendingSend] = []) -> [TranscriptRow] {
		var rows: [TranscriptRow] = []
		if state.hasEarlier { rows.append(TranscriptRow(id: "load-earlier", kind: .loadEarlier, inContext: false)) }

		var results: [String: ToolResultItem] = [:]
		var resultEntries: [String: EntryID] = [:]
		for item in state.items {
			if case .toolResult(let result) = item.body {
				results[result.callId] = result
				resultEntries[result.callId] = item.id
			}
		}
		// A message keeps one row from sent to queued to in the transcript, so it changes in place instead of being
		// replaced: its row is named by the request that sent it.
		var requests: [EntryID: String] = [:]
		for submission in state.submissions.values {
			if let entry = submission.entryId, let request = submission.requestId { requests[entry] = request }
		}
		let lastAssistant = state.items.last { if case .assistant = $0.body { true } else { false } }?.id
		var shownCalls: Set<String> = []
		var previous: EntryID?

		for item in state.items {
			let inContext = state.isInContext(item.id)
			defer { previous = item.id }
			switch item.body {
			case .user(let user):
				let id = requests[item.id].map { "input-\($0)" } ?? "item-\(item.id)"
				rows.append(TranscriptRow(id: id, kind: .user(UserMessage.parse(user.content, entryId: item.id), kind: user.kind, at: item.at), inContext: inContext))
			case .assistant(let assistant):
				for (index, block) in assistant.content.enumerated() {
					let id = blockID(after: previous, index)
					switch block {
					case .text(let text) where !text.isEmpty:
						rows.append(TranscriptRow(id: id, kind: .text(text, streaming: false), inContext: inContext))
					case .thinking(let text, let redacted) where !text.isEmpty || redacted:
						rows.append(TranscriptRow(id: id, kind: .thinking(text, redacted: redacted, streaming: false), inContext: inContext))
					case .toolCall(let call):
						shownCalls.insert(call.id)
						let pendingInRun = state.isBusy && item.id == lastAssistant
						rows.append(TranscriptRow(
							id: "call-\(call.id)",
							kind: .toolCall(toolRow(call, result: results[call.id], resultEntry: resultEntries[call.id], state: state, inRun: pendingInRun)),
							inContext: inContext
						))
					default:
						break
					}
				}
				switch assistant.stopReason {
				case .aborted: rows.append(TranscriptRow(id: "item-\(item.id)-stop", kind: .notice(.stopped), inContext: inContext))
				case .error: rows.append(TranscriptRow(id: "item-\(item.id)-stop", kind: .notice(.error(assistant.error ?? "The model returned an error.")), inContext: inContext))
				case .length: rows.append(TranscriptRow(id: "item-\(item.id)-stop", kind: .notice(.lengthLimit), inContext: inContext))
				default: break
				}
			case .toolResult(let result):
				// Shown with its call. A result whose call is outside the window gets a row of its own.
				if !shownCalls.contains(result.callId) {
					let call = ToolCallBlock(id: result.callId, name: result.toolName, args: .object([:]))
					rows.append(TranscriptRow(id: "call-\(result.callId)", kind: .toolCall(toolRow(call, result: result, resultEntry: item.id, state: state, inRun: false)), inContext: inContext))
				}
			case .reset(let reset):
				rows.append(TranscriptRow(id: "item-\(item.id)", kind: .notice(.reset(handoff: reset.handoff)), inContext: true))
			case .compaction(let compaction):
				rows.append(TranscriptRow(id: "item-\(item.id)", kind: .notice(.compaction(summary: compaction.summary)), inContext: true))
			case .custom(let custom):
				rows.append(TranscriptRow(id: "item-\(item.id)", kind: .notice(.custom(kind: custom.kind)), inContext: inContext))
			case .unknown(let type):
				rows.append(TranscriptRow(id: "item-\(item.id)", kind: .notice(.unsupported(type: type)), inContext: inContext))
			}
		}

		if let streaming = state.streaming {
			// The ids the blocks keep once the answer is an item, so its rows aren't rebuilt when streaming ends.
			let last = state.items.last?.id
			for (index, block) in streaming.content.enumerated() {
				let id = blockID(after: last, index)
				// Only the newest block is still being written; the ones before it are finished.
				let growing = index == streaming.content.count - 1
				switch block {
				case .text(let text):
					rows.append(TranscriptRow(id: id, kind: .text(text, streaming: growing), inContext: true))
				case .thinking(let text, let redacted):
					rows.append(TranscriptRow(id: id, kind: .thinking(text, redacted: redacted, streaming: growing), inContext: true))
				case .toolCall(let call):
					rows.append(TranscriptRow(id: "call-\(call.id)", kind: .toolCall(ToolCallRow(callId: call.id, name: call.name, args: call.args, status: .waiting, output: "", result: nil)), inContext: true))
				default:
					break
				}
			}
		}

		for failure in state.failures {
			rows.append(TranscriptRow(id: "failure-\(failure.taskId)", kind: .notice(.taskFailed(failure)), inContext: true))
		}
		rows = foldRounds(rows, live: state.isBusy)
		var used = Set(rows.map(\.id))
		for item in state.inbox where item.mode != .write {
			let id = item.requestId.map { "input-\($0)" } ?? "queued-\(item.submissionId)"
			guard used.insert(id).inserted else { continue }
			rows.append(TranscriptRow(id: id, kind: .queued(item), inContext: true))
		}
		for pending in outbox {
			guard used.insert("input-\(pending.id)").inserted else { continue }
			rows.append(TranscriptRow(id: "input-\(pending.id)", kind: .pending(pending), inContext: true))
		}
		return rows
	}

	/// The row showing entry `entry`, or the nearest one after it with a row: a user item's own row, or the first row of
	/// an answer's blocks, which are named by the entry before it (`blockID`) and may sit in a folded round. Nil when no
	/// row comes at or after it.
	public static func rowID(for entry: EntryID, in rows: [TranscriptRow], state: ConversationState) -> String? {
		let byID = Dictionary(rows.enumerated().map { ($1.id, $0) }) { first, _ in first }
		var inRound: [String: Int] = [:]
		for (index, row) in rows.enumerated() {
			if case .toolRound(let round) = row.kind { for entry in round.entries { inRound[entry.id] = index } }
		}
		let requests = Dictionary(state.submissions.values.compactMap { s in s.entryId.flatMap { e in s.requestId.map { (e, $0) } } }) { first, _ in first }
		for (offset, item) in state.items.enumerated() where item.id >= entry {
			let previous = offset > 0 ? state.items[offset - 1].id : nil
			var candidates = ["item-\(item.id)"]
			if let request = requests[item.id] { candidates.insert("input-\(request)", at: 0) }
			if case .assistant(let assistant) = item.body {
				for (index, block) in assistant.content.enumerated() {
					if case .toolCall(let call) = block { candidates.append("call-\(call.id)") } else { candidates.append(blockID(after: previous, index)) }
				}
			}
			// The earliest row among the item's, so the reader lands at its start.
			let found = candidates.compactMap { id -> (Int, String)? in
				if let index = byID[id] { return (index, id) }
				if let index = inRound[id] { return (index, rows[index].id) }
				return nil
			}.min { $0.0 < $1.0 }
			if let found { return found.1 }
		}
		return nil
	}

	/// A block of the assistant item after entry `previous`. Streaming blocks get the ids of the item they become,
	/// which is added after the newest entry; ids by entry ID would change as the stream ends.
	static func blockID(after previous: EntryID?, _ index: Int) -> String {
		"after-\(previous.map(String.init) ?? "start")-\(index)"
	}

	/// Groups each run of calls and thinking into one `toolRound` row from its first call on; thinking before the first
	/// call stays a row of its own, as how the model started. The round folds once the run is over (an answer, notice
	/// or message follows it, or the conversation isn't `live`) and has two or more finished calls. A run still going
	/// stays open, so a call that finishes at once doesn't fold the rows under the reader mid-run.
	static func foldRounds(_ rows: [TranscriptRow], live: Bool) -> [TranscriptRow] {
		var out: [TranscriptRow] = []
		var run: [TranscriptRow] = []
		func isCall(_ row: TranscriptRow) -> Bool {
			if case .toolCall = row.kind { true } else { false }
		}
		func finish(closed: Bool) {
			guard let firstCall = run.firstIndex(where: isCall) else {
				out.append(contentsOf: run)
				run = []
				return
			}
			let entries = run[firstCall...].compactMap { row -> ToolRound.Entry? in
				switch row.kind {
				case .toolCall(let call): .call(call)
				case .thinking(let text, let redacted, let streaming): .thinking(id: row.id, text: text, redacted: redacted, streaming: streaming)
				default: nil
				}
			}
			let calls = entries.compactMap { if case .call(let call) = $0 { call } else { nil } }
			let settled = calls.allSatisfy { call in
				switch call.status {
				case .done, .failed, .ended, .noResult: true
				default: false
				}
			}
			let first = run[firstCall]
			out.append(contentsOf: run[..<firstCall])
			let round = ToolRound(entries: entries, folded: closed && calls.count >= 2 && settled)
			out.append(TranscriptRow(id: "round-\(first.id)", kind: .toolRound(round), inContext: first.inContext))
			run = []
		}
		for row in rows {
			switch row.kind {
			case .toolCall, .thinking:
				run.append(row)
			default:
				finish(closed: true)
				out.append(row)
			}
		}
		finish(closed: !live)
		return out
	}

	static func toolRow(_ call: ToolCallBlock, result: ToolResultItem?, resultEntry: EntryID?, state: ConversationState, inRun: Bool) -> ToolCallRow {
		var row = ToolCallRow(callId: call.id, name: call.name, args: call.args, status: .noResult, output: "", result: result)
		if let result {
			row.output = text(of: result.content, images: resultEntry == nil)
			if let resultEntry { row.images = ImageRef.all(in: result.content, entryId: resultEntry) }
			row.status = result.isError ? .failed(code: result.diagnostics.first?.code) : .done
		} else if let slot = state.tools.first(where: { $0.callId == call.id }) {
			row.output = slot.output
			row.status = slot.status == .ended ? .ended : .running
		} else if let approval = state.approvals.first(where: { $0.callId == call.id }) {
			row.status = .needsApproval(approval)
		} else if inRun {
			row.status = .waiting
		}
		return row
	}

	/// The blocks' text; images as a placeholder unless they're shown on their own (`images: false`).
	static func text(of blocks: [Block], images: Bool = true) -> String {
		blocks.compactMap { block in
			switch block {
			case .text(let text): text
			case .image(let mimeType): images ? "[image \(mimeType)]" : nil
			default: nil
			}
		}.joined(separator: "\n")
	}
}
