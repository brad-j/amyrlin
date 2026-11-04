#if DEBUG
import AppKit

/// `--args -snapshot name.png [-snapshotDelay 6]` draws the app's window into a PNG in the app's temporary directory (its
/// sandbox's) after a wait, for checking a change while the screen is locked, when screencapture gets only black.
/// Debug builds only.
@MainActor enum DebugSnapshot {
	static func start() {
		let arguments = ProcessInfo.processInfo.arguments
		guard let flag = arguments.firstIndex(of: "-snapshot"), flag + 1 < arguments.count else { return }
		let path = FileManager.default.temporaryDirectory.appending(path: arguments[flag + 1]).path
		var delay = 6.0
		if let d = arguments.firstIndex(of: "-snapshotDelay"), d + 1 < arguments.count, let value = Double(arguments[d + 1]) { delay = value }
		Task { @MainActor in
			try? await Task.sleep(for: .seconds(delay))
			write(to: path)
		}
	}

	static func write(to path: String) {
		guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 400 }),
			let view = window.contentView?.superview ?? window.contentView
		else { return }
		let bounds = view.bounds
		guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
		view.cacheDisplay(in: bounds, to: rep)
		try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
		FileHandle.standardError.write(Data("snapshot written: \(path)\n".utf8))
	}
}
#endif
