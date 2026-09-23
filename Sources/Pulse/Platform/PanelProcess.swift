// pulse-linux: excluded — the panel is a Mac app on macOS, and there is no
// second process to find.
#if !canImport(AppKit)
import Foundation

#if canImport(Glibc)
import Glibc
#endif

/// The running panel, found by its pid file.
///
/// **Why a file and not a search.** `pkill -x PulsePanel` works and is what a
/// reader reaches for, but it matches on a name any process can have, and it
/// cannot tell a panel running from this build apart from one running from a
/// stale install. `--quit` has to signal *the* panel that belongs to this
/// account's session, and the panel is the only thing that knows its own pid, so
/// it writes it down.
///
/// Nothing here links GTK: the command line has to work over ssh and in a
/// container, which is the whole reason the CLI exists. It is only a file and a
/// `kill`.
package enum PanelProcess {
    /// `$XDG_RUNTIME_DIR` is the right place — per-user, already 0700, and
    /// cleared by the session at logout, so a pid file cannot outlive the
    /// session that made it. The fallback is for a session that does not set it,
    /// which a bare `ssh` login does not.
    package static var pidFileURL: URL {
        let environment = ProcessInfo.processInfo.environment
        if let runtime = environment["XDG_RUNTIME_DIR"], !runtime.isEmpty {
            return URL(fileURLWithPath: runtime).appendingPathComponent("pulse-panel.pid")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/pulse/panel.pid")
    }

    /// Writes this process's pid, so `--quit` can find it. Called by the panel.
    @discardableResult
    package static func claim() -> Bool {
        let url = pidFileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        return (try? Data("\(getpid())\n".utf8).write(to: url, options: .atomic)) != nil
    }

    /// Removes it again, on the way out.
    package static func release() {
        try? FileManager.default.removeItem(at: pidFileURL)
    }

    /// The panel's pid if one is running, and `nil` otherwise.
    ///
    /// **A stale file is cleaned up rather than reported.** A killed panel — by
    /// `pkill`, by a crash, by the OOM killer — leaves the file behind, and
    /// `kill(pid, 0)` is how the difference is told: it succeeds for a process
    /// that exists, fails with `ESRCH` for one that does not, and fails with
    /// `EPERM` for one that exists and belongs to somebody else. `EPERM` counts
    /// as alive, because it is.
    package static func running() -> Int32? {
        guard let text = try? String(contentsOf: pidFileURL, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0 else { return nil }

        guard kill(pid, 0) == 0 || errno == EPERM else {
            release()
            return nil
        }
        return pid
    }

    /// Sends a signal to the running panel. `false` when there is not one.
    @discardableResult
    package static func send(_ signal: Int32) -> Bool {
        guard let pid = running() else { return false }
        return kill(pid, signal) == 0
    }
}
#endif
