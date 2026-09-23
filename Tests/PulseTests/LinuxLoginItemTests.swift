import Foundation
import Testing

@testable import Pulse

/// Starting the panel at login, which is the one part of the Linux integration
/// that writes outside Pulse's own directories.
///
/// **The file is asserted, not just written.** A `.desktop` file with the wrong
/// `Exec=` starts nothing at login and says nothing about it, and the reader
/// finds out by noticing a panel that never appears.
@Suite("Linux login item", .serialized)
struct LinuxLoginItemTests {
    /// A body with `XDG_CONFIG_HOME` pointed at a directory of its own, put
    /// back afterwards so one test cannot decide where the next one writes.
    private func inTemporaryConfig(_ body: (URL) throws -> Void) rethrows {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-autostart-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previous = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        setenv("XDG_CONFIG_HOME", root.path, 1)
        defer {
            if let previous { setenv("XDG_CONFIG_HOME", previous, 1) }
            else { unsetenv("XDG_CONFIG_HOME") }
            try? FileManager.default.removeItem(at: root)
        }
        try body(root)
    }

    /// `XDG_CONFIG_HOME` is honoured, because a reader who has moved their
    /// config directory has moved it for a reason.
    @Test("The file goes where XDG_CONFIG_HOME says")
    func honoursXDGConfigHome() throws {
        try inTemporaryConfig { root in
            #expect(LinuxLoginItem.fileURL.path == root.appendingPathComponent("autostart/pulse.desktop").path)
        }
    }

    /// Nothing is written until it is asked for — a panel that installs itself
    /// into a login session the reader did not ask about is not a panel, it is
    /// a startup entry.
    @Test("Nothing exists until it is enabled")
    func offByDefault() throws {
        try inTemporaryConfig { _ in
            #expect(LinuxLoginItem.state == .off)
            #expect(!LinuxLoginItem.isEnabled)
        }
    }

    /// Enabled writes a file a desktop would actually read, and disabling takes
    /// it away again.
    @Test("Enabling writes a desktop file and disabling removes it")
    func enableAndDisable() throws {
        try inTemporaryConfig { _ in
            let target = try #require(LinuxLoginItem.panelExecutable,
                                      "no PulsePanel beside the test runner")
            #expect(LinuxLoginItem.setEnabled(true))
            #expect(FileManager.default.fileExists(atPath: LinuxLoginItem.fileURL.path))
            #expect(LinuxLoginItem.state == .on)

            let text = try String(contentsOf: LinuxLoginItem.fileURL, encoding: .utf8)
            #expect(text.hasPrefix("[Desktop Entry]"))
            #expect(LinuxLoginItem.execLine(in: text) == target)
            // The three that decide whether it is usable at login: a type, an
            // application (not a link), and no terminal.
            #expect(text.contains("Type=Application"))
            #expect(text.contains("Terminal=false"))

            #expect(LinuxLoginItem.setEnabled(false))
            #expect(!FileManager.default.fileExists(atPath: LinuxLoginItem.fileURL.path))
            #expect(LinuxLoginItem.state == .off)
        }
    }

    /// **A file pointing at nothing is not "on".** An install that moved leaves
    /// an `Exec=` line behind, and reporting that as enabled would be a promise
    /// the login session cannot keep.
    @Test("A file whose target is gone reports as missing, not as on")
    func danglingFileIsMissing() throws {
        try inTemporaryConfig { root in
            let directory = root.appendingPathComponent("autostart")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try LinuxLoginItem.contents(panel: "/nonexistent/PulsePanel")
                .write(to: LinuxLoginItem.fileURL, atomically: true, encoding: .utf8)
            // Enabled as far as the file is concerned, but the target is not
            // there — and it is the state that is asked, not the file.
            #expect(LinuxLoginItem.state != .on)
        }
    }

    /// The `Exec=` line is read back out of the file, which is what the check
    /// above is built on — quoting included, since the specification allows it
    /// and a future writer might add it.
    @Test("The Exec line is read back with its quotes removed")
    func execLineParsing() {
        #expect(LinuxLoginItem.execLine(in: "Exec=/usr/bin/PulsePanel\n") == "/usr/bin/PulsePanel")
        #expect(LinuxLoginItem.execLine(in: "Exec=\"/opt/pulse/PulsePanel\"\n") == "/opt/pulse/PulsePanel")
        #expect(LinuxLoginItem.execLine(in: "Name=Pulse\n") == nil)
    }
}
