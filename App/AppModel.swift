import AmyrlinCore
import Foundation
import Observation

/// Identifies a conversation across machines: conversation IDs are unique only within one host.
struct ConversationKey: Hashable {
	let machine: UUID
	let conversation: ConversationID
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
	var selection: ConversationKey?
	var showInspector = true
	var isAddingMachine = false
	/// The machine a new conversation is being started on, while its sheet is open.
	var newConversationMachine: UUID?
	/// A failed app-level action, shown once in the window.
	var error: String?

	private static let defaultsKey = "machines"
	private let client = ClientInfo(
		name: "amyrlin",
		version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
	)

	init() {
		let saved = UserDefaults.standard.array(forKey: Self.defaultsKey) as? [[String: String]] ?? []
		let entries = saved.compactMap { entry -> (UUID, URL)? in
			guard let id = entry["id"].flatMap(UUID.init(uuidString:)), let url = entry["url"].flatMap(URL.init(string:)) else { return nil }
			return (id, url)
		}
		for (id, url) in entries {
			machines.append(makeMachine(id: id, url: url))
		}
		save()
		for machine in machines { machine.store.start() }
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

	/// Starts a conversation in `project` with `text` as its first message, and selects it.
	func startConversation(on machine: Machine, project: String?, text: String) async -> Bool {
		do {
			let summary = try await machine.store.createConversation(project: project, text: text)
			selection = ConversationKey(machine: machine.id, conversation: summary.id)
			return true
		} catch {
			self.error = (error as? ProtocolError)?.message ?? String(describing: error)
			return false
		}
	}

	private func makeMachine(id: UUID, url: URL) -> Machine {
		Machine(id: id, url: url, store: HostStore(url: url, client: client))
	}

	private func save() {
		UserDefaults.standard.set(machines.map { ["id": $0.id.uuidString, "url": $0.url.absoluteString] }, forKey: Self.defaultsKey)
	}
}
