#if !canImport(AppKit)
import Foundation

/// `--enable` and `--disable`: which providers the rail shows.
///
/// **`--json` reports the rail, and until now nothing set it.** The panel's
/// contents live in `settings.enabledProviders`, and the only ways to change
/// them were the Settings window — which is macOS-only — or editing
/// `~/.config/Pulse.plist` by hand. So "how do I show Kimi?" had no answer that
/// belonged to the program, which is not a thing to leave in a port of a
/// program whose whole job is to show you something.
///
/// It sits beside `--set-key` deliberately, and is the same shape: a command
/// that changes one setting and says what it did. `--set-key` enables the
/// provider it stored a key for, because a key for something switched off is a
/// step nobody wanted — this is for the providers that need no key at all.
enum ProviderCommand {
    static let enableArgument = "--enable"
    static let disableArgument = "--disable"

    /// Nil when neither argument is present, so the caller can fall through to
    /// the next mode.
    static func run(argument: String) -> Int32? {
        guard argument == enableArgument || argument == disableArgument else { return nil }
        guard let name = CommandLine.arguments.last, !name.hasPrefix("-") else {
            note(missingName(argument))
            return 2
        }
        return set(name: name, enabled: argument == enableArgument)
    }

    /// **The name is a parameter, not read from `CommandLine`.** The first
    /// version reached for `CommandLine.arguments.last` inside, which meant the
    /// only way to test what happened with a bad name was to be a process with a
    /// bad name — so that path was untested by construction, and a test that
    /// tried returned the wrong answer for reasons the test could not see.
    static func set(name: String, enabled: Bool) -> Int32 {
        // **Case-insensitively, and by display name too.** The raw values are
        // camel case — `kimiCode`, `openCodeGo` — and asking somebody to
        // remember which letters are capitalised is a way to make a command
        // annoying for no reason. "Kimi Code" is what the settings list shows,
        // so it works as well.
        let wanted = name.lowercased()
        guard let provider = Provider(rawValue: name) ?? Provider.allCases.first(where: {
            $0.rawValue.lowercased() == wanted || $0.displayName.lowercased() == wanted
        }) else {
            note("Pulse: no provider called \(name).\n\n" + list())
            return 2
        }

        let settings = AppSettings.restored()
        let account = AccountKey(provider)
        settings.setEnabled(enabled, for: account)

        guard settings.shownAccounts.contains(account) == enabled else {
            // `setEnabled` can refuse: an account whose provider needs a choice
            // it has not been given cannot be switched on. Saying so beats
            // reporting success and showing nothing.
            note("Pulse: \(provider.displayName) could not be switched "
                 + "\(enabled ? "on" : "off").")
            return 1
        }

        print("\(provider.displayName) \(enabled ? "on" : "off") — "
              + "\(settings.shownAccounts.count) on the rail")
        return 0
    }

    private static func missingName(_ argument: String) -> String {
        """
        Pulse: \(argument) needs a provider name.

          pulse \(argument) <provider>

        \(list())
        """
    }

    /// Every provider, with whether it is on the rail and whether it has a
    /// reading — which is the question somebody running `--enable` is really
    /// asking: *why is that ring empty?*
    static func list() -> String {
        let settings = AppSettings.restored()
        let enabled = Set(settings.shownAccounts.map(\.id))
        let rows = Provider.allCases.map { provider in
            let on = enabled.contains(provider.rawValue) ? "●" : "○"
            return "  \(on) \(provider.rawValue.padding(toLength: 16, withPad: " ", startingAt: 0))"
                + provider.displayName
        }
        return (["  ● on the rail   ○ switched off", ""] + rows).joined(separator: "\n")
    }

    private static func note(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}
#endif
