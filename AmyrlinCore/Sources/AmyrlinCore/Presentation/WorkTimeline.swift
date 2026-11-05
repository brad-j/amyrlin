import Foundation

/// The work panel's timeline (option B, 2026-11-04): what the agent did in the latest turn, as landmarks rather than
/// tool calls. A step of its plan marked done, a commit with its message, a check it ran and whether it passed, and the
/// files it changed, read from its edit and write calls and from shell commands that write files (`> file`,
/// `sed -i`, `tee`, `cat <<EOF > file`). What's left between landmarks merges into one quiet line ("read 9 files"), and
/// the call still running is the last line.
public enum WorkTimeline {
	public struct Step: Sendable, Hashable {
		public enum Kind: Sendable, Hashable { case stepDone, commit, check, files, other, running }
		public var at: Int64?
		public var text: String
		public internal(set) var kind: Kind
		public var running: Bool
		public var failed: Bool

		public init(at: Int64?, text: String, kind: Kind, running: Bool = false, failed: Bool = false) {
			self.at = at
			self.text = text
			self.kind = kind
			self.running = running
			self.failed = failed
		}
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

	/// The latest turn's plans as the agent wrote them, oldest first, each with the steps it had done by then.
	public static func plans(_ items: [Item]) -> [(at: Int64?, done: [String])] {
		let start = items.lastIndex { if case .user = $0.body { true } else { false } }.map { $0 + 1 } ?? 0
		return items[start...].compactMap { item in
			guard case .assistant(let answer) = item.body else { return nil }
			let text = answer.content.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined(separator: "\n")
			guard let block = text.range(of: #"```plan[ \t]*\n([\s\S]*?)(```|$)"#, options: .regularExpression) else { return nil }
			let lines = text[block].split(separator: "\n")
			let done = lines.compactMap { line -> String? in
				let trimmed = line.trimmingCharacters(in: .whitespaces)
				guard trimmed.hasPrefix("- [x]") || trimmed.hasPrefix("- [X]") else { return nil }
				return String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
			}
			return (item.at, done)
		}
	}

	/// The timeline from the latest turn: plan steps as they're marked done (from `plans`), interleaved with the calls.
	/// `dir` is the project's directory in the sandbox, which paths are shown relative to.
	public static func steps(_ calls: [ToolCallRow], plans: [(at: Int64?, done: [String])] = [], times: [String: Int64] = [:], dir: String? = nil) -> [Step] {
		func short(_ path: String) -> String { relative(path, to: dir) }
		var events: [(order: Int64, step: Step)] = []
		var seq: Int64 = 0
		func add(_ step: Step, at: Int64?) {
			seq += 1
			// Calls without a time keep their order after anything timed before them.
			events.append(((at ?? 0) * 1000 + seq, step))
		}

		// Plan steps, the first time each shows as done.
		var doneBefore: Set<String> = []
		for plan in plans {
			for step in plan.done where !doneBefore.contains(step) {
				add(Step(at: plan.at, text: step, kind: .stepDone), at: plan.at)
				doneBefore.insert(step)
			}
		}

		// Calls, with quiet ones merged between landmarks.
		var quiet: (kind: String, paths: Set<String>, count: Int, at: Int64?)?
		func flush() {
			guard let current = quiet else { return }
			let files = current.paths.isEmpty ? current.count : current.paths.count
			let noun = files == 1 ? "file" : "files"
			let text = switch current.kind {
			case "read": "read \(files) \(noun)"
			case "bash": current.count == 1 ? "ran a command" : "ran \(current.count) commands"
			default: current.count == 1 ? current.kind : "\(current.kind) ×\(current.count)"
			}
			add(Step(at: current.at, text: text, kind: .other), at: current.at)
			quiet = nil
		}
		for call in calls {
			let running = if case .running = call.status { true } else if case .waiting = call.status { true } else { false }
			let failed = if case .failed = call.status { true } else { false }
			let at = times[call.callId]
			let command = call.args["command"]?.stringValue ?? ""
			var landmarks: [Step] = []
			if call.name == "edit" || call.name == "write", let path = call.args["path"]?.stringValue ?? call.args["file_path"]?.stringValue {
				landmarks.append(Step(at: at, text: (running ? "editing " : call.name == "write" ? "wrote " : "edited ") + short(path), kind: .files, running: running))
			} else if call.name == "bash" {
				let written = writtenFiles(command)
				if !written.isEmpty {
					landmarks.append(Step(at: at, text: "wrote " + written.map(short).joined(separator: ", "), kind: .files, running: running))
				}
				if let check = checkName(command) {
					let bad = failed || exitedBadly(call.output)
					landmarks.append(Step(at: at, text: "ran \(check)" + (running ? "" : bad ? ": failed" : ": passed"), kind: .check, running: running, failed: !running && bad))
				}
				if let message = commitMessage(command), !running {
					landmarks.append(Step(at: at, text: "committed: \(message)", kind: .commit, failed: failed))
				}
				if landmarks.isEmpty, running {
					landmarks.append(Step(at: at, text: "running \(firstWord(command))", kind: .running, running: true))
				}
			} else if running {
				landmarks.append(Step(at: at, text: call.name == "read" ? "reading \(short(call.args["path"]?.stringValue ?? "a file"))" : call.name, kind: .running, running: true))
			}
			if landmarks.isEmpty {
				if quiet?.kind != call.name {
					flush()
					quiet = (call.name, [], 0, at)
				}
				quiet?.count += 1
				if let path = call.args["path"]?.stringValue ?? call.args["file_path"]?.stringValue { quiet?.paths.insert(path) }
			} else {
				flush()
				for step in landmarks { add(step, at: at) }
			}
		}
		flush()
		// With times, plan steps fall between calls; without, they follow the calls they came after in the transcript.
		// A plan step right after the commit that did it says the same thing twice; the commit stays, marked done.
		var out: [Step] = []
		for step in events.sorted(by: { $0.order < $1.order }).map(\.step) {
			if step.kind == .stepDone, let last = out.last, last.kind == .commit, similar(step.text, last.text) {
				out[out.count - 1].kind = .stepDone
				continue
			}
			out.append(step)
		}
		return out
	}

	/// Whether a plan step and a commit message are about the same thing: most of the step's longer words are in it.
	static func similar(_ step: String, _ commit: String) -> Bool {
		func words(_ text: String) -> Set<String> {
			Set(text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "." }.map(String.init).filter { $0.count > 3 })
		}
		let a = words(step)
		guard !a.isEmpty else { return false }
		return Double(a.intersection(words(commit)).count) / Double(a.count) >= 0.5
	}

	/// A path relative to the project's directory, else its last two parts.
	static func relative(_ path: String, to dir: String?) -> String {
		if let dir, !dir.isEmpty, path.hasPrefix(dir + "/") { return String(path.dropFirst(dir.count + 1)) }
		if path.hasPrefix("/") { return path.split(separator: "/").suffix(2).joined(separator: "/") }
		return path
	}

	/// The files a shell command writes: `> f`, `>> f`, `tee f`, `sed -i … f`, `cp/mv … f`, `touch f`, not /dev/null.
	public static func writtenFiles(_ command: String) -> [String] {
		var files: [String] = []
		let patterns = [
			#"(?<![0-9&>])>>?\s*['"]?([^\s'";&|<>]+)"#,
			#"\btee\s+(?:-a\s+)?['"]?([^\s'";&|<>]+)"#,
			#"\bsed\s+-i(?:\s*''|\.\w+)?\s+(?:-e\s+)?(?:'[^']*'|"[^"]*")\s+['"]?([^\s'";&|<>]+)"#,
			#"\btouch\s+['"]?([^\s'";&|<>]+)"#,
		]
		for pattern in patterns {
			guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
			for match in regex.matches(in: command, range: NSRange(command.startIndex..., in: command)) {
				guard let range = Range(match.range(at: 1), in: command) else { continue }
				let path = String(command[range])
				if path.hasPrefix("/dev/") || path.hasPrefix("&") || path.isEmpty || path.hasPrefix("$") { continue }
				if !files.contains(path) { files.append(path) }
			}
		}
		return files
	}

	/// A `git commit -m "…"` command's message, its first line.
	public static func commitMessage(_ command: String) -> String? {
		guard command.contains("git commit") else { return nil }
		let pattern = #"git commit[^;&|]*?-[a-zA-Z]*m\s+(?:"((?:[^"\\]|\\.)*)"|'([^']*)')"#
		guard let regex = try? NSRegularExpression(pattern: pattern),
			let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command))
		else { return "a commit" }
		for group in [1, 2] {
			if let range = Range(match.range(at: group), in: command) {
				return String(command[range]).replacingOccurrences(of: "\\\"", with: "\"").split(separator: "\n").first.map(String.init)
			}
		}
		return "a commit"
	}

	/// "the tests", "the build", "the type check", "lint", or a project's own test script, for a command that is one.
	static func checkName(_ command: String) -> String? {
		let c = command.lowercased()
		if c.range(of: #"\b(pnpm|npm|yarn|bun)( run)? test\b|\bvitest\b|\bjest\b|node (--[a-z-]+ )*--test|\bpytest\b|\bcargo test\b|\bgo test\b|\bswift test\b"#, options: .regularExpression) != nil { return "the tests" }
		if c.range(of: #"\btsc\b|type-?check"#, options: .regularExpression) != nil { return "the type check" }
		if c.range(of: #"\b(pnpm|npm|yarn|bun)( run)? (build|check)\b|\bcargo build\b|\bxcodebuild\b"#, options: .regularExpression) != nil { return "the build" }
		if c.range(of: #"\blint\b|\boxlint\b|\beslint\b|\bbiome\b"#, options: .regularExpression) != nil { return "lint" }
		// The project's own script: ./test.sh, ./scripts/check, bash test/run.sh.
		if let match = c.range(of: #"(?:\./|\bbash |\bsh )([\w./-]*(?:test|check)[\w./-]*)"#, options: .regularExpression) {
			let script = c[match].replacingOccurrences(of: #"^(\./|bash |sh )"#, with: "", options: .regularExpression)
			return script
		}
		return nil
	}

	/// A finished command's output that says it failed, for tools that report through output, not the error flag.
	static func exitedBadly(_ output: String) -> Bool {
		output.range(of: #"(?m)^(\[ELIFECYCLE\]|error TS\d+|✗ |FAIL\b|npm ERR!)|exit code [1-9]|failed with exit|exit [1-9]\d*\s*$"#, options: .regularExpression) != nil
	}

	private static func firstWord(_ command: String) -> String {
		let words = command.split(separator: " ").filter { !$0.contains("=") && $0 != "cd" && !$0.hasPrefix("&&") && !$0.hasPrefix("/") }
		return words.first.map { "`\($0)`" } ?? "a command"
	}
}
