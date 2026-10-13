import AmyrlinCore
import AppKit
import SwiftUI

/// The transcript as a SwiftUI List, which is backed by a reusing NSTableView on macOS. It follows the bottom while
/// the user is there and stays put once they scroll up. Content sits in a centred reading column.
struct TranscriptView: View {
	let store: ConversationStore
	@State private var atBottom = true

	var body: some View {
		let rows = TranscriptLayout.rows(state: store.state, outbox: store.outbox)
		ScrollViewReader { proxy in
			List(rows) { row in
				TranscriptRowView(row: row, store: store)
					.frame(maxWidth: Metrics.measure, alignment: .leading)
					.frame(maxWidth: .infinity)
					.opacity(row.inContext ? 1 : 0.45)
					.listRowSeparator(.hidden)
					.listRowBackground(Color.clear)
					.listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 24))
			}
			.listStyle(.plain)
			.scrollContentBackground(.hidden)
			.environment(\.defaultMinListRowHeight, 1)
			.onScrollGeometryChange(for: Bool.self) { geometry in
				geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 48
			} action: { _, isAtBottom in
				atBottom = isAtBottom
			}
			.onChange(of: Follow(rows: rows)) { _, follow in
				guard atBottom, let last = follow.lastID else { return }
				proxy.scrollTo(last, anchor: .bottom)
			}
			.onChange(of: store.state.hasSnapshot) { _, has in
				if has, let last = rows.last?.id { proxy.scrollTo(last, anchor: .bottom) }
			}
			.onAppear {
				if let last = rows.last?.id { proxy.scrollTo(last, anchor: .bottom) }
			}
			.overlay(alignment: .bottom) {
				if !atBottom, let last = rows.last?.id {
					Button {
						proxy.scrollTo(last, anchor: .bottom)
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
				}
			}
		}
	}

	/// What changes when the bottom of the transcript grows: a new last row, or more text or output in it.
	private struct Follow: Equatable {
		let lastID: String?
		let lastSize: Int

		init(rows: [TranscriptRow]) {
			lastID = rows.last?.id
			lastSize = switch rows.last?.kind {
			case .text(let text, _), .thinking(let text, _, _): text.utf8.count
			case .toolCall(let call): call.output.utf8.count
			default: 0
			}
		}
	}
}

struct TranscriptRowView: View {
	let row: TranscriptRow
	let store: ConversationStore

	var body: some View {
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
		case .user(let text, _):
			UserBlock(text: text)
		case .text(let text, let streaming):
			AnswerBlock(text: text, streaming: streaming)
		case .thinking(let text, let redacted, let streaming):
			ThinkingRow(text: text, redacted: redacted, streaming: streaming)
		case .toolCall(let call):
			ToolCallView(call: call)
		case .toolRound(let round):
			ToolRoundView(round: round)
		case .notice(let notice):
			NoticeView(notice: notice)
		case .queued(let item):
			UserBlock(text: item.text ?? "Queued message", tag: item.mode == .steer ? "steer" : "queued", dim: true)
		case .pending(let pending):
			PendingView(pending: pending, store: store)
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

/// The user's message: a framed block with a `❯` prompt and a violet edge.
private struct UserBlock: View {
	let text: String
	var tag: String?
	var dim = false

	var body: some View {
		Gutter(glyph: "❯", color: dim ? Palette.ink3 : Palette.accent) {
			VStack(alignment: .leading, spacing: 4) {
				if let tag {
					Text(tag).font(Typography.label).foregroundStyle(Palette.accent)
				}
				Text(text)
					.font(Typography.reading)
					.foregroundStyle(dim ? Palette.ink2 : Palette.ink)
					.lineSpacing(3)
					.textSelection(.enabled)
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

/// An answer: Markdown in IBM Plex Sans after a `●` mark, with `[copy]` on hover once it's finished.
private struct AnswerBlock: View {
	let text: String
	let streaming: Bool
	@State private var hovering = false
	@State private var copied = false

	var body: some View {
		Gutter(glyph: "●", color: streaming ? Palette.accent : Palette.ink3) {
			VStack(alignment: .leading, spacing: 4) {
				MarkdownView(source: text)
				if !streaming {
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

private struct ThinkingRow: View {
	let text: String
	let redacted: Bool
	let streaming: Bool
	@State private var expanded = false

	var body: some View {
		Gutter(glyph: "∴") {
			VStack(alignment: .leading, spacing: 6) {
				Button {
					withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
				} label: {
					HStack(spacing: 8) {
						Text(streaming ? "thinking" : "thought")
						if streaming { StateMark(.running, size: 9) }
						if !expanded {
							Text(redacted ? "redacted" : preview)
								.lineLimit(1)
								.truncationMode(.tail)
						}
					}
					.font(Typography.uiSmall)
					.foregroundStyle(Palette.ink3)
					.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
				if expanded {
					Text(redacted ? "The provider redacted this thinking." : text)
						.font(Typography.readingSmall)
						.foregroundStyle(Palette.ink2)
						.lineSpacing(3)
						.textSelection(.enabled)
				}
			}
		}
		.padding(.vertical, 4)
	}

	private var preview: String {
		text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
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
		.overlay(Rectangle().stroke(Palette.rule))
	}
}

/// One call's line: mark, `$ command` (or the tool and its path), and its status at the right.
private struct CallLine: View {
	let call: ToolCallRow
	let expanded: Bool

	var body: some View {
		HStack(spacing: 8) {
			StateMark(mark, size: 11)
			Text(call.name == "bash" ? "$" : call.name)
				.foregroundStyle(Palette.ink3)
			Text(argument)
				.foregroundStyle(Palette.ink)
				.lineLimit(1)
				.truncationMode(.tail)
			Spacer(minLength: 8)
			Text(status)
				.foregroundStyle(statusColor)
				.monospacedDigit()
			Text(expanded ? "▾" : "▸").foregroundStyle(Palette.ink3)
		}
		.font(Typography.code)
		.contentShape(Rectangle())
		.help(argumentFull)
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

	/// The one argument worth showing: a command, a path, or the arguments as JSON.
	var argument: String {
		if case .object(let object) = call.args {
			for key in ["command", "path", "file_path", "pattern", "url", "query"] {
				if let value = object[key]?.stringValue { return value.replacingOccurrences(of: "\n", with: " ⏎ ") }
			}
			if object.count == 1, let value = object.values.first?.stringValue { return value }
		}
		return call.args.jsonText
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

	private static let tailLines = 8

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			if !tail, case .object(let args) = call.args, args.count > 1 {
				OutputText(text: call.args.jsonText, label: "arguments")
			}
			if !call.output.isEmpty {
				OutputText(text: tail ? tailText : fullText, minLines: tail ? Self.tailLines : nil)
			}
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
				withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
			} label: {
				CallLine(call: call, expanded: expanded || running)
			}
			.buttonStyle(.plain)
		} content: {
			if case .needsApproval = call.status {
				EmptyView()
			} else if running && !call.output.isEmpty {
				CallDetail(call: call, tail: true)
			} else if expanded {
				CallDetail(call: call, tail: false)
			}
		}
		.padding(.leading, 24)
		.padding(.vertical, 3)
	}

	private var running: Bool {
		if case .running = call.status { true } else { false }
	}

	static func duration(_ ms: Int) -> String {
		ms < 1000 ? "\(ms)ms" : ms < 60_000 ? String(format: "%.1fs", Double(ms) / 1000) : "\(ms / 60_000)m \(ms % 60_000 / 1000)s"
	}
}

/// A finished round folded into one box: "+ ran 3 commands". Opens to its calls, each opening to its output.
private struct ToolRoundView: View {
	let round: ToolRound
	@State private var expanded = false
	@State private var open: Set<String> = []

	var body: some View {
		ConsoleBox {
			Button {
				withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
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
			if expanded {
				VStack(alignment: .leading, spacing: 0) {
					ForEach(round.calls, id: \.callId) { call in
						Button {
							if open.contains(call.callId) { open.remove(call.callId) } else { open.insert(call.callId) }
						} label: {
							CallLine(call: call, expanded: open.contains(call.callId))
								.padding(.horizontal, 10)
								.padding(.vertical, 6)
						}
						.buttonStyle(.plain)
						.overlay(alignment: .top) { Rectangle().fill(Palette.rule).frame(height: 1) }
						if open.contains(call.callId) { CallDetail(call: call, tail: false) }
					}
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

private struct PendingView: View {
	let pending: PendingSend
	let store: ConversationStore

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			UserBlock(text: pending.text, tag: pending.failure == nil ? "sending" : nil, dim: true)
			if let failure = pending.failure {
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
}
