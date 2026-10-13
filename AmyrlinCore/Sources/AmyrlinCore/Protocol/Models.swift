import Foundation

/// Durable IDs: entries, submissions, tasks and conversations share one numeric space per host (protocol section 4).
public typealias EntryID = Int64
public typealias SubmissionID = Int64
public typealias TaskID = Int64
public typealias ConversationID = Int64

/// An image's bytes as the protocol carries them: base64, with its type.
public struct ImageUpload: Codable, Sendable, Hashable {
	public var mimeType: String
	public var data: String
	public init(mimeType: String, data: String) {
		self.mimeType = mimeType
		self.data = data
	}
}

/// Where an image is in a transcript: block `index` of item `entryId`.
public struct ImageRef: Sendable, Hashable {
	public var entryId: EntryID
	public var index: Int
	public var mimeType: String
	public init(entryId: EntryID, index: Int, mimeType: String) {
		self.entryId = entryId
		self.index = index
		self.mimeType = mimeType
	}

	/// The image blocks of item `entryId`'s content.
	public static func all(in content: [Block], entryId: EntryID) -> [ImageRef] {
		content.enumerated().compactMap { index, block in
			if case .image(let mimeType) = block { ImageRef(entryId: entryId, index: index, mimeType: mimeType) } else { nil }
		}
	}
}

public struct ModelRef: Codable, Sendable, Hashable {
	public var provider: String
	public var modelId: String

	public init(provider: String, modelId: String) {
		self.provider = provider
		self.modelId = modelId
	}

	public var key: String { "\(provider)/\(modelId)" }
}

/// Token counts and cost in US dollars (protocol section 4.2). Assistant items carry it without the breakdowns.
public struct Spend: Decodable, Sendable, Hashable {
	public var input: Int = 0
	public var output: Int = 0
	public var cacheRead: Int = 0
	public var cacheWrite: Int = 0
	public var total: Int = 0
	public var cost: Double = 0
	public var byModel: [String: Spend] = [:]
	public var byTool: [String: Spend] = [:]

	public static let zero = Spend()

	public init() {}

	public init(from decoder: any Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		input = try c.decodeIfPresent(Int.self, forKey: .input) ?? 0
		output = try c.decodeIfPresent(Int.self, forKey: .output) ?? 0
		cacheRead = try c.decodeIfPresent(Int.self, forKey: .cacheRead) ?? 0
		cacheWrite = try c.decodeIfPresent(Int.self, forKey: .cacheWrite) ?? 0
		total = try c.decodeIfPresent(Int.self, forKey: .total) ?? 0
		cost = try c.decodeIfPresent(Double.self, forKey: .cost) ?? 0
		byModel = try c.decodeIfPresent([String: Spend].self, forKey: .byModel) ?? [:]
		byTool = try c.decodeIfPresent([String: Spend].self, forKey: .byTool) ?? [:]
	}

	private enum CodingKeys: String, CodingKey {
		case input, output, cacheRead, cacheWrite, total, cost, byModel, byTool
	}
}

public struct Diagnostic: Decodable, Sendable, Hashable {
	public var severity: String
	public var message: String
	public var code: String?
}

// MARK: - Blocks and items

public struct ToolCallBlock: Sendable, Hashable {
	public var id: String
	public var name: String
	public var args: JSONValue
}

/// Content of a message (protocol section 4.4).
public enum Block: Decodable, Sendable, Hashable {
	case text(String)
	case thinking(String, redacted: Bool)
	case toolCall(ToolCallBlock)
	case image(mimeType: String)
	case unknown(type: String)

	public init(from decoder: any Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		let type = try c.decode(String.self, forKey: .type)
		switch type {
		case "text":
			self = .text(try c.decode(String.self, forKey: .text))
		case "thinking":
			self = .thinking(
				try c.decodeIfPresent(String.self, forKey: .text) ?? "",
				redacted: try c.decodeIfPresent(Bool.self, forKey: .redacted) ?? false
			)
		case "toolCall":
			self = .toolCall(
				ToolCallBlock(
					id: try c.decode(String.self, forKey: .id),
					name: try c.decode(String.self, forKey: .name),
					args: try c.decodeIfPresent(JSONValue.self, forKey: .args) ?? .object([:])
				)
			)
		case "image":
			self = .image(mimeType: try c.decodeIfPresent(String.self, forKey: .mimeType) ?? "")
		default:
			self = .unknown(type: type)
		}
	}

	private enum CodingKeys: String, CodingKey {
		case type, text, redacted, id, name, args, mimeType
	}
}

public struct UserItem: Sendable, Hashable {
	public var content: [Block]
	/// Set when the input carried its own entry kind (protocol section 4.3).
	public var kind: String?
	public var data: JSONValue?
}

public struct AssistantItem: Sendable, Hashable {
	public var content: [Block]
	public var stopReason: StopReason
	public var model: ModelRef?
	public var spend: Spend?
	public var error: String?
}

public struct ToolResultItem: Sendable, Hashable {
	public var callId: String
	public var toolName: String
	public var content: [Block]
	public var isError: Bool
	public var details: JSONValue?
	public var diagnostics: [Diagnostic]
	public var durationMs: Int?
}

public struct ResetItem: Sendable, Hashable {
	public var handoff: String?
	public var contextStart: EntryID
}

public struct CompactionItem: Sendable, Hashable {
	public var summary: String
	public var reason: String
	public var contextStart: EntryID
}

public struct CustomItem: Sendable, Hashable {
	public var kind: String
	public var data: JSONValue?
}

/// One transcript item, from one durable entry (protocol section 4.3).
public struct Item: Decodable, Sendable, Hashable, Identifiable {
	public enum Body: Sendable, Hashable {
		case user(UserItem)
		case assistant(AssistantItem)
		case toolResult(ToolResultItem)
		case reset(ResetItem)
		case compaction(CompactionItem)
		case custom(CustomItem)
		case unknown(type: String)
	}

	public var id: EntryID
	public var at: Int64?
	public var truncated: Bool
	public var body: Body

	/// The entry ID at which the model's context starts, for reset and compaction items.
	public var contextStart: EntryID? {
		switch body {
		case .reset(let reset): reset.contextStart
		case .compaction(let compaction): compaction.contextStart
		default: nil
		}
	}

	public init(from decoder: any Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		id = try c.decode(EntryID.self, forKey: .id)
		at = try c.decodeIfPresent(Int64.self, forKey: .at)
		truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
		let type = try c.decode(String.self, forKey: .type)
		switch type {
		case "user":
			body = .user(
				UserItem(
					content: try c.decodeIfPresent([Block].self, forKey: .content) ?? [],
					kind: try c.decodeIfPresent(String.self, forKey: .kind),
					data: try c.decodeIfPresent(JSONValue.self, forKey: .data)
				)
			)
		case "assistant":
			body = .assistant(
				AssistantItem(
					content: try c.decodeIfPresent([Block].self, forKey: .content) ?? [],
					stopReason: try c.decodeIfPresent(StopReason.self, forKey: .stopReason) ?? .unknown(""),
					model: try c.decodeIfPresent(ModelRef.self, forKey: .model),
					spend: try c.decodeIfPresent(Spend.self, forKey: .spend),
					error: try c.decodeIfPresent(String.self, forKey: .error)
				)
			)
		case "toolResult":
			body = .toolResult(
				ToolResultItem(
					callId: try c.decode(String.self, forKey: .callId),
					toolName: try c.decodeIfPresent(String.self, forKey: .toolName) ?? "",
					content: try c.decodeIfPresent([Block].self, forKey: .content) ?? [],
					isError: try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false,
					details: try c.decodeIfPresent(JSONValue.self, forKey: .details),
					diagnostics: try c.decodeIfPresent([Diagnostic].self, forKey: .diagnostics) ?? [],
					durationMs: try c.decodeIfPresent(Int.self, forKey: .durationMs)
				)
			)
		case "reset":
			body = .reset(
				ResetItem(
					handoff: try c.decodeIfPresent(String.self, forKey: .handoff),
					contextStart: try c.decodeIfPresent(EntryID.self, forKey: .contextStart) ?? id
				)
			)
		case "compaction":
			body = .compaction(
				CompactionItem(
					summary: try c.decodeIfPresent(String.self, forKey: .summary) ?? "",
					reason: try c.decodeIfPresent(String.self, forKey: .reason) ?? "",
					contextStart: try c.decode(EntryID.self, forKey: .contextStart)
				)
			)
		case "custom":
			body = .custom(
				CustomItem(
					kind: try c.decodeIfPresent(String.self, forKey: .kind) ?? "",
					data: try c.decodeIfPresent(JSONValue.self, forKey: .data)
				)
			)
		default:
			body = .unknown(type: type)
		}
	}

	private enum CodingKeys: String, CodingKey {
		case id, at, truncated, type, content, kind, data, stopReason, model, spend, error
		case callId, toolName, isError, details, diagnostics, durationMs, handoff, contextStart, summary, reason
	}
}

// MARK: - Live state

/// A running tool call the transcript cannot show yet (protocol section 4.5).
public struct ToolSlot: Decodable, Sendable, Hashable, Identifiable {
	public var callId: String
	public var name: String
	public var status: SlotStatus
	public var output: String
	public var droppedBytes: Int
	public var droppedLines: Int
	public var details: JSONValue?
	public var diagnostics: [Diagnostic]

	public var id: String { callId }

	public init(callId: String, name: String, status: SlotStatus) {
		self.callId = callId
		self.name = name
		self.status = status
		output = ""
		droppedBytes = 0
		droppedLines = 0
		details = nil
		diagnostics = []
	}

	public init(from decoder: any Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		callId = try c.decode(String.self, forKey: .callId)
		name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
		status = try c.decode(SlotStatus.self, forKey: .status)
		output = try c.decodeIfPresent(String.self, forKey: .output) ?? ""
		droppedBytes = try c.decodeIfPresent(Int.self, forKey: .droppedBytes) ?? 0
		droppedLines = try c.decodeIfPresent(Int.self, forKey: .droppedLines) ?? 0
		details = try c.decodeIfPresent(JSONValue.self, forKey: .details)
		diagnostics = try c.decodeIfPresent([Diagnostic].self, forKey: .diagnostics) ?? []
	}

	private enum CodingKeys: String, CodingKey {
		case callId, name, status, output, droppedBytes, droppedLines, details, diagnostics
	}
}

public struct InboxItem: Decodable, Sendable, Hashable, Identifiable {
	public var submissionId: SubmissionID
	public var mode: InboxMode
	public var requestId: String?
	public var text: String?
	public var kind: String?

	public var id: SubmissionID { submissionId }
}

public struct Submission: Decodable, Sendable, Hashable, Identifiable {
	public var id: SubmissionID
	public var requestId: String?
	public var type: String
	public var status: SubmissionStatus
	public var entryId: EntryID?
	public var answerId: EntryID?
	public var reason: String?
	public var detail: JSONValue?
}

/// Stored tool selection: exactly these tools, or the host default minus some.
public enum ToolSelection: Codable, Sendable, Hashable {
	case only([String])
	case remove([String])

	public init(from decoder: any Decoder) throws {
		let container = try decoder.singleValueContainer()
		if let names = try? container.decode([String].self) {
			self = .only(names)
		} else {
			self = .remove(try container.decode([String: [String]].self)["remove"] ?? [])
		}
	}

	public func encode(to encoder: any Encoder) throws {
		var container = encoder.singleValueContainer()
		switch self {
		case .only(let names): try container.encode(names)
		case .remove(let names): try container.encode(["remove": names])
		}
	}
}

public struct StoredSettings: Decodable, Sendable, Hashable {
	public var model: ModelRef?
	public var thinkingLevel: ThinkingLevel?
	public var cwd: String?
	public var tools: ToolSelection?
	public var instructions: String?
}

public struct EffectiveSettings: Decodable, Sendable, Hashable {
	public var model: ModelRef?
	public var thinkingLevel: ThinkingLevel?
	public var cwd: String?
	public var tools: [String]

	public init(from decoder: any Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		model = try c.decodeIfPresent(ModelRef.self, forKey: .model)
		thinkingLevel = try c.decodeIfPresent(ThinkingLevel.self, forKey: .thinkingLevel)
		cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
		tools = try c.decodeIfPresent([String].self, forKey: .tools) ?? []
	}

	private enum CodingKeys: String, CodingKey {
		case model, thinkingLevel, cwd, tools
	}
}

/// A conversation's agent settings, as stored and as resolved (protocol section 4.8).
public struct ConversationSettings: Decodable, Sendable, Hashable {
	public var stored: StoredSettings
	public var effective: EffectiveSettings
}

public struct Approval: Decodable, Sendable, Hashable, Identifiable {
	public var approvalId: String
	public var conversationId: ConversationID
	public var callId: String
	public var toolName: String
	public var args: JSONValue
	public var requestedAt: Int64

	public var id: String { approvalId }
}

public struct ApprovalResolution: Decodable, Sendable, Hashable {
	public var approvalId: String
	public var decision: ApprovalDecision
	public var by: String?
	public var message: String?
}

public struct RetryState: Decodable, Sendable, Hashable {
	public var attempt: Int
	public var at: Int64
	public var error: String
}

public struct CompactionStatus: Decodable, Sendable, Hashable, Identifiable {
	public var taskId: TaskID
	public var reason: String
	public var blocking: Bool
	public var attempt: Int?
	public var retry: RetryState?

	public var id: TaskID { taskId }
}

public struct TaskFailure: Decodable, Sendable, Hashable {
	public var taskId: TaskID
	public var kind: String
	public var message: String
}

/// The in-flight assistant message (protocol section 6.1 `streaming`).
public struct Streaming: Decodable, Sendable, Hashable {
	public var attempt: Int
	public var content: [Block]
	public var model: ModelRef?
}

public struct RunState: Decodable, Sendable, Hashable {
	public var inputs: [SubmissionID]
}

public struct ParentRef: Decodable, Sendable, Hashable {
	public var conversationId: ConversationID
	public var at: EntryID
}

// MARK: - Host

public struct HostIdentity: Decodable, Sendable, Hashable {
	public var hostId: String
	public var name: String
	public var serverVersion: String?
	public var durableVersion: String?
}

public struct Person: Decodable, Sendable, Hashable {
	public var login: String
	public var name: String?
}

public struct Limits: Decodable, Sendable, Hashable {
	public var maxFrameBytes: Int
	public var snapshotItems: Int
}

public struct StuckInfo: Decodable, Sendable, Hashable {
	public var reason: String
	public var taskKind: String?
}

/// One row of the sidebar (protocol section 4.10).
public struct ConversationSummary: Decodable, Sendable, Hashable, Identifiable {
	public var id: ConversationID
	public var title: String
	public var status: ConversationStatus
	public var archived: Bool
	public var parent: ParentRef?
	public var model: ModelRef?
	public var createdAt: Int64
	public var updatedAt: Int64
	public var pendingApprovals: Int
	public var spend: Spend
	public var stuck: StuckInfo?
	/// The project a conversation works in, for servers that have projects.
	public var workspace: String?
	public var project: String?
	public var dir: String?

	public init(from decoder: any Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		id = try c.decode(ConversationID.self, forKey: .id)
		title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
		status = try c.decodeIfPresent(ConversationStatus.self, forKey: .status) ?? .idle
		archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
		parent = try c.decodeIfPresent(ParentRef.self, forKey: .parent)
		model = try c.decodeIfPresent(ModelRef.self, forKey: .model)
		createdAt = try c.decodeIfPresent(Int64.self, forKey: .createdAt) ?? 0
		updatedAt = try c.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? createdAt
		pendingApprovals = try c.decodeIfPresent(Int.self, forKey: .pendingApprovals) ?? 0
		spend = try c.decodeIfPresent(Spend.self, forKey: .spend) ?? .zero
		stuck = try c.decodeIfPresent(StuckInfo.self, forKey: .stuck)
		workspace = try c.decodeIfPresent(String.self, forKey: .workspace)
		project = try c.decodeIfPresent(String.self, forKey: .project)
		dir = try c.decodeIfPresent(String.self, forKey: .dir)
	}

	private enum CodingKeys: String, CodingKey {
		case id, title, status, archived, parent, model, createdAt, updatedAt, pendingApprovals, spend, stuck, workspace, project, dir
	}
}

public struct ModelInfo: Decodable, Sendable, Hashable, Identifiable {
	public var provider: String
	public var modelId: String
	public var name: String?
	public var reasoning: Bool?
	public var thinkingLevels: [ThinkingLevel]?
	public var contextWindow: Int?
	public var maxTokens: Int?
	public var input: [String]?
	public var available: Bool?

	public var ref: ModelRef { ModelRef(provider: provider, modelId: modelId) }
	public var id: String { ref.key }
}

/// A directory new conversations can start in.
public struct ProjectInfo: Decodable, Sendable, Hashable, Identifiable {
	public var workspace: String
	public var name: String
	/// Relative to the workspace root, such as `Software/aludra`.
	public var path: String
	public var dir: String

	public var id: String { dir }
}

public struct ToolInfo: Decodable, Sendable, Hashable, Identifiable {
	public var name: String
	public var description: String?
	public var requiresApproval: Bool?

	public var id: String { name }
}
