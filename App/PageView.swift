import AmyrlinCore
import AppKit
import SwiftUI
import WebKit

/// A page the agent published, in place of its `publish_page` call: the title, then the page at its content's height
/// up to `maxHeight` (it scrolls inside past that), with a button that opens it full screen. Fetched through the
/// conversation's store, which keeps it.
struct PageView: View {
	let page: TranscriptPage
	@Environment(ConversationStore.self) private var store
	@State private var loaded: PublishedPage?
	@State private var failure: String?
	@State private var height: CGFloat?

	static var maxHeight: CGFloat { 640 * Typography.textScale }
	static var placeholderHeight: CGFloat { 120 * Typography.textScale }

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack(spacing: 8) {
				Text(loaded?.title ?? page.title)
					.font(Typography.uiStrong)
					.foregroundStyle(Palette.ink2)
					.lineLimit(1)
					.truncationMode(.tail)
				if let bytes = page.bytes {
					Text(TranscriptFile.size(bytes)).font(Typography.uiSmall).foregroundStyle(Palette.ink3)
				}
				Spacer(minLength: 0)
				if let loaded {
					IconButton("arrow.up.left.and.arrow.down.right", color: Palette.ink3) { PageWindow.open(loaded) }
						.help("Open full screen")
				}
			}
			ZStack {
				if let loaded {
					PageWebView(html: loaded.enforcedHTML, maxHeight: Self.maxHeight) { measured in
						if height != measured { height = measured }
					}
					// Hidden until measured, so a page doesn't flash at the placeholder's height first.
					.opacity(height == nil ? 0 : 1)
				}
				if loaded == nil || height == nil {
					Text(failure.map { "[page unavailable: \($0)]" } ?? "[loading page]")
						.font(Typography.uiSmall)
						.foregroundStyle(failure == nil ? Palette.ink3 : Palette.bad)
				}
			}
			.frame(maxWidth: .infinity)
			.frame(height: min(height ?? Self.placeholderHeight, Self.maxHeight))
			.overlay(Rectangle().stroke(Palette.rule))
		}
		.padding(.leading, 24)
		.padding(.vertical, 6)
		.task(id: page.page) {
			guard loaded == nil else { return }
			do {
				loaded = try await store.page(page.page)
				failure = nil
			} catch let error as ProtocolError {
				failure = error.message
			} catch {
				failure = String(describing: error)
			}
		}
	}
}

/// A web view holding one page's HTML, loaded from a string. It has no bridge to the app: no script message handlers,
/// no user scripts, and a data store that's thrown away with it. The page's own scripts run. Any navigation away from
/// the page opens in the default browser instead, and `onHeight` hears the content's height whenever it may have
/// changed (after loading, a few times as its scripts settle, and when the width changes).
struct PageWebView: NSViewRepresentable {
	let html: String
	/// The height past which the page scrolls inside; below it, the scroll wheel goes on to the transcript. Nil scrolls
	/// inside always, as full screen.
	var maxHeight: CGFloat?
	var onHeight: ((CGFloat) -> Void)?

	func makeCoordinator() -> Coordinator { Coordinator() }

	func makeNSView(context: Context) -> WKWebView {
		let configuration = WKWebViewConfiguration()
		configuration.websiteDataStore = .nonPersistent()
		configuration.userContentController = WKUserContentController()
		configuration.defaultWebpagePreferences.allowsContentJavaScript = true
		configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
		configuration.preferences.isElementFullscreenEnabled = false
		let view = MeasuredWebView(frame: .zero, configuration: configuration)
		view.navigationDelegate = context.coordinator
		view.uiDelegate = context.coordinator
		view.allowsBackForwardNavigationGestures = false
		view.allowsMagnification = false
		view.scrollsInside = maxHeight == nil
		view.onWidthChange = { [weak coordinator = context.coordinator] in coordinator?.measure() }
		context.coordinator.view = view
		return view
	}

	func updateNSView(_ view: WKWebView, context: Context) {
		context.coordinator.onHeight = { [weak view] height in
			(view as? MeasuredWebView)?.scrollsInside = maxHeight.map { height > $0 } ?? true
			onHeight?(height)
		}
		guard context.coordinator.html != html else { return }
		context.coordinator.html = html
		// No base URL: the page is about:blank, with no origin of the app's or the host's to reach.
		view.loadHTMLString(html, baseURL: nil)
	}

	static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
		view.stopLoading()
		coordinator.settle?.cancel()
	}

	@MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
		weak var view: WKWebView?
		var html: String?
		var onHeight: ((CGFloat) -> Void)?
		var settle: Task<Void, Never>?

		/// The bottom of the body's content, margin included. Not `documentElement.scrollHeight`, which is never less
		/// than the view's own height, so a page would never shrink from where it started. It runs in the app's own
		/// content world, so the page's scripts can't see it or change what it reads.
		private static let script = """
		(() => {
			const b = document.body;
			if (!b) return 0;
			const bottom = b.getBoundingClientRect().bottom + window.scrollY + (parseFloat(getComputedStyle(b).marginBottom) || 0);
			return Math.ceil(Math.max(bottom, b.scrollHeight));
		})()
		"""

		func measure() {
			guard let view else { return }
			view.evaluateJavaScript(Self.script, in: nil, in: .defaultClient) { [weak self] result in
				guard case .success(let value) = result, let number = value as? NSNumber, number.doubleValue > 0 else { return }
				self?.onHeight?(CGFloat(number.doubleValue))
			}
		}

		func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
			measure()
			// Charts and the like draw after load; measure again as they settle.
			settle?.cancel()
			settle = Task { [weak self] in
				for wait in [150, 500, 1500] {
					try? await Task.sleep(for: .milliseconds(wait))
					guard !Task.isCancelled else { return }
					self?.measure()
				}
			}
		}

		func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
			guard let url = action.request.url else { return decisionHandler(.cancel) }
			// The page itself (about:blank, from the string), its anchors, and srcdoc frames load in place.
			if url.scheme == "about" { return decisionHandler(.allow) }
			// Anything else leaves the page. A frame loading on its own isn't the user following a link, so it's
			// only stopped; a link the user clicked, or the page itself going somewhere, opens in the browser.
			let mainFrame = action.targetFrame?.isMainFrame ?? true
			if mainFrame || action.navigationType == .linkActivated { Self.openOutside(url) }
			decisionHandler(.cancel)
		}

		/// `target="_blank"` and `window.open`: the browser, never a window of the app's.
		func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
			if let url = action.request.url, action.navigationType == .linkActivated || action.targetFrame == nil { Self.openOutside(url) }
			return nil
		}

		private static func openOutside(_ url: URL) {
			guard let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else { return }
			NSWorkspace.shared.open(url)
		}
	}
}

/// Says when its width changes, since the page's height changes with it, and passes the scroll wheel on to the
/// transcript while the whole page shows, so scrolling over it scrolls the transcript.
private final class MeasuredWebView: WKWebView {
	var onWidthChange: (() -> Void)?
	var scrollsInside = false
	private var lastWidth: CGFloat = 0

	override func scrollWheel(with event: NSEvent) {
		if scrollsInside { super.scrollWheel(with: event) } else { nextResponder?.scrollWheel(with: event) }
	}

	override func layout() {
		super.layout()
		guard abs(bounds.width - lastWidth) > 0.5 else { return }
		lastWidth = bounds.width
		onWidthChange?()
	}
}

/// A page in a window of its own, full screen. Escape closes it.
@MainActor
enum PageWindow {
	private static var open: Set<NSWindow> = []

	static func open(_ page: PublishedPage) {
		let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
		let window = EscapableWindow(contentRect: screen, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
		window.title = page.title
		window.isReleasedWhenClosed = false
		window.collectionBehavior.insert(.fullScreenPrimary)
		window.contentView = NSHostingView(rootView: PageWebView(html: page.enforcedHTML, maxHeight: nil).ignoresSafeArea())
		open.insert(window)
		NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
			MainActor.assumeIsolated { _ = open.remove(window) }
		}
		window.makeKeyAndOrderFront(nil)
		window.toggleFullScreen(nil)
	}

	private final class EscapableWindow: NSWindow {
		override func cancelOperation(_ sender: Any?) { close() }
	}
}
