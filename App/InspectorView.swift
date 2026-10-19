import AmyrlinCore
import SwiftUI

/// The session's model, thinking, project, context and usage, in the transcript's quiet style: labels in small caps,
/// values in ink, hairlines between groups.
struct InspectorView: View {
	let store: ConversationStore
	let host: HostStore

	private var settings: ConversationSettings? { store.state.settings }
	private var models: [ModelInfo] { host.info?.models ?? [] }
	private var currentModel: ModelRef? { settings?.stored.model ?? settings?.effective.model }
	private var currentInfo: ModelInfo? { currentModel.flatMap { ref in models.first { $0.ref == ref } } }
	private var thinking: ThinkingLevel? { settings?.stored.thinkingLevel ?? settings?.effective.thinkingLevel }

	var body: some View {
		VStack(spacing: 0) {
			HeaderBar {
				Text("session").font(Typography.label).foregroundStyle(Palette.ink3).textCase(.uppercase)
				Spacer()
			}
			ScrollView {
				VStack(alignment: .leading, spacing: 0) {
					PanelSection("Agent") {
						Row("Model") {
							Menu {
								ModelChoices(store: store, host: host)
							} label: {
								Value(currentModel.map { ModelNaming.name($0, in: models) } ?? "—", chevron: true)
							}
							.menuStyle(.button)
							.buttonStyle(.plain)
							.fixedSize()
							.disabled(models.isEmpty)
						}
						if let currentModel, ModelNaming.needsProvider(currentModel, in: models) {
							Row("Provider") { Value(ModelNaming.provider(currentModel.provider)) }
						}
						Row("Thinking") {
							Menu {
								ThinkingChoices(store: store, host: host)
							} label: {
								Value(thinking?.rawValue ?? "—", chevron: true)
							}
							.menuStyle(.button)
							.buttonStyle(.plain)
							.fixedSize()
						}
					}
					if let dir = settings?.effective.cwd ?? settings?.stored.cwd {
						PanelSection(store.state.conversation?.project ?? "scratch", titleColor: store.state.conversation?.project.map { Palette.project($0, in: host.state.projectColors) } ?? Palette.ink3) {
							Text(ConversationView.shortPath(dir))
								.font(Typography.uiSmall)
								.foregroundStyle(Palette.ink2)
								.textSelection(.enabled)
								.lineLimit(3)
						}
					}
					PanelSection("Context") {
						if let used = contextUsed, let window = currentInfo?.contextWindow, window > 0 {
							let fraction = min(1, Double(used) / Double(window))
							VStack(alignment: .leading, spacing: 6) {
								HStack {
									Text("\(ComposerView.tokens(used)) of \(ComposerView.tokens(window))")
									Spacer()
									Text(fraction.formatted(.percent.precision(.fractionLength(0))))
										.foregroundStyle(Palette.ink3)
								}
								.font(Typography.ui)
								.foregroundStyle(Palette.ink)
								.monospacedDigit()
								Capsule().fill(Palette.rule2).frame(height: 3)
									.overlay(alignment: .leading) {
										GeometryReader { proxy in
											Capsule().fill(fraction > 0.8 ? Palette.wait : Palette.ink2).frame(width: proxy.size.width * fraction)
										}
									}
							}
						} else {
							Text("Nothing sent yet").font(Typography.ui).foregroundStyle(Palette.ink3)
						}
					}
					PanelSection("Usage") {
						let spend = store.state.spend
						Row("Tokens") { Value(spend.total.formatted()) }
						Row("Output") { Value(spend.output.formatted()) }
						Row("Cached") { Value(spend.cacheRead.formatted()) }
						// What the host says was charged, never priced from the tokens: plan-paid answers cost nothing more.
						if let cost = host.state.conversations[store.id]?.cost {
							Row("Cost") { Value(Dollars.text(cost)) }
								.help("What OpenRouter billed for this session. Answers on a Claude Code or ChatGPT plan aren't counted.")
						}
					}
					if let allowed = host.state.conversations[store.id]?.alwaysAllowed, !allowed.isEmpty {
						PanelSection("Always allowed") {
							ForEach(allowed, id: \.self) { summary in
								Row(summary) {
									Button("[forget]") { forget(summary) }
										.buttonStyle(.plain)
										.font(Typography.uiSmall)
										.foregroundStyle(Palette.ink2)
										.help("Ask again before this session runs \(summary)")
								}
							}
						}
					}
					PanelSection("Context actions") {
						HStack(spacing: 8) {
							Button("compact") { Task { await store.compact() } }
								.buttonStyle(QuietButton())
								.help("Summarize older messages so the model sees less")
							Button("new context") { Task { await store.reset() } }
								.buttonStyle(QuietButton())
								.help("Start the model from nothing; the transcript stays")
						}
					}
				}
				.padding(.horizontal, 16)
				.padding(.bottom, 8)
			}
		}
		.background(Palette.panel)
	}

	private func forget(_ summary: String) {
		Task {
			do {
				try await host.forgetApproval(summary, in: store.id)
			} catch {
				store.lastError = (error as? ProtocolError)?.message ?? String(describing: error)
			}
		}
	}

	private var contextUsed: Int? {
		for item in store.state.items.reversed() {
			if case .assistant(let answer) = item.body, let spend = answer.spend, spend.input + spend.cacheRead + spend.cacheWrite > 0 {
				return spend.input + spend.cacheRead + spend.cacheWrite
			}
		}
		return nil
	}
}

/// The models a session's host offers, as menu items, under their providers when there's more than one; picking one
/// configures the session. The inspector and the status line both use it.
struct ModelChoices: View {
	let store: ConversationStore
	let host: HostStore

	var body: some View {
		let groups = ModelNaming.byProvider(host.info?.models ?? [])
		let settings = store.state.settings
		let current = settings?.stored.model ?? settings?.effective.model
		ForEach(groups, id: \.provider) { group in
			if groups.count > 1 {
				Section(ModelNaming.providerHeading(group.provider)) { items(group.models, current: current) }
			} else {
				items(group.models, current: current)
			}
		}
	}

	private func items(_ models: [ModelInfo], current: ModelRef?) -> some View {
		ForEach(models) { model in
			let name = model.name ?? model.modelId
			Button(model.ref == current ? "✓ \(name)" : name) {
				Task { await store.configure(SettingsChange(model: .set(model.ref))) }
			}
		}
	}
}

/// The thinking levels the session's model takes, as menu items.
struct ThinkingChoices: View {
	let store: ConversationStore
	let host: HostStore

	var body: some View {
		let settings = store.state.settings
		let ref = settings?.stored.model ?? settings?.effective.model
		let info = ref.flatMap { ref in host.info?.models.first { $0.ref == ref } }
		ForEach(info?.thinkingLevels ?? ThinkingLevel.known, id: \.self) { level in
			Button(level.rawValue) {
				Task { await store.configure(SettingsChange(thinkingLevel: .set(level))) }
			}
		}
	}
}

private struct Row<Content: View>: View {
	let label: String
	@ViewBuilder let content: Content

	init(_ label: String, @ViewBuilder content: () -> Content) {
		self.label = label
		self.content = content()
	}

	var body: some View {
		HStack {
			Text(label).font(Typography.ui).foregroundStyle(Palette.ink2)
			Spacer()
			content
		}
	}
}

private struct Value: View {
	let text: String
	var chevron = false

	init(_ text: String, chevron: Bool = false) {
		self.text = text
		self.chevron = chevron
	}

	var body: some View {
		HStack(spacing: 5) {
			Text(text).font(Typography.ui).foregroundStyle(Palette.ink).monospacedDigit()
			if chevron {
				Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Palette.ink3)
			}
		}
		.contentShape(Rectangle())
	}
}
