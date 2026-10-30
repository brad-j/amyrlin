import AmyrlinCore
import AppKit
import SwiftUI

/// The transcript: a stack in a scroll view, in a centred reading column. It follows the bottom while what's
/// written grows, gliding rather than jumping, and stops following once the user scrolls away; scrolling back to the
/// bottom, or the arrow, follows again. Rows arriving fade up into place, and streamed text reveals at `RevealPace`.
struct TranscriptView: View {
	let store: ConversationStore
	@State private var ledger = RevealLedger()
	@State private var position = ScrollPosition(edge: .bottom)
	/// Whether the transcript keeps to the bottom as it grows. Only the user's own scrolling changes it.
	@State private var following = true
	@State private var userScrolling = false
	@State private var atBottom = true
	/// False until the first snapshot has been laid out, so opening a conversation doesn't animate its history in.
	@State private var settled = false
	/// True while the view is gliding down to the bottom.
	@State private var chasing = false
	/// The follow's working values, in a class so that changing them each frame doesn't redraw the transcript.
	@State private var follow = FollowState()

	private struct Geometry: Equatable {
		var offset: CGFloat = 0
		var bottom: CGFloat = 0
	}

	private final class FollowState {
		var geometry = Geometry()
		var lastTick: Date?
		/// Points a second.
		var velocity: CGFloat = 0
	}

	var body: some View {
		// The rows are their own view: the follow moves the scroll position every frame, and only this wrapper sees it.
		ScrollView {
			TranscriptRows(store: store, ledger: ledger, animated: settled) { id in
				position.scrollTo(id: id, anchor: .top)
			}
			.equatable()
		}
		.environment(\.revealLedger, ledger)
		.scrollPosition($position)
		.defaultScrollAnchor(.bottom, for: .initialOffset)
		.onScrollGeometryChange(for: Bool.self) { Self.isAtBottom($0, within: 4) } action: { _, bottom in
			// Scrolling back down to the very bottom follows again.
			if userScrolling, bottom { following = true }
		}
		.onScrollPhaseChange { _, phase, context in
			switch phase {
			// The follow sets positions without animating, so it makes no phases: any of these is the user, on a
			// trackpad (interacting, then decelerating with momentum) or a mouse wheel (decelerating alone).
			case .tracking, .interacting, .decelerating:
				userScrolling = true
			case .idle:
				if userScrolling {
					userScrolling = false
					// Any deliberate scroll up stops following; only ending right at the bottom keeps it.
					following = Self.isAtBottom(context.geometry, within: 4)
				}
			case .animating:
				break
			}
		}
		.onScrollGeometryChange(for: Bool.self) { Self.isAtBottom($0) } action: { _, bottom in
			atBottom = bottom
		}
		.onScrollGeometryChange(for: Geometry.self) { g in
			Geometry(offset: g.contentOffset.y, bottom: max(0, g.contentSize.height - g.containerSize.height + g.contentInsets.bottom))
		} action: { old, new in
			// While the follow glides it keeps its own offset: the scroll view reports a set position a frame late,
			// and starting a step from that would step back.
			follow.geometry.bottom = new.bottom
			if !chasing { follow.geometry.offset = new.offset }
			guard following, !userScrolling, new.bottom != old.bottom else { return }
			if settled { chase() } else { position.scrollTo(edge: .bottom) }
		}
		// The follow: a spring stepped each display frame, so growth glides into view. A ScrollPosition change in
		// withAnimation doesn't animate in a macOS scroll view; it jumps.
		.background {
			TimelineView(.animation(paused: !chasing)) { context in
				Color.clear.onChange(of: context.date) { _, now in step(now) }
			}
		}
		.onChange(of: store.state.hasSnapshot, initial: true) { _, has in
			guard has, !settled else { return }
			position.scrollTo(edge: .bottom)
			// After this layout pass: the snapshot's rows are in place, and what follows animates.
			Task { @MainActor in settled = true }
		}
		.onChange(of: store.outbox.count) { old, new in
			// Sending a message always goes to the bottom, wherever the user was reading.
			guard new > old else { return }
			following = true
			chase()
		}
		.overlay(alignment: .bottom) {
			if !atBottom, !following {
				Button {
					following = true
					chase()
				} label: {
					Image(systemName: "arrow.down")
						.font(.system(size: 12, weight: .semibold))
						.foregroundStyle(Palette.ink2)
						.frame(width: 30, height: 30)
						.background(Palette.paper3, in: Circle())
						.overlay(Circle().stroke(Palette.rule2))
				}
				.buttonStyle(.plain)
				.padding(.bottom, 10)
				.help("Scroll to the newest")
				.transition(.opacity.combined(with: .scale(scale: 0.85)))
			}
		}
		.animation(.state, value: !atBottom && !following)
	}

	private func chase() {
		guard !chasing else { return }
		follow.lastTick = nil
		follow.velocity = 0
		chasing = true
	}

	private func stopChasing() {
		chasing = false
		follow.velocity = 0
	}

	/// One frame of the follow: a critically damped spring towards the bottom, so the transcript eases into motion and
	/// settles without overshooting. A line glides in over about a quarter of a second, and a block that appears at
	/// once (a code block, a table) accelerates into view instead of lurching.
	private func step(_ now: Date) {
		guard following, !userScrolling else {
			stopChasing()
			return
		}
		let elapsed = follow.lastTick.map { min(now.timeIntervalSince($0), 1.0 / 30) } ?? 1.0 / 120
		follow.lastTick = now
		let bottom = follow.geometry.bottom
		let gap = bottom - follow.geometry.offset
		guard abs(gap) > 0.5 || abs(follow.velocity) > 5 else {
			if abs(gap) > 0 { position.scrollTo(y: bottom) }
			follow.geometry.offset = bottom
			stopChasing()
			return
		}
		let omega: CGFloat = 22
		follow.velocity += (omega * omega * gap - 2 * omega * follow.velocity) * elapsed
		var next = follow.geometry.offset + follow.velocity * elapsed
		// Never past the bottom: a spring that would overshoot lands instead.
		if (gap > 0 && next > bottom) || (gap < 0 && next < bottom) {
			next = bottom
			follow.velocity = 0
		}
		position.scrollTo(y: next)
		follow.geometry.offset = next
	}

	/// Near the bottom: within 48 points hides the arrow; deciding whether to follow takes `within: 4`.
	private static func isAtBottom(_ geometry: ScrollGeometry, within slack: CGFloat = 48) -> Bool {
		geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - slack
	}
}

/// The transcript's rows, animated as they arrive once `animated`. They're in a plain stack, laid out exactly: a lazy
/// stack estimates the height of rows it hasn't laid out and corrects it as they come and go, which made the content
/// jump by thousands of points while an answer streamed over a long history. To keep a plain stack cheap, it holds a
/// window: from `window` rows before the end when the transcript opened, plus every row after. "Show earlier" at the top
/// adds `window` older rows at a time, keeping the row that was first where it was.
private struct TranscriptRows: View, Equatable {
	let store: ConversationStore
	let ledger: RevealLedger
	let animated: Bool
	/// Scrolls so row `id` is at the top, after earlier rows are added above it.
	let keepAtTop: (String) -> Void
	/// How many times "show earlier" was used.
	@State private var pages = 0

	private static let window = 60

	/// The follow moves the scroll position every frame, which rebuilds the view holding this one; comparing the data
	/// (not the closure) keeps that from rebuilding every row.
	nonisolated static func == (a: Self, b: Self) -> Bool {
		a.store === b.store && a.ledger === b.ledger && a.animated == b.animated
	}

	var body: some View {
		let rows = TranscriptLayout.rows(state: store.state, outbox: store.outbox)
		let _ = prime(rows)
		let start = startIndex(rows)
		VStack(spacing: 0) {
			if start > 0 {
				Button {
					let first = rows[start].id
					pages += 1
					keepAtTop(first)
				} label: {
					Text("[show \(min(start, Self.window)) earlier]")
						.font(Typography.uiSmall)
						.foregroundStyle(Palette.ink3)
						.frame(maxWidth: .infinity)
						.padding(.vertical, 10)
						.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
				.help("\(start) earlier rows aren't shown")
			}
			ForEach(rows[start...]) { row in
				// Equatable: as one row streams, the others aren't rebuilt.
				ReadingColumn(measure: Metrics.measure, margin: 24) {
					TranscriptRowView(row: row, store: store).equatable()
				}
					.opacity(row.inContext ? 1 : 0.45)
					.transition(row.isText ? .answerArrival : .rowArrival)
			}
		}
		.scrollTargetLayout()
		.padding(.bottom, 8)
		.animation(animated ? .row : nil, value: rows.map(\.id))
	}

	/// The first row shown: `window` rows before the end when the transcript opened (or a fresh snapshot replaced its
	/// rows), less a window for each "show earlier".
	private func startIndex(_ rows: [TranscriptRow]) -> Int {
		guard store.state.hasSnapshot, !rows.isEmpty else { return 0 }
		let anchor: Int
		if let id = ledger.recentStart, let index = rows.firstIndex(where: { $0.id == id }) {
			anchor = index
		} else {
			anchor = max(0, rows.count - Self.window)
			ledger.recentStart = rows[anchor].id
		}
		return max(0, anchor - pages * Self.window)
	}

	/// Rows already there when the snapshot first arrives show in full; the ledger reveals only what comes after.
	private func prime(_ rows: [TranscriptRow]) {
		guard store.state.hasSnapshot, !ledger.isPrimed else { return }
		ledger.prime(rows.map { row in
			switch row.kind {
			case .text(let text, _), .thinking(let text, _, _): (row.id, text.count)
			default: (row.id, 0)
			}
		})
	}
}

struct TranscriptRowView: View, Equatable {
	let row: TranscriptRow
	let store: ConversationStore

	nonisolated static func == (a: Self, b: Self) -> Bool {
		a.row == b.row && a.store === b.store
	}

	var body: some View {
		// Rows' images fetch through the conversation's store.
		content.environment(store)
	}

	@ViewBuilder private var content: some View {
		switch row.kind {
		case .loadEarlier:
			HStack(spacing: 8) {
				Spacer()
				ProgressView().controlSize(.small)
				Text("Loading earlier messages").font(Typography.readingSmall).foregroundStyle(Palette.ink3)
				Spacer()
			}
			.padding(.vertical, 10)
			.task { await store.loadEarlier() }
		case .user(let text, _, let images, let videos):
			InputRow(text: text, images: images, videos: videos)
		case .text(let text, let streaming):
			AnswerBlock(id: row.id, text: text, streaming: streaming)
		case .thinking(let text, let redacted, let streaming):
			ThinkingRow(id: row.id, text: text, redacted: redacted, streaming: streaming)
		case .toolCall(let call):
			ToolCallView(call: call)
		case .toolRound(let round):
			ToolRoundView(round: round)
		case .notice(let notice):
			NoticeView(notice: notice)
		case .queued(let item):
			InputRow(text: item.text.map(TranscriptVideo.withoutNotes) ?? "Queued message", tag: item.mode == .steer ? "steer" : "queued", dim: true)
		case .pending(let pending):
			InputRow(text: pending.text, tag: pending.failure == nil ? "sending" : nil, dim: true, pendingImages: pending.images.count, pendingVideos: pending.videos.count, pending: pending)
		}
	}
}

// MARK: - Messages

/// The transcript's left gutter: one mono glyph per row, so prompts, answers and tools line up like a console.
private struct Gutter<Content: View>: View {
	let glyph: String
	var color: Color = Palette.ink3
	@ViewBuilder let content: Content

	var body: some View {
		HStack(alignment: .firstTextBaseline, spacing: 10) {
			Text(glyph)
				.font(Typography.ui)
				.foregroundStyle(color)
				.frame(width: 14, alignment: .center)
			content
				.frame(maxWidth: .infinity, alignment: .leading)
		}
	}
}

/// The user's message: a framed block with a `❯` prompt and a violet edge. The same row shows it sending, queued
/// and placed (one row ID throughout), so it brightens in place as it lands; a failed send offers retry.
private struct InputRow: View {
	let text: String
	var images: [ImageRef] = []
	var videos: [TranscriptVideo] = []
	var tag: String?
	var dim = false
	/// Images and videos not sent yet, shown as counts.
	var pendingImages = 0
	var pendingVideos = 0
	/// Set while it's the client's own send not yet placed.
	var pending: PendingSend?
	@Environment(ConversationStore.self) private var store

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			block
			Disclosure(open: pending?.failure != nil) {
				if let pending, let failure = pending.failure {
					HStack(spacing: 10) {
						Text(failure).foregroundStyle(Palette.bad)
						Button("[retry]") { store.retry(pending) }.buttonStyle(.plain).foregroundStyle(Palette.accent)
						Button("[discard]") { store.discard(pending) }.buttonStyle(.plain).foregroundStyle(Palette.ink3)
					}
					.font(Typography.uiSmall)
					.padding(.leading, 24)
				}
			}
		}
		.animation(.state, value: dim)
		.animation(.state, value: tag)
	}

	private var block: some View {
		Gutter(glyph: "❯", color: dim ? Palette.ink3 : Palette.accent) {
			VStack(alignment: .leading, spacing: 4) {
				if let tag {
					Text(tag).font(Typography.label).foregroundStyle(Palette.accent).transition(.opacity)
				}
				if !images.isEmpty {
					let prompt = 12.5 * Typography.scale
					TranscriptImages(refs: images, store: store)
						// The prompt sits beside the images' top edge rather than down by the text.
						.alignmentGuide(.firstTextBaseline) { $0[.top] + prompt }
						.padding(.bottom, text.isEmpty ? 0 : 6)
				}
				ForEach(videos, id: \.self) { video in
					TranscriptVideoView(video: video, store: store)
						.padding(.bottom, text.isEmpty && video == videos.last ? 0 : 6)
				}
				if pendingImages > 0 {
					Text(pendingImages == 1 ? "[1 image]" : "[\(pendingImages) images]").font(Typography.uiSmall).foregroundStyle(Palette.ink3)
				}
				if pendingVideos > 0 {
					Text(pendingVideos == 1 ? "[1 video]" : "[\(pendingVideos) videos]").font(Typography.uiSmall).foregroundStyle(Palette.ink3)
				}
				if !text.isEmpty {
					Text(text)
						.font(Typography.reading)
						.foregroundStyle(dim ? Palette.ink2 : Palette.ink)
						.lineSpacing(Typography.readingLineSpacing)
						.textSelection(.enabled)
				}
			}
			.padding(.horizontal, 12)
			.padding(.vertical, 9)
			.frame(maxWidth: .infinity, alignment: .leading)
			.background(Palette.paper2)
			.overlay(Rectangle().stroke(Palette.rule))
			.overlay(alignment: .leading) { Rectangle().fill(dim ? Palette.rule2 : Palette.accent).frame(width: 2) }
		}
		.padding(.top, 22)
		.padding(.bottom, 8)
	}
}

/// An answer: Markdown in IBM Plex Sans after a `●` mark, with `[copy]` on hover once it's finished. Streamed text
/// reveals smoothly, its newest words fading in; the mark is the accent until the answer is written out.
private struct AnswerBlock: View {
	let id: String
	let text: String
	let streaming: Bool
	@State private var hovering = false
	@State private var copied = false

	var body: some View {
		Revealing(id: id, text: text) { visible, revealing in
			answer(visible, writing: streaming || revealing)
		}
	}

	private func answer(_ visible: String, writing: Bool) -> some View {
		Gutter(glyph: "●", color: writing ? Palette.accent : Palette.ink3) {
			VStack(alignment: .leading, spacing: 4) {
				MarkdownView(source: visible, revealing: writing)
				if !writing {
					Button(copied ? "[copied]" : "[copy]") {
						NSPasteboard.general.clearContents()
						NSPasteboard.general.setString(text, forType: .string)
						copied = true
						Task {
							try? await Task.sleep(for: .seconds(1.5))
							copied = false
						}
					}
					.buttonStyle(.plain)
					.font(Typography.label)
					.foregroundStyle(copied ? Palette.add : Palette.ink3)
					.opacity(hovering || copied ? 1 : 0)
					.help("Copy the answer")
				}
			}
		}
		.padding(.vertical, 6)
		.onHover { hovering = $0 }
	}
}

/// `∴ thinking`, with a light passing over it while the model thinks, then `∴ thought`. Opened, the thinking itself,
/// revealed as it streams.
private struct ThinkingRow: View {
	let id: String
	let text: String
	let redacted: Bool
	let streaming: Bool
	@State private var expanded = false
	@Environment(\.revealLedger) private var ledger

	var body: some View {
		Gutter(glyph: "∴") {
			VStack(alignment: .leading, spacing: 6) {
				Button {
					// A finished thought opens whole; only one still streaming reveals.
					if !streaming { ledger?.record(id, Double(text.count)) }
					withAnimation(.row) { expanded.toggle() }
				} label: {
					ZStack(alignment: .leading) {
						if streaming {
							Text("thinking").shimmer().transition(.opacity)
						} else {
							Text("thought").foregroundStyle(Palette.ink3).transition(.opacity)
						}
					}
					.font(Typography.uiSmall)
					.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
				Disclosure(open: expanded) {
					Group {
						if redacted {
							Text("The provider redacted this thinking.")
						} else {
							Revealing(id: id, text: text) { visible, revealing in
								Text(visible).tailFade(revealing)
							}
						}
					}
					.font(Typography.readingSmall)
					.foregroundStyle(Palette.ink2)
					.lineSpacing(3)
					.textSelection(.enabled)
				}
			}
		}
		.padding(.vertical, 4)
		.animation(.state, value: streaming)
	}
}

// MARK: - Tool calls

/// A framed box: a header line, then whatever opens under it on darker paper.
private struct ConsoleBox<Header: View, Content: View>: View {
	@ViewBuilder let header: Header
	@ViewBuilder let content: Content

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			header
				.padding(.horizontal, 10)
				.padding(.vertical, 6)
			content
		}
		.background(Palette.paper2)
		// Opening content slides out from under the header, not over the rows above.
		.clipped()
		.overlay(Rectangle().stroke(Palette.rule))
	}
}

/// One call's line: mark, `$ command` (or the tool and its path), and its status at the right.
private struct CallLine: View {
	let call: ToolCallRow
	let expanded: Bool

	var body: some View {
		HStack(spacing: 8) {
			// Each state's mark replaces the last with a quick scale and fade: a call that finishes at once still reads
			// as waiting, then done.
			ZStack {
				StateMark(mark, size: 11)
					.id(mark)
					.transition(.scale(scale: 0.4).combined(with: .opacity))
			}
			.frame(width: 11, height: 11)
			Text(call.name == "bash" ? "$" : call.name)
				.foregroundStyle(Palette.ink3)
			Text(argument)
				.foregroundStyle(argument == "…" ? Palette.ink3 : Palette.ink)
				.lineLimit(1)
				.truncationMode(.tail)
				.contentTransition(.opacity)
			Spacer(minLength: 8)
			Text(status)
				.foregroundStyle(statusColor)
				.monospacedDigit()
				.contentTransition(.numericText())
			Text(expanded ? "▾" : "▸").foregroundStyle(Palette.ink3)
		}
		.font(Typography.code)
		.contentShape(Rectangle())
		.help(argumentFull)
		.animation(.state, value: mark)
		.animation(.state, value: status)
	}

	private var mark: StateMark.State {
		switch call.status {
		case .running: .running
		case .waiting: .queued
		case .needsApproval: .waiting
		case .done: .done
		case .failed: .failed
		case .ended, .noResult: .idle
		}
	}

	/// The one argument worth showing: a command, a path, a script's first line, or the arguments as JSON; `…` while
	/// they're still streaming.
	var argument: String {
		if case .object(let object) = call.args {
			if object.isEmpty { return "…" }
			for key in ["command", "path", "file_path", "pattern", "url", "query"] {
				if let value = object[key]?.stringValue { return value.replacingOccurrences(of: "\n", with: " ⏎ ") }
			}
			if let code = object["code"]?.stringValue { return Self.firstLine(of: code) }
			if object.count == 1, let value = object.values.first?.stringValue { return value }
		}
		return call.args.jsonText
	}

	/// A script's first line that says something: not blank, and not codemode's `// @options` line.
	static func firstLine(of code: String) -> String {
		let lines = code.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
		return lines.first { !$0.isEmpty && !$0.hasPrefix("// @options") } ?? "…"
	}

	var argumentFull: String {
		if case .object(let object) = call.args, object.count == 1, let value = object.values.first?.stringValue { return value }
		return call.args.jsonText
	}

	private var status: String {
		switch call.status {
		case .running: "running"
		case .waiting: "waiting"
		case .needsApproval: "needs you"
		case .done: call.result?.durationMs.map(ToolCallView.duration) ?? "ok"
		case .failed(let code): code ?? "error"
		case .ended: "no result"
		case .noResult: ""
		}
	}

	private var statusColor: Color {
		switch call.status {
		case .failed: Palette.bad
		case .needsApproval: Palette.wait
		case .running: Palette.accent
		default: Palette.ink3
		}
	}
}

/// What a call shows when open: its arguments when they're more than the line says, its output, its diagnostics.
private struct CallDetail: View {
	let call: ToolCallRow
	let tail: Bool
	@Environment(ConversationStore.self) private var store

	private static let tailLines = 8

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			if !tail, case .object(let args) = call.args {
				if args.count == 1, let (key, value) = args.first, let text = value.stringValue, text.contains("\n") {
					// One long argument, a script or a message, reads as itself rather than escaped in JSON.
					OutputText(text: text, label: key == "code" ? "script" : key)
				} else if args.count > 1 {
					OutputText(text: call.args.jsonText, label: "arguments")
				}
			}
			if !call.output.isEmpty {
				OutputText(text: tail ? tailText : fullText, minLines: tail ? Self.tailLines : nil)
			}
			if !tail, !call.images.isEmpty { TranscriptImages(refs: call.images, store: store) }
			ForEach(Array((call.result?.diagnostics ?? []).enumerated()), id: \.offset) { _, diagnostic in
				Text("\(diagnostic.severity): \(diagnostic.message)")
					.font(Typography.uiSmall)
					.foregroundStyle(diagnostic.severity == "error" ? Palette.bad : Palette.ink2)
			}
		}
		.padding(10)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(Palette.paper)
		.overlay(alignment: .top) { Rectangle().fill(Palette.rule).frame(height: 1) }
	}

	private var lines: [Substring] {
		call.output.trimmingCharacters(in: .newlines).split(separator: "\n", omittingEmptySubsequences: false)
	}

	private var tailText: String {
		lines.suffix(Self.tailLines).joined(separator: "\n")
	}

	private var fullText: String {
		guard lines.count > 400 else { return lines.joined(separator: "\n") }
		return "… \(lines.count - 400) earlier lines\n" + lines.suffix(400).joined(separator: "\n")
	}
}

/// One call in a box. A running call shows a fixed-height tail of its output; a finished one opens on click.
private struct ToolCallView: View {
	let call: ToolCallRow
	@State private var expanded = false

	var body: some View {
		ConsoleBox {
			Button {
				withAnimation(.row) { expanded.toggle() }
			} label: {
				CallLine(call: call, expanded: expanded || running)
			}
			.buttonStyle(.plain)
		} content: {
			// The running tail opens under the line once output starts and folds away when the call ends; it stays a
			// tail while it folds, so it doesn't become the whole output on its way out.
			Disclosure(open: opened) {
				CallDetail(call: call, tail: running || !expanded)
			}
		}
		.padding(.leading, 24)
		.padding(.vertical, 3)
	}

	private var opened: Bool {
		if case .needsApproval = call.status { return false }
		return (running && !call.output.isEmpty) || expanded
	}

	private var running: Bool {
		if case .running = call.status { true } else { false }
	}

	static func duration(_ ms: Int) -> String {
		ms < 1000 ? "\(ms)ms" : ms < 60_000 ? String(format: "%.1fs", Double(ms) / 1000) : "\(ms / 60_000)m \(ms % 60_000 / 1000)s"
	}
}

/// A run of calls: each call and the thinking between them while the run goes on, then, once it's over, one box
/// ("+ ran 3 commands") that opens to its calls. The fold happens in place: the calls close up as the box opens over
/// them. Thinking after the last call stays below.
private struct ToolRoundView: View {
	let round: ToolRound

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			Disclosure(open: round.folded) { FoldedRound(round: round) }
			Disclosure(open: !round.folded) { entries(round.body) }
			entries(round.trailing)
		}
	}

	private func entries(_ entries: [ToolRound.Entry]) -> some View {
		ForEach(entries) { entry in
			switch entry {
			case .call(let call): ToolCallView(call: call)
			case .thinking(let id, let text, let redacted, let streaming): ThinkingRow(id: id, text: text, redacted: redacted, streaming: streaming)
			}
		}
	}
}

/// A finished round folded into one box: "+ ran 3 commands". Opens to its calls, each opening to its output.
private struct FoldedRound: View {
	let round: ToolRound
	@State private var expanded = false
	@State private var open: Set<String> = []

	var body: some View {
		ConsoleBox {
			Button {
				withAnimation(.row) { expanded.toggle() }
			} label: {
				HStack(spacing: 8) {
					StateMark(round.failed > 0 ? .failed : .done, size: 11)
					Text("+").foregroundStyle(Palette.ink3)
					Text(round.summary).foregroundStyle(Palette.ink2).lineLimit(1)
					if round.failed > 0 { Text("\(round.failed) failed").foregroundStyle(Palette.bad) }
					Spacer(minLength: 8)
					if round.durationMs > 0 {
						Text(ToolCallView.duration(round.durationMs)).foregroundStyle(Palette.ink3).monospacedDigit()
					}
					Text(expanded ? "▾" : "▸").foregroundStyle(Palette.ink3)
				}
				.font(Typography.code)
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
		} content: {
			Disclosure(open: expanded) {
				ForEach(round.calls, id: \.callId) { call in
					Button {
						withAnimation(.row) {
							if open.contains(call.callId) { open.remove(call.callId) } else { open.insert(call.callId) }
						}
					} label: {
						CallLine(call: call, expanded: open.contains(call.callId))
							.padding(.horizontal, 10)
							.padding(.vertical, 6)
					}
					.buttonStyle(.plain)
					.overlay(alignment: .top) { Rectangle().fill(Palette.rule).frame(height: 1) }
					Disclosure(open: open.contains(call.callId)) { CallDetail(call: call, tail: false) }
				}
			}
		}
		.padding(.leading, 24)
		.padding(.vertical, 3)
	}
}

/// Mono output text. `minLines` keeps a running tail from growing as it streams.
private struct OutputText: View {
	let text: String
	var label: String?
	var minLines: Int?

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			if let label {
				Text(label).font(Typography.label).foregroundStyle(Palette.ink3)
			}
			Text(text)
				.font(Typography.codeSmall)
				.foregroundStyle(Palette.ink2)
				.lineSpacing(2)
				.textSelection(.enabled)
				.frame(maxWidth: .infinity, minHeight: minLines.map { CGFloat($0) * Typography.codeSmallLine }, alignment: .topLeading)
		}
	}
}

// MARK: - Notices and pending sends

private struct NoticeView: View {
	let notice: TranscriptNotice
	@State private var expanded = false

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			if isBoundary {
				HStack(spacing: 10) {
					Rectangle().fill(Palette.rule2).frame(height: 1)
					Text(title).fixedSize()
					if detail != nil {
						Button(expanded ? "[hide]" : "[show]") { expanded.toggle() }
							.buttonStyle(.plain)
							.foregroundStyle(Palette.accent)
					}
					Rectangle().fill(Palette.rule2).frame(height: 1)
				}
				.font(Typography.uiSmall)
				.foregroundStyle(Palette.ink3)
			} else {
				Gutter(glyph: glyph, color: color) {
					Text(title).font(Typography.uiSmall).foregroundStyle(color).textSelection(.enabled)
				}
			}
			if expanded, let detail {
				MarkdownView(source: detail)
					.padding(.leading, 24)
			}
		}
		.padding(.vertical, 8)
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	private var isBoundary: Bool {
		switch notice {
		case .reset, .compaction: true
		default: false
		}
	}

	private var glyph: String {
		switch notice {
		case .stopped: "■"
		case .error, .taskFailed: "!"
		default: "·"
		}
	}

	private var title: String {
		switch notice {
		case .stopped: "stopped"
		case .error(let message): message
		case .lengthLimit: "the answer hit the output limit"
		case .reset(let handoff): handoff.map { "new context: \($0)" } ?? "new context"
		case .compaction: "compacted"
		case .custom(let kind): "entry \(kind)"
		case .unsupported(let type): "can't show \(type) items yet"
		case .taskFailed(let failure): "\(failure.kind) failed: \(failure.message)"
		}
	}

	private var detail: String? {
		if case .compaction(let summary) = notice { summary } else { nil }
	}

	private var color: Color {
		switch notice {
		case .error, .taskFailed: Palette.bad
		default: Palette.ink3
		}
	}
}

private extension TranscriptRow {
	var isText: Bool {
		if case .text = kind { true } else { false }
	}
}

/// Takes the space it's offered without asking its content, and gives the content all of it. After every update the
/// window works out its minimum size, and a vertical scroll view asked for its size measures its whole content at that
/// width: the transcript's every row, laid out again on each frame of a stream. It reports no alignment guides either,
/// so a stack placing it doesn't reach into the content for them.
struct FillSpace: Layout {
	func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
		CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
	}

	func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
		for subview in subviews { subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size)) }
	}

	func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
	func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
}

/// A transcript row: full width, its content in a centred column at most `measure` wide with `margin` either side.
/// Frames and padding would do the same, but placing by alignment asks the row's content for its guides, down to
/// each line of text, on every frame; this places it directly and reports no guides.
struct ReadingColumn: Layout {
	let measure: CGFloat
	let margin: CGFloat

	private func column(_ width: CGFloat) -> CGFloat {
		max(0, min(measure, width - 2 * margin))
	}

	func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
		let width = proposal.width ?? (measure + 2 * margin)
		let height = subviews.first?.sizeThatFits(ProposedViewSize(width: column(width), height: nil)).height ?? 0
		return CGSize(width: width, height: height)
	}

	func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
		let width = column(bounds.width)
		let x = bounds.minX + max(margin, (bounds.width - width) / 2)
		for subview in subviews {
			subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: nil))
		}
	}

	func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
	func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
}
