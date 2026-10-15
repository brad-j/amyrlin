import AppKit

/// Copies text as soon as it's selected with the mouse, as a terminal does: a drag, a double or triple click, or a
/// shift-click. Only read-only text copies itself (the transcript, the inspector, labels), so selecting in the composer
/// to type or paste over it leaves the pasteboard alone.
///
/// Selectable SwiftUI `Text` is a text field whose field editor, a read-only `NSTextView`, holds the selection; it posts
/// one selection change when the mouse comes up.
@MainActor
enum CopyOnSelect {
	private static var observer: NSObjectProtocol?

	static func start() {
		guard observer == nil else { return }
		observer = NotificationCenter.default.addObserver(forName: NSTextView.didChangeSelectionNotification, object: nil, queue: .main) { note in
			let view = note.object as? NSTextView
			MainActor.assumeIsolated { copy(from: view) }
		}
	}

	private static func copy(from view: NSTextView?) {
		// Mouse-up only: a field takes focus on mouse-down, selecting all of itself for a moment while still editable.
		guard let view, !view.isEditable, NSApp.currentEvent?.type == .leftMouseUp else { return }
		let range = view.selectedRange()
		guard range.length > 0 else { return }
		let text = (view.string as NSString).substring(with: range)
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(text, forType: .string)
	}
}
