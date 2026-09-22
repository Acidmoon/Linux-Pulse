import Testing
@testable import Pulse

/// The portable half of `GlobalShortcut`.
///
/// `GlobalShortcutTests` covers the same type through its AppKit spelling —
/// `NSEvent.ModifierFlags`, `.display`, `.carbonModifiers` — and is excluded
/// from the Linux build with everything else that needs AppKit. The value and
/// its storage encoding were split out precisely so that `AppSettings` can hold
/// one on any platform, so they need coverage that runs on both; otherwise the
/// split would be verified on macOS alone.
///
/// The modifier literals here are the raw bits rather than `[.command]`
/// because those are what the portable type actually stores. That the bit
/// values match AppKit's is asserted from the AppKit side, in the file that can
/// see AppKit, and is what keeps the two spellings from drifting apart.
@Suite("Shortcut value")
struct ShortcutValueTests {
    /// The letter P on a US layout, which is the key upstream's own tests use.
    private static let p: UInt16 = 35

    @Test("At least one of command, option or control is required")
    func requiredModifier() {
        #expect(GlobalShortcut(keyCode: Self.p, modifierBits: 0) == nil)
        #expect(GlobalShortcut(keyCode: Self.p, modifierBits: GlobalShortcut.shiftBit) == nil)

        #expect(GlobalShortcut(keyCode: Self.p, modifierBits: GlobalShortcut.commandBit) != nil)
        #expect(GlobalShortcut(keyCode: Self.p, modifierBits: GlobalShortcut.optionBit) != nil)
        #expect(GlobalShortcut(keyCode: Self.p, modifierBits: GlobalShortcut.controlBit) != nil)
        #expect(GlobalShortcut(
            keyCode: Self.p,
            modifierBits: GlobalShortcut.shiftBit | GlobalShortcut.commandBit
        ) != nil)
    }

    @Test("Bits outside the four are dropped rather than stored")
    func unknownBitsAreFiltered() {
        // Caps lock, function and the numeric-pad flag are all real modifier
        // bits AppKit defines and none of them may be registered. They arrive
        // here whenever a recorder hands over a raw `NSEvent.modifierFlags`.
        let capsLock: UInt = 1 << 16
        let function: UInt = 1 << 23
        let numericPad: UInt = 1 << 21

        let shortcut = GlobalShortcut(
            keyCode: Self.p,
            modifierBits: GlobalShortcut.commandBit | capsLock | function | numericPad
        )
        #expect(shortcut?.modifierBits == GlobalShortcut.commandBit)
    }

    @Test("Storage round-trips")
    func storageRoundTrip() {
        let shortcut = GlobalShortcut(
            keyCode: Self.p,
            modifierBits: GlobalShortcut.commandBit | GlobalShortcut.optionBit | GlobalShortcut.shiftBit
        )
        #expect(shortcut != nil)
        #expect(GlobalShortcut(storage: shortcut!.storage) == shortcut)
    }

    @Test("A stored value that no longer parses reads as no shortcut")
    func storageRejectsGarbage() {
        // Written by a version that stored them differently, or edited by hand.
        //
        // Falling back to nil rather than to a wrong combination is the whole
        // point: a shortcut the user did not choose would take a key away from
        // every other application.
        #expect(GlobalShortcut(storage: "") == nil)
        #expect(GlobalShortcut(storage: "35") == nil)
        #expect(GlobalShortcut(storage: "35:1:2") == nil)
        #expect(GlobalShortcut(storage: "notanumber:1048576") == nil)
        #expect(GlobalShortcut(storage: "35:notanumber") == nil)
    }

    @Test("A stored value is re-validated on the way in")
    func storageRevalidates() {
        // `35:0` is well-formed and names no required modifier. The rule is
        // applied to what comes off disk too, not only to what a recorder
        // produces — otherwise a hand-edited file could install a bare key.
        #expect(GlobalShortcut(storage: "35:0") == nil)
        #expect(GlobalShortcut(storage: "35:\(GlobalShortcut.shiftBit)") == nil)
        #expect(GlobalShortcut(storage: "35:\(GlobalShortcut.commandBit)") != nil)
    }

    @Test("The filter the AppKit spelling builds from is the one that runs")
    func filterUsesTheSharedBits() {
        // `App/GlobalShortcut.swift` constructs its `NSEvent.ModifierFlags`
        // from `allowedBits` and `requiredBits` rather than restating AppKit's
        // numbers. This pins the values the rest of the type depends on, so a
        // change here is a change the AppKit side sees rather than a second
        // definition it can disagree with.
        #expect(GlobalShortcut.allowedBits
            == GlobalShortcut.shiftBit | GlobalShortcut.controlBit
                | GlobalShortcut.optionBit | GlobalShortcut.commandBit)
        #expect(GlobalShortcut.requiredBits
            == GlobalShortcut.controlBit | GlobalShortcut.optionBit | GlobalShortcut.commandBit)
        #expect(GlobalShortcut.requiredBits & GlobalShortcut.shiftBit == 0)
        #expect(GlobalShortcut.requiredBits & GlobalShortcut.allowedBits == GlobalShortcut.requiredBits)
    }
}
