import Foundation
import Testing
@testable import AmyrlinCore

/// `HostConnection` against a fake server the test drives frame by frame.
@Suite(.timeLimit(.minutes(1)))
struct HostConnectionTests {
	let transport = FakeTransport()
	let connection: HostConnection

	init() {
		var policy = ReconnectPolicy()
		policy.keepalive = nil
		connection = HostConnection(
			url: URL(string: "wss://egwene.example.ts.net/amyrlin")!,
			transport: transport,
			client: ClientInfo(name: "amyrlin-tests", version: "0"),
			policy: policy,
			sleep: { _ in await Task.yield() },
			random: { 0.5 }
		)
	}

	/// Starts the connection and completes the handshake on its first socket.
	private func connected() async throws -> FakeServerSide {
		await connection.start()
		let server = try await transport.nextConnection()
		try await server.acceptHello()
		return server
	}

	private static let snapshot: JSONValue = .object([
		"type": "snapshot", "conversation": .object(["id": .number(1)]), "items": .array([]),
		"tools": .array([]), "inbox": .array([]), "spend": .object([:]),
	])

	@Test func handshakeOffersV1AndRaisesTheMessageLimit() async throws {
		await connection.start()
		let server = try await transport.nextConnection()
		let hello = try await server.acceptHello()
		#expect(hello["type"] == "hello")
		#expect(hello["protocols"] == .array([.number(1)]))
		#expect(server.maximumMessageSize == 16 * 1024 * 1024)
		await connection.stop()
	}

	@Test func requestsMatchResponsesById() async throws {
		let server = try await connected()
		async let info = connection.send(Commands.HostInfo())
		async let list = connection.send(Commands.ListConversations())
		let first = try await server.nextRequest()
		let second = try await server.nextRequest()
		let (infoRequest, listRequest) = first.method == "host.info" ? (first, second) : (second, first)
		// Answer out of order.
		server.respond(listRequest, result: .object(["conversations": .array([])]))
		server.respond(infoRequest, result: .object([
			"host": .object(["hostId": "h", "name": "egwene"]), "models": .array([]), "tools": .array([]),
		]))
		#expect(try await info.host.name == "egwene")
		#expect(try await list.conversations.isEmpty)
		await connection.stop()
	}

	@Test func errorResponsesThrowProtocolErrors() async throws {
		let server = try await connected()
		let result = Task { [connection] in
			try await connection.send(Commands.Submit(conversationId: 1, requestId: "r", text: "x", whenBusy: .reject))
		}
		server.respond(try await server.nextRequest("submit"), error: "busy", message: "Conversation is busy")
		await #expect(throws: ProtocolError(code: "busy", message: "Conversation is busy")) { try await result.value }
		await connection.stop()
	}

	@Test func unsupportedProtocolStopsRetrying() async throws {
		await connection.start()
		let server = try await transport.nextConnection()
		_ = try await server.receive()
		server.send(.object(["type": "goodbye", "reason": "unsupported_protocol", "protocols": .array([.number(2)])]))
		for await status in connection.statusUpdates {
			if case .failed = status { break }
		}
		// A failed connection does not come back, so new requests fail at once instead of waiting.
		await #expect(throws: ConnectionError.unsupportedProtocol(serverSpeaks: [2])) { try await connection.send(Commands.HostInfo()) }
	}

	@Test func subscriptionResumesWithAFreshSnapshotAfterReconnect() async throws {
		let server = try await connected()
		let subscription = await connection.watchConversation(1)
		var updates = subscription.updates.makeAsyncIterator()
		let watch = try await server.nextRequest("conversation.watch")
		#expect(watch.params["conversationId"] == .number(1))
		server.respond(watch, result: .object(["subscription": "s1"]))
		server.event("s1", seq: 0, [Self.snapshot])
		#expect(await updates.next()?.firstEvent?.isSnapshot == true)
		server.event("s1", seq: 1, [.object(["type": "run.started", "inputs": .array([.number(8)])])])
		#expect(await updates.next()?.firstEvent == .runStarted(inputs: [8]))

		server.drop()
		#expect(await updates.next()?.isResyncing == true)
		let second = try await transport.nextConnection()
		try await second.acceptHello()
		let rewatch = try await second.nextRequest("conversation.watch")
		second.respond(rewatch, result: .object(["subscription": "s9"]))
		second.event("s9", seq: 0, [Self.snapshot])
		#expect(await updates.next()?.firstEvent?.isSnapshot == true)
		await connection.stop()
	}

	@Test func safeRequestsAreResentAfterReconnect() async throws {
		let server = try await connected()
		async let submitted = connection.send(Commands.Submit(conversationId: 1, requestId: "req-42", text: "Count to five."))
		let first = try await server.nextRequest("submit")
		#expect(first.params["requestId"] == "req-42")
		server.drop()
		let second = try await transport.nextConnection()
		try await second.acceptHello()
		let resent = try await second.nextRequest("submit")
		#expect(resent.params["requestId"] == "req-42")
		second.respond(resent, result: .object([
			"submission": .object(["id": .number(8), "type": "input", "status": "placed", "entryId": .number(7)]),
			"duplicate": true,
		]))
		let result = try await submitted
		#expect(result.duplicate)
		#expect(result.submission.id == 8)
		await connection.stop()
	}

	@Test func unsafeRequestsReportAnUnknownOutcome() async throws {
		let server = try await connected()
		let compacted = Task { [connection] in try await connection.send(Commands.Compact(conversationId: 1)) }
		_ = try await server.nextRequest("compact")
		server.drop()
		await #expect(throws: ConnectionError.outcomeUnknown(method: "compact")) { try await compacted.value }
		await connection.stop()
	}

	@Test func unknownEventTypeResubscribesThenGivesUp() async throws {
		let server = try await connected()
		let subscription = await connection.watchConversation(1)
		var updates = subscription.updates.makeAsyncIterator()
		var resyncs = 0
		var failed = false
		for attempt in 0..<4 {
			let watch = try await server.nextRequest("conversation.watch")
			server.respond(watch, result: .object(["subscription": .string("s\(attempt)")]))
			server.event("s\(attempt)", seq: 0, [Self.snapshot])
			#expect(await updates.next()?.firstEvent?.isSnapshot == true)
			server.event("s\(attempt)", seq: 1, [.object(["type": "turn.started"])])
			switch await updates.next() {
			case .resyncing?: resyncs += 1
			case .failed?: failed = true
			default: Issue.record("expected a resync or failure")
			}
		}
		// Three resyncs within a minute are allowed; the fourth gives up and ends the stream.
		#expect(resyncs == 3)
		#expect(failed)
		#expect(await updates.next() == nil)
		await connection.stop()
	}

	@Test func seqGapsAndMissingSnapshotsResync() async throws {
		let server = try await connected()
		let subscription = await connection.watchConversation(1)
		var updates = subscription.updates.makeAsyncIterator()
		let watch = try await server.nextRequest("conversation.watch")
		server.respond(watch, result: .object(["subscription": "s1"]))
		server.event("s1", seq: 0, [.object(["type": "run.started", "inputs": .array([])])])
		#expect(await updates.next()?.isResyncing == true)
		let rewatch = try await server.nextRequest("conversation.watch")
		server.respond(rewatch, result: .object(["subscription": "s2"]))
		server.event("s2", seq: 0, [Self.snapshot])
		#expect(await updates.next()?.firstEvent?.isSnapshot == true)
		server.event("s2", seq: 2, [.object(["type": "run.started", "inputs": .array([])])])
		#expect(await updates.next()?.isResyncing == true)
		await connection.stop()
	}

	@Test func fixtureStreamedOverTheSocketReachesTheReducedState() async throws {
		let server = try await connected()
		let subscription = await connection.watchConversation(1)
		let watch = try await server.nextRequest("conversation.watch")
		server.respond(watch, result: .object(["subscription": "s1"]))
		let frames = try Fixtures.wireFrameJSON("04-steer-during-tools")
		for (seq, frame) in frames.enumerated() { server.event("s1", seq: seq, frame) }
		var state = ConversationState()
		var received = 0
		for await update in subscription.updates {
			guard case .events(let events) = update else { continue }
			#expect(state.apply(events) == .applied)
			received += 1
			if received == frames.count { break }
		}
		#expect(state == Fixtures.reduce(try Fixtures.wireFrames("04-steer-during-tools")).state)
		await connection.stop()
	}

	@Test func backoffGrowsAndCaps() {
		let policy = ReconnectPolicy()
		#expect(policy.delay(attempt: 0, random: 1) == .milliseconds(500))
		#expect(policy.delay(attempt: 3, random: 1) == .seconds(4))
		#expect(policy.delay(attempt: 12, random: 1) == .seconds(30))
		#expect(policy.delay(attempt: 3, random: 0.25) == .seconds(1))
	}
}

extension SubscriptionUpdate {
	var firstEvent: Event? {
		if case .events(let events) = self { events.first } else { nil }
	}

	var isResyncing: Bool {
		if case .resyncing = self { true } else { false }
	}
}
