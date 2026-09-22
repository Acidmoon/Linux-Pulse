/// The day table's columns, which are also what it can be sorted by.
///
/// Moved out of `Settings/TokenSpendView.swift` for the Linux build: the view
/// is excluded there, but `SpendSummary.sorted(_:by:ascending:)` — which is
/// data ordering rather than layout — takes one.
///
/// `ModelSpendSummary` carries a second, identically-shaped `DayColumn` of its
/// own. That duplication is upstream's and is left alone here rather than
/// merged in passing: the two are used by different tables, and collapsing
/// them is a change to what those tables mean, not a portability fix.
enum DayColumn: String, CaseIterable, Identifiable, Sendable {
    case date
    case input
    case output
    case cacheRead
    case cacheWrite
    case total
    case cost

    var id: String { rawValue }

    var title: String {
        switch self {
        case .date: .localized("Date")
        case .input: .localized("Input")
        case .output: .localized("Output")
        // Short, because seven columns of Chinese headings in a settings pane
        // is a table that wraps.
        case .cacheRead: .localized("C. read")
        case .cacheWrite: .localized("C. write")
        case .total: .localized("Total")
        case .cost: .localized("Cost")
        }
    }
}
