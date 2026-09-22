// Moved out of `BotMarkView.swift`, where it was written.
//
// **An enum, not a view**, and it was only in that file because that is where
// it was first needed. It is its own file now because the engine and
// upstream's tests both use it — `gaze` is part of a programme — and the file
// it used to live in is the one part of BotMark that is genuinely rewritten,
// because it draws. Moving the enum is the whole change; nothing was renamed.
// pulse-linux: moved

/// Which way a mark habitually looks.
///
/// A rail against the right-hand edge of the screen has everything worth
/// looking at to its left, and a mark staring off the edge of the display
/// looks like it is facing a wall.
///
/// **Two mechanisms, because one of them cannot do it alone.** A standing
/// lean moves the middle of the mark's wandering gaze. Turning the gaze round
/// (`mirrored`) negates it. Only the turn can fix a pose that is
/// *intrinsically* lopsided — several upstream states and expressions rest
/// with the eyes well off to one side, and measured over ten minutes a
/// `sleepy` mark sat right of centre on 97% of frames no matter how hard the
/// lean pulled. Only the lean can fix a *symmetric* wander, which negating it
/// leaves exactly as symmetric as it found it. Both together are what stops a
/// right-hand rail facing the wall.
///
/// So the engine always leans the same way — `bias` is positive whichever
/// edge this is — and `mirrored` decides which way that lands.
///
/// **It turns the gaze, not the mark.** Mirroring the whole drawing aimed the
/// eyes correctly and looked ridiculous: the body flipped over like a card,
/// which is not what a character does when it looks the other way. The engine
/// scales its horizontal gaze terms instead, so the body stays put and the
/// eyes travel across — see `BotMarkEngine.facing`.
enum BotMarkGaze: Sendable {
    case ahead
    case left
    case right

    /// Enough to read as a direction at 16pt, and well short of the span
    /// clamp that pins an eye against the inside of the body.
    private static let lean = 7.0

    /// Always outward in the engine's own space. `mirrored` turns it around.
    var bias: Double { self == .ahead ? 0 : Self.lean }

    /// Whether the gaze is turned round. Only the left-facing case needs it:
    /// the engine's own lean already points right.
    var mirrored: Bool { self == .left }

    /// The rail's own edge decides it: docked right, look left; docked left,
    /// look right. A top rail runs horizontally and has screen on both sides,
    /// so it looks straight ahead.
    init(edge: PanelEdge) {
        switch edge {
        case .right: self = .left
        case .left: self = .right
        case .top: self = .ahead
        }
    }
}
