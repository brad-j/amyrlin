import AmyrlinCore
import Foundation
import Observation
import SwiftUI

/// Identifies a conversation across machines: conversation IDs are unique only within one host.
struct ConversationKey: Hashable {
	let machine: UUID
	let conversation: ConversationID
}

/// A session's change of state, shown as a toast until it's opened, dismissed, or (for `.done` and `.stuck`) a few
/// seconds pass.
struct Toast: Identifiable, Equatable {
	let id = UUID()
	let key: ConversationKey
	let kind: SessionAlert.Kind
}

/// A change the undo bar can take back while it shows, by its button or ⌘Z, or with no `undo` a note the bar only
/// shows, such as how a regenerated title went.
struct UndoableChange: Identifiable {
	let id = UUID()
	/// What was done, as the bar says it: "Archived Fix flaky login test".
	let title: String
	let undo: (@MainActor () -> Void)?
}

/// A session in the task list, with what it takes to draw and group it.
struct TaskEntry: Identifiable {
	let key: ConversationKey
	let summary: ConversationSummary
	let ship: ShipOutcome?
	var id: ConversationKey { key }
}

/// Where the task list looks: every project on every machine, or one project on one machine.
enum TaskScope: Hashable {
	case all
	/// A project by its name on a machine; "" is scratch.
	case project(machine: UUID, name: String)
}

/// A task not started yet: its project and where it will run. The first message creates it on the host. One is kept
/// for the app, so its text and choices stay while other tasks are looked at.
@MainActor @Observable
final class NewTask {
	var machine: UUID?
	/// Nil for scratch: the host gives it a directory of its own.
	var project: ProjectInfo?
	/// Runs its tools in a sandbox, when the project can take one.
	var sandbox = true
	/// Set once a project is picked by hand, or the default could be worked out; until then the box looks again as
	/// machines load their projects.
	var settled = false
}

/// One pane of the middle column. Split, the column shows its panes side by side; one has focus, and the sidebar, the
/// inspector and the status line follow it.
struct Pane: Identifiable, Equatable {
	enum Content: Hashable {
		/// A pane split off and not given a session yet.
		case empty
		case conversation(ConversationKey)
		/// The new-task box; there's one, wherever it shows.
		case newTask

		var machine: UUID? {
			switch self {
			case .conversation(let key): key.machine
			case .empty, .newTask: nil
			}
		}
	}

	let id = UUID()
	var content: Content
}

/// The machines the app knows, persisted as URLs, and the panes showing their sessions.
@MainActor @Observable
final class AppModel {
	struct Machine: Identifiable {
		let id: UUID
		let url: URL
		let store: HostStore
	}

	private(set) var machines: [Machine] = []
	/// Left to right; never empty.
	private(set) var panes = [Pane(content: .empty)] {
		didSet {
			saveSelection()
			// A session opened in a pane shows what its toast said, and its finished run is read.
			toasts.removeAll { isOpen($0.key) }
			markOpenRead()
		}
	}
	/// The index of the pane with focus.
	private(set) var focus = 0 {
		didSet { saveSelection() }
	}
	/// As many as fit beside the sidebar and the inspector on a laptop's screen.
	static let maxPanes = 3

	/// The focused pane's conversation. Setting one already open in another pane focuses that pane instead of showing
	/// it twice.
	var selection: ConversationKey? {
		get {
			// Checked: closing a pane changes `panes` and then `focus`, and saving in between reads this.
			guard panes.indices.contains(focus), case .conversation(let key) = panes[focus].content else { return nil }
			return key
		}
		set {
			guard let newValue else {
				if selection != nil { panes[focus].content = .empty }
				return
			}
			if let index = panes.firstIndex(where: { $0.content == .conversation(newValue) }) {
				focus = index
			} else {
				panes[focus].content = .conversation(newValue)
			}
		}
	}
	/// Whether the focused pane shows the new-task box.
	var isWritingNewTask: Bool {
		panes.indices.contains(focus) && panes[focus].content == .newTask
	}

	/// Whether a conversation shows in any pane, focused or not.
	func isOpen(_ key: ConversationKey) -> Bool {
		panes.contains { $0.content == .conversation(key) }
	}

	var canSplit: Bool { panes.count < Self.maxPanes }

	func focusPane(_ index: Int) {
		if panes.indices.contains(index), focus != index { focus = index }
	}

	/// Focuses the next pane to the right, or with -1 to the left, wrapping around.
	func cycleFocus(_ step: Int) {
		focus = (focus + step + panes.count) % panes.count
	}

	/// Opens an empty pane right of the focused one and focuses it; the sidebar fills it.
	func splitRight() {
		insertPane(.empty)
	}

	/// Opens `key` in a new pane right of the focused one, or focuses the pane it's already in. With no room for
	/// another pane, the focused one shows it.
	func openInNewPane(_ key: ConversationKey) {
		if isOpen(key) || !canSplit {
			selection = key
		} else {
			insertPane(.conversation(key))
		}
	}

	/// Closes a pane, the focused one by default. The last pane can't close.
	func closePane(_ index: Int? = nil) {
		let index = index ?? focus
		guard panes.count > 1, panes.indices.contains(index) else { return }
		panes.remove(at: index)
		if focus > index || focus == panes.count { focus -= 1 }
	}

	private func insertPane(_ content: Pane.Content) {
		guard canSplit else { return }
		panes.insert(Pane(content: content), at: focus + 1)
		focus += 1
	}

	/// Sessions whose finished run hasn't been looked at, as "machine/conversation": a run ended while the session was
	/// out of view or the app was behind. Opening one reads it. Kept on this Mac only.
	var unread: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "unreadSessions") ?? []) {
		didSet { if !ephemeral { UserDefaults.standard.set(unread.sorted(), forKey: "unreadSessions") } }
	}

	func isUnread(_ key: ConversationKey) -> Bool {
		unread.contains(Self.storedKey(key))
	}

	func markRead(_ key: ConversationKey) {
		unread.remove(Self.storedKey(key))
	}

	/// Reads every session open in a pane, while the app is in front, where they can be seen.
	private func markOpenRead() {
		guard NSApplication.shared.isActive else { return }
		let open = Set(panes.compactMap { pane -> String? in
			if case .conversation(let key) = pane.content { return Self.storedKey(key) }
			return nil
		})
		if !unread.isDisjoint(with: open) { unread.subtract(open) }
	}

	/// Unarchived tasks in the list's scope on every machine, matching the search's `words`.
	func tasks(matching words: [String] = []) -> [TaskEntry] {
		machines.flatMap { machine in
			machine.store.state.active
				.filter { inScope($0, on: machine.id) && SessionSearch.matches($0, words: words) }
				.map { TaskEntry(key: ConversationKey(machine: machine.id, conversation: $0.id), summary: $0, ship: machine.store.state.ships[$0.id]) }
		}
	}

	/// The ten most recently active archived tasks in scope, or with words every match.
	func archivedTasks(matching words: [String] = []) -> [TaskEntry] {
		let all = machines.flatMap { machine in
			machine.store.state.archived
				.filter { inScope($0, on: machine.id) && SessionSearch.matches($0, words: words) }
				.map { TaskEntry(key: ConversationKey(machine: machine.id, conversation: $0.id), summary: $0, ship: machine.store.state.ships[$0.id]) }
		}
		.sorted { $0.summary.updatedAt > $1.summary.updatedAt }
		return words.isEmpty ? Array(all.prefix(10)) : all
	}

	private func inScope(_ summary: ConversationSummary, on machine: UUID) -> Bool {
		switch scope {
		case .all: true
		case .project(let scoped, let name): scoped == machine && (summary.project ?? "") == name
		}
	}

	/// The machine the list doesn't name on its rows: the first with a sandbox host, else the first. Rows from any
	/// other machine carry its name.
	var homeMachine: UUID? {
		(machines.first { $0.store.sandboxes != nil } ?? machines.first)?.id
	}

	/// The tag a row from `machine` carries, or nil for the home machine (and when there's only one).
	func machineTag(_ machineID: UUID) -> String? {
		guard machines.count > 1, machineID != homeMachine, let machine = machine(machineID) else { return nil }
		return isThisMac(machine) ? "Mac" : name(of: machine)
	}

	/// Whether `machine` is the Mac the app runs on, by its host name.
	func isThisMac(_ machine: Machine) -> Bool {
		let local = (Host.current().localizedName ?? ProcessInfo.processInfo.hostName).lowercased()
		let name = name(of: machine).lowercased()
		return !name.isEmpty && (local.hasPrefix(name) || ProcessInfo.processInfo.hostName.lowercased().hasPrefix(name))
	}

	/// The key `unread` stores a session by.
	static func storedKey(_ key: ConversationKey) -> String {
		"\(key.machine.uuidString)/\(key.conversation)"
	}

	private func title(of key: ConversationKey) -> String {
		machine(key.machine)?.store.state.conversations[key.conversation]?.title ?? "session"
	}

	/// The change the undo bar offers; a newer one replaces it.
	private(set) var undoable: UndoableChange?

	func offerUndo(_ title: String, _ undo: @escaping @MainActor () -> Void) {
		undoable = UndoableChange(title: title, undo: undo)
	}

	/// Shows `title` where the undo bar goes, with nothing to undo; it replaces an offered change.
	func note(_ title: String) {
		undoable = UndoableChange(title: title, undo: nil)
	}

	/// Takes back the offered change; false when there's none.
	@discardableResult
	func undoLast() -> Bool {
		guard let change = undoable, let undo = change.undo else { return false }
		undoable = nil
		undo()
		return true
	}

	func dismissUndo(_ change: UndoableChange) {
		if undoable?.id == change.id { undoable = nil }
	}

	/// Closed at launch; ⌥⌘I or the header's inspector button opens it.
	var showInspector = false
	var showSidebar = true
	var sidebarWidth: CGFloat = CGFloat(UserDefaults.standard.object(forKey: "sidebarWidth") as? Double ?? 280) {
		didSet { UserDefaults.standard.set(Double(sidebarWidth), forKey: "sidebarWidth") }
	}
	var inspectorWidth: CGFloat = CGFloat(UserDefaults.standard.object(forKey: "inspectorWidth") as? Double ?? 280) {
		didSet { UserDefaults.standard.set(Double(inspectorWidth), forKey: "inspectorWidth") }
	}
	var isAddingMachine = false
	/// The keyboard shortcuts sheet (⌘K).
	var showingShortcuts = false
	/// The spotlight (⌘/), which finds a project on any machine.
	var showingSpotlight = false
	/// The sidebar's search; sessions whose title, project and directory hold every word show.
	var sessionQuery = ""
	/// Set to put the keyboard in the sidebar's search, which clears it once it has.
	var focusSearch = false
	/// The conversation whose title is being changed.
	var renaming: ConversationKey?
	/// The machine whose removal is being confirmed.
	var removingMachine: UUID?
	/// Sessions that need approval, finished a run or got stuck while out of view, oldest first.
	private(set) var toasts: [Toast] = []
	static let maxToasts = 4
	/// The new task being written.
	let newTask = NewTask()
	/// Picking the new task's project, from every machine.
	var pickingProject = false
	/// The machine whose aludra settings are open.
	var hostSettingsMachine: UUID?
	/// A failed app-level action, shown once in the window.
	var error: String?

	/// What the task list shows, kept across launches.
	var scope: TaskScope = .all {
		didSet {
			guard !ephemeral else { return }
			if case .project(let machine, let name) = scope {
				UserDefaults.standard.set(["machine": machine.uuidString, "project": name], forKey: Self.scopeKey)
			} else {
				UserDefaults.standard.removeObject(forKey: Self.scopeKey)
			}
		}
	}
	/// The home's project table lists every project, not only recent ones.
	var showAllProjects = false

	private static let scopeKey = "taskScope"
	private static let defaultsKey = "machines"
	private static let selectionKey = "selection"
	private let client = ClientInfo(
		name: "amyrlin",
		version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
	)

	/// Machines given at launch for screenshots, which are never saved over the real list.
	private var ephemeral = false

	init() {
		let saved = UserDefaults.standard.array(forKey: Self.defaultsKey) as? [[String: String]] ?? []
		var entries = saved.compactMap { entry -> (UUID, URL)? in
			guard let id = entry["id"].flatMap(UUID.init(uuidString:)), let url = entry["url"].flatMap(URL.init(string:)) else { return nil }
			return (id, url)
		}
		#if DEBUG
		// `--args -ephemeralMachines "wss://a/amyrlin wss://b/amyrlin"` (or "" for none) replaces the machines for this
		// launch only, for screenshots.
		let arguments = ProcessInfo.processInfo.arguments
		if let flag = arguments.firstIndex(of: "-ephemeralMachines"), flag + 1 < arguments.count {
			ephemeral = true
			entries = arguments[flag + 1].split(separator: " ").compactMap { URL(string: String($0)) }.map { (UUID(), $0) }
		}
		#endif
		for (id, url) in entries {
			machines.append(makeMachine(id: id, url: url))
		}
		save()
		for machine in machines { machine.store.start() }
		// Coming back to the app reads the sessions open in its panes, and drops their toasts from while it was away.
		NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
			MainActor.assumeIsolated {
				guard let self else { return }
				self.toasts.removeAll { self.isOpen($0.key) }
				self.markOpenRead()
			}
		}
		// The host archives quiet sessions itself now (aludra 3568dcf); the list the app kept of sessions not to archive
		// is the host's to keep. Pins and folds went with the project tree.
		for key in ["keptSessions", "pinnedSessions", "collapsedProjects", "collapsedMachines", "openArchives"] {
			UserDefaults.standard.removeObject(forKey: key)
		}
		if let saved = UserDefaults.standard.dictionary(forKey: Self.scopeKey) as? [String: String],
			let machine = saved["machine"].flatMap(UUID.init(uuidString:)), self.machine(machine) != nil, let name = saved["project"]
		{
			scope = .project(machine: machine, name: name)
		}
		if let saved = UserDefaults.standard.dictionary(forKey: Self.selectionKey) as? [String: String],
			let machine = saved["machine"].flatMap(UUID.init(uuidString:)), self.machine(machine) != nil,
			let conversation = saved["conversation"].flatMap(ConversationID.init)
		{
			selection = ConversationKey(machine: machine, conversation: conversation)
		}
		#if DEBUG
		// `--args -openConversation 12` opens conversation 12 of the first machine, for screenshots.
		if let flag = ProcessInfo.processInfo.arguments.firstIndex(of: "-openConversation"), flag + 1 < ProcessInfo.processInfo.arguments.count,
			let conversation = ConversationID(ProcessInfo.processInfo.arguments[flag + 1]), let first = machines.first
		{
			selection = ConversationKey(machine: first.id, conversation: conversation)
		}
		// `--args -openSplit 12` opens conversation 12 of the first machine in a second pane, for screenshots.
		if let flag = ProcessInfo.processInfo.arguments.firstIndex(of: "-openSplit"), flag + 1 < ProcessInfo.processInfo.arguments.count,
			let conversation = ConversationID(ProcessInfo.processInfo.arguments[flag + 1]), let first = machines.first
		{
			openInNewPane(ConversationKey(machine: first.id, conversation: conversation))
		}
		// `--args -openNewTask` opens the new-task box, for screenshots.
		if ProcessInfo.processInfo.arguments.contains("-openNewTask") { newTask() }
		// `--args -openAddMachine` shows the Add Machine sheet at launch, for screenshots.
		if ProcessInfo.processInfo.arguments.contains("-openAddMachine") {
			Task {
				try? await Task.sleep(for: .seconds(2))
				isAddingMachine = true
			}
		}
		// `open Amyrlin.app --args -openPicker` shows the project picker at launch, for screenshots.
		if ProcessInfo.processInfo.arguments.contains("-openPicker") {
			Task {
				try? await Task.sleep(for: .seconds(2))
				newTask()
				pickingProject = true
			}
		}
		// `--args -openHostSettings` shows the first machine's settings at launch, for screenshots.
		if ProcessInfo.processInfo.arguments.contains("-openHostSettings"), let first = machines.first {
			Task {
				try? await Task.sleep(for: .seconds(2))
				hostSettingsMachine = first.id
			}
		}
		// `--args -openSpotlight` shows the spotlight at launch, for screenshots.
		if ProcessInfo.processInfo.arguments.contains("-openSpotlight") {
			Task {
				try? await Task.sleep(for: .seconds(2))
				showingSpotlight = true
			}
		}
		// `--args -confirmRemoveMachine` asks to remove the first machine at launch, for screenshots.
		if ProcessInfo.processInfo.arguments.contains("-confirmRemoveMachine"), let first = machines.first {
			Task {
				try? await Task.sleep(for: .seconds(2))
				removingMachine = first.id
			}
		}
		// `--args -showInspector` opens the inspector, which starts closed, and `-hideSidebar` closes the sidebar, for
		// screenshots.
		if ProcessInfo.processInfo.arguments.contains("-showInspector") { showInspector = true }
		if ProcessInfo.processInfo.arguments.contains("-hideSidebar") { showSidebar = false }
		#endif
	}

	func addMachine(_ url: URL) {
		guard !machines.contains(where: { $0.url == url }) else { return }
		let machine = makeMachine(id: UUID(), url: url)
		machines.append(machine)
		save()
		machine.store.start()
	}

	func removeMachine(_ id: UUID) {
		guard let index = machines.firstIndex(where: { $0.id == id }) else { return }
		let machine = machines.remove(at: index)
		toasts.removeAll { $0.key.machine == id }
		unread = unread.filter { !$0.hasPrefix("\(id.uuidString)/") }
		if case .project(id, _) = scope { scope = .all }
		if newTask.machine == id { newTask.machine = nil; newTask.project = nil }
		undoable = nil
		for pane in panes.indices.reversed() where panes[pane].content.machine == id {
			if panes.count > 1 { closePane(pane) } else { panes[pane].content = .empty }
		}
		save()
		Task { await machine.store.stop() }
	}

	func machine(_ id: UUID) -> Machine? {
		machines.first { $0.id == id }
	}

	/// The machine's name: the host's, or its address until it has connected.
	func name(of machine: Machine) -> String {
		machine.store.state.host?.name ?? machine.store.info?.host.name ?? machine.url.host() ?? machine.url.absoluteString
	}

	/// The selected conversation's machine and store.
	var selected: (machine: Machine, conversation: ConversationStore)? {
		guard let selection, let machine = machine(selection.machine) else { return nil }
		return (machine, machine.store.conversation(selection.conversation))
	}

	/// Messages written and not sent, by the session or new session they're for, so each keeps its text and attachments
	/// while another is shown. Held until the app quits.
	@ObservationIgnored private var compositions: [Pane.Content: Composition] = [:]

	func composition(for content: Pane.Content) -> Composition {
		if let composition = compositions[content] { return composition }
		let composition = Composition()
		compositions[content] = composition
		return composition
	}

	/// Opens the new-task box in the focused pane (⌘N), or focuses the pane already showing it. Its project is the
	/// list's, else the one last picked, else the newest session's on the first connected machine.
	func newTask(in project: ProjectInfo? = nil, on machineID: UUID? = nil) {
		guard !machines.isEmpty else {
			isAddingMachine = true
			return
		}
		if let machineID, let project {
			choose(project, on: machineID)
		} else if case .project(let machineID, let name) = scope, let machine = machine(machineID) {
			if newTask.machine != machineID || (newTask.project?.name ?? "") != name {
				choose(machine.store.projects.first { $0.name == name }, on: machineID)
			}
		} else if !newTask.settled || newTask.machine.flatMap(machine) == nil {
			chooseDefaultProject()
		}
		if let index = panes.firstIndex(where: { $0.content == .newTask }) {
			focus = index
		} else {
			panes[focus].content = .newTask
		}
	}

	/// Sets the new task's project; it runs in a sandbox when the project can take one.
	func choose(_ project: ProjectInfo?, on machineID: UUID) {
		newTask.machine = machineID
		newTask.project = project
		newTask.sandbox = sandboxRefusal(for: project, on: machineID) == nil
		newTask.settled = true
	}

	/// The project of the newest task on the home machine (the one with sandboxes), or on the first connected one.
	/// Not settled while that machine hasn't listed its projects, so the box tries again once it has.
	func chooseDefaultProject() {
		guard let machine = homeMachine.flatMap(machine) ?? machines.first(where: { $0.store.isConnected }) ?? machines.first else { return }
		let projects = machine.store.projects
		let newest = machine.store.state.active.first { summary in projects.contains { $0.name == summary.project } }
		choose(projects.first { $0.name == newest?.project } ?? projects.first, on: machine.id)
		newTask.settled = !projects.isEmpty
	}

	/// Why the new task can't run in a sandbox, or nil when it can.
	func sandboxRefusal(for project: ProjectInfo?, on machineID: UUID) -> String? {
		guard let machine = machine(machineID) else { return "the machine isn't in the app" }
		guard machine.store.sandboxes != nil else { return "\(name(of: machine)) has no sandbox host" }
		guard let project else { return "a scratch task has no project to copy" }
		let current = machine.store.projects.first { $0.dir == project.dir } ?? project
		return current.checkout?.sandboxRefusal
	}

	/// Starts the new task with `text` as its first message, shows it where the box was, and clears the box.
	func startTask(text: String, images: [ImageUpload] = [], videos: [VideoUpload] = [], files: [FileUpload] = []) async -> Bool {
		guard let machineID = newTask.machine, let machine = machine(machineID) else { return false }
		let sandbox = newTask.sandbox && sandboxRefusal(for: newTask.project, on: machineID) == nil
		do {
			let summary = try await machine.store.createConversation(project: newTask.project?.dir, text: text, images: images, videos: videos, files: files, sandbox: sandbox)
			let key = ConversationKey(machine: machine.id, conversation: summary.id)
			// A crossfade: the new conversation is blank for a moment while its first snapshot comes, which cut in as a flash.
			withAnimation(.row) {
				// The box's pane, which may have lost focus while the host made the session.
				if let pane = panes.firstIndex(where: { $0.content == .newTask }) {
					panes[pane].content = .conversation(key)
					focus = pane
				} else {
					selection = key
				}
			}
			return true
		} catch {
			self.error = (error as? ProtocolError)?.message ?? String(describing: error)
			return false
		}
	}

	/// Shows the sidebar if it's hidden and puts the keyboard in its search (⌘F).
	func searchSessions() {
		if !showSidebar { withAnimation(.panel) { showSidebar = true } }
		focusSearch = true
	}

	/// Gives a conversation a new title on its host.
	func rename(_ target: ConversationKey, to title: String) {
		guard let machine = machine(target.machine) else { return }
		Task {
			do {
				try await machine.store.rename(target.conversation, to: title)
			} catch {
				self.error = (error as? ProtocolError)?.message ?? String(describing: error)
			}
		}
	}

	/// Opens a message search's result: its session in the focused pane (or the pane showing it), scrolled to the item,
	/// paging history back to it if it's older than what's loaded.
	func openSearchResult(_ result: SearchResult, on machineID: UUID) {
		guard let machine = machine(machineID) else { return }
		let key = ConversationKey(machine: machineID, conversation: result.session)
		selection = key
		let store = machine.store.conversation(result.session)
		Task {
			await store.waitForSnapshot()
			await store.reveal(result.entry)
		}
	}

	/// Whether Regenerate Title can be offered: the host has `conversations.retitle` and the session has messages.
	func canRetitle(_ target: ConversationKey) -> Bool {
		guard let machine = machine(target.machine), machine.store.isConnected, machine.store.has(Commands.RetitleConversation.method),
			let summary = machine.store.state.conversations[target.conversation]
		else { return false }
		return summary.hasMessages
	}

	/// Has the host's model write the session's title again from the whole conversation, replacing the one there, and
	/// says how it went where the undo bar goes.
	func retitle(_ target: ConversationKey) {
		guard let machine = machine(target.machine) else { return }
		let before = title(of: target)
		note("Writing a title for \(before)…")
		Task {
			do {
				let written = try await machine.store.retitle(target.conversation)
				note(written ? "Retitled \(title(of: target))" : "No model answered; the title stayed")
			} catch let error as ProtocolError where error.code == "bad_request" {
				note("Nothing to title yet: the session has no messages")
			} catch let error as ProtocolError where error.code == "unknown_method" {
				note("This machine's aludra can't regenerate titles")
			} catch {
				note("Couldn't regenerate the title: \((error as? ProtocolError)?.message ?? String(describing: error))")
			}
		}
	}

	/// Hides a task from the list, or with false brings it back; either can be undone. A running one keeps running. A
	/// session brought back stays until it's archived again: the host keeps it out of its own archiving. Archiving a
	/// sandbox task removes its sandbox once its commits are home.
	func setArchived(_ target: ConversationKey, _ archived: Bool) {
		guard let machine = machine(target.machine) else { return }
		sendArchived(target.conversation, archived, on: machine)
		offerUndo("\(archived ? "Archived" : "Brought back") \(title(of: target))") { [weak self] in
			self?.sendArchived(target.conversation, !archived, on: machine)
		}
	}

	private func sendArchived(_ ids: [ConversationID], _ archived: Bool, on machine: Machine) {
		Task {
			do {
				for id in ids { try await machine.store.setArchived(id, archived) }
			} catch {
				self.error = (error as? ProtocolError)?.message ?? String(describing: error)
			}
		}
	}

	private func sendArchived(_ id: ConversationID, _ archived: Bool, on machine: Machine) {
		sendArchived([id], archived, on: machine)
	}

	/// Picks `project`'s colour on `machine`, or with nil gives it back its name's.
	func setProjectColor(_ project: String, _ color: Int?, on machine: Machine) {
		Task {
			do {
				try await machine.store.setProjectColor(project, color)
			} catch {
				self.error = (error as? ProtocolError)?.message ?? String(describing: error)
			}
		}
	}

	/// The toasts still worth showing: one saying a session needs you goes once it doesn't.
	var shownToasts: [Toast] {
		toasts.filter { toast in
			guard toast.kind == .needsYou else { return true }
			return machine(toast.key.machine)?.store.state.conversations[toast.key.conversation]?.status == .needsApproval
		}
	}

	/// Shows the toast's session in the focused pane, or focuses the pane already showing it.
	func openToast(_ toast: Toast) {
		dismissToast(toast)
		selection = toast.key
	}

	func dismissToast(_ toast: Toast) {
		toasts.removeAll { $0.id == toast.id }
	}

	/// A toast for each alert, but none for a session open in a pane while the app is in front, which shows it already.
	/// A session's newer toast replaces its older one.
	private func receive(_ alerts: [SessionAlert], from machine: UUID) {
		for alert in alerts {
			let key = ConversationKey(machine: machine, conversation: alert.summary.id)
			if isOpen(key), NSApplication.shared.isActive { continue }
			if alert.kind == .done { unread.insert(Self.storedKey(key)) }
			toasts.removeAll { $0.key == key }
			toasts.append(Toast(key: key, kind: alert.kind))
		}
		toasts = Array(shownToasts.suffix(Self.maxToasts))
	}

	private func makeMachine(id: UUID, url: URL) -> Machine {
		let store = HostStore(url: url, client: client)
		store.onAlerts = { [weak self] alerts in self?.receive(alerts, from: id) }
		return Machine(id: id, url: url, store: store)
	}

	/// The focused conversation, reopened at the next launch; not for machines given at launch, whose sessions aren't
	/// in the saved list.
	private func saveSelection() {
		guard !ephemeral else { return }
		if let selection {
			UserDefaults.standard.set(["machine": selection.machine.uuidString, "conversation": String(selection.conversation)], forKey: Self.selectionKey)
		} else {
			UserDefaults.standard.removeObject(forKey: Self.selectionKey)
		}
	}

	private func save() {
		guard !ephemeral else { return }
		UserDefaults.standard.set(machines.map { ["id": $0.id.uuidString, "url": $0.url.absoluteString] }, forKey: Self.defaultsKey)
	}
}
