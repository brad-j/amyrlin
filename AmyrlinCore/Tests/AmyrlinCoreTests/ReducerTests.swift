import Foundation
import Testing
@testable import AmyrlinCore

/// Reducer cases the fixtures cannot show: faux never streams tool-call argument deltas or trims output.
@Suite struct ReducerTests {
	private func state(_ snapshotJSON: String = #"{"type":"snapshot","conversation":{"id":1}}"#) throws -> ConversationState {
		guard case .snapshot(let snapshot) = try event(snapshotJSON) else { throw FakeError(description: "not a snapshot") }
		return ConversationState(snapshot: snapshot)
	}

	private func event(_ json: String) throws -> ConversationEvent {
		try JSONDecoder().decode(ConversationEvent.self, from: Data(json.utf8))
	}

	@Test func trimCountsUTF16CodeUnitsLikeJavaScript() {
		// "👍" is one Character, two UTF-16 code units; "é" written as e + U+0301 is one Character, two code units.
		#expect(ConversationState.trimmingUTF16Prefix("👍ok", count: 2) == "ok")
		#expect(ConversationState.trimmingUTF16Prefix("e\u{301}x", count: 2) == "x")
		#expect(ConversationState.trimmingUTF16Prefix("abc", count: 0) == "abc")
		#expect(ConversationState.trimmingUTF16Prefix("abc", count: 9) == "")
	}

	@Test func toolOutputTrimsThenAppends() throws {
		var s = try state()
		#expect(s.apply(try event(#"{"type":"tool.started","callId":"c","name":"bash","args":{}}"#)) == .applied)
		s.apply(try event(#"{"type":"tool.updated","callId":"c","output":{"set":"👍line1\n"}}"#))
		s.apply(try event(#"{"type":"tool.updated","callId":"c","output":{"trimStart":2,"append":"line2\n"}}"#))
		#expect(s.tools.first?.output == "line1\nline2\n")
		s.apply(try event(#"{"type":"tool.updated","callId":"c","details":{"k":1}}"#))
		#expect(s.tools.first?.details == .object(["k": .number(1)]))
		s.apply(try event(#"{"type":"tool.updated","callId":"c","details":null,"diagnostics":[]}"#))
		#expect(s.tools.first?.details == nil)
	}

	@Test func toolCallArgumentsStreamByPath() throws {
		var s = try state()
		s.apply(try event(#"{"type":"stream.started","attempt":1,"content":[]}"#))
		let outcome = s.apply(try event(#"""
		{"type":"stream.delta","ops":[
		 {"op":"start","index":0,"block":{"type":"toolCall","id":"call-1","name":"bash","args":{}}},
		 {"op":"appendArg","index":0,"path":["command"],"text":"ls -"},
		 {"op":"appendArg","index":0,"path":["command"],"text":"la"},
		 {"op":"appendArg","index":0,"path":["env","HOME"],"text":"/tmp"}]}
		"""#))
		#expect(outcome == .applied)
		guard case .toolCall(let call)? = s.streaming?.content.first else {
			Issue.record("expected a streamed tool call")
			return
		}
		#expect(call.args == .object(["command": "ls -la", "env": .object(["HOME": "/tmp"])]))
	}

	@Test func assistantItemEndsTheStream() throws {
		var s = try state()
		s.apply(try event(#"{"type":"stream.started","attempt":1,"content":[{"type":"text","text":"Hel"}]}"#))
		s.apply(try event(#"{"type":"stream.delta","ops":[{"op":"appendText","index":0,"text":"lo"}]}"#))
		guard case .text(let text)? = s.streaming?.content.first else { return }
		#expect(text == "Hello")
		s.apply(try event(#"{"type":"item.added","item":{"id":11,"type":"assistant","content":[{"type":"text","text":"Hello."}],"stopReason":"stop"}}"#))
		#expect(s.streaming == nil)
		#expect(s.items.map(\.id) == [11])
	}

	@Test func impossibleChangesAskForAResync() throws {
		var s = try state()
		s.apply(try event(#"{"type":"stream.started","attempt":1,"content":[]}"#))
		let delta = s.apply(try event(#"{"type":"stream.delta","ops":[{"op":"appendText","index":3,"text":"x"}]}"#))
		#expect(delta != .applied)
		#expect(s.apply(try event(#"{"type":"tool.updated","callId":"nobody","output":{"append":"x"}}"#)) != .applied)
		#expect(s.apply(.unknown(type: "turn.started")) != .applied)
		var fresh = ConversationState()
		#expect(fresh.apply(.runStarted(inputs: [1])) != .applied, "events before the first snapshot")
	}

	@Test func itemsStayOrderedAndDeduplicated() throws {
		var s = try state()
		for id in [5, 3, 9, 3] {
			s.apply(try event(#"{"type":"item.added","item":{"id":\#(id),"type":"custom","kind":"k\#(id)"}}"#))
		}
		#expect(s.items.map(\.id) == [3, 5, 9])
	}

	@Test func historyPagesPrepend() throws {
		var s = try state(#"{"type":"snapshot","conversation":{"id":1},"hasEarlier":true,"items":[{"id":50,"type":"custom","kind":"k"}]}"#)
		let page = try JSONDecoder().decode([Item].self, from: Data(#"[{"id":10,"type":"custom","kind":"a"},{"id":20,"type":"custom","kind":"b"}]"#.utf8))
		s.prepend(history: page, hasEarlier: false)
		#expect(s.items.map(\.id) == [10, 20, 50])
		#expect(!s.hasEarlier)
	}

	@Test func runEndClearsEndedSlotsButKeepsHistory() throws {
		var s = try state()
		s.apply(try event(#"{"type":"run.started","inputs":[8]}"#))
		s.apply(try event(#"{"type":"tool.ended","callId":"lost"}"#))
		#expect(s.tools.map(\.status) == [.ended])
		s.apply(try event(#"{"type":"run.ended","inputs":[8]}"#))
		#expect(s.tools.isEmpty)
		#expect(!s.isBusy)
	}
}
