#!/usr/bin/env bash
#
# Installs Pulse for one user, so that `pulse` is a command.
#
# **Because it was not one, and the documentation said it was.** Everything
# under `Docs/linux` writes `pulse --json`, `pulse --place`, and a reader who
# runs that gets "找不到命令 pulse" — on a machine where the binary is called
# `Pulse`, is capitalised, and lives in `.build/release/`. A build directory is
# not an installation, and a program whose whole job is to be looked at should
# not need a path typed at it.
#
# Layout, and both halves of it matter:
#
#   $prefix/bin/pulse              a symlink, so the command is the name the
#                                  docs use and the one `PATH` has
#   $prefix/lib/pulse/Pulse        the real binary
#   $prefix/lib/pulse/PulsePanel   the panel, which is a separate executable
#   $prefix/lib/pulse/Pulse_Pulse.bundle
#                                  the provider logos and strings, which
#                                  `Bundle.module` finds beside whichever
#                                  executable `/proc/self/exe` resolves to
#
# **Everything in `lib/pulse` and only a symlink in `bin`**, which is measured
# rather than tidy: a symlink follows to the real file, so the bundle is found,
# while `pulse --autostart on` resolves `PulsePanel` from where the command was
# invoked — `$prefix/lib/pulse`, via the rule in `LinuxLoginItem` — and the
# session that reads the `.desktop` file gets an absolute path that is still
# there next login.
#
# Usage:
#   Scripts/linux/install.sh                 # ~/.local
#   Scripts/linux/install.sh --prefix /usr/local   # needs write access to it
#   Scripts/linux/install.sh --uninstall
set -euo pipefail

cd "$(dirname "$0")/../.."
root=$PWD

prefix=${PREFIX:-$HOME/.local}
uninstall=0
while [ $# -gt 0 ]; do
    case $1 in
        --prefix) prefix=${2:?--prefix needs a directory}; shift 2 ;;
        --prefix=*) prefix=${1#--prefix=}; shift ;;
        --uninstall) uninstall=1; shift ;;
        -h|--help) sed -n '2,32p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "install.sh: unknown option $1" >&2; exit 2 ;;
    esac
done

lib=$prefix/lib/pulse
bin=$prefix/bin

if [ "$uninstall" = 1 ]; then
    rm -f "$bin/pulse"
    rm -rf "$lib"
    # The autostart entry names a path under `$lib`, so leaving it behind would
    # be an entry pointing at nothing — which is exactly the `missingTarget`
    # state `LinuxLoginItem` reports. Said rather than removed silently, since
    # it is the reader's own file.
    entry=${XDG_CONFIG_HOME:-$HOME/.config}/autostart/pulse.desktop
    if [ -e "$entry" ]; then
        rm -f "$entry"
        echo "Removed $entry"
    fi
    echo "Uninstalled from $prefix. Settings in ${XDG_CONFIG_HOME:-$HOME/.config}/Pulse.plist were left alone."
    exit 0
fi

# MARK: - Build

if [ ! -x .build/release/Pulse ]; then
    echo "No release build found; building one. This takes a few minutes."
    # `panel-env.sh` is what puts GTK4 on `PKG_CONFIG_PATH` where it is not in a
    # system location, and without it the panel target is not defined at all —
    # silently, because SwiftPM drops targets whose dependencies do not resolve.
    source Scripts/linux/panel-env.sh >/dev/null 2>&1 || true
    source Scripts/linux/swift-env.sh
    swift build -c release --manifest-cache none
fi

if [ ! -x .build/release/Pulse ]; then
    echo "install.sh: .build/release/Pulse is missing and could not be built." >&2
    exit 1
fi

panel=1
if [ ! -x .build/release/PulsePanel ]; then
    panel=0
fi

# MARK: - Install

mkdir -p "$lib" "$bin"
install -m755 .build/release/Pulse "$lib/Pulse"
# The name the documentation uses. `ln -sf`, so installing twice is not an
# error, and relative, so the whole prefix can be moved.
ln -sf ../lib/pulse/Pulse "$bin/pulse"

if [ "$panel" = 1 ]; then
    install -m755 .build/release/PulsePanel "$lib/.PulsePanel"
    # **A wrapper when the panel's own libraries are somewhere `ldconfig` does
    # not know about**, which is the normal case on a machine that cannot
    # install `libgtk4-layer-shell-dev` from its distribution and used
    # `Scripts/linux/gtk4-sysroot.sh` instead — Ubuntu 24.04 does not package
    # it, so that is the documented path and not an odd one. `$ORIGIN` in the
    # binary's RUNPATH covers the Swift runtime's own directory; the sysroot is
    # not something the binary could know about when it was linked.
    #
    # Dozens of bytes of shell rather than a `patchelf` dependency, and it
    # keeps `PulsePanel` as the name everything looks for —
    # `LinuxLoginItem.panelExecutable` and the `execv` in `pulse` with no
    # arguments both want exactly that, and both run a script happily.
    extra=""
    if ldd "$lib/.PulsePanel" 2>/dev/null | grep -q "not found"; then
        sysroot=${PULSE_GTK_SYSROOT:-$HOME/.local/share/pulse-gtk4/sysroot}
        if [ -d "$sysroot/usr/lib/x86_64-linux-gnu" ]; then
            extra="$sysroot/usr/lib/x86_64-linux-gnu"
        fi
    fi

    if [ -n "$extra" ]; then
        # `$lib` is absolute and so is `$extra`, and neither contains a quote;
        # both are written in rather than passed, because a wrapper that reads
        # its own location has to be right about symlinks to be right at all.
        cat > "$lib/PulsePanel" <<WRAPPER
#!/bin/sh
# Written by Scripts/linux/install.sh: this panel links libraries that live
# outside the loader's search path. Delete this file and rename \`.PulsePanel\`
# if the libraries become system-wide.
export LD_LIBRARY_PATH="$extra\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec "$lib/.PulsePanel" "\$@"
WRAPPER
        chmod 755 "$lib/PulsePanel"
        echo "Wrapped the panel for libraries in $extra"
    else
        mv "$lib/.PulsePanel" "$lib/PulsePanel"
    fi
else
    echo "Note: no PulsePanel was built, so the panel is not installed."
    echo "      The command line works without it; see Docs/linux/install.md."
fi

# The resources, beside the executables. `Bundle.module` resolves through
# `/proc/self/exe`, which follows the symlink in `bin` to the real file here —
# verified by installing to a scratch prefix and rendering the same rail, byte
# for byte, from both locations.
for bundle in .build/release/*.bundle; do
    [ -e "$bundle" ] || continue
    rm -rf "$lib/$(basename "$bundle")"
    cp -r "$bundle" "$lib/"
done

# MARK: - What it found, and what to do next

echo
echo "Installed:"
echo "  $bin/pulse                 → $lib/Pulse"
[ "$panel" = 1 ] && echo "  $lib/PulsePanel             the floating panel"

case ":$PATH:" in
    *":$bin:"*) ;;
    *)
        echo
        echo "**$bin is not on your PATH.** Add it, for this shell and the next:"
        echo
        echo "  echo 'export PATH=\"$bin:\$PATH\"' >> ~/.bashrc"
        echo "  export PATH=\"$bin:\$PATH\""
        ;;
esac

echo
echo "Try it:"
echo
echo "  pulse --providers          what is on the rail"
echo "  pulse --enable claudeCode  put one there"
echo "  pulse                      open the panel"
echo "  pulse --autostart on       and have it come back at login"
