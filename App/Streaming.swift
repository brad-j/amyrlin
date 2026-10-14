import AmyrlinCore
import SwiftUI

extension Animation {
	/// A row arriving or leaving the transcript, and the rows around it making room.
	static let row = Animation.smooth(duration: 0.28)
	/// A call's mark or status changing: waiting, running, done.
	static let state = Animation.snappy(duration: 0.22)
}

extension AnyTransition {
	/// A transcript row arriving: it fades up from just below. Leaving, it fades.
	static var rowArrival: AnyTransition {
		.asymmetric(insertion: .opacity.combined(with: .offset(y: 6)), removal: .opacity)
	}

	/// An answer arriving. The first words of an answer are what close a run of calls, so it often arrives as the run
	/// folds above it; it waits for the fold to make room rather than fading in over the rows still moving up.
	static var answerArrival: AnyTransition {
		.asymmetric(
			insertion: .opacity.combined(with: .offset(y: 6)).animation(Animation.row.delay(0.22)),
			removal: .opacity
		)
	}
}

/// Content that opens and closes in place: its frame's height animates between nothing and the content's own,
/// clipped, as it fades. Two things make that work. The height is measured, because SwiftUI can't interpolate
/// between a natural height and zero; it would snap the layout and only fade the drawing. And the change is made in
/// its own animated transaction, so every row it moves (the rest of the round, the rows below) glides with it rather
/// than jumping to where it ends up. Closed content is kept only while it animates away.
struct Disclosure<Content: View>: View {
	let open: Bool
	@ViewBuilder let content: Content
	@State private var mounted: Bool
	/// Whether the frame takes the content's height or none; follows `open` once the content is measured.
	@State private var shown: Bool
	@State private var height: CGFloat?

	init(open: Bool, @ViewBuilder content: () -> Content) {
		self.open = open
		self.content = content()
		_mounted = State(initialValue: open)
		_shown = State(initialValue: open)
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			if mounted { content }
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.fixedSize(horizontal: false, vertical: true)
		.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measured in
			height = measured
			// Opening content that wasn't there before: now that it's measured, it can grow from nothing.
			if open, !shown, measured > 0 { withAnimation(.row) { shown = true } }
		}
		.frame(height: shown ? height : 0, alignment: .top)
		.clipped()
		.opacity(shown ? 1 : 0)
		.onChange(of: open) { _, now in
			if now {
				if mounted, (height ?? 0) > 0 { withAnimation(.row) { shown = true } } else { mounted = true }
			} else {
				withAnimation(.row) { shown = false }
				Task {
					try? await Task.sleep(for: .seconds(0.4))
					if !open { mounted = false }
				}
			}
		}
	}
}

extension EnvironmentValues {
	/// How far each streamed row has been revealed, shared by the transcript's rows.
	@Entry var revealLedger: RevealLedger?
}

/// Reveals `text` at `RevealPace` instead of as it arrives, and gives `content` the part to show and whether it's
/// still catching up. Rows already there when the transcript opened show in full; only what arrives after reveals.
struct Revealing<Content: View>: View {
	let id: String
	let text: String
	@ViewBuilder let content: (_ visible: String, _ revealing: Bool) -> Content
	@Environment(\.revealLedger) private var ledger
	@State private var clock = RevealClock()
	@State private var active = false

	var body: some View {
		let length = text.count
		TimelineView(.animation(paused: !active)) { context in
			let shown = clock.advance(id: id, length: length, ledger: ledger, at: context.date, running: active)
			content(shown >= length ? text : String(text.prefix(shown)), shown < length)
				.onChange(of: shown >= length) { _, caughtUp in
					if caughtUp { active = false }
				}
		}
		.onAppear { active = clock.start(id: id, length: length, ledger: ledger) < length }
		.onChange(of: length) { _, new in
			if clock.shown < Double(new) { active = true }
		}
	}
}

/// The reveal's position, a class so that advancing it each frame doesn't invalidate the view it's drawn in.
@MainActor
final class RevealClock {
	private(set) var shown = -1.0
	private var last: Date?

	/// Where to start: from the ledger, once.
	func start(id: String, length: Int, ledger: RevealLedger?) -> Int {
		if shown < 0 { shown = ledger?.shown(id, length: length) ?? Double(length) }
		return Int(shown)
	}

	/// Characters to show at `date`.
	func advance(id: String, length: Int, ledger: RevealLedger?, at date: Date, running: Bool) -> Int {
		_ = start(id: id, length: length, ledger: ledger)
		guard running else {
			last = nil
			shown = min(shown, Double(length))
			return Int(shown)
		}
		// After a pause the timeline's first frame says nothing about how long a frame is.
		let elapsed = last.map { min(date.timeIntervalSince($0), 1.0 / 30) } ?? 1.0 / 120
		last = date
		shown = RevealPace.advance(shown, towards: length, elapsed: elapsed)
		ledger?.record(id, shown)
		return Int(shown)
	}
}

/// Draws the last `span` glyphs of a text fading towards its end, so freshly revealed words ease in instead of
/// popping. Only the last text of a block still being revealed gets it.
struct TailFade: TextRenderer {
	var span = 36.0
	var floor = 0.12

	func draw(layout: Text.Layout, in context: inout GraphicsContext) {
		var total = 0
		for line in layout { for run in line { total += run.count } }
		var index = 0
		for line in layout {
			for run in line {
				for slice in run {
					let fromEnd = Double(total - 1 - index)
					index += 1
					if fromEnd >= span {
						context.draw(slice)
					} else {
						var faded = context
						let t = fromEnd / span
						faded.opacity = floor + (1 - floor) * t * t * (3 - 2 * t)
						faded.draw(slice)
					}
				}
			}
		}
	}
}

extension Text {
	/// `TailFade` while `on`, the plain text otherwise.
	@ViewBuilder func tailFade(_ on: Bool) -> some View {
		if on { textRenderer(TailFade()) } else { self }
	}
}

/// A light passing across the text, for work in progress such as "thinking".
struct Shimmer: ViewModifier {
	var base: Color = Palette.ink3
	var highlight: Color = Palette.ink

	func body(content: Content) -> some View {
		TimelineView(.animation) { context in
			let period = 1.8
			let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
			let centre = -0.4 + phase * 1.8
			content.foregroundStyle(
				LinearGradient(
					stops: [
						.init(color: base, location: min(max(centre - 0.35, 0), 1)),
						.init(color: highlight, location: min(max(centre, 0), 1)),
						.init(color: base, location: min(max(centre + 0.35, 0), 1)),
					],
					startPoint: .leading,
					endPoint: .trailing
				)
			)
		}
	}
}

extension View {
	func shimmer() -> some View { modifier(Shimmer()) }
}
