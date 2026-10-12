import Foundation
@testable import AmyrlinCore

/// An in-memory WebSocket. Each `connect` yields a `FakeServerSide` the test drives as the server.
final class FakeTransport: WebSocketTransport {
	private let connections: Mailbox<FakeServerSide>
	private let continuation: AsyncThrowingStream<FakeServerSide, any Error>.Continuation

	init() {
		let (stream, continuation) = AsyncThrowingStream<FakeServerSide, any Error>.makeStream()
		connections = Mailbox(stream)
		self.continuation = continuation
	}

	func connect(to url: URL, maximumMessageSize: Int) async throws -> any WebSocketConnection {
		let (toClient, toClientContinuation) = AsyncThrowingStream<String, any Error>.makeStream()
		let (toServer, toServerContinuation) = AsyncStream<String>.makeStream()
		continuation.yield(FakeServerSide(toClient: toClientContinuation, fromClient: toServer, maximumMessageSize: maximumMessageSize))
		return FakeClientSide(incoming: Mailbox(toClient), outgoing: toServerContinuation, closeIncoming: toClientContinuation)
	}

	/// The next connection the client opens.
	func nextConnection() async throws -> FakeServerSide {
		guard let next = try await connections.next() else { throw TransportClosed() }
		return next
	}
}

/// Hands out a stream's elements one call at a time, so a Sendable connection can share one iterator.
/// Each mailbox has one reader at a time; the iterator copies share the stream's storage.
actor Mailbox<Element: Sendable> {
	private var iterator: AsyncThrowingStream<Element, any Error>.AsyncIterator

	init(_ stream: AsyncThrowingStream<Element, any Error>) {
		iterator = stream.makeAsyncIterator()
	}

	func next() async throws -> Element? {
		var copy = iterator
		defer { iterator = copy }
		return try await copy.next(isolation: self)
	}
}

struct FakeClientSide: WebSocketConnection {
	let incoming: Mailbox<String>
	let outgoing: AsyncStream<String>.Continuation
	let closeIncoming: AsyncThrowingStream<String, any Error>.Continuation

	func send(_ text: String) async throws {
		if case .terminated = outgoing.yield(text) { throw TransportClosed() }
	}

	func receive() async throws -> String {
		guard let text = try await incoming.next() else { throw TransportClosed() }
		return text
	}

	func ping() async throws {}

	func close() async {
		outgoing.finish()
		closeIncoming.finish(throwing: TransportClosed())
	}
}

/// The test's end of one connection.
final class FakeServerSide: Sendable {
	struct Request: Sendable {
		let id: String
		let method: String
		let params: JSONValue
	}

	let maximumMessageSize: Int
	private let toClient: AsyncThrowingStream<String, any Error>.Continuation
	private let fromClient: Mailbox<String>

	init(toClient: AsyncThrowingStream<String, any Error>.Continuation, fromClient: AsyncStream<String>, maximumMessageSize: Int) {
		self.toClient = toClient
		self.maximumMessageSize = maximumMessageSize
		let (stream, continuation) = AsyncThrowingStream<String, any Error>.makeStream()
		Task {
			for await text in fromClient { continuation.yield(text) }
			continuation.finish()
		}
		self.fromClient = Mailbox(stream)
	}

	func send(_ json: String) {
		toClient.yield(json)
	}

	func send(_ value: JSONValue) {
		send(String(decoding: try! JSONEncoder().encode(value), as: UTF8.self))
	}

	/// Breaks the connection, as a network failure would.
	func drop() {
		toClient.finish(throwing: TransportClosed())
	}

	/// The next frame from the client, decoded.
	func receive() async throws -> JSONValue {
		guard let text = try await fromClient.next() else { throw TransportClosed() }
		return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
	}

	/// Reads the client's hello and answers with a v1 welcome.
	@discardableResult
	func acceptHello(hostId: String = "host-1") async throws -> JSONValue {
		let hello = try await receive()
		send(.object([
			"type": "welcome", "protocol": .number(1),
			"host": .object(["hostId": .string(hostId), "name": "egwene"]),
			"you": .object(["login": "brad@example.com"]),
			"limits": .object(["maxFrameBytes": .number(16_777_216), "snapshotItems": .number(200)]),
		]))
		return hello
	}

	func nextRequest() async throws -> Request {
		let frame = try await receive()
		guard frame["type"]?.stringValue == "request", let id = frame["id"]?.stringValue, let method = frame["method"]?.stringValue else {
			throw FakeError(description: "expected a request, got \(frame.jsonText)")
		}
		return Request(id: id, method: method, params: frame["params"] ?? .null)
	}

	/// Reads requests until one has `method`, answering `unsubscribe` along the way.
	func nextRequest(_ method: String) async throws -> Request {
		while true {
			let request = try await nextRequest()
			if request.method == method { return request }
			if request.method == "unsubscribe" { respond(request, result: .object([:])) }
		}
	}

	func respond(_ request: Request, result: JSONValue) {
		send(.object(["type": "response", "id": .string(request.id), "result": result]))
	}

	func respond(_ request: Request, error code: String, message: String = "") {
		send(.object(["type": "response", "id": .string(request.id), "error": .object(["code": .string(code), "message": .string(message)])]))
	}

	func event(_ subscription: String, seq: Int, _ events: [JSONValue]) {
		send(.object(["type": "event", "subscription": .string(subscription), "seq": .number(Double(seq)), "events": .array(events)]))
	}
}

struct FakeError: Error, CustomStringConvertible {
	let description: String
}
