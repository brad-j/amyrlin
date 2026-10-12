import AmyrlinCore
import SwiftUI

/// Every typeface the app uses, in one place. Reading text is Fira Sans, bundled in App/Fonts; controls keep SF.
enum Typography {
	static let reading = Font.custom("Fira Sans", size: 14.5)
	static let readingSmall = Font.custom("Fira Sans", size: 13)
	static let code = Font.system(size: 12, design: .monospaced)
	static let label = Font.system(size: 11, weight: .medium)
}

/// Restrained cool neutrals, with color only where it carries meaning.
enum Palette {
	static let background = Color(red: 0.078, green: 0.086, blue: 0.098)
	static let surface = Color(red: 0.118, green: 0.129, blue: 0.145)
	static let raised = Color(red: 0.157, green: 0.169, blue: 0.188)
	static let hairline = Color.white.opacity(0.07)
	static let secondaryText = Color(red: 0.62, green: 0.66, blue: 0.71)
	static let tertiaryText = Color(red: 0.45, green: 0.48, blue: 0.53)
	static let accent = Color(red: 0.45, green: 0.64, blue: 1.0)

	static let idle = Color(red: 0.42, green: 0.45, blue: 0.50)
	static let busy = Color(red: 0.36, green: 0.62, blue: 1.0)
	static let approval = Color(red: 0.70, green: 0.55, blue: 1.0)
	static let failure = Color(red: 1.0, green: 0.45, blue: 0.48)
	static let success = Color(red: 0.40, green: 0.80, blue: 0.70)

	static func color(for status: ConversationStatus) -> Color {
		switch status {
		case .idle: idle
		case .busy: busy
		case .needsApproval: approval
		case .stuck: failure
		case .unknown: idle
		}
	}

	static func color(for status: HostConnection.Status) -> Color {
		switch status {
		case .connected: success
		case .connecting, .waiting: busy.opacity(0.6)
		case .failed: failure
		case .idle, .stopped: idle
		}
	}
}

struct StatusDot: View {
	let color: Color
	var pulsing = false

	@State private var dim = false

	var body: some View {
		Circle()
			.fill(color)
			.frame(width: 7, height: 7)
			.opacity(pulsing && dim ? 0.35 : 1)
			.animation(pulsing ? .easeInOut(duration: 0.9).repeatForever() : .default, value: dim)
			.onAppear { dim = pulsing }
			.onChange(of: pulsing) { _, now in dim = now }
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
