import Foundation

/// A session changing state in a way worth telling someone who isn't watching it.
public struct SessionAlert: Sendable, Hashable {
	public enum Kind: Sendable, Hashable {
		/// It's waiting for a tool call to be allowed or denied.
		case needsYou
		/// A run ended and it's idle again.
		case done
		case stuck
		/// A ship landed or stopped (sandbox tasks).
		case shipped(ShipOutcome)
	}

	public let kind: Kind
	public let summary: ConversationSummary
}

/// What changed between two versions of a machine's session list: a session newly needing approval, newly stuck, or
/// going idle after a run (from busy, or from needing approval when the answer ended it). Sessions new to the list say
/// nothing, so the first snapshot is quiet; an archived session only says when it needs you.
public enum SessionAlerts {
	public static func between(_ old: [ConversationID: ConversationSummary], _ new: [ConversationID: ConversationSummary]) -> [SessionAlert] {
		new.values.sorted { $0.id < $1.id }.compactMap { summary in
			// A ship's end, as the summary keeps it, says so in place of the run's end that comes with it.
			if let before = old[summary.id], let ship = summary.sandbox?.lastShip, before.sandbox?.lastShip != ship, !summary.archived {
				return SessionAlert(kind: .shipped(ship), summary: summary)
			}
			guard let before = old[summary.id], before.status != summary.status else { return nil }
			switch (before.status, summary.status) {
			case (_, .needsApproval):
				return SessionAlert(kind: .needsYou, summary: summary)
			case (_, .stuck) where !summary.archived:
				return SessionAlert(kind: .stuck, summary: summary)
			case (.busy, .idle) where !summary.archived, (.needsApproval, .idle) where !summary.archived:
				return SessionAlert(kind: .done, summary: summary)
			default:
				return nil
			}
		}
	}
}
