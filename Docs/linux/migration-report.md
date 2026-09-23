# The Linux port: architecture, mappings, and what is different

This is the document the migration was asked for: how the Linux app is put
together, what every macOS mechanism became, and the places where the two are
**not** the same. Every claim here was measured on this machine (Deepin 25, KWin,
X11, glibc 2.38) or read out of the source it describes, and the measurements
that decided anything are cited.

## Architecture

```
                    ┌──────────────────────────────────────────┐
                    │  Pulse  (library, Sources/Pulse)          │
                    │                                           │
                    │  Models · Providers · Readers · Auth      │
                    │  UsageStore · UsageCache · UsageReport    │
                    │  PanelPlacement · DockLayout · PanelLayout│
                    │  BotMarkEngine · the whole animation      │
                    │  PulseDefaults · LocalizationSource       │
                    └────────────┬─────────────────┬────────────┘
                                 │                 │
             import Pulse        │                 │  import Pulse
                                 ▼                 ▼
        ┌────────────────────────────┐   ┌──────────────────────────────┐
        │ PulseCLI  (Sources/PulseCLI)│   │ PulsePanel (Sources/PulsePanel)│
        │                            │   │                               │
        │ 3 lines: PulseCLI.run()    │   │ GTK4 window · Cairo canvas    │
        │                            │   │ X11 EWMH · layer-shell        │
        │ links: Foundation, crypto, │   │ pointer · AT-SPI · input region│
        │        SQLite              │   │                               │
        │ **links no GTK at all**    │   │ links: GTK4, layer-shell, X11 │
        └────────────────────────────┘   └──────────────────────────────┘
             installed as `pulse`              installed as `PulsePanel`
```

Three things about that shape are decisions rather than accidents, and each was
forced by a measurement:

**The library is a library because SwiftPM gives a dependent target an empty
module when the dependency is an executable.** Measured, by putting a `public
func` on one side and failing to see it from the other. The CLI is three lines
over the library's one `public` symbol; `Pulse`'s own tests still do
`@testable import Pulse` and did not have to change.

**The panel is a separate executable because it is the only thing that links
GTK.** `pulse --json` has to keep working where there is no GPU stack at all.
Verified: `ldd .build/debug/Pulse | grep -c gtk` is **0**, and `Pulse --json` runs
with `DISPLAY` unset.

**The panel's targets are conditional on GTK4 being findable**, because
`swift test` builds every target in the package — an unconditional panel would
mean the core could not be built or tested without GTK4's headers, and this port
has a headless half that runs on exactly such machines. The manifest looks for
the `.pc` files rather than running pkg-config, which SwiftPM's manifest sandbox
may not permit.

Inside the library, the panel's own code lives under `Sources/Pulse/Panel/GTK/`
and is written against a **`PanelCanvas` protocol** — fifteen drawing verbs. The
renderer walks a `BotMarkFrame` and the rail's geometry and never sees a
`cairo_t`; `CairoCanvas` in the panel executable is the only thing that does.
That seam is what keeps the drawing with the frame it draws while the executable
stays thin, without annotating four thousand lines of upstream code with
`package`.

## What the panel is made of

**It is upstream's panel.** The numbers, the shapes and the rules are upstream's
code, compiled for Linux:

| | lines | what it is |
|---|---|---|
| `BotMarkEngine`, `Morphs`, `Particles`, `Geometry`, `Data`, `Tint`, … | ~3,950 | the animation, computed — no `body`, no `some View`, no `@State` |
| `DockLayout`, `DetailCardLayout`, `PanelLayout`, `PanelHitArea` | ~600 | every dimension the rail and the card are laid out with |
| `DockBerthShape`, `NotchBerthShape`, `NotchAlertShape`, `UsageBubbleShape` | 261 | the silhouettes |
| `UsageTint`, `BotMarkTint` | ~400 | what colour a ring is, and what colour a mark is |
| `RailEntry`, `RailEntryBuilder` | ~100 | which window a ring shows, and what the card calls it |
| `PanelPlacement` | 461 | edge docking, multi-display placement, the frame/rail offset trap |
| `SVGIcon`, `SVGPathData` | ~450 | **new** — the provider logos, which macOS gets from `NSImage` |
| `PanelModel`, `PanelRenderer`, `PanelRailRenderer`, `PanelCardRenderer` | ~1,100 | **new** — the display list drawn with Cairo |
| `CairoCanvas`, window, pointer, X11/layer-shell | ~500 | **new** — GTK and the two windowing protocols |

The provider half was finished in phase 1 and is unchanged by all of this: 20
providers, ~50 log readers, OAuth, loopback callbacks, the sealed-file store, and
`pulse --json`.

## macOS → Linux, mechanism by mechanism

| macOS | Linux | state |
|---|---|---|
| SwiftUI / AppKit views | GTK4 via a C shim, Cairo for drawing | done; the panel's own code is reused rather than rewritten |
| `NSPanel`, always-on-top | X11: EWMH `_NET_WM_STATE_ABOVE`; Wayland: `wlr-layer-shell` | **measured**; layer-shell is Wayland-only and calling it on X11 logs a GTK `CRITICAL` |
| Keychain / `LocalSecrets` | Secret Service, else a 0600 file | done in phase 1; 5 tests |
| `SMAppService` / LaunchAgent | XDG autostart `~/.config/autostart/pulse.desktop` | done; `LinuxLoginItem`, 5 tests |
| Sparkle | removed — system package manager or a GitHub release | done; the dependency is not resolved on Linux at all |
| Global shortcut (`EventTap`) | **not implemented** — X11 could use `XGrabKey`, Wayland has no portable equivalent | see *Known differences* |
| Chromium cookie reading | same browsers, Linux config paths | done in phase 1 |
| `*.lproj` | the same `.lproj` tables, through `Bundle.module` | done; **and the interpolated keys now resolve** — see below |
| codesign / `xattr` | not needed | n/a |
| `NSImage` for provider logos | `SVGPathData` parses the bundled SVGs | **new**; 15 tests |
| `CGPath`, `CGAffineTransform` | `Platform/DrawingCompat.swift` | measured: Foundation has `CGFloat`/`CGPoint`/`CGSize`/`CGRect`, and **not** `CGPath`/`CGAffineTransform`/`CGVector` |
| `Color`, `Path`, `Shape` | the same names, supplied in the module | so upstream's files compile with only their imports guarded |
| `NSColor` for component reads | `ColourReading` | macOS goes through `NSColor`, Linux reads the stored components |
| `UserDefaults.standard` | the suite named `Pulse` | **measured**: on Linux the domain is the executable's *file name* |
| `RelativeDateTimeFormatter` | hand-written | **absent from swift-corelibs-foundation**; `DateComponentsFormatter` is explicitly unavailable |
| `String.LocalizationValue` | `LocalizedKey` | **absent**; its absence left 63 call sites in English |
| `NSFont` / Core Text | Pango through Cairo | `pango_cairo_show_layout`, whose origin is the top-left |
| AT-SPI accessibility | GTK's own | the a11y bus warning on a machine without it is harmless |

## Known differences and limits

These are the places where the Linux app is **not** the macOS app. None of them
is a bug being excused; each has a cause.

**Multi-display following is X11 only.** Upstream samples the pointer's display
every quarter second, because "the pointer is the whole definition of active".
X11 answers with `XQueryPointer`. **Wayland deliberately has no global pointer
query** — a client cannot ask where the pointer is outside its own surfaces — so
there the panel stays on whichever display it was put on. And this machine has
one display, so all that is verified is that a single-display system never moves
the panel. A second screen is the one thing this port could not test.

**No global shortcut.** Upstream registers one through `EventTap`. On X11 that is
`XGrabKey` and would work; on Wayland a global shortcut needs a compositor
portal, which is a different protocol per desktop and not portable. Rather than
implement half of it, the feature is absent and the panel is reached by clicking
it. The tray below is the intended replacement.

**No tray icon.** GTK4 has no tray API; an icon means a StatusNotifierItem over
D-Bus, which is a component rather than a binding. The panel itself is the
surface, and `pulse` with no arguments starts it.

**Glass is not implemented.** `PanelSurface` offers flat black or Liquid Glass,
and flat black is the default on both platforms. There is no Linux equivalent of
`glassEffect`, and a blur would need a compositor-specific protocol.

**The hover halo is an approximation.** Upstream draws it as a shadow cast by the
arc; **Cairo has no blur**, so it is three increasingly wide and faint strokes.
At 36 points across the difference is invisible.

**`_NET_WM_DESKTOP` is set but KWin reports 0.** The panel asks to be on every
desktop; the window manager keeps its own answer. On a single-desktop session it
does not matter, and it is recorded rather than hidden.

**A window taller than the screen gets maximised, and a maximised window cannot
be moved.** Upstream's `PanelLayout` computes the maximum the panel could need —
1822 points — and AppKit constrains the frame. KWin maximises instead, so the
window is clamped to the monitor before it is created, and the rail's offsets are
re-derived from the frame the window actually got. That is what
`PanelPlacement.offsets` exists for, and its own comment describes the 72-point
error the same trap caused on a Mac.

## The bugs this port found, and how

Recorded because each one was invisible from the outside and only a measurement
found it.

**`CGAffineTransform` composition was wrong in three places**, and upstream's own
`BotMarkTests` found it: 8,744 of its assertions failed on one number, how far
the mark had slid out of the rail's budget. `translatedBy`, `scaledBy` and
`rotated` were each written as `concatenating`, which applies the new operation
in the destination space rather than the source one.

**A `static inline` function's address is not a usable C callback.** The first
draw shim wrapped GTK's five-argument callback down to four and passed the real
one through `user_data`; it linked, and it never fired. The panel ticked at 30fps,
called `gtk_widget_queue_draw` on all 107 of them, `gtk_widget_get_mapped` said
the window was mapped, and the draw callback ran **zero** times.

**A non-resizable window is sized by its child, and a drawing area's natural size
is 0×0.** So `gtk_window_set_default_size` was ignored and the panel was **0 by
0** — mapped, on screen, invisible, and no error from GTK or the window manager.
Only `gtk_widget_get_width` on the real window could have said so.

**`(a, a + 2π)` is a whole circle and `2π mod 2π` is zero**, so every ring's track
was drawn as `cairo_arc(cr, x, y, r, 0, 0)` — nothing at all.

**`pango_cairo_show_layout` puts the layout's top-left at the current point, not
its baseline**, so every line on the detail card was half a line low and each
row's title sat on its own progress bar.

**`UserDefaults.standard` on Linux takes its domain from the running binary's
file name**, and it is the real file: a symlink named `Pulse` still reports the
name it points at, and `exec -a Pulse` does not change it either. Two binaries
read two files, so the panel came up with no rings while `pulse --json` listed
three accounts.

**`Shape.path(in:)` is SwiftUI's**, and upstream's shapes read it as the view's
own frame — coordinates from `(0, 0)`, no `minX`. Passing the rail's real
rectangle put the silhouette in the panel's top-left corner.

**`kiro.svg` draws outside its own viewBox** (y = -2.2 and y = 25.5 in a 24-unit
box), which is what an SVG viewport clips — so the renderer clips too.

## Both backends, on one machine

The two sessions were run against the same binary on the same day. X11 is this
machine's own session (KWin); Wayland is a **nested** `kwin_wayland`, started
with `--socket wayland-pulse-test` inside it, which is a real wlr-layer-shell
compositor rather than a stub.

| | Wayland (nested KWin) | X11 (KWin) |
|---|---|---|
| `pulse_display_backend()` | `wayland` | `x11` |
| `gtk_layer_is_supported()` | **true** | **false** |
| `gdk_display_is_composited()` | true | true |
| monitors | 1 | 1 |
| docking path taken | layer-shell | EWMH |
| window geometry read back | not available | 342×1080 at (1578, 0) |

Two things follow. The branch is real: on Wayland the panel anchors to an edge
through the layer shell and declines the keyboard, and on X11 it asks the window
manager in EWMH terms — the same binary, decided at runtime by
`gtk_layer_is_supported()` rather than by a build flag.

And on Wayland the frame is **not read back**, because there is nothing to read
it back from: `XGetGeometry` is X11's, and a layer-shell surface is placed by the
compositor from the margins it was given. `railOrigin` stays as computed from the
request, which is correct there by construction — the compositor puts the window
where the margins said. On X11 it is read back because a frame is only ever a
request.

**What this does not cover:** GNOME's Mutter, which implements no
`wlr-layer-shell` at all — the panel detects that, says so on stderr, and appears
as an ordinary window. No Mutter session was available to run it under, so that
path is written and reasoned about but not exercised. And the nested compositor
is a test harness: it has one synthetic output, so multi-display behaviour on
Wayland is untested for the same reason it is on X11.

## Verification

- **852 tests in 91 suites**, all passing, with and without the GTK4 paths on
  `PKG_CONFIG_PATH`.
- Upstream's own tests are enabled wherever they can run, rather than new ones
  being written alongside: `BotMarkTests` (30), `BotMarkChoreographyTests`,
  `BotMarkRestTests`, `RailGeometryTests` (13). A test written beside a port
  checks the port against itself — which is exactly how the transform bug
  survived, and how this repository's own transform test came to assert the wrong
  answers.
- The panel's appearance is verified by **rendering it to a PNG**
  (`PulsePanel --render out.png [--rail] [--pointer "x,y;x,y"]`), because this
  machine has no screenshot tool and "it opens and looks right" is the acceptance
  bar. The same entry point works with no display, so CI can use it.
- The window is verified from outside the process: `xdotool` reports 342×1080 at
  (1578, 0) on a 1920-wide screen — flush with the edge — and `xprop` shows
  `_NET_WM_STATE_ABOVE`, `SKIP_TASKBAR` and `SKIP_PAGER` all set.
- **The hover interaction is driven by a real pointer**, not by the render path's
  direct call: `GtkEventControllerMotion` on the drawing area, and `xdotool`
  pushing the pointer into the sliver to open the rail and onto a ring to select
  it. Worth doing because a hover that does nothing looks exactly like a pointer
  that never arrived — and `xdotool mousemove` on this machine does **not** place
  the pointer where it is told (asked for (1918, 540), landed at (1854, 421)), so
  the sweep that worked used relative moves.
