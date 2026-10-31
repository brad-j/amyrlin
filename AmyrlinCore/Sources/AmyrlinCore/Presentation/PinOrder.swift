import Foundation

/// Pinned sessions in the order they were arranged, as opaque keys ("machine/conversation"). A new pin goes to the top,
/// and a drag or Move Up/Down changes the order. Kept on the client: pins are this Mac's arrangement, not the host's.
public struct PinOrder: Equatable, Sendable {
	public private(set) var keys: [String]

	public init(_ keys: [String] = []) {
		var seen: Set<String> = []
		self.keys = keys.filter { seen.insert($0).inserted }
	}

	public func contains(_ key: String) -> Bool { keys.contains(key) }

	/// Pins `key` at `index` (the top by default), or moves it there if it's pinned already.
	public mutating func pin(_ key: String, at index: Int = 0) {
		keys.removeAll { $0 == key }
		keys.insert(key, at: min(max(index, 0), keys.count))
	}

	/// Unpins `key`, returning where it was so an undo can put it back.
	@discardableResult
	public mutating func unpin(_ key: String) -> Int? {
		guard let index = keys.firstIndex(of: key) else { return nil }
		keys.remove(at: index)
		return index
	}

	/// Moves `key` one place up (-1) or down (1) among `visible`, the pins one list shows, which may be a subset of all
	/// pins (one machine's). False when it's already at that end.
	@discardableResult
	public mutating func move(_ key: String, by step: Int, among visible: [String]) -> Bool {
		guard let at = visible.firstIndex(of: key), visible.indices.contains(at + step) else { return false }
		return place(key, before: step < 0 ? visible[at + step] : visible.indices.contains(at + 2) ? visible[at + 2] : nil, among: visible)
	}

	/// Puts `key` just before `target` among `visible`, or after the last of them when `target` is nil; the drop of a drag.
	@discardableResult
	public mutating func place(_ key: String, before target: String?, among visible: [String]) -> Bool {
		guard key != target, contains(key) else { return false }
		let old = keys
		keys.removeAll { $0 == key }
		if let target, let index = keys.firstIndex(of: target) {
			keys.insert(key, at: index)
		} else if let last = visible.last(where: { $0 != key }), let index = keys.firstIndex(of: last) {
			keys.insert(key, at: index + 1)
		} else {
			keys.append(key)
		}
		return keys != old
	}

	/// Drops keys `exists` says are gone, such as sessions of a removed machine.
	public mutating func prune(keeping exists: (String) -> Bool) {
		keys.removeAll { !exists($0) }
	}
}
