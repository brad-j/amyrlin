import Foundation
import Testing
@testable import AmyrlinCore

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
	try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

@Suite struct DecodingTests {
	@Test func unknownFieldsAreIgnored() throws {
		let event = try decode(ConversationEvent.self, #"{"type":"run.started","inputs":[8],"futureField":{"x":1}}"#)
		#expect(event == .runStarted(inputs: [8]))
	}

	@Test func unknownEventTypeDecodesAsUnknown() throws {
		let event = try decode(ConversationEvent.self, #"{"type":"turn.started"}"#)
		#expect(event == .unknown(type: "turn.started"))
	}

	@Test func unknownEnumValuesAreKept() throws {
		let slot = try decode(ToolSlot.self, #"{"callId":"c","name":"bash","status":"paused"}"#)
		#expect(slot.status == .unknown("paused"))
		let summary = try decode(ConversationSummary.self, #"{"id":1,"title":"t","status":"sleeping"}"#)
		#expect(summary.status == .unknown("sleeping"))
	}

	@Test func unknownItemAndBlockTypesAreKept() throws {
		let item = try decode(Item.self, #"{"id":5,"type":"poll","content":[]}"#)
		#expect(item.body == .unknown(type: "poll"))
		let block = try decode(Block.self, #"{"type":"audio"}"#)
		#expect(block == .unknown(type: "audio"))
	}

	@Test func oneBadEventDoesNotHideTheFrame() throws {
		let frame = try decode(
			EventFrame<ConversationEvent>.self,
			#"{"type":"event","subscription":"s1","seq":3,"events":[{"type":"run.started","inputs":[1]},{"type":"tool.ended"},{"type":"run.ended","inputs":[1]}]}"#
		)
		#expect(frame.events.count == 3)
		#expect(try frame.events[0].result.get() == .runStarted(inputs: [1]))
		guard case .failure(let failure) = frame.events[1].result else {
			Issue.record("tool.ended without callId must fail to decode")
			return
		}
		#expect(failure.type == "tool.ended")
		#expect(try frame.events[2].result.get() == .runEnded(inputs: [1]))
	}

	@Test func toolUpdateDistinguishesAbsentNullAndValue() throws {
		let absent = try decode(ConversationEvent.self, #"{"type":"tool.updated","callId":"c","output":{"append":"x"}}"#)
		let cleared = try decode(ConversationEvent.self, #"{"type":"tool.updated","callId":"c","details":null,"diagnostics":[]}"#)
		guard case .toolUpdated(let a) = absent, case .toolUpdated(let b) = cleared else {
			Issue.record("expected tool.updated")
			return
		}
		#expect(a.details == .unchanged)
		#expect(a.output == .trimAppend(trimStart: 0, append: "x"))
		#expect(b.details == .cleared)
		#expect(b.diagnostics == .set([]))
	}

	@Test func projectsAndProjectFieldsDecodeWhenPresent() throws {
		let info = try decode(Commands.HostInfo.Result.self, #"{"host":{"hostId":"h","name":"aludra"},"models":[],"tools":[],"projects":[{"workspace":"egwene","name":"amyrlin","path":"Software/amyrlin","dir":"/home/brad/westwood/Projects/Software/amyrlin"}]}"#)
		#expect(info.projects?.map(\.name) == ["amyrlin"])
		let summary = try decode(ConversationSummary.self, #"{"id":7,"title":"t","project":"amyrlin","dir":"/x","workspace":"egwene"}"#)
		#expect(summary.project == "amyrlin")
		let bare = try decode(ConversationSummary.self, #"{"id":7,"title":"t"}"#)
		#expect(bare.project == nil)
	}

	@Test func settingsChangeEncodesTriState() throws {
		let change = SettingsChange(model: .set(ModelRef(provider: "p", modelId: "m")), thinkingLevel: .cleared)
		let encoder = JSONEncoder()
		encoder.outputFormatting = .sortedKeys
		let json = String(decoding: try encoder.encode(change), as: UTF8.self)
		#expect(json == #"{"model":{"modelId":"m","provider":"p"},"thinkingLevel":null}"#)
	}
}
