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

for module in gtk4 gtk4-layer-shell-0 x11; do
    if ! pkg-config --exists "$module" 2>/dev/null; then
        echo "panel-env: **$module not found.**" >&2
        echo "  Install it with: sudo apt install libgtk-4-dev libgtk4-layer-shell-dev libx11-dev" >&2
        echo "  Or unpack one into a sysroot: Scripts/linux/gtk4-sysroot.sh" >&2
        return 1 2>/dev/null || exit 1
    fi
done

for module in gtk4 gtk4-layer-shell-0 x11; do
    printf 'panel-env: %-22s %s\n' "$module" "$(pkg-config --modversion $module)" >&2
done
