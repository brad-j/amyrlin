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

	/// Row IDs, with the entries inside rounds.
	private func allIDs(_ rows: [TranscriptRow]) -> [String] {
		rows.flatMap { row -> [String] in
			if case .toolRound(let round) = row.kind { [row.id] + round.entries.map(\.id) } else { [row.id] }
		}
	}

	private func round(_ rows: [TranscriptRow]) -> ToolRound? {
		for row in rows { if case .toolRound(let round) = row.kind { return round } }
		return nil
	}

	private func toolStatuses(_ rows: [TranscriptRow]) -> [String: ToolCallRow.Status] {
		var statuses: [String: ToolCallRow.Status] = [:]
		for row in rows {
			if case .toolCall(let call) = row.kind { statuses[call.callId] = call.status }
			if case .toolRound(let round) = row.kind { for call in round.calls { statuses[call.callId] = call.status } }
		}
		return statuses
	}

	@Test func toolCallGoesFromWaitingToRunningToDone() throws {
		let statuses = try rowsOverTime("02-tool-round").compactMap { toolStatuses($0)["call-1"] }
		#expect(statuses.first == .waiting)
		#expect(statuses.contains(.running))
		#expect(statuses.last == .done)
		let final = try #require(try rowsOverTime("02-tool-round").last)
		guard let call = round(final)?.calls.first(where: { $0.callId == "call-1" }) else {
			Issue.record("expected the call in its round")
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
		#expect(final.map(\.id) == ["input-req-01", "after-7-0", "after-7-1"])
		#expect(!final.contains { if case .text(_, streaming: true) = $0.kind { true } else { false } })
	}

	/// A block's row keeps its id from the first streamed delta to the stored item, so the list updates the row in
	/// place instead of replacing it (and its open state) as the stream ends.
	@Test func streamedBlocksKeepTheirRowIDs() throws {
		for name in ["01-plain-answer", "02-tool-round", "03-parallel-tools"] {
			var streamed: Set<String> = []
			let history = try rowsOverTime(name)
			for rows in history {
				for row in rows {
					switch row.kind {
					case .text(_, streaming: true), .thinking(_, _, streaming: true): streamed.insert(row.id)
					case .toolRound(let round):
						for case .thinking(let id, _, _, true) in round.entries { streamed.insert(id) }
					default: break
					}
				}
			}
			#expect(!streamed.isEmpty, "\(name) streams a block")
			let final = Set(allIDs(try #require(history.last)))
			#expect(streamed.isSubset(of: final), "\(name): \(streamed.subtracting(final)) were replaced")
		}
	}

	private func call(_ id: String) -> TranscriptRow {
		TranscriptRow(id: "call-\(id)", kind: .toolCall(ToolCallRow(callId: id, name: "bash", args: .object([:]), status: .done, output: "", result: nil)), inContext: true)
	}

	private func thought(_ id: String) -> TranscriptRow {
		TranscriptRow(id: id, kind: .thinking(id, redacted: false, streaming: false), inContext: true)
	}

	/// A run is one row from its first call on, so it folds in place. Calls that finish at once don't fold under the
	/// reader while the run goes on; they fold when it's over, and the thinking after the last call stays out of the
	/// fold.
	@Test func roundsFoldOnlyOnceTheRunIsOver() throws {
		let rows = [thought("lead"), call("a"), thought("between"), call("b"), thought("after")]
		let live = TranscriptLayout.foldRounds(rows, live: true)
		#expect(live.map(\.id) == ["lead", "round-call-a"])
		#expect(round(live)?.folded == false)
		#expect(round(live)?.entries.map(\.id) == ["call-a", "between", "call-b", "after"])
		#expect(round(TranscriptLayout.foldRounds(rows, live: false))?.folded == true)
		let answer = TranscriptRow(id: "answer", kind: .text("Done.", streaming: true), inContext: true)
		let folded = TranscriptLayout.foldRounds(rows + [answer], live: true)
		#expect(folded.map(\.id) == ["lead", "round-call-a", "answer"])
		let done = try #require(round(folded))
		#expect(done.folded)
		#expect(done.thinking == ["between"])
		#expect(done.trailing.map(\.id) == ["after"])
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
		#expect(TranscriptLayout.rows(state: state, outbox: [pending]).last?.id == "input-req-x")
	}

	@Test func finishedRoundsFoldIntoOneLine() throws {
		let last = try #require(try rowsOverTime("03-parallel-tools").last)
		let parallel = try #require(round(last))
		#expect(parallel.folded, "three finished calls fold")
		#expect(parallel.calls.map(\.callId) == ["call-a", "call-b", "call-c"])
		#expect(parallel.summary == "count ×2 · lookup")
		// One call doesn't fold.
		#expect(round(try #require(try rowsOverTime("02-tool-round").last))?.folded == false)
		// A round still running stays open.
		let mid = try rowsOverTime("03-parallel-tools").compactMap(round).first { $0.calls.contains { $0.status == .running } }
		#expect(mid?.folded == false)
	}

	@Test func roundSummaryNamesTheCodingTools() {
		let calls = ["bash", "read", "bash", "edit", "read", "read"].enumerated().map { index, name in
			ToolCallRow(callId: "c\(index)", name: name, args: .object([:]), status: .done, output: "", result: nil)
		}
		#expect(ToolRound(entries: calls.map(ToolRound.Entry.call), folded: true).summary == "ran 2 commands · read 3 files · edited 1 file")
	}

	@Test func rowIDsAreUnique() throws {
		for name in Fixtures.names {
			for rows in try rowsOverTime(name) {
				#expect(Set(rows.map(\.id)).count == rows.count, "\(name) has duplicate row IDs")
			}
		}
	}

	/// Only the block being written is streaming: thinking before an answer reads "thought" once the answer starts.
	@Test func onlyTheNewestStreamedBlockIsStreaming() throws {
		let history = try rowsOverTime("01-plain-answer")
		let both = try #require(history.first { rows in rows.contains { if case .text(_, streaming: true) = $0.kind { true } else { false } } })
		#expect(both.contains { if case .thinking(_, _, streaming: false) = $0.kind { true } else { false } })
		#expect(!both.contains { if case .thinking(_, _, streaming: true) = $0.kind { true } else { false } })
	}

	@Test func revealDrainsWhatArrivedInAboutAThirdOfASecond() {
		var shown = 0.0
		var t = 0.0
		while shown < 1800, t < 2 {
			shown = RevealPace.advance(shown, towards: 1800, elapsed: 1.0 / 120)
			t += 1.0 / 120
		}
		#expect(t > 0.8 && t < 1.6, "a whole block sweeps in quickly but visibly: \(t)s")
		#expect(RevealPace.advance(0, towards: 1800, elapsed: 1.0 / 120) < 60, "it starts gently")
		#expect(RevealPace.advance(10, towards: 12, elapsed: 0.1) == 12, "a few characters left go at once")
		#expect(RevealPace.advance(50, towards: 20, elapsed: 0.01) == 20, "text that shrank is shown as it is")
	}

	@MainActor @Test func theLedgerRevealsOnlyWhatArrivesAfterOpening() {
		let ledger = RevealLedger()
		#expect(ledger.shown("a", length: 40) == 40, "before priming everything shows")
		ledger.prime([("a", 40)])
		#expect(ledger.shown("a", length: 50) == 40, "an open row reveals only its growth")
		#expect(ledger.shown("b", length: 30) == 0, "a new row reveals from the start")
		ledger.record("b", 12)
		#expect(ledger.shown("b", length: 30) == 12, "a row scrolled away resumes")
	}

	/// A message sent, queued and then placed is one row throughout, whatever stage the layout sees it at.
	@Test func aMessageKeepsOneRowFromSentToPlaced() throws {
		var state = ConversationState()
		for frame in try Fixtures.wireFrames("05-follow-up-while-busy") { state.apply(frame) }
		let ids = TranscriptLayout.rows(state: state).map(\.id)
		#expect(ids.filter { $0.hasPrefix("input-") }.count >= 2, "\(ids)")
		let request = try #require(state.submissions.values.compactMap(\.requestId).first)
		let pending = PendingSend(id: request, text: "again", whenBusy: .followUp)
		let rows = TranscriptLayout.rows(state: state, outbox: [pending])
		#expect(rows.filter { $0.id == "input-\(request)" }.count == 1, "the outbox doesn't repeat a placed message")
	}
}
