import Foundation
import Testing
@testable import AmyrlinCore

/// Runs count up while they go, and the last one keeps its time.
@Suite struct TurnClockTests {
	@Test func aWatchedRunCountsUpThenKeepsItsTime() throws {
		var state = ConversationState()
		var turns = TurnClock()
		let start = Date(timeIntervalSince1970: 1_000_000)
		var began: Date?
		var ended: Date?
		for (index, frame) in try Fixtures.wireFrames("02-tool-round").enumerated() {
			let now = start.addingTimeInterval(TimeInterval(index))
			state.apply(frame)
			turns.observe(state, snapshot: frame.first?.isSnapshot == true, now: now)
			if state.isBusy {
				if began == nil { began = now }
				#expect(turns.started == began)
			} else if began != nil, ended == nil {
				ended = now
			}
		}
		let from = try #require(began)
		let to = try #require(ended)
		#expect(turns.started == nil)
		#expect(turns.last == to.timeIntervalSince(from))
	}

	@Test func aRunUnderwayAtTheSnapshotStartedAtItsMessage() throws {
		let frames = try Fixtures.wireFrames("10-late-join.mid-answer")
		var state = ConversationState()
		state.apply(try #require(frames.first))
		try #require(state.isBusy)
		let sent = try #require(state.items.last { if case .user = $0.body { true } else { false } }?.at)
		var turns = TurnClock()
		turns.observe(state, snapshot: true, now: Date(timeIntervalSince1970: TimeInterval(sent) / 1000 + 30))
		#expect(turns.started == Date(timeIntervalSince1970: TimeInterval(sent) / 1000))
	}

	@Test func aRunThatEndedOutOfSightHasNoTime() {
		var turns = TurnClock()
		var busy = ConversationState()
		busy.run = RunState(inputs: [])
		turns.observe(busy, snapshot: false)
		turns.observe(ConversationState(), snapshot: true)
		#expect(turns.started == nil)
		#expect(turns.last == nil)
	}

	@Test func timesReadShort() {
		#expect(TurnClock.format(8.7) == "8s")
		#expect(TurnClock.format(65) == "1m 05s")
		#expect(TurnClock.format(3720) == "1h 02m")
	}
}
