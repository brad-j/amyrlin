import AmyrlinCore
import AppKit
import SwiftUI

/// The rail (2026-11-04, sandbox-only): projects, not tasks. "Home" at the top is the queue across every project;
/// under it, the projects with sandbox tasks or activity, each with small counts of what waits (amber needs you,
/// violet running, green ready), most recently active first, then the rest folded. A click opens the project's page.
/// Search finds tasks and messages and lists them under the projects. Only machines with a sandbox host count.
struct SidebarView: View {
	@Bindable var model: AppModel
	@FocusState private var searchFocused: Bool
	/// What the machines' messages.search found for the query, merged.
	@State private var messages = MessageResults()
	@State private var restOpen = false

	private var words: [String] { SessionSearch.words(model.sessionQuery) }
	private var searching: Bool { !words.isEmpty }

	var body: some View {
		let rail = RailProjects.build(model)
		VStack(spacing: 0) {
			HeaderBar {
				Text("amyrlin").foregroundStyle(Palette.ink3)
				Spacer(minLength: 8)
				MachinesMenu(model: model)
			}
			if !model.machines.isEmpty {
				search
			}
			ScrollView {
				LazyVStack(alignment: .leading, spacing: 0) {
					MachineTrouble(model: model)
					if searching {
						SearchResults(model: model, words: words, messages: messages)
					} else {
						RailRow(title: "Home", note: nil, color: Palette.ink, counts: rail.total, selected: model.scope == .all && model.selection == nil && !model.isWritingNewTask) {
							model.goHome()
						}
						.padding(.bottom, 6)
						Text("projects").font(Typography.label).textCase(.uppercase).foregroundStyle(Palette.ink3)
							.padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
						ForEach(rail.active) { item in projectRow(item) }
						if !rail.rest.isEmpty {
							MoreLine(text: restOpen ? "hide the others" : "\(rail.rest.count) more") {
								withAnimation(.easeInOut(duration: 0.15)) { restOpen.toggle() }
							}
							if restOpen { ForEach(rail.rest) { item in projectRow(item) } }
						}
						if let maker = model.sandboxMachines.first(where: { $0.store.newProjects != nil }) {
							Button { model.creatingProject = .create(machine: maker.id) } label: {
								HStack(spacing: 6) {
									Text("+").foregroundStyle(Palette.accent)
									Text("New project").foregroundStyle(Palette.ink2)
								}
								.font(Typography.ui)
								.padding(.horizontal, 12)
								.padding(.vertical, 8)
								.contentShape(Rectangle())
							}
							.buttonStyle(.plain)
							.help("Make a project on \(model.name(of: maker)), with a private GitHub repository")
						}
					}
				}
				.padding(.bottom, 12)
			}
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
			let found = await MessageResults.search(query, on: model.sandboxMachines.filter { $0.store.isConnected })
			guard !Task.isCancelled else { return }
			messages = found
		}
		.onChange(of: model.focusSearch, initial: true) { _, now in
			guard now else { return }
			searchFocused = true
			model.focusSearch = false
		}
	}

	private func projectRow(_ item: RailProjects.Item) -> some View {
		let colors = model.machine(item.machine)?.store.state.projectColors ?? [:]
		let scope = TaskScope.project(machine: item.machine, name: item.name)
		return RailRow(
			title: item.name.isEmpty ? "scratch" : item.name,
			note: model.machineTag(item.machine),
			color: item.name.isEmpty ? Palette.ink2 : Palette.project(item.name, in: colors),
			counts: item.counts,
			dim: item.counts.isEmpty,
			selected: model.scope == scope && model.selection == nil && !model.isWritingNewTask
		) {
			model.openProject(machine: item.machine, name: item.name)
		}
	}

	/// `/` and the query; esc clears the query, then leaves.
	private var search: some View {
		HStack(spacing: 8) {
			Text("/").font(Typography.uiStrong).foregroundStyle(searchFocused || searching ? Palette.accent : Palette.ink3)
			TextField("", text: $model.sessionQuery, prompt: Text("search tasks").foregroundStyle(Palette.ink3))
				.textFieldStyle(.plain)
				.font(Typography.ui)
				.foregroundStyle(Palette.ink)
				.focused($searchFocused)
				.onKeyPress(.escape) {
					if model.sessionQuery.isEmpty { searchFocused = false } else { model.sessionQuery = "" }
					return .handled
				}
			if !model.sessionQuery.isEmpty {
				IconButton("xmark") { model.sessionQuery = "" }.help("Clear the search")
			} else if let combo = Shortcuts.shared.combo(.searchSessions), !searchFocused {
				Text(combo.display).font(Typography.uiSmall).foregroundStyle(Palette.ink3)
			}
		}
		.padding(.horizontal, 10)
		.frame(minHeight: 28 * Typography.scale)
		.background(Palette.paper2)
		.overlay(Rectangle().stroke(searchFocused ? Palette.rule2 : Palette.rule))
		.padding(.horizontal, 12)
		.padding(.top, 10)
		.padding(.bottom, 8)
	}
}

/// The rail's projects, from every machine with sandboxes: those with an unarchived sandbox task, or a task in the last
/// two weeks, most recently active first; the rest by name. Each has its counts by group.
@MainActor enum RailProjects {
	struct Item: Identifiable {
		let machine: UUID
		let name: String
		let counts: [TaskGroups.Group: Int]
		let last: Int64
		var id: String { "\(machine)/\(name)" }
	}

	static let recent: TimeInterval = 14 * 86_400

	static func build(_ model: AppModel) -> (active: [Item], rest: [Item], total: [TaskGroups.Group: Int]) {
		var items: [Item] = []
		var total: [TaskGroups.Group: Int] = [:]
		let cutoff = Int64((Date.now.timeIntervalSince1970 - recent) * 1000)
		for machine in model.sandboxMachines {
			let sandboxed = machine.store.state.conversations.values.filter { $0.sandbox != nil }
			var byProject: [String: (counts: [TaskGroups.Group: Int], last: Int64)] = [:]
			for summary in sandboxed {
				let name = summary.project ?? ""
				var entry = byProject[name] ?? ([:], 0)
				entry.last = max(entry.last, summary.updatedAt)
				if !summary.archived {
					let group = TaskGroups.group(summary, ship: machine.store.state.ship(summary.id))
					if group != .done {
						entry.counts[group, default: 0] += 1
						total[group, default: 0] += 1
					}
				}
				byProject[name] = entry
			}
			// Every project on the machine that can take a sandbox, so a new one shows before its first task.
			for project in machine.store.projects where project.checkout?.takesSandboxes ?? false {
				if byProject[project.name] == nil { byProject[project.name] = ([:], 0) }
			}
			for (name, entry) in byProject {
				items.append(Item(machine: machine.id, name: name, counts: entry.counts, last: entry.last))
			}
		}
		let active = items.filter { !$0.counts.isEmpty || $0.last >= cutoff }.sorted { a, b in
			a.last != b.last ? a.last > b.last : a.name < b.name
		}
		let rest = items.filter { $0.counts.isEmpty && $0.last < cutoff && !$0.name.isEmpty }.sorted { $0.name < $1.name }
		return (active, rest, total)
	}
}

/// A rail row: the name in its colour, a quiet note (its machine, when there's more than one), and pips for what waits.
private struct RailRow: View {
	let title: String
	let note: String?
	let color: Color
	let counts: [TaskGroups.Group: Int]
	var dim = false
	let selected: Bool
	let action: () -> Void
	@State private var hovering = false

	var body: some View {
		Button(action: action) {
			HStack(spacing: 6) {
				Text(title).foregroundStyle(dim && !selected ? color.opacity(0.7) : color).lineLimit(1).truncationMode(.tail)
				if let note { Text(note).foregroundStyle(Palette.ink3).lineLimit(1) }
				Spacer(minLength: 6)
				ForEach([TaskGroups.Group.needsYou, .running, .ready], id: \.self) { group in
					if let count = counts[group], count > 0 { Pip(count: count, group: group) }
				}
			}
			.font(Typography.ui)
			.padding(.horizontal, 12)
			.padding(.vertical, 5)
			.background(selected ? Palette.paper3 : hovering ? Palette.paper2 : .clear)
			.overlay(alignment: .leading) { if selected { Rectangle().fill(color).frame(width: 2) } }
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.onHover { hovering = $0 }
	}
}

/// A count in a small box, in the group's colour.
struct Pip: View {
	let count: Int
	let group: TaskGroups.Group

	var body: some View {
		Text("\(count)")
			.font(Typography.label)
			.monospacedDigit()
			.foregroundStyle(color)
			.padding(.horizontal, 4)
			.overlay(Rectangle().stroke(color.opacity(0.7)))
			.help("\(count) \(group.title)")
	}

	private var color: Color {
		switch group {
		case .needsYou: Palette.wait
		case .running: Palette.accent
		case .ready: Palette.add
		case .done: Palette.ink3
		}
	}
}

/// What a search finds: tasks by title, project or folder in every project (archived ones too), then the messages
/// holding the words.
private struct SearchResults: View {
	let model: AppModel
	let words: [String]
	let messages: MessageResults

	var body: some View {
		let found = (model.allTasks() + model.archivedTasks()).filter { SessionSearch.matches($0.summary, words: words) }
			.sorted { $0.summary.updatedAt > $1.summary.updatedAt }
		Text("tasks").font(Typography.label).textCase(.uppercase).foregroundStyle(Palette.ink3)
			.padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 4)
		if found.isEmpty {
			Text("No task matches").font(Typography.uiSmall).foregroundStyle(Palette.ink3).padding(.horizontal, 12)
		}
		ForEach(found.prefix(30)) { item in
			TaskLine(model: model, item: item, showProject: true)
		}
		MessagesSection(model: model, results: messages).padding(.horizontal, 12)
	}
}

/// The machines, in a menu at the header's right: each with its connection, its settings and removal, and Add Machine.
/// The dot is green while every machine is connected, amber or red otherwise.
struct MachinesMenu: View {
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

/// `show 11 more`, quiet.
struct MoreLine: View {
	let text: String
	let action: () -> Void
	@State private var hovering = false

	var body: some View {
		Button(action: action) {
			Text(text)
				.font(Typography.uiSmall)
				.foregroundStyle(hovering ? Palette.ink2 : Palette.ink3)
				.padding(.horizontal, 12)
				.padding(.vertical, 5)
				.frame(maxWidth: .infinity, alignment: .leading)
				.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.onHover { hovering = $0 }
	}
}

/// A machine that can't connect, or has no sandbox host, says so at the top of the rail.
private struct MachineTrouble: View {
	let model: AppModel

	var body: some View {
		ForEach(model.machines) { machine in
			if let trouble = trouble(machine) {
				VStack(alignment: .leading, spacing: 2) {
					Text("\(model.name(of: machine)) · \(trouble.title)").foregroundStyle(Palette.wait)
					Text(trouble.detail).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
				}
				.font(Typography.uiSmall)
				.textSelection(.enabled)
				.padding(.horizontal, 12)
				.padding(.bottom, 8)
			}
		}
	}

	private func trouble(_ machine: AppModel.Machine) -> (title: String, detail: String)? {
		if model.lacksSandboxes(machine) {
			return ("no sandboxes", "This app runs work in sandboxes, and this machine's aludra has no sandbox host. Remove it from the machines menu.")
		}
		switch machine.store.status {
		case .waiting(_, let error): return (MachinesMenu.status(machine.store.status), error)
		case .failed(let reason): return (MachinesMenu.status(machine.store.status), reason)
		default: return nil
		}
	}
}

/// A task in a list (the home's rail, a project's page, search): its mark, title, the host's line, and its age.
/// A click opens it; ⌘-click opens it in a pane of its own.
struct TaskLine: View {
	let model: AppModel
	let item: TaskEntry
	var showProject = false
	var compact = false
	@State private var hovering = false

	var body: some View {
		let id = item.id
		let summary = item.summary
		let colors = model.machine(id.machine)?.store.state.projectColors ?? [:]
		let selected = model.selection == id
		Button {
			if NSEvent.modifierFlags.contains(.command) {
				withAnimation(.panel) { model.openInNewPane(id) }
			} else {
				model.selection = id
			}
		} label: {
			HStack(alignment: .firstTextBaseline, spacing: 8) {
				TaskMark(summary: summary, ship: item.ship, unread: model.isUnread(id)).frame(width: 10)
				VStack(alignment: .leading, spacing: 1) {
					Text(summary.title.isEmpty ? "New task" : summary.title)
						.font(compact ? Typography.uiSansSmall : Typography.uiSans)
						.foregroundStyle(summary.archived ? Palette.ink3 : Palette.ink)
						.lineLimit(1)
					if !compact, let line = TaskLine.line(summary, ship: item.ship) {
						Text(line).font(Typography.uiSansSmall).foregroundStyle(Palette.ink3).lineLimit(1)
					}
				}
				Spacer(minLength: 6)
				if showProject {
					Text(summary.project ?? "scratch")
						.font(Typography.uiSmall)
						.foregroundStyle(summary.project.map { Palette.project($0, in: colors) } ?? Palette.ink3)
						.lineLimit(1)
				}
				Text(Date(timeIntervalSince1970: TimeInterval(summary.updatedAt) / 1000).shortAge)
					.font(Typography.uiSmall)
					.foregroundStyle(Palette.ink3)
					.monospacedDigit()
			}
			.padding(.horizontal, 12)
			.padding(.vertical, compact ? 3 : 5)
			.background(selected ? Palette.paper3 : hovering ? Palette.paper2 : .clear)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.onHover { hovering = $0 }
		.contextMenu { TaskMenu(model: model, entry: item) }
	}

	/// The host's line, or failing one what the app knows: a stopped or landed ship, a failed or preparing sandbox.
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
}

/// A task's mark: a spinner while it runs or its sandbox is made, an amber diamond when it asks, amber when checks fail,
/// red when stuck or its ship stopped, a green dot when ready to ship, a purple dot for a run not yet read, and a
/// quiet check once shipped or done.
struct TaskMark: View {
	let summary: ConversationSummary
	let ship: ShipOutcome?
	let unread: Bool

	var body: some View {
		let need = TaskGroups.need(summary, ship: ship)
		Group {
			switch (need, TaskGroups.group(summary, ship: ship)) {
			case (.approval?, _), (.question?, _):
				StateMark(.waiting, size: 10)
			case (.checksFail?, _):
				Image(systemName: "exclamationmark.triangle").resizable().scaledToFit().foregroundStyle(Palette.wait)
			case (.some, _):
				StateMark(.failed, size: 10)
			case (nil, .running):
				StateMark(.running, size: 10)
			case (nil, .ready):
				Circle().fill(unread ? Palette.accent : Palette.add).frame(width: 7, height: 7)
			default:
				if unread { Circle().fill(Palette.accent).frame(width: 7, height: 7) } else { StateMark(.done, size: 8) }
			}
		}
		.frame(width: 10, height: 10)
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

