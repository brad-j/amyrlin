import Foundation
import Testing
@testable import AmyrlinCore

/// Runs recorded from more than one attachment point: fixture 10 before submitting, mid-tool and mid-answer, and
/// fixture 17 from the start and during its retry wait. A client that joins late must end where a client watching from
/// the start ends (protocol section 7.3).
@Suite struct ConvergenceTests {
	/// Each late joiner and the full stream of the same run.
	static let fullStreams = [
		"10-late-join": "10-late-join.full",
		"10-late-join.mid-answer": "10-late-join.full",
		"17-retry.during-wait": "17-retry",
	]
	static let joiners = fullStreams.keys.sorted()

	@Test(arguments: joiners)
	func lateJoinerReachesTheSameFinalState(_ joiner: String) throws {
		let full = Fixtures.reduce(try Fixtures.wireFrames(Self.fullStreams[joiner]!)).state
		let late = Fixtures.reduce(try Fixtures.wireFrames(joiner)).state
		#expect(late == full)
		#expect(full.items.count >= 3)
	}

	/// Stronger: at the moment the late watcher attached, its snapshot equals the full stream's state at some frame.
	/// This checks the slot omissions of section 4.5 and the streaming mapping of section 6.1, not only the end state.
	@Test(arguments: joiners)
	func lateSnapshotEqualsTheFullStreamAtTheAttachPoint(_ joiner: String) throws {
		guard case .snapshot(let snapshot)? = try Fixtures.wireFrames(joiner).first?.first else {
			Issue.record("\(joiner) must start with a snapshot")
			return
		}
		let joined = ConversationState(snapshot: snapshot).comparable
		var state = ConversationState()
		var matched = false
		for frame in try Fixtures.wireFrames(Self.fullStreams[joiner]!) {
			state.apply(frame)
			if state.comparable == joined { matched = true }
		}
		#expect(matched, "no prefix of the full stream equals the \(joiner) snapshot")
	}
}

extension ConversationState {
	/// State without the parts a snapshot cannot carry: submission events seen so far and failures.
	var comparable: ConversationState {
		var copy = self
		copy.submissions = [:]
		copy.failures = []
		return copy
	}
}
