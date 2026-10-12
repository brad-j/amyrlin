import Foundation
import Testing
@testable import AmyrlinCore

/// Frames recorded from the real server (`server/test/capture.mjs`, faux model): a plain answer, an approved bash call
/// with a queued follow-up, a settings change, an approval cancelled by abort, and a reset.
@Suite struct ServerCaptureTests {
	static let file = Fixtures.directory.deletingLastPathComponent().appending(path: "server-v1/session.jsonl")

	@Test func appReducesTheServersFrames() throws {
		let text = try String(contentsOf: Self.file, encoding: .utf8)
		let frames = try text.split(separator: "\n").map { line in
			try JSONDecoder().decode([ConversationEvent].self, from: Data(line.utf8))
		}
		var state = ConversationState()
		var sawApproval = false
		var sawQueued = false
		for (index, frame) in frames.enumerated() {
			for event in frame {
				if case .unknown(let type) = event { Issue.record("frame \(index): unknown event \(type)") }
			}
			#expect(state.apply(frame) == .applied, "frame \(index)")
			if !state.approvals.isEmpty { sawApproval = true }
			if !state.inbox.isEmpty { sawQueued = state.inbox.allSatisfy { $0.text != nil } }
		}
		#expect(sawApproval)
		#expect(sawQueued, "queued inputs carry their text")
		#expect(!state.isBusy)
		#expect(state.approvals.isEmpty)
		#expect(state.tools.isEmpty)
		#expect(state.settings?.stored.thinkingLevel == .high)
		#expect(state.settings?.effective.tools.contains("bash") == true)
		#expect(state.contextStart != nil, "the reset moved the context start")
		let results = state.items.compactMap { item -> ToolResultItem? in
			if case .toolResult(let result) = item.body { result } else { nil }
		}
		#expect(results.map(\.isError) == [false, true])
		#expect(results.last?.diagnostics.first?.code == "aborted")
		#expect(state.spend.total > 0)
	}
}
