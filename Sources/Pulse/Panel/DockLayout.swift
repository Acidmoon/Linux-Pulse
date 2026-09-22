// Moved out of `UsageDockView.swift`, where it was written.
//
// **Numbers, not a view.** Every member below is a `static var` over
// `PanelMetrics`, `RailSpacing` and `CGFloat`, and it was only in that file
// because that is where the rail is drawn. It is its own file now so that the
// rail's geometry is upstream's geometry on Linux too, and so that upstream's
// own `RailGeometryTests` and `NotchGeometryTests` can check it here — both of
// those test nothing but this type and the shapes that use it.
//
// Moving it is the whole change. Nothing was renamed and no number was touched.
// pulse-linux: moved

// `SwiftUI` re-exports `Foundation` on a Mac, so the numbers below never had
// to name `CGFloat`. Harmless on a Mac, which is why it is unconditional.
import Foundation

enum DockLayout {
    /// Rail width. Flush against the screen's right edge.
    static var width: CGFloat { 64 * PanelMetrics.scale }
    /// Measured from the panel's top edge, NOT from the rail body's flat top
    /// — the concave flare occupies the first `flareHeight` of it. So the
    /// breathing room actually visible above the first ring is
    /// `verticalPadding - flareHeight`. It can never drop below `flareHeight`,
    /// which would clip the ring against the flare; both styles below clear
    /// it by 22pt.
    ///
    /// Softened ends carry a **written** 46pt, tuned against the flatter
    /// 24 × 38 flare beside them. Round ends **derive** it, so the first ring
    /// keeps its place in the end it is centred in: its centre `endRingOffset`
    /// further in than the centre of the end's circle, which is itself
    /// `flareHeight + cornerRadius` in. 54pt at standard size — the rail is
    /// 16pt longer that way, which is why this setting goes through
    /// `onChange?()` like the other rail metrics.
    static var verticalPadding: CGFloat {
        guard PanelMetrics.usesRoundEnds else { return 46 * PanelMetrics.scale }
        return flareHeight + cornerRadius - ringDiameter / 2 + endRingOffset
    }

    /// Room added at each end of the rail beyond what would sit the first
    /// ring exactly on the centre of the rounded end: 20pt of black over that
    /// ring instead of the 12pt beside it, at standard size.
    ///
    /// Zero is the concentric position, and it was built first. Set beside
    /// the design this rail follows, it read cramped — a ring with no more
    /// black over it than beside it looks pushed up against the end. Nothing,
    /// 8 and 12 were drawn side by side and 8 was picked. The bottom end gets
    /// the same, which is room under the last label.
    ///
    /// Zero with softened ends, whose 46pt padding was written rather than
    /// derived: there is no end circle for a ring to be concentric with.
    static var endRingOffset: CGFloat {
        PanelMetrics.usesRoundEnds ? 8 * PanelMetrics.scale : 0
    }
    static var horizontalPadding: CGFloat { 10 * PanelMetrics.scale }

    static var ringDiameter: CGFloat { 36 * PanelMetrics.scale }
    static var ringLineWidth: CGFloat { 4 * PanelMetrics.scale }
    /// Gap between a ring and the percent label beneath it.
    static var ringToTextSpacing: CGFloat { 6 * PanelMetrics.scale }
    static var percentFontSize: CGFloat { 13 * PanelMetrics.scale }
    /// Rendered line height of the percent label, and its width at "100%".
    ///
    /// The panel's AppKit frame is worked out from these before SwiftUI lays
    /// anything out, so they are budgets rather than measurements — and a
    /// budget that is **short** is not an approximation, it is a squeeze. The
    /// height was 15 and the line renders at 15.6–16.0 per unit of scale, so
    /// every item overflowed its own frame by a fraction; centred, that put
    /// ring *i* half an item's worth of error from where the hit testing
    /// looked for it, reaching 6pt down a full rail.
    ///
    /// Measured with the real font — `.system(size:weight:.medium,
    /// design:.rounded)`, `.monospacedDigit()` — at all three sizes, and
    /// rounded **up**: 15.6/16.0/15.6 for the height, 36.9/37.0/37.8 for the
    /// width. Anything drawn on the panel that needs a budget gets it this
    /// way, never by eye.
    static var percentTextHeight: CGFloat { 16 * PanelMetrics.scale }
    static var percentTextWidth: CGFloat { 38 * PanelMetrics.scale }
    /// Gap between the ring+label items, along the rail.
    ///
    /// The only measurement `RailSpacing` touches: the rings keep their size
    /// and the rail grows or shrinks around them, which is a different wish
    /// from wanting the whole panel bigger.
    static var itemSpacing: CGFloat { 30 * PanelMetrics.scale * PanelMetrics.spacing }

    /// The second ring's own geometry, all of it measured off the first so
    /// the two cannot drift apart.
    ///
    /// **Everything inside the ring has to move for this**, which is why it is
    /// here and not a constant in the view. At standard scale the band between
    /// the icon's disc and the ring's inner edge is six points wide, and the
    /// activity mark already rides the middle of it — the one place a second
    /// arc wants. So when this is on the mark moves inward and the disc gives
    /// up two points; the ring itself, the rail's width and the ring centres
    /// are all unchanged, so nothing outside this circle notices.
    static var secondRingDiameter: CGFloat { 26 * PanelMetrics.scale }
    static var secondRingLineWidth: CGFloat { 2.5 * PanelMetrics.scale }

    /// Reach of the two convex corners on the rail's inner side.
    ///
    /// **Round ends** (`AppSettings.usesRoundEnds`): half the rail, so each
    /// end is a full half-circle. Not a taste for round things. A ring is
    /// centred across the rail, so an end this round shares its centre line
    /// with the ring nearest it and follows that ring round — 12pt of black
    /// down both sides of it at standard size, a little more over it
    /// (`endRingOffset`) — instead of squaring off above it. The rail, its
    /// rings and the card's corners then read as one family of curves.
    /// Circular for the reason the floating capsule is: at this radius the
    /// corner meets the flare with no straight edge between them, and there
    /// is nothing for a superellipse to ease into.
    ///
    /// **Softened ends** (the default): 26pt, drawn as a fourth-order
    /// superellipse rather than a circular arc — see
    /// `DockBerthShape.appendCorner`. A superellipse eases into the edge
    /// beside it, so it reads tighter than its radius: about a 14pt circular
    /// corner, squarer than the 20pt ring it wraps. That is the look Pulse
    /// shipped with, and it is kept because it is the one people know.
    ///
    /// Either way, constrained by `cornerRadius + flareWidth <= width`, since
    /// the corner and the flare share the rail's top and bottom edges. Both
    /// styles land on exactly `width`.
    static var cornerRadius: CGFloat {
        PanelMetrics.usesRoundEnds ? width / 2 : 26 * PanelMetrics.scale
    }
    /// How far the concave flare rises above the rail body's flat top edge
    /// (and drops below its bottom edge) on its way to the screen edge.
    ///
    /// With round ends this is the end's own circle turned inside out: as
    /// tall as it is wide, and as wide as the half of the rail the corner
    /// leaves. The two meet on the rail's centre line with one tangent, so
    /// the end is a single S-curve into the screen edge rather than a corner
    /// followed by a shoulder. Softened ends keep the written 24, a flatter
    /// curve than the corner beside it.
    static var flareHeight: CGFloat {
        PanelMetrics.usesRoundEnds ? cornerRadius : 24 * PanelMetrics.scale
    }
    /// How far in from the screen edge the flare starts sweeping.
    ///
    /// With round ends, the whole of the rail the corner does not take, so
    /// `cornerRadius + flareWidth` is exactly `width` and the body's flat top
    /// edge has no length at all. A top rail carrying labels is thicker than
    /// `width`; there the difference is a short flat run between the corner
    /// and the flare. Softened ends keep the written 38, which also sums to
    /// `width` against their 26pt corner.
    static var flareWidth: CGFloat {
        PanelMetrics.usesRoundEnds ? width - cornerRadius : 38 * PanelMetrics.scale
    }

    /// Height of one ring + its percent label.
    static var itemHeight: CGFloat { ringDiameter + ringToTextSpacing + percentTextHeight }

    /// Whether the label is drawn above its ring rather than below it.
    static var labelLeads: Bool { PanelMetrics.labelAboveRing }

    /// How far into its item a ring starts, which is nothing at all unless the
    /// label is above it — then the ring is pushed down past the whole label
    /// block. **Everything that locates a ring has to add this**, the drawing
    /// and the hit testing alike, or a click lands on the number instead of on
    /// the ring it appears to be aimed at.
    static func ringOffsetInItem(on axis: PanelEdge.Axis) -> CGFloat {
        guard labelLeads, showsPercentages(on: axis) else { return 0 }
        return percentTextHeight + ringToTextSpacing
    }

    /// Whether an item carries its percent label. A setting on both axes, with
    /// opposite defaults: down a side the label sits under its ring and costs
    /// nothing, while across the top it is a second line of type directly under
    /// the menu bar.
    static func showsPercentages(on axis: PanelEdge.Axis) -> Bool {
        axis == .vertical
            ? PanelMetrics.sideRailShowsPercentages
            : PanelMetrics.topRailShowsPercentages
    }

    /// The room left at each end of the rail, before the first ring.
    ///
    /// Less when the rail is floating, and that is not a taste: docked, the
    /// concave flare carves `flareHeight` out of each end, so the black you
    /// actually see above the first ring is the difference. Off the edge there
    /// is no flare and the whole padding shows — 54pt against a 30pt gap
    /// between rings, which reads as the ends having been forgotten. Taking
    /// the flare off the number keeps the *visible* breathing room the same on
    /// both, which is what anyone is actually looking at — and because the
    /// flare is as tall as the rail is half wide, it also sits the end ring in
    /// the capsule's round end exactly where it sits in the docked rail's.
    static func endPadding(docked: Bool) -> CGFloat {
        docked ? verticalPadding : verticalPadding - flareHeight
    }

    /// One item's extent **along** the rail.
    ///
    /// Down a side that is the ring stacked over its label; across the top the
    /// two are stacked the same way but the run is the other axis, so an item
    /// is as wide as the **wider of the two**.
    ///
    /// It used to be the ring alone, on the stated premise that the label is
    /// narrower at every size. Measured, "100%" is *wider* — by 1.5 / 1.0 /
    /// 1.1pt at small / standard / large — so a top rail was built about a
    /// point short per ring, the stack was squeezed, and the only thing in an
    /// item that can compress is the text: every label rendered as "10…".
    static func itemLength(on axis: PanelEdge.Axis) -> CGFloat {
        guard showsPercentages(on: axis) else { return ringDiameter }
        return axis == .vertical ? itemHeight : max(ringDiameter, percentTextWidth)
    }

    /// The rail's extent **across** its run: its width down a side, its height
    /// across the top.
    ///
    /// `width` is deliberately more than a ring and its padding — the rail has
    /// always been drawn wider than its contents — so a top rail without
    /// labels keeps exactly the same proportion by using the same number. With
    /// labels there is a second line to make room for.
    /// Down a side this is always `width`, labels or not: the berth's flare
    /// and its corners share that measurement (`cornerRadius + flareWidth <=
    /// width`), so narrowing the rail when the labels go would fold the shape
    /// in on itself. Only the rail's *length* changes there.
    static func thickness(on axis: PanelEdge.Axis) -> CGFloat {
        guard axis == .horizontal, showsPercentages(on: .horizontal) else { return width }
        return itemHeight + horizontalPadding * 2
    }

    /// Rail length for a given number of providers: the padding at each end +
    /// the items + the gaps between them. Providers can be switched off in
    /// settings, so this is not a constant.
    static func length(for itemCount: Int, on axis: PanelEdge.Axis, docked: Bool = true) -> CGFloat {
        let count = CGFloat(max(itemCount, 1))
        return endPadding(docked: docked) * 2 + itemLength(on: axis) * count + itemSpacing * (count - 1)
    }

    /// The rail's full size, laid the way `edge` lays it.
    static func size(for itemCount: Int, on axis: PanelEdge.Axis, docked: Bool = true) -> CGSize {
        let along = length(for: itemCount, on: axis, docked: docked)
        let across = thickness(on: axis)
        return axis == .vertical
            ? CGSize(width: across, height: along)
            : CGSize(width: along, height: across)
    }

    /// Where a ring's centre sits **across** the rail.
    ///
    /// The items are centred in the rail's thickness, and how thick an item is
    /// depends on whether it carries a label — so this is not simply half the
    /// rail. Down a side only the ring is ever as wide as this, the label being
    /// narrower; across the top the label is stacked under the ring and counts.
    static func ringCentreAcross(on axis: PanelEdge.Axis) -> CGFloat {
        let item = axis == .vertical
            ? ringDiameter
            : (showsPercentages(on: axis) ? itemHeight : ringDiameter)
        let lead = axis == .horizontal ? ringOffsetInItem(on: axis) : 0
        return (thickness(on: axis) - item) / 2 + lead + ringDiameter / 2
    }

    /// How far along the rail the first ring's centre sits, and the step from
    /// one to the next.
    static func firstRingAlong(docked: Bool = true, on axis: PanelEdge.Axis = .vertical) -> CGFloat {
        // How far into its item the ring's centre sits, **along the rail**.
        //
        // Down a side the item is the ring stacked over its label, so this is
        // the label's share when it leads plus half a ring. Across the top the
        // stack runs the other way and the ring is simply centred in the
        // item's width — which is *not* half a ring once the item is as wide
        // as the label, and the label is the wider of the two.
        let intoItem = axis == .vertical
            ? ringOffsetInItem(on: axis) + ringDiameter / 2
            : itemLength(on: axis) / 2
        return endPadding(docked: docked) + intoItem
    }
    static func ringStep(on axis: PanelEdge.Axis) -> CGFloat {
        itemLength(on: axis) + itemSpacing
    }

    /// Rail length with every provider switched on, which is what the panel
    /// has to leave room for. Measured docked, which is the longer of the two —
    /// the window never needs to shrink, only the rail drawn inside it.
    static func maximumLength(on axis: PanelEdge.Axis) -> CGFloat {
        length(for: PanelMetrics.railCapacity, on: axis, docked: true)
    }

    /// Kept for the vertical rail, which is what every existing caller means.
    static func height(for itemCount: Int) -> CGFloat {
        length(for: itemCount, on: .vertical)
    }

    /// What the rail hides down to when the pointer is elsewhere: a sliver
    /// against the screen edge.
    ///
    /// Six points is enough to be seen and — because it is welded to the edge
    /// of the display — trivially easy to hit, since throwing the pointer at
    /// the edge always lands on it. The tracking area around it is wider than
    /// the drawing, so approaching from inside works without having to arrive
    /// exactly.
    static var collapsedWidth: CGFloat { 6 * PanelMetrics.scale }
    static var collapsedHeight: CGFloat { 96 * PanelMetrics.scale }
    static var collapsedHitWidth: CGFloat { 20 * PanelMetrics.scale }

    /// The sliver, laid the way `axis` lays the rail: 6pt of it against the
    /// screen edge and 96pt along it, whichever way round that falls.
    static func collapsedSize(on axis: PanelEdge.Axis) -> CGSize {
        axis == .vertical
            ? CGSize(width: collapsedWidth, height: collapsedHeight)
            : CGSize(width: collapsedHeight, height: collapsedWidth)
    }

    /// The same for the tracking area, which is wider than the drawing.
    static func collapsedHitSize(on axis: PanelEdge.Axis) -> CGSize {
        axis == .vertical
            ? CGSize(width: collapsedHitWidth, height: collapsedHeight)
            : CGSize(width: collapsedHeight, height: collapsedHitWidth)
    }

    /// The tallest the rail ever gets. The panel window is kept at this height
    /// whatever is switched on, so turning a provider off never has to resize
    /// the window — the rail simply draws shorter inside it, and the leftover
    /// space is transparent.
    static var maximumHeight: CGFloat { height(for: PanelMetrics.railCapacity) }
}

/// A provider's place in the rail: what it reports, and the one window its
/// ring shows. The ring's window is resolved by the caller because the choice
/// is a setting, and the rail shouldn't have to know about settings.
