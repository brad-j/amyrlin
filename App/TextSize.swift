import Observation
import SwiftUI

/// The two text sizes, as zooms of the design's sizes, kept across launches: the transcript's (reading text, headings
/// and code) and the chrome's (sidebar, headers, inspector, composer, status line). ⌘+ and ⌘− step the transcript's;
/// Settings sets either.
@MainActor @Observable
final class TextSize {
	static let shared = TextSize()

	/// What 100% is: the design's sizes are drawn at 1.15 times their points.
	static let base: CGFloat = 1.15
	/// The zooms offered, in steps that read as distinct sizes.
	static let steps: [CGFloat] = [0.8, 0.9, 1, 1.1, 1.2, 1.35, 1.5, 1.7, 2]

	var textZoom: CGFloat {
		didSet { UserDefaults.standard.set(Double(textZoom), forKey: "textZoom") }
	}
	var interfaceZoom: CGFloat {
		didSet { UserDefaults.standard.set(Double(interfaceZoom), forKey: "interfaceZoom") }
	}

	private init() {
		textZoom = Self.nearest(UserDefaults.standard.object(forKey: "textZoom") as? Double ?? 1)
		interfaceZoom = Self.nearest(UserDefaults.standard.object(forKey: "interfaceZoom") as? Double ?? 1)
	}

	/// The step `by` away from `zoom`, held at the ends.
	static func step(_ zoom: CGFloat, by offset: Int) -> CGFloat {
		let index = steps.firstIndex(of: nearest(zoom)) ?? 2
		return steps[min(max(index + offset, 0), steps.count - 1)]
	}

	static func nearest(_ zoom: Double) -> CGFloat {
		steps.min { abs($0 - zoom) < abs($1 - zoom) } ?? 1
	}

	static func percent(_ zoom: CGFloat) -> String {
		"\(Int((zoom * 100).rounded()))%"
	}
}

/// The View menu's text size commands, as in Messages: they size the transcript; Settings sizes the chrome too.
struct TextSizeCommands: Commands {
	let size: TextSize

	var body: some Commands {
		CommandGroup(after: .toolbar) {
			Divider()
			Button("Bigger Text") { size.textZoom = TextSize.step(size.textZoom, by: 1) }
				.keyboardShortcut("+", modifiers: .command)
				.disabled(size.textZoom == TextSize.steps.last)
			Button("Smaller Text") { size.textZoom = TextSize.step(size.textZoom, by: -1) }
				.keyboardShortcut("-", modifiers: .command)
				.disabled(size.textZoom == TextSize.steps.first)
			Button("Actual Size") { size.textZoom = 1 }
				.keyboardShortcut("0", modifiers: .command)
				.disabled(size.textZoom == 1)
			Divider()
		}
	}
}

/// Settings (⌘,): the transcript's and the chrome's text sizes, each stepped and shown as a percentage.
struct SettingsView: View {
	@Bindable var size: TextSize

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			HeaderBar {
				Text("text size").font(Typography.label).foregroundStyle(Palette.ink3).textCase(.uppercase)
			}
			VStack(alignment: .leading, spacing: 14) {
				row("transcript", detail: "messages, code and tool output · ⌘+ ⌘− ⌘0", zoom: $size.textZoom)
				row("interface", detail: "sidebar, headers, inspector, composer", zoom: $size.interfaceZoom)
				Text("The quick brown fox jumps over the lazy dog.")
					.font(Typography.reading)
					.foregroundStyle(Palette.ink)
					.padding(.top, 6)
			}
			.padding(16)
		}
		.frame(width: 520 * Typography.scale)
		.background(Palette.paper)
		.preferredColorScheme(.dark)
	}

	private func row(_ title: String, detail: String, zoom: Binding<CGFloat>) -> some View {
		HStack(spacing: 10) {
			VStack(alignment: .leading, spacing: 3) {
				Text(title).font(Typography.ui).foregroundStyle(Palette.ink)
				Text(detail).font(Typography.uiSmall).foregroundStyle(Palette.ink3)
			}
			Spacer(minLength: 12)
			BracketButton("−") { zoom.wrappedValue = TextSize.step(zoom.wrappedValue, by: -1) }
				.disabled(zoom.wrappedValue == TextSize.steps.first)
			Text(TextSize.percent(zoom.wrappedValue))
				.font(Typography.ui)
				.foregroundStyle(zoom.wrappedValue == 1 ? Palette.ink2 : Palette.accent)
				.monospacedDigit()
				.frame(minWidth: 44 * Typography.scale)
			BracketButton("+") { zoom.wrappedValue = TextSize.step(zoom.wrappedValue, by: 1) }
				.disabled(zoom.wrappedValue == TextSize.steps.last)
			BracketButton("reset") { zoom.wrappedValue = 1 }
				.disabled(zoom.wrappedValue == 1)
		}
	}
}
