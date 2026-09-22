/// Token counts, written the way a reader of the language reads numbers.
///
/// Moved out of `Panel/AccountUsageCard.swift` for the Linux build: the card
/// is excluded there, but this is arithmetic and string formatting with no
/// view in it at all, and `MyriadUnitsTests` drives it directly.
enum TokenCount {
    /// "5.9B", "119M" — or "4.19亿", "4764万" where numbers are grouped by ten
    /// thousands. The scale is the point, not the digits.
    static func short(_ tokens: Int) -> String {
        short(tokens, units: LocalizationSource.myriadUnits)
    }

    /// The same formatting with the units supplied. Not `private` so
    /// `MyriadUnitsTests` can drive it without setting the app's language; do
    /// not tidy it back.
    static func short(_ tokens: Int, units: (tenThousand: String, hundredMillion: String)?) -> String {
        if let units { return grouped(tokens, units) }

        let value = Double(tokens)
        switch value {
        case 1_000_000_000...: return format(value / 1_000_000_000, decimals: value < 1e10 ? 1 : 0) + "B"
        case 1_000_000...: return format(value / 1_000_000, decimals: value < 1e7 ? 1 : 0) + "M"
        case 1_000...: return format(value / 1_000, decimals: value < 1e4 ? 1 : 0) + "K"
        default: return "\(tokens)"
        }
    }

    /// 万 is 10⁴ and 亿 is 10⁸, so the breaks fall in different places than
    /// thousands do — 419,000,000 is 4.19亿, not "419 million".
    ///
    /// The two characters are handed in rather than written here: the same
    /// arithmetic serves Japanese and Korean, which break at the same powers
    /// and spell them differently. See `LocalizationSource.myriadUnits`.
    private static func grouped(
        _ tokens: Int,
        _ units: (tenThousand: String, hundredMillion: String)
    ) -> String {
        let value = Double(tokens)
        switch value {
        case 100_000_000...:
            let scaled = value / 100_000_000
            // Three significant figures, which is what "419M" carried.
            return format(scaled, decimals: scaled < 10 ? 2 : (scaled < 100 ? 1 : 0)) + units.hundredMillion
        case 10_000...:
            let scaled = value / 10_000
            return format(scaled, decimals: scaled < 10 ? 1 : 0) + units.tenThousand
        default:
            return "\(tokens)"
        }
    }

    private static func format(_ value: Double, decimals: Int) -> String {
        let text = String(format: "%.\(decimals)f", value)
        guard text.contains(".") else { return text }
        // "4.10亿" and "4.00亿" both read as a mistake; trim what adds nothing.
        return text
            .replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\.$", with: "", options: .regularExpression)
    }
}
