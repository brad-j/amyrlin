import Foundation
import Testing
@testable import AmyrlinCore

@Suite struct SessionSearchTests {
	static func session(_ title: String, project: String? = nil, dir: String? = nil) -> ConversationSummary {
		var json = #"{"id":1,"title":"\#(title)""#
		if let project { json += #","project":"\#(project)""# }
		if let dir { json += #","dir":"\#(dir)""# }
		return try! JSONDecoder().decode(ConversationSummary.self, from: Data((json + "}").utf8))
	}

	@Test func everyWordMustMatchSomewhere() {
		let session = Self.session("Fix the reconnect loop", project: "amyrlin", dir: "/home/brad/Software/amyrlin")
		#expect(SessionSearch.matches(session, words: SessionSearch.words("RECONNECT")))
		#expect(SessionSearch.matches(session, words: SessionSearch.words("amyr loop")))
		#expect(SessionSearch.matches(session, words: SessionSearch.words("software")))
		#expect(!SessionSearch.matches(session, words: SessionSearch.words("amyrlin aludra")))
	}

	@Test func aSessionInNoProjectIsScratch() {
		#expect(SessionSearch.matches(Self.session("notes"), words: ["scratch"]))
		#expect(!SessionSearch.matches(Self.session("notes", project: "aludra"), words: ["scratch"]))
	}

	@Test func noWordsMatchesEverything() {
		#expect(SessionSearch.words("   ").isEmpty)
		#expect(SessionSearch.matches(Self.session("anything"), words: []))
	}
}
