#if !canImport(AppKit)
import Foundation

/// The detail card: the panel beside the rail that says what a ring is showing.
///
/// **A port of `UsageDetailCard` and `ProgressMetricRow`**, and its shape is
/// upstream's too — `UsageBubbleShape` is the same silhouette with the tail
/// cut into the side that faces the rail, and it came out of that file with
/// nothing changed but its imports. What is re-derived is the placement: the
/// card's position beside the ring, its clamp against the panel's edges, and
/// the tail's own position along the card's edge so it keeps aiming at the ring
/// even when the card has been pushed away from centre.
///
/// Everything inside it is a number from `DetailCardLayout` — the width, the
/// padding, the corner radius, the tail's size, the font sizes, the bar height
/// — so the card that appears here is the size and shape of the card that
/// appears on a Mac.
@MainActor
enum PanelCardRenderer {
    /// Draws the card for the selected ring, if there is one. Called after the
    /// rail so the card's tail laps over the rail's edge, as it does upstream.
    @MainActor
    static func draw(_ entry: RailEntry, index: Int, model: PanelModel,
                     into canvas: PanelCanvas) {
        let windows = entry.usage.windows
        let message = bodyMessage(entry.usage)
        let footnote = footnote(entry.usage)
        let rows = max(windows.count, 1)
        let height = DetailCardLayout.height(forWindows: windows.isEmpty ? 0 : windows.count,
                                             footnote: footnote != nil)
        let width = DetailCardLayout.width
        // The rail-facing side carries the tail, so the bubble is wider than the
        // content by exactly that.
        let bubbleSize = CGSize(width: width + DetailCardLayout.pointerWidth, height: height)

        // **To the left of a right-hand rail, and just clear of it.** The inset
        // is the card, the tail and the gap between them, which is what
        // `DetailCardLayout.horizontalGap` is for.
        let rail = model.railRect
        let inset = width + DetailCardLayout.pointerWidth + DetailCardLayout.horizontalGap
        let ring = model.railCentre(index)
        let edge = model.edge
        let origin = CGPoint(
            x: edge == .left ? rail.maxX + DetailCardLayout.horizontalGap : rail.minX - inset,
            y: min(max(ring.y - height / 2, 0), max(model.panelSize.height - height, 0)))

        // Where the tail's tip sits along the card's rail-facing edge: the
        // ring's centre expressed in the card's own space, and kept clear of the
        // rounded corners by one of them.
        let clearance = DetailCardLayout.cornerRadius + DetailCardLayout.pointerHeight / 2
        let along = min(max(ring.y - origin.y, clearance),
                        max(height - clearance, clearance))

        canvas.save()
        canvas.translate(x: origin.x, y: origin.y)
        let bubble = UsageBubbleShape(edge: edge, pointerCenter: along,
                                      cornerRadius: DetailCardLayout.cornerRadius,
                                      pointerWidth: DetailCardLayout.pointerWidth,
                                      pointerHeight: DetailCardLayout.pointerHeight)
        // Origin at zero, like every other `Shape`: `path(in:)` is SwiftUI's,
        // and upstream reads it as the view's own frame. See
        // `PanelRailRenderer`'s note on the berth.
        canvas.emit(bubble.path(in: CGRect(origin: .zero, size: bubbleSize)).cgPath)
        canvas.fill(.black, opacity: 1)
        canvas.restore()

        // The content, inset from the bubble by the tail's width on the
        // rail-facing side and by the padding everywhere else.
        let padding = DetailCardLayout.padding
        var pen = CGPoint(x: origin.x + padding
                            + (edge == .left ? DetailCardLayout.pointerWidth : 0),
                          y: origin.y + padding)
        let textLeft = pen.x
        let textWidth = width - padding * 2

        // MARK: Header

        // **Upstream's own vertical rhythm, to the point.** `DetailCardLayout`
        // states the card's height as `padding*2 + headerHeight + count *
        // (contentSpacing + rowHeight)`, where a row is a title line, a bar and
        // a figures line with `rowInternalSpacing` between them — so laying the
        // content out in those same units is what makes it fit the height the
        // card was measured for. The first version used the font sizes times
        // 1.4 and the rows ran into each other and past the bottom edge.
        let line = DetailCardLayout.rowTextLineHeight
        let iconSize = DetailCardLayout.headerIconSize

        if let icon = SVGIcon.icon(named: entry.usage.provider.iconResource) {
            draw(icon, into: canvas, at: CGPoint(x: textLeft + iconSize / 2,
                                                 y: pen.y + DetailCardLayout.headerHeight / 2),
                 size: iconSize, colour: .primary, opacity: 1)
        }
        let title = entry.title.isEmpty ? entry.usage.provider.displayName : entry.title
        let heading = String.localized("\(title) Usage")
        canvas.text(heading,
                    centre: CGPoint(x: textLeft + iconSize + 8
                                    + measured(heading, size: DetailCardLayout.titleFontSize,
                                               canvas: canvas) / 2,
                                    y: pen.y + DetailCardLayout.headerHeight / 2),
                    size: DetailCardLayout.titleFontSize, colour: .primary, opacity: 1,
                    bold: true)
        pen.y += DetailCardLayout.headerHeight + DetailCardLayout.contentSpacing

        // MARK: The limits, one row each

        for window in windows {
            let spent = UsageTint.isSpent(window)
            let accent = UsageTint.color(for: window.usedFraction, isExhausted: spent,
                                         warningAt: UsageTint.warningThreshold)
            let fraction = entry.showsRemaining ? window.remainingFraction : window.usedFraction
            let figure = window.percentText(remaining: entry.showsRemaining)

            canvas.text(window.name,
                        centre: CGPoint(x: textLeft
                                        + measured(window.name, size: DetailCardLayout.rowFontSize,
                                                   canvas: canvas) / 2,
                                        y: pen.y + line / 2),
                        size: DetailCardLayout.rowFontSize, colour: .primary, opacity: 1,
                        bold: false)
            pen.y += line + DetailCardLayout.rowInternalSpacing

            // `Capsule().fill(...)` twice: a track, then the accent over it.
            let barHeight = DetailCardLayout.progressBarHeight
            let used = min(max(fraction, 0), 1)
            canvas.emit(CGPath(roundedRect: CGRect(x: textLeft, y: pen.y,
                                                   width: textWidth, height: barHeight),
                               cornerWidth: barHeight / 2, cornerHeight: barHeight / 2,
                               transform: nil))
            canvas.fill(.primary, opacity: 0.17)
            if used > 0 {
                let barWidth = max(textWidth * used, barHeight)
                canvas.emit(CGPath(roundedRect: CGRect(x: textLeft, y: pen.y,
                                                       width: barWidth, height: barHeight),
                                   cornerWidth: barHeight / 2, cornerHeight: barHeight / 2,
                                   transform: nil))
                canvas.fill(spent ? .pulseExhausted : accent, opacity: 1)
            }
            pen.y += barHeight + DetailCardLayout.rowInternalSpacing

            // **The word follows the figure.** Upstream caught this: the label
            // said "Used" whichever way the number was counted, so a limit 88%
            // gone read "12% Used" on the card while the rail beside it said
            // "12% left".
            let word = entry.showsRemaining
                ? String.localized("\(figure) Left") : String.localized("\(figure) Used")
            canvas.text(word,
                        centre: CGPoint(x: textLeft
                                        + measured(word, size: DetailCardLayout.rowFontSize,
                                                   canvas: canvas) / 2,
                                        y: pen.y + line / 2),
                        size: DetailCardLayout.rowFontSize,
                        colour: spent ? .pulseExhausted : .primary,
                        opacity: spent ? 1 : 0.75, bold: false)
            let reset = resetText(window)
            if !reset.isEmpty {
                canvas.text(reset,
                            centre: CGPoint(x: textLeft + textWidth
                                            - measured(reset, size: DetailCardLayout.footnoteFontSize,
                                                       canvas: canvas) / 2,
                                            y: pen.y + line / 2),
                            size: DetailCardLayout.footnoteFontSize, colour: .primary,
                            opacity: 0.55, bold: false)
            }
            pen.y += line + DetailCardLayout.contentSpacing
        }

        // MARK: The body, when there are no limits to draw

        if let message {
            canvas.text(message,
                        centre: CGPoint(x: textLeft + measured(message, size: DetailCardLayout.messageFontSize,
                                                               canvas: canvas) / 2,
                                        y: pen.y + line / 2),
                        size: DetailCardLayout.messageFontSize, colour: .primary,
                        opacity: 0.55, bold: false)
            pen.y += line + DetailCardLayout.contentSpacing
        }

        // **A card with only a title in it reads as a card that failed to
        // load.** DeepSeek on "balance only" reports money and no limits by
        // design, and the money is then the whole reading.
        if let balance = entry.usage.creditBalance, windows.isEmpty {
            let label = String.localized("Credit balance")
            canvas.text(label,
                        centre: CGPoint(x: textLeft
                                        + measured(label, size: DetailCardLayout.rowFontSize,
                                                   canvas: canvas) / 2,
                                        y: pen.y + line / 2),
                        size: DetailCardLayout.rowFontSize, colour: .primary, opacity: 0.75,
                        bold: false)
            canvas.text(balance,
                        centre: CGPoint(x: textLeft + textWidth
                                        - measured(balance, size: DetailCardLayout.rowFontSize,
                                                   canvas: canvas) / 2,
                                        y: pen.y + line / 2),
                        size: DetailCardLayout.rowFontSize, colour: .primary, opacity: 1,
                        bold: true)
            pen.y += line + DetailCardLayout.contentSpacing
        }

        if let footnote {
            canvas.text(footnote,
                        centre: CGPoint(x: textLeft
                                        + measured(footnote, size: DetailCardLayout.footnoteFontSize,
                                                   canvas: canvas) / 2,
                                        y: pen.y + line / 2),
                        size: DetailCardLayout.footnoteFontSize, colour: .primary,
                        opacity: 0.4, bold: false)
        }
    }

    // MARK: - Upstream's own text rules

    /// A line under the limits saying how much to trust them. Claude Code's
    /// figures only refresh while a session is running, so an old reading has to
    /// say so rather than pass for current.
    private static func footnote(_ usage: ProviderUsage) -> String? {
        switch usage.state {
        case .live, .unavailable:
            return nil
        case .stale:
            guard let observed = usage.observedAt else {
                return String.localized("Reading may be out of date")
            }
            return String.localized("As of \(relative(observed))")
        }
    }

    /// "2 minutes ago", written here because **swift-corelibs-foundation has no
    /// relative formatter**: `RelativeDateTimeFormatter` is absent and
    /// `DateComponentsFormatter` is explicitly marked unavailable. Upstream's
    /// line comes from the first of those.
    ///
    /// **This is the one piece of the card's text that is not upstream's code.**
    /// It is one sentence, on a line only a stale reading ever shows, and the
    /// alternative is building a date formatter for it — which would be more
    /// code saying the same thing less clearly.
    private static func relative(_ date: Date) -> String {
        let seconds = max(Date().timeIntervalSince(date), 0)
        let minute = 60.0, hour = 3600.0, day = 86_400.0
        guard seconds >= minute else { return String.localized("just now") }
        let (value, unit): (Double, String) = if seconds < hour {
            (seconds / minute, "minute")
        } else if seconds < day {
            (seconds / hour, "hour")
        } else {
            (seconds / day, "day")
        }
        let count = Int(value.rounded())
        return String.localized("\(count) \(unit)\(count == 1 ? "" : "s") ago")
    }

    /// **A card with only a title in it reads as a card that failed to load.**
    /// So a reading that says nothing at all still has to say *that*, and an
    /// unavailable one says which route failed instead.
    private static func bodyMessage(_ usage: ProviderUsage) -> String? {
        if case .unavailable(let reason) = usage.state { return reason.message }
        guard usage.windows.isEmpty, usage.creditBalance == nil else { return nil }
        return ProviderUsage.Unavailability.noLimitsReported.message
    }

    /// When a limit comes back, or how long it is when the provider said so and
    /// nothing more.
    ///
    /// **The fallback may only state a length the provider stated.**
    /// `windowSeconds` is sometimes a sort key rather than a measurement —
    /// Cursor's billing cycle stored as a flat 30 days, Kimi's rolling weekly
    /// allowance — and printing one here would put a figure nobody reported on
    /// the card, under a heading that reads like a reported one.
    private static func resetText(_ window: UsageWindow) -> String {
        guard let resets = window.resetsAt else {
            return window.reportsLength ? window.lengthText : ""
        }
        let formatter = DateFormatter()
        formatter.locale = LocalizationSource.locale
        formatter.setLocalizedDateFormatFromTemplate(
            Calendar.current.isDateInToday(resets) ? "jmm" : "MMMdjmm")
        return String.localized("Resets \(formatter.string(from: resets))")
    }

    // MARK: - Drawing helpers

    /// How wide a string will be, from the backend that will draw it. A local
    /// estimate would drift further off the longer the text, and this is a card
    /// whose whole content is a few short strings.
    private static func measured(_ text: String, size: Double, canvas: PanelCanvas) -> Double {
        canvas.measure(text, size: size, bold: false)
    }

    /// The icon, template-filled, exactly as the rail draws it.
    private static func draw(_ icon: SVGIcon.Icon, into canvas: PanelCanvas, at centre: CGPoint,
                             size: Double, colour: Color, opacity: Double) {
        let scale = min(size / icon.viewBox.width, size / icon.viewBox.height)
        let drawn = CGSize(width: icon.viewBox.width * scale, height: icon.viewBox.height * scale)
        canvas.save()
        canvas.translate(x: centre.x - drawn.width / 2 - icon.viewBox.minX * scale,
                         y: centre.y - drawn.height / 2 - icon.viewBox.minY * scale)
        canvas.setFillRule(evenOdd: icon.evenOdd)
        canvas.emit(CGPath(commands: icon.commands),
                    transform: CGAffineTransform(scaleX: scale, y: scale))
        canvas.fill(colour, opacity: opacity)
        canvas.restore()
        canvas.setFillRule(evenOdd: false)
    }


}
#endif
