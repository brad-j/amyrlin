import AmyrlinCore
import SwiftUI

/// Machines, and on each its sessions grouped by project, in the inspector's style: small-caps labels, hairlines,
/// quiet rows. The project needing attention comes first; each row is a state mark, a title and an age.
/// ↑ and ↓ move between sessions while the sidebar has focus.
struct SidebarView: View {
	@Bindable var model: AppModel
	@FocusState private var focused: Bool

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 0) {
				ForEach(model.machines) { machine in
					MachineSection(machine: machine, model: model)
				}
			}
			.padding(.horizontal, 16)
			// Clear of the window's controls, which sit over the sidebar's top.
			.padding(.top, 44)
		}
		.background(Palette.panel)
		.focusable()
		.focusEffectDisabled()
		.focused($focused)
		.onKeyPress(.downArrow) { move(1) }
		.onKeyPress(.upArrow) { move(-1) }
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
			.padding(.horizontal, 16)
			.padding(.vertical, 10)
			.background(Palette.panel)
			.overlay(alignment: .top) { Rectangle().fill(Palette.rule).frame(height: 1) }
		}
	}

	/// Every session the sidebar shows, in order; folded projects are skipped.
	private var ordered: [ConversationKey] {
		model.machines.flatMap { machine in
			MachineSection.groups(machine.store)
				.filter { !model.isCollapsed(machine: machine.id, project: $0.project) }
				.flatMap { $0.sessions.map { ConversationKey(machine: machine.id, conversation: $0.id) } }
		}
	}

	private func move(_ step: Int) -> KeyPress.Result {
		let keys = ordered
		guard !keys.isEmpty else { return .ignored }
		let index = model.selection.flatMap { keys.firstIndex(of: $0) } ?? (step > 0 ? -1 : keys.count)
		model.selection = keys[min(max(index + step, 0), keys.count - 1)]
		return .handled
	}
}

private struct MachineSection: View {
	let machine: AppModel.Machine
	let model: AppModel

	private var store: HostStore { machine.store }

	/// Sessions by project, the project needing attention first, then the most recently active.
	static func groups(_ store: HostStore) -> [(project: String, sessions: [ConversationSummary])] {
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
		VStack(alignment: .leading, spacing: 0) {
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
						.font(.system(size: 13, weight: .medium))
						.foregroundStyle(Palette.ink2)
						.frame(width: 22, height: 22)
						.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
				.help("New session (pick a project)")
				.disabled(!store.isConnected)
			}
			.padding(.vertical, 12)
			.overlay(alignment: .bottom) { Rectangle().fill(Palette.rule).frame(height: 1) }
			.help(statusHelp)
			.contextMenu {
				Button("Remove Machine", role: .destructive) { model.removeMachine(machine.id) }
			}

			ForEach(Self.groups(store), id: \.project) { group in
				let collapsed = model.collapsedBinding(machine: machine.id, project: group.project)
				PanelSection(
					group.project.isEmpty ? "Sessions" : group.project,
					titleColor: group.project.isEmpty ? Palette.ink3 : Palette.project(group.project),
					collapsed: collapsed,
					trailing: collapsed.wrappedValue ? foldedNote(group.sessions) : nil
				) {
					VStack(spacing: 2) {
						ForEach(group.sessions) { summary in
							let key = ConversationKey(machine: machine.id, conversation: summary.id)
							SessionRow(summary: summary, selected: model.selection == key) {
								model.selection = key
							}
						}
					}
				}
			}
			if store.state.hasSnapshot, store.state.active.isEmpty {
				Text("No sessions yet")
					.font(Typography.readingSmall)
					.foregroundStyle(Palette.ink3)
					.padding(.vertical, 14)
			}
		}
	}

	/// What a folded project still says: how many sessions, and whether one needs you or is working.
	private func foldedNote(_ sessions: [ConversationSummary]) -> String {
		if sessions.contains(where: { $0.status == .needsApproval }) { return "needs you" }
		if sessions.contains(where: { $0.status == .busy }) { return "working" }
		return "\(sessions.count)"
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
	let selected: Bool
	let select: () -> Void
	@State private var hovering = false

	var body: some View {
		Button(action: select) {
			HStack(spacing: 9) {
				StateMark(summary.status, size: 11)
				Text(summary.title)
					.font(Typography.readingSmall)
					.foregroundStyle(selected ? Palette.ink : Palette.ink2)
					.lineLimit(1)
					.truncationMode(.tail)
				Spacer(minLength: 6)
				Text(Date(timeIntervalSince1970: TimeInterval(summary.updatedAt) / 1000).shortAge)
					.font(Typography.label)
					.foregroundStyle(Palette.ink3)
					.monospacedDigit()
			}
			.padding(.horizontal, 8)
			.padding(.vertical, 6)
			.background(selected ? (summary.project.map(Palette.projectWash) ?? Palette.selection) : hovering ? Palette.paper2 : .clear, in: RoundedRectangle(cornerRadius: Metrics.radiusRow))
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.padding(.horizontal, -8)
		.onHover { hovering = $0 }
		.help(summary.title)
	}
}
