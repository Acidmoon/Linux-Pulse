# Build environment for the GTK4 panel.
#
# **On a normal machine this script does nothing but check.** GTK4 is found
# through pkg-config, which is what `sudo apt install libgtk-4-dev
# libgtk4-layer-shell-dev libx11-dev` sets up; see Docs/linux/install.md.
#
# The sysroot branch exists for a machine where those packages cannot be
# installed — no root, or a distribution that does not carry them — and GTK4 is
# unpacked from .deb files into a directory instead:
#
#     Scripts/linux/gtk4-sysroot.sh ~/.local/share/pulse-gtk4/sysroot
#
# The two paths are not equivalent in one respect: a sysroot extracted this way
# has the *headers* while the shared objects come from the system, so the
# runtime needs LD_LIBRARY_PATH for whichever libraries the system lacks.
# `Scripts/run-panel.sh` handles that.

PULSE_GTK_SYSROOT="${PULSE_GTK_SYSROOT:-$HOME/.local/share/pulse-gtk4/sysroot}"

if [ -d "$PULSE_GTK_SYSROOT/usr/lib/x86_64-linux-gnu/pkgconfig" ]; then
    export PKG_CONFIG_PATH="$PULSE_GTK_SYSROOT/usr/lib/x86_64-linux-gnu/pkgconfig:$PULSE_GTK_SYSROOT/usr/share/pkgconfig:${PKG_CONFIG_PATH:-/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/share/pkgconfig}"
    export PULSE_GTK_SYSROOT
    echo "panel-env: using GTK4 sysroot at $PULSE_GTK_SYSROOT" >&2
fi

# **Required**, because without them there is no panel to build: the manifest
# defines the panel's targets only when pkg-config can find GTK4, so a machine
# missing this one builds the command line and nothing else.
missing_required=0
for module in gtk4 x11; do
    if pkg-config --exists "$module" 2>/dev/null; then
        printf 'panel-env: %-22s %s\n' "$module" "$(pkg-config --modversion $module)" >&2
    else
        printf 'panel-env: %-22s **not found**\n' "$module" >&2
        missing_required=1
    fi
done

if [ "$missing_required" = 0 ]; then
    # **Optional**, and the difference matters: gtk4-layer-shell is what docks
    # the rail on Wayland, and it is not packaged by Ubuntu 24.04 at all. The
    # panel builds and runs without it — on X11 it docks through EWMH, and on
    # Wayland it says so and appears as an ordinary window — so this is a note
    # rather than a failure.
    if pkg-config --exists gtk4-layer-shell-0 2>/dev/null; then
        printf 'panel-env: %-22s %s\n' "gtk4-layer-shell-0" \
            "$(pkg-config --modversion gtk4-layer-shell-0)" >&2
    else
        echo "panel-env: **gtk4-layer-shell not found.** The panel will build and" >&2
        echo "  will dock on X11; on Wayland it will appear as an ordinary window." >&2
        echo "  Ubuntu 24.04 does not package it. See Docs/linux/install.md." >&2
    fi
    return 0 2>/dev/null || exit 0
fi

echo "panel-env: install them with:" >&2
echo "  sudo apt install libgtk-4-dev libx11-dev libgtk4-layer-shell-dev" >&2
echo "  or unpack them into a sysroot: Scripts/linux/gtk4-sysroot.sh" >&2
return 1 2>/dev/null || exit 1
