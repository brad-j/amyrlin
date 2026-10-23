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

/// A project in the sidebar: its machine and name, "" for scratch.
struct ProjectKey: Hashable {
	let machine: UUID
	let project: String
}

/// A conversation not created yet: a project picked, no message sent. The first message creates it on the host.
struct Draft: Hashable {
	let machine: UUID
	/// Nil for a no-project session: the host gives it a scratch directory of its own.
	let project: ProjectInfo?
}

/// One pane of the middle column. Split, the column shows its panes side by side; one has focus, and the sidebar, the
/// inspector and the status line follow it.
struct Pane: Identifiable, Equatable {
	enum Content: Hashable {
		/// A pane split off and not given a session yet.
		case empty
		case conversation(ConversationKey)
		case draft(Draft)

		var machine: UUID? {
			switch self {
			case .empty: nil
			case .conversation(let key): key.machine
			case .draft(let draft): draft.machine
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
			// A session opened in a pane shows what its toast said.
			toasts.removeAll { isOpen($0.key) }
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
	/// The focused pane's draft, shown in place of a conversation until its first message is sent.
	var draft: Draft? {
		guard panes.indices.contains(focus), case .draft(let draft) = panes[focus].content else { return nil }
		return draft
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

	/// Folded project groups in the sidebar, as "machine/project", kept across launches.
	var collapsedProjects: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "collapsedProjects") ?? []) {
		didSet { UserDefaults.standard.set(collapsedProjects.sorted(), forKey: "collapsedProjects") }
	}

	func collapsedBinding(machine: UUID, project: String) -> Binding<Bool> {
		let key = "\(machine.uuidString)/\(project)"
		return Binding(
			get: { self.collapsedProjects.contains(key) },
			set: { folded in
				if folded { self.collapsedProjects.insert(key) } else { self.collapsedProjects.remove(key) }
			}
		)
	}

	func isCollapsed(machine: UUID, project: String) -> Bool {
		collapsedProjects.contains("\(machine.uuidString)/\(project)")
	}

	/// Folds or opens every project on `machine` the sidebar shows, and its archive.
	func setAllProjectsCollapsed(_ folded: Bool, on machine: Machine) {
		let projects = Set(machine.store.state.active.map { $0.project ?? "" }).map { "\(machine.id.uuidString)/\($0)" }
		if folded {
			collapsedProjects.formUnion(projects)
			openArchives.remove(machine.id)
		} else {
			collapsedProjects.subtract(projects)
		}
	}

	/// Machines folded to their header in the sidebar, kept across launches.
	var collapsedMachines: Set<UUID> = Set((UserDefaults.standard.stringArray(forKey: "collapsedMachines") ?? []).compactMap(UUID.init(uuidString:))) {
		didSet { UserDefaults.standard.set(collapsedMachines.map(\.uuidString).sorted(), forKey: "collapsedMachines") }
	}

	/// Machines whose Archived group is open in the sidebar. It starts folded, unlike projects, so this keeps the open ones.
	var openArchives: Set<UUID> = Set((UserDefaults.standard.stringArray(forKey: "openArchives") ?? []).compactMap(UUID.init(uuidString:))) {
		didSet { UserDefaults.standard.set(openArchives.map(\.uuidString).sorted(), forKey: "openArchives") }
	}

	/// Folded when true, like `collapsedBinding`.
	func archiveCollapsedBinding(machine: UUID) -> Binding<Bool> {
		Binding(
			get: { !self.openArchives.contains(machine) },
			set: { folded in
				if folded { self.openArchives.remove(machine) } else { self.openArchives.insert(machine) }
			}
		)
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
	/// The project whose removal from the sidebar is being confirmed.
	var removingProject: ProjectKey?
	/// The machine a new conversation is being started on, while its sheet is open.
	var newConversationMachine: UUID?
	/// The machine whose aludra settings are open.
	var hostSettingsMachine: UUID?
	/// A failed app-level action, shown once in the window.
	var error: String?

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
		// `--args -openAddMachine` shows the Add Machine sheet at launch, for screenshots.
		if ProcessInfo.processInfo.arguments.contains("-openAddMachine") {
			Task {
				try? await Task.sleep(for: .seconds(2))
				isAddingMachine = true
			}
		}
		// `open Amyrlin.app --args -openPicker` shows the project picker at launch, for screenshots.
		if ProcessInfo.processInfo.arguments.contains("-openPicker"), let first = machines.first {
			Task {
				try? await Task.sleep(for: .seconds(2))
				newConversationMachine = first.id
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
		// `--args -showInspector` opens the inspector, which starts closed, `-hideSidebar` closes the sidebar, and
		// `-openDraft` opens a no-project draft on the first machine, for screenshots.
		if ProcessInfo.processInfo.arguments.contains("-showInspector") { showInspector = true }
		if ProcessInfo.processInfo.arguments.contains("-hideSidebar") { showSidebar = false }
		if ProcessInfo.processInfo.arguments.contains("-openDraft"), let first = machines.first {
			openDraft(on: first.id, project: nil)
		}
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

	/// Opens an empty conversation for `project` in the focused pane; nothing is created on the host until the first
	/// message.
	func openDraft(on machine: UUID, project: ProjectInfo?) {
		panes[focus].content = .draft(Draft(machine: machine, project: project))
	}

	/// Shows the sidebar if it's hidden and puts the keyboard in its search (⌘F).
	func searchSessions() {
		if !showSidebar { withAnimation(.panel) { showSidebar = true } }
		focusSearch = true
	}

	/// Opens the project picker on the first connected machine (⌘N).
	func newSession() {
		guard let machine = machines.first(where: { $0.store.isConnected }) ?? machines.first else {
			isAddingMachine = true
			return
		}
		newConversationMachine = machine.id
	}

	/// Starts `draft`'s conversation with `text` as its first message, and shows it in the draft's pane.
	func startConversation(_ draft: Draft, text: String, images: [ImageUpload] = []) async -> Bool {
		guard let machine = machine(draft.machine) else { return false }
		do {
			let summary = try await machine.store.createConversation(project: draft.project?.dir, text: text, images: images)
			let key = ConversationKey(machine: machine.id, conversation: summary.id)
			// A crossfade: the new conversation is blank for a moment while its first snapshot comes, which cut in as a flash.
			withAnimation(.row) {
				// The draft's pane, which may have lost focus while the host made the session.
				if let pane = panes.firstIndex(where: { $0.content == .draft(draft) }) {
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

	/// Hides a conversation from the sidebar's projects, or with false brings it back. A running one keeps running.
	func setArchived(_ target: ConversationKey, _ archived: Bool) {
		guard let machine = machine(target.machine) else { return }
		Task {
			do {
				try await machine.store.setArchived(target.conversation, archived)
			} catch {
				self.error = (error as? ProtocolError)?.message ?? String(describing: error)
			}
		}
	}

	/// The project's sessions that aren't archived; the sidebar shows a project while it has any.
	func activeSessions(in target: ProjectKey) -> [ConversationSummary] {
		machine(target.machine)?.store.state.active.filter { ($0.project ?? "") == target.project } ?? []
	}

	/// Takes a project off the sidebar by archiving its sessions; running ones keep running, and each can be brought back
	/// from the archive.
	func removeProject(_ target: ProjectKey) {
		guard let machine = machine(target.machine) else { return }
		let ids = activeSessions(in: target).map(\.id)
		Task {
			do {
				for id in ids { try await machine.store.setArchived(id, true) }
			} catch {
				self.error = (error as? ProtocolError)?.message ?? String(describing: error)
			}
		}
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
