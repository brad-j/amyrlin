import Foundation

/// Sessions waiting on Brad: one asking to allow a tool call, one stuck, or one that finished a run he hasn't looked at
/// since (`unread`, kept by the client). An archived session only counts while it asks, as with alerts.
public enum WaitingOnYou {
	public enum Reason: Int, Sendable, Hashable, Comparable {
		case approval, stuck, reply

		public static func < (a: Reason, b: Reason) -> Bool { a.rawValue < b.rawValue }
	}

	public static func reason(_ summary: ConversationSummary, unread: Bool) -> Reason? {
		switch summary.status {
		case .needsApproval: .approval
		case .stuck where !summary.archived: .stuck
		case .idle where !summary.archived && unread: .reply
		default: nil
		}
	}

	/// The waiting sessions among `sessions`, approvals first, then stuck, then replies, newest first within each.
	public static func among(_ sessions: some Sequence<ConversationSummary>, unread: (ConversationID) -> Bool) -> [(summary: ConversationSummary, reason: Reason)] {
		sessions
			.compactMap { summary in reason(summary, unread: unread(summary.id)).map { (summary: summary, reason: $0) } }
			.sorted { a, b in
				if a.reason != b.reason { return a.reason < b.reason }
				return a.summary.updatedAt != b.summary.updatedAt ? a.summary.updatedAt > b.summary.updatedAt : a.summary.id > b.summary.id
			}
	}
}
