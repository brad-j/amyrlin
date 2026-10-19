import AmyrlinCore
import SwiftUI

/// Toasts at the top right of the panes, newest at the bottom: a session out of view that needs you, finished a run or
/// got stuck. A click opens the session; × dismisses. "Needs you" shows the waiting command with deny and allow, and
/// stays until it's answered; the others go after a few seconds unless the pointer is on them.
struct ToastStack: View {
	let model: AppModel

	var body: some View {
		VStack(alignment: .trailing, spacing: 8) {
			ForEach(model.shownToasts) { toast in
				ToastView(toast: toast, model: model)
					.transition(.move(edge: .trailing).combined(with: .opacity))
			}
		}
		.animation(.row, value: model.shownToasts.map(\.id))
		.padding(.top, Metrics.bar + 10)
		.padding(.trailing, 14)
	}
}

private struct ToastView: View {
	let toast: Toast
	let model: AppModel
	@State private var hovering = false

	/// How long `.done` and `.stuck` stay.
	static let lifetime: Duration = .seconds(6)

	private var machine: AppModel.Machine? { model.machine(toast.key.machine) }
	private var summary: ConversationSummary? { machine?.store.state.conversations[toast.key.conversation] }
	/// The session's store, watched while a "needs you" toast shows so its waiting call can be answered here.
	private var conversation: ConversationStore? {
		toast.kind == .needsYou ? machine?.store.conversation(toast.key.conversation) : nil
	}
	private var approval: Approval? { conversation?.state.approvals.first }

	var body: some View {
		HStack(alignment: .firstTextBaseline, spacing: 10) {
			StateMark(mark, size: 10)
			VStack(alignment: .leading, spacing: 3) {
				Text(summary?.title ?? "A session")
					.foregroundStyle(Palette.ink)
					.lineLimit(1)
					.truncationMode(.tail)
				Text(detail)
					.font(Typography.uiSmall)
					.foregroundStyle(Palette.ink3)
					.lineLimit(2)
				if let approval, let conversation {
					answer(approval, in: conversation)
				}
			}
			Spacer(minLength: 4)
			IconButton("xmark") { model.dismissToast(toast) }
				.help("Dismiss")
		}
		.font(Typography.ui)
		.padding(.leading, 12)
		.padding(.trailing, 6)
		.padding(.vertical, 9)
		.frame(width: 320 * Typography.scale, alignment: .leading)
		.background(hovering ? Palette.paper3 : Palette.paper2)
		.overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 2) }
		.overlay(Rectangle().stroke(Palette.rule2))
		.shadow(color: .black.opacity(0.35), radius: 12, y: 4)
		.contentShape(Rectangle())
		.onTapGesture { model.openToast(toast) }
		.onHover { hovering = $0 }
		.help("Open \(summary?.title ?? "the session")")
		.task { conversation?.start() }
		// Restarts when the pointer leaves, so a toast being read stays.
		.task(id: hovering) {
			guard toast.kind != .needsYou, !hovering else { return }
			try? await Task.sleep(for: Self.lifetime)
			guard !Task.isCancelled else { return }
			model.dismissToast(toast)
		}
	}

	/// The command it waits to run, then deny and allow. The toast goes once the session no longer needs you, so a failed
	/// answer leaves it to try again; the host takes the same answer twice.
	private func answer(_ approval: Approval, in conversation: ConversationStore) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			Text("$ " + approval.command)
				.font(Typography.code)
				.foregroundStyle(Palette.ink)
				.lineLimit(2)
				.truncationMode(.tail)
				.help(approval.command)
			HStack(spacing: 8) {
				Button("deny") { answer(approval, in: conversation, approve: false) }
					.buttonStyle(QuietButton(font: Typography.uiSmall))
				Button("allow") { answer(approval, in: conversation, approve: true) }
					.buttonStyle(QuietButton(fill: Palette.wait, ink: Palette.waitInk, font: Typography.uiSmall))
			}
		}
		.padding(.top, 5)
	}

	private func answer(_ approval: Approval, in conversation: ConversationStore, approve: Bool) {
		Task { await conversation.answer(approval, approve: approve) }
	}

	private var mark: StateMark.State {
		switch toast.kind {
		case .needsYou: .waiting
		case .done: .done
		case .stuck: .failed
		}
	}

	private var color: Color {
		switch toast.kind {
		case .needsYou: Palette.wait
		case .done: Palette.add
		case .stuck: Palette.bad
		}
	}

	private var detail: String {
		model.detail(of: toast.kind, summary, on: machine)
	}
}
