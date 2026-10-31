import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AmyrlinCore

/// Images in messages: prepared before sending, and where the transcript says they are.
@Suite struct ImageTests {
	private func image(width: Int, height: Int, type: UTType, alpha: Bool = false) throws -> Data {
		let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue))
		context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
		context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
		let made = try #require(context.makeImage())
		return try #require(ImagePreparation.encode(made, as: type))
	}

	private func size(_ upload: ImageUpload) throws -> (Int, Int) {
		let data = try #require(Data(base64Encoded: upload.data))
		let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
		let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
		return (image.width, image.height)
	}

	@Test func aLargeImageIsScaledToTheLongEdgeAndKeepsItsKind() throws {
		let png = try ImagePreparation.prepare(try image(width: 3000, height: 1500, type: .png, alpha: true))
		#expect(png.mimeType == "image/png")
		#expect(try size(png) == (1568, 784))
		let jpeg = try ImagePreparation.prepare(try image(width: 1000, height: 2000, type: .jpeg))
		#expect(jpeg.mimeType == "image/jpeg")
		#expect(try size(jpeg) == (784, 1568))
		let tiff = try ImagePreparation.prepare(try image(width: 40, height: 30, type: .tiff))
		#expect(tiff.mimeType == "image/jpeg", "anything not PNG goes as JPEG")
		#expect(try size(tiff) == (40, 30), "a small image keeps its size")
	}

	@Test func somethingThatIsNotAnImageIsRefused() {
		#expect(throws: ImagePreparation.Failure.unreadable) { try ImagePreparation.prepare(Data("not an image".utf8)) }
	}

	@Test func theTranscriptSaysWhereAMessagesAndAResultsImagesAre() throws {
		let frames = [
			#"[{"type":"snapshot","conversation":{"id":1,"title":"T","archived":false,"parent":null},"items":[],"hasEarlier":false,"contextStart":null,"run":null,"streaming":null,"retry":null,"tools":[],"inbox":[],"approvals":[],"compactions":[],"settings":{"stored":{},"effective":{"tools":[]}},"spend":{"byModel":{},"byTool":{},"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0,"cost":0}}]"#,
			#"[{"type":"item.added","item":{"id":7,"at":1,"type":"user","content":[{"type":"text","text":"What's this?"},{"type":"image","mimeType":"image/png"}]}}]"#,
			#"[{"type":"item.added","item":{"id":8,"at":2,"type":"assistant","content":[{"type":"toolCall","id":"c1","name":"read","args":{"path":"shot.png"}}],"stopReason":"toolUse","model":{"provider":"faux","modelId":"faux-1"}}}]"#,
			#"[{"type":"item.added","item":{"id":9,"at":3,"type":"toolResult","callId":"c1","toolName":"read","content":[{"type":"text","text":"Read image file [image/png]"},{"type":"image","mimeType":"image/png"}],"isError":false,"diagnostics":[]}}]"#,
		]
		var state = ConversationState()
		for frame in frames { state.apply(try JSONDecoder().decode([ConversationEvent].self, from: Data(frame.utf8))) }
		let rows = TranscriptLayout.rows(state: state)
		guard case .user(let message, _, _)? = rows.first(where: { $0.id == "item-7" })?.kind else {
			Issue.record("expected the user row")
			return
		}
		#expect(message.text == "What's this?", "the image isn't a placeholder in the text")
		#expect(message.images == [ImageRef(entryId: 7, index: 1, mimeType: "image/png")])
		guard case .toolRound(let round)? = rows.first(where: { $0.id == "round-call-c1" })?.kind, let call = round.calls.first else {
			Issue.record("expected the call's round")
			return
		}
		#expect(call.output == "Read image file [image/png]")
		#expect(call.images == [ImageRef(entryId: 9, index: 1, mimeType: "image/png")])
	}

	@Test func imagesAreSentOnlyWhenThereAreSome() throws {
		let plain = String(decoding: try JSONEncoder().encode(Commands.Submit(conversationId: 1, requestId: "r", text: "hi").params), as: UTF8.self)
		#expect(!plain.contains("images"))
		let withImage = String(decoding: try JSONEncoder().encode(Commands.Submit(conversationId: 1, requestId: "r", text: "", images: [ImageUpload(mimeType: "image/png", data: "AA==")]).params), as: UTF8.self)
		#expect(withImage.contains(#""images":[{"#))
	}
}
