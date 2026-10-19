import Foundation

/// A v1 method, with its params and result types (protocol section 5).
public protocol Command: Sendable {
	associatedtype Params: Encodable & Sendable
	associatedtype Result: Decodable & Sendable
	static var method: String { get }
	/// Whether a request whose response was lost may be sent again after reconnecting (protocol section 9.1).
	static var retriesOnReconnect: Bool { get }
	var params: Params { get }
}

public enum Commands {
	public struct HostInfo: Command {
		public static let method = "host.info"
		public static let retriesOnReconnect = true
		public struct Params: Encodable, Sendable {}
		public struct Defaults: Decodable, Sendable, Hashable {
			public var model: ModelRef?
			public var thinkingLevel: ThinkingLevel?
		}
		public struct Result: Decodable, Sendable, Hashable {
			public var host: HostIdentity
			public var models: [ModelInfo]
			public var tools: [ToolInfo]
			public var defaults: Defaults?
			/// Where new conversations can start; servers that tie conversations to projects list them (aludra does).
			public var projects: [ProjectInfo]?
			/// Projects whose colour was picked, name to `ProjectColor.hues` index (aludra).
			public var projectColors: [String: Int]?
			/// This calendar month's charged dollars, when any session was charged (aludra).
			public var monthCost: Double?
		}
		public let params = Params()
		public init() {}
	}

	/// Picks a project's colour on its host, or with nil gives it back its name's (aludra).
	public struct SetProjectColor: Command {
		public static let method = "projects.setColor"
		public static let retriesOnReconnect = true
		public struct Params: Encodable, Sendable {
			public var project: String
			public var color: Int?

			// `color` is sent as null to clear it; the synthesized encoding would leave it out.
			public func encode(to encoder: any Encoder) throws {
				var c = encoder.container(keyedBy: CodingKeys.self)
				try c.encode(project, forKey: .project)
				try c.encode(color, forKey: .color)
			}

			private enum CodingKeys: String, CodingKey { case project, color }
		}
		public struct Result: Decodable, Sendable, Hashable { public var projectColors: [String: Int] }
		public let params: Params
		public init(project: String, color: Int?) { params = Params(project: project, color: color) }
	}

	public struct ListConversations: Command {
		public static let method = "conversations.list"
		public static let retriesOnReconnect = true
		public struct Params: Encodable, Sendable { public var includeArchived: Bool }
		public struct Result: Decodable, Sendable, Hashable { public var conversations: [ConversationSummary] }
		public let params: Params
		public init(includeArchived: Bool = false) { params = Params(includeArchived: includeArchived) }
	}

	public struct CreatedResult: Decodable, Sendable, Hashable {
		public var conversation: ConversationSummary
		public var duplicate: Bool
	}

	public struct CreateConversation: Command {
		public static let method = "conversations.create"
		public static let retriesOnReconnect = true
		public struct Params: Encodable, Sendable {
			public var requestId: String
			public var title: String?
			public var settings: SettingsChange?
			/// A project directory from `host.info`.
			public var project: String?
			/// A first message, submitted with the conversation.
			public var text: String?
			/// The first message's images (aludra).
			public var images: [ImageUpload]?
		}
		public typealias Result = CreatedResult
		public let params: Params
		public init(requestId: String = UUID().uuidString, title: String? = nil, settings: SettingsChange? = nil, project: String? = nil, text: String? = nil, images: [ImageUpload] = []) {
			params = Params(requestId: requestId, title: title, settings: settings, project: project, text: text, images: images.isEmpty ? nil : images)
		}
	}

	public struct ForkConversation: Command {
		public static let method = "conversations.fork"
		public static let retriesOnReconnect = true
		public struct Params: Encodable, Sendable {
			public var requestId: String
			public var conversationId: ConversationID
			public var at: EntryID
			public var title: String?
		}
		public typealias Result = CreatedResult
		public let params: Params
		public init(requestId: String = UUID().uuidString, conversationId: ConversationID, at: EntryID, title: String? = nil) {
			params = Params(requestId: requestId, conversationId: conversationId, at: at, title: title)
		}
	}

	/// Gives a conversation a new title (aludra; deferred in the v1 review, added as an optional method).
	public struct RenameConversation: Command {
		public static let method = "conversations.rename"
		public static let retriesOnReconnect = true
		public struct Params: Encodable, Sendable {
			public var conversationId: ConversationID
			public var title: String
		}
		public struct Result: Decodable, Sendable, Hashable { public var conversation: ConversationSummary }
		public let params: Params
		public init(conversationId: ConversationID, title: String) {
			params = Params(conversationId: conversationId, title: title)
		}
	}

	public struct ArchiveConversation: Command {
		public static let method = "conversations.archive"
		public static let retriesOnReconnect = true
		public struct Params: Encodable, Sendable {
			public var conversationId: ConversationID
			public var archived: Bool
		}
		public struct Result: Decodable, Sendable, Hashable { public var conversation: ConversationSummary }
		public let params: Params
		public init(conversationId: ConversationID, archived: Bool) {
			params = Params(conversationId: conversationId, archived: archived)
		}
	}

	public struct Submit: Command {
		public static let method = "submit"
		public static let retriesOnReconnect = true
		public struct Params: Encodable, Sendable {
			public var conversationId: ConversationID
			public var requestId: String
			public var text: String
			public var whenBusy: WhenBusy
			/// Images with the text (aludra).
			public var images: [ImageUpload]?
		}
		public struct Result: Decodable, Sendable, Hashable {
			public var submission: Submission
			public var duplicate: Bool
		}
		public let params: Params
		public init(conversationId: ConversationID, requestId: String, text: String, whenBusy: WhenBusy = .followUp, images: [ImageUpload] = []) {
			params = Params(conversationId: conversationId, requestId: requestId, text: text, whenBusy: whenBusy, images: images.isEmpty ? nil : images)
		}
	}

	/// An image in the transcript: block `index` of item `entryId` (aludra). Image blocks carry no bytes.
	public struct ConversationImage: Command {
		public static let method = "conversation.image"
		public static let retriesOnReconnect = true
		public struct Params: Encodable, Sendable {
			public var conversationId: ConversationID
			public var entryId: EntryID
			public var index: Int
		}
		public typealias Result = ImageUpload
		public let params: Params
		public init(conversationId: ConversationID, entryId: EntryID, index: Int) {
			params = Params(conversationId: conversationId, entryId: entryId, index: index)
		}
	}

	public struct Abort: Command {
		public static let method = "abort"
		public static let retriesOnReconnect = true
		public struct Params: Encodable, Sendable { public var conversationId: ConversationID }
		public typealias Result = EmptyResult
		public let params: Params
		public init(conversationId: ConversationID) { params = Params(conversationId: conversationId) }
	}

	public struct Configure: Command {
		public static let method = "configure"
		public static let retriesOnReconnect = true
		public struct Params: Encodable, Sendable {
			public var conversationId: ConversationID
			public var changes: SettingsChange
		}
		public struct Result: Decodable, Sendable, Hashable { public var settings: ConversationSettings }
		public let params: Params
		public init(conversationId: ConversationID, changes: SettingsChange) {
			params = Params(conversationId: conversationId, changes: changes)
		}
	}

	public struct Compact: Command {
		public static let method = "compact"
		public static let retriesOnReconnect = false
		public struct Params: Encodable, Sendable {
			public var conversationId: ConversationID
			public var instructions: String?
		}
		public struct Result: Decodable, Sendable, Hashable { public var taskId: TaskID }
		public let params: Params
		public init(conversationId: ConversationID, instructions: String? = nil) {
			params = Params(conversationId: conversationId, instructions: instructions)
		}
	}

	public struct Reset: Command {
		public static let method = "reset"
		public static let retriesOnReconnect = false
		public struct Params: Encodable, Sendable {
			public var conversationId: ConversationID
			public var handoff: String?
		}
		public typealias Result = EmptyResult
		public let params: Params
		public init(conversationId: ConversationID, handoff: String? = nil) {
			params = Params(conversationId: conversationId, handoff: handoff)
		}
	}

	public struct AnswerApproval: Command {
		public static let method = "approval.answer"
		public static let retriesOnReconnect = true
		public enum Decision: String, Encodable, Sendable { case approve, deny }
		public struct Params: Encodable, Sendable {
			public var approvalId: String
			public var decision: Decision
			public var message: String?
			/// Approving, also allow the approval's summary for the rest of the session (aludra). Left out when false.
			public var always: Bool?
		}
		public struct Result: Decodable, Sendable, Hashable { public var approval: ApprovalResolution }
		public let params: Params
		public init(approvalId: String, decision: Decision, message: String? = nil, always: Bool = false) {
			params = Params(approvalId: approvalId, decision: decision, message: message, always: always ? true : nil)
		}
	}

	/// Asks again before the session runs a summary an always answer allowed (aludra; optional within v1).
	public struct ForgetApproval: Command {
		public static let method = "approval.forget"
		public static let retriesOnReconnect = true
		public struct Params: Encodable, Sendable {
			public var conversationId: ConversationID
			public var summary: String
		}
		public struct Result: Decodable, Sendable, Hashable { public var conversation: ConversationSummary }
		public let params: Params
		public init(conversationId: ConversationID, summary: String) {
			params = Params(conversationId: conversationId, summary: summary)
		}
	}

	public struct History: Command {
		public static let method = "conversation.history"
		public static let retriesOnReconnect = true
		public struct Params: Encodable, Sendable {
			public var conversationId: ConversationID
			public var before: EntryID
			public var limit: Int
		}
		public struct Result: Decodable, Sendable, Hashable {
			public var items: [Item]
			public var hasEarlier: Bool
		}
		public let params: Params
		public init(conversationId: ConversationID, before: EntryID, limit: Int = 100) {
			params = Params(conversationId: conversationId, before: before, limit: limit)
		}
	}

	struct WatchConversation: Command {
		static let method = "conversation.watch"
		static let retriesOnReconnect = false
		struct Params: Encodable, Sendable { var conversationId: ConversationID }
		let params: Params
		typealias Result = WatchResult
	}

	struct WatchHost: Command {
		static let method = "host.watch"
		static let retriesOnReconnect = false
		struct Params: Encodable, Sendable {}
		let params = Params()
		typealias Result = WatchResult
	}

	struct Unsubscribe: Command {
		static let method = "unsubscribe"
		static let retriesOnReconnect = false
		struct Params: Encodable, Sendable { var subscription: String }
		let params: Params
		typealias Result = EmptyResult
	}

	struct WatchResult: Decodable, Sendable { var subscription: String }
}

/// `configure` changes: an unset field is left alone, `.cleared` resets it to the host default (protocol section 5).
public struct SettingsChange: Encodable, Sendable, Hashable {
	public var model: FieldUpdate<ModelRef> = .unchanged
	public var thinkingLevel: FieldUpdate<ThinkingLevel> = .unchanged
	public var cwd: FieldUpdate<String> = .unchanged
	public var tools: FieldUpdate<[String]> = .unchanged

	public init(
		model: FieldUpdate<ModelRef> = .unchanged,
		thinkingLevel: FieldUpdate<ThinkingLevel> = .unchanged,
		cwd: FieldUpdate<String> = .unchanged,
		tools: FieldUpdate<[String]> = .unchanged
	) {
		self.model = model
		self.thinkingLevel = thinkingLevel
		self.cwd = cwd
		self.tools = tools
	}

	public func encode(to encoder: any Encoder) throws {
		var c = encoder.container(keyedBy: CodingKeys.self)
		try c.encodeUpdate(model, forKey: .model)
		try c.encodeUpdate(thinkingLevel, forKey: .thinkingLevel)
		try c.encodeUpdate(cwd, forKey: .cwd)
		try c.encodeUpdate(tools, forKey: .tools)
	}

	private enum CodingKeys: String, CodingKey { case model, thinkingLevel, cwd, tools }
}

extension KeyedEncodingContainer {
	mutating func encodeUpdate<Value: Encodable>(_ update: FieldUpdate<Value>, forKey key: Key) throws {
		switch update {
		case .unchanged: break
		case .cleared: try encodeNil(forKey: key)
		case .set(let value): try encode(value, forKey: key)
		}
	}
}
