import Foundation
@testable import AmyrlinCore

/// Test-side stand-in for the server's translation: turns pi-durable fixture lines into protocol v1 event frames,
/// following `docs/protocol.md` sections 4, 6.1 and 7. Fixtures have one conversation, the root, with ID 1.
struct DurableMapper {
	struct MappingError: Error, CustomStringConvertible {
		let description: String
	}

	let conversationId: Int = 1
	/// submission ID → requestId, learned from `submission` events (inbox enrichment, section 4.6).
	private var requestIds: [Double: String] = [:]
	/// callId → (name, args), learned from assistant entries, for approvals.
	private var toolCalls: [String: (name: String, args: JSONValue)] = [:]
	/// Approvals the server would hold in memory (section 8).
	private var pendingApprovals: [String: JSONValue] = [:]

	/// The wire frames for one fixture line, each an array of events. Empty when the line yields nothing.
	mutating func frames(for line: JSONValue) throws -> [[JSONValue]] {
		if let snapshot = line["snapshot"] {
			return [[try mapSnapshot(snapshot)]]
		}
		if case .array(let batch)? = line["batch"] {
			let events = try batch.flatMap { try map($0) }
			return events.isEmpty ? [] : [events]
		}
		if let note = line["note"]?.stringValue {
			return mapNote(note, data: line["data"]).map { [[$0]] } ?? []
		}
		return []
	}

	// MARK: Snapshot (section 6.1)

	private mutating func mapSnapshot(_ s: JSONValue) throws -> JSONValue {
		let entries = s["entries"].arrayValue
		for entry in entries { learn(entry) }
		var tools: [JSONValue] = []
		for slot in s["tools"].arrayValue {
			switch slot["status"]?.stringValue {
			case "running": tools.append(mapSlot(slot, status: "running"))
			case "done" where slot["entry"] == nil: tools.append(mapSlot(slot, status: "ended"))
			default: break // pending, and done with a result entry, are omitted (section 4.5)
			}
		}
		let generation = s["generation"]
		var streaming: JSONValue = .null
		if let message = generation?["message"] {
			streaming = .object([
				"attempt": generation?["attempt"] ?? .number(1),
				"content": mapContent(message["content"]),
				"model": modelRef(message),
			])
		}
		var retry: JSONValue = .null
		if let r = generation?["retry"] {
			retry = .object(["attempt": generation?["attempt"] ?? .number(1), "at": r["at"] ?? .null, "error": r["error"] ?? .null])
		}
		return .object([
			"type": "snapshot",
			"conversation": .object(["id": .number(Double(conversationId)), "title": "Fixture", "archived": false, "parent": .null]),
			"items": .array(entries.compactMap(mapEntry)),
			"hasEarlier": false,
			"contextStart": entries.first?["head"] ?? .null,
			"run": s["run"].map { .object(["inputs": $0["inputs"] ?? .array([])]) } ?? .null,
			"streaming": streaming,
			"retry": retry,
			"tools": .array(tools),
			"inbox": .array(s["inbox"].arrayValue.map(mapInboxItem)),
			"approvals": .array(pendingApprovals.keys.sorted().compactMap { pendingApprovals[$0] }),
			"compactions": .array(s["compactions"].arrayValue.map(mapCompaction)),
			"settings": mapSettings(s["agent"] ?? .object([:])),
			"spend": mapUsageState(s["usage"]),
		])
	}

	private func mapSlot(_ slot: JSONValue, status: String) -> JSONValue {
		.object([
			"callId": slot["callId"] ?? "",
			"name": slot["name"] ?? "",
			"status": .string(status),
			"output": slot["output"] ?? "",
			"droppedBytes": slot["droppedBytes"] ?? .number(0),
			"droppedLines": slot["droppedLines"] ?? .number(0),
			"details": slot["details"] ?? .null,
			"diagnostics": slot["diagnostics"] ?? .array([]),
		])
	}

	private func mapInboxItem(_ item: JSONValue) -> JSONValue {
		var out: [String: JSONValue] = ["submissionId": item["id"] ?? .null, "mode": item["mode"] ?? ""]
		if case .number(let id)? = item["id"], let requestId = requestIds[id] { out["requestId"] = .string(requestId) }
		return .object(out)
	}

	private func mapCompaction(_ c: JSONValue) -> JSONValue {
		.object([
			"taskId": c["taskId"] ?? .null, "reason": c["reason"] ?? "", "blocking": c["blocking"] ?? false,
			"attempt": c["attempt"] ?? .null, "retry": c["retry"] ?? .null,
		])
	}

	private func mapSettings(_ agent: JSONValue) -> JSONValue {
		var stored: [String: JSONValue] = [:]
		for key in ["model", "thinkingLevel", "cwd", "tools", "instructions"] { stored[key] = agent[key] }
		var effective = stored
		effective["instructions"] = nil
		effective["tools"] = .array([])
		return .object(["stored": .object(stored), "effective": .object(effective)])
	}

	// MARK: Events (section 7.1)

	private mutating func map(_ e: JSONValue) throws -> [JSONValue] {
		let type = e["type"]?.stringValue ?? ""
		switch type {
		case "snapshot":
			return [try mapSnapshot(e)]
		case "run_start":
			return [.object(["type": "run.started", "inputs": e["inputs"] ?? .array([])])]
		case "run_end":
			return [.object(["type": "run.ended", "inputs": e["inputs"] ?? .array([])])]
		case "turn_start", "turn_end", "deferred_poll":
			return []
		case "message_start":
			let message = e["message"] ?? .null
			guard message["role"]?.stringValue == "assistant" else { return [] }
			return [.object(["type": "stream.started", "attempt": .number(1), "content": mapContent(message["content"]), "model": modelRef(message)])]
		case "message_update":
			let ops = try e["changes"].arrayValue.map(mapChange)
			return ops.isEmpty ? [] : [.object(["type": "stream.delta", "ops": .array(ops)])]
		case "message_end", "entry_appended":
			let entry = e["entry"] ?? .null
			learn(entry)
			return mapEntry(entry).map { [.object(["type": "item.added", "item": $0])] } ?? []
		case "tool_execution_start":
			return [.object(["type": "tool.started", "callId": e["toolCallId"] ?? "", "name": e["toolName"] ?? "", "args": e["args"] ?? .object([:])])]
		case "tool_execution_update":
			var out: [String: JSONValue] = ["type": "tool.updated", "callId": e["toolCallId"] ?? ""]
			for key in ["output", "details", "diagnostics"] { out[key] = e[key] }
			return [.object(out)]
		case "tool_execution_end":
			var out: [String: JSONValue] = ["type": "tool.ended", "callId": e["toolCallId"] ?? ""]
			out["resultId"] = e["entry"]?["id"]
			return [.object(out)]
		case "inbox_update":
			return [.object(["type": "inbox.changed", "items": .array(e["items"].arrayValue.map(mapInboxItem))])]
		case "submission":
			let r = e["record"] ?? .null
			if case .number(let id)? = r["id"], let requestId = r["requestId"]?.stringValue { requestIds[id] = requestId }
			var s: [String: JSONValue] = ["id": r["id"] ?? .null, "type": r["type"] ?? "", "status": r["status"] ?? ""]
			s["requestId"] = r["requestId"]
			s["entryId"] = r["entry"]
			s["answerId"] = r["answer"]
			s["reason"] = r["reason"]
			s["detail"] = r["detail"]
			return [.object(["type": "submission", "submission": .object(s)])]
		case "agent_changed":
			return [.object(["type": "settings.changed", "settings": mapSettings(e["agent"] ?? .object([:]))])]
		case "usage_changed":
			return [.object(["type": "spend.changed", "spend": mapUsageState(e["usage"])])]
		case "compaction_start":
			return [.object(["type": "compaction.started", "taskId": e["taskId"] ?? .null, "reason": e["reason"] ?? "", "blocking": e["blocking"] ?? false])]
		case "compaction_end":
			return [.object(["type": "compaction.ended", "taskId": e["taskId"] ?? .null, "reason": e["reason"] ?? ""])]
		case "auto_retry_start":
			return [.object(["type": "retry.scheduled", "attempt": e["attempt"] ?? .null, "at": e["at"] ?? .null, "error": e["errorMessage"] ?? ""])]
		case "auto_retry_end":
			return [.object(["type": "retry.cleared", "attempt": e["attempt"] ?? .null])]
		case "task_failed":
			return [.object(["type": "task.failed", "taskId": e["taskId"] ?? .null, "kind": e["kind"] ?? "", "message": e["message"] ?? ""])]
		default:
			throw MappingError(description: "durable event type \(type) has no mapping in protocol section 7.1")
		}
	}

	private func mapChange(_ c: JSONValue) throws -> JSONValue {
		let index = c["contentIndex"] ?? .null
		switch c["type"]?.stringValue {
		case "text_start", "thinking_start", "toolcall_start":
			return .object(["op": "start", "index": index, "block": mapBlock(c["block"] ?? .null)])
		case "text_delta", "thinking_delta":
			return .object(["op": "appendText", "index": index, "text": c["delta"] ?? ""])
		case "toolcall_delta":
			return .object(["op": "appendArg", "index": index, "path": c["path"] ?? .array([]), "text": c["delta"] ?? ""])
		case "block":
			return .object(["op": "set", "index": index, "block": mapBlock(c["block"] ?? .null)])
		case "message":
			return .object(["op": "replace", "content": mapContent(c["message"]?["content"])])
		case let other:
			throw MappingError(description: "message change \(other ?? "nil") has no mapping in protocol section 7.2")
		}
	}

	// MARK: Approvals (section 8), from recorder notes

	private mutating func mapNote(_ note: String, data: JSONValue?) -> JSONValue? {
		if note.hasPrefix("beforeTool hook entered"), let callId = data?["toolCallId"]?.stringValue {
			let approvalId = "\(conversationId):\(callId)"
			let call = toolCalls[callId]
			let approval: JSONValue = .object([
				"approvalId": .string(approvalId), "conversationId": .number(Double(conversationId)), "callId": .string(callId),
				"toolName": .string(call?.name ?? ""), "args": call?.args ?? .object([:]), "requestedAt": .number(0),
			])
			pendingApprovals[approvalId] = approval
			return .object(["type": "approval.requested", "approval": approval])
		}
		let decision: String? = switch note {
		case "approved": "approve"
		case "hook wait ended": "cancelled"
		default: nil
		}
		if let decision, let approvalId = pendingApprovals.keys.sorted().first {
			pendingApprovals[approvalId] = nil
			return .object(["type": "approval.resolved", "approvalId": .string(approvalId), "decision": .string(decision)])
		}
		// A killed process loses its in-memory approvals; the next process raises them again.
		if note.contains("killed") { pendingApprovals = [:] }
		return nil
	}

	// MARK: Entries (section 4.3)

	private mutating func learn(_ entry: JSONValue) {
		guard entry["kind"]?.stringValue == "pi.assistant" else { return }
		for block in entry["model"]?.arrayValue.first?["content"].arrayValue ?? [] where block["type"]?.stringValue == "toolCall" {
			if let id = block["id"]?.stringValue {
				toolCalls[id] = (block["name"]?.stringValue ?? "", block["arguments"] ?? .object([:]))
			}
		}
	}

	func mapEntry(_ entry: JSONValue) -> JSONValue? {
		let kind = entry["kind"]?.stringValue ?? ""
		let message = entry["model"]?.arrayValue.first
		var item: [String: JSONValue] = ["id": entry["id"] ?? .null]
		item["at"] = message?["timestamp"]
		switch kind {
		case "pi.system":
			return nil
		case "pi.assistant":
			let m = message ?? .null
			item["type"] = "assistant"
			item["content"] = mapContent(m["content"])
			item["stopReason"] = m["stopReason"]
			item["model"] = modelRef(m)
			item["spend"] = m["usage"].map(mapUsage)
			item["error"] = m["errorMessage"]
		case "pi.tool-result":
			let m = message ?? .null
			item["type"] = "toolResult"
			item["callId"] = m["toolCallId"]
			item["toolName"] = m["toolName"]
			item["content"] = mapContent(m["content"])
			item["isError"] = m["isError"]
			item["details"] = m["details"]
			item["diagnostics"] = entry["data"]?["diagnostics"] ?? .array([])
			item["durationMs"] = m["durationMs"]
		case "pi.reset":
			item["type"] = "reset"
			item["handoff"] = message.map { text(of: $0["content"]) }.map(JSONValue.string)
			item["contextStart"] = entry["head"] ?? entry["id"]
		case "pi.compaction":
			item["type"] = "compaction"
			item["summary"] = .string(text(of: message?["content"]))
			item["reason"] = entry["data"]?["reason"] ?? ""
			item["contextStart"] = entry["head"]
		default:
			if message?["role"]?.stringValue == "user" {
				item["type"] = "user"
				item["content"] = mapContent(message?["content"])
				if kind != "pi.user" {
					item["kind"] = .string(kind)
					item["data"] = entry["data"]
				}
			} else {
				item["type"] = "custom"
				item["kind"] = .string(kind)
				item["data"] = entry["data"]
			}
		}
		return .object(item)
	}

	private func mapContent(_ content: JSONValue?) -> JSONValue {
		switch content {
		case .string(let text)?: .array([.object(["type": "text", "text": .string(text)])])
		case .array(let blocks)?: .array(blocks.map(mapBlock))
		default: .array([])
		}
	}

	private func mapBlock(_ b: JSONValue) -> JSONValue {
		switch b["type"]?.stringValue {
		case "text": .object(["type": "text", "text": b["text"] ?? ""])
		case "thinking": .object(["type": "thinking", "text": b["thinking"] ?? "", "redacted": b["redacted"] ?? false])
		case "toolCall": .object(["type": "toolCall", "id": b["id"] ?? "", "name": b["name"] ?? "", "args": b["arguments"] ?? .object([:])])
		case "image": .object(["type": "image", "mimeType": b["mimeType"] ?? ""])
		default: .object(["type": b["type"] ?? ""])
		}
	}

	private func text(of content: JSONValue?) -> String {
		switch content {
		case .string(let text)?: text
		case .array(let blocks)?: blocks.compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }.joined()
		default: ""
		}
	}

	private func modelRef(_ message: JSONValue) -> JSONValue {
		.object(["provider": message["provider"] ?? "", "modelId": message["model"] ?? ""])
	}

	// MARK: Spend (section 4.2)

	private func mapUsage(_ u: JSONValue) -> JSONValue {
		.object([
			"input": u["input"] ?? .number(0), "output": u["output"] ?? .number(0),
			"cacheRead": u["cacheRead"] ?? .number(0), "cacheWrite": u["cacheWrite"] ?? .number(0),
			"total": u["totalTokens"] ?? .number(0), "cost": u["cost"]?["total"] ?? .number(0),
		])
	}

	private func mapUsageState(_ state: JSONValue?) -> JSONValue {
		var totals: [String: Double] = [:]
		var buckets: [String: JSONValue] = [:]
		for (bucket, key) in [("models", "byModel"), ("tools", "byTool")] {
			var mapped: [String: JSONValue] = [:]
			if case .object(let entries)? = state?[bucket] {
				for (name, usage) in entries {
					let spend = mapUsage(usage)
					mapped[name] = spend
					for field in ["input", "output", "cacheRead", "cacheWrite", "total", "cost"] {
						if case .number(let n)? = spend[field] { totals[field, default: 0] += n }
					}
				}
			}
			buckets[key] = .object(mapped)
		}
		var out = buckets
		for field in ["input", "output", "cacheRead", "cacheWrite", "total", "cost"] { out[field] = .number(totals[field] ?? 0) }
		return .object(out)
	}
}

extension Optional where Wrapped == JSONValue {
	var arrayValue: [JSONValue] {
		if case .array(let array)? = self { array } else { [] }
	}
}

extension JSONValue {
	var arrayValue: [JSONValue] {
		if case .array(let array) = self { array } else { [] }
	}
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral {
	public init(stringLiteral value: String) { self = .string(value) }
	public init(booleanLiteral value: Bool) { self = .bool(value) }
}
