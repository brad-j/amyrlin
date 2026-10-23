import AmyrlinCore
import AppKit
import SwiftUI

/// One conversation: transcript, an approval docked above the composer, and the composer.
struct ConversationView: View {
	let store: ConversationStore
	let host: HostStore
	/// The message being written, kept while another session is shown.
	let composition: Composition
	/// Opens the rename sheet for this conversation.
	var rename: () -> Void = {}

	private var summary: ConversationSummary? { host.state.conversations[store.id] }

	var body: some View {
		VStack(spacing: 0) {
			ConversationHeader(title: summary?.title ?? store.state.conversation?.title ?? "Conversation", project: summary?.project, dir: summary?.dir, colors: host.state.projectColors, busy: store.state.isBusy, rename: rename)
			// Under the header, so the header stays in line with the side columns' bands.
			if let problem = store.problem {
				Banner(text: "Stopped watching: \(problem)", color: Palette.bad)
			} else if store.isResyncing || !host.isConnected {
				Banner(text: host.isConnected ? "Catching up" : "Reconnecting to \(host.url.host() ?? "the host")", color: Palette.wait)
			}
			FillSpace { TranscriptView(store: store) }
			VStack(spacing: 8) {
				// An approval rises in above the composer and drops away once answered, instead of popping.
				ForEach(store.state.approvals) { approval in
					ApprovalCard(approval: approval, store: store)
						.frame(maxWidth: Metrics.measure + 48)
						.padding(.horizontal, 40)
						.transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 10)), removal: .opacity.combined(with: .offset(y: 6))))
				}
				// The sidebar's toggle sits in the margin at the column's edge, level with the composer.
				ComposerView(store: store, host: host, composition: composition)
					.frame(maxWidth: Metrics.measure + 48)
					.padding(.horizontal, 40)
					.frame(maxWidth: .infinity)
					.overlay(alignment: .leading) { SidebarToggle().padding(.leading, 10) }
			}
			.padding(.top, 18)
			.padding(.bottom, 12)
			.frame(maxWidth: .infinity)
			.animation(.row, value: store.state.approvals.map(\.approvalId))
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

/// The session as a console path: `../` dim, the project in its colour, then the title.
private struct ConversationHeader: View {
	let title: String
	let project: String?
	let dir: String?
	let colors: [String: Int]
	let busy: Bool
	let rename: () -> Void

	var body: some View {
		HeaderBar {
			PathLabel(project: project, dir: dir, colors: colors)
			if busy {
				StateMark(.running, size: 10).padding(.trailing, 6)
			}
			Text(title).foregroundStyle(Palette.ink2).truncationMode(.tail)
				.onTapGesture(count: 2, perform: rename)
				.help("Double-click to rename")
			Spacer(minLength: 8)
			HStack(spacing: 6) {
				PaneCloseButton()
				InspectorToggle()
			}
		}
	}
}

/// Where a session runs, as a console path: `../` dim, then the project in its colour, then a gap before what follows.
/// Under the pointer, the dots open to the whole path. A session in no project says "scratch": its directory is a
/// scratch one, which says less.
struct PathLabel: View {
	let project: String?
	let dir: String?
	let colors: [String: Int]
	@State private var hovering = false

	var body: some View {
		HStack(spacing: 0) {
			if project == nil {
				Text("scratch").foregroundStyle(Palette.ink3)
			} else if let project, let dir {
				Text(hovering ? Self.parent(dir, project) : "../").foregroundStyle(Palette.ink3)
				Text(project).foregroundStyle(Palette.project(project, in: colors))
			}
			Text("  ")
		}
		.onHover { hovering = $0 }
	}

	/// The directory up to the project, `~/westwood/Projects/Software/`; all of it, then a slash, if it doesn't end in
	/// the project's name.
	static func parent(_ dir: String, _ project: String) -> String {
		let short = ConversationView.shortPath(dir)
		return short.hasSuffix(project) ? String(short.dropLast(project.count)) : short + "/"
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
	/// Mono's `ui` when nil.
	var font: Font?

	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.font(font ?? Typography.ui)
			.foregroundStyle(ink)
			.padding(.vertical, 5)
			.padding(.horizontal, 12)
			.background(fill ?? Palette.paper3)
			.overlay(Rectangle().stroke(fill == nil ? Palette.rule2 : .clear))
			.opacity(configuration.isPressed ? 0.75 : 1)
			.contentShape(Rectangle())
	}
}

/// A message being written and not sent: its text, its attachments, and the long pastes its markers stand for.
/// AppModel keeps one for each session and new session, so switching away and back finds it as it was left.
@MainActor @Observable
final class Composition {
	var text = ""
	let attachments = Attachments()
	@ObservationIgnored let pasted = PastedText()

	func clear() {
		text = ""
		_ = attachments.take()
		pasted.clear()
	}
}

/// The input line: `❯` then the message, in mono. Return sends (a follow-up while busy), ⇧Return adds a line,
/// ⌘Return or the steer toggle steers, Esc stops. The model, thinking and context live in the status line below.
struct ComposerView: View {
	let store: ConversationStore
	let host: HostStore
	@Bindable var composition: Composition
	@State private var steer = false
	@FocusState private var focused: Bool

	private var attachments: Attachments { composition.attachments }
	private var pasted: PastedText { composition.pasted }

	private var busy: Bool { store.state.isBusy }

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			AttachmentStrip(attachments: attachments)
			line
		}
		.promptBox(focused: focused)
		.acceptsPastes(attachments, text: pasted, focused: focused)
		.followsPaneFocus($focused)
		.onChange(of: busy) { _, now in if !now { steer = false } }
	}

	private var line: some View {
		HStack(alignment: .firstTextBaseline, spacing: 10) {
			Text("❯")
				.font(Typography.uiStrong)
				.foregroundStyle(focused ? Palette.accent : Palette.ink3)
			TextField(busy ? (steer ? "steer the run" : "queue a follow-up") : "message", text: $composition.text, axis: .vertical)
				.textFieldStyle(.plain)
				.font(Typography.ui)
				.foregroundStyle(Palette.ink)
				.lineLimit(3...12)
				.focused($focused)
				.wrapsAtItsWidth(focused: focused)
				.onKeyPress(.return, phases: .down) { press in
					if press.modifiers.contains(.option) || press.modifiers.contains(.shift) {
						insertLineBreak()
						return .handled
					}
					send(steer: press.modifiers.contains(.command) || steer)
					return .handled
				}
				.onKeyPress(.escape) {
					guard busy else { return .ignored }
					Task { await store.abort() }
					return .handled
				}
			if busy {
				// The icon says the mode: a wheel to steer, an hourglass to queue.
				IconButton(steer ? "steeringwheel" : "hourglass", color: steer ? Palette.accent : Palette.ink3) { steer.toggle() }
					.help(steer
						? "Steering: the message joins the running work after its current tool round. Click to queue instead."
						: "Queuing: the message waits for the run to finish. Click to steer instead; ⌘Return steers once.")
				IconButton("stop.circle", color: Palette.bad) { Task { await store.abort() } }
					.help("Stop the run (Esc)")
			}
			IconButton("photo.badge.plus", color: attachments.isFull ? Palette.ink3 : Palette.ink2) { attachments.pick() }
				.disabled(attachments.isFull)
				.help("Attach images; you can also drop them here or paste them (⌘V)")
			SendButton(enabled: canSend) { send(steer: steer) }
				.help("Send (Return)")
		}
	}

	private var canSend: Bool {
		!composition.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
	}

	/// The session's model as the status line names it, lowercased: `opus 5.5`, or `opus 5.5 via claude code` when the
	/// host offers models from more than one provider.
	@MainActor static func modelName(store: ConversationStore, host: HostStore) -> String? {
		let settings = store.state.settings
		guard let ref = settings?.stored.model ?? settings?.effective.model else { return nil }
		let models = host.info?.models ?? []
		let name = ModelNaming.name(ref, in: models).lowercased()
		return ModelNaming.needsProvider(ref, in: models) ? "\(name) via \(ModelNaming.provider(ref.provider).lowercased())" : name
	}

	/// How full the context is, as the status line says it: `ctx 24k/1M`.
	@MainActor static func contextLine(store: ConversationStore, host: HostStore) -> String? {
		guard let used = contextUsed(store) else { return nil }
		let settings = store.state.settings
		let ref = settings?.stored.model ?? settings?.effective.model
		let info = ref.flatMap { ref in host.info?.models.first { $0.ref == ref } }
		let window = info?.contextWindow.map { "/\(tokens($0))" } ?? ""
		return "ctx \(tokens(used))\(window)"
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
		let message = pasted.expand(composition.text)
		guard canSend else { return }
		let images = attachments.take()
		composition.clear()
		store.send(message, images: images, whenBusy: steer ? .steer : .followUp)
	}
}

extension View {
	/// A pane's composer takes the keyboard when the pane gains focus, and focuses the pane when it's clicked into.
	func followsPaneFocus(_ focused: FocusState<Bool>.Binding) -> some View {
		modifier(FollowsPaneFocus(focused: focused))
	}

	/// The composer's frame: a raised box with a rule, and the accent down its left edge while it has focus.
	func promptBox(focused: Bool) -> some View {
		padding(.horizontal, 12)
			.padding(.vertical, 10)
			.background(Palette.paper2)
			.overlay(Rectangle().stroke(focused ? Palette.rule2 : Palette.rule))
			.overlay(alignment: .leading) { Rectangle().fill(focused ? Palette.accent : .clear).frame(width: 2) }
	}
}

private struct FollowsPaneFocus: ViewModifier {
	let focused: FocusState<Bool>.Binding
	@Environment(AppModel.self) private var model: AppModel?
	@Environment(\.paneIndex) private var index
	@Environment(\.paneFocused) private var paneFocused

	func body(content: Content) -> some View {
		content
			.onAppear { if paneFocused { focused.wrappedValue = true } }
			.onChange(of: paneFocused) { _, now in if now { focused.wrappedValue = true } }
			.onChange(of: focused.wrappedValue) { _, now in if now { model?.focusPane(index) } }
	}
}

extension View {
	/// A multi-line field's text wraps at the field's width as it changes. The field editor's text container keeps the
	/// width it had when editing began, so when the busy buttons appear or the pane narrows the lines run under the
	/// buttons. AppKit sets up the editor afresh for each field it edits, so this lasts only while the field has it.
	func wrapsAtItsWidth(focused: Bool) -> some View {
		onChange(of: focused, initial: true) { _, now in
			guard now else { return }
			// The field editor becomes first responder after the focus changes.
			DispatchQueue.main.async {
				(NSApp.keyWindow?.firstResponder as? NSTextView)?.textContainer?.widthTracksTextView = true
			}
		}
	}
}

/// ⇧Return and ⌥Return put a line break at the cursor. Left to the field editor, ⇧Return selects instead.
@MainActor func insertLineBreak() {
	NSApp.sendAction(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil)
}

/// The composer's ↵: accent when there's something to send.
struct SendButton: View {
	let enabled: Bool
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			Text("↵")
				.font(Typography.uiStrong)
				.foregroundStyle(enabled ? Palette.accentInk : Palette.ink3)
				.frame(width: 26, height: 22)
				.background(enabled ? Palette.accent : Palette.paper3)
		}
		.buttonStyle(.plain)
		.disabled(!enabled)
	}
}
