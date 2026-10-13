import AmyrlinCore
import SwiftUI

/// One conversation: transcript, an approval docked above the composer, and the composer.
struct ConversationView: View {
	let store: ConversationStore
	let host: HostStore
	@Binding var showInspector: Bool

	private var summary: ConversationSummary? { host.state.conversations[store.id] }

	var body: some View {
		VStack(spacing: 0) {
			if let problem = store.problem {
				Banner(text: "Stopped watching: \(problem)", color: Palette.bad)
			} else if store.isResyncing || !host.isConnected {
				Banner(text: host.isConnected ? "Catching up" : "Reconnecting to \(host.url.host() ?? "the host")", color: Palette.wait)
			}
			TranscriptView(store: store)
			VStack(spacing: 8) {
				ForEach(store.state.approvals) { approval in
					ApprovalCard(approval: approval, store: store)
				}
				ComposerView(store: store, host: host)
			}
			.frame(maxWidth: Metrics.measure + 48)
			.padding(.horizontal, 24)
			.padding(.bottom, 14)
			.frame(maxWidth: .infinity)
		}
		.background(Palette.paper)
		.navigationTitle(summary?.title ?? store.state.conversation?.title ?? "Conversation")
		.navigationSubtitle(summary?.dir.map(Self.shortPath) ?? "")
		.toolbar {
			ToolbarItemGroup(placement: .primaryAction) {
				Button {
					showInspector.toggle()
				} label: {
					Label("Inspector", systemImage: "sidebar.right")
				}
				.help("Show or hide the inspector (⌥⌘I)")
			}
		}
		.alert("Command failed", isPresented: Binding(get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil } })) {
			Button("OK") { store.lastError = nil }
		} message: {
			Text(store.lastError ?? "")
		}
		.task { store.start() }
	}

	/// `~/westwood/Projects/Software/aludra` for `/home/brad/westwood/...`.
	static func shortPath(_ dir: String) -> String {
		dir.replacingOccurrences(of: #"^/(home|Users)/[^/]+"#, with: "~", options: .regularExpression)
	}
}

private struct Banner: View {
	let text: String
	let color: Color

	var body: some View {
		HStack(spacing: 8) {
			StateMark(color == Palette.bad ? .failed : .running, size: 10)
			Text(text)
		}
		.font(Typography.readingSmall)
		.foregroundStyle(color)
		.frame(maxWidth: .infinity)
		.padding(.vertical, 5)
		.background(Palette.paper2)
		.overlay(alignment: .bottom) { Rectangle().fill(Palette.rule).frame(height: 1) }
	}
}

/// A call waiting for Brad: amber edge, what it does in a line, the whole command, Deny and Allow.
struct ApprovalCard: View {
	let approval: Approval
	let store: ConversationStore

	private var command: String {
		approval.args["command"]?.stringValue ?? approval.args.jsonText
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack(spacing: 8) {
				StateMark(.waiting, size: 11)
				Text("\(approval.toolName) wants to run")
					.font(Typography.readingSmall)
					.foregroundStyle(Palette.ink2)
				Spacer()
			}
			Text(command)
				.font(Typography.code)
				.foregroundStyle(Palette.ink)
				.textSelection(.enabled)
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(.horizontal, 12)
				.padding(.vertical, 9)
				.background(Palette.paper, in: RoundedRectangle(cornerRadius: Metrics.radiusSmall))
			HStack(spacing: 8) {
				Button {
					Task { await store.answer(approval, approve: false) }
				} label: {
					Text("Deny").frame(maxWidth: .infinity)
				}
				.buttonStyle(QuietButton())
				Button {
					Task { await store.answer(approval, approve: true) }
				} label: {
					Text("Allow").frame(maxWidth: .infinity)
				}
				.buttonStyle(QuietButton(fill: Palette.wait, ink: Palette.waitInk))
			}
		}
		.padding(12)
		.background(Palette.paper2, in: RoundedRectangle(cornerRadius: Metrics.radiusLarge))
		.overlay(RoundedRectangle(cornerRadius: Metrics.radiusLarge).stroke(Palette.wait.opacity(0.85)))
	}
}

/// A flat button: paper with a hairline, or a fill colour.
struct QuietButton: ButtonStyle {
	var fill: Color?
	var ink: Color = Palette.ink

	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.font(Typography.readingSmall.weight(.medium))
			.foregroundStyle(fill == nil ? ink : ink)
			.padding(.vertical, 7)
			.padding(.horizontal, 12)
			.background(fill ?? Palette.paper3, in: RoundedRectangle(cornerRadius: Metrics.radius))
			.overlay(RoundedRectangle(cornerRadius: Metrics.radius).stroke(fill == nil ? Palette.rule2 : .clear))
			.opacity(configuration.isPressed ? 0.75 : 1)
			.contentShape(Rectangle())
	}
}

/// The message box: Return sends (a follow-up while busy), ⌘Return or the Steer toggle steers, Esc stops.
/// Below the text, the model, thinking and how much of the context window is used; Stop while a run goes.
struct ComposerView: View {
	let store: ConversationStore
	let host: HostStore
	@State private var text = ""
	@State private var steer = false
	@FocusState private var focused: Bool

	private var busy: Bool { store.state.isBusy }

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			if !store.state.inbox.isEmpty {
				Text("\(store.state.inbox.count) queued")
					.font(Typography.label)
					.foregroundStyle(Palette.ink3)
					.padding(.horizontal, 14)
					.padding(.top, 8)
			}
			TextField(busy ? (steer ? "Steer the run" : "Queue a follow-up") : "Message", text: $text, axis: .vertical)
				.textFieldStyle(.plain)
				.font(Typography.reading)
				.foregroundStyle(Palette.ink)
				.lineLimit(1...12)
				.focused($focused)
				.onKeyPress(.return, phases: .down) { press in
					if press.modifiers.contains(.option) || press.modifiers.contains(.shift) { return .ignored }
					send(steer: press.modifiers.contains(.command) || steer)
					return .handled
				}
				.onKeyPress(.escape) {
					guard busy else { return .ignored }
					Task { await store.abort() }
					return .handled
				}
				.padding(.horizontal, 14)
				.padding(.top, 12)
				.padding(.bottom, 8)
			HStack(spacing: 10) {
				if busy {
					Button(steer ? "Steer" : "Queue") { steer.toggle() }
						.buttonStyle(.plain)
						.font(Typography.label)
						.foregroundStyle(steer ? Palette.accent : Palette.ink3)
						.help("Steer joins the running work after its current tool round; Queue waits for the run to finish. ⌘Return steers once.")
				}
				Text(modelLine)
					.font(Typography.label)
					.foregroundStyle(Palette.ink3)
					.lineLimit(1)
				Spacer()
				if busy {
					Button {
						Task { await store.abort() }
					} label: {
						HStack(spacing: 5) {
							Image(systemName: "stop.fill").font(.system(size: 8))
							Text("Stop")
						}
					}
					.buttonStyle(QuietButton())
					.help("Stop the run (Esc)")
				}
				Button {
					send(steer: steer)
				} label: {
					Image(systemName: "arrow.up")
						.font(.system(size: 12, weight: .bold))
						.foregroundStyle(canSend ? Palette.accentInk : Palette.ink3)
						.frame(width: 26, height: 26)
						.background(canSend ? Palette.accent : Palette.paper3, in: Circle())
				}
				.buttonStyle(.plain)
				.disabled(!canSend)
				.help("Send (Return)")
			}
			.padding(.horizontal, 12)
			.padding(.bottom, 10)
		}
		.background(Palette.paper2, in: RoundedRectangle(cornerRadius: Metrics.radiusLarge))
		.overlay(RoundedRectangle(cornerRadius: Metrics.radiusLarge).stroke(focused ? Palette.rule2 : Palette.rule))
		.onAppear { focused = true }
		.onChange(of: busy) { _, now in if !now { steer = false } }
	}

	private var canSend: Bool {
		!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
	}

	/// "Opus 5.5 · high · 38k of 1M".
	private var modelLine: String {
		let settings = store.state.settings
		let ref = settings?.stored.model ?? settings?.effective.model
		let info = ref.flatMap { ref in host.info?.models.first { $0.ref == ref } }
		var parts: [String] = []
		if let ref { parts.append(info?.name ?? ref.modelId) }
		if let level = settings?.stored.thinkingLevel ?? settings?.effective.thinkingLevel { parts.append(level.rawValue) }
		if let used = contextUsed {
			let window = info?.contextWindow.map { " of \(Self.tokens($0))" } ?? ""
			parts.append("\(Self.tokens(used))\(window)")
		}
		return parts.joined(separator: " · ")
	}

	/// Tokens the newest answer's request sent: what the context holds now.
	private var contextUsed: Int? {
		for item in store.state.items.reversed() {
			if case .assistant(let answer) = item.body, let spend = answer.spend, spend.input + spend.cacheRead + spend.cacheWrite > 0 {
				return spend.input + spend.cacheRead + spend.cacheWrite
			}
		}
		return nil
	}

	static func tokens(_ n: Int) -> String {
		n >= 1_000_000 ? "\(n / 1_000_000)M" : n >= 1000 ? "\(n / 1000)k" : "\(n)"
	}

	private func send(steer: Bool) {
		let message = text
		guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
		text = ""
		store.send(message, whenBusy: steer ? .steer : .followUp)
	}
}
