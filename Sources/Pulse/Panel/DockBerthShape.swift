// Moved out of `UsageDockView.swift`, where it was written.
//
// **A shape, not a view.** `path(in:)` is arithmetic over a rectangle, and the
// rail's silhouette — the concave flare that fuses it to the screen edge, and
// the corners at the other end — is the most recognisable thing about the
// panel. It is here so that on Linux it is still upstream's outline, drawn
// through `PanelRenderer`, rather than a rounded rectangle that resembles it.
//
// Moving it is the whole change. Nothing was renamed and no number was touched.
// pulse-linux: moved

#if canImport(SwiftUI)
import SwiftUI
#else
// On Linux the two names this needs — `Path` and `Shape` — are the shim in
// `Panel/GTK/PanelPath.swift`. `CGFloat`, `CGRect` and `CGPoint` come from
// Foundation either way.
import Foundation
#endif

/// A vertical "berth" shape for the collapsed rail, in the spirit of a
/// Dynamic Island or the flared root of a browser tab: the rail looks like
/// it grew out of the screen's right edge rather than being parked next to
/// it.
///
/// The right edge runs flush against the screen for the shape's whole
/// height — nothing is rounded there, so no wallpaper ever shows between
/// the rail and the edge. The rail *body* is inset from the top and bottom
/// by `flareHeight`, and each end sweeps out to the screen edge through a
/// concave fillet that leaves the body's flat edge horizontally and meets
/// the screen edge vertically, so both junctions are tangent-continuous.
///
/// The flare lives inside the bounding rect, which is why
/// `DockLayout.verticalPadding` must stay >= `flareHeight`: content laid
/// out above the body's flat top would fall outside the shape and be
/// clipped.
struct DockBerthShape: Shape {
    /// Which screen edge the rail is flush against.
    ///
    /// Drawn once, facing right, then moved into place: mirrored for the left
    /// edge, turned a quarter for the top. The outline carries no text and no
    /// asymmetric detail, so transforming the finished path is exact and
    /// avoids a second copy of the geometry that could drift from this one.
    var edge: PanelEdge = .right
    /// Off the edge there is nothing to fuse with, so the flare gives way to a
    /// capsule with fully round ends. Drawing an edge-hugging silhouette in
    /// the middle of the desktop reads as a rendering fault rather than as a
    /// design.
    var isDocked: Bool = true

    /// How far open the berth is: 0 is the collapsed sliver, 1 the full rail.
    ///
    /// The sliver is not a different shape — it is this one with its flare and
    /// corners wound all the way down, which is what lets the two be animated
    /// between as a single object changing size rather than swapped for one
    /// another. At 0 the flare vanishes and the corner radius equals the whole
    /// width, leaving exactly the rounded-on-one-side sliver.
    var openness: CGFloat = 1

    /// Lets the outline itself be interpolated, so the silhouette is redrawn
    /// at every step of the animation instead of one shape being faded into
    /// another.
    var animatableData: CGFloat {
        get { openness }
        set { openness = newValue }
    }

    private var flareHeight: CGFloat { DockLayout.flareHeight * openness }
    private var flareWidth: CGFloat { DockLayout.flareWidth * openness }
    private var cornerRadius: CGFloat {
        DockLayout.collapsedWidth
            + (DockLayout.cornerRadius - DockLayout.collapsedWidth) * openness
    }

    func path(in rect: CGRect) -> Path {
        guard isDocked else { return floating(in: rect) }

        switch edge {
        case .right:
            return facingRight(in: rect)

        case .left:
            return facingRight(in: rect).applying(
                CGAffineTransform(translationX: rect.width, y: 0).scaledBy(x: -1, y: 1)
            )

        case .top:
            // A quarter turn anticlockwise, which carries the flare from the
            // right-hand edge to the top one. The canonical rect is this one
            // laid on its side, so the drawing is unchanged and only its
            // placement differs — and because it is a rotation rather than a
            // reflection, the path's winding is preserved.
            let canonical = CGRect(x: 0, y: 0, width: rect.height, height: rect.width)
            return facingRight(in: canonical).applying(
                CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: rect.height)
            )
        }
    }

    /// A true capsule: the ends are half circles, not rounded-off corners.
    ///
    /// Circular, not a squircle. A squircle eases its curvature into the
    /// straight edge either side of it, and at this width the two corners of
    /// an end meet with no straight edge between them at all — so there is
    /// nothing to ease into and the result reads as a flattened lozenge. Fully
    /// round ends are what a free-standing pill is — and while
    /// `AppSettings.usesRoundEnds` is on they are the docked rail's ends too,
    /// less the flare.
    private func floating(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2
        return Path(
            roundedRect: rect,
            cornerSize: CGSize(width: radius, height: radius),
            style: .circular
        )
    }

    private func facingRight(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let f = min(flareHeight, h / 2)
        // The convex corners live on the body, which spans y in [f, h - f].
        let r = max(min(cornerRadius, min(w, (h - f * 2) / 2)), 0)
        // The flare must leave room for that corner: if `flareWidth + r`
        // exceeded the width, the body's flat top edge would run backwards
        // and the path would fold in on itself.
        let fw = max(min(flareWidth, w - r), 0)

        // Pulls each fillet's control points off its endpoints. 0.55 is the
        // usual circular-arc approximation; it keeps the sweep full instead
        // of flattening it into a sliver.
        let k: CGFloat = 0.55

        var path = Path()

        // Body's flat top edge, left to right.
        path.move(to: CGPoint(x: r, y: f))
        path.addLine(to: CGPoint(x: w - fw, y: f))

        // Concave fillet sweeping up into the screen edge.
        path.addCurve(
            to: CGPoint(x: w, y: 0),
            control1: CGPoint(x: w - fw * (1 - k), y: f),
            control2: CGPoint(x: w, y: f * k)
        )

        // Flush against the screen for the full height.
        path.addLine(to: CGPoint(x: w, y: h))

        // Mirrored fillet back down into the body's bottom edge.
        path.addCurve(
            to: CGPoint(x: w - fw, y: h - f),
            control1: CGPoint(x: w, y: h - f * k),
            control2: CGPoint(x: w - fw * (1 - k), y: h - f)
        )

        // Body's flat bottom edge, right to left.
        path.addLine(to: CGPoint(x: r, y: h - f))

        // The two convex corners. Round ends draw them as circular arcs —
        // see `DockLayout.cornerRadius` for why not a squircle — each
        // starting at the tangent point the path is already on: bottom edge
        // round to the left edge, then left edge round to the top one.
        // Softened ends sample a superellipse instead, which is the shape
        // Pulse shipped with.
        if PanelMetrics.usesRoundEnds {
            path.addArc(
                tangent1End: CGPoint(x: 0, y: h - f),
                tangent2End: CGPoint(x: 0, y: f),
                radius: r
            )

            // Left edge.
            path.addLine(to: CGPoint(x: 0, y: f + r))

            path.addArc(
                tangent1End: CGPoint(x: 0, y: f),
                tangent2End: CGPoint(x: w, y: f),
                radius: r
            )
        } else {
            // Bottom-left corner: starts directly below the corner's center
            // and ends directly to its left.
            appendCorner(
                to: &path,
                center: CGPoint(x: r, y: h - f - r),
                radius: r,
                from: CGVector(dx: 0, dy: 1),
                to: CGVector(dx: -1, dy: 0)
            )

            // Left edge.
            path.addLine(to: CGPoint(x: 0, y: f + r))

            // Top-left corner: starts to the left of its center, ends above it.
            appendCorner(
                to: &path,
                center: CGPoint(x: r, y: f + r),
                radius: r,
                from: CGVector(dx: -1, dy: 0),
                to: CGVector(dx: 0, dy: -1)
            )
        }

        path.closeSubpath()
        return path
    }

    /// Appends a quarter of a superellipse — the continuously curved
    /// "squircle" corner macOS uses for its own rounded rectangles — rather
    /// than a circular arc.
    ///
    /// A circular arc jumps from zero curvature along the straight edge to
    /// `1/radius` the instant the corner starts. That discontinuity is what
    /// reads as the edge having been sliced off. A superellipse eases the
    /// curvature in, so the straight edge and the corner belong to the same
    /// stroke. SwiftUI exposes this as `.continuous` for plain rounded
    /// rectangles, but the berth outline has to be drawn by hand, so it is
    /// sampled here instead.
    ///
    /// Only reached while `AppSettings.usesRoundEnds` is off. With it on the
    /// corner is a half circle of half the rail, where there is no straight
    /// edge left for a superellipse to ease into.
    ///
    /// `from` and `to` are unit directions from `center` to the corner's
    /// start and end points; they must be perpendicular and axis-aligned.
    private func appendCorner(
        to path: inout Path,
        center: CGPoint,
        radius: CGFloat,
        from start: CGVector,
        to end: CGVector
    ) {
        guard radius > 0 else { return }

        for step in 1...Self.cornerSampleCount {
            let t = CGFloat(step) / CGFloat(Self.cornerSampleCount) * (.pi / 2)
            // |x/r|^n + |y/r|^n = 1, in its parametric form.
            let along = pow(cos(t), 2 / Self.squircleExponent)
            let across = pow(sin(t), 2 / Self.squircleExponent)

            path.addLine(to: CGPoint(
                x: center.x + radius * (start.dx * along + end.dx * across),
                y: center.y + radius * (start.dy * along + end.dy * across)
            ))
        }
    }

    /// Superellipse exponent. 2 would be a plain circle; 4 lands close to the
    /// squircle Apple uses, keeping the corner full while easing it into the
    /// straight edges.
    private static let squircleExponent: CGFloat = 4
    /// Enough segments that the sampled curve stays sub-pixel smooth at the
    /// sizes this rail is drawn at.
    private static let cornerSampleCount = 48
}
