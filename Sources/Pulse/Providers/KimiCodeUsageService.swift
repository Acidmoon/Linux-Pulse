import Foundation
#if canImport(FoundationNetworking)
// On Linux, URLSession and friends live in this separate module. On
// Darwin it does not exist and Foundation already re-exports them, so
// the guard keeps macOS exactly as it was.
import FoundationNetworking
#endif

/// Kimi Code's limits, from its own documented usage endpoint.
///
/// Two places the credential can come from, in this order:
///
/// 1. **A key pasted into Settings**, kept encrypted on this Mac. It wins, for
///    the reason OpenCode Go's does: someone who typed a key meant that one to
///    be used, and a stale token the CLI left behind must not override a
///    deliberate choice.
/// 2. **What the Kimi Code CLI saved for itself** in
///    `~/.kimi-code/credentials/kimi-code.json` — the same borrowing Claude
///    Code, Codex, Grok, Command Code and OpenCode Go get.
///
/// The fallback was left out on purpose once ("for now without the fallback to
/// a credential another tool stored"). It is here now because of what that
/// omission cost on Linux: the paste field lives in the settings window, so on
/// a platform without one `kimiCode` could not be configured **at all** — the
/// only one of the twenty that no command could reach. See
/// [Docs/linux/cli.md](../../Docs/linux/cli.md).
///
/// **The endpoint takes either.** A Kimi Code API key and the CLI's OAuth
/// access token are both accepted as a bearer token, which is why one route
/// serves both and why the token being the CLI's is not a special case.
///
/// The reply has **two kinds of limit in it and they are not the same figure**:
///
/// - `limits[]` — windows the service actually times, each stating a duration
///   and a unit (300 minutes, say). These are read as they are given.
/// - `usage` — the weekly allowance. The reply gives it a reset time and no
///   length, and the reset can land anywhere inside the week since the window
///   rolls, so the length is not inferable from it — it is named from what the
///   plan actually is.
///
/// Every count arrives as a *string*, and `detail` reports what is left rather
/// than what is spent, so both are converted here and everything downstream
/// stays in whole numbers of what is gone.
struct KimiCodeUsageService: Sendable {
    let enteredKey: String?

    private static let endpoint = URL(string: "https://api.kimi.com/coding/v1/usages")!

    /// One place a Kimi Code login can be found.
    ///
    /// `expiryIsMilliseconds` is per source rather than assumed, because the
    /// two disagree — measured on a machine holding both: Pi's `expires` is
    /// 1790077936089 and the CLI's `expires_at` is 1786525383, for expiries two
    /// months apart. Reading either one on the other's scale is not a small
    /// error: in seconds the millisecond value is the year 58691, so an expired
    /// token would look usable for ever.
    struct LoginSource: Sendable {
        let file: URL
        /// The keys to walk to reach the token, outermost first.
        let tokenPath: [String]
        let expiryPath: [String]
        let expiryIsMilliseconds: Bool
    }

    /// A usable-looking login, and when it stops being one.
    struct Login: Equatable {
        let token: String
        /// Nil when the store did not say, which is treated as usable: see
        /// `storedLogin`.
        let expiresAt: Date?
    }

    /// Every store Pulse will look in, and nothing about which wins —
    /// `storedLogin` decides that by date.
    ///
    /// Two, because the login can be in either: the Kimi Code CLI writes one,
    /// and Pi writes the other. **They are not copies of each other** — the
    /// tokens differ in length and in value on the machine this was measured
    /// on — so which one is current depends on which tool was used last, and
    /// that is not something to hardcode.
    ///
    /// Pi is not a stranger here: upstream already reads its session logs for
    /// the token-spend panes (`PiFamilySessionReader`), which is the same
    /// relationship Claude Code, Codex, Grok, Command Code and OpenCode Go
    /// have with their own stores.
    static func loginSources(home: URL) -> [LoginSource] {
        [
            LoginSource(
                file: home.appending(path: ".pi/agent/auth.json"),
                tokenPath: ["kimi-coding", "access"],
                expiryPath: ["kimi-coding", "expires"],
                expiryIsMilliseconds: true
            ),
            LoginSource(
                // Not `~/.kimi/…`: that is the older path, and this build keeps
                // everything under a directory named after the product —
                // measured on a machine with it installed, where `~/.kimi` does
                // not exist at all.
                file: home.appending(path: ".kimi-code/credentials/kimi-code.json"),
                tokenPath: ["access_token"],
                expiryPath: ["expires_at"],
                expiryIsMilliseconds: false
            ),
        ]
    }

    /// The login to use, and whether there is one worth using.
    ///
    /// **The freshest usable token wins**, rather than the first store in some
    /// order. There is no reason to prefer one tool's login over another's —
    /// both are borrowed, neither is the user's declared choice (a pasted key
    /// is, and is checked before this) — and a token that is still good is
    /// strictly better than one that is not.
    ///
    /// **Nothing here refreshes anything, deliberately.** Both stores hold a
    /// refresh token beside the access token, and OAuth refresh tokens rotate:
    /// spending one would invalidate the copy the tool that owns it is holding,
    /// signing the user out of Pi or out of the CLI. An expired token is
    /// reported as expired and left alone, and renewing it is the owning tool's
    /// job — which is why `.expired` exists as its own answer rather than being
    /// reported as a refused key.
    ///
    /// A store with no expiry field is treated as usable rather than as
    /// expired. The field belongs to the other tool, and refusing a token over
    /// a field Pulse does not own is a worse failure than letting the endpoint
    /// answer 401.
    static func storedLogin(now: Date = Date(), home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> Credential {
        let found = loginSources(home: home).compactMap(login)

        guard !found.isEmpty else { return .missing }

        let usable = found.filter { login in
            guard let expiry = login.expiresAt else { return true }
            return expiry > now
        }

        // Nil sorts as the far future so that a store which did not state an
        // expiry is not beaten by one that did — it cannot be shown to have
        // expired, which is the whole test being applied.
        guard let best = usable.max(by: {
            ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture)
        }) else {
            return .expired
        }

        return .token(best.token)
    }

    private static func login(at source: LoginSource) -> Login? {
        guard
            let data = try? Data(contentsOf: source.file),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let token = value(in: root, at: source.tokenPath) as? String,
            !token.isEmpty
        else { return nil }

        var expiresAt: Date?
        if let raw = value(in: root, at: source.expiryPath) as? NSNumber {
            let seconds = source.expiryIsMilliseconds ? raw.doubleValue / 1000 : raw.doubleValue
            expiresAt = Date(timeIntervalSince1970: seconds)
        }

        return Login(token: token, expiresAt: expiresAt)
    }

    private static func value(in root: [String: Any], at path: [String]) -> Any? {
        var node: Any = root
        for key in path {
            guard let dictionary = node as? [String: Any], let next = dictionary[key] else {
                return nil
            }
            node = next
        }
        return node
    }

    /// What the credential lookup found.
    ///
    /// `expired` is its own case rather than folded into "missing", because the
    /// two want different instructions: no file means signing in to the CLI
    /// first, whereas a token that has run out means running the CLI once.
    /// Reading a stale token as a refused key would send someone looking for a
    /// key to replace when what they have is a login that needs renewing.
    enum Credential: Equatable {
        case token(String)
        case expired
        case missing
    }

    func fetch() async -> ProviderUsage {
        let credential: Credential
        if let entered = enteredKey.flatMap({ $0.isEmpty ? nil : $0 }) {
            credential = .token(entered)
        } else {
            credential = Self.storedLogin()
        }

        let key: String
        switch credential {
        case .token(let token):
            key = token
        // The CLI renews this token while it is being used and nothing renews
        // it for Pulse, so an installation that has not run `kimi` in a while
        // lands here rather than at a 401.
        case .expired:
            return .unavailable(.kimiCode, reason: .kimiLoginExpired)
        case .missing:
            return .unavailable(.kimiCode, reason: .apiKeyMissing)
        }

        var request = URLRequest(url: Self.endpoint)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        guard let (data, response) = try? await NetworkSession.shared.data(for: request) else {
            return .unavailable(.kimiCode, reason: .unreachable)
        }

        switch (response as? HTTPURLResponse)?.statusCode {
        case 200: break
        case 401, 403: return .unavailable(.kimiCode, reason: .apiKeyRefused)
        case 429: return .unavailable(.kimiCode, reason: .rateLimited)
        default: return .unavailable(.kimiCode, reason: .serverError)
        }

        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            return .unavailable(.kimiCode, reason: .unreadableReply)
        }

        let windows = Self.windows(from: reply)
        guard !windows.isEmpty else {
            return .unavailable(.kimiCode, reason: .noLimitsReported)
        }

        return ProviderUsage(
            account: AccountKey(.kimiCode),
            windows: windows,
            observedAt: Date(),
            state: .live,
            plan: Self.planName(reply.user?.membership?.level),
            // `totalQuota` comes back empty and `parallel.limit` is how many
            // requests may run at once, which is not a balance.
            creditBalance: nil
        )
    }

    // MARK: - Reading the reply

    private struct Reply: Decodable {
        struct Detail: Decodable {
            let limit: String?
            let used: String?
            let remaining: String?
            let resetTime: String?
        }

        struct Window: Decodable {
            let duration: Int?
            let timeUnit: String?
        }

        struct Limit: Decodable {
            let window: Window?
            let detail: Detail?
        }

        struct Membership: Decodable { let level: String? }
        struct User: Decodable { let membership: Membership? }

        let user: User?
        let usage: Detail?
        let limits: [Limit]?
    }

    private static func windows(from reply: Reply) -> [UsageWindow] {
        var found: [UsageWindow] = []

        // The timed windows first, named by the length the service states.
        for (index, limit) in (reply.limits ?? []).enumerated() {
            guard
                let seconds = duration(of: limit.window),
                let window = window(
                    from: limit.detail,
                    // The position too: two windows of the same length is
                    // exactly the shape the other providers' per-model limits
                    // take, and duplicate ids collapse rows in the card.
                    id: "limit.\(index).\(seconds)",
                    kind: kind(forSeconds: seconds),
                    seconds: seconds
                )
            else { continue }

            found.append(window)
        }

        // Then the weekly allowance, which the reply carries separately and
        // does not put a length on. Only its reset time is ever displayed; the
        // seconds are what sort it after the shorter windows.
        if let weekly = window(from: reply.usage, id: "weekly", kind: .weekly,
                               seconds: 7 * 86_400, reportsLength: false) {
            found.append(weekly)
        }

        return found.sorted { $0.windowSeconds < $1.windowSeconds }
    }

    private static func window(
        from detail: Reply.Detail?,
        id: String,
        kind: UsageWindow.Kind,
        seconds: Int,
        reportsLength: Bool = true
    ) -> UsageWindow? {
        guard
            let detail,
            let limit = number(detail.limit),
            limit > 0
        else { return nil }

        // `used` when it is given, otherwise what the limit and the remainder
        // imply. `limits[].detail` carries no `used` at all.
        let used = number(detail.used) ?? number(detail.remaining).map { limit - $0 }
        guard let used else { return nil }

        return UsageWindow(
            id: id,
            kind: kind,
            scope: nil,
            usedFraction: min(max(used / limit, 0), 1),
            windowSeconds: seconds,
            resetsAt: detail.resetTime.flatMap(Self.date(from:)),
            // The rolling allowance states a reset and no length, so `seconds`
            // is what sorts it rather than something to divide by. It is the
            // *caller* that knows which one this is: testing the kind instead
            // would also catch a limit that genuinely states seven days, and
            // silently take away its forecast and its clock arc.
            reportsLength: reportsLength,
            isExhausted: used >= limit
        )
    }

    /// A window's length in seconds, or nil for a unit that isn't recognised —
    /// a window with no length can't be named or sorted, and inventing one
    /// would put a figure under a heading that isn't true.
    private static func duration(of window: Reply.Window?) -> Int? {
        guard let window, let duration = window.duration, duration > 0 else { return nil }

        return switch window.timeUnit {
        case "TIME_UNIT_SECOND": duration
        case "TIME_UNIT_MINUTE": duration * 60
        case "TIME_UNIT_HOUR": duration * 3_600
        case "TIME_UNIT_DAY": duration * 86_400
        default: nil
        }
    }

    private static func kind(forSeconds seconds: Int) -> UsageWindow.Kind {
        switch seconds {
        case 5 * 3_600: .fiveHour
        case 7 * 86_400: .weekly
        case 30 * 86_400: .monthly
        default: .other(seconds: seconds)
        }
    }

    /// "LEVEL_INTERMEDIATE" → "Intermediate". An unfamiliar tier is passed
    /// through tidied rather than blanked: an unknown name still beats none,
    /// and it is the only clue left when a new tier appears.
    private static func planName(_ level: String?) -> String? {
        guard let level, !level.isEmpty else { return nil }

        let bare = level.hasPrefix("LEVEL_") ? String(level.dropFirst("LEVEL_".count)) : level
        return bare
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }

    private static func number(_ text: String?) -> Double? {
        text.flatMap(Double.init)
    }

    /// The stamps carry sub-second precision, which the plain internet-date
    /// options refuse.
    private static func date(from text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
