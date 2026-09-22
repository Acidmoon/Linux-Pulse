// Moved out of `UsageDetailCard.swift`, where it was written.
//
// **Numbers, not a view.** Every member is a `static` over `PanelMetrics`,
// `DockLayout` and `CGFloat`, and it was only in that file because that is
// where it was first drawn. It is its own file now so that the panel's
// geometry is upstream's geometry on Linux too, and so upstream's own
// `RailGeometryTests` can check it here.
//
// Moving it is the whole change. Nothing was renamed and no number was touched.
// pulse-linux: moved

// `SwiftUI` re-exports `Foundation` on a Mac, so the numbers below never had to
// name `CGFloat`. Harmless on a Mac, which is why it is unconditional.
import Foundation

/// Layout constants for the detail bubble. Shared with
/// `PanelLayout` (which derives `expandedWidth` from
/// these plus `DockLayout`) and with `FloatingUsagePanelView`'s vertical
/// alignment math, so the AppKit panel frame and the SwiftUI content never
/// drift apart.
enum DetailCardLayout {
    static var width: CGFloat { 250 * PanelMetrics.scale }
    static var padding: CGFloat { 18 * PanelMetrics.scale }
    /// The rings' own curve: the outer edge of a ring's stroke, 20pt at
    /// standard size.
    ///
    /// One circle sets every curve on the panel — the rail's ends are this
    /// plus the band beside a ring (`DockLayout.cornerRadius`), the card's
    /// corners are this — so the three shapes read as one family instead of
    /// three radii picked separately. It also sits where the card's own
    /// content puts it: 18pt of padding round a bar whose ends are 3pt round.
    static var cornerRadius: CGFloat { (DockLayout.ringDiameter + DockLayout.ringLineWidth) / 2 }

    static var pointerWidth: CGFloat { 20 * PanelMetrics.scale }
    static var pointerHeight: CGFloat { 40 * PanelMetrics.scale }
    /// Gap between the pointer's tip and the dock rail. The tip approaches
    /// the rail but doesn't need to touch it.
    static var horizontalGap: CGFloat { 8 * PanelMetrics.scale }

    /// Vertical rhythm between header / progress row / progress row.
    static var contentSpacing: CGFloat { 14 * PanelMetrics.scale }
    /// Spacing between a row's title line, its progress bar, and its
    /// percent line.
    static var rowInternalSpacing: CGFloat { 7 * PanelMetrics.scale }
    static var progressBarHeight: CGFloat { 6 * PanelMetrics.scale }
    /// Rendered line height of the header row (icon + title).
    static var headerHeight: CGFloat { 19 * PanelMetrics.scale }

    // Type scales with everything else. It did not, once: the card's *width*
    // followed `PanelMetrics` while every font in it was written as a constant,
    // so at Small a 205pt card still tried to hold 14pt text and truncated its
    // own title, and at Large a 305pt card held the same 11.5pt rows and read
    // as half empty next to rings that had grown. The line-height budgets above
    // were already scaled, which is what makes these ratios hold at every size.
    static var titleFontSize: CGFloat { 14 * PanelMetrics.scale }
    static var rowFontSize: CGFloat { 11.5 * PanelMetrics.scale }
    static var messageFontSize: CGFloat { 12 * PanelMetrics.scale }
    static var footnoteFontSize: CGFloat { 11 * PanelMetrics.scale }
    /// The provider's mark in the header.
    static var headerIconSize: CGFloat { 16 * PanelMetrics.scale }
    /// Rendered line height of a row's title/percent text.
    static var rowTextLineHeight: CGFloat { 14 * PanelMetrics.scale }

    static var rowHeight: CGFloat {
        rowTextLineHeight + rowInternalSpacing + progressBarHeight + rowInternalSpacing + rowTextLineHeight
            // The forecast is a fourth line under every limit, and the panel's
            // frame is worked out from this before SwiftUI lays anything out.
            // Left out, a top-docked card with five limits ran 84pt past the
            // window and was sliced flat against its edge.
            + (PanelMetrics.showsForecast ? rowInternalSpacing + rowTextLineHeight : 0)
    }

    /// Starting guess for the card's height, used for the very first layout
    /// pass only. The real height depends on how many limits the provider
    /// reports, so `FloatingUsagePanelView` measures it and works from that
    /// instead — see its `cardHeight`.
    static var estimatedHeight: CGFloat { height(forWindows: 2) }

    /// Room the panel has to leave for the tallest card it might have to show.
    ///
    /// The panel's frame is fixed, and a card taller than it gets sliced off
    /// square against the window's edge — which looks like a rendering bug,
    /// not like a card that didn't fit. Providers report a variable number of
    /// limits (Codex adds one group per model with its own limits), so this
    /// budgets for more than are on screen today.
    static var maximumHeight: CGFloat { height(forWindows: 5, footnote: true) }

    static func height(forWindows count: Int, footnote: Bool = false) -> CGFloat {
        padding * 2
            + headerHeight
            + CGFloat(count) * (contentSpacing + rowHeight)
            + (footnote ? contentSpacing + footnoteHeight : 0)
    }

    /// Rendered line height of the "as of …" line under the limits.
    static var footnoteHeight: CGFloat { 13 * PanelMetrics.scale }
}
