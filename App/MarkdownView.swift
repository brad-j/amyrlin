import AmyrlinCore
import AppKit
import SwiftUI

/// Renders Markdown blocks from AmyrlinCore's parser; inline formatting through Foundation's inline parser.
/// `revealing` is for text cut off mid-stream: it's settled first (`Markdown.settled`), and the end of its last block
/// fades in.
struct MarkdownView: View {
	let source: String
	var revealing = false

	var body: some View {
		let blocks = Markdown.blocks(revealing ? Markdown.settled(source) : source)
		VStack(alignment: .leading, spacing: 10) {
			ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
				// Equatable, so finished blocks above the one being written aren't laid out again each frame.
				BlockView(block: block, tail: revealing && index == blocks.count - 1).equatable()
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}
}

private struct BlockView: View, Equatable {
	let block: MarkdownBlock
	/// The block's end is still being revealed.
	var tail = false

	var body: some View {
		switch block {
		case .paragraph(let text):
			Inline(text, tail: tail)
		case .heading(let level, let text):
			Text(Inline.attributed(text, strong: Typography.heading(level)))
				.font(Typography.heading(level))
				.foregroundStyle(Palette.ink)
				.tailFade(tail)
				.padding(.top, level <= 2 ? 6 : 2)
				.textSelection(.enabled)
		case .list(let items):
			VStack(alignment: .leading, spacing: 5) {
				ForEach(Array(items.enumerated()), id: \.offset) { index, item in
					HStack(alignment: .firstTextBaseline, spacing: 8) {
						marker(item)
							.frame(minWidth: 14, alignment: .trailing)
						Inline(item.text, tail: tail && index == items.count - 1)
					}
					.padding(.leading, CGFloat(item.depth) * 18)
				}
			}
		case .code(let language, let code, _):
			CodeBlock(language: language, code: code, tail: tail)
		case .quote(let text):
			HStack(alignment: .top, spacing: 12) {
				Rectangle().fill(Palette.rule2).frame(width: 2)
				Inline(text, color: Palette.ink2, tail: tail)
			}
			.fixedSize(horizontal: false, vertical: true)
		case .table(let header, let rows):
			TableBlock(header: header, rows: rows)
		case .rule:
			Rectangle().fill(Palette.rule).frame(height: 1).padding(.vertical, 4)
		}
	}

	@ViewBuilder private func marker(_ item: MarkdownBlock.ListItem) -> some View {
		if let checked = item.checked {
			Image(systemName: checked ? "checkmark.square" : "square")
				.font(.system(size: 11))
				.foregroundStyle(checked ? Palette.add : Palette.ink3)
		} else if let number = item.number {
			Text("\(number).").font(Typography.codeSmall).foregroundStyle(Palette.ink3).monospacedDigit()
		} else {
			Text(item.depth == 0 ? "•" : "◦").font(Typography.reading).foregroundStyle(Palette.ink3)
		}
	}
}

/// A paragraph's inline Markdown: bold, italics, links, and `code` in mono.
private struct Inline: View {
	let text: String
	var color: Color = Palette.ink
	var tail = false

	init(_ text: String, color: Color = Palette.ink, tail: Bool = false) {
		self.text = text
		self.color = color
		self.tail = tail
	}

	var body: some View {
		Text(Self.attributed(text))
			.font(Typography.reading)
			.foregroundStyle(color)
			.tailFade(tail)
			.lineSpacing(4)
			.textSelection(.enabled)
			.fixedSize(horizontal: false, vertical: true)
			.tint(Palette.accent)
	}

	/// `strong` is the font for **bold**; left to SwiftUI it would be Plex Bold, three steps above light text.
	static func attributed(_ text: String, strong: Font = Typography.readingStrong) -> AttributedString {
		let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
		var attributed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
		for run in attributed.runs where run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
			attributed[run.range].font = strong
		}
		for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
			attributed[run.range].font = Typography.inlineCode
			attributed[run.range].foregroundColor = Palette.ink
			attributed[run.range].backgroundColor = Palette.paper3
		}
		return attributed
	}
}

private struct CodeBlock: View {
	let language: String?
	let code: String
	var tail = false
	@State private var copied = false

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			HStack {
				Text(language ?? "code").font(Typography.label).foregroundStyle(Palette.ink3)
				Spacer()
				Button {
					NSPasteboard.general.clearContents()
					NSPasteboard.general.setString(code, forType: .string)
					copied = true
					Task {
						try? await Task.sleep(for: .seconds(1.5))
						copied = false
					}
				} label: {
					Image(systemName: copied ? "checkmark" : "doc.on.doc")
						.font(.system(size: 10.5))
						.foregroundStyle(copied ? Palette.add : Palette.ink3)
				}
				.buttonStyle(.plain)
				.help("Copy")
			}
			.padding(.horizontal, 12)
			.padding(.vertical, 6)
			Rectangle().fill(Palette.rule).frame(height: 1)
			ScrollView(.horizontal, showsIndicators: false) {
				Text(code)
					.font(Typography.code)
					.foregroundStyle(Palette.ink)
					.tailFade(tail)
					.lineSpacing(3)
					.textSelection(.enabled)
					.fixedSize()
					.padding(12)
			}
		}
		.background(Palette.paper2, in: RoundedRectangle(cornerRadius: Metrics.radius))
		.overlay(RoundedRectangle(cornerRadius: Metrics.radius).stroke(Palette.rule))
	}
}

private struct TableBlock: View {
	let header: [String]
	let rows: [[String]]

	var body: some View {
		Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
			GridRow {
				ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
					Text(Inline.attributed(cell, strong: Typography.readingSmallStrong)).font(Typography.readingSmallStrong).foregroundStyle(Palette.ink2)
				}
			}
			Rectangle().fill(Palette.rule).frame(height: 1).gridCellUnsizedAxes(.horizontal)
			ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
				GridRow {
					ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
						Text(Inline.attributed(cell, strong: Typography.readingSmallStrong)).font(Typography.readingSmall).foregroundStyle(Palette.ink)
					}
				}
			}
		}
		.textSelection(.enabled)
		.padding(12)
		.background(Palette.paper2, in: RoundedRectangle(cornerRadius: Metrics.radius))
		.overlay(RoundedRectangle(cornerRadius: Metrics.radius).stroke(Palette.rule))
	}
}
