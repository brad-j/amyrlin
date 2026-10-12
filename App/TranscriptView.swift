import AmyrlinCore
import SwiftUI

/// The transcript as a SwiftUI List, which is backed by a reusing NSTableView on macOS. It follows the bottom while
/// the user is there and stays put once they scroll up.
struct TranscriptView: View {
	let store: ConversationStore
	@State private var atBottom = true

	var body: some View {
		let rows = TranscriptLayout.rows(state: store.state, outbox: store.outbox)
		ScrollViewReader { proxy in
			List(rows) { row in
				TranscriptRowView(row: row, store: store)
					.listRowSeparator(.hidden)
					.listRowBackground(Color.clear)
					.listRowInsets(EdgeInsets(top: 3, leading: 16, bottom: 3, trailing: 16))
					.opacity(row.inContext ? 1 : 0.45)
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
			HStack {
				Spacer()
				ProgressView().controlSize(.small)
				Text("Loading earlier messages").font(Typography.readingSmall).foregroundStyle(Palette.tertiaryText)
				Spacer()
			}
			.padding(.vertical, 6)
			.task { await store.loadEarlier() }
		case .user(let text, _):
			Text(text)
				.font(Typography.reading)
				.textSelection(.enabled)
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(.horizontal, 12)
				.padding(.vertical, 8)
				.background(Palette.raised, in: RoundedRectangle(cornerRadius: 8))
				.padding(.top, 10)
		case .text(let text, _):
			MarkdownText(text: text)
		case .thinking(let text, let redacted, let streaming):
			ThinkingView(text: text, redacted: redacted, streaming: streaming)
		case .toolCall(let call):
			ToolCallView(call: call)
		case .notice(let notice):
			NoticeView(notice: notice)
		case .queued(let item):
			HStack(alignment: .firstTextBaseline, spacing: 8) {
				Text(item.mode == .steer ? "Steer" : "Queued")
					.font(Typography.label)
					.foregroundStyle(Palette.busy)
				Text(item.text ?? "Queued message")
					.font(Typography.reading)
					.foregroundStyle(Palette.secondaryText)
			}
			.padding(.top, 6)
		case .pending(let pending):
			PendingView(pending: pending, store: store)
		}
	}
}

/// Inline Markdown (bold, italics, code, links) with Foundation's parser; block structure stays plain text.
private struct MarkdownText: View {
	let text: String

	var body: some View {
		Text(Self.attributed(text))
			.font(Typography.reading)
			.lineSpacing(3)
			.textSelection(.enabled)
			.frame(maxWidth: .infinity, alignment: .leading)
	}

	static func attributed(_ text: String) -> AttributedString {
		let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
		return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
	}
}

private struct ThinkingView: View {
	let text: String
	let redacted: Bool
	let streaming: Bool
	@State private var expanded = false

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			Button {
				expanded.toggle()
			} label: {
				HStack(spacing: 4) {
					Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
					Text(streaming ? "Thinking…" : "Thought").font(Typography.label)
					if !expanded {
						Text(redacted ? "redacted" : text.split(separator: "\n").first.map(String.init) ?? "")
							.font(Typography.readingSmall)
							.lineLimit(1)
					}
				}
				.foregroundStyle(Palette.tertiaryText)
			}
			.buttonStyle(.plain)
			if expanded {
				Text(redacted ? "The provider redacted this thinking." : text)
					.font(Typography.readingSmall)
					.foregroundStyle(Palette.secondaryText)
					.textSelection(.enabled)
					.padding(.leading, 13)
			}
		}
	}
}

private struct ToolCallView: View {
	let call: ToolCallRow
	@State private var expanded = false

	private static let collapsedLines = 12

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			Button {
				expanded.toggle()
			} label: {
				HStack(spacing: 8) {
					statusIcon.frame(width: 14)
					Text(call.name).font(Typography.code.weight(.semibold))
					Text(argsSummary)
						.font(Typography.code)
						.foregroundStyle(Palette.secondaryText)
						.lineLimit(1)
						.truncationMode(.tail)
					Spacer(minLength: 8)
					Text(statusText).font(Typography.label).foregroundStyle(statusColor)
				}
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			if !call.output.isEmpty {
				Text(visibleOutput)
					.font(Typography.code)
					.foregroundStyle(Palette.secondaryText)
					.textSelection(.enabled)
					.frame(maxWidth: .infinity, alignment: .leading)
					.padding(8)
					.background(Palette.surface, in: RoundedRectangle(cornerRadius: 6))
			}
			if expanded, let diagnostics = call.result?.diagnostics, !diagnostics.isEmpty {
				ForEach(Array(diagnostics.enumerated()), id: \.offset) { _, diagnostic in
					Text("\(diagnostic.severity): \(diagnostic.message)")
						.font(Typography.readingSmall)
						.foregroundStyle(diagnostic.severity == "error" ? Palette.failure : Palette.secondaryText)
				}
			}
		}
		.padding(.vertical, 4)
	}

	/// The tail while collapsed or running, so long output stays one bounded row.
	private var visibleOutput: String {
		let lines = call.output.split(separator: "\n", omittingEmptySubsequences: false)
		let limit = expanded ? 400 : Self.collapsedLines
		guard lines.count > limit else { return call.output.trimmingCharacters(in: .newlines) }
		return "… \(lines.count - limit) earlier lines\n" + lines.suffix(limit).joined(separator: "\n").trimmingCharacters(in: .newlines)
	}

	private var argsSummary: String {
		if case .object(let object) = call.args, object.count == 1, let value = object.values.first?.stringValue { return value }
		return call.args.jsonText
	}

	@ViewBuilder private var statusIcon: some View {
		switch call.status {
		case .running: ProgressView().controlSize(.mini)
		case .waiting: Image(systemName: "circle.dotted").foregroundStyle(Palette.tertiaryText)
		case .needsApproval: Image(systemName: "hand.raised.fill").foregroundStyle(Palette.approval)
		case .done: Image(systemName: "checkmark").foregroundStyle(Palette.success)
		case .failed: Image(systemName: "xmark").foregroundStyle(Palette.failure)
		case .ended, .noResult: Image(systemName: "exclamationmark").foregroundStyle(Palette.tertiaryText)
		}
	}

	private var statusText: String {
		switch call.status {
		case .running: "running"
		case .waiting: "waiting"
		case .needsApproval: "needs approval"
		case .done: call.result?.durationMs.map { "\($0) ms" } ?? "done"
		case .failed(let code): code ?? "error"
		case .ended: "ended without a result"
		case .noResult: "no result"
		}
	}

	private var statusColor: Color {
		switch call.status {
		case .failed: Palette.failure
		case .needsApproval: Palette.approval
		case .running: Palette.busy
		default: Palette.tertiaryText
		}
	}
}

private struct NoticeView: View {
	let notice: TranscriptNotice

	var body: some View {
		HStack(alignment: .firstTextBaseline, spacing: 6) {
			Image(systemName: icon)
			Text(text).textSelection(.enabled)
		}
		.font(Typography.readingSmall)
		.foregroundStyle(color)
		.padding(.vertical, 4)
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

	private var text: String {
		switch notice {
		case .stopped: "Stopped"
		case .error(let message): message
		case .lengthLimit: "The answer hit the output limit."
		case .reset(let handoff): handoff.map { "New context. Handoff: \($0)" } ?? "New context"
		case .compaction(let summary): "Compacted. The model now sees a summary of what came before.\n\(summary)"
		case .custom(let kind): "Entry \(kind)"
		case .unsupported(let type): "This app cannot show \(type) items yet."
		case .taskFailed(let failure): "\(failure.kind) failed: \(failure.message)"
		}
	}

	private var color: Color {
		switch notice {
		case .error, .taskFailed: Palette.failure
		default: Palette.tertiaryText
		}
	}
}

private struct PendingView: View {
	let pending: PendingSend
	let store: ConversationStore

	var body: some View {
		HStack(alignment: .firstTextBaseline, spacing: 8) {
			Text(pending.text)
				.font(Typography.reading)
				.foregroundStyle(Palette.secondaryText)
				.frame(maxWidth: .infinity, alignment: .leading)
			if let failure = pending.failure {
				Text(failure).font(Typography.label).foregroundStyle(Palette.failure)
				Button("Retry") { store.retry(pending) }
				Button("Discard") { store.discard(pending) }
			} else {
				ProgressView().controlSize(.mini)
			}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 8)
		.background(Palette.raised.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
		.padding(.top, 10)
	}
}
