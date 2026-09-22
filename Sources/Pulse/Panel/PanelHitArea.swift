// Moved out of `FloatingUsagePanelView.swift`, where it was written.
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

/// The two areas the pointer test asks about, kept together because the
/// relationship between them is what makes the show/hide cycle safe.
///
/// **The sliver's target must sit entirely inside the rail's.** Hiding only
/// happens when the pointer is outside the *rail*, so if the sliver could
/// stick out beyond it there would be points that hide the rail and then
/// immediately land on the sliver — whose tracking area shows it again, which
/// hides it again. That is the open/close loop this file has already been
/// fixed for twice, in a new costume. `stripIsContainedInRail()` asserts the
/// containment for every rail length and every edge, and is run on every debug
/// launch from `FloatingPanelController`.
enum PanelHitArea {
    /// Forgiveness around the edges before the pointer counts as gone.
    ///
    /// Lives here rather than on the view because the view is `@MainActor`
    /// (every SwiftUI `View` is) while these are plain geometry called from
    /// wherever — reaching across that boundary is a warning under Swift 5's
    /// rules and an error under Swift 6's, which is how it broke in Xcode
    /// while `swift build` stayed happy.
    static let slack: CGFloat = 8

    /// The surface extends up to the physical screen top and is at least as
    /// wide as the housing, even when the rail only has one ring.
    ///
    /// No padding is added under the rail. The housing above the rings is the
    /// screen's own bezel, not room this panel chose, and matching it would
    /// mean 38pt of black under a 36pt ring: the rail keeps the symmetric
    /// padding it has everywhere else and the housing simply sits on top.
    ///
    /// The body alone — `NotchBerthShape` sweeps `DockLayout.flareWidth`
    /// further out at the screen edge, and the grab area deliberately does not
    /// follow it there.
    static func notchSurface(rail: CGRect, notchSize: CGSize) -> CGRect {
        let width = max(rail.width, notchSize.width)
        return CGRect(x: rail.midX - width / 2, y: rail.minY - notchSize.height,
                      width: width, height: rail.height + notchSize.height)
    }

    /// The rail's rectangle inside the panel, in the panel's top-left space.
    static func rail(edge: PanelEdge, railSize: CGSize, railTop: CGFloat, railLeading: CGFloat) -> CGRect {
        let panel = PanelLayout.size(for: edge)
        let x: CGFloat = switch edge {
        case .left, .top: edge == .top ? railLeading : 0
        case .right: panel.width - railSize.width
        }

        return CGRect(x: x, y: railTop, width: railSize.width, height: railSize.height)
    }

    /// The provider ring under a point in the panel's top-left coordinate
    /// space. Only the circle is clickable: the label and the empty berth keep
    /// their existing meaning as drag surface.
    static func slot(
        at point: CGPoint,
        edge: PanelEdge,
        slots: [RailSlot],
        railTop: CGFloat,
        railLeading: CGFloat,
        docked: Bool
    ) -> RailSlot? {
        let size = DockLayout.size(for: slots.count, on: edge.axis, docked: docked)
        let rail = rail(edge: edge, railSize: size, railTop: railTop, railLeading: railLeading)
        guard rail.contains(point) else { return nil }

        // Includes the selected ring's 1.06 scale and a small amount of pointer
        // forgiveness without reaching the percentage label beneath it.
        let radius = DockLayout.ringDiameter / 2 * 1.08
        let across = DockLayout.ringCentreAcross(on: edge.axis)

        for (index, slot) in slots.enumerated() {
            let along = DockLayout.firstRingAlong(docked: docked, on: edge.axis)
                + CGFloat(index) * DockLayout.ringStep(on: edge.axis)
            let centre = edge.isVertical
                ? CGPoint(x: rail.minX + across, y: rail.minY + along)
                : CGPoint(x: rail.minX + along, y: rail.minY + across)

            let dx = point.x - centre.x
            let dy = point.y - centre.y
            if dx * dx + dy * dy <= radius * radius { return slot }
        }

        return nil
    }

    /// The sliver only ever exists docked — off the edge the rail stays open —
    /// so this is always hard against the screen edge.
    static func strip(edge: PanelEdge, railSize: CGSize, railTop: CGFloat, railLeading: CGFloat) -> CGRect {
        let rail = rail(edge: edge, railSize: railSize, railTop: railTop, railLeading: railLeading)
        let hit = DockLayout.collapsedHitSize(on: edge.axis)

        // Centred along the rail's band, which is where it is drawn, and hard
        // against the screen edge across it. The same forgiveness the card's
        // band gets is added along the run, so the sliver isn't a trip wire.
        switch edge {
        case .left:
            return CGRect(x: rail.minX, y: rail.midY - hit.height / 2, width: hit.width, height: hit.height)
                .insetBy(dx: 0, dy: -slack)
        case .right:
            return CGRect(x: rail.maxX - hit.width, y: rail.midY - hit.height / 2, width: hit.width, height: hit.height)
                .insetBy(dx: 0, dy: -slack)
        case .top:
            return CGRect(x: rail.midX - hit.width / 2, y: rail.minY, width: hit.width, height: hit.height)
                .insetBy(dx: -slack, dy: 0)
        }
    }

    /// Whether the sliver is reachable without leaving the rail's area, for
    /// every rail length the app can produce.
    ///
    /// Measured against the metrics currently in force — panel size, ring
    /// spacing and both label flags all change the rail, and all of them can
    /// change while the app runs, so the assertion is worth its cost on every
    /// launch rather than once against one arbitrary combination.
    ///
    /// The bound is the rail's **capacity**, not the number of providers: the
    /// rail is keyed by account now, and a second Codex login makes it longer
    /// than `Provider.allCases` ever describes.
    static func stripIsContainedInRail() -> Bool {
        for edge in [PanelEdge.left, .right, .top] {
            for count in 1...max(PanelMetrics.railCapacity, 1) {
                // Docked is the only state the sliver exists in — off the edge
                // the rail stays open — but it is measured here in both so a
                // change to the floating length cannot quietly break it.
                let size = DockLayout.size(for: count, on: edge.axis, docked: true)
                let panel = PanelLayout.size(for: edge)
                // Every offset the rail can take inside the panel, since it is
                // no longer pinned to the middle of it.
                let travel = edge.isVertical
                    ? max(panel.height - size.height, 0)
                    : max(panel.width - size.width, 0)

                for offset in stride(from: 0.0, through: travel, by: 1) {
                    let top = edge.isVertical ? offset : 0
                    let leading = edge.isVertical ? 0 : offset
                    guard rail(edge: edge, railSize: size, railTop: top, railLeading: leading)
                        .contains(strip(edge: edge, railSize: size, railTop: top, railLeading: leading))
                    else { return false }
                }
            }
        }
        return true
    }
}
