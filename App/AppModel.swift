import AmyrlinCore
import Foundation
import Observation
import SwiftUI

/// Identifies a conversation across machines: conversation IDs are unique only within one host.
struct ConversationKey: Hashable {
	let machine: UUID
	let conversation: ConversationID
}

/// A conversation not created yet: a project picked, no message sent. The first message creates it on the host.
struct Draft: Equatable {
	let machine: UUID
	/// Nil for a no-project session: the host gives it a scratch directory of its own.
	let project: ProjectInfo?
}

/// The machines the app knows, persisted as URLs, and the current selection.
@MainActor @Observable
final class AppModel {
	struct Machine: Identifiable {
		let id: UUID
		let url: URL
		let store: HostStore
	}

	private(set) var machines: [Machine] = []
	var selection: ConversationKey? {
		didSet {
			if selection != nil { draft = nil }
			// Reopened at the next launch.
			if let selection {
				UserDefaults.standard.set(["machine": selection.machine.uuidString, "conversation": String(selection.conversation)], forKey: Self.selectionKey)
			} else {
				UserDefaults.standard.removeObject(forKey: Self.selectionKey)
			}
		}
	}
	/// Shown in place of a conversation until its first message is sent.
	var draft: Draft?
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
	/// The conversation whose title is being changed.
	var renaming: ConversationKey?
	/// The machine a new conversation is being started on, while its sheet is open.
	var newConversationMachine: UUID?
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
		// `--args -showInspector` opens the inspector, which starts closed, and `-openDraft` a no-project draft on the
		// first machine, for screenshots.
		if ProcessInfo.processInfo.arguments.contains("-showInspector") { showInspector = true }
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
		if selection?.machine == id { selection = nil }
		save()
		Task { await machine.store.stop() }
	}

	func machine(_ id: UUID) -> Machine? {
		machines.first { $0.id == id }
	}

	/// The selected conversation's machine and store.
	var selected: (machine: Machine, conversation: ConversationStore)? {
		guard let selection, let machine = machine(selection.machine) else { return nil }
		return (machine, machine.store.conversation(selection.conversation))
	}

	/// Opens an empty conversation for `project`; nothing is created on the host until the first message.
	func openDraft(on machine: UUID, project: ProjectInfo?) {
		selection = nil
		draft = Draft(machine: machine, project: project)
	}

	/// Opens the project picker on the first connected machine (⌘N).
	func newSession() {
		guard let machine = machines.first(where: { $0.store.isConnected }) ?? machines.first else {
			isAddingMachine = true
			return
		}
		newConversationMachine = machine.id
	}

	/// Starts a conversation in `project` with `text` as its first message, and selects it.
	func startConversation(on machine: Machine, project: String?, text: String, images: [ImageUpload] = []) async -> Bool {
		do {
			let summary = try await machine.store.createConversation(project: project, text: text, images: images)
			selection = ConversationKey(machine: machine.id, conversation: summary.id)
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

	private func makeMachine(id: UUID, url: URL) -> Machine {
		Machine(id: id, url: url, store: HostStore(url: url, client: client))
	}

	private func save() {
		guard !ephemeral else { return }
		UserDefaults.standard.set(machines.map { ["id": $0.id.uuidString, "url": $0.url.absoluteString] }, forKey: Self.defaultsKey)
	}
}
