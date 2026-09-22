import Foundation

// Note the filename: Swift 6 rejects one target containing two files with
// the same name, and `App/GlobalShortcut.swift` holds the macOS half of this
// type. Renaming this back to `GlobalShortcut.swift` does not build.

/// A key combination Pulse answers to from anywhere, not only while it is the
/// active application.
///
/// Stored rather than hardcoded, and unset until someone sets one: a default
/// combination is a key taken out of every other app's hands on behalf of a
/// person who never asked for it, and there is no combination free enough to
/// take that way.
///
/// **The value is portable; registering it is not.** A key code and a set of
/// modifier bits are what gets stored, and both fit in a short string, so
/// `AppSettings` can hold one on any platform. What differs is what those
/// numbers *mean*: macOS virtual key codes are positions on an Apple keyboard
/// and have nothing in common with X11 keycodes, and the modifier bits here are
/// AppKit's. So this type is deliberately about the container and its encoding,
/// not about the key — see `App/GlobalShortcut.swift` for the AppKit spelling
/// and the Carbon registration. Linux will need its own mapping when X11
/// key grabbing lands in roadmap phase 3, and a value parsed from a macOS
/// settings file will not name the same physical key there.
struct GlobalShortcut: Equatable, Hashable, Sendable {
    /// The virtual key code, which is a position on the keyboard rather than a
    /// character — the same physical key on every layout.
    let keyCode: UInt16
    /// The modifier bits, already filtered to the four this can register. Kept
    /// as bits rather than as `NSEvent.ModifierFlags` so the whole value stays
    /// `Sendable` on every platform and can be written to `UserDefaults` as one
    /// short string.
    let modifierBits: UInt

    /// Nil when the combination is not one Pulse is willing to take.
    init?(keyCode: UInt16, modifierBits: UInt) {
        let kept = modifierBits & Self.allowedBits
        guard kept & Self.requiredBits != 0 else { return nil }
        self.keyCode = keyCode
        self.modifierBits = kept
    }

    // MARK: - The four modifiers, as bits

    // Written out as literals rather than derived from `NSEvent.ModifierFlags`,
    // which does not exist on Linux. They are AppKit's own values and this is
    // the only place they appear: `App/GlobalShortcut.swift` builds its
    // `NSEvent.ModifierFlags` back out of these, so the two spellings cannot
    // drift apart.

    static let shiftBit: UInt = 1 << 17
    static let controlBit: UInt = 1 << 18
    static let optionBit: UInt = 1 << 19
    static let commandBit: UInt = 1 << 20

    /// What may be part of a combination.
    static let allowedBits: UInt = shiftBit | controlBit | optionBit | commandBit

    /// At least one of these has to be in it.
    ///
    /// Shift alone is not a modifier for this purpose — `⇧P` would take the
    /// letter P away from every text field on the Mac, which is a bug report
    /// from someone who cannot type their own name. Bare keys are refused for
    /// the same reason, function keys included: F1 already belongs to the
    /// display's brightness.
    static let requiredBits: UInt = controlBit | optionBit | commandBit

    // MARK: - Storage

    var storage: String { "\(keyCode):\(modifierBits)" }

    /// A stored value that no longer parses — written by a version that stored
    /// them differently, or edited by hand — reads as no shortcut rather than
    /// as a wrong one. The combination is re-validated on the way in, so a
    /// stored value naming no required modifier is refused here too.
    init?(storage: String) {
        let parts = storage.split(separator: ":")
        guard parts.count == 2,
              let keyCode = UInt16(parts[0]),
              let bits = UInt(parts[1])
        else { return nil }
        self.init(keyCode: keyCode, modifierBits: bits)
    }
}
