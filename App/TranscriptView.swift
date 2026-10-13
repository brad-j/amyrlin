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

/// The user's message: a right-aligned block, as in aludra.
private struct UserBlock: View {
	let text: String
	var tag: String?
	var dim = false

	var body: some View {
		HStack {
			Spacer(minLength: 80)
			VStack(alignment: .leading, spacing: 3) {
				if let tag {
					Text(tag).font(Typography.label).foregroundStyle(Palette.accent)
				}
				Text(text)
					.font(Typography.reading)
					.foregroundStyle(dim ? Palette.ink2 : Palette.ink)
					.lineSpacing(3)
					.textSelection(.enabled)
			}
			.padding(.horizontal, 13)
			.padding(.vertical, 9)
			.background(Palette.paper3, in: UnevenRoundedRectangle(topLeadingRadius: Metrics.radiusLarge, bottomLeadingRadius: Metrics.radiusLarge, bottomTrailingRadius: Metrics.radiusSmall, topTrailingRadius: Metrics.radiusLarge))
		}
		.padding(.top, 22)
		.padding(.bottom, 8)
	}
}

/// An answer: Markdown blocks, full width, with a copy button on hover once it's finished.
private struct AnswerBlock: View {
	let text: String
	let streaming: Bool
	@State private var hovering = false
	@State private var copied = false

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			MarkdownView(source: text)
			if !streaming {
				Button {
					NSPasteboard.general.clearContents()
					NSPasteboard.general.setString(text, forType: .string)
					copied = true
					Task {
						try? await Task.sleep(for: .seconds(1.5))
						copied = false
					}
				} label: {
					Image(systemName: copied ? "checkmark" : "doc.on.doc")
						.font(.system(size: 11))
						.foregroundStyle(copied ? Palette.add : Palette.ink3)
						.frame(width: 22, height: 22)
				}
				.buttonStyle(.plain)
				.opacity(hovering || copied ? 1 : 0)
				.help("Copy the answer")
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
		VStack(alignment: .leading, spacing: 6) {
			Button {
				withAnimation(.easeInOut(duration: 0.22)) { expanded.toggle() }
			} label: {
				HStack(spacing: 8) {
					if streaming { StateMark(.running, size: 11) } else {
						Image(systemName: "chevron.right")
							.font(.system(size: 9, weight: .semibold))
							.rotationEffect(.degrees(expanded ? 90 : 0))
							.frame(width: 11)
					}
					Text(streaming ? "Thinking" : "Thought")
						.font(Typography.codeSmall)
					if !expanded {
						Text(redacted ? "redacted" : preview)
							.font(Typography.readingSmall)
							.lineLimit(1)
							.truncationMode(.tail)
					}
				}
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
					.padding(.leading, 19)
			}
		}
		.padding(.vertical, 5)
	}

	private var preview: String {
		text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
	}
}

// MARK: - Tool calls

/// One call: a mono row of mark, tool, argument and duration. The argument opens its output.
private struct ToolCallView: View {
	let call: ToolCallRow
	var nested = false
	@State private var expanded = false

	private static let tailLines = 8

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			Button {
				withAnimation(.easeInOut(duration: 0.22)) { expanded.toggle() }
			} label: {
				HStack(spacing: 10) {
					StateMark(mark, size: 12)
					Text(call.name)
						.foregroundStyle(Palette.ink3)
						.frame(width: 38, alignment: .leading)
					Text(argument)
						.foregroundStyle(Palette.ink)
						.lineLimit(1)
						.truncationMode(.tail)
						.underline(pattern: .dot, color: expanded ? Palette.ink3 : Palette.rule2)
					Spacer(minLength: 8)
					Text(status)
						.foregroundStyle(statusColor)
						.monospacedDigit()
				}
				.font(Typography.code)
				.frame(minHeight: 26)
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.help(argumentFull)

			if case .needsApproval = call.status {
				EmptyView()
			} else if running && !call.output.isEmpty {
				OutputBlock(text: tail, minLines: Self.tailLines)
			} else if expanded {
				if case .object(let args) = call.args, args.count > 1 || argument != argumentFull {
					OutputBlock(text: argumentFull, label: "arguments")
				}
				if !call.output.isEmpty { OutputBlock(text: expandedOutput) }
				ForEach(Array((call.result?.diagnostics ?? []).enumerated()), id: \.offset) { _, diagnostic in
					Text(diagnostic.message)
						.font(Typography.readingSmall)
						.foregroundStyle(diagnostic.severity == "error" ? Palette.bad : Palette.ink2)
				}
			}
		}
		.padding(.vertical, nested ? 0 : 2)
	}

	private var running: Bool {
		if case .running = call.status { true } else { false }
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
	private var argument: String {
		if case .object(let object) = call.args {
			for key in ["command", "path", "file_path", "pattern", "url", "query"] {
				if let value = object[key]?.stringValue { return value.replacingOccurrences(of: "\n", with: " ⏎ ") }
			}
			if object.count == 1, let value = object.values.first?.stringValue { return value }
		}
		return call.args.jsonText
	}

	private var argumentFull: String {
		if case .object(let object) = call.args, object.count == 1, let value = object.values.first?.stringValue { return value }
		return call.args.jsonText
	}

	private var status: String {
		switch call.status {
		case .running: "running"
		case .waiting: "waiting"
		case .needsApproval: "needs you"
		case .done: call.result?.durationMs.map(Self.duration) ?? ""
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

	private var tail: String {
		let lines = call.output.trimmingCharacters(in: .newlines).split(separator: "\n", omittingEmptySubsequences: false)
		return lines.suffix(Self.tailLines).joined(separator: "\n")
	}

	private var expandedOutput: String {
		let lines = call.output.trimmingCharacters(in: .newlines).split(separator: "\n", omittingEmptySubsequences: false)
		guard lines.count > 400 else { return lines.joined(separator: "\n") }
		return "… \(lines.count - 400) earlier lines\n" + lines.suffix(400).joined(separator: "\n")
	}

	static func duration(_ ms: Int) -> String {
		ms < 1000 ? "\(ms)ms" : ms < 60_000 ? String(format: "%.1fs", Double(ms) / 1000) : "\(ms / 60_000)m \(ms % 60_000 / 1000)s"
	}
}

/// A finished round folded into one line: "ran 3 commands · read 2 files". Opens to its calls.
private struct ToolRoundView: View {
	let round: ToolRound
	@State private var expanded = false

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			Button {
				withAnimation(.easeInOut(duration: 0.22)) { expanded.toggle() }
			} label: {
				HStack(spacing: 10) {
					StateMark(round.failed > 0 ? .failed : .done, size: 12)
					Text(round.summary)
						.foregroundStyle(Palette.ink2)
						.lineLimit(1)
					if round.failed > 0 {
						Text("\(round.failed) failed").foregroundStyle(Palette.bad)
					}
					Spacer(minLength: 8)
					if round.durationMs > 0 {
						Text(ToolCallView.duration(round.durationMs)).foregroundStyle(Palette.ink3).monospacedDigit()
					}
					Image(systemName: "chevron.down")
						.font(.system(size: 9, weight: .semibold))
						.foregroundStyle(Palette.ink3)
						.rotationEffect(.degrees(expanded ? 180 : 0))
				}
				.font(Typography.code)
				.frame(minHeight: 26)
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			if expanded {
				VStack(alignment: .leading, spacing: 2) {
					ForEach(round.calls, id: \.callId) { call in
						ToolCallView(call: call, nested: true)
					}
				}
				.padding(.leading, 12)
				.overlay(alignment: .leading) { Rectangle().fill(Palette.rule).frame(width: 1) }
			}
		}
		.padding(.vertical, 2)
	}
}

/// Mono text on a darker plate. `minLines` keeps a running tail from growing as it streams.
private struct OutputBlock: View {
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
				.frame(maxWidth: .infinity, minHeight: minLines.map { CGFloat($0) * 15.5 }, alignment: .topLeading)
		}
		.padding(10)
		.background(Palette.paper2, in: RoundedRectangle(cornerRadius: Metrics.radius))
		.overlay(RoundedRectangle(cornerRadius: Metrics.radius).stroke(Palette.rule))
		.padding(.leading, 22)
	}
}

// MARK: - Notices and pending sends

private struct NoticeView: View {
	let notice: TranscriptNotice
	@State private var expanded = false

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack(alignment: .firstTextBaseline, spacing: 8) {
				Image(systemName: icon).frame(width: 12)
				Text(title)
				if detail != nil {
					Button(expanded ? "Hide" : "Show") { expanded.toggle() }
						.buttonStyle(.plain)
						.foregroundStyle(Palette.accent)
				}
			}
			.font(Typography.readingSmall)
			.foregroundStyle(color)
			if expanded, let detail {
				MarkdownView(source: detail)
					.padding(.leading, 20)
			}
		}
		.padding(.vertical, 8)
		.frame(maxWidth: .infinity, alignment: .leading)
		.overlay(alignment: .top) {
			if isBoundary { Rectangle().fill(Palette.rule).frame(height: 1) }
		}
	}

	private var isBoundary: Bool {
		switch notice {
		case .reset, .compaction: true
		default: false
		}
	}

	private var icon: String {
		switch notice {
		case .stopped: "stop.circle"
		case .error, .taskFailed: "exclamationmark.triangle"
		case .lengthLimit: "text.append"
		case .reset: "arrow.counterclockwise"
		case .compaction: "rectangle.compress.vertical"
		case .custom, .unsupported: "doc.plaintext"
		}
	}

	private var title: String {
		switch notice {
		case .stopped: "Stopped"
		case .error(let message): message
		case .lengthLimit: "The answer hit the output limit."
		case .reset(let handoff): handoff.map { "New context: \($0)" } ?? "New context"
		case .compaction: "Compacted. The model sees a summary of what came before."
		case .custom(let kind): "Entry \(kind)"
		case .unsupported(let type): "This app can't show \(type) items yet."
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
		HStack(alignment: .center, spacing: 10) {
			Spacer(minLength: 80)
			if let failure = pending.failure {
				VStack(alignment: .trailing, spacing: 4) {
					Text(failure).font(Typography.readingSmall).foregroundStyle(Palette.bad)
					HStack {
						Button("Discard") { store.discard(pending) }
						Button("Retry") { store.retry(pending) }
					}
					.controlSize(.small)
				}
			} else {
				StateMark(.running, size: 11)
			}
			Text(pending.text)
				.font(Typography.reading)
				.foregroundStyle(Palette.ink2)
				.padding(.horizontal, 13)
				.padding(.vertical, 9)
				.background(Palette.paper3.opacity(0.6), in: UnevenRoundedRectangle(topLeadingRadius: Metrics.radiusLarge, bottomLeadingRadius: Metrics.radiusLarge, bottomTrailingRadius: Metrics.radiusSmall, topTrailingRadius: Metrics.radiusLarge))
		}
		.padding(.top, 22)
		.padding(.bottom, 8)
	}
}
