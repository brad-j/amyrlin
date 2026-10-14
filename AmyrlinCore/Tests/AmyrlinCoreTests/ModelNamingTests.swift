import Foundation
import Testing
@testable import AmyrlinCore

/// Models from several providers, as aludra's host.info lists them once OpenRouter is signed in.
@Suite struct ModelNamingTests {
	private let models: [ModelInfo] = {
		let json = #"""
			[{"provider":"claude-bridge","modelId":"claude-opus-5-5","name":"Opus 5.5","contextWindow":1000000},
			 {"provider":"openai","modelId":"gpt-5.5","name":"GPT-5.5"},
			 {"provider":"openrouter","modelId":"anthropic/claude-opus-5.5","name":"Anthropic: Claude Opus 5.5"},
			 {"provider":"claude-bridge","modelId":"claude-sonnet-5-5","name":"Sonnet 5.5"},
			 {"provider":"openrouter","modelId":"~google/gemini-pro-latest","name":"Google: Gemini Pro Latest"}]
			"""#
		return try! JSONDecoder().decode([ModelInfo].self, from: Data(json.utf8))
	}()

	@Test func idsWithSlashesStayWhole() throws {
		let gemini = ModelRef(provider: "openrouter", modelId: "~google/gemini-pro-latest")
		#expect(models.map(\.id).contains(gemini))
		#expect(ModelNaming.name(gemini, in: models) == "Google: Gemini Pro Latest")
		let unlisted = ModelRef(provider: "openrouter", modelId: "meta-llama/llama-5")
		#expect(ModelNaming.name(unlisted, in: models) == "meta-llama/llama-5")

		let change = SettingsChange(model: .set(gemini))
		let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(change)) as? [String: Any]
		let model = encoded?["model"] as? [String: String]
		#expect(model == ["provider": "openrouter", "modelId": "~google/gemini-pro-latest"])
	}

	@Test func providersGroupInTheHostsOrder() {
		let groups = ModelNaming.byProvider(models)
		#expect(groups.map(\.provider) == ["claude-bridge", "openai", "openrouter"])
		#expect(groups[0].models.map(\.modelId) == ["claude-opus-5-5", "claude-sonnet-5-5"])
		#expect(groups[2].models.map(\.modelId) == ["anthropic/claude-opus-5.5", "~google/gemini-pro-latest"])
	}

	@Test func theProviderShowsWhenItTellsModelsApart() {
		let opus = ModelRef(provider: "claude-bridge", modelId: "claude-opus-5-5")
		#expect(ModelNaming.needsProvider(opus, in: models))
		let claudeOnly = models.filter { $0.provider == "claude-bridge" }
		#expect(!ModelNaming.needsProvider(opus, in: claudeOnly))
		#expect(ModelNaming.needsProvider(ModelRef(provider: "openrouter", modelId: "anthropic/claude-opus-5.5"), in: claudeOnly))
		#expect(!ModelNaming.needsProvider(opus, in: []), "no provider before host.info arrives")
		#expect(ModelNaming.provider("claude-bridge") == "Claude Code")
		#expect(ModelNaming.provider("mistral") == "mistral")
	}
}
