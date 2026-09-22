import Testing

@testable import Pulse

/// `--set-key` / `--clear-key` argument parsing.
///
/// Only the parsing. Storing is covered by `LocalSecretsTests`, which drives the
/// same `APIKeyStore` through a round trip — and running the command itself here
/// would read the real stdin and write the real `keys.dat`, so a test that
/// called `run` would be configuring the machine running the suite.
@Suite("Key command arguments")
struct KeyCommandTests {
    private static let pulse = "/usr/local/bin/Pulse"

    @Test("The provider after the flag is read")
    func readsTheProvider() {
        #expect(KeyCommand.value(after: "--set-key", in: [Self.pulse, "--set-key", "kimiCode"])
            == "kimiCode")
        #expect(KeyCommand.value(after: "--clear-key", in: [Self.pulse, "--clear-key", "deepSeek"])
            == "deepSeek")
    }

    @Test("A flag with nothing after it reads as nothing")
    func missingValue() {
        #expect(KeyCommand.value(after: "--set-key", in: [Self.pulse, "--set-key"]) == nil)
        #expect(KeyCommand.value(after: "--set-key", in: [Self.pulse]) == nil)
    }

    /// A leading dash is refused rather than taken as a provider name, so
    /// `--set-key --clear-key kimiCode` does not report "no provider called
    /// '--clear-key'" — and, worse, does not go looking for a key on stdin.
    @Test("Another flag is not read as the provider")
    func anotherFlagIsNotAProvider() {
        #expect(KeyCommand.value(after: "--set-key",
                                 in: [Self.pulse, "--set-key", "--clear-key", "kimiCode"]) == nil)
    }

    @Test("The flag is matched whole")
    func noPrefixMatching() {
        // `--set-key` is not a prefix of `--set-keys`, and a longer argument
        // must not match the shorter flag.
        #expect(KeyCommand.value(after: "--set-key", in: [Self.pulse, "--set-keys", "kimiCode"]) == nil)
    }

    /// The two modes are distinct, and neither is a prefix of the other, which
    /// is what keeps `firstIndex(of:)` from matching the wrong one.
    @Test("Set and clear are different flags")
    func modesAreDistinct() {
        #expect(KeyCommand.setArgument != KeyCommand.clearArgument)
        #expect(!KeyCommand.setArgument.hasPrefix(KeyCommand.clearArgument))
        #expect(!KeyCommand.clearArgument.hasPrefix(KeyCommand.setArgument))
    }

    /// `--set-key` accepts exactly the providers that take a pasted key.
    ///
    /// Pinned because it is a list that can silently drift: a new paste provider
    /// that nobody adds here is one a headless install cannot configure, and a
    /// provider that stops taking a key would have this command storing
    /// something nothing reads.
    @Test("Every accepted provider keeps its own credential")
    func acceptedProvidersKeepTheirOwnCredential() {
        let pasteProviders = [Provider.kimiCode, .openCodeGo, .zai, .glmCoding,
                              .minimax, .minimaxCN, .deepSeek, .commandCode,
                              .volcengine, .devin, .ollamaCloud]
        for provider in pasteProviders {
            #expect(provider.usesAPIKey, "\(provider.rawValue) stopped taking a pasted key")
        }

        // And the ones that must be refused.
        for provider in [Provider.claudeCode, .codex, .kiro, .antigravity, .cursor, .grok, .grokBot] {
            #expect(!provider.usesAPIKey, "\(provider.rawValue) would be offered a key field")
        }
    }
}
