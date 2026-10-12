import AmyrlinCore
import SwiftUI

/// Machines, each with its conversations and their status.
struct SidebarView: View {
	@Bindable var model: AppModel

	var body: some View {
		List(selection: $model.selection) {
			ForEach(model.machines) { machine in
				MachineSection(machine: machine, model: model)
			}
		}
		.listStyle(.sidebar)
		.safeAreaInset(edge: .bottom, spacing: 0) {
			HStack {
				Button {
					model.isAddingMachine = true
				} label: {
					Label("Add Machine", systemImage: "plus")
						.font(Typography.label)
				}
				.buttonStyle(.borderless)
				.foregroundStyle(Palette.secondaryText)
				Spacer()
			}
			.padding(.horizontal, 12)
			.padding(.vertical, 8)
		}
	}
}

private struct MachineSection: View {
	let machine: AppModel.Machine
	let model: AppModel

	private var store: HostStore { machine.store }

	var body: some View {
		Section {
			ForEach(store.state.active) { summary in
				ConversationRow(summary: summary)
					.tag(ConversationKey(machine: machine.id, conversation: summary.id))
					.contextMenu {
						Button("Archive") { Task { try? await store.setArchived(summary.id, true) } }
					}
			}
			if store.state.hasSnapshot, store.state.active.isEmpty {
				Text("No conversations")
					.font(Typography.readingSmall)
					.foregroundStyle(Palette.tertiaryText)
			}
		} header: {
			HStack(spacing: 6) {
				StatusDot(color: Palette.color(for: store.status), pulsing: !store.isConnected)
				Text(store.state.host?.name ?? store.info?.host.name ?? machine.url.host() ?? machine.url.absoluteString)
					.lineLimit(1)
				Spacer()
				Button {
					Task { await model.newConversation(on: machine) }
				} label: {
					Image(systemName: "square.and.pencil")
				}
				.buttonStyle(.borderless)
				.help("New conversation")
				.disabled(!store.isConnected)
			}
			.help(statusHelp)
			.contextMenu {
				Button("Remove Machine", role: .destructive) { model.removeMachine(machine.id) }
			}
		}
	}

	private var statusHelp: String {
		switch store.status {
		case .connected: "Connected to \(machine.url.absoluteString)"
		case .connecting: "Connecting to \(machine.url.absoluteString)"
		case .waiting(let delay, let error): "Reconnecting in \(delay.formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1)))): \(error)"
		case .failed(let reason): reason
		case .idle, .stopped: "Not connected"
		}
	}
}

private struct ConversationRow: View {
	let summary: ConversationSummary

	var body: some View {
		HStack(spacing: 8) {
			StatusDot(color: Palette.color(for: summary.status), pulsing: summary.status == .busy || summary.status == .needsApproval)
			Text(summary.title)
				.lineLimit(1)
				.truncationMode(.tail)
			Spacer(minLength: 4)
			if summary.pendingApprovals > 0 {
				Text("\(summary.pendingApprovals)")
					.font(Typography.label)
					.padding(.horizontal, 5)
					.background(Palette.approval.opacity(0.25), in: Capsule())
			}
		}
		.help(summary.status.rawValue)
	}
}
