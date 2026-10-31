import AmyrlinCore
import AppKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// Images, videos and files waiting to go with a message: from the attach button, a drop, or a paste. Images and
/// videos are prepared as they're added (AmyrlinCore's ImagePreparation and VideoPreparation), so sending is immediate
/// once nothing is preparing; anything else goes as a file, read as it's added, to hosts that take files.
@MainActor @Observable
final class Attachments {
	struct Item: Identifiable {
		let id = UUID()
		let upload: ImageUpload
		let preview: NSImage
	}

	struct Video: Identifiable {
		let id = UUID()
		let upload: VideoUpload
		/// Its first frame.
		let preview: NSImage?
	}

	struct File: Identifiable {
		let id = UUID()
		let upload: FileUpload
		let bytes: Int
	}

	private(set) var items: [Item] = []
	private(set) var videos: [Video] = []
	private(set) var files: [File] = []
	/// aludra's limit on a message's files, until a host says otherwise.
	nonisolated static let maxFiles = 20
	/// The most one file is read for: aludra takes 25 MB of files a message.
	nonisolated static let maxFileBytes = 25 * 1024 * 1024
	/// Videos being re-encoded; a message waits for them.
	private(set) var preparing = 0
	/// Why the last image or video couldn't be added, until the next one is.
	var problem: String?
	/// Bumped when the list is taken, so videos still preparing then don't land in the next message.
	@ObservationIgnored private var generation = 0

	var isEmpty: Bool { items.isEmpty && videos.isEmpty && files.isEmpty }
	var isPreparing: Bool { preparing > 0 }
	var isFull: Bool { items.count >= ImagePreparation.maxImages && videos.count + preparing >= VideoPreparation.maxVideos && files.count >= Self.maxFiles }

	func add(_ data: [Data]) {
		guard !data.isEmpty else { return }
		problem = nil
		Task {
			for chunk in data {
				guard items.count < ImagePreparation.maxImages else {
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

	/// Images go as images and videos as videos; anything else goes as a file.
	func add(files: [URL]) {
		let movies = files.filter(Self.isMovie)
		add(files.filter(Self.isImage).compactMap { try? Data(contentsOf: $0) })
		for movie in movies { add(video: movie) }
		add(others: files.filter { !Self.isImage($0) && !Self.isMovie($0) })
	}

	/// Files sent as they are. A folder, or a file that can't be read, says why instead.
	private func add(others urls: [URL]) {
		guard !urls.isEmpty else { return }
		problem = nil
		Task {
			for url in urls {
				guard files.count < Self.maxFiles else {
					problem = "A message takes at most \(Self.maxFiles) files."
					return
				}
				do {
					let file = try await Task.detached(priority: .userInitiated) { try Self.read(url) }.value
					files.append(file)
				} catch {
					problem = (error as? FileProblem)?.description ?? "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
				}
			}
		}
	}

	struct FileProblem: Error, CustomStringConvertible {
		let description: String
	}

	nonisolated private static func read(_ url: URL) throws -> File {
		let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentTypeKey])
		if values.isDirectory == true { throw FileProblem(description: "\(url.lastPathComponent) is a folder; zip it to send it.") }
		if let size = values.fileSize, size > maxFileBytes {
			throw FileProblem(description: "\(url.lastPathComponent) is \(TranscriptFile.size(size)); a message's files take at most \(maxFileBytes / 1_048_576) MB together.")
		}
		let data = try Data(contentsOf: url)
		let type = values.contentType ?? UTType(filenameExtension: url.pathExtension)
		return File(upload: FileUpload(name: url.lastPathComponent, mimeType: type?.preferredMIMEType, data: data.base64EncodedString()), bytes: data.count)
	}

	func remove(_ file: File) {
		files.removeAll { $0.id == file.id }
	}

	private func add(video url: URL) {
		problem = nil
		guard videos.count + preparing < VideoPreparation.maxVideos else {
			problem = "A message takes at most \(VideoPreparation.maxVideos) videos."
			return
		}
		preparing += 1
		let generation = generation
		Task {
			defer { if generation == self.generation { preparing -= 1 } }
			do {
				let upload = try await Task.detached(priority: .userInitiated) { try await VideoPreparation.prepare(url) }.value
				guard generation == self.generation else { return }
				guard videos.reduce(upload.data.count, { $0 + $1.upload.data.count }) / 4 * 3 <= VideoPreparation.maxBytes else {
					problem = "A message's videos take at most \(VideoPreparation.maxBytes / 1_048_576) MB together."
					return
				}
				let preview = upload.frames.first.flatMap { Data(base64Encoded: $0.data) }.flatMap(NSImage.init(data:))
				videos.append(Video(upload: upload, preview: preview))
			} catch {
				guard generation == self.generation else { return }
				problem = (error as? VideoPreparation.Failure)?.description ?? String(describing: error)
			}
		}
	}

	func remove(_ item: Item) {
		items.removeAll { $0.id == item.id }
	}

	func remove(_ video: Video) {
		videos.removeAll { $0.id == video.id }
	}

	/// Whether a host must turn the attachments away: one whose `host.info` says nothing of videos or files would drop
	/// them without a word, and one with limits refuses a message past them. Says why in `problem`.
	func refused(by info: AmyrlinCore.Commands.HostInfo.Result?) -> Bool {
		if !videos.isEmpty, info?.videos == nil {
			problem = "This machine's aludra doesn't take videos yet; update it, or remove the video."
			return true
		}
		if let reason = AttachmentBudget.problem(images: items.map(\.upload), videos: videos.map(\.upload), files: files.map(\.upload), limits: info?.files) {
			problem = reason
			return true
		}
		return false
	}

	/// The images, videos and files to send, emptying the list; videos still preparing are dropped.
	func take() -> (images: [ImageUpload], videos: [VideoUpload], files: [FileUpload]) {
		defer {
			items = []
			videos = []
			files = []
			preparing = 0
			problem = nil
			generation += 1
		}
		return (items.map(\.upload), videos.map(\.upload), files.map(\.upload))
	}

	/// Opens the file picker: images, videos or any other file.
	func pick() {
		let panel = NSOpenPanel()
		panel.allowedContentTypes = [.item]
		panel.allowsMultipleSelection = true
		panel.canChooseDirectories = false
		panel.prompt = "Attach"
		if panel.runModal() == .OK { add(files: panel.urls) }
	}

	/// Files on the pasteboard (images, videos or anything else), or image data when there's no text to paste instead.
	/// False when there's none of them.
	func paste(from pasteboard: NSPasteboard = .general) -> Bool {
		let files = Self.fileURLs(on: pasteboard)
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

	/// A drop's files, ones another app promises to write (Photos, say), or image data. False when it has none.
	func drop(from pasteboard: NSPasteboard) -> Bool {
		let files = Self.fileURLs(on: pasteboard)
		if !files.isEmpty {
			add(files: files)
			return true
		}
		let promises = Self.mediaPromises(on: pasteboard)
		if !promises.isEmpty {
			let folder = FileManager.default.temporaryDirectory.appending(path: "amyrlin-drop-\(UUID().uuidString)")
			try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
			for promise in promises {
				promise.receivePromisedFiles(atDestination: folder, operationQueue: Self.promiseQueue) { url, error in
					guard error == nil else { return }
					Task { @MainActor in self.add(files: [url]) }
				}
			}
			return true
		}
		for type in [NSPasteboard.PasteboardType.png, .tiff] {
			if let data = pasteboard.data(forType: type) {
				add([data])
				return true
			}
		}
		return false
	}

	/// Whether a drag carries anything `drop` takes.
	static func hasMedia(_ pasteboard: NSPasteboard) -> Bool {
		!fileURLs(on: pasteboard).isEmpty || !mediaPromises(on: pasteboard).isEmpty || pasteboard.availableType(from: [.png, .tiff]) != nil
	}

	/// The types a drop target registers for so `drop` sees them.
	static let dropTypes: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

	private static let promiseQueue = OperationQueue()

	private static func type(of url: URL) -> UTType? { UTType(filenameExtension: url.pathExtension) }
	private static func isImage(_ url: URL) -> Bool { type(of: url)?.conforms(to: .image) == true }
	private static func isMovie(_ url: URL) -> Bool { type(of: url)?.conforms(to: .movie) == true }

	private static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
		pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
	}

	private static func mediaPromises(on pasteboard: NSPasteboard) -> [NSFilePromiseReceiver] {
		pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver] ?? []
	}
}

/// Attached images, videos and files above the text, each with a way to take it off; a video shows its first frame and
/// length, a file its name and size.
struct AttachmentStrip: View {
	let attachments: Attachments

	var body: some View {
		if !attachments.isEmpty || attachments.isPreparing || attachments.problem != nil {
			VStack(alignment: .leading, spacing: 6) {
				if !attachments.files.isEmpty {
					Wrapping(spacing: 6) {
						ForEach(attachments.files) { file in
							FileChip(name: file.upload.name, detail: TranscriptFile.size(file.bytes), help: "Remove this file") { attachments.remove(file) }
						}
					}
				}
				HStack(spacing: 8) {
					ForEach(attachments.items) { item in
						thumbnail(item.preview, help: "Remove this image") { attachments.remove(item) }
					}
					ForEach(attachments.videos) { video in
						thumbnail(video.preview, help: "Remove this video") { attachments.remove(video) }
							.overlay(alignment: .bottomLeading) {
								Text(video.upload.seconds.map(TranscriptVideo.clock) ?? "video")
									.font(Typography.uiSmall)
									.foregroundStyle(Palette.ink)
									.padding(.horizontal, 3)
									.background(Palette.paper3)
							}
					}
					ForEach(0..<attachments.preparing, id: \.self) { _ in
						ProgressView()
							.controlSize(.small)
							.frame(width: 52, height: 52)
							.overlay(Rectangle().stroke(Palette.rule2))
							.help("Preparing the video to send")
					}
				}
				if let problem = attachments.problem {
					Text(problem).font(Typography.uiSmall).foregroundStyle(Palette.bad)
				}
			}
		}
	}

	private func thumbnail(_ preview: NSImage?, help: String, remove: @escaping () -> Void) -> some View {
		Group {
			if let preview {
				Image(nsImage: preview).resizable().scaledToFill()
			} else {
				Palette.paper3
			}
		}
		.frame(width: 52, height: 52)
		.clipped()
		.overlay(Rectangle().stroke(Palette.rule2))
		.overlay(alignment: .topTrailing) {
			Button(action: remove) {
				Text("×")
					.font(Typography.uiSmall)
					.foregroundStyle(Palette.ink)
					.frame(width: 16, height: 16)
					.background(Palette.paper3)
			}
			.buttonStyle(.plain)
			.help(help)
		}
	}
}

/// Takes images and videos dropped on the view, and pasted (⌘V) while `focused` is true. The text field's editor would take the
/// paste first and ignore an image, so ⌘V is looked at before it; it would take a drop too, so DropCatcher sits above it. Long text goes into the field as a marker that
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
			.overlay(DropCatcher(attachments: attachments, targeted: $targeted))
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
}

/// Takes image and video drops over the view it covers. While the text field is editing, its editor registers for files and
/// images and would take them as text (a file's path, or nothing), and AppKit gives a drop to the frontmost view
/// registered for it, so this lies on top for drops and lets clicks through to what's beneath.
private struct DropCatcher: NSViewRepresentable {
	let attachments: Attachments
	@Binding var targeted: Bool

	func makeNSView(context: Context) -> Catcher {
		Catcher()
	}

	func updateNSView(_ view: Catcher, context: Context) {
		view.attachments = attachments
		view.targeted = $targeted
	}

	final class Catcher: NSView {
		var attachments: Attachments?
		var targeted: Binding<Bool>?

		init() {
			super.init(frame: .zero)
			registerForDraggedTypes(Attachments.dropTypes)
		}

		required init?(coder: NSCoder) { nil }

		override func hitTest(_ point: NSPoint) -> NSView? { nil }

		override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
			guard Attachments.hasMedia(sender.draggingPasteboard) else { return [] }
			targeted?.wrappedValue = true
			return .copy
		}

		override func draggingExited(_ sender: NSDraggingInfo?) {
			targeted?.wrappedValue = false
		}

		override func draggingEnded(_ sender: NSDraggingInfo) {
			targeted?.wrappedValue = false
		}

		override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
			targeted?.wrappedValue = false
			return attachments?.drop(from: sender.draggingPasteboard) ?? false
		}
	}
}

extension View {
	func acceptsPastes(_ attachments: Attachments, text pasted: PastedText, focused: Bool) -> some View {
		modifier(AcceptsPastes(attachments: attachments, pasted: pasted, focused: focused))
	}
}

/// A file as a chip: an icon, its name and a detail (its size, or how long the host keeps it), with × when it can be
/// taken off.
struct FileChip: View {
	let name: String
	let detail: String
	var help: String = ""
	var remove: (() -> Void)?

	var body: some View {
		HStack(spacing: 6) {
			Image(systemName: "doc").foregroundStyle(Palette.ink3)
			// The name gives way before the size and date.
			Text(name).foregroundStyle(Palette.ink2).lineLimit(1).truncationMode(.middle)
			Text(detail).foregroundStyle(Palette.ink3).lineLimit(1).fixedSize()
			if let remove {
				Button(action: remove) {
					Text("×").foregroundStyle(Palette.ink)
				}
				.buttonStyle(.plain)
				.help(help)
			}
		}
		.font(Typography.uiSmall)
		.padding(.horizontal, 7)
		.padding(.vertical, 4)
		.background(Palette.paper3)
		.overlay(Rectangle().stroke(Palette.rule2))
		.frame(maxWidth: 420, alignment: .leading)
	}
}

/// A file sent with a message, or long text the host saved to one, as a chip: its name, size and how long the host keeps
/// it. The path is in the tooltip and the context menu, for pointing an agent at it later.
struct TranscriptFileView: View {
	let file: TranscriptFile

	var body: some View {
		FileChip(name: file.name, detail: [file.bytes.map(TranscriptFile.size), file.keeping()].compactMap(\.self).joined(separator: " · "))
			.help(file.path)
			.contextMenu {
				Button("Copy Path on Host") {
					NSPasteboard.general.clearContents()
					NSPasteboard.general.setString(file.path, forType: .string)
				}
			}
	}
}

/// A video sent with a message: what it's called, how long it is and whether the host still has it, then the frames
/// sent with it. The path is in the tooltip and the context menu, for pointing an agent at it later.
struct TranscriptVideoView: View {
	let video: TranscriptVideo
	let store: ConversationStore

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack(spacing: 6) {
				Image(systemName: "film").foregroundStyle(Palette.ink3)
				Text(video.name).foregroundStyle(Palette.ink2)
				Text([video.seconds.map(TranscriptVideo.clock), video.keeping()].compactMap(\.self).joined(separator: " · "))
					.foregroundStyle(Palette.ink3)
			}
			.font(Typography.uiSmall)
			.help(video.path)
			.contextMenu {
				Button("Copy Path on Host") {
					NSPasteboard.general.clearContents()
					NSPasteboard.general.setString(video.path, forType: .string)
				}
			}
			if !video.frames.isEmpty {
				TranscriptImages(refs: video.frames, store: store)
			}
		}
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
struct Wrapping: Layout {
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
