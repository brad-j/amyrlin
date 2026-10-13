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

/// The server answered the WebSocket upgrade with an HTTP status instead of switching protocols: 403 when tailscale
/// serve's login isn't let in, 502 when nothing answers behind tailscale serve.
public struct UpgradeRefused: Error, Sendable, Hashable {
	public let status: Int
	public init(status: Int) { self.status = status }
}

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
		do {
			try await task.send(.string(text))
		} catch {
			throw refusal(error)
		}
	}

	func receive() async throws -> String {
		let message: URLSessionWebSocketTask.Message
		do {
			message = try await task.receive()
		} catch {
			throw refusal(error)
		}
		switch message {
		case .string(let text): return text
		case .data(let data): return String(decoding: data, as: UTF8.self)
		@unknown default: throw TransportClosed()
		}
	}

	/// The upgrade's HTTP status when the server refused it, else the error as it came.
	private func refusal(_ error: any Error) -> any Error {
		if let http = task.response as? HTTPURLResponse, http.statusCode != 101 { return UpgradeRefused(status: http.statusCode) }
		return error
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
