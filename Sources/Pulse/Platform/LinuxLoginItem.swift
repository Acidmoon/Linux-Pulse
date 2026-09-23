#if !canImport(ServiceManagement)
import Foundation

/// Starting Pulse when the user logs in, on Linux.
///
/// **The replacement for `SMAppService` and for the launch agent beside it.**
/// Upstream needed two routes because `SMAppService.mainApp` only works for an
/// app in a real `.app` bundle and a bare executable has to write a launch agent
/// instead. Linux has one route and it is the same shape as that second one: a
/// `.desktop` file in `~/.config/autostart`, which every desktop reads at login.
/// Nothing has to be loaded for it to take effect next time, and nothing has to
/// be running for it to be written — which is exactly what upstream says about
/// `~/Library/LaunchAgents`.
///
/// **Written by hand rather than through a library.** `libsystemd`'s and
/// GLib's autostart helpers would both be dependencies for eleven lines of
/// `key=value`, and the format is specified by the Desktop Entry Specification
/// rather than by either of them.
enum LinuxLoginItem {
    enum State: Equatable {
        case on
        case off
        /// Present, but not pointing at a binary that exists — which is what an
        /// install that moved looks like, and is worth saying rather than
        /// reporting as "on".
        case missingTarget
    }

    /// `$XDG_CONFIG_HOME/autostart`, which is `~/.config/autostart` unless the
    /// reader has said otherwise. `XDG_CONFIG_HOME` is honoured because the
    /// specification says so and because a reader who has moved their config
    /// directory has moved it for a reason.
    static var directory: URL {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("autostart")
    }

    /// Named after the application rather than the binary: the file is what a
    /// desktop's startup-applications list shows, and `pulse.desktop` reads as
    /// the application while `PulsePanel.desktop` reads as an implementation.
    static var fileURL: URL { directory.appendingPathComponent("pulse.desktop") }

    /// The panel, which is what should start — not the command-line binary.
    /// Found beside the running executable, the way `PulseLinuxMain` finds it
    /// for `pulse` with no arguments: the two are installed together and
    /// finding a *different* Pulse on `PATH` would be worse than finding none.
    static var panelExecutable: String? {
        let selfPath = CommandLine.arguments.first ?? ""
        let directory = (selfPath as NSString).deletingLastPathComponent
        let candidates = [
            directory.isEmpty ? nil : (directory as NSString).appendingPathComponent("PulsePanel"),
            // Installed to a `lib` directory beside the one on `PATH`, which is
            // where `Scripts/install.sh` puts it.
            directory.isEmpty ? nil
                : ((directory as NSString).deletingLastPathComponent as NSString)
                    .appendingPathComponent("lib/pulse/PulsePanel"),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var state: State {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .off }
        guard let target = panelExecutable else { return .missingTarget }
        // The file is ours, so it is read rather than trusted: an install that
        // moved leaves an Exec line pointing at nothing, and starting nothing at
        // login is worth knowing about before it happens.
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8),
              let exec = execLine(in: text) else { return .missingTarget }
        return FileManager.default.isExecutableFile(atPath: exec) ? .on : .missingTarget
    }

    static var isEnabled: Bool { state == .on }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        guard enabled else {
            try? FileManager.default.removeItem(at: fileURL)
            return true
        }
        guard let panel = panelExecutable else { return false }
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            try contents(panel: panel).write(to: fileURL, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// The file itself, kept separate so it can be asserted rather than only
    /// written.
    static func contents(panel: String) -> String {
        """
        [Desktop Entry]
        Type=Application
        Name=Pulse
        Comment=AI coding tool usage, on the edge of the screen
        Exec=\(panel)
        # **No `Terminal=true` and no `StartupNotify`.** The panel draws its own
        # window and has nothing to say in a terminal; asking for one would put a
        # console on screen at every login.
        Terminal=false
        StartupNotify=false
        # A panel is not a document: reopening a session should not start a
        # second one, and `X-GNOME-Autostart-enabled` is what GNOME reads.
        X-GNOME-Autostart-enabled=true
        """
    }

    /// The `Exec=` value, with the quoting the specification allows removed.
    static func execLine(in contents: String) -> String? {
        for line in contents.split(separator: "\n") where line.hasPrefix("Exec=") {
            return line.dropFirst("Exec=".count)
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }
}
#endif
