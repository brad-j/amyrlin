import Foundation
import Observation

/// One machine: its connection, its conversation list and spend, and the stores of the conversations open on it.
@MainActor @Observable
public final class HostStore {
	public let url: URL
	public private(set) var status: HostConnection.Status = .idle
	public private(set) var state = HostState()
	public private(set) var info: Commands.HostInfo.Result?
	/// The host's settings as last read, on each connect and by `refreshSettings`. Nil until then, and for a host from
	/// before `settings.get`, which has none to offer.
	public private(set) var settings: HostSettings?
	/// aludra's own methods this host answered `unknown_method` to, so the app stops offering them. Cleared on each
	/// connect, since the machine may come back running a newer aludra.
	public private(set) var lacking: Set<String> = []
	/// Set when `host.watch` gave up or ended; the list is then stale.
	public private(set) var watchProblem: String?
	/// Told when sessions start needing approval, finish a run or get stuck (SessionAlerts), as `host.watch` reports it.
	@ObservationIgnored public var onAlerts: (@MainActor ([SessionAlert]) -> Void)?

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
				if case .connected = status {
					self.lacking = []
					await self.refreshInfo()
					// Apart, so a slow answer doesn't hold up the statuses after it.
					Task { await self.refreshSettings() }
				}
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
	public func createConversation(title: String? = nil, settings: SettingsChange? = nil, project: String? = nil, text: String? = nil, images: [ImageUpload] = [], videos: [VideoUpload] = []) async throws -> ConversationSummary {
		let result = try await connection.send(Commands.CreateConversation(title: title, settings: settings, project: project, text: text, images: images, videos: videos))
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

	/// Whether the host has `method`, as far as the app knows: until it answers `unknown_method`, it's taken to.
	public func has(_ method: String) -> Bool {
		!lacking.contains(method)
	}

	/// Sends one of aludra's own commands, noting `unknown_method` so `has` says the host lacks it from then on.
	public func sendExtension<C: Command>(_ command: C) async throws -> C.Result {
		do {
			return try await connection.send(command)
		} catch let error as ProtocolError where error.code == "unknown_method" {
			lacking.insert(C.method)
			throw error
		}
	}

	/// Has a model write the title again from the whole conversation; false when no model did and the title stayed.
	@discardableResult
	public func retitle(_ id: ConversationID) async throws -> Bool {
		let result = try await sendExtension(Commands.RetitleConversation(conversationId: id))
		state.upsert(result.conversation)
		return result.written
	}

	/// Picks `project`'s colour on this host, or with nil gives it back its name's.
	public func setProjectColor(_ project: String, _ color: Int?) async throws {
		state.projectColors = try await connection.send(Commands.SetProjectColor(project: project, color: color)).projectColors
	}

	/// Reads the host's settings again. A host without them answers `unknown_method`, which clears them; any other
	/// failure keeps the last ones.
	public func refreshSettings() async {
		do {
			settings = try await connection.send(Commands.GetSettings()).settings
		} catch let error as ProtocolError where error.code == "unknown_method" {
			settings = nil
		} catch {}
	}

	/// Saves `changes` to the host's settings and returns them all after. A refused change throws `invalid_settings`
	/// (`ProtocolError.reasons` has each reason) and saves nothing. Projects, models and defaults come from the settings,
	/// so `host.info` is read again.
	@discardableResult
	public func saveSettings(_ changes: [String: SettingChange]) async throws -> HostSettings {
		let saved = try await connection.send(Commands.SetSettings(changes: changes)).settings
		settings = saved
		await refreshInfo()
		return saved
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
				// One event at a time, so a session that asks and is answered within a batch still says so.
				var alerts: [SessionAlert] = []
				for event in events {
					let before = state.conversations
					if case .needsResync(let reason) = state.apply(event) {
						await subscription.resync(reason: reason)
						break
					}
					alerts += SessionAlerts.between(before, state.conversations)
				}
				if !alerts.isEmpty { onAlerts?(alerts) }
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
