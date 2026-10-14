import Foundation

/// The block structure of an answer: enough Markdown for what models write. Inline formatting (bold, italics, code,
/// links) is left in each block's text for the view to render. Built for streaming: an unclosed code fence is a code
/// block up to the end, and a half-written table row is a paragraph until its separator line arrives.
public enum MarkdownBlock: Sendable, Hashable {
	case paragraph(String)
	case heading(level: Int, text: String)
	/// Items in order, each with its nesting depth (0 for top level) and, for ordered lists, its number.
	case list(items: [ListItem])
	case code(language: String?, code: String, closed: Bool)
	case quote(String)
	case table(header: [String], rows: [[String]])
	case rule

	public struct ListItem: Sendable, Hashable {
		public var depth: Int
		/// The number of an ordered item, nil for a bullet.
		public var number: Int?
		/// `[ ]` or `[x]` task items.
		public var checked: Bool?
		public var text: String
	}
}

public enum Markdown {
	public static func blocks(_ source: String) -> [MarkdownBlock] {
		var parser = Parser(lines: source.components(separatedBy: "\n"))
		return parser.parse()
	}

	/// Text cut off mid-stream, ready to show without flickering between two looks as it grows. A trailing line that
	/// would change kind once it's written (a table header before its separator, a bare list marker or `#`, half a
	/// fence) waits; an open `**` or backtick is closed; half a link shows as its label. Finished text needs none of it.
	public static func settled(_ text: String) -> String {
		var lines = text.components(separatedBy: "\n")
		let fences = lines.filter { Parser.fence($0.trimmingCharacters(in: .whitespaces)) != nil }.count
		if fences % 2 == 1 {
			// Inside a code block: a closing fence still being typed would show as code, and an empty last line is
			// an extra line that goes away if the fence comes next. Both wait.
			if let last = lines.last?.trimmingCharacters(in: .whitespaces), last.count < 3, last.allSatisfy({ $0 == "`" || $0 == "~" }),
				Parser.fence(lines.dropLast().last?.trimmingCharacters(in: .whitespaces) ?? "") == nil
			{
				lines.removeLast()
			}
			return lines.joined(separator: "\n")
		}
		if let last = lines.last?.trimmingCharacters(in: .whitespaces), isUnfinishedMarker(last) {
			lines.removeLast()
		}
		// Trailing `|` lines are a table only once the header has its separator.
		var start = lines.count
		while start > 0 {
			let line = lines[start - 1].trimmingCharacters(in: .whitespaces)
			if line.hasPrefix("|") || (line.isEmpty && start == lines.count) { start -= 1 } else { break }
		}
		let pipes = lines[start...].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
		if !pipes.isEmpty, !(pipes.count >= 2 && Parser.isTableSeparator(pipes[pipes.startIndex + 1])) {
			lines.removeSubrange(start...)
		} else if pipes.count > 2, let last = lines.last?.trimmingCharacters(in: .whitespaces), !last.isEmpty,
			!last.hasSuffix("|") || last.count(where: { $0 == "|" }) < pipes[pipes.startIndex].count(where: { $0 == "|" })
		{
			// A body row still being written would resize the columns with each character; it shows once it has all
			// its cells.
			lines.removeLast()
		}
		if let last = lines.last, !last.isEmpty, Parser.fence(last.trimmingCharacters(in: .whitespaces)) == nil {
			lines[lines.count - 1] = closingInline(last)
		}
		return lines.joined(separator: "\n")
	}

	/// `-`, `3.`, `##`, `--`: the start of a list item, heading or rule with nothing after it yet.
	static func isUnfinishedMarker(_ trimmed: String) -> Bool {
		guard !trimmed.isEmpty else { return false }
		if ["-", "*", "+", "--", "**", "__", "_", ">"].contains(trimmed) { return true }
		if trimmed.allSatisfy({ $0 == "#" }), trimmed.count <= 6 { return true }
		if trimmed.allSatisfy({ $0 == "`" || $0 == "~" }), trimmed.count < 3 { return true }
		let digits = trimmed.prefix { $0.isNumber }
		if !digits.isEmpty, digits.count <= 9 {
			let rest = trimmed.dropFirst(digits.count)
			return rest.isEmpty || rest == "." || rest == ")"
		}
		return false
	}

	/// Closes what the cut left open on the last line: a code span, `**`, a link.
	static func closingInline(_ line: String) -> String {
		var line = line
		if line.filter({ $0 == "`" }).count % 2 == 1 {
			if line.hasSuffix("`") { line.removeLast() } else { line += "`" }
		}
		// Outside code spans: every other stretch between backticks.
		let prose = line.split(separator: "`", omittingEmptySubsequences: false).enumerated().filter { $0.offset % 2 == 0 }.map(\.element).joined(separator: " ")
		if prose.components(separatedBy: "**").count % 2 == 0 {
			if line.hasSuffix("**") { line.removeLast(2) } else { line += "**" }
		}
		if let open = line.lastIndex(of: "["), !line[open...].contains("`") {
			let rest = line[line.index(after: open)...]
			if let close = rest.firstIndex(of: "]") {
				let after = rest[rest.index(after: close)...]
				if after.hasPrefix("("), !after.contains(")") {
					line = String(line[..<open]) + String(rest[..<close])
				}
			} else {
				line.remove(at: open)
			}
		}
		return line
	}

	private struct Parser {
		let lines: [String]
		var index = 0
		var blocks: [MarkdownBlock] = []
		var paragraph: [String] = []

		init(lines: [String]) {
			self.lines = lines
		}

		mutating func parse() -> [MarkdownBlock] {
			while index < lines.count {
				let line = lines[index]
				let trimmed = line.trimmingCharacters(in: .whitespaces)
				if trimmed.isEmpty {
					flush()
					index += 1
				} else if let fence = Self.fence(trimmed) {
					flush()
					code(fence: fence)
				} else if let heading = Self.heading(trimmed) {
					flush()
					blocks.append(heading)
					index += 1
				} else if Self.isRule(trimmed) {
					flush()
					blocks.append(.rule)
					index += 1
				} else if trimmed.hasPrefix(">") {
					flush()
					quote()
				} else if Self.listItem(line) != nil {
					flush()
					list()
				} else if trimmed.hasPrefix("|"), index + 1 < lines.count, Self.isTableSeparator(lines[index + 1]) {
					flush()
					table()
				} else {
					paragraph.append(trimmed)
					index += 1
				}
			}
			flush()
			return blocks
		}

		mutating func flush() {
			guard !paragraph.isEmpty else { return }
			blocks.append(.paragraph(paragraph.joined(separator: "\n")))
			paragraph = []
		}

		mutating func code(fence: (marker: String, language: String?)) {
			index += 1
			var body: [String] = []
			var closed = false
			while index < lines.count {
				let line = lines[index]
				index += 1
				if line.trimmingCharacters(in: .whitespaces).hasPrefix(fence.marker) {
					closed = true
					break
				}
				body.append(line)
			}
			blocks.append(.code(language: fence.language, code: body.joined(separator: "\n"), closed: closed))
		}

		mutating func quote() {
			var body: [String] = []
			while index < lines.count {
				let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
				guard trimmed.hasPrefix(">") else { break }
				body.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
				index += 1
			}
			blocks.append(.quote(body.joined(separator: "\n")))
		}

		mutating func list() {
			var items: [MarkdownBlock.ListItem] = []
			var indents: [Int] = []
			while index < lines.count {
				let line = lines[index]
				if let item = Self.listItem(line) {
					while let last = indents.last, item.indent < last { indents.removeLast() }
					if indents.last.map({ item.indent > $0 }) ?? true { indents.append(item.indent) }
					items.append(.init(depth: indents.count - 1, number: item.number, checked: item.checked, text: item.text))
					index += 1
				} else if !line.trimmingCharacters(in: .whitespaces).isEmpty, line.first?.isWhitespace == true, !items.isEmpty {
					// A continuation line of the previous item.
					items[items.count - 1].text += "\n" + line.trimmingCharacters(in: .whitespaces)
					index += 1
				} else if line.trimmingCharacters(in: .whitespaces).isEmpty, index + 1 < lines.count, Self.listItem(lines[index + 1]) != nil {
					// A blank line between items keeps the list going.
					index += 1
				} else {
					break
				}
			}
			blocks.append(.list(items: items))
		}

		mutating func table() {
			let header = Self.cells(lines[index])
			index += 2
			var rows: [[String]] = []
			while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
				var row = Self.cells(lines[index])
				if row.count < header.count { row += Array(repeating: "", count: header.count - row.count) }
				rows.append(Array(row.prefix(header.count)))
				index += 1
			}
			blocks.append(.table(header: header, rows: rows))
		}

		static func fence(_ trimmed: String) -> (marker: String, language: String?)? {
			for marker in ["```", "~~~"] where trimmed.hasPrefix(marker) {
				let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
				return (marker, language.isEmpty ? nil : language)
			}
			return nil
		}

		static func heading(_ trimmed: String) -> MarkdownBlock? {
			let hashes = trimmed.prefix { $0 == "#" }.count
			guard (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " else { return nil }
			return .heading(level: hashes, text: trimmed.dropFirst(hashes + 1).trimmingCharacters(in: .whitespaces))
		}

		static func isRule(_ trimmed: String) -> Bool {
			let compact = trimmed.filter { !$0.isWhitespace }
			guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
			return compact.allSatisfy { $0 == first }
		}

		static func listItem(_ line: String) -> (indent: Int, number: Int?, checked: Bool?, text: String)? {
			let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
			let rest = line.drop { $0 == " " || $0 == "\t" }
			var number: Int?
			var body: Substring
			if let marker = rest.first, "-*+".contains(marker), rest.dropFirst().first == " " {
				body = rest.dropFirst(2)
			} else {
				let digits = rest.prefix { $0.isNumber }
				guard !digits.isEmpty, digits.count <= 9 else { return nil }
				let after = rest.dropFirst(digits.count)
				guard let dot = after.first, dot == "." || dot == ")", after.dropFirst().first == " " else { return nil }
				number = Int(digits)
				body = after.dropFirst(2)
			}
			var checked: Bool?
			if body.hasPrefix("[ ] ") {
				checked = false
				body = body.dropFirst(4)
			} else if body.hasPrefix("[x] ") || body.hasPrefix("[X] ") {
				checked = true
				body = body.dropFirst(4)
			}
			return (indent, number, checked, String(body))
		}

		static func isTableSeparator(_ line: String) -> Bool {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			guard trimmed.hasPrefix("|") || trimmed.hasPrefix("-") || trimmed.hasPrefix(":") else { return false }
			return trimmed.contains("-") && trimmed.allSatisfy { "|-: ".contains($0) }
		}

		static func cells(_ line: String) -> [String] {
			var trimmed = line.trimmingCharacters(in: .whitespaces)
			if trimmed.hasPrefix("|") { trimmed.removeFirst() }
			if trimmed.hasSuffix("|") { trimmed.removeLast() }
			return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
		}
	}
}
