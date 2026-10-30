import AVFoundation
import Foundation

/// Videos for a message: re-encoded as 720p H.264 MP4 (540p if that's still too big), with up to six frames pulled
/// from the start to the end, which the model sees as images. The host saves the video for the agent and checks it
/// again (aludra's src/videos.ts).
public enum VideoPreparation {
	public static let maxVideos = 2
	/// The host's limit, for a message's videos together.
	public static let maxBytes = 40 * 1024 * 1024
	public static let maxFrames = 6

	public enum Failure: Error, Equatable, CustomStringConvertible {
		case unreadable
		case unencodable
		case tooBig(megabytes: Int)

		public var description: String {
			switch self {
			case .unreadable: "That isn't a video this Mac can read."
			case .unencodable: "The video couldn't be prepared to send."
			case .tooBig(let megabytes): "That video is \(megabytes) MB even at 540p; the limit is \(VideoPreparation.maxBytes / 1_048_576) MB. Trim it to the part that matters."
			}
		}
	}

	public static func prepare(_ url: URL) async throws -> VideoUpload {
		let asset = AVURLAsset(url: url)
		guard (try? await asset.loadTracks(withMediaType: .video).first) != nil,
			let duration = try? await asset.load(.duration), duration.isNumeric else { throw Failure.unreadable }
		let seconds = duration.seconds
		var data = try await export(asset, preset: AVAssetExportPreset1280x720)
		if data.count > maxBytes { data = try await export(asset, preset: AVAssetExportPreset960x540) }
		guard data.count <= maxBytes else { throw Failure.tooBig(megabytes: Int((Double(data.count) / 1_048_576).rounded(.up))) }
		return VideoUpload(name: url.lastPathComponent, mimeType: "video/mp4", data: data.base64EncodedString(), seconds: seconds, frames: try await frames(of: asset, seconds: seconds))
	}

	/// When to take frames from a video `seconds` long: one for a clip under a second, otherwise the start, the end, and
	/// evenly between, one for every three seconds or so up to six. The end is a tenth of a second short of it, where a
	/// frame still is.
	static func frameTimes(seconds: Double) -> [Double] {
		guard seconds >= 1 else { return [0] }
		let count = min(maxFrames, Int(seconds / 3) + 2)
		let end = seconds - 0.1
		return (0..<count).map { end * Double($0) / Double(count - 1) }
	}

	static func frames(of asset: AVURLAsset, seconds: Double) async throws -> [VideoFrame] {
		let generator = AVAssetImageGenerator(asset: asset)
		generator.appliesPreferredTrackTransform = true
		generator.maximumSize = CGSize(width: ImagePreparation.longEdge, height: ImagePreparation.longEdge)
		let tolerance = CMTime(seconds: 0.1, preferredTimescale: 600)
		generator.requestedTimeToleranceBefore = tolerance
		generator.requestedTimeToleranceAfter = tolerance
		var frames: [VideoFrame] = []
		for time in frameTimes(seconds: seconds) {
			guard let (image, actual) = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)),
				let jpeg = ImagePreparation.encode(image, as: .jpeg) else { continue }
			frames.append(VideoFrame(mimeType: "image/jpeg", data: jpeg.base64EncodedString(), at: max(0, actual.seconds)))
		}
		guard !frames.isEmpty else { throw Failure.unreadable }
		return frames
	}

	private static func export(_ asset: AVURLAsset, preset: String) async throws -> Data {
		guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { throw Failure.unencodable }
		let out = FileManager.default.temporaryDirectory.appending(path: "amyrlin-video-\(UUID().uuidString).mp4")
		defer { try? FileManager.default.removeItem(at: out) }
		do {
			try await session.export(to: out, as: .mp4)
			return try Data(contentsOf: out)
		} catch {
			throw Failure.unencodable
		}
	}
}
