import Foundation

@testable import Pulse

/// A `PanelCanvas` that writes down what it was asked to draw.
///
/// **What makes the renderer testable without a display.** Everything the panel
/// draws goes through fifteen verbs, so a canvas that records them turns "does
/// the rail look right" into an assertion — which matters because the
/// alternatives are a screenshot on a machine that has a session, or CI
/// comparing a PNG nobody can read.
///
/// It is deliberately not a mock with expectations. It records, and the tests
/// ask it questions; a canvas that asserted as it went would have to know what
/// each test was about.
@MainActor
final class RecordingCanvas: PanelCanvas {
    /// Every call, in order.
    enum Event: Equatable {
        case move(CGPoint)
        case line(CGPoint)
        case curve(CGPoint)
        case arc(centre: CGPoint, radius: Double, start: Double, end: Double, clockwise: Bool)
        case close
        case fill(Color, opacity: Double)
        case fillGradient([Color], opacity: Double)
        case stroke(Color, opacity: Double, width: Double)
        case fillKeepingPath(Color, opacity: Double)
        case clip
        case newPath
        case newSubPath
        case save
        case restore
        case translate(x: Double, y: Double)
        case text(String, centre: CGPoint, size: Double, colour: Color,
                  opacity: Double, bold: Bool)
        case fillRule(evenOdd: Bool)
    }

    private(set) var events: [Event] = []

    /// Every stroke, which is what most of the questions are about.
    var strokes: [(colour: Color, opacity: Double, width: Double)] {
        events.compactMap {
            if case .stroke(let colour, let opacity, let width) = $0 {
                return (colour, opacity, width)
            }
            return nil
        }
    }

    var texts: [(string: String, centre: CGPoint, size: Double, opacity: Double)] {
        events.compactMap {
            if case .text(let string, let centre, let size, _, let opacity, _) = $0 {
                return (string, centre, size, opacity)
            }
            return nil
        }
    }

    /// The arcs drawn as full circles, which is how the rail draws a ring and
    /// its track apart from the fraction of it that is used.
    var fullCircles: [Double] {
        events.compactMap {
            if case .arc(_, let radius, let start, let end, _) = $0,
               abs((end - start) - 2 * .pi) < 1e-9 {
                return radius
            }
            return nil
        }
    }

    /// Partial arcs — the used fraction, the working mark, the clock.
    var arcs: [(start: Double, end: Double, radius: Double)] {
        events.compactMap {
            if case .arc(_, let radius, let start, let end, _) = $0,
               abs((end - start) - 2 * .pi) > 1e-9 {
                return (start, end, radius)
            }
            return nil
        }
    }

    func move(to point: CGPoint) { events.append(.move(point)) }
    func line(to point: CGPoint) { events.append(.line(point)) }
    func curve(to point: CGPoint, control1: CGPoint, control2: CGPoint) {
        events.append(.curve(point))
    }
    func arc(centre: CGPoint, radius: Double, start: Double, end: Double, clockwise: Bool) {
        events.append(.arc(centre: centre, radius: radius, start: start, end: end,
                           clockwise: clockwise))
    }
    func close() { events.append(.close) }
    func setFillRule(evenOdd: Bool) { events.append(.fillRule(evenOdd: evenOdd)) }
    func fill(_ colour: Color, opacity: Double) { events.append(.fill(colour, opacity: opacity)) }
    func fillGradient(_ stops: [Color], from: CGPoint, to: CGPoint, opacity: Double) {
        events.append(.fillGradient(stops, opacity: opacity))
    }
    func stroke(_ colour: Color, opacity: Double, width: Double) {
        events.append(.stroke(colour, opacity: opacity, width: width))
    }
    func fillKeepingPath(_ colour: Color, opacity: Double) {
        events.append(.fillKeepingPath(colour, opacity: opacity))
    }
    func clip() { events.append(.clip) }
    func newPath() { events.append(.newPath) }
    func newSubPath() { events.append(.newSubPath) }
    func save() { events.append(.save) }
    func restore() { events.append(.restore) }
    func translate(x: Double, y: Double) { events.append(.translate(x: x, y: y)) }
    func text(_ string: String, centre: CGPoint, size: Double, colour: Color,
              opacity: Double, bold: Bool) {
        events.append(.text(string, centre: centre, size: size, colour: colour,
                            opacity: opacity, bold: bold))
    }
    /// A crude stand-in for Pango, and honest about it: every glyph is six
    /// tenths of the size. The tests that use it ask about *whether* something
    /// was drawn and where it was centred, not how wide it came out.
    func measure(_ string: String, size: Double, bold: Bool) -> Double {
        Double(string.count) * size * 0.6
    }
}
