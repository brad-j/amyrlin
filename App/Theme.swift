import AmyrlinCore
import SwiftUI

/* Hallmark · redesign · genre: atmospheric (technical) · macrostructure: transcript-first app, console chrome
 * theme: custom · vibe: "console chrome around a readable transcript" · paper: oklch(16.5% 0.003 260)
 * accent: oklch(80% 0.13 300) violet, plus one colour per project · reading: IBM Plex Sans (the transcript only)
 * mono: IBM Plex Mono (bundled) for all chrome · shape: square, 1 px rules · nav: tree sidebar · footer: status line
 * pre-emit critique: P5 H4 E4 S5 R4 V4 · aludra/app/styles/app.css carries the same system
 */
// Colours from aludra's tokens (aludra/design/tokens.css), converted from OKLCH to sRGB, so the Mac and the phone read
// as one product. Colour lives in state marks, the accent and project colours; everything else is near-black neutrals.

/// Every typeface the app uses, both bundled in App/Fonts under the SIL OFL. The transcript reads in IBM Plex Sans;
/// every other surface, from the sidebar to the status line, is IBM Plex Mono, its monospaced sibling.
/// Sizes come in two sets that the Text Size settings scale apart: the transcript's (reading, headings and code, scaled
/// by `textScale`) and the chrome's (`ui` and the rest, scaled by `scale`). Both read TextSize, so a view redraws when
/// either changes. Text is light and emphasis is regular; light text on the dark paper reads as heavy as regular does
/// on white.
@MainActor enum Typography {
	/// The chrome's scale: 1.15 at 100%.
	static var scale: CGFloat { TextSize.base * TextSize.shared.interfaceZoom }
	/// The transcript's scale: 1.15 at 100%.
	static var textScale: CGFloat { TextSize.base * TextSize.shared.textZoom }
	/// Both families ship one file per weight; `.weight(_:)` picks among the bundled ones, light to bold.
	private static func sans(_ size: CGFloat, _ weight: Font.Weight = .light, scale: CGFloat = textScale) -> Font {
		.custom("IBM Plex Sans", size: size * scale).weight(weight)
	}
	private static func mono(_ size: CGFloat, _ weight: Font.Weight = .light, scale: CGFloat = scale) -> Font {
		.custom("IBM Plex Mono", size: size * scale).weight(weight)
	}

	static var reading: Font { sans(15) }
	static var readingSmall: Font { sans(13) }
	static var readingStrong: Font { sans(15, .medium) }
	static var readingSmallStrong: Font { sans(13, .medium) }
	static func heading(_ level: Int) -> Font {
		sans([20, 17.5, 16, 15][min(max(level, 1), 4) - 1], .regular)
	}
	/// The transcript's code: blocks, tool calls and their output.
	static var code: Font { mono(12.5, scale: textScale) }
	static var codeSmall: Font { mono(11.5, scale: textScale) }
	static var inlineCode: Font { mono(13, scale: textScale) }
	/// Chrome: sidebar rows, the inspector, the picker, the composer, the header.
	static var ui: Font { mono(12.5) }
	static var uiSmall: Font { mono(11.5) }
	static var uiStrong: Font { mono(12.5, .regular) }
	static var label: Font { mono(10.5, .regular) }
	static var projectHeader: Font { mono(12.5, .regular) }
	/// A machine's name is a row's size; the computer icon and full ink set it apart.
	static var machineHeader: Font { mono(12.5, .regular) }
	/// Chrome in the reading face, scaled with the chrome, for the shortcuts sheet: a reference read down a list, and
	/// the keys' symbols sit better beside it than beside mono.
	static var uiSans: Font { sans(13, scale: scale) }
	static var uiSansSmall: Font { sans(11.5, scale: scale) }
	static var uiSansStrong: Font { sans(13, .medium, scale: scale) }
	/// A key's symbol on its cap: the system face, which draws ⌘ ⌥ ⇧ ⌃ as menus do.
	static var keyCap: Font { .system(size: 10.5 * scale, weight: .regular) }
	/// The space between lines of `reading` text: Plex Sans sets lines 1.3 em apart, and the transcript's are 10% more
	/// than that plus 4 points.
	static var readingLineSpacing: CGFloat {
		let natural = 1.3 * 15 * textScale
		return (natural + 4) * 1.1 - natural
	}
	/// Line height of `codeSmall`, for blocks that keep a fixed number of lines.
	static var codeSmallLine: CGFloat { 15.5 * textScale }
}

enum Palette {
	static let paper = Color(red: 0.053, green: 0.056, blue: 0.061)
	/// The side panels (sidebar and inspector), a step darker than the transcript: #0a0a0a.
	static let panel = Color(red: 10 / 255, green: 10 / 255, blue: 10 / 255)
	static let paper2 = Color(red: 0.091, green: 0.095, blue: 0.103)
	static let paper3 = Color(red: 0.131, green: 0.137, blue: 0.146)
	static let rule = Color(red: 0.146, green: 0.151, blue: 0.158)
	static let rule2 = Color(red: 0.233, green: 0.240, blue: 0.250)
	static let ink = Color(red: 0.904, green: 0.909, blue: 0.917)
	static let ink2 = Color(red: 0.724, green: 0.732, blue: 0.744)
	static let ink3 = Color(red: 0.541, green: 0.550, blue: 0.564)
	/// Violet at aludra's accent lightness: oklch(80% 0.13 300).
	static let accent = Color(red: 0.795, green: 0.666, blue: 1.0)
	static let accentInk = Color(red: 0.070, green: 0.045, blue: 0.111)
	/// The selected row: paper with a trace of the accent, oklch(25% 0.035 300).
	static let selection = Color(red: 0.142, green: 0.117, blue: 0.188)
	static let wait = Color(red: 0.960, green: 0.760, blue: 0.371)
	static let waitInk = Color(red: 0.121, green: 0.078, blue: 0.002)
	static let bad = Color(red: 0.957, green: 0.479, blue: 0.476)
	static let add = Color(red: 0.478, green: 0.834, blue: 0.610)

	// Names the views used before the redesign.
	static let background = paper
	static let surface = paper2
	static let raised = paper3
	static let hairline = rule
	static let secondaryText = ink2
	static let tertiaryText = ink3
	static let failure = bad
	static let success = add

	/// Each project's own colour (AmyrlinCore's ProjectColor), the same everywhere it appears: the one picked on its
	/// host (`colors`, the host's `projectColors`), else its name's.
	static func project(_ name: String, in colors: [String: Int]) -> Color {
		let c = ProjectColor.rgb(for: name, overrides: colors)
		return Color(red: c.red, green: c.green, blue: c.blue)
	}

	/// The selected row's wash in a project's hue: dark paper with a trace of it.
	static func projectWash(_ name: String, in colors: [String: Int]) -> Color {
		let c = ProjectColor.oklchToSRGB(lightness: 0.25, chroma: 0.035, hue: ProjectColor.hues[ProjectColor.index(for: name, overrides: colors)])
		return Color(red: c.red, green: c.green, blue: c.blue)
	}

	/// Hue `index` as a small filled circle for menus, which draw SF Symbols in one ink.
	static func swatch(_ index: Int) -> NSImage {
		let c = ProjectColor.oklchToSRGB(lightness: ProjectColor.lightness, chroma: ProjectColor.chroma, hue: ProjectColor.hues[index])
		let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
			NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1).setFill()
			NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
			return true
		}
		image.isTemplate = false
		return image
	}

	static func color(for status: ConversationStatus) -> Color {
		switch status {
		case .busy: accent
		case .needsApproval: wait
		case .stuck: bad
		case .idle, .unknown: ink3
		}
	}

	static func color(for status: HostConnection.Status) -> Color {
		switch status {
		case .connected: add
		case .connecting, .waiting: wait
		case .failed: bad
		case .idle, .stopped: ink3
		}
	}
}

@MainActor enum Metrics {
	/// The reading column: about 70 characters of reading text.
	static var measure: CGFloat { 720 * Typography.textScale }
	/// Every corner radius scales by this. Square since the console redesign (2026-10-12); 0.65 before.
	static let rounding: CGFloat = 0
	static let radiusSmall: CGFloat = 5 * rounding
	/// Rows in the sidebar and the picker.
	static let radiusRow: CGFloat = 6 * rounding
	static let radius: CGFloat = 8 * rounding
	static let radiusLarge: CGFloat = 14 * rounding
	/// The header band every column starts with, under the title bar: one height, so their rules make one line. It
	/// grows and shrinks with the chrome's text.
	static var bar: CGFloat { (36 * TextSize.shared.interfaceZoom).rounded() }
	/// The status line across the foot of the window.
	static var statusBar: CGFloat { (28 * TextSize.shared.interfaceZoom).rounded() }
}

extension Animation {
	/// How the sidebar and the inspector open and close, and the toggles at the middle column's edges with them.
	static let panel = Animation.smooth(duration: 0.32)
}

extension EnvironmentValues {
	/// Whether the sidebar shows; set on the middle column, whose foot holds the button that toggles it.
	@Entry var sidebarShown: Binding<Bool>?
	/// Whether the inspector shows; set on the rightmost pane, whose header holds the button that toggles it.
	@Entry var inspectorShown: Binding<Bool>?
	/// Where this pane is in the middle column, from the left.
	@Entry var paneIndex = 0
	/// Whether this pane has focus. Its composer takes the keyboard when it gains it.
	@Entry var paneFocused = true
}

/// The sidebar's toggle, at the foot of the middle column left of the composer, where it stays whether the sidebar
/// shows or not.
struct SidebarToggle: View {
	@Environment(\.sidebarShown) private var shown

	var body: some View {
		if let shown {
			IconButton("sidebar.left") { withAnimation(.panel) { shown.wrappedValue.toggle() } }
				.help(shown.wrappedValue ? "Hide the sidebar (⌃⌘S)" : "Show the sidebar (⌃⌘S)")
		}
	}
}

/// The inspector's toggle, at the right of the rightmost pane's header, so it rides along as the inspector opens and
/// closes.
struct InspectorToggle: View {
	@Environment(\.inspectorShown) private var shown

	var body: some View {
		if let shown {
			IconButton("sidebar.right") { withAnimation(.panel) { shown.wrappedValue.toggle() } }
				.help(shown.wrappedValue ? "Hide the inspector (⌥⌘I)" : "Show the inspector (⌥⌘I)")
		}
	}
}

/// A pane's close icon, in its header while the middle column is split.
struct PaneCloseButton: View {
	@Environment(AppModel.self) private var model: AppModel?
	@Environment(\.paneIndex) private var index

	var body: some View {
		if let model, model.panes.count > 1 {
			IconButton("xmark") { withAnimation(.panel) { model.closePane(index) } }
				.help("Close this pane (⇧⌘W)")
		}
	}
}

/// A column's header band (`Metrics.bar` tall, a rule under it). The sidebar, the conversation and the inspector each
/// start with one, so the window reads as one grid.
struct HeaderBar<Content: View>: View {
	@ViewBuilder let content: Content

	init(@ViewBuilder content: () -> Content = { EmptyView() }) {
		self.content = content()
	}

	var body: some View {
		HStack(spacing: 0) { content }
			.font(Typography.ui)
			.lineLimit(1)
			.padding(.horizontal, 16)
			.frame(maxWidth: .infinity, minHeight: Metrics.bar, maxHeight: Metrics.bar, alignment: .leading)
			.overlay(alignment: .bottom) { Rectangle().fill(Palette.rule).frame(height: 1) }
	}
}

/// A quiet bracketed command for header bands and the status line: `[−]`, `[reset]`.
struct BracketButton: View {
	let title: String
	var color: Color = Palette.ink3
	let action: () -> Void
	@State private var hovering = false

	init(_ title: String, color: Color = Palette.ink3, action: @escaping () -> Void) {
		self.title = title
		self.color = color
		self.action = action
	}

	var body: some View {
		Button(action: action) {
			Text("[\(title)]")
				.font(Typography.uiSmall)
				.foregroundStyle(hovering ? Palette.ink : color)
				.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.onHover { hovering = $0 }
	}
}

/// A quiet icon command for header bands, in BracketButton's colours: an SF Symbol where the bracket would be text.
/// Pair it with `.help` so the command still has words.
struct IconButton: View {
	let systemName: String
	var color: Color = Palette.ink3
	let action: () -> Void
	@State private var hovering = false

	init(_ systemName: String, color: Color = Palette.ink3, action: @escaping () -> Void) {
		self.systemName = systemName
		self.color = color
		self.action = action
	}

	var body: some View {
		Button(action: action) {
			Image(systemName: systemName)
				.font(.system(size: 13 * Typography.scale, weight: .light))
				.foregroundStyle(hovering ? Palette.ink : color)
				.frame(minWidth: 18 * Typography.scale, minHeight: 18 * Typography.scale)
				.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.onHover { hovering = $0 }
	}
}

/// A state mark: shape and colour together, as in aludra (spinner, amber diamond, red cross, check, square).
struct StateMark: View {
	enum State { case running, waiting, failed, done, idle, queued }
	let state: State
	var size: CGFloat = 12

	var body: some View {
		Group {
			switch state {
			case .running:
				Spinner(color: Palette.accent)
			case .waiting:
				Image(systemName: "diamond.fill").resizable().scaledToFit().foregroundStyle(Palette.wait)
			case .failed:
				Image(systemName: "xmark.circle").resizable().scaledToFit().foregroundStyle(Palette.bad)
			case .done:
				Image(systemName: "checkmark").resizable().scaledToFit().fontWeight(.semibold).foregroundStyle(Palette.ink3)
			case .idle:
				Circle().strokeBorder(Palette.rule2, lineWidth: 1.5)
			case .queued:
				Image(systemName: "circle.dotted").resizable().scaledToFit().foregroundStyle(Palette.ink3)
			}
		}
		.frame(width: size, height: size)
	}

	init(_ state: State, size: CGFloat = 12) {
		self.state = state
		self.size = size
	}

	init(_ status: ConversationStatus, size: CGFloat = 12) {
		switch status {
		case .busy: state = .running
		case .needsApproval: state = .waiting
		case .stuck: state = .failed
		case .idle, .unknown: state = .idle
		}
		self.size = size
	}
}

/// A quarter arc turning once every 0.9 s.
struct Spinner: View {
	let color: Color

	var body: some View {
		TimelineView(.animation) { context in
			let angle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9 * 360
			ZStack {
				Circle().stroke(color.opacity(0.22), lineWidth: 1.6)
				Circle().trim(from: 0, to: 0.28).stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round)).rotationEffect(.degrees(angle))
			}
		}
	}
}

/// Kept for the sidebar's machine header.
struct StatusDot: View {
	let color: Color
	var pulsing = false

	var body: some View {
		Circle().fill(color).frame(width: 7, height: 7).opacity(pulsing ? 0.6 : 1)
	}
}

extension Spend {
	var tokensText: String {
		"\(input.formatted()) in · \(output.formatted()) out"
	}
}

extension Date {
	/// "now", "4m", "3h", "2d": how aludra's drawer shows age.
	var shortAge: String {
		let seconds = max(0, Int(Date.now.timeIntervalSince(self)))
		switch seconds {
		case ..<60: return "now"
		case ..<3600: return "\(seconds / 60)m"
		case ..<86_400: return "\(seconds / 3600)h"
		default: return "\(seconds / 86_400)d"
		}
	}
}

/// A group in a side panel: a small-caps label and its content, set off from the next by space.
/// Given `collapsed`, the label becomes a button with a chevron that folds the content away; `trailing` shows
/// beside the label (a count while folded).
struct PanelSection<Content: View>: View {
	let title: String
	var titleColor: Color = Palette.ink3
	var collapsed: Binding<Bool>?
	var trailing: String?
	@ViewBuilder let content: Content
	@State private var hovering = false

	init(_ title: String, titleColor: Color = Palette.ink3, collapsed: Binding<Bool>? = nil, trailing: String? = nil, @ViewBuilder content: () -> Content) {
		self.title = title
		self.titleColor = titleColor
		self.collapsed = collapsed
		self.trailing = trailing
		self.content = content()
	}

	private var isCollapsed: Bool { collapsed?.wrappedValue ?? false }

	var body: some View {
		VStack(alignment: .leading, spacing: 9) {
			if let collapsed {
				Button {
					withAnimation(.easeInOut(duration: 0.2)) { collapsed.wrappedValue.toggle() }
				} label: {
					HStack(spacing: 6) {
						label
						Spacer(minLength: 6)
						if let trailing {
							Text(trailing).font(Typography.label).foregroundStyle(Palette.ink3).monospacedDigit()
						}
						Image(systemName: "chevron.down")
							.font(.system(size: 9 * Typography.scale, weight: .semibold))
							.foregroundStyle(Palette.ink3)
							.rotationEffect(.degrees(isCollapsed ? -90 : 0))
							.opacity(hovering || isCollapsed ? 1 : 0.5)
					}
					.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
				.onHover { hovering = $0 }
				.help(isCollapsed ? "Show \(title)" : "Hide \(title)")
			} else {
				label
			}
			if !isCollapsed { content }
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		// Space between sections, no rule, as between the sidebar's machines.
		.padding(.top, 18)
		.padding(.bottom, 4)
	}

	private var label: some View {
		Text(title)
			.font(Typography.label)
			.foregroundStyle(titleColor)
			.textCase(.uppercase)
			.lineLimit(1)
	}
}
