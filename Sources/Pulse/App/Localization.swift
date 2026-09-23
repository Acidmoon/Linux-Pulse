import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif

/// The interface language: whatever the system is set to, or one the user has
/// picked explicitly.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english
    case chineseSimplified
    case chineseTraditional
    case japanese
    case korean

    var id: String { rawValue }

    /// The locale to format dates, times and money in.
    ///
    /// Strings and numbers have to agree: picking English and then being told
    /// a credit expires "in 22天8小时" is the sort of half-translated seam
    /// that makes an app feel unfinished.
    var locale: Locale {
        switch self {
        case .system: .autoupdatingCurrent
        case .english: Locale(identifier: "en_US")
        case .chineseSimplified: Locale(identifier: "zh_Hans")
        case .chineseTraditional: Locale(identifier: "zh_Hant")
        case .japanese: Locale(identifier: "ja_JP")
        case .korean: Locale(identifier: "ko_KR")
        }
    }

    /// Name of the `.lproj` folder to read strings from, or `nil` to let the
    /// system choose. Lowercased because SwiftPM lowercases these folder
    /// names when it builds the resource bundle.
    var bundleName: String? {
        switch self {
        case .system: nil
        case .english: "en"
        case .chineseSimplified: "zh-hans"
        case .chineseTraditional: "zh-hant"
        case .japanese: "ja"
        case .korean: "ko"
        }
    }

    /// Languages are conventionally listed in their own language, so only the
    /// "follow the system" option gets translated.
    var title: String {
        switch self {
        case .system: .localized("System")
        case .english: "English"
        case .chineseSimplified: "简体中文"
        case .chineseTraditional: "繁體中文"
        case .japanese: "日本語"
        case .korean: "한국어"
        }
    }
}

/// Where `String.localized(_:)` reads from.
///
/// Normally the module's own bundle, which resolves against the system
/// language. Picking a language in settings swaps in that language's `.lproj`
/// sub-bundle instead, so the change takes effect immediately rather than on
/// the next launch.
enum LocalizationSource {
    private static let lock = NSLock()
    // Written only from the main thread when the setting changes, read from
    // anywhere a string is looked up; the lock covers the crossing.
    nonisolated(unsafe) private static var override: Bundle?
    nonisolated(unsafe) private static var chosen: AppLanguage = .system

    static var bundle: Bundle {
        lock.withLock { override } ?? .module
    }

    /// The locale that goes with the language the strings are coming from.
    static var locale: Locale {
        lock.withLock { chosen }.locale
    }

    static func use(_ language: AppLanguage) {
        lock.withLock {
            chosen = language
            override = language.bundleName.flatMap(loadTable)
        }
    }

    /// Finds a language's `.lproj` bundle.
    ///
    /// Resolved against the names the bundle itself reports rather than a
    /// hardcoded folder name: SwiftPM lowercases `zh-Hans.lproj` on the way
    /// into the built bundle, and there is no guarantee about the casing it
    /// will use, so anything that assumes one spelling can come up empty —
    /// silently, leaving the app in the system language with no clue why.
    private static func loadTable(named name: String) -> Bundle? {
        let match = Bundle.module.localizations.first {
            $0.caseInsensitiveCompare(name) == .orderedSame
        } ?? name

        if let path = Bundle.module.path(forResource: match, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }

        // Fall back to building the path by hand, in case the resource lookup
        // above doesn't consider `.lproj` directories.
        return Bundle.module.resourceURL
            .map { $0.appendingPathComponent("\(match).lproj") }
            .flatMap { Bundle(url: $0) }
    }
}

extension LocalizationSource {
    /// The myriad units for a language that counts by 10⁴ and 10⁸ instead of
    /// by thousands, or nil where thousands are what a reader expects.
    ///
    /// None of these languages groups in thousands, so "419M" is something the
    /// reader has to convert in their head before it means anything. The unit
    /// characters are written here rather than in the strings file on purpose:
    /// they belong to the numeral system, not to the copy, and a translator
    /// being offered them as text to change would be a mistake waiting to
    /// happen.
    ///
    /// **They are not the same four characters in all four languages**, which
    /// is why this returns them rather than a `Bool`: 10⁸ is 亿 in simplified
    /// Chinese, 億 in traditional Chinese and in Japanese, and 억 in Korean.
    /// Printing 亿 to a Taiwanese or Japanese reader is the same class of
    /// mistake as leaving the number in millions.
    static var myriadUnits: (tenThousand: String, hundredMillion: String)? {
        myriadUnits(for: locale)
    }

    /// The same rule against a supplied locale. Not `private` so `MyriadUnitsTests`
    /// can ask it about a language the app is not currently set to; do not
    /// tidy it back.
    static func myriadUnits(for locale: Locale) -> (tenThousand: String, hundredMillion: String)? {
        let language = locale.language
        switch language.languageCode?.identifier {
        case "zh":
            // `script` is filled in for the identifiers `AppLanguage` builds
            // and for a maximised system locale; the regions are the fallback
            // for a plain "zh_TW" that never went through that.
            let traditional = language.script?.identifier == "Hant"
                || ["TW", "HK", "MO"].contains(language.region?.identifier ?? "")
            return traditional ? ("萬", "億") : ("万", "亿")
        case "ja": return ("万", "億")
        case "ko": return ("만", "억")
        default: return nil
        }
    }
}

extension String {
    /// Looks a key up in the app's current language.
    ///
    /// Always use this instead of letting SwiftUI localize implicitly.
    /// `Text("Some text")` and friends resolve against `Bundle.main`, which
    /// for a SwiftPM target is the bare executable — the `.lproj` folders
    /// live in `Bundle.module`, so implicit lookups silently fall through to
    /// the key itself and the app stays in English no matter the system
    /// language or the user's choice.
    #if canImport(Darwin)
    static func localized(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: LocalizationSource.bundle)
    }
    #else
    /// Looks a key up through the older `Bundle` API, because Linux's
    /// Foundation has neither `String.LocalizationValue` nor
    /// `String(localized:bundle:)` — both were verified by compiling them
    /// rather than assumed. Everything around them does work: `Bundle.module`,
    /// `localizations`, `path(forResource:ofType:"lproj")`, and every
    /// `Locale.Language` accessor `myriadUnits` uses.
    ///
    /// **A key that interpolates is looked up as its already-interpolated
    /// text.** `LocalizationValue` is the thing that carries a key and its
    /// arguments separately; without it the call has collapsed to one `String`
    /// before this runs, so no entry in the strings file can match and the
    /// text prints as written. Non-interpolated keys — the large majority, and
    /// every string in the `.lproj` tables — resolve normally, through the
    /// same `LocalizationSource.bundle` the Darwin path uses, so a language
    /// chosen in settings still takes effect immediately.
    ///
    /// Closing that gap is roadmap phase 3; it needs a format-string scheme of
    /// Pulse's own or a move to gettext, and it is a change to how every
    /// translated string is authored, not a portability shim.
    /// A key that is already a `String` rather than a literal.
    ///
    /// **Labelled, and that is not cosmetic.** With a bare `_` this overload and
    /// the `LocalizedKey` one are both reachable from `localized("\(x) Used")`
    /// — a string literal can be a `String` — and the compiler picks this one,
    /// which is the collapse the whole shim exists to prevent. A different label
    /// makes the choice explicit at every call site that has one to make.
    static func localized(raw key: String) -> String {
        LocalizationSource.bundle.localizedString(forKey: key, value: key, table: nil)
    }

    /// The interpolated form, through `LocalizedKey`. See that type for why the
    /// key and its arguments have to stay apart until the table has been read.
    static func localized(_ key: LocalizedKey) -> String {
        let translated = LocalizationSource.bundle.localizedString(
            forKey: key.key, value: key.key, table: nil)
        guard !key.arguments.isEmpty else { return translated }
        return String(format: translated, arguments: key.arguments)
    }
    #endif
}

#if canImport(SwiftUI)
extension Text {
    /// `Text` that resolves its key in the app's current language. See
    /// `String.localized(_:)` for why the implicit form can't be used.
    init(localized key: String.LocalizationValue) {
        self.init(String.localized(key))
    }
}
#endif

#if !canImport(Darwin)
/// `String.LocalizationValue`, which Linux's Foundation does not have.
///
/// **This is what makes a translated sentence with a number in it work.** On a
/// Mac, `String.localized("\(figure) Used")` passes a value that keeps the
/// *key* and the *arguments* apart — the key being `"%@ Used"`, which is what
/// the `.lproj` tables are indexed by. Linux's Foundation has no
/// `LocalizationValue` and no `String(localized:bundle:)`, so the same call
/// collapses to the finished sentence `"10% Used"` before anything looks it up,
/// and no entry in any table can ever match. Sixty-three call sites and
/// fifty-nine keys per language were going untranslated because of it, and the
/// gap was written down as "roadmap phase 3" until this.
///
/// **Every interpolation is `%@`.** Measured across all five `.lproj` tables
/// first: fifty-nine interpolated keys each, and every placeholder in every one
/// of them is `%@` — there is no `%lld`, no `%d`, no positional form. So an
/// argument is described as a string and handed to `String(format:)`, which is
/// both what the tables expect and the only thing that can be right when the
/// same key has to serve a percentage, a count and a currency amount.
///
/// It is `ExpressibleByStringInterpolation` rather than a function because that
/// is what lets the call sites stay as they are. `String.localized("\(x) Used")`
/// is upstream's spelling and the tables are keyed by what it produces; adding
/// an argument to sixty-three calls would have been a change to how every
/// translated string in the app is authored.
struct LocalizedKey: ExpressibleByStringInterpolation, Sendable {
    let key: String
    let arguments: [String]

    init(stringLiteral value: String) {
        self.key = value
        self.arguments = []
    }

    init(stringInterpolation: Interpolation) {
        self.key = stringInterpolation.key
        self.arguments = stringInterpolation.arguments
    }

    struct Interpolation: StringInterpolationProtocol {
        fileprivate(set) var key = ""
        fileprivate(set) var arguments: [String] = []

        init(literalCapacity: Int, interpolationCount: Int) {
            key.reserveCapacity(literalCapacity + interpolationCount * 2)
        }

        mutating func appendLiteral(_ literal: String) {
            key += literal
        }

        /// One overload, taking anything that can describe itself. A narrower
        /// set — `String`, `Int`, `Double` — would leave `URL`, `Date` or a
        /// provider's own type unresolvable at the call site, which is how a
        /// shim becomes a reason to change upstream code after all.
        mutating func appendInterpolation<T>(_ value: T) {
            key += "%@"
            arguments.append(String(describing: value))
        }
    }
}
#endif
