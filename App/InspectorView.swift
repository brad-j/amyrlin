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
		ScrollView {
			VStack(alignment: .leading, spacing: 0) {
				PanelSection("Agent") {
					Row("Model") {
					Menu {
						ForEach(models) { model in
							Button(model.name ?? model.modelId) {
								Task { await store.configure(SettingsChange(model: .set(model.ref))) }
							}
						}
					} label: {
						Value(currentInfo?.name ?? currentModel?.modelId ?? "—", chevron: true)
					}
					.menuStyle(.button)
					.buttonStyle(.plain)
					.fixedSize()
					.disabled(models.isEmpty)
					}
					Row("Thinking") {
						Menu {
							ForEach(currentInfo?.thinkingLevels ?? ThinkingLevel.known, id: \.self) { level in
								Button(level.rawValue) {
									Task { await store.configure(SettingsChange(thinkingLevel: .set(level))) }
								}
							}
						} label: {
							Value(thinking?.rawValue ?? "—", chevron: true)
						}
						.menuStyle(.button)
						.buttonStyle(.plain)
						.fixedSize()
					}
				}
				if let dir = settings?.effective.cwd ?? settings?.stored.cwd {
					PanelSection(store.state.conversation?.project ?? "Project", titleColor: store.state.conversation?.project.map(Palette.project) ?? Palette.ink3) {
						Text(ConversationView.shortPath(dir))
							.font(Typography.codeSmall)
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
							.font(Typography.readingSmall)
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
						Text("Nothing sent yet").font(Typography.readingSmall).foregroundStyle(Palette.ink3)
					}
				}
				PanelSection("Usage") {
					let spend = store.state.spend
					Row("Tokens") { Value(spend.total.formatted()) }
					Row("Output") { Value(spend.output.formatted()) }
					Row("Cached") { Value(spend.cacheRead.formatted()) }
					if spend.cost > 0 { Row("Cost") { Value(spend.costText) } }
				}
				PanelSection("Context actions") {
					HStack(spacing: 8) {
						Button("Compact") { Task { await store.compact() } }
							.buttonStyle(QuietButton())
							.help("Summarize older messages so the model sees less")
						Button("New context") { Task { await store.reset() } }
							.buttonStyle(QuietButton())
							.help("Start the model from nothing; the transcript stays")
					}
				}
			}
			.padding(.horizontal, 16)
			.padding(.vertical, 8)
		}
		.background(Palette.paper)
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

private struct Row<Content: View>: View {
	let label: String
	@ViewBuilder let content: Content

	init(_ label: String, @ViewBuilder content: () -> Content) {
		self.label = label
		self.content = content()
	}

	var body: some View {
		HStack {
			Text(label).font(Typography.readingSmall).foregroundStyle(Palette.ink2)
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
			Text(text).font(Typography.readingSmall).foregroundStyle(Palette.ink).monospacedDigit()
			if chevron {
				Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Palette.ink3)
			}
		}
		.contentShape(Rectangle())
	}
}
