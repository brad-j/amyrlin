import Foundation

/// The work panel's timeline (option B, 2026-11-04): what the agent did in the latest turn, in a few plain lines built
/// from its tool calls. Calls of one kind in a row merge ("read 9 files"), a bash call that runs tests or a build says
/// so with its outcome ("ran the tests: failed"), and the call still running is the last line. Times are when each
/// stretch started.
public enum WorkTimeline {
	public struct Step: Sendable, Hashable {
		public var at: Int64?
		public var text: String
		public var running: Bool
		public var failed: Bool
	}

	/// The latest turn's calls in order, from the rows the transcript lays out.
	public static func calls(_ rows: [TranscriptRow]) -> [ToolCallRow] {
		let lastUser = rows.lastIndex { if case .user = $0.kind { true } else { false } }
		let turn = lastUser.map { rows[($0 + 1)...] } ?? rows[...]
		return turn.flatMap { row -> [ToolCallRow] in
			switch row.kind {
			case .toolCall(let call): [call]
			case .toolRound(let round): round.calls
			default: []
			}
		}
	}

	public static func steps(_ calls: [ToolCallRow], times: [String: Int64] = [:]) -> [Step] {
		var steps: [Step] = []
		var group: (kind: String, paths: Set<String>, count: Int, at: Int64?)?
		func flush() {
			guard let current = group else { return }
			let files = current.paths.isEmpty ? current.count : current.paths.count
			let noun = files == 1 ? "file" : "files"
			let text = switch current.kind {
			case "read": "read \(files) \(noun)"
			case "edit": "edited \(files) \(noun)"
			case "write": "wrote \(files) \(noun)"
			case "bash": current.count == 1 ? "ran a command" : "ran \(current.count) commands"
			default: current.count == 1 ? current.kind : "\(current.kind) ×\(current.count)"
			}
			steps.append(Step(at: current.at, text: text, running: false, failed: false))
			group = nil
		}
		for call in calls {
			let running = if case .running = call.status { true } else if case .waiting = call.status { true } else { false }
			let failed = if case .failed = call.status { true } else { false }
			let at = times[call.callId]
			if call.name == "bash", let check = checkName(call.args["command"]?.stringValue ?? "") {
				flush()
				let outcome = running ? "" : failed || exitedBadly(call.output) ? ": failed" : ": passed"
				steps.append(Step(at: at, text: "ran \(check)\(outcome)", running: running, failed: failed || (!running && exitedBadly(call.output))))
				continue
			}
			if running {
				flush()
				let path = call.args["path"]?.stringValue ?? call.args["file_path"]?.stringValue
				let what = switch call.name {
				case "read": "reading \(path.map(short) ?? "a file")"
				case "edit", "write": "editing \(path.map(short) ?? "a file")"
				case "bash": "running \(firstWord(call.args["command"]?.stringValue))"
				default: call.name
				}
				steps.append(Step(at: at, text: what, running: true, failed: false))
				continue
			}
			let kind = call.name == "write" ? "edit" : call.name
			if group?.kind != kind {
				flush()
				group = (kind, [], 0, at)
			}
			group?.count += 1
			if let path = call.args["path"]?.stringValue ?? call.args["file_path"]?.stringValue { group?.paths.insert(path) }
		}
		flush()
		return steps
	}

	/// "the tests", "the build", "the type check" or "lint" for a command that is one, else nil.
	static func checkName(_ command: String) -> String? {
		let c = command.lowercased()
		if c.range(of: #"\b(pnpm|npm|yarn|bun)( run)? test\b|\bvitest\b|\bjest\b|node (--[a-z-]+ )*--test|\bpytest\b|\bcargo test\b|\bgo test\b|\bswift test\b"#, options: .regularExpression) != nil { return "the tests" }
		if c.range(of: #"\btsc\b|type-?check"#, options: .regularExpression) != nil { return "the type check" }
		if c.range(of: #"\b(pnpm|npm|yarn|bun)( run)? (build|check)\b|\bcargo build\b|\bxcodebuild\b"#, options: .regularExpression) != nil { return "the build" }
		if c.range(of: #"\blint\b|\boxlint\b|\beslint\b|\bbiome\b"#, options: .regularExpression) != nil { return "lint" }
		return nil
	}

	/// A finished command's output that says it failed, for tools that report through output, not the error flag.
	static func exitedBadly(_ output: String) -> Bool {
		output.range(of: #"(?m)^(\[ELIFECYCLE\]|error TS\d+|✗ |FAIL |npm ERR!)|exit code [1-9]|failed with exit"#, options: .regularExpression) != nil
	}

	private static func short(_ path: String) -> String {
		path.split(separator: "/").suffix(2).joined(separator: "/")
	}

	private static func firstWord(_ command: String?) -> String {
		guard let command else { return "a command" }
		let words = command.split(separator: " ").filter { !$0.contains("=") && $0 != "cd" && !$0.hasPrefix("&&") }
		return words.first.map { "`\($0)`" } ?? "a command"
	}
}
