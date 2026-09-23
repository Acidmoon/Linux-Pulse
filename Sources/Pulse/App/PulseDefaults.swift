import Foundation

/// Where Pulse's settings live.
///
/// **Named explicitly on Linux, because the alternative is named after the
/// executable.** `UserDefaults.standard` in swift-corelibs-foundation takes its
/// domain from `ProcessInfo.processInfo.processName`, which is the *file name of
/// the running binary* — and it is the real file, not `argv[0]`: a symlink named
/// `Pulse` still reports the name it points at, and `exec -a Pulse` does not
/// change it either. Measured, all three.
///
/// That was fine while there was one binary. There are two now — `Pulse` for the
/// command line and `PulsePanel` for the rail — and they are two halves of one
/// application that must agree about which providers are switched on, where the
/// rail is docked, and every other thing the reader has chosen. Left to
/// `.standard` they would read different files and each would look like a fresh
/// install to the other, which is exactly what happened: the panel came up with
/// no rings while `pulse --json` listed three accounts, and the cause was a file
/// name.
///
/// **macOS keeps `.standard`.** There, the domain is the app's bundle
/// identifier, both executables are the same app, and changing it would move
/// every existing reader's settings. The platform difference is the point of
/// this file: one place that says where settings live, differing only where the
/// platforms do.
enum PulseDefaults {
    /// **`var`, so a test can point it somewhere of its own.**
    ///
    /// A `let` was the tidier thing and it made these tests untestable in the
    /// way that matters: everything reads and writes through this one value, so
    /// a test that changes a setting changes the machine's, and a test that
    /// asserts on a setting asserts about whatever else in the suite wrote last.
    /// Two tests here passed alone and failed in the suite for exactly that
    /// reason — and before that they were quietly writing to the developer's own
    /// settings file.
    ///
    /// `nonisolated(unsafe)` because a global var is; the atomicity that matters
    /// is `UserDefaults`' own, and nothing swaps this outside a test's setup and
    /// teardown. `Sources/PulsePanel` never touches it.
    nonisolated(unsafe) static var shared: UserDefaults = {
        #if canImport(AppKit)
        // On a Mac this is the bundle's own domain, which is what every Pulse on
        // that machine already uses.
        return UserDefaults.standard
        #else
        // The suite named `Pulse`, which swift-corelibs-foundation reads and
        // writes as `~/.config/Pulse.plist` — the same file the command-line
        // binary has always used, so nothing moves for anyone already running
        // it.
        //
        // **`PULSE_DEFAULTS_SUITE` redirects it, and the test suite sets it.**
        // `swift test` was writing the developer's own settings: everything
        // reads and writes through this one value, so any test that changes a
        // setting changes the machine's — running the suite left this file
        // holding `settings.enabledProviders = ['codex#test']`, a ring from
        // somebody's fixture, and left it there. `Scripts/linux/test.sh` and CI
        // both set the variable, so the suite is hermetic without every test
        // having to remember.
        let suite = ProcessInfo.processInfo.environment["PULSE_DEFAULTS_SUITE"] ?? "Pulse"
        return UserDefaults(suiteName: suite) ?? .standard
        #endif
    }()
}
