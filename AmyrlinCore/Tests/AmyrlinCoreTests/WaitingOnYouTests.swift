import Foundation
import Testing
@testable import AmyrlinCore

@Suite struct WaitingOnYouTests {
	static func summary(_ id: ConversationID, _ status: String, archived: Bool = false, at: Int64 = 0) -> ConversationSummary {
		try! JSONDecoder().decode(ConversationSummary.self, from: Data(#"{"id":\#(id),"title":"t\#(id)","status":"\#(status)","archived":\#(archived),"createdAt":\#(at),"updatedAt":\#(at)}"#.utf8))
	}

	@Test func approvalsStuckAndUnreadRunsWait() {
		#expect(WaitingOnYou.reason(Self.summary(1, "needsApproval"), unread: false) == .approval)
		#expect(WaitingOnYou.reason(Self.summary(1, "stuck"), unread: false) == .stuck)
		#expect(WaitingOnYou.reason(Self.summary(1, "idle"), unread: true) == .reply)
		#expect(WaitingOnYou.reason(Self.summary(1, "idle"), unread: false) == nil)
		// A session running again isn't waiting, read or not.
		#expect(WaitingOnYou.reason(Self.summary(1, "busy"), unread: true) == nil)
	}

	@Test func archivedSessionsOnlyWaitWhenTheyAsk() {
		#expect(WaitingOnYou.reason(Self.summary(1, "needsApproval", archived: true), unread: false) == .approval)
		#expect(WaitingOnYou.reason(Self.summary(1, "stuck", archived: true), unread: false) == nil)
		#expect(WaitingOnYou.reason(Self.summary(1, "idle", archived: true), unread: true) == nil)
	}

	@Test func approvalsFirstThenStuckThenRepliesNewestFirst() {
		let sessions = [
			Self.summary(1, "idle", at: 5),
			Self.summary(2, "idle", at: 9),
			Self.summary(3, "stuck", at: 1),
			Self.summary(4, "needsApproval", at: 2),
			Self.summary(5, "busy", at: 10),
			Self.summary(6, "idle", at: 10),
		]
		let waiting = WaitingOnYou.among(sessions) { [1, 2, 5].contains($0) }
		#expect(waiting.map(\.summary.id) == [4, 3, 2, 1])
	}
}
