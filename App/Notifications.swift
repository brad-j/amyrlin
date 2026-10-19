import AmyrlinCore
import AppKit
import UserNotifications

/// System notifications for alerts that arrive while the app isn't in front, where the toasts can't be seen, and the
/// Dock badge, which counts sessions waiting for a tool call to be allowed. A session's newer notification replaces its
/// older one, a click opens the session, and one saying a session needs you is withdrawn once it doesn't.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
	/// Opens a clicked notification's session.
	var onOpen: ((ConversationKey) -> Void)?

	private let center = UNUserNotificationCenter.current()
	/// Sessions with a "needs you" notification delivered, by identifier.
	private var waiting: [String: ConversationKey] = [:]

	override init() {
		super.init()
		center.delegate = self
	}

	/// Asks once for permission to alert; later calls return the first answer without asking.
	func requestPermission() {
		center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
	}

	func post(_ kind: SessionAlert.Kind, for key: ConversationKey, title: String, detail: String) {
		let content = UNMutableNotificationContent()
		content.title = title
		content.body = detail
		content.sound = .default
		content.threadIdentifier = key.machine.uuidString
		content.userInfo = ["machine": key.machine.uuidString, "conversation": String(key.conversation)]
		let id = Self.identifier(key)
		if kind == .needsYou { waiting[id] = key } else { waiting[id] = nil }
		center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
	}

	/// Takes away the sessions' notifications, as when they're opened.
	func withdraw(_ keys: some Sequence<ConversationKey>) {
		let ids = keys.map(Self.identifier)
		guard !ids.isEmpty else { return }
		for id in ids { waiting[id] = nil }
		center.removeDeliveredNotifications(withIdentifiers: ids)
	}

	/// Sets the Dock badge to the number of sessions needing you, and withdraws "needs you" notifications for sessions
	/// that no longer do.
	func update(needingYou: Set<ConversationKey>) {
		NSApplication.shared.dockTile.badgeLabel = needingYou.isEmpty ? nil : String(needingYou.count)
		withdraw(waiting.values.filter { !needingYou.contains($0) })
	}

	private static func identifier(_ key: ConversationKey) -> String {
		"\(key.machine.uuidString)/\(key.conversation)"
	}

	nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
		let info = response.notification.request.content.userInfo
		guard let machine = (info["machine"] as? String).flatMap(UUID.init(uuidString:)),
			let conversation = (info["conversation"] as? String).flatMap(ConversationID.init)
		else { return }
		await MainActor.run {
			NSApplication.shared.activate()
			onOpen?(ConversationKey(machine: machine, conversation: conversation))
		}
	}
}
