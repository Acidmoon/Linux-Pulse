import CGTK4
import CX11
#if canImport(CGTK4LayerShell)
import CGTK4LayerShell
#endif
import Foundation
import Pulse

/// The Linux panel.
///
/// **This file is the whole of the GTK side.** Everything it draws comes from
/// `Pulse`'s `PanelModel`, which owns the readings, the engines and the
/// geometry; everything it draws *onto* goes through `CairoCanvas`. What is left
/// here is a window, a timer, and the two platform answers for a rail that has
/// to stay on top and out of the task list.
///
/// ## Where the window goes, and two coordinate systems
///
/// `PanelPlacement.layout(in:topEdge:panel:rail:)` is upstream's placement and
/// it works in **AppKit's screen space, which runs bottom-up**: its own comment
/// says "ratio 0 — the rail at the top — is the *highest* y". X11 and Wayland
/// both run top-down from the monitor's top-left corner. So the monitor is
/// handed to `layout` as a bottom-up rectangle built from the same numbers, and
/// what comes back is flipped: a point at AppKit `y` on a monitor whose X11
/// origin is `my` and height is `mh` is at X11 `y = my + mh - y`.
///
/// Getting this wrong is not subtle — the rail appears at the bottom when it was
/// put at the top — and it is the kind of thing a port discovers at runtime, so
/// it is written down here rather than left in the arithmetic.
///
/// ## Staying on top
///
/// The two backends need different answers and neither is GTK's:
///
///   - **Wayland** has `wlr-layer-shell`, which is what it is for. The rail
///     anchors to an edge, sets the layer to `TOP`, and declines the keyboard.
///   - **X11** has no such protocol and GTK4 dropped `keep_above`. The window
///     asks the window manager in EWMH terms instead — see `Sources/CX11`.
///     Measured on this machine's KWin before any of it was written.
///
/// `gtk_layer_is_supported()` is asked at runtime, not compiled in: the same
/// binary runs both ways, and calling into layer-shell on X11 makes GTK log a
/// `CRITICAL` about `GDK_IS_WAYLAND_DISPLAY`.
@MainActor
final class Panel {
    private let model: PanelModel
    private var window: UnsafeMutablePointer<GtkWidget>?
    private var area: UnsafeMutablePointer<GtkWidget>?
    private var timer: UInt32 = 0
    /// The last frame read back, and how many times it has been read.
    ///
    /// **Confirmed until it stops changing, not once.** The window manager
    /// honours a move asynchronously, so the first read-back can describe the
    /// position the window had *before* the move — measured: one run in three
    /// reported the panel centred at (789, 0) while the next two reported
    /// (1578, 0), and with a single confirmation the first one kept it. Two
    /// identical reads in a row is the signal that the frame has settled.
    private var confirmedFrame = CGRect.zero
    private var confirmAttempts = 0

    /// The animation rate. 30fps, which is what upstream's SwiftUI view chose:
    /// everything the mark plays is slow, and seven engines redrawing at the
    /// display's rate is work nobody can see.
    private static let frameMilliseconds: UInt32 = 33

    init(model: PanelModel) {
        self.model = model
    }

    /// Builds the window and shows it. Called from GTK's `activate`, because a
    /// `GtkApplicationWindow` needs an application that is running.
    func present(application: UnsafeMutablePointer<GtkApplication>) {
        let window = pulse_application_window(application)
        self.window = window
        pulse_window_set_title(window, "Pulse")
        pulse_window_undecorate(window)
        pulse_window_set_resizable(window, 0)
        // **Never focused.** The panel is decoration with a hover; a click on a
        // ring must not raise it over the window somebody is working in, and
        // taking focus on map is what makes the first frame flicker.
        pulse_window_set_focusable(window, 0)

        // The geometry is worked out **before the window exists**, because the
        // size it asks for has to fit the screen: a window taller than the
        // display gets maximised by the window manager, and a maximised window
        // cannot be moved. See `PanelModel.geometry(forScreen:)`.
        let monitor = currentMonitor()
        let geometry = model.geometry(forScreen: monitor.rect)
        pulse_window_set_default_size(window, Int32(geometry.size.width),
                                      Int32(geometry.size.height))

        // **Layer-shell has to be told before the window is mapped, not after.**
        // "Set the window up to be a layer surface once it is mapped. this must
        // be called before" — the header's own words, and the first version
        // called it from the map handler, which is too late. Measured under a
        // nested `kwin_wayland`: the panel started, connected its pointer
        // controller, and was drawn **zero** times, against 158 draws in six
        // seconds on X11. So this happens here, before `present`, and the map
        // handler is left to the X11 half.
        #if canImport(CGTK4LayerShell)
        if String(cString: pulse_display_backend()) == "wayland",
           pulse_layer_shell_supported() == 1 {
            pulse_layer_shell_init(window)
            let edge = model.geometry(forScreen: monitor.rect).side
            pulse_layer_shell_set_layer(window, Int32(PULSE_LAYER_TOP))
            pulse_layer_shell_set_keyboard_mode(window, Int32(PULSE_LAYER_KEYBOARD_NONE))
            // No exclusive zone: the rail floats over the edge and the windows
            // behind it keep their full height.
            pulse_layer_shell_set_exclusive_zone(window, 0)
            pulse_layer_shell_set_anchor(window, Int32(PULSE_LAYER_EDGE_LEFT),
                                         edge == .left ? 1 : 0)
            pulse_layer_shell_set_anchor(window, Int32(PULSE_LAYER_EDGE_RIGHT),
                                         edge == .right ? 1 : 0)
            pulse_layer_shell_set_anchor(window, Int32(PULSE_LAYER_EDGE_TOP), 1)
            pulse_layer_shell_set_margin(window, Int32(PULSE_LAYER_EDGE_TOP),
                                         Int32(max(model.geometry(forScreen: monitor.rect)
                                                    .windowOrigin.y, 0)))
        }
        #endif

        // The stylesheet, which exists for one reason: GTK clears a window to
        // the theme's background unless it is told not to, and a "transparent"
        // panel that paints the theme's grey is not transparent.
        pulse_css_load("""
        window.pulse-panel, window.pulse-panel > * { background: transparent; }
        .pulse-panel { background-color: rgba(0,0,0,0); }
        """)
        pulse_widget_add_class(window, "pulse-panel")

        let area = pulse_drawing_area_new()
        self.area = area
        pulse_widget_add_class(area, "pulse-panel")
        pulse_drawing_area_make_transparent(area)
        // **The size request is what makes the window the right size.** A
        // non-resizable `GtkWindow` takes its size from its child's natural
        // size, and a `GtkDrawingArea`'s natural size is 0×0 — so `set_default_size`
        // is ignored and the panel comes out **0 by 0**, mapped, invisible, and
        // with no error anywhere. Measured with `gtk_widget_get_width` on the
        // real window. Asking the area for the size is the version that works
        // and still leaves the window un-resizable by the reader.
        pulse_widget_set_size_request(area, Int32(geometry.size.width),
                                      Int32(geometry.size.height))
        pulse_window_set_child(window, area)
        let panelPointer = Unmanaged.passUnretained(self).toOpaque()
        pulse_drawing_area_set_draw(area, Panel.drawCallback, panelPointer)

        // **Hover is what the panel is for.** The pointer opens the rail and
        // picks a ring; leaving closes both. The callbacks are Swift's, cast
        // here where the signal's signature is known — see `pulse_connect` for
        // why they are not wrapped in C.
        let pointer = pulse_pointer_controller(area)
        let motionHandler = pulse_connect(pointer, "motion",
                                          unsafeBitCast(Panel.motionCallback, to: GCallback.self),
                                          panelPointer)
        let leaveHandler = pulse_connect(pointer, "leave",
                                         unsafeBitCast(Panel.leaveCallback, to: GCallback.self),
                                         panelPointer)
        if ProcessInfo.processInfo.environment["PULSE_PANEL_DEBUG"] != nil {
            FileHandle.standardError.write(Data(
                ("pointer controller \(pointer != nil), motion handler \(motionHandler), "
                 + "leave handler \(leaveHandler)\n").utf8))
        }

        // **Positioned on the map signal, not before it.** See `pulse_on_map`:
        // a move that arrives before the surface is mapped is not a request the
        // window manager sees, and KWin centred a panel that had asked for the
        // right-hand edge.
        pulse_on_map(window, Panel.mapCallback)
        pulse_window_present(window)

        // The first reading, and the animation clock. `refresh` is asked once
        // and the store paces itself from there.
        model.refresh()
        timer = pulse_add_timer(Self.frameMilliseconds, Panel.tickCallback,
                                Unmanaged.passUnretained(self).toOpaque())
    }

    /// Where the window goes, and how it stays there. Runs on the map signal.
    private func applyBackendHints() {
        guard let window, let area else { return }
        let backend = String(cString: pulse_display_backend())
        let monitor = currentMonitor()
        let geometry = model.geometry(forScreen: monitor.rect)
        let _ = area
        if ProcessInfo.processInfo.environment["PULSE_PANEL_DEBUG"] != nil {
            #if canImport(CGTK4LayerShell)
            let layerShell = pulse_layer_shell_supported() == 1
            #else
            let layerShell = false
            #endif
            FileHandle.standardError.write(Data(
                ("backend \(backend), layer-shell supported \(layerShell), "
                 + "composited \(pulse_display_has_alpha() == 1), "
                 + "monitors \(pulse_monitor_count())\n").utf8))
        }

        switch backend {
        case "wayland":
            // **Nothing to do here, and that is the point.** Layer-shell was set
            // up before the window was mapped — see `present` — and a Wayland
            // compositor places a layer surface from the margins it was given,
            // so there is no frame to read back either. Reaching this branch at
            // all means the compositor has no layer shell: Mutter, which
            // implements none of it.
            if pulse_layer_shell_supported() != 1 {
                FileHandle.standardError.write(Data("""
                Pulse: this Wayland compositor has no layer-shell support, so the \
                panel cannot be docked to the screen edge or kept above other \
                windows. It will appear as an ordinary window. GNOME (Mutter) is \
                the compositor this affects; KDE, Sway and Hyprland are not.
                \n
                """.utf8))
            }

        default:
            // X11, or anything else GDK can drive: ask the window manager.
            guard pulse_x11_available(window) == 1 else { return }
            // Before the frame moves, so the WM never sees it as ordinary.
            pulse_x11_set_dock_type(window, 0)
            pulse_x11_move(window, Int32(geometry.windowOrigin.x),
                           Int32(geometry.windowOrigin.y))
            pulse_x11_set_above(window, 1)
            pulse_x11_set_skip_taskbar(window, 1)
            pulse_x11_set_all_desktops(window)
        }

    }

    /// The monitor the rail is on — the primary, or the first if there is no
    /// primary. The rail is given the monitor's **whole** rectangle and not its
    /// work area, because a docked rail is flush against the screen's physical
    /// edge: reserving the taskbar's strip would leave it floating a few pixels
    /// away from the edge it is supposed to be welded to.
    private func currentMonitor() -> (index: Int, rect: CGRect) {
        let count = pulse_monitor_count()
        guard count > 0 else {
            return (0, CGRect(x: 0, y: 0, width: 1920, height: 1080))
        }
        let primary = pulse_primary_monitor()
        let chosen = primary >= 0 ? Int(primary) : 0
        let monitor = pulse_monitor_at(Int32(chosen))
        return (chosen, CGRect(x: Double(monitor.x), y: Double(monitor.y),
                               width: Double(monitor.width), height: Double(monitor.height)))
    }

    private var lastDisplaySample = Date()
    /// Counted only for the debug line — the question "is the timer running or
    /// is the window not being drawn" cannot be answered from the outside.
    private var ticks = 0

    /// One step of the animation.
    func tick() {
        if ProcessInfo.processInfo.environment["PULSE_PANEL_DEBUG"] != nil {
            ticks += 1
            if ticks % 30 == 1 {
                FileHandle.standardError.write(Data("tick \(ticks)\n".utf8))
            }
        }
        // **Which display the panel is on, sampled rather than listened for.**
        // Upstream's rule and its reason: the pointer is the whole definition of
        // "active", and a pointer that crosses onto another display and comes to
        // rest there emits nothing further to notice. A quarter of a second is
        // slow enough to cost nothing and fast enough that the rail has arrived
        // by the time the hand has.
        if Date().timeIntervalSince(lastDisplaySample) > 0.25 {
            lastDisplaySample = Date()
            followPointer()
        }
        guard let area else { return }
        let now = Date()
        model.advance(to: now)
        pulse_widget_queue_draw(area)
    }

    // MARK: - The C callbacks

    /// A C function pointer cannot be an actor-isolated method, so these are
    /// `static` and reach the instance through the pointer GTK was given.
    /// Everything they call is main-actor bound, and GTK calls a draw or a
    /// timer callback on the main thread — which is a fact GTK documents, stated
    /// once, here.
    /// **GTK's own five-argument callback**, passed through with no wrapper —
    /// see `pulse_drawing_area_set_draw`.
    private static let drawCallback: @convention(c) (UnsafeMutablePointer<GtkDrawingArea>?,
                                                     OpaquePointer?,
                                                     Int32, Int32,
                                                     UnsafeMutableRawPointer?) -> Void = {
        _, context, width, height, data in
        guard let context, let data else { return }
        // **Addresses, not pointers.** A C pointer is not `Sendable`, so
        // carrying one into a main-actor closure is a data-race error — and it
        // is one the compiler is right about in general and wrong about here:
        // the context is only alive for the duration of this call, on this
        // thread. An `Int` crosses the boundary without a claim being made
        // about it, and the pointer is reconstituted inside.
        let contextAddress = Int(bitPattern: context)
        let panelAddress = Int(bitPattern: data)
        MainActor.assumeIsolated {
            guard let context = OpaquePointer(bitPattern: contextAddress),
                  let panelRaw = UnsafeMutableRawPointer(bitPattern: panelAddress) else { return }
            let panel = Unmanaged<Panel>.fromOpaque(panelRaw).takeUnretainedValue()
            panel.draw(into: context, width: Int(width), height: Int(height))
        }
    }

    /// The window is on screen, so a position request will be honoured and a
    /// read-back will describe something real.
    private static let mapCallback: @convention(c) (UnsafeMutablePointer<GtkWidget>?, UnsafeMutableRawPointer?) -> Void = { _, _ in
        MainActor.assumeIsolated {
            // The instance pointer is not carried by this signal, and there is
            // one panel per process — so the panel is held in a box the entry
            // point fills in. See `LivePanel` below.
            LivePanel.current?.place()
        }
    }

    /// Where the window goes and how it stays there, once it exists.
    ///
    /// Split out of `present` because it has to run **after** the map. Called
    /// once; the rail's own offsets then follow from the frame the window really
    /// got, which is what `PanelModel.confirmWindow` is for.
    func place() {
        applyBackendHints()
    }

    /// The pointer moved. `x` and `y` are in the drawing area's own space, which
    /// is the panel's — the same space `PanelHitArea` measures in.
    /// The first argument is GTK's controller, which is an incomplete type on
    /// the Swift side and is not used — a raw pointer is ABI-identical and
    /// needs no name.
    private static let motionCallback: @convention(c) (UnsafeMutableRawPointer?,
                                                       Double, Double,
                                                       UnsafeMutableRawPointer?) -> Void = {
        _, x, y, data in
        guard let data else { return }
        let address = Int(bitPattern: data)
        MainActor.assumeIsolated {
            guard let raw = UnsafeMutableRawPointer(bitPattern: address) else { return }
            Unmanaged<Panel>.fromOpaque(raw).takeUnretainedValue()
                .pointerMoved(to: CGPoint(x: x, y: y))
        }
    }

    private static let leaveCallback: @convention(c) (UnsafeMutableRawPointer?,
                                                      UnsafeMutableRawPointer?) -> Void = { _, data in
        guard let data else { return }
        let address = Int(bitPattern: data)
        MainActor.assumeIsolated {
            guard let raw = UnsafeMutableRawPointer(bitPattern: address) else { return }
            Unmanaged<Panel>.fromOpaque(raw).takeUnretainedValue().pointerMoved(to: nil)
        }
    }

    /// Moves the panel to the display the pointer is on, if it has moved.
    ///
    /// **X11 only.** A Wayland client cannot ask where the pointer is outside
    /// its own surfaces — that is the protocol, not a missing binding — so
    /// `pulse_x11_pointer_position` answers 0 there and nothing happens. The
    /// panel stays on whichever display it was put on.
    private func followPointer() {
        var x: Int32 = 0, y: Int32 = 0
        guard pulse_x11_pointer_position(&x, &y) == 1, let window else { return }

        let count = pulse_monitor_count()
        guard count > 1 else { return }
        var monitors: [(index: Int, rect: CGRect)] = []
        for index in 0..<Int(count) {
            let monitor = pulse_monitor_at(Int32(index))
            guard monitor.valid == 1 else { continue }
            monitors.append((index, CGRect(x: Double(monitor.x), y: Double(monitor.y),
                                           width: Double(monitor.width),
                                           height: Double(monitor.height))))
        }
        guard let geometry = model.followPointer(pointerOnScreen: CGPoint(x: Double(x), y: Double(y)),
                                                 monitors: monitors) else { return }
        pulse_x11_move(window, Int32(geometry.windowOrigin.x), Int32(geometry.windowOrigin.y))
        // The frame is a request again, so the offsets are re-derived on the
        // next draws rather than from this.
        confirmAttempts = 0
        confirmedFrame = .zero
    }

    private func pointerMoved(to point: CGPoint?) {
        model.setPointer(point)
        if ProcessInfo.processInfo.environment["PULSE_PANEL_DEBUG"] != nil {
            let where_ = point.map { "(\(Int($0.x)), \(Int($0.y)))" } ?? "off the panel"
            let strip = model.hoverStrip
            FileHandle.standardError.write(Data(
                ("pointer \(where_) -> open \(model.railOpenness > 0.5), "
                 + "ring \(model.selectedSlot ?? "none"), "
                 + "strip (\(Int(strip.minX)),\(Int(strip.minY))) "
                 + "\(Int(strip.width))x\(Int(strip.height))\n").utf8))
        }
    }

    private static let tickCallback: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { data in
        guard let data else { return 0 }
        let panelAddress = Int(bitPattern: data)
        MainActor.assumeIsolated {
            guard let panelRaw = UnsafeMutableRawPointer(bitPattern: panelAddress) else { return }
            Unmanaged<Panel>.fromOpaque(panelRaw).takeUnretainedValue().tick()
        }
        return 1
    }

    private func draw(into context: OpaquePointer, width: Int, height: Int) {
        if ProcessInfo.processInfo.environment["PULSE_PANEL_DEBUG"] != nil {
            FileHandle.standardError.write(Data("draw \(width)x\(height)\n".utf8))
        }
        // **The frame is confirmed on the first draw, not when the move is
        // asked for.** A position request is asynchronous: measured here, the
        // read-back immediately after `XMoveWindow` still said (0, 0) while the
        // window was at (1578, 0) a moment later. By the first draw the window
        // manager has finished, and the rail's offsets are then measured against
        // the frame it really got — which is the whole point of
        // `PanelModel.confirmWindow`.
        if confirmAttempts < 40, let window {
            var x: Int32 = 0, y: Int32 = 0, frameWidth: Int32 = 0, frameHeight: Int32 = 0
            if pulse_x11_window_geometry(window, &x, &y, &frameWidth, &frameHeight) == 1 {
                let frame = CGRect(x: Double(x), y: Double(y),
                                   width: Double(frameWidth), height: Double(frameHeight))
                confirmAttempts += 1
                if frame == confirmedFrame {
                    // Settled. Stop asking, and stop redrawing because of it.
                    confirmAttempts = 40
                } else {
                    confirmedFrame = frame
                    model.confirmWindow(origin: frame.origin, size: frame.size)
                    model.resetSettleReport()
                }
            }
        }

        let canvas = CairoCanvas(context)
        canvas.save()
        // Cleared to nothing first: the window is transparent and the rail is
        // the only thing drawn, so without this every frame stacks on the last.
        cairo_set_operator(context, CAIRO_OPERATOR_SOURCE)
        cairo_set_source_rgba(context, 0, 0, 0, 0)
        cairo_paint(context)
        cairo_set_operator(context, CAIRO_OPERATOR_OVER)
        canvas.restore()

        // The input region follows the rail's state, so the transparent part of
        // the window is not a place to click.
        if let window {
            let region = model.inputRegion
            pulse_window_set_input_region(window, Int32(region.minX), Int32(region.minY),
                                          Int32(region.width), Int32(region.height))
        }

        model.draw(into: canvas,
                   size: CGSize(width: Double(width), height: Double(height)),
                   at: Date())
    }
}

/// The one panel in this process, so the map signal's callback can reach it.
/// GTK's `map` signal carries the widget and nothing else, and there is exactly
/// one panel per process by construction.
@MainActor
enum LivePanel {
    static var current: Panel?
}

/// `--pointer "x,y;x,y"`, in the panel's own coordinates — the space the hit
/// test measures in, which is the top-left corner of the window. A sequence,
/// because arriving at a ring means arriving at the edge first: while the rail
/// is collapsed only the sliver's target counts, so a lone pointer placed on a
/// ring is a pointer on the sliver.
func parsedPointers() -> [CGPoint] {
    guard let index = CommandLine.arguments.firstIndex(of: "--pointer"),
          index + 1 < CommandLine.arguments.count else { return [] }
    return CommandLine.arguments[index + 1].split(separator: ";").compactMap { entry in
        let parts = entry.split(separator: ",")
        guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else { return nil }
        return CGPoint(x: x, y: y)
    }
}

/// `--hover [n]`: put the pointer where it opens the rail, and optionally onto
/// ring `n` so its card appears. `--open` is the same without a ring.
///
/// The coordinates come from the model rather than from the command line,
/// because the model is where the geometry already is.
func parsedHoverRing() -> Int? {
    if let index = CommandLine.arguments.firstIndex(of: "--hover"),
       index + 1 < CommandLine.arguments.count,
       let ring = Int(CommandLine.arguments[index + 1]) {
        return ring
    }
    return nil
}

// MARK: - Entry

// `--render <file>` draws the panel into a PNG and exits, before GTK is
// initialised at all — so it works over ssh, in a container, and in CI. It is
// the port's answer to "there is no screenshot tool on this machine", and the
// only way the panel's appearance can be looked at without a session.
if let index = CommandLine.arguments.firstIndex(of: "--render"),
   index + 1 < CommandLine.arguments.count {
    let path = CommandLine.arguments[index + 1]
    var size: CGSize?
    if let widthIndex = CommandLine.arguments.firstIndex(of: "--width"),
       widthIndex + 1 < CommandLine.arguments.count,
       let width = Double(CommandLine.arguments[widthIndex + 1]),
       let heightIndex = CommandLine.arguments.firstIndex(of: "--height"),
       heightIndex + 1 < CommandLine.arguments.count,
       let height = Double(CommandLine.arguments[heightIndex + 1]) {
        size = CGSize(width: width, height: height)
    }
    // A 1920×1080 screen, which is what this was developed against. Only the
    // placement measures against it; nothing is drawn outside the panel.
    exit(await RenderToPNG.run(path: path, size: size,
                               monitor: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                               railOnly: CommandLine.arguments.contains("--rail"),
                               pointers: parsedPointers(),
                               hoverRing: parsedHoverRing(),
                               openOnly: CommandLine.arguments.contains("--open")))
}

pulse_init()

guard let application = pulse_application_new() else {
    FileHandle.standardError.write(Data("Pulse: could not start GTK.\n".utf8))
    exit(1)
}

let model = PanelModel()
let panel = Panel(model: model)
LivePanel.current = panel

/// The panel has to survive as long as the signal connection does, which is the
/// life of the application.
let panelPointer = Unmanaged.passUnretained(panel).toOpaque()
// A raw pointer, not `Unmanaged`: `GtkApplication` is an opaque C struct and
// not a Swift class, so `Unmanaged` has nothing to retain.
let applicationPointer = UnsafeMutableRawPointer(application)

let activate: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = {
    applicationPointer, panelPointer in
    guard let applicationPointer, let panelPointer else { return }
    let applicationAddress = Int(bitPattern: applicationPointer)
    let panelAddress = Int(bitPattern: panelPointer)
    MainActor.assumeIsolated {
        guard let applicationRaw = UnsafeMutableRawPointer(bitPattern: applicationAddress),
              let panelRaw = UnsafeMutableRawPointer(bitPattern: panelAddress) else { return }
        let application = applicationRaw.assumingMemoryBound(to: GtkApplication.self)
        let panel = Unmanaged<Panel>.fromOpaque(panelRaw).takeUnretainedValue()
        panel.present(application: application)
    }
}

g_signal_connect_data(application, "activate",
                      unsafeBitCast(activate, to: GCallback.self),
                      panelPointer, nil, GConnectFlags(rawValue: 0))

exit(pulse_application_run(application))
