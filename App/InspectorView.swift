import AmyrlinCore
import SwiftUI

/// Model, thinking level, working directory and spend for the selected conversation.
struct InspectorView: View {
	let store: ConversationStore
	let host: HostStore

	private var settings: ConversationSettings? { store.state.settings }
	private var models: [ModelInfo] { host.info?.models ?? [] }

	private var effectiveModel: ModelInfo? {
		guard let ref = settings?.effective.model else { return nil }
		return models.first { $0.ref == ref }
	}

	var body: some View {
		Form {
			Section("Model") {
				Picker("Model", selection: modelBinding) {
					ForEach(models) { model in
						Text(model.name ?? model.modelId).tag(ModelRef?.some(model.ref))
					}
				}
				Picker("Thinking", selection: thinkingBinding) {
					ForEach(effectiveModel?.thinkingLevels ?? ThinkingLevel.known, id: \.self) { level in
						Text(level.rawValue).tag(ThinkingLevel?.some(level))
					}
				}
				.disabled(effectiveModel?.reasoning == false)
			}
			if let dir = settings?.effective.cwd ?? settings?.stored.cwd {
				Section("Project") {
					Text(dir)
						.font(Typography.code)
						.textSelection(.enabled)
						.lineLimit(2)
						.truncationMode(.head)
				}
			}
			Section("Usage") {
				if store.state.spend.cost > 0 {
					LabeledContent("Cost", value: store.state.spend.costText)
				}
				LabeledContent("Tokens", value: store.state.spend.tokensText)
				LabeledContent("Cache", value: "\(store.state.spend.cacheRead.formatted()) read · \(store.state.spend.cacheWrite.formatted()) written")
				ForEach(store.state.spend.byModel.keys.sorted(), id: \.self) { key in
					LabeledContent(key, value: store.state.spend.byModel[key].map { $0.cost > 0 ? $0.costText : $0.total.formatted() + " tokens" } ?? "")
						.font(Typography.readingSmall)
				}
			}
			Section("Run") {
				LabeledContent("Status", value: store.state.isBusy ? "Working" : "Idle")
				if !store.state.inbox.isEmpty { LabeledContent("Queued", value: "\(store.state.inbox.count)") }
				if !store.state.compactions.isEmpty { LabeledContent("Compacting", value: "\(store.state.compactions.count)") }
				HStack {
					Button("Compact") { Task { await store.compact() } }
					Button("Reset Context") { Task { await store.reset() } }
				}
			}
		}
		.formStyle(.grouped)
		.font(Typography.readingSmall)
	}

	private var modelBinding: Binding<ModelRef?> {
		Binding(
			get: { settings?.stored.model ?? settings?.effective.model },
			set: { value in
				guard let value else { return }
				Task { await store.configure(SettingsChange(model: .set(value))) }
			}
		)
	}

	private var thinkingBinding: Binding<ThinkingLevel?> {
		Binding(
			get: { settings?.stored.thinkingLevel ?? settings?.effective.thinkingLevel },
			set: { value in
				guard let value else { return }
				Task { await store.configure(SettingsChange(thinkingLevel: .set(value))) }
			}
		)
	}
}
