import Foundation

/// The sidebar's search: a session matches when every word of the query is in its title, its project ("scratch" for
/// a session in none) or its directory, ignoring case.
public enum SessionSearch {
	public static func words(_ query: String) -> [String] {
		query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
	}

	/// True for every session when the query has no words.
	public static func matches(_ summary: ConversationSummary, words: [String]) -> Bool {
		let haystack = "\(summary.title) \(summary.project ?? "scratch") \(summary.dir ?? "")".lowercased()
		return words.allSatisfy(haystack.contains)
	}
}
