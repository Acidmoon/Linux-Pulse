#!/usr/bin/env bash
# Puts a Swift toolchain on PATH for a Linux build.
#
# Source it, do not run it:
#
#     source Scripts/linux/swift-env.sh
#     swift build
#
# Why a script rather than an assumption that `swift` is installed: the
# toolchain here is a tarball from swift.org, not a distribution package, and
# which one is right depends on the glibc the host ships. The Ubuntu 24.04
# build wants glibc >= 2.39; Debian 12, Deepin 25 and Ubuntu 22.04 are all
# below that and need the Ubuntu 22.04 build instead. Picking the wrong one
# fails at the first link, not at download time, so pinning it in one place
# is cheaper than rediscovering it.
#
# `SWIFT_TOOLCHAIN_ROOT` wins if it is already set, which is what CI does.
# Otherwise the newest swift-*-RELEASE-ubuntu22.04 under
# ~/.local/share/swift/tc is used.

set -o pipefail

_pulse_swift_root="${SWIFT_TOOLCHAIN_ROOT:-}"

if [[ -z "$_pulse_swift_root" ]]; then
    _pulse_tc_base="${PULSE_SWIFT_TC_BASE:-$HOME/.local/share/swift/tc}"
    if [[ -d "$_pulse_tc_base" ]]; then
        # `sort -V` so swift-6.10.0 sorts after swift-6.9.0, which a plain
        # lexicographic sort gets backwards.
        _pulse_swift_root="$(
            find "$_pulse_tc_base" -maxdepth 1 -type d -name 'swift-*-RELEASE-*' 2>/dev/null \
                | sort -V | tail -n 1
        )"
    fi
fi

if [[ -z "$_pulse_swift_root" || ! -x "$_pulse_swift_root/usr/bin/swift" ]]; then
    cat >&2 <<'EOF'
Pulse: no Swift toolchain found.

Install one, then re-source this script:

  mkdir -p ~/.local/share/swift/tc && cd ~/.local/share/swift
  curl -fSLO https://download.swift.org/swift-6.4.0-release/ubuntu2204/swift-6.4.0-RELEASE/swift-6.4.0-RELEASE-ubuntu22.04.tar.gz
  tar -xzf swift-6.4.0-RELEASE-ubuntu22.04.tar.gz -C tc

Or point SWIFT_TOOLCHAIN_ROOT at an existing toolchain:

  export SWIFT_TOOLCHAIN_ROOT=/opt/swift/usr

Use the Ubuntu 22.04 build on any glibc below 2.39 (Debian 12, Deepin 25,
Ubuntu 22.04). The 24.04 build needs 2.39 or newer. Check with:

  ldd --version | head -1
EOF
    unset _pulse_swift_root _pulse_tc_base
    return 1 2>/dev/null || exit 1
fi

export SWIFT_TOOLCHAIN_ROOT="$_pulse_swift_root"
case ":$PATH:" in
    *":$SWIFT_TOOLCHAIN_ROOT/usr/bin:"*) ;;
    *) export PATH="$SWIFT_TOOLCHAIN_ROOT/usr/bin:$PATH" ;;
esac

unset _pulse_swift_root _pulse_tc_base
