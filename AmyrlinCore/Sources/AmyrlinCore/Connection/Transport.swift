import Foundation

/// Opens WebSocket connections. Tests substitute a fake; the app uses `URLSessionTransport`.
public protocol WebSocketTransport: Sendable {
	func connect(to url: URL, maximumMessageSize: Int) async throws -> any WebSocketConnection
}

/// One open WebSocket carrying text frames.
public protocol WebSocketConnection: Sendable {
	func send(_ text: String) async throws
	/// The next text frame. Throws once the connection is closed or broken.
	func receive() async throws -> String
	/// Round-trips a WebSocket ping. Throws when no pong arrives.
	func ping() async throws
	func close() async
}

public struct TransportClosed: Error, Sendable {}

/// `URLSessionWebSocketTask` behind `WebSocketTransport`.
public struct URLSessionTransport: WebSocketTransport {
	public init() {}

	public func connect(to url: URL, maximumMessageSize: Int) async throws -> any WebSocketConnection {
		let task = URLSession.shared.webSocketTask(with: url)
		// The default limit is 1 MiB; snapshots can be larger (protocol section 2.3).
		task.maximumMessageSize = maximumMessageSize
		task.resume()
		return URLSessionConnection(task: task)
	}
}

private struct URLSessionConnection: WebSocketConnection {
	let task: URLSessionWebSocketTask

	func send(_ text: String) async throws {
		try await task.send(.string(text))
	}

	func receive() async throws -> String {
		switch try await task.receive() {
		case .string(let text): return text
		case .data(let data): return String(decoding: data, as: UTF8.self)
		@unknown default: throw TransportClosed()
		}
	}

	func ping() async throws {
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
			task.sendPing { error in
				if let error { continuation.resume(throwing: error) } else { continuation.resume() }
			}
		}
	}

	func close() async {
		task.cancel(with: .normalClosure, reason: nil)
	}
}
