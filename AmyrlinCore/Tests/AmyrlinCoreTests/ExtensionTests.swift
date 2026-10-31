import Foundation
import Testing
@testable import AmyrlinCore

/// aludra's own methods outside v1 (protocol section 10, items 13 on): what they send and decode, and that a host
/// without one (`unknown_method`) stops being offered it until it reconnects.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ExtensionTests {
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

	static let info: JSONValue = .object(["host": .object(["hostId": "h", "name": "egwene"]), "models": .array([]), "tools": .array([])])

	/// A connected store with `host.info` and `settings.get` answered.
	private func connect() async throws -> FakeServerSide {
		host.start()
		let server = try await transport.nextConnection()
		try await server.acceptHello()
		server.respond(try await server.nextRequest("host.info"), result: Self.info)
		server.respond(try await server.nextRequest("settings.get"), error: "unknown_method")
		return server
	}

	static func summary(_ title: String, created: Double = 100, updated: Double = 200) -> JSONValue {
		.object(["id": .number(7), "title": .string(title), "status": "idle", "createdAt": .number(created), "updatedAt": .number(updated)])
	}

	@Test func retitleTakesTheNewTitleOrSaysNoneWasWritten() async throws {
		let server = try await connect()
		let retitling = Task { try await host.retitle(7) }
		let request = try await server.nextRequest("conversations.retitle")
		#expect(request.params == .object(["conversationId": .number(7)]))
		server.respond(request, result: .object(["conversation": Self.summary("Checkpoints in amyrlin"), "written": true]))
		#expect(try await retitling.value)
		#expect(host.state.conversations[7]?.title == "Checkpoints in amyrlin")

		let again = Task { try await host.retitle(7) }
		server.respond(try await server.nextRequest("conversations.retitle"), result: .object(["conversation": Self.summary("Checkpoints in amyrlin"), "written": false]))
		#expect(try await again.value == false)
		await host.stop()
	}

	@Test func aSessionWithoutMessagesHasNothingToTitle() throws {
		let decode = { (json: JSONValue) in try JSONDecoder().decode(ConversationSummary.self, from: JSONEncoder().encode(json)) }
		#expect(try decode(Self.summary("New session", created: 100, updated: 100)).hasMessages == false)
		#expect(try decode(Self.summary("Fix the login", created: 100, updated: 250)).hasMessages)
	}

	@Test func anOlderHostLacksAMethodUntilItReconnects() async throws {
		let server = try await connect()
		#expect(host.has("conversations.retitle"))
		let retitling = Task { try await host.retitle(7) }
		server.respond(try await server.nextRequest("conversations.retitle"), error: "unknown_method", message: "Unknown method conversations.retitle")
		await #expect(throws: ProtocolError.self) { try await retitling.value }
		#expect(!host.has("conversations.retitle"))
		#expect(host.has("messages.search"), "only the method it refused")

		// The machine comes back, perhaps running a newer aludra.
		server.drop()
		let newer = try await transport.nextConnection()
		try await newer.acceptHello()
		newer.respond(try await newer.nextRequest("host.info"), result: Self.info)
		#expect(await eventually { host.has("conversations.retitle") })
		await host.stop()
	}

	@Test func otherRefusalsDontMarkTheMethodMissing() async throws {
		let server = try await connect()
		let retitling = Task { try await host.retitle(7) }
		server.respond(try await server.nextRequest("conversations.retitle"), error: "bad_request", message: "the session has no messages yet")
		await #expect(throws: ProtocolError.self) { try await retitling.value }
		#expect(host.has("conversations.retitle"))
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
