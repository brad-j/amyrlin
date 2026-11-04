import Foundation
import Testing
@testable import AmyrlinCore

/// Sandbox tasks (protocol section 10 item 19), decoded from the shapes egwene's aludra sends.
struct SandboxDecodingTests {
	private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
		try JSONDecoder().decode(T.self, from: Data(json.utf8))
	}

	@Test func hostInfoCarriesSandboxDefaultsAndCheckouts() throws {
		let info = try decode(Commands.HostInfo.Result.self, """
		{"host":{"hostId":"h","name":"egwene"},"models":[],"tools":[],
		 "sandboxes":{"shipTo":"main","afterRun":"fetch","approvals":"off"},
		 "projects":[
		  {"workspace":"w","name":"bdaytrip","path":"Software/bdaytrip","dir":"/w/bdaytrip","checkout":{"branch":"main","dirty":2,"ahead":0,"behind":1,"upstream":"origin/main","sandboxes":true}},
		  {"workspace":"w","name":"keychain","path":"Prints/keychain","dir":"/w/keychain","checkout":{"dirty":0,"ahead":0,"behind":0,"sandboxes":{"reason":"it isn't in git"}}},
		  {"workspace":"w","name":"old","path":"old","dir":"/w/old"}
		 ]}
		""")
		#expect(info.sandboxes?.shipTo == .main)
		#expect(info.sandboxes?.approvals == .off)
		let projects = try #require(info.projects)
		#expect(projects[0].checkout == Checkout(branch: "main", dirty: 2, ahead: 0, behind: 1, upstream: "origin/main"))
		#expect(projects[0].checkout?.takesSandboxes == true)
		#expect(projects[1].checkout?.sandboxRefusal == "it isn't in git")
		#expect(projects[2].checkout == nil)
	}

	@Test func aHostWithoutASandboxHostHasNoDefaults() throws {
		let info = try decode(Commands.HostInfo.Result.self, #"{"host":{"hostId":"h","name":"mac"},"models":[],"tools":[]}"#)
		#expect(info.sandboxes == nil)
	}

	@Test func summariesCarryTheSandboxSourceAndLine() throws {
		let summary = try decode(ConversationSummary.self, """
		{"id":33196,"title":"Add test line to README","status":"idle","createdAt":1,"updatedAt":2,"project":"bdaytrip",
		 "dir":"/home/user/work/bdaytrip","source":"/home/brad/westwood/Projects/Software/bdaytrip",
		 "line":"Ready to push. · checks pass",
		 "sandbox":{"number":1,"branch":"sandbox/1","state":"preparing","step":"cloning","approvals":"off","base":"2834a4b"}}
		""")
		let sandbox = try #require(summary.sandbox)
		#expect(sandbox.number == 1)
		#expect(sandbox.branch == "sandbox/1")
		#expect(sandbox.state == .preparing)
		#expect(sandbox.step == "cloning")
		#expect(sandbox.base == "2834a4b")
		#expect(summary.source == "/home/brad/westwood/Projects/Software/bdaytrip")
		#expect(summary.line == "Ready to push. · checks pass")
	}

	@Test func aFailedSandboxIsStuckWithItsDetail() throws {
		let summary = try decode(ConversationSummary.self, """
		{"id":1,"status":"stuck","stuck":{"reason":"sandbox_failed","detail":"clone failed"},
		 "sandbox":{"number":4,"state":"failed","reason":"git clone exited 128"}}
		""")
		#expect(summary.status == .stuck)
		#expect(summary.stuck?.reason == "sandbox_failed")
		#expect(summary.stuck?.detail == "clone failed")
		#expect(summary.sandbox?.state == .failed)
		#expect(summary.sandbox?.branch == "sandbox/4")
		#expect(summary.sandbox?.reason == "git clone exited 128")
	}

	@Test func aHeldSubmitHasNoIDYet() throws {
		let held = try decode(Commands.Submit.Result.self, #"{"submission":{"requestId":"r1","type":"input","status":"queued"}}"#)
		#expect(held.submission.id == nil)
		#expect(held.submission.requestId == "r1")
		#expect(held.duplicate == false)
		let placed = try decode(Commands.Submit.Result.self, #"{"submission":{"id":8,"status":"placed","entryId":7},"duplicate":false}"#)
		#expect(placed.submission.id == 8)
	}

	@Test func aResultDecodesWholeAndWhileRunning() throws {
		let done = try decode(Commands.GetTaskResult.Result.self, """
		{"result":{"at":10,"summary":"There's a packing page.","changes":["New Packing link"],
		 "headsUp":[{"kind":"dependency","text":"Added date-fns"}],
		 "checks":[{"name":"pnpm check && pnpm build","ok":true},{"name":"types","ok":false,"detail":"TS2322"}],
		 "shots":[{"id":"s1","label":"/","side":"before","path":"/"},{"id":"s2","label":"/","side":"after","path":"/"}],
		 "code":{"commits":1,"files":4,"add":98,"del":4},
		 "question":{"text":"Move them to gear?","options":["Move","Read both"]}}}
		""").result
		let result = try #require(done)
		#expect(!result.isRunning)
		#expect(result.checks.map(\.ok) == [true, false])
		#expect(result.shots.map(\.side) == [.before, .after])
		#expect(result.code == TaskResult.Code(commits: 1, files: 4, add: 98, del: 4))
		#expect(result.question?.options == ["Move", "Read both"])
		#expect(result.plan == nil)

		let running = try #require(try decode(Commands.GetTaskResult.Result.self, #"{"result":{"at":11,"plan":[{"text":"Read","done":true},{"text":"Edit","done":false}]}}"#).result)
		#expect(running.isRunning)
		#expect(running.plan?.map(\.done) == [true, false])
		#expect(try decode(Commands.GetTaskResult.Result.self, #"{"result":null}"#).result == nil)
	}

	@Test func shipEventsDecodeBothWays() throws {
		let shipped = try decode(HostEvent.self, #"{"type":"sandbox.shipped","conversationId":3,"shipped":true,"to":"branch","pushed":"origin/sandbox-4-ab12cd3","head":"ab12cd3","commits":2,"pr":"https://github.com/x/y/pull/9"}"#)
		#expect(shipped == .shipped(ShipEvent(conversationId: 3, outcome: .shipped(to: .branch, pushed: "origin/sandbox-4-ab12cd3", head: "ab12cd3", commits: 2, pr: "https://github.com/x/y/pull/9"))))
		let stopped = try decode(HostEvent.self, #"{"type":"sandbox.shipped","conversationId":3,"shipped":false,"kind":"upstream_moved","reason":"rejected"}"#)
		#expect(stopped == .shipped(ShipEvent(conversationId: 3, outcome: .stopped(kind: .upstreamMoved, reason: "rejected"))))
	}

	@Test func hostStateKeepsProjectsAndShips() throws {
		var state = HostState()
		state.apply(try decode(HostEvent.self, #"{"type":"host.snapshot","host":{"hostId":"h","name":"egwene"},"spend":{},"conversations":[]}"#))
		state.apply(try decode(HostEvent.self, #"{"type":"host.projects","projects":[{"workspace":"w","name":"lan","path":"lan","dir":"/w/lan","checkout":{"branch":"main","dirty":0,"ahead":0,"behind":0,"sandboxes":true}}]}"#))
		#expect(state.projects?.first?.checkout?.branch == "main")
		state.apply(try decode(HostEvent.self, #"{"type":"sandbox.shipped","conversationId":5,"shipped":false,"kind":"check_failed","reason":"nothing to ship"}"#))
		#expect(state.ships[5] == .stopped(kind: .checkFailed, reason: "nothing to ship"))
	}

	@Test func syncSaysWhetherItMerged() throws {
		let plain = try decode(SyncResult.self, #"{"branch":"sandbox/1","head":"abc","commits":1,"uncommitted":0}"#)
		#expect(!plain.merged && plain.mergeRefusal == nil)
		let refused = try decode(SyncResult.self, #"{"branch":"sandbox/1","commits":0,"uncommitted":2,"merged":{"reason":"the checkout isn't on main"}}"#)
		#expect(refused.mergeRefusal == "the checkout isn't on main")
		#expect(try decode(SyncResult.self, #"{"branch":"sandbox/1","commits":0,"uncommitted":0,"merged":true}"#).merged)
	}

	@Test func createSendsSandboxFieldsOnlyWithASandbox() throws {
		let encoder = JSONEncoder()
		encoder.outputFormatting = .sortedKeys
		let local = String(decoding: try encoder.encode(Commands.CreateConversation(requestId: "r", project: "/w/lan", text: "hi", approvals: .ask).params), as: UTF8.self)
		#expect(!local.contains("sandbox") && !local.contains("approvals"))
		let boxed = String(decoding: try encoder.encode(Commands.CreateConversation(requestId: "r", project: "/w/lan", text: "hi", sandbox: true, approvals: .ask).params), as: UTF8.self)
		#expect(boxed.contains(#""sandbox":true"#) && boxed.contains(#""approvals":"ask""#))
	}
}
