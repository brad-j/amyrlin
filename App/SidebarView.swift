import AmyrlinCore
import SwiftUI

/// Machines, and on each its sessions grouped by project: the most urgent project first, project names in the accent,
/// each row a state mark, a title and an age (aludra's drawer, on a Mac sidebar).
struct SidebarView: View {
	@Bindable var model: AppModel

	var body: some View {
		List(selection: $model.selection) {
			ForEach(model.machines) { machine in
				MachineSection(machine: machine, model: model)
			}
		}
		.listStyle(.sidebar)
		.scrollContentBackground(.hidden)
		.background(Palette.paper2)
		.safeAreaInset(edge: .bottom, spacing: 0) {
			HStack {
				Button {
					model.isAddingMachine = true
				} label: {
					Label("Add Machine", systemImage: "plus")
						.font(Typography.label)
				}
				.buttonStyle(.borderless)
				.foregroundStyle(Palette.ink3)
				Spacer()
			}
			.padding(.horizontal, 14)
			.padding(.vertical, 9)
			.background(Palette.paper2)
			.overlay(alignment: .top) { Rectangle().fill(Palette.rule).frame(height: 1) }
		}
	}
}

private struct MachineSection: View {
	let machine: AppModel.Machine
	let model: AppModel

	private var store: HostStore { machine.store }

	/// Sessions by project, the project needing attention first, then the most recently active.
	private var groups: [(project: String, sessions: [ConversationSummary])] {
		let byProject = Dictionary(grouping: store.state.active) { $0.project ?? "" }
		func urgency(_ sessions: [ConversationSummary]) -> Int {
			sessions.contains { $0.status == .needsApproval } ? 0 : sessions.contains { $0.status == .busy } ? 1 : 2
		}
		return byProject
			.map { (project: $0.key, sessions: $0.value.sorted { $0.updatedAt > $1.updatedAt }) }
			.sorted { a, b in
				let (ua, ub) = (urgency(a.sessions), urgency(b.sessions))
				if ua != ub { return ua < ub }
				return (a.sessions.first?.updatedAt ?? 0) > (b.sessions.first?.updatedAt ?? 0)
			}
	}

	var body: some View {
		Section {
			ForEach(groups, id: \.project) { group in
				if !group.project.isEmpty {
					Text(group.project)
						.font(Typography.projectHeader)
						.foregroundStyle(Palette.accent)
						.padding(.top, 10)
						.padding(.bottom, 1)
						.selectionDisabled()
				}
				ForEach(group.sessions) { summary in
					SessionRow(summary: summary)
						.tag(ConversationKey(machine: machine.id, conversation: summary.id))
				}
			}
			if store.state.hasSnapshot, store.state.active.isEmpty {
				Text("No sessions yet")
					.font(Typography.readingSmall)
					.foregroundStyle(Palette.ink3)
			}
		} header: {
			HStack(spacing: 7) {
				StatusDot(color: Palette.color(for: store.status), pulsing: !store.isConnected)
				Text(store.state.host?.name ?? store.info?.host.name ?? machine.url.host() ?? machine.url.absoluteString)
					.font(Typography.label)
					.foregroundStyle(Palette.ink3)
					.textCase(.uppercase)
					.lineLimit(1)
				Spacer()
				Button {
					model.newConversationMachine = machine.id
				} label: {
					Image(systemName: "plus")
						.font(.system(size: 12, weight: .medium))
						.foregroundStyle(Palette.ink2)
				}
				.buttonStyle(.borderless)
				.help("New session (pick a project)")
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

private struct SessionRow: View {
	let summary: ConversationSummary

	var body: some View {
		HStack(spacing: 9) {
			StateMark(summary.status, size: 11)
			Text(summary.title)
				.font(Typography.readingSmall)
				.foregroundStyle(Palette.ink)
				.lineLimit(1)
				.truncationMode(.tail)
			Spacer(minLength: 6)
			Text(Date(timeIntervalSince1970: TimeInterval(summary.updatedAt) / 1000).shortAge)
				.font(Typography.label)
				.foregroundStyle(Palette.ink3)
				.monospacedDigit()
		}
		.padding(.vertical, 2)
		.help(summary.title)
	}
}
