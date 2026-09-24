// pulse-linux: excluded — there is no separate panel process to signal on
// macOS, and the panel's own Settings window sets these.
#if !canImport(AppKit)
import Foundation

#if canImport(Glibc)
import Glibc
#endif

/// The panel itself: where it sits, whether it comes back, and how to stop it.
///
/// **Why this is a command and not a window.** The macOS version sets all of
/// this in a Settings window. There is no such window on Linux, so the only way
/// to change any of it was to edit `~/.config/Pulse.plist` by hand and then kill
/// the panel, because nothing re-reads the file. That is a poor answer from a
/// program whose job is to be looked at, and it is the answer a reader got when
/// they asked how to move it.
///
/// A window is still the eventual answer for the things a *sentence* cannot say
/// — which rings, in what order. What is here is for the settings a sentence
/// can say in a word, which is most of what anybody changes.
enum PanelCommand {
    static let placeArgument = "--place"
    static let positionArgument = "--position"
    static let autostartArgument = "--autostart"
    static let quitArgument = "--quit"
    static let collapseArgument = "--auto-collapse"
    static let remainingArgument = "--shows-remaining"

    /// The arguments this command owns, so the entry point can ask whether any
    /// of them is present without knowing how many there are.
    static let arguments = [placeArgument, positionArgument, autostartArgument, quitArgument,
                            collapseArgument, remainingArgument]

    /// Whether this command owns an argument, **without doing anything about
    /// it**.
    ///
    /// Split out because the entry point needs only the question, and a test
    /// that asked it by calling `run` was not asking a question at all: the
    /// first version of the test did exactly that over every argument in the
    /// list — including `--quit`, which sent `SIGTERM` to whatever pid file the
    /// machine had. It killed the reader's running panel. A predicate that can
    /// kill a process is not a predicate.
    static func claims(_ argument: String) -> Bool { arguments.contains(argument) }

    static func run(argument: String) -> Int32? {
        guard claims(argument) else { return nil }
        switch argument {
        case placeArgument: return place()
        case positionArgument: return position()
        case autostartArgument: return autostart()
        case quitArgument: return quit()
        case collapseArgument: return setCollapse()
        case remainingArgument: return setRemaining()
        default: return nil
        }
    }

    /// `pulse --place left`. `float` is the fourth answer and not an edge: a
    /// floating panel is the one that is not against anything.
    private static func place() -> Int32 {
        guard let word = value(after: placeArgument) else { return missing(placeArgument, "<left|right|top|float>") }

        let dock: PanelDock
        switch word.lowercased() {
        case "left": dock = .edge(.left)
        case "right": dock = .edge(.right)
        case "top": dock = .edge(.top)
        case "float", "floating": dock = .floating
        default:
            note("Pulse: \\(word) is not a place. Try left, right, top or float.")
            return 2
        }

        var placement = PanelPlacement.restored()
        placement.record(dock: dock,
                         horizontalRatio: placement.horizontalRatio,
                         verticalRatio: placement.verticalRatio,
                         display: placement.display)
        print("Pulse: \(describe(placement))")
        return tellRunningPanel()
    }

    /// `pulse --position 0.5` — where along the edge it is, 0 at the start and 1
    /// at the end.
    ///
    /// **One number, because only one of the two ratios is ever in play.** A
    /// docked panel is pinned on the axis it is docked to and centred on the
    /// other, so a left-hand rail has exactly one degree of freedom and its name
    /// is the vertical ratio. A floating panel is the case where both matter;
    /// `--position` sets the vertical one there, which is the one somebody means
    /// when they say "in the middle", and the horizontal ratio keeps whatever
    /// the settings file has.
    private static func position() -> Int32 {
        guard let word = value(after: positionArgument), let number = Double(word) else {
            return missing(positionArgument, "<0.0-1.0>")
        }
        guard (0...1).contains(number) else {
            // Out of range is refused rather than clamped, because a reader who
            // typed `--position 50` means half way and a reader who typed
            // `--position 5` means something this cannot guess.
            note("Pulse: \\(word) is not between 0 and 1.")
            return 2
        }

        var placement = PanelPlacement.restored()
        // **Non-optional, and it answers for a floating panel too** — it
        // reports which half of the screen the rail is in, which is what decides
        // which way the card unfolds. So the axis is always known.
        let onVerticalAxis = placement.edge.isVertical
        placement.record(dock: placement.dock,
                         horizontalRatio: onVerticalAxis ? placement.horizontalRatio : number,
                         verticalRatio: onVerticalAxis ? number : placement.verticalRatio,
                         display: placement.display)
        print("Pulse: \(describe(placement))")
        return tellRunningPanel()
    }

    /// `pulse --auto-collapse off`, which is the one that decides whether there
    /// is anything to look at.
    ///
    /// **Collapsed is the default and it hides everything.** Docked and
    /// auto-collapsing, the rail rests at `openness` 0 — a 64-pixel sliver of
    /// background with no ring and no figure on it, which is the macOS app's
    /// behaviour and reads as a bug the first time somebody sees it: a thin dark
    /// line at the edge of the screen and no indication that their quota is
    /// behind it. Upstream puts this in the Settings window. There is no
    /// Settings window, and the person who asked why they could not see their
    /// usage had to be told to edit a plist — which is the answer this command
    /// exists to stop being necessary.
    private static func setCollapse() -> Int32 {
        guard let enabled = boolean(after: collapseArgument) else {
            return missing(collapseArgument, "<on|off>")
        }
        let settings = AppSettings.restored()
        settings.autoCollapse = enabled
        PulseDefaults.shared.synchronize()
        print(enabled
              ? "Pulse: the rail collapses to the edge until you point at it."
              : "Pulse: the rail stays open — every ring and its figure on screen.")
        return tellRunningPanel()
    }

    /// `pulse --shows-remaining on` — whether a ring reads what is left or what
    /// has been used. Both are the same number seen from either end, and which
    /// one a reader wants is not something to guess at.
    private static func setRemaining() -> Int32 {
        guard let enabled = boolean(after: remainingArgument) else {
            return missing(remainingArgument, "<on|off>")
        }
        let settings = AppSettings.restored()
        settings.showsRemaining = enabled
        PulseDefaults.shared.synchronize()
        print(enabled
              ? "Pulse: rings show what is left."
              : "Pulse: rings show what has been used.")
        return tellRunningPanel()
    }

    /// `on`/`off` and the usual synonyms, or `nil` for anything else — so a
    /// mistyped value is refused rather than read as `false`, which is what
    /// `Bool.init(_:)`-style parsing does to it.
    private static func boolean(after argument: String) -> Bool? {
        guard let word = value(after: argument) else { return nil }
        switch word.lowercased() {
        case "on", "yes", "true", "1": return true
        case "off", "no", "false", "0": return false
        default: return nil
        }
    }

    private static func autostart() -> Int32 {
        guard let word = value(after: autostartArgument) else { return missing(autostartArgument, "<on|off>") }
        switch word.lowercased() {
        case "on", "yes", "true":
            guard LinuxLoginItem.setEnabled(true) else {
                note("Pulse: could not write \(LinuxLoginItem.fileURL.path). "
                     + "Is PulsePanel next to this binary?")
                return 1
            }
            print("Pulse: starts at login — \(LinuxLoginItem.fileURL.path)")
            return 0
        case "off", "no", "false":
            LinuxLoginItem.setEnabled(false)
            print("Pulse: does not start at login")
            return 0
        default:
            note("Pulse: \\(word) is not on or off.")
            return 2
        }
    }

    /// `pulse --quit`, which is the polite version of `pkill -x PulsePanel`.
    ///
    /// The panel removes its own pid file on the way out, so this is also the
    /// thing that leaves no litter behind. Exit code 1 when nothing was running,
    /// because "I stopped it" and "there was nothing to stop" are different
    /// answers and a script may care.
    private static func quit() -> Int32 {
        guard PanelProcess.send(SIGTERM) else {
            print("Pulse: the panel is not running.")
            return 1
        }
        print("Pulse: stopping the panel.")
        return 0
    }

    /// **Tells a running panel to read its settings again.**
    ///
    /// Without this a placement change means killing the panel and starting it,
    /// which loses the rail's readings and its animation for no reason — the
    /// panel is perfectly capable of moving; it simply had not been asked.
    /// Exit code 0 either way: the settings were written, which is what the
    /// command is for, and a panel that is not running will read them when it
    /// starts.
    private static func tellRunningPanel() -> Int32 {
        if PanelProcess.send(SIGUSR1) { return 0 }
        print("Pulse: it will be in place the next time the panel starts.")
        return 0
    }

    /// The word after an argument, or `nil` when it is missing or is the next
    /// option — `pulse --place --quit` names no place.
    private static func value(after argument: String) -> String? {
        let words = CommandLine.arguments
        guard let index = words.lastIndex(of: argument), index + 1 < words.count else { return nil }
        let value = words[index + 1]
        return value.hasPrefix("--") ? nil : value
    }

    /// Says something on stderr, so it is not mistaken for the answer a pipe
    /// wanted. The same shape `ProviderCommand` uses.
    private static func note(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    /// What `--help` prints for these, kept here so the list cannot drift from
    /// the arguments the command answers to.
    static var usageLines: String {
        """
          \(placeArgument) <edge>       left, right, top, or float
          \(positionArgument) <0.0-1.0> where along that edge it sits,
                                 0 at the start, 0.5 centred, 1 at the end
          \(collapseArgument) <on|off>  whether the rail hides at the screen edge
                                 until you point at it (on by default)
          \(remainingArgument) <on|off> whether a ring reads what is left
                                 or what has been used
          \(autostartArgument) <on|off> start it at login
          \(quitArgument)               stop it
        """
    }

    private static func missing(_ argument: String, _ shape: String) -> Int32 {
        note("""
        Pulse: \(argument) needs a value.

          pulse \(argument) \(shape)
        """)
        return 2
    }

    /// A sentence for what was just set, because "Pulse: ok" leaves a reader
    /// looking at a panel that did not visibly move wondering which of the two
    /// happened.
    private static func describe(_ placement: PanelPlacement) -> String {
        let where_ = placement.isDocked
            ? "docked to the \(placement.edge.rawValue) edge"
            : "floating"
        let percent = Int((placement.edge.isVertical
                           ? placement.verticalRatio : placement.horizontalRatio) * 100)
        return "\(where_), \(percent)% along it."
    }
}
#endif
