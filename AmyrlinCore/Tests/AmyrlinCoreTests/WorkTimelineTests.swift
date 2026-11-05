import Foundation
import Testing
@testable import AmyrlinCore

struct WorkTimelineTests {
	private func call(_ id: String, _ name: String, _ args: [String: JSONValue], _ status: ToolCallRow.Status = .done, output: String = "") -> ToolCallRow {
		ToolCallRow(callId: id, name: name, args: .object(args), status: status, output: output, result: nil)
	}

	@Test func shellWritesCommitsAndChecksAreLandmarks() {
		// The calls from Brad's real task 35617, shortened.
		let steps = WorkTimeline.steps([
			call("1", "bash", ["command": "cd /w && ls -la && git log --oneline | head && cat hello.sh"]),
			call("2", "bash", ["command": #"cd /w && printf '#!/bin/sh\necho bye\n' > goodbye.sh && chmod +x goodbye.sh && git add goodbye.sh && git commit -qm "Add goodbye.sh""#]),
			call("3", "write", ["path": "/w/test.sh"]),
			call("4", "bash", ["command": #"cd /w && chmod +x test.sh && ./test.sh; echo "test.sh exit $?" && git commit -qm "Add test.sh""#], output: "ok hello.sh\nok goodbye.sh\ntest.sh exit 0"),
			call("5", "edit", ["path": "/w/hello.sh"], .running),
		], dir: "/w")
		#expect(steps.map(\.text) == [
			"ran a command",
			"wrote goodbye.sh",
			"committed: Add goodbye.sh",
			"wrote test.sh",
			"ran test.sh: passed",
			"committed: Add test.sh",
			"editing hello.sh",
		])
		#expect(steps.last?.running == true)
	}

	@Test func failingChecksAndQuietRunsMerge() {
		let steps = WorkTimeline.steps([
			call("1", "read", ["path": "src/a.ts"]),
			call("2", "read", ["path": "src/b.ts"]),
			call("3", "bash", ["command": "pnpm test"], output: "[ELIFECYCLE] Test failed"),
			call("4", "bash", ["command": "pnpm exec tsc --noEmit"], output: ""),
		])
		#expect(steps.map(\.text) == ["read 2 files", "ran the tests: failed", "ran the type check: passed"])
		#expect(steps[1].failed)
	}

	@Test func aPlanStepItsCommitCoversFolds() {
		let steps = WorkTimeline.steps(
			[ToolCallRow(callId: "1", name: "bash", args: .object(["command": #"git commit -m "Add goodbye.sh that prints bye and the date""#]), status: .done, output: "", result: nil)],
			plans: [(at: 300, done: ["Add goodbye.sh that prints \"bye\" and the date"])],
			times: ["1": 200]
		)
		#expect(steps.map(\.text) == ["committed: Add goodbye.sh that prints bye and the date"])
		#expect(steps.first?.kind == .stepDone)
	}

	@Test func planStepsShowWhenTheyreDone() throws {
		let items = try JSONDecoder().decode([Item].self, from: Data(#"""
		[{"id":1,"type":"user","at":100,"content":[{"type":"text","text":"go"}]},
		 {"id":2,"type":"assistant","at":200,"stopReason":"toolUse","content":[{"type":"text","text":"```plan\n- [ ] Add goodbye\n- [ ] Add test\n```"}]},
		 {"id":3,"type":"assistant","at":300,"stopReason":"toolUse","content":[{"type":"text","text":"```plan\n- [x] Add goodbye\n- [ ] Add test\n```"}]},
		 {"id":4,"type":"assistant","at":400,"stopReason":"stop","content":[{"type":"text","text":"Done.\n```plan\n- [x] Add goodbye\n- [x] Add test\n```"}]}]
		"""#.utf8))
		let plans = WorkTimeline.plans(items)
		#expect(plans.map(\.done) == [[], ["Add goodbye"], ["Add goodbye", "Add test"]])
		let steps = WorkTimeline.steps([], plans: plans)
		#expect(steps.map(\.text) == ["Add goodbye", "Add test"])
		#expect(steps.allSatisfy { $0.kind == .stepDone })
	}

	@Test func shellWritesAreRead() {
		#expect(WorkTimeline.writtenFiles(#"printf 'x' > a.sh && echo y >> logs/b.txt"#) == ["a.sh", "logs/b.txt"])
		#expect(WorkTimeline.writtenFiles("cat <<'EOF' > src/c.ts") == ["src/c.ts"])
		#expect(WorkTimeline.writtenFiles("sed -i 's/a/b/' src/d.ts") == ["src/d.ts"])
		#expect(WorkTimeline.writtenFiles("echo hi | tee out.txt") == ["out.txt"])
		#expect(WorkTimeline.writtenFiles("ls 2>/dev/null; cmd > /dev/null 2>&1") == [])
		#expect(WorkTimeline.writtenFiles("git status") == [])
	}

	@Test func commitsAndChecksAreNamed() {
		#expect(WorkTimeline.commitMessage(#"git add . && git commit -m "Fix the date""#) == "Fix the date")
		#expect(WorkTimeline.commitMessage("git commit -qam 'Tidy'") == "Tidy")
		#expect(WorkTimeline.commitMessage("git status") == nil)
		#expect(WorkTimeline.checkName("pnpm exec tsc --noEmit") == "the type check")
		#expect(WorkTimeline.checkName("pnpm build") == "the build")
		#expect(WorkTimeline.checkName("pnpm lint") == "lint")
		#expect(WorkTimeline.checkName("node --no-warnings --test test/*.test.ts") == "the tests")
		#expect(WorkTimeline.checkName("cd /w && ./test.sh") == "test.sh")
		#expect(WorkTimeline.checkName("git status") == nil)
	}
}
