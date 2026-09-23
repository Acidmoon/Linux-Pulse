// The X11 half of "always on top, and not in the task list".
//
// **GTK4 has no API for either.** `gtk_window_set_keep_above` existed in GTK3
// and is gone; the GTK4 answer is `gtk4-layer-shell`, which is a Wayland
// protocol with no X11 implementation. So on an X11 session the window has to
// ask the window manager directly, in EWMH terms, through the X connection GDK
// already has open.
//
// Measured on this machine before any of this was written (KWin on Deepin 25):
// `_NET_WM_STATE_ABOVE`, `_NET_WM_STATE_SKIP_TASKBAR`, `_NET_WM_STATE_SKIP_PAGER`
// and `_NET_WM_WINDOW_TYPE_DOCK` are all in the root window's `_NET_SUPPORTED`.
// `_NET_WM_STATE_STICKY` is **not** — which matters only for showing on every
// desktop, and the panel does that by setting `_NET_WM_DESKTOP` instead.
//
// Everything here is a no-op when the surface is not an X11 one, so the caller
// does not have to branch on the backend to call it — only to decide whether
// calling it is the right thing to do at all.
#pragma once

#include <gtk/gtk.h>

#if defined(GDK_WINDOWING_X11)
/* GTK4's X11 header is `<gdk/x11/gdkx.h>`. There is no `<gdk/gdkx.h>` — that
 * was the GTK3 spelling, and including it is a compile error rather than a
 * fallback. */
#include <gdk/x11/gdkx.h>
#include <X11/Xatom.h>
#include <X11/Xlib.h>
#define PULSE_HAVE_X11 1
#else
#define PULSE_HAVE_X11 0
#endif

#if !PULSE_HAVE_X11

/* A machine whose GDK has no X11 backend at all: nothing to talk to. The
 * functions still exist so that the panel compiles and runs unchanged. */
static inline int pulse_x11_available(GtkWidget* window) { (void)window; return 0; }
static inline int pulse_x11_window_geometry(GtkWidget* window, int* x, int* y,
                                            int* width, int* height) {
    (void)window; (void)x; (void)y; (void)width; (void)height;
    return 0;
}
static inline void pulse_x11_set_above(GtkWidget* window, int on) { (void)window; (void)on; }
static inline void pulse_x11_set_skip_taskbar(GtkWidget* window, int on) { (void)window; (void)on; }
static inline void pulse_x11_set_dock_type(GtkWidget* window, int on) { (void)window; (void)on; }
static inline void pulse_x11_set_all_desktops(GtkWidget* window) { (void)window; }
static inline void pulse_x11_move(GtkWidget* window, int x, int y) { (void)window; (void)x; (void)y; }

#else

/* The order below matters and is not alphabetical: each function uses the ones
 * above it. It was written the other way first, which is a header that compiles
 * on a machine with no X11 and fails on one with it — the branch that is not
 * being built is the branch that hides the mistake. */

static inline Display* pulse_x11_display(void) {
    GdkDisplay* display = gdk_display_get_default();
    return (display != NULL && GDK_IS_X11_DISPLAY(display))
        ? gdk_x11_display_get_xdisplay(display) : NULL;
}

static inline Window pulse_x11_window(GtkWidget* window) {
    GdkSurface* surface = gtk_native_get_surface(gtk_widget_get_native(window));
    if (surface == NULL || !GDK_IS_X11_SURFACE(surface)) return 0;
    return gdk_x11_surface_get_xid(surface);
}

static inline int pulse_x11_available(GtkWidget* window) {
    GdkSurface* surface = gtk_native_get_surface(gtk_widget_get_native(window));
    return (surface != NULL && GDK_IS_X11_SURFACE(surface)) ? 1 : 0;
}

/* The window's real position and size, after the window manager has had its
 * say. **A frame is a request**: a panel taller than the screen gets shortened,
 * a window at the bottom gets pushed up, and KWin constrains both. Measured on
 * this machine — a 1822-point panel on a 1080-point screen came back 1024 tall
 * at y = 0, and the rail's offsets, computed from the frame that was *asked
 * for*, put it below the window it was drawn in.
 *
 * Two X round trips: `XGetGeometry` for the size, `XTranslateCoordinates` to
 * turn the parent-relative origin into a screen one. Returns 1 when it filled
 * the four values in. */
static inline int pulse_x11_window_geometry(GtkWidget* window, int* x, int* y,
                                            int* width, int* height) {
    Display* display = pulse_x11_display();
    Window xwindow = pulse_x11_window(window);
    if (display == NULL || xwindow == 0) return 0;

    Window root = 0;
    int localX = 0, localY = 0;
    unsigned int w = 0, h = 0, border = 0, depth = 0;
    if (!XGetGeometry(display, xwindow, &root, &localX, &localY, &w, &h, &border, &depth)) {
        return 0;
    }

    int screenX = 0, screenY = 0;
    Window child = 0;
    XTranslateCoordinates(display, xwindow, root, 0, 0, &screenX, &screenY, &child);

    *x = screenX;
    *y = screenY;
    *width = (int)w;
    *height = (int)h;
    return 1;
}

/* `_NET_WM_STATE` is a list of atoms, and the protocol for changing it is a
 * client message to the root window rather than a property write — a direct
 * `XChangeProperty` on a mapped window is ignored by most window managers.
 * `_NET_WM_STATE_ADD` is 1, `_NET_WM_STATE_REMOVE` is 0. */
static inline void pulse_x11_send_state(Window window, const char* state, int on) {
    Display* display = pulse_x11_display();
    if (display == NULL || window == 0) return;
    Atom wmState = XInternAtom(display, "_NET_WM_STATE", False);
    Atom target = XInternAtom(display, state, False);
    XEvent event;
    memset(&event, 0, sizeof(event));
    event.xclient.type = ClientMessage;
    event.xclient.window = window;
    event.xclient.message_type = wmState;
    event.xclient.format = 32;
    event.xclient.data.l[0] = on ? 1 : 0;
    event.xclient.data.l[1] = (long)target;
    event.xclient.data.l[2] = 0;
    event.xclient.data.l[3] = 1; /* source indication: an ordinary application */
    event.xclient.data.l[4] = 0;
    XSendEvent(display, DefaultRootWindow(display), False,
               SubstructureRedirectMask | SubstructureNotifyMask, &event);
    XFlush(display);
}

/* One state, applied now. `XSendEvent` is asynchronous, so the caller cannot
 * read the result back; the check that it worked is `xprop` on the real window,
 * which is what `Docs/linux/windowing.md` records. */
static inline void pulse_x11_set_above(GtkWidget* window, int on) {
    pulse_x11_send_state(pulse_x11_window(window), "_NET_WM_STATE_ABOVE", on);
}

static inline void pulse_x11_set_skip_taskbar(GtkWidget* window, int on) {
    Window xwindow = pulse_x11_window(window);
    /* A panel with no taskbar entry must not answer Alt-Tab either, so the item
     * is skipped in both places the WM keeps a list. */
    pulse_x11_send_state(xwindow, "_NET_WM_STATE_SKIP_TASKBAR", on);
    pulse_x11_send_state(xwindow, "_NET_WM_STATE_SKIP_PAGER", on);
    pulse_x11_send_state(xwindow, "_NET_WM_STATE_SKIP_SWITCHER", on);
}

/* `_NET_WM_WINDOW_TYPE` **is** a property, unlike the state list, and it has to
 * be set before the window is mapped or the window manager has already decided
 * what it is. `_NET_WM_WINDOW_TYPE_NORMAL` is what a docked panel wants when it
 * should keep a shadow and behave like a window in every other respect — `DOCK`
 * makes the WM reserve space and treat it as part of the desktop, which this
 * panel deliberately does not do. */
static inline void pulse_x11_set_dock_type(GtkWidget* window, int on) {
    Display* display = pulse_x11_display();
    Window xwindow = pulse_x11_window(window);
    if (display == NULL || xwindow == 0) return;
    Atom type = XInternAtom(display, "_NET_WM_WINDOW_TYPE", False);
    Atom value = XInternAtom(display, on ? "_NET_WM_WINDOW_TYPE_DOCK"
                                         : "_NET_WM_WINDOW_TYPE_NORMAL", False);
    XChangeProperty(display, xwindow, type, XA_ATOM, 32, PropModeReplace,
                    (unsigned char*)&value, 1);
    XFlush(display);
}

/* Every desktop, which is what `_NET_WM_STATE_STICKY` would have said on a
 * window manager that had it. `0xFFFFFFFF` is `_NET_WM_DESKTOP`'s "all". */
static inline void pulse_x11_set_all_desktops(GtkWidget* window) {
    Display* display = pulse_x11_display();
    Window xwindow = pulse_x11_window(window);
    if (display == NULL || xwindow == 0) return;
    Atom property = XInternAtom(display, "_NET_WM_DESKTOP", False);
    unsigned long all = 0xFFFFFFFF;
    XChangeProperty(display, xwindow, property, XA_CARDINAL, 32, PropModeReplace,
                    (unsigned char*)&all, 1);
    XFlush(display);
}

/* Moving a window by geometry rather than by a GTK call, so that the position
 * is the one `PanelPlacement` computed and not one GDK negotiated: on X11
 * `gtk_window_set_default_size` and friends go through the window manager,
 * which may adjust before the first frame. `XMoveWindow` on a mapped window is
 * honoured by a running WM as a client request and has no such negotiation. */
static inline void pulse_x11_move(GtkWidget* window, int x, int y) {
    Display* display = pulse_x11_display();
    Window xwindow = pulse_x11_window(window);
    if (display == NULL || xwindow == 0) return;
    XMoveWindow(display, xwindow, x, y);
    XFlush(display);
}

#endif
