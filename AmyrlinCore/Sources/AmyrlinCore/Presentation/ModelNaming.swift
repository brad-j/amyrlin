import Foundation

/// How the app names models and their providers. A host can offer the same model through two providers, such as
/// Claude Opus through Claude Code and through OpenRouter, so a name alone doesn't always say which runs. Model IDs
/// are opaque: OpenRouter's contain slashes ("anthropic/claude-opus-5.5", "~google/gemini-pro-latest").
public enum ModelNaming {
	/// A provider's short name: aludra's by the names its web app gives them, any other by its ID.
	public static func provider(_ id: String) -> String {
		switch id {
		case "claude-bridge": "Claude Code"
		case "openai": "OpenAI"
		case "openrouter": "OpenRouter"
		case "anthropic": "Anthropic"
		case "faux": "Faux"
		default: id
		}
	}

	/// A provider with how it's paid, as aludra's web app heads its model picker: "Claude Code · your plan".
	public static func providerHeading(_ id: String) -> String {
		switch id {
		case "claude-bridge": "Claude Code · your plan"
		case "openai": "OpenAI · your ChatGPT plan"
		case "openrouter": "OpenRouter · billed per request"
		default: provider(id)
		}
	}

	/// `ref`'s name as the host lists it, or its ID when the host doesn't list it.
	public static func name(_ ref: ModelRef, in models: [ModelInfo]) -> String {
		models.first { $0.ref == ref }?.name ?? ref.modelId
	}

	/// Whether `ref` needs its provider beside its name: the host's models come from more than one provider, or `ref`
	/// is from one they don't. False before the host has listed any.
	public static func needsProvider(_ ref: ModelRef, in models: [ModelInfo]) -> Bool {
		let providers = Set(models.map(\.provider))
		return !providers.isEmpty && (providers.count > 1 || !providers.contains(ref.provider))
	}

	/// `models` by provider, providers and models in the host's order.
	public static func byProvider(_ models: [ModelInfo]) -> [(provider: String, models: [ModelInfo])] {
		var groups: [(provider: String, models: [ModelInfo])] = []
		for model in models {
			if let index = groups.firstIndex(where: { $0.provider == model.provider }) {
				groups[index].models.append(model)
			} else {
				groups.append((model.provider, [model]))
			}
		}
		return groups
	}
}
