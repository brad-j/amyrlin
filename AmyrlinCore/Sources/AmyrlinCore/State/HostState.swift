import Foundation

/// One machine's conversation list and spend, built from `host.watch` (protocol section 6.2).
public struct HostState: Sendable, Hashable {
	public var host: HostIdentity?
	public var spend: Spend = .zero
	/// Projects whose colour was picked on this host: name to `ProjectColor.hues` index.
	public var projectColors: [String: Int] = [:]
	public private(set) var conversations: [ConversationID: ConversationSummary] = [:]
	public private(set) var hasSnapshot = false

	public init() {}

	/// Unarchived conversations, most recently active first.
	public var active: [ConversationSummary] {
		conversations.values.filter { !$0.archived }.sorted(by: Self.newestFirst)
	}

	public var archived: [ConversationSummary] {
		conversations.values.filter(\.archived).sorted(by: Self.newestFirst)
	}

	private static func newestFirst(_ a: ConversationSummary, _ b: ConversationSummary) -> Bool {
		a.updatedAt != b.updatedAt ? a.updatedAt > b.updatedAt : a.id > b.id
	}

	/// Applies a summary the client got from a command result, such as `conversations.create`.
	public mutating func upsert(_ summary: ConversationSummary) {
		conversations[summary.id] = summary
	}

	@discardableResult
	public mutating func apply(_ events: [HostEvent]) -> ConversationState.Outcome {
		for event in events {
			let outcome = apply(event)
			if case .needsResync = outcome { return outcome }
		}
		return .applied
	}

	@discardableResult
	public mutating func apply(_ event: HostEvent) -> ConversationState.Outcome {
		if !hasSnapshot {
			guard case .snapshot = event else { return .needsResync(reason: "event before the first snapshot") }
		}
		switch event {
		case .snapshot(let snapshot):
			host = snapshot.host
			spend = snapshot.spend
			projectColors = snapshot.projectColors ?? [:]
			conversations = Dictionary(snapshot.conversations.map { ($0.id, $0) }) { _, last in last }
			hasSnapshot = true
		case .conversationUpdated(let summary):
			conversations[summary.id] = summary
		case .conversationRemoved(let id):
			conversations[id] = nil
		case .spend(let spend):
			self.spend = spend
		case .projectColors(let colors):
			projectColors = colors
		case .unknown(let type):
			return .needsResync(reason: "unknown event type \(type)")
		}
		return .applied
	}
}
