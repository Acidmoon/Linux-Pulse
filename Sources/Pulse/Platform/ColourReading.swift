#if canImport(SwiftUI)
import SwiftUI
#endif
import Foundation

/// A colour's own numbers, asked for in sRGB.
///
/// **The one place the panel reaches for `NSColor`.** `BotMarkTint` measures a
/// brand colour's luminance and computes its hue, and neither is answerable
/// from a SwiftUI `Color` — so the Mac converts the colour and reads the
/// components off the result. Linux has no `NSColor`, and rather than write an
/// AppKit stub that would have to pretend about colour spaces, `Color` on Linux
/// simply keeps its components (`Platform/DrawingCompat.swift`).
///
/// Same source text either way, which is why this is a property on `Color`
/// rather than a free function: at the three call sites in `BotMarkTint` only
/// the expression after the `=` changes, and the surrounding logic — the floor,
/// the amount of white to mix in, the luminance weights — stays upstream's.
///
/// **Hue is the one real difference.** The Mac takes it from `NSColor`, which
/// converts through HSB; Linux computes the standard RGB→hue formula. Both
/// answer the same angle, and the only thing asked of it is how far apart two
/// brand colours are (`separation`), which either answers identically.
struct ColourReading: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    /// Degrees, 0…360.
    var hue: Double
}

#if !canImport(AppKit)
extension Color {
    /// "#RRGGBB", which is what a chosen colour is stored as.
    ///
    /// Upstream's copy of this lives in `Panel/UsageTint.swift` and goes via
    /// `NSColor(self).usingColorSpace(.sRGB)`, with a comment explaining that a
    /// colour picked in another space answers its components in that space and
    /// the numbers would not survive a round trip. A Linux `Color` has one
    /// space and stores its numbers, so there is no round trip to lose — and
    /// this is the same `String(format:)` on the far side.
    var hexString: String? {
        String(format: "#%02X%02X%02X",
               Int((red * 255).rounded()),
               Int((green * 255).rounded()),
               Int((blue * 255).rounded()))
    }
}
#endif

extension Color {
    /// Nil for a colour that has no sRGB answer. Only reachable through the
    /// AppKit path — a Linux `Color` always has components — and it exists
    /// because the upstream call sites all guard against it.
    var reading: ColourReading? {
        #if canImport(AppKit)
        guard let srgb = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        return ColourReading(red: srgb.redComponent,
                             green: srgb.greenComponent,
                             blue: srgb.blueComponent,
                             hue: Double(srgb.hueComponent) * 360)
        #else
        return ColourReading(red: red, green: green, blue: blue, hue: hueDegrees)
        #endif
    }

    #if !canImport(AppKit)
    /// The standard conversion, in degrees. Undefined — and reported as 0 —
    /// for a grey, where there is no hue to report: all three channels equal
    /// means no dominant one, which is the `max == min` case below.
    private var hueDegrees: Double {
        let maximum = max(red, green, blue), minimum = min(red, green, blue)
        let span = maximum - minimum
        guard span > 0 else { return 0 }
        let sector: Double
        if maximum == red {
            sector = ((green - blue) / span).truncatingRemainder(dividingBy: 6)
        } else if maximum == green {
            sector = (blue - red) / span + 2
        } else {
            sector = (red - green) / span + 4
        }
        let degrees = sector * 60
        return degrees < 0 ? degrees + 360 : degrees
    }
    #endif
}
