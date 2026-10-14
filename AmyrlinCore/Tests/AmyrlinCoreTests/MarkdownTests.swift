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

	/// A cut-off answer shows what it will look like, not a flash of raw Markdown.
	@Test func settledTextHoldsBackWhatWouldChangeKind() {
		#expect(Markdown.settled("Some **bold") == "Some **bold**")
		#expect(Markdown.settled("Some **") == "Some ")
		#expect(Markdown.settled("Run `pnpm sy") == "Run `pnpm sy`")
		#expect(Markdown.settled("Run `pnpm` and **this `x**`") == "Run `pnpm` and **this `x**`**", "bold markers in code don't count")
		#expect(Markdown.settled("See [the docs](https://exa") == "See the docs")
		#expect(Markdown.settled("See [the do") == "See the do")
		#expect(Markdown.settled("Pages:\n\n1. One\n2.") == "Pages:\n\n1. One")
		#expect(Markdown.settled("Intro\n\n##") == "Intro\n")
		#expect(Markdown.settled("Intro\n\n| Command | What it does |") == "Intro\n")
		#expect(Markdown.settled("Intro\n\n| Command | What it does |\n") == "Intro\n")
		#expect(Markdown.settled("| Command | What |\n| --- | -") == "| Command | What |\n| --- | -", "a table once its separator starts")
		#expect(Markdown.settled("| A | B |\n| --- | --- |\n| pnpm sy") == "| A | B |\n| --- | --- |", "a row shows once it's whole")
		#expect(Markdown.settled("| A | B |\n| --- | --- |\n| x | y |") == "| A | B |\n| --- | --- |\n| x | y |")
		#expect(Markdown.settled("```ts\nlet a = 1\n``") == "```ts\nlet a = 1", "half a closing fence isn't code")
		#expect(Markdown.settled("```ts\nlet a = `x") == "```ts\nlet a = `x", "nothing is closed inside code")
		#expect(Markdown.settled("Done.") == "Done.")
	}

	/// Revealed a character at a time, an answer only ever grows: no block, item or row shows and then goes away, which
	/// would make the transcript's height bounce as it streams.
	@Test func settledTextOnlyGrowsAsItReveals() {
		let answer = """
			Cairhien is a static bookshelf built from your **Goodreads** feed with [Astro](https://astro.build).

			## How it works

			- `pnpm sync` runs `scripts/sync.ts`. It fetches the feed, **100 books** per page.
			- `pnpm build` builds only from the snapshot.
			  It never contacts Goodreads.

			1. `/` shows what you're reading.
			2. `/read` groups finished books by year.

			```ts
			export async function sync(feed: URL) {
			  await write("data/books.json", books)
			}
			```

			| Command | What it does |
			| --- | --- |
			| `pnpm sync` | Pulls the feed |
			| `pnpm build` | Builds the site |

			> Nothing here talks to Goodreads at build time.

			---

			Done.
			"""
		func shape(_ blocks: [MarkdownBlock]) -> [Int] {
			blocks.map { block in
				switch block {
				case .list(let items): 100 + items.count
				case .table(_, let rows): 200 + rows.count
				case .code(_, let code, _): 300 + code.components(separatedBy: "\n").count
				default: 0
				}
			}
		}
		var previous: [Int] = []
		var previousText = ""
		for end in answer.indices {
			let text = String(answer[..<end])
			let current = shape(Markdown.blocks(Markdown.settled(text)))
			let lost = current.count < previous.count || zip(previous, current).contains { $0 > $1 && $0 / 100 == $1 / 100 }
			#expect(!lost, "\(previous) → \(current) going from \(previousText.suffix(30).debugDescription) to \(text.suffix(30).debugDescription)")
			if lost { break }
			previous = current
			previousText = text
		}
	}
}
