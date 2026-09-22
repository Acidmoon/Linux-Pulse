// `gtk4-layer-shell`, as a target of its own.
//
// **A separate module because the dependency is optional and the platform
// checking is the point.** A GTK4 window on X11 has no layer shell to talk to —
// measured on this machine: `gtk_layer_is_supported()` returns 0, and calling
// `gtk_layer_init_for_window` anyway makes GTK log a `CRITICAL` about
// `GDK_IS_WAYLAND_DISPLAY`. So the panel branches on the runtime answer and
// only Wayland ever takes this path; the type of the branch is
// `#if canImport(CGTK4LayerShell)`, which is also what lets a machine without
// the library build the panel at all.
//
// Everything the panel needs from it, and nothing else.
#pragma once

#include <gtk/gtk.h>
#include <gtk4-layer-shell.h>

/* 1 only where a layer shell exists to use: a wlr-layer-shell compositor on
 * Wayland. Not a build-time answer — the same binary runs both ways. */
static inline int pulse_layer_shell_supported(void) {
    return gtk_layer_is_supported() ? 1 : 0;
}

/* Every call below is a no-op unless `gtk_layer_init_for_window` has run, and
 * that must only run where `pulse_layer_shell_supported()` said yes. */
static inline void pulse_layer_shell_init(GtkWidget* window) {
    gtk_layer_init_for_window(GTK_WINDOW(window));
}

static inline void pulse_layer_shell_set_anchor(GtkWidget* window, int edge, int anchored) {
    gtk_layer_set_anchor(GTK_WINDOW(window), (GtkLayerShellEdge)edge, anchored ? TRUE : FALSE);
}

/* Exclusive zones reserve space the way a dock does. The panel must not: it
 * floats over the edge and the windows behind it keep their full height. */
static inline void pulse_layer_shell_set_exclusive_zone(GtkWidget* window, int size) {
    gtk_layer_set_exclusive_zone(GTK_WINDOW(window), size);
}

/* Margins are measured from the anchored edge, which is how the rail is pushed
 * clear of a top panel or a title bar. */
static inline void pulse_layer_shell_set_margin(GtkWidget* window, int edge, int margin) {
    gtk_layer_set_margin(GTK_WINDOW(window), (GtkLayerShellEdge)edge, margin);
}

/* `LAYER_TOP` draws over ordinary windows without taking keyboard focus. */
static inline void pulse_layer_shell_set_layer(GtkWidget* window, int layer) {
    gtk_layer_set_layer(GTK_WINDOW(window), (GtkLayerShellLayer)layer);
}

/* On a compositor that lets it, the panel declines focus outright — the same
 * intent as `pulse_window_set_focusable`, stated where Wayland can hear it. */
static inline void pulse_layer_shell_set_keyboard_mode(GtkWidget* window, int mode) {
    gtk_layer_set_keyboard_mode(GTK_WINDOW(window), (GtkLayerShellKeyboardMode)mode);
}

/* The enum values, re-exported as plain ints so the Swift side does not have to
 * depend on how clang names an anonymous enum's cases. */
enum {
    PULSE_LAYER_EDGE_LEFT = GTK_LAYER_SHELL_EDGE_LEFT,
    PULSE_LAYER_EDGE_RIGHT = GTK_LAYER_SHELL_EDGE_RIGHT,
    PULSE_LAYER_EDGE_TOP = GTK_LAYER_SHELL_EDGE_TOP,
    PULSE_LAYER_EDGE_BOTTOM = GTK_LAYER_SHELL_EDGE_BOTTOM
};

enum {
    PULSE_LAYER_TOP = GTK_LAYER_SHELL_LAYER_TOP,
    PULSE_LAYER_OVERLAY = GTK_LAYER_SHELL_LAYER_OVERLAY
};

enum {
    PULSE_LAYER_KEYBOARD_NONE = GTK_LAYER_SHELL_KEYBOARD_MODE_NONE,
    PULSE_LAYER_KEYBOARD_ON_DEMAND = GTK_LAYER_SHELL_KEYBOARD_MODE_ON_DEMAND
};
