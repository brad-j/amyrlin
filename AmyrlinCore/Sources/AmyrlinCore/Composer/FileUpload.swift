import Foundation

/// A file for a message (aludra's own, outside v1): any kind, base64. The host saves it and tells the agent where, with
/// a `<file>` note in the message (aludra's src/files.ts); the bytes never go to the model on their own.
public struct FileUpload: Codable, Sendable, Hashable {
	public var name: String
	public var mimeType: String?
	public var data: String

	public init(name: String, mimeType: String?, data: String) {
		self.name = name
		self.mimeType = mimeType
		self.data = data
	}

	/// The file's size, from its base64 without decoding it.
	public var bytes: Int { AttachmentBudget.decodedSize(data) }
}

/// What a message's attachments may come to on a host. aludra's limits arrive in `host.info.files`; a host without it
/// takes no files.
public enum AttachmentBudget {
	/// The bytes base64 `data` decodes to.
	public static func decodedSize(_ data: String) -> Int {
		let padding = data.hasSuffix("==") ? 2 : data.hasSuffix("=") ? 1 : 0
		return data.utf8.count / 4 * 3 - padding
	}

	/// Why a message with these attachments can't go to a host with `limits`, or nil when it can. `limits` nil means the
	/// host takes no files, which only matters when there are some.
	public static func problem(images: [ImageUpload], videos: [VideoUpload], files: [FileUpload], limits: Commands.HostInfo.FileLimits?) -> String? {
		guard !files.isEmpty else { return nil }
		guard let limits else { return "This machine's aludra doesn't take files yet; update it, or remove the files." }
		if files.count > limits.maxFiles { return "A message takes at most \(limits.maxFiles) files." }
		let fileBytes = files.reduce(0) { $0 + $1.bytes }
		if fileBytes > limits.maxBytes { return "A message's files take at most \(megabytes(limits.maxBytes)) together; these come to \(megabytes(fileBytes))." }
		let all = images.map(\.data) + videos.flatMap { [$0.data] + $0.frames.map(\.data) } + files.map(\.data)
		let total = all.reduce(0) { $0 + decodedSize($1) }
		if total > limits.maxMessageBytes { return "A message's images, videos and files take at most \(megabytes(limits.maxMessageBytes)) together; these come to \(megabytes(total))." }
		return nil
	}

	static func megabytes(_ bytes: Int) -> String {
		"\(Int((Double(bytes) / 1_048_576).rounded(.up))) MB"
	}
}
