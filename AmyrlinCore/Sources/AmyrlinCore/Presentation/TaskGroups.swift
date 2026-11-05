import Foundation

/// The task list's groups: what each session needs from you (protocol section 10 item 19).
///
/// - needs you: asking to allow a call, asking a question, stuck (a failed sandbox too), a stopped ship, or a sandbox
///   task's failing checks. A local session's checks are only the commands its turn happened to run, so they don't
///   make it need you.
/// - running: a run going on, a sandbox being made, or a ship under way.
/// - ready: sandbox work that came back and hasn't shipped.
/// - done: everything else that isn't archived: finished local sessions, shipped work, removed sandboxes, and sandbox
///   work that changed nothing (`empty`, from TaskStore.nothingToShip).
///
/// A question and failing checks are read from the summary's `line`, which the host words for exactly this ("Asks: …",
/// "· 2 checks fail"); the host doesn't send them apart.
public enum TaskGroups {
	public enum Group: Int, CaseIterable, Sendable, Hashable, Comparable {
		case needsYou, running, ready, done

		public var title: String {
			switch self {
			case .needsYou: "needs you"
			case .running: "running"
			case .ready: "ready"
			case .done: "done"
			}
		}

		public static func < (a: Group, b: Group) -> Bool { a.rawValue < b.rawValue }
	}

	/// Why a session needs you, for its mark and its help.
	public enum Need: Sendable, Hashable {
		case approval, question, stuck, shipStopped, checksFail
	}

	public static func need(_ summary: ConversationSummary, ship: ShipOutcome? = nil) -> Need? {
		switch summary.status {
		case .needsApproval: return .approval
		case .stuck: return .stuck
		case .busy: return nil
		default: break
		}
		if summary.sandbox?.state == .failed { return .stuck }
		if case .stopped = ship { return .shipStopped }
		guard let line = summary.line else { return nil }
		if line.hasPrefix("Asks:") { return .question }
		if summary.sandbox != nil, line.range(of: #"· \d+ checks? fails?$"#, options: .regularExpression) != nil { return .checksFail }
		return nil
	}

	/// A ship is under way: the host words the line "Shipping" from the ship's request until it lands or stops, idle
	/// in the moment before its run starts too.
	public static func isShipping(_ summary: ConversationSummary) -> Bool {
		summary.sandbox != nil && summary.line?.hasPrefix("Shipping") == true
	}

	public static func group(_ summary: ConversationSummary, ship: ShipOutcome? = nil, empty: Bool = false) -> Group {
		if need(summary, ship: ship) != nil { return .needsYou }
		if summary.status == .busy || summary.sandbox?.state == .preparing || isShipping(summary) { return .running }
		if let sandbox = summary.sandbox, sandbox.state != .removed, summary.hasMessages {
			if case .shipped = ship { return .done }
			return empty ? .done : .ready
		}
		return .done
	}

	/// `sessions` by group, in the groups' order and leaving out empty ones. Running sessions keep the order they
	/// started in, so a row doesn't jump as it works; the others are newest first.
	public static func grouped<Item>(
		_ items: [Item],
		summary: (Item) -> ConversationSummary,
		ship: (Item) -> ShipOutcome? = { _ in nil },
		empty: (Item) -> Bool = { _ in false }
	) -> [(group: Group, items: [Item])] {
		let byGroup = Dictionary(grouping: items) { group(summary($0), ship: ship($0), empty: empty($0)) }
		return Group.allCases.compactMap { group in
			guard let members = byGroup[group], !members.isEmpty else { return nil }
			let sorted = members.sorted { x, y in
				let (a, b) = (summary(x), summary(y))
				if group == .running { return a.createdAt != b.createdAt ? a.createdAt > b.createdAt : a.id > b.id }
				return a.updatedAt != b.updatedAt ? a.updatedAt > b.updatedAt : a.id > b.id
			}
			return (group, sorted)
		}
	}
}

/// The list's two kinds (Brad's option B, 2026-11-04). Sandbox work is a task: it has states and ends in Ship, so it
/// keeps TaskGroups' groups. A session that runs on its machine is a chat: a conversation you come back to, never
/// "done", listed newest first in one line each; one that needs you comes first, and those quiet for a day fold away.
public enum TaskList {
	/// Chats quiet longer than this fold into "older".
	public static let recentWindow: TimeInterval = 86_400

	public static func isTask(_ summary: ConversationSummary) -> Bool {
		summary.sandbox != nil
	}

	/// Chats in the list's order, and how many of them are older than the window: needing you first (newest first),
	/// then running and the rest, newest first, so a chat never jumps because it started running.
	public static func chats<Item>(
		_ items: [Item],
		summary: (Item) -> ConversationSummary,
		now: Date = .now
	) -> (recent: [Item], older: [Item]) {
		let cutoff = Int64((now.timeIntervalSince1970 - recentWindow) * 1000)
		let needing = items.filter { TaskGroups.need(summary($0)) != nil }.sorted { summary($0).updatedAt > summary($1).updatedAt }
		let rest = items.filter { TaskGroups.need(summary($0)) == nil }.sorted { summary($0).updatedAt > summary($1).updatedAt }
		// A running chat and one needing you are never folded, however long they've gone.
		let recent = needing + rest.filter { summary($0).updatedAt >= cutoff || summary($0).status == .busy }
		let older = rest.filter { summary($0).updatedAt < cutoff && summary($0).status != .busy }
		return (recent, older)
	}
}
