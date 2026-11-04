import Foundation
import Testing
@testable import AmyrlinCore

@Suite struct SessionAlertsTests {
	static func summary(_ id: ConversationID, _ status: String, archived: Bool = false) -> ConversationSummary {
		try! JSONDecoder().decode(ConversationSummary.self, from: Data(#"{"id":\#(id),"title":"t\#(id)","status":"\#(status)","archived":\#(archived)}"#.utf8))
	}

	static func list(_ summaries: ConversationSummary...) -> [ConversationID: ConversationSummary] {
		Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0) })
	}

	static func kinds(_ old: [ConversationID: ConversationSummary], _ new: [ConversationID: ConversationSummary]) -> [SessionAlert.Kind] {
		SessionAlerts.between(old, new).map(\.kind)
	}

	@Test func runsThatAskFinishOrStickSaySo() {
		#expect(Self.kinds(Self.list(Self.summary(1, "busy")), Self.list(Self.summary(1, "needsApproval"))) == [.needsYou])
		#expect(Self.kinds(Self.list(Self.summary(1, "busy")), Self.list(Self.summary(1, "idle"))) == [.done])
		#expect(Self.kinds(Self.list(Self.summary(1, "needsApproval")), Self.list(Self.summary(1, "idle"))) == [.done])
		#expect(Self.kinds(Self.list(Self.summary(1, "busy")), Self.list(Self.summary(1, "stuck"))) == [.stuck])
	}

	@Test func quietOtherwise() {
		// Starting a run, an approval answered, no change, and a session new to the list.
		#expect(Self.kinds(Self.list(Self.summary(1, "idle")), Self.list(Self.summary(1, "busy"))).isEmpty)
		#expect(Self.kinds(Self.list(Self.summary(1, "needsApproval")), Self.list(Self.summary(1, "busy"))).isEmpty)
		#expect(Self.kinds(Self.list(Self.summary(1, "idle")), Self.list(Self.summary(1, "idle"))).isEmpty)
		#expect(Self.kinds([:], Self.list(Self.summary(1, "needsApproval"), Self.summary(2, "stuck"))).isEmpty)
	}

	@Test func archivedSessionsOnlySayWhenTheyNeedYou() {
		#expect(Self.kinds(Self.list(Self.summary(1, "busy", archived: true)), Self.list(Self.summary(1, "idle", archived: true))).isEmpty)
		#expect(Self.kinds(Self.list(Self.summary(1, "busy", archived: true)), Self.list(Self.summary(1, "needsApproval", archived: true))) == [.needsYou])
	}

	@Test func severalAtOnceInIDOrder() {
		let alerts = SessionAlerts.between(
			Self.list(Self.summary(2, "busy"), Self.summary(1, "busy")),
			Self.list(Self.summary(2, "idle"), Self.summary(1, "needsApproval"))
		)
		#expect(alerts.map(\.summary.id) == [1, 2])
		#expect(alerts.map(\.kind) == [.needsYou, .done])
	}
}

struct ShipAlertTests {
	private func summary(_ json: String) throws -> ConversationSummary {
		try JSONDecoder().decode(ConversationSummary.self, from: Data(json.utf8))
	}

	@Test func aShipKeptOnTheSummarySaysSoInPlaceOfDone() throws {
		let before = try summary(#"{"id":3,"status":"busy","sandbox":{"number":3}}"#)
		let after = try summary(#"{"id":3,"status":"idle","sandbox":{"number":3,"shipped":{"at":1,"to":"main","pushed":"origin/main","head":"a","commits":1}}}"#)
		let alerts = SessionAlerts.between([3: before], [3: after])
		#expect(alerts.map(\.kind) == [.shipped(.shipped(to: .main, pushed: "origin/main", head: "a", commits: 1, pr: nil))])
	}
}
