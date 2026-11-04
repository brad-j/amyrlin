import AmyrlinCore
import AppKit
import SwiftUI

/// The task list: a section per machine, each its sessions grouped by what they need from you (TaskGroups): needs
/// you, running, ready and done (the newest eight until asked for more), then the archive folded away. A machine's
/// header folds its section, saying while folded whether anything needs you. Each row is a mark, the title, its age,
/// and under it the project and the host's line of where it stands. The scope switcher at the top narrows the list to
/// one project; All shows everything.
/// ↑ and ↓ move between tasks while the list or its search has focus.
struct SidebarView: View {
	@Bindable var model: AppModel
	@FocusState private var focused: Bool
	@FocusState private var searchFocused: Bool
	/// What the machines' messages.search found for the query, merged.
	@State private var messages = MessageResults()
	@State private var archiveOpen = false

	private var words: [String] { SessionSearch.words(model.sessionQuery) }

	private var searching: Bool { !words.isEmpty }

	/// The machines the list shows: every one, or the scoped project's.
	private var shownMachines: [AppModel.Machine] {
		if case .project(let machine, _) = model.scope { return model.machines.filter { $0.id == machine } }
		return model.machines
	}

	/// One machine's groups, with done cut to the newest few unless opened or searching; the count left out is returned.
	private func groups(on machine: AppModel.Machine) -> (groups: [(group: TaskGroups.Group, items: [TaskEntry])], hiddenDone: Int) {
		var groups = TaskGroups.grouped(model.tasks(on: machine, matching: words), summary: \.summary, ship: \.ship)
		var hidden = 0
		if !searching, !model.expandedDone.contains(machine.id), let index = groups.firstIndex(where: { $0.group == .done }) {
			hidden = max(groups[index].items.count - AppModel.doneLimit, 0)
			groups[index].items = Array(groups[index].items.prefix(AppModel.doneLimit))
		}
		return (groups, hidden)
	}

	private func folded(_ machine: AppModel.Machine) -> Bool {
		!searching && model.foldedMachines.contains(machine.id)
	}

	var body: some View {
		let archived = archiveOpen || !words.isEmpty ? model.archivedTasks(matching: words) : []
		VStack(spacing: 0) {
			HeaderBar {
				ScopeSwitcher(model: model)
				Spacer(minLength: 8)
				MachinesMenu(model: model)
			}
			if !model.machines.isEmpty {
				NewTaskButton(model: model)
				search
			}
			ScrollView {
				LazyVStack(alignment: .leading, spacing: 0) {
					// A stack per machine: the groups' ids repeat from one machine to the next.
					ForEach(shownMachines) { machine in
						VStack(alignment: .leading, spacing: 0) { machineSection(machine) }
					}
					archive(archived)
					if !words.isEmpty { MessagesSection(model: model, results: messages).padding(.horizontal, 12) }
				}
				.padding(.bottom, 12)
			}
			.focusable()
			.focusEffectDisabled()
			.focused($focused)
			.onKeyPress(.downArrow) { move(1) }
			.onKeyPress(.upArrow) { move(-1) }
		}
		.background(Palette.panel)
		// Searches each machine's messages as the query settles; a new query cancels the last.
		.task(id: model.sessionQuery) {
			let query = model.sessionQuery.trimmingCharacters(in: .whitespacesAndNewlines)
			guard query.count >= 2 else {
				messages = MessageResults()
				return
			}
			messages.searching = true
			try? await Task.sleep(for: .milliseconds(250))
			guard !Task.isCancelled else { return }
			let found = await MessageResults.search(query, on: model.machines.filter { $0.store.isConnected })
			guard !Task.isCancelled else { return }
			messages = found
		}
		.onChange(of: model.focusSearch, initial: true) { _, now in
			guard now else { return }
			searchFocused = true
			model.focusSearch = false
		}
	}

	@ViewBuilder private func machineSection(_ machine: AppModel.Machine) -> some View {
		let folded = folded(machine)
		let (groups, hiddenDone) = groups(on: machine)
		MachineHeader(model: model, machine: machine, folded: folded, waiting: groups.first { $0.group == .needsYou }?.items.count ?? 0) {
			withAnimation(.easeInOut(duration: 0.15)) {
				if model.foldedMachines.contains(machine.id) { model.foldedMachines.remove(machine.id) } else { model.foldedMachines.insert(machine.id) }
			}
		}
		if !folded {
			if let trouble = MachineHeader.trouble(machine.store.status) {
				Text(trouble)
					.font(Typography.uiSmall)
					.foregroundStyle(Palette.ink3)
					.fixedSize(horizontal: false, vertical: true)
					.textSelection(.enabled)
					.padding(.horizontal, 12)
					.padding(.top, 2)
			}
			ForEach(groups, id: \.group) { group in
				GroupLabel(title: group.group.title, color: group.group == .needsYou ? Palette.wait : Palette.ink3, count: group.items.count + (group.group == .done ? hiddenDone : 0))
				ForEach(group.items) { entry in
					row(entry)
				}
				if group.group == .done, hiddenDone > 0 || model.expandedDone.contains(machine.id) {
					MoreLine(text: hiddenDone > 0 ? "show \(hiddenDone) more" : "show fewer") {
						withAnimation(.easeInOut(duration: 0.15)) {
							if model.expandedDone.contains(machine.id) { model.expandedDone.remove(machine.id) } else { model.expandedDone.insert(machine.id) }
						}
					}
				}
			}
			if groups.isEmpty, machine.store.state.hasSnapshot {
				Text(searching ? "No matching tasks" : model.scope == .all ? "No tasks" : "No tasks in this project")
					.font(Typography.uiSmall)
					.foregroundStyle(Palette.ink3)
					.padding(.horizontal, 12)
					.padding(.top, 8)
			}
		}
	}

	private func row(_ entry: TaskEntry) -> some View {
		let machine = model.machine(entry.key.machine)
		return TaskRow(
			entry: entry,
			selected: model.selection == entry.key,
			open: model.isOpen(entry.key),
			unread: model.isUnread(entry.key),
			showProject: model.scope == .all,
			// The section names the machine; an archived row, listed apart, names its own.
			machineTag: entry.summary.archived ? model.machineTag(entry.key.machine) : nil,
			connected: machine?.store.isConnected ?? false,
			colors: machine?.store.state.projectColors ?? [:]
		) {
			// ⌘-click opens the task in a pane of its own, beside the focused one.
			if NSEvent.modifierFlags.contains(.command) {
				withAnimation(.panel) { model.openInNewPane(entry.key) }
			} else {
				model.selection = entry.key
			}
		}
		.contextMenu { TaskMenu(model: model, entry: entry) }
	}

	@ViewBuilder private func archive(_ archived: [TaskEntry]) -> some View {
		if model.machines.contains(where: { !$0.store.state.archived.isEmpty }) {
			Button {
				withAnimation(.easeInOut(duration: 0.15)) { archiveOpen.toggle() }
			} label: {
				HStack(spacing: 6) {
					Text(archiveOpen || !words.isEmpty ? "▾" : "▸")
					Text("archived")
					Spacer()
				}
				.font(Typography.label)
				.textCase(.uppercase)
				.foregroundStyle(Palette.ink3)
				.padding(.horizontal, 12)
				.padding(.top, 16)
				.padding(.bottom, 4)
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.help(archiveOpen ? "Hide the archive" : "Show the ten most recent archived tasks; a search looks through all of them")
			ForEach(archived) { entry in row(entry) }
		}
	}

	/// `/` and the query; ↩ opens the first match and esc clears the query, then leaves.
	private var search: some View {
		HStack(spacing: 8) {
			Text("/").font(Typography.uiStrong).foregroundStyle(searchFocused || !words.isEmpty ? Palette.accent : Palette.ink3)
			TextField("", text: $model.sessionQuery, prompt: Text("search tasks").foregroundStyle(Palette.ink3))
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
		.padding(.horizontal, 12)
		.padding(.bottom, 4)
	}

	/// Every task the list shows, in order.
	private var ordered: [ConversationKey] {
		let shown = shownMachines.filter { !folded($0) }.flatMap { groups(on: $0).groups.flatMap(\.items).map(\.key) }
		let archived = archiveOpen || !words.isEmpty ? model.archivedTasks(matching: words) : []
		return shown + archived.map(\.key)
	}

	private func move(_ step: Int) -> KeyPress.Result {
		let keys = ordered
		guard !keys.isEmpty else { return .ignored }
		let index = model.selection.flatMap { keys.firstIndex(of: $0) } ?? (step > 0 ? -1 : keys.count)
		model.selection = keys[min(max(index + step, 0), keys.count - 1)]
		return .handled
	}
}

/// A group's label: small caps and how many it holds.
private struct GroupLabel: View {
	let title: String
	let color: Color
	let count: Int

	var body: some View {
		HStack(spacing: 6) {
			Text(title).foregroundStyle(color)
			Spacer(minLength: 6)
			Text("\(count)").foregroundStyle(Palette.ink3).monospacedDigit()
		}
		.font(Typography.label)
		.textCase(.uppercase)
		.padding(.horizontal, 12)
		.padding(.top, 14)
		.padding(.bottom, 4)
	}
}

/// `+ New task ⌘N`, under the header.
private struct NewTaskButton: View {
	let model: AppModel
	@State private var hovering = false

	var body: some View {
		let on = model.isWritingNewTask
		Button { model.newTask() } label: {
			HStack(spacing: 8) {
				Text("+").foregroundStyle(Palette.accent)
				Text("New task").foregroundStyle(on || hovering ? Palette.ink : Palette.ink2)
				Spacer()
				if let combo = Shortcuts.shared.combo(.newSession) {
					Text(combo.display).font(Typography.uiSmall).foregroundStyle(Palette.ink3)
				}
			}
			.font(Typography.ui)
			.padding(.horizontal, 10)
			.frame(minHeight: 28 * Typography.scale)
			.background(on ? Palette.paper2 : .clear)
			.overlay(Rectangle().stroke(on ? Palette.accent : Palette.rule2))
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.onHover { hovering = $0 }
		.padding(.horizontal, 12)
		.padding(.top, 10)
		.padding(.bottom, 8)
		.help("Start a task")
	}
}

/// The header's scope: `All projects ▾`, or the project in its colour with its machine when it isn't the home one. The
/// menu lists the projects that have tasks, most recently active first, and All.
private struct ScopeSwitcher: View {
	let model: AppModel

	private struct Choice: Hashable {
		let machine: UUID
		let name: String
		let last: Int64
	}

	private var choices: [Choice] {
		var latest: [Choice: Int64] = [:]
		for machine in model.machines {
			for summary in machine.store.state.active {
				let choice = Choice(machine: machine.id, name: summary.project ?? "", last: 0)
				latest[choice] = max(latest[choice] ?? 0, summary.updatedAt)
			}
		}
		return latest.map { Choice(machine: $0.key.machine, name: $0.key.name, last: $0.value) }.sorted { $0.last > $1.last }
	}

	var body: some View {
		Menu {
			Button(model.scope == .all ? "✓ All projects" : "All projects") { model.scope = .all }
			Divider()
			ForEach(choices, id: \.self) { choice in
				let scope = TaskScope.project(machine: choice.machine, name: choice.name)
				let label = (choice.name.isEmpty ? "scratch" : choice.name) + (model.machineTag(choice.machine).map { " · \($0)" } ?? "")
				Button(model.scope == scope ? "✓ \(label)" : label) { model.scope = scope }
			}
		} label: {
			HStack(spacing: 6) {
				switch model.scope {
				case .all:
					Text("All projects").foregroundStyle(Palette.ink2)
				case .project(let machineID, let name):
					let colors = model.machine(machineID)?.store.state.projectColors ?? [:]
					Text(name.isEmpty ? "scratch" : name).foregroundStyle(name.isEmpty ? Palette.ink2 : Palette.project(name, in: colors))
					if let tag = model.machineTag(machineID) { Text(tag).foregroundStyle(Palette.ink3) }
				}
				Text("▾").foregroundStyle(Palette.ink3)
			}
			.font(Typography.ui)
		}
		.menuStyle(.button)
		.buttonStyle(.plain)
		.menuIndicator(.hidden)
		.fixedSize()
		.help("Show every project's tasks, or one project's")
	}
}

/// The machines, in a menu at the header's right: each with its connection, its settings and removal, and Add Machine.
/// The dot is green while every machine is connected, amber or red otherwise.
private struct MachinesMenu: View {
	let model: AppModel

	private var worst: Color {
		let statuses = model.machines.map(\.store.status)
		if statuses.contains(where: { if case .failed = $0 { true } else { false } }) { return Palette.bad }
		if statuses.contains(where: { if case .connected = $0 { false } else { true } }) { return Palette.wait }
		return Palette.add
	}

	var body: some View {
		Menu {
			ForEach(model.machines) { machine in
				Menu(menuTitle(machine)) {
					if case .waiting = machine.store.status {
						Button("Reconnect Now") { Task { await machine.store.reconnect() } }
					}
					if machine.store.settings != nil {
						Button("Settings…") { model.hostSettingsMachine = machine.id }.disabled(!machine.store.isConnected)
					}
					Button("Copy Address") {
						NSPasteboard.general.clearContents()
						NSPasteboard.general.setString(machine.url.absoluteString, forType: .string)
					}
					Divider()
					Button("Remove Machine…", role: .destructive) { model.removingMachine = machine.id }
				}
			}
			if !model.machines.isEmpty { Divider() }
			Button("Add Machine…") { model.isAddingMachine = true }
		} label: {
			HStack(spacing: 6) {
				StatusDot(color: model.machines.isEmpty ? Palette.ink3 : worst)
				Image(systemName: "desktopcomputer")
					.font(.system(size: 12 * Typography.scale, weight: .light))
					.foregroundStyle(Palette.ink3)
			}
			.frame(minHeight: 18 * Typography.scale)
			.contentShape(Rectangle())
		}
		.menuStyle(.button)
		.buttonStyle(.plain)
		.menuIndicator(.hidden)
		.fixedSize()
		.help(model.machines.map { "\(model.name(of: $0)): \(Self.status($0.store.status))" }.joined(separator: "\n"))
	}

	private func menuTitle(_ machine: AppModel.Machine) -> String {
		let month = machine.store.state.monthCost.map { " · \(Dollars.text($0)) this month" } ?? ""
		return "\(model.name(of: machine)) · \(Self.status(machine.store.status))\(month)"
	}

	static func status(_ status: HostConnection.Status) -> String {
		switch status {
		case .connected: "connected"
		case .connecting: "connecting"
		case .waiting: "reconnecting"
		case .failed: "can't connect"
		case .idle, .stopped: "not connected"
		}
	}
}

/// A machine's section header: its connection, its name, and while folded how many tasks need you. A click folds it.
private struct MachineHeader: View {
	let model: AppModel
	let machine: AppModel.Machine
	let folded: Bool
	let waiting: Int
	let toggle: () -> Void
	@State private var hovering = false

	var body: some View {
		Button(action: toggle) {
			HStack(spacing: 8) {
				StatusDot(color: Palette.color(for: machine.store.status), pulsing: !machine.store.isConnected)
				Text(model.name(of: machine)).foregroundStyle(Palette.ink)
				if model.isThisMac(machine) { Text("this Mac").foregroundStyle(Palette.ink3) }
				Text(folded ? "▸" : "▾").foregroundStyle(Palette.ink3).opacity(hovering || folded ? 1 : 0)
				Spacer(minLength: 6)
				if !machine.store.isConnected {
					Text(MachinesMenu.status(machine.store.status)).foregroundStyle(Palette.wait)
				} else if folded, waiting > 0 {
					Text("\(waiting) needs you").foregroundStyle(Palette.wait)
				}
			}
			.font(Typography.uiStrong)
			.padding(.horizontal, 12)
			.padding(.top, 16)
			.padding(.bottom, 2)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.onHover { hovering = $0 }
		.help("\(folded ? "Show" : "Hide") \(model.name(of: machine))'s tasks")
	}

	/// Why a machine isn't connected, once a try has failed.
	static func trouble(_ status: HostConnection.Status) -> String? {
		switch status {
		case .waiting(_, let error): error
		case .failed(let reason): reason
		default: nil
		}
	}
}

/// `show 11 more`, quiet, under a group.
private struct MoreLine: View {
	let text: String
	let action: () -> Void
	@State private var hovering = false

	var body: some View {
		Button(action: action) {
			Text(text)
				.font(Typography.uiSmall)
				.foregroundStyle(hovering ? Palette.ink2 : Palette.ink3)
				.padding(.leading, 30)
				.padding(.vertical, 4)
				.frame(maxWidth: .infinity, alignment: .leading)
				.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.onHover { hovering = $0 }
	}
}

/// A task's menu, on its row and in its header.
struct TaskMenu: View {
	let model: AppModel
	let entry: TaskEntry

	var body: some View {
		let key = entry.key
		let store = model.machine(key.machine)?.store
		let connected = store?.isConnected ?? false
		Button("Open in New Pane") { withAnimation(.panel) { model.openInNewPane(key) } }
			.disabled(!model.canSplit || model.isOpen(key))
		if model.isUnread(key) {
			Button("Mark as Read") { withAnimation(.row) { model.markRead(key) } }
		}
		Divider()
		Button("Rename…") { model.renaming = key }.disabled(!connected)
		// Only hosts that answer conversations.retitle (aludra 2899ef8 and later), and not before a first message.
		if store?.has(Commands.RetitleConversation.method) == true {
			Button("Regenerate Title") { model.retitle(key) }.disabled(!model.canRetitle(key))
		}
		if let project = entry.summary.project, let store, store.state.projectColors[project] != nil || connected {
			ColourMenu(model: model, project: project, machine: key.machine)
		}
		Divider()
		// Archiving only hides the task; a running one keeps running.
		if entry.summary.archived {
			Button("Bring Back from the Archive") { model.setArchived(key, false) }.disabled(!connected)
		} else {
			Button("Archive") { model.setArchived(key, true) }.disabled(!connected)
		}
	}
}

/// Picks a project's colour on its machine, for names whose hashed colours clash; Automatic goes back to the name's.
private struct ColourMenu: View {
	let model: AppModel
	let project: String
	let machine: UUID

	var body: some View {
		if let machine = model.machine(machine) {
			let picked = machine.store.state.projectColors[project]
			Menu("\(project) Colour") {
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
	}
}

/// A task: its mark, title and age, and under them its project (in All), its machine when it isn't the home one, and
/// the host's line of where it stands. The focused pane's task has a wash and its project's colour at its edge; one
/// open in another pane has a fainter edge.
private struct TaskRow: View {
	let entry: TaskEntry
	let selected: Bool
	let open: Bool
	let unread: Bool
	let showProject: Bool
	let machineTag: String?
	let connected: Bool
	let colors: [String: Int]
	let select: () -> Void
	@State private var hovering = false

	private var summary: ConversationSummary { entry.summary }
	private var need: TaskGroups.Need? { TaskGroups.need(summary, ship: entry.ship) }
	private var group: TaskGroups.Group { TaskGroups.group(summary, ship: entry.ship) }

	var body: some View {
		Button(action: select) {
			VStack(alignment: .leading, spacing: 2) {
				HStack(spacing: 8) {
					TaskMark(summary: summary, need: need, group: group, unread: unread)
					Text(summary.title.isEmpty ? "New task" : summary.title)
						.font(Typography.uiSans)
						.foregroundStyle(selected ? Palette.ink : Palette.ink2)
						.lineLimit(1)
						.truncationMode(.tail)
					Spacer(minLength: 6)
					Text(Date(timeIntervalSince1970: TimeInterval(summary.updatedAt) / 1000).shortAge)
						.font(Typography.uiSmall)
						.foregroundStyle(Palette.ink3)
						.monospacedDigit()
				}
				HStack(spacing: 6) {
					if showProject {
						Text(summary.project ?? "scratch")
							.foregroundStyle(summary.project.map { Palette.project($0, in: colors) } ?? Palette.ink3)
							.layoutPriority(1)
					}
					if let machineTag {
						Text(machineTag)
							.foregroundStyle(Palette.ink2)
							.padding(.horizontal, 4)
							.overlay(Rectangle().stroke(Palette.rule2))
							.layoutPriority(1)
					}
					if let line = Self.line(summary, ship: entry.ship) {
						Text(line).foregroundStyle(lineColor).lineLimit(1).truncationMode(.tail)
					}
				}
				.font(Typography.uiSansSmall)
				.padding(.leading, 18)
				.lineLimit(1)
			}
			.padding(.horizontal, 12)
			.padding(.vertical, 6)
			.opacity(connected ? 1 : 0.55)
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
		.help(help)
	}

	private var lineColor: Color {
		switch need {
		case .approval, .question: Palette.wait
		case .stuck, .shipStopped, .checksFail: Palette.bad
		case nil: group == .ready ? Palette.add : Palette.ink3
		}
	}

	/// The host's line, or failing one what the app knows: a stopped or landed ship, a failed or removed sandbox.
	static func line(_ summary: ConversationSummary, ship: ShipOutcome?) -> String? {
		switch ship {
		case .shipped(let to, let pushed, _, _, let pr) where summary.status != .busy:
			return pr != nil ? "PR open · \(pushed)" : to == .main ? "Live on \(pushed.replacingOccurrences(of: "origin/", with: ""))" : "Pushed to \(pushed)"
		case .stopped(_, let reason) where summary.status != .busy:
			return "Ship stopped: \(reason)"
		default: break
		}
		if summary.sandbox?.state == .failed { return "Sandbox failed: \(summary.sandbox?.reason ?? "no reason given")" }
		if summary.status == .needsApproval, summary.line == nil { return "Waiting for your approval" }
		if summary.status == .stuck, summary.line == nil { return "Stuck: \(summary.stuck?.reason ?? "no reason given")" }
		return summary.line
	}

	private var help: String {
		var where_: String
		if let sandbox = summary.sandbox {
			where_ = "in a sandbox (\(sandbox.branch))"
			if sandbox.state == .removed { where_ += ", removed" }
		} else {
			where_ = "here, in the project's checkout"
		}
		let machine = machineTag.map { " on \($0)" } ?? ""
		let why: String? = switch need {
		case .approval: "Asks to allow a tool call"
		case .question: "Asks you something"
		case .stuck: "Stuck"
		case .shipStopped: "Its ship stopped; nothing was pushed"
		case .checksFail: "Its checks fail"
		case nil: unread ? "Finished a run you haven't read" : nil
		}
		return [summary.title, why, "\(summary.project ?? "scratch")\(machine) · runs \(where_)", connected ? nil : "Its machine isn't connected"]
			.compactMap(\.self).joined(separator: "\n")
	}
}

/// A task's mark: a spinner while it runs or its sandbox is made, an amber diamond when it asks, a red cross when it's
/// stuck or failing, a green dot when it's ready to ship, a purple dot for a finished run not yet read, and a quiet
/// check once done.
private struct TaskMark: View {
	let summary: ConversationSummary
	let need: TaskGroups.Need?
	let group: TaskGroups.Group
	let unread: Bool

	var body: some View {
		Group {
			switch (need, group) {
			case (.approval?, _), (.question?, _):
				StateMark(.waiting, size: 10)
			case (.some, _):
				StateMark(.failed, size: 10)
			case (nil, .running):
				StateMark(.running, size: 10)
			case (nil, .ready):
				Circle().fill(unread ? Palette.accent : Palette.add).frame(width: 8, height: 8)
			default:
				if unread {
					Circle().fill(Palette.accent).frame(width: 8, height: 8)
				} else {
					StateMark(.done, size: 9)
				}
			}
		}
		.frame(width: 10, height: 10)
	}
}

/// One search's results from every machine searched, merged: each machine's best first, then their second best, and
/// so on, since one host's ranks don't compare with another's.
struct MessageResults {
	struct Hit: Identifiable {
		let machine: UUID
		let result: SearchResult
		var id: String { "\(machine.uuidString)/\(result.item.isEmpty ? "\(result.entry):\(result.index)" : result.item)" }
	}

	var hits: [Hit] = []
	var searching = false
	/// Why a machine couldn't search, by its name.
	var failures: [String] = []
	/// Machines whose aludra has no message search.
	var unsupported: [String] = []

	/// A snippet with its matched words lit and the « » markers gone.
	static func snippet(_ text: String) -> AttributedString {
		var out = AttributedString()
		for run in SearchSnippet.runs(text) {
			var piece = AttributedString(run.text)
			piece.foregroundColor = run.matched ? Palette.ink : Palette.ink3
			if run.matched { piece.backgroundColor = Palette.selection }
			out += piece
		}
		return out
	}

	@MainActor static func search(_ query: String, on machines: [AppModel.Machine]) async -> MessageResults {
		var lists: [(UUID, [SearchResult])] = []
		var out = MessageResults()
		// Every machine at once; each answers on its own connection.
		let searches = machines.map { machine in
			(machine, Task { @MainActor in try await machine.store.searchMessages(query) })
		}
		for (machine, search) in searches {
			let name = machine.store.state.host?.name ?? machine.store.info?.host.name ?? machine.url.host() ?? "a machine"
			do {
				let results = try await search.value
				if machine.store.has(Commands.SearchMessages.method) { lists.append((machine.id, results)) } else { out.unsupported.append(name) }
			} catch let error as ProtocolError where error.code == "unknown_method" {
				out.unsupported.append(name)
			} catch {
				out.failures.append("\(name): \((error as? ProtocolError)?.message ?? String(describing: error))")
			}
		}
		// In the sidebar's order of machines, so the merge doesn't change with which answered first.
		lists.sort { a, b in (machines.firstIndex { $0.id == a.0 } ?? 0) < (machines.firstIndex { $0.id == b.0 } ?? 0) }
		out.hits = SearchMerge.interleave(lists).map { Hit(machine: $0.machine, result: $0.result) }
		return out
	}
}

/// Under the title matches while searching: messages and answers holding the words, from every machine's
/// messages.search, each with its session, a snippet with the matched words lit, and archived marked. A click opens the
/// session at the message.
private struct MessagesSection: View {
	let model: AppModel
	let results: MessageResults

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			Rectangle().fill(Palette.rule).frame(height: 1).padding(.top, 12).padding(.bottom, 8)
			HStack(spacing: 6) {
				Text("messages").foregroundStyle(Palette.ink3)
				Spacer(minLength: 6)
				if results.searching {
					Text("searching…").foregroundStyle(Palette.ink3)
				} else if !results.hits.isEmpty {
					Text("\(results.hits.count)").foregroundStyle(Palette.ink3).monospacedDigit()
				}
			}
			.font(Typography.projectHeader)
			.padding(.leading, 2)
			.padding(.vertical, 3)
			if !results.searching, results.hits.isEmpty {
				Text(results.unsupported.count == model.machines.count && !model.machines.isEmpty ? "This aludra can't search messages" : "No messages match")
					.font(Typography.uiSmall)
					.foregroundStyle(Palette.ink3)
					.padding(.vertical, 4)
			}
			ForEach(results.hits) { hit in
				MessageHitRow(model: model, hit: hit, showMachine: model.machines.count > 1)
			}
			ForEach(results.failures, id: \.self) { failure in
				Text(failure).font(Typography.uiSmall).foregroundStyle(Palette.wait).padding(.vertical, 2)
			}
			if !results.unsupported.isEmpty, results.unsupported.count < model.machines.count {
				Text("Not searched: \(results.unsupported.joined(separator: ", ")) (no message search)")
					.font(Typography.uiSmall).foregroundStyle(Palette.ink3).padding(.vertical, 2)
			}
		}
		.padding(.bottom, 6)
	}
}

private struct MessageHitRow: View {
	let model: AppModel
	let hit: MessageResults.Hit
	let showMachine: Bool
	@State private var hovering = false

	private var machine: AppModel.Machine? { model.machine(hit.machine) }
	private var colors: [String: Int] { machine?.store.state.projectColors ?? [:] }

	var body: some View {
		let result = hit.result
		Button {
			model.openSearchResult(result, on: hit.machine)
		} label: {
			VStack(alignment: .leading, spacing: 2) {
				HStack(spacing: 6) {
					Text(result.from == .user ? "❯" : "●")
						.foregroundStyle(result.from == .user ? Palette.accent : Palette.ink3)
					Text(result.title.isEmpty ? "Untitled" : result.title)
						.foregroundStyle(Palette.ink2)
						.lineLimit(1)
						.truncationMode(.tail)
					Spacer(minLength: 4)
					if result.archived { Text("archived").foregroundStyle(Palette.ink3) }
					Text(Date(timeIntervalSince1970: TimeInterval(result.at) / 1000).shortAge)
						.foregroundStyle(Palette.ink3)
						.monospacedDigit()
				}
				.font(Typography.uiSmall)
				Text(MessageResults.snippet(result.snippet))
					.font(Typography.uiSansSmall)
					.lineLimit(3)
					.fixedSize(horizontal: false, vertical: true)
				if showMachine, let machine {
					Text("\(model.name(of: machine)) · \(result.project.isEmpty ? "scratch" : result.project)")
						.font(Typography.label)
						.foregroundStyle(Palette.ink3)
				}
			}
			.padding(.leading, 8)
			.padding(.trailing, 6)
			.padding(.vertical, 5)
			.frame(maxWidth: .infinity, alignment: .leading)
			.background(hovering ? Palette.paper2 : .clear)
			.overlay(alignment: .leading) {
				Rectangle().fill(result.project.isEmpty ? Palette.rule2 : Palette.project(result.project, in: colors)).frame(width: 2)
			}
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.onHover { hovering = $0 }
		.help("\(result.from == .user ? "Your message" : "An answer") in \(result.title)\(result.project.isEmpty ? "" : " · \(result.project)")\(result.archived ? " (archived)" : "")")
	}

}

