// Moved out of `UsageDockView.swift`, where it was written.
//
// **A description of one ring, not a drawing of one.** Every field is a value
// the rail decides before anything is drawn: the reading, the window it chose,
// whether a CLI is running, the colour, the mark's persona and body, and what
// the card calls it. It is produced by `RailEntryBuilder` and consumed by the
// drawing, and on Linux the drawing is Cairo rather than SwiftUI — so the type
// had to stop living in a `View` file.
//
// Moving it is the whole change. Nothing was renamed and no field was touched.
// pulse-linux: moved

import Foundation

struct RailEntry: Identifiable, Equatable {
    let usage: ProviderUsage
    let headline: UsageWindow?
    /// Whether this provider's CLI is working at this moment, which the ring
    /// shows as a turning mark.
    var isRunning: Bool = false
    /// Whether Pulse is currently fetching a fresh reading for this provider.
    var isRefreshing: Bool = false
    /// A colour chosen for this ring, or nil to colour it by usage.
    var tint: Color?
    /// Whether this ring draws the animated mark instead of the logo.
    var showsBotMark: Bool = false
    /// The persona chosen for this ring, or nil to let the rail deal one.
    var botPersona: BotMarkPersona?
    /// The shape this ring's mark wears.
    var botBody: BotMarkBody = .default
    /// Something that just happened to this account and is worth a one-shot.
    var botEvent: BotMarkEvent?
    /// A colour chosen for this ring's mark, or nil for its brand colour.
    var botColour: Color?
    /// How much of the headline window's clock has run, or nil to leave the
    /// outer arc off — either because the setting is off, or because this
    /// window doesn't report enough to work it out.
    /// Which ring this is. An unsplit account's slot keeps the account's own
    /// id, so nothing stored before slots existed stops matching.
    var slot: RailSlot
    /// What the card calls it: the account's label, and the model group after
    /// it where an account has been split into one ring per group.
    var title: String
    var elapsed: Double?
    /// What to draw in the ring when there is no percentage to draw.
    ///
    /// DeepSeek sells prepaid credit and reports no allowance, so on "balance
    /// only" there is deliberately no window and therefore no fraction — but
    /// there *is* a figure, and a ring showing an em dash beside a perfectly
    /// good balance reads as a provider that failed. Nil everywhere else,
    /// where nothing known really does mean nothing known.
    var figure: String?
    /// The next-fullest limit, when the second ring is switched on and this
    /// provider reports more than one.
    var second: UsageWindow?
    /// Show what is left rather than what is gone — the figure and the arc
    /// together. Carried on the entry like the tint, because the item is built
    /// from this and doesn't otherwise see the settings.
    var showsRemaining: Bool = false

    var id: String { slot.id }
}
