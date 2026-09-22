import Foundation

/// Money and token formatting for the spend panes.
///
/// Moved out of `Settings/SpendCharts.swift` for the Linux build: the chart
/// is excluded there, but formatting is arithmetic and `SpendFormatTests`
/// drives it directly.
/// The hours, in the words each language actually uses for one.
///
/// **Not `.dateTime.hour()`.** It is locale-aware and still wrong here: for
/// Chinese it produces the written "10时" where an hour spoken aloud is
/// "10 点". A key per language says it the way that language says it, and the
/// number is interpolated as a string so the entry stays `%@`.
enum SpendFormat {
    /// A hover can be read without the surrounding span picker, including
    /// across New Year, so unlike the axis it includes the year.
    static func chartDate(_ date: Date) -> String {
        date.formatted(.dateTime.year().month(.abbreviated).day().locale(LocalizationSource.locale))
    }

    static func hour(_ hour: Int) -> String {
        .localized("\("\(hour)") o'clock")
    }

    /// The exact count, grouped the reader's way and in the app's language.
    ///
    /// For a help tag: `TokenCount.short` rounds by ten thousands, and a reader
    /// checking one figure wants every digit rather than a short form that
    /// hides the difference between two nearby numbers.
    static func tokens(_ count: Int) -> String {
        let number = count.formatted(.number.locale(LocalizationSource.locale))
        return String.localized("\(number) tokens")
    }

    /// How many of a model's tokens had no price behind the estimate. The same
    /// phrasing as the line under the total, for a row's help tag.
    static func unpriced(_ count: Int) -> String {
        let number = count.formatted(.number.locale(LocalizationSource.locale))
        return String.localized("\(number) tokens unpriced")
    }

    /// A dollar figure, in dollars whatever the reader's currency is, at two
    /// places — or none once it is over a thousand.
    ///
    /// **A positive amount too small to show is still not free.** Rounded to
    /// cents it would print `$0.00`, which reads as nothing spent; it says
    /// "less than a cent" instead. A real zero still prints `$0.00`, because
    /// that one is a measurement.
    static func money(_ amount: Double, locale: Locale = LocalizationSource.locale) -> String {
        if amount > 0, amount < 0.01 {
            let cent = 0.01.formatted(
                .currency(code: "USD")
                    .precision(.fractionLength(2))
                    .locale(locale)
            )
            return String.localized("< \(cent)")
        }

        return amount.formatted(
            .currency(code: "USD")
                .precision(.fractionLength(amount >= 1000 ? 0 : 2))
                .locale(locale)
        )
    }

    /// The same figure as a help tag, where the visible rounding hides the
    /// digits being checked.
    ///
    /// **Significant digits, not a fixed count.** A fixed six places turns
    /// anything below a millionth into `$0.000000`, contradicting the visible
    /// "less than a cent"; and a fixed count also drops a large amount's real
    /// fraction. Significant digits keep a tiny positive amount visible and a
    /// large one exact.
    static func moneyExact(_ amount: Double, locale: Locale = LocalizationSource.locale) -> String {
        // A real zero keeps the same two places the page shows it with.
        guard amount != 0 else { return money(amount, locale: locale) }

        return amount.formatted(
            .currency(code: "USD")
                .precision(.significantDigits(1...15))
                .locale(locale)
        )
    }
}
