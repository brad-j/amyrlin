import Foundation
import Observation

/// One machine: its connection, its conversation list and spend, and the stores of the conversations open on it.
@MainActor @Observable
public final class HostStore {
	public let url: URL
	public private(set) var status: HostConnection.Status = .idle
	public private(set) var state = HostState()
	public private(set) var info: Commands.HostInfo.Result?
	/// Set when `host.watch` gave up or ended; the list is then stale.
	public private(set) var watchProblem: String?

	@ObservationIgnored public let connection: HostConnection
	@ObservationIgnored private var tasks: [Task<Void, Never>] = []
	@ObservationIgnored private var stores: [ConversationID: ConversationStore] = [:]

	public init(url: URL, client: ClientInfo, transport: any WebSocketTransport = URLSessionTransport(), policy: ReconnectPolicy = .standard) {
		self.url = url
		connection = HostConnection(url: url, transport: transport, client: client, policy: policy)
	}

	public init(connection: HostConnection) {
		url = connection.url
		self.connection = connection
	}

	public var isConnected: Bool {
		if case .connected = status { true } else { false }
	}

	public func start() {
		guard tasks.isEmpty else { return }
		let connection = connection
		tasks.append(Task {
			for await status in connection.statusUpdates {
				self.status = status
				if case .connected = status { await self.refreshInfo() }
			}
		})
		tasks.append(Task { await self.watchHost() })
		Task { await connection.start() }
	}

	public func stop() async {
		for task in tasks { task.cancel() }
		tasks = []
		for store in stores.values { store.stop() }
		await connection.stop()
	}

	/// The store for one conversation, created on first use. Call `start()` on it to watch.
	public func conversation(_ id: ConversationID) -> ConversationStore {
		if let store = stores[id] { return store }
		let store = ConversationStore(id: id, connection: connection)
		stores[id] = store
		return store
	}

	public func createConversation(title: String? = nil, settings: SettingsChange? = nil) async throws -> ConversationSummary {
		let result = try await connection.send(Commands.CreateConversation(title: title, settings: settings))
		state.upsert(result.conversation)
		return result.conversation
	}

	public func setArchived(_ id: ConversationID, _ archived: Bool) async throws {
		let result = try await connection.send(Commands.ArchiveConversation(conversationId: id, archived: archived))
		state.upsert(result.conversation)
	}

	private func refreshInfo() async {
		info = try? await connection.send(Commands.HostInfo())
	}

	private func watchHost() async {
		let subscription = await connection.watchHost()
		for await update in subscription.updates {
			switch update {
			case .events(let events):
				watchProblem = nil
				if case .needsResync(let reason) = state.apply(events) {
					await subscription.resync(reason: reason)
				}
			case .resyncing:
				// Keep showing the last list until the fresh snapshot replaces it.
				break
			case .failed(let reason), .ended(let reason):
				watchProblem = reason
			}
		}
	}
}
