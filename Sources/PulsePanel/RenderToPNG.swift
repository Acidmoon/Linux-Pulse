import CGTK4
import Foundation
import Pulse

/// Draws the panel into a PNG, with no display and no window manager.
///
/// **The evidence that the panel looks like the panel.** Everything about this
/// port can be checked against a measurement or a test except the one thing the
/// goal is about — whether it opens and looks right — and a screenshot needs a
/// screenshot tool, a session, and a person to look at it. This needs none of
/// the three: the rail is drawn through `PanelModel.draw` into an image surface,
/// exactly as the window draws it into a widget, and written out.
///
/// It is also what makes the *appearance* testable. A CI run can render and
/// check that the file is non-empty and the expected sizes; a person can open
/// it. Both are better than "it compiled".
@MainActor
enum RenderToPNG {
    /// `monitor` is the screen the rail thinks it is on, in X11 terms. It only
    /// has to be a plausible rectangle: nothing is drawn outside the panel, and
    /// the placement maths needs a screen to measure the rail against.
    /// `railOnly` renders just the strip the rail occupies, at its own size,
    /// instead of the whole window. The window is 1822pt tall because it has to
    /// hold a rail with every provider switched on and the card that unfolds
    /// beside it — so a render of the whole thing is mostly empty space, and the
    /// part worth looking at is a sixth of the image. This is for looking at.
    static func run(path: String, size: CGSize?, monitor: CGRect,
                    railOnly: Bool = false, pointers: [CGPoint] = [],
                    seconds: Double = 3) async -> Int32 {
        let model = PanelModel()
        // Started, which reads last time's numbers off disk. Nothing is
        // *fetched* — the pass `start()` kicks off will fail without a network
        // in most CI runs and that is fine — so a render is deterministic and
        // works offline, against whatever `pulse --refresh` last stored.
        model.refresh()

        // The disk read is a `Task` inside the store, so the readings appear a
        // moment after `refresh()` returns rather than during it. Waiting for
        // them is the difference between rendering a rail and rendering an
        // empty rectangle; the bound is there so a machine with no cache at all
        // still produces an image.
        let deadline = Date().addingTimeInterval(2)
        while !model.hasAnyReading, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }

        // Three seconds of animation, stepped the way the window steps it, so a
        // rendered frame is a frame the panel would really have drawn rather
        // than the first one before the springs have settled.
        model.geometry(forScreen: monitor)
        let start = Date(timeIntervalSinceReferenceDate: 700_000_000)
        // **Pointers, in order, so the hover states can be seen without a
        // mouse.** The rail is collapsed until something is under the pointer,
        // and *only the sliver's own target counts while it is collapsed* —
        // upstream's rule, and the reason a single pointer placed on a ring
        // renders the sliver: there is no ring there yet. So a render that wants
        // to show a selected ring has to arrive the way a hand does — at the
        // edge first, then onto the ring — with a second between them.
        let step = 1.0 / 30
        let frames = Int(seconds / step)
        let perPointer = max(frames / max(pointers.count, 1), 1)
        var applied = 0
        for index in 0...frames {
            if applied < pointers.count, index >= applied * perPointer {
                model.setPointer(pointers[applied])
                applied += 1
            }
            model.advance(to: start.addingTimeInterval(Double(index) * step))
        }

        let extent = size ?? (railOnly ? model.railSize : model.panelSize)
        guard let surface = pulse_image_surface_new(Int32(extent.width), Int32(extent.height)),
              let context = pulse_context_new(surface) else {
            FileHandle.standardError.write(Data("Pulse: could not make a drawing surface.\n".utf8))
            return 1
        }
        defer {
            pulse_context_destroy(context)
            pulse_surface_destroy(surface)
        }

        // Cleared to nothing first, because the window is transparent and the
        // rail is the only thing on it — the same two lines the draw callback
        // does before it calls in.
        cairo_set_operator(context, CAIRO_OPERATOR_SOURCE)
        cairo_set_source_rgba(context, 0, 0, 0, 0)
        cairo_paint(context)
        cairo_set_operator(context, CAIRO_OPERATOR_OVER)

        let canvas = CairoCanvas(context)
        if railOnly {
            // The rail's own origin taken back out, so the strip is drawn at the
            // image's top-left however the window happened to place it.
            let origin = model.railOrigin
            canvas.translate(x: -origin.x, y: -origin.y)
        }
        model.draw(into: canvas, size: extent, at: start.addingTimeInterval(3))

        let status = pulse_surface_write_png(surface, path)
        guard status == 0 else {
            FileHandle.standardError.write(Data(
                "Pulse: could not write \(path) (Cairo status \(status)).\n".utf8))
            return 1
        }
        print("Pulse: wrote \(path) — \(Int(extent.width))×\(Int(extent.height)), "
              + "\(model.summary).")
        return 0
    }
}
