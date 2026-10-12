import Foundation
import Testing
@testable import AmyrlinCore

/// Every recorded scenario, converted to protocol v1 by the test-side mapper and run through the reducer.
@Suite struct FixtureReducerTests {
	@Test(arguments: Fixtures.names)
	func reducesCleanlyToAnIdleConversation(_ name: String) throws {
		let frames = try Fixtures.wireFrames(name)
		#expect(!frames.isEmpty)
		for event in frames.joined() {
			if case .unknown(let type) = event { Issue.record("\(name): mapper produced unknown event \(type)") }
		}
		let (state, outcomes) = Fixtures.reduce(frames)
		for (index, outcome) in outcomes.enumerated() where outcome != .applied {
			Issue.record("\(name): frame \(index) did not apply: \(outcome)")
		}
		#expect(state.run == nil, "\(name) ends busy")
		#expect(state.streaming == nil)
		#expect(state.tools.isEmpty, "\(name) ends with tool slots \(state.tools.map(\.callId))")
		#expect(state.inbox.isEmpty)
		#expect(state.approvals.isEmpty)
		#expect(state.compactions.isEmpty)
		#expect(state.items.map(\.id) == state.items.map(\.id).sorted())
	}

	/// Streamed text must be what the committed message says, and live tool output must be what its result holds.
	@Test(arguments: Fixtures.names)
	func liveStateMatchesWhatGetsCommitted(_ name: String) throws {
		var state = ConversationState()
		for frame in try Fixtures.wireFrames(name) {
			for event in frame {
				switch event {
				case .itemAdded(let item):
					if case .assistant(let assistant) = item.body, let streaming = state.streaming {
						for (live, final) in zip(streaming.content, assistant.content) {
							#expect(final.plainText.hasPrefix(live.plainText), "\(name): streamed \(live) is not a prefix of \(final)")
						}
					}
					if case .toolResult(let result) = item.body, let slot = state.tools.first(where: { $0.callId == result.callId }) {
						#expect(result.content.first?.plainText.hasPrefix(slot.output) ?? slot.output.isEmpty, "\(name): \(result.callId)")
					}
				default:
					break
				}
				#expect(state.apply(event) == .applied)
			}
		}
	}

	@Test func plainAnswerStreamsThinkingThenText() throws {
		let state = Fixtures.reduce(try Fixtures.wireFrames("01-plain-answer")).state
		#expect(state.items.map(\.summary) == ["user", "assistant stop"])
		guard case .assistant(let answer) = state.items[1].body else { return }
		#expect(answer.content.map(\.kind) == ["thinking", "text"])
		#expect(answer.content[1].plainText.hasPrefix("The capital of Portugal is Lisbon."))
		#expect(state.spend.total > 0)
		#expect(state.submission(requestId: "req-01")?.status == .done)
	}

	@Test func toolRoundShowsLiveOutputThenTheResult() throws {
		var state = ConversationState()
		var outputs: [String] = []
		for frame in try Fixtures.wireFrames("02-tool-round") {
			state.apply(frame)
			if let slot = state.tools.first { outputs.append(slot.output) }
		}
		#expect(outputs.first == "")
		#expect(outputs.contains("1\n2\n3\n"))
		#expect(outputs.last == "1\n2\n3\n4\n5\n")
		#expect(state.items.map(\.summary) == ["user", "assistant toolUse", "toolResult call-1", "assistant stop"])
	}

	@Test func parallelToolsFinishOutOfCallOrder() throws {
		let state = Fixtures.reduce(try Fixtures.wireFrames("03-parallel-tools")).state
		#expect(state.items.map(\.summary) == ["user", "assistant toolUse", "toolResult call-c", "toolResult call-b", "toolResult call-a", "assistant stop"])
	}

	@Test func steerJoinsTheRunningRun() throws {
		var state = ConversationState()
		var sawQueuedSteer = false
		for frame in try Fixtures.wireFrames("04-steer-during-tools") {
			state.apply(frame)
			if state.inbox.contains(where: { $0.mode == .steer && $0.requestId == "req-04b" }) { sawQueuedSteer = true }
		}
		#expect(sawQueuedSteer)
		#expect(state.items.map(\.summary) == ["user", "assistant toolUse", "toolResult call-1", "user", "assistant stop"])
		#expect(state.submission(requestId: "req-04a")?.status == .done)
		#expect(state.submission(requestId: "req-04b")?.status == .done)
	}

	@Test func followUpStartsASecondRun() throws {
		var state = ConversationState()
		var runs: [[SubmissionID]] = []
		for frame in try Fixtures.wireFrames("05-follow-up-while-busy") {
			for event in frame {
				if case .runStarted(let inputs) = event { runs.append(inputs) }
				state.apply(event)
			}
		}
		#expect(runs.count == 2)
		#expect(state.items.map(\.summary) == ["user", "assistant stop", "user", "assistant stop"])
	}

	@Test func abortMidGenerationKeepsThePartial() throws {
		let state = Fixtures.reduce(try Fixtures.wireFrames("06-abort-mid-generation")).state
		#expect(state.items.map(\.summary) == ["user", "assistant aborted"])
		let submission = state.submission(requestId: "req-06")
		#expect(submission?.status == .unanswered)
		#expect(submission?.reason == "aborted")
	}

	@Test func abortMidToolGivesAnErrorResult() throws {
		let state = Fixtures.reduce(try Fixtures.wireFrames("07-abort-mid-tool")).state
		guard case .toolResult(let result) = state.items.last?.body else {
			Issue.record("expected a tool result last")
			return
		}
		#expect(result.isError)
		#expect(result.diagnostics.map(\.code) == ["aborted"])
		#expect(result.content.first?.plainText == "1\n2\n3\n")
	}

	@Test func blockedToolNeverGetsASlot() throws {
		var state = ConversationState()
		var slotNames: Set<String> = []
		for frame in try Fixtures.wireFrames("08-blocked-tool") {
			state.apply(frame)
			slotNames.formUnion(state.tools.map(\.callId))
		}
		#expect(slotNames == ["call-ok"])
		let blocked = state.items.compactMap { item -> ToolResultItem? in
			if case .toolResult(let result) = item.body, result.callId == "call-blocked" { result } else { nil }
		}
		#expect(blocked.first?.diagnostics.map(\.code) == ["blocked"])
	}

	@Test func compactionMovesContextStartButKeepsHistory() throws {
		let state = Fixtures.reduce(try Fixtures.wireFrames("09-manual-compaction")).state
		#expect(state.contextStart == 19)
		#expect(state.items.first?.id == 7)
		#expect(!state.isInContext(7))
		#expect(state.isInContext(19))
		guard case .compaction(let compaction) = state.items.last?.body else {
			Issue.record("expected the compaction item last")
			return
		}
		#expect(compaction.reason == "manual")
		#expect(compaction.summary.contains("Plan a week in Portugal"))
	}

	@Test func crashAndResumeEndsWithAnInterruptedResult() throws {
		let frames = try Fixtures.wireFrames("11-crash-and-resume")
		let snapshots = frames.joined().filter { if case .snapshot = $0 { true } else { false } }
		#expect(snapshots.count == 2)
		let state = Fixtures.reduce(frames).state
		#expect(state.items.map(\.summary) == ["user", "assistant toolUse", "toolResult call-1", "assistant stop"])
		guard case .toolResult(let result) = state.items[2].body else { return }
		#expect(result.diagnostics.map(\.code) == ["interrupted"])
		#expect(state.submission(requestId: "req-11")?.status == .done)
	}

	@Test func approvalIsPendingUntilAnswered() throws {
		var state = ConversationState()
		var pending: [Int] = []
		for frame in try Fixtures.wireFrames("12-approval-hook") {
			state.apply(frame)
			pending.append(state.approvals.count)
		}
		#expect(pending.contains(1))
		#expect(pending.last == 0)
		#expect(state.items.map(\.summary) == ["user", "assistant toolUse", "toolResult call-1", "assistant stop"])
	}

	@Test func approvalIsRaisedAgainAfterACrash() throws {
		let events = try Fixtures.wireFrames("15-approval-crash-resume").joined()
		let requested = events.filter { if case .approvalRequested = $0 { true } else { false } }
		#expect(requested.count == 2)
		let state = Fixtures.reduce(try Fixtures.wireFrames("15-approval-crash-resume")).state
		#expect(state.submission(requestId: "req-15")?.status == .done)
	}

	@Test func abortCancelsAPendingApproval() throws {
		let events = Array(try Fixtures.wireFrames("16-approval-abort").joined())
		#expect(events.contains(.approvalResolved(ApprovalResolution(approvalId: "1:call-1", decision: .cancelled))))
		let state = Fixtures.reduce(try Fixtures.wireFrames("16-approval-abort")).state
		guard case .toolResult(let result) = state.items.last?.body else { return }
		#expect(result.diagnostics.map(\.code) == ["aborted"])
	}

	@Test func configureAndResetUpdateSettingsAndContext() throws {
		var state = ConversationState()
		var thinkingLevels: [ThinkingLevel?] = []
		for frame in try Fixtures.wireFrames("13-configure-and-reset") {
			state.apply(frame)
			thinkingLevels.append(state.settings?.stored.thinkingLevel)
		}
		#expect(thinkingLevels.contains(.high))
		#expect(state.settings?.stored.thinkingLevel == nil)
		#expect(state.settings?.stored.cwd == "/work/repo")
		#expect(state.contextStart == 12)
		guard case .reset(let reset) = state.items.first(where: { $0.id == 12 })?.body else {
			Issue.record("expected a reset item")
			return
		}
		#expect(reset.handoff == "We were planning a trip to Portugal.")
	}

	@Test func overflowSnapshotReplacesStateMidStream() throws {
		let frames = try Fixtures.wireFrames("14-overflow-snapshot")
		let laterSnapshots = frames.dropFirst().joined().filter { if case .snapshot = $0 { true } else { false } }
		#expect(laterSnapshots.count == 1)
		let state = Fixtures.reduce(frames).state
		guard case .toolResult(let result) = state.items.first(where: { $0.summary == "toolResult call-1" })?.body else {
			Issue.record("expected the count result")
			return
		}
		#expect(result.content.first?.plainText.hasSuffix("160\n") == true)
	}
}

extension ApprovalResolution {
	init(approvalId: String, decision: ApprovalDecision) {
		self.init(approvalId: approvalId, decision: decision, by: nil, message: nil)
	}
}

extension Block {
	var plainText: String {
		switch self {
		case .text(let text), .thinking(let text, _): text
		case .toolCall(let call): call.name
		default: ""
		}
	}

	var kind: String {
		switch self {
		case .text: "text"
		case .thinking: "thinking"
		case .toolCall: "toolCall"
		case .image: "image"
		case .unknown(let type): type
		}
	}
}

extension Item {
	/// A short description for comparing transcripts in tests.
	var summary: String {
		switch body {
		case .user: "user"
		case .assistant(let assistant): "assistant \(assistant.stopReason.rawValue)"
		case .toolResult(let result): "toolResult \(result.callId)"
		case .reset: "reset"
		case .compaction: "compaction"
		case .custom(let custom): "custom \(custom.kind)"
		case .unknown(let type): "unknown \(type)"
		}
	}
}
