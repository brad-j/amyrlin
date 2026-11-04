import Foundation

/// The home's project table: one row per project on a machine, with what the task list doesn't show, its checkout, and
/// a count of its tasks by group. Recent projects (a task active in the last `recentDays`) come first, most recently
/// active first; with `all`, the rest follow by name.
public enum ProjectTable {
	public static let recentDays = 30

	public struct Row<Machine: Hashable & Sendable>: Sendable, Identifiable {
		public let machine: Machine
		public let project: ProjectInfo
		/// Unarchived tasks by group, for the "1 needs you · 2 ready" cell.
		public let counts: [TaskGroups.Group: Int]
		/// The newest task's activity, of any task, archived ones too.
		public let lastActive: Int64?
		/// The title of the newest task, archived ones too.
		public let lastTitle: String?

		public var id: String { "\(machine)\n\(project.dir)" }
	}

	public static func rows<Machine>(
		_ sources: [ProjectSpotlight.Source<Machine>],
		ships: (Machine, ConversationID) -> ShipOutcome? = { _, _ in nil },
		all: Bool,
		now: Date = .now
	) -> (rows: [Row<Machine>], hidden: Int) {
		let cutoff = Int64((now.timeIntervalSince1970 - Double(recentDays) * 86_400) * 1000)
		var rows: [Row<Machine>] = []
		for source in sources {
			let byProject = Dictionary(grouping: source.sessions) { $0.source ?? $0.dir ?? "" }
			let byName = Dictionary(grouping: source.sessions.filter { $0.source == nil }) { $0.project ?? "" }
			for project in source.projects {
				// A sandbox session's `dir` is in the sandbox; its `source` is the project's directory here.
				let sessions = Set((byProject[project.dir] ?? []) + (byName[project.name] ?? []).filter { $0.dir?.hasPrefix(project.dir) ?? false })
				let newest = sessions.max { $0.updatedAt < $1.updatedAt }
				var counts: [TaskGroups.Group: Int] = [:]
				for session in sessions where !session.archived {
					counts[TaskGroups.group(session, ship: ships(source.machine, session.id)), default: 0] += 1
				}
				rows.append(Row(machine: source.machine, project: project, counts: counts, lastActive: newest?.updatedAt, lastTitle: newest?.title))
			}
		}
		let recent = rows.filter { ($0.lastActive ?? 0) >= cutoff }
			.sorted { ($0.lastActive ?? 0) > ($1.lastActive ?? 0) }
		guard all else { return (recent, rows.count - recent.count) }
		let rest = rows.filter { ($0.lastActive ?? 0) < cutoff }
			.sorted { $0.project.name.lowercased() < $1.project.name.lowercased() }
		return (recent + rest, 0)
	}
}
