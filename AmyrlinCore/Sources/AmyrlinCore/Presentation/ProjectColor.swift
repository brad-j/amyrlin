import Foundation

/// A colour for each project, picked from its name: the same project gets the same colour on every launch and every
/// machine. Hues share one lightness and chroma, so every project label reads equally on the dark paper. Red and amber
/// are left out, because they mean failed and waiting for approval.
public enum ProjectColor {
	/// OKLCH hues in degrees, ordered so neighbours differ.
	public static let hues: [Double] = [300, 165, 50, 240, 330, 110, 190, 355, 265, 140, 215]
	public static let lightness = 0.80
	public static let chroma = 0.12

	/// Index into `hues` for `project`. FNV-1a, because Swift's `hashValue` changes on every launch.
	public static func index(for project: String) -> Int {
		var hash: UInt64 = 0xcbf2_9ce4_8422_2325
		for byte in project.utf8 {
			hash ^= UInt64(byte)
			hash = hash &* 0x0000_0100_0000_01b3
		}
		return Int(hash % UInt64(hues.count))
	}

	/// sRGB components in 0...1.
	public static func rgb(for project: String) -> (red: Double, green: Double, blue: Double) {
		oklchToSRGB(lightness: lightness, chroma: chroma, hue: hues[index(for: project)])
	}

	/// OKLCH to gamma-encoded sRGB, clamped to the gamut.
	public static func oklchToSRGB(lightness: Double, chroma: Double, hue: Double) -> (red: Double, green: Double, blue: Double) {
		let a = chroma * cos(hue * .pi / 180)
		let b = chroma * sin(hue * .pi / 180)
		let l = pow(lightness + 0.396_337_777_4 * a + 0.215_803_757_3 * b, 3)
		let m = pow(lightness - 0.105_561_345_8 * a - 0.063_854_172_8 * b, 3)
		let s = pow(lightness - 0.089_484_177_5 * a - 1.291_485_548_0 * b, 3)
		func encode(_ linear: Double) -> Double {
			let x = min(max(linear, 0), 1)
			return x <= 0.003_130_8 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
		}
		return (
			encode(4.076_741_662_1 * l - 3.307_711_591_3 * m + 0.230_969_929_2 * s),
			encode(-1.268_438_004_6 * l + 2.609_757_401_1 * m - 0.341_319_396_5 * s),
			encode(-0.004_196_086_3 * l - 0.703_418_614_7 * m + 1.707_614_701_0 * s)
		)
	}
}
