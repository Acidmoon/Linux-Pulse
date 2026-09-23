import Foundation
import Testing

@testable import Pulse

/// What the rail draws, checked by writing down what it was asked to draw.
///
/// **The renderer's other tests are pictures.** `PulsePanel --render` produces a
/// PNG that a person looks at and CI checks is not blank — which catches "drew
/// nothing" and cannot catch "drew the wrong colour" or "stopped drawing the
/// working mark". Everything the panel draws goes through fifteen verbs, so a
/// canvas that records them makes those questions answerable without a display,
/// a session, or an eye.
@Suite("What the rail draws")
@MainActor
struct PanelRendererTests {
    private func entry(used: Double?, figure: String? = nil, isRunning: Bool = false,
                       isRefreshing: Bool = false, spent: Bool = false,
                       showsRemaining: Bool = false, second: Double? = nil,
                       elapsed: Double? = nil, showsBotMark: Bool = false,
                       provider: Provider = .claudeCode) -> RailEntry {
        let window = used.map {
            UsageWindow(id: "five_hour", kind: .fiveHour, scope: nil, usedFraction: $0,
                        windowSeconds: 5 * 3600, resetsAt: nil, reportsLength: true,
                        isExhausted: spent)
        }
        let secondWindow = second.map {
            UsageWindow(id: "week", kind: .weekly, scope: nil, usedFraction: $0,
                        windowSeconds: 7 * 86_400, resetsAt: nil, reportsLength: true)
        }
        return RailEntry(
            usage: ProviderUsage(account: AccountKey(provider),
                                 windows: [window, secondWindow].compactMap { $0 },
                                 observedAt: Date(), state: .live, plan: nil,
                                 creditBalance: nil),
            headline: window,
            isRunning: isRunning,
            isRefreshing: isRefreshing,
            tint: nil,
            showsBotMark: showsBotMark,
            botPersona: nil,
            botBody: .default,
            botEvent: nil,
            botColour: nil,
            slot: RailSlot(AccountKey(provider)),
            title: provider.displayName,
            elapsed: elapsed,
            figure: figure,
            second: secondWindow,
            showsRemaining: showsRemaining
        )
    }

    private func draw(_ entry: RailEntry, isSelected: Bool = false,
                      animatesActivity: Bool = true) -> RecordingCanvas {
        let canvas = RecordingCanvas()
        PanelRailRenderer.drawRing(entry, centre: CGPoint(x: 100, y: 200), opacity: 1,
                                   isSelected: isSelected, animatesActivity: animatesActivity,
                                   frame: nil, config: nil, canvas: canvas)
        return canvas
    }

    /// A ring is a track and an arc over it. The track is a full circle; the arc
    /// starts at twelve o'clock, which is what makes it a gauge rather than a
    /// decoration.
    @Test("A ring with a reading draws a track and an arc from the top")
    func drawsTrackAndArc() {
        let canvas = draw(entry(used: 0.4))
        #expect(canvas.fullCircles.count >= 1, "no full circle for the track")
        let fraction = try? #require(canvas.arcs.first)
        guard let fraction else { return }
        #expect(abs(fraction.start - -Double.pi / 2) < 1e-9, "the arc did not start at the top")
        #expect(abs((fraction.end - fraction.start) - 2 * .pi * 0.4) < 1e-9,
                "the arc does not cover 40% of the circle")
    }

    /// **No reading draws no arc, either way round.** The rule upstream measured
    /// by sampling the rendered circumference: a provider that has not answered
    /// — the first seconds after launch, one signed out — must not draw a
    /// complete ring, because a complete ring reads as "all fine".
    @Test("A ring with no reading draws no fraction")
    func noReadingDrawsNothing() {
        let canvas = draw(entry(used: nil))
        // The track is still there; what must not be is a coloured fraction.
        #expect(canvas.arcs.isEmpty, "an unread ring drew \(canvas.arcs.count) fraction arcs")
        // And the figure is an em dash rather than a number, because a zero
        // would read as "you have used nothing".
        #expect(canvas.texts.contains { $0.string == "—" },
                "expected an em dash, got \(canvas.texts.map(\.string))")
    }

    /// Counting down shows the complement of the arc.
    ///
    /// **And the rail's figure is the bare number.** The word — "88% Left",
    /// "12% Used" — is on the *card*, not under the ring; `UsageDockItem` draws
    /// `percentText` and nothing else, which this test found out by asserting
    /// the opposite.
    @Test("Counting down reverses the arc")
    func remainingReversesTheArc() {
        let canvas = draw(entry(used: 0.12, showsRemaining: true))
        guard let fraction = canvas.arcs.first else {
            Issue.record("no arc"); return
        }
        #expect(abs((fraction.end - fraction.start) - 2 * .pi * 0.88) < 1e-9,
                "an 88%-left ring covered \((fraction.end - fraction.start) / (2 * .pi)) of the circle")
        #expect(canvas.texts.contains { $0.string == "88%" },
                "expected '88%', got \(canvas.texts.map(\.string))")
    }

    /// **The working mark.** A CLI that is doing something gets a white arc
    /// travelling round inside the ring, and it is the only thing on the rail
    /// that moves on its own. Nothing else tested it, because it needs a
    /// provider that is really running.
    @Test("A working CLI gets the travelling mark")
    func workingCLIDrawsTheMark() {
        let canvas = draw(entry(used: 0.4, isRunning: true))
        // Three strokes: the track, the fraction, and the mark.
        #expect(canvas.strokes.count >= 3, "got \(canvas.strokes.count) strokes")
        let mark = canvas.strokes.last
        let expected = max(DockLayout.ringLineWidth * 0.5, 1.5)
        // An epsilon rather than `==`, because the expected width is
        // `ringLineWidth * 0.5` and the drawn one is the same product computed
        // on the other side of a function call: the two can differ in the last
        // bit, and `==` on doubles is the wrong question in any case.
        #expect(abs((mark?.width ?? 0) - expected) < 1e-9,
                Comment(rawValue: "the mark is not the thinner arc: got \(String(describing: mark?.width)), expected \(expected), all widths \(canvas.strokes.map(\.width))"))
        // And it is white, because colour on the ring means how much is gone.
        #expect(mark?.colour == Color.primary)
    }

    /// Not while the animated mark is playing: the two are one fact drawn twice,
    /// and the arc is the half that says nothing about which provider it is.
    @Test("The mark goes when the animated body is there instead")
    func noMarkWithBotMark() {
        let canvas = draw(entry(used: 0.4, isRunning: true, showsBotMark: true))
        #expect(!canvas.strokes.contains { $0.width == max(DockLayout.ringLineWidth * 0.5, 1.5) },
                "the travelling mark was drawn beside the animated mark")
    }

    /// A rail that is not on screen does not animate: upstream turns the
    /// activity marks off for a collapsed rail, and this is that switch.
    @Test("Nothing travels when activity is off")
    func noMarkWhenNotAnimating() {
        let canvas = draw(entry(used: 0.4, isRunning: true), animatesActivity: false)
        #expect(!canvas.strokes.contains { $0.width == max(DockLayout.ringLineWidth * 0.5, 1.5) })
    }

    /// **The figure is drawn, and it is the headline's.** This is the half of the
    /// acceptance criterion an image cannot check.
    @Test("The figure under the ring is the headline's")
    func figureMatchesHeadline() {
        let canvas = draw(entry(used: 0.47))
        #expect(canvas.texts.contains { $0.string == "47%" },
                "expected '47%', got \(canvas.texts.map(\.string))")
    }

    /// A spent limit fills the ring **whichever way it counts** — counting down,
    /// nothing left is no arc at all, so the most urgent state would have had
    /// the least ink on screen.
    /// **A spent ring is a full circle, which is why this is checked by colour.**
    /// Its arc covers the whole circumference, so it is geometrically
    /// indistinguishable from the track underneath it — the difference is that
    /// one is the exhausted red and the other is the primary colour at 0.18.
    @Test("A spent limit fills the ring both ways round")
    func spentFillsTheRing() {
        for showsRemaining in [false, true] {
            let canvas = draw(entry(used: 1, spent: true, showsRemaining: showsRemaining))
            #expect(canvas.strokes.contains { $0.colour == .pulseExhausted && $0.opacity == 1 },
                    Comment(rawValue: "a spent ring was not drawn in the exhausted colour (remaining=\(showsRemaining)): \(canvas.strokes.map(\.colour))"))
            let filled = canvas.fullCircles.filter { $0 == DockLayout.ringDiameter / 2 }
            #expect(filled.count >= 2,
                    "a spent ring has no filled circle over its track (remaining=\(showsRemaining))")
        }
    }

    /// The second ring is drawn when the provider reports more than one limit —
    /// thinner, inside the first, and in the same colour language.
    @Test("A second limit draws a second ring")
    func secondRingIsDrawn() {
        let canvas = draw(entry(used: 0.2, second: 0.6))
        let secondLine = DockLayout.secondRingLineWidth
        #expect(canvas.strokes.contains { $0.width == secondLine },
                "no second ring: \(canvas.strokes.map(\.width))")
    }

    /// The window clock is a third, fainter arc outside the ring — the only
    /// thing drawn outside it, and only when the reader has asked for it.
    @Test("The window clock is drawn outside the ring, and only when asked")
    func clockArc() {
        let without = draw(entry(used: 0.2))
        let with = draw(entry(used: 0.2, elapsed: 0.5))
        #expect(with.arcs.count > without.arcs.count, "no clock arc appeared")
        let outermost = with.arcs.map(\.radius).max() ?? 0
        #expect(outermost > DockLayout.ringDiameter / 2,
                "the clock arc is not outside the ring: \(outermost)")
    }

    /// A selected ring grows in place — the same centre and a larger radius, so
    /// the ring beside it does not move.
    @Test("The ring under the pointer is larger")
    func selectedRingIsLarger() {
        let plain = draw(entry(used: 0.2)).fullCircles.max() ?? 0
        let selected = draw(entry(used: 0.2), isSelected: true).fullCircles.max() ?? 0
        #expect(abs(selected - plain * 1.06) < 0.001, "\(plain) became \(selected)")
    }

    /// **The SVG icons are drawn under the even-odd rule, and the mark under the
    /// nonzero one.** Most of the bundled logos draw a hole with a second
    /// outline, and under the wrong rule they are solid blobs.
    @Test("The fill rule is put back after an icon")
    func fillRuleIsRestored() {
        let canvas = draw(entry(used: 0.2))
        let rules = canvas.events.compactMap {
            if case .fillRule(let evenOdd) = $0 { return evenOdd }
            return nil
        }
        #expect(rules.contains(true), "the icon was not drawn even-odd")
        #expect(rules.last == false, "the fill rule was left on even-odd: \(rules)")
    }
}
