import Foundation

/// Long pastes held out of the composer. The field shows a marker in the text's place, `[paste #1 +42 lines]`, or
/// `[paste #1 1234 chars]` for a long line, and sending puts the text back. The markers and limits are pi's editor's.
/// One backspace deletes a whole marker (`marker(endingAt:in:)`), which drops its text from the message; the text is
/// kept until `clear()`, so undo brings it back.
public final class PastedText {
	private var held: [String: String] = [:]
	private var count = 0

	public init() {}

	/// More than ten lines, or more than a thousand characters.
	public static func isLong(_ text: String) -> Bool {
		let text = normalized(text)
		return lines(text) > 10 || text.count > 1000
	}

	/// Keeps the text and returns the marker that stands for it.
	public func hold(_ text: String) -> String {
		let text = Self.normalized(text)
		count += 1
		let lines = Self.lines(text)
		let marker = lines > 10 ? "[paste #\(count) +\(lines) lines]" : "[paste #\(count) \(text.count) chars]"
		held[marker] = text
		return marker
	}

	/// The message with each marker this holds replaced by its text. Other text that looks like a marker stays.
	public func expand(_ message: String) -> String {
		guard !held.isEmpty else { return message }
		var result = ""
		var rest = message[...]
		while let range = rest.range(of: Self.markerPattern, options: .regularExpression) {
			result += rest[..<range.lowerBound]
			let marker = String(rest[range])
			result += held[marker] ?? marker
			rest = rest[range.upperBound...]
		}
		return result + rest
	}

	/// The range, in UTF-16 units as the text view counts, of a marker this holds that ends at `location`.
	public func marker(endingAt location: Int, in text: String) -> NSRange? {
		let text = text as NSString
		guard !held.isEmpty, location > 0, location <= text.length else { return nil }
		let before = text.substring(to: location)
		guard let range = before.range(of: Self.markerPattern + "$", options: .regularExpression),
			held[String(before[range])] != nil else { return nil }
		return NSRange(range, in: before)
	}

	/// Forgets every paste, once the message is sent.
	public func clear() {
		held = [:]
		count = 0
	}

	private static let markerPattern = #"\[paste #\d+ (\+\d+ lines|\d+ chars)\]"#

	private static func normalized(_ text: String) -> String {
		text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
	}

	private static func lines(_ text: String) -> Int {
		text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
	}
}
