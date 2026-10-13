import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Images for a message: decoded, scaled to Claude's recommended 1568 px on the long side at most, and encoded as PNG
/// if they were PNG (they may have transparency) or JPEG, which also covers HEIC and anything else ImageIO reads. The
/// host checks them again (aludra's src/images.ts).
public enum ImagePreparation {
	public static let longEdge = 1568
	public static let maxImages = 8
	/// A PNG bigger than this goes as JPEG instead, to stay well under the host's 5 MB limit.
	static let maxPNGBytes = 3 * 1024 * 1024

	public enum Failure: Error, Equatable, CustomStringConvertible {
		case unreadable
		case unencodable

		public var description: String {
			switch self {
			case .unreadable: "That isn't an image this Mac can read."
			case .unencodable: "The image couldn't be prepared to send."
			}
		}
	}

	public static func prepare(_ data: Data) throws -> ImageUpload {
		guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { throw Failure.unreadable }
		let options: [CFString: Any] = [
			kCGImageSourceCreateThumbnailFromImageAlways: true,
			kCGImageSourceCreateThumbnailWithTransform: true,
			kCGImageSourceThumbnailMaxPixelSize: longEdge,
			kCGImageSourceShouldCacheImmediately: true,
		]
		guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw Failure.unreadable }
		let png = (CGImageSourceGetType(source) as String?) == UTType.png.identifier
		if png, let encoded = encode(image, as: .png), encoded.count <= maxPNGBytes {
			return ImageUpload(mimeType: "image/png", data: encoded.base64EncodedString())
		}
		guard let jpeg = encode(flattened(image) ?? image, as: .jpeg) else { throw Failure.unencodable }
		return ImageUpload(mimeType: "image/jpeg", data: jpeg.base64EncodedString())
	}

	static func encode(_ image: CGImage, as type: UTType) -> Data? {
		let out = NSMutableData()
		guard let destination = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
		CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
		return CGImageDestinationFinalize(destination) ? out as Data : nil
	}

	/// The image on white, since JPEG has no transparency and what was clear would go black.
	static func flattened(_ image: CGImage) -> CGImage? {
		guard image.alphaInfo != .none, image.alphaInfo != .noneSkipFirst, image.alphaInfo != .noneSkipLast else { return image }
		let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
		guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
		context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
		context.fill(rect)
		context.draw(image, in: rect)
		return context.makeImage()
	}
}
