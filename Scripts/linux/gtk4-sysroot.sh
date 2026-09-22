#!/usr/bin/env bash
# Unpack GTK4's development files into a directory, without root.
#
# For a machine where `sudo apt install libgtk-4-dev` is not available: CI
# images without a package cache, containers built with `--user`, or a
# distribution that carries GTK4's runtime but not its headers. It downloads the
# .deb files, unpacks them, and rewrites the `prefix=` line in each extracted
# `.pc` so pkg-config reports the header paths inside the directory.
#
# **Not the supported path.** `Docs/linux/install.md` says
# `libgtk-4-dev libgtk4-layer-shell-dev libx11-dev`, and this script exists only
# because the machine the port was developed on could not install them. Two
# things about it are worth knowing before relying on it:
#
#   - It unpacks **headers and .pc files only**; the shared objects stay the
#     system's. A library whose *runtime* the system also lacks — measured here
#     with `libgtk4-layer-shell0` — has to be fetched the same way, so this
#     script takes extra package names.
#   - Some `.pc` files name dependencies whose packages ship under a different
#     name than the module (`libjpeg.pc` is in `libjpeg62-turbo-dev`, not in the
#     `libjpeg-dev` metapackage). Those get empty stub `.pc` files, which is
#     correct for compiling — they are leaves, and their `-l` flags are on
#     libraries GTK4 links anyway.
#
# Usage: Scripts/linux/gtk4-sysroot.sh [destination] [extra-package ...]

set -euo pipefail

destination="${1:-$HOME/.local/share/pulse-gtk4/sysroot}"
shift || true

packages=(
    libgtk-4-dev libgtk4-layer-shell-dev
    libcairo2-dev libpango1.0-dev libgdk-pixbuf-2.0-dev libgraphene-1.0-dev
    libharfbuzz-dev libfreetype-dev libfontconfig-dev libpng-dev libepoxy-dev
    libx11-dev libxext-dev libxi-dev libxrandr-dev libxinerama-dev
    libxcomposite-dev libxcursor-dev libxdamage-dev libxfixes-dev
    libxkbcommon-dev libwayland-dev libegl-dev libglib2.0-dev libfribidi-dev
    libxrender-dev libpixman-1-dev libxcb1-dev libxft-dev
    x11proto-dev libbz2-dev libexpat1-dev libgraphite2-dev
    libjpeg62-turbo-dev libtiff-dev libvulkan-dev libxau-dev
    libxcb-render0-dev libxcb-shm0-dev libxdmcp-dev libdatrie-dev liblerc-dev
    libthai-dev libwebp-dev libdeflate-dev liblzma-dev
)

if [ "$#" -gt 0 ]; then
    packages+=("$@")
fi

work="$(mktemp -d)"
echo "gtk4-sysroot: unpacking into $destination"
mkdir -p "$destination"

cd "$work"
# `apt-get download` does not fail the script when one name is unknown, which is
# deliberate: the list above is a superset, and the loop below reports what is
# still missing rather than what could not be fetched.
apt-get download "${packages[@]}" 2>&1 | tail -3 || true
for deb in *.deb; do
    [ -e "$deb" ] || continue
    dpkg -x "$deb" "$destination"
done

# The extracted .pc files say `prefix=/usr`. Point them at the directory they
# were actually unpacked into, so no PKG_CONFIG_SYSROOT_DIR is needed — that
# variable would also rewrite the *system's* .pc files, which is what broke the
# first attempt at this (glib's headers live in /usr and are not unpacked here).
find "$destination" -name '*.pc' -print0 | while IFS= read -r -d '' pc; do
    sed -i "s|=/usr|=$destination/usr|g; s| -I/usr| -I$destination/usr|g; s| -L/usr| -L$destination/usr|g; s| /usr/| $destination/usr/|g" "$pc"
done

# Whatever is still unresolvable gets an empty stub, and is named on the way out.
missing="$(PKG_CONFIG_PATH="$destination/usr/lib/x86_64-linux-gnu/pkgconfig:$destination/usr/share/pkgconfig:/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/share/pkgconfig" \
    pkg-config --cflags gtk4 gtk4-layer-shell-0 2>&1 \
    | grep -oE "Package '[^']+'" | tr -d "'" | sed 's/Package //' | sort -u || true)"

for module in $missing; do
    printf 'Name: %s\nDescription: Stub for a leaf dependency whose package ships under another name.\nVersion: 1.0.0\nCflags:\nLibs:\n' "$module" \
        > "$destination/usr/lib/x86_64-linux-gnu/pkgconfig/$module.pc"
    echo "gtk4-sysroot: stubbed $module"
done

rm -rf "$work"
echo "gtk4-sysroot: done. Use it with: source Scripts/linux/panel-env.sh"
