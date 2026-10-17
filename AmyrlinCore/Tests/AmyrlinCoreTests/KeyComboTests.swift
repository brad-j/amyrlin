import Foundation
import Testing
@testable import AmyrlinCore

@Suite struct KeyComboTests {
	@Test func showsModifiersInMenuOrder() {
		#expect(KeyCombo("d", command: true, shift: true).display == "⇧⌘D")
		#expect(KeyCombo("k", command: true, shift: true, option: true, control: true).display == "⌃⌥⇧⌘K")
		#expect(KeyCombo("[", command: true).display == "⌘[")
		#expect(KeyCombo("d", command: true, shift: true).symbols == ["⇧", "⌘", "D"])
		#expect(KeyCombo(" ", control: true).symbols == ["⌃", "Space"])
	}

	@Test func namesKeysThatTypeNothing() {
		#expect(KeyCombo("\u{F702}", option: true).display == "⌥←")
		#expect(KeyCombo("\u{F705}").display == "F2")
		#expect(KeyCombo("\r", command: true).display == "⌘↩")
		#expect(KeyCombo(" ", control: true).display == "⌃Space")
	}

	@Test func normalizesCaseDeleteAndEnter() {
		#expect(KeyCombo("D", command: true) == KeyCombo("d", command: true))
		#expect(KeyCombo("\u{7F}", command: true).key == "\u{08}")
		#expect(KeyCombo("\u{03}", command: true).key == "\r")
	}

	@Test func needsAModifierUnlessAFunctionKey() {
		#expect(!KeyCombo("d").isUsable)
		#expect(!KeyCombo("d", shift: true).isUsable)
		#expect(KeyCombo("d", option: true).isUsable)
		#expect(KeyCombo("\u{F704}").isUsable)
	}

	@Test func roundTripsThroughJSON() throws {
		let combo = KeyCombo("w", command: true, shift: true)
		let data = try JSONEncoder().encode([combo])
		#expect(try JSONDecoder().decode([KeyCombo].self, from: data) == [combo])
	}
}
