import Foundation
import Testing

@testable import Pulse

/// **The ring and `pulse --json` say the same number.**
///
/// It is one of the acceptance criteria, and it is the kind of thing that can
/// quietly stop being true: the panel picks a window to draw on the rail and
/// `--json` picks one to report, and the two are separate code paths that agree
/// today because they call the same function. Nothing about a compile error
/// would say so if one of them started choosing for itself.
///
/// So this drives both over the same readings — several limits, a pinned one, a
/// spent one, and one with no reading at all — and compares the figure that
/// would be drawn with the figure that would be printed.
@Suite("The ring and the report agree")
struct RingMatchesReportTests {
    private func window(_ id: String, used: Double, scope: String? = nil,
                        seconds: Int = 5 * 3600) -> UsageWindow {
        // The initializer upstream's own tests use. `name` is derived from the
        // id and the kind, so there is nothing to pass.
        UsageWindow(id: id, kind: .fiveHour, scope: scope, usedFraction: used,
                    windowSeconds: seconds, resetsAt: nil, reportsLength: true)
    }

    private func reading(_ provider: Provider, windows: [UsageWindow],
                         state: ProviderUsage.State = .live) -> ProviderUsage {
        ProviderUsage(account: AccountKey(provider), windows: windows,
                      observedAt: Date(), state: state, plan: nil, creditBalance: nil)
    }

    /// What `--json` prints for an account, in the shape the model uses.
    private struct Printed: Decodable {
        struct Headline: Decodable { let usedPercent: Int; let windowId: String }
        let headline: Headline?
    }

    private func printed(_ readings: [String: ProviderUsage],
                         accounts: [AccountKey],
                         pinned: [String: String] = [:]) -> [String: Printed] {
        let rail = AppSettings.StoredRail(accounts: accounts, labels: [:],
                                          pinnedWindows: pinned)
        let data = UsageReport.encode(rail: rail, readings: readings, generatedAt: Date())
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["accounts"] as? [[String: Any]] else { return [:] }
        var out: [String: Printed] = [:]
        for entry in list {
            guard let id = entry["id"] as? String,
                  let encoded = try? JSONSerialization.data(withJSONObject: entry),
                  let decoded = try? JSONDecoder().decode(Printed.self, from: encoded) else { continue }
            out[id] = decoded
        }
        return out
    }

    /// A ring draws the *fullest* limit, which is what the report calls the
    /// headline — with three limits where the middle one is fullest, so a path
    /// that took the first or the last would disagree.
    @Test("The ring's limit is the report's headline")
    @MainActor
    func fullestWindowAgrees() throws {
        let usage = reading(.claudeCode, windows: [
            window("five_hour", used: 0.12),
            window("week", used: 0.47, scope: "opus", seconds: 7 * 86_400),
            window("month", used: 0.31, seconds: 30 * 86_400),
        ])
        let account = AccountKey(.claudeCode)
        // `entry(for:usage:)` takes the reading as an argument, so no store has
        // to be faked — which matters because `UsageStore` is `final` and
        // reaches for the cache and the network.
        let entry = RailEntryBuilder.entry(
            for: RailSlot(account), usage: usage,
            settings: AppSettings(enabledAccounts: [account.id], providerOrder: [account.id]),
            store: store(account: account),
            minute: Date())
        let report = printed([account.id: usage], accounts: [account])
            .compactMapValues { $0 }.first?.value

        #expect(entry.headline?.id == report?.headline?.windowId)
        #expect(entry.headline?.percentValue() == report?.headline?.usedPercent)
        #expect(entry.headline?.percentValue() == 47)
    }

    /// **A pinned window is the one exception, and it is deliberate** — the
    /// reader asked for that ring to show that limit. Both sides read the pin,
    /// so both move together; this is what says so, because a pin honoured on
    /// one side only is exactly the bug that would make them disagree.
    @Test("A pinned limit is what both of them show")
    @MainActor
    func pinnnedWindowAgrees() throws {
        let usage = reading(.codex, windows: [
            window("five_hour", used: 0.12),
            window("week", used: 0.47, seconds: 7 * 86_400),
        ])
        let account = AccountKey(.codex)
        let settings = AppSettings(enabledAccounts: [account.id], providerOrder: [account.id])
        settings.setPinnedWindow("five_hour", for: account)

        let entry = RailEntryBuilder.entry(for: RailSlot(account), usage: usage,
                                           settings: settings, store: store(account: account),
                                           minute: Date())
        let report = printed([account.id: usage], accounts: [account],
                             pinned: [account.id: "five_hour"])
            .compactMapValues { $0 }.first?.value

        #expect(entry.headline?.id == "five_hour")
        #expect(entry.headline?.percentValue() == report?.headline?.usedPercent)
        #expect(entry.headline?.percentValue() == 12)
    }

    /// Counting down shows the same limit from the other end, and the report
    /// follows the setting too — so a rail set to "remaining" and a `--json`
    /// run are still the same number.
    @Test("Counting down agrees with the report as well")
    @MainActor
    func remainingAgrees() throws {
        let usage = reading(.kimiCode, windows: [window("limit_month_total", used: 0.1,
                                                        seconds: 30 * 86_400)])
        let account = AccountKey(.kimiCode)
        let settings = AppSettings(enabledAccounts: [account.id], providerOrder: [account.id])
        settings.showsRemaining = true

        let entry = RailEntryBuilder.entry(for: RailSlot(account), usage: usage,
                                           settings: settings, store: store(account: account),
                                           minute: Date())
        let report = printed([account.id: usage], accounts: [account])
            .compactMapValues { $0 }.first?.value

        // The report's headline is always the used figure — it is the reading,
        // and `showsRemaining` only changes how the panel draws it.
        #expect(entry.headline?.percentValue() == report?.headline?.usedPercent)
        #expect(entry.headline?.percentText(remaining: true) == "90%")
    }

    /// No reading, no number — and the report says the same nothing rather than
    /// a zero, which is the claim the em dash exists to avoid making.
    @Test("An unread account has no headline on either side")
    @MainActor
    func unavailableAgrees() throws {
        let account = AccountKey(.cursor)
        let usage = ProviderUsage(account: account, windows: [], observedAt: nil,
                                  state: .unavailable(.signInRequired), plan: nil,
                                  creditBalance: nil)
        let entry = RailEntryBuilder.entry(
            for: RailSlot(account), usage: usage,
            settings: AppSettings(enabledAccounts: [account.id], providerOrder: [account.id]),
            store: store(account: account), minute: Date())
        #expect(entry.headline == nil)
        let report = printed([account.id: usage], accounts: [account])
            .compactMapValues { $0 }.first?.value
        #expect(report?.headline == nil)
    }
}

private extension RingMatchesReportTests {
    /// A store that is never started, so it fetches nothing and holds nothing.
    ///
    /// `UsageStore` is `final`, so it cannot be subclassed to answer with a
    /// reading — and it does not need to be: `RailEntryBuilder.entry` takes the
    /// reading as an argument, and what it asks the store for is only whether a
    /// CLI is running and whether a pass is in flight, which an idle store
    /// answers correctly.
    @MainActor
    func store(account: AccountKey) -> UsageStore {
        UsageStore(settings: AppSettings(enabledAccounts: [account.id],
                                          providerOrder: [account.id]),
                   schedulesNextPass: false)
    }
}
