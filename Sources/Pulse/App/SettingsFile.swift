// pulse-linux: excluded — on macOS the settings live behind `cfprefsd`, which
// is a cross-process service and does not need any of this.
#if !canImport(AppKit)
import Foundation

/// The settings file, read as a file.
///
/// **Because `UserDefaults` cannot see another process's write, and that was
/// measured rather than assumed.** `pulse --place` writes the settings and tells
/// the running panel to read them again; the panel's `UserDefaults` went on
/// reporting the values it started with, and so did a freshly constructed
/// `UserDefaults` for the same suite. A probe — one process holding a suite,
/// another rewriting its plist — read `nil` before the write, `nil` three
/// seconds after it, and `nil` from a rebuilt instance, while the same instance
/// could still see a key it had written itself. Foundation on Linux keeps a
/// process-wide registry of parsed domains and hands the same one back; only the
/// file has the new values.
///
/// On macOS none of this is necessary: `cfprefsd` exists precisely so that a
/// write from one process is a read in another, and `UserDefaults` there is a
/// proxy to it.
enum SettingsFile {
    /// The same name `PulseDefaults` uses for the suite, which is the file's
    /// name without the extension. `PULSE_DEFAULTS_SUITE` moves both, so a test
    /// run cannot read the reader's settings by accident.
    static var suiteName: String {
        ProcessInfo.processInfo.environment["PULSE_DEFAULTS_SUITE"] ?? "Pulse"
    }

    /// `$XDG_CONFIG_HOME/Pulse.plist`, which is where swift-corelibs-foundation
    /// puts a suite — verified by reading the file the running panel writes. The
    /// fallback is `~/.config`, which is the same path for every session that
    /// does not set the variable.
    static var url: URL {
        let environment = ProcessInfo.processInfo.environment
        let config = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config").path
        return URL(fileURLWithPath: config).appendingPathComponent("\(suiteName).plist")
    }

    /// The stored settings, as they are on disk at this moment.
    ///
    /// `nil` when there is no file or it cannot be parsed — a first run, or a
    /// half-written file — and every caller falls back to whatever it had, which
    /// is the right answer for both: none of these settings is worth refusing to
    /// show a panel over.
    static func read() -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil))
            as? [String: Any]
    }
}
#endif
