import Foundation
import Testing
@testable import AmyrlinCore

/// Files in messages (aludra's own, protocol section 10 item 17): host.info's limits, what's sent, what a host refuses,
/// and the file notes a user message carries.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct FileTests {
	/// As egwene's aludra answered host.info, cut to what matters here.
	static let info = #"{"host":{"hostId":"h","name":"egwene"},"models":[],"tools":[],"videos":{"maxVideos":2,"maxBytes":41943040,"maxFrames":6,"keepDays":14},"files":{"maxFiles":20,"maxBytes":26214400,"pasteBytes":32768,"keepDays":14,"maxMessageBytes":83886080}}"#

	static var limits: Commands.HostInfo.FileLimits {
		get throws { try #require(try JSONDecoder().decode(Commands.HostInfo.Result.self, from: Data(info.utf8)).files) }
	}

	@Test func hostInfoCarriesTheLimitsOrNothing() throws {
		let limits = try Self.limits
		#expect(limits.maxFiles == 20 && limits.maxBytes == 26_214_400 && limits.pasteBytes == 32_768 && limits.keepDays == 14 && limits.maxMessageBytes == 83_886_080)
		let older = try JSONDecoder().decode(Commands.HostInfo.Result.self, from: Data(#"{"host":{"hostId":"h","name":"egwene"},"models":[],"tools":[]}"#.utf8))
		#expect(older.files == nil)
	}

	static func file(_ name: String, bytes: Int) -> FileUpload {
		FileUpload(name: name, mimeType: "text/csv", data: Data(count: bytes).base64EncodedString())
	}

	@Test func aHostWithoutFilesGetsNone() throws {
		#expect(AttachmentBudget.problem(images: [], videos: [], files: [Self.file("a.csv", bytes: 10)], limits: nil)?.contains("doesn't take files") == true)
		#expect(AttachmentBudget.problem(images: [], videos: [], files: [], limits: nil) == nil, "nothing to refuse without files")
	}

	@Test func theLimitsAreKept() throws {
		let limits = try Self.limits
		#expect(AttachmentBudget.problem(images: [], videos: [], files: [Self.file("a.csv", bytes: 1000)], limits: limits) == nil)
		#expect(AttachmentBudget.problem(images: [], videos: [], files: (0..<21).map { Self.file("\($0).txt", bytes: 1) }, limits: limits)?.contains("at most 20 files") == true)
		#expect(AttachmentBudget.problem(images: [], videos: [], files: [Self.file("big.bin", bytes: 26 * 1_048_576)], limits: limits)?.contains("25 MB") == true)
		// Under the files' limit, over the message's with the video.
		var small = limits
		small.maxMessageBytes = 3 * 1_048_576
		let video = VideoUpload(name: "v.mp4", mimeType: "video/mp4", data: Data(count: 2 * 1_048_576).base64EncodedString(), seconds: 1, frames: [])
		#expect(AttachmentBudget.problem(images: [], videos: [video], files: [Self.file("b.bin", bytes: 1_048_576 + 1)], limits: small)?.contains("images, videos and files") == true)
	}

	@Test func sizesComeFromTheBase64() {
		for bytes in [0, 1, 2, 3, 4, 1000, 1001, 1002] {
			#expect(Self.file("x", bytes: bytes).bytes == bytes)
		}
		#expect(TranscriptFile.size(68) == "68 bytes")
		#expect(TranscriptFile.size(84_624) == "82.6 KB")
		#expect(TranscriptFile.size(1_363_149) == "1.3 MB")
	}

	private func encode(_ params: some Encodable) throws -> JSONValue {
		try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(params))
	}

	@Test func submitAndCreateSendFilesOnlyWhenThereAreSome() throws {
		let submit = try encode(Commands.Submit(conversationId: 1, requestId: "r", text: "look", files: [FileUpload(name: "a.csv", mimeType: "text/csv", data: "aGk=")]).params)
		#expect(submit["files"] == .array([.object(["name": "a.csv", "mimeType": "text/csv", "data": "aGk="])]))
		#expect(try encode(Commands.Submit(conversationId: 1, requestId: "r", text: "plain").params)["files"] == nil)
		let create = try encode(Commands.CreateConversation(requestId: "c", text: "", files: [FileUpload(name: "notes", mimeType: nil, data: "aGk=")]).params)
		#expect(create["files"] == .array([.object(["name": "notes", "data": "aGk="])]), "no mimeType when it isn't known")
	}

	/// As aludra writes them (src/files.ts): a file sent with the message, and long text it saved.
	static let notes = "Test: how many rows?\n\n<file name=\"lenses.csv\" type=\"text/csv\" bytes=\"68\" path=\"/home/brad/.local/share/aludra/uploads/28782/20261031-020554-lenses.csv\" until=\"2026-11-14\">\nThe user attached a file (68 bytes), saved on this machine until 2026-11-14. Read it with your tools; for a binary format, use a command that understands it.\n</file>"

	@Test func fileNotesAreChipsNotText() {
		let message = UserMessage.parse([.text(Self.notes)], entryId: 3)
		#expect(message.text == "Test: how many rows?")
		#expect(message.files == [TranscriptFile(name: "lenses.csv", mimeType: "text/csv", bytes: 68, path: "/home/brad/.local/share/aludra/uploads/28782/20261031-020554-lenses.csv", until: "2026-11-14")])

		let pasted = "Long text starts here\n…" + "\n\n<file name=\"message.txt\" type=\"text/plain\" bytes=\"84624\" path=\"/u/1/message.txt\" until=\"2026-11-14\">\nThe user's message was too long to send whole (82.6 KB), so all of it is saved in this file; what's above is only its start. Read the file for the rest.\n</file>"
		let long = UserMessage.parse([.text(pasted)], entryId: 4)
		#expect(long.text == "Long text starts here\n…")
		#expect(long.files.map(\.name) == ["message.txt"] && long.files[0].bytes == 84_624)

		// A file alone, in a block of its own; a file whose name has a quote; and a message without notes.
		let alone = UserMessage.parse([.text(""), .text("<file name=\"say &quot;hi&quot;.txt\" bytes=\"2\" path=\"/p\" until=\"2026-11-14\">\nx\n</file>")], entryId: 5)
		#expect(alone.text.isEmpty && alone.files.first?.name == "say \"hi\".txt" && alone.files.first?.mimeType == nil)
		#expect(UserMessage.parse([.text("just words")], entryId: 6).files.isEmpty)
		#expect(UserMessage.withoutNotes(Self.notes) == "Test: how many rows?")
	}

	@Test func aFileKeepsUntilItsDay() {
		let file = TranscriptFile(name: "a", path: "/p", until: "2026-11-14")
		#expect(file.keeping(now: Date(timeIntervalSince1970: 1_793_400_000)) == "kept until Nov 14")
		#expect(file.keeping(now: Date(timeIntervalSince1970: 1_800_000_000)) == "deleted from the host Nov 14")
		#expect(TranscriptFile(name: "a", path: "/p", until: "").keeping() == "on the host")
	}

	/// Both notes in one message: the restore line first, then the files, then the words.
	@Test func restoreAndFileNotesTogether() {
		let restored = #"<restored checkpoint="4">The user put the project's files back (1 written, 0 deleted): a.ts. Read a file again.</restored>"#
		let message = UserMessage.parse([.text(restored), .text(Self.notes)], entryId: 7)
		#expect(message.restore?.checkpoint == 4)
		#expect(message.files.count == 1)
		#expect(message.text == "Test: how many rows?")
	}
}
