import Foundation
import Testing

@testable import Pulse

/// The Codex app-server client, driven against a real child process.
///
/// **These used to assert on the mechanism.** Four of them checked
/// `reader.readabilityHandler` before and after events, because the invariant
/// they carried — an EOF must not leave a busy loop, and must not leave a live
/// helper with nothing able to kill it — could not be seen from outside. On
/// Linux that mechanism does not work at all: a handler never delivered EOF on
/// a busy pipe, and a child whose stdout EOF it had seen was never reaped. The
/// reader is a `Subprocess.Child` now, whose reader thread simply ends at EOF,
/// so the busy loop is not expressible and the assertions have moved to what
/// the client does about the events.
///
/// The other half of the change is that the helper is no longer injected as a
/// `Process` plus a pipe. The executable and its arguments are constructor
/// arguments, so `/bin/sh` and a script run through the **same** code path as
/// `codex app-server`: the handshake, the framing, the restart and the EOF
/// handling are all exercised rather than bypassed.
@Suite("Codex app server")
struct CodexAppServerTests {
    private static let shell = URL(fileURLWithPath: "/bin/sh")

    /// Answers each request with a fixed result, echoing back the id it read.
    ///
    /// The id has to be echoed: the client matches replies to pending requests
    /// by it, and a reply with the wrong one is silently ignored — which is a
    /// hang rather than a failure, and the least useful way for a test to go
    /// wrong.
    private static func replying(_ result: String) -> String {
        """
        while read -r line; do
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9]*\\).*/\\1/p')
          [ -n "$id" ] && printf '{"jsonrpc":"2.0","id":%s,"result":%s}\\n' "$id" '\(result)'
        done
        """
    }

    @Test("A reply comes back through the handshake and the framing")
    func answersARequest() async throws {
        let server = CodexAppServer(
            executable: Self.shell,
            arguments: ["-c", Self.replying(#"{"limits":[1,2,3]}"#)],
            requestTimeout: .seconds(10)
        )

        let data = try await server.rateLimits()
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(decoded?["limits"] as? [Int] == [1, 2, 3])
        await server.shutDown()
    }

    /// A read can land mid-line, and two messages can arrive in one chunk.
    /// Both are ordinary on a pipe, and both are what the buffer is for.
    @Test("Messages survive being split and being batched")
    func framesMessages() async throws {
        // The first chunk ends halfway through the line, so the client has to
        // hold the remainder rather than parse it.
        let script = """
        while read -r line; do
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9]*\\).*/\\1/p')
          [ -z "$id" ] && continue
          printf '{"jsonrpc":"2.0","id":%s,"res' "$id"
          sleep 0.2
          printf 'ult":{"split":true}}\\n'
        done
        """
        let server = CodexAppServer(
            executable: Self.shell,
            arguments: ["-c", script],
            requestTimeout: .seconds(10)
        )

        let data = try await server.rateLimits()
        #expect(String(data: data, encoding: .utf8)?.contains("split") == true)
        await server.shutDown()
    }

    /// **The case that used to fail.** A helper that closes its stdout and
    /// stays alive has nothing left to say, so it must be terminated rather
    /// than forgotten — otherwise quitting Pulse leaves it behind.
    ///
    /// Checked from outside, with `kill(pid, 0)` on the pid the helper wrote
    /// itself, so the assertion is about the operating system rather than about
    /// a flag this code sets for itself. The earlier version of this test could
    /// not do that: it asserted `!helper.isRunning`, which on Linux stayed
    /// `true` for a helper that was already dead.
    @Test("A helper that closes its stdout is terminated, not forgotten")
    func outputClosedTerminatesTheHelper() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appending(path: "pulse-codex-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }

        let script = """
        read -r line
        printf '{"jsonrpc":"2.0","id":1,"result":{}}\\n'
        echo $$ > \(marker.path)
        exec 1>&-
        sleep 30
        """
        let server = CodexAppServer(
            executable: Self.shell,
            arguments: ["-c", script],
            requestTimeout: .seconds(5)
        )

        // The initialize handshake answers; the request after it never will,
        // because the helper has closed its output by then.
        await #expect(throws: (any Error).self) {
            _ = try await server.accountUsage()
        }

        let pid = try #require(
            pid_t((try? String(contentsOf: marker, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"),
            "the helper never wrote its pid"
        )
        #expect(pid > 1)

        var stillThere = true
        let gone = Date().addingTimeInterval(3)
        while Date() < gone {
            if kill(pid, 0) != 0 { stillThere = false; break }
            // `Task.sleep`, not `Thread.sleep`: this is an async context.
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(!stillThere, "the helper outlived the stdout it closed")
    }

    /// A helper that has exited is replaced rather than reused.
    ///
    /// Counted by the helper appending a line each time it starts, which is the
    /// only evidence available from outside that a second process ran.
    ///
    /// The helper is killed from here rather than being written to exit after
    /// one answer. Exiting on its own leaves a race the test would be measuring
    /// instead of the behaviour: the reply to the first request arrives while
    /// the helper is still winding down, so the second request can legitimately
    /// find it running and reuse it. Waiting for the pid to be gone first is
    /// what makes "a dead helper is replaced" the thing under test.
    @Test("A dead helper is replaced on the next request")
    func restartAfterExit() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "pulse-codex-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let counter = directory.appending(path: "starts")
        let pidFile = directory.appending(path: "pid")

        let script = """
        echo $$ > \(pidFile.path)
        echo start >> \(counter.path)
        while read -r line; do
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9]*\\).*/\\1/p')
          [ -n "$id" ] && printf '{"jsonrpc":"2.0","id":%s,"result":{"ok":true}}\n' "$id"
        done
        """
        let server = CodexAppServer(
            executable: Self.shell,
            arguments: ["-c", script],
            requestTimeout: .seconds(10)
        )

        _ = try await server.accountUsage()

        let pid = try #require(
            pid_t((try? String(contentsOf: pidFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0")
        )
        #expect(pid > 1)
        kill(pid, SIGKILL)

        let gone = Date().addingTimeInterval(5)
        while kill(pid, 0) == 0, Date() < gone {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(kill(pid, 0) != 0, "the helper was not killed")

        // A fresh helper has to start, because the one just killed can answer
        // nothing. If the dead one were kept, this throws `.startFailed`.
        _ = try await server.rateLimits()

        let starts = (try? String(contentsOf: counter, encoding: .utf8))?
            .split(separator: "\n").count ?? 0
        #expect(starts == 2, "expected a fresh helper, saw \(starts) starts")
        await server.shutDown()
    }

    /// Nothing must be left waiting when the helper goes.
    ///
    /// A continuation nobody answers suspends its caller for ever, so a helper
    /// dying mid-request has to fail that request rather than let it sit until
    /// its timeout.
    @Test("A helper dying fails what was waiting")
    func deathFailsPendingRequests() async throws {
        let script = """
        read -r line
        printf '{"jsonrpc":"2.0","id":1,"result":{}}\\n'
        exit 0
        """
        let server = CodexAppServer(
            executable: Self.shell,
            arguments: ["-c", script],
            // Long, so a timeout cannot be what ends this. The failure has to
            // come from the helper going away.
            requestTimeout: .seconds(60)
        )

        let started = Date()
        await #expect(throws: (any Error).self) {
            _ = try await server.accountUsage()
        }
        #expect(
            Date().timeIntervalSince(started) < 10,
            "the request waited for its timeout instead of noticing the helper had gone"
        )
    }
}
