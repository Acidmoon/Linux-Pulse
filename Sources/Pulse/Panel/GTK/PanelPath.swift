#if !canImport(SwiftUI)
import Foundation

/// The parts of `SwiftUI.Path` that the rail's shapes are written in.
///
/// **A fourth place where a name is all that stood between upstream's code and
/// Linux**, after `Color`, the CoreGraphics geometry and `BotMarkFrame`. The
/// notch berth, the floating berth, the alert cue and the hover card are all
/// `Shape` types whose `path(in:)` is arithmetic over `CGRect` — 261 lines
/// between them, and the most recognisable thing about the rail. They were
/// excluded on the reading that a `Shape` is SwiftUI; a `Shape` is a function
/// from a rectangle to a path.
///
/// Measured first, as with everything else here: across those four files the
/// whole of the `Path` API they use is `move`, `addLine`, `addCurve`,
/// `addArc` (two forms), `addPath`, `closeSubpath`, `applying` and four
/// initializers. That is the list below.
///
/// `Path` holds the same `PathCommand` list `CGPath` does, so a shape's outline
/// goes to the canvas through `PanelRenderer.emit` with nothing in between —
/// there is no second geometry to keep in step.
struct Path {
    private(set) var commands: [PathCommand]

    init() { commands = [] }

    init(_ path: CGPath) { commands = path.commands }

    init(ellipseIn rect: CGRect) {
        commands = CGPath(ellipseIn: rect, transform: nil).commands
    }

    init(roundedRect rect: CGRect, cornerRadius: Double) {
        commands = CGPath(roundedRect: rect, cornerWidth: cornerRadius,
                          cornerHeight: cornerRadius, transform: nil).commands
    }

    /// `style` is the one place this is not exact. `.circular` is circular
    /// arcs, and `.continuous` is the superellipse Apple draws — sampled with
    /// the same exponent and sample count `DockBerthShape` already uses for its
    /// own softened corners, rather than being approximated by the circular
    /// case. `DockBerthShape` is the reference for what that shape is, and this
    /// agrees with it rather than with a guess.
    init(roundedRect rect: CGRect, cornerSize: CGSize, style: RoundedCornerStyle) {
        switch style {
        case .circular:
            commands = CGPath(roundedRect: rect, cornerWidth: cornerSize.width,
                              cornerHeight: cornerSize.height, transform: nil).commands
        case .continuous:
            commands = Path.superellipse(in: rect, cornerWidth: cornerSize.width,
                                         cornerHeight: cornerSize.height)
        }
    }

    mutating func move(to point: CGPoint) { commands.append(.move(to: point)) }
    mutating func addLine(to point: CGPoint) { commands.append(.line(to: point)) }

    mutating func addCurve(to point: CGPoint, control1: CGPoint, control2: CGPoint) {
        commands.append(.curve(control1: control1, control2: control2, to: point))
    }

    mutating func addQuadCurve(to point: CGPoint, control: CGPoint) {
        commands.append(.quadCurve(control: control, to: point))
    }

    mutating func addArc(center: CGPoint, radius: Double,
                         startAngle: Double, endAngle: Double, clockwise: Bool) {
        commands.append(.arc(centre: center, radius: radius,
                             start: startAngle, end: endAngle, clockwise: clockwise))
    }

    /// The corner-rounding arc: from wherever the path is now, an arc of
    /// `radius` tangent to the line through the current point and
    /// `tangent1End`, and to the line through `tangent1End` and `tangent2End`.
    ///
    /// **Not an arc through those points**, which is the mistake to avoid here
    /// — they name the *corner being rounded off*, and the arc cuts it. The
    /// construction is the standard one: the tangent points are `r / tan(θ/2)`
    /// from the corner along each line, and the centre is `r / sin(θ/2)` along
    /// the bisector. Where the two lines are collinear there is no corner to
    /// round and the correct output is a straight line to `tangent1End`.
    mutating func addArc(tangent1End: CGPoint, tangent2End: CGPoint, radius: Double) {
        guard let start = lastPoint else { return }
        let toCorner = CGPoint(x: tangent1End.x - start.x, y: tangent1End.y - start.y)
        let fromCorner = CGPoint(x: tangent2End.x - tangent1End.x, y: tangent2End.y - tangent1End.y)
        let incoming = Path.normalized(toCorner)
        let outgoing = Path.normalized(fromCorner)
        guard let incoming, let outgoing else {
            addLine(to: tangent1End)
            return
        }

        // The interior angle at the corner, between the reversed incoming
        // direction and the outgoing one.
        let cosine = max(-1, min(1, -incoming.x * outgoing.x - incoming.y * outgoing.y))
        let angle = acos(cosine)

        // Collinear, or so nearly so that the tangent length would be
        // unbounded. Both directions being equal is a straight continuation;
        // being opposite is a doubling back, which no radius can round.
        guard angle > 1e-9, abs(Double.pi - angle) > 1e-9, radius > 0 else {
            addLine(to: tangent1End)
            return
        }

        let tangentDistance = radius / tan(angle / 2)
        let firstTangent = CGPoint(x: tangent1End.x - incoming.x * tangentDistance,
                                   y: tangent1End.y - incoming.y * tangentDistance)
        let secondTangent = CGPoint(x: tangent1End.x + outgoing.x * tangentDistance,
                                    y: tangent1End.y + outgoing.y * tangentDistance)

        let bisector = Path.normalized(CGPoint(x: outgoing.x - incoming.x,
                                               y: outgoing.y - incoming.y)) ?? outgoing
        let centreDistance = radius / sin(angle / 2)
        let centre = CGPoint(x: tangent1End.x + bisector.x * centreDistance,
                             y: tangent1End.y + bisector.y * centreDistance)

        let startAngle = atan2(firstTangent.y - centre.y, firstTangent.x - centre.x)
        let endAngle = atan2(secondTangent.y - centre.y, secondTangent.x - centre.x)

        // The short way, which is the arc that stays inside the corner. With y
        // down, increasing angle is clockwise on screen.
        var sweep = (endAngle - startAngle).truncatingRemainder(dividingBy: 2 * .pi)
        if sweep < 0 { sweep += 2 * .pi }
        let clockwise = sweep <= .pi

        addLine(to: firstTangent)
        commands.append(.arc(centre: centre, radius: radius,
                             start: startAngle,
                             end: clockwise ? startAngle + sweep : startAngle - (2 * .pi - sweep),
                             clockwise: clockwise))
    }

    mutating func addPath(_ other: Path) { commands.append(contentsOf: other.commands) }
    mutating func closeSubpath() { commands.append(.close) }

    /// Used by `DockBerthShape` and `UsageBubbleShape`, which draw one shape and
    /// then put it somewhere: mirroring and turning the finished outline is
    /// exact because the outline carries no text and no asymmetric detail.
    func applying(_ transform: CGAffineTransform) -> Path {
        var transform = transform
        return Path(CGPath(commands: commands).copy(using: &transform) ?? CGPath(commands: commands))
    }

    /// What the canvas draws. No conversion — the commands are the same ones.
    var cgPath: CGPath { CGPath(commands: commands) }

    private var lastPoint: CGPoint? {
        for command in commands.reversed() {
            if let point = command.trailingPoint { return point }
        }
        return nil
    }

    private static func normalized(_ vector: CGPoint) -> CGPoint? {
        let length = (vector.x * vector.x + vector.y * vector.y).squareRoot()
        guard length > 1e-12 else { return nil }
        return CGPoint(x: vector.x / length, y: vector.y / length)
    }

    /// Apple's continuous corners, as `DockBerthShape` builds its own softened
    /// ends: |x/r|^n + |y/r|^n = 1 with n = 4, sampled finely enough that the
    /// curve is sub-pixel at the sizes the panel draws.
    private static func superellipse(in rect: CGRect, cornerWidth: Double,
                                    cornerHeight: Double) -> [PathCommand] {
        let exponent = 4.0
        let samples = 48
        let rx = min(cornerWidth, rect.width / 2)
        let ry = min(cornerHeight, rect.height / 2)
        guard rx > 0, ry > 0 else {
            return CGPath(roundedRect: rect, cornerWidth: 0, cornerHeight: 0,
                          transform: nil).commands
        }

        /// One corner, from `start` to `end` around `centre`, in the direction
        /// the outline runs.
        func corner(centre: CGPoint, start: CGPoint, end: CGPoint) -> [PathCommand] {
            var out: [PathCommand] = []
            for step in 0...samples {
                let t = Double(step) / Double(samples) * (.pi / 2)
                let along = pow(cos(t), 2 / exponent)
                let across = pow(sin(t), 2 / exponent)
                out.append(.line(to: CGPoint(x: centre.x + rx * (start.x * along + end.x * across),
                                             y: centre.y + ry * (start.y * along + end.y * across))))
            }
            return out
        }

        var out: [PathCommand] = []
        // Clockwise from the top-right corner: right edge down, bottom edge
        // left, left edge up, top edge right — the same winding as the circular
        // case, which matters because the rail and its flare share one fill.
        out.append(.move(to: CGPoint(x: rect.maxX - rx, y: rect.minY)))
        out.append(contentsOf: corner(centre: CGPoint(x: rect.maxX - rx, y: rect.minY + ry),
                                     start: CGPoint(x: 1, y: -1), end: CGPoint(x: 1, y: 1)))
        out.append(.line(to: CGPoint(x: rect.maxX, y: rect.maxY - ry)))
        out.append(contentsOf: corner(centre: CGPoint(x: rect.maxX - rx, y: rect.maxY - ry),
                                     start: CGPoint(x: 1, y: 1), end: CGPoint(x: -1, y: 1)))
        out.append(.line(to: CGPoint(x: rect.minX + rx, y: rect.maxY)))
        out.append(contentsOf: corner(centre: CGPoint(x: rect.minX + rx, y: rect.maxY - ry),
                                     start: CGPoint(x: -1, y: 1), end: CGPoint(x: -1, y: -1)))
        out.append(.line(to: CGPoint(x: rect.minX, y: rect.minY + ry)))
        out.append(contentsOf: corner(centre: CGPoint(x: rect.minX + rx, y: rect.minY + ry),
                                     start: CGPoint(x: -1, y: -1), end: CGPoint(x: 1, y: -1)))
        out.append(.close)
        return out
    }
}

/// Which kind of corner. Both are used upstream and they are different shapes:
/// the rail's ends are circular when they are round and superelliptical when
/// they are softened, and the hover card is always the soft one.
enum RoundedCornerStyle: Sendable {
    case circular
    case continuous
}

/// A function from a rectangle to a path.
///
/// Only `path(in:)` is required. Upstream's shapes declare `animatableData` as
/// well, and they can: swift's `Animatable` is a SwiftUI protocol that the
/// Linux build has no use for, and a type may have a property no protocol asks
/// for. Requiring it here would be inventing a protocol to match a framework
/// rather than to match the shapes.
protocol Shape {
    func path(in rect: CGRect) -> Path
}

extension PathCommand {
    /// The point a command leaves the pen at, for `addArc(tangent1End:…)`, which
    /// needs to know where the outline currently is.
    fileprivate var trailingPoint: CGPoint? {
        switch self {
        case .move(let point), .line(let point): return point
        case .quadCurve(_, let point), .curve(_, _, let point): return point
        case .arc(let centre, let radius, _, let end, _):
            return CGPoint(x: centre.x + radius * cos(end), y: centre.y + radius * sin(end))
        case .close: return nil
        }
    }
}

#endif
