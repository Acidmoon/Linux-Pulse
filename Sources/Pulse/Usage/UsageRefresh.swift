import Foundation

/// `Pulse --refresh`: ask every enabled provider once, then exit.
///
/// `--json` prints the cache and **never fetches**, deliberately: it is meant to
/// be run every couple of seconds by a status line, and a command that opened
/// connections and touched credentials at that rate would be a worse citizen
/// than no command at all. That leaves a headless install with nothing able to
/// fill the cache — which is what this is. Between them they are the whole
/// non-GUI surface: `pulse --refresh` puts figures in, `pulse --json` reads
/// them out.
///
/// **It behaves like a launch rather than like a status-line poll.** The
/// enabled set is resolved through `AppSettings.restored()`, which stamps
/// `hasRun` and the offered list on its way through — the same thing the app
/// does at startup, and the reason `--json` uses `storedRail()` instead. So on
/// an installation that has never run the app this finds nothing switched on
/// and says so, rather than guessing at what would be.
///
/// It prints to **stderr** and leaves stdout alone, so
/// `pulse --refresh && pulse --json | jq` is not two documents interleaved.
@MainActor
enum UsageRefresh {
    /// `nonisolated` because the entry point matches it before it has any
    /// business being on the main actor — and it is a constant, so there is
    /// nothing to protect.
    nonisolated static let modeArgument = "--refresh"

    /// Bounds the whole pass, not one request: everything in a pass carries its
    /// own timeout already and they run side by side. `UsageStore.passCeiling`
    /// is 180s for the same reason — past that a pass is not slow, it is lost.
    static let deadline: Duration = .seconds(180)

    /// Runs the pass. Returns the process's exit code.
    ///
    /// 0 when the rail settled, 1 when there was nothing to ask or the deadline
    /// passed. Individual providers failing is **not** a non-zero exit: that is
    /// an ordinary answer, it is recorded per account in the cache, and `--json`
    /// is where it belongs.
    static func run() async -> Int32 {
        let settings = AppSettings.restored()
        let accounts = settings.shownAccounts

        guard !accounts.isEmpty else {
            note("""
            Pulse: nothing is switched on, so there is nothing to ask.

            Enable a provider in the app first — this command reports what is
            already configured rather than choosing for you.
            """)
            return 1
        }

        note("Pulse: asking \(accounts.count) \(accounts.count == 1 ? "account" : "accounts")…")

        let started = ContinuousClock.now
        // No timer: this runs one pass and exits, and arming the next one on a
        // run loop whose thread is on its way out is an error Foundation logs.
        let store = UsageStore(settings: settings, schedulesNextPass: false)
        // Reads `keys.dat` for the providers that keep their own credential.
        // Without it every pasted key reports as missing.
        store.loadAPIKeys()
        store.refresh()
        let settled = await store.idle(within: deadline)
        store.stop()
        let elapsed = started.duration(to: .now)

        report(usage: accounts.map { ($0, store.usage(for: $0)) }, elapsed: elapsed)

        guard settled else {
            note("""
            Pulse: gave up after \(Self.seconds(deadline)). The cache holds what \
            arrived; `pulse --json` will print it.
            """)
            return 1
        }
        return 0
    }

    // MARK: - Output

    /// One line per account, in rail order.
    ///
    /// The same two things `--json` reports, in a shape meant to be read by a
    /// person running the command by hand: the display percentage, which is the
    /// figure the ring would show, or the reason there is none. Nothing is
    /// invented for an account that has no reading — an unavailable one says
    /// which kind of unavailable, and the token is the one `--json` uses so the
    /// two cannot disagree about what happened.
    private static func report(
        usage: [(AccountKey, ProviderUsage)],
        elapsed: Duration
    ) {
        let width = usage.map(\.0.id.count).max() ?? 0
        for (account, reading) in usage {
            let name = account.id.padding(toLength: width, withPad: " ", startingAt: 0)
            note("  \(name)  \(summary(of: reading))")
        }

        let read = usage.filter { $0.1.observedAt != nil }.count
        note("Pulse: \(read) of \(usage.count) answered in \(Self.seconds(elapsed)).")
    }

    private static func summary(of reading: ProviderUsage) -> String {
        guard case .unavailable(let reason) = reading.state else {
            // `headlineWindow` is the same choice the ring makes, so a figure
            // printed here and a figure drawn there are the same figure.
            guard let window = reading.headlineWindow() else {
                // Reachable: a provider can answer with nothing in it, and
                // saying so is better than printing 0%.
                return "answered, but reported no window"
            }
            return "\(window.percentText)\(window.isExhausted ? "  (spent)" : "")"
        }
        return "unavailable: \(reason.rawValue)"
    }

    private static func seconds(_ duration: Duration) -> String {
        let parts = duration.components
        return String(format: "%.1fs", Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
    }

    /// Diagnostics go to stderr so that stdout stays whatever the caller asked
    /// for. `--json` writes a JSON document there; this command must not add to
    /// it.
    private static func note(_ text: String) {
        FileHandle.standardError.write(Data("\(text)\n".utf8))
    }
}
