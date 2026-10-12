import AmyrlinCore
import SwiftUI

/// Model, thinking level, working directory and spend for the selected conversation.
struct InspectorView: View {
	let store: ConversationStore
	let host: HostStore
	@State private var cwd = ""

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
					Text(defaultModelLabel).tag(ModelRef?.none)
					ForEach(models) { model in
						Text(model.name ?? model.modelId).tag(ModelRef?.some(model.ref))
					}
				}
				Picker("Thinking", selection: thinkingBinding) {
					Text("Default (\(host.info?.defaults?.thinkingLevel?.rawValue ?? "host"))").tag(ThinkingLevel?.none)
					ForEach(effectiveModel?.thinkingLevels ?? ThinkingLevel.known, id: \.self) { level in
						Text(level.rawValue).tag(ThinkingLevel?.some(level))
					}
				}
				.disabled(effectiveModel?.reasoning == false)
			}
			Section("Working directory") {
				TextField("Host default", text: $cwd)
					.font(Typography.code)
					.onSubmit {
						let value = cwd.trimmingCharacters(in: .whitespaces)
						Task { await store.configure(SettingsChange(cwd: value.isEmpty ? .cleared : .set(value))) }
					}
				if let effective = settings?.effective.cwd, settings?.stored.cwd == nil {
					Text("Using \(effective)").font(Typography.readingSmall).foregroundStyle(Palette.tertiaryText)
				}
			}
			Section("Spend") {
				LabeledContent("Cost", value: store.state.spend.costText)
				LabeledContent("Tokens", value: store.state.spend.tokensText)
				LabeledContent("Cache", value: "\(store.state.spend.cacheRead.formatted()) read · \(store.state.spend.cacheWrite.formatted()) written")
				ForEach(store.state.spend.byModel.keys.sorted(), id: \.self) { key in
					LabeledContent(key, value: store.state.spend.byModel[key]?.costText ?? "")
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
		.onAppear { cwd = settings?.stored.cwd ?? "" }
		.onChange(of: settings?.stored.cwd) { _, stored in cwd = stored ?? "" }
	}

	private var defaultModelLabel: String {
		let model = host.info?.defaults?.model?.modelId ?? "host"
		return "Default (\(model))"
	}

	private var modelBinding: Binding<ModelRef?> {
		Binding(
			get: { settings?.stored.model },
			set: { value in Task { await store.configure(SettingsChange(model: value.map { .set($0) } ?? .cleared)) } }
		)
	}

	private var thinkingBinding: Binding<ThinkingLevel?> {
		Binding(
			get: { settings?.stored.thinkingLevel },
			set: { value in Task { await store.configure(SettingsChange(thinkingLevel: value.map { .set($0) } ?? .cleared)) } }
		)
	}
}
