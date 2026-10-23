import Foundation
import Testing
@testable import AmyrlinCore

@Suite struct StaleSessionsTests {
	static let now = Date(timeIntervalSince1970: 1_800_000_000)

	static func summary(_ id: ConversationID, daysAgo: Double, status: String = "idle", archived: Bool = false, pending: Int = 0) -> ConversationSummary {
		let at = Int64((now.timeIntervalSince1970 - daysAgo * 24 * 60 * 60) * 1000)
		return try! JSONDecoder().decode(ConversationSummary.self, from: Data(#"{"id":\#(id),"title":"t\#(id)","status":"\#(status)","archived":\#(archived),"createdAt":\#(at),"updatedAt":\#(at),"pendingApprovals":\#(pending)}"#.utf8))
	}

	@Test func idleSessionsThreeDaysQuietGo() {
		let sessions = [Self.summary(1, daysAgo: 0.7), Self.summary(2, daysAgo: 2.9), Self.summary(3, daysAgo: 3), Self.summary(4, daysAgo: 7)]
		#expect(StaleSessions.among(sessions, now: Self.now) == [3, 4])
	}

	@Test func workingArchivedAndKeptSessionsStay() {
		let sessions = [
			Self.summary(1, daysAgo: 5, status: "busy"),
			Self.summary(2, daysAgo: 5, status: "needsApproval", pending: 1),
			Self.summary(3, daysAgo: 5, status: "stuck"),
			Self.summary(4, daysAgo: 5, archived: true),
			Self.summary(5, daysAgo: 5),
			Self.summary(6, daysAgo: 5),
		]
		#expect(StaleSessions.among(sessions, now: Self.now, kept: [5]) == [6])
	}
}
