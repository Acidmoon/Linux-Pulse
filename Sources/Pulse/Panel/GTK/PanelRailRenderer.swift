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
    /// The travelling mark that says a CLI is working: a white arc inside the
    /// ring, going round once a second.
    ///
    /// **Inside the ring, and white.** Upstream is explicit about both: colour
    /// on the ring itself means one thing — how much of the limit is gone — and
    /// a white arc laid over it would cover the answer while claiming to be
    /// about something else. And it goes round rather than sitting still, which
    /// is the only thing on the rail that moves on its own.
    private static let busySweep: Double = 0.22
    private static let busyPeriod: Double = 1.0

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
        let openness = min(max(model.railOpenness, 0), 1)

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
        // **The silhouette morphs rather than being swapped.** `openness` is
        // the shape's own parameter: at 0 the flare is gone and the corner
        // radius is the whole width, which is exactly the rounded-on-one-side
        // sliver. That is why the collapsed and expanded states can be animated
        // between as one object — upstream says so at length on the shape.
        //
        // The rect animates with it, because the shape's frame is what changes
        // size: `isExpanded ? railSize : collapsedSize`, on the same spring.
        let collapsed = DockLayout.collapsedSize(on: edge.axis)
        let current = CGSize(
            width: collapsed.width + (railSize.width - collapsed.width) * openness,
            height: collapsed.height + (railSize.height - collapsed.height) * openness)
        // Centred on the rail's own band, which is where the open rail sits.
        let berthRect = CGRect(x: rail.minX + (rail.width - current.width) * (edge.isLeft ? 0 : 1),
                               y: rail.midY - current.height / 2,
                               width: current.width, height: current.height)

        canvas.save()
        canvas.translate(x: berthRect.minX, y: berthRect.minY)
        let berth = DockBerthShape(edge: edge, isDocked: model.isDocked, openness: openness)
        canvas.emit(berth.path(in: CGRect(origin: .zero, size: current)).cgPath)
        // **Black, or the colour of the worst limit while the rail is shut.**
        // Upstream's `PanelSurface(tint: isExpanded ? nil : alert)`: a shut rail
        // is a sliver against the edge with no other way to say anything.
        canvas.fill(openness < 0.5 ? (model.alertTint ?? .black) : .black, opacity: 1)
        canvas.restore()

        // **The rings arrive into the opening berth.** Upstream fades them in
        // on a delay behind the spring, so the silhouette is most of the way
        // there before anything is drawn on it.
        let ringsOpacity = model.ringsOpacity
        guard ringsOpacity > 0.01 else { return }

        for (index, entry) in entries.enumerated() {
            let centre = ringCentre(index, in: rail, edge: edge, docked: model.isDocked)
            drawRing(entry, centre: centre, opacity: ringsOpacity,
                     isSelected: model.selectedSlot == entry.id,
                     animatesActivity: model.animatesActivity,
                     axis: edge.axis,
                     frame: model.frame(for: entry.id),
                     config: model.configuration(for: entry.id),
                     canvas: canvas)
        }

        // **The card last, so its tail laps over the rail's edge.** Upstream
        // layers it the same way: the bubble is drawn with the body and the tail
        // as one path, and the two only read as one silhouette if nothing is
        // painted over the join.
        if let selected = model.selectedSlot,
           let index = entries.firstIndex(where: { $0.id == selected }) {
            PanelCardRenderer.draw(entries[index], index: index, model: model, into: canvas)
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

    /// One ring, with everything it needs passed in rather than read off the
    /// model.
    ///
    /// **Split out so it can be driven without a store.** A ring is a function
    /// of its entry, its centre, its opacity and whether it is the one under the
    /// pointer — and a test that has to build a `PanelModel` (which reads the
    /// machine's real settings) to find out whether the working mark is drawn is
    /// a test that says different things on different machines.
    static func drawRing(_ entry: RailEntry, centre: CGPoint, opacity: Double,
                         isSelected: Bool, animatesActivity: Bool,
                         axis: PanelEdge.Axis = .vertical,
                         frame: BotMarkFrame?, config: BotMarkConfig?,
                         canvas: PanelCanvas) {
        // How far round the working mark has travelled. Read from the clock
        // rather than accumulated, so a dropped frame does not slow it down —
        // upstream gets this from Core Animation, which is the same idea.
        let busyPhase = Date().timeIntervalSinceReferenceDate
        let busyAnimates = animatesActivity
        let diameter = DockLayout.ringDiameter
        let lineWidth = DockLayout.ringLineWidth
        // **The ring under the pointer grows in place.** `scaleEffect(1.06)`
        // on a SwiftUI view scales about its own centre, so the ring on the
        // rail does not move — it is the same centre with a larger radius, and
        // the mark inside it scales with it. The figure below does not, which is
        // why the label is drawn outside this.
        let scale = isSelected ? 1.06 : 1
        let radius = diameter / 2 * scale

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
        // **The halo, before anything else on the ring.** Upstream draws it as
        // a shadow cast by the arc — `.shadow(color: arcColour.opacity(0.42),
        // radius: 10)` — and Cairo has no blur, so it is approximated with
        // three increasingly wide and faint strokes of the same colour. A real
        // gaussian would be better and would need a filter; at 36 points across
        // the difference is not visible.
        if isSelected {
            canvas.newSubPath()
            canvas.arc(centre: centre, radius: radius, start: 0, end: 2 * .pi, clockwise: true)
            for (width, alpha) in [(lineWidth + 4, 0.18), (lineWidth + 8, 0.10)] {
                canvas.newSubPath()
                canvas.arc(centre: centre, radius: radius, start: 0, end: 2 * .pi, clockwise: true)
                canvas.stroke(colour, opacity: alpha * opacity, width: width)
            }
        }

        canvas.newSubPath()
        canvas.arc(centre: centre, radius: radius, start: 0, end: 2 * .pi, clockwise: true)
        canvas.stroke(.primary, opacity: trackOpacity * opacity, width: lineWidth)

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
            canvas.stroke(.primary, opacity: trackOpacity * opacity,
                          width: DockLayout.secondRingLineWidth)
            canvas.newSubPath()
            canvas.arc(centre: centre, radius: secondRadius,
                       start: -Double.pi / 2,
                       end: -Double.pi / 2 + 2 * .pi * (secondSpent ? 1 : max(secondShown, 0)),
                       clockwise: true)
            canvas.stroke(secondColour, opacity: opacity, width: DockLayout.secondRingLineWidth)
        }

        // The reading, from twelve o'clock.
        if fraction > 0 {
            canvas.newSubPath()
            canvas.arc(centre: centre, radius: radius, start: -Double.pi / 2,
                       end: -Double.pi / 2 + 2 * .pi * fraction, clockwise: true)
            canvas.stroke(colour, opacity: opacity * (entry.isRefreshing ? 0.3 : 1),
                          width: lineWidth)
        }

        // The window clock: how much of the limit's period has run, outside the
        // ring and thinner than it.
        if let elapsed = entry.elapsed {
            let clockRadius = (diameter + lineWidth
                + (clockGap + clockLineWidth / 2) * 2) / 2
            canvas.newSubPath()
            canvas.arc(centre: centre, radius: clockRadius, start: -Double.pi / 2,
                       end: -Double.pi / 2 + 2 * .pi * min(max(elapsed, 0), 1), clockwise: true)
            canvas.stroke(.primary, opacity: clockOpacity * opacity, width: clockLineWidth)
        }

        // The disc the mark stands on, then the mark.
        let squeeze = entry.second == nil ? 0 : secondRingSqueeze * PanelMetrics.scale
        let centreDiameter = max(diameter - (lineWidth + centreGap) * 2 - squeeze * 2, 0)
        canvas.newSubPath()
        // The travelling mark, which says "this one is working" and is the only
        // thing on the rail that moves without being asked to.
        //
        // **Not while the animated mark is playing.** The two are one fact drawn
        // twice, and the arc is the half that says nothing about which provider
        // it belongs to — so the mark keeps it and the arc goes.
        if entry.isRunning, !entry.showsBotMark, busyAnimates {
            let busiest = entry.second == nil
                ? max(diameter - lineWidth * 1.5 - centreGap, 0)
                : max(centreDiameter + secondRingSqueeze * PanelMetrics.scale, 0)
            let phase = (busyPhase.truncatingRemainder(dividingBy: busyPeriod)) / busyPeriod
            canvas.newSubPath()
            canvas.arc(centre: centre, radius: busiest / 2,
                       start: -Double.pi / 2 + 2 * .pi * phase,
                       end: -Double.pi / 2 + 2 * .pi * (phase + busySweep),
                       clockwise: true)
            canvas.stroke(.primary, opacity: opacity,
                          width: max(lineWidth * 0.5, 1.5))
        }

        canvas.arc(centre: centre, radius: centreDiameter / 2, start: 0, end: 2 * .pi, clockwise: true)
        canvas.fill(.black, opacity: opacity)
        canvas.restore()

        // The logo, or the animated mark in its place. Upstream draws one or
        // the other and never both, and the choice is per account.
        let known = entry.headline != nil || entry.figure != nil
        if !entry.showsBotMark {
            drawLogo(entry.usage.provider, into: canvas, centre: centre,
                     size: centreDiameter * iconScale,
                     opacity: opacity * (known ? 1 : logoWithoutReading))
        }

        if entry.showsBotMark, let frame, let config {
            let extent = centreDiameter * botScale
            canvas.save()
            // The mark is drawn in its own box, so the canvas is moved to the
            // disc and the renderer's own viewBox mapping does the rest.
            canvas.translate(x: centre.x - extent / 2, y: centre.y - extent / 2)
            PanelRenderer.draw(frame, config: config, into: canvas,
                               width: extent, height: extent, opacity: opacity)
            canvas.restore()
        }

        // The figure, above or below the ring on a setting.
        // Whether a ring carries a figure at all is the axis's business: down a
        // side always, across the top only when the reader has asked for it.
        guard DockLayout.showsPercentages(on: axis) else { return }
        let figure = entry.headline?.percentText(remaining: entry.showsRemaining)
            ?? entry.figure ?? "—"
        let figureColour: Color = spent ? .pulseExhausted : .primary
        let figureOpacity = opacity * (spent ? 1 : (known ? (entry.isRefreshing ? 0.3 : 1) : 0.4))
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
