import Foundation
import Testing

@testable import Pulse

/// Kimi Code's reply parsing, driven by a **captured** reply.
///
/// The fixture below is the shape a real account returned on 2026-09-23, with
/// the account's own identifiers removed and nothing else changed — the ratios,
/// the reset times, the window names and the extra keys are as they arrived.
///
/// **That is the point of this file.** The provider read `usage`, singular, and
/// the endpoint had moved to `usages`, plural, keyed by name; nothing noticed,
/// because every test up to then had been written from the same understanding
/// of the reply as the code it was checking. The monthly limits were silently
/// dropped and the ring showed 2% where the fullest window was 10%. A fixture
/// captured from the wire is the only thing that can catch that.
@Suite("Kimi usage parsing")
struct KimiUsageTests {
    /// What the endpoint actually sent, minus the account's identifiers.
    private static let captured = Data(#"""
    {
      "limits": [
        {
          "window": { "duration": 300, "timeUnit": "TIME_UNIT_MINUTE" },
          "detail": {
            "limit": "100",
            "used": "2",
            "remaining": "98",
            "resetTime": "2026-09-22T17:34:13.259685Z"
          }
        }
      ],
      "booster_wallet": { "status": "STATUS_DISABLED", "allowTopup": true },
      "usages": {
        "limit_5h":          { "used_ratio": 0.019267, "reset_time": "2026-09-22T17:34:12Z" },
        "limit_month_total": { "used_ratio": 0.0998,   "reset_time": "2026-10-21T00:00:00Z" },
        "limit_month_code":  { "used_ratio": 0.0968,   "reset_time": "2026-10-21T00:00:00Z" }
      }
    }
    """#.utf8)

    private func windows(_ json: Data) throws -> [UsageWindow] {
        let reply = try JSONDecoder().decode(KimiCodeUsageService.Reply.self, from: json)
        return KimiCodeUsageService.windows(from: reply)
    }

    /// **The regression.** Three windows, not one.
    @Test("A captured reply yields every window it carries")
    func parsesEveryWindow() throws {
        let found = try windows(Self.captured)
        #expect(found.count == 3, "got \(found.map(\.id))")
        #expect(found.map(\.id).sorted() == ["limit.0.18000", "limit_month_code", "limit_month_total"])
    }

    /// `limit_5h` states the window `limits[]` already stated — the same
    /// allowance, once as counts and once as a ratio — so it must not become a
    /// second row for the same five hours.
    @Test("The five-hour window is not reported twice")
    func deduplicatesTheTimedWindow() throws {
        let found = try windows(Self.captured)
        let fiveHour = found.filter { $0.windowSeconds == 5 * 3_600 }
        #expect(fiveHour.count == 1, "the five-hour limit was drawn \(fiveHour.count) times")
        // And it is the one from `limits[]`, which states its length and its
        // counts, rather than the ratio-shaped duplicate.
        #expect(fiveHour.first?.reportsLength == true)
        #expect(fiveHour.first?.id == "limit.0.18000")
    }

    /// Two monthly windows share one sort key and must not collapse into one
    /// another — the bug the first version of this deduplication had.
    @Test("Two windows of the same length both survive")
    func sameLengthWindowsAreKept() throws {
        let found = try windows(Self.captured)
        let monthly = found.filter { $0.kind == .monthly }
        #expect(monthly.count == 2, "got \(monthly.map(\.id))")
        #expect(Set(monthly.map(\.windowSeconds)) == [30 * 86_400])
    }

    /// The figure the ring shows: the fullest window, which is a monthly one
    /// here and was not being seen at all.
    ///
    /// Asked through `ProviderUsage.headlineWindow`, which is what the ring and
    /// `--json` both call, rather than re-implementing "fullest" here — a test
    /// that picked the window its own way could agree with itself and disagree
    /// with the panel.
    @Test("The ring's window is the fullest one, not the five-hour limit")
    func headlineIsTheFullest() throws {
        let found = try windows(Self.captured)
        let headline = ProviderUsage(
            account: AccountKey(.kimiCode),
            windows: found,
            observedAt: Date(),
            state: .live,
            plan: nil,
            creditBalance: nil
        ).headlineWindow()

        #expect(headline?.id == "limit_month_total")
        #expect(headline?.percentValue() == 10)
    }

    /// The reply states no length for the ratio-shaped windows, so the number
    /// that sorts them must never be displayed as one.
    @Test("A ratio window's length is a sort key and says so")
    func ratioWindowsDoNotReportALength() throws {
        let found = try windows(Self.captured)
        for window in found where window.id.hasPrefix("limit_month") {
            #expect(!window.reportsLength, "\(window.id) claims to report its length")
        }
        // While the one that does state a length still reports it.
        #expect(found.first { $0.id == "limit.0.18000" }?.reportsLength == true)
    }

    @Test("A ratio is already a fraction, so it is not an estimate")
    func ratiosAreNotEstimates() throws {
        let found = try windows(Self.captured)
        let monthly = try #require(found.first { $0.id == "limit_month_total" })
        #expect(monthly.usedFraction == 0.0998)
        #expect(monthly.estimate == nil, "the service computed this; nothing was inferred")
        #expect(monthly.resetsAt != nil)
    }

    /// A window named something this does not know is dropped rather than
    /// guessed at — the same rule the windows' own `timeUnit` follows.
    @Test("An unrecognised window name is dropped")
    func unknownNamesAreDropped() throws {
        let json = Data(#"""
        { "usages": { "limit_week_rolling": { "used_ratio": 0.5, "reset_time": "2026-09-30T00:00:00Z" } } }
        """#.utf8)
        #expect(try windows(json).isEmpty)
    }

    /// The singular field is what the endpoint was documented to send. Keeping
    /// it means a plan that still receives it does not regress.
    @Test("The older singular reply still parses")
    func legacyShapeStillParses() throws {
        let json = Data(#"""
        {
          "user": { "membership": { "level": "LEVEL_INTERMEDIATE" } },
          "usage": { "limit": "100", "remaining": "74", "resetTime": "2026-02-11T17:32:50.757941Z" }
        }
        """#.utf8)
        let found = try windows(json)
        #expect(found.count == 1)
        #expect(found.first?.kind == .weekly)
        #expect(found.first?.reportsLength == false)
        #expect(abs((found.first?.usedFraction ?? 0) - 0.26) < 0.0001)
    }

    /// `booster_wallet` arrived with the same reply and is not a limit: it is a
    /// top-up balance, disabled on this account, priced in CNY. Nothing may
    /// turn it into a percentage, and nothing does — it is simply not read.
    /// Pinned so that stays a decision rather than becoming an omission.
    @Test("The booster wallet is not mistaken for a limit")
    func boosterWalletIsNotALimit() throws {
        let found = try windows(Self.captured)
        #expect(found.allSatisfy { $0.id != "booster_wallet" })
        #expect(found.allSatisfy { $0.scope != "booster_wallet" })
    }

    /// A reply with no windows at all is what tells `fetch` to report
    /// `.noLimitsReported` rather than an empty reading.
    @Test("An empty reply yields no windows")
    func emptyReply() throws {
        #expect(try windows(Data("{}".utf8)).isEmpty)
    }
}
