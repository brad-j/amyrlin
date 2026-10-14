import Foundation

/// How fast streamed text appears. Text arrives in chunks, about ten a second from pi-durable's commits or a whole
/// block at once from the Claude Code bridge; shown as it arrives it jumps a line at a time. The view instead reveals
/// it at a rate that drains what has arrived in about `catchUp` seconds: a steady glide at the model's own speed, and
/// a quick sweep through a block that came all at once.
public enum RevealPace {
	/// Seconds to catch up with what has arrived.
	public static let catchUp = 0.3
	/// Characters a second, whatever the backlog: a few characters left still go at once.
	public static let minimumRate = 120.0
	/// Characters a second at most, for a very long block arriving whole.
	public static let maximumRate = 9000.0

	/// The characters shown `elapsed` seconds after `shown`, revealing towards `target`.
	public static func advance(_ shown: Double, towards target: Int, elapsed: Double) -> Double {
		let goal = Double(target)
		guard shown < goal else { return goal }
		let rate = min(max((goal - shown) / catchUp, minimumRate), maximumRate)
		return min(goal, shown + rate * max(0, elapsed))
	}
}

/// How far a block has been revealed, kept outside the view: the transcript's rows are lazy, and one scrolled away and
/// back resumes where it was rather than revealing again.
@MainActor
public final class RevealLedger {
	/// Characters shown, by row ID.
	private var shown: [String: Double] = [:]
	public private(set) var isPrimed = false
	/// The first row of the transcript's window, chosen when it opens.
	public var recentStart: String?

	public init() {}

	/// Marks rows already there when the transcript first opens as shown in full: only what arrives later reveals.
	public func prime(_ rows: [(id: String, length: Int)]) {
		guard !isPrimed else { return }
		isPrimed = true
		for row in rows { shown[row.id] = Double(row.length) }
	}

	/// Characters shown of row `id`: where it was left, or nothing for a row that arrived after the transcript opened.
	/// Before the transcript has primed, everything shows in full.
	public func shown(_ id: String, length: Int) -> Double {
		if let value = shown[id] { return min(value, Double(length)) }
		return isPrimed ? 0 : Double(length)
	}

	public func record(_ id: String, _ value: Double) {
		shown[id] = value
	}
}
