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
}

/// A finished round of two or more tool calls, folded into one line (aludra's design: "read 4 files · ran 2 commands").
public struct ToolRound: Sendable, Hashable {
	public var calls: [ToolCallRow]
	/// Thinking between the calls, shown when the round is opened.
	public var thinking: [String]

	public var failed: Int {
		calls.filter { if case .failed = $0.status { true } else { false } }.count
	}

	public var durationMs: Int {
		calls.compactMap(\.result?.durationMs).reduce(0, +)
	}

	/// "ran 3 commands · read 2 files", in order of first use.
	public var summary: String {
		var order: [String] = []
		var counts: [String: Int] = [:]
		for call in calls {
			if counts[call.name] == nil { order.append(call.name) }
			counts[call.name, default: 0] += 1
		}
		return order.map { name in
			let n = counts[name] ?? 0
			switch name {
			case "bash": return n == 1 ? "ran 1 command" : "ran \(n) commands"
			case "read": return n == 1 ? "read 1 file" : "read \(n) files"
			case "write": return n == 1 ? "wrote 1 file" : "wrote \(n) files"
			case "edit": return n == 1 ? "edited 1 file" : "edited \(n) files"
			default: return n == 1 ? "\(name)" : "\(name) ×\(n)"
			}
		}.joined(separator: " · ")
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
		case user(text: String, kind: String?)
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
		for item in state.items {
			if case .toolResult(let result) = item.body { results[result.callId] = result }
		}
		let lastAssistant = state.items.last { if case .assistant = $0.body { true } else { false } }?.id
		var shownCalls: Set<String> = []

		for item in state.items {
			let inContext = state.isInContext(item.id)
			switch item.body {
			case .user(let user):
				rows.append(TranscriptRow(id: "item-\(item.id)", kind: .user(text: text(of: user.content), kind: user.kind), inContext: inContext))
			case .assistant(let assistant):
				for (index, block) in assistant.content.enumerated() {
					let id = "item-\(item.id)-\(index)"
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
							kind: .toolCall(toolRow(call, result: results[call.id], state: state, inRun: pendingInRun)),
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
					rows.append(TranscriptRow(id: "call-\(result.callId)", kind: .toolCall(toolRow(call, result: result, state: state, inRun: false)), inContext: inContext))
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
			for (index, block) in streaming.content.enumerated() {
				let id = "stream-\(index)"
				switch block {
				case .text(let text):
					rows.append(TranscriptRow(id: id, kind: .text(text, streaming: true), inContext: true))
				case .thinking(let text, let redacted):
					rows.append(TranscriptRow(id: id, kind: .thinking(text, redacted: redacted, streaming: true), inContext: true))
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
		rows = foldRounds(rows)
		for item in state.inbox where item.mode != .write {
			rows.append(TranscriptRow(id: "queued-\(item.submissionId)", kind: .queued(item), inContext: true))
		}
		for pending in outbox {
			rows.append(TranscriptRow(id: "pending-\(pending.id)", kind: .pending(pending), inContext: true))
		}
		return rows
	}

	/// Folds each run of two or more finished calls (with any thinking between them) into one `toolRound` row.
	static func foldRounds(_ rows: [TranscriptRow]) -> [TranscriptRow] {
		var out: [TranscriptRow] = []
		var run: [TranscriptRow] = []
		func finish() {
			let calls = run.compactMap { row -> ToolCallRow? in if case .toolCall(let call) = row.kind { call } else { nil } }
			let settled = calls.allSatisfy { call in
				switch call.status {
				case .done, .failed, .ended, .noResult: true
				default: false
				}
			}
			if calls.count >= 2, settled, let first = run.first(where: { if case .toolCall = $0.kind { true } else { false } }) {
				// Thinking before the first call stays visible: it's how the model started.
				let lead = run.prefix { if case .thinking = $0.kind { true } else { false } }
				out.append(contentsOf: lead)
				let thinking = run.dropFirst(lead.count).compactMap { row -> String? in if case .thinking(let text, _, _) = row.kind { text } else { nil } }
				out.append(TranscriptRow(id: "round-\(first.id)", kind: .toolRound(ToolRound(calls: calls, thinking: thinking)), inContext: first.inContext))
			} else {
				out.append(contentsOf: run)
			}
			run = []
		}
		for row in rows {
			switch row.kind {
			case .toolCall, .thinking:
				run.append(row)
			default:
				finish()
				out.append(row)
			}
		}
		finish()
		return out
	}

	static func toolRow(_ call: ToolCallBlock, result: ToolResultItem?, state: ConversationState, inRun: Bool) -> ToolCallRow {
		var row = ToolCallRow(callId: call.id, name: call.name, args: call.args, status: .noResult, output: "", result: result)
		if let result {
			row.output = text(of: result.content)
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

	static func text(of blocks: [Block]) -> String {
		blocks.compactMap { block in
			switch block {
			case .text(let text): text
			case .image(let mimeType): "[image \(mimeType)]"
			default: nil
			}
		}.joined(separator: "\n")
	}
}
