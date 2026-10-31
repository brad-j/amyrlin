import Foundation
import Testing
@testable import AmyrlinCore

/// Checkpoints (aludra's own, protocol section 10 item 15): decoding the host's answers, finding a message's
/// checkpoint, the restore note in a user message, and reading the list as turns start and end.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct CheckpointTests {
	let transport = FakeTransport()
	let host: HostStore

	init() {
		var policy = ReconnectPolicy()
		policy.keepalive = nil
		let connection = HostConnection(
			url: URL(string: "wss://egwene.example.ts.net/amyrlin")!,
			transport: transport,
			client: ClientInfo(name: "amyrlin-tests", version: "0"),
			policy: policy,
			sleep: { _ in await Task.yield() },
			random: { 0.5 }
		)
		host = HostStore(connection: connection)
	}

	/// As egwene's aludra answered checkpoints.list, plus a restore.
	static let list = #"""
	{"checkpoints":[
	{"at":1793406637695,"tree":"fc47359c","kind":"turn","message":1793406637657,"id":1},
	{"at":1793407810727,"tree":"8fbb7d69","kind":"turn","message":1793407810706,"id":2},
	{"at":1793407900000,"tree":"2e03e915","kind":"restore","restored":1,"id":3},
	{"at":1793407919719,"tree":"8fbb7d69","kind":"turn","message":1793407919661,"id":4},
	{"at":1793407919800,"tree":"8fbb7d69","kind":"snapshot","id":5}
	]}
	"""#

	@Test func checkpointsDecodeWithTheirKind() throws {
		let checkpoints = try JSONDecoder().decode(Commands.ListCheckpoints.Result.self, from: Data(Self.list.utf8)).checkpoints
		#expect(checkpoints.map(\.id) == [1, 2, 3, 4, 5])
		#expect(checkpoints[0].kind == .turn && checkpoints[0].message == 1793406637657)
		#expect(checkpoints[2].kind == .restore && checkpoints[2].restored == 1 && checkpoints[2].message == nil)
		#expect(checkpoints[4].kind == .unknown("snapshot"), "a kind this app doesn't know still decodes")
	}

	@Test func changesDecodeAvailableOrNot() throws {
		let json = #"{"changes":{"available":true,"since":1793406637695,"add":405,"del":6,"files":[{"path":"src/search.ts","add":153,"del":0,"binary":false,"status":"added"},{"path":"docs/new.md","old":"docs/old.md","add":1,"del":1,"binary":false,"status":"renamed"},{"path":"logo.png","add":0,"del":0,"binary":true,"status":"modified"}]}}"#
		let changes = try JSONDecoder().decode(Commands.CheckpointChanges.Result.self, from: Data(json.utf8)).changes
		guard case .available(let since, let add, let del, let files) = changes else {
			Issue.record("expected changes")
			return
		}
		#expect(since == 1793406637695 && add == 405 && del == 6)
		#expect(files.map(\.status) == [.added, .renamed, .modified])
		#expect(files[1].old == "docs/old.md")
		#expect(files[2].binary)
		let none = try JSONDecoder().decode(Changes.self, from: Data(#"{"available":false,"reason":"the project isn't in git"}"#.utf8))
		#expect(none == .unavailable(reason: "the project isn't in git"))
	}

	@Test func restoreAndDiffDecode() throws {
		let restored = try JSONDecoder().decode(RestoreResult.self, from: Data(#"{"written":3,"deleted":1,"files":["a.ts","b.ts","c.ts","d.ts"],"undo":6}"#.utf8))
		#expect(restored == RestoreResult(written: 3, deleted: 1, files: ["a.ts", "b.ts", "c.ts", "d.ts"], undo: 6))
		let diff = try JSONDecoder().decode(Commands.CheckpointDiff.Result.self, from: Data(#"{"path":"a.ts","patch":"@@ -1 +1 @@\n-a\n+b\n"}"#.utf8))
		#expect(diff.patch.hasPrefix("@@"))
	}

	@Test func theRestoreNoteIsALineNotText() {
		let note = #"<restored checkpoint="2">The user put the project's files back to how they were before an earlier turn (3 written, 1 deleted): a.ts, b.ts, c.ts. Read a file again before relying on what you saw of it.</restored>"#
		let message = UserMessage.parse([.text(note), .text("Now try it the other way.")], entryId: 9)
		#expect(message.restore == TranscriptRestore(checkpoint: 2))
		#expect(message.text == "Now try it the other way.")

		// In one block with the words after it, as a string message would be.
		let joined = UserMessage.parse([.text(note + "\n\nNow try it the other way.")], entryId: 9)
		#expect(joined.restore?.checkpoint == 2)
		#expect(joined.text == "Now try it the other way.")

		// Only the first text block carries it; quoted later, it's the user's own words.
		let quoted = UserMessage.parse([.text("Why did you write"), .text(note)], entryId: 9)
		#expect(quoted.restore == nil)
		#expect(UserMessage.parse([.text("plain")], entryId: 9) == UserMessage(text: "plain"))
		#expect(UserMessage.withoutNotes(note + "Next") == "Next")
	}

	/// The checkpoints are read with the snapshot and again as a run ends, and a message finds its turn's checkpoint by
	/// its `at`; a restore checkpoint is never a message's.
	@Test func checkpointsFollowTurnsAndMatchMessages() async throws {
		let store = host.conversation(1)
		await host.connection.start()
		store.start()
		let server = try await transport.nextConnection()
		try await server.acceptHello()
		server.respond(try await server.nextRequest("conversation.watch"), result: .object(["subscription": "s1"]))
		server.event("s1", seq: 0, [.object(["type": "snapshot", "conversation": .object(["id": .number(1)])])])
		let first = try await server.nextRequest("checkpoints.list")
		#expect(first.params == .object(["conversationId": .number(1)]))
		server.respond(first, result: try JSONDecoder().decode(JSONValue.self, from: Data(Self.list.utf8)))
		#expect(await eventually { store.checkpoints?.count == 5 })
		#expect(store.checkpoint(forMessageAt: 1793407810706)?.id == 2)
		#expect(store.checkpoint(forMessageAt: 1793407900000) == nil, "a restore checkpoint isn't a message's")
		#expect(store.checkpoint(forMessageAt: nil) == nil)

		server.event("s1", seq: 1, [.object(["type": "run.started", "inputs": .array([])])])
		server.respond(try await server.nextRequest("checkpoints.list"), result: .object(["checkpoints": .array([])]))
		server.event("s1", seq: 2, [.object(["type": "run.ended", "outcome": "completed"])])
		server.respond(try await server.nextRequest("checkpoints.list"), result: .object(["checkpoints": .array([])]))
		#expect(await eventually { store.checkpoints == [] })
		await host.stop()
	}

	@Test func aHostWithoutCheckpointsIsAskedOnce() async throws {
		let store = host.conversation(1)
		await host.connection.start()
		store.start()
		let server = try await transport.nextConnection()
		try await server.acceptHello()
		server.respond(try await server.nextRequest("conversation.watch"), result: .object(["subscription": "s1"]))
		server.event("s1", seq: 0, [.object(["type": "snapshot", "conversation": .object(["id": .number(1)])])])
		server.respond(try await server.nextRequest("checkpoints.list"), error: "unknown_method", message: "Unknown method checkpoints.list")
		#expect(await eventually { store.checkpoints == nil })
		await store.refreshCheckpoints()
		#expect(store.checkpoint(forMessageAt: 1) == nil)
		await host.stop()
	}

	@Test func restoreSendsTheCheckpointAndReadsTheListAgain() async throws {
		let store = host.conversation(1)
		await host.connection.start()
		let server = try await transport.nextConnection()
		try await server.acceptHello()
		let restoring = Task { try await store.restore(2) }
		let request = try await server.nextRequest("checkpoints.restore")
		#expect(request.params == .object(["conversationId": .number(1), "checkpoint": .number(2)]))
		server.respond(request, result: .object(["written": .number(1), "deleted": .number(0), "files": .array(["a.ts"]), "undo": .number(6)]))
		server.respond(try await server.nextRequest("checkpoints.list"), result: .object(["checkpoints": .array([])]))
		#expect(try await restoring.value.undo == 6)

		let refused = Task { try await store.restore(2) }
		server.respond(try await server.nextRequest("checkpoints.restore"), error: "busy", message: "the session is running; stop it or wait before restoring")
		await #expect(throws: ProtocolError.self) { try await refused.value }
		await host.stop()
	}

	private func eventually(_ condition: () -> Bool) async -> Bool {
		for _ in 0..<2_000 {
			if condition() { return true }
			try? await Task.sleep(for: .milliseconds(1))
		}
		return condition()
	}
}
