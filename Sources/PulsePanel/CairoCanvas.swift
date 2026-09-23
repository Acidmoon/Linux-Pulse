import CGTK4
import Foundation
import Pulse

/// `PanelCanvas` over a Cairo context.
///
/// **The whole of the GTK-to-Swift seam.** Everything above this in the panel is
/// a GTK call; everything below is the module's own drawing code, and the only
/// thing it knows about Cairo is the fifteen verbs it is handed. The alternative
/// — annotating upstream's panel sources with `package` so the renderer could
/// live in the executable — was a door four thousand lines wide.
///
/// Two conventions are settled here rather than left to be rediscovered:
///
///   - **Angles.** Cairo measures angles with y down, so increasing angle is
///     clockwise on screen — which is what `PanelCanvas.arc` means by
///     `clockwise`, so the flag picks `cairo_arc` against `cairo_arc_negative`
///     and nothing is flipped. The frame's own convention is the same one;
///     `PathCommand.arc` records it.
///   - **A standalone arc must not be joined to whatever was drawn before it.**
///     `cairo_arc` draws a line from the current point to the arc's start when
///     the path is not empty, which is CoreGraphics' behaviour for an arc *in* a
///     path and is wrong for a ring stroke. `newSubPath()` is the difference,
///     and the rail renderer calls it.
final class CairoCanvas: PanelCanvas {
    private let context: OpaquePointer

    init(_ context: OpaquePointer) {
        self.context = context
    }

    func move(to point: CGPoint) { cairo_move_to(context, point.x, point.y) }
    func line(to point: CGPoint) { cairo_line_to(context, point.x, point.y) }

    func curve(to point: CGPoint, control1: CGPoint, control2: CGPoint) {
        cairo_curve_to(context, control1.x, control1.y, control2.x, control2.y, point.x, point.y)
    }

    /// `clockwise` is increasing angle, which is what Cairo already does.
    func arc(centre: CGPoint, radius: Double, start: Double, end: Double, clockwise: Bool) {
        let travel = travel(from: start, to: end, clockwise: clockwise)
        if travel >= 0 {
            cairo_arc(context, centre.x, centre.y, radius, start, start + travel)
        } else {
            cairo_arc_negative(context, centre.x, centre.y, radius, start, start + travel)
        }
    }

    /// How far the arc goes, normalised into the direction asked for.
    ///
    /// **`(a, a + 2π)` is a whole circle and `(a, a)` is nothing**, so the
    /// remainder cannot be taken first: `2π mod 2π` is zero, and a full-circle
    /// track drawn as `cairo_arc(cr, x, y, r, 0, 0)` is a track that is not
    /// there. That was the first render — every ring's track missing, leaving
    /// the fraction arcs floating in the black.
    private func travel(from start: Double, to end: Double, clockwise: Bool) -> Double {
        var delta = (end - start).truncatingRemainder(dividingBy: 2 * .pi)
        if clockwise {
            if delta <= 0 { delta += 2 * .pi }
        } else if delta >= 0 {
            delta -= 2 * .pi
        }
        return delta
    }

    func close() { cairo_close_path(context) }

    func newPath() { cairo_new_path(context) }
    func newSubPath() { cairo_new_sub_path(context) }
    func save() { cairo_save(context) }
    func restore() { cairo_restore(context) }
    func translate(x: Double, y: Double) { cairo_translate(context, x, y) }
    func clip() { cairo_clip(context) }

    func setFillRule(evenOdd: Bool) {
        cairo_set_fill_rule(context, evenOdd ? CAIRO_FILL_RULE_EVEN_ODD : CAIRO_FILL_RULE_WINDING)
    }

    func fill(_ colour: Color, opacity: Double) {
        setSource(colour, opacity: opacity)
        cairo_fill(context)
    }

    func fillKeepingPath(_ colour: Color, opacity: Double) {
        setSource(colour, opacity: opacity)
        cairo_fill_preserve(context)
    }

    func stroke(_ colour: Color, opacity: Double, width: Double) {
        setSource(colour, opacity: opacity)
        cairo_set_line_width(context, width)
        // `StrokeStyle(lineCap: .round, lineJoin: .round)`, which is what every
        // arc and every stroked shape upstream draws asks for.
        cairo_set_line_cap(context, CAIRO_LINE_CAP_ROUND)
        cairo_set_line_join(context, CAIRO_LINE_JOIN_ROUND)
        cairo_stroke(context)
    }

    func fillGradient(_ stops: [Color], from: CGPoint, to: CGPoint, opacity: Double) {
        guard let pattern = cairo_pattern_create_linear(from.x, from.y, to.x, to.y) else {
            fill(stops.first ?? .white, opacity: opacity)
            return
        }
        for (index, stop) in stops.enumerated() {
            let offset = stops.count <= 1 ? 0 : Double(index) / Double(stops.count - 1)
            cairo_pattern_add_color_stop_rgba(pattern, offset, stop.red, stop.green,
                                              stop.blue, stop.opacity * opacity)
        }
        cairo_set_source(context, pattern)
        cairo_fill(context)
        cairo_pattern_destroy(pattern)
    }

    func text(_ string: String, centre: CGPoint, size: Double, colour: Color,
              opacity: Double, bold: Bool) {
        // Measured rather than guessed, so a figure that grows from "9%" to
        // "10%" grows about its own centre.
        let weight = Int32(bold ? PULSE_WEIGHT_SEMIBOLD : PULSE_WEIGHT_MEDIUM)
        let width = pulse_text_width(context, string, size, weight)
        let ascent = pulse_text_ascent(context, string, size, weight)
        pulse_text(context, centre.x - width / 2, centre.y + ascent / 2,
                   string, size, colour.red, colour.green, colour.blue,
                   colour.opacity * opacity, weight)
    }

    private func setSource(_ colour: Color, opacity: Double) {
        cairo_set_source_rgba(context, colour.red, colour.green, colour.blue,
                              colour.opacity * opacity)
    }
}
