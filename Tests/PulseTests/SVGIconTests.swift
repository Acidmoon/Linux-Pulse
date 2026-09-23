import Foundation
import Testing

@testable import Pulse

/// SVG path data, and the icons it was written for.
///
/// **The parser exists because the rail's default content is a logo**, and what
/// it produces is a filled silhouette nobody diffs. A parser that mishandles one
/// verb does not fail — it draws a logo with a piece missing, or with a hole
/// filled in, and the only way anyone notices is by looking at the rail. So the
/// grammar is tested against the things it can get wrong: relative against
/// absolute, an implicit lineto, the reflected control points of `S` and `T`,
/// the arc flags, and the pen returning to the subpath after `Z`.
@Suite("SVG path data")
struct SVGPathDataTests {
    private func parse(_ data: String) -> [PathCommand] {
        SVGPathData.parse(data)
    }

    /// The simplest possible check, and the one that would have caught a
    /// scanner that cannot separate numbers without a comma: SVG allows `1-2`
    /// and `.5.5` and `1e-3`, and none of them have separators.
    @Test("Absolute and relative forms of the same path agree")
    func relativeMatchesAbsolute() {
        #expect(parse("M10 10L20 20") == parse("M10 10l10 10"))
        #expect(parse("M10 10H30V40") == parse("M10 10h20v30"))
        #expect(parse("M10 10C1 2 3 4 5 6") == parse("M10 10c-9 -8 -7 -6 -5 -4"))
    }

    /// `M` carries implicit `L`s, which is the rule that trips a parser that
    /// reads exactly one pair and moves on.
    @Test("A move is followed by implicit lines")
    func moveTakesImplicitLines() {
        let commands = parse("M0 0 10 10 20 20")
        #expect(commands == [.move(to: CGPoint(x: 0, y: 0)),
                             .line(to: CGPoint(x: 10, y: 10)),
                             .line(to: CGPoint(x: 20, y: 20))])
    }

    /// `S` and `T` are shorthand for a smooth join: the first control point is
    /// the previous one mirrored through the current point. Getting the
    /// reflection wrong makes a curve kink, which reads as a drawing mistake.
    @Test("A smooth curve mirrors the previous control point")
    func smoothCurvesReflect() {
        // C to (10,0) with second control (8,0), then S: the next first control
        // is (10,0) + ((10,0) - (8,0)) = (12,0).
        let commands = parse("M0 0C2 0 8 0 10 0S14 0 20 0")
        guard case .curve(let control1, _, _) = commands.last else {
            Issue.record("expected a curve, got \(String(describing: commands.last))")
            return
        }
        #expect(control1 == CGPoint(x: 12, y: 0), "got \(control1)")
    }

    @Test("A smooth quadratic mirrors the previous control point")
    func smoothQuadraticsReflect() {
        let commands = parse("M0 0Q6 0 10 0T20 0")
        guard case .quadCurve(let control, let to) = commands.last else {
            Issue.record("expected a quadratic, got \(String(describing: commands.last))")
            return
        }
        #expect(control == CGPoint(x: 14, y: 0), "got \(control)")
        #expect(to == CGPoint(x: 20, y: 0))
    }

    /// **The pen goes back to where the subpath began.** A relative command
    /// after a `Z` measured from where the outline happened to finish is offset
    /// by the whole width of the subpath before it — which is how a
    /// two-outline logo ends up with its second half in the wrong place.
    @Test("A close returns the pen to the subpath's start")
    func closeRewindsThePen() {
        // The second subpath starts 5 to the right of the first one's start,
        // which is (10, 10) — not of where the outline finished, which is
        // (30, 10). Checked on the move, because the line after it is measured
        // from wherever the move landed and would hide the difference.
        let commands = parse("M10 10L20 20L30 10Zm5 0l10 0")
        guard case .move(let started) = commands.first(where: {
            if case .move = $0 { return true }
            return false
        }) else {
            Issue.record("no move")
            return
        }
        #expect(started == CGPoint(x: 10, y: 10), "the subpath began at \(started)")
        // And the relative move did land 5 to its right.
        guard case .move(let second) = commands.last(where: {
            if case .move = $0 { return true }
            return false
        }) else {
            Issue.record("no second move")
            return
        }
        #expect(second == CGPoint(x: 15, y: 10), "got \(second)")
    }

    /// The arc flags are single digits with no separator, so
    /// `A5 5 0 0110 10` is a flag, a flag, then `10` — a number reader takes
    /// `0110` and the arc is drawn somewhere else entirely.
    @Test("Arc flags are read one digit at a time")
    func arcFlagsAreSingleDigits() {
        let commands = parse("M0 0A5 5 0 0110 10")
        guard case .curve(_, _, let end) = commands.last else {
            Issue.record("expected the arc's last segment, got \(String(describing: commands.last))")
            return
        }
        // The endpoints are the one thing the arc must land on exactly.
        #expect(abs(end.x - 10) < 1e-9 && abs(end.y - 10) < 1e-9, "got \(end)")
    }

    /// An arc is a chain of cubics, and it has to *end* where it was asked to
    /// however many segments it took and whichever way round it went.
    @Test("Every arc form lands on its endpoint", arguments: [
        "M0 0A5 5 0 0 0 10 0", "M0 0A5 5 0 0 1 10 0",
        "M0 0A5 5 0 1 0 10 0", "M0 0A5 5 0 1 1 10 0",
        "M0 0A8 3 30 0 1 10 4", "M0 0a5 5 0 0 1 10 0",
    ])
    func arcsLandOnTheirEndpoint(_ data: String) {
        let commands = parse(data)
        var end: CGPoint?
        if case .curve(_, _, let point) = commands.last { end = point }
        let landed = try? #require(end)
        #expect(abs((landed?.x ?? .infinity) - 10) < 1e-6, "\(data) ended at \(String(describing: landed))")
    }

    /// A degenerate arc — coincident endpoints, or a zero radius — is a line
    /// rather than a division by zero. The spec says so and the icons contain
    /// both.
    @Test("Degenerate arcs do not produce NaN")
    func degenerateArcs() {
        for data in ["M5 5A5 5 0 0 1 5 5", "M0 0A0 0 0 0 1 10 10", "M0 0A5 5 0 0 1 0 0"] {
            for command in parse(data) {
                for point in command.points {
                    #expect(point.x.isFinite && point.y.isFinite, "\(data) produced \(point)")
                }
            }
        }
    }

    /// Exponent notation, which an icon uses for a sub-pixel radius and which a
    /// scanner written for `123.456` reads as `1` followed by `e-3` as garbage.
    @Test("Numbers in exponent notation are read whole")
    func exponentNotation() {
        let commands = parse("M1e-3 2E+1L3 4")
        guard case .move(let start) = commands.first else {
            Issue.record("no move")
            return
        }
        #expect(abs(start.x - 0.001) < 1e-12, "got \(start.x)")
        #expect(abs(start.y - 20) < 1e-12, "got \(start.y)")
    }

    /// A verb the parser does not know skips its numbers rather than eating the
    /// following commands, so one unknown letter cannot turn the rest of a path
    /// into garbage.
    @Test("An unknown verb is skipped with its numbers")
    func unknownVerbs() {
        let commands = parse("M0 0W1 2 3 4L5 5")
        #expect(commands == [.move(to: CGPoint(x: 0, y: 0)), .line(to: CGPoint(x: 5, y: 5))])
    }
}

/// The marks the rail draws by default, checked against the files themselves.
///
/// `Bundle.module` in a test target is the *test's* bundle, not Pulse's, so
/// every one of these goes through `SVGIcon` — which is the only thing that can
/// see the real resources. That is the same reason upstream's `LobeIconStore` is
/// not private.
@Suite("Provider icons")
struct SVGIconTests {
    /// **Every provider has a mark and it parses.** A missing or unparseable
    /// icon is an empty ring on the rail — the default state of the whole
    /// application — and nothing about compiling would say so.
    @Test("Every provider's icon parses", arguments: Provider.allCases)
    @MainActor
    func everyIconParses(provider: Provider) throws {
        let icon = try #require(SVGIcon.icon(named: provider.iconResource),
                                "\(provider.rawValue) has no icon at \(provider.iconResource).svg")
        #expect(!icon.commands.isEmpty, "\(provider.rawValue) parsed to an empty path")
        #expect(icon.evenOdd, "\(provider.rawValue) is not marked evenodd, which every icon in Resources is")
    }

    /// **Every coordinate is a real number.**
    ///
    /// This started out asserting that every point stays inside the viewBox, and
    /// the icons do not: `kiro.svg` draws to y = -2.2 and y = 25.5 in a 24-unit
    /// box, and several others overdraw. That is not a parsing failure — it is
    /// what an SVG viewport clips, which is why the renderer clips too. So what
    /// is checked here is the thing that *would* be a failure: a coordinate that
    /// is not a number, which an arc conversion or a scanner can produce out of
    /// a path that looks fine.
    @Test("Every icon's coordinates are finite", arguments: Provider.allCases)
    @MainActor
    func iconsHaveFiniteCoordinates(provider: Provider) throws {
        let icon = try #require(SVGIcon.icon(named: provider.iconResource))
        var outside = 0, total = 0
        for command in icon.commands {
            for point in command.points {
                total += 1
                #expect(point.x.isFinite && point.y.isFinite,
                        "\(provider.rawValue): \(point)")
                if point.x < icon.viewBox.minX - 1 || point.x > icon.viewBox.maxX + 1
                    || point.y < icon.viewBox.minY - 1 || point.y > icon.viewBox.maxY + 1 {
                    outside += 1
                }
            }
        }
        // And the overdraw is a small minority rather than a parser that has
        // lost the plot: a relative command read as absolute, or an arc whose
        // centre landed somewhere else, puts the *whole* icon outside.
        #expect(Double(outside) / Double(max(total, 1)) < 0.25,
                "\(provider.rawValue): \(outside) of \(total) points outside the viewBox")
    }

    /// **Curves survive, and straight lines are not invented.** A parser that
    /// silently dropped every `C` and `A` would still produce a path with points
    /// in it and a box in range — it would just be the wrong shape. So both
    /// sides are pinned: the OpenAI mark is all curves, and the Kilo Code mark is
    /// `M`/`v`/`h`/`z` and nothing else.
    ///
    /// Eight of the 34 files are polygons, measured, which is why this is not a
    /// claim about all of them.
    @Test("Curves are parsed, and only where the file has them")
    @MainActor
    func curvesSurvive() throws {
        let openai = try #require(SVGIcon.icon(named: "openai"))
        #expect(openai.commands.contains { if case .curve = $0 { return true }; return false },
                "the OpenAI mark parsed with no curves at all")

        let kilocode = try #require(SVGIcon.icon(named: "kilocode"))
        #expect(!kilocode.commands.contains { if case .curve = $0 { return true }; return false },
                "the Kilo Code mark is polygons and parsed with curves invented")
        #expect(kilocode.commands.contains { if case .line = $0 { return true }; return false })
    }

    /// The viewBox is read rather than assumed. Every icon in `Resources` says
    /// `0 0 24 24`, and this is what would notice if one did not.
    @Test("A viewBox is read from the file")
    @MainActor
    func viewBoxIsRead() throws {
        let icon = try #require(SVGIcon.icon(named: Provider.claudeCode.iconResource))
        #expect(icon.viewBox == CGRect(x: 0, y: 0, width: 24, height: 24), "got \(icon.viewBox)")
    }

    /// A name that is not there returns nil rather than an empty icon, which is
    /// what lets the rail draw its question mark instead of a blank disc.
    @Test("A missing icon is nil")
    @MainActor
    func missingIcon() {
        #expect(SVGIcon.icon(named: "no-such-provider-mark") == nil)
    }
}
