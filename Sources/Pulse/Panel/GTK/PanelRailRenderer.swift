#if !canImport(AppKit)
import Foundation

/// The rail: its silhouette, its rings and their figures.
///
/// **A port of `UsageDockView` and `UsageRingView`, and the numbers are theirs.**
/// Every dimension below is a `DockLayout` member rather than a literal, so the
/// rail's width, its step, its ring size, its line weights, its end padding and
/// the rule about whether a ring carries a label at all are upstream's — and
/// upstream's `RailGeometryTests` checks them here.
///
/// What is re-derived is the *placement*: upstream asks SwiftUI for a `VStack`
/// with a spacing and a padding, and the rings land where it puts them. Cairo
/// has no stack, so this walks the same arithmetic the hit test walks —
/// `firstRingAlong` plus `index * ringStep` across, `ringCentreAcross` along —
/// which is the one placement upstream itself asserts must agree with the
/// drawing rather than merely matching it.
@MainActor
enum PanelRailRenderer {
    /// The disc's own margin: the ring's stroke is inset by this plus half its
    /// width, and the mark is sized from what is left.
    private static let centreGap: Double = 4
    /// The mark is drawn larger than the disc it sits on, which is upstream's
    /// choice and gives the character room to morph into shapes wider than a
    /// circle.
    private static let botScale: Double = 1.4
    /// What the disc gives up a side when a second ring is drawn.
    private static let secondRingSqueeze: Double = 2
    /// The logo's share of the disc. `UsageRingView`'s own constant.
    private static let iconScale: Double = 0.8
    /// A ring with no reading dims its logo rather than hiding it, so the rail
    /// says at a glance which providers it actually has data for.
    private static let logoWithoutReading: Double = 0.35
    /// The track behind every arc, at this much of the primary colour.
    private static let trackOpacity: Double = 0.18
    /// The clock arc, measured out from the ring's outer edge.
    private static let clockGap: Double = 3
    private static let clockLineWidth: Double = 2
    private static let clockOpacity: Double = 0.35

    /// Draws the whole rail into `canvas`, which is the panel's own surface:
    /// the origin is the panel's top-left corner, not the rail's.
    static func draw(_ entries: [RailEntry], model: PanelModel,
                     into canvas: PanelCanvas, size: CGSize) {
        let edge = model.edge
        let railSize = model.railSize
        // The rail sits inside the window, which is larger — the card unfolds
        // into the difference, and a window pushed back onto the screen moves
        // the rail relative to it. So the origin comes from the placement
        // rather than being recomputed here: `PanelHitArea.rail` is the same
        // arithmetic but does not know where the window actually landed.
        let rail = CGRect(origin: model.railOrigin, size: railSize)

        // The berth: upstream's silhouette, drawn in the rect the rail occupies.
        //
        // **`path(in:)` is handed a rect at the origin, and the canvas is moved
        // instead.** `Shape.path(in:)` is SwiftUI's, and upstream's shapes read
        // it the way SwiftUI does — as the view's own frame, with `rect.width`
        // and `rect.height` and coordinates measured from `(0, 0)`. They do not
        // add `rect.minX`, because in SwiftUI there is nothing to add. Passing
        // the rail's real rect produced a silhouette at the panel's top-left
        // corner with the rings somewhere else entirely, which is what the first
        // render looked like.
        canvas.save()
        canvas.translate(x: rail.minX, y: rail.minY)
        let berth = DockBerthShape(edge: edge, isDocked: model.isDocked, openness: 1)
        canvas.emit(berth.path(in: CGRect(origin: .zero, size: railSize)).cgPath)
        canvas.fill(.black, opacity: 1)
        canvas.restore()

        for (index, entry) in entries.enumerated() {
            let centre = ringCentre(index, in: rail, edge: edge, docked: model.isDocked)
            drawRing(entry, index: index, model: model, centre: centre, canvas: canvas)
        }
    }

    /// Where a ring's centre sits, in the panel's own space. The same sum the
    /// hit test steps along.
    static func ringCentre(_ index: Int, in rail: CGRect, edge: PanelEdge, docked: Bool) -> CGPoint {
        let along = rail.minY + DockLayout.firstRingAlong(docked: docked, on: edge.axis)
            + Double(index) * DockLayout.ringStep(on: edge.axis)
        let across = rail.minX + DockLayout.ringCentreAcross(on: edge.axis)
        return CGPoint(x: across, y: along)
    }

    private static func drawRing(_ entry: RailEntry, index: Int, model: PanelModel,
                                 centre: CGPoint, canvas: PanelCanvas) {
        let diameter = DockLayout.ringDiameter
        let lineWidth = DockLayout.ringLineWidth
        let radius = diameter / 2

        let spent = UsageTint.isSpent(entry.headline) || (entry.headline?.usedFraction ?? 0) >= 1
        let used = min(max(entry.headline?.usedFraction ?? 0, 0), 1)

        // **No reading draws nothing, either way round.** A provider that has
        // not answered — the first seconds after launch, one signed out, one
        // waiting on a key — must not draw a complete ring, and an empty track
        // is what "nothing known" looks like. Upstream measured that failure by
        // sampling the rendered circumference; this keeps the rule rather than
        // the measurement.
        let fraction: Double = entry.headline == nil
            ? 0
            : (spent || used >= 1 ? 1 : (entry.showsRemaining ? 1 - used : used))

        let automatic = UsageTint.color(for: used, isExhausted: spent,
                                        warningAt: UsageTint.warningThreshold)
        // Spent is the one state a chosen colour does not get to hide.
        let colour = (entry.tint != nil && !spent) ? entry.tint! : automatic

        // The track first, so every arc sits in it.
        canvas.save()
        canvas.newSubPath()
        canvas.arc(centre: centre, radius: radius, start: 0, end: 2 * .pi, clockwise: true)
        canvas.stroke(.primary, opacity: trackOpacity, width: lineWidth)

        // The second ring, inside the first and thinner, before the disc is
        // drawn over its middle.
        if let second = entry.second {
            let secondSpent = UsageTint.isSpent(second)
            let secondUsed = min(max(second.usedFraction, 0), 1)
            let secondShown = entry.showsRemaining && !secondSpent ? 1 - secondUsed : secondUsed
            let secondColour = (entry.tint != nil && !secondSpent)
                ? entry.tint!
                : UsageTint.color(for: secondUsed, isExhausted: secondSpent,
                                  warningAt: UsageTint.warningThreshold)
            let secondRadius = DockLayout.secondRingDiameter / 2
            canvas.newSubPath()
            canvas.arc(centre: centre, radius: secondRadius, start: 0, end: 2 * .pi, clockwise: true)
            canvas.stroke(.primary, opacity: trackOpacity, width: DockLayout.secondRingLineWidth)
            canvas.newSubPath()
            canvas.arc(centre: centre, radius: secondRadius,
                       start: -Double.pi / 2,
                       end: -Double.pi / 2 + 2 * .pi * (secondSpent ? 1 : max(secondShown, 0)),
                       clockwise: true)
            canvas.stroke(secondColour, opacity: 1, width: DockLayout.secondRingLineWidth)
        }

        // The reading, from twelve o'clock.
        if fraction > 0 {
            canvas.newSubPath()
            canvas.arc(centre: centre, radius: radius, start: -Double.pi / 2,
                       end: -Double.pi / 2 + 2 * .pi * fraction, clockwise: true)
            canvas.stroke(colour, opacity: entry.isRefreshing ? 0.3 : 1, width: lineWidth)
        }

        // The window clock: how much of the limit's period has run, outside the
        // ring and thinner than it.
        if let elapsed = entry.elapsed {
            let clockRadius = (diameter + lineWidth
                + (clockGap + clockLineWidth / 2) * 2) / 2
            canvas.newSubPath()
            canvas.arc(centre: centre, radius: clockRadius, start: -Double.pi / 2,
                       end: -Double.pi / 2 + 2 * .pi * min(max(elapsed, 0), 1), clockwise: true)
            canvas.stroke(.primary, opacity: clockOpacity, width: clockLineWidth)
        }

        // The disc the mark stands on, then the mark.
        let squeeze = entry.second == nil ? 0 : secondRingSqueeze * PanelMetrics.scale
        let centreDiameter = max(diameter - (lineWidth + centreGap) * 2 - squeeze * 2, 0)
        canvas.newSubPath()
        canvas.arc(centre: centre, radius: centreDiameter / 2, start: 0, end: 2 * .pi, clockwise: true)
        canvas.fill(.black, opacity: 1)
        canvas.restore()

        // The logo, or the animated mark in its place. Upstream draws one or
        // the other and never both, and the choice is per account.
        let known = entry.headline != nil || entry.figure != nil
        if !entry.showsBotMark {
            drawLogo(entry.usage.provider, into: canvas, centre: centre,
                     size: centreDiameter * iconScale,
                     opacity: known ? 1 : logoWithoutReading)
        }

        if entry.showsBotMark,
           let frame = model.frame(for: entry.id),
           let config = model.configuration(for: entry.id) {
            let extent = centreDiameter * botScale
            canvas.save()
            // The mark is drawn in its own box, so the canvas is moved to the
            // disc and the renderer's own viewBox mapping does the rest.
            canvas.translate(x: centre.x - extent / 2, y: centre.y - extent / 2)
            PanelRenderer.draw(frame, config: config, into: canvas,
                               width: extent, height: extent)
            canvas.restore()
        }

        // The figure, above or below the ring on a setting.
        guard DockLayout.showsPercentages(on: model.edge.axis) else { return }
        let figure = entry.headline?.percentText(remaining: entry.showsRemaining)
            ?? entry.figure ?? "—"
        let figureColour: Color = spent ? .pulseExhausted : .primary
        let figureOpacity = spent ? 1 : (known ? (entry.isRefreshing ? 0.3 : 1) : 0.4)
        // The label's own centre, half its line height clear of the ring — the
        // same `ringToTextSpacing` the stack uses, so the figure sits where a
        // `VStack` would have put it.
        let offset = radius + DockLayout.ringToTextSpacing + DockLayout.percentFontSize / 2
        let labelCentre = CGPoint(x: centre.x,
                                  y: DockLayout.labelLeads ? centre.y - offset : centre.y + offset)
        canvas.text(figure, centre: labelCentre,
                    size: DockLayout.percentFontSize, colour: figureColour,
                    opacity: figureOpacity, bold: false)
    }
}


extension PanelRailRenderer {
    /// A provider's mark, drawn as a template: one fill, one colour, and only
    /// the outline matters.
    ///
    /// `SVGIcon` parses it into the same commands everything else here draws
    /// with, so this is the scaling and nothing more — the icon is fitted into
    /// a square of `size` about `centre`, the way `.resizable().scaledToFit()`
    /// does on a Mac. A missing icon draws a question mark rather than nothing,
    /// which is upstream's fallback and is how a broken resource shows up.
    private static func drawLogo(_ provider: Provider, into canvas: PanelCanvas,
                                 centre: CGPoint, size: Double, opacity: Double) {
        guard let icon = SVGIcon.icon(named: provider.iconResource) else {
            canvas.text("?", centre: centre, size: size * 0.9, colour: .primary,
                        opacity: opacity * 0.5, bold: false)
            return
        }
        let scale = min(size / icon.viewBox.width, size / icon.viewBox.height)
        let drawn = CGSize(width: icon.viewBox.width * scale, height: icon.viewBox.height * scale)

        canvas.save()
        // The viewBox's own origin taken out too, so an icon whose box does not
        // start at zero lands centred rather than offset by its own margin.
        let origin = CGPoint(x: centre.x - drawn.width / 2,
                             y: centre.y - drawn.height / 2)
        canvas.translate(x: origin.x - icon.viewBox.minX * scale,
                         y: origin.y - icon.viewBox.minY * scale)

        // **Clipped to the viewBox, which is what an SVG viewport does.** Not a
        // precaution: `kiro.svg` draws to y = -2.2 and y = 25.5 in a 24-unit box
        // — measured while writing the test that assumed none of them did — and
        // a renderer that does not clip draws a shape that spills out of the
        // ring. Upstream gets this for free from `NSImage`.
        canvas.setFillRule(evenOdd: true)
        canvas.emit(CGPath(commands: [
            .move(to: icon.viewBox.origin),
            .line(to: CGPoint(x: icon.viewBox.maxX, y: icon.viewBox.minY)),
            .line(to: CGPoint(x: icon.viewBox.maxX, y: icon.viewBox.maxY)),
            .line(to: CGPoint(x: icon.viewBox.minX, y: icon.viewBox.maxY)),
            .close,
        ]), transform: CGAffineTransform(scaleX: scale, y: scale))
        canvas.clip()
        canvas.newPath()

        canvas.setFillRule(evenOdd: icon.evenOdd)
        canvas.emit(CGPath(commands: icon.commands),
                    transform: CGAffineTransform(scaleX: scale, y: scale))
        canvas.fill(.primary, opacity: opacity)
        canvas.restore()
        // Put back, because the mark's outlines want the nonzero rule and the
        // icons want the other one.
        canvas.setFillRule(evenOdd: false)
    }
}
#endif
