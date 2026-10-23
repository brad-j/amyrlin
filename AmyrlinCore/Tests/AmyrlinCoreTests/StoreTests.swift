import Foundation
import Testing
@testable import AmyrlinCore

/// The stores the app binds to, against the fake server.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct StoreTests {
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

	/// Polls main-actor state until `condition` holds; the stores update from tasks the test does not await.
	private func eventually(_ condition: () -> Bool) async -> Bool {
		for _ in 0..<2_000 {
			if condition() { return true }
			try? await Task.sleep(for: .milliseconds(1))
		}
		return condition()
	}

	@Test func hostStoreListsConversationsAndFetchesInfo() async throws {
		host.start()
		let server = try await transport.nextConnection()
		try await server.acceptHello()
		var watch: FakeServerSide.Request?
		for _ in 0..<2 {
			let request = try await server.nextRequest()
			switch request.method {
			case "host.watch": watch = request
			case "host.info":
				server.respond(request, result: .object([
					"host": .object(["hostId": "h", "name": "egwene"]), "models": .array([]), "tools": .array([]),
				]))
			default: Issue.record("unexpected \(request.method)")
			}
		}
		let hostWatch = try #require(watch)
		server.respond(hostWatch, result: .object(["subscription": "h1"]))
		server.event("h1", seq: 0, [.object([
			"type": "host.snapshot", "host": .object(["hostId": "h", "name": "egwene"]), "spend": .object([:]),
			"conversations": .array([
				.object(["id": .number(1), "title": "Older", "status": "idle", "updatedAt": .number(100)]),
				.object(["id": .number(2), "title": "Newer", "status": "busy", "updatedAt": .number(200)]),
			]),
		])])
		#expect(await eventually { host.state.active.map(\.title) == ["Newer", "Older"] })
		server.event("h1", seq: 1, [.object([
			"type": "conversation.updated",
			"conversation": .object(["id": .number(1), "title": "Older", "status": "needsApproval", "pendingApprovals": .number(1), "updatedAt": .number(300)]),
		])])
		#expect(await eventually { host.state.active.first?.status == .needsApproval })
		#expect(host.info?.host.name == "egwene")
		#expect(host.isConnected)
		await host.stop()
	}

	/// `onAlerts` hears each change in turn, even an ask and its answer in one batch, and nothing from the snapshot.
	@Test func alertsFollowHostWatch() async throws {
		var heard: [SessionAlert.Kind] = []
		host.onAlerts = { heard += $0.map(\.kind) }
		host.start()
		let server = try await transport.nextConnection()
		try await server.acceptHello()
		var watch: FakeServerSide.Request?
		for _ in 0..<2 {
			let request = try await server.nextRequest()
			if request.method == "host.watch" { watch = request }
		}
		let hostWatch = try #require(watch)
		server.respond(hostWatch, result: .object(["subscription": "h1"]))
		server.event("h1", seq: 0, [.object([
			"type": "host.snapshot", "host": .object(["hostId": "h", "name": "egwene"]), "spend": .object([:]),
			"conversations": .array([.object(["id": .number(1), "title": "Count", "status": "needsApproval", "updatedAt": .number(100)])]),
		])])
		#expect(await eventually { host.state.hasSnapshot })
		server.event("h1", seq: 1, ["busy", "needsApproval", "busy", "idle"].map { status in
			.object(["type": "conversation.updated", "conversation": .object(["id": .number(1), "title": "Count", "status": .string(status), "updatedAt": .number(200)])])
		})
		#expect(await eventually { host.state.conversations[1]?.status == .idle })
		#expect(heard == [.needsYou, .done])
		await host.stop()
	}

	/// Archiving moves a session between the lists, from the command's result and from `host.watch`; titles follow
	/// `conversation.updated`, as when the host's model titles a new session.
	@Test func archivingAndRetitlingFollowTheHost() async throws {
		host.start()
		let server = try await transport.nextConnection()
		try await server.acceptHello()
		var watch: FakeServerSide.Request?
		for _ in 0..<2 {
			let request = try await server.nextRequest()
			if request.method == "host.watch" { watch = request }
		}
		let hostWatch = try #require(watch)
		server.respond(hostWatch, result: .object(["subscription": "h1"]))
		server.event("h1", seq: 0, [.object([
			"type": "host.snapshot", "host": .object(["hostId": "h", "name": "egwene"]), "spend": .object([:]),
			"conversations": .array([
				.object(["id": .number(1), "title": "Count to five.", "status": "busy", "updatedAt": .number(100)]),
				.object(["id": .number(2), "title": "Old", "status": "idle", "archived": true, "updatedAt": .number(50)]),
			]),
		])])
		#expect(await eventually { host.state.active.map(\.id) == [1] && host.state.archived.map(\.id) == [2] })

		server.event("h1", seq: 1, [.object([
			"type": "conversation.updated",
			"conversation": .object(["id": .number(1), "title": "Counting to five", "status": "busy", "updatedAt": .number(100)]),
		])])
		#expect(await eventually { host.state.conversations[1]?.title == "Counting to five" })

		let archiving = Task { try await host.setArchived(1, true) }
		let archive = try await server.nextRequest("conversations.archive")
		#expect(archive.params["conversationId"] == .number(1))
		#expect(archive.params["archived"] == true)
		server.respond(archive, result: .object([
			"conversation": .object(["id": .number(1), "title": "Counting to five", "status": "busy", "archived": true, "updatedAt": .number(100)]),
		]))
		try await archiving.value
		#expect(host.state.active.isEmpty)
		#expect(host.state.archived.map(\.id) == [1, 2])
		#expect(host.state.conversations[1]?.status == .busy, "archiving doesn't stop a run")

		server.event("h1", seq: 2, [.object([
			"type": "conversation.updated",
			"conversation": .object(["id": .number(2), "title": "Old", "status": "idle", "archived": false, "updatedAt": .number(50)]),
		])])
		#expect(await eventually { host.state.active.map(\.id) == [2] })
		await host.stop()
	}

	/// The month's total comes with the snapshot; when a session is charged again, `host.info` is read for the new one.
	@Test func monthCostFollowsChargedSessions() async throws {
		host.monthCostDelay = .zero
		host.start()
		let server = try await transport.nextConnection()
		try await server.acceptHello()
		var watch: FakeServerSide.Request?
		for _ in 0..<2 {
			let request = try await server.nextRequest()
			switch request.method {
			case "host.watch": watch = request
			case "host.info":
				server.respond(request, result: .object([
					"host": .object(["hostId": "h", "name": "egwene"]), "models": .array([]), "tools": .array([]), "monthCost": .number(12.3),
				]))
			default: Issue.record("unexpected \(request.method)")
			}
		}
		let hostWatch = try #require(watch)
		server.respond(hostWatch, result: .object(["subscription": "h1"]))
		server.event("h1", seq: 0, [.object([
			"type": "host.snapshot", "host": .object(["hostId": "h", "name": "egwene"]), "spend": .object([:]), "monthCost": .number(12.3),
			"conversations": .array([
				.object(["id": .number(1), "title": "Routed", "status": "busy", "cost": .number(0.4), "updatedAt": .number(100)]),
				.object(["id": .number(2), "title": "Planned", "status": "idle", "spend": .object(["cost": .number(9)]), "updatedAt": .number(50)]),
			]),
		])])
		#expect(await eventually { host.state.monthCost == 12.3 })
		#expect(host.state.conversations[2]?.cost == nil, "a plan-paid session has no cost")

		server.event("h1", seq: 1, [.object([
			"type": "conversation.updated",
			"conversation": .object(["id": .number(1), "title": "Routed", "status": "idle", "cost": .number(0.42), "updatedAt": .number(110)]),
		])])
		let info = try await server.nextRequest("host.info")
		server.respond(info, result: .object([
			"host": .object(["hostId": "h", "name": "egwene"]), "models": .array([]), "tools": .array([]), "monthCost": .number(12.32),
		]))
		#expect(await eventually { host.state.monthCost == 12.32 })
		await host.stop()
	}

	@Test func sentMessageStaysInTheOutboxUntilTheTranscriptShowsIt() async throws {
		let store = host.conversation(1)
		await host.connection.start()
		store.start()
		let server = try await transport.nextConnection()
		try await server.acceptHello()
		let watch = try await server.nextRequest("conversation.watch")
		server.respond(watch, result: .object(["subscription": "s1"]))
		server.event("s1", seq: 0, [.object(["type": "snapshot", "conversation": .object(["id": .number(1)])])])
		#expect(await eventually { store.state.hasSnapshot })

		store.send("  Count to five.  ")
		#expect(store.outbox.map(\.text) == ["Count to five."])
		let submit = try await server.nextRequest("submit")
		let requestId = try #require(submit.params["requestId"]?.stringValue)
		#expect(requestId == store.outbox.first?.id)
		#expect(submit.params["whenBusy"] == "followUp")
		server.respond(submit, result: .object([
			"submission": .object(["id": .number(8), "requestId": .string(requestId), "type": "input", "status": "placed", "entryId": .number(7)]),
			"duplicate": false,
		]))
		// The response can arrive before the frame that shows the message; the outbox keeps it until then.
		try await Task.sleep(for: .milliseconds(20))
		#expect(store.outbox.count == 1)
		server.event("s1", seq: 1, [
			.object(["type": "item.added", "item": .object(["id": .number(7), "type": "user", "content": .array([.object(["type": "text", "text": "Count to five."])])])]),
			.object(["type": "submission", "submission": .object(["id": .number(8), "requestId": .string(requestId), "type": "input", "status": "placed", "entryId": .number(7)])]),
			.object(["type": "run.started", "inputs": .array([.number(8)])]),
		])
		#expect(await eventually { store.outbox.isEmpty })
		#expect(store.state.isBusy)
		#expect(store.state.items.map(\.id) == [7])
		await host.stop()
	}

	@Test func refusedSendStaysForRetry() async throws {
		let store = host.conversation(1)
		await host.connection.start()
		store.start()
		let server = try await transport.nextConnection()
		try await server.acceptHello()
		let watch = try await server.nextRequest("conversation.watch")
		server.respond(watch, result: .object(["subscription": "s1"]))
		server.event("s1", seq: 0, [.object(["type": "snapshot", "conversation": .object(["id": .number(1)])])])

		store.send("Only if idle", whenBusy: .reject)
		let submit = try await server.nextRequest("submit")
		server.respond(submit, error: "busy", message: "Conversation is busy")
		#expect(await eventually { store.outbox.first?.failure == "Conversation is busy" })

		let pending = try #require(store.outbox.first)
		store.retry(pending)
		let again = try await server.nextRequest("submit")
		#expect(again.params["requestId"]?.stringValue == pending.id, "a retry reuses the requestId")
		await host.stop()
	}

	private func hostInfo(defaultModel: String = "claude-opus-5-5") -> JSONValue {
		.object([
			"host": .object(["hostId": "h", "name": "egwene"]), "models": .array([]), "tools": .array([]),
			"defaults": .object(["model": .object(["provider": "claude-bridge", "modelId": .string(defaultModel)])]),
		])
	}

	private var settingsResult: JSONValue {
		get throws { .object(["settings": try JSONDecoder().decode(JSONValue.self, from: Data(settingsJSON.utf8))]) }
	}

	/// Settings are read on each connect, after `host.info`. A host from before them answers `unknown_method` and has
	/// none, so the app offers no settings screen for it.
	@Test func settingsAreReadOnConnectAndAbsentFromOlderHosts() async throws {
		host.start()
		let server = try await transport.nextConnection()
		try await server.acceptHello()
		server.respond(try await server.nextRequest("host.info"), result: hostInfo())
		server.respond(try await server.nextRequest("settings.get"), result: try settingsResult)
		#expect(await eventually { host.settings?.settings.count == 11 })

		// The machine comes back running an older aludra.
		server.drop()
		let older = try await transport.nextConnection()
		try await older.acceptHello()
		older.respond(try await older.nextRequest("host.info"), result: hostInfo())
		older.respond(try await older.nextRequest("settings.get"), error: "unknown_method", message: "Unknown method settings.get")
		#expect(await eventually { host.settings == nil })
		await host.stop()
	}

	/// A save sends only the changes and reads `host.info` again, since the defaults, models and projects come from the
	/// settings. A refused one keeps the settings as they were and gives every reason.
	@Test func savingSendsTheChangesThenReadsHostInfoAgain() async throws {
		host.start()
		let server = try await transport.nextConnection()
		try await server.acceptHello()
		server.respond(try await server.nextRequest("host.info"), result: hostInfo())
		server.respond(try await server.nextRequest("settings.get"), result: try settingsResult)
		#expect(await eventually { host.settings != nil })
		let before = host.settings

		let saving = Task { try await host.saveSettings(["model.id": .value(.text("claude-bridge/claude-sonnet-5-5")), "approvals.hosts": .toDefault]) }
		let set = try await server.nextRequest("settings.set")
		#expect(set.params == .object(["changes": .object(["model.id": "claude-bridge/claude-sonnet-5-5", "approvals.hosts": .null])]))
		var result = try settingsResult
		if case .object(var outer) = result, case .object(var settings) = outer["settings"] {
			settings["restart"] = .array(["model.choices"])
			outer["settings"] = .object(settings)
			result = .object(outer)
		}
		server.respond(set, result: result)
		server.respond(try await server.nextRequest("host.info"), result: hostInfo(defaultModel: "claude-sonnet-5-5"))
		let saved = try await saving.value
		#expect(saved.restart == ["model.choices"])
		#expect(host.settings == saved)
		#expect(host.info?.defaults?.model == ModelRef(provider: "claude-bridge", modelId: "claude-sonnet-5-5"), "host.info was read again")

		let refusing = Task { try await host.saveSettings(["backup.keep": .value(.text("lots")), "approvals.waitHours": .value(.text(""))]) }
		let refused = try await server.nextRequest("settings.set")
		let reasons: [JSONValue] = ["backup.keep should be a number", "approvals.waitHours should be a number"]
		server.send(.object(["type": "response", "id": .string(refused.id), "error": .object([
			"code": "invalid_settings", "message": "backup.keep should be a number\napprovals.waitHours should be a number", "data": .object(["errors": .array(reasons)]),
		])]))
		await #expect(throws: ProtocolError.self) { try await refusing.value }
		do {
			_ = try await refusing.value
		} catch let error as ProtocolError {
			#expect(error.reasons == ["backup.keep should be a number", "approvals.waitHours should be a number"])
		}
		#expect(host.settings == saved, "nothing was saved")
		#expect(before != saved)
		await host.stop()
	}
}
