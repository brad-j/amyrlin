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
	/// How long to gather cost changes before reading the month's total again.
	@ObservationIgnored var monthCostDelay: Duration = .seconds(1)
	@ObservationIgnored private var monthCostTask: Task<Void, Never>?

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
		monthCostTask?.cancel()
		monthCostTask = nil
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

	/// A new conversation, in `project` when the server has projects, starting with `text` when given.
	public func createConversation(title: String? = nil, settings: SettingsChange? = nil, project: String? = nil, text: String? = nil, images: [ImageUpload] = []) async throws -> ConversationSummary {
		let result = try await connection.send(Commands.CreateConversation(title: title, settings: settings, project: project, text: text, images: images))
		state.upsert(result.conversation)
		return result.conversation
	}

	/// Reconnects now rather than when the wait after a failed try is over.
	public func reconnect() async {
		await connection.retryNow()
	}

	public func rename(_ id: ConversationID, to title: String) async throws {
		let result = try await connection.send(Commands.RenameConversation(conversationId: id, title: title))
		state.upsert(result.conversation)
	}

	public func setArchived(_ id: ConversationID, _ archived: Bool) async throws {
		let result = try await connection.send(Commands.ArchiveConversation(conversationId: id, archived: archived))
		state.upsert(result.conversation)
	}

	/// Picks `project`'s colour on this host, or with nil gives it back its name's.
	public func setProjectColor(_ project: String, _ color: Int?) async throws {
		state.projectColors = try await connection.send(Commands.SetProjectColor(project: project, color: color)).projectColors
	}

	private func refreshInfo() async {
		guard let result = try? await connection.send(Commands.HostInfo()) else { return }
		info = result
		state.monthCost = result.monthCost
	}

	/// Reads the month's total again shortly, once for any number of cost changes in the meantime.
	private func refreshMonthCost() {
		guard monthCostTask == nil else { return }
		monthCostTask = Task {
			try? await Task.sleep(for: monthCostDelay)
			monthCostTask = nil
			guard !Task.isCancelled else { return }
			await refreshInfo()
		}
	}

	private func watchHost() async {
		let subscription = await connection.watchHost()
		for await update in subscription.updates {
			switch update {
			case .events(let events):
				watchProblem = nil
				let costs = state.costs
				let hadSnapshot = state.hasSnapshot
				if case .needsResync(let reason) = state.apply(events) {
					await subscription.resync(reason: reason)
				}
				// A snapshot brings its own monthCost; a session charged since needs host.info's.
				let snapshot = events.contains { if case .snapshot = $0 { true } else { false } }
				if hadSnapshot, !snapshot, state.costs != costs { refreshMonthCost() }
			case .resyncing:
				// Keep showing the last list until the fresh snapshot replaces it.
				break
			case .failed(let reason), .ended(let reason):
				watchProblem = reason
			}
		}
	}
}
