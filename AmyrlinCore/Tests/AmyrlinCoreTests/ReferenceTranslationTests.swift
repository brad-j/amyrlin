import Foundation
import Testing
@testable import AmyrlinCore

/// `server/src/translate.mjs` is the server's translation. Its output for every fixture, written to `fixtures/wire-v1/`
/// by `pnpm run export-wire` in `server/`, must equal the Swift test mapper's output frame by frame.
@Suite struct ReferenceTranslationTests {
	static let wireDirectory = Fixtures.directory.deletingLastPathComponent().appending(path: "wire-v1")

	@Test(arguments: Fixtures.names)
	func javaScriptTranslationMatchesTheSwiftMapper(_ name: String) throws {
		let text = try String(contentsOf: Self.wireDirectory.appending(path: "\(name).jsonl"), encoding: .utf8)
		let javaScript = try text.split(separator: "\n").map { line -> JSONValue in
			try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
		}
		let swift = try Fixtures.wireFrameJSON(name).map(JSONValue.array)
		#expect(javaScript.count == swift.count, "\(name): \(javaScript.count) frames from JS, \(swift.count) from Swift")
		for (index, (js, sw)) in zip(javaScript, swift).enumerated() where js != sw {
			Issue.record("\(name) frame \(index) differs\n  js:    \(js.jsonText)\n  swift: \(sw.jsonText)")
			return
		}
	}
}
