#!/usr/bin/env bash
# Runs the test suite against settings of its own.
#
# **Because the suite writes settings.** Everything in Pulse reads and writes
# through `PulseDefaults.shared`, so a test that changes a setting changes the
# developer's — running `swift test` by hand left `~/.config/Pulse.plist` holding
# a fixture's `['codex#test']` instead of the rail its owner had chosen.
# `PULSE_DEFAULTS_SUITE` points every one of those writes at a throwaway suite
# under the XDG config directory, where they belong. Use this instead of calling
# `swift test` directly.
set -euo pipefail
cd "$(dirname "$0")/../.."
source Scripts/linux/panel-env.sh >/dev/null 2>&1 || true
source Scripts/linux/swift-env.sh
export PULSE_DEFAULTS_SUITE="${PULSE_DEFAULTS_SUITE:-pulse-tests}"
exec swift test "$@"
