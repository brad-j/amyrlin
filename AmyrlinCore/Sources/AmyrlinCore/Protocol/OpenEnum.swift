/// A string enum that keeps values it does not know (protocol section 3: enum values are open).
/// Conforming types implement `init(rawValue:)` without failing, mapping unknown strings to their `unknown` case.
public protocol OpenEnum: RawRepresentable, Codable, Sendable, Hashable where RawValue == String {
	init(rawValue: String)
}

extension OpenEnum {
	public init(from decoder: any Decoder) throws {
		self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
	}

	public func encode(to encoder: any Encoder) throws {
		var container = encoder.singleValueContainer()
		try container.encode(rawValue)
	}
}

public enum ThinkingLevel: OpenEnum {
	case off, minimal, low, medium, high, xhigh, max
	case unknown(String)

	public static let known: [ThinkingLevel] = [.off, .minimal, .low, .medium, .high, .xhigh, .max]

	public init(rawValue: String) {
		self = Self.known.first { $0.rawValue == rawValue } ?? .unknown(rawValue)
	}

	public var rawValue: String {
		switch self {
		case .off: "off"
		case .minimal: "minimal"
		case .low: "low"
		case .medium: "medium"
		case .high: "high"
		case .xhigh: "xhigh"
		case .max: "max"
		case .unknown(let raw): raw
		}
	}
}

public enum StopReason: OpenEnum {
	case stop, toolUse, length, error, aborted
	case unknown(String)

	public init(rawValue: String) {
		switch rawValue {
		case "stop": self = .stop
		case "toolUse": self = .toolUse
		case "length": self = .length
		case "error": self = .error
		case "aborted": self = .aborted
		default: self = .unknown(rawValue)
		}
	}

	public var rawValue: String {
		switch self {
		case .stop: "stop"
		case .toolUse: "toolUse"
		case .length: "length"
		case .error: "error"
		case .aborted: "aborted"
		case .unknown(let raw): raw
		}
	}
}

public enum SlotStatus: OpenEnum {
	case running, ended
	case unknown(String)

	public init(rawValue: String) {
		switch rawValue {
		case "running": self = .running
		case "ended": self = .ended
		default: self = .unknown(rawValue)
		}
	}

	public var rawValue: String {
		switch self {
		case .running: "running"
		case .ended: "ended"
		case .unknown(let raw): raw
		}
	}
}

public enum InboxMode: OpenEnum {
	case steer, followUp, write
	case unknown(String)

	public init(rawValue: String) {
		switch rawValue {
		case "steer": self = .steer
		case "followUp": self = .followUp
		case "write": self = .write
		default: self = .unknown(rawValue)
		}
	}

	public var rawValue: String {
		switch self {
		case .steer: "steer"
		case .followUp: "followUp"
		case .write: "write"
		case .unknown(let raw): raw
		}
	}
}

public enum SubmissionStatus: OpenEnum {
	case queued, placed, done, unanswered
	case unknown(String)

	public init(rawValue: String) {
		switch rawValue {
		case "queued": self = .queued
		case "placed": self = .placed
		case "done": self = .done
		case "unanswered": self = .unanswered
		default: self = .unknown(rawValue)
		}
	}

	public var rawValue: String {
		switch self {
		case .queued: "queued"
		case .placed: "placed"
		case .done: "done"
		case .unanswered: "unanswered"
		case .unknown(let raw): raw
		}
	}

	public var isSettled: Bool { self == .done || self == .unanswered }
}

public enum ConversationStatus: OpenEnum {
	case idle, busy, needsApproval, stuck
	case unknown(String)

	public init(rawValue: String) {
		switch rawValue {
		case "idle": self = .idle
		case "busy": self = .busy
		case "needsApproval": self = .needsApproval
		case "stuck": self = .stuck
		default: self = .unknown(rawValue)
		}
	}

	public var rawValue: String {
		switch self {
		case .idle: "idle"
		case .busy: "busy"
		case .needsApproval: "needsApproval"
		case .stuck: "stuck"
		case .unknown(let raw): raw
		}
	}
}

public enum ApprovalDecision: OpenEnum {
	case approve, deny, cancelled
	case unknown(String)

	public init(rawValue: String) {
		switch rawValue {
		case "approve": self = .approve
		case "deny": self = .deny
		case "cancelled": self = .cancelled
		default: self = .unknown(rawValue)
		}
	}

	public var rawValue: String {
		switch self {
		case .approve: "approve"
		case .deny: "deny"
		case .cancelled: "cancelled"
		case .unknown(let raw): raw
		}
	}
}

public enum WhenBusy: String, Codable, Sendable {
	case followUp, steer, reject
}
