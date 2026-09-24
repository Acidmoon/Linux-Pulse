// A Swift-shaped face on the parts of GTK4 that Swift cannot call directly.
//
// **Header-only and statically inlined on purpose.** Everything here is a cast,
// a macro, or two lines of wrapping, and none of it is a library: a
// `systemLibrary` target that shipped a .c file would be a second build system
// to keep working, for functions the compiler can just paste in.
//
// Two things make this necessary rather than convenient:
//
//   1. **GObject's upcasts are macros.** `gtk_application_window_new` returns a
//      `GtkWidget*` and `gtk_window_set_title` wants a `GtkWindow*`; C gets
//      between them with `GTK_WINDOW()`, which calls `gtk_window_get_type()`
//      and is not something Swift can spell. Every cast the panel needs is a
//      function below.
//   2. **Some of GTK is macros or variadic.** `G_OBJECT`, the version constants
//      and `g_object_new`'s property list are all things clang's importer
//      reasonably declines to expose.
//
// Nothing here draws. `gtk_drawing_area_set_draw_func` takes a plain C callback
// and Swift can express its signature, so the panel's drawing is called
// directly and this file never sees a `cairo_t`.
#pragma once

#include <gtk/gtk.h>
#include <pango/pangocairo.h>

/* `g_unix_signal_add`, which is where SIGUSR1 is arranged. It is GLib rather
 * than GTK but it is the signal facility that goes with the main loop the panel
 * already runs, and a hand-rolled `signal()` handler would be delivered on
 * whichever thread the kernel picked and would have to get itself onto the main
 * one. `glib-unix.h` also brings `signal.h` with it, so `PULSE_SIGUSR1` and
 * `PULSE_SIGTERM` below are the only names Swift needs. */
#include <glib-unix.h>

/* The backend headers, because `GDK_IS_X11_DISPLAY` and `GDK_IS_WAYLAND_DISPLAY`
 * are macros that live in them and nowhere else — without these the two
 * spellings are implicit function declarations, which compiles and then fails to
 * link. `gdkconfig.h` (reached through `gdk.h`) is what says which backends
 * this GDK was built with, so a GTK without one of them simply does not include
 * its header and the macro is never asked for. */
#ifdef GDK_WINDOWING_X11
#include <gdk/x11/gdkx.h>
#endif
#ifdef GDK_WINDOWING_WAYLAND
#include <gdk/wayland/gdkwayland.h>
#endif

// MARK: - Starting up

/* GTK has to have connected before anything can ask about the display: without
 * this `gdk_display_get_default()` is NULL and `pulse_display_backend()` answers
 * "none" on a machine that has a session running. Creating a `GtkApplication`
 * does not do it — `g_application_run` does, and by then every decision that
 * depended on the backend has been made. */
static inline void pulse_init(void) {
    gtk_init();
}

/* A repeating timer. The panel animates at 30fps off this rather than off the
 * frame clock, the same rate upstream's SwiftUI view chose and for the same
 * reason: everything it plays is slow, and seven engines redrawing at the
 * display's rate is work nobody can see. */
static inline unsigned pulse_add_timer(unsigned milliseconds,
                                       gboolean (*callback)(gpointer),
                                       gpointer data) {
    return g_timeout_add(milliseconds, callback, data);
}

/* Runs a callback once the window has been mapped.
 *
 * **The timing is the whole point.** A position request that arrives before the
 * surface is mapped is not a request the window manager ever sees: it applies
 * its own placement policy and the window lands wherever that puts it —
 * measured, with KWin centring a panel that had asked for the right-hand edge.
 * `XMoveWindow` after the map is a client request like any other and is
 * honoured. */
typedef void (*pulse_map_callback)(GtkWidget* window, void* user_data);

static inline void pulse_map_trampoline(GtkWidget* window, gpointer data) {
    pulse_map_callback callback = (pulse_map_callback)data;
    if (callback != NULL) callback(window, NULL);
}

static inline void pulse_on_map(GtkWidget* window, pulse_map_callback callback) {
    g_signal_connect_data(window, "map", G_CALLBACK(pulse_map_trampoline),
                          (gpointer)callback, NULL, (GConnectFlags)0);
}

static inline int pulse_widget_width(GtkWidget* widget) { return gtk_widget_get_width(widget); }
static inline int pulse_widget_height(GtkWidget* widget) { return gtk_widget_get_height(widget); }
static inline int pulse_widget_is_mapped(GtkWidget* widget) { return gtk_widget_get_mapped(widget) ? 1 : 0; }

static inline void pulse_widget_queue_draw(GtkWidget* widget) {
    gtk_widget_queue_draw(widget);
}

// MARK: - Applications and windows

static inline GtkApplication* pulse_application_new(void) {
    return gtk_application_new(NULL, G_APPLICATION_DEFAULT_FLAGS);
}

static inline GtkWidget* pulse_application_window(GtkApplication* application) {
    return gtk_application_window_new(application);
}

static inline void pulse_window_set_title(GtkWidget* window, const char* title) {
    gtk_window_set_title(GTK_WINDOW(window), title);
}

static inline void pulse_window_undecorate(GtkWidget* window) {
    gtk_window_set_decorated(GTK_WINDOW(window), FALSE);
}

static inline void pulse_window_set_default_size(GtkWidget* window, int width, int height) {
    gtk_window_set_default_size(GTK_WINDOW(window), width, height);
}

/* The panel is positioned by its own geometry, so the compositor must not
 * rearrange it. On Wayland this is a no-op; on X11 it drops the shadow and lets
 * the window sit flush against the screen edge. */
static inline void pulse_window_set_resizable(GtkWidget* window, int resizable) {
    gtk_window_set_resizable(GTK_WINDOW(window), resizable ? TRUE : FALSE);
}

static inline void pulse_window_present(GtkWidget* window) {
    gtk_window_present(GTK_WINDOW(window));
}

/* A window that never takes focus: the panel is decoration with a hover, and a
 * click on a ring must not raise it over the window the reader was working in.
 * It also keeps the compositor from giving the window an activation on map,
 * which is what makes the first frame appear without a flicker in whatever was
 * focused.
 *
 * `gtk_widget_set_focusable`, not `gtk_window_set_focusable` — the latter does
 * not exist in GTK4, and the widget property is the one that means this. */
static inline void pulse_window_set_focusable(GtkWidget* window, int focusable) {
    gtk_widget_set_focusable(window, focusable ? TRUE : FALSE);
}

// MARK: - Widgets

static inline GtkWidget* pulse_drawing_area_new(void) {
    return gtk_drawing_area_new();
}

/* The draw callback, handed straight to GTK.
 *
 * **No trampoline, which was the first version and did not work.** A helper that
 * wrapped GTK's five-argument callback down to four and passed the real one
 * through `user_data` took the address of a `static inline` function in a
 * header-only module — which links, and then never fires: the panel ticked along
 * at 30fps with `gtk_widget_queue_draw` called on every one of them and the draw
 * callback never ran once. `GtkDrawingAreaDrawFunc` is a plain function pointer
 * that Swift can express, so it is passed through unchanged and the user data
 * carries what the panel needs.
 *
 * `gtk_widget_queue_draw` is kept for `pulse_drawing_area_set_draw`'s callers to
 * ask for one. */
static inline void pulse_drawing_area_set_draw(GtkWidget* area,
                                               GtkDrawingAreaDrawFunc callback,
                                               gpointer user_data) {
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(area), callback, user_data, NULL);
}

// MARK: - Menus, and clicks

/* A popover: the menu the panel never had.
 *
 * **Upstream's menu bar had Settings and Quit, and on Linux there was nothing.**
 * A reader who started the panel could not stop it except by killing the
 * process, which is not a way to treat somebody's application. The tray icon
 * that would hold those items on a Mac does not exist here — GTK4 has no tray
 * API — so they go on the panel itself, on a right-click.
 *
 * Buttons rather than a `GMenu`: a menu is scaffolding for four actions, and
 * `GMenu`/`GAction` would be another several bindings to learn for as many
 * lines. */
static inline GtkWidget* pulse_popover_new(void) {
    GtkWidget* popover = gtk_popover_new();
    GtkWidget* box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
    gtk_widget_set_margin_top(box, 6);
    gtk_widget_set_margin_bottom(box, 6);
    gtk_widget_set_margin_start(box, 6);
    gtk_widget_set_margin_end(box, 6);
    gtk_popover_set_child(GTK_POPOVER(popover), box);
    return popover;
}

static inline void pulse_popover_add_button(GtkWidget* popover, const char* label,
                                            GCallback callback, void* data) {
    GtkWidget* box = gtk_popover_get_child(GTK_POPOVER(popover));
    if (box == NULL) return;
    GtkWidget* button = gtk_button_new_with_label(label);
    /* Flat, so a menu of four lines does not look like a dialogue box. */
    gtk_widget_add_css_class(button, "flat");
    gtk_widget_set_halign(button, GTK_ALIGN_FILL);
    if (callback != NULL) {
        g_signal_connect_data(G_OBJECT(button), "clicked", callback, data, NULL,
                              (GConnectFlags)0);
    }
    gtk_box_append(GTK_BOX(box), button);
}

/* Where the pointer is, so a right-click opens the menu under the hand rather
 * than in a corner. `gtk_popover_popup` needs a rectangle to point at; a
 * one-pixel box at the pointer is what the documentation suggests and what every
 * toolkit does. */
static inline void pulse_popover_popup_at_pointer(GtkWidget* popover) {
    GdkDevice* pointer = gdk_seat_get_pointer(
        gdk_display_get_default_seat(gdk_display_get_default()));
    if (pointer == NULL) {
        gtk_popover_popup(GTK_POPOVER(popover));
        return;
    }
    GdkSurface* surface = gtk_native_get_surface(gtk_widget_get_native(popover));
    double x = 0, y = 0;
    if (surface != NULL && gdk_surface_get_device_position(surface, pointer, &x, &y, NULL)) {
        GdkRectangle rect = {(int)x, (int)y, 1, 1};
        gtk_popover_set_pointing_to(GTK_POPOVER(popover), &rect);
        gtk_popover_set_has_arrow(GTK_POPOVER(popover), FALSE);
    }
    gtk_popover_popup(GTK_POPOVER(popover));
}

static inline void pulse_popover_popdown(GtkWidget* popover) {
    gtk_popover_popdown(GTK_POPOVER(popover));
}

/* A popover belongs to a widget the way a child does, but `popup` measures
 * against the surface rather than the parent's allocation — so it is parented
 * to the drawing area and points at the pointer. */
static inline void pulse_widget_set_parent(GtkWidget* widget, GtkWidget* parent) {
    gtk_widget_set_parent(widget, parent);
}

/* A click gesture on one mouse button. The button is a `GtkGestureSingle`
 * property, so this is how a left click and a right click are told apart — and
 * the event controllers' signal signatures are what Swift is handed. */
static inline void* pulse_click_gesture(GtkWidget* widget, unsigned button,
                                        GCallback callback, void* data) {
    GtkGesture* gesture = gtk_gesture_click_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(gesture), button);
    if (callback != NULL) {
        g_signal_connect_data(G_OBJECT(gesture), "pressed", callback, data, NULL,
                              (GConnectFlags)0);
    }
    gtk_widget_add_controller(widget, GTK_EVENT_CONTROLLER(gesture));
    return gesture;
}

/* Pointer motion and leaving, as an event controller.
 *
 * The controller is returned rather than the signals being connected here,
 * because **a `static inline` function's address is not a usable C callback** —
 * the lesson from the draw function, which linked and never fired. Swift has the
 * two callbacks already and connects them with `pulse_connect` below, the same
 * way the application's own `activate` signal is connected. */
/* `void*` rather than `GtkEventController*`, because **the GTK event-controller
 * structs are incomplete** — the typedef exists in the header and the body is
 * private to GTK, so clang's importer has no name to give Swift and the type is
 * simply not there. The pointer is only ever handed back to `pulse_connect`. */
static inline void* pulse_pointer_controller(GtkWidget* widget) {
    GtkEventController* controller = gtk_event_controller_motion_new();
    gtk_widget_add_controller(widget, controller);
    return controller;
}

/* One signal, connected to a Swift function. The callback is cast on the Swift
 * side, where the signature is known. */
static inline unsigned long pulse_connect(void* controller, const char* signal,
                                          GCallback callback, void* data) {
    return g_signal_connect_data((GObject*)controller, signal, callback, (gpointer)data,
                                 NULL, (GConnectFlags)0);
}

/* **The window only takes input where it draws.** A transparent panel is still a
 * 342×1080 window, and without this every click on the desktop behind it lands
 * on the panel instead — the whole point of it being transparent is that the
 * desktop is still there. `gdk_surface_set_input_region` is the Wayland *and*
 * X11 answer, unlike everything else about this window. */
static inline void pulse_window_set_input_region(GtkWidget* window, int x, int y,
                                                 int width, int height) {
    GdkSurface* surface = gtk_native_get_surface(gtk_widget_get_native(window));
    if (surface == NULL) return;
    cairo_rectangle_int_t rectangle = {x, y, width, height};
    cairo_region_t* region = cairo_region_create_rectangle(&rectangle);
    gdk_surface_set_input_region(surface, region);
    cairo_region_destroy(region);
}

/* Asked for a redraw, and the surface told it is transparent. Without the
 * second call GTK clears the drawing area to the theme's background colour
 * before the callback runs, which on a "transparent" panel is an opaque box. */
static inline void pulse_drawing_area_make_transparent(GtkWidget* area) {
    gtk_widget_set_hexpand(area, TRUE);
    gtk_widget_set_vexpand(area, TRUE);
}

static inline void pulse_widget_add_class(GtkWidget* widget, const char* name) {
    gtk_widget_add_css_class(widget, name);
}

static inline void pulse_widget_set_size_request(GtkWidget* widget, int width, int height) {
    gtk_widget_set_size_request(widget, width, height);
}

static inline void pulse_window_set_child(GtkWidget* window, GtkWidget* child) {
    gtk_window_set_child(GTK_WINDOW(window), child);
}

// MARK: - The main loop, and getting out of it

static inline int pulse_application_run(GtkApplication* application) {
    return g_application_run(G_APPLICATION(application), 0, NULL);
}

static inline void pulse_application_quit(GtkApplication* application) {
    g_application_quit(G_APPLICATION(application));
}

// MARK: - Off-screen surfaces

/* The panel's own drawing, on an image instead of a window.
 *
 * **This exists so the panel can be looked at without a display.** There is no
 * screenshot tool on the machine the port was developed on, and "it opens and
 * looks right" is the whole acceptance bar for a UI — so the rail is drawn
 * through exactly the same code into a PNG, which can be inspected, diffed and
 * attached to a CI run. `PulsePanel --render out.png` is that.
 *
 * The drawing is the same call either way: `PanelModel.draw` takes a
 * `PanelCanvas`, and `CairoCanvas` wraps whichever Cairo context it is given. */
static inline cairo_surface_t* pulse_image_surface_new(int width, int height) {
    return cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height);
}

static inline cairo_t* pulse_context_new(cairo_surface_t* surface) {
    return cairo_create(surface);
}

/* 0 on success; Cairo's own error code otherwise, which is worth returning
 * rather than swallowing — a render that produced no file should say why. */
static inline int pulse_surface_write_png(cairo_surface_t* surface, const char* path) {
    cairo_status_t status = cairo_surface_write_to_png(surface, path);
    return (int)status;
}

static inline void pulse_surface_destroy(cairo_surface_t* surface) {
    if (surface != NULL) cairo_surface_destroy(surface);
}

static inline void pulse_context_destroy(cairo_t* context) {
    if (context != NULL) cairo_destroy(context);
}

// MARK: - Text

/* Drawn with Pango rather than Cairo's toy text API. The toy API has no
 * kerning, no hinting control and one font face for the whole surface, and the
 * panel's whole content is small numbers — the one place where that shows.
 *
 * `x` is the left edge of the text and `y` is its **baseline**, which is what
 * Cairo means by it. The caller centres by subtracting half the measured
 * width, which is what `pulse_text_width` is for: the same layout, measured
 * rather than guessed, so a percentage does not shift as it goes from "9%" to
 * "10%". */
static inline void pulse_text(cairo_t* cr, double x, double y,
                              const char* text, double size,
                              double red, double green, double blue, double alpha,
                              int weight) {
    PangoLayout* layout = pango_cairo_create_layout(cr);
    PangoFontDescription* font = pango_font_description_new();
    pango_font_description_set_family(font, "sans");
    pango_font_description_set_absolute_size(font, size * PANGO_SCALE);
    pango_font_description_set_weight(font, (PangoWeight)weight);
    pango_layout_set_font_description(layout, font);
    pango_layout_set_text(layout, text, -1);

    cairo_set_source_rgba(cr, red, green, blue, alpha);
    cairo_move_to(cr, x, y);
    pango_cairo_show_layout(cr, layout);

    pango_font_description_free(font);
    g_object_unref(layout);
}

static inline double pulse_text_width(cairo_t* cr, const char* text,
                                     double size, int weight) {
    PangoLayout* layout = pango_cairo_create_layout(cr);
    PangoFontDescription* font = pango_font_description_new();
    pango_font_description_set_family(font, "sans");
    pango_font_description_set_absolute_size(font, size * PANGO_SCALE);
    pango_font_description_set_weight(font, (PangoWeight)weight);
    pango_layout_set_font_description(layout, font);
    pango_layout_set_text(layout, text, -1);

    int width = 0, height = 0;
    pango_layout_get_pixel_size(layout, &width, &height);

    pango_font_description_free(font);
    g_object_unref(layout);
    return (double)width;
}

/* The height of the laid-out text, which is what a caller centring it on a point
 * needs.
 *
 * **`pango_cairo_show_layout` puts the layout's top-left at the current point,
 * not its baseline.** The first version of this used the baseline — read out of
 * `pango_layout_iter_get_baseline` — and every line on the detail card was drawn
 * about half a line too low, which put the row titles on top of their own
 * progress bars. A line's own pixel height is the measurement that cannot be
 * off, because it is the box being positioned. */
static inline double pulse_text_height(cairo_t* cr, const char* text,
                                      double size, int weight) {
    PangoLayout* layout = pango_cairo_create_layout(cr);
    PangoFontDescription* font = pango_font_description_new();
    pango_font_description_set_family(font, "sans");
    pango_font_description_set_absolute_size(font, size * PANGO_SCALE);
    pango_font_description_set_weight(font, (PangoWeight)weight);
    pango_layout_set_font_description(layout, font);
    pango_layout_set_text(layout, text, -1);

    int width = 0, height = 0;
    pango_layout_get_pixel_size(layout, &width, &height);

    pango_font_description_free(font);
    g_object_unref(layout);
    return (double)height;
}

enum {
    PULSE_WEIGHT_NORMAL = PANGO_WEIGHT_NORMAL,
    PULSE_WEIGHT_MEDIUM = PANGO_WEIGHT_MEDIUM,
    PULSE_WEIGHT_SEMIBOLD = PANGO_WEIGHT_SEMIBOLD,
    PULSE_WEIGHT_BOLD = PANGO_WEIGHT_BOLD
};

// MARK: - CSS

/* Loaded from a string rather than a file: the panel's stylesheet is four rules
 * and shipping it beside the binary would be a path to get wrong at runtime. */
static inline void pulse_css_load(const char* css) {
    GtkCssProvider* provider = gtk_css_provider_new();
    gtk_css_provider_load_from_string(provider, css);
    gtk_style_context_add_provider_for_display(
        gdk_display_get_default(), GTK_STYLE_PROVIDER(provider),
        GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_unref(provider);
}

/* Whether the display can composite a transparent window at all. Without a
 * compositor an RGBA visual does not exist and a "transparent" panel comes out
 * black, which is worse than not drawing it. */
static inline int pulse_display_has_alpha(void) {
    GdkDisplay* display = gdk_display_get_default();
    if (display == NULL) return 0;
    return gdk_display_is_composited(display) ? 1 : 0;
}

/* Which backend this session is on, as a string: "x11", "wayland" or something
 * else. Used to decide what to do about always-on-top, which the two need
 * different answers for. */
static inline const char* pulse_display_backend(void) {
    GdkDisplay* display = gdk_display_get_default();
    if (display == NULL) return "none";
    if (GDK_IS_X11_DISPLAY(display)) return "x11";
    if (GDK_IS_WAYLAND_DISPLAY(display)) return "wayland";
    return "other";
}

// MARK: - Monitors

/* Monitor geometry in the compositor's own coordinate space, which on X11 is
 * the union of all screens and is where a window's position is measured.
 *
 * **Geometry and nothing else.** GTK4 removed `gdk_monitor_get_workarea` and
 * `gdk_monitor_is_primary` in 4.12; there is no query for either, and inventing
 * one from the geometry would be guessing at where a taskbar is. The rail wants
 * the whole screen anyway — it is welded to the physical edge, not to the usable
 * area — and "which monitor is primary" is answered by `pulse_primary_monitor`,
 * which says what it actually does. */
typedef struct {
    int x, y, width, height;
    int valid;
} pulse_monitor_geometry;

static inline int pulse_monitor_count(void) {
    GdkDisplay* display = gdk_display_get_default();
    if (display == NULL) return 0;
    GListModel* monitors = gdk_display_get_monitors(display);
    return monitors == NULL ? 0 : (int)g_list_model_get_n_items(monitors);
}

/* `index` counts monitors the way GDK does, which is the order they were
 * reported — stable within a session but not meaningful across them, so the
 * panel looks for the primary and falls back to the first. */
/* **Zero, which is a guess and is labelled as one.** GTK4 dropped
 * `gdk_monitor_is_primary` in 4.12 and offers nothing in its place: GDK's
 * monitor list has no primary in it. A compositor's first monitor is almost
 * always the primary one, so that is what this answers — and the panel follows
 * the pointer to another monitor as soon as it is dragged, which is the
 * behaviour the answer is actually for. */
static inline int pulse_primary_monitor(void) {
    return pulse_monitor_count() > 0 ? 0 : -1;
}

static inline pulse_monitor_geometry pulse_monitor_at(int index) {
    pulse_monitor_geometry out = {0, 0, 0, 0, 0};
    GdkDisplay* display = gdk_display_get_default();
    if (display == NULL) return out;
    GListModel* monitors = gdk_display_get_monitors(display);
    if (monitors == NULL || index < 0 || index >= (int)g_list_model_get_n_items(monitors)) return out;

    GdkMonitor* monitor = GDK_MONITOR(g_list_model_get_item(monitors, index));
    if (monitor == NULL) return out;

    GdkRectangle geometry;
    gdk_monitor_get_geometry(monitor, &geometry);
    out.x = geometry.x;
    out.y = geometry.y;
    out.width = geometry.width;
    out.height = geometry.height;
    out.valid = gdk_monitor_is_valid(monitor) ? 1 : 0;
    g_object_unref(monitor);
    return out;
}

/* Which monitor a point is on, or -1. Used to follow the pointer the way
 * `ActiveDisplayFollower` does on a Mac. */
static inline int pulse_monitor_index_at(int x, int y) {
    GdkDisplay* display = gdk_display_get_default();
    if (display == NULL) return -1;
    GListModel* monitors = gdk_display_get_monitors(display);
    if (monitors == NULL) return -1;
    guint count = g_list_model_get_n_items(monitors);
    for (guint index = 0; index < count; index++) {
        GdkMonitor* monitor = GDK_MONITOR(g_list_model_get_item(monitors, index));
        if (monitor == NULL) continue;
        GdkRectangle geometry;
        gdk_monitor_get_geometry(monitor, &geometry);
        g_object_unref(monitor);
        if (x >= geometry.x && x < geometry.x + geometry.width &&
            y >= geometry.y && y < geometry.y + geometry.height) {
            return (int)index;
        }
    }
    return -1;
}

// MARK: - Being told, from outside

/* **How `pulse --place` moves a panel that is already running.** The alternative
 * was to write the settings file and let the panel notice, which means watching
 * the file — and a watcher fires on the write its own process makes, so it needs
 * the guard that distinguishes the two, and it fires twice for one save, and it
 * reports a whole-file change for every unrelated key. A signal says exactly one
 * thing: read your settings again.
 *
 * `g_unix_signal_add` is the right one and not `signal()`: it delivers on the
 * main loop, so the handler is on the same thread as everything it touches. A
 * `signal()` handler runs wherever the kernel decides, and moving a window from
 * there is a data race with the drawing. */
#define PULSE_SIGUSR1 SIGUSR1
#define PULSE_SIGTERM SIGTERM

/* `PulseSignalHandler` is a `gboolean (*)(void*)` in GLib's spelling. It returns
 * `G_SOURCE_CONTINUE` (nonzero) to stay installed; returning zero removes it
 * after the first signal, which is a panel that moves once and then ignores
 * every later request. */
static inline unsigned int pulse_on_signal(int signum, GCallback handler, void* data) {
    return g_unix_signal_add(signum, (GSourceFunc)handler, data);
}

/* **A repeating timer, for draining the main queue.** `g_main_loop_run` — which
 * is what `g_application_run` is — does not drain libdispatch's main queue, and
 * on Linux `@MainActor` and `DispatchQueue.main` work *is* that queue. So a
 * GTK-only main thread runs GLib sources and nothing else: every `Task { }`, and
 * every network completion that hops back to the main actor, waits forever.
 *
 * Measured, with a program that schedules one of each and then loops: inside a
 * plain `Thread.sleep` loop neither ever ran. Inside
 * `RunLoop.current.run(mode:before:)` both did. Hence a timer that does that. */
static inline unsigned int pulse_on_interval(unsigned int milliseconds, GCallback handler,
                                             void* data) {
    return g_timeout_add(milliseconds, (GSourceFunc)handler, data);
}

/* `SIGTERM` as `pulse --quit` sends it, and as a compositor or a session manager
 * sends it at logout. Both should take the same path out. */
static inline int pulse_raise(int pid, int signum) {
    return kill((pid_t)pid, signum);
}
