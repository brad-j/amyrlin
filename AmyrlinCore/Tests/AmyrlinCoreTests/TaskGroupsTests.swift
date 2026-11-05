import Foundation
import Testing
@testable import AmyrlinCore

struct TaskGroupsTests {
	private func summary(_ id: Int, status: String = "idle", line: String? = nil, sandbox: String? = nil, created: Int = 100, updated: Int = 200) throws -> ConversationSummary {
		var json = #"{"id":\#(id),"status":"\#(status)","createdAt":\#(created),"updatedAt":\#(updated)"#
		if let line { json += #","line":"\#(line)""# }
		if let sandbox { json += #","sandbox":{"number":\#(id),"state":"\#(sandbox)"}"# }
		return try JSONDecoder().decode(ConversationSummary.self, from: Data((json + "}").utf8))
	}

	@Test func needsYouCoversAsksStuckQuestionsAndFailingChecks() throws {
		#expect(TaskGroups.need(try summary(1, status: "needsApproval")) == .approval)
		#expect(TaskGroups.need(try summary(1, status: "stuck")) == .stuck)
		#expect(TaskGroups.need(try summary(1, sandbox: "failed")) == .stuck)
		#expect(TaskGroups.need(try summary(1, line: "Asks: drop the image plugin?")) == .question)
		#expect(TaskGroups.need(try summary(1, line: "Added the page. · 2 checks fail", sandbox: "ready")) == .checksFail)
		#expect(TaskGroups.need(try summary(1, line: "Added the page. · 1 check fails", sandbox: "ready")) == .checksFail)
		// A local session's checks are what its turn ran; failing ones don't make it need you.
		#expect(TaskGroups.need(try summary(1, line: "Added the page. · 1 check fails")) == nil)
		#expect(TaskGroups.need(try summary(1, line: "Added the page. · checks pass")) == nil)
		#expect(TaskGroups.need(try summary(1, sandbox: "ready"), ship: .stopped(kind: .blocked, reason: "asks")) == .shipStopped)
		// A run going on needs nothing yet, whatever its last line said.
		#expect(TaskGroups.need(try summary(1, status: "busy", line: "Asks: which?")) == nil)
	}

	@Test func sandboxWorkIsReadyUntilItShips() throws {
		let ready = try summary(1, line: "Done · checks pass", sandbox: "ready")
		#expect(TaskGroups.group(ready) == .ready)
		#expect(TaskGroups.group(try summary(1, sandbox: "paused")) == .ready)
		#expect(TaskGroups.group(ready, ship: .shipped(to: .main, pushed: "origin/main", head: "a", commits: 1, pr: nil)) == .done)
		#expect(TaskGroups.group(ready, ship: .shipped(to: .main, pushed: "origin/main", head: "a", commits: 0, pr: nil)) == .done, "nothing to push is done")
		#expect(TaskGroups.group(try summary(1, sandbox: "removed")) == .done)
		#expect(TaskGroups.group(ready, empty: true) == .done)
		// Nothing said yet: a sandbox made and waiting for its first message isn't ready work.
		#expect(TaskGroups.group(try summary(1, sandbox: "ready", updated: 100)) == .done)
	}

	@Test func shippingRunsEvenWhileIdle() throws {
		#expect(TaskGroups.group(try summary(1, line: "Shipping", sandbox: "ready")) == .running)
		#expect(TaskGroups.group(try summary(1, status: "busy", line: "Shipping · getting it ready", sandbox: "ready")) == .running)
		#expect(TaskGroups.isShipping(try summary(1, line: "Shipping")) == false)
	}

	@Test func preparingAndBusyRun() throws {
		#expect(TaskGroups.group(try summary(1, sandbox: "preparing")) == .running)
		#expect(TaskGroups.group(try summary(1, status: "busy")) == .running)
		#expect(TaskGroups.group(try summary(1, line: "I fixed the comment.")) == .done)
	}

	@Test func groupsKeepRunningInStartOrderAndTheRestNewestFirst() throws {
		let items = [
			try summary(1, status: "busy", created: 10, updated: 900),
			try summary(2, status: "busy", created: 20, updated: 100),
			try summary(3, updated: 300),
			try summary(4, updated: 400),
			try summary(5, status: "needsApproval"),
		]
		let groups = TaskGroups.grouped(items, summary: { $0 })
		#expect(groups.map(\.group) == [.needsYou, .running, .done])
		#expect(groups[1].items.map(\.id) == [2, 1])
		#expect(groups[2].items.map(\.id) == [4, 3])
	}
}

struct ProjectTableTests {
	private func project(_ name: String) throws -> ProjectInfo {
		try JSONDecoder().decode(ProjectInfo.self, from: Data(#"{"workspace":"w","name":"\#(name)","path":"Software/\#(name)","dir":"/w/\#(name)"}"#.utf8))
	}

	private func session(_ id: Int, _ json: String) throws -> ConversationSummary {
		try JSONDecoder().decode(ConversationSummary.self, from: Data(("{\"id\":\(id),\"createdAt\":1," + json + "}").utf8))
	}

	@Test func recentProjectsFirstAndSandboxSessionsCountByTheirSource() throws {
		let now = Date(timeIntervalSince1970: 100 * 86_400)
		let day = Int64(86_400_000)
		let sessions = [
			try session(1, #""updatedAt":\#(99 * day),"status":"needsApproval","project":"lan","dir":"/w/lan","title":"Quiet hours""#),
			try session(2, #""updatedAt":\#(98 * day),"status":"idle","project":"bday","dir":"/home/user/work/bday","source":"/w/bday","line":"Done","sandbox":{"number":2,"state":"ready"},"title":"Packing""#),
			try session(3, #""updatedAt":\#(10 * day),"status":"idle","project":"old","dir":"/w/old","archived":true,"title":"Ancient""#),
		]
		let source = ProjectSpotlight.Source(machine: 0, projects: [try project("old"), try project("bday"), try project("lan"), try project("zed")], sessions: sessions)
		let recent = ProjectTable.rows([source], all: false, now: now)
		#expect(recent.rows.map(\.project.name) == ["lan", "bday"])
		#expect(recent.hidden == 2)
		#expect(recent.rows[0].counts == [.needsYou: 1])
		#expect(recent.rows[1].counts == [.ready: 1])
		let all = ProjectTable.rows([source], all: true, now: now)
		#expect(all.rows.map(\.project.name) == ["lan", "bday", "old", "zed"])
		#expect(all.rows[2].lastTitle == "Ancient")
		#expect(all.rows[2].counts.isEmpty)
	}
}

struct TaskListTests {
	private func summary(_ id: Int, status: String = "idle", updated: Int64, sandbox: Bool = false) throws -> ConversationSummary {
		let box = sandbox ? #","sandbox":{"number":1,"state":"ready"}"# : ""
		return try JSONDecoder().decode(ConversationSummary.self, from: Data(#"{"id":\#(id),"status":"\#(status)","createdAt":1,"updatedAt":\#(updated)\#(box)}"#.utf8))
	}

	@Test func chatsPutNeedsYouFirstAndFoldTheQuiet() throws {
		let now = Date(timeIntervalSince1970: 10 * 86_400)
		let day: Int64 = 86_400_000
		let items = [
			try summary(1, updated: 9 * day + 5),
			try summary(2, status: "needsApproval", updated: 2 * day),
			try summary(3, updated: 9 * day + 9),
			try summary(4, updated: 3 * day),
			try summary(5, status: "busy", updated: 1 * day),
		]
		let chats = TaskList.chats(items, summary: { $0 }, now: now)
		#expect(chats.recent.map(\.id) == [2, 3, 1, 5])
		#expect(chats.older.map(\.id) == [4])
		#expect(TaskList.isTask(try summary(6, updated: 1, sandbox: true)))
		#expect(!TaskList.isTask(items[0]))
	}
}
