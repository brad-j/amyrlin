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

/// A user message as the transcript shows it: its words, with the notes the host added for the agent taken out and
/// shown as what they stand for: a restore line, images and videos.
public struct UserMessage: Sendable, Hashable {
	public var text: String
	public var images: [ImageRef]
	public var videos: [TranscriptVideo]
	public var restore: TranscriptRestore?

	public init(text: String, images: [ImageRef] = [], videos: [TranscriptVideo] = [], restore: TranscriptRestore? = nil) {
		self.text = text
		self.images = images
		self.videos = videos
		self.restore = restore
	}

	public static func parse(_ content: [Block], entryId: EntryID) -> UserMessage {
		var blocks = content
		var restore: TranscriptRestore?
		for (index, block) in blocks.enumerated() {
			guard case .text(var text) = block else { continue }
			// Only a message's first text block carries the restore note.
			if restore == nil, !blocks[..<index].contains(where: { if case .text = $0 { true } else { false } }), let taken = TranscriptRestore.take(text) {
				restore = taken.restore
				text = taken.rest
			}
			blocks[index] = .text(text)
		}
		let rest = TranscriptVideo.split(blocks, entryId: entryId)
		return UserMessage(text: rest.text.trimmingCharacters(in: .whitespacesAndNewlines), images: rest.images, videos: rest.videos, restore: restore)
	}

	/// Text without the host's notes, such as a queued message's.
	public static func withoutNotes(_ text: String) -> String {
		TranscriptVideo.withoutNotes(TranscriptRestore.take(text)?.rest ?? text)
	}
}
