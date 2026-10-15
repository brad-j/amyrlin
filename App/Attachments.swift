import AmyrlinCore
import AppKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// Images waiting to go with a message: from the attach button, a drop, or a paste. Each is scaled and encoded as it's
/// added (AmyrlinCore's ImagePreparation), so sending is immediate.
@MainActor @Observable
final class Attachments {
	struct Item: Identifiable {
		let id = UUID()
		let upload: ImageUpload
		let preview: NSImage
	}

	private(set) var items: [Item] = []
	/// Why the last image couldn't be added, until the next one is.
	var problem: String?

	var isEmpty: Bool { items.isEmpty }
	var isFull: Bool { items.count >= ImagePreparation.maxImages }

	func add(_ data: [Data]) {
		guard !data.isEmpty else { return }
		problem = nil
		Task {
			for chunk in data {
				guard !isFull else {
					problem = "A message takes at most \(ImagePreparation.maxImages) images."
					return
				}
				do {
					let upload = try await Task.detached(priority: .userInitiated) { try ImagePreparation.prepare(chunk) }.value
					guard let bytes = Data(base64Encoded: upload.data), let preview = NSImage(data: bytes) else { continue }
					items.append(Item(upload: upload, preview: preview))
				} catch {
					problem = (error as? ImagePreparation.Failure)?.description ?? String(describing: error)
				}
			}
		}
	}

	func add(files: [URL]) {
		add(files.compactMap { try? Data(contentsOf: $0) })
	}

	func remove(_ item: Item) {
		items.removeAll { $0.id == item.id }
	}

	/// The images to send, emptying the list.
	func take() -> [ImageUpload] {
		defer { items = [] }
		return items.map(\.upload)
	}

	/// Opens the file picker for images.
	func pick() {
		let panel = NSOpenPanel()
		panel.allowedContentTypes = [.image]
		panel.allowsMultipleSelection = true
		panel.canChooseDirectories = false
		panel.prompt = "Attach"
		if panel.runModal() == .OK { add(files: panel.urls) }
	}

	/// Image files on the pasteboard, or image data when there's no text to paste instead. False when there's neither.
	func paste(from pasteboard: NSPasteboard = .general) -> Bool {
		let files = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
			.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
		if !files.isEmpty {
			add(files: files)
			return true
		}
		guard pasteboard.string(forType: .string) == nil else { return false }
		for type in [NSPasteboard.PasteboardType.png, .tiff] {
			if let data = pasteboard.data(forType: type) {
				add([data])
				return true
			}
		}
		return false
	}
}

/// Attached images above the text, each with a way to take it off.
struct AttachmentStrip: View {
	let attachments: Attachments

	var body: some View {
		if !attachments.isEmpty || attachments.problem != nil {
			VStack(alignment: .leading, spacing: 6) {
				HStack(spacing: 8) {
					ForEach(attachments.items) { item in
						Image(nsImage: item.preview)
							.resizable()
							.scaledToFill()
							.frame(width: 52, height: 52)
							.clipped()
							.overlay(Rectangle().stroke(Palette.rule2))
							.overlay(alignment: .topTrailing) {
								Button {
									attachments.remove(item)
								} label: {
									Text("×")
										.font(Typography.uiSmall)
										.foregroundStyle(Palette.ink)
										.frame(width: 16, height: 16)
										.background(Palette.paper3)
								}
								.buttonStyle(.plain)
								.help("Remove this image")
							}
					}
				}
				if let problem = attachments.problem {
					Text(problem).font(Typography.uiSmall).foregroundStyle(Palette.bad)
				}
			}
		}
	}
}

/// Takes images dropped on the view, and pasted (⌘V) while `focused` is true. The text field's editor would take the
/// paste first and ignore an image, so ⌘V is looked at before it. Long text goes into the field as a marker that
/// `pasted` holds the text for (PastedText); other text pastes as usual. Backspace right after a marker deletes it whole.
struct AcceptsPastes: ViewModifier {
	let attachments: Attachments
	let pasted: PastedText
	let focused: Bool
	@State private var monitor: Any?
	@State private var targeted = false
	@State private var active = Flag()

	final class Flag {
		var on = false
	}

	func body(content: Content) -> some View {
		content
			.overlay(Rectangle().stroke(targeted ? Palette.accent : .clear, lineWidth: 1))
			.onDrop(of: [.fileURL, .image], isTargeted: $targeted) { providers in
				load(providers)
				return true
			}
			.onChange(of: focused, initial: true) { _, now in active.on = now }
			.onAppear {
				let flag = active
				let attachments = attachments
				let pasted = pasted
				monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
					if flag.on, event.keyCode == 51, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
						return MainActor.assumeIsolated { Self.deleteMarker(in: pasted) } ? nil : event
					}
					guard flag.on, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "v" else { return event }
					return MainActor.assumeIsolated { attachments.paste() || Self.pasteLong(into: pasted) } ? nil : event
				}
			}
			.onDisappear {
				if let monitor { NSEvent.removeMonitor(monitor) }
				monitor = nil
			}
	}

	/// Long text on the pasteboard goes in at the cursor as its marker. False for short text, or no text.
	@MainActor private static func pasteLong(into pasted: PastedText, from pasteboard: NSPasteboard = .general) -> Bool {
		guard let text = pasteboard.string(forType: .string), PastedText.isLong(text),
			let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return false }
		editor.insertText(pasted.hold(text), replacementRange: editor.selectedRange())
		return true
	}

	/// Deletes the marker just before the cursor, when nothing is selected. False when there's no marker there.
	@MainActor private static func deleteMarker(in pasted: PastedText) -> Bool {
		guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return false }
		let selection = editor.selectedRange()
		guard selection.length == 0, let range = pasted.marker(endingAt: selection.location, in: editor.string) else { return false }
		editor.insertText("", replacementRange: range)
		return true
	}

	private func load(_ providers: [NSItemProvider]) {
		for provider in providers {
			if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
				_ = provider.loadObject(ofClass: URL.self) { url, _ in
					guard let url, UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true else { return }
					Task { @MainActor in attachments.add(files: [url]) }
				}
			} else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
				provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
					guard let data else { return }
					Task { @MainActor in attachments.add([data]) }
				}
			}
		}
	}
}

extension View {
	func acceptsPastes(_ attachments: Attachments, text pasted: PastedText, focused: Bool) -> some View {
		modifier(AcceptsPastes(attachments: attachments, pasted: pasted, focused: focused))
	}
}

/// A message's or a result's images as thumbnails of one height, fetched from the host, wrapping onto more lines when
/// they don't fit across. One opens in Quick Look, where the arrow keys step through the rest.
struct TranscriptImages: View {
	let refs: [ImageRef]
	let store: ConversationStore
	@State private var loaded: [ImageRef: Data] = [:]
	@State private var previewing: URL?

	static var height: CGFloat { 120 * Typography.textScale }

	var body: some View {
		Wrapping(spacing: 8) {
			ForEach(refs, id: \.self) { ref in
				TranscriptImage(ref: ref, store: store, data: $loaded[ref]) { open(ref) }
			}
		}
		.quickLookPreview($previewing, in: refs.filter { loaded[$0] != nil }.map(file))
	}

	/// Writes the loaded images out for Quick Look, which reads files, and shows `ref`'s.
	private func open(_ ref: ImageRef) {
		for (ref, data) in loaded where !FileManager.default.fileExists(atPath: file(ref).path) {
			try? data.write(to: file(ref))
		}
		previewing = file(ref)
	}

	private func file(_ ref: ImageRef) -> URL {
		let ext = UTType(mimeType: ref.mimeType)?.preferredFilenameExtension ?? "png"
		return FileManager.default.temporaryDirectory.appending(path: "amyrlin-\(store.id)-\(ref.entryId)-\(ref.index).\(ext)")
	}
}

private struct TranscriptImage: View {
	let ref: ImageRef
	let store: ConversationStore
	@Binding var data: Data?
	let open: () -> Void
	@State private var failed = false
	@State private var hovering = false

	var body: some View {
		Group {
			if let data, let image = NSImage(data: data) {
				Button(action: open) {
					Image(nsImage: image)
						.resizable()
						.scaledToFill()
						.frame(width: Self.width(image.size), height: TranscriptImages.height)
						.clipped()
						.overlay(Rectangle().stroke(hovering ? Palette.accent : Palette.rule2))
				}
				.buttonStyle(.plain)
				.pointerStyle(.link)
				.onHover { inside in withAnimation(.state) { hovering = inside } }
				.help("Preview")
			} else {
				Text(failed ? "[image unavailable]" : "[image]")
					.font(Typography.uiSmall)
					.foregroundStyle(Palette.ink3)
					.frame(width: TranscriptImages.height * 1.6, height: TranscriptImages.height)
					.overlay(Rectangle().stroke(Palette.rule))
			}
		}
		.task(id: ref) {
			guard data == nil else { return }
			do {
				data = try await store.image(ref)
			} catch {
				failed = true
			}
		}
	}

	/// The thumbnail's width for an image of `size`: its own shape at the thumbnail height, cropped when it's much
	/// taller or wider than that.
	static func width(_ size: CGSize) -> CGFloat {
		let height = TranscriptImages.height
		guard size.width > 0, size.height > 0 else { return height * 1.6 }
		return (height * min(max(size.width / size.height, 0.5), 2.4)).rounded()
	}
}

/// Lays its views out in a row, starting another below whenever the next one wouldn't fit across.
private struct Wrapping: Layout {
	let spacing: CGFloat

	func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
		let frames = place(subviews, width: proposal.width ?? .infinity)
		return CGSize(width: frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
	}

	func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
		for (subview, frame) in zip(subviews, place(subviews, width: bounds.width)) {
			subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
		}
	}

	private func place(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
		var frames: [CGRect] = []
		var origin = CGPoint.zero
		var lineHeight: CGFloat = 0
		for subview in subviews {
			let size = subview.sizeThatFits(.unspecified)
			if origin.x > 0, origin.x + size.width > width {
				origin = CGPoint(x: 0, y: origin.y + lineHeight + spacing)
				lineHeight = 0
			}
			frames.append(CGRect(origin: origin, size: size))
			origin.x += size.width + spacing
			lineHeight = max(lineHeight, size.height)
		}
		return frames
	}
}
