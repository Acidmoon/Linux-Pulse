// Moved out of `FloatingUsagePanelView`, where they were written.
//
// **What each ring shows, which is not a view question.** Which window a ring
// takes, what the card calls it, when a second ring appears, when a figure is
// shown instead of a percentage, and when a finished turn becomes a one-shot —
// all of it reads `AppSettings` and `UsageStore` and produces `RailEntry`
// values. It was a private computed property on a SwiftUI view because that is
// where it was first needed.
//
// It is here so the Linux panel builds its rail from upstream's rules and not
// from a copy of them: a ported rail that decided for itself which window to
// show would drift, and the drift would look like a provider misbehaving.
//
// The bodies below are upstream's, unchanged. The only edits are the
// signatures — what was read from `self` is passed in, because there is no
// `self` to read it from — and `@MainActor`, because `AppSettings` and
// `UsageStore` are main-actor bound and a closure that merely claims to be on
// the main actor still sends them into it as far as the compiler is concerned.
// The panel's whole model runs on the main thread because GTK draws there.
// pulse-linux: moved

import Foundation

@MainActor
enum RailEntryBuilder {
    /// Only the providers switched on in settings, so the rail shrinks when
    /// one is turned off.
    static func entries(settings: AppSettings, store: UsageStore, minute: Date) -> [RailEntry] {
        RailSlot.rail(
            for: settings.shownAccounts,
            isSplit: settings.isSplit,
            groups: { RailSlot.modelGroups(of: store.usage(for: $0)) }
        ).map { slot in
            let reading = store.usage(for: slot.account)
            return entry(
                for: slot,
                usage: slot.group.map { RailEntryBuilder.usage(reading, keeping: $0) } ?? reading,
                settings: settings,
                store: store,
                minute: minute
            )
        }
    }

    /// One ring. `usage` is the reading that belongs to *this* slot, which for a
    /// split account is one model group of the provider's windows and not all of
    /// them.
    static func entry(for slot: RailSlot, usage: ProviderUsage, settings: AppSettings,
                      store: UsageStore, minute: Date) -> RailEntry {
        let account = slot.account
        let label = settings.label(for: account)
        let pinned = settings.pinnedWindow(for: account)
        let headline = usage.headlineWindow(preferring: pinned)

        // The money, but only where there is a reading and deliberately no
        // window to draw — which today is DeepSeek on "balance only". An
        // unavailable reading has nothing to say, and putting a remembered
        // figure on the rail there would show it as though it were current.
        let figure: String? = if headline == nil, case .unavailable = usage.state {
            nil
        } else if headline == nil {
            // The short form: the exact figure is on the card and in Settings,
            // and it does not fit in a ring.
            usage.creditRemaining?.railText() ?? usage.creditBalance
        } else {
            nil
        }

        return RailEntry(
            usage: usage,
            headline: headline,
            // Activity is per *provider*: a running CLI belongs to whichever
            // account it happens to be signed in to, and the transcripts do
            // not say which. Every account of that provider shows the mark.
            isRunning: store.isRunning(account.provider),
            isRefreshing: store.isRefreshing(account),
            tint: settings.ringTint(for: account),
            showsBotMark: settings.showsBotMark(for: account),
            botPersona: settings.botPersona(for: account),
            botBody: settings.botBody(for: account),
            // **A reset outranks a finished turn.** Both can be true in the
            // same few seconds — a turn that ends as the window rolls over —
            // and the reset is the rarer news.
            botEvent: store.justReset(account) ? .limitReset
                : store.justFinishedWorking(account.provider) ? .workFinished : nil,
            botColour: settings.botColour(for: account),
            slot: slot,
            // The group after the name, so two rings of one provider are told
            // apart by the one thing that differs between them.
            title: slot.group.map { "\(label) · \($0)" } ?? label,
            // Nil unless it is switched on *and* the window says enough to
            // work it out — a reset time on its own is not enough.
            elapsed: settings.showsWindowClock ? headline?.elapsedFraction(at: minute) : nil,
            figure: figure,
            second: settings.showsSecondRing ? usage.secondWindow(preferring: pinned) : nil,
            showsRemaining: settings.showsRemaining
        )
    }

    /// The same reading with only one group's limits in it, so every figure
    /// downstream — the ring, the card, the second ring — is about that group
    /// and nothing else.
    static func usage(_ usage: ProviderUsage, keeping group: String) -> ProviderUsage {
        ProviderUsage(
            account: usage.account,
            windows: usage.windows.filter { $0.scope == group },
            observedAt: usage.observedAt,
            state: usage.state,
            plan: usage.plan,
            creditBalance: usage.creditBalance
        )
    }
}
