import Foundation

/// Money as the app writes it: "<$0.01", "$0.42", "$12.30", "$140". Only for dollars actually charged
/// (`ConversationSummary.cost`, the host's `monthCost`), never for `Spend.cost`.
public enum Dollars {
	public static func text(_ amount: Double) -> String {
		if amount > 0, amount < 0.01 { return "<$0.01" }
		let cents = (amount * 100).rounded()
		if cents >= 10_000 {
			return "$" + (cents / 100).rounded().formatted(.number.locale(Locale(identifier: "en_US")).precision(.fractionLength(0)))
		}
		return "$" + (cents / 100).formatted(.number.locale(Locale(identifier: "en_US")).precision(.fractionLength(2)))
	}
}
