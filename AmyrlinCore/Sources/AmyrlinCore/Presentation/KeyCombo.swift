import Foundation

/// A key with its modifiers, as a menu command's shortcut is saved and shown: `⇧⌘D`. `key` is one character, the one
/// the key types with no modifiers, or AppKit's character for a key that types none (the arrows, F1 to F12).
public struct KeyCombo: Codable, Hashable, Sendable {
	public var key: String
	public var command: Bool
	public var shift: Bool
	public var option: Bool
	public var control: Bool

	public init(_ key: String, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
		self.key = Self.normalize(key)
		self.command = command
		self.shift = shift
		self.option = option
		self.control = control
	}

	/// Lowercased, so ⇧ is only ever the modifier; Delete as SwiftUI's KeyEquivalent.delete, and Enter as Return.
	static func normalize(_ key: String) -> String {
		switch key {
		case "\u{7F}": "\u{08}"
		case "\u{03}": "\r"
		default: key.lowercased()
		}
	}

	/// Modifiers in the order macOS menus write them, then the key: `⌃⌥⇧⌘K`.
	public var display: String {
		(control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + keyName
	}

	/// One symbol per key, for drawing each on its own cap: `["⇧", "⌘", "D"]`.
	public var symbols: [String] {
		[(control, "⌃"), (option, "⌥"), (shift, "⇧"), (command, "⌘")].filter(\.0).map(\.1) + [keyName]
	}

	public var keyName: String {
		if let name = Self.names[key] { return name }
		if let scalar = key.unicodeScalars.first, key.unicodeScalars.count == 1, (0xF704...0xF70F).contains(scalar.value) {
			return "F\(scalar.value - 0xF704 + 1)"
		}
		return key.uppercased()
	}

	private static let names: [String: String] = [
		"\r": "↩", "\u{1B}": "⎋", "\u{08}": "⌫", "\u{F728}": "⌦", "\t": "⇥", " ": "Space",
		"\u{F700}": "↑", "\u{F701}": "↓", "\u{F702}": "←", "\u{F703}": "→",
		"\u{F729}": "↖", "\u{F72B}": "↘", "\u{F72C}": "⇞", "\u{F72D}": "⇟",
	]

	public var isFunctionKey: Bool {
		guard let scalar = key.unicodeScalars.first, key.unicodeScalars.count == 1 else { return false }
		return (0xF704...0xF70F).contains(scalar.value)
	}

	public var isArrow: Bool { ["\u{F700}", "\u{F701}", "\u{F702}", "\u{F703}"].contains(key) }

	/// Whether a menu can take it without stealing typing: it needs ⌘, ⌃ or ⌥, or is a function key.
	public var isUsable: Bool { command || control || option || isFunctionKey }
}
