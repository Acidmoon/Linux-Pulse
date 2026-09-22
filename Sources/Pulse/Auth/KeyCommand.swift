import Foundation

/// `Pulse --set-key <provider>` and `--clear-key <provider>`: storing a pasted
/// key without the settings window.
///
/// Eleven of the twenty providers take a key the user pastes — Kimi Code,
/// DeepSeek, MiniMax, z.ai, OpenCode Go, Command Code and the rest — and every
/// one of them is entered through a field in Settings. That leaves a headless
/// install unable to configure any of them, which is the same shape of gap
/// `--refresh` exists to fill for `--json`: there is a command that uses the
/// credential and, until now, nothing outside the GUI that can provide one.
///
/// **The key is read from stdin, never from the argument list.** An argument is
/// visible in `ps` to every user on the machine and is written to shell history
/// by default; `gh auth login --with-token` reads from stdin for the same
/// reason, and that is the shape this follows:
///
///     pulse --set-key kimiCode
///     <paste, then Enter>
///
/// Nothing about the key is echoed back. It is written to `keys.dat` sealed
/// with this machine's identifier, and the command reports only which provider
/// it was for and whether it landed.
@MainActor
enum KeyCommand {
    nonisolated static let setArgument = "--set-key"
    nonisolated static let clearArgument = "--clear-key"

    /// Runs whichever of the two was asked for. Returns the process's exit code.
    static func run(argument: String) -> Int32 {
        guard let name = value(after: argument, in: CommandLine.arguments) else {
            note("""
            Pulse: \(argument) needs a provider.

            One of: \(Provider.allCases.map(\.rawValue).joined(separator: ", "))
            """)
            return 2
        }

        guard let provider = Provider(rawValue: name) else {
            // Named rather than silently ignored: a typo that reported success
            // would look exactly like a provider that never answers.
            note("Pulse: no provider called '\(name)'. Known providers: "
                + Provider.allCases.map(\.rawValue).joined(separator: ", "))
            return 2
        }

        guard provider.usesAPIKey else {
            // Copilot, the extra-account logins and the browser-session
            // providers are not keys, and accepting one would store something
            // nothing will ever read.
            note("""
            Pulse: \(provider.displayName) does not take a pasted key.

            \(reason(for: provider))
            """)
            return 2
        }

        if argument == clearArgument {
            return clear(provider)
        }
        return set(provider)
    }

    private static func clear(_ provider: Provider) -> Int32 {
        guard APIKeyStore.setKey(nil, for: provider) else {
            note("Pulse: couldn't clear the key for \(provider.displayName).")
            return 1
        }
        note("Pulse: cleared the key for \(provider.displayName).")
        return 0
    }

    private static func set(_ provider: Provider) -> Int32 {
        // A line, not the whole of stdin: this is meant to be typed into, and
        // waiting for EOF would mean a paste that looks like it did nothing
        // until the terminal is closed.
        guard let line = readLine(strippingNewline: true) else {
            note("Pulse: no key on standard input.")
            return 1
        }

        let key = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            note("Pulse: the key was empty, so nothing was stored.")
            return 1
        }

        guard APIKeyStore.setKey(key, for: provider) else {
            note("""
            Pulse: couldn't store the key for \(provider.displayName).

            The file is sealed with this machine's identifier, so this fails when
            that cannot be read rather than storing something unopenable.
            """)
            return 1
        }

        // Enabled as well, because a key for a provider nothing asks is a key
        // that does nothing. This is the one thing here that changes a setting
        // rather than storing a secret, and it is said out loud so the change
        // is not a surprise later.
        let settings = AppSettings.restored()
        let wasEnabled = settings.isEnabled(AccountKey(provider))
        if !wasEnabled {
            settings.enabledAccounts.insert(provider.rawValue)
            note("Pulse: stored the key for \(provider.displayName) and switched it on.")
        } else {
            note("Pulse: stored the key for \(provider.displayName).")
        }

        note("Run `pulse --refresh` to ask it.")
        return 0
    }

    /// The value after `argument`, if it is there and is not another flag.
    ///
    /// `in:` is a parameter rather than reading `CommandLine.arguments` directly
    /// so the parsing can be tested. It is the only part of this command that is
    /// pure, and it is also the part with a rule in it — see the leading-dash
    /// case below — which is exactly the combination worth a test.
    nonisolated static func value(after argument: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: argument) else { return nil }
        let next = arguments.index(after: index)
        guard next < arguments.endIndex else { return nil }
        let value = arguments[next]
        // Refusing a leading dash keeps `--set-key --clear-key kimiCode` from
        // reading `--clear-key` as a provider name.
        return value.hasPrefix("-") ? nil : value
    }

    private static func reason(for provider: Provider) -> String {
        switch provider {
        case .copilot:
            return "It takes a GitHub device login, kept in keys.dat — sign in from Settings."
        case .ollamaCloud, .xiaomiMiMo:
            return "It is read from a browser session, imported from Settings."
        case .cursor, .grokBot, .devin:
            return "It is read from another program's stored login, with an optional key in Settings."
        case .antigravity, .kiro:
            return "It is read from a helper that has to be running."
        default:
            return "It takes a credential Pulse has to obtain itself."
        }
    }

    /// Diagnostics go to stderr, so `pulse --set-key` can be used in a pipeline
    /// without its chatter becoming the pipeline's input.
    private static func note(_ text: String) {
        FileHandle.standardError.write(Data("\(text)\n".utf8))
    }
}
