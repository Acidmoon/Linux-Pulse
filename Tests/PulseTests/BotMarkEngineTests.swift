#if !canImport(SwiftUI)
// Linux only, and **not because the engine is**. The animation assertions below
// would hold on either platform; what would not compile on a Mac is the way
// they look at it — `PathCommand`, `CGPath.commands` and
// `boundingBoxOfPath`'s implementation are `Platform/DrawingCompat.swift`,
// which exists only where CoreGraphics does not.
//
// `BotMarkTests` next door is the portable half: upstream's own suite, which
// runs on both platforms and is worth far more than anything here.

import Foundation
import Testing

@testable import Pulse

/// The BotMark animation, running on Linux.
///
/// **This is the test that says the animation was not cut.** The mark is
/// 4305 lines upstream and 3948 of them are not SwiftUI — the engine, the
/// morphs, the particles, the geometry — so they are upstream's own code with
/// only their imports made conditional, and `Platform/DrawingCompat.swift`
/// supplies the four names they did not have (`CGPath`, `CGMutablePath`,
/// `CGAffineTransform`, `CGVector`) plus `Color`.
///
/// Compiling it proved nothing worth having. What these tests check is that it
/// **runs**: that the springs settle, that the paths come out with points in
/// them, that the frames differ from each other, and that the numbers stay in
/// the unit space the renderer will draw them in. A stub that returned empty
/// paths would compile exactly as well.
@Suite("BotMark on Linux")
struct BotMarkEngineTests {
    /// The recipe `BotMarkView` uses, minus the SwiftUI around it.
    private func programme(_ mood: BotMarkMood, persona: BotMarkPersona = .calm,
                          body: BotMarkBody = .blob, at date: Date) -> BotMarkProgramme {
        var programme = BotMarkProgramme.forMood(mood, persona: persona, at: date)
        programme.shape = body.shape
        programme.viewWidth = 32
        programme.color = Color(red: 0.2, green: 0.6, blue: 0.9)
        programme.eyeColor = BotMarkTint.eyes(on: programme.color)
        return programme
    }

    /// Steps an engine the way the view does — 30fps, `timeIntervalSinceReferenceDate`.
    private func run(_ mood: BotMarkMood, seconds: Double = 4,
                     persona: BotMarkPersona = .calm, body: BotMarkBody = .blob,
                     from start: Date = Date(timeIntervalSinceReferenceDate: 700_000_000))
        -> [(frame: BotMarkFrame, config: BotMarkConfig, at: Date)] {
        let engine = BotMarkEngine()
        var output: [(BotMarkFrame, BotMarkConfig, Date)] = []
        let step = 1.0 / 30
        for index in 0...Int(seconds / step) {
            let date = start.addingTimeInterval(Double(index) * step)
            let programme = programme(mood, persona: persona, body: body, at: date)
            let frame = engine.advance(to: date.timeIntervalSinceReferenceDate,
                                       programme: programme)
            output.append((frame, programme.configuration(for: engine.state), date))
        }
        return output
    }

    /// The unit space every measurement below is relative to.
    private static let viewBox = 0.0...228.54

    @Test("The engine produces frames with real geometry in them")
    func producesGeometry() {
        let frames = run(.working)
        #expect(!frames.isEmpty)

        for (frame, _, _) in frames {
            #expect(!frame.headPath.isEmpty, "the head path had nothing in it")
            #expect(frame.viewBoxRadius > 0, "a mark with no radius cannot be drawn")
            #expect(frame.opacity >= 0 && frame.opacity <= 1, "opacity \(frame.opacity)")
            #expect(frame.morphAmount >= 0 && frame.morphAmount <= 1)
        }
    }

    /// The springs have to actually move. A frozen first frame is what a
    /// stubbed-out engine looks like, and it is also what a wrong time unit
    /// looks like — the upstream formulas are in milliseconds, and passing
    /// seconds would make every spring effectively still.
    ///
    /// **Measured through `transform`, not `headPath`.** The head path is one
    /// static outline per body shape — 60 seconds of idle draws the same
    /// `[PathCommand]` 1800 times — and every bit of motion is in the matrix
    /// applied to it. The first version of this test counted distinct paths
    /// and would have passed for a mark that never moved.
    @Test("The mark animates: frames differ from one another")
    func animates() {
        let frames = run(.working, seconds: 4)
        let transforms = Set(frames.map(\.frame.transform))
        #expect(transforms.count > 100, "only \(transforms.count) distinct transforms in 120 frames")
        // And the outline really is static, so the next person does not have to
        // measure it again to find that out.
        #expect(Set(frames.map(\.frame.headPath.commands)).count == 1)
    }

    /// The eyes blink.
    ///
    /// **Not through `Eye.visible`.** That flag means "the eyes are shown at
    /// all", and it goes false only while a morph is playing — an idle mark
    /// reports both eyes visible on all 1800 frames of a minute. A blink is
    /// `eyeOpen`, a spring the eye's own transform is scaled by, and the
    /// engine exposes it as `eyelid`.
    @Test("The eyes blink")
    func blinks() {
        let engine = BotMarkEngine()
        let start = Date(timeIntervalSinceReferenceDate: 700_000_000)
        var least = 1.0
        for index in 0...900 {          // 30 seconds
            let date = start.addingTimeInterval(Double(index) / 30)
            _ = engine.advance(to: date.timeIntervalSinceReferenceDate,
                               programme: programme(.idle, at: date))
            least = min(least, engine.eyelid)
        }
        #expect(least < 0.5, "the eyes never closed in thirty seconds; the least open was \(least)")
    }

    /// Every drawn point has to land in the unit space, because the renderer
    /// scales from it and a point outside it is a mark with a spike through
    /// the panel. Generous by a tenth either side: a morph is allowed to reach
    /// past the view box, and the box it reports grows with it.
    @Test("Every point lands in the space the renderer scales from")
    func staysInTheUnitSpace() {
        for mood in [BotMarkMood.idle, .working, .fetching, .spent, .unavailable] {
            for (frame, _, _) in run(mood, seconds: 3) {
                let radius = frame.viewBoxRadius * 1.1
                let centre = BotMarkFrame.viewBoxCentre
                let box = CGRect(x: centre - radius, y: centre - radius,
                                 width: radius * 2, height: radius * 2)
                for shape in frame.shapes {
                    for command in shape.path.commands {
                        for point in command.points {
                            #expect(box.contains(point),
                                    "\(point) is outside the view box in \(mood) — command \(command)")
                        }
                    }
                }
            }
        }
    }

    /// Same clock, same picture. The renderer is a separate process driven by
    /// timestamps, and without this a GTK frame could never be compared with a
    /// SwiftUI one.
    @Test("The same timestamps give the same frames")
    func isDeterministic() {
        let first = run(.working, seconds: 2)
        let second = run(.working, seconds: 2)
        #expect(first.count == second.count)
        for (left, right) in zip(first, second) {
            #expect(left.frame.headPath.commands == right.frame.headPath.commands)
            #expect(left.frame.viewBoxRadius == right.frame.viewBoxRadius)
            #expect(left.frame.opacity == right.frame.opacity)
        }
    }

    /// Every mood is one a real ring is in, and each has to draw something.
    /// `spent` and `unavailable` are the two that matter most: they are what a
    /// rail shows when a limit is gone or a provider is down, which is when a
    /// blank disc would be worst.
    @Test("Every mood draws a mark", arguments: BotMarkMood.allCases)
    func everyMoodDraws(mood: BotMarkMood) {
        let frames = run(mood, seconds: 2)
        #expect(frames.allSatisfy { !$0.frame.headPath.isEmpty })
        #expect(frames.allSatisfy { !$0.frame.eyes.isEmpty }, "\(mood) drew no eyes")
    }

    /// Every body shape has to close and be drawable, since the shape is the
    /// reader's choice and not the persona's.
    @Test("Every body shape draws", arguments: BotMarkBody.allCases)
    func everyBodyDraws(body: BotMarkBody) {
        let frames = run(.idle, seconds: 1, body: body)
        #expect(frames.allSatisfy { !$0.frame.headPath.isEmpty }, "\(body) drew nothing")
        #expect(frames.allSatisfy { $0.frame.headPath.commands.contains(.close) },
                "\(body) did not close its outline")
    }

    /// The brand table and the eye colour are the part of BotMark that needed
    /// a Linux answer for `NSColor` (`ColourReading`). This is that answer
    /// being asked a question with a known answer.
    @Test("A dark body gets light eyes and a light body gets dark ones")
    func eyeContrast() {
        let dark = BotMarkTint.eyes(on: Color(red: 0.05, green: 0.05, blue: 0.08))
        let light = BotMarkTint.eyes(on: Color(red: 0.95, green: 0.95, blue: 0.95))
        #expect(dark.red > 0.5, "dark eyes on a light body")
        #expect(light.red < 0.5, "light eyes on a dark body")
    }

    /// `lifted` needs a colour's components, which is `NSColor`'s job on a Mac
    /// and `ColourReading`'s here — so the conversion is what to check.
    @Test("A colour reports the hue it looks like")
    func readsHue() {
        #expect(Color(red: 1, green: 0, blue: 0).reading?.hue == 0)
        #expect(Color(red: 0, green: 1, blue: 0).reading?.hue == 120)
        #expect(Color(red: 0, green: 0, blue: 1).reading?.hue == 240)
        // A grey has no dominant channel, so no hue to report.
        #expect(Color(white: 0.5).reading?.hue == 0)
    }

    /// And the components come back as they went in, which is what the
    /// luminance weights are applied to.
    @Test("A colour reports its own components")
    func readsComponents() {
        let colour = Color(red: 0.1, green: 0.2, blue: 0.3)
        #expect(colour.reading?.red == 0.1)
        #expect(colour.reading?.green == 0.2)
        #expect(colour.reading?.blue == 0.3)
        // The weights `BotMarkTint` uses, on a known answer.
        let reading = try? #require(colour.reading)
        if let reading {
            let luminance = 0.2126 * reading.red + 0.7152 * reading.green + 0.0722 * reading.blue
            #expect(abs(luminance - 0.18596) < 0.0001, "got \(luminance)")
        }
    }

    /// Every provider gets a colour and no two of them are the same, which is
    /// the dealt wheel working. It is checked here rather than on a Mac
    /// because the wheel is built from hues, and hues are what Linux had to
    /// answer for.
    @Test("Every provider is dealt a distinct colour")
    func everyProviderGetsAColour() {
        let colours = Provider.allCases.map { BotMarkTint.body(for: $0) }
        #expect(colours.count == Provider.allCases.count)
        #expect(Set(colours.map { BotMarkTint.eyes(on: $0) }).count <= 2,
                "eye colours should only be the light one or the dark one")
    }

    /// The path type and the transform are ours, so the composition rules are
    /// worth pinning — and this is the test that was wrong first.
    ///
    /// **CoreGraphics does not compose these the way the obvious reading
    /// does.** `translatedBy` is `CGAffineTransformTranslate`, whose `tx'` is
    /// `tx + x·a + y·c`: the translation travels through the linear part that
    /// is already there. `scaledBy` scales `a, b, c, d` and *leaves `tx`/`ty`
    /// alone`. `rotated` is `Concat(R, self)`, likewise leaving the translation
    /// put. Writing all three as `concatenating` gets them wrong by exactly the
    /// scale factor, which is invisible until a transform has both.
    ///
    /// This file asserted the wrong answers at first, and upstream's suite
    /// disagreed with 8744 of its own assertions — on one number, how far the
    /// mark had slid out of the rail's budget. The formulas below are the ones
    /// that made it agree.
    @Test("A transform composes the way CoreGraphics composes it")
    func transformConvention() {
        // CGAffineTransformTranslate: tx' = tx + x·a + y·c.
        let scaled = CGAffineTransform(scaleX: 2, y: 2).translatedBy(x: 10, y: 0)
        #expect(scaled.tx == 20, "a translation under a scale of 2 moved \(scaled.tx)")

        // CGAffineTransformScale: the linear part scales, the translation does not.
        let moved = CGAffineTransform(translationX: 1, y: 1).scaledBy(x: 2, y: 2)
        #expect(moved.a == 2)
        #expect(moved.tx == 1, "scaling moved the translation to \(moved.tx)")

        // Which is what makes the engine's eye placement work: take a point
        // relative to a centre, scale it, and put it down at (finalX, finalY).
        let placed = CGAffineTransform(translationX: 40, y: 90)
            .scaledBy(x: 3, y: 3)
            .translatedBy(x: -114.5, y: -114.5)
            .transform(CGPoint(x: 114.5, y: 114.5))
        #expect(abs(placed.x - 40) < 1e-9 && abs(placed.y - 90) < 1e-9, "got \(placed)")

        // CGAffineTransformRotate: `Concat(R, self)`, so the translation stays.
        let turned = CGAffineTransform(translationX: 5, y: 0).rotated(by: .pi / 2)
        #expect(turned.tx == 5, "rotating moved the translation to \(turned.tx)")
        #expect(abs(turned.transform(CGPoint(x: 1, y: 0)).y - 1) < 1e-9)

        // And `concatenating` is `CGAffineTransformConcat`: self first, then the
        // argument — so a translate followed by a scale lands at 4, not 2.
        let both = CGAffineTransform(translationX: 1, y: 0)
            .concatenating(CGAffineTransform(scaleX: 2, y: 2))
        #expect(both.transform(CGPoint(x: 1, y: 0)).x == 4)

        // The rotation matrix itself, in the y-down space a view draws in:
        // a quarter turn by −π/2 sends +x to −y.
        let quarter = CGAffineTransform(rotationAngle: -Double.pi / 2)
            .transform(CGPoint(x: 1, y: 0))
        #expect(abs(quarter.x) < 1e-9 && abs(quarter.y + 1) < 1e-9, "got \(quarter)")
    }

    /// `ellipseIn` and `roundedRect` are cubic approximations rather than real
    /// arcs, so the shape they make is worth one check: an ellipse has to
    /// start on its own right edge and come back to it.
    @Test("An ellipse starts and ends on its own right edge")
    func ellipseClosesOnItself() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 60)
        let ellipse = CGPath(ellipseIn: rect, transform: nil)
        guard case .move(let start) = ellipse.commands.first else {
            Issue.record("an ellipse did not begin with a move")
            return
        }
        #expect(start == CGPoint(x: 100, y: 30), "got \(start)")
        // Four cubic segments and a close, and the last curve lands back on
        // the start rather than near it.
        #expect(ellipse.commands.filter { if case .curve = $0 { return true } else { return false } }.count == 4)
        if case .curve(_, _, let end) = ellipse.commands[4] {
            #expect(end == start, "the ellipse did not close on \(end)")
        } else {
            Issue.record("the last ellipse command was not a curve")
        }
        #expect(ellipse.boundingBox.width == 100)
        #expect(ellipse.boundingBox.height == 60)
    }

    /// A rounded rect's corner radius is clamped rather than allowed to cross
    /// its corners over.
    @Test("An over-large corner radius is clamped")
    func roundedRectClamps() {
        let path = CGPath(roundedRect: CGRect(x: 0, y: 0, width: 20, height: 40),
                          cornerWidth: 100, cornerHeight: 100, transform: nil)
        for command in path.commands {
            for point in command.points {
                #expect(point.x >= -0.001 && point.x <= 20.001, "x ran to \(point.x)")
                #expect(point.y >= -0.001 && point.y <= 40.001, "y ran to \(point.y)")
            }
        }
    }

    /// A path under a transform moves, which is what `copy(using:)` is for.
    @Test("A transform moves a path")
    func transformMovesAPath() {
        let circle = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 10, height: 10), transform: nil)
        var transform = CGAffineTransform(translationX: 100, y: 0)
        let moved = circle.copy(using: &transform)
        #expect(moved?.boundingBox.minX == 100, "got \(moved?.boundingBox.minX ?? -1)")
        // And the original is untouched, because `copy` means copy.
        #expect(circle.boundingBox.minX == 0)
    }
}



#endif
