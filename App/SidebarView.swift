import AmyrlinCore
import AppKit
import SwiftUI

/// Machines, and on each its sessions grouped by project, in the inspector's style: small-caps labels, hairlines,
/// quiet rows. Sessions keep their place as they work, and archived sessions fold away at the end; each row is a
/// state mark, a title and an age.
/// ↑ and ↓ move between sessions while the sidebar or its search has focus. The search, under the header, narrows the
/// tree to matching sessions, open whatever their folds.
struct SidebarView: View {
	@Bindable var model: AppModel
	@FocusState private var focused: Bool
	@FocusState private var searchFocused: Bool

	private var words: [String] { SessionSearch.words(model.sessionQuery) }

	var body: some View {
		VStack(spacing: 0) {
			HeaderBar {
				Text("machines").font(Typography.label).foregroundStyle(Palette.ink3).textCase(.uppercase)
				Spacer()
				IconButton("plus") { model.isAddingMachine = true }
					.help("Add a machine (⇧⌘N)")
			}
			if !model.machines.isEmpty { search }
			ScrollView {
				VStack(alignment: .leading, spacing: 0) {
					ForEach(model.machines) { machine in
						MachineSection(machine: machine, model: model, words: words)
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
		.onChange(of: model.focusSearch, initial: true) { _, now in
			guard now else { return }
			searchFocused = true
			model.focusSearch = false
		}
	}

	/// `/` and the query, in the picker's style; ↩ opens the first match and esc clears the query, then leaves.
	private var search: some View {
		HStack(spacing: 8) {
			Text("/").font(Typography.uiStrong).foregroundStyle(searchFocused || !words.isEmpty ? Palette.accent : Palette.ink3)
			TextField("", text: $model.sessionQuery, prompt: Text("search sessions").foregroundStyle(Palette.ink3))
				.textFieldStyle(.plain)
				.font(Typography.ui)
				.foregroundStyle(Palette.ink)
				.focused($searchFocused)
				.onSubmit {
					if let first = ordered.first { model.selection = first }
				}
				.onKeyPress(.downArrow) { move(1) }
				.onKeyPress(.upArrow) { move(-1) }
				.onKeyPress(.escape) {
					if model.sessionQuery.isEmpty { searchFocused = false } else { model.sessionQuery = "" }
					return .handled
				}
			if !model.sessionQuery.isEmpty {
				IconButton("xmark") { model.sessionQuery = "" }
					.help("Clear the search")
			} else if let combo = Shortcuts.shared.combo(.searchSessions), !searchFocused {
				Text(combo.display).font(Typography.uiSmall).foregroundStyle(Palette.ink3)
			}
		}
		.padding(.horizontal, 10)
		.frame(minHeight: 28 * Typography.scale)
		.background(Palette.paper2)
		.overlay(Rectangle().stroke(searchFocused ? Palette.rule2 : Palette.rule))
		.padding(.horizontal, 16)
		.padding(.top, 12)
	}

	/// Every session the sidebar shows, in order; folded projects are skipped unless searching.
	private var ordered: [ConversationKey] {
		let searching = !words.isEmpty
		return model.machines.flatMap { machine in
			let projects = MachineSection.groups(machine.store, words: words)
				.filter { searching || !model.isCollapsed(machine: machine.id, project: $0.project) }
				.flatMap(\.sessions)
			let archived = searching || model.openArchives.contains(machine.id) ? MachineSection.archived(machine.store, words: words) : []
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
	/// The search's words; none shows every session.
	let words: [String]
	@State private var hovering = false

	private var store: HostStore { machine.store }
	private var searching: Bool { !words.isEmpty }

	/// Sessions matching `words` by project: scratch (sessions in no project) pinned first, then the project with the
	/// newest session. Ordered by creation, not activity, so a session stays put while it works.
	static func groups(_ store: HostStore, words: [String]) -> [(project: String, sessions: [ConversationSummary])] {
		let matching = store.state.active.filter { SessionSearch.matches($0, words: words) }
		let byProject = Dictionary(grouping: matching) { $0.project ?? "" }
		func newestFirst(_ a: ConversationSummary, _ b: ConversationSummary) -> Bool {
			a.createdAt != b.createdAt ? a.createdAt > b.createdAt : a.id > b.id
		}
		return byProject
			.map { (project: $0.key, sessions: $0.value.sorted(by: newestFirst)) }
			.sorted { a, b in
				if a.project.isEmpty != b.project.isEmpty { return a.project.isEmpty }
				let (ca, cb) = (a.sessions.first?.createdAt ?? 0, b.sessions.first?.createdAt ?? 0)
				return ca != cb ? ca > cb : a.project < b.project
			}
	}

	static func archived(_ store: HostStore, words: [String]) -> [ConversationSummary] {
		store.state.archived.filter { SessionSearch.matches($0, words: words) }
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

			let groups = Self.groups(store, words: words)
			let archived = Self.archived(store, words: words)
			VStack(alignment: .leading, spacing: 10) {
				ForEach(groups, id: \.project) { group in
					// A search opens every fold, so its matches show.
					let collapsed = searching ? .constant(false) : model.collapsedBinding(machine: machine.id, project: group.project)
					VStack(alignment: .leading, spacing: 0) {
						let name = group.project.isEmpty ? "scratch" : group.project
						ProjectRow(
							name: name,
							color: group.project.isEmpty ? Palette.ink3 : Palette.project(group.project, in: store.state.projectColors),
							collapsed: collapsed,
							note: collapsed.wrappedValue ? foldedNote(group.sessions) : nil,
							newSession: store.isConnected ? { newSession(in: group) } : nil
						)
						.contextMenu {
							Button("New Session in \(name)") { newSession(in: group) }.disabled(!store.isConnected)
							if !group.project.isEmpty, store.isConnected { colourMenu(group.project) }
						}
						if !collapsed.wrappedValue {
							sessionRows(group.sessions)
						}
					}
				}
				// Archived sessions last, folded until opened; a session needing approval still shows in the fold.
				if !archived.isEmpty {
					let collapsed = searching ? .constant(false) : model.archiveCollapsedBinding(machine: machine.id)
					VStack(alignment: .leading, spacing: 0) {
						// A hairline sets the archive apart from the projects above it.
						Rectangle().fill(Palette.rule).frame(height: 1).padding(.bottom, 8)
						ProjectRow(name: "archived", color: Palette.ink3, collapsed: collapsed, note: collapsed.wrappedValue ? foldedNote(archived) : nil)
						if !collapsed.wrappedValue { sessionRows(archived) }
					}
				}
			}
			.padding(.bottom, 6)
			if searching, store.state.hasSnapshot, groups.isEmpty, archived.isEmpty {
				Text("No matching sessions")
					.font(Typography.ui)
					.foregroundStyle(Palette.ink3)
					.padding(.vertical, 6)
			} else if store.state.hasSnapshot, store.state.conversations.isEmpty {
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
			SessionRow(summary: summary, last: index == sessions.count - 1, selected: model.selection == key, open: model.isOpen(key), colors: store.state.projectColors) {
				// ⌘-click opens the session in a pane of its own, beside the focused one.
				if NSEvent.modifierFlags.contains(.command) {
					withAnimation(.panel) { model.openInNewPane(key) }
				} else {
					model.selection = key
				}
			}
			.contextMenu {
				Button("Open in New Pane") { withAnimation(.panel) { model.openInNewPane(key) } }
					.disabled(!model.canSplit || model.isOpen(key))
				Divider()
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

	/// Opens an empty session in the group's project, or scratch's; the picker when the host doesn't list the project.
	private func newSession(in group: (project: String, sessions: [ConversationSummary])) {
		guard !group.project.isEmpty else {
			model.openDraft(on: machine.id, project: nil)
			return
		}
		let projects = store.info?.projects ?? []
		let dir = group.sessions.lazy.compactMap(\.dir).first
		if let project = projects.first(where: { $0.dir == dir }) ?? projects.first(where: { $0.name == group.project }) {
			model.openDraft(on: machine.id, project: project)
		} else {
			model.newConversationMachine = machine.id
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

/// A project in the tree: `▾ name`, folding its sessions; folded, a count or what needs attention. With `newSession`,
/// a new-session icon shows while the pointer is over the row.
private struct ProjectRow: View {
	let name: String
	let color: Color
	@Binding var collapsed: Bool
	let note: String?
	var newSession: (() -> Void)? = nil
	@State private var hovering = false
	/// Tracked apart from `hovering`: the icon's own hover takes the row's away, which hid it under the pointer.
	@State private var hoveringIcon = false

	var body: some View {
		HStack(spacing: 4) {
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
			if let newSession {
				IconButton("square.and.pencil", action: newSession)
					.help("New session in \(name)")
					.onHover { hoveringIcon = $0 }
					.opacity(hovering || hoveringIcon ? 1 : 0)
			}
		}
		.contentShape(Rectangle())
		.onHover { inside in withAnimation(.state) { hovering = inside } }
	}
}

/// A session in the tree: a guide (├ or └), its state mark, its title, what it was charged if anything, and its age.
/// The focused pane's session has a wash and a mark at its edge; one open in another pane has a fainter mark only.
private struct SessionRow: View {
	let summary: ConversationSummary
	let last: Bool
	let selected: Bool
	let open: Bool
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
				if selected || open {
					Rectangle().fill(summary.project.map { Palette.project($0, in: colors) } ?? Palette.accent).frame(width: 2).opacity(selected ? 1 : 0.5)
				}
			}
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.onHover { hovering = $0 }
		.help(summary.cost.map { "\(summary.title)\n\(Dollars.text($0)) charged by OpenRouter" } ?? summary.title)
	}
}
