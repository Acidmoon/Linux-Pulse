# Installing Pulse on Linux

## What it needs

Three runtime pieces, and one of them only for the panel:

| | why | Debian/Ubuntu | Fedora |
|---|---|---|---|
| Swift 6 | the language | see below | see below |
| `libsqlite3` | reading the local session logs | `libsqlite3-dev` | `sqlite-devel` |
| `libgtk-4` | **the panel only** | `libgtk-4-dev` | `gtk4-devel` |
| `gtk4-layer-shell` | edge docking on Wayland | `libgtk4-layer-shell-dev` | `gtk4-layer-shell-devel` |
| `libx11` | always-on-top on X11 | `libx11-dev` | `libX11-devel` |

```sh
sudo apt install libsqlite3-dev libgtk-4-dev libgtk4-layer-shell-dev libx11-dev
```

**The command line needs none of the GTK packages.** `pulse --json`,
`--refresh`, `--set-key` and the status-line hook link no GUI libraries at all —
verified, `ldd` on the built binary reports zero — so a server or a container can
run them with only SQLite present. The panel is a separate executable and its
targets are only defined when GTK4 can be found by pkg-config, which is what
keeps `swift test` working on a machine without the headers.

### Swift

The toolchain is not in any distribution's packages. Any 6.x release works;
Ubuntu 24.04's glibc is new enough for the official 24.04 build.

```sh
# On Ubuntu 24.04
curl -O https://download.swift.org/swift-6.0.3-release/ubuntu2404/swift-6.0.3-RELEASE/swift-6.0.3-RELEASE-ubuntu24.04.tar.gz
mkdir -p ~/.local/share/swift && tar xzf swift-6.0.3-RELEASE-ubuntu24.04.tar.gz -C ~/.local/share/swift
export PATH="$HOME/.local/share/swift/swift-6.0.3-RELEASE-ubuntu24.04/usr/bin:$PATH"
```

This port was developed and verified against **6.4.0 on Ubuntu 22.04's build**,
because the machine it was written on has glibc 2.38 and the 24.04 build wants
2.39. On a 24.04 system the newer build is the easier choice.

## Building

```sh
git clone https://github.com/Acidmoon/Linux-Pulse
cd Linux-Pulse
source Scripts/linux/swift-env.sh   # puts the toolchain on PATH
swift build -c release
```

Two binaries come out:

- `.build/release/Pulse` — the command line, and the Claude Code status line.
- `.build/release/PulsePanel` — the floating panel. Built only where GTK4 is.

`Scripts/linux/panel-env.sh` checks that GTK4, layer-shell and X11 can be found
and says which versions it found. If a machine cannot install them,
`Scripts/linux/gtk4-sysroot.sh` unpacks the development files into a directory
instead — that is how this port was built, and the script says what it does and
what it does not.

## Installing

```sh
Scripts/linux/install.sh                 # into ~/.local
Scripts/linux/install.sh --prefix /usr/local
Scripts/linux/install.sh --uninstall
```

**A build directory is not an installation, and the documentation said it was.**
Everything here writes `pulse --json` and `pulse --place`, and a reader who typed
that got `找不到命令 pulse` — on a machine where the binary is called `Pulse`,
capitalised, and lives in `.build/release/`. The script builds a release build if
there is not one, then installs:

```
~/.local/bin/pulse                 → ~/.local/lib/pulse/Pulse    (a symlink)
~/.local/lib/pulse/PulsePanel      the panel
~/.local/lib/pulse/Pulse_Pulse.bundle   provider logos and strings
```

**Only a symlink in `bin`, everything else in `lib/pulse`, and both halves
matter.** The symlink is what makes the command the name the documentation uses
and the name `PATH` already has. The real file being in `lib/pulse` is what makes
`Bundle.module` find the resources — it resolves through `/proc/self/exe`, which
follows the link — and what makes `--autostart` write an `Exec` line naming
`lib/pulse/PulsePanel`, resolved by the rule in `LinuxLoginItem`. Verified by
installing to a scratch prefix and rendering the same rail from both locations,
byte for byte.

If the panel's libraries are outside the loader's search path — which is the
documented path on Ubuntu 24.04, where `libgtk4-layer-shell` is not packaged and
`Scripts/linux/gtk4-sysroot.sh` puts it somewhere of its own — the installer
writes `PulsePanel` as a two-line shell wrapper that sets `LD_LIBRARY_PATH` and
execs the real binary at `.PulsePanel`. Both `pulse` with no arguments and the
autostart entry look for the name `PulsePanel`, and both run a script happily.

## Running

```sh
pulse --refresh     # ask every enabled provider once, and fill the cache
pulse --json        # what the panel will show, as JSON
pulse               # with no arguments: open the panel
```

Without the installer, the same commands are `./.build/release/Pulse --refresh`
and so on; `Scripts/linux/install.sh` above is what makes `pulse` a word.

The last one finds the panel **that belongs to this command** — beside the real
binary, or in `../lib/pulse` — and hands the process over with `execv`, so the
panel inherits the terminal and the command returns when the panel exits. It
does not search `PATH`: finding a different Pulse's panel would be worse than
finding none. When there is no panel it says so, rather than printing the usage
text at somebody who asked for a window.

**The path is found through `/proc/self/exe`, not `argv[0]`, and that is
measured.** A command reached through `PATH` is invoked with the bare word as
`argv[0]` — `pulse`, with no directory in it — so anything derived from it is
empty. The symptom was `pulse --autostart on` answering "Is PulsePanel next to
this binary?" on an install where `PulsePanel` was exactly where it belongs.

The panel is docked to a screen edge, floats above other windows, keeps out of
the task list, and takes no focus. Move the pointer to the edge and the rail
opens; hover a ring and its card appears beside it.

**Where the rail sits** is stored in `~/.config/Pulse.plist` — the same file the
command line reads, by name rather than by file location: see
`PulseDefaults` for why that had to be made explicit.

## Starting it at login

```sh
pulse --autostart on      # writes the file below
pulse --autostart off
```

That writes `~/.config/autostart/pulse.desktop`:

```ini
[Desktop Entry]
Type=Application
Name=Pulse
Exec=/home/you/.local/lib/pulse/PulsePanel
Terminal=false
StartupNotify=false
```

`LinuxLoginItem` writes exactly that file, and `pulse.desktop` is what a
desktop's own startup-applications list will show and can remove. The `Exec` path
is absolute — an `Exec` of `./…` would be resolved against the login session's
working directory, which is not the one it was written from, and the entry would
be there, read back as "on", and start nothing.

## Wayland and X11

The panel runs on both and **behaves differently on each**, because the two
protocols are different rather than because the code is:

| | X11 | Wayland |
|---|---|---|
| Docking to the edge | EWMH, through `Sources/CX11` | `wlr-layer-shell` |
| Always on top | `_NET_WM_STATE_ABOVE` | the layer shell's `TOP` layer |
| No taskbar entry | `_NET_WM_STATE_SKIP_TASKBAR` | implied by the layer |
| Following the pointer's display | `XQueryPointer`, works | **not possible** |

**GNOME does not implement `wlr-layer-shell`.** On Mutter the panel says so on
stderr and appears as an ordinary window rather than silently doing nothing.
That covers GNOME on Wayland; GNOME on X11 is unaffected.

## Uninstalling

There is nothing outside `~/.config/Pulse.plist`, `~/.config/autostart/pulse.desktop`
and Pulse's own cache directory. `pulse --uninstall-statusline` removes the
status-line entry from Claude Code's settings.
