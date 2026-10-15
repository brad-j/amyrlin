import Foundation

/// How long the current run has taken, and the last one took, timed on this Mac from the state after each frame. A run
/// starts its clock when it's seen to start; one already going when a snapshot arrives started at its newest message,
/// by the host's clock. The protocol carries no run times, so a run that ended out of sight has none.
public struct TurnClock: Sendable, Hashable {
	/// When the current run started; nil while idle.
	public private(set) var started: Date?
	/// How long the last run watched to its end took.
	public private(set) var last: TimeInterval?

	public init() {}

	public mutating func observe(_ state: ConversationState, snapshot: Bool, now: Date = Date()) {
		if state.isBusy {
			guard started == nil else { return }
			started = snapshot ? Self.newestMessage(state).map { min($0, now) } ?? now : now
		} else if let started {
			// A snapshot that finds the run over doesn't say when it ended.
			last = snapshot ? nil : now.timeIntervalSince(started)
			self.started = nil
		}
	}

	private static func newestMessage(_ state: ConversationState) -> Date? {
		let item = state.items.last { if case .user = $0.body { true } else { false } }
		return item?.at.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
	}

	/// `8s`, `1m 05s`, `1h 02m`.
	public static func format(_ seconds: TimeInterval) -> String {
		let total = max(0, Int(seconds))
		if total < 60 { return "\(total)s" }
		if total < 3600 { return "\(total / 60)m \(String(format: "%02d", total % 60))s" }
		return "\(total / 3600)h \(String(format: "%02d", total / 60 % 60))m"
	}
}
