import Foundation
import Testing

@testable import Pulse

/// `pulse --refresh`'s waiting, which is the part of it that can be tested
/// without a network and without the developer's own settings.
///
/// `UsageRefresh.run()` itself is deliberately not tested here. It resolves the
/// enabled set through `AppSettings.restored()`, which reads the real
/// `UserDefaults` — so a test of it would fetch whatever the machine running
/// the suite happens to have switched on, which is the opposite of a test. What
/// is covered instead is the one thing the command added to `UsageStore`: a way
/// to be told that a pass has finished.
@Suite("Usage store idle")
@MainActor
struct UsageStoreIdleTests {
    /// A store with `deepSeek` switched on and no key entered.
    ///
    /// Chosen because it fails **without a network and without reading
    /// anything**: a provider that keeps its own credential and has none
    /// reports `.apiKeyMissing` locally, so a pass over it completes in
    /// milliseconds. That is what makes the "finished" path reachable in a test.
    ///
    /// **Not `kimiCode`, which this used to use.** Kimi Code borrows a login
    /// from another tool when no key is pasted, so a test that enabled it was
    /// reading whichever credential stores the machine running the suite
    /// happens to have — and would have made a real request to Kimi if one of
    /// them were current. A test that configures itself from the developer's
    /// home directory is not testing anything; it went unnoticed until the
    /// borrowing was added, and this comment is here so it is not added back.
    private func store(provider: Provider) -> UsageStore {
        let settings = AppSettings(
            enabledAccounts: [provider.rawValue],
            providerOrder: [provider.rawValue]
        )
        return UsageStore(settings: settings, schedulesNextPass: false)
    }

    @Test("A pass that cannot start settles immediately")
    func nothingEnabled() async {
        let store = UsageStore(
            settings: AppSettings(enabledAccounts: [], providerOrder: []),
            schedulesNextPass: false
        )
        let started = ContinuousClock.now

        // `refresh()` returns without doing anything when nothing is selected,
        // which leaves the store already settled — so a waiter must not be
        // parked on a pass that is never going to run and never going to end.
        store.refresh()
        let settled = await store.idle(within: .seconds(10))

        #expect(settled)
        #expect(started.duration(to: .now) < .seconds(2), "waited on a pass that never started")
    }

    /// The point of the whole thing: the waiter is released by the pass
    /// **ending**, not by the clock.
    ///
    /// If `settle()` were missing, this would still return `true` after the
    /// deadline — so the deadline is set far out and the elapsed time is what
    /// is asserted. A regression here would otherwise look like a slow machine.
    @Test("The end of a pass releases the waiter, not the deadline")
    func passEndReleasesTheWaiter() async {
        let store = self.store(provider: .deepSeek)
        let started = ContinuousClock.now

        store.refresh()
        let settled = await store.idle(within: .seconds(60))
        let elapsed = started.duration(to: .now)

        #expect(settled)
        #expect(elapsed < .seconds(20), "released by the deadline, not by the pass ending")
        #expect(!store.isRefreshing)
    }

    /// A provider that keeps no credential is asked anyway — this is only here
    /// to show that the pass above really fetched rather than short-circuiting
    /// on the account set.
    @Test("The pass leaves a reading behind for the account it asked")
    func passLeavesAReading() async {
        let store = self.store(provider: .deepSeek)
        store.refresh()
        _ = await store.idle(within: .seconds(60))

        let reading = store.usage(for: AccountKey(.deepSeek))
        #expect(reading.observedAt == nil, "a provider with no key reported a reading")
        guard case .unavailable(let reason) = reading.state else {
            Issue.record("expected an unavailable reading, got \(reading.state)")
            return
        }
        #expect(reason == .apiKeyMissing)
    }
}

/// `--refresh` and `--json` are the two halves of the headless surface, and the
/// thing that makes them a pair rather than a coincidence is that `--json`
/// prints exactly what `--refresh` banked. Pinned here so a change to one that
/// forgets the other fails rather than silently degrades.
@Suite("Headless surface")
struct HeadlessSurfaceTests {
    @Test("Both modes are named, and neither is the other")
    func modeArguments() {
        #expect(UsageRefresh.modeArgument == "--refresh")
        #expect(UsageReport.modeArgument == "--json")
        #expect(UsageRefresh.modeArgument != UsageReport.modeArgument)
    }
}
