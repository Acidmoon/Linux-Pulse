import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

@testable import Pulse

/// The OAuth redirect listener, over a real socket.
///
/// **Nothing tested this before.** On macOS it was `NWListener`; the Linux port
/// replaced the transport with `bind`/`listen`/`accept` while leaving the state
/// check, the error page, the timeout and the once-only settle alone, and none
/// of that had a test behind it either. A loopback listener is exactly the kind
/// of thing that looks fine and is not: the port has to be readable before the
/// browser is opened, the redirect has to be answered with a real HTTP response
/// or the browser hangs, and the wrong state has to be refused rather than
/// accepted.
///
/// Real requests rather than a fake: the subject is the socket.
@Suite("OAuth loopback callback", .serialized)
struct LoopbackCallbackTests {
    /// One HTTP GET, and the body that came back.
    ///
    /// `URLSession` rather than a raw socket because the response has to be
    /// something a browser would accept — a malformed status line would leave a
    /// real one waiting, and a hand-rolled client would not notice.
    private static func get(_ port: UInt16, _ pathAndQuery: String) async throws -> String {
        let url = URL(string: "http://127.0.0.1:\(port)\(pathAndQuery)")!
        let (data, _) = try await URLSession.shared.data(from: url)
        return String(decoding: data, as: UTF8.self)
    }

    @Test("The redirect is answered, and the code comes back")
    func returnsTheCode() async throws {
        let callback = try LoopbackCallback(port: nil, path: "/callback")
        try await callback.start(expecting: "state-abc")
        defer { callback.stop() }

        // Read before the browser is opened, which is why `start` is a separate
        // step from `awaitCode` at all: this goes into the authorize URL.
        #expect(callback.port > 0, "the port is not known after start()")

        // A `Task` rather than `async let`: the result is awaited inside
        // `#expect(throws:)`, and an `async let` cannot be captured in a closure.
        let arrived = Task { try await callback.awaitCode(giveUpAfter: .seconds(10)) }
        let page = try await Self.get(callback.port, "/callback?code=THE_CODE&state=state-abc")

        #expect(page.contains("Signed in"), "the browser was left with: \(page)")
        #expect(try await arrived.value == "THE_CODE")
    }

    @Test("A state that does not match is refused")
    func mismatchedStateIsRefused() async throws {
        let callback = try LoopbackCallback(port: nil, path: "/callback")
        try await callback.start(expecting: "the-right-state")
        defer { callback.stop() }

        // A `Task` rather than `async let`: the result is awaited inside
        // `#expect(throws:)`, and an `async let` cannot be captured in a closure.
        let arrived = Task { try await callback.awaitCode(giveUpAfter: .seconds(10)) }
        _ = try await Self.get(callback.port, "/callback?code=THE_CODE&state=the-wrong-state")

        await #expect(throws: OAuthLogin.Failure.cancelled) { try await arrived.value }
    }

    /// The provider's own refusal reaches the user as a refusal, not as a
    /// timeout — the difference between "you said no" and "nothing happened".
    @Test("A refusal from the provider is reported as one")
    func refusalIsReported() async throws {
        let callback = try LoopbackCallback(port: nil, path: "/callback")
        try await callback.start(expecting: "state-abc")
        defer { callback.stop() }

        // A `Task` rather than `async let`: the result is awaited inside
        // `#expect(throws:)`, and an `async let` cannot be captured in a closure.
        let arrived = Task { try await callback.awaitCode(giveUpAfter: .seconds(10)) }
        _ = try await Self.get(callback.port, "/callback?error=access_denied&error_description=User+declined")

        await #expect(throws: OAuthLogin.Failure.refused("User declined")) { try await arrived.value }
    }

    /// A `+` in a query string means a space, and a provider that spells a
    /// refusal `User+declined` arrives verbatim without it being undone. The
    /// literal `+` case matters as much: a real plus in a code arrives as
    /// `%2B`, and decoding after undoing the spaces is what keeps the two
    /// apart.
    @Test("A plus in the state is read as the space it stands for")
    func plusIsASpace() async throws {
        let callback = try LoopbackCallback(port: nil, path: "/callback")
        try await callback.start(expecting: "state with spaces")
        defer { callback.stop() }

        // A `Task` rather than `async let`: the result is awaited inside
        // `#expect(throws:)`, and an `async let` cannot be captured in a closure.
        let arrived = Task { try await callback.awaitCode(giveUpAfter: .seconds(10)) }
        _ = try await Self.get(callback.port, "/callback?code=abc%2Bdef&state=state+with+spaces")

        // `%2B` survives as a plus while `+` became a space — so both the
        // state matched and the code is intact.
        #expect(try await arrived.value == "abc+def")
    }

    @Test("A request for another path is not taken as this sign-in's")
    func otherPathsAreIgnored() async throws {
        let callback = try LoopbackCallback(port: nil, path: "/callback")
        try await callback.start(expecting: "state-abc")
        defer { callback.stop() }

        let arrived = Task { try await callback.awaitCode(giveUpAfter: .seconds(2)) }
        let page = try await Self.get(callback.port, "/favicon.ico?code=THE_CODE&state=state-abc")

        #expect(page.contains("can be closed"), "a request for another path was answered with: \(page)")
        // Nothing was settled by it, so the wait runs out rather than
        // returning a code from a request that was not the redirect.
        await #expect(throws: OAuthLogin.Failure.timedOut) { try await arrived.value }
    }

    /// The one address a provider's registered client accepts is taken, almost
    /// always by that CLI's own sign-in running at the same moment. Reporting
    /// it as `portBusy` is what turns that into "close the other one" instead
    /// of a button that stopped working.
    @Test("A port already in use is reported rather than waited on")
    func busyPortIsReported() async throws {
        let first = try LoopbackCallback(port: nil, path: "/callback")
        try await first.start(expecting: "state-abc")
        defer { first.stop() }

        // The port the first one actually took, asked for again.
        #expect(throws: OAuthLogin.Failure.portBusy(first.port)) {
            _ = try LoopbackCallback(port: first.port, path: "/callback")
        }
    }

    /// Stopping has to take the socket with it, or a second sign-in in the same
    /// session finds its own port busy.
    @Test("Stopping releases the port")
    func stopReleasesThePort() async throws {
        let callback = try LoopbackCallback(port: nil, path: "/callback")
        try await callback.start(expecting: "state-abc")
        let port = callback.port

        callback.stop()
        // The close is what unwedges `accept`, so the descriptor is gone by
        // the time this returns rather than a moment later.
        try await Task.sleep(for: .milliseconds(100))

        let again = try LoopbackCallback(port: port, path: "/callback")
        try await again.start(expecting: "state-abc")
        defer { again.stop() }
        #expect(again.port == port)
    }
}
