import AmyrlinCore
import AppKit
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
/// paste first and ignore an image, so ⌘V is looked at before it; text on the pasteboard pastes as usual.
struct AcceptsImages: ViewModifier {
	let attachments: Attachments
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
				monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
					guard flag.on, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "v" else { return event }
					return MainActor.assumeIsolated { attachments.paste() } ? nil : event
				}
			}
			.onDisappear {
				if let monitor { NSEvent.removeMonitor(monitor) }
				monitor = nil
			}
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
	func acceptsImages(_ attachments: Attachments, focused: Bool) -> some View {
		modifier(AcceptsImages(attachments: attachments, focused: focused))
	}
}

/// A message's or a result's images, small, fetched from the host; one opens in Preview.
struct TranscriptImages: View {
	let refs: [ImageRef]
	let store: ConversationStore

	var body: some View {
		HStack(alignment: .top, spacing: 8) {
			ForEach(refs, id: \.self) { ref in
				TranscriptImage(ref: ref, store: store)
			}
		}
	}
}

private struct TranscriptImage: View {
	let ref: ImageRef
	let store: ConversationStore
	@State private var data: Data?
	@State private var failed = false

	var body: some View {
		Group {
			if let data, let image = NSImage(data: data) {
				Button {
					open(data)
				} label: {
					Image(nsImage: image)
						.resizable()
						.frame(width: Self.fit(image.size).width, height: Self.fit(image.size).height)
						.overlay(Rectangle().stroke(Palette.rule2))
				}
				.buttonStyle(.plain)
				.help("Open in Preview")
			} else {
				Text(failed ? "[image unavailable]" : "[image]")
					.font(Typography.uiSmall)
					.foregroundStyle(Palette.ink3)
					.frame(width: 120, height: 80)
					.overlay(Rectangle().stroke(Palette.rule))
			}
		}
		.task(id: ref) {
			do {
				data = try await store.image(ref)
			} catch {
				failed = true
			}
		}
	}

	/// The image's size within 320 × 200, never larger than it is.
	static func fit(_ size: CGSize) -> CGSize {
		guard size.width > 0, size.height > 0 else { return CGSize(width: 120, height: 80) }
		let scale = min(1, 320 / size.width, 200 / size.height)
		return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
	}

	private func open(_ data: Data) {
		let ext = UTType(mimeType: ref.mimeType)?.preferredFilenameExtension ?? "png"
		let url = FileManager.default.temporaryDirectory.appending(path: "amyrlin-\(store.id)-\(ref.entryId)-\(ref.index).\(ext)")
		do {
			try data.write(to: url)
			NSWorkspace.shared.open(url)
		} catch {
			failed = true
		}
	}
}
