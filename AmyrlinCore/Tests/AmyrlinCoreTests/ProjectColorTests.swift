import Testing
@testable import AmyrlinCore

@Suite struct ProjectColorTests {
	@Test func theSameProjectAlwaysGetsTheSameColour() {
		// Pinned: a change here recolours every project Brad has.
		#expect(ProjectColor.index(for: "aludra") == 6)
		#expect(ProjectColor.index(for: "waygate-cs") == 8)
	}

	@Test func coloursAvoidFailedRedAndWaitingAmber() {
		for hue in ProjectColor.hues {
			#expect(!(10...40).contains(hue), "red is for failures")
			#expect(!(70...95).contains(hue), "amber is for waiting")
		}
	}

	@Test func everyHueStaysInsideSRGB() {
		for hue in ProjectColor.hues {
			let c = ProjectColor.oklchToSRGB(lightness: ProjectColor.lightness, chroma: ProjectColor.chroma, hue: hue)
			for value in [c.red, c.green, c.blue] { #expect(value >= 0 && value <= 1) }
		}
	}

	@Test func theOldBlueAccentConvertsAsBefore() {
		// aludra's accent, oklch(85% 0.105 215), checked against the CSS value used before the redesign.
		let c = ProjectColor.oklchToSRGB(lightness: 0.85, chroma: 0.105, hue: 215)
		#expect(abs(c.red - 0.454) < 0.002 && abs(c.green - 0.876) < 0.002 && abs(c.blue - 0.975) < 0.002)
	}

	@Test func bradsProjectsSpreadAcrossTheHues() {
		let names = ["aludra", "amyrlin", "gaidin", "gray-ajah", "waygate-cs", "loial", "homelab", "pocket-agent", "nurb", "cairhien"]
		let used = Set(names.map(ProjectColor.index(for:)))
		#expect(used.count >= 6, "ten projects should land on at least six of eleven hues, got \(used.count)")
	}
}
