import Foundation
import Testing
@testable import AmyrlinCore

@Suite struct TranscriptLayoutTests {
	/// The rows after each frame of a fixture.
	private func rowsOverTime(_ name: String) throws -> [[TranscriptRow]] {
		var state = ConversationState()
		return try Fixtures.wireFrames(name).map { frame in
			state.apply(frame)
			return TranscriptLayout.rows(state: state)
		}
	}

	private func toolStatuses(_ rows: [TranscriptRow]) -> [String: ToolCallRow.Status] {
		var statuses: [String: ToolCallRow.Status] = [:]
		for row in rows {
			if case .toolCall(let call) = row.kind { statuses[call.callId] = call.status }
		}
		return statuses
	}

	@Test func toolCallGoesFromWaitingToRunningToDone() throws {
		let statuses = try rowsOverTime("02-tool-round").compactMap { toolStatuses($0)["call-1"] }
		#expect(statuses.first == .waiting)
		#expect(statuses.contains(.running))
		#expect(statuses.last == .done)
		let final = try #require(try rowsOverTime("02-tool-round").last)
		guard case .toolCall(let call)? = final.first(where: { $0.id == "call-call-1" })?.kind else {
			Issue.record("expected the call row")
			return
		}
		#expect(call.output == "1\n2\n3\n4\n5\n")
		#expect(call.args == .object(["n": .number(5)]))
	}

	@Test func blockedAndAbortedCallsShowTheirCode() throws {
		#expect(toolStatuses(try #require(try rowsOverTime("08-blocked-tool").last))["call-blocked"] == .failed(code: "blocked"))
		#expect(toolStatuses(try #require(try rowsOverTime("07-abort-mid-tool").last))["call-1"] == .failed(code: "aborted"))
		#expect(toolStatuses(try #require(try rowsOverTime("11-crash-and-resume").last))["call-1"] == .failed(code: "interrupted"))
	}

	@Test func pendingApprovalShowsOnTheCall() throws {
		let history = try rowsOverTime("12-approval-hook")
		#expect(history.contains { rows in
			if case .needsApproval? = toolStatuses(rows)["call-1"] { true } else { false }
		})
		#expect(toolStatuses(try #require(history.last))["call-1"] == .done)
	}

	@Test func streamedTextShowsAsStreamingThenCommitted() throws {
		let history = try rowsOverTime("01-plain-answer")
		#expect(history.contains { rows in rows.contains { if case .text(_, streaming: true) = $0.kind { true } else { false } } })
		let final = try #require(history.last)
		#expect(final.map(\.id) == ["item-7", "item-11-0", "item-11-1"])
		#expect(!final.contains { if case .text(_, streaming: true) = $0.kind { true } else { false } })
	}

	@Test func abortedAnswerEndsWithAStoppedNotice() throws {
		let final = try #require(try rowsOverTime("06-abort-mid-generation").last)
		#expect(final.last?.kind == .notice(.stopped))
	}

	@Test func compactedHistoryIsOutOfContext() throws {
		let final = try #require(try rowsOverTime("09-manual-compaction").last)
		#expect(final.first?.inContext == false)
		#expect(final.contains { if case .notice(.compaction) = $0.kind { true } else { false } })
	}

	@Test func queuedSteersAndPendingSendsFollowTheTranscript() throws {
		let history = try rowsOverTime("04-steer-during-tools")
		#expect(history.contains { rows in rows.last.map { if case .queued(let item) = $0.kind { item.mode == .steer } else { false } } ?? false })
		var state = ConversationState()
		for frame in try Fixtures.wireFrames("04-steer-during-tools") { state.apply(frame) }
		let pending = PendingSend(id: "req-x", text: "hello", whenBusy: .followUp)
		#expect(TranscriptLayout.rows(state: state, outbox: [pending]).last?.id == "pending-req-x")
	}

	@Test func rowIDsAreUnique() throws {
		for name in Fixtures.names {
			for rows in try rowsOverTime(name) {
				#expect(Set(rows.map(\.id)).count == rows.count, "\(name) has duplicate row IDs")
			}
		}
	}
}
