import Foundation
import Testing

@testable import Pulse

/// Which stored Kimi Code login Pulse picks up, and what it says when there
/// isn't a usable one.
///
/// Driven against a temporary home rather than the real one, because the real
/// one is whichever machine is running the suite — and on the machine this was
/// written on it holds two different tokens, both expired, one of which belongs
/// to a tool that is not Pulse.
@Suite("Kimi stored login")
struct KimiStoredLoginTests {
    /// A home with the stores written into it.
    private struct Home {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appending(path: "pulse-kimi-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        /// Pi's store: `kimi-coding.access`, and `expires` in **milliseconds**.
        func writePi(access: String, expires: Date?) throws {
            var entry: [String: Any] = ["type": "oauth", "access": access, "refresh": "unused"]
            if let expires { entry["expires"] = Int(expires.timeIntervalSince1970 * 1000) }
            try write(["kimi-coding": entry], to: ".pi/agent/auth.json")
        }

        /// The CLI's store: `access_token`, and `expires_at` in **seconds**.
        func writeCLI(access: String, expiresAt: Date?) throws {
            var entry: [String: Any] = ["token_type": "Bearer", "access_token": access]
            if let expiresAt { entry["expires_at"] = Int(expiresAt.timeIntervalSince1970) }
            try write(entry, to: ".kimi-code/credentials/kimi-code.json")
        }

        private func write(_ object: [String: Any], to path: String) throws {
            let file = root.appending(path: path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONSerialization.data(withJSONObject: object).write(to: file)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("A usable login in either store is found")
    func findsEitherStore() throws {
        let pi = try Home(); defer { pi.remove() }
        try pi.writePi(access: "pi-token", expires: Self.now.addingTimeInterval(3600))
        #expect(KimiCodeUsageService.storedLogin(now: Self.now, home: pi.root)
            == .token("pi-token"))

        let cli = try Home(); defer { cli.remove() }
        try cli.writeCLI(access: "cli-token", expiresAt: Self.now.addingTimeInterval(3600))
        #expect(KimiCodeUsageService.storedLogin(now: Self.now, home: cli.root)
            == .token("cli-token"))
    }

    /// **The reason the scale is per source.** Pi's `expires` is milliseconds
    /// and the CLI's `expires_at` is seconds, and both were measured on one
    /// machine. Reading the millisecond value as seconds puts the expiry in the
    /// year 58691, so an expired token would be handed to the endpoint for ever
    /// and the answer would be a 401 rather than "your login ran out".
    @Test("A millisecond expiry is read as milliseconds")
    func millisecondExpiryIsNotSeconds() throws {
        let home = try Home(); defer { home.remove() }
        // Expired an hour ago, in Pi's scale.
        try home.writePi(access: "stale", expires: Self.now.addingTimeInterval(-3600))
        #expect(KimiCodeUsageService.storedLogin(now: Self.now, home: home.root) == .expired)
    }

    @Test("A second-scale expiry is read as seconds")
    func secondExpiryIsNotMilliseconds() throws {
        let home = try Home(); defer { home.remove() }
        try home.writeCLI(access: "fresh", expiresAt: Self.now.addingTimeInterval(-3600))
        #expect(KimiCodeUsageService.storedLogin(now: Self.now, home: home.root) == .expired)
    }

    /// Nothing refreshes anything, so an expired token is reported as expired
    /// and left where it is. Spending a refresh token would rotate it and sign
    /// the tool that owns it out — which, for the machine this was written on,
    /// is the agent running the test.
    @Test("Both expired is reported as expired, not as missing or refused")
    func bothExpired() throws {
        let home = try Home(); defer { home.remove() }
        try home.writePi(access: "stale-pi", expires: Self.now.addingTimeInterval(-60))
        try home.writeCLI(access: "stale-cli", expiresAt: Self.now.addingTimeInterval(-60))

        #expect(KimiCodeUsageService.storedLogin(now: Self.now, home: home.root) == .expired)
    }

    @Test("No store at all is reported as missing")
    func nonePresent() throws {
        let home = try Home(); defer { home.remove() }
        #expect(KimiCodeUsageService.storedLogin(now: Self.now, home: home.root) == .missing)
    }

    /// The two stores hold different tokens — measured, 648 characters against
    /// 677 — so which one is current is not something to hardcode. The freshest
    /// usable one wins.
    @Test("The freshest usable login wins")
    func freshestWins() throws {
        let home = try Home(); defer { home.remove() }
        try home.writePi(access: "older", expires: Self.now.addingTimeInterval(600))
        try home.writeCLI(access: "newer", expiresAt: Self.now.addingTimeInterval(7200))

        #expect(KimiCodeUsageService.storedLogin(now: Self.now, home: home.root)
            == .token("newer"))
    }

    /// And a stale one does not win merely by being in the store that is checked
    /// first: with Pi's token expired and the CLI's good, the CLI's is used.
    @Test("A stale login does not shadow a usable one")
    func staleDoesNotShadow() throws {
        let home = try Home(); defer { home.remove() }
        try home.writePi(access: "stale", expires: Self.now.addingTimeInterval(-60))
        try home.writeCLI(access: "usable", expiresAt: Self.now.addingTimeInterval(60))

        #expect(KimiCodeUsageService.storedLogin(now: Self.now, home: home.root)
            == .token("usable"))
    }

    /// A store that does not state an expiry cannot be shown to have expired,
    /// and the field belongs to the other tool — so it is used and the endpoint
    /// gets to answer.
    @Test("A login with no stated expiry is used")
    func noExpiryIsUsable() throws {
        let home = try Home(); defer { home.remove() }
        try home.writeCLI(access: "undated", expiresAt: nil)
        #expect(KimiCodeUsageService.storedLogin(now: Self.now, home: home.root)
            == .token("undated"))
    }

    @Test("A store that exists but names no token is ignored")
    func noTokenIsNotALogin() throws {
        let home = try Home(); defer { home.remove() }
        try home.writePi(access: "", expires: Self.now.addingTimeInterval(3600))
        #expect(KimiCodeUsageService.storedLogin(now: Self.now, home: home.root) == .missing)
    }
}
