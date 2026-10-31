import AmyrlinCore
import Testing

struct PinOrderTests {
	@Test func newPinsGoToTheTopAndUnpinSaysWhereItWas() {
		var pins = PinOrder()
		pins.pin("a")
		pins.pin("b")
		#expect(pins.keys == ["b", "a"])
		let r1 = pins.unpin("a")
		#expect(r1 == 1)
		let r2 = pins.unpin("a")
		#expect(r2 == nil)
		pins.pin("a", at: 1)
		#expect(pins.keys == ["b", "a"])
	}

	@Test func duplicatesFromStorageAreDropped() {
		#expect(PinOrder(["a", "b", "a"]).keys == ["a", "b"])
	}

	/// One machine's list moves among its own pins, leaving another machine's where they are.
	@Test func movingStepsAmongTheVisiblePins() {
		var pins = PinOrder(["m1/1", "m2/9", "m1/2", "m1/3"])
		let visible = ["m1/1", "m1/2", "m1/3"]
		let r3 = pins.move("m1/3", by: -1, among: visible)
		#expect(r3)
		#expect(pins.keys == ["m1/1", "m2/9", "m1/3", "m1/2"])
		let r4 = pins.move("m1/1", by: -1, among: visible)
		#expect(!r4)
		let r5 = pins.move("m1/1", by: 1, among: ["m1/1", "m1/3", "m1/2"])
		#expect(r5)
		#expect(pins.keys == ["m2/9", "m1/3", "m1/1", "m1/2"])
		let r6 = pins.move("m1/1", by: 1, among: ["m1/3", "m1/1", "m1/2"])
		#expect(r6)
		#expect(pins.keys == ["m2/9", "m1/3", "m1/2", "m1/1"])
		let r7 = pins.move("m1/1", by: 1, among: ["m1/3", "m1/2", "m1/1"])
		#expect(!r7)
	}

	@Test func aDropLandsBeforeItsTargetOrAfterTheLast() {
		var pins = PinOrder(["a", "b", "c"])
		let r8 = pins.place("c", before: "a", among: pins.keys)
		#expect(r8)
		#expect(pins.keys == ["c", "a", "b"])
		let r9 = pins.place("c", before: nil, among: ["c", "a", "b"])
		#expect(r9)
		#expect(pins.keys == ["a", "b", "c"])
		let r10 = pins.place("b", before: "c", among: pins.keys)
		#expect(!r10, "already there")
		let r11 = pins.place("x", before: "a", among: pins.keys)
		#expect(!r11, "not pinned")
	}

	@Test func pruneDropsWhatsGone() {
		var pins = PinOrder(["m1/1", "m2/1"])
		pins.prune { $0.hasPrefix("m1/") }
		#expect(pins.keys == ["m1/1"])
	}
}
