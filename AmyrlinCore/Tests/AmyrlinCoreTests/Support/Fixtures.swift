import Foundation
@testable import AmyrlinCore

/// The recorded pi-durable streams in `fixtures/durable-1.1.0/` at the repository root.
enum Fixtures {
	static let directory = URL(fileURLWithPath: #filePath)
		.deletingLastPathComponent() // Support
		.deletingLastPathComponent() // AmyrlinCoreTests
		.deletingLastPathComponent() // Tests
		.deletingLastPathComponent() // AmyrlinCore
		.deletingLastPathComponent() // repository root
		.appending(path: "fixtures/durable-1.1.0")

	static var names: [String] {
		let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
		return files.filter { $0.hasSuffix(".jsonl") }.map { String($0.dropLast(6)) }.sorted()
	}

	static func lines(_ name: String) throws -> [JSONValue] {
		let text = try String(contentsOf: directory.appending(path: "\(name).jsonl"), encoding: .utf8)
		return try text.split(separator: "\n").map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
	}

	/// The fixture as protocol v1 frames of JSON events, as a server would send them.
	static func wireFrameJSON(_ name: String) throws -> [[JSONValue]] {
		var mapper = DurableMapper()
		return try lines(name).flatMap { try mapper.frames(for: $0) }
	}

	/// The fixture as protocol v1 frames, encoded to JSON and decoded with the app's types.
	static func wireFrames(_ name: String) throws -> [[ConversationEvent]] {
		try wireFrameJSON(name).map { frame in
			try JSONDecoder().decode([ConversationEvent].self, from: try JSONEncoder().encode(JSONValue.array(frame)))
		}
	}

	/// Reduces frames from the first snapshot on. Records every frame's outcome.
	static func reduce(_ frames: [[ConversationEvent]]) -> (state: ConversationState, outcomes: [ConversationState.Outcome]) {
		var state = ConversationState()
		var outcomes: [ConversationState.Outcome] = []
		for frame in frames { outcomes.append(state.apply(frame)) }
		return (state, outcomes)
	}
}
