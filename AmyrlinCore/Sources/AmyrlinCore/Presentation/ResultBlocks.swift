import Foundation

/// The fenced `result` and `plan` blocks a sandbox session's agent writes for the result page (protocol section 10
/// item 19). The page shows them from `task.result`; the transcript leaves them out of the answer's prose. A block
/// still being written is left out from its opening fence on, so it doesn't flash in while streaming.
public enum ResultBlocks {
	private static let fence = try! NSRegularExpression(pattern: #"(?m)^[ \t]*```(result|plan)[ \t]*\n[\s\S]*?(?:^[ \t]*```[ \t]*$\n?|\z)"#)

	public static func hidden(_ text: String) -> String {
		guard text.contains("```result") || text.contains("```plan") else { return text }
		let range = NSRange(text.startIndex..., in: text)
		let stripped = fence.stringByReplacingMatches(in: text, range: range, withTemplate: "")
		// Close the gap the blocks leave: at most one blank line in a row, none at the end.
		return stripped
			.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
			.trimmingCharacters(in: .whitespacesAndNewlines)
	}
}
