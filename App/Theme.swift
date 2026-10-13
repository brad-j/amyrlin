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
/// Every size goes through `scale`, so all text grows or shrinks together (a font-size setting can set it later).
enum Typography {
	static let scale: CGFloat = 1.15
	private static func sans(_ size: CGFloat) -> Font { .custom("IBM Plex Sans", size: size * scale) }
	/// Both families ship one file per weight; `.weight(_:)` picks among the bundled ones.
	private static func mono(_ size: CGFloat) -> Font { .custom("IBM Plex Mono", size: size * scale) }

	static let reading = sans(15)
	static let readingSmall = sans(13)
	static let readingStrong = sans(15).weight(.semibold)
	static func heading(_ level: Int) -> Font {
		sans([20, 17.5, 16, 15][min(max(level, 1), 4) - 1]).weight(.medium)
	}
	static let code = mono(12.5)
	static let codeSmall = mono(11.5)
	static let inlineCode = mono(13)
	/// Chrome: sidebar rows, the inspector, the picker, the composer, the header.
	static let ui = mono(12.5)
	static let uiSmall = mono(11.5)
	static let uiStrong = mono(12.5).weight(.semibold)
	static let label = mono(10.5).weight(.medium)
	static let projectHeader = mono(12.5).weight(.medium)
	static let machineHeader = mono(14.5).weight(.medium)
	/// Line height of `codeSmall`, for blocks that keep a fixed number of lines.
	static let codeSmallLine: CGFloat = 15.5 * scale
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

	/// Each project's own colour (AmyrlinCore's ProjectColor), the same everywhere it appears.
	static func project(_ name: String) -> Color {
		let c = ProjectColor.rgb(for: name)
		return Color(red: c.red, green: c.green, blue: c.blue)
	}

	/// The selected row's wash in a project's hue: dark paper with a trace of it.
	static func projectWash(_ name: String) -> Color {
		let c = ProjectColor.oklchToSRGB(lightness: 0.25, chroma: 0.035, hue: ProjectColor.hues[ProjectColor.index(for: name)])
		return Color(red: c.red, green: c.green, blue: c.blue)
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

enum Metrics {
	/// The reading column: about 70 characters of reading text.
	static let measure: CGFloat = 720 * Typography.scale
	/// Every corner radius scales by this. Square since the console redesign (2026-10-12); 0.65 before.
	static let rounding: CGFloat = 0
	static let radiusSmall: CGFloat = 5 * rounding
	/// Rows in the sidebar and the picker.
	static let radiusRow: CGFloat = 6 * rounding
	static let radius: CGFloat = 8 * rounding
	static let radiusLarge: CGFloat = 14 * rounding
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
	var costText: String {
		cost.formatted(.currency(code: "USD").precision(.fractionLength(cost < 1 ? 4 : 2)))
	}

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

/// A group in a side panel (sidebar and inspector): a small-caps label, its content, a hairline under it.
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
		.padding(.vertical, 14)
		.overlay(alignment: .bottom) { Rectangle().fill(Palette.rule).frame(height: 1) }
	}

	private var label: some View {
		Text(title)
			.font(Typography.label)
			.foregroundStyle(titleColor)
			.textCase(.uppercase)
			.lineLimit(1)
	}
}
