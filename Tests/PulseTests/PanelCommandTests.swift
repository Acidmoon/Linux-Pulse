import Foundation
import Testing

@testable import Pulse

/// The panel's own controls: `pulse --place`, `--position`, `--quit`,
/// `--autostart` — and the reload they drive.
///
/// **These are hermetic.** `PULSE_DEFAULTS_SUITE` moves both `PulseDefaults` and
/// `SettingsFile` to a throwaway name, so a test here writes a file of its own
/// rather than the reader's `~/.config/Pulse.plist`. `Scripts/linux/test.sh`
/// sets it.
@Suite("Panel commands", .serialized)
struct PanelCommandTests {
    /// A settings file of this test's own, written directly.
    ///
    /// **Written as a file, not through `UserDefaults`, on purpose.** The
    /// placement reload exists *because* `UserDefaults` cannot see another
    /// process's write; a test that wrote through it could not tell a working
    /// reload from one that was quietly reading the process's own cache, which
    /// is exactly how the first version of this passed nothing at all.
    private func inOwnSettings(_ body: () throws -> Void) rethrows {
        let previousDefaults = PulseDefaults.shared
        let previousSuite = ProcessInfo.processInfo.environment["PULSE_DEFAULTS_SUITE"]
        let previousRuntime = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"]
        let name = "pulse-panel-tests-\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        setenv("PULSE_DEFAULTS_SUITE", name, 1)
        setenv("XDG_RUNTIME_DIR", root.path, 1)
        PulseDefaults.shared = UserDefaults(suiteName: name) ?? .standard
        defer {
            PulseDefaults.shared.removePersistentDomain(forName: name)
            PulseDefaults.shared = previousDefaults
            if let previousSuite { setenv("PULSE_DEFAULTS_SUITE", previousSuite, 1) }
            else { unsetenv("PULSE_DEFAULTS_SUITE") }
            if let previousRuntime { setenv("XDG_RUNTIME_DIR", previousRuntime, 1) }
            else { unsetenv("XDG_RUNTIME_DIR") }
            try? FileManager.default.removeItem(at: root)
        }
        try body()
    }

    private func writeSettings(_ values: [String: Any]) {
        try? PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
            .write(to: SettingsFile.url)
    }

    /// **The one that matters.** A panel that is already running is told to
    /// re-read, and it has to see the value that is *in the file*.
    @Test("The placement is read from the file, not from the process's defaults")
    func reloadReadsTheFile() throws {
        try inOwnSettings {
            // A value the defaults have never seen, so nothing in this process
            // could be answering from a cache.
            writeSettings([
                "panel.floating": false,
                "panel.edge": "left",
                "panel.verticalRatio": 0.25,
                "panel.horizontalRatio": 1.0,
            ])

            let placement = PanelPlacement.reloaded()
            #expect(placement.edge == .left)
            #expect(placement.isDocked)
            #expect(placement.verticalRatio == 0.25, "read \(placement.verticalRatio)")
        }
    }

    /// A floating panel reloads as floating, which is a different branch of the
    /// same read.
    @Test("Floating is read back as floating")
    func reloadReadsFloating() throws {
        try inOwnSettings {
            writeSettings([
                "panel.floating": true,
                "panel.edge": "right",
                "panel.verticalRatio": 0.7,
                "panel.horizontalRatio": 0.3,
            ])

            let placement = PanelPlacement.reloaded()
            #expect(!placement.isDocked)
            #expect(placement.horizontalRatio == 0.3)
            #expect(placement.verticalRatio == 0.7)
        }
    }

    /// A file that is not there, or is rubbish, leaves the panel as it was
    /// rather than refusing to show anything — a first run has no file at all.
    @Test("No file leaves the placement alone instead of failing")
    func missingFile() throws {
        try inOwnSettings {
            try? FileManager.default.removeItem(at: SettingsFile.url)
            // Answering at all is the assertion: this is the first-launch path.
            _ = PanelPlacement.reloaded()
        }
    }

    /// The rail's own settings come from the file too, so `--enable` reaches a
    /// panel that is already running.
    @Test("Switching a provider on reaches the settings the panel is holding")
    func reloadReadsTheRail() throws {
        try inOwnSettings {
            let settings = AppSettings.restored()
            settings.setEnabled(true, for: AccountKey(.codex))
            PulseDefaults.shared.synchronize()

            // Written behind the live instance's back, exactly as another
            // process does it.
            writeSettings([ProviderSelection.enabledKey: ["codex", "kimiCode"]])

            settings.adoptCommandLineSettings()
            let accounts = settings.shownAccounts.map(\.id)
            #expect(accounts.contains("kimiCode"), "the rail says \(accounts)")
        }
    }

    // MARK: - The pid file

    @Test("The pid file names this process, and is found again")
    func pidFileRoundTrip() throws {
        try inOwnSettings {
            #expect(PanelProcess.running() == nil, "a pid file appeared from nowhere")
            #expect(PanelProcess.claim())
            #expect(PanelProcess.running() == getpid())

            PanelProcess.release()
            #expect(PanelProcess.running() == nil)
        }
    }

    /// **A pid file left by a killed panel is cleaned up, not believed.** The
    /// panel is killed by `pkill` often enough, and `kill(pid, 0)` is how a stale
    /// file is told from a live one. Without this, `--quit` would report that it
    /// stopped a panel that had been gone for days.
    @Test("A pid file for a process that is gone is discarded")
    func stalePidFile() throws {
        try inOwnSettings {
            // 1 is `init`, and it is never a Pulse panel; a pid nobody owns is
            // harder to pick portably. `kill(1, 0)` succeeds for root and fails
            // with EPERM otherwise, and EPERM counts as alive — so the pid that
            // is reliably absent is a very large one.
            try? Data("999999\n".utf8).write(to: PanelProcess.pidFileURL)

            #expect(PanelProcess.running() == nil)
            #expect(!FileManager.default.fileExists(atPath: PanelProcess.pidFileURL.path),
                    "the stale file was left behind")
        }
    }

    @Test("Sending to a panel that is not running says so rather than signalling a stranger")
    func sendWithoutAPanel() throws {
        try inOwnSettings {
            #expect(!PanelProcess.send(SIGUSR1))
        }
    }

    // MARK: - Arguments

    /// Claiming is asked as a **question**, never by running the command.
    ///
    /// The first version of this called `run(argument:)` over every argument,
    /// which is not a test of claiming at all — and over `--quit` it sent
    /// `SIGTERM` to whatever pid file the machine had, because these tests were
    /// not yet isolated from it. It killed the running panel. Hence `claims`.
    @Test("Every argument the command owns is one it claims")
    func claimedArguments() {
        for argument in PanelCommand.arguments {
            #expect(PanelCommand.claims(argument), "\(argument) is not claimed")
        }
    }

    @Test("An argument it does not own is left for the next mode")
    func unclaimed() {
        #expect(!PanelCommand.claims("--json"))
        #expect(PanelCommand.run(argument: "--json") == nil)
    }

    /// **`--quit` with no panel must not signal anybody.** It is the one command
    /// here whose mistake is not a wrong value but a killed process, so it is
    /// run against a runtime directory with nothing in it and has to come back
    /// having done nothing.
    @Test("Quitting with no panel running does nothing and says so")
    func quitWithNoPanel() throws {
        try inOwnSettings {
            #expect(PanelCommand.run(argument: PanelCommand.quitArgument) == 1)
            #expect(PanelProcess.running() == nil)
        }
    }
}
