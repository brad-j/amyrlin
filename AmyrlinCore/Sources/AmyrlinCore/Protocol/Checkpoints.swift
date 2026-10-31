import Foundation

/// A snapshot of a project session's files (aludra's own, outside v1). A `turn` checkpoint is taken as the user message
/// sent at `message` starts a turn; `message` equals that user item's `at`. A `restore` one holds the files just before
/// checkpoint `restored` was put back, which is what undoing that restore goes back to.
public struct Checkpoint: Decodable, Sendable, Hashable, Identifiable {
	public enum Kind: OpenEnum {
		case turn, restore
		case unknown(String)

		public init(rawValue: String) {
			switch rawValue {
			case "turn": self = .turn
			case "restore": self = .restore
			default: self = .unknown(rawValue)
			}
		}

		public var rawValue: String {
			switch self {
			case .turn: "turn"
			case .restore: "restore"
			case .unknown(let value): value
			}
		}
	}

	public var id: Int
	public var at: Int64
	public var tree: String
	public var kind: Kind
	public var message: Int64?
	public var restored: Int?
}

/// One file a session or turn changed, against where it started.
public struct ChangedFile: Decodable, Sendable, Hashable, Identifiable {
	public enum Status: OpenEnum {
		case added, deleted, modified, renamed
		case unknown(String)

		public init(rawValue: String) {
			switch rawValue {
			case "added": self = .added
			case "deleted": self = .deleted
			case "modified": self = .modified
			case "renamed": self = .renamed
			default: self = .unknown(rawValue)
			}
		}

		public var rawValue: String {
			switch self {
			case .added: "added"
			case .deleted: "deleted"
			case .modified: "modified"
			case .renamed: "renamed"
			case .unknown(let value): value
			}
		}
	}

	public var path: String
	/// A renamed file's old path.
	public var old: String?
	public var add: Int
	public var del: Int
	public var binary: Bool
	public var status: Status

	public var id: String { path }

	public init(from decoder: any Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		path = try c.decode(String.self, forKey: .path)
		old = try c.decodeIfPresent(String.self, forKey: .old)
		add = try c.decodeIfPresent(Int.self, forKey: .add) ?? 0
		del = try c.decodeIfPresent(Int.self, forKey: .del) ?? 0
		binary = try c.decodeIfPresent(Bool.self, forKey: .binary) ?? false
		status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .modified
	}

	private enum CodingKeys: String, CodingKey { case path, old, add, del, binary, status }
}

/// What changed over a span, the biggest files first (aludra's `Changes`), or why it can't say: the project isn't in
/// git, or the session is older than checkpoints.
public enum Changes: Decodable, Sendable, Hashable {
	case available(since: Int64, add: Int, del: Int, files: [ChangedFile])
	case unavailable(reason: String)

	public init(from decoder: any Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		if try c.decodeIfPresent(Bool.self, forKey: .available) == false {
			self = .unavailable(reason: try c.decodeIfPresent(String.self, forKey: .reason) ?? "Changes aren't available")
		} else {
			self = .available(
				since: try c.decodeIfPresent(Int64.self, forKey: .since) ?? 0,
				add: try c.decodeIfPresent(Int.self, forKey: .add) ?? 0,
				del: try c.decodeIfPresent(Int.self, forKey: .del) ?? 0,
				files: try c.decodeIfPresent([ChangedFile].self, forKey: .files) ?? []
			)
		}
	}

	private enum CodingKeys: String, CodingKey { case available, since, add, del, files, reason }
}

/// What a restore did: files written and deleted, the paths, and `undo`, the checkpoint that puts them back.
public struct RestoreResult: Decodable, Sendable, Hashable {
	public var written: Int
	public var deleted: Int
	public var files: [String]
	public var undo: Int
}

extension Commands {
	/// A session's checkpoints, oldest first (aludra's own).
	public struct ListCheckpoints: Command {
		public static let method = "checkpoints.list"
		public static let retriesOnReconnect = true
		public struct Params: Encodable, Sendable { public var conversationId: ConversationID }
		public struct Result: Decodable, Sendable, Hashable { public var checkpoints: [Checkpoint] }
		public let params: Params
		public init(conversationId: ConversationID) { params = Params(conversationId: conversationId) }
	}

	/// What changed from a checkpoint to the next, or to now for the latest (aludra's own).
	public struct CheckpointChanges: Command {
		public static let method = "checkpoints.changes"
		public static let retriesOnReconnect = true
		public struct Params: Encodable, Sendable {
			public var conversationId: ConversationID
			public var checkpoint: Int
		}
		public struct Result: Decodable, Sendable, Hashable { public var changes: Changes }
		public let params: Params
		public init(conversationId: ConversationID, checkpoint: Int) { params = Params(conversationId: conversationId, checkpoint: checkpoint) }
	}

	/// One file's diff over a checkpoint's span; only a file in its changes has one (aludra's own).
	public struct CheckpointDiff: Command {
		public static let method = "checkpoints.changes"
		public static let retriesOnReconnect = true
		public struct Params: Encodable, Sendable {
			public var conversationId: ConversationID
			public var checkpoint: Int
			public var path: String
		}
		public struct Result: Decodable, Sendable, Hashable {
			public var path: String
			public var patch: String
		}
		public let params: Params
		public init(conversationId: ConversationID, checkpoint: Int, path: String) {
			params = Params(conversationId: conversationId, checkpoint: checkpoint, path: path)
		}
	}

	/// Puts the project's files back to a checkpoint, after recording them as they are (aludra's own). `busy` while the
	/// session runs or waits. Not sent again after a dropped connection: a second one would record the restored files
	/// as the undo point.
	public struct RestoreCheckpoint: Command {
		public static let method = "checkpoints.restore"
		public static let retriesOnReconnect = false
		public struct Params: Encodable, Sendable {
			public var conversationId: ConversationID
			public var checkpoint: Int
		}
		public typealias Result = RestoreResult
		public let params: Params
		public init(conversationId: ConversationID, checkpoint: Int) { params = Params(conversationId: conversationId, checkpoint: checkpoint) }
	}
}
