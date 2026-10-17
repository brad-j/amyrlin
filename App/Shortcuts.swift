import AmyrlinCore
import AppKit
import Observation
import SwiftUI

/// A menu command whose key can be changed in the shortcuts sheet (⌘K).
enum ShortcutCommand: String, CaseIterable, Identifiable {
	case newSession, addMachine, searchSessions, showShortcuts
	case toggleSidebar, toggleInspector
	case splitRight, closePane, nextPane, previousPane
	case biggerText, smallerText, actualSize

	var id: String { rawValue }

	var title: String {
		switch self {
		case .newSession: "New Session…"
		case .addMachine: "Add Machine…"
		case .searchSessions: "Search Sessions"
		case .showShortcuts: "Keyboard Shortcuts"
		case .toggleSidebar: "Show or Hide Sidebar"
		case .toggleInspector: "Show or Hide Inspector"
		case .splitRight: "Split Right"
		case .closePane: "Close Pane"
		case .nextPane: "Next Pane"
		case .previousPane: "Previous Pane"
		case .biggerText: "Bigger Text"
		case .smallerText: "Smaller Text"
		case .actualSize: "Actual Size"
		}
	}

	var defaultCombo: KeyCombo? {
		switch self {
		case .newSession: KeyCombo("n", command: true)
		case .addMachine: KeyCombo("n", command: true, shift: true)
		case .searchSessions: KeyCombo("f", command: true)
		case .showShortcuts: KeyCombo("k", command: true)
		case .toggleSidebar: KeyCombo("s", command: true, control: true)
		case .toggleInspector: KeyCombo("i", command: true, option: true)
		case .splitRight: KeyCombo("d", command: true)
		case .closePane: KeyCombo("w", command: true, shift: true)
		case .nextPane: KeyCombo("]", command: true)
		case .previousPane: KeyCombo("[", command: true)
		case .biggerText: KeyCombo("+", command: true)
		case .smallerText: KeyCombo("-", command: true)
		case .actualSize: KeyCombo("0", command: true)
		}
	}

	/// The sheet's groups, in order.
	static let groups: [(title: String, commands: [ShortcutCommand])] = [
		("sessions", [.newSession, .addMachine, .searchSessions, .showShortcuts]),
		("columns", [.toggleSidebar, .toggleInspector]),
		("panes", [.splitRight, .closePane, .nextPane, .previousPane]),
		("text", [.biggerText, .smallerText, .actualSize]),
	]
}

/// Each command's key: its default unless changed or removed in the shortcuts sheet, kept across launches. The menus
/// read their keys from here, so a change applies at once.
@MainActor @Observable
final class Shortcuts {
	static let shared = Shortcuts()

	/// Changed keys by command; nil for a key removed.
	private(set) var overrides: [ShortcutCommand: KeyCombo?] {
		didSet {
			let stored = Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value) })
			UserDefaults.standard.set(try? JSONEncoder().encode(stored), forKey: Self.defaultsKey)
		}
	}

	private static let defaultsKey = "shortcuts"

	/// Keys the system or the composer already answer to, with what they do; no command can take them.
	static let reserved: [KeyCombo: String] = [
		KeyCombo("q", command: true): "Quit",
		KeyCombo("w", command: true): "Close Window",
		KeyCombo("h", command: true): "Hide",
		KeyCombo("m", command: true): "Minimize",
		KeyCombo(",", command: true): "Settings",
		KeyCombo("c", command: true): "Copy",
		KeyCombo("v", command: true): "Paste",
		KeyCombo("x", command: true): "Cut",
		KeyCombo("a", command: true): "Select All",
		KeyCombo("z", command: true): "Undo",
		KeyCombo("z", command: true, shift: true): "Redo",
		KeyCombo("\r", command: true): "the composer's steer",
		KeyCombo("\r", shift: true): "the composer's new line",
		KeyCombo("\r", option: true): "the composer's new line",
	]

	private init() {
		let data = UserDefaults.standard.data(forKey: Self.defaultsKey)
		let stored = data.flatMap { try? JSONDecoder().decode([String: KeyCombo?].self, from: $0) } ?? [:]
		overrides = Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in ShortcutCommand(rawValue: key).map { ($0, value) } })
	}

	func combo(_ command: ShortcutCommand) -> KeyCombo? {
		if let override = overrides[command] { return override }
		return command.defaultCombo
	}

	func shortcut(_ command: ShortcutCommand) -> KeyboardShortcut? {
		guard let combo = combo(command), let key = combo.key.first else { return nil }
		return KeyboardShortcut(KeyEquivalent(key), modifiers: combo.modifiers)
	}

	func isChanged(_ command: ShortcutCommand) -> Bool { overrides.keys.contains(command) }

	var anyChanged: Bool { !overrides.isEmpty }

	/// Why `combo` can't be `command`'s, or nil when it can.
	func problem(_ combo: KeyCombo, for command: ShortcutCommand) -> String? {
		if !combo.isUsable { return "\(combo.display) would type into the composer; add ⌘, ⌃ or ⌥" }
		if let use = Self.reserved[combo] { return "\(combo.display) is \(use)" }
		if combo.isArrow, combo.command || combo.option, !combo.control { return "\(combo.display) moves the cursor in text" }
		if let owner = ShortcutCommand.allCases.first(where: { $0 != command && self.combo($0) == combo }) {
			return "\(combo.display) is already \(owner.title)"
		}
		return nil
	}

	/// Gives `command` a new key, or with nil takes its key away.
	func set(_ combo: KeyCombo?, for command: ShortcutCommand) {
		if combo == command.defaultCombo {
			overrides.removeValue(forKey: command)
		} else {
			overrides[command] = .some(combo)
		}
	}

	func reset(_ command: ShortcutCommand) {
		overrides.removeValue(forKey: command)
	}

	func resetAll() {
		overrides = [:]
	}
}

extension KeyCombo {
	/// The key an event types with no modifiers, and the modifiers held.
	init?(_ event: NSEvent) {
		guard let key = event.characters(byApplyingModifiers: []), key.count == 1 else { return nil }
		let flags = event.modifierFlags
		self.init(key, command: flags.contains(.command), shift: flags.contains(.shift), option: flags.contains(.option), control: flags.contains(.control))
	}

	var modifiers: EventModifiers {
		var modifiers: EventModifiers = []
		if command { modifiers.insert(.command) }
		if shift { modifiers.insert(.shift) }
		if option { modifiers.insert(.option) }
		if control { modifiers.insert(.control) }
		return modifiers
	}
}

extension View {
	/// The command's key from Shortcuts, or none when it was removed.
	func keyboardShortcut(_ command: ShortcutCommand, in shortcuts: Shortcuts) -> some View {
		keyboardShortcut(shortcuts.shortcut(command))
	}
}

/// Takes the next key pressed in the app, before the menus see it, while the shortcuts sheet records one.
@MainActor @Observable
final class KeyRecorder {
	private(set) var recording: ShortcutCommand?
	private var monitor: Any?

	/// Calls `handle` with each key down until `stop`; the key goes no further.
	func start(_ command: ShortcutCommand, handle: @escaping @MainActor (NSEvent) -> Void) {
		stop()
		recording = command
		monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
			MainActor.assumeIsolated { handle(event) }
			return nil
		}
	}

	func stop() {
		if let monitor { NSEvent.removeMonitor(monitor) }
		monitor = nil
		recording = nil
	}
}

/// Every keyboard shortcut (⌘K), in two columns of groups: the menu commands', which a click changes, then the fixed
/// keys of the composer and the sidebar. Set in Plex Sans with each key on its own cap, as a reference reads.
struct ShortcutsSheet: View {
	let shortcuts: Shortcuts
	@Environment(\.dismiss) private var dismiss
	@State private var recorder = KeyRecorder()
	@State private var problem: String?

	/// Keys that aren't menu commands, so they don't change: each a list of combinations, each a list of caps.
	private static let composer: [(caps: [[String]], title: String)] = [
		([["↩"]], "Send, or queue while running"),
		([["⌘", "↩"]], "Steer the run once"),
		([["⇧", "↩"], ["⌥", "↩"]], "New line"),
		([["esc"]], "Stop the run"),
		([["⌘", "V"]], "Paste images or long text"),
	]
	private static let sidebar: [(caps: [[String]], title: String)] = [
		([["↑"], ["↓"]], "Move between sessions"),
		([["⌘", "click"]], "Open in a new pane"),
		([["↩"]], "Open the first match"),
		([["esc"]], "Clear the search"),
	]

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			HStack {
				Text("Keyboard Shortcuts").font(Typography.uiSansStrong).foregroundStyle(Palette.ink)
				Spacer()
				if shortcuts.anyChanged {
					Button("Reset All") {
						recorder.stop()
						problem = nil
						shortcuts.resetAll()
					}
					.buttonStyle(.plain)
					.font(Typography.uiSansSmall)
					.foregroundStyle(Palette.ink3)
				}
			}
			.padding(.horizontal, 22)
			.frame(height: Metrics.bar + 8)
			Rectangle().fill(Palette.rule).frame(height: 1)
			// Scrolls only when the text is too big for the screen.
			ViewThatFits(in: .vertical) {
				columns
				ScrollView { columns }
			}
			Rectangle().fill(Palette.rule).frame(height: 1)
			HStack(spacing: 12) {
				Group {
					if let problem {
						Text(problem).foregroundStyle(Palette.bad)
					} else if recorder.recording != nil {
						Text("Press the new shortcut. Delete removes it; esc cancels.").foregroundStyle(Palette.accent)
					} else {
						Text("Click a shortcut to change it.").foregroundStyle(Palette.ink3)
					}
				}
				.font(Typography.uiSansSmall)
				.lineLimit(1)
				Spacer()
				Button("Done") { dismiss() }
					.buttonStyle(QuietButton(font: Typography.uiSans))
					.keyboardShortcut(.cancelAction)
			}
			.padding(.horizontal, 22)
			.padding(.vertical, 12)
		}
		.frame(width: 780 * Typography.scale)
		.background(Palette.paper)
		.onDisappear { recorder.stop() }
	}

	private var columns: some View {
		let groups = ShortcutCommand.groups
		return HStack(alignment: .top, spacing: 40) {
			VStack(alignment: .leading, spacing: 22) {
				commandGroup(groups[0])
				commandGroup(groups[1])
				fixedGroup("Composer", Self.composer)
			}
			VStack(alignment: .leading, spacing: 22) {
				commandGroup(groups[2])
				commandGroup(groups[3])
				fixedGroup("Sidebar", Self.sidebar)
			}
		}
		.padding(.horizontal, 22)
		.padding(.vertical, 20)
	}

	private func commandGroup(_ group: (title: String, commands: [ShortcutCommand])) -> some View {
		section(group.title.capitalized) {
			ForEach(group.commands) { command in
				EditableShortcutRow(
					command: command,
					combo: shortcuts.combo(command),
					changed: shortcuts.isChanged(command),
					recording: recorder.recording == command,
					toggle: { recorder.recording == command ? stopRecording() : record(command) },
					reset: { shortcuts.reset(command) }
				)
			}
		}
	}

	private func fixedGroup(_ title: String, _ rows: [(caps: [[String]], title: String)]) -> some View {
		section(title) {
			ForEach(rows, id: \.title) { row in
				HStack(spacing: 12) {
					Text(row.title).foregroundStyle(Palette.ink2)
					Spacer(minLength: 12)
					HStack(spacing: 8) {
						ForEach(row.caps.indices, id: \.self) { index in KeyCaps(symbols: row.caps[index]) }
					}
				}
				.frame(minHeight: 26 * Typography.scale)
			}
		}
	}

	private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
		VStack(alignment: .leading, spacing: 2) {
			Text(title).font(Typography.uiSansSmall.weight(.medium)).foregroundStyle(Palette.ink3).padding(.bottom, 6)
			content()
		}
		.font(Typography.uiSans)
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	private func record(_ command: ShortcutCommand) {
		problem = nil
		recorder.start(command) { event in
			let bare = event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty
			switch event.keyCode {
			case 53 where bare: // Esc
				stopRecording()
			case 51 where bare, 117 where bare: // Delete, Forward Delete
				shortcuts.set(nil, for: command)
				stopRecording()
			default:
				guard let combo = KeyCombo(event) else { return }
				if let reason = shortcuts.problem(combo, for: command) {
					problem = reason
				} else {
					shortcuts.set(combo, for: command)
					stopRecording()
				}
			}
		}
	}

	private func stopRecording() {
		recorder.stop()
		problem = nil
	}
}

/// A menu command and its keys, which a click records anew; Reset shows once it's changed.
private struct EditableShortcutRow: View {
	let command: ShortcutCommand
	let combo: KeyCombo?
	let changed: Bool
	let recording: Bool
	let toggle: () -> Void
	let reset: () -> Void
	@State private var hovering = false

	var body: some View {
		HStack(spacing: 10) {
			// The menu's "…" says a sheet follows; here it's only noise.
			Text(command.title.replacingOccurrences(of: "…", with: "")).foregroundStyle(Palette.ink)
			Spacer(minLength: 12)
			if changed, !recording {
				Button("Reset", action: reset)
					.buttonStyle(.plain)
					.font(Typography.uiSansSmall)
					.foregroundStyle(Palette.ink3)
					.help("Back to \(command.defaultCombo?.display ?? "none")")
			}
			Button(action: toggle) {
				Group {
					if recording {
						Text("Type shortcut")
							.font(Typography.uiSansSmall)
							.foregroundStyle(Palette.accentInk)
							.padding(.horizontal, 8)
							.frame(minHeight: 20 * Typography.scale)
							.background(Palette.accent)
					} else if let combo {
						KeyCaps(symbols: combo.symbols, highlighted: hovering)
					} else {
						Text("none")
							.font(Typography.uiSansSmall)
							.foregroundStyle(Palette.ink3)
							.padding(.horizontal, 8)
							.frame(minHeight: 20 * Typography.scale)
							.overlay(Rectangle().stroke(hovering ? Palette.ink3 : Palette.rule2, style: StrokeStyle(lineWidth: 1, dash: [2, 2])))
					}
				}
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.onHover { hovering = $0 }
			.help(recording ? "Press the new shortcut" : "Change the shortcut")
		}
		.frame(minHeight: 26 * Typography.scale)
	}
}

/// Keys as caps, one symbol each: `⇧` `⌘` `D`.
struct KeyCaps: View {
	let symbols: [String]
	var highlighted = false

	var body: some View {
		HStack(spacing: 3) {
			ForEach(symbols.indices, id: \.self) { index in
				Text(symbols[index])
					.font(Typography.keyCap)
					.foregroundStyle(highlighted ? Palette.ink : Palette.ink2)
					.padding(.horizontal, 5)
					.frame(minWidth: 20 * Typography.scale, minHeight: 20 * Typography.scale)
					.background(Palette.paper3)
					.overlay(Rectangle().stroke(highlighted ? Palette.ink3 : Palette.rule2))
			}
		}
	}
}
