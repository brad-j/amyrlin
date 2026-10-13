import Foundation
import os

/// Events a subscription can carry; lets the connection check frames without knowing the event type.
public protocol SubscriptionEvent: Decodable, Sendable {
	var isSnapshot: Bool { get }
	var unknownType: String? { get }
}

extension ConversationEvent: SubscriptionEvent {
	public var isSnapshot: Bool { if case .snapshot = self { true } else { false } }
	public var unknownType: String? { if case .unknown(let type) = self { type } else { nil } }
}

extension HostEvent: SubscriptionEvent {
	public var isSnapshot: Bool { if case .snapshot = self { true } else { false } }
	public var unknownType: String? { if case .unknown(let type) = self { type } else { nil } }
}

/// What a subscription delivers to its consumer.
public enum SubscriptionUpdate<Event: Sendable>: Sendable {
	/// One frame's events, decoded. A frame that starts with a snapshot replaces all state.
	case events([Event])
	/// The connection dropped or the stream was resynced; a fresh snapshot follows.
	case resyncing(reason: String)
	/// The subscription failed three times in a minute and will not retry (protocol section 3).
	case failed(reason: String)
	/// The server ended it for good, for example `not_found`.
	case ended(reason: String)
}

/// A live subscription. It survives reconnects: the connection watches again and delivers a fresh snapshot.
public struct Subscription<Event: Sendable>: Sendable {
	public let updates: AsyncStream<SubscriptionUpdate<Event>>
	let token: UUID
	let connection: HostConnection

	/// Asks for a fresh snapshot, for example when the reducer cannot apply an event.
	public func resync(reason: String) async {
		await connection.resync(token, reason: reason)
	}

	public func cancel() async {
		await connection.cancel(token)
	}
}

public enum ConnectionError: Error, Sendable, Hashable {
	/// The socket dropped after the request was sent, and the method is not safe to send twice (section 9.1).
	case outcomeUnknown(method: String)
	case stopped
	case unsupportedProtocol(serverSpeaks: [Int])
	case badHandshake(String)
}

public struct ReconnectPolicy: Sendable {
	public var initialDelay: Duration = .milliseconds(500)
	public var maximumDelay: Duration = .seconds(30)
	/// A connection that lives this long resets the backoff.
	public var stableAfter: Duration = .seconds(60)
	/// Ping interval; nil turns keepalive off.
	public var keepalive: Duration? = .seconds(15)
	/// No frame or pong for this long counts as a dead connection.
	public var deadAfter: Duration = .seconds(45)
	public var maximumMessageSize = 16 * 1024 * 1024
	/// A subscription that resyncs this many times within `failureWindow` gives up.
	public var maximumResyncs = 3
	public var failureWindow: Duration = .seconds(60)

	public static let standard = ReconnectPolicy()

	public init() {}

	/// Exponential backoff with full jitter.
	func delay(attempt: Int, random: Double) -> Duration {
		let exponent = min(attempt, 16)
		let capped = min(initialDelay * Int(1 << exponent), maximumDelay)
		return capped * random
	}
}

/// One WebSocket to one amyrlin server, with reconnects (protocol sections 2, 3 and 9).
public actor HostConnection {
	public enum Status: Sendable, Hashable {
		case idle
		case connecting(attempt: Int)
		case connected(Welcome)
		case waiting(retryIn: Duration, lastError: String)
		/// No retry will help, such as a protocol version mismatch.
		case failed(String)
		case stopped
	}

	public typealias Sleeper = @Sendable (Duration) async throws -> Void

	public let url: URL
	public private(set) var status: Status = .idle {
		didSet { statusContinuation.yield(status) }
	}
	public nonisolated let statusUpdates: AsyncStream<Status>

	private let transport: any WebSocketTransport
	private let client: ClientInfo
	private let policy: ReconnectPolicy
	private let sleep: Sleeper
	private let random: @Sendable () -> Double
	private let statusContinuation: AsyncStream<Status>.Continuation
	private let log = Logger(subsystem: "io.bradjohnson.amyrlin", category: "connection")

	private var runTask: Task<Void, Never>?
	private var connection: (any WebSocketConnection)?
	private var connectionID = 0
	private var lastFrameAt = ContinuousClock.now
	private var nextRequestID = 0
	private var pending: [String: PendingRequest] = [:]
	private var subscriptions: [UUID: SubscriptionRecord] = [:]
	private var serverSubscriptions: [String: UUID] = [:]
	/// Set once the connection can never succeed; later requests fail with it at once.
	private var terminalError: ConnectionError?

	public init(
		url: URL,
		transport: any WebSocketTransport = URLSessionTransport(),
		client: ClientInfo,
		policy: ReconnectPolicy = .standard,
		sleep: @escaping Sleeper = { try await Task.sleep(for: $0) },
		random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }
	) {
		self.url = url
		self.transport = transport
		self.client = client
		self.policy = policy
		self.sleep = sleep
		self.random = random
		(statusUpdates, statusContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
	}

	// MARK: Lifecycle

	public func start() {
		guard runTask == nil else { return }
		// A stopped connection may start again; a protocol mismatch stays failed.
		if terminalError == .stopped { terminalError = nil }
		runTask = Task { await self.run() }
	}

	public func stop() async {
		runTask?.cancel()
		runTask = nil
		await connection?.close()
		connection = nil
		for request in pending.values { request.continuation.resume(throwing: ConnectionError.stopped) }
		pending = [:]
		for record in subscriptions.values { record.finish(.ended(reason: "stopped")) }
		subscriptions = [:]
		serverSubscriptions = [:]
		terminalError = terminalError ?? .stopped
		status = .stopped
	}

	private func run() async {
		var attempt = 0
		while !Task.isCancelled {
			status = .connecting(attempt: attempt)
			let connectedAt = ContinuousClock.now
			var reason = "connection closed"
			do {
				try await connectAndServe()
			} catch let error as ConnectionError {
				if case .unsupportedProtocol = error {
					status = .failed("The server speaks protocol versions this app does not.")
					failAll(error)
					return
				}
				reason = String(describing: error)
			} catch {
				reason = ConnectionTrouble.explain(error)
			}
			if Task.isCancelled { return }
			dropConnection(reason: reason)
			attempt = ContinuousClock.now - connectedAt >= policy.stableAfter ? 0 : attempt + 1
			let delay = policy.delay(attempt: attempt, random: random())
			status = .waiting(retryIn: delay, lastError: reason)
			log.info("reconnecting to \(self.url, privacy: .public) in \(delay, privacy: .public): \(reason, privacy: .public)")
			do { try await sleep(delay) } catch { return }
		}
	}

	/// Connects, handshakes, restores subscriptions and pending requests, then reads frames until the socket fails.
	private func connectAndServe() async throws {
		let socket = try await transport.connect(to: url, maximumMessageSize: policy.maximumMessageSize)
		connectionID += 1
		let id = connectionID
		connection = socket
		try await socket.send(encode(HelloFrame(protocols: supportedProtocolVersions, client: client)))
		let welcome = try handshake(try await socket.receive())
		lastFrameAt = .now
		status = .connected(welcome)
		for token in subscriptions.keys { startWatch(token) }
		for request in pending.values.sorted(by: { $0.order < $1.order }) where !request.sent {
			await transmit(request.id)
		}
		let keepalive = policy.keepalive.map { interval in Task { await self.keepalive(connection: id, every: interval) } }
		defer { keepalive?.cancel() }
		while true {
			let text = try await socket.receive()
			lastFrameAt = .now
			handle(text)
		}
	}

	private func handshake(_ text: String) throws -> Welcome {
		let data = Data(text.utf8)
		let envelope = try JSONDecoder().decode(ServerEnvelope.self, from: data)
		switch envelope.type {
		case "welcome":
			let welcome = try JSONDecoder().decode(Welcome.self, from: data)
			guard supportedProtocolVersions.contains(welcome.protocol) else {
				throw ConnectionError.unsupportedProtocol(serverSpeaks: [welcome.protocol])
			}
			return welcome
		case "goodbye":
			let goodbye = try JSONDecoder().decode(Goodbye.self, from: data)
			if goodbye.reason == "unsupported_protocol" {
				throw ConnectionError.unsupportedProtocol(serverSpeaks: goodbye.protocols ?? [])
			}
			throw ConnectionError.badHandshake("goodbye: \(goodbye.reason)")
		default:
			throw ConnectionError.badHandshake("expected welcome, got \(envelope.type)")
		}
	}

	private func keepalive(connection id: Int, every interval: Duration) async {
		while !Task.isCancelled, id == connectionID, let socket = connection {
			do { try await sleep(interval) } catch { return }
			guard id == connectionID else { return }
			if ContinuousClock.now - lastFrameAt > policy.deadAfter {
				log.info("no frame for \(self.policy.deadAfter, privacy: .public); closing")
				await socket.close()
				return
			}
			if (try? await socket.ping()) != nil { lastFrameAt = .now }
		}
	}

	/// Settles what the lost connection leaves behind (protocol section 9.1).
	private func dropConnection(reason: String) {
		connection = nil
		serverSubscriptions = [:]
		for (id, request) in pending where request.sent {
			if request.retriesOnReconnect {
				pending[id]?.sent = false
			} else {
				pending[id] = nil
				request.continuation.resume(throwing: ConnectionError.outcomeUnknown(method: request.method))
			}
		}
		for token in subscriptions.keys {
			subscriptions[token]?.serverID = nil
			subscriptions[token]?.notify(.resyncing(reason: reason))
		}
	}

	private func failAll(_ error: ConnectionError) {
		terminalError = error
		for request in pending.values { request.continuation.resume(throwing: error) }
		pending = [:]
		for record in subscriptions.values { record.finish(.failed(reason: String(describing: error))) }
		subscriptions = [:]
	}

	// MARK: Requests

	/// Sends a command and waits for its response. While disconnected the request waits for the next connection.
	public func send<C: Command>(_ command: C) async throws -> C.Result {
		let data = try await rawRequest(method: C.method, params: command.params, retriesOnReconnect: C.retriesOnReconnect)
		let response = try JSONDecoder().decode(ResponseFrame<C.Result>.self, from: data)
		if let error = response.error { throw error }
		if let result = response.result { return result }
		// An absent result decodes for types without required fields, such as EmptyResult.
		return try JSONDecoder().decode(C.Result.self, from: Data("{}".utf8))
	}

	private func rawRequest(
		method: String,
		params: some Encodable & Sendable,
		retriesOnReconnect: Bool,
		watch: PendingRequest.Watch? = nil
	) async throws -> Data {
		if let terminalError { throw terminalError }
		nextRequestID += 1
		let id = "r\(nextRequestID)"
		let text = try encode(RequestFrame(id: id, method: method, params: params))
		return try await withCheckedThrowingContinuation { continuation in
			pending[id] = PendingRequest(
				id: id, order: nextRequestID, method: method, text: text,
				retriesOnReconnect: retriesOnReconnect, watch: watch, continuation: continuation
			)
			if case .connected = status { Task { await self.transmit(id) } }
		}
	}

	private func transmit(_ id: String) async {
		guard let request = pending[id], !request.sent, let socket = connection else { return }
		pending[id]?.sent = true
		do {
			try await socket.send(request.text)
		} catch {
			// The read loop sees the failure too and settles the request in dropConnection.
			log.debug("send failed for \(request.method, privacy: .public): \(String(describing: error), privacy: .public)")
		}
	}

	// MARK: Subscriptions

	public func watchConversation(_ id: ConversationID) -> Subscription<ConversationEvent> {
		subscribe(.conversation(id))
	}

	public func watchHost() -> Subscription<HostEvent> {
		subscribe(.host)
	}

	private func subscribe<Event: SubscriptionEvent>(_ target: SubscriptionRecord.Target) -> Subscription<Event> {
		let (stream, continuation) = AsyncStream<SubscriptionUpdate<Event>>.makeStream()
		let token = UUID()
		if let terminalError {
			continuation.yield(.failed(reason: String(describing: terminalError)))
			continuation.finish()
			return Subscription(updates: stream, token: token, connection: self)
		}
		subscriptions[token] = SubscriptionRecord(target: target, continuation: continuation)
		continuation.onTermination = { [weak self] _ in
			Task { await self?.cancel(token) }
		}
		if case .connected = status { startWatch(token) }
		return Subscription(updates: stream, token: token, connection: self)
	}

	private func startWatch(_ token: UUID) {
		guard let record = subscriptions[token] else { return }
		subscriptions[token]?.expectedSeq = 0
		subscriptions[token]?.generation += 1
		let watch = PendingRequest.Watch(token: token, generation: subscriptions[token]?.generation ?? 0)
		Task {
			do {
				// The read loop registers the server's subscription ID when the response arrives, before it reads
				// the subscription's first event frame (protocol section 2.2). Here only errors matter.
				let data: Data
				switch record.target {
				case .conversation(let id):
					data = try await self.rawRequest(
						method: Commands.WatchConversation.method, params: Commands.WatchConversation.Params(conversationId: id),
						retriesOnReconnect: false, watch: watch
					)
				case .host:
					data = try await self.rawRequest(
						method: Commands.WatchHost.method, params: Commands.WatchHost.Params(), retriesOnReconnect: false, watch: watch
					)
				}
				if let error = try JSONDecoder().decode(ResponseFrame<Commands.WatchResult>.self, from: data).error { throw error }
			} catch let error as ProtocolError where error.code == "not_found" {
				self.end(token, reason: "not_found")
			} catch {
				// A dropped connection retries on reconnect; anything else counts as a failed resync.
				if case .connected = self.status { self.resync(token, reason: "watch failed: \(error)") }
			}
		}
	}

	private func registerWatch(_ token: UUID, generation: Int, serverID: String) {
		guard subscriptions[token]?.generation == generation else {
			// Superseded by a later watch of the same subscription.
			Task { _ = try? await self.send(Commands.Unsubscribe(params: .init(subscription: serverID))) }
			return
		}
		subscriptions[token]?.serverID = serverID
		serverSubscriptions[serverID] = token
	}

	func resync(_ token: UUID, reason: String) {
		guard var record = subscriptions[token] else { return }
		let now = ContinuousClock.now
		record.resyncs = record.resyncs.filter { now - $0 < policy.failureWindow } + [now]
		if let serverID = record.serverID {
			serverSubscriptions[serverID] = nil
			Task { _ = try? await self.send(Commands.Unsubscribe(params: .init(subscription: serverID))) }
		}
		record.serverID = nil
		subscriptions[token] = record
		if record.resyncs.count > policy.maximumResyncs {
			log.error("giving up on \(String(describing: record.target), privacy: .public): \(reason, privacy: .public)")
			end(token, reason: reason, failed: true)
			return
		}
		log.notice("resyncing \(String(describing: record.target), privacy: .public): \(reason, privacy: .public)")
		record.notify(.resyncing(reason: reason))
		if case .connected = status { startWatch(token) }
	}

	func cancel(_ token: UUID) {
		guard let record = subscriptions.removeValue(forKey: token) else { return }
		record.finish(.ended(reason: "cancelled"))
		if let serverID = record.serverID {
			serverSubscriptions[serverID] = nil
			Task { _ = try? await self.send(Commands.Unsubscribe(params: .init(subscription: serverID))) }
		}
	}

	private func end(_ token: UUID, reason: String, failed: Bool = false) {
		guard let record = subscriptions.removeValue(forKey: token) else { return }
		if let serverID = record.serverID { serverSubscriptions[serverID] = nil }
		record.finish(failed ? .failed(reason: reason) : .ended(reason: reason))
	}

	// MARK: Frames

	private func handle(_ text: String) {
		let data = Data(text.utf8)
		guard let envelope = try? JSONDecoder().decode(ServerEnvelope.self, from: data) else {
			log.error("undecodable frame: \(text, privacy: .public)")
			return
		}
		switch envelope.type {
		case "response":
			guard let id = envelope.id, let request = pending.removeValue(forKey: id) else { return }
			if let watch = request.watch,
				let result = (try? JSONDecoder().decode(ResponseFrame<Commands.WatchResult>.self, from: data))?.result
			{
				registerWatch(watch.token, generation: watch.generation, serverID: result.subscription)
			}
			request.continuation.resume(returning: data)
		case "event":
			guard let serverID = envelope.subscription else { return }
			// Frames of unsubscribed or superseded watches have no token and are dropped.
			if let token = serverSubscriptions[serverID] { deliver(data, to: token) }
		case "end":
			guard let frame = try? JSONDecoder().decode(EndFrame.self, from: data),
				let token = serverSubscriptions.removeValue(forKey: frame.subscription)
			else { return }
			subscriptions[token]?.serverID = nil
			if frame.reason == "not_found" {
				end(token, reason: frame.reason)
			} else {
				resync(token, reason: "server ended the subscription: \(frame.reason)")
			}
		case "goodbye":
			log.info("server said goodbye: \(text, privacy: .public)")
		default:
			log.error("unknown frame type \(envelope.type, privacy: .public)")
		}
	}

	private func deliver(_ data: Data, to token: UUID) {
		guard let record = subscriptions[token] else { return }
		switch record.deliver(data, record.expectedSeq) {
		case .delivered(let seq):
			subscriptions[token]?.expectedSeq = seq + 1
		case .problem(let reason):
			log.error("subscription frame rejected (\(reason, privacy: .public)): \(String(decoding: data, as: UTF8.self), privacy: .public)")
			resync(token, reason: reason)
		}
	}

	private func encode(_ value: some Encodable) throws -> String {
		String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
	}
}

private struct PendingRequest {
	let id: String
	let order: Int
	let method: String
	let text: String
	let retriesOnReconnect: Bool
	/// Set for `conversation.watch` and `host.watch`: the subscription to register when the response arrives.
	let watch: Watch?
	let continuation: CheckedContinuation<Data, any Error>
	var sent = false

	struct Watch {
		let token: UUID
		let generation: Int
	}
}

/// A subscription's bookkeeping, with its event type erased into closures.
struct SubscriptionRecord {
	enum Target: Sendable, CustomStringConvertible {
		case conversation(ConversationID)
		case host

		var description: String {
			switch self {
			case .conversation(let id): "conversation \(id)"
			case .host: "host"
			}
		}
	}

	enum FrameCheck {
		case delivered(seq: Int)
		case problem(String)
	}

	let target: Target
	var serverID: String?
	var expectedSeq = 0
	var generation = 0
	var resyncs: [ContinuousClock.Instant] = []
	/// Decodes and checks a frame against the expected `seq`, and yields its events when it is good.
	let deliver: @Sendable (Data, Int) -> FrameCheck
	let notify: @Sendable (StatusUpdate) -> Void
	let finish: @Sendable (StatusUpdate) -> Void

	enum StatusUpdate {
		case resyncing(reason: String)
		case failed(reason: String)
		case ended(reason: String)
	}

	init<Event: SubscriptionEvent>(target: Target, continuation: AsyncStream<SubscriptionUpdate<Event>>.Continuation) {
		self.target = target
		deliver = { data, expectedSeq in
			let frame: EventFrame<Event>
			do {
				frame = try JSONDecoder().decode(EventFrame<Event>.self, from: data)
			} catch {
				return .problem("frame did not decode: \(error)")
			}
			guard frame.seq == expectedSeq else { return .problem("expected seq \(expectedSeq), got \(frame.seq)") }
			var events: [Event] = []
			for (index, lossy) in frame.events.enumerated() {
				switch lossy.result {
				case .success(let event):
					if let type = event.unknownType { return .problem("unknown event type \(type)") }
					if expectedSeq == 0, index == 0, !event.isSnapshot { return .problem("first frame does not start with a snapshot") }
					events.append(event)
				case .failure(let failure):
					return .problem("event \(failure.type ?? "?") did not decode: \(failure.message)")
				}
			}
			continuation.yield(.events(events))
			return .delivered(seq: frame.seq)
		}
		notify = { update in
			switch update {
			case .resyncing(let reason): continuation.yield(.resyncing(reason: reason))
			case .failed(let reason): continuation.yield(.failed(reason: reason))
			case .ended(let reason): continuation.yield(.ended(reason: reason))
			}
		}
		finish = { update in
			switch update {
			case .resyncing(let reason): continuation.yield(.resyncing(reason: reason))
			case .failed(let reason): continuation.yield(.failed(reason: reason))
			case .ended(let reason): continuation.yield(.ended(reason: reason))
			}
			continuation.finish()
		}
	}
}
