import Foundation
import Testing

@testable import Pulse

/// The sealed-file layer, on this platform.
///
/// **Nothing tested this before, which is why it is here.** The Linux port
/// changed the one input that matters — `LocalSecrets` derives its key from the
/// machine identifier, and that went from IOKit's `IOPlatformUUID` to
/// `/etc/machine-id`. A silent failure there would have been invisible: every
/// read would return nil, every pasted key would report as missing, and the app
/// would look like it had simply lost the user's configuration.
///
/// The round trip is a real AES-GCM seal and open through swift-crypto, not a
/// mock, so it also covers the CryptoKit-to-swift-crypto substitution in
/// `Package.swift`.
@Suite("Local secrets")
struct LocalSecretsTests {
    /// One purpose per test, so a box sealed by one test cannot be opened by
    /// another's key even though both derive from the same machine.
    private func purpose(_ name: String) -> String { "pulse.test.\(name)" }

    @Test("The machine identifier is readable")
    func machineIdentifierIsReadable() {
        // Everything below depends on this. `/etc/machine-id` is the systemd
        // answer and `/var/lib/dbus/machine-id` its older name; a host with
        // neither would have every sealed file silently unopenable, which is
        // the failure mode this asserts against rather than round-tripping
        // into.
        let sealed = LocalSecrets.seal(Data("probe".utf8), purpose: purpose("identifier"))
        #expect(sealed != nil, "no machine identifier, so nothing can be sealed")
    }

    @Test("A sealed value opens again")
    func roundTrip() {
        let plain = Data("sk-live-not-a-real-key".utf8)
        let sealed = LocalSecrets.seal(plain, purpose: purpose("roundTrip"))
        #expect(sealed != nil)
        #expect(sealed != plain, "the box is the plaintext")

        let opened = LocalSecrets.open(sealed!, purpose: purpose("roundTrip"))
        #expect(opened == plain)
    }

    @Test("A different purpose cannot open it")
    func purposeIsPartOfTheKey() {
        // The whole point of deriving per purpose: a box from one store must
        // never open in another, even though both come from this machine.
        let sealed = LocalSecrets.seal(Data("secret".utf8), purpose: purpose("storeA"))!
        #expect(LocalSecrets.open(sealed, purpose: purpose("storeB")) == nil)
    }

    @Test("Tampered and truncated boxes do not open")
    func tamperingIsDetected() {
        let sealed = LocalSecrets.seal(Data("secret".utf8), purpose: purpose("tamper"))!
        #expect(LocalSecrets.open(Data(), purpose: purpose("tamper")) == nil)
        #expect(LocalSecrets.open(sealed.prefix(8), purpose: purpose("tamper")) == nil)

        var flipped = sealed
        flipped[flipped.count - 1] ^= 0x01
        #expect(LocalSecrets.open(flipped, purpose: purpose("tamper")) == nil)
    }

    @Test("A written file is owner-only, and stays that way")
    func writeIsOwnerOnly() throws {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "pulse-secret-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(LocalSecrets.write(Data("x".utf8), to: file))
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.int16Value == 0o600)

        // Written twice on purpose. `write(to:options:.atomic)` **replaces**
        // the file rather than truncating it, and the replacement does not
        // inherit the permissions — which is why the mode is applied after
        // every write and not once at creation.
        #expect(LocalSecrets.write(Data("y".utf8), to: file))
        let again = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((again[.posixPermissions] as? NSNumber)?.int16Value == 0o600)
    }
}

/// `keys.dat` end to end: a key goes in, comes back out, and a second provider's
/// key survives the first one being written.
///
/// The persistence bug this guards against is upstream's and is described on
/// `setKey`: a file that exists but will not decode was once treated as an empty
/// one, so saving one provider's key threw away every other provider's and
/// reported success.
@Suite("API key store", .serialized)
struct APIKeyStoreTests {
    @Test("A key survives a round trip through the sealed file")
    func roundTrip() throws {
        // The store writes to `PulseStorage.directory`, which is the real
        // user's — there is nowhere else for it to go, and the file is the
        // subject here. Restored afterwards so a test run does not decide
        // anything for the person running it.
        let file = PulseStorage.directory.appending(path: "keys.dat")
        let backup = try? Data(contentsOf: file)
        defer {
            if let backup { try? backup.write(to: file) }
            else { try? FileManager.default.removeItem(at: file) }
        }

        #expect(APIKeyStore.setKey("sk-test-one", for: .deepSeek))
        #expect(APIKeyStore.key(for: .deepSeek) == "sk-test-one")

        // The second write must not take the first with it.
        #expect(APIKeyStore.setKey("sk-test-two", for: .minimax))
        #expect(APIKeyStore.key(for: .minimax) == "sk-test-two")
        #expect(APIKeyStore.key(for: .deepSeek) == "sk-test-one")

        // Clearing one leaves the other.
        #expect(APIKeyStore.setKey(nil, for: .deepSeek))
        #expect(APIKeyStore.key(for: .deepSeek) == nil)
        #expect(APIKeyStore.key(for: .minimax) == "sk-test-two")
    }

    @Test("The file on disk is not the plaintext")
    func fileIsEncrypted() throws {
        let file = PulseStorage.directory.appending(path: "keys.dat")
        let backup = try? Data(contentsOf: file)
        defer {
            if let backup { try? backup.write(to: file) }
            else { try? FileManager.default.removeItem(at: file) }
        }

        #expect(APIKeyStore.setKey("sk-must-not-appear-in-the-clear", for: .deepSeek))
        let raw = try Data(contentsOf: file)
        #expect(raw.range(of: Data("sk-must-not-appear-in-the-clear".utf8)) == nil)
    }
}
