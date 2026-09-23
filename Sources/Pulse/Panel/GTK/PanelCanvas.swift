#if !canImport(AppKit)
import Foundation

/// What the panel draws on.
///
/// **The seam that keeps GTK out of this module.** The renderer below walks a
/// `BotMarkFrame` and the rail's geometry, and everything it does is a handful
/// of verbs — move, curve, fill, clip, write a number. Naming those verbs means
/// the renderer can live with the frame it is drawing, in a module that has
/// never heard of Cairo; the panel executable implements this against
/// `gtk_drawing_area_set_draw_func`'s context and nothing above knows.
///
/// The alternative was annotating four thousand lines of upstream panel code
/// with `package` so a second target could reach `BotMarkConfig`'s thirty
/// fields. A protocol with fifteen methods is a smaller door, and it is the
/// smaller door for the right reason: the drawing is the part that has to be
/// replaced, and this is exactly its shape.
///
/// **Colours arrive as `Color` and opacities separately**, because that is how
/// the frame carries them — a shape has a fill and an opacity, a frame has a
/// body colour and an opacity of its own — and multiplying them is the back
/// end's business, not the renderer's. `CairoCanvas` does it in one place.
package protocol PanelCanvas: AnyObject {
    func move(to point: CGPoint)
    func line(to point: CGPoint)
    func curve(to point: CGPoint, control1: CGPoint, control2: CGPoint)
    /// An arc, in the frame's own angle convention: radians, clockwise on
    /// screen when `clockwise`, measured from the positive x axis.
    func arc(centre: CGPoint, radius: Double, start: Double, end: Double, clockwise: Bool)
    /// Starts a new subpath, so a following arc is not joined to whatever was
    /// drawn before it. Cairo draws a connecting line otherwise, which is right
    /// for an arc inside a path and wrong for a ring.
    func newSubPath()

    func close()

    func fill(_ colour: Color, opacity: Double)
    func fillGradient(_ stops: [Color], from: CGPoint, to: CGPoint, opacity: Double)
    func stroke(_ colour: Color, opacity: Double, width: Double)

    /// Fills and leaves the path in place, so the next call can clip to it.
    /// This is how the eyes are kept inside the head: one emission of the head
    /// outline, filled, then clipped, then the eyes drawn through the clip.
    func fillKeepingPath(_ colour: Color, opacity: Double)
    func clip()
    func newPath()

    func save()
    func restore()

    /// Shifts the origin. Used to put a mark's own box at the disc it stands
    /// on: the renderer draws in the frame's viewBox space and knows nothing
    /// about where on the rail that box is.
    func translate(x: Double, y: Double)

    /// A number or a word, centred on `centre`: horizontally on its measured
    /// width, and vertically on its own optical middle rather than on a
    /// baseline, because that is what the ring's geometry is expressed in. Pango
    /// measures both, so a figure that goes from "9%" to "10%" grows about the
    /// centre instead of shifting sideways.
    func text(_ string: String, centre: CGPoint, size: Double, colour: Color,
              opacity: Double, bold: Bool)
}
#endif
