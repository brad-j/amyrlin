import Foundation

/// Sessions quiet long enough to archive on their own: idle, not archived, nothing waiting on an answer, and last active
/// `age` or more before `now`. Sessions in `kept` stay, such as ones brought back from the archive by hand.
public enum StaleSessions {
	public static let age: TimeInterval = 3 * 24 * 60 * 60

	public static func among(_ sessions: some Sequence<ConversationSummary>, now: Date, kept: Set<ConversationID> = []) -> [ConversationID] {
		let cutoff = Int64((now.timeIntervalSince1970 - age) * 1000)
		return sessions
			.filter { !$0.archived && $0.status == .idle && $0.pendingApprovals == 0 && $0.updatedAt <= cutoff && !kept.contains($0.id) }
			.map(\.id)
			.sorted()
	}
}
