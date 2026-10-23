import Foundation

// A host's settings, from aludra's `settings.get` and `settings.set` (its own additions, outside v1; aludra's
// src/api-types.ts, Setting and Settings). Each setting describes itself, so the app draws its form from the list
// rather than knowing aludra's settings. A host from before them answers `unknown_method`.

/// How a setting's value is shaped, for drawing its control: `text` and `path` are strings, `number` and `integer`
/// numbers, `list` a list of strings, `model` a model as `provider/id`, `models` a list of those, `choice` one of the
/// setting's `options`, and `workspaces` a list of `{name, roots}`.
public enum SettingKind: OpenEnum {
	case text, path, number, integer, list, model, models, choice, workspaces
	case unknown(String)

	public static let known: [SettingKind] = [.text, .path, .number, .integer, .list, .model, .models, .choice, .workspaces]

	public init(rawValue: String) {
		self = Self.known.first { $0.rawValue == rawValue } ?? .unknown(rawValue)
	}

	public var rawValue: String {
		switch self {
		case .text: "text"
		case .path: "path"
		case .number: "number"
		case .integer: "integer"
		case .list: "list"
		case .model: "model"
		case .models: "models"
		case .choice: "choice"
		case .workspaces: "workspaces"
		case .unknown(let raw): raw
		}
	}
}

/// A workspace: a name, and the path patterns its projects are found by (`~/code/*`).
public struct Workspace: Codable, Sendable, Hashable {
	public var name: String
	public var roots: [String]

	public init(name: String, roots: [String]) {
		self.name = name
		self.roots = roots
	}
}

/// A setting's value, in the shape its kind gives it. `other` keeps a shape this app doesn't know.
public enum SettingValue: Codable, Sendable, Hashable {
	case text(String)
	case number(Double)
	case list([String])
	case workspaces([Workspace])
	case other(JSONValue)

	public init(from decoder: any Decoder) throws {
		let container = try decoder.singleValueContainer()
		if let text = try? container.decode(String.self) {
			self = .text(text)
		} else if let number = try? container.decode(Double.self) {
			self = .number(number)
		} else if let list = try? container.decode([String].self) {
			self = .list(list)
		} else if let workspaces = try? container.decode([Workspace].self) {
			self = .workspaces(workspaces)
		} else {
			self = .other(try container.decode(JSONValue.self))
		}
	}

	public func encode(to encoder: any Encoder) throws {
		var container = encoder.singleValueContainer()
		switch self {
		case .text(let text): try container.encode(text)
		// Through JSONValue, so a whole number goes as one (an `integer` setting refuses 7.0).
		case .number(let number): try container.encode(JSONValue.number(number))
		case .list(let list): try container.encode(list)
		case .workspaces(let workspaces): try container.encode(workspaces)
		case .other(let value): try container.encode(value)
		}
	}

	/// The value as `kind` has it: an empty list is no workspaces for `workspaces`, since `[]` decodes as a list.
	func shaped(as kind: SettingKind) -> SettingValue {
		if kind == .workspaces, self == .list([]) { return .workspaces([]) }
		return self
	}
}

/// One setting, described well enough to show and change it without knowing aludra's settings.
public struct HostSetting: Decodable, Sendable, Hashable, Identifiable {
	/// Its place in the settings file, such as `approvals.hosts`; the key to change it by.
	public var key: String
	public var label: String
	/// One line of help, for the form.
	public var help: String
	public var kind: SettingKind
	/// What the host makes of the file, defaults filled in.
	public var value: SettingValue
	/// The value when the file doesn't name it; nil for a setting with no default (workspaces).
	public var `default`: SettingValue?
	/// Whether the settings file names it, rather than leaving the default.
	public var set: Bool
	/// A `choice`'s values.
	public var options: [String]
	/// Whether clients may change it. The rest change only in the settings file.
	public var editable: Bool
	/// Whether a change reaches the running host at once, rather than at its next restart.
	public var live: Bool

	public var id: String { key }

	public init(from decoder: any Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		key = try c.decode(String.self, forKey: .key)
		label = try c.decodeIfPresent(String.self, forKey: .label) ?? key
		help = try c.decodeIfPresent(String.self, forKey: .help) ?? ""
		kind = try c.decode(SettingKind.self, forKey: .kind)
		value = try c.decode(SettingValue.self, forKey: .value).shaped(as: kind)
		`default` = try c.decodeIfPresent(SettingValue.self, forKey: .default)?.shaped(as: kind)
		set = try c.decodeIfPresent(Bool.self, forKey: .set) ?? false
		options = try c.decodeIfPresent([String].self, forKey: .options) ?? []
		editable = try c.decodeIfPresent(Bool.self, forKey: .editable) ?? false
		live = try c.decodeIfPresent(Bool.self, forKey: .live) ?? false
	}

	private enum CodingKeys: String, CodingKey {
		case key, label, help, kind, value, `default`, set, options, editable, live
	}
}

/// Every setting of a host, and where they come from.
public struct HostSettings: Decodable, Sendable, Hashable {
	/// The settings file; nil when the host started without one, and then nothing can be saved.
	public var file: String?
	/// In the order a form shows them.
	public var settings: [HostSetting]
	/// Keys whose saved value the running host doesn't have yet; a restart brings them in.
	public var restart: [String]
	/// What's wrong in the file, such as a hand edit the host wouldn't start with.
	public var errors: [String]

	public init(from decoder: any Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		file = try c.decodeIfPresent(String.self, forKey: .file)
		settings = try c.decode([HostSetting].self, forKey: .settings)
		restart = try c.decodeIfPresent([String].self, forKey: .restart) ?? []
		errors = try c.decodeIfPresent([String].self, forKey: .errors) ?? []
	}

	private enum CodingKeys: String, CodingKey { case file, settings, restart, errors }
}

/// One `settings.set` change: a new value, or back to the default, which is sent as null.
public enum SettingChange: Encodable, Sendable, Hashable {
	case value(SettingValue)
	case toDefault

	public func encode(to encoder: any Encoder) throws {
		var container = encoder.singleValueContainer()
		switch self {
		case .value(let value): try container.encode(value)
		case .toDefault: try container.encodeNil()
		}
	}
}

extension ProtocolError {
	/// Every reason a request was refused: an `invalid_settings` error's `data.errors`, one each, or else the message.
	public var reasons: [String] {
		if case .array(let errors)? = data?["errors"] {
			let reasons = errors.compactMap(\.stringValue)
			if !reasons.isEmpty { return reasons }
		}
		return [message]
	}
}
