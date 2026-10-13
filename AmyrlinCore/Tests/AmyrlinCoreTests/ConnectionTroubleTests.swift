import Foundation
import Testing
@testable import AmyrlinCore

/// What the sidebar says when a machine can't be reached: the likely cause and what to run.
@Suite struct ConnectionTroubleTests {
	@Test func refusedUpgradesNameTheFix() {
		#expect(ConnectionTrouble.explain(UpgradeRefused(status: 403)).contains("api.users"))
		#expect(ConnectionTrouble.explain(UpgradeRefused(status: 502)).contains("aludra service install"))
		#expect(ConnectionTrouble.explain(UpgradeRefused(status: 401)).contains("tailscale serve"))
		#expect(ConnectionTrouble.explain(UpgradeRefused(status: 418)).contains("HTTP 418"))
	}

	@Test func networkErrorsNameTheFix() {
		#expect(ConnectionTrouble.explain(URLError(.cannotFindHost)).contains("doesn't resolve"))
		#expect(ConnectionTrouble.explain(URLError(.timedOut)).contains("tailscale serve --bg 8724"))
		#expect(ConnectionTrouble.explain(NSError(domain: NSURLErrorDomain, code: URLError.Code.secureConnectionFailed.rawValue)).contains("HTTPS"))
	}

	@Test func otherErrorsSayWhatTheyAre() {
		struct Odd: Error {}
		#expect(ConnectionTrouble.explain(Odd()) == "Odd()")
	}
}
