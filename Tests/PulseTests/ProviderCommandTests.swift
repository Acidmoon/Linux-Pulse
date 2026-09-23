import Foundation
import Testing

@testable import Pulse

/// `--enable` and `--disable`, which are how the rail's contents get set.
///
/// **And the write they make has to reach the file.** `UserDefaults` on Linux
/// keeps its values in memory and reaches the disk on a timer or at exit, and
/// these commands *are* the process — so `pulse --enable kimiCode` printed "Kimi
/// Code on — 2 on the rail" and the very next command read a file that still
/// said one. It was in a store that died with the process, and the same defect
/// was already in `--set-key`, which enables the provider whose key it stored.
@Suite("Provider commands", .serialized)
struct ProviderCommandTests {
    /// **A settings file of its own**, which is the only way a test of a
    /// settings command means anything.
    ///
    /// `PulseDefaults.shared` is what everything reads and writes through, so
    /// pointing it at a throwaway domain makes these hermetic — and the two
    /// earlier versions were not: one wrote to the reader's real settings, and
    /// the next passed alone and failed in the suite because another test had
    /// written last.
    private func inOwnDefaults(_ body: () throws -> Void) rethrows {
        let previous = PulseDefaults.shared
        let name = "pulse-tests-\(UUID().uuidString)"
        let own = UserDefaults(suiteName: name) ?? .standard
        own.removePersistentDomain(forName: name)
        PulseDefaults.shared = own
        defer {
            own.removePersistentDomain(forName: name)
            PulseDefaults.shared = previous
        }
        try body()
    }

    /// **The write survives being read back by a fresh `AppSettings`**, which is
    /// what the command is for.
    ///
    /// The *disk* half is checked by the command itself rather than here, and
    /// the reason is worth stating: `PulseDefaults.shared` is a process-wide
    /// singleton whose file is decided the first time anything touches it, so a
    /// test process that has already read the machine's settings cannot be
    /// redirected to a temporary one. `pulse --enable kimiCode` followed by
    /// reading `~/.config/Pulse.plist` is what proved the flush — and it failed
    /// before `PulseCLI.run()` synchronized, which is how the defect was found.
    @Test("Enabling a provider is visible to a fresh read")
    func enablingRoundTrips() throws {
        try inOwnDefaults {
            #expect(ProviderCommand.set(name: "kimiCode", enabled: true) == 0)
            let accounts = AppSettings.restored().shownAccounts.map(\.id)
            #expect(accounts.contains("kimiCode"), "the rail says \(accounts)")
        }
    }

    /// **Two providers first, because the last one cannot be removed.**
    /// `AppSettings.enabledAccounts` refuses to become empty — its `didSet`
    /// restores the old value — and it is right to: a rail with nothing on it is
    /// a state a reader reaches by never choosing, not by deleting the last
    /// thing they chose. So disabling has to be tested with something left over.
    @Test("Disabling takes it off again")
    func disablingRoundTrips() throws {
        try inOwnDefaults {
            #expect(ProviderCommand.set(name: "kimicode", enabled: true) == 0)
            #expect(ProviderCommand.set(name: "cursor", enabled: true) == 0)
            #expect(ProviderCommand.set(name: "kimiCode", enabled: false) == 0)
            let accounts = AppSettings.restored().shownAccounts.map(\.id)
            #expect(!accounts.contains("kimiCode"), "the rail says \(accounts)")
            #expect(accounts.contains("cursor"), "the rail says \(accounts)")
        }
    }

    /// A name that is not a provider is refused rather than silently switching
    /// nothing on and reporting success.
    @Test("An unknown provider name is refused")
    func unknownProvider() throws {
        try inOwnDefaults {
            #expect(ProviderCommand.set(name: "notAProvider", enabled: true) == 2)
        }
    }

    /// The display name works as well as the raw value, because "MiniMax CN" is
    /// what the settings file's reader sees in the list.
    @Test("A provider can be named by its display name")
    func displayNameWorks() throws {
        try inOwnDefaults {
            #expect(ProviderCommand.set(name: "Kimi Code", enabled: true) == 0)
            #expect(AppSettings.restored().shownAccounts.map(\.id).contains("kimiCode"))
        }
    }

    /// The list says what is on the rail and what is not — the question
    /// somebody running `--enable` is really asking is *why is that ring empty?*
    @Test("The list names every provider and its state")
    func listing() {
        try? inOwnDefaults {
            let settings = AppSettings.restored()
            settings.setEnabled(true, for: AccountKey(.kimiCode))
            let listed = ProviderCommand.list()
            for provider in Provider.allCases {
                #expect(listed.contains(provider.rawValue), "\(provider.rawValue) is missing")
            }
            #expect(listed.contains("● kimiCode"), "kimiCode is not marked as on")
            #expect(listed.contains("○ cursor"), "cursor is not marked as off")
        }
    }


}
