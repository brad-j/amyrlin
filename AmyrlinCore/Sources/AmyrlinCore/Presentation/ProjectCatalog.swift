import Foundation

/// The projects a new session can start in, grouped for the picker: "Recent" (projects with sessions, newest first),
/// then each folder ("Software", "Fabrication", ...), largest first. A search ranks name prefixes over other name
/// matches over path matches, keeping folder groups. aludra's web picker follows the same rules
/// (aludra/app/lib/projects.ts).
public enum ProjectCatalog {
	public struct Entry: Sendable, Hashable, Identifiable {
		public let project: ProjectInfo
		public let sessions: Int
		/// Milliseconds since 1970, of the project's most recently active session.
		public let lastActive: Int64?

		public var id: String { project.dir }
	}

	public struct Group: Sendable, Hashable, Identifiable {
		public let id: String
		public let title: String
		public let entries: [Entry]
	}

	public static let recentID = "recent"
	public static let recentLimit = 8

	/// The folder a project sits in: the first part of its path, or its workspace when the path has one part.
	public static func folder(of project: ProjectInfo) -> String {
		let parts = project.path.split(separator: "/")
		return parts.count > 1 ? String(parts[0]) : project.workspace
	}

	public static func groups(projects: [ProjectInfo], sessions: [ConversationSummary]) -> [Group] {
		let entries = entries(projects: projects, sessions: sessions)
		let recent = entries.filter { $0.lastActive != nil }
			.sorted { ($0.lastActive ?? 0) > ($1.lastActive ?? 0) }
			.prefix(recentLimit)
		var out: [Group] = []
		if !recent.isEmpty { out.append(Group(id: recentID, title: "Recent", entries: Array(recent))) }
		return out + folderGroups(entries)
	}

	/// Projects matching every word of `query`, grouped by folder, best matches first in each group and groups ordered
	/// by their best match. An empty query gives no groups.
	public static func search(_ query: String, projects: [ProjectInfo], sessions: [ConversationSummary]) -> [Group] {
		let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
		guard !words.isEmpty else { return [] }
		var scored: [(entry: Entry, score: Int)] = []
		for entry in entries(projects: projects, sessions: sessions) {
			if let score = score(entry.project, words: words) { scored.append((entry, score)) }
		}
		let byFolder = Dictionary(grouping: scored) { folder(of: $0.entry.project) }
		return byFolder
			.map { folder, matches -> (Group, Int) in
				let sorted = matches.sorted { $0.score != $1.score ? $0.score > $1.score : $0.entry.project.name.lowercased() < $1.entry.project.name.lowercased() }
				return (Group(id: folder, title: folder, entries: sorted.map(\.entry)), sorted.first?.score ?? 0)
			}
			.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.title < $1.0.title }
			.map(\.0)
	}

	/// 3 when the name starts with the first word, 2 when the name holds every word, 1 when the path or workspace does;
	/// nil when some word is missing. Recently used projects win ties.
	static func score(_ project: ProjectInfo, words: [String]) -> Int? {
		let name = project.name.lowercased()
		let haystack = "\(project.path) \(project.workspace)".lowercased()
		guard words.allSatisfy({ name.contains($0) || haystack.contains($0) }) else { return nil }
		if name.hasPrefix(words[0]) { return 3 }
		if words.allSatisfy(name.contains) { return 2 }
		return 1
	}

	private static func entries(projects: [ProjectInfo], sessions: [ConversationSummary]) -> [Entry] {
		let byDir = Dictionary(grouping: sessions.filter { !$0.archived }) { $0.dir ?? "" }
		return projects.map { project in
			let mine = byDir[project.dir] ?? []
			return Entry(project: project, sessions: mine.count, lastActive: mine.map(\.updatedAt).max())
		}
	}

	private static func folderGroups(_ entries: [Entry]) -> [Group] {
		Dictionary(grouping: entries) { folder(of: $0.project) }
			.map { folder, entries in
				Group(id: folder, title: folder, entries: entries.sorted { $0.project.name.lowercased() < $1.project.name.lowercased() })
			}
			.sorted { $0.entries.count != $1.entries.count ? $0.entries.count > $1.entries.count : $0.title < $1.title }
	}
}
