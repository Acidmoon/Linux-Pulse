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
    private(set) var pointer: CGPoint?
    /// Whether the pointer is on something the panel is drawing — the sliver
    /// when it is collapsed, the rail and the card's band when it is not.
    private var isHovered = false
    /// How far open the rail is, 0 to 1, on a spring. Upstream animates this
    /// with `.spring(response: 0.32, dampingFraction: 0.86)`, which is this
    /// spring's `frequency: 2π/0.32` and `damping: 0.86` — `BotMarkSpring` is
    /// already in the module and is the same integrator the mark uses.
    private var openness = BotMarkSpring(0)
    /// The ring the pointer is on, if any.
    package private(set) var selectedSlot: String?
    private var isQuiet = false
    private var lastActivity = Date()
    private var lastAdvance = Date()
    /// When the rail's contents were last rebuilt. Slower than the frame rate:
    /// see `advance`.
    private var lastEntryBuild = Date.distantPast
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
        // **`restored()`, not `PanelPlacement()`.** The bare initializer is the
        // *default* placement — docked right, centred — and says so: upstream
        // writes `PanelPlacement(dock: .edge(.right), ...)` as its no-argument
        // case. `restored()` is the one that reads the reader's own edge, dock
        // and ratios.
        //
        // The first version called `PanelPlacement()` with a comment claiming it
        // restored the settings, which it does not, so every choice made in the
        // settings file was silently overridden by the default: a rail set to the
        // left edge appeared on the right. Found by running it against a
        // settings file that had been set to the left.
        self.placement = PanelPlacement.restored()
        rebuildEntries(at: Date())
    }

    // MARK: - Size and placement

    /// What the placement is, for a diagnostic.  is internal to the
    /// target and the panel is a different one.
    package func placementSummary() -> String { "\(placement) \(panelSize)" }

    /// Re-reads the settings and applies them to the objects the panel is
    /// already using. This is the panel end of `pulse --place`.
    ///
    /// **The same objects, re-filled — not new ones.** `UsageStore` keeps its
    /// `AppSettings` for as long as it lives, so handing the model a fresh
    /// instance would leave the store reading accounts out of the old one and
    /// the rail disagreeing with itself about which providers are on. Writing
    /// each field through the live instance keeps one source of truth, and the
    /// `didSet`s that already exist do the rest of the work — including
    /// refusing to empty the rail, which is the same rule as ever.
    ///
    /// Only the settings a reader can change from outside are copied. The rest
    /// — the card's metrics, the language — are read where they are used and
    /// need no reload.
    package func reloadSettings() {
        settings.adoptCommandLineSettings()
        placement = PanelPlacement.reloaded()
        // The rail's shape follows from which accounts are on it, so it is
        // rebuilt rather than merely redrawn — a provider switched on from the
        // command line has no ring until this runs.
        rebuildEntries(at: Date())
    }

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

    /// The monitor the last `geometry(forScreen:)` was asked about, and the
    /// rail's top-left in that space as *requested*. Kept so the correction
    /// below can be made against the frame the window actually got.
    private var monitorRect: CGRect = .zero
    private var requestedRailTopLeft: CGPoint = .zero
    /// The window's top edge in AppKit terms, which is what the flip needs.
    private var screenTop: Double = 0

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
        // **Never taller or wider than the screen.** Upstream's `PanelLayout`
        // computes the *maximum* the panel could need — a rail with every
        // provider switched on plus the card that unfolds beside it, which is
        // 1822 points on a laptop. A Mac's AppKit constrains the frame and moves
        // on. KWin **maximises** it instead, and a maximised window ignores
        // `XMoveWindow` — measured: the panel asked for the right-hand edge and
        // appeared centred, with `_NET_WM_STATE_MAXIMIZED_VERT` set on it. The
        // rail still fits, because `confirmWindow` re-derives its offsets from
        // the frame the window actually got.
        let maximum = CGSize(width: min(panelSize.width, appKit.width),
                             height: min(panelSize.height, appKit.height))
        let layout = placement.layout(in: appKit, topEdge: top,
                                      panel: maximum, rail: railSize)
        let windowOrigin = CGPoint(x: layout.frame.minX, y: top - layout.frame.maxY)
        let rail = CGPoint(x: layout.railOrigin.x - layout.frame.minX,
                           y: layout.frame.maxY - layout.railOrigin.y)
        railOrigin = rail
        monitorRect = appKit
        screenTop = top
        // The rail's top-left in AppKit terms, which is what `offsets` wants.
        requestedRailTopLeft = CGPoint(x: layout.railOrigin.x, y: layout.railOrigin.y)

        let side: PanelSide = switch placement.edge {
        case .left: .left
        case .right: .right
        case .top: .top
        }
        return PanelGeometry(windowOrigin: windowOrigin, size: maximum,
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

    /// Refreshes one ring's account, which is what a click on a ring is for.
    ///
    /// Upstream's `onRefresh`, wired to the same `UsageStore.refresh(_:)`. The
    /// ring under the pointer is chosen by the same hit test that opens its
    /// card, so what a click refreshes is what the reader was pointing at.
    package func refresh(_ slotID: String) {
        guard let entry = entries.first(where: { $0.id == slotID }) else { return }
        store.refresh(entry.slot.account)
        lastActivity = Date()
        isQuiet = false
    }

    /// Which ring is under a point, if any — for a click rather than a hover.
    /// The rail has to be open: a collapsed rail is not showing any rings.
    package func slotID(at point: CGPoint) -> String? {
        guard openness.value >= 0.5 else { return nil }
        return PanelHitArea.slot(at: point, edge: placement.edge,
                                 slots: entries.map(\.slot),
                                 railTop: railOrigin.y, railLeading: railOrigin.x,
                                 docked: placement.isDocked)?.id
    }

    /// Whether anything on the rail is **moving**, so the panel has to be drawn
    /// again.
    ///
    /// **Because redrawing a 342×1080 transparent window thirty times a second
    /// costs a quarter of a core to show a six-point sliver.** Measured: 26% of
    /// a core in a release build with one ring and nothing happening, which is
    /// the state the panel is in almost all of the time. Everything on this rail
    /// is either still or one of four things that move, so those four are what
    /// this asks about:
    ///
    ///   - the opening and closing spring, while it is still settling
    ///   - a CLI that is working — the travelling mark
    ///   - an account drawing the animated mark, which is never still
    ///   - a refresh in flight, which dims the arc until it lands
    ///
    /// The figure changing is the fifth, and it is not something that *moves* —
    /// it arrives — so it is a flag the entry rebuild sets rather than something
    /// this can see by looking.
    package var needsRedraw: Bool {
        if abs(openness.value - openness.target) > 0.001 || abs(openness.velocity) > 0.01 {
            return true
        }
        if contentChanged { return true }
        return entries.contains { $0.isRunning || $0.isRefreshing || $0.showsBotMark }
    }

    /// Whether last time's readings differ from this time's, set where they are
    /// rebuilt. Cleared by `takeRedrawRequest`.
    private var contentChanged = true

    /// One question, asked once per tick: draw, or not?
    ///
    /// The flag is cleared here rather than read, so a change that arrives while
    /// nothing else is moving gets exactly one frame.
    package func takeRedrawRequest() -> Bool {
        let wanted = needsRedraw
        contentChanged = false
        return wanted
    }

    /// The readings, as a value that changes when anything visible about them
    /// does. A signature rather than a comparison of the entries themselves,
    /// because comparing two arrays of `RailEntry` walks every window of every
    /// account thirty times a second.
    private var contentSignature: [String] = []

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
        // **The rail is rebuilt on a slower clock than it is drawn on.** A
        // reading arrives once a pass, which is minutes; doing it thirty times a
        // second was a third of this method's cost and none of its point. The
        // springs and the marks still keep their own time.
        if date.timeIntervalSince(lastEntryBuild) > 0.5 || entries.isEmpty {
            lastEntryBuild = date
            minute = date
            if date.timeIntervalSince(lastActivity) > 20 * 60 { isQuiet = true }
            rebuildEntries(at: date)
        }

        // **The target first, always, and only then whether to integrate.** The
        // first version of this put the target inside the "is it moving" test —
        // and that test compares the value against the target, so a rail at rest
        // with the pointer on it never set its target and never moved: hovering
        // did nothing at all. Found by pointing at it, not by reading it.
        openness.target = (isHovered || !placement.isDocked || !settings.autoCollapse) ? 1 : 0

        // And the integration only while there is something to integrate. A
        // settled spring is a multiply, an add and a comparison thirty times a
        // second for an answer that has not changed.
        let elapsed = min(max(date.timeIntervalSince(lastAdvance), 0), 0.25)
        lastAdvance = date
        if abs(openness.value - openness.target) > 0.0005 || abs(openness.velocity) > 0.005 {
            // Substepped the way the mark is: a spring integrated at 30fps and
            // at 120fps should reach the same place.
            var remaining = elapsed
            while remaining > 0 {
                let step = min(BotMath.fixedStep, remaining)
                openness.step(frequency: 2 * .pi / 0.32, damping: 0.86, delta: step)
                remaining -= step
            }
        } else {
            openness.value = openness.target
            openness.velocity = 0
        }

        // **And the marks are only advanced when a mark is on screen.** Nothing
        // else reads a frame, so a rail of logos does not need seven engines
        // stepped thirty times a second to have their answers thrown away.
        guard entries.contains(where: \.showsBotMark) else { return }

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
            // **The figure arriving is a reason to draw.** Everything else on
            // this rail is either still or one of the four things that move; a
            // new reading is neither — it just appears — so it is recorded here
            // rather than looked for by `needsRedraw`.
            let signature = rebuilt.map { "\($0.id):\($0.headline?.percentText ?? "-"):\($0.figure ?? "-"):\($0.isRunning)" }
            if signature != contentSignature {
                contentSignature = signature
                contentChanged = true
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

    /// **The rail's offsets, recomputed from the frame the window really got.**
    ///
    /// `PanelPlacement.layout` returns a frame that is a *request*. A panel as
    /// tall as a rail with every provider on is taller than a laptop screen, so
    /// the window manager shortens it — measured here: 1822 points asked for on
    /// a 1080-point display, 1024 given back. Offsets measured from a frame the
    /// window never had are relative to a position it is not in, and on this
    /// screen they put the rail below the bottom of its own window: invisible.
    ///
    /// Upstream's own comment on `offsets(forRailTopLeft:in:rail:)` describes
    /// exactly this, including the 72-point error it caused there. The
    /// arithmetic is theirs; this only supplies the frame.
    ///
    /// `origin` and `size` come from the window manager, in top-down screen
    /// coordinates.
    package func confirmWindow(origin: CGPoint, size: CGSize) {
        guard monitorRect != .zero else { return }
        let actual = CGRect(x: origin.x,
                            y: screenTop - (origin.y + size.height),
                            width: size.width, height: size.height)
        let offsets = PanelPlacement.offsets(forRailTopLeft: requestedRailTopLeft,
                                             in: actual, rail: railSize)
        // `leading` and `top` are already measured from the frame's top-left
        // corner — `top` is `frame.maxY - origin.y`, which in AppKit's y-up
        // space is a distance *down* from the top — so no flip is needed here.
        railOrigin = CGPoint(x: offsets.leading, y: offsets.top)

        // Said out loud when asked. Whether the rail is inside its own window is
        // not something a test can see, and a rail below the bottom of a
        // shortened window looks like a panel that failed to draw rather than
        // like arithmetic that used the wrong frame.
        if ProcessInfo.processInfo.environment["PULSE_PANEL_DEBUG"] != nil,
           settleReported < 1 {
            let fits = railOrigin.y + railSize.height <= size.height
            let line = "Pulse panel: window \(Int(size.width))x\(Int(size.height)) at "
                + "(\(Int(origin.x)), \(Int(origin.y))), asked for "
                + "\(Int(panelSize.width))x\(Int(panelSize.height)); rail "
                + "\(Int(railSize.width))x\(Int(railSize.height)) at "
                + "(\(Int(railOrigin.x)), \(Int(railOrigin.y))) - "
                + (fits ? "inside the window" : "**outside the window**")
            FileHandle.standardError.write(Data((line + "\n").utf8))
            // Reported once. The frame is confirmed on several draws while the
            // window manager settles, and only the last one is the answer.
            settleReported += 1
        }
    }

    /// How many times the geometry has been reported. For the debug line, which
    /// is about the settled frame rather than the four before it.
    package var settleReported = 0

    /// Called when the frame changes again, so the debug line describes the
    /// position the window finally took rather than an intermediate one.
    package func resetSettleReport() { settleReported = 0 }

    /// How far open the rail is, 0 to 1. Read by the renderer.
    package var railOpenness: Double { openness.value }

    /// Whether the rail's own motion is drawn: the travelling mark while a CLI
    /// works, and the refresh arc. Upstream's `animatesActivity`, which is off
    /// for a rail that is not on screen.
    package var animatesActivity: Bool { true }
    /// Whether the rail is open enough to draw its rings. Upstream fades them
    /// in on a delay so the berth opens first and the rings arrive into it.
    package var ringsOpacity: Double {
        let progress = min(max(openness.value, 0), 1)
        // The same shape as `.easeOut(duration: 0.18).delay(0.12)` behind a
        // 0.32-second spring: nothing for the first third, then most of it.
        let delayed = (progress - 0.3) / 0.7
        return min(max(delayed, 0), 1)
    }

    /// The monitor the rail is on, by index.
    package private(set) var monitorIndex: Int = 0

    /// Moves the rail to the display the pointer is on, if it has moved.
    ///
    /// Upstream's rule, and upstream's reason for it: **the pointer is the whole
    /// definition of "active"** — not the key window, not the frontmost app's
    /// frame, because an app can be focused on one display while the person is
    /// working on another.
    ///
    /// Returns the geometry to apply, or nil when there is nothing to do: the
    /// pointer has not changed display, no display can be named, or the panel is
    /// under the hand — moving it then would put it somewhere the pointer is not
    /// and the next sample would move it back, which reads as a flicker.
    ///
    /// **Not verifiable on this machine**, which has one display. What is
    /// checked here is that a single-display system never moves the panel.
    package func followPointer(pointerOnScreen pointer: CGPoint,
                               monitors: [(index: Int, rect: CGRect)]) -> PanelGeometry? {
        guard !monitors.isEmpty else { return nil }
        guard let target = monitors.first(where: { $0.rect.contains(pointer) }) else { return nil }
        guard target.index != monitorIndex else { return nil }
        // The rail's own rectangle, in screen coordinates — or the sliver's
        // target, which is what the pointer is actually on.
        let railOnScreen = CGRect(x: monitorRect.minX + railOrigin.x,
                                  y: monitorRect.minY + railOrigin.y,
                                  width: railSize.width, height: railSize.height)
        guard !railOnScreen.insetBy(dx: -PanelHitArea.slack, dy: -PanelHitArea.slack)
            .contains(pointer) else { return nil }

        monitorIndex = target.index
        return geometry(forScreen: target.rect)
    }

    /// The pointer moved, in the panel's own top-left space. Nil when it left.
    ///
    /// This is where the interaction lives: entering the sliver opens the rail,
    /// arriving on a ring selects it, and leaving the panel closes both. The
    /// rules are upstream's — `FloatingUsagePanelView.isOverContent` and
    /// `select(_:)` — because the difference between "the pointer is inside the
    /// window" and "the pointer is on something" is the difference between a
    /// panel that holds itself open over a corner of empty screen and one that
    /// closes when it should.
    package func setPointer(_ point: CGPoint?) {
        pointer = point
        guard let point else {
            isHovered = false
            selectedSlot = nil
            return
        }
        lastActivity = Date()
        isQuiet = false
        isHovered = isOverContent(point)
        // **A change of ring is a change of picture.** The ring under the
        // pointer is scaled and haloed, so moving from one to the next has to
        // be drawn — and nothing about a settled spring or an idle CLI would say
        // so. Without this the halo arrives on the next heartbeat, up to two
        // seconds later, which reads as the panel being slow rather than as the
        // optimisation it is.
        let previous = selectedSlot
        selectedSlot = selectedSlot(at: point)
        if selectedSlot != previous { contentChanged = true }
    }

    /// The strip's rectangle, for the debug line. Off-panel it is what the
    /// pointer has to be inside to open the rail, and a hover that does not work
    /// is almost always this rectangle and the pointer disagreeing.
    package var hoverStrip: CGRect {
        PanelHitArea.strip(edge: placement.edge, railSize: railSize,
                           railTop: railOrigin.y, railLeading: railOrigin.x)
    }

    /// Whether the pointer counts as being on the panel.
    private func isOverContent(_ point: CGPoint) -> Bool {
        let rail = railRect
        // **Collapsed, only the sliver's own target counts.** Testing the rail's
        // full extent would hold the panel open across sixty points of empty
        // space it is not drawing in.
        if openness.value < 0.5 {
            return PanelHitArea.strip(edge: placement.edge, railSize: railSize,
                                      railTop: railOrigin.y, railLeading: railOrigin.x)
                .contains(point)
        }
        if rail.contains(point) { return true }
        guard let selectedSlot, let index = entries.firstIndex(where: { $0.id == selectedSlot })
        else { return false }
        // The band the card unfolds into, full width across the panel and with
        // the same slack the rail's own edge gets — so the gap the pointer
        // crosses between the rail and the card is covered too.
        let windows = max(1, entries[index].usage.windows.count)
        let cardHeight = DetailCardLayout.height(forWindows: windows)
        let start = railCentre(index).y - cardHeight / 2 - PanelHitArea.slack
        return CGRect(x: 0, y: start, width: panelSize.width,
                      height: cardHeight + PanelHitArea.slack * 2).contains(point)
    }

    /// Which ring, if any, is under the pointer. Only when the rail is open:
    /// a collapsed rail is not showing any rings, and `PanelHitArea.slot`
    /// measures against the open rail's geometry.
    private func selectedSlot(at point: CGPoint) -> String? {
        guard openness.value >= 0.5 else { return nil }
        // Upstream's own hit test, which is also what `RailGeometryTests`
        // checks — so the ring the pointer opens is the ring the geometry says
        // is there, not a second opinion about where the rings are.
        return PanelHitArea.slot(at: point, edge: placement.edge,
                                 slots: entries.map(\.slot),
                                 railTop: railOrigin.y, railLeading: railOrigin.x,
                                 docked: placement.isDocked)?.id
    }

    /// The rail's rectangle inside the window.
    var railRect: CGRect { CGRect(origin: railOrigin, size: railSize) }

    /// **Where to put a pointer to open the rail, and to pick a ring.**
    ///
    /// A caller that wants to render the hover states would otherwise have to
    /// know the rail's geometry — the sliver's target is twenty points wide
    /// against the screen edge, and the rings step down the rail by a number
    /// that depends on how many of them there are. Every one of those numbers is
    /// here already, and a hardcoded pair of coordinates in a test or a CI job
    /// is a copy of them that goes stale the first time the rail changes.
    ///
    /// Nil when the rail is floating, where nothing is collapsed and the pointer
    /// does not have to arrive at an edge to open it.
    package var hoverPoints: (toOpen: CGPoint, toSelect: (Int) -> CGPoint) {
        let strip = PanelHitArea.strip(edge: placement.edge, railSize: railSize,
                                       railTop: railOrigin.y, railLeading: railOrigin.x)
        return (
            toOpen: CGPoint(x: strip.midX, y: strip.midY),
            toSelect: { index in self.railCentre(index) }
        )
    }

    /// The colour the collapsed sliver takes when a limit is close, or nil for
    /// black.
    ///
    /// **Only the sliver carries it.** Expanded, the rings already say which
    /// limit is where, and a coloured rail beside them would be the same fact
    /// told twice. Collapsed, the rail is six points against the screen edge and
    /// has no room to say anything else — so it says this, or it says nothing.
    ///
    /// `dockShowsAlertColor` off means never, upstream's reason being worth
    /// keeping: some rails stay past the threshold for as long as they are
    /// watched, and a permanently coloured line welded to the screen edge is
    /// worse than the thing it is warning about.
    package var alertTint: Color? {
        guard settings.dockShowsAlertColor else { return nil }
        guard let worst = entries.compactMap(\.headline)
            .max(by: { $0.usedFraction < $1.usedFraction }) else { return nil }
        let threshold = settings.warningThreshold.fraction
        guard worst.isExhausted || worst.usedFraction >= threshold else { return nil }
        return UsageTint.color(for: worst.usedFraction, isExhausted: worst.isExhausted,
                               warningAt: threshold)
    }

    /// **The part of the window that takes input.** Everything else is
    /// transparent and must let the click through to the desktop, which is what
    /// `gdk_surface_set_input_region` is for — a 342×1080 window that answers
    /// every click is not a panel, it is a wall.
    ///
    /// Collapsed it is the sliver's target; open it is the rail plus, when a
    /// card is showing, the band the card unfolds into — the same two rectangles
    /// `isOverContent` tests, so what holds the panel open and what takes the
    /// click cannot disagree.
    package var inputRegion: CGRect {
        let rail = railRect
        if openness.value < 0.5 {
            return PanelHitArea.strip(edge: placement.edge, railSize: railSize,
                                      railTop: railOrigin.y, railLeading: railOrigin.x)
        }
        guard let selectedSlot,
              let index = entries.firstIndex(where: { $0.id == selectedSlot }) else {
            return rail
        }
        let windows = max(1, entries[index].usage.windows.count)
        let height = DetailCardLayout.height(forWindows: windows)
        let centre = railCentre(index)
        // The rail and the card's band, joined — one bounding rectangle, since
        // an input region is a region and a union of two is two rectangles the
        // surface API cannot take without more machinery than this needs.
        return rail.union(CGRect(x: 0, y: centre.y - height / 2,
                                 width: panelSize.width, height: height))
    }

    /// Where a ring's centre is, in the panel's own space. The same sum the hit
    /// test walks, from the renderer that draws them.
    func railCentre(_ index: Int) -> CGPoint {
        PanelRailRenderer.ringCentre(index, in: railRect, edge: placement.edge,
                                     docked: placement.isDocked)
    }
}
#endif
