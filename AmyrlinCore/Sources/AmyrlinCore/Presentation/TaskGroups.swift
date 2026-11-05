import Foundation

/// The task list's groups: what each session needs from you (protocol section 10 item 19).
///
/// - needs you: asking to allow a call, asking a question, stuck (a failed sandbox too), a stopped ship, or a sandbox
///   task's failing checks. A local session's checks are only the commands its turn happened to run, so they don't
///   make it need you.
/// - running: a run going on, or a sandbox being made.
/// - ready: sandbox work that came back and hasn't shipped.
/// - done: everything else that isn't archived: finished local sessions, shipped work and removed sandboxes.
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

	public static func group(_ summary: ConversationSummary, ship: ShipOutcome? = nil) -> Group {
		if need(summary, ship: ship) != nil { return .needsYou }
		if summary.status == .busy || summary.sandbox?.state == .preparing { return .running }
		if let sandbox = summary.sandbox, sandbox.state != .removed, summary.hasMessages {
			if case .shipped = ship { return .done }
			return .ready
		}
		return .done
	}

	/// `sessions` by group, in the groups' order and leaving out empty ones. Running sessions keep the order they
	/// started in, so a row doesn't jump as it works; the others are newest first.
	public static func grouped<Item>(
		_ items: [Item],
		summary: (Item) -> ConversationSummary,
		ship: (Item) -> ShipOutcome? = { _ in nil }
	) -> [(group: Group, items: [Item])] {
		let byGroup = Dictionary(grouping: items) { group(summary($0), ship: ship($0)) }
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
