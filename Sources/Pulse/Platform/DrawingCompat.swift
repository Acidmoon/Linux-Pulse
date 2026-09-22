#if !canImport(SwiftUI) && !canImport(CoreGraphics)
// The Linux drawing primitives that upstream's panel code reaches for.
//
// **This file exists so that the panel's own code can stay upstream's.** The
// BotMark animation is 4305 lines, and 3948 of them are not SwiftUI at all:
// `BotMarkEngine` (1512 lines) has no `body`, no `some View` and no `@State`,
// and neither do the morphs, the particles, the geometry or the brand table.
// What they do have is arithmetic over points, transforms and paths, and a
// `Color` — so the whole thing is reusable verbatim if those four things exist
// under Linux.
//
// Measured, not assumed, which is what makes the list this short. `import
// Foundation` on Linux already provides `CGFloat`, `CGPoint`, `CGSize` and
// `CGRect` (verified by compiling each in turn). It does **not** provide
// `CGAffineTransform`, `CGVector`, `CGPath` or `CGMutablePath`, and there is no
// `SwiftUI` at all to provide `Color`. Those five are everything below.
//
// The names are the ones the upstream sources already use, deliberately. A
// file that imports `CoreGraphics` on a Mac and finds `CGPath` here on Linux
// needs no edit to its body at all, which is the entire point: the guard goes
// on the import block and the interior still merges.
//
// **What is not here is any pretence of being CoreGraphics.** There is no
// `CGContext`, no rasteriser and no `CGColorSpace`; nothing in this file draws.
// It is the geometry upstream computes with, and the drawing happens in the
// GTK4 process that reads `BotMarkFrame` — a display list upstream already
// built for its own view (`Docs/decisions/linux-panel.md`).

import Foundation

// MARK: - Vectors and transforms

/// Only the two fields upstream reads, in `UsageDockView`'s gradient direction.
struct CGVector: Hashable, Sendable {
    var dx: Double
    var dy: Double

    init(dx: Double, dy: Double) {
        self.dx = dx
        self.dy = dy
    }
}

/// The affine matrix, in CoreGraphics' own field order and with its method
/// names, because that is the order the upstream code composes them in.
///
/// The convention matters and is the one place a quiet mistake would show up as
/// a drawing that is subtly wrong rather than as a compile error. A point is a
/// row vector: `x' = x * a + y * c + tx`, `y' = x * b + y * d + ty`. That is
/// CoreGraphics' (and CGAffineTransformMake's) convention, not the column-vector
/// one, and `transform(_:)` below is written to match it.
struct CGAffineTransform: Hashable, Sendable {
    var a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double

    static let identity = CGAffineTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.tx = tx
        self.ty = ty
    }

    init(translationX: Double, y: Double) {
        self.init(a: 1, b: 0, c: 0, d: 1, tx: translationX, ty: y)
    }

    init(scaleX: Double, y: Double) {
        self.init(a: scaleX, b: 0, c: 0, d: y, tx: 0, ty: 0)
    }

    init(rotationAngle: Double) {
        let cosine = cos(rotationAngle), sine = sin(rotationAngle)
        self.init(a: cosine, b: sine, c: -sine, d: cosine, tx: 0, ty: 0)
    }

    /// `self` then `other` — `other` is applied to the result, which is what
    /// CoreGraphics' `concatenating` means and the opposite of reading the call
    /// as "apply other first".
    func concatenating(_ other: CGAffineTransform) -> CGAffineTransform {
        CGAffineTransform(
            a: a * other.a + b * other.c,
            b: a * other.b + b * other.d,
            c: c * other.a + d * other.c,
            d: c * other.b + d * other.d,
            tx: tx * other.a + ty * other.c + other.tx,
            ty: tx * other.b + ty * other.d + other.ty
        )
    }

    /// **The translation happens in the transform's own space, not the
    /// destination's.** `tx' = tx + x·a + y·c`, which is
    /// `CGAffineTransformTranslate` and not `self * T`.
    ///
    /// The difference does not show up until there is a scale or a rotation to
    /// travel through, and then it is the whole drawing: `translate(1,1)` then
    /// `scale(2,2)` puts the origin at (2,2) here and at (1,1) under the naive
    /// reading. Upstream's own suite caught exactly this — 8744 of its
    /// assertions failed on one number, how far the mark had slid.
    func translatedBy(x: Double, y: Double) -> CGAffineTransform {
        CGAffineTransform(a: a, b: b, c: c, d: d,
                          tx: tx + x * a + y * c,
                          ty: ty + x * b + y * d)
    }

    /// `CGAffineTransformScale`: the linear part scales and **the translation
    /// does not**. So `translate(cx, cy)` then `scale(s)` scales about the
    /// point just moved to, which is the idiom the panel relies on everywhere.
    func scaledBy(x: Double, y: Double) -> CGAffineTransform {
        CGAffineTransform(a: a * x, b: b * x, c: c * y, d: d * y, tx: tx, ty: ty)
    }

    /// `CGAffineTransformRotate`, which is `Concat(R, self)` — the rotation
    /// goes **outside**, leaving the translation where it was.
    func rotated(by angle: Double) -> CGAffineTransform {
        CGAffineTransform(rotationAngle: angle).concatenating(self)
    }

    func transform(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * a + point.y * c + tx,
                y: point.x * b + point.y * d + ty)
    }

    func transform(_ rect: CGRect) -> CGRect {
        let corners = [
            transform(CGPoint(x: rect.minX, y: rect.minY)),
            transform(CGPoint(x: rect.maxX, y: rect.minY)),
            transform(CGPoint(x: rect.minX, y: rect.maxY)),
            transform(CGPoint(x: rect.maxX, y: rect.maxY)),
        ]
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!,
                      width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
}

// MARK: - Paths

/// One command of a path, kept in the order it was added.
///
/// **A command list rather than a rasterised outline**, because the two things
/// this has to serve want different things from it: a renderer wants Cairo's
/// own verbs (`move_to`, `line_to`, `curve_to`, `close_path`), and
/// `BotMarkFrame`'s measurement wants points it can transform. Both are a walk
/// over this list, and neither needs it resolved into anything else.
enum PathCommand: Hashable, Sendable {
    case move(to: CGPoint)
    case line(to: CGPoint)
    /// Kept separate from `curve` because the source is a `Q` in an SVG path
    /// and elevating it here would hide that from anyone reading a frame.
    case quadCurve(control: CGPoint, to: CGPoint)
    case curve(control1: CGPoint, control2: CGPoint, to: CGPoint)
    case arc(centre: CGPoint, radius: Double, start: Double, end: Double, clockwise: Bool)
    case close
}

/// Not `final`, and not a struct, because `CGMutablePath` subclasses it and
/// `copy(using:)` returns the base type — which is how upstream distinguishes
/// a path it may keep adding to from one it may not. A struct would make the
/// two the same type and turn that distinction into a comment.
class CGPath: Equatable {
    /// Readable so a renderer can walk it. Upstream never inspects this; it is
    /// the contract with the GTK4 process.
    ///
    /// `fileprivate(set)` rather than `private(set)`: the only writer is
    /// `CGMutablePath`, and it is in this file precisely so that no other type
    /// can be one.
    fileprivate(set) var commands: [PathCommand]

    init(commands: [PathCommand] = []) {
        self.commands = commands
    }

    /// **Approximated, not exact.** CoreGraphics makes a true ellipse out of
    /// arcs; this makes one out of four cubic Béziers, which is what every
    /// toolkit does and is not what `addArc` below does. The error is under
    /// 0.03% of the radius — a fifth of a pixel on a mark that is 100 units
    /// across — and the alternative is a command type that can carry an
    /// ellipse's two radii and a renderer that has to know about it.
    ///
    /// The `transform` is always `nil` at every call site, and is `Optional`
    /// to keep the call sites spelling it the way they already do.
    convenience init(ellipseIn rect: CGRect, transform: CGAffineTransform? = nil) {
        let cosine = 0.5522847498307936
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let rx = rect.width / 2, ry = rect.height / 2
        let ox = rx * cosine, oy = ry * cosine
        let right = CGPoint(x: centre.x + rx, y: centre.y)
        let bottom = CGPoint(x: centre.x, y: centre.y + ry)
        let left = CGPoint(x: centre.x - rx, y: centre.y)
        let top = CGPoint(x: centre.x, y: centre.y - ry)

        self.init(commands: [
            .move(to: right),
            .curve(control1: CGPoint(x: right.x, y: centre.y + oy),
                   control2: CGPoint(x: centre.x + ox, y: bottom.y), to: bottom),
            .curve(control1: CGPoint(x: centre.x - ox, y: bottom.y),
                   control2: CGPoint(x: left.x, y: centre.y + oy), to: left),
            .curve(control1: CGPoint(x: left.x, y: centre.y - oy),
                   control2: CGPoint(x: centre.x - ox, y: top.y), to: top),
            .curve(control1: CGPoint(x: centre.x + ox, y: top.y),
                   control2: CGPoint(x: right.x, y: centre.y - oy), to: right),
            .close,
        ])
    }

    /// Four lines and four quarter-turns, each turn the same cubic
    /// approximation `init(ellipseIn:)` uses. A corner radius is clamped to
    /// half the side it sits on, which is what CoreGraphics does with an
    /// over-large radius rather than letting the corners cross over.
    convenience init(roundedRect rect: CGRect, cornerWidth: Double, cornerHeight: Double,
                     transform: CGAffineTransform? = nil) {
        let cosine = 0.5522847498307936
        let rx = min(cornerWidth, rect.width / 2), ry = min(cornerHeight, rect.height / 2)
        let ox = rx * cosine, oy = ry * cosine
        var commands: [PathCommand] = []
        commands.append(.move(to: CGPoint(x: rect.minX + rx, y: rect.minY)))
        commands.append(.line(to: CGPoint(x: rect.maxX - rx, y: rect.minY)))
        commands.append(.curve(control1: CGPoint(x: rect.maxX - rx + ox, y: rect.minY),
                              control2: CGPoint(x: rect.maxX, y: rect.minY + ry - oy),
                              to: CGPoint(x: rect.maxX, y: rect.minY + ry)))
        commands.append(.line(to: CGPoint(x: rect.maxX, y: rect.maxY - ry)))
        commands.append(.curve(control1: CGPoint(x: rect.maxX, y: rect.maxY - ry + oy),
                              control2: CGPoint(x: rect.maxX - rx + ox, y: rect.maxY),
                              to: CGPoint(x: rect.maxX - rx, y: rect.maxY)))
        commands.append(.line(to: CGPoint(x: rect.minX + rx, y: rect.maxY)))
        commands.append(.curve(control1: CGPoint(x: rect.minX + rx - ox, y: rect.maxY),
                              control2: CGPoint(x: rect.minX, y: rect.maxY - ry + oy),
                              to: CGPoint(x: rect.minX, y: rect.maxY - ry)))
        commands.append(.line(to: CGPoint(x: rect.minX, y: rect.minY + ry)))
        commands.append(.curve(control1: CGPoint(x: rect.minX, y: rect.minY + ry - oy),
                              control2: CGPoint(x: rect.minX + rx - ox, y: rect.minY),
                              to: CGPoint(x: rect.minX + rx, y: rect.minY)))
        commands.append(.close)
        self.init(commands: commands)
    }

    static func == (lhs: CGPath, rhs: CGPath) -> Bool {
        lhs.commands == rhs.commands
    }

    var isEmpty: Bool { commands.isEmpty }

    /// The path under a transform. Always succeeds — CoreGraphics can return
    /// nil here, and upstream guards with `??`, so returning an optional keeps
    /// those guards meaningful on a Mac and harmless here.
    func copy(using transform: inout CGAffineTransform) -> CGPath? {
        CGPath(commands: commands.map { $0.transformed(by: transform) })
    }

    func copy() -> CGPath? {
        CGPath(commands: commands)
    }

    /// The tight box of the drawn curve, which is what CoreGraphics means by
    /// this name — as opposed to `boundingBox` below, which is the box of the
    /// control points and can be larger.
    ///
    /// **Solved, not sampled.** A curve's extent is at its endpoints or at the
    /// roots of its derivative, so those roots are what this finds: a quadratic
    /// for a quadratic segment, and the quadratic that a cubic's derivative
    /// is. No allocation per call and no tolerance to pick.
    ///
    /// This started out sampling each segment at 32 points and taking the box
    /// of those, which was easier to be sure of and cost 417 seconds of
    /// upstream's own test suite — one of its tests calls this three times per
    /// frame across 2.16 million frames, which is nothing against CoreGraphics'
    /// native call and is half a minute of array-building here. Exact is both
    /// the right answer and the fast one.
    var boundingBoxOfPath: CGRect {
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        var pen = CGPoint.zero
        var subpathStart = CGPoint.zero

        func include(_ point: CGPoint) {
            minX = Swift.min(minX, point.x); maxX = Swift.max(maxX, point.x)
            minY = Swift.min(minY, point.y); maxY = Swift.max(maxY, point.y)
        }
        func includeCurve(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint,
                          cubic: Bool) -> CGPoint {
            include(p0); include(p3)
            // Both axes in one pass, and no array per axis: `stationary` hands
            // each root to a closure as it finds it. This is called three times
            // a frame across 2.16 million frames by an upstream test, and the
            // arrays were the second-largest cost in the suite after the
            // sampling this replaced.
            Self.forEachStationary(p0.x, p1.x, p2.x, p3.x, cubic: cubic) { t in
                include(Self.point(p0, p1, p2, p3, at: t, cubic: cubic))
            }
            Self.forEachStationary(p0.y, p1.y, p2.y, p3.y, cubic: cubic) { t in
                include(Self.point(p0, p1, p2, p3, at: t, cubic: cubic))
            }
            return p3
        }

        for command in commands {
            switch command {
            case .move(let point):
                include(point); pen = point; subpathStart = point
            case .line(let point):
                include(pen); include(point); pen = point
            case .quadCurve(let control, let point):
                pen = includeCurve(pen, control, control, point, cubic: false)
            case .curve(let control1, let control2, let point):
                pen = includeCurve(pen, control1, control2, point, cubic: true)
            case .arc(let centre, let radius, let start, let end, let clockwise):
                var sweep = (end - start).truncatingRemainder(dividingBy: 2 * .pi)
                if clockwise, sweep > 0 { sweep -= 2 * .pi }
                if !clockwise, sweep < 0 { sweep += 2 * .pi }
                include(CGPoint(x: centre.x + radius * cos(start), y: centre.y + radius * sin(start)))
                include(CGPoint(x: centre.x + radius * cos(end), y: centre.y + radius * sin(end)))
                // The four axis crossings the sweep passes through put the
                // arc's own extremes on the box; nothing between them can.
                let direction: Double = sweep < 0 ? -1 : 1
                for quarter in 0..<4 {
                    let angle = Double(quarter) * .pi / 2
                    let travelled = (angle - start) * direction
                    if travelled > 0, travelled < abs(sweep) {
                        include(CGPoint(x: centre.x + radius * cos(angle),
                                        y: centre.y + radius * sin(angle)))
                    }
                }
                pen = CGPoint(x: centre.x + radius * cos(end), y: centre.y + radius * sin(end))
            case .close:
                pen = subpathStart
            }
        }
        guard minX <= maxX, minY <= maxY else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Where a Bézier segment's derivative is zero, as `t` in (0, 1), handed
    /// to `body` as they are found. Roots outside the segment are not roots of
    /// the segment, so they are skipped rather than reported and filtered.
    private static func forEachStationary(_ p0: Double, _ p1: Double, _ p2: Double,
                                         _ p3: Double, cubic: Bool, _ body: (Double) -> Void) {
        if !cubic {
            // B'(t) = 2((1-t)(p1-p0) + t(p2-p1)), so one root.
            let denominator = p0 - 2 * p1 + p2
            guard abs(denominator) > 1e-12 else { return }
            let t = (p0 - p1) / denominator
            if t > 0, t < 1 { body(t) }
            return
        }
        // B'(t)/3 = a t² + b t + c.
        let a = 3 * (-p0 + 3 * p1 - 3 * p2 + p3)
        let b = 6 * (p0 - 2 * p1 + p2)
        let c = 3 * (p1 - p0)
        if abs(a) < 1e-12 {
            guard abs(b) > 1e-12 else { return }
            let t = -c / b
            if t > 0, t < 1 { body(t) }
            return
        }
        let discriminant = b * b - 4 * a * c
        guard discriminant >= 0 else { return }
        let root = discriminant.squareRoot()
        let first = (-b + root) / (2 * a)
        if first > 0, first < 1 { body(first) }
        let second = (-b - root) / (2 * a)
        if second > 0, second < 1 { body(second) }
    }

    /// A segment evaluated at `t`, in de Casteljau's form — which for a
    /// quadratic is the cubic repeated, so one expression serves both.
    private static func point(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint,
                              at t: Double, cubic: Bool) -> CGPoint {
        let inverse = 1 - t
        if !cubic {
            return CGPoint(x: inverse * inverse * p0.x + 2 * inverse * t * p1.x + t * t * p3.x,
                           y: inverse * inverse * p0.y + 2 * inverse * t * p1.y + t * t * p3.y)
        }
        let a = inverse * inverse * inverse, b = 3 * inverse * inverse * t
        let c = 3 * inverse * t * t, d = t * t * t
        return CGPoint(x: a * p0.x + b * p1.x + c * p2.x + d * p3.x,
                       y: a * p0.y + b * p1.y + c * p2.y + d * p3.y)
    }

    /// The box the path's **control points** fall in.
    ///
    /// Not the tight box of the drawn curve, which is what CoreGraphics
    /// returns. Nothing in the panel measures with it — `BotMarkFrame` carries
    /// `viewBoxRadius` for that — and the difference is noted here rather than
    /// left as a trap for whoever reaches for it next.
    var boundingBox: CGRect {
        let points = commands.flatMap(\.points)
        guard !points.isEmpty else { return .zero }
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!,
                      width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
}

/// The mutable half. Upstream builds every path through this.
final class CGMutablePath: CGPath {
    /// The current point, so `addLine(to:)` after a `move` is anchored the way
    /// CoreGraphics anchors it. Kept because the arc conversion below needs it.
    private var current: CGPoint?

    override init(commands: [PathCommand] = []) {
        super.init(commands: commands)
        current = commands.last?.endPoint
    }

    func move(to point: CGPoint) {
        append(.move(to: point))
    }

    func addLine(to point: CGPoint) {
        append(.line(to: point))
    }

    func addQuadCurve(to point: CGPoint, control: CGPoint) {
        append(.quadCurve(control: control, to: point))
    }

    func addCurve(to point: CGPoint, control1: CGPoint, control2: CGPoint) {
        append(.curve(control1: control1, control2: control2, to: point))
    }

    /// The labels are CoreGraphics' own, which is what the call sites use:
    /// `center`, `radius`, `startAngle`, `endAngle`, `clockwise`.
    func addArc(center: CGPoint, radius: Double,
                startAngle: Double, endAngle: Double, clockwise: Bool) {
        append(.arc(centre: center, radius: radius,
                    start: startAngle, end: endAngle, clockwise: clockwise))
    }

    func addPath(_ other: CGPath) {
        for command in other.commands { append(command) }
    }

    func closeSubpath() {
        append(.close)
        current = nil
    }

    /// The one place a path grows, so every mutation also maintains `current`.
    private func append(_ command: PathCommand) {
        commands.append(command)
        current = command.endPoint
    }
}

extension CGPoint {
    /// CoreGraphics has this on `CGPoint` itself, and the panel's call sites
    /// use it rather than `transform.transform(_:)`.
    func applying(_ transform: CGAffineTransform) -> CGPoint {
        transform.transform(self)
    }
}

extension PathCommand {
    /// Where the command leaves the pen. `.close` and `.arc` report their own
    /// end where CoreGraphics would, so a following line starts in the right
    /// place.
    var endPoint: CGPoint? {
        switch self {
        case .move(let point), .line(let point): return point
        case .quadCurve(_, let point), .curve(_, _, let point): return point
        case .arc(let centre, let radius, _, let end, _):
            return CGPoint(x: centre.x + radius * cos(end), y: centre.y + radius * sin(end))
        case .close: return nil
        }
    }

    /// Every point this command is defined by, control points included.
    ///
    /// Readable rather than private because it has two callers that are not
    /// this file: the renderer's scaler and the test that checks every point
    /// lands in the unit space.
    var points: [CGPoint] {
        switch self {
        case .move(let point), .line(let point): return [point]
        case .quadCurve(let control, let point): return [control, point]
        case .curve(let control1, let control2, let point): return [control1, control2, point]
        case .arc(let centre, let radius, _, _, _):
            // The box of the whole circle, which is what an arc's own extent
            // cannot always give without knowing which way it sweeps.
            return [CGPoint(x: centre.x - radius, y: centre.y - radius),
                    CGPoint(x: centre.x + radius, y: centre.y + radius)]
        case .close: return []
        }
    }

    func transformed(by transform: CGAffineTransform) -> PathCommand {
        switch self {
        case .move(let point): return .move(to: transform.transform(point))
        case .line(let point): return .line(to: transform.transform(point))
        case .quadCurve(let control, let point):
            return .quadCurve(control: transform.transform(control),
                              to: transform.transform(point))
        case .curve(let control1, let control2, let point):
            return .curve(control1: transform.transform(control1),
                          control2: transform.transform(control2),
                          to: transform.transform(point))
        case .arc(let centre, let radius, let start, let end, let clockwise):
            // A uniform transform carries a circle to a circle, so the centre
            // and the radius move and the angles only shift. A **non-uniform**
            // one carries it to an ellipse, which this cannot express — the
            // arcs upstream draws are all under uniform scale, and rather than
            // silently draw the wrong shape the radius is left alone and noted
            // here as the limit it is.
            let moved = transform.transform(centre)
            let scale = (abs(transform.a) + abs(transform.d)) / 2
            return .arc(centre: moved, radius: radius * scale,
                        start: start, end: end, clockwise: clockwise)
        case .close: return .close
        }
    }
}

// MARK: - Colour

/// The colour space `Color.init?(hex:)` names. There is one on Linux, so this
/// is a spelling rather than a choice — `SwiftUI` has the same case and the
/// initializer below ignores it either way.
enum RGBColorSpace: Sendable {
    case sRGB
}

/// A colour, as the panel's own code treats one: four components and nothing
/// else. No colour space, no dynamic appearance, no named catalogue.
///
/// SwiftUI's `Color` is a much larger thing and upstream uses three of its
/// corners — it is built from components, it is compared for equality, and it
/// can be asked for its components back. The last of those is what
/// `BotMarkTint.lifted` exists for: it measures a brand colour's luminance and
/// mixes it toward white until it clears the disc. That needs the numbers, so
/// they are stored rather than looked up.
struct Color: Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var opacity: Double

    init(red: Double, green: Double, blue: Double, opacity: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.opacity = opacity
    }

    /// The `SwiftUI` spelling, with the colour space named. The space is
    /// accepted and ignored: a Linux colour is sRGB because that is what the
    /// screen is, not because it was told.
    init(_ space: RGBColorSpace, red: Double, green: Double, blue: Double, opacity: Double = 1) {
        self.init(red: red, green: green, blue: blue, opacity: opacity)
    }

    /// Grayscale, which is how the eyes are coloured.
    init(white: Double, opacity: Double = 1) {
        self.init(red: white, green: white, blue: white, opacity: opacity)
    }

    static let white = Color(white: 1)
    static let black = Color(white: 0)
    static let clear = Color(white: 0, opacity: 0)

    func opacity(_ value: Double) -> Color {
        Color(red: red, green: green, blue: blue, opacity: opacity * value)
    }

    /// The components, in the role `NSColor` plays on a Mac.
    ///
    /// Upstream reaches these through `NSColor(colour).usingColorSpace(.sRGB)`,
    /// and that call has no Linux answer. Rather than write an AppKit stub that
    /// would have to pretend about colour spaces, the components are simply
    /// here — this type has no other space to convert from.
    var redComponent: Double { red }
    var greenComponent: Double { green }
    var blueComponent: Double { blue }
}

#endif
