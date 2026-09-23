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

        let size = model.panelSize
        pulse_window_set_default_size(window, Int32(size.width), Int32(size.height))

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
        pulse_window_set_child(window, area)
        pulse_drawing_area_set_draw(area, Panel.drawCallback)

        pulse_window_present(window)
        applyBackendHints()

        // The first reading, and the animation clock. `refresh` is asked once
        // and the store paces itself from there.
        model.refresh()
        timer = pulse_add_timer(Self.frameMilliseconds, Panel.tickCallback,
                                Unmanaged.passUnretained(self).toOpaque())
    }

    /// Where the window goes, and how it stays there.
    private func applyBackendHints() {
        guard let window, let area else { return }
        let backend = String(cString: pulse_display_backend())
        let monitor = currentMonitor()
        let geometry = model.geometry(forScreen: monitor.rect)
        switch backend {
        case "wayland":
            #if canImport(CGTK4LayerShell)
            if pulse_layer_shell_supported() == 1 {
                pulse_layer_shell_init(window)
                // Anchored to the edge it is docked to and to the top, with a
                // margin equal to where the rail belongs. Margins are measured
                // from the anchored edge, so only the ones that are anchored
                // mean anything.
                let edge = geometry.side
                pulse_layer_shell_set_layer(window, Int32(PULSE_LAYER_TOP))
                pulse_layer_shell_set_keyboard_mode(window, Int32(PULSE_LAYER_KEYBOARD_NONE))
                pulse_layer_shell_set_exclusive_zone(window, 0)
                pulse_layer_shell_set_anchor(window, Int32(PULSE_LAYER_EDGE_LEFT),
                                             edge == .left ? 1 : 0)
                pulse_layer_shell_set_anchor(window, Int32(PULSE_LAYER_EDGE_RIGHT),
                                             edge == .right ? 1 : 0)
                pulse_layer_shell_set_anchor(window, Int32(PULSE_LAYER_EDGE_TOP), 1)
                pulse_layer_shell_set_margin(window, Int32(PULSE_LAYER_EDGE_TOP),
                                             Int32(max(geometry.windowOrigin.y, 0)))
                return
            }
            #endif
            // No layer shell to use. Nothing below helps on Wayland either —
            // a compositor there will not take EWMH — so the window is left
            // where the compositor put it, and that is a limitation rather
            // than a bug. `Docs/linux/windowing.md` says so.
            FileHandle.standardError.write(Data("""
            Pulse: this Wayland compositor has no layer-shell support, so the \
            panel cannot be docked to the screen edge. It will appear as an \
            ordinary window. GNOME (Mutter) is the compositor this affects.
            \n
            """.utf8))

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

    /// One step of the animation.
    func tick() {
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
    private static let drawCallback: pulse_draw_callback = { context, width, height, data in
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
        let canvas = CairoCanvas(context)
        canvas.save()
        // Cleared to nothing first: the window is transparent and the rail is
        // the only thing drawn, so without this every frame stacks on the last.
        cairo_set_operator(context, CAIRO_OPERATOR_SOURCE)
        cairo_set_source_rgba(context, 0, 0, 0, 0)
        cairo_paint(context)
        cairo_set_operator(context, CAIRO_OPERATOR_OVER)
        canvas.restore()

        model.draw(into: canvas,
                   size: CGSize(width: Double(width), height: Double(height)),
                   at: Date())
    }
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
                               railOnly: CommandLine.arguments.contains("--rail")))
}

pulse_init()

guard let application = pulse_application_new() else {
    FileHandle.standardError.write(Data("Pulse: could not start GTK.\n".utf8))
    exit(1)
}

let model = PanelModel()
let panel = Panel(model: model)

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
