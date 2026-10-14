import Foundation

/// A field that an update may leave alone, clear with `null`, or set (`tool.updated` details and diagnostics).
public enum FieldUpdate<Value: Sendable & Hashable>: Sendable, Hashable {
	case unchanged
	case cleared
	case set(Value)
}

extension KeyedDecodingContainer {
	func decodeUpdate<Value: Decodable & Sendable & Hashable>(_ type: Value.Type, forKey key: Key) throws -> FieldUpdate<Value> {
		guard contains(key) else { return .unchanged }
		if try decodeNil(forKey: key) { return .cleared }
		return .set(try decode(Value.self, forKey: key))
	}
}

/// `tool.updated.output`: a replacement, or a front trim in UTF-16 code units followed by an append (section 7.3).
public enum OutputUpdate: Decodable, Sendable, Hashable {
	case set(String)
	case trimAppend(trimStart: Int, append: String)

	public init(from decoder: any Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		if let set = try c.decodeIfPresent(String.self, forKey: .set) {
			self = .set(set)
		} else {
			self = .trimAppend(
				trimStart: try c.decodeIfPresent(Int.self, forKey: .trimStart) ?? 0,
				append: try c.decodeIfPresent(String.self, forKey: .append) ?? ""
			)
		}
	}

	private enum CodingKeys: String, CodingKey { case set, trimStart, append }
}

public struct ToolUpdate: Sendable, Hashable {
	public var callId: String
	public var output: OutputUpdate?
	public var details: FieldUpdate<JSONValue>
	public var diagnostics: FieldUpdate<[Diagnostic]>
}

/// One operation on the in-flight message (protocol section 7.2).
public enum StreamOp: Decodable, Sendable, Hashable {
	case start(index: Int, block: Block)
	case appendText(index: Int, text: String)
	case appendArg(index: Int, path: [PathComponent], text: String)
	case set(index: Int, block: Block)
	case replace(content: [Block])
	case unknown(op: String)

	public init(from decoder: any Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		let op = try c.decode(String.self, forKey: .op)
		switch op {
		case "start":
			self = .start(index: try c.decode(Int.self, forKey: .index), block: try c.decode(Block.self, forKey: .block))
		case "appendText":
			self = .appendText(index: try c.decode(Int.self, forKey: .index), text: try c.decode(String.self, forKey: .text))
		case "appendArg":
			self = .appendArg(
				index: try c.decode(Int.self, forKey: .index),
				path: try c.decode([PathComponent].self, forKey: .path),
				text: try c.decode(String.self, forKey: .text)
			)
		case "set":
			self = .set(index: try c.decode(Int.self, forKey: .index), block: try c.decode(Block.self, forKey: .block))
		case "replace":
			self = .replace(content: try c.decode([Block].self, forKey: .content))
		default:
			self = .unknown(op: op)
		}
	}

	private enum CodingKeys: String, CodingKey { case op, index, block, text, path, content }
}

public struct ConversationRef: Decodable, Sendable, Hashable {
	public var id: ConversationID
	public var title: String?
	public var archived: Bool?
	public var parent: ParentRef?
	/// Set by servers that tie conversations to projects.
	public var project: String?
	public var dir: String?
}

/// The first event of every `conversation.watch` frame stream (protocol section 6.1).
public struct ConversationSnapshot: Decodable, Sendable, Hashable {
	public var conversation: ConversationRef
	public var items: [Item]
	public var hasEarlier: Bool
	public var contextStart: EntryID?
	public var run: RunState?
	public var streaming: Streaming?
	public var retry: RetryState?
	public var tools: [ToolSlot]
	public var inbox: [InboxItem]
	public var approvals: [Approval]
	public var compactions: [CompactionStatus]
	public var settings: ConversationSettings?
	public var spend: Spend

	public init(from decoder: any Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		conversation = try c.decode(ConversationRef.self, forKey: .conversation)
		items = try c.decodeIfPresent([Item].self, forKey: .items) ?? []
		hasEarlier = try c.decodeIfPresent(Bool.self, forKey: .hasEarlier) ?? false
		contextStart = try c.decodeIfPresent(EntryID.self, forKey: .contextStart)
		run = try c.decodeIfPresent(RunState.self, forKey: .run)
		streaming = try c.decodeIfPresent(Streaming.self, forKey: .streaming)
		retry = try c.decodeIfPresent(RetryState.self, forKey: .retry)
		tools = try c.decodeIfPresent([ToolSlot].self, forKey: .tools) ?? []
		inbox = try c.decodeIfPresent([InboxItem].self, forKey: .inbox) ?? []
		approvals = try c.decodeIfPresent([Approval].self, forKey: .approvals) ?? []
		compactions = try c.decodeIfPresent([CompactionStatus].self, forKey: .compactions) ?? []
		settings = try c.decodeIfPresent(ConversationSettings.self, forKey: .settings)
		spend = try c.decodeIfPresent(Spend.self, forKey: .spend) ?? .zero
	}

	private enum CodingKeys: String, CodingKey {
		case conversation, items, hasEarlier, contextStart, run, streaming, retry, tools, inbox, approvals, compactions
		case settings, spend
	}
}

/// Events of a `conversation.watch` subscription (protocol section 7.1).
public enum ConversationEvent: Decodable, Sendable, Hashable {
	case snapshot(ConversationSnapshot)
	case itemAdded(Item)
	case streamStarted(Streaming)
	case streamDelta([StreamOp])
	case toolStarted(callId: String, name: String, args: JSONValue)
	case toolUpdated(ToolUpdate)
	case toolEnded(callId: String, resultId: EntryID?)
	case runStarted(inputs: [SubmissionID])
	case runEnded(inputs: [SubmissionID])
	case submission(Submission)
	case inboxChanged([InboxItem])
	case settingsChanged(ConversationSettings)
	case spendChanged(Spend)
	case compactionStarted(CompactionStatus)
	case compactionEnded(taskId: TaskID)
	case retryScheduled(RetryState)
	case retryCleared(attempt: Int)
	case taskFailed(TaskFailure)
	case approvalRequested(Approval)
	case approvalResolved(ApprovalResolution)
	/// A type this version does not define. The client resyncs (protocol section 3).
	case unknown(type: String)

	public init(from decoder: any Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		let type = try c.decode(String.self, forKey: .type)
		switch type {
		case "snapshot":
			self = .snapshot(try ConversationSnapshot(from: decoder))
		case "item.added":
			self = .itemAdded(try c.decode(Item.self, forKey: .item))
		case "stream.started":
			self = .streamStarted(try Streaming(from: decoder))
		case "stream.delta":
			self = .streamDelta(try c.decode([StreamOp].self, forKey: .ops))
		case "tool.started":
			self = .toolStarted(
				callId: try c.decode(String.self, forKey: .callId),
				name: try c.decodeIfPresent(String.self, forKey: .name) ?? "",
				args: try c.decodeIfPresent(JSONValue.self, forKey: .args) ?? .object([:])
			)
		case "tool.updated":
			self = .toolUpdated(
				ToolUpdate(
					callId: try c.decode(String.self, forKey: .callId),
					output: try c.decodeIfPresent(OutputUpdate.self, forKey: .output),
					details: try c.decodeUpdate(JSONValue.self, forKey: .details),
					diagnostics: try c.decodeUpdate([Diagnostic].self, forKey: .diagnostics)
				)
			)
		case "tool.ended":
			self = .toolEnded(
				callId: try c.decode(String.self, forKey: .callId),
				resultId: try c.decodeIfPresent(EntryID.self, forKey: .resultId)
			)
		case "run.started":
			self = .runStarted(inputs: try c.decodeIfPresent([SubmissionID].self, forKey: .inputs) ?? [])
		case "run.ended":
			self = .runEnded(inputs: try c.decodeIfPresent([SubmissionID].self, forKey: .inputs) ?? [])
		case "submission":
			self = .submission(try c.decode(Submission.self, forKey: .submission))
		case "inbox.changed":
			self = .inboxChanged(try c.decodeIfPresent([InboxItem].self, forKey: .items) ?? [])
		case "settings.changed":
			self = .settingsChanged(try c.decode(ConversationSettings.self, forKey: .settings))
		case "spend.changed":
			self = .spendChanged(try c.decode(Spend.self, forKey: .spend))
		case "compaction.started":
			self = .compactionStarted(try CompactionStatus(from: decoder))
		case "compaction.ended":
			self = .compactionEnded(taskId: try c.decode(TaskID.self, forKey: .taskId))
		case "retry.scheduled":
			self = .retryScheduled(try RetryState(from: decoder))
		case "retry.cleared":
			self = .retryCleared(attempt: try c.decodeIfPresent(Int.self, forKey: .attempt) ?? 0)
		case "task.failed":
			self = .taskFailed(try TaskFailure(from: decoder))
		case "approval.requested":
			self = .approvalRequested(try c.decode(Approval.self, forKey: .approval))
		case "approval.resolved":
			self = .approvalResolved(try ApprovalResolution(from: decoder))
		default:
			self = .unknown(type: type)
		}
	}

	private enum CodingKeys: String, CodingKey {
		case type, item, ops, callId, name, args, output, details, diagnostics, resultId, inputs, submission, items
		case settings, spend, taskId, attempt, approval
	}
}

public struct HostSnapshot: Decodable, Sendable, Hashable {
	public var host: HostIdentity
	public var spend: Spend
	public var conversations: [ConversationSummary]
	/// Projects whose colour was picked (aludra).
	public var projectColors: [String: Int]?
	/// This calendar month's charged dollars, when any session was charged (aludra).
	public var monthCost: Double?
}

/// Events of a `host.watch` subscription (protocol section 6.2).
public enum HostEvent: Decodable, Sendable, Hashable {
	case snapshot(HostSnapshot)
	case conversationUpdated(ConversationSummary)
	case conversationRemoved(ConversationID)
	case spend(Spend)
	/// The picked project colours changed (aludra).
	case projectColors([String: Int])
	case unknown(type: String)

	public init(from decoder: any Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		let type = try c.decode(String.self, forKey: .type)
		switch type {
		case "host.snapshot": self = .snapshot(try HostSnapshot(from: decoder))
		case "host.projectColors": self = .projectColors(try c.decode([String: Int].self, forKey: .projectColors))
		case "conversation.updated": self = .conversationUpdated(try c.decode(ConversationSummary.self, forKey: .conversation))
		case "conversation.removed": self = .conversationRemoved(try c.decode(ConversationID.self, forKey: .conversationId))
		case "host.spend": self = .spend(try c.decode(Spend.self, forKey: .spend))
		default: self = .unknown(type: type)
		}
	}

	private enum CodingKeys: String, CodingKey { case type, conversation, conversationId, spend, projectColors }
}

/// An event that failed to decode, kept so the subscription can log it and resync.
public struct UndecodableEvent: Error, Sendable, Hashable {
	public var type: String?
	public var message: String
}

/// Decodes each element on its own, so one bad event does not hide the rest of the frame.
struct LossyEvent<Event: Decodable & Sendable>: Decodable, Sendable {
	let result: Result<Event, UndecodableEvent>

	init(from decoder: any Decoder) throws {
		do {
			result = .success(try Event(from: decoder))
		} catch {
			let type = try? decoder.container(keyedBy: TypeKey.self).decode(String.self, forKey: .type)
			result = .failure(UndecodableEvent(type: type, message: String(describing: error)))
		}
	}

	private enum TypeKey: String, CodingKey { case type }
}
