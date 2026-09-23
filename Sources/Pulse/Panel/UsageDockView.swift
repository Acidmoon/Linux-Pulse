// The macOS UI. Excluded from the Linux build rather than ported: this file
// is SwiftUI/AppKit presentation, and the Linux panel is drawn by a separate
// GTK4 process (see Docs/linux/migration-assessment.md). The guard is the
// module the file actually imports, so a file that only needs SwiftUI is not
// asking for AppKit.
// pulse-linux: excluded
#if canImport(SwiftUI)
import SwiftUI

/// Layout constants for the collapsed dock rail. Shared with
/// `FloatingPanelController.Layout` (which derives its panel sizes from
/// these plus `DetailCardLayout`) so the AppKit panel frame and the SwiftUI
/// content never drift apart.

/// The rail, in whatever state it is currently in — full, collapsed to a
/// sliver against the screen edge, or somewhere between the two.
///
/// The two states used to be separate views swapped by a transition, which is
/// what made the sliver read as *disappearing* while a rail *appeared* in its
/// place. They are one thing: a single berth whose size and outline are
/// animated, with the rings fading in once it has opened enough to hold them.
struct UsageDockView: View {
    let entries: [RailEntry]
    /// Where the pointer is in the panel's coordinates, or nil when it is off
    /// the panel. The marks' eyes follow it.
    var pointer: CGPoint?
    /// Whether no CLI has written for a while; only the sleepy persona uses
    /// this to add a night-time doze.
    var isQuiet = false
    let selectedSlot: String?
    let edge: PanelEdge
    /// Fused to a screen edge, or standing free on the desktop. Only the
    /// silhouette changes: docked it flares into the edge, floating it closes
    /// itself off into a capsule.
    var isDocked: Bool = true
    /// Open, or wound down to the sliver.
    var isExpanded: Bool = true
    var notchSize: CGSize?
    /// Colours the sliver when a limit is close enough that hiding the rail
    /// would be hiding something worth seeing.
    var alert: Color?
    /// Liquid Glass instead of flat black.
    var usesGlass: Bool = false
    /// Whether a ring turns while its CLI is working or Pulse is refreshing
    /// it. See `AppSettings.animatesRingActivity`.
    var animatesActivity: Bool = true
    /// Called as the pointer arrives on a provider's ring. The details flyout
    /// follows the pointer rather than a click, so this is what drives
    /// selection. Leaving is handled by `PanelPointerWatcher`, not here.
    let onEnter: (RailEntry) -> Void
    /// The accessibility/default action for a provider ring. Physical clicks
    /// are resolved by `FloatingPanel`, which owns mouse input ahead of SwiftUI.
    var onRefresh: (AccountKey) -> Void = { _ in }
    /// Called as the pointer arrives on the collapsed sliver.
    var onOpen: () -> Void = {}

    private var railSize: CGSize { DockLayout.size(for: entries.count, on: edge.axis, docked: isDocked) }
    private var currentSize: CGSize {
        isExpanded ? railSize : DockLayout.collapsedSize(on: edge.axis)
    }

    var body: some View {
        // Laid out at full size whatever it is drawing, so nothing around it
        // moves as it opens and closes.
        ZStack(alignment: edge.stackAlignment) {
            berth

            rings
                .opacity(isExpanded ? 1 : 0)
                // Its own timing, overriding the spring the shape rides on:
                // the contents appear once the berth has opened enough to hold
                // them, and are gone before it closes. Without the delay they
                // fade up over a shape that is still a sliver, which is the
                // giveaway that these were ever two separate things.
                .animation(
                    .easeOut(duration: isExpanded ? 0.18 : 0.10)
                        .delay(isExpanded ? 0.12 : 0),
                    value: isExpanded
                )
        }
        .frame(width: railSize.width, height: railSize.height)
        .allowsHitTesting(notchSize == nil || isExpanded)
        .accessibilityHidden(notchSize != nil && !isExpanded)
        // No drag handle lives here any more. A press only reaches a view
        // inside `NSHostingView` if SwiftUI claims it first, and it would not
        // claim the empty black between the rings: the berth opts out of hit
        // testing and nothing else covers those points, so the panel could be
        // dragged by its rings and nowhere else. Laying a shape over the handle
        // to claim them swallowed the press instead of passing it down, and
        // then nothing could be dragged at all.
        //
        // The window takes its own mouse events instead — see `FloatingPanel`
        // in FloatingPanelController.swift — which happens before any of
        // SwiftUI's hit testing and cannot be undone by it.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String.localized("Provider usage selector"))
    }

    @ViewBuilder
    private var berth: some View {
        if let notchSize {
            let surface = PanelHitArea.notchSurface(rail: CGRect(origin: .zero, size: railSize), notchSize: notchSize)
            PanelSurface(
                shape: NotchBerthShape(notchSize: notchSize, openness: isExpanded ? 1 : 0),
                usesGlass: usesGlass
            )
            .overlay {
                // The hardware housing replaces the ordinary collapsed
                // sliver. Keep its one useful signal as a thin line directly
                // under the housing; expanded rings already carry the colour.
                if !isExpanded, let alert {
                    NotchAlertShape(notchSize: notchSize)
                        .fill(alert)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            // Wider than the surface by the room the fillets sweep into at
            // the screen edge; the shape insets that back off for the body.
            .frame(width: surface.width + DockLayout.flareWidth * 2, height: surface.height)
            .offset(y: surface.minY)
            .frame(width: railSize.width, height: railSize.height, alignment: .top)
        } else {
            ordinaryBerth
        }
    }

    private var ordinaryBerth: some View {
        let shape = DockBerthShape(edge: edge, isDocked: isDocked, openness: isExpanded ? 1 : 0)

        return PanelSurface(
            shape: shape,
            usesGlass: usesGlass,
            // Only the sliver carries the alert colour: expanded, the rings
            // already say which limit is where.
            tint: isExpanded ? nil : alert
        )
            .frame(width: currentSize.width, height: currentSize.height)
            .overlay(alignment: edge.stackAlignment) {
                // Only while collapsed, and only over the sliver: a tracking
                // area on the full band would open the panel from sixty points
                // of empty air.
                if !isExpanded {
                    let hit = DockLayout.collapsedHitSize(on: edge.axis)
                    Color.clear
                        .frame(width: hit.width, height: hit.height)
                        .contentShape(.rect)
                        .background(PointerEntryReporter(onEnter: onOpen))
                        .accessibilityElement()
                        .accessibilityLabel(String.localized("Show usage panel"))
                }
            }
    }

    private var rings: some View {
        // The same items, stacked whichever way the rail runs. `AnyLayout`
        // keeps them one set of views across the change rather than two sets
        // swapped, so a rail that is re-docked from a side to the top carries
        // its rings round with it instead of rebuilding them.
        let stack = edge.isVertical
            ? AnyLayout(VStackLayout(spacing: DockLayout.itemSpacing))
            : AnyLayout(HStackLayout(spacing: DockLayout.itemSpacing))

        // Dealt here because this is the one place that knows the order the
        // rings are actually in — the rail shows enabled accounts, so who sits
        // next to whom is not knowable from `Provider.allCases`.
        // Only when something is actually drawing a mark: the deal tries
        // forty stride-and-rotation combinations, which is cheap but not free,
        // and a rail of logos has no use for the answer.
        let botTints = entries.contains(where: \.showsBotMark)
            ? BotMarkTint.deal(over: entries.map(\.usage.provider),
                               chosen: entries.map(\.botColour))
            : []
        // Dealt by position so the ring beside this one is a different
        // character; a chosen persona simply wins over the deal.
        let personas = entries.enumerated().map { index, entry in
            entry.botPersona ?? BotMarkPersona.automatic(at: index)
        }
        // Everything worth looking at is away from the edge the rail is on.
        let gaze = BotMarkGaze(edge: edge)

        return stack {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                UsageDockItem(
                    entry: entry,
                    botTint: index < botTints.count ? botTints[index] : .clear,
                    botPersona: personas[index],
                    botBody: entry.botBody,
                    botGaze: gaze,
                    botEvent: entry.botEvent,
                    pointer: pointer,
                    isQuiet: isQuiet,
                    isSelected: selectedSlot == entry.slot.id,
                    isInteractive: isExpanded,
                    showsPercentage: DockLayout.showsPercentages(on: edge.axis),
                    animatesActivity: animatesActivity,
                    onEnter: { onEnter(entry) },
                    onRefresh: { onRefresh(entry.slot.account) }
                )
                // **Every item takes exactly the length it was budgeted.**
                // `DockLayout` decides the rail's size before SwiftUI lays
                // anything out, and the hit testing steps along it in those
                // same units — so an item allowed to take its natural size
                // instead puts every ring after it a little further out than
                // the hit test looks, and the error accumulates down the rail.
                // It reached 12.6pt at eleven rings, which is a third of a
                // ring, purely from a label rendering narrower than its budget.
                .frame(
                    width: edge.isVertical ? nil : DockLayout.itemLength(on: .horizontal),
                    height: edge.isVertical ? DockLayout.itemLength(on: .vertical) : nil
                )
            }
        }
        // The padding follows the run too: the generous end padding is what
        // the flare needs room inside, and the flare is at the rail's ends
        // whichever way it is lying.
        .padding(edge.isVertical ? .vertical : .horizontal, DockLayout.endPadding(docked: isDocked))
        .padding(edge.isVertical ? .horizontal : .vertical, DockLayout.horizontalPadding)
        .frame(width: railSize.width, height: railSize.height)
    }
}

private struct UsageDockItem: View {
    let entry: RailEntry
    /// The body colour for this ring's animated mark, dealt across the rail.
    let botTint: Color
    /// The character this ring's mark plays.
    let botPersona: BotMarkPersona
    /// The shape it wears.
    let botBody: BotMarkBody
    /// Which way it looks.
    let botGaze: BotMarkGaze
    /// A one-shot for something that just happened.
    let botEvent: BotMarkEvent?
    /// The pointer in panel coordinates, for this ring's mark to look at.
    let pointer: CGPoint?
    /// Whether the machine has been quiet for a while.
    let isQuiet: Bool
    let isSelected: Bool
    /// False while the rail is collapsed. The rings are still in the view
    /// tree then, only invisible — and an invisible ring with a live tracking
    /// area would open a card for a provider nobody can see.
    let isInteractive: Bool
    /// False for a rail lying across the top with the labels switched off,
    /// which is the default there — see `AppSettings.topRailShowsPercentages`.
    var showsPercentage: Bool = true
    /// Whether this ring turns while its CLI is working or being refreshed.
    var animatesActivity: Bool = true
    let onEnter: () -> Void
    let onRefresh: () -> Void

    private var usage: ProviderUsage { entry.usage }
    private var headline: UsageWindow? { entry.headline }

    var body: some View {
        // The label goes above or below on a setting. `ringOffsetInItem` is
        // the same swap expressed as a number, and the hit testing runs on
        // that — the two must not be allowed to disagree.
        VStack(spacing: DockLayout.ringToTextSpacing) {
            if DockLayout.labelLeads { percentLabel }

            ring

            if !DockLayout.labelLeads { percentLabel }
        }
        .contentShape(.rect)
        .background {
            if isInteractive { PointerEntryReporter(onEnter: onEnter) }
        }
        .accessibilityElement(children: .ignore)
        // The entry's title, not the provider's name: a split provider draws
        // two rings from one login, and named by the provider alone VoiceOver
        // reads out the same thing twice.
        .accessibilityLabel(String.localized("\(entry.title) usage"))
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(String.localized("Activate to refresh usage."))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text(String.localized("Refresh usage")), onRefresh)
    }

    /// Lifted out of `body` because the initializer has enough arguments that
    /// type-checking it inline exceeded the compiler's budget.
    private var ring: some View {
        UsageRingView(
            provider: usage.provider,
            usedFraction: headline?.usedFraction,
            // A ring showing money instead of a percentage has a reading; only
            // one showing an em dash does not.
            hasReading: headline != nil || entry.figure != nil,
            chosenTint: entry.tint,
            isSpent: UsageTint.isSpent(headline),
            showsRemaining: entry.showsRemaining,
            diameter: DockLayout.ringDiameter,
            lineWidth: DockLayout.ringLineWidth,
            isBusy: entry.isRunning,
            isRefreshing: entry.isRefreshing,
            animatesActivity: animatesActivity,
            showsBotMark: entry.showsBotMark,
            botTint: botTint,
            botPersona: botPersona,
            botBody: botBody,
            botGaze: botGaze,
            botEvent: botEvent,
            botPointer: pointer,
            botQuiet: isQuiet,
            highlight: isSelected,
            elapsedFraction: entry.elapsed,
            secondFraction: entry.second?.usedFraction,
            secondIsSpent: UsageTint.isSpent(entry.second)
        )
        .scaleEffect(isSelected ? 1.06 : 1)
    }

    /// An em dash rather than 0% when nothing is known: a zero would read as
    /// "you've used nothing" — or, flipped, as "you have nothing left", which
    /// is a worse claim still.
    @ViewBuilder
    private var percentLabel: some View {
        if showsPercentage {
            Text(headline?.percentText(remaining: entry.showsRemaining) ?? entry.figure ?? "—")
                .font(.system(size: DockLayout.percentFontSize, weight: .medium, design: .rounded))
                // Money is longer than a percentage and its length is not
                // bounded by anything — "¥9.40" fits where "$1,234.56" does
                // not — so it shrinks to fit rather than being cut off inside
                // the ring.
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                // A spent limit colours the figure too. At ring size a fourth
                // hue on the stroke alone would read as the third.
                .foregroundStyle(
                    UsageTint.isSpent(headline)
                        ? Color.pulseExhausted
                        : .primary.opacity(headline == nil && entry.figure == nil ? 0.4 : 1)
                )
                .monospacedDigit()
                // Dimmed with the arc, so the whole ring goes quiet together
                // while its reading is fetched, and returns with it.
                .opacity(entry.isRefreshing ? 0.4 : 1)
                .animation(.easeOut(duration: 0.2), value: entry.isRefreshing)
                // Digits change places rather than cutting, so a figure that
                // actually moved is visibly what moved.
                .contentTransition(.numericText())
                .animation(
                    .spring(response: 0.5, dampingFraction: 0.85),
                    value: headline?.percentText(remaining: entry.showsRemaining) ?? entry.figure
                )
        }
    }

    private var accessibilityValue: String {
        let reading = headline.map { window in
            entry.showsRemaining
                ? String.localized("\(window.percentText(remaining: true)) left, \(window.name)")
                : String.localized("\(window.percentText) used, \(window.name)")
        } ?? String.localized("No reading")
        return entry.isRefreshing
            ? "\(reading). \(String.localized("Refreshing…"))"
            : reading
    }
}


#Preview("Dock") {
    UsageDockView(
        entries: Provider.allCases.map {
            RailEntry(
                usage: .unavailable($0, reason: .loading),
                headline: nil,
                slot: RailSlot(AccountKey($0)),
                title: $0.displayName
            )
        },
        selectedSlot: RailSlot(AccountKey(.claudeCode)).id,
        edge: .right,
        onEnter: { _ in }
    )
    .frame(height: DockLayout.maximumHeight + 80)
    .padding()
    .background(.gray)
}
#endif
