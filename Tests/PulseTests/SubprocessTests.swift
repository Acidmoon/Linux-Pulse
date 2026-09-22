import Foundation
import Testing

@testable import Pulse

/// The subprocess helper, against real children.
///
/// Every case here corresponds to something Foundation's `Process` got wrong on
/// this platform, which is why they are written against it rather than against
/// the providers that use it — see `Docs/decisions/linux-subprocess.md` for the
/// measurements. A test that only ran `/bin/echo` would pass on either
/// implementation and prove nothing.
@Suite("Subprocess")
struct SubprocessTests {
    private static let shell = URL(fileURLWithPath: "/bin/sh")

    // MARK: - One-shot

    @Test("Standard output and a zero exit")
    func capturesOutput() throws {
        let outcome = try Subprocess.run(
            Self.shell,
            ["-c", "printf 'hello'"],
            deadline: 10,
            outputCeiling: 64 * 1024
        )
        #expect(outcome.succeeded)
        #expect(String(data: outcome.standardOutput, encoding: .utf8) == "hello")
        #expect(outcome.exitCode == 0)
        #expect(outcome.signal == nil)
    }

    @Test("A non-zero exit is reported rather than thrown")
    func reportsNonZeroExit() throws {
        // 7 rather than 1: 1 is also what a shell gives for "could not run the
        // command", so it would pass even if the exit status were being faked.
        let outcome = try Subprocess.run(
            Self.shell,
            ["-c", "exit 7"],
            deadline: 10,
            outputCeiling: 64 * 1024
        )
        #expect(!outcome.succeeded)
        #expect(outcome.exitCode == 7)
        #expect(outcome.signal == nil)
    }

    @Test("The two streams are kept apart")
    func separatesStreams() throws {
        let outcome = try Subprocess.run(
            Self.shell,
            ["-c", "printf out; printf err >&2"],
            deadline: 10,
            outputCeiling: 64 * 1024
        )
        #expect(String(data: outcome.standardOutput, encoding: .utf8) == "out")
        #expect(String(data: outcome.standardError, encoding: .utf8) == "err")
    }

    /// **The case that broke `Process`.** A child writing more than a pipe
    /// buffer must still finish, and its output must still be readable.
    ///
    /// Measured against `readabilityHandler`: the quiet descriptor signalled
    /// EOF immediately and the busy one never did, so the read waited out its
    /// whole deadline on a process that had already exited. This wrote to
    /// stdout in one variant and stderr in the other because which descriptor
    /// stalled changed run to run.
    @Test("Bulk output on stdout finishes")
    func bulkOutputOnStandardOutput() throws {
        let outcome = try Subprocess.run(
            Self.shell,
            ["-c", "yes PADDING | head -c 4194304"],
            deadline: 20,
            outputCeiling: 512 * 1024
        )
        #expect(outcome.succeeded)
        #expect(!outcome.timedOut)
        // Capped, so somewhere between the ceiling and one chunk past it.
        #expect(outcome.standardOutput.count >= 512 * 1024)
        #expect(outcome.standardOutput.count <= 512 * 1024 + 64 * 1024)
    }

    @Test("Bulk output on stderr finishes, and stdout is still read")
    func bulkOutputOnStandardError() throws {
        // The shape that deadlocks a reader which drains stdout first: 1 MiB to
        // stderr, then a small answer on stdout.
        let outcome = try Subprocess.run(
            Self.shell,
            ["-c", "yes ERROR | head -c 1048576 >&2; printf '{\"items\":[]}'"],
            deadline: 20,
            outputCeiling: 512 * 1024
        )
        #expect(outcome.succeeded)
        #expect(!outcome.timedOut)
        #expect(String(data: outcome.standardOutput, encoding: .utf8) == #"{"items":[]}"#)
        #expect(outcome.standardError.count >= 512 * 1024)
    }

    /// **The other case that broke `Process`.** A deadline has to actually
    /// return, and the child has to actually die.
    ///
    /// `readabilityHandler` + `terminate()` left the child a zombie that
    /// `Process.isRunning` reported as running for ever. Here the exit comes
    /// from `waitpid`, and the group is checked from outside with `kill(pid, 0)`
    /// so the assertion is about the operating system rather than about a flag
    /// this code sets itself.
    @Test("A child past its deadline is killed and reported as timed out")
    func deadlineKillsTheChild() throws {
        let outcome = try Subprocess.run(
            Self.shell,
            ["-c", "sleep 30"],
            deadline: 1,
            outputCeiling: 64 * 1024
        )
        #expect(outcome.timedOut)
        #expect(outcome.signal == SIGTERM || outcome.signal == SIGKILL)
    }

    /// A helper that forks must not leave the descendant behind.
    ///
    /// This is why the child leads its own process group: `codex app-server`
    /// starts a sandbox and `arkcli` runs subcommands, and killing only the
    /// direct child leaves those running with the pipe still open.
    @Test("Terminating takes the whole process group with it")
    func terminateKillsTheGroup() throws {
        let marker = FileManager.default.temporaryDirectory
            .appending(path: "pulse-subprocess-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }

        // The grandchild writes its own pid and then sleeps.
        let child = try Subprocess.Child(
            executable: Self.shell,
            arguments: ["-c", "sh -c 'echo $$ > \(marker.path); sleep 30' & wait"]
        )
        child.start()

        // Wait for the grandchild to name itself.
        var grandchild: pid_t = 0
        let until = Date().addingTimeInterval(5)
        while Date() < until {
            if let text = try? String(contentsOf: marker, encoding: .utf8),
               let parsed = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                grandchild = parsed
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        #expect(grandchild > 1, "the grandchild never wrote its pid")

        child.terminate()

        // SIGTERM does not reap; give the system a moment, then ask whether
        // anything with that pid is still there.
        var stillThere = true
        let gone = Date().addingTimeInterval(3)
        while Date() < gone {
            if kill(grandchild, 0) != 0 { stillThere = false; break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        #expect(!stillThere, "the grandchild outlived the child that started it")
    }

    // MARK: - Streaming

    @Test("A long-lived child can be written to and heard from")
    func streamingChildTalks() throws {
        // Echoes each line back with a prefix, which is the shape both the
        // Codex and Kiro clients depend on.
        let child = try Subprocess.Child(
            executable: Self.shell,
            arguments: ["-c", "while read line; do printf 'got %s\\n' \"$line\"; done"]
        )

        let lines = LineCollector()
        child.onOutput = { chunk in lines.append(chunk) }
        child.start()

        child.write(Data("one\n".utf8))
        child.write(Data("two\n".utf8))

        let until = Date().addingTimeInterval(5)
        while Date() < until, lines.count < 2 {
            Thread.sleep(forTimeInterval: 0.02)
        }
        #expect(lines.lines == ["got one", "got two"])

        child.terminate()
        #expect(!child.isRunning, "terminate returned with the child still running")
    }

    @Test("A child that closes its own stdout is reported as exited")
    func exitIsReported() throws {
        // The case that `Process` could not answer: it closes stdout
        // immediately and then stays alive, so an EOF is not an exit.
        let child = try Subprocess.Child(
            executable: Self.shell,
            arguments: ["-c", "exec 1>&-; sleep 30"]
        )
        child.start()
        Thread.sleep(forTimeInterval: 0.3)

        child.terminate()
        #expect(!child.isRunning)
        #expect(child.exitCode != nil, "no exit code after the child was killed")
    }

    @Test("A child that exits on its own reports its code")
    func naturalExitIsReported() throws {
        let child = try Subprocess.Child(executable: Self.shell, arguments: ["-c", "exit 5"])

        let exited = DispatchSemaphore(value: 0)
        let code = ValueBox<Int32?>(nil)
        child.onExit = { status in
            code.value = status
            exited.signal()
        }
        child.start()

        #expect(exited.wait(timeout: .now() + 5) == .success, "onExit never fired")
        #expect(code.value == 5)
        #expect(!child.isRunning)
    }
}

/// Collects newline-delimited lines from a child's output.
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var collected: [String] = []

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = buffer[buffer.index(after: newline)...]
            collected.append(String(decoding: line, as: UTF8.self))
        }
    }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }

    var count: Int { lines.count }
}

private final class ValueBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T

    init(_ value: T) { stored = value }

    var value: T {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}
