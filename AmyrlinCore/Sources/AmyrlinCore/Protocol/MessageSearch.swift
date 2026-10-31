import Foundation

/// A message or answer matching a search, best first, with its session's title and project (aludra's own
/// `SearchResult`). `entry` is the item's entry ID in `conversation.history`; `item` is aludra's own id for it.
public struct SearchResult: Decodable, Sendable, Hashable {
	public enum Author: OpenEnum {
		case user, agent
		case unknown(String)

		public init(rawValue: String) {
			switch rawValue {
			case "user": self = .user
			case "agent": self = .agent
			default: self = .unknown(rawValue)
			}
		}

		public var rawValue: String {
			switch self {
			case .user: "user"
			case .agent: "agent"
			case .unknown(let value): value
			}
		}
	}

	public var session: ConversationID
	public var entry: EntryID
	public var index: Int
	public var item: String
	public var from: Author
	public var at: Int64
	/// The text around the match, matched words between « and ». `SearchSnippet` reads it.
	public var snippet: String
	public var title: String
	public var project: String
	public var workspace: String
	public var archived: Bool

	public init(from decoder: any Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		session = try c.decode(ConversationID.self, forKey: .session)
		entry = try c.decode(EntryID.self, forKey: .entry)
		index = try c.decodeIfPresent(Int.self, forKey: .index) ?? 0
		item = try c.decodeIfPresent(String.self, forKey: .item) ?? ""
		from = try c.decodeIfPresent(Author.self, forKey: .from) ?? .agent
		at = try c.decodeIfPresent(Int64.self, forKey: .at) ?? 0
		snippet = try c.decodeIfPresent(String.self, forKey: .snippet) ?? ""
		title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
		project = try c.decodeIfPresent(String.self, forKey: .project) ?? ""
		workspace = try c.decodeIfPresent(String.self, forKey: .workspace) ?? ""
		archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
	}

	private enum CodingKeys: String, CodingKey { case session, entry, index, item, from, at, snippet, title, project, workspace, archived }
}

/// A snippet's text in runs, each matched or not, without the « » the host marks matches with.
public enum SearchSnippet {
	public struct Run: Sendable, Hashable {
		public var text: String
		public var matched: Bool
		public init(_ text: String, matched: Bool) {
			self.text = text
			self.matched = matched
		}
	}

	public static func runs(_ snippet: String) -> [Run] {
		var runs: [Run] = []
		var current = ""
		var matched = false
		func flush() {
			if !current.isEmpty { runs.append(Run(current, matched: matched)) }
			current = ""
		}
		for character in snippet {
			switch character {
			case "«" where !matched:
				flush()
				matched = true
			case "»" where matched:
				flush()
				matched = false
			default:
				current.append(character)
			}
		}
		// An unclosed « still ends its run.
		flush()
		return runs
	}
}

/// Results from several machines in one list. One host's ranks don't compare with another's, so it takes each
/// machine's best, then each one's second best, and so on, machines in the order given.
public enum SearchMerge {
	public static func interleave<Machine>(_ lists: [(Machine, [SearchResult])]) -> [(machine: Machine, result: SearchResult)] {
		let longest = lists.map(\.1.count).max() ?? 0
		var out: [(machine: Machine, result: SearchResult)] = []
		for rank in 0..<longest {
			for (machine, results) in lists where rank < results.count {
				out.append((machine: machine, result: results[rank]))
			}
		}
		return out
	}
}

extension Commands {
	/// Messages and answers matching `query`, across a host's sessions or in one, best first (aludra's own). Archived
	/// sessions are searched too, their results marked. A host without it answers `unknown_method`.
	public struct SearchMessages: Command {
		public static let method = "messages.search"
		public static let retriesOnReconnect = true
		public struct Params: Encodable, Sendable {
			public var query: String
			public var conversationId: ConversationID?
			public var limit: Int?
		}
		public struct Result: Decodable, Sendable, Hashable { public var results: [SearchResult] }
		public let params: Params
		public init(query: String, conversationId: ConversationID? = nil, limit: Int? = nil) {
			params = Params(query: query, conversationId: conversationId, limit: limit)
		}
	}
}
