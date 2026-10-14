import AmyrlinCore
import AppKit
import SwiftUI

/// Machines, and on each its sessions grouped by project, in the inspector's style: small-caps labels, hairlines,
/// quiet rows. The project needing attention comes first, and archived sessions fold away at the end; each row is a
/// state mark, a title and an age.
/// ↑ and ↓ move between sessions while the sidebar has focus.
struct SidebarView: View {
	@Bindable var model: AppModel
	@FocusState private var focused: Bool

	var body: some View {
		VStack(spacing: 0) {
			HeaderBar {
				Text("machines").font(Typography.label).foregroundStyle(Palette.ink3).textCase(.uppercase)
				Spacer()
				IconButton("plus") { model.isAddingMachine = true }
					.help("Add a machine (⇧⌘N)")
			}
			ScrollView {
				VStack(alignment: .leading, spacing: 0) {
					ForEach(model.machines) { machine in
						MachineSection(machine: machine, model: model)
					}
				}
				.padding(.horizontal, 16)
			}
			.focusable()
			.focusEffectDisabled()
			.focused($focused)
			.onKeyPress(.downArrow) { move(1) }
			.onKeyPress(.upArrow) { move(-1) }
		}
		.background(Palette.panel)
	}

	/// Every session the sidebar shows, in order; folded projects are skipped.
	private var ordered: [ConversationKey] {
		model.machines.flatMap { machine in
			let projects = MachineSection.groups(machine.store)
				.filter { !model.isCollapsed(machine: machine.id, project: $0.project) }
				.flatMap(\.sessions)
			let archived = model.openArchives.contains(machine.id) ? machine.store.state.archived : []
			return (projects + archived).map { ConversationKey(machine: machine.id, conversation: $0.id) }
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
	@State private var hovering = false

	private var store: HostStore { machine.store }

	/// Sessions by project: scratch (sessions in no project) pinned first, then the project needing attention, then the
	/// most recently active.
	static func groups(_ store: HostStore) -> [(project: String, sessions: [ConversationSummary])] {
		let byProject = Dictionary(grouping: store.state.active) { $0.project ?? "" }
		func urgency(_ sessions: [ConversationSummary]) -> Int {
			sessions.contains { $0.status == .needsApproval } ? 0 : sessions.contains { $0.status == .busy } ? 1 : 2
		}
		return byProject
			.map { (project: $0.key, sessions: $0.value.sorted { $0.updatedAt > $1.updatedAt }) }
			.sorted { a, b in
				if a.project.isEmpty != b.project.isEmpty { return a.project.isEmpty }
				let (ua, ub) = (urgency(a.sessions), urgency(b.sessions))
				if ua != ub { return ua < ub }
				return (a.sessions.first?.updatedAt ?? 0) > (b.sessions.first?.updatedAt ?? 0)
			}
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			HStack(spacing: 9) {
				Image(systemName: "desktopcomputer")
					.font(.system(size: 13 * Typography.scale, weight: .light))
					.foregroundStyle(Palette.ink2)
					.overlay(alignment: .bottomTrailing) {
						StatusDot(color: Palette.color(for: store.status), pulsing: !store.isConnected)
							.padding(1.5)
							.background(Circle().fill(Palette.panel))
							.offset(x: 4, y: 3)
					}
				Text(model.name(of: machine))
					.font(Typography.machineHeader)
					.foregroundStyle(Palette.ink)
					.lineLimit(1)
				Spacer()
				if let month = store.state.monthCost {
					Text("\(Dollars.text(month)) this month")
						.font(Typography.uiSmall)
						.foregroundStyle(Palette.ink3)
						.monospacedDigit()
						.lineLimit(1)
						.help("What OpenRouter charged this calendar month on this machine. Claude Code and ChatGPT plans aren't counted.")
				}
				// Shown while the pointer is over the machine, so the header stays quiet otherwise.
				Menu { machineMenu } label: {
					Image(systemName: "ellipsis")
						.font(.system(size: 13 * Typography.scale, weight: .light))
						.foregroundStyle(Palette.ink3)
						.frame(minWidth: 18 * Typography.scale, minHeight: 18 * Typography.scale)
						.contentShape(Rectangle())
				}
				.menuStyle(.button)
				.buttonStyle(.plain)
				.menuIndicator(.hidden)
				.fixedSize()
				.opacity(hovering ? 1 : 0)
				.help("Machine")
				IconButton("square.and.pencil", color: store.isConnected ? Palette.accent : Palette.ink3) {
					model.newConversationMachine = machine.id
				}
				.help("New session (pick a project)")
				.disabled(!store.isConnected)
			}
			// No rule: the icon and full ink mark a machine, and space separates one from the next.
			.padding(.top, 18)
			.padding(.bottom, 8)
			.contentShape(Rectangle())
			.onHover { inside in withAnimation(.state) { hovering = inside } }
			.help(statusHelp)
			.contextMenu { machineMenu }
			if let trouble {
				Text(trouble)
					.font(Typography.uiSmall)
					.foregroundStyle(Palette.wait)
					.fixedSize(horizontal: false, vertical: true)
					.textSelection(.enabled)
					.padding(.top, 10)
			}

			VStack(alignment: .leading, spacing: 10) {
				ForEach(Self.groups(store), id: \.project) { group in
					let collapsed = model.collapsedBinding(machine: machine.id, project: group.project)
					VStack(alignment: .leading, spacing: 0) {
						ProjectRow(
							name: group.project.isEmpty ? "scratch" : group.project,
							color: group.project.isEmpty ? Palette.ink3 : Palette.project(group.project, in: store.state.projectColors),
							collapsed: collapsed,
							note: collapsed.wrappedValue ? foldedNote(group.sessions) : nil
						)
						.contextMenu {
							if !group.project.isEmpty, store.isConnected { colourMenu(group.project) }
						}
						if !collapsed.wrappedValue {
							sessionRows(group.sessions)
						}
					}
				}
				// Archived sessions last, folded until opened; a session needing approval still shows in the fold.
				let archived = store.state.archived
				if !archived.isEmpty {
					let collapsed = model.archiveCollapsedBinding(machine: machine.id)
					VStack(alignment: .leading, spacing: 0) {
						// A hairline sets the archive apart from the projects above it.
						Rectangle().fill(Palette.rule).frame(height: 1).padding(.bottom, 8)
						ProjectRow(name: "archived", color: Palette.ink3, collapsed: collapsed, note: collapsed.wrappedValue ? foldedNote(archived) : nil)
						if !collapsed.wrappedValue { sessionRows(archived) }
					}
				}
			}
			.padding(.bottom, 6)
			if store.state.hasSnapshot, store.state.conversations.isEmpty {
				Text("No sessions yet")
					.font(Typography.ui)
					.foregroundStyle(Palette.ink3)
					.padding(.vertical, 6)
			}
		}
	}

	private func sessionRows(_ sessions: [ConversationSummary]) -> some View {
		ForEach(Array(sessions.enumerated()), id: \.element.id) { index, summary in
			let key = ConversationKey(machine: machine.id, conversation: summary.id)
			SessionRow(summary: summary, last: index == sessions.count - 1, selected: model.selection == key, colors: store.state.projectColors) {
				model.selection = key
			}
			.contextMenu {
				Button("Rename…") { model.renaming = key }.disabled(!store.isConnected)
				// Archiving only hides the session; a running one keeps running.
				if summary.archived {
					Button("Bring Back from the Archive") { model.setArchived(key, false) }.disabled(!store.isConnected)
				} else {
					Button("Archive") { model.setArchived(key, true) }.disabled(!store.isConnected)
				}
			}
		}
	}

	/// The machine's commands, in its ⋯ menu and its right-click menu.
	@ViewBuilder private var machineMenu: some View {
		if case .waiting = store.status {
			Button("Reconnect Now") { Task { await store.reconnect() } }
		}
		Button("Copy Address") {
			NSPasteboard.general.clearContents()
			NSPasteboard.general.setString(machine.url.absoluteString, forType: .string)
		}
		Divider()
		Button("Remove Machine…", role: .destructive) { model.removingMachine = machine.id }
	}

	/// Picks the project's colour on this machine, for names whose hashed colours clash; Automatic goes back to the name's.
	@ViewBuilder private func colourMenu(_ project: String) -> some View {
		let picked = store.state.projectColors[project]
		Menu("Colour") {
			Button(picked == nil ? "✓ Automatic" : "Automatic") { model.setProjectColor(project, nil, on: machine) }
			Divider()
			ForEach(ProjectColor.names.indices, id: \.self) { index in
				Button {
					model.setProjectColor(project, index, on: machine)
				} label: {
					Label {
						Text(picked == index ? "✓ \(ProjectColor.names[index])" : ProjectColor.names[index])
					} icon: {
						Image(nsImage: Palette.swatch(index))
					}
				}
			}
		}
	}

	/// What a folded project still says: how many sessions, and whether one needs you or is working.
	private func foldedNote(_ sessions: [ConversationSummary]) -> String {
		if sessions.contains(where: { $0.status == .needsApproval }) { return "needs you" }
		if sessions.contains(where: { $0.status == .busy }) { return "working" }
		return "\(sessions.count)"
	}

	/// Why the machine isn't connected and what to do, once a try has failed.
	private var trouble: String? {
		switch store.status {
		case .waiting(_, let error): error
		case .failed(let reason): reason
		default: nil
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

/// A project in the tree: `▾ name`, folding its sessions; folded, a count or what needs attention.
private struct ProjectRow: View {
	let name: String
	let color: Color
	@Binding var collapsed: Bool
	let note: String?

	var body: some View {
		Button {
			withAnimation(.easeInOut(duration: 0.15)) { collapsed.toggle() }
		} label: {
			HStack(spacing: 6) {
				Text(collapsed ? "▸" : "▾").foregroundStyle(Palette.ink3)
				Text(name).foregroundStyle(color).lineLimit(1)
				Spacer(minLength: 6)
				if let note {
					Text(note)
						.foregroundStyle(note == "needs you" ? Palette.wait : note == "working" ? Palette.accent : Palette.ink3)
				}
			}
			.font(Typography.projectHeader)
			.padding(.vertical, 3)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.help(collapsed ? "Show \(name)" : "Hide \(name)")
	}
}

/// A session in the tree: a guide (├ or └), its state mark, its title, what it was charged if anything, and its age.
private struct SessionRow: View {
	let summary: ConversationSummary
	let last: Bool
	let selected: Bool
	let colors: [String: Int]
	let select: () -> Void
	@State private var hovering = false

	var body: some View {
		Button(action: select) {
			HStack(spacing: 7) {
				Text(last ? "└" : "├")
					.foregroundStyle(Palette.rule2)
				StateMark(summary.status, size: 10)
				Text(summary.title)
					.foregroundStyle(selected ? Palette.ink : Palette.ink2)
					.lineLimit(1)
					.truncationMode(.tail)
				Spacer(minLength: 6)
				if let cost = summary.cost {
					Text(Dollars.text(cost))
						.foregroundStyle(Palette.ink3)
						.monospacedDigit()
				}
				Text(Date(timeIntervalSince1970: TimeInterval(summary.updatedAt) / 1000).shortAge)
					.foregroundStyle(Palette.ink3)
					.monospacedDigit()
			}
			.font(Typography.ui)
			.padding(.leading, 2)
			.padding(.trailing, 6)
			.padding(.vertical, 4)
			.background(selected ? (summary.project.map { Palette.projectWash($0, in: colors) } ?? Palette.selection) : hovering ? Palette.paper2 : .clear)
			.overlay(alignment: .leading) {
				if selected { Rectangle().fill(summary.project.map { Palette.project($0, in: colors) } ?? Palette.accent).frame(width: 2) }
			}
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.onHover { hovering = $0 }
		.help(summary.cost.map { "\(summary.title)\n\(Dollars.text($0)) charged by OpenRouter" } ?? summary.title)
	}
}
