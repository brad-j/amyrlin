import Foundation
import Testing
@testable import AmyrlinCore

@Suite struct FuzzyMatchTests {
	@Test func findsCharactersInOrderIgnoringCaseAndSpaces() {
		#expect(FuzzyMatch.match("amrln", in: "amyrlin")?.positions == [0, 1, 3, 4, 6])
		#expect(FuzzyMatch.match("AMY", in: "amyrlin")?.positions == [0, 1, 2])
		#expect(FuzzyMatch.match("soft amy", in: "Software/amyrlin") != nil)
		#expect(FuzzyMatch.match("nilrma", in: "amyrlin") == nil)
		#expect(FuzzyMatch.match("amyrlins", in: "amyrlin") == nil)
	}

	@Test func emptyQueryMatchesEverything() {
		#expect(FuzzyMatch.match("  ", in: "aludra") == FuzzyMatch.Match(score: 0, positions: []))
	}

	@Test func prefersWordStartsAndRuns() {
		// "sr" takes server-rack's two word starts over the s and r of "server".
		#expect(FuzzyMatch.match("sr", in: "server-rack")?.positions == [0, 7])
		let prefix = FuzzyMatch.match("ray", in: "gray-ajah")!
		let run = FuzzyMatch.match("ray", in: "ray-tracer")!
		#expect(run.score > prefix.score)
		let tight = FuzzyMatch.match("amy", in: "amyrlin")!
		let spread = FuzzyMatch.match("amy", in: "a-mighty-yak")!
		#expect(tight.score > spread.score)
	}

	@Test func camelCaseHumpsCountAsWordStarts() {
		#expect(FuzzyMatch.match("pc", in: "ProjectCatalog")?.positions == [0, 7])
	}
}

@Suite struct ProjectSpotlightTests {
	static let projects = ProjectCatalogTests.projects
	static let egwene = ProjectSpotlight.Source(machine: "egwene", projects: projects, sessions: [])

	@Test func noQueryListsRecentFirstThenByName() {
		let sessions = [ProjectCatalogTests.session(1, dir: "Personal/Trips", updatedAt: 100), ProjectCatalogTests.session(2, dir: "Software/gaidin", updatedAt: 300)]
		let results = ProjectSpotlight.search("", in: [.init(machine: "egwene", projects: Self.projects, sessions: sessions)])
		#expect(results.prefix(4).map(\.project.name) == ["gaidin", "Trips", "aludra", "amyrlin"])
	}

	@Test func nameMatchesBeatPathMatches() {
		let results = ProjectSpotlight.search("fab", in: [Self.egwene])
		#expect(results.map(\.project.name) == ["keychain", "server-rack"])
		#expect(results[0].pathMatches == [0, 1, 2])
		#expect(results[0].nameMatches.isEmpty)
		let aludra = ProjectSpotlight.search("ald", in: [Self.egwene])
		#expect(aludra.first?.project.name == "aludra")
		#expect(aludra.first?.nameMatches == [0, 1, 3])
	}

	@Test func searchesEveryMachineAndRecentWinsTies() {
		let tower = ProjectSpotlight.Source(
			machine: "tower",
			projects: [ProjectCatalogTests.project("Software/amyrlin", workspace: "tower")],
			sessions: [ProjectCatalogTests.session(1, dir: "Software/amyrlin", updatedAt: 500)]
		)
		let results = ProjectSpotlight.search("amyrlin", in: [Self.egwene, tower])
		#expect(results.map(\.machine) == ["tower", "egwene"])
		#expect(Set(results.map(\.id)).count == 2)
	}
}
