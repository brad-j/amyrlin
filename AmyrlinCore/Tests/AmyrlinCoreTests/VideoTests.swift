import AVFoundation
import Foundation
import Testing
@testable import AmyrlinCore

/// Videos in messages: prepared before sending, and read back from the host's note in the transcript.
@Suite struct VideoTests {
	/// A QuickTime movie `seconds` long at 1920×1080, its frames gray and getting lighter.
	private func movie(seconds: Int) async throws -> URL {
		let url = FileManager.default.temporaryDirectory.appending(path: "amyrlin-test-\(UUID().uuidString).mov")
		let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
		let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1920, AVVideoHeightKey: 1080])
		let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 1920, kCVPixelBufferHeightKey as String: 1080])
		writer.add(input)
		#expect(writer.startWriting())
		writer.startSession(atSourceTime: .zero)
		let fps = 10
		for frame in 0..<(seconds * fps) {
			while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
			var buffer: CVPixelBuffer?
			CVPixelBufferPoolCreatePixelBuffer(nil, try #require(adaptor.pixelBufferPool), &buffer)
			let pixels = try #require(buffer)
			CVPixelBufferLockBaseAddress(pixels, [])
			memset(CVPixelBufferGetBaseAddress(pixels), Int32(frame * 255 / (seconds * fps)), CVPixelBufferGetDataSize(pixels))
			CVPixelBufferUnlockBaseAddress(pixels, [])
			adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
		}
		input.markAsFinished()
		await writer.finishWriting()
		#expect(writer.status == .completed)
		return url
	}

	@Test func framesAreTakenFromTheStartToTheEnd() {
		#expect(VideoPreparation.frameTimes(seconds: 0.5) == [0])
		#expect(VideoPreparation.frameTimes(seconds: 2.1) == [0, 2])
		let ten = VideoPreparation.frameTimes(seconds: 10.1)
		#expect(ten.count == 5)
		#expect(ten.first == 0 && ten.last == 10)
		#expect(VideoPreparation.frameTimes(seconds: 600).count == VideoPreparation.maxFrames)
	}

	@Test func aMovieIsReencodedAsA720pMP4WithItsFrames() async throws {
		let url = try await movie(seconds: 4)
		defer { try? FileManager.default.removeItem(at: url) }
		let upload = try await VideoPreparation.prepare(url)
		#expect(upload.mimeType == "video/mp4")
		#expect(upload.name == url.lastPathComponent)
		#expect(abs((upload.seconds ?? 0) - 4) < 0.2)
		let data = try #require(Data(base64Encoded: upload.data))
		#expect(String(decoding: data[4..<8], as: UTF8.self) == "ftyp", "what aludra checks an MP4 by")
		let out = FileManager.default.temporaryDirectory.appending(path: "amyrlin-test-\(UUID().uuidString).mp4")
		try data.write(to: out)
		defer { try? FileManager.default.removeItem(at: out) }
		let track = try #require(try await AVURLAsset(url: out).loadTracks(withMediaType: .video).first)
		#expect(try await track.load(.naturalSize) == CGSize(width: 1280, height: 720))
		#expect(upload.frames.count == 3)
		#expect(upload.frames.allSatisfy { $0.mimeType == "image/jpeg" })
		#expect(upload.frames.first?.at == 0)
		#expect(abs((upload.frames.last?.at ?? 0) - 3.9) < 0.2)
	}

	@Test func somethingThatIsNotAVideoIsRefused() async throws {
		let url = FileManager.default.temporaryDirectory.appending(path: "amyrlin-test-\(UUID().uuidString).mov")
		try Data("not a movie".utf8).write(to: url)
		defer { try? FileManager.default.removeItem(at: url) }
		await #expect(throws: VideoPreparation.Failure.unreadable) { try await VideoPreparation.prepare(url) }
	}

	@Test func theTranscriptShowsAVideoInPlaceOfTheHostsNote() {
		let note = "\n\n<video name=\"flicker.mp4\" seconds=\"9.5\" path=\"/data/uploads/12/20261029-141503-flicker.mp4\" until=\"2026-11-12\">\nThe user attached a video…\n</video>"
		let content: [Block] = [.text("Why does it flicker?"), .image(mimeType: "image/png"), .text(note), .image(mimeType: "image/jpeg"), .image(mimeType: "image/jpeg")]
		let message = TranscriptVideo.split(content, entryId: 7)
		#expect(message.text == "Why does it flicker?")
		#expect(message.images == [ImageRef(entryId: 7, index: 1, mimeType: "image/png")], "the user's own image isn't a frame")
		#expect(message.videos == [TranscriptVideo(name: "flicker.mp4", seconds: 9.5, path: "/data/uploads/12/20261029-141503-flicker.mp4", until: "2026-11-12", frames: [ImageRef(entryId: 7, index: 3, mimeType: "image/jpeg"), ImageRef(entryId: 7, index: 4, mimeType: "image/jpeg")])])
		#expect(TranscriptVideo.withoutNotes("Why?" + note) == "Why?")
		let plain = TranscriptVideo.split([.text("hi"), .image(mimeType: "image/png")], entryId: 3)
		#expect(plain.text == "hi" && plain.images.count == 1 && plain.videos.isEmpty)
	}

	@Test func theTranscriptSaysWhetherTheHostStillHasIt() throws {
		let video = TranscriptVideo(name: "a.mp4", seconds: 65, path: "/x", until: "2026-11-12", frames: [])
		let before = try Date("2026-11-01T12:00:00Z", strategy: .iso8601)
		let after = try Date("2026-11-13T12:00:00Z", strategy: .iso8601)
		#expect(video.keeping(now: before) == "on the host until Nov 12")
		#expect(video.keeping(now: after) == "deleted from the host Nov 12")
		#expect(TranscriptVideo.clock(65.2) == "1:05")
	}
}
