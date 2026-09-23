#if !canImport(AppKit)
import Foundation

/// Everything the Linux panel shows, in the module that owns the frame.
///
/// **Here rather than in the panel executable on purpose.** The rail's contents
/// are upstream's rules (`RailEntryBuilder`), the mark is upstream's engine, and
/// the geometry is upstream's `DockLayout` — all of it internal to this module.
/// A second target could only reach them through an access-level change spread
/// over four thousand lines. So the model lives here and the executable is the
/// two things that genuinely cannot be here: a GTK window and a Cairo binding.
///
/// **`@MainActor`, and the bridge to GTK is one line in the panel.** Every type
/// it touches — `AppSettings`, `UsageStore`, `UsageStore.usage(for:)` — is
/// main-actor bound, so the model is too. GTK calls a draw callback on the main
/// thread, which means the panel can `MainActor.assumeIsolated` around its two
/// calls into this and be telling the truth: it is a fact about GTK's threading
/// that GTK documents, stated once where the C function pointer is.
/// Which screen edge the rail is welded to, for a caller that has to tell a
/// compositor about it. `PanelEdge` is internal and this is the one bit of it
/// the panel executable needs, so it is spelled out rather than exported.
package enum PanelSide: Sendable {
    case left
    case right
    case top
}

/// Where the panel's window goes and where the rail goes inside it.
///
/// A struct of four numbers rather than `PanelPlacement.Layout`, because that
/// one is an internal type and this crosses into the panel executable — which
/// is the only thing that needs to know a screen position at all.
package struct PanelGeometry {
    /// The window's top-left corner, in the monitor's own top-down space.
    package let windowOrigin: CGPoint
    package let size: CGSize
    /// The rail's top-left corner inside the window.
    package let railOrigin: CGPoint
    /// The edge the rail is docked to. Meaningless when it is floating, where
    /// the rail is not against an edge at all.
    package let side: PanelSide
}

@MainActor
package final class PanelModel {
    private let settings: AppSettings
    private let store: UsageStore

    /// Where the rail is docked and how it is parked.
    private(set) var placement: PanelPlacement

    /// One engine per ring, kept across frames so the springs carry — the same
    /// thing `BotMarkView` keeps in `@State`, and for the same reason: a new
    /// engine every frame would restart every spring and the mark would stand
    /// still.
    private var engines: [String: BotMarkEngine] = [:]

    private var entries: [RailEntry] = []
    /// Dealt across the rail, so two neighbouring marks are different colours.
    private var botTints: [Color] = []
    /// Who says it. A chosen persona wins over the deal.
    private var personas: [BotMarkPersona] = []
    /// Everything worth looking at is away from the edge the rail is on.
    private var gaze: BotMarkGaze = .ahead

    /// The pointer, in the panel's own top-left space, or nil when it is off.
    private var pointer: CGPoint?
    private var isQuiet = false
    private var lastActivity = Date()
    /// The minute the window clock is drawn against, and only when it is on.
    private var minute = Date()

    /// The last frame each ring drew, kept so the draw callback has something
    /// to paint between advances and so a canvas can be redrawn without
    /// stepping time.
    private var frames: [String: BotMarkFrame] = [:]

    package init() {
        let settings = AppSettings.restored()
        self.settings = settings
        self.store = UsageStore(settings: settings)
        // `PanelPlacement()` restores the edge and the floating/docked choice from
        // the reader's own settings — it is where upstream reads them too, and
        // nothing here should have a second opinion about where the rail goes.
        self.placement = PanelPlacement()
        rebuildEntries(at: Date())
    }

    // MARK: - Size and placement

    /// The panel window's size, which is its maximum and not the rail's: the
    /// card unfolds into it, and a window that grew when a card opened would
    /// move the coordinate space the rail is laid out in mid-animation. Upstream
    /// says the same thing at length in `FloatingPanelController.Layout`.
    package var panelSize: CGSize { PanelLayout.size(for: placement.edge) }

    /// Where the rail sits inside the panel, which is what everything else is
    /// measured against.
    package var railSize: CGSize {
        DockLayout.size(for: entries.count, on: placement.edge.axis, docked: placement.isDocked)
    }

    /// Internal: `PanelEdge` is an internal type, so these cannot be `package`
    /// — and the panel executable does not need them. It asks for a size, a
    /// draw and a hit test, and everything else stays in here.
    var isDocked: Bool { placement.isDocked }
    var edge: PanelEdge { placement.edge }

    /// Where the rail sits inside the window, in the panel's own top-left space.
    /// Written by `geometry(forScreen:)` from the placement's answer, and read
    /// by the renderer — so the rail is drawn where the window manager actually
    /// put the window, not where it was asked to put it.
    package private(set) var railOrigin: CGPoint = .zero

    /// Where the window goes and where the rail goes inside it, for a monitor
    /// given in **X11 and Wayland terms**: top-left origin, y increasing
    /// downwards.
    ///
    /// **The flip lives here and nowhere else.** `PanelPlacement` is upstream's
    /// and works in AppKit's screen space, which runs bottom-up — its own
    /// comment says ratio 0, the rail at the top, is the *highest* y. So the
    /// monitor goes in as a bottom-up rectangle built from the same numbers and
    /// the answer comes back flipped: `y_topDown = monitor.minY + monitor.height
    /// - y_appKit`.
    ///
    /// Getting this backwards is not subtle — the rail appears at the bottom
    /// when it was put at the top — and a port discovers that at runtime, so it
    /// is stated here rather than buried in the arithmetic.
    package func geometry(forScreen monitor: CGRect) -> PanelGeometry {
        let top = monitor.minY + monitor.height
        let appKit = CGRect(x: monitor.minX, y: monitor.minY,
                            width: monitor.width, height: monitor.height)
        let layout = placement.layout(in: appKit, topEdge: top,
                                      panel: panelSize, rail: railSize)
        let windowOrigin = CGPoint(x: layout.frame.minX, y: top - layout.frame.maxY)
        let rail = CGPoint(x: layout.railOrigin.x - layout.frame.minX,
                           y: layout.frame.maxY - layout.railOrigin.y)
        railOrigin = rail
        let side: PanelSide = switch placement.edge {
        case .left: .left
        case .right: .right
        case .top: .top
        }
        return PanelGeometry(windowOrigin: windowOrigin, size: panelSize,
                             railOrigin: rail, side: side)
    }

    // MARK: - Readings

    /// Starts the store and asks for a pass, if one is not already running.
    ///
    /// **`start()`, not `refresh()`.** They look alike and are not: `start()` is
    /// what reads last time's numbers off disk and puts them on the rail before
    /// the first request goes out, so the panel shows something during the
    /// second a cold start takes. Calling `refresh()` alone skips that load
    /// entirely — measured, by a panel that reported "0 with a reading" for a
    /// provider `pulse --json` was showing at 10%.
    ///
    /// Safe to call more than once: `start()` returns early once it is
    /// observing, and the store paces the passes from there.
    package func refresh() {
        store.start()
    }

    /// Whether any ring has a reading yet. A render waits for this; the window
    /// does not, because it is redrawn thirty times a second either way.
    package var hasAnyReading: Bool {
        entries.contains { $0.headline != nil || $0.figure != nil }
    }

    // MARK: - The clock

    /// One animation step. Called at 30fps by the panel's timer, which is the
    /// rate upstream's view chose: everything the mark plays is slow, and seven
    /// engines redrawing at the display's rate is work nobody can see.
    package func advance(to date: Date) {
        minute = date
        if date.timeIntervalSince(lastActivity) > 20 * 60 { isQuiet = true }
        rebuildEntries(at: date)

        for (index, entry) in entries.enumerated() {
            let engine = engines[entry.id] ?? {
                let engine = BotMarkEngine()
                engines[entry.id] = engine
                return engine
            }()

            var programme = BotMarkProgramme.forMood(
                mood(for: entry),
                persona: personas.indices.contains(index) ? personas[index] : .calm,
                isQuiet: isQuiet,
                isPointedAt: false,
                at: date
            )
            programme.event = entry.botEvent
            programme.shape = entry.botBody.shape
            programme.gazeBias = gaze.bias
            programme.flipX = gaze.mirrored
            programme.color = markColour(index: index, entry: entry)
            programme.eyeColor = BotMarkTint.eyes(on: programme.color)
            programme.viewWidth = DockLayout.ringDiameter
            programme.pointer = nil

            frames[entry.id] = engine.advance(to: date.timeIntervalSinceReferenceDate,
                                              programme: programme)
            configurations[entry.id] = programme.configuration(for: engine.state)
        }
    }

    /// The last frame a ring drew, if it has drawn one. `BotMarkFrame` is
    /// internal, so these are too — see `railEntries`.
    func frame(for id: String) -> BotMarkFrame? { frames[id] }
    func configuration(for id: String) -> BotMarkConfig? { configurations[id] }
    private var configurations: [String: BotMarkConfig] = [:]

    /// The rings, in rail order. **Internal, not `package`**: `RailEntry` is an
    /// internal type, so a `package` member cannot name it. The renderer is in
    /// this module and reads it directly; the panel executable never does, and
    /// that is the point of the split.
    var railEntries: [RailEntry] { entries }

    /// What the mark is doing, which `BotMarkMood.resolve` decides and this only
    /// feeds. Nothing here looks at the warning threshold: how close a limit is,
    /// is what the ring's colour means.
    private func mood(for entry: RailEntry) -> BotMarkMood {
        let spent = UsageTint.isSpent(entry.headline) || (entry.headline?.usedFraction ?? 0) >= 1
        return BotMarkMood.resolve(
            isBusy: entry.isRunning,
            isRefreshing: entry.isRefreshing,
            isSpent: spent,
            hasReading: entry.headline != nil || entry.figure != nil
        )
    }

    /// The body colour: a chosen one, or the brand colour dealt across the rail.
    private func markColour(index: Int, entry: RailEntry) -> Color {
        if let chosen = entry.botColour { return chosen }
        if index < botTints.count { return botTints[index] }
        return BotMarkTint.body(for: entry.usage.provider)
    }

    private func rebuildEntries(at date: Date) {
        let rebuilt = RailEntryBuilder.entries(settings: settings, store: store, minute: date)
        do {
            // Only recomputed when the rail's *shape* changes: the deal runs
            // forty stride-and-rotation combinations, and doing that 30 times a
            // second would be work for an answer that only changes when a
            // provider is switched on or off.
            if rebuilt.map(\.id) != entries.map(\.id) || rebuilt.count != entries.count {
                botTints = rebuilt.contains(where: \.showsBotMark)
                    ? BotMarkTint.deal(over: rebuilt.map(\.usage.provider),
                                       chosen: rebuilt.map(\.botColour))
                    : []
                personas = rebuilt.enumerated().map { index, entry in
                    entry.botPersona ?? BotMarkPersona.automatic(at: index)
                }
            }
            // The colours can change without the rail changing shape — a brand
            // colour is chosen in Settings — so they are dealt again whenever
            // the ids change or there are no dealt colours yet.
            if botTints.isEmpty, rebuilt.contains(where: \.showsBotMark) {
                botTints = BotMarkTint.deal(over: rebuilt.map(\.usage.provider),
                                            chosen: rebuilt.map(\.botColour))
            }
            entries = rebuilt
            gaze = BotMarkGaze(edge: placement.edge)
        }
        if rebuilt.contains(where: \.isRunning) {
            lastActivity = date
            isQuiet = false
        }
    }

    /// How many rings the rail is showing. For the renderer's own report, and
    /// for a caller that wants to know whether it drew anything at all.
    package var railCount: Int { entries.count }

    /// One line about what the model is holding, for a headless render. A panel
    /// that draws nothing is either a settings question or a bug, and the two
    /// look identical from the outside.
    package var summary: String {
        let accounts = settings.shownAccounts.count
        let ready = entries.filter { $0.headline != nil }.count
        let rail = railOrigin
        return "\(accounts) enabled account\(accounts == 1 ? "" : "s"), "
            + "\(entries.count) rail slot\(entries.count == 1 ? "" : "s"), "
            + "\(ready) with a reading; rail at (\(Int(rail.x)), \(Int(rail.y))) "
            + "of \(Int(panelSize.width))×\(Int(panelSize.height))"
    }

    /// Draws everything. The one entry point the panel executable calls.
    package func draw(into canvas: PanelCanvas, size: CGSize, at date: Date) {
        PanelRailRenderer.draw(entries, model: self, into: canvas, size: size)
    }

    /// The pointer moved, in the panel's own top-left space. Nil when it left.
    package func setPointer(_ point: CGPoint?) {
        pointer = point
        if point != nil { lastActivity = Date(); isQuiet = false }
    }
}
#endif
