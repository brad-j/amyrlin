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
			ConversationHeader(title: summary?.title ?? store.state.conversation?.title ?? "Conversation", project: summary?.project, dir: summary?.dir, busy: store.state.isBusy, showInspector: $showInspector)
			TranscriptView(store: store)
			VStack(spacing: 8) {
				ForEach(store.state.approvals) { approval in
					ApprovalCard(approval: approval, store: store)
				}
				ComposerView(store: store, host: host)
			}
			.frame(maxWidth: Metrics.measure + 48)
			.padding(.horizontal, 24)
			.padding(.bottom, 12)
			.frame(maxWidth: .infinity)
			StatusLine(store: store, host: host)
		}
		.background(Palette.paper)
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

/// The session as a console path: `~/westwood/Projects/Software/` dim, the project in its colour, then the title.
private struct ConversationHeader: View {
	let title: String
	let project: String?
	let dir: String?
	let busy: Bool
	@Binding var showInspector: Bool

	var body: some View {
		HStack(spacing: 0) {
			if let dir {
				let short = ConversationView.shortPath(dir)
				let parent = project.map { short.hasSuffix($0) ? String(short.dropLast($0.count)) : short + "/" } ?? short
				Text(parent).foregroundStyle(Palette.ink3)
				if let project { Text(project).foregroundStyle(Palette.project(project)) }
				Text("  ").foregroundStyle(Palette.ink3)
			}
			if busy {
				StateMark(.running, size: 10).padding(.trailing, 6)
			}
			Text(title).foregroundStyle(Palette.ink2).lineLimit(1).truncationMode(.tail)
			Spacer(minLength: 8)
			if !showInspector {
				Button("[inspector]") { showInspector = true }
					.buttonStyle(.plain)
					.foregroundStyle(Palette.ink3)
					.help("Show the inspector (⌥⌘I)")
			}
		}
		.font(Typography.ui)
		.lineLimit(1)
		.padding(.horizontal, 16)
		.padding(.vertical, 9)
		.overlay(alignment: .bottom) { Rectangle().fill(Palette.rule).frame(height: 1) }
	}
}

/// The bottom line, as in tmux or vim: host, model, thinking, context and the run's state.
private struct StatusLine: View {
	let store: ConversationStore
	let host: HostStore

	var body: some View {
		HStack(spacing: 0) {
			StatusDot(color: Palette.color(for: host.status), pulsing: !host.isConnected)
				.padding(.trailing, 7)
			Text(host.state.host?.name ?? host.url.host() ?? "host").foregroundStyle(Palette.ink2)
			segment(ComposerView.modelLine(store: store, host: host))
			Spacer(minLength: 8)
			if !store.state.inbox.isEmpty { segment("\(store.state.inbox.count) queued", trailing: true) }
			if !store.state.approvals.isEmpty {
				Text("needs you").foregroundStyle(Palette.wait).padding(.trailing, 14)
			}
			Text(store.state.isBusy ? "running" : "idle")
				.foregroundStyle(store.state.isBusy ? Palette.accent : Palette.ink3)
		}
		.font(Typography.uiSmall)
		.lineLimit(1)
		.padding(.horizontal, 16)
		.padding(.vertical, 5)
		.background(Palette.panel)
		.overlay(alignment: .top) { Rectangle().fill(Palette.rule).frame(height: 1) }
	}

	private func segment(_ text: String, trailing: Bool = false) -> some View {
		HStack(spacing: 0) {
			if !trailing { Text("  │  ").foregroundStyle(Palette.rule2) }
			Text(text).foregroundStyle(Palette.ink3)
			if trailing { Text("  │  ").foregroundStyle(Palette.rule2) }
		}
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
		.font(Typography.uiSmall)
		.foregroundStyle(color)
		.frame(maxWidth: .infinity)
		.padding(.vertical, 5)
		.background(Palette.paper2)
		.overlay(alignment: .bottom) { Rectangle().fill(Palette.rule).frame(height: 1) }
	}
}

/// A call waiting for Brad: an amber-edged box with what it runs, then deny and allow.
struct ApprovalCard: View {
	let approval: Approval
	let store: ConversationStore

	private var command: String {
		approval.args["command"]?.stringValue ?? approval.args.jsonText
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			HStack(spacing: 8) {
				StateMark(.waiting, size: 10)
				Text("? \(approval.toolName) wants to run").foregroundStyle(Palette.wait)
				Spacer()
			}
			.font(Typography.ui)
			.padding(.horizontal, 10)
			.padding(.vertical, 7)
			Text("$ " + command)
				.font(Typography.code)
				.foregroundStyle(Palette.ink)
				.textSelection(.enabled)
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(10)
				.background(Palette.paper)
				.overlay(alignment: .top) { Rectangle().fill(Palette.rule).frame(height: 1) }
				.overlay(alignment: .bottom) { Rectangle().fill(Palette.rule).frame(height: 1) }
			HStack(spacing: 8) {
				Spacer()
				Button("deny") { Task { await store.answer(approval, approve: false) } }
					.buttonStyle(QuietButton())
				Button("allow") { Task { await store.answer(approval, approve: true) } }
					.buttonStyle(QuietButton(fill: Palette.wait, ink: Palette.waitInk))
			}
			.padding(8)
		}
		.background(Palette.paper2)
		.overlay(Rectangle().stroke(Palette.wait.opacity(0.85)))
		.overlay(alignment: .leading) { Rectangle().fill(Palette.wait).frame(width: 2) }
	}
}

/// A flat, square button in mono: paper with a rule, or a fill colour.
struct QuietButton: ButtonStyle {
	var fill: Color?
	var ink: Color = Palette.ink

	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.font(Typography.ui)
			.foregroundStyle(ink)
			.padding(.vertical, 5)
			.padding(.horizontal, 12)
			.background(fill ?? Palette.paper3)
			.overlay(Rectangle().stroke(fill == nil ? Palette.rule2 : .clear))
			.opacity(configuration.isPressed ? 0.75 : 1)
			.contentShape(Rectangle())
	}
}

/// The input line: `❯` then the message, in mono. Return sends (a follow-up while busy), ⌘Return or the steer toggle
/// steers, Esc stops. The model, thinking and context live in the status line below.
struct ComposerView: View {
	let store: ConversationStore
	let host: HostStore
	@State private var text = ""
	@State private var steer = false
	@FocusState private var focused: Bool

	private var busy: Bool { store.state.isBusy }

	var body: some View {
		HStack(alignment: .firstTextBaseline, spacing: 10) {
			Text("❯")
				.font(Typography.uiStrong)
				.foregroundStyle(focused ? Palette.accent : Palette.ink3)
			TextField(busy ? (steer ? "steer the run" : "queue a follow-up") : "message", text: $text, axis: .vertical)
				.textFieldStyle(.plain)
				.font(Typography.ui)
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
			if busy {
				Button(steer ? "[steer]" : "[queue]") { steer.toggle() }
					.buttonStyle(.plain)
					.font(Typography.uiSmall)
					.foregroundStyle(steer ? Palette.accent : Palette.ink3)
					.help("Steer joins the running work after its current tool round; queue waits for the run to finish. ⌘Return steers once.")
				Button("[esc stop]") { Task { await store.abort() } }
					.buttonStyle(.plain)
					.font(Typography.uiSmall)
					.foregroundStyle(Palette.bad)
					.help("Stop the run (Esc)")
			}
			Button {
				send(steer: steer)
			} label: {
				Text("↵")
					.font(Typography.uiStrong)
					.foregroundStyle(canSend ? Palette.accentInk : Palette.ink3)
					.frame(width: 26, height: 22)
					.background(canSend ? Palette.accent : Palette.paper3)
			}
			.buttonStyle(.plain)
			.disabled(!canSend)
			.help("Send (Return)")
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 10)
		.background(Palette.paper2)
		.overlay(Rectangle().stroke(focused ? Palette.rule2 : Palette.rule))
		.overlay(alignment: .leading) { Rectangle().fill(focused ? Palette.accent : .clear).frame(width: 2) }
		.onAppear { focused = true }
		.onChange(of: busy) { _, now in if !now { steer = false } }
	}

	private var canSend: Bool {
		!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
	}

	/// "opus 5.5 · high · ctx 38k/1M".
	@MainActor static func modelLine(store: ConversationStore, host: HostStore) -> String {
		let settings = store.state.settings
		let ref = settings?.stored.model ?? settings?.effective.model
		let info = ref.flatMap { ref in host.info?.models.first { $0.ref == ref } }
		var parts: [String] = []
		if let ref { parts.append((info?.name ?? ref.modelId).lowercased()) }
		if let level = settings?.stored.thinkingLevel ?? settings?.effective.thinkingLevel { parts.append(level.rawValue) }
		if let used = contextUsed(store) {
			let window = info?.contextWindow.map { "/\(tokens($0))" } ?? ""
			parts.append("ctx \(tokens(used))\(window)")
		}
		return parts.joined(separator: " · ")
	}

	/// Tokens the newest answer's request sent: what the context holds now.
	@MainActor static func contextUsed(_ store: ConversationStore) -> Int? {
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
