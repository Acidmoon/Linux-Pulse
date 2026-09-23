#if !canImport(AppKit)
import Foundation

/// Drawing a `BotMarkFrame`, a rail and a ring, through a `PanelCanvas`.
///
/// **The port of `BotMarkView.drawBotMark`, and deliberately a literal one.**
/// The upstream function is sixty lines and every line of it is a decision
/// somebody made about how the mark looks: the viewBox mapping, the layer
/// order, that morph parts take the body's colour, that a stroke width is
/// scaled with the rest, that the eyes are clipped to the head so a lean cannot
/// spill them past the silhouette, that the badge is drawn last and in the eye
/// colour. None of that is discoverable from the frame alone, and none of it is
/// re-derived here.
///
/// The calls are in the same order and take the same arguments as upstream's, so
/// the two can be read side by side. `context.fill(Path(path), with: .color(c))`
/// is `canvas.emit(path)` then `canvas.fill(c, opacity:)`.
enum PanelRenderer {
    // MARK: - The mark

    static func draw(_ frame: BotMarkFrame, config: BotMarkConfig,
                     into canvas: PanelCanvas, width: Double, height: Double) {
        let extent = min(width, height)
        let scale = extent / (frame.viewBoxRadius * 2)
        let origin = BotMarkFrame.viewBoxCentre - frame.viewBoxRadius

        // `scale` then `translate`, which under CoreGraphics' composition is
        // `(point - origin) * scale` — the upstream viewBox mapped onto the
        // surface. The composition order matters and is the one thing here that
        // a reader is most likely to get backwards; see
        // `DrawingCompat.translatedBy`.
        let base = CGAffineTransform(scaleX: scale, y: scale)
            .translatedBy(x: -origin, y: -origin)

        paint(frame.backParticles, config: config, into: canvas, base: base)

        // Morph parts and humming markers sit under the character and take the
        // body's colour, as the upstream layers them.
        for shape in frame.shapes {
            canvas.emit(shape.path, transform: base)
            if let strokeWidth = shape.strokeWidth {
                canvas.stroke(config.color, opacity: shape.opacity, width: strokeWidth * scale)
            } else {
                canvas.fill(config.color, opacity: shape.opacity)
            }
        }

        var combined = frame.transform.concatenating(base)
        guard let headPath = frame.headPath.copy(using: &combined) else { return }

        canvas.emit(headPath)
        canvas.fillKeepingPath(config.color, opacity: frame.opacity)

        // `eyeLayer.clip(to: head)`. The head path is still current from the
        // fill above, so the clip costs no second emission.
        canvas.save()
        canvas.clip()
        for eye in frame.eyes where eye.visible {
            var eyeTransform = eye.transform.concatenating(combined)
            guard let path = eye.path.copy(using: &eyeTransform) else { continue }
            canvas.emit(path)
            canvas.fill(config.eyeColor, opacity: frame.opacity)
        }
        canvas.restore()
        canvas.newPath()

        paint(frame.frontParticles, config: config, into: canvas, base: base)

        if let badge = frame.badge {
            let radius = badge.radius * config.badgeScale
            let rect = CGRect(x: badge.centre.x - radius, y: badge.centre.y - radius,
                              width: radius * 2, height: radius * 2)
            canvas.emit(CGPath(ellipseIn: rect, transform: nil), transform: combined)
            // Stroke first, keeping the path, then fill it — which is what
            // makes the ring read as an outline around the badge rather than
            // an outline under it.
            canvas.stroke(config.eyeColor, opacity: frame.opacity, width: 10 * scale)
            canvas.emit(CGPath(ellipseIn: rect, transform: nil), transform: combined)
            canvas.fill(config.badgeColor, opacity: frame.opacity)
        }
    }

    /// Back particles and front particles, which differ only in when they are
    /// drawn. A particle carries its own colour, and a ribbon carries five stops
    /// of it along the segment's own axis.
    private static func paint(_ items: [BotMarkFrame.Painted], config: BotMarkConfig,
                              into canvas: PanelCanvas, base: CGAffineTransform) {
        for item in items {
            var transform = base
            guard let path = item.path.copy(using: &transform) else { continue }
            canvas.emit(path)
            switch item.paint {
            case .solid(let colour):
                canvas.fill(colour, opacity: item.opacity)
            case .gradient(let stops, let from, let to):
                // The endpoints are in the frame's unit space like everything
                // else, so they go through the same mapping the path did.
                canvas.fillGradient(stops,
                                    from: from.applying(transform),
                                    to: to.applying(transform),
                                    opacity: item.opacity)
            }
        }
    }
}

// MARK: - Paths

extension PanelCanvas {
    /// Emits a `CGPath`, with `transform` applied to every point.
    ///
    /// Cairo has three path verbs and the frame's command list has six, so two
    /// are converted rather than passed through:
    ///
    ///   - **A quadratic becomes a cubic**, which is exact: a quadratic is the
    ///     cubic whose control points sit two-thirds of the way from each
    ///     endpoint towards the quadratic's control point.
    ///   - **An arc is passed on** as an arc, because the backend already has
    ///     one and its angle convention is the frame's own — see `arc(centre:…)`.
    func emit(_ path: CGPath, transform: CGAffineTransform = .identity) {
        var pen = CGPoint.zero
        for command in path.commands {
            switch command {
            case .move(let point):
                let moved = transform.transform(point)
                move(to: moved)
                pen = moved
            case .line(let point):
                let moved = transform.transform(point)
                line(to: moved)
                pen = moved
            case .quadCurve(let control, let point):
                let start = pen
                let quadratic = transform.transform(control)
                let end = transform.transform(point)
                curve(to: end,
                      control1: CGPoint(x: start.x + 2.0 / 3.0 * (quadratic.x - start.x),
                                        y: start.y + 2.0 / 3.0 * (quadratic.y - start.y)),
                      control2: CGPoint(x: end.x + 2.0 / 3.0 * (quadratic.x - end.x),
                                        y: end.y + 2.0 / 3.0 * (quadratic.y - end.y)))
                pen = end
            case .curve(let control1, let control2, let point):
                curve(to: transform.transform(point),
                      control1: transform.transform(control1),
                      control2: transform.transform(control2))
                pen = transform.transform(point)
            case .arc(let centre, let radius, let start, let end, let clockwise):
                let middle = transform.transform(centre)
                // Uniform scale, which is every transform the panel applies to a
                // mark: the viewBox mapping scales both axes by the same factor.
                let scale = (abs(transform.a) + abs(transform.d)) / 2
                arc(centre: middle, radius: radius * scale,
                    start: start, end: end, clockwise: clockwise)
                pen = CGPoint(x: middle.x + radius * scale * cos(end),
                              y: middle.y + radius * scale * sin(end))
            case .close:
                close()
            }
        }
    }
}
#endif
