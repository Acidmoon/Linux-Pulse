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
 * `gtk_window_set_focusable` also keeps the compositor from giving it an
 * activation on map, which is what makes the first frame appear without a
 * flicker in the focused application. */
static inline void pulse_window_set_focusable(GtkWidget* window, int focusable) {
    gtk_window_set_focusable(GTK_WINDOW(window), focusable ? TRUE : FALSE);
}

// MARK: - Widgets

static inline GtkWidget* pulse_drawing_area_new(void) {
    return gtk_drawing_area_new();
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

/* The distance from a line's top to its baseline, so a caller that knows where
 * a box's vertical centre is can put the baseline there without guessing at a
 * font metric. */
static inline double pulse_text_ascent(cairo_t* cr, const char* text,
                                      double size, int weight) {
    PangoLayout* layout = pango_cairo_create_layout(cr);
    PangoFontDescription* font = pango_font_description_new();
    pango_font_description_set_family(font, "sans");
    pango_font_description_set_absolute_size(font, size * PANGO_SCALE);
    pango_font_description_set_weight(font, (PangoWeight)weight);
    pango_layout_set_font_description(layout, font);
    pango_layout_set_text(layout, text, -1);

    PangoLayoutIter* iter = pango_layout_get_iter(layout);
    double ascent = 0;
    if (iter != NULL) {
        ascent = pango_layout_iter_get_baseline(iter) / (double)PANGO_SCALE;
        pango_layout_iter_free(iter);
    }

    pango_font_description_free(font);
    g_object_unref(layout);
    return ascent;
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
 * the union of all screens and is where a window's position is measured. */
typedef struct {
    int x, y, width, height;
    int work_x, work_y, work_width, work_height;
    int primary;
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
static inline pulse_monitor_geometry pulse_monitor_at(int index) {
    pulse_monitor_geometry out = {0, 0, 0, 0, 0, 0, 0, 0, 0};
    GdkDisplay* display = gdk_display_get_default();
    if (display == NULL) return out;
    GListModel* monitors = gdk_display_get_monitors(display);
    if (monitors == NULL || index < 0 || index >= (int)g_list_model_get_n_items(monitors)) return out;

    GdkMonitor* monitor = GDK_MONITOR(g_list_model_get_item(monitors, index));
    if (monitor == NULL) return out;

    GdkRectangle geometry, workarea;
    gdk_monitor_get_geometry(monitor, &geometry);
    gdk_monitor_get_workarea(monitor, &workarea);
    out.x = geometry.x; out.y = geometry.y;
    out.width = geometry.width; out.height = geometry.height;
    out.work_x = workarea.x; out.work_y = workarea.y;
    out.work_width = workarea.width; out.work_height = workarea.height;
    out.primary = gdk_monitor_is_primary(monitor) ? 1 : 0;
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
