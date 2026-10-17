import Foundation

/// fzf-style matching: the query's characters in order anywhere in the text, ignoring case and the query's spaces, so
/// "amrln" finds amyrlin. Matches at the start of the text or of a word (after / - _ . or a space, or a capital after
/// a lowercase letter) and runs of consecutive characters score higher; gaps between matched characters score lower.
/// The best alignment wins, not the first one found.
public enum FuzzyMatch {
	public struct Match: Sendable, Hashable {
		public let score: Int
		/// The matched characters' offsets in the text.
		public let positions: [Int]
	}

	static let hit = 16
	static let consecutive = 8
	static let startBonus = 10
	static let wordBonus = 8
	static let camelBonus = 7

	/// Nil when some character of the query isn't in the text in order. An empty query matches with no score.
	public static func match(_ query: String, in text: String) -> Match? {
		let q = Array(query.lowercased().filter { !$0.isWhitespace })
		let t = Array(text)
		let lower = t.map { Character($0.lowercased()) }
		let (m, n) = (q.count, t.count)
		guard m > 0 else { return Match(score: 0, positions: []) }
		guard m <= n else { return nil }

		let bonus = (0..<n).map { j -> Int in
			if j == 0 { return startBonus }
			let previous = t[j - 1]
			if "/-_. ".contains(previous) { return wordBonus }
			if previous.isLowercase, t[j].isUppercase { return camelBonus }
			return 0
		}

		// score[i][j]: the best score with q[i] matched at t[j]; from[i][j] where q[i - 1] was matched.
		let none = Int.min
		var score = Array(repeating: Array(repeating: none, count: n), count: m)
		var from = Array(repeating: Array(repeating: -1, count: n), count: m)
		for j in 0..<n where lower[j] == q[0] {
			// The first character's word bonus counts double, and a late start costs a little.
			score[0][j] = hit + bonus[j] * 2 - min(j, 12)
		}
		for i in 1..<m {
			// The best of score[i - 1][k] + k over k ≤ j - 2, for a gap: a gap of g costs g + 2.
			var best = none
			var bestAt = -1
			for j in i..<n {
				let k = j - 2
				if k >= 0, score[i - 1][k] != none, score[i - 1][k] + k > best {
					best = score[i - 1][k] + k
					bestAt = k
				}
				guard lower[j] == q[i] else { continue }
				var here = none
				if score[i - 1][j - 1] != none {
					here = score[i - 1][j - 1] + hit + bonus[j] + consecutive
					from[i][j] = j - 1
				}
				if best != none, best - j - 1 + hit + bonus[j] > here {
					here = best - j - 1 + hit + bonus[j]
					from[i][j] = bestAt
				}
				score[i][j] = here
			}
		}

		guard let end = (0..<n).filter({ score[m - 1][$0] != none }).max(by: { score[m - 1][$0] < score[m - 1][$1] }) else { return nil }
		var positions = [end]
		for i in stride(from: m - 1, to: 0, by: -1) {
			positions.append(from[i][positions[positions.count - 1]])
		}
		return Match(score: score[m - 1][end], positions: positions.reversed())
	}
}
