import Foundation

/// A page the agent published with `publish_page` (aludra, protocol section 10): a result whose details name it,
/// `{page, title, bytes}`. The transcript shows the page itself in place of the call, fetched with `conversation.page`.
public struct TranscriptPage: Sendable, Hashable {
	public var callId: String
	/// The host's name for it, passed back to `conversation.page` as it came.
	public var page: JSONValue
	public var title: String
	public var bytes: Int?

	public init(callId: String, page: JSONValue, title: String, bytes: Int? = nil) {
		self.callId = callId
		self.page = page
		self.title = title
		self.bytes = bytes
	}

	public static let toolName = "publish_page"

	/// The page a tool result stands for, or nil when it isn't one: another tool, an error, or details without a page.
	public static func from(_ result: ToolResultItem) -> TranscriptPage? {
		guard result.toolName == toolName, !result.isError, let details = result.details else { return nil }
		guard let page = details["page"], page != .null else { return nil }
		let bytes: Int? = if case .number(let n)? = details["bytes"] { Int(n) } else { nil }
		return TranscriptPage(callId: result.callId, page: page, title: details["title"]?.stringValue ?? "Page", bytes: bytes)
	}
}

/// A published page as `conversation.page` returns it. `html` carries its own Content-Security-Policy; `csp` is the
/// same policy, for a client to enforce as well.
public struct PublishedPage: Decodable, Sendable, Hashable {
	public var page: JSONValue
	public var title: String
	public var html: String
	public var bytes: Int?
	public var createdAt: Int64?
	public var csp: String?

	/// The HTML with `csp` added as a meta tag at its start, so the policy holds even if the page's own were missing. Two
	/// policies both apply, so this can only narrow the page's. A meta before `<html>` lands in the head the parser
	/// makes; it goes after a doctype so the page keeps its mode.
	public var enforcedHTML: String {
		guard let csp, !csp.isEmpty else { return html }
		let escaped = csp.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;")
		let meta = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(escaped)\">"
		if let doctype = html.firstMatch(of: /^\s*<!doctype[^>]*>/.ignoresCase()) {
			return html[..<doctype.range.upperBound] + meta + html[doctype.range.upperBound...]
		}
		return meta + html
	}
}
