import Foundation
import Testing
@testable import AmyrlinCore

struct WorkTimelineTests {
	private func call(_ id: String, _ name: String, _ args: [String: JSONValue], _ status: ToolCallRow.Status = .done, output: String = "") -> ToolCallRow {
		ToolCallRow(callId: id, name: name, args: .object(args), status: status, output: output, result: nil)
	}

	@Test func runsOfOneKindMergeAndChecksSayHowTheyWent() {
		let steps = WorkTimeline.steps([
			call("1", "read", ["path": "src/a.ts"]),
			call("2", "read", ["path": "src/b.ts"]),
			call("3", "read", ["path": "src/a.ts"]),
			call("4", "edit", ["path": "src/a.ts"]),
			call("5", "write", ["path": "src/c.ts"]),
			call("6", "bash", ["command": "cd /w && pnpm test"], output: "[ELIFECYCLE] Test failed"),
			call("7", "edit", ["path": "src/a.ts"]),
			call("8", "bash", ["command": "pnpm test"], output: "15 passed"),
			call("9", "bash", ["command": "ls -la"]),
			call("10", "edit", ["path": "src/routes/packing.tsx"], .running),
		])
		#expect(steps.map(\.text) == ["read 2 files", "edited 2 files", "ran the tests: failed", "edited 1 file", "ran the tests: passed", "ran a command", "editing routes/packing.tsx"])
		#expect(steps[2].failed)
		#expect(steps.last?.running == true)
	}

	@Test func checksAreNamed() {
		#expect(WorkTimeline.checkName("pnpm exec tsc --noEmit") == "the type check")
		#expect(WorkTimeline.checkName("pnpm build") == "the build")
		#expect(WorkTimeline.checkName("pnpm lint") == "lint")
		#expect(WorkTimeline.checkName("node --no-warnings --test test/*.test.ts") == "the tests")
		#expect(WorkTimeline.checkName("git status") == nil)
	}
}
