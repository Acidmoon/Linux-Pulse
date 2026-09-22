// Moved out of `FloatingPanelController.Layout`, where it was written.
//
// **Pure geometry, and on Linux there is no window controller to hang it on.**
// It is what the panel's window is sized to, which is a question the Linux
// panel asks as much as the Mac one — the card unfolds into the space this
// computes. So it is a type of its own, named `PanelLayout` rather than `Layout`
// because `SwiftUI` already has a protocol by that name.
//
// `width`/`height` and every number below are upstream's, untouched. The only
// change is the name, and `shownSlotCount` moved here with it because it is the
// same question — how many rings the rail is sized for.
// pulse-linux: moved

import Foundation

enum PanelLayout {
    /// The panel's size for a given dock and display housing. It changes
    /// when the axis or screen geometry changes, never while a card opens
    /// or the notch surface expands. That distinction is
    /// the whole point: growing the window mid-animation moves the
    /// coordinate space the rail is laid out in, so the rail lurches
    /// sideways and slides back every time a card appears. Re-docking
    /// happens under the pointer, with no card open, and has to resize.
    static func size(for edge: PanelEdge, notchSize: CGSize? = nil) -> CGSize {
        // Card + its pointer + the gap after it, which is the room the
        // card unfolds into whichever way it unfolds.
        let reach = DetailCardLayout.width
            + DetailCardLayout.pointerWidth
            + DetailCardLayout.horizontalGap

        switch edge.axis {
        case .vertical:
            return CGSize(
                width: reach + DockLayout.thickness(on: .vertical),
                // Tall enough for whichever is bigger: the rail with every
                // provider on, or the tallest card that might be shown
                // beside it. A card taller than the window gets sliced off
                // flat against its edge, which reads as a drawing bug
                // rather than as a card that didn't fit.
                height: max(DockLayout.maximumLength(on: .vertical), DetailCardLayout.maximumHeight)
            )
        case .horizontal:
            return CGSize(
                // Wide enough for whichever is wider, for the same reason.
                width: max(DockLayout.maximumLength(on: .horizontal), DetailCardLayout.width, notchSize?.width ?? 0),
                height: DockLayout.thickness(on: .horizontal)
                    + (notchSize?.height ?? 0)
                    + DetailCardLayout.horizontalGap
                    + DetailCardLayout.pointerWidth
                    + DetailCardLayout.maximumHeight
            )
        }
    }

    /// The vertical dock's size, which is what the previews and anything
    /// written before there was a second axis mean.
    static var width: CGFloat { size(for: .right).width }
    static var height: CGFloat { size(for: .right).height }

    /// How many rings the rail is showing, which is what its size is computed
    /// from. Moved here from `FloatingPanelController`, where it was a `static`
    /// on the window controller and reached nothing on it.
    static func shownSlotCount(
        _ settings: AppSettings,
        usage: (AccountKey) -> ProviderUsage
    ) -> Int {
        RailSlot.rail(
            for: settings.shownAccounts,
            isSplit: settings.isSplit,
            groups: { RailSlot.modelGroups(of: usage($0)) }
        ).count
    }
}
