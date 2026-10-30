import Foundation

/// A video sent with a message, as the transcript reads it back. aludra saves the video and puts a note in the message,
/// a text block `<video name="…" seconds="…" path="…" until="…">…</video>`, followed by the frames sent with it as
/// image blocks (aludra's src/videos.ts). The note is for the agent; the transcript shows the video in its place.
public struct TranscriptVideo: Sendable, Hashable {
	public var name: String
	public var seconds: Double?
	/// Where the host keeps it.
	public var path: String
	/// The day the host deletes it, `2026-11-12`.
	public var until: String
	public var frames: [ImageRef]

	/// A user message's blocks without its videos' notes and frames, and the videos they stood for.
	public static func split(_ content: [Block], entryId: EntryID) -> (text: String, images: [ImageRef], videos: [TranscriptVideo]) {
		var texts: [String] = []
		var images: [ImageRef] = []
		var videos: [TranscriptVideo] = []
		// The video whose frames the image blocks after its note are.
		var taking: Int?
		for (index, block) in content.enumerated() {
			switch block {
			case .text(let text):
				let notes = text.matches(of: note)
				guard !notes.isEmpty else {
					taking = nil
					texts.append(text)
					continue
				}
				for match in notes { videos.append(video(from: String(match.output.1))) }
				taking = videos.count - 1
				let rest = text.replacing(note, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
				if !rest.isEmpty { texts.append(rest) }
			case .image(let mimeType):
				let ref = ImageRef(entryId: entryId, index: index, mimeType: mimeType)
				if let taking { videos[taking].frames.append(ref) } else { images.append(ref) }
			default:
				continue
			}
		}
		return (texts.joined(separator: "\n"), images, videos)
	}

	/// `m:ss`, as the frames' times are written.
	public static func clock(_ seconds: Double) -> String {
		let whole = Int(seconds.rounded())
		return "\(whole / 60):\(String(format: "%02d", whole % 60))"
	}

	nonisolated(unsafe) private static let note = /\s*<video\b([^>]*)>[\s\S]*?<\/video>/
	nonisolated(unsafe) private static let attribute = /(\w+)="([^"]*)"/

	private static func video(from attributes: String) -> TranscriptVideo {
		var values: [String: String] = [:]
		for match in attributes.matches(of: attribute) { values[String(match.output.1)] = String(match.output.2) }
		return TranscriptVideo(name: values["name"] ?? "video", seconds: values["seconds"].flatMap(Double.init), path: values["path"] ?? "", until: values["until"] ?? "", frames: [])
	}
}

extension TranscriptVideo {
	/// Text without the videos' notes, such as a queued message's.
	public static func withoutNotes(_ text: String) -> String {
		text.replacing(note, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
	}

	/// What the transcript says of where the video is: `on the host until Nov 12`, or that it's gone, as of `now`.
	public func keeping(now: Date = .now) -> String {
		let parse = Date.ISO8601FormatStyle().year().month().day()
		guard let day = try? parse.parse(until) else { return "on the host" }
		let shown = day.formatted(Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!).month(.abbreviated).day())
		return day > now ? "on the host until \(shown)" : "deleted from the host \(shown)"
	}
}
