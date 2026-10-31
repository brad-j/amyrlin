import Foundation

/// A restore the host told the agent about: a user message after the project's files were put back starts with a text
/// block `<restored checkpoint="N">…</restored>` (aludra's src/checkpoints.ts). The note is for the agent; the
/// transcript shows a line saying the files went back.
public struct TranscriptRestore: Sendable, Hashable {
	public var checkpoint: Int

	public init(checkpoint: Int) {
		self.checkpoint = checkpoint
	}

	nonisolated(unsafe) static let note = /\s*<restored\b[^>]*?checkpoint="(\d+)"[^>]*>[\s\S]*?<\/restored>\s*/

	/// The restore a text block's note names and the text without the note, or nil when it has none.
	static func take(_ text: String) -> (restore: TranscriptRestore, rest: String)? {
		guard let match = text.firstMatch(of: note), let checkpoint = Int(match.output.1) else { return nil }
		return (TranscriptRestore(checkpoint: checkpoint), text.replacing(note, with: ""))
	}
}

/// A file sent with a message, or long text the host saved to a file, as the transcript reads it back. aludra saves it
/// and puts a note in the message, a text block `<file name="…" type="…" bytes="…" path="…" until="…">…</file>`
/// (aludra's src/files.ts). The note is for the agent; the transcript shows the file as a chip.
public struct TranscriptFile: Sendable, Hashable {
	public var name: String
	public var mimeType: String?
	public var bytes: Int?
	/// Where the host keeps it.
	public var path: String
	/// The day the host deletes it, `2026-11-13`.
	public var until: String

	public init(name: String, mimeType: String? = nil, bytes: Int? = nil, path: String, until: String) {
		self.name = name
		self.mimeType = mimeType
		self.bytes = bytes
		self.path = path
		self.until = until
	}

	nonisolated(unsafe) static let note = /\s*<file\b([^>]*)>[\s\S]*?<\/file>/
	nonisolated(unsafe) private static let attribute = /(\w+)="([^"]*)"/

	/// The files a text block's notes stand for and the text without them, or nil when it has none.
	static func take(_ text: String) -> (files: [TranscriptFile], rest: String)? {
		let notes = text.matches(of: note)
		guard !notes.isEmpty else { return nil }
		let files = notes.map { file(from: String($0.output.1)) }
		return (files, text.replacing(note, with: ""))
	}

	private static func file(from attributes: String) -> TranscriptFile {
		var values: [String: String] = [:]
		for match in attributes.matches(of: attribute) { values[String(match.output.1)] = unescaped(String(match.output.2)) }
		return TranscriptFile(name: values["name"] ?? "file", mimeType: values["type"], bytes: values["bytes"].flatMap(Int.init), path: values["path"] ?? "", until: values["until"] ?? "")
	}

	private static func unescaped(_ value: String) -> String {
		value.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
	}

	/// The size as the chip says it: `812 bytes`, `4.2 KB`, `1.3 MB`.
	public static func size(_ bytes: Int) -> String {
		if bytes < 1024 { return "\(bytes) bytes" }
		if bytes < 1_048_576 { return String(format: "%.1f KB", Double(bytes) / 1024) }
		return String(format: "%.1f MB", Double(bytes) / 1_048_576)
	}

	/// What the chip says of where the file is: `kept until Nov 13`, or that it's gone, as of `now`.
	public func keeping(now: Date = .now) -> String {
		let parse = Date.ISO8601FormatStyle().year().month().day()
		guard let day = try? parse.parse(until) else { return "on the host" }
		let shown = day.formatted(Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!).month(.abbreviated).day())
		return day > now ? "kept until \(shown)" : "deleted from the host \(shown)"
	}
}

/// A user message as the transcript shows it: its words, with the notes the host added for the agent taken out and
/// shown as what they stand for: a restore line, images, videos and files.
public struct UserMessage: Sendable, Hashable {
	public var text: String
	public var images: [ImageRef]
	public var videos: [TranscriptVideo]
	public var files: [TranscriptFile]
	public var restore: TranscriptRestore?

	public init(text: String, images: [ImageRef] = [], videos: [TranscriptVideo] = [], files: [TranscriptFile] = [], restore: TranscriptRestore? = nil) {
		self.text = text
		self.images = images
		self.videos = videos
		self.files = files
		self.restore = restore
	}

	public static func parse(_ content: [Block], entryId: EntryID) -> UserMessage {
		var blocks = content
		var restore: TranscriptRestore?
		var files: [TranscriptFile] = []
		for (index, block) in blocks.enumerated() {
			guard case .text(var text) = block else { continue }
			// Only a message's first text block carries the restore note.
			if restore == nil, !blocks[..<index].contains(where: { if case .text = $0 { true } else { false } }), let taken = TranscriptRestore.take(text) {
				restore = taken.restore
				text = taken.rest
			}
			if let taken = TranscriptFile.take(text) {
				files += taken.files
				text = taken.rest
			}
			blocks[index] = .text(text)
		}
		let rest = TranscriptVideo.split(blocks, entryId: entryId)
		return UserMessage(text: rest.text.trimmingCharacters(in: .whitespacesAndNewlines), images: rest.images, videos: rest.videos, files: files, restore: restore)
	}

	/// Text without the host's notes, such as a queued message's.
	public static func withoutNotes(_ text: String) -> String {
		TranscriptVideo.withoutNotes((TranscriptRestore.take(text)?.rest ?? text).replacing(TranscriptFile.note, with: ""))
	}
}
