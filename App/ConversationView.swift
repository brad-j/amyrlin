import AmyrlinCore
import SwiftUI

/// One conversation: transcript, pinned approvals, message box, and the inspector.
struct ConversationView: View {
	let store: ConversationStore
	let host: HostStore
	@Binding var showInspector: Bool

	private var summary: ConversationSummary? { host.state.conversations[store.id] }

	var body: some View {
		VStack(spacing: 0) {
			if let problem = store.problem {
				Banner(text: "Stopped watching: \(problem)", color: Palette.failure)
			} else if store.isResyncing || !host.isConnected {
				Banner(text: host.isConnected ? "Catching up…" : "Reconnecting to \(host.url.host() ?? "the server")…", color: Palette.busy)
			}
			TranscriptView(store: store)
			if !store.state.approvals.isEmpty {
				ApprovalBar(store: store)
			}
			ComposerView(store: store)
		}
		.background(Palette.background)
		.navigationTitle(summary?.title ?? store.state.conversation?.title ?? "Conversation")
		.navigationSubtitle(subtitle)
		.toolbar {
			ToolbarItemGroup(placement: .primaryAction) {
				if store.state.isBusy {
					Button {
						Task { await store.abort() }
					} label: {
						Label("Stop", systemImage: "stop.fill")
					}
					.help("Stop the run (Esc)")
				}
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

	private var subtitle: String {
		var parts: [String] = []
		if store.state.isBusy { parts.append("Working") }
		if let model = store.state.settings?.effective.model ?? summary?.model { parts.append(model.modelId) }
		return parts.joined(separator: " · ")
	}
}

private struct Banner: View {
	let text: String
	let color: Color

	var body: some View {
		Text(text)
			.font(Typography.readingSmall)
			.foregroundStyle(color)
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(.horizontal, 16)
			.padding(.vertical, 5)
			.background(color.opacity(0.10))
	}
}

/// Approvals pinned above the message box.
struct ApprovalBar: View {
	let store: ConversationStore

	var body: some View {
		VStack(spacing: 0) {
			ForEach(store.state.approvals) { approval in
				HStack(alignment: .firstTextBaseline, spacing: 10) {
					Image(systemName: "hand.raised.fill")
						.foregroundStyle(Palette.approval)
					VStack(alignment: .leading, spacing: 2) {
						Text(approval.toolName)
							.font(Typography.code.weight(.semibold))
						Text(approval.args.jsonText)
							.font(Typography.code)
							.foregroundStyle(Palette.secondaryText)
							.lineLimit(2)
							.truncationMode(.tail)
							.textSelection(.enabled)
					}
					Spacer()
					Button("Deny") { Task { await store.answer(approval, approve: false) } }
					Button("Approve") { Task { await store.answer(approval, approve: true) } }
						.buttonStyle(.borderedProminent)
						.tint(Palette.approval)
				}
				.padding(.horizontal, 16)
				.padding(.vertical, 10)
				Divider().overlay(Palette.hairline)
			}
		}
		.background(Palette.approval.opacity(0.08))
		.overlay(alignment: .top) { Divider().overlay(Palette.approval.opacity(0.4)) }
	}
}

/// Return sends (a follow-up while busy), ⌘Return steers, Esc stops the run.
struct ComposerView: View {
	let store: ConversationStore
	@State private var text = ""
	@FocusState private var focused: Bool

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			TextField(store.state.isBusy ? "Follow up, or ⌘Return to steer" : "Message", text: $text, axis: .vertical)
				.textFieldStyle(.plain)
				.font(Typography.reading)
				.lineLimit(1...10)
				.focused($focused)
				.onKeyPress(.return, phases: .down) { press in
					if press.modifiers.contains(.option) || press.modifiers.contains(.shift) { return .ignored }
					send(steer: press.modifiers.contains(.command))
					return .handled
				}
				.onKeyPress(.escape) {
					guard store.state.isBusy else { return .ignored }
					Task { await store.abort() }
					return .handled
				}
				.padding(10)
				.background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
				.overlay(RoundedRectangle(cornerRadius: 8).stroke(focused ? Palette.accent.opacity(0.5) : Palette.hairline))
			HStack(spacing: 12) {
				Text("Return sends · ⌘Return steers · ⌥Return new line · Esc stops")
				Spacer()
				if !store.state.inbox.isEmpty {
					Text("\(store.state.inbox.count) queued")
				}
			}
			.font(Typography.label)
			.foregroundStyle(Palette.tertiaryText)
			.padding(.horizontal, 2)
		}
		.padding(.horizontal, 16)
		.padding(.top, 8)
		.padding(.bottom, 10)
		.onAppear { focused = true }
	}

	private func send(steer: Bool) {
		let message = text
		guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
		text = ""
		store.send(message, whenBusy: steer ? .steer : .followUp)
	}
}
