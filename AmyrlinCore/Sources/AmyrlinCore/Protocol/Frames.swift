import Foundation

/// The protocol versions this client speaks (protocol section 3).
public let supportedProtocolVersions = [1]

public struct ClientInfo: Codable, Sendable, Hashable {
	public var name: String
	public var version: String

	public init(name: String, version: String) {
		self.name = name
		self.version = version
	}
}

struct HelloFrame: Encodable {
	let type = "hello"
	let protocols: [Int]
	let client: ClientInfo
}

struct RequestFrame<Params: Encodable>: Encodable {
	let type = "request"
	let id: String
	let method: String
	let params: Params
}

/// The `type` and routing fields every server frame has; decoded first to decide how to decode the rest.
struct ServerEnvelope: Decodable {
	let type: String
	let id: String?
	let subscription: String?
}

public struct Welcome: Decodable, Sendable, Hashable {
	public var `protocol`: Int
	public var host: HostIdentity
	public var you: Person?
	public var limits: Limits?
}

public struct Goodbye: Decodable, Sendable, Hashable {
	public var reason: String
	public var protocols: [Int]?
}

/// An error a server returns for one request (protocol section 2.1).
public struct ProtocolError: Decodable, Sendable, Hashable, Error {
	public var code: String
	public var message: String
	public var retryable: Bool
	public var data: JSONValue?

	public init(code: String, message: String, retryable: Bool = false, data: JSONValue? = nil) {
		self.code = code
		self.message = message
		self.retryable = retryable
		self.data = data
	}

	public init(from decoder: any Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		code = try c.decode(String.self, forKey: .code)
		message = try c.decodeIfPresent(String.self, forKey: .message) ?? code
		retryable = try c.decodeIfPresent(Bool.self, forKey: .retryable) ?? false
		data = try c.decodeIfPresent(JSONValue.self, forKey: .data)
	}

	private enum CodingKeys: String, CodingKey { case code, message, retryable, data }
}

struct ResponseFrame<Result: Decodable>: Decodable {
	let id: String
	let result: Result?
	let error: ProtocolError?
}

struct EventFrame<Event: Decodable & Sendable>: Decodable {
	let subscription: String
	let seq: Int
	let events: [LossyEvent<Event>]
}

struct EndFrame: Decodable {
	let subscription: String
	let reason: String
}

/// A response with an empty object as its result.
public struct EmptyResult: Decodable, Sendable, Hashable {}
