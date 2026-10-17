import Foundation

/// The projects of every machine, for the spotlight (⌘/): with no query the most recently used first, then the rest by
/// name; with one, fuzzy matches (FuzzyMatch) on the name, or failing that on the path, best first. A name match counts
/// for more than the same match in the path, and recently used projects win ties.
public enum ProjectSpotlight {
	public struct Source<Machine: Hashable & Sendable>: Sendable {
		public let machine: Machine
		public let projects: [ProjectInfo]
		public let sessions: [ConversationSummary]

		public init(machine: Machine, projects: [ProjectInfo], sessions: [ConversationSummary]) {
			self.machine = machine
			self.projects = projects
			self.sessions = sessions
		}
	}

	public struct Result<Machine: Hashable & Sendable>: Sendable, Hashable, Identifiable {
		public let machine: Machine
		public let entry: ProjectCatalog.Entry
		/// The query's characters in the project's name, or else in its path, as offsets.
		public let nameMatches: [Int]
		public let pathMatches: [Int]
		let score: Int

		public var project: ProjectInfo { entry.project }
		public var id: String { "\(machine)\n\(entry.project.dir)" }
	}

	/// What a name match is worth over the same match in the path.
	static let nameBonus = 24
	public static let limit = 50

	public static func search<Machine>(_ query: String, in sources: [Source<Machine>]) -> [Result<Machine>] {
		let all = sources.flatMap { source in
			ProjectCatalog.entries(projects: source.projects, sessions: source.sessions).map { (source.machine, $0) }
		}
		let results: [Result<Machine>] = all.compactMap { machine, entry in
			if let name = FuzzyMatch.match(query, in: entry.project.name) {
				return Result(machine: machine, entry: entry, nameMatches: name.positions, pathMatches: [], score: name.score + nameBonus)
			}
			if let path = FuzzyMatch.match(query, in: entry.project.path) {
				return Result(machine: machine, entry: entry, nameMatches: [], pathMatches: path.positions, score: path.score)
			}
			return nil
		}
		return Array(results.sorted(by: ranked).prefix(limit))
	}

	private static func ranked<Machine>(_ a: Result<Machine>, _ b: Result<Machine>) -> Bool {
		if a.score != b.score { return a.score > b.score }
		let (la, lb) = (a.entry.lastActive ?? 0, b.entry.lastActive ?? 0)
		if la != lb { return la > lb }
		return a.project.name.lowercased() < b.project.name.lowercased()
	}
}
