#if !canImport(AppKit)
import Foundation

/// SVG path data, parsed into the command list the canvas draws.
///
/// **Written because the rail's default content is a logo and there was no way
/// to draw one.** `Provider.iconResource` names a file in `Resources/`, the
/// files are SVG, and on a Mac `NSImage` renders them as vectors and treats them
/// as templates — so one file serves 36pt in the rail and 16pt on the card.
/// Linux has no such thing, and a ring whose default state is an empty circle is
/// not the same application.
///
/// The icons turned out to use **the whole** path grammar: `M L H V C S Q T A Z`
/// in both absolute and relative forms, measured across all 34 files, plus
/// `fill-rule="evenodd"` on most of them. So this is the grammar, not the subset
/// that happened to appear in one file — a parser that silently skipped what it
/// did not know would draw three-quarters of a logo and look like a rendering
/// bug rather than a missing feature.
///
/// The viewBox is `0 0 24 24` on every one of them, which is why the caller
/// scales rather than the parser.
enum SVGPathData {
    /// Parses a `d` attribute. Never throws: a malformed path yields the
    /// commands it managed and the caller draws what it got — the alternative
    /// is a rail with a hole in it, since the `d` strings come from a file
    /// nobody is editing.
    static func parse(_ data: String) -> [PathCommand] {
        var scanner = Scanner(data)
        var commands: [PathCommand] = []
        // Where the pen is, and where the current subpath began — `Z` returns
        // to it, and a relative `m` after a `Z` is measured from it.
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        /// The last cubic control point, for `S`. Mirrored through the current
        /// point when the previous command was not a cubic, per the spec.
        var lastCubicControl: CGPoint?
        /// The same for `T` and a quadratic's control point.
        var lastQuadControl: CGPoint?

        var command: Character = " "
        while true {
            guard let next = scanner.nextCommand() else { break }
            command = next
            let relative = command.isLowercase
            let verb = Character(command.uppercased())

            /// A coordinate: relative commands are offsets from the pen.
            func point(_ x: Double, _ y: Double) -> CGPoint {
                relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }

            switch verb {
            case "M":
                guard let x = scanner.number(), let y = scanner.number() else { break }
                let target = point(x, y)
                commands.append(.move(to: target))
                current = target
                subpathStart = target
                lastCubicControl = nil
                lastQuadControl = nil
                // A second pair, and any after it, is a line — the grammar
                // says `M` is followed by implicit `L`s.
                readLines(&scanner, into: &commands, current: &current, relative: relative)

            case "L":
                readLines(&scanner, into: &commands, current: &current, relative: relative)

            case "H":
                while let x = scanner.number() {
                    let target = CGPoint(x: relative ? current.x + x : x, y: current.y)
                    commands.append(.line(to: target))
                    current = target
                }
                lastCubicControl = nil
                lastQuadControl = nil

            case "V":
                while let y = scanner.number() {
                    let target = CGPoint(x: current.x, y: relative ? current.y + y : y)
                    commands.append(.line(to: target))
                    current = target
                }
                lastCubicControl = nil
                lastQuadControl = nil

            case "C":
                while let x1 = scanner.number(), let y1 = scanner.number(),
                      let x2 = scanner.number(), let y2 = scanner.number(),
                      let x = scanner.number(), let y = scanner.number() {
                    let control1 = point(x1, y1)
                    let control2 = point(x2, y2)
                    let target = point(x, y)
                    commands.append(.curve(control1: control1, control2: control2, to: target))
                    current = target
                    lastCubicControl = control2
                }
                lastQuadControl = nil

            case "S":
                while let x2 = scanner.number(), let y2 = scanner.number(),
                      let x = scanner.number(), let y = scanner.number() {
                    // The mirrored control, or the current point when the last
                    // command was not a cubic — which is what the spec means by
                    // "coincident with the current point".
                    let control1 = lastCubicControl.map {
                        CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y)
                    } ?? current
                    let control2 = point(x2, y2)
                    let target = point(x, y)
                    commands.append(.curve(control1: control1, control2: control2, to: target))
                    current = target
                    lastCubicControl = control2
                }
                lastQuadControl = nil

            case "Q":
                while let x1 = scanner.number(), let y1 = scanner.number(),
                      let x = scanner.number(), let y = scanner.number() {
                    let control = point(x1, y1)
                    let target = point(x, y)
                    commands.append(.quadCurve(control: control, to: target))
                    current = target
                    lastQuadControl = control
                }
                lastCubicControl = nil

            case "T":
                while let x = scanner.number(), let y = scanner.number() {
                    let control = lastQuadControl.map {
                        CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y)
                    } ?? current
                    let target = point(x, y)
                    commands.append(.quadCurve(control: control, to: target))
                    current = target
                    lastQuadControl = control
                }
                lastCubicControl = nil

            case "A":
                while let rx = scanner.number(), let ry = scanner.number(),
                      let rotation = scanner.number(),
                      let largeArc = scanner.flag(), let sweep = scanner.flag(),
                      let x = scanner.number(), let y = scanner.number() {
                    let target = point(x, y)
                    appendArc(into: &commands, from: current, to: target,
                              rx: rx, ry: ry, rotationDegrees: rotation,
                              largeArc: largeArc, sweep: sweep)
                    current = target
                }
                lastCubicControl = nil
                lastQuadControl = nil

            case "Z":
                commands.append(.close)
                // **The pen goes back to the subpath's start.** A relative
                // command after a `Z` is measured from there, not from where
                // the outline happened to finish — and getting that wrong
                // shifts the next subpath by the whole width of the last one.
                current = subpathStart
                lastCubicControl = nil
                lastQuadControl = nil

            default:
                // An unknown letter is skipped along with its numbers rather
                // than treated as a point, so one unrecognised verb does not
                // turn the rest of the path into garbage.
                scanner.skipNumbers()
            }
        }
        return commands
    }

    /// The implicit `L`s after an `M`, and every `L` pair after an `L`.
    private static func readLines(_ scanner: inout Scanner, into commands: inout [PathCommand],
                                  current: inout CGPoint, relative: Bool) {
        while let x = scanner.number(), let y = scanner.number() {
            let target = relative ? CGPoint(x: current.x + x, y: current.y + y)
                                  : CGPoint(x: x, y: y)
            commands.append(.line(to: target))
            current = target
        }
    }

    // MARK: - Arcs

    /// An SVG elliptical arc, emitted as cubic segments.
    ///
    /// **The endpoint-to-centre conversion from the specification**, which is
    /// the least obvious arithmetic in the format: an arc is given by where it
    /// ends and how far round it goes, and drawing it needs where it is centred.
    /// The spec's own steps are followed in order, including the radius
    /// correction that scales both radii up when the endpoints are further apart
    /// than the ellipse can reach — without it such an arc is undefined and
    /// most renderers draw a line.
    private static func appendArc(into commands: inout [PathCommand], from start: CGPoint,
                                  to end: CGPoint, rx: Double, ry: Double,
                                  rotationDegrees: Double, largeArc: Bool, sweep: Bool) {
        // Degenerate radii mean a straight line, and coincident endpoints mean
        // nothing at all — both per the spec, and both worth handling rather
        // than dividing by zero.
        guard rx != 0, ry != 0, start != end else {
            if start != end { commands.append(.line(to: end)) }
            return
        }

        let rx = abs(rx), ry = abs(ry)
        let rotation = rotationDegrees * .pi / 180
        let cosine = cos(rotation), sine = sin(rotation)

        let halfX = (start.x - end.x) / 2
        let halfY = (start.y - end.y) / 2
        let x1 = cosine * halfX + sine * halfY
        let y1 = -sine * halfX + cosine * halfY

        // Scale the radii up if they cannot span the endpoints.
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        let (rx2, ry2) = lambda > 1 ? (rx * lambda.squareRoot(), ry * lambda.squareRoot()) : (rx, ry)

        let denominator = rx2 * rx2 * y1 * y1 + ry2 * ry2 * x1 * x1
        var coefficient = 0.0
        if denominator > 0 {
            let numerator = rx2 * rx2 * ry2 * ry2 - rx2 * rx2 * y1 * y1 - ry2 * ry2 * x1 * x1
            coefficient = (largeArc == sweep ? -1 : 1) * max(0, numerator / denominator).squareRoot()
        }
        let centreX = coefficient * rx2 * y1 / ry2
        let centreY = coefficient * -ry2 * x1 / rx2

        let centre = CGPoint(
            x: cosine * centreX - sine * centreY + (start.x + end.x) / 2,
            y: sine * centreX + cosine * centreY + (start.y + end.y) / 2)

        let startVector = CGPoint(x: (x1 - centreX) / rx2, y: (y1 - centreY) / ry2)
        let endVector = CGPoint(x: (-x1 - centreX) / rx2, y: (-y1 - centreY) / ry2)
        let startAngle = angle(of: CGPoint(x: 1, y: 0), startVector)
        var delta = angle(of: startVector, endVector)
        if !sweep, delta > 0 { delta -= 2 * .pi }
        if sweep, delta < 0 { delta += 2 * .pi }

        /// The ellipse at an angle.
        func point(_ theta: Double) -> CGPoint {
            let x = rx2 * cos(theta), y = ry2 * sin(theta)
            return CGPoint(x: centre.x + cosine * x - sine * y,
                           y: centre.y + sine * x + cosine * y)
        }
        /// Its derivative, for the control points.
        func tangent(_ theta: Double) -> CGPoint {
            let x = -rx2 * sin(theta), y = ry2 * cos(theta)
            return CGPoint(x: cosine * x - sine * y, y: sine * x + cosine * y)
        }

        // At most a quarter turn each, which is the same limit the shim's own
        // circle approximation uses and for the same reason.
        let segments = max(1, Int((abs(delta) / (Double.pi / 2)).rounded(.up)))
        let step = delta / Double(segments)
        let handle = 4.0 / 3.0 * tan(step / 4)

        var theta = startAngle
        for _ in 0..<segments {
            let next = theta + step
            let from = point(theta), to = point(next)
            commands.append(.curve(
                control1: CGPoint(x: from.x + handle * tangent(theta).x,
                                  y: from.y + handle * tangent(theta).y),
                control2: CGPoint(x: to.x - handle * tangent(next).x,
                                  y: to.y - handle * tangent(next).y),
                to: to))
            theta = next
        }
    }

    /// The angle between two vectors, signed, which the arc conversion needs in
    /// both places it is used.
    private static func angle(of first: CGPoint, _ second: CGPoint) -> Double {
        atan2(first.x * second.y - first.y * second.x, first.x * second.x + first.y * second.y)
    }

    // MARK: - Scanning

    /// A reader over the `d` string.
    ///
    /// Hand-written rather than a regular expression because SVG's number
    /// syntax is not comma-separated in any way a splitter can rely on: `1-2` is
    /// two numbers, `1.5.5` is two more, `1e-3` is one, and a letter may follow
    /// a number with no separator at all. A scanner that consumes what it can
    /// and stops where it must is the only thing that reads all four correctly.
    private struct Scanner {
        private let characters: [Character]
        private var index = 0

        init(_ text: String) { characters = Array(text) }

        /// The next command letter, or nil at the end. Whitespace and commas are
        /// skipped; anything that is not a letter is not a command.
        mutating func nextCommand() -> Character? {
            skipSeparators()
            guard index < characters.count else { return nil }
            let character = characters[index]
            guard character.isLetter else {
                // Not a command: leave it for `number()`, which will decline it
                // and end the loop rather than looping forever.
                return nil
            }
            index += 1
            return character
        }

        /// The next number, or nil if the next thing is not one.
        mutating func number() -> Double? {
            skipSeparators()
            let start = index
            if index < characters.count, characters[index] == "+" || characters[index] == "-" {
                index += 1
            }
            var sawDigit = false
            while index < characters.count, characters[index].isNumber {
                index += 1
                sawDigit = true
            }
            if index < characters.count, characters[index] == "." {
                index += 1
                while index < characters.count, characters[index].isNumber {
                    index += 1
                    sawDigit = true
                }
            }
            guard sawDigit else {
                index = start
                return nil
            }
            // An exponent, which `1e-3` needs and `1e` alone does not.
            if index < characters.count, characters[index] == "e" || characters[index] == "E" {
                let beforeExponent = index
                index += 1
                if index < characters.count, characters[index] == "+" || characters[index] == "-" {
                    index += 1
                }
                var sawExponentDigit = false
                while index < characters.count, characters[index].isNumber {
                    index += 1
                    sawExponentDigit = true
                }
                if !sawExponentDigit { index = beforeExponent }
            }
            return Double(String(characters[start..<index]))
        }

        /// An arc flag, which the grammar says is a single `0` or `1` and which
        /// **must not** be read as a number: `A 5 5 0 0110 10` is a flag, a
        /// flag, then `10`, and a number reader takes `0110` instead.
        mutating func flag() -> Bool? {
            skipSeparators()
            guard index < characters.count,
                  characters[index] == "0" || characters[index] == "1" else { return nil }
            let value = characters[index] == "1"
            index += 1
            return value
        }

        /// Consumes numbers until one fails, for an unknown command letter.
        mutating func skipNumbers() {
            while number() != nil {}
        }

        private mutating func skipSeparators() {
            while index < characters.count,
                  characters[index] == "," || characters[index].isWhitespace {
                index += 1
            }
        }
    }
}
#endif
