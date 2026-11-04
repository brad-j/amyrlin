import Testing
@testable import AmyrlinCore

struct ResultBlocksTests {
	@Test func finishedBlocksGoAndTheProseStays() {
		let text = """
		```plan
		- [x] Read
		- [ ] Edit
		```

		I added the page.

		```result
		{"summary": "There's a packing page."}
		```
		"""
		#expect(ResultBlocks.hidden(text) == "I added the page.")
	}

	@Test func aBlockStillBeingWrittenIsHiddenFromItsFence() {
		#expect(ResultBlocks.hidden("Done.\n\n```result\n{\"summary\": \"Th") == "Done.")
	}

	@Test func otherFencesStay() {
		let text = "Run this:\n\n```sh\npnpm test\n```"
		#expect(ResultBlocks.hidden(text) == text)
	}

	@Test func aShipLineStaysAboveTheResult() {
		#expect(ResultBlocks.hidden("Rebased.\n\nSHIP-READY\n\n```result\n{}\n```\n") == "Rebased.\n\nSHIP-READY")
	}
}
