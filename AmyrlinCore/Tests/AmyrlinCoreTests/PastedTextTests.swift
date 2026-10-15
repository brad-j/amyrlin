import Foundation
import Testing
@testable import AmyrlinCore

/// Long pastes stand in the composer as markers and go out whole.
@Suite struct PastedTextTests {
	private static func lines(_ n: Int) -> String {
		(1...n).map { "line \($0)" }.joined(separator: "\n")
	}

	@Test func onlyLongTextIsHeld() {
		#expect(!PastedText.isLong(Self.lines(10)))
		#expect(PastedText.isLong(Self.lines(11)))
		#expect(!PastedText.isLong(String(repeating: "x", count: 1000)))
		#expect(PastedText.isLong(String(repeating: "x", count: 1001)))
		#expect(PastedText.isLong(Array(repeating: "a", count: 11).joined(separator: "\r\n")))
	}

	@Test func markersCountLinesOrCharacters() {
		let pasted = PastedText()
		#expect(pasted.hold(Self.lines(42)) == "[paste #1 +42 lines]")
		#expect(pasted.hold(String(repeating: "x", count: 1234)) == "[paste #2 1234 chars]")
	}

	@Test func sendingPutsTheTextBack() {
		let pasted = PastedText()
		let log = Self.lines(20)
		let trace = Self.lines(30)
		let first = pasted.hold(log)
		let second = pasted.hold(trace)
		#expect(pasted.expand("why does \(first) fail?\n\(second)") == "why does \(log) fail?\n\(trace)")
		#expect(pasted.expand("typed [paste #9 +3 lines] by hand") == "typed [paste #9 +3 lines] by hand")
	}

	@Test func pastedMarkersAreNotExpandedAgain() {
		let pasted = PastedText()
		let first = pasted.hold(Self.lines(12))
		let second = pasted.hold(Self.lines(11) + "\n" + first)
		#expect(pasted.expand(second) == Self.lines(11) + "\n" + first)
	}

	@Test func backspaceFindsTheMarkerBeforeTheCursor() {
		let pasted = PastedText()
		let marker = pasted.hold(Self.lines(12))
		let text = "see → \(marker) ok" as NSString
		let range = text.range(of: marker)
		#expect(pasted.marker(endingAt: range.upperBound, in: text as String) == range)
		#expect(pasted.marker(endingAt: range.upperBound - 1, in: text as String) == nil)
		#expect(pasted.marker(endingAt: text.length, in: text as String) == nil)
		#expect(pasted.marker(endingAt: 25, in: "[paste #7 +3 lines]") == nil)
	}

	@Test func clearingStartsOver() {
		let pasted = PastedText()
		let marker = pasted.hold(Self.lines(12))
		pasted.clear()
		#expect(pasted.expand(marker) == marker)
		#expect(pasted.hold(Self.lines(12)) == "[paste #1 +12 lines]")
	}
}
