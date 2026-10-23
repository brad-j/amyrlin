import Foundation

/// A host's settings as a form: what each field holds while it's edited, and the changes they make. Every field comes
/// from the setting's own description, so a setting the host adds shows without a change here, as in aludra's web app
/// (app/components/Settings.tsx). Only what changed is sent.
public struct SettingsForm: Sendable, Hashable {
	/// What a field holds while it's edited: lists one entry per line, numbers as typed.
	public enum Draft: Sendable, Hashable {
		case text(String)
		case workspaces([WorkspaceDraft])
	}

	public struct WorkspaceDraft: Sendable, Hashable, Identifiable {
		public let id: UUID
		public var name: String
		/// Path patterns, one per line.
		public var roots: String

		public init(id: UUID = UUID(), name: String = "", roots: String = "") {
			self.id = id
			self.name = name
			self.roots = roots
		}
	}

	public private(set) var settings: HostSettings
	public private(set) var drafts: [String: Draft]
	/// Settings put back to their default, sent as null so the file stops naming them.
	public private(set) var reset: Set<String> = []

	public init(_ settings: HostSettings) {
		self.settings = settings
		drafts = Dictionary(settings.settings.map { ($0.key, Self.draft(of: $0, $0.value)) }) { _, last in last }
	}

	/// Whether the form changes `setting`: the host lets clients change it, and this app knows its kind's control.
	public static func isEditable(_ setting: HostSetting) -> Bool {
		guard setting.editable else { return false }
		if case .unknown = setting.kind { return false }
		return true
	}

	public func draft(_ key: String) -> Draft {
		drafts[key] ?? .text("")
	}

	public mutating func edit(_ key: String, _ draft: Draft) {
		drafts[key] = draft
	}

	/// Fills the field with the setting's default, which the save sends as null while the field still holds it.
	public mutating func useDefault(_ setting: HostSetting) {
		guard let value = setting.default else { return }
		drafts[setting.key] = Self.draft(of: setting, value)
		reset.insert(setting.key)
	}

	/// Whether the field holds the setting's default; false for a setting without one.
	public func isAtDefault(_ setting: HostSetting) -> Bool {
		setting.default != nil && Self.value(of: setting, draft(setting.key)) == setting.default
	}

	/// What a save sends: each editable setting whose field differs from its value, and those put back to the default.
	public var changes: [String: SettingChange] {
		var changes: [String: SettingChange] = [:]
		for setting in settings.settings where Self.isEditable(setting) {
			let value = Self.value(of: setting, draft(setting.key))
			if reset.contains(setting.key), value == setting.default {
				changes[setting.key] = .toDefault
			} else if value != setting.value {
				changes[setting.key] = .value(value)
			}
		}
		return changes
	}

	public var isDirty: Bool { !changes.isEmpty }

	/// The field for `value` of `setting`.
	public static func draft(of setting: HostSetting, _ value: SettingValue) -> Draft {
		switch value {
		case .workspaces(let workspaces):
			.workspaces(workspaces.map { WorkspaceDraft(name: $0.name, roots: $0.roots.joined(separator: "\n")) })
		case .list(let list):
			.text(list.joined(separator: "\n"))
		case .text(let text):
			.text(text)
		case .number(let number):
			.text(numberText(number))
		case .other(let value):
			.text(value.jsonText)
		}
	}

	/// The value a field means, as the host takes it. A number that isn't one goes as typed, for the host to refuse
	/// with its reason.
	public static func value(of setting: HostSetting, _ draft: Draft) -> SettingValue {
		switch draft {
		case .workspaces(let workspaces):
			return .workspaces(workspaces.map { Workspace(name: $0.name.trimmingCharacters(in: .whitespaces), roots: lines($0.roots)) })
		case .text(let text):
			switch setting.kind {
			case .list, .models:
				return .list(lines(text))
			case .number, .integer:
				let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
				if let number = Double(trimmed), number.isFinite { return .number(number) }
				return .text(trimmed)
			default:
				return .text(text.trimmingCharacters(in: .whitespacesAndNewlines))
			}
		}
	}

	/// A value in a line, for settings shown but not edited here: lists joined by commas, `none` for an empty one.
	public static func shown(_ value: SettingValue) -> String {
		switch value {
		case .text(let text): text
		case .number(let number): numberText(number)
		case .list(let list): list.isEmpty ? "none" : list.joined(separator: ", ")
		case .workspaces(let workspaces):
			workspaces.isEmpty ? "none" : workspaces.map { "\($0.name): \($0.roots.joined(separator: ", "))" }.joined(separator: "; ")
		case .other(let value): value.jsonText
		}
	}

	/// The non-empty lines of `text`, trimmed.
	static func lines(_ text: String) -> [String] {
		text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
	}

	/// `24` rather than `24.0` for a whole number.
	private static func numberText(_ number: Double) -> String {
		number.rounded() == number && abs(number) < 1e15 ? String(Int64(number)) : String(number)
	}
}
