import Foundation
import Testing
@testable import AmyrlinCore

/// Visual replies (aludra, protocol section 10 item 18): a `publish_page` result is a page, shown in place of its call
/// only on a host whose host.info says `pages`, and fetched once with `conversation.page`.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PageTests {
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

	static let snapshot = #"[{"type":"snapshot","conversation":{"id":1,"title":"T","archived":false,"parent":null},"items":[],"hasEarlier":false,"contextStart":null,"run":null,"streaming":null,"retry":null,"tools":[],"inbox":[],"approvals":[],"compactions":[],"settings":{"stored":{},"effective":{"tools":[]}},"spend":{"byModel":{},"byTool":{},"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0,"cost":0}}]"#

	/// A turn that publishes a page, then reads a file, then answers.
	static let turn = [
		#"[{"type":"item.added","item":{"id":7,"at":1,"type":"user","content":[{"type":"text","text":"Chart it"}]}}]"#,
		#"[{"type":"item.added","item":{"id":8,"at":2,"type":"assistant","content":[{"type":"toolCall","id":"p1","name":"publish_page","args":{"title":"Sales","html":"<p>hi</p>"}},{"type":"toolCall","id":"r1","name":"read","args":{"path":"a.ts"}}],"stopReason":"toolUse","model":{"provider":"faux","modelId":"faux-1"}}}]"#,
		#"[{"type":"item.added","item":{"id":9,"at":3,"type":"toolResult","callId":"p1","toolName":"publish_page","content":[{"type":"text","text":"Published page 3"}],"isError":false,"details":{"page":3,"title":"Sales","bytes":2048},"diagnostics":[]}}]"#,
		#"[{"type":"item.added","item":{"id":10,"at":4,"type":"toolResult","callId":"r1","toolName":"read","content":[{"type":"text","text":"x"}],"isError":false,"diagnostics":[]}}]"#,
		#"[{"type":"item.added","item":{"id":11,"at":5,"type":"assistant","content":[{"type":"text","text":"Here it is."}],"stopReason":"stop","model":{"provider":"faux","modelId":"faux-1"}}}]"#,
	]

	static func state(_ frames: [String]) throws -> ConversationState {
		var state = ConversationState()
		for frame in [snapshot] + frames { state.apply(try JSONDecoder().decode([ConversationEvent].self, from: Data(frame.utf8))) }
		return state
	}

	static func result(_ json: String) throws -> ToolResultItem {
		let item = try JSONDecoder().decode(Item.self, from: Data(json.utf8))
		guard case .toolResult(let result) = item.body else { throw FakeError(description: "not a result") }
		return result
	}

	@Test func aPublishPageResultIsAPage() throws {
		let page = TranscriptPage.from(try Self.result(#"{"id":9,"at":3,"type":"toolResult","callId":"p1","toolName":"publish_page","content":[],"isError":false,"details":{"page":3,"title":"Sales","bytes":2048},"diagnostics":[]}"#))
		#expect(page == TranscriptPage(callId: "p1", page: .number(3), title: "Sales", bytes: 2048))
		// A page named by a string passes back as it came.
		let named = TranscriptPage.from(try Self.result(#"{"id":9,"type":"toolResult","callId":"p2","toolName":"publish_page","isError":false,"details":{"page":"pg_3","title":"Sales","bytes":10}}"#))
		#expect(named?.page == .string("pg_3"))
	}

	@Test func otherResultsAreNotPages() throws {
		let cases = [
			#"{"id":9,"type":"toolResult","callId":"a","toolName":"read","isError":false,"details":{"page":3,"title":"Sales","bytes":1}}"#,
			#"{"id":9,"type":"toolResult","callId":"b","toolName":"publish_page","isError":true,"details":{"page":3,"title":"Sales","bytes":1}}"#,
			#"{"id":9,"type":"toolResult","callId":"c","toolName":"publish_page","isError":false}"#,
			#"{"id":9,"type":"toolResult","callId":"d","toolName":"publish_page","isError":false,"details":{"title":"No page"}}"#,
		]
		for json in cases { #expect(TranscriptPage.from(try Self.result(json)) == nil, "\(json)") }
		// Missing title or bytes still makes a page.
		let bare = TranscriptPage.from(try Self.result(#"{"id":9,"type":"toolResult","callId":"e","toolName":"publish_page","isError":false,"details":{"page":4}}"#))
		#expect(bare?.title == "Page" && bare?.bytes == nil)
	}

	@Test func aHostWithPagesShowsThePageInPlaceOfTheCall() throws {
		let rows = TranscriptLayout.rows(state: try Self.state(Self.turn), pages: true)
		let kinds = rows.map { row -> String in
			switch row.kind {
			case .user: "user"
			case .page(let page): "page \(page.title)"
			case .toolRound(let round): "round \(round.calls.map(\.name).joined(separator: ","))"
			case .toolCall(let call): "call \(call.name)"
			case .text(let text, _): "text \(text)"
			default: "other"
			}
		}
		// The page sits where its call was, above the answer; the read after it is a call of its own.
		#expect(kinds == ["user", "page Sales", "round read", "text Here it is."])
		#expect(rows[1].id == "call-p1", "the page keeps its call's row")
	}

	@Test func aHostWithoutPagesShowsTheCall() throws {
		let rows = TranscriptLayout.rows(state: try Self.state(Self.turn), pages: false)
		#expect(!rows.contains { if case .page = $0.kind { true } else { false } })
		guard case .toolRound(let round)? = rows.first(where: { $0.id == "round-call-p1" })?.kind else {
			Issue.record("expected the call's round")
			return
		}
		#expect(round.calls.map(\.name) == ["publish_page", "read"])
		#expect(TranscriptLayout.rows(state: try Self.state(Self.turn)) == rows, "pages are off unless asked for")
	}

	@Test func aPageWaitingOnItsResultIsACall() throws {
		let rows = TranscriptLayout.rows(state: try Self.state(Array(Self.turn.prefix(2))), pages: true)
		#expect(!rows.contains { if case .page = $0.kind { true } else { false } })
	}

	@Test func aPageWhoseCallIsOutsideTheWindowIsStillAPage() throws {
		let rows = TranscriptLayout.rows(state: try Self.state([Self.turn[2]]), pages: true)
		#expect(rows.map(\.id) == ["call-p1"])
		guard case .page(let page)? = rows.first?.kind else {
			Issue.record("expected the page")
			return
		}
		#expect(page.page == .number(3))
	}

	@Test func hostInfoSaysWhetherPagesAreServed() throws {
		let decode = { (json: String) in try JSONDecoder().decode(Commands.HostInfo.Result.self, from: Data(json.utf8)) }
		#expect(try decode(#"{"host":{"hostId":"h","name":"egwene"},"models":[],"tools":[],"pages":true}"#).pages == true)
		#expect(try decode(#"{"host":{"hostId":"h","name":"egwene"},"models":[],"tools":[],"pages":false}"#).pages == false)
		#expect(try decode(#"{"host":{"hostId":"h","name":"egwene"},"models":[],"tools":[]}"#).pages == nil)
	}

	static let page: JSONValue = .object([
		"page": .number(3), "title": "Sales", "html": "<!doctype html><html><body><p>hi</p></body></html>", "bytes": .number(2048),
		"createdAt": .number(1_793_400_000_000), "csp": "default-src 'none'; script-src 'unsafe-inline'",
	])

	@Test func aPageIsFetchedOnceAndKept() async throws {
		let store = host.conversation(1)
		await host.connection.start()
		let server = try await transport.nextConnection()
		try await server.acceptHello()
		let first = Task { try await store.page(.number(3)) }
		let second = Task { try await store.page(.number(3)) }
		let request = try await server.nextRequest("conversation.page")
		#expect(request.params == .object(["conversationId": .number(1), "page": .number(3)]))
		server.respond(request, result: Self.page)
		let fetched = try await first.value
		#expect(fetched.title == "Sales" && fetched.createdAt == 1_793_400_000_000)
		#expect(try await second.value == fetched)
		#expect(try await store.page(.number(3)) == fetched)

		// A failed fetch isn't kept; the next ask sends again, and the one after that has it.
		let failing = Task { try await store.page(.number(4)) }
		server.respond(try await server.nextRequest("conversation.page"), error: "not_found", message: "no page 4")
		await #expect(throws: ProtocolError.self) { try await failing.value }
		let again = Task { try await store.page(.number(4)) }
		let retried = try await server.nextRequest("conversation.page")
		#expect(retried.params["page"] == .number(4), "the page wasn't fetched from a cache")
		server.respond(retried, result: Self.page)
		_ = try await again.value
		await host.stop()
	}

	@Test func theCSPIsAddedAfterTheDoctype() throws {
		let page = try JSONDecoder().decode(PublishedPage.self, from: JSONEncoder().encode(Self.page))
		#expect(page.enforcedHTML == #"<!doctype html><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'"><html><body><p>hi</p></body></html>"#)
		var bare = page
		bare.html = "<p>x</p>"
		bare.csp = "a \"b\""
		#expect(bare.enforcedHTML == #"<meta http-equiv="Content-Security-Policy" content="a &quot;b&quot;"><p>x</p>"#)
		bare.csp = nil
		#expect(bare.enforcedHTML == "<p>x</p>")
	}
}
