import AmyrlinCore
import AppKit
import SwiftUI

/// Renders Markdown blocks from AmyrlinCore's parser; inline formatting through Foundation's inline parser.
struct MarkdownView: View {
	let source: String

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			ForEach(Array(Markdown.blocks(source).enumerated()), id: \.offset) { _, block in
				BlockView(block: block)
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}
}

private struct BlockView: View {
	let block: MarkdownBlock

	var body: some View {
		switch block {
		case .paragraph(let text):
			Inline(text)
		case .heading(let level, let text):
			Text(Inline.attributed(text))
				.font(Typography.heading(level))
				.foregroundStyle(Palette.ink)
				.padding(.top, level <= 2 ? 6 : 2)
				.textSelection(.enabled)
		case .list(let items):
			VStack(alignment: .leading, spacing: 5) {
				ForEach(Array(items.enumerated()), id: \.offset) { _, item in
					HStack(alignment: .firstTextBaseline, spacing: 8) {
						marker(item)
							.frame(minWidth: 14, alignment: .trailing)
						Inline(item.text)
					}
					.padding(.leading, CGFloat(item.depth) * 18)
				}
			}
		case .code(let language, let code, _):
			CodeBlock(language: language, code: code)
		case .quote(let text):
			HStack(alignment: .top, spacing: 12) {
				Rectangle().fill(Palette.rule2).frame(width: 2)
				Inline(text, color: Palette.ink2)
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

	init(_ text: String, color: Color = Palette.ink) {
		self.text = text
		self.color = color
	}

	var body: some View {
		Text(Self.attributed(text))
			.font(Typography.reading)
			.foregroundStyle(color)
			.lineSpacing(4)
			.textSelection(.enabled)
			.fixedSize(horizontal: false, vertical: true)
			.tint(Palette.accent)
	}

	static func attributed(_ text: String) -> AttributedString {
		let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
		var attributed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
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
					Text(Inline.attributed(cell)).font(Typography.readingSmall.weight(.semibold)).foregroundStyle(Palette.ink2)
				}
			}
			Rectangle().fill(Palette.rule).frame(height: 1).gridCellUnsizedAxes(.horizontal)
			ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
				GridRow {
					ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
						Text(Inline.attributed(cell)).font(Typography.readingSmall).foregroundStyle(Palette.ink)
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
