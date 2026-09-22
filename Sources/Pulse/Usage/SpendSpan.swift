/// How far back the token-spend pane counts.
///
/// Moved out of `Settings/TokenSpendView.swift` for the Linux build: the pane is
/// excluded there, but `AppSettings.spendSpan` is a stored setting and the enum
/// is a value, not a view. Kept where `AppSettings` can reach it.
/// How far back the pane counts.
///
/// Not the card's fixed month: the question here is "where has it all gone",
/// which is asked over a week and over a year, and the answer changes shape at
/// each end.
enum SpendSpan: String, CaseIterable, Identifiable, Sendable {
    case today
    case week
    case month
    case quarter
    case all

    /// The span the pane opens on: the last week, the shortest window that
    /// shows a work rhythm rather than a single day. The reader's own pick is
    /// kept by `AppSettings.spendSpan`.
    static let `default` = SpendSpan.week

    var id: String { rawValue }

    /// Nil counts everything the transcripts go back to.
    var days: Int? {
        switch self {
        // One day, which is the day in progress rather than the last
        // twenty-four hours: the ledger's rows are local midnights.
        case .today: 1
        case .week: 7
        case .month: 30
        case .quarter: 90
        case .all: nil
        }
    }

    var title: String {
        switch self {
        // Interpolate a string, never the integer: an `Int` in a localization
        // key produces `%lld`, which will not match a `%@` entry.
        case .today: .localized("Today")
        case .week: .localized("Last \("7") days")
        case .month: .localized("Last \("30") days")
        case .quarter: .localized("Last \("90") days")
        case .all: .localized("All time")
        }
    }
}
