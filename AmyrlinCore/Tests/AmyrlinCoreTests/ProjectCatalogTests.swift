import Foundation
import Testing
@testable import AmyrlinCore

@Suite struct ProjectCatalogTests {
	static func project(_ path: String, workspace: String = "egwene") -> ProjectInfo {
		let name = String(path.split(separator: "/").last ?? "")
		return try! JSONDecoder().decode(ProjectInfo.self, from: Data(#"{"workspace":"\#(workspace)","name":"\#(name)","path":"\#(path)","dir":"/w/\#(path)"}"#.utf8))
	}

	static func session(_ id: Int, dir: String, updatedAt: Int64) -> ConversationSummary {
		try! JSONDecoder().decode(ConversationSummary.self, from: Data(#"{"id":\#(id),"title":"t","dir":"/w/\#(dir)","updatedAt":\#(updatedAt)}"#.utf8))
	}

	static let projects = [
		"Software/aludra", "Software/amyrlin", "Software/gaidin", "Software/gray-ajah", "Fabrication/keychain",
		"Fabrication/server-rack", "Electronics/esp32-projects", "Personal/Trips",
	].map { project($0) }

	@Test func recentComesFirstThenFoldersLargestFirst() {
		let sessions = [Self.session(1, dir: "Software/gaidin", updatedAt: 100), Self.session(2, dir: "Fabrication/keychain", updatedAt: 300), Self.session(3, dir: "Software/gaidin", updatedAt: 200)]
		let groups = ProjectCatalog.groups(projects: Self.projects, sessions: sessions)
		#expect(groups.map(\.title) == ["Recent", "Software", "Fabrication", "Electronics", "Personal"])
		#expect(groups[0].entries.map(\.project.name) == ["keychain", "gaidin"])
		#expect(groups[0].entries[1].sessions == 2)
		#expect(groups[0].entries[1].lastActive == 200)
		#expect(groups[1].entries.map(\.project.name) == ["aludra", "amyrlin", "gaidin", "gray-ajah"])
	}

	@Test func noSessionsMeansNoRecentGroup() {
		#expect(ProjectCatalog.groups(projects: Self.projects, sessions: []).first?.title == "Software")
	}

	@Test func searchRanksNamePrefixesFirstAndKeepsFolders() {
		let results = ProjectCatalog.search("a", projects: Self.projects, sessions: [])
		#expect(results.first?.title == "Software")
		#expect(results.first?.entries.prefix(2).map(\.project.name) == ["aludra", "amyrlin"])
		let rack = ProjectCatalog.search("rack", projects: Self.projects, sessions: [])
		#expect(rack.map(\.title) == ["Fabrication"])
		#expect(rack.first?.entries.map(\.project.name) == ["server-rack"])
	}

	@Test func searchWordsCanMatchTheFolder() {
		let results = ProjectCatalog.search("fab key", projects: Self.projects, sessions: [])
		#expect(results.flatMap(\.entries).map(\.project.name) == ["keychain"])
		#expect(ProjectCatalog.search("   ", projects: Self.projects, sessions: []).isEmpty)
		#expect(ProjectCatalog.search("zzz", projects: Self.projects, sessions: []).isEmpty)
	}
}
