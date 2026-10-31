import Foundation
import Testing
@testable import AmyrlinCore

/// Message search (aludra's own, protocol section 10 item 16): decoding results, the snippet's marked words, merging
/// machines, finding a result's row, and a host without it.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MessageSearchTests {
	/// As egwene's aludra answered messages.search, with an archived result added.
	static let answer = #"""
	{"results":[
	{"session":27624,"entry":27928,"index":0,"item":"e27928:0","from":"agent","at":1793406002727,"snippet":"API routes: `GET /api/sessions/:id/«checkpoints»`, `GET .../«checkpoints»/:n/changes` (with…","title":"Compare t3code to Aludra ideas","project":"aludra","workspace":"egwene"},
	{"session":12,"entry":40,"index":1,"item":"e40:1","from":"user","at":1793400000000,"snippet":"«restore» it","title":"Old","project":"gaidin","workspace":"egwene","archived":true}
	]}
	"""#

	@Test func resultsDecode() throws {
		let results = try JSONDecoder().decode(Commands.SearchMessages.Result.self, from: Data(Self.answer.utf8)).results
		#expect(results.map(\.session) == [27624, 12])
		#expect(results[0].entry == 27928 && results[0].from == .agent && !results[0].archived)
		#expect(results[1].from == .user && results[1].archived && results[1].index == 1)
	}

	@Test func paramsLeaveOutWhatIsntGiven() throws {
		let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(Commands.SearchMessages(query: "checkpoint restore", limit: 30).params))
		#expect(json == .object(["query": "checkpoint restore", "limit": .number(30)]))
	}

	@Test func snippetsDropTheMarkersAndKeepWhatMatched() {
		#expect(SearchSnippet.runs("let «lighthouse» beams «reach» far") == [
			.init("let ", matched: false), .init("lighthouse", matched: true), .init(" beams ", matched: false),
			.init("reach", matched: true), .init(" far", matched: false),
		])
		#expect(SearchSnippet.runs("«all»") == [.init("all", matched: true)])
		#expect(SearchSnippet.runs("unclosed «tail") == [.init("unclosed ", matched: false), .init("tail", matched: true)])
		#expect(SearchSnippet.runs("a stray » stays") == [.init("a stray » stays", matched: false)])
	}

	@Test func machinesTakeTurns() throws {
		let results = try JSONDecoder().decode(Commands.SearchMessages.Result.self, from: Data(Self.answer.utf8)).results
		let merged = SearchMerge.interleave([("egwene", results), ("rand", [results[1]]), ("mat", [])])
		#expect(merged.map(\.machine) == ["egwene", "rand", "egwene"])
		#expect(merged.map(\.result.entry) == [27928, 40, 40])
	}

	/// A result names an entry; its row is the user message's, or an answer's first row, which may be a later block when
	/// the first is empty thinking, or the round a call sits in.
	@Test func aResultFindsItsRow() throws {
		var state = ConversationState()
		let frames = [
			#"[{"type":"snapshot","conversation":{"id":1},"items":[{"id":5,"at":1,"type":"user","content":[{"type":"text","text":"Look at it"}]},{"id":6,"at":2,"type":"assistant","content":[{"type":"thinking","text":""},{"type":"text","text":"On archiving: here's how"}],"stopReason":"stop"},{"id":7,"at":3,"type":"user","content":[{"type":"text","text":"Next"}]},{"id":8,"at":4,"type":"assistant","content":[{"type":"toolCall","id":"c1","name":"read","args":{}}],"stopReason":"toolUse"},{"id":9,"at":5,"type":"toolResult","callId":"c1","toolName":"read","content":[],"isError":false,"diagnostics":[]},{"id":10,"at":6,"type":"assistant","content":[{"type":"toolCall","id":"c2","name":"read","args":{}}],"stopReason":"toolUse"},{"id":11,"at":7,"type":"toolResult","callId":"c2","toolName":"read","content":[],"isError":false,"diagnostics":[]},{"id":12,"at":8,"type":"assistant","content":[{"type":"text","text":"Done"}],"stopReason":"stop"}]}]"#,
		]
		for frame in frames { state.apply(try JSONDecoder().decode([ConversationEvent].self, from: Data(frame.utf8))) }
		let rows = TranscriptLayout.rows(state: state)
		#expect(TranscriptLayout.rowID(for: 5, in: rows, state: state) == "item-5")
		#expect(TranscriptLayout.rowID(for: 6, in: rows, state: state) == "after-5-1", "past the empty thinking")
		#expect(TranscriptLayout.rowID(for: 8, in: rows, state: state) == "round-call-c1", "a call in a folded round")
		#expect(TranscriptLayout.rowID(for: 9, in: rows, state: state) == "round-call-c1", "an item without a row finds the next one")
		#expect(TranscriptLayout.rowID(for: 12, in: rows, state: state) == "after-11-0")
		#expect(TranscriptLayout.rowID(for: 99, in: rows, state: state) == nil)
	}

	@Test func anOlderHostIsntAskedAgain() async throws {
		let transport = FakeTransport()
		var policy = ReconnectPolicy()
		policy.keepalive = nil
		let host = HostStore(connection: HostConnection(url: URL(string: "wss://egwene.example.ts.net/amyrlin")!, transport: transport, client: ClientInfo(name: "amyrlin-tests", version: "0"), policy: policy, sleep: { _ in await Task.yield() }, random: { 0.5 }))
		await host.connection.start()
		let server = try await transport.nextConnection()
		try await server.acceptHello()
		let searching = Task { try await host.searchMessages("restore") }
		let request = try await server.nextRequest("messages.search")
		#expect(request.params == .object(["query": "restore", "limit": .number(30)]))
		server.respond(request, error: "unknown_method", message: "Unknown method messages.search")
		await #expect(throws: ProtocolError.self) { try await searching.value }
		#expect(!host.has("messages.search"))
		#expect(try await host.searchMessages("restore").isEmpty, "answered here, without asking")
		await host.stop()
	}

	/// Paging back to an entry older than the snapshot, then marking it to scroll to.
	@Test func revealPagesBackToTheEntry() async throws {
		let transport = FakeTransport()
		var policy = ReconnectPolicy()
		policy.keepalive = nil
		let host = HostStore(connection: HostConnection(url: URL(string: "wss://egwene.example.ts.net/amyrlin")!, transport: transport, client: ClientInfo(name: "amyrlin-tests", version: "0"), policy: policy, sleep: { _ in await Task.yield() }, random: { 0.5 }))
		let store = host.conversation(1)
		await host.connection.start()
		store.start()
		let server = try await transport.nextConnection()
		try await server.acceptHello()
		server.respond(try await server.nextRequest("conversation.watch"), result: .object(["subscription": "s1"]))
		server.event("s1", seq: 0, [.object(["type": "snapshot", "conversation": .object(["id": .number(1)]), "hasEarlier": true, "items": .array([
			.object(["id": .number(300), "type": "user", "content": .array([.object(["type": "text", "text": "late"])])]),
		])])])
		server.respond(try await server.nextRequest("checkpoints.list"), result: .object(["checkpoints": .array([])]))
		await store.waitForSnapshot()
		let revealing = Task { await store.reveal(120) }
		let first = try await server.nextRequest("conversation.history")
		#expect(first.params["before"] == .number(300))
		server.respond(first, result: .object(["items": .array([.object(["id": .number(200), "type": "user", "content": .array([])])]), "hasEarlier": true]))
		let second = try await server.nextRequest("conversation.history")
		#expect(second.params["before"] == .number(200))
		server.respond(second, result: .object(["items": .array([.object(["id": .number(100), "type": "user", "content": .array([])])]), "hasEarlier": true]))
		await revealing.value
		#expect(store.revealing == 120, "it stops once the entry's page is in")
		#expect(store.state.items.map(\.id) == [100, 200, 300])
		await host.stop()
	}
}
