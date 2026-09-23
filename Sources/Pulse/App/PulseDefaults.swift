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
    #if canImport(AppKit)
    /// On a Mac this is the bundle's own domain, which is what every Pulse on
    /// that machine already uses.
    nonisolated(unsafe) static let shared = UserDefaults.standard
    #else
    /// The suite named `Pulse`, which swift-corelibs-foundation reads and writes
    /// as `~/.config/Pulse.plist` — the same file the command-line binary has
    /// always used, so nothing moves for anyone already running it.
    /// `nonisolated(unsafe)` for `UserDefaults`' own reason, not this file's:
    /// the class is thread-safe and simply is not marked `Sendable`. Upstream
    /// reached it as `UserDefaults.standard`, which has the same shape.
    nonisolated(unsafe) static let shared: UserDefaults = UserDefaults(suiteName: "Pulse") ?? .standard
    #endif
}
