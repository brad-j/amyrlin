import Testing
@testable import AmyrlinCore

@Suite struct MarkdownTests {
	@Test func paragraphsHeadingsAndRules() {
		let blocks = Markdown.blocks("# Title\n\nFirst line\nsecond line\n\n---\n\n## Next")
		#expect(blocks == [.heading(level: 1, text: "Title"), .paragraph("First line\nsecond line"), .rule, .heading(level: 2, text: "Next")])
	}

	@Test func listsKeepDepthNumbersAndTasks() {
		let blocks = Markdown.blocks("- one\n  - nested\n- two\n  continued\n\n1. first\n2) second\n- [x] done\n- [ ] todo")
		#expect(blocks == [
			.list(items: [
				.init(depth: 0, number: nil, checked: nil, text: "one"),
				.init(depth: 1, number: nil, checked: nil, text: "nested"),
				.init(depth: 0, number: nil, checked: nil, text: "two\ncontinued"),
				.init(depth: 0, number: 1, checked: nil, text: "first"),
				.init(depth: 0, number: 2, checked: nil, text: "second"),
				.init(depth: 0, number: nil, checked: true, text: "done"),
				.init(depth: 0, number: nil, checked: false, text: "todo"),
			]),
		])
	}

	@Test func codeFencesKeepTheirTextAndAnUnclosedOneRunsToTheEnd() {
		#expect(Markdown.blocks("```swift\nlet a = 1\n\n# not a heading\n```\nafter") == [
			.code(language: "swift", code: "let a = 1\n\n# not a heading", closed: true), .paragraph("after"),
		])
		#expect(Markdown.blocks("text\n```\nstill streaming") == [.paragraph("text"), .code(language: nil, code: "still streaming", closed: false)])
	}

	@Test func tablesNeedTheirSeparatorLine() {
		#expect(Markdown.blocks("| Check | Result |\n| --- | :-: |\n| tsc | passed |\n| tests |") == [
			.table(header: ["Check", "Result"], rows: [["tsc", "passed"], ["tests", ""]]),
		])
		#expect(Markdown.blocks("| half a table") == [.paragraph("| half a table")])
	}

	@Test func quotes() {
		#expect(Markdown.blocks("> Nothing is pushed yet.\n> Really.") == [.quote("Nothing is pushed yet.\nReally.")])
	}

	@Test func theFauxMarkdownAnswerFromAludra() {
		let source = """
		Here's what changed, in **three** parts:

		1. `src/api.ts` serves the app and its API.
		2. The socket sends each session's transcript as it grows.

		```ts
		const server = createApi(host, { user });
		```

		| Check | Result |
		| --- | --- |
		| tsc | passed |

		> Nothing is pushed yet.
		"""
		let kinds = Markdown.blocks(source).map { block -> String in
			switch block {
			case .paragraph: "p"
			case .heading: "h"
			case .list: "list"
			case .code: "code"
			case .quote: "quote"
			case .table: "table"
			case .rule: "rule"
			}
		}
		#expect(kinds == ["p", "list", "code", "table", "quote"])
	}
}
