import Foundation
import Testing

@testable import Pulse

/// Translated sentences with numbers in them.
///
/// **The gap this closes was sixty-three call sites wide and silent.** On a Mac
/// `String.localized("\(figure) Used")` passes a value that keeps the key
/// (`"%@ Used"`) and the argument apart, and the `.lproj` tables are indexed by
/// that key. Linux's Foundation has no `LocalizationValue` and no
/// `String(localized:bundle:)`, so the same call collapsed to the finished
/// sentence — `"10% Used"` — before anything looked it up, and no entry in any
/// table could match. Every one of those strings printed in English whatever the
/// reader had chosen.
///
/// These tests go through the real tables, which is the only thing that can show
/// it: a test of `LocalizedKey` on its own would check that a `%@` was built,
/// which is not the part that was broken.
/// **Serialized, because the language is global state.** `LocalizationSource.use`
/// swaps the bundle every lookup reads from, so two of these running at once is
/// one test restoring the system language in the middle of another's sentence —
/// which is what happened: `%@ Used` resolved and the `%@ Left` on the next line
/// did not.
@Suite("Localized sentences", .serialized)
struct LocalizationTests {
    /// Runs a body with the language pinned, and puts it back afterwards so one
    /// test cannot decide what the next one reads.
    private func inLanguage(_ language: AppLanguage, _ body: () -> Void) {
        LocalizationSource.use(language)
        defer { LocalizationSource.use(.system) }
        body()
    }

    /// **The one that matters.** The figure and the word come out of the table
    /// together, in the table's own order — Simplified Chinese puts the word
    /// first, which is why composing `figure + " " + localized("Used")` would
    /// have been wrong even though it looks simpler.
    @Test("An interpolated key is translated, and its argument placed by the table")
    func interpolatedStringIsTranslated() {
        inLanguage(.chineseSimplified) {
            let figure = "10%"
            #expect(String.localized("\(figure) Used") == "已用 10%")
            #expect(String.localized("\(figure) Left") == "剩余 10%")
        }
    }

    /// A different sentence with a different argument — so this is the table
    /// being read rather than one key that happened to match.
    @Test("A second interpolated sentence resolves too")
    func anotherInterpolatedString() {
        inLanguage(.chineseSimplified) {
            let title = "Kimi Code"
            #expect(String.localized("\(title) Usage") == "Kimi Code 用量")
            #expect(String.localized("Resets \("21 Oct")") == "21 Oct 重置")
        }
    }

    /// English is a language too, and its table has the same keys. A language
    /// override that only worked for the non-Latin ones would be half a fix.
    @Test("English resolves through its own table")
    func englishResolves() {
        inLanguage(.english) {
            let figure = "10%"
            #expect(String.localized("\(figure) Used") == "10% Used")
        }
    }

    /// A key with no entry prints as written rather than as an empty string —
    /// which is what a missing translation has to do, since the alternative is a
    /// blank line where a sentence should be.
    @Test("A key that is not in the table prints as its own text")
    func missingKey() {
        inLanguage(.chineseSimplified) {
            #expect(String.localized("Nothing here is translated \("x")") == "Nothing here is translated x")
        }
    }

    /// And a plain key still works, because the overload that takes a `String`
    /// is still there for callers that already have one.
    @Test("A key with no arguments still resolves")
    func plainKey() {
        inLanguage(.chineseSimplified) {
            #expect(String.localized("Credit balance") == "额度余额")
        }
    }

    /// The key an interpolation produces, checked directly — because everything
    /// above depends on it being `%@` and not `%lld` or `%d`. Measured across
    /// all five tables before this was written: every one of the fifty-nine
    /// interpolated keys uses `%@` and nothing else.
    @Test("Every interpolation becomes %@")
    func interpolationShape() {
        let key: LocalizedKey = "\(1) of \("two") by \(2.5)"
        #expect(key.key == "%@ of %@ by %@")
        #expect(key.arguments == ["1", "two", "2.5"])
    }
}
