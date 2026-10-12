import Foundation

/// Any JSON value. Used where the protocol passes data through untouched: tool arguments, details and custom entry data.
public enum JSONValue: Sendable, Hashable {
	case null
	case bool(Bool)
	case number(Double)
	case string(String)
	case array([JSONValue])
	case object([String: JSONValue])

	public subscript(key: String) -> JSONValue? {
		if case .object(let object) = self { object[key] } else { nil }
	}

	public var stringValue: String? {
		if case .string(let string) = self { string } else { nil }
	}

	/// Compact JSON text, for display.
	public var jsonText: String {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
		guard let data = try? encoder.encode(self) else { return "null" }
		return String(decoding: data, as: UTF8.self)
	}
}

extension JSONValue: Codable {
	public init(from decoder: any Decoder) throws {
		let container = try decoder.singleValueContainer()
		if container.decodeNil() {
			self = .null
		} else if let bool = try? container.decode(Bool.self) {
			self = .bool(bool)
		} else if let number = try? container.decode(Double.self) {
			self = .number(number)
		} else if let string = try? container.decode(String.self) {
			self = .string(string)
		} else if let array = try? container.decode([JSONValue].self) {
			self = .array(array)
		} else {
			self = .object(try container.decode([String: JSONValue].self))
		}
	}

	public func encode(to encoder: any Encoder) throws {
		var container = encoder.singleValueContainer()
		switch self {
		case .null: try container.encodeNil()
		case .bool(let bool): try container.encode(bool)
		case .number(let number):
			// Integral values encode as integers, so IDs read back as Int64.
			if number.rounded() == number, abs(number) < 9_007_199_254_740_992 {
				try container.encode(Int64(number))
			} else {
				try container.encode(number)
			}
		case .string(let string): try container.encode(string)
		case .array(let array): try container.encode(array)
		case .object(let object): try container.encode(object)
		}
	}
}

extension JSONValue {
	/// Appends `text` to the string at `path`, creating objects and an empty string where they are missing.
	/// Used for streamed tool-call arguments (`appendArg`). Returns false when the path runs through a non-container.
	mutating func append(_ text: String, at path: ArraySlice<PathComponent>) -> Bool {
		guard let first = path.first else {
			switch self {
			case .string(let string): self = .string(string + text); return true
			case .null: self = .string(text); return true
			default: return false
			}
		}
		let rest = path.dropFirst()
		switch (first, self) {
		case (.key(let key), .object(var object)):
			var child = object[key] ?? (rest.isEmpty ? .string("") : .object([:]))
			guard child.append(text, at: rest) else { return false }
			object[key] = child
			self = .object(object)
			return true
		case (.key, .null):
			self = .object([:])
			return append(text, at: path)
		case (.index(let index), .array(var array)) where index >= 0 && index <= array.count:
			if index == array.count { array.append(rest.isEmpty ? .string("") : .object([:])) }
			guard array[index].append(text, at: rest) else { return false }
			self = .array(array)
			return true
		default:
			return false
		}
	}
}

/// One step of a path into a JSON value: an object key or an array index.
public enum PathComponent: Sendable, Hashable, Codable {
	case key(String)
	case index(Int)

	public init(from decoder: any Decoder) throws {
		let container = try decoder.singleValueContainer()
		if let index = try? container.decode(Int.self) {
			self = .index(index)
		} else {
			self = .key(try container.decode(String.self))
		}
	}

	public func encode(to encoder: any Encoder) throws {
		var container = encoder.singleValueContainer()
		switch self {
		case .key(let key): try container.encode(key)
		case .index(let index): try container.encode(index)
		}
	}
}
