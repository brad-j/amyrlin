import Foundation

// Sandbox tasks (aludra's own, protocol section 10 item 19). A host without `host.info.sandboxes` offers none of it.

/// Where a session's tools run and what they need from a person, as the host settles it per session.
public enum Approvals: OpenEnum {
	case ask, off
	case unknown(String)

	public init(rawValue: String) {
		switch rawValue {
		case "ask": self = .ask
		case "off": self = .off
		default: self = .unknown(rawValue)
		}
	}

	public var rawValue: String {
		switch self {
		case .ask: "ask"
		case .off: "off"
		case .unknown(let value): value
		}
	}
}

/// Where a ship lands: the upstream branch, or a branch of its own with a pull request.
public enum ShipTo: OpenEnum {
	case main, branch
	case unknown(String)

	public init(rawValue: String) {
		switch rawValue {
		case "main": self = .main
		case "branch": self = .branch
		default: self = .unknown(rawValue)
		}
	}

	public var rawValue: String {
		switch self {
		case .main: "main"
		case .branch: "branch"
		case .unknown(let value): value
		}
	}
}

/// What the host does with a sandbox's commits when a run ends.
public enum AfterRun: OpenEnum {
	case off, fetch, merge
	case unknown(String)

	public init(rawValue: String) {
		switch rawValue {
		case "off": self = .off
		case "fetch": self = .fetch
		case "merge": self = .merge
		default: self = .unknown(rawValue)
		}
	}

	public var rawValue: String {
		switch self {
		case .off: "off"
		case .fetch: "fetch"
		case .merge: "merge"
		case .unknown(let value): value
		}
	}
}

/// `host.info.sandboxes`: present only on a host with a sandbox host.
public struct SandboxDefaults: Decodable, Sendable, Hashable {
	public var shipTo: ShipTo
	public var afterRun: AfterRun
	public var approvals: Approvals

	public init(from decoder: any Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		shipTo = try c.decodeIfPresent(ShipTo.self, forKey: .shipTo) ?? .main
		afterRun = try c.decodeIfPresent(AfterRun.self, forKey: .afterRun) ?? .fetch
		approvals = try c.decodeIfPresent(Approvals.self, forKey: .approvals) ?? .off
	}

	private enum CodingKeys: String, CodingKey { case shipTo, afterRun, approvals }
}

/// A project's checkout on its host, as last read: never fetched to work out, so `behind` is as of the last fetch.
public struct Checkout: Decodable, Sendable, Hashable {
	/// The checked-out branch; nil when detached or outside git.
	public var branch: String?
	/// Uncommitted paths, untracked ones included. They stay behind when a sandbox starts.
	public var dirty: Int
	public var ahead: Int
	public var behind: Int
	public var upstream: String?
	/// Nil when a sandbox can start from it, or why it can't ("it isn't in git").
	public var sandboxRefusal: String?

	public var takesSandboxes: Bool { sandboxRefusal == nil }

	public init(branch: String? = nil, dirty: Int = 0, ahead: Int = 0, behind: Int = 0, upstream: String? = nil, sandboxRefusal: String? = nil) {
		self.branch = branch
		self.dirty = dirty
		self.ahead = ahead
		self.behind = behind
		self.upstream = upstream
		self.sandboxRefusal = sandboxRefusal
	}

	public init(from decoder: any Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		branch = try c.decodeIfPresent(String.self, forKey: .branch)
		dirty = try c.decodeIfPresent(Int.self, forKey: .dirty) ?? 0
		ahead = try c.decodeIfPresent(Int.self, forKey: .ahead) ?? 0
		behind = try c.decodeIfPresent(Int.self, forKey: .behind) ?? 0
		upstream = try c.decodeIfPresent(String.self, forKey: .upstream)
		// `true`, or `{reason}`; anything else reads as a refusal without a reason.
		if (try? c.decode(Bool.self, forKey: .sandboxes)) == true {
			sandboxRefusal = nil
		} else if let refusal = try? c.decode([String: String].self, forKey: .sandboxes) {
			sandboxRefusal = refusal["reason"] ?? "a sandbox can't start here"
		} else {
			sandboxRefusal = "this host has no sandbox host"
		}
	}

	private enum CodingKeys: String, CodingKey { case branch, dirty, ahead, behind, upstream, sandboxes }
}

/// Where a sandbox is in its life. `paused` is informational: any tool call wakes it, so treat it as `ready`.
public enum SandboxState: OpenEnum {
	case preparing, ready, paused, failed, removed
	case unknown(String)

	public init(rawValue: String) {
		switch rawValue {
		case "preparing": self = .preparing
		case "ready": self = .ready
		case "paused": self = .paused
		case "failed": self = .failed
		case "removed": self = .removed
		default: self = .unknown(rawValue)
		}
	}

	public var rawValue: String {
		switch self {
		case .preparing: "preparing"
		case .ready: "ready"
		case .paused: "paused"
		case .failed: "failed"
		case .removed: "removed"
		case .unknown(let value): value
		}
	}
}

/// A sandbox session's sandbox, on its summary.
public struct SandboxInfo: Decodable, Sendable, Hashable {
	/// The host's own count, one across projects, never reused.
	public var number: Int
	/// `sandbox/<number>` in the project's checkout.
	public var branch: String
	public var state: SandboxState
	public var approvals: Approvals
	/// The commit it started from; nil until the template is made.
	public var base: String?
	/// While preparing: `waiting`, `cloning`, `installing`, `saving` or `starting`.
	public var step: String?
	/// Attempts at one ask share a group (×3).
	public var group: String?
	/// Why it failed.
	public var reason: String?
	/// How its ships went, kept on the summary (requested of aludra; nil on a host without it): the latest that landed,
	/// or the latest that stopped since.
	public var lastShip: ShipOutcome?

	public init(from decoder: any Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		number = try c.decode(Int.self, forKey: .number)
		branch = try c.decodeIfPresent(String.self, forKey: .branch) ?? "sandbox/\(number)"
		state = try c.decodeIfPresent(SandboxState.self, forKey: .state) ?? .ready
		approvals = try c.decodeIfPresent(Approvals.self, forKey: .approvals) ?? .off
		base = try c.decodeIfPresent(String.self, forKey: .base)
		step = try c.decodeIfPresent(String.self, forKey: .step)
		group = try c.decodeIfPresent(String.self, forKey: .group)
		reason = try c.decodeIfPresent(String.self, forKey: .reason)
		if let stopped = try c.decodeIfPresent(StoppedShip.self, forKey: .shipStopped) {
			lastShip = .stopped(kind: stopped.kind, reason: stopped.reason ?? "")
		} else if let shipped = try c.decodeIfPresent(LandedShip.self, forKey: .shipped) {
			lastShip = .shipped(to: shipped.to ?? .main, pushed: shipped.pushed ?? "", head: shipped.head ?? "", commits: shipped.commits ?? 0, pr: shipped.pr)
		}
	}

	private struct LandedShip: Decodable {
		var to: ShipTo?
		var pushed: String?
		var head: String?
		var commits: Int?
		var pr: String?
	}

	private struct StoppedShip: Decodable {
		var kind: ShipOutcome.FailureKind
		var reason: String?
	}

	private enum CodingKeys: String, CodingKey { case number, branch, state, approvals, base, step, group, reason, shipped, shipStopped }
}

// MARK: - Results

/// What a turn did, in plain words for someone who uses the project (`task.result`). During a run only `at` and `plan`
/// are set.
public struct TaskResult: Decodable, Sendable, Hashable {
	public struct HeadsUp: Decodable, Sendable, Hashable {
		/// `upstream`, `dependency`, `left` or `other`.
		public var kind: String
		public var text: String
	}

	public struct Check: Decodable, Sendable, Hashable {
		public var name: String
		public var ok: Bool
		/// The end of a failing check's output.
		public var detail: String?
	}

	public struct Shot: Decodable, Sendable, Hashable, Identifiable {
		public enum Side: OpenEnum {
			case before, after
			case unknown(String)

			public init(rawValue: String) {
				switch rawValue {
				case "before": self = .before
				case "after": self = .after
				default: self = .unknown(rawValue)
				}
			}

			public var rawValue: String {
				switch self {
				case .before: "before"
				case .after: "after"
				case .unknown(let value): value
				}
			}
		}

		public var id: String
		public var label: String
		public var side: Side
		public var path: String?
	}

	public struct Code: Decodable, Sendable, Hashable {
		public var commits: Int
		public var files: Int
		public var add: Int
		public var del: Int

		public static let zero = Code(commits: 0, files: 0, add: 0, del: 0)

		public init(commits: Int, files: Int, add: Int, del: Int) {
			self.commits = commits
			self.files = files
			self.add = add
			self.del = del
		}
	}

	public struct Step: Decodable, Sendable, Hashable {
		public var text: String
		public var done: Bool
	}

	public struct Question: Decodable, Sendable, Hashable {
		public var text: String
		public var why: String?
		public var options: [String]

		public init(from decoder: any Decoder) throws {
			let c = try decoder.container(keyedBy: CodingKeys.self)
			text = try c.decode(String.self, forKey: .text)
			why = try c.decodeIfPresent(String.self, forKey: .why)
			options = try c.decodeIfPresent([String].self, forKey: .options) ?? []
		}

		private enum CodingKeys: String, CodingKey { case text, why, options }
	}

	public var at: Int64
	/// Nil while a run goes on.
	public var summary: String?
	public var changes: [String]
	public var headsUp: [HeadsUp]
	public var checks: [Check]
	public var shots: [Shot]
	public var code: Code
	/// The agent's checklist; `[]` during a run until it writes one, nil when it never did.
	public var plan: [Step]?
	public var question: Question?

	/// True for the plan-only shape `task.result` returns while a run goes on.
	public var isRunning: Bool { summary == nil }

	public init(from decoder: any Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		at = try c.decodeIfPresent(Int64.self, forKey: .at) ?? 0
		summary = try c.decodeIfPresent(String.self, forKey: .summary)
		changes = try c.decodeIfPresent([String].self, forKey: .changes) ?? []
		headsUp = try c.decodeIfPresent([HeadsUp].self, forKey: .headsUp) ?? []
		checks = try c.decodeIfPresent([Check].self, forKey: .checks) ?? []
		shots = try c.decodeIfPresent([Shot].self, forKey: .shots) ?? []
		code = try c.decodeIfPresent(Code.self, forKey: .code) ?? .zero
		plan = try c.decodeIfPresent([Step].self, forKey: .plan)
		question = try c.decodeIfPresent(Question.self, forKey: .question)
	}

	private enum CodingKeys: String, CodingKey { case at, summary, changes, headsUp, checks, shots, code, plan, question }
}

/// How a ship ended, from the `sandbox.shipped` event on `host.watch`.
public enum ShipOutcome: Sendable, Hashable {
	public enum FailureKind: OpenEnum {
		/// The run didn't end with SHIP-READY: it asks something, was stopped, or its model failed.
		case blocked
		/// The push was refused because the upstream moved; ship again.
		case upstreamMoved
		/// git or gh couldn't do it against the upstream.
		case pushFailed
		/// The host's own checks before pushing: files left uncommitted, nothing to ship, no upstream.
		case checkFailed
		case unknown(String)

		public init(rawValue: String) {
			switch rawValue {
			case "blocked": self = .blocked
			case "upstream_moved": self = .upstreamMoved
			case "push_failed": self = .pushFailed
			case "check_failed": self = .checkFailed
			default: self = .unknown(rawValue)
			}
		}

		public var rawValue: String {
			switch self {
			case .blocked: "blocked"
			case .upstreamMoved: "upstream_moved"
			case .pushFailed: "push_failed"
			case .checkFailed: "check_failed"
			case .unknown(let value): value
			}
		}
	}

	/// `to` is the mode; `pushed` the remote branch (`origin/main`).
	case shipped(to: ShipTo, pushed: String, head: String, commits: Int, pr: String?)
	case stopped(kind: FailureKind, reason: String)
}

public struct ShipEvent: Sendable, Hashable {
	public init(conversationId: ConversationID, outcome: ShipOutcome) {
		self.conversationId = conversationId
		self.outcome = outcome
	}

	public var conversationId: ConversationID
	public var outcome: ShipOutcome
}

extension ShipEvent: Decodable {
	public init(from decoder: any Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		conversationId = try c.decode(ConversationID.self, forKey: .conversationId)
		if try c.decodeIfPresent(Bool.self, forKey: .shipped) == true {
			outcome = .shipped(
				to: try c.decodeIfPresent(ShipTo.self, forKey: .to) ?? .main,
				pushed: try c.decodeIfPresent(String.self, forKey: .pushed) ?? "",
				head: try c.decodeIfPresent(String.self, forKey: .head) ?? "",
				commits: try c.decodeIfPresent(Int.self, forKey: .commits) ?? 0,
				pr: try c.decodeIfPresent(String.self, forKey: .pr)
			)
		} else {
			outcome = .stopped(
				kind: try c.decodeIfPresent(ShipOutcome.FailureKind.self, forKey: .kind) ?? .blocked,
				reason: try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
			)
		}
	}

	private enum CodingKeys: String, CodingKey { case conversationId, shipped, to, pushed, head, commits, pr, kind, reason }
}

/// What `sandbox.sync` brought home.
public struct SyncResult: Decodable, Sendable, Hashable {
	public var branch: String
	public var head: String?
	/// Commits new on the branch.
	public var commits: Int
	/// Files left uncommitted in the sandbox, counted and not fetched.
	public var uncommitted: Int
	/// Only with `merge`: nil when the fast-forward happened, or why it didn't.
	public var mergeRefusal: String?
	public var merged: Bool

	public init(from decoder: any Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		branch = try c.decode(String.self, forKey: .branch)
		head = try c.decodeIfPresent(String.self, forKey: .head)
		commits = try c.decodeIfPresent(Int.self, forKey: .commits) ?? 0
		uncommitted = try c.decodeIfPresent(Int.self, forKey: .uncommitted) ?? 0
		if (try? c.decode(Bool.self, forKey: .merged)) == true {
			merged = true
			mergeRefusal = nil
		} else {
			merged = false
			mergeRefusal = (try? c.decode([String: String].self, forKey: .merged))?["reason"]
		}
	}

	private enum CodingKeys: String, CodingKey { case branch, head, commits, uncommitted, merged }
}

extension Commands {
	/// The latest turn's result, or the plan while a run goes on; nil before any answer.
	public struct GetTaskResult: Command {
		public static let method = "task.result"
		public static let retriesOnReconnect = true
		public struct Params: Encodable, Sendable { public var conversationId: ConversationID }
		public struct Result: Decodable, Sendable, Hashable { public var result: TaskResult? }
		public let params: Params
		public init(conversationId: ConversationID) { params = Params(conversationId: conversationId) }
	}

	/// A screenshot from a result, a base64 PNG; `not_found` once past its days.
	public struct GetTaskShot: Command {
		public static let method = "task.shot"
		public static let retriesOnReconnect = true
		public struct Params: Encodable, Sendable {
			public var conversationId: ConversationID
			public var shot: String
		}
		public typealias Result = ImageUpload
		public let params: Params
		public init(conversationId: ConversationID, shot: String) { params = Params(conversationId: conversationId, shot: shot) }
	}

	/// `sandbox/N` against its base, in the shape of `checkpoints.changes`.
	public struct TaskCode: Command {
		public static let method = "task.code"
		public static let retriesOnReconnect = true
		public struct Params: Encodable, Sendable { public var conversationId: ConversationID }
		public struct Result: Decodable, Sendable, Hashable { public var changes: Changes }
		public let params: Params
		public init(conversationId: ConversationID) { params = Params(conversationId: conversationId) }
	}

	/// One file's patch on `sandbox/N` against its base.
	public struct TaskCodeDiff: Command {
		public static let method = "task.code"
		public static let retriesOnReconnect = true
		public struct Params: Encodable, Sendable {
			public var conversationId: ConversationID
			public var path: String
		}
		public typealias Result = CheckpointDiff.Result
		public let params: Params
		public init(conversationId: ConversationID, path: String) { params = Params(conversationId: conversationId, path: path) }
	}

	/// Fetches the sandbox's commits into `sandbox/N` now, and with `merge` fast-forwards the checked-out branch when
	/// it's safe.
	public struct SyncSandbox: Command {
		public static let method = "sandbox.sync"
		public static let retriesOnReconnect = true
		public struct Params: Encodable, Sendable {
			public var conversationId: ConversationID
			public var merge: Bool?
		}
		public typealias Result = SyncResult
		public let params: Params
		public init(conversationId: ConversationID, merge: Bool = false) { params = Params(conversationId: conversationId, merge: merge ? true : nil) }
	}

	/// Starts a ship; sending it is the approval of the push. It runs as a turn and ends with `sandbox.shipped`.
	public struct ShipSandbox: Command {
		public static let method = "sandbox.ship"
		/// A second one while the first runs is `busy`, and a lost answer may have started one.
		public static let retriesOnReconnect = false
		public struct Params: Encodable, Sendable {
			public var conversationId: ConversationID
			public var to: ShipTo?
			public var note: String?
		}
		public struct Result: Decodable, Sendable, Hashable { public var started: Bool }
		public let params: Params
		public init(conversationId: ConversationID, to: ShipTo? = nil, note: String? = nil) {
			params = Params(conversationId: conversationId, to: to, note: note)
		}
	}

	/// Deletes the local `sandbox/N`, unmerged commits and all; the sandbox stays.
	public struct DiscardSandbox: Command {
		public static let method = "sandbox.discard"
		public static let retriesOnReconnect = true
		public struct Params: Encodable, Sendable { public var conversationId: ConversationID }
		public struct Result: Decodable, Sendable, Hashable {
			public var branch: String
			public var deleted: Bool
		}
		public let params: Params
		public init(conversationId: ConversationID) { params = Params(conversationId: conversationId) }
	}

	/// Archives a group's other attempts, which removes their sandboxes and branches.
	public struct KeepInGroup: Command {
		public static let method = "group.keep"
		public static let retriesOnReconnect = true
		public struct Params: Encodable, Sendable {
			public var group: String
			public var conversationId: ConversationID
		}
		public struct Result: Decodable, Sendable, Hashable { public var archived: [ConversationID] }
		public let params: Params
		public init(group: String, conversationId: ConversationID) { params = Params(group: group, conversationId: conversationId) }
	}
}
