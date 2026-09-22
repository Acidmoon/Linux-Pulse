import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Child processes, without Foundation's `Process`.
///
/// **Why not `Process`.** Measured on this platform, `Process` fails in three
/// separate ways that the provider helpers walked into one at a time:
///
/// 1. `Pipe.fileHandleForReading.readabilityHandler` **does not deliver EOF on
///    the descriptor that carried bulk data.** With a child writing more than a
///    pipe buffer, the quiet pipe signalled EOF immediately and the busy one
///    never did, so a read group waited out its whole deadline on a process
///    that had already exited. It is a race, so which pipe stalled changed run
///    to run, and one run crashed inside `_dispatch_event_loop_drain`.
/// 2. `Process.terminate()` kills the child correctly, but the child is then
///    **never reaped** when a readability handler had observed EOF on its
///    stdout — so it stays a zombie and `Process.isRunning` stays `true` for
///    ever. Measured as a four-cell matrix; the other three cells reaped
///    normally.
/// 3. `terminationHandler` therefore does not fire reliably, so
///    `isRunning`/`terminationStatus` are not answers a caller can wait on.
///
/// `waitpid` is called by this file, so reaping is deterministic and an exit is
/// known rather than inferred. `read` and `poll` are called directly, so EOF is
/// a return value rather than a callback that may never arrive.
///
/// The measurements, and what each one does and does not prove, are in
/// `Docs/decisions/linux-subprocess.md`.
///
/// One implementation for every platform on purpose: `posix_spawn`, `poll` and
/// `waitpid` all exist on Darwin as well, and a second implementation behind a
/// conditional would be a second thing to be wrong.
enum Subprocess {
    /// How long a killed child is given to die politely before `SIGKILL`.
    ///
    /// Short because this is the escape hatch, not the plan: the callers are
    /// all children the user's own tools started, and one that ignores `SIGTERM`
    /// is exactly the case this exists for.
    static let graceAfterTerminate: TimeInterval = 2

    /// How often the read loop wakes when no descriptor is ready.
    ///
    /// A slice rather than a blocking read so the loop can notice a deadline,
    /// and so nothing is parked on a write end a grandchild is holding open.
    static let pollSliceMilliseconds: Int32 = 200

    /// Ignores `SIGPIPE` for the life of the process.
    ///
    /// Writing to a pipe whose far end has closed raises it, and its default
    /// action is to terminate the process — so a helper exiting would take
    /// Pulse down with it, which from the outside looks like the app crashing
    /// at random. macOS does this from `AppDelegate`, which the Linux build
    /// excludes, so the call lives here instead: both entry points reach
    /// `Subprocess`, and this is next to the writes that need it.
    ///
    /// Called once at startup rather than per write, because a signal
    /// disposition is process-wide and there is nothing per-child about it.
    static func ignoreSIGPIPE() {
        signal(SIGPIPE, SIG_IGN)
    }

    // MARK: - One-shot

    /// What a finished child left behind.
    struct Outcome {
        let standardOutput: Data
        let standardError: Data
        /// The exit code, or `-1` when a signal ended it — `signal` says which.
        let exitCode: Int32
        /// The signal that ended it, when one did.
        let signal: Int32?
        /// True when the deadline ran out and the child was killed. The output
        /// is still whatever was read before that, which is the point of
        /// reading with a cap rather than discarding a slow answer.
        let timedOut: Bool

        var succeeded: Bool { signal == nil && exitCode == 0 && !timedOut }
    }

    /// Runs `executable` to completion and returns what it wrote.
    ///
    /// Both pipes are drained **concurrently**, up to `outputCeiling` bytes
    /// each. A caller that read stdout to EOF before touching stderr deadlocks
    /// on any child that fills the stderr pipe first — 64 KiB — which is why
    /// this is a loop over both descriptors rather than two sequential reads.
    static func run(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String]? = nil,
        input: Data? = nil,
        deadline: TimeInterval,
        outputCeiling: Int
    ) throws -> Outcome {
        let child = try spawn(
            executable,
            arguments,
            environment: environment,
            keepStandardInput: input != nil
        )
        defer { closeReadingEnds(child) }

        if let input {
            // On its own thread, for two reasons: a child that waits for EOF
            // before answering would deadlock against a caller that wrote the
            // whole input first, and an input larger than the pipe buffer would
            // deadlock against itself. The write end is closed here, which is
            // what gives the child its EOF.
            Thread.detachNewThread {
                var offset = 0
                input.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return }
                    while offset < input.count {
                        let written = posixWrite(
                            child.standardInput,
                            base + offset,
                            input.count - offset
                        )
                        guard written > 0 else { break }
                        offset += written
                    }
                }
                close(child.standardInput)
            }
        }

        let collected = Collected(ceiling: outputCeiling)
        let until = Date().addingTimeInterval(deadline)

        // Both descriptors, one loop. `out` and `err` are EOFed independently
        // and the child may exit between the two.
        var open: Set<Int32> = [child.standardOutput, child.standardError]
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)

        while !open.isEmpty, Date() < until {
            var interests = open.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            // Snapshot the descriptors before polling: `interests` is parallel
            // to `open`, and the indices have to survive the removal below.
            let descriptors = Array(open)

            let ready = interests.withUnsafeMutableBufferPointer { pointer in
                poll(pointer.baseAddress, nfds_t(pointer.count), pollSliceMilliseconds)
            }
            guard ready >= 0 else { break }
            if ready == 0 { continue }

            for (index, descriptor) in descriptors.enumerated() {
                guard interests[index].revents != 0 else { continue }
                let count = read(descriptor, &buffer, buffer.count)
                // 0 is EOF and negative is an error; either way this pipe is
                // finished with.
                guard count > 0 else {
                    open.remove(descriptor)
                    continue
                }
                collected.append(
                    Data(buffer[0..<count]),
                    isStandardError: descriptor == child.standardError
                )
            }
        }

        let timedOut = !open.isEmpty
        if timedOut {
            terminate(child.pid)
            // Drain whatever the dying child had already written. Bounded, so a
            // descendant that inherited the write end cannot hold this here.
            drain(child, into: collected, for: graceAfterTerminate, open: &open, buffer: &buffer)
        }

        let status = reap(child.pid, within: graceAfterTerminate)
        return Outcome(
            standardOutput: collected.standardOutput,
            standardError: collected.standardError,
            exitCode: status?.exitCode ?? -1,
            signal: status?.signal,
            timedOut: timedOut
        )
    }

    // MARK: - Streaming

    /// A child that stays alive and is talked to, rather than one that runs and
    /// finishes.
    ///
    /// `CodexAppServer` and `KiroACPClient` both need this: newline-delimited
    /// JSON out, request lines in, and an EOF that has to be noticed because it
    /// means the helper died. Each is fed by its own thread, which is two
    /// threads for the life of the child — bounded, and the alternative on this
    /// platform is a callback that may never fire.
    final class Child: @unchecked Sendable {
        let pid: pid_t

        /// Called on a reader thread for each chunk read from the child's
        /// stdout. Never called after `onExit`.
        var onOutput: (@Sendable (Data) -> Void)?
        /// The same for stderr, for a child whose diagnostics are worth keeping.
        var onErrorOutput: (@Sendable (Data) -> Void)?
        /// Called once, after the child has been reaped **and both pipes have
        /// been drained**. By then `exitCode` is set and `isRunning` is false,
        /// so a handler can trust both.
        ///
        /// The draining is part of it deliberately. A child that answers and
        /// then exits — which is ordinary — leaves its answer in the pipe
        /// buffer, and a callback that fired on the exit alone would have a
        /// handler discard an answer that had already arrived.
        var onExit: (@Sendable (Int32) -> Void)?
        /// Called when the child's **stdout** reaches EOF, which is not the
        /// same event as the child exiting: a helper can close its output and
        /// carry on running. That is the case `CodexAppServer` has to act on —
        /// a helper with nothing to say must not be left resident with nobody
        /// able to kill it — so the two are reported separately rather than
        /// being folded into one "finished" callback.
        var onOutputClosed: (@Sendable () -> Void)?

        private let standardInput: Int32
        private let standardOutput: Int32
        private let standardError: Int32
        private let writeLock = NSLock()
        private let stateLock = NSLock()
        /// The two reader threads, so the exit can wait for them.
        private let readers = DispatchGroup()
        private var reaped: Int32?
        private var started = false

        init(
            executable: URL,
            arguments: [String],
            environment: [String: String]? = nil
        ) throws {
            let spawned = try Subprocess.spawn(
                executable,
                arguments,
                environment: environment,
                keepStandardInput: true
            )
            pid = spawned.pid
            standardInput = spawned.standardInput
            standardOutput = spawned.standardOutput
            standardError = spawned.standardError
        }

        /// Starts reading. Separate from `init` so a caller can set the
        /// callbacks first and cannot miss a chunk that arrives in between.
        func start() {
            stateLock.lock()
            guard !started else { stateLock.unlock(); return }
            started = true
            stateLock.unlock()

            readers.enter()
            watch(standardOutput, isStandardOutput: true) { [weak self] chunk in
                self?.onOutput?(chunk)
            }
            readers.enter()
            watch(standardError, isStandardOutput: false) { [weak self] chunk in
                self?.onErrorOutput?(chunk)
            }

            let thread = Thread { [weak self] in
                guard let self else { return }
                let status = Subprocess.reap(self.pid, within: nil)
                self.stateLock.lock()
                self.reaped = status?.exitCode ?? -1
                self.stateLock.unlock()
                // `reaped` is set first, which is what the readers look at to
                // decide they are finished — so this cannot wait for something
                // that is waiting for it.
                self.readers.wait()
                self.onExit?(self.exitCode ?? -1)
            }
            thread.name = "com.pulse.subprocess.reaper"
            thread.start()
        }

        /// Writes to the child's stdin. False when the child has gone.
        ///
        /// A closed pipe raises `SIGPIPE`, whose default action is to kill the
        /// process; `Subprocess.ignoreSIGPIPE()` is what stops a helper exiting
        /// from taking Pulse with it. With that in place a write to a dead
        /// child returns an error, which is what this reports — the alternative
        /// is a caller that keeps writing into a pipe nobody is reading.
        @discardableResult
        func write(_ data: Data) -> Bool {
            writeLock.lock()
            defer { writeLock.unlock() }
            var offset = 0
            var wroteEverything = true
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                while offset < data.count {
                    let written = posixWrite(standardInput, base + offset, data.count - offset)
                    guard written > 0 else {
                        wroteEverything = false
                        return
                    }
                    offset += written
                }
            }
            return wroteEverything
        }

        var isRunning: Bool {
            stateLock.lock()
            defer { stateLock.unlock() }
            return reaped == nil
        }

        /// The exit code, or nil while the child is still running.
        var exitCode: Int32? {
            stateLock.lock()
            defer { stateLock.unlock() }
            return reaped
        }

        /// SIGTERM to the group, then SIGKILL, then wait briefly for the
        /// reaper thread to have the exit. Safe to call more than once.
        ///
        /// The reaping itself belongs to the reaper thread started by `start()`
        /// — two waiters on one pid means one of them gets `ECHILD`, and the
        /// one that loses is whichever got there second.
        func terminate() {
            Subprocess.terminate(pid)
            let until = Date().addingTimeInterval(Subprocess.graceAfterTerminate)
            while isRunning, Date() < until {
                Thread.sleep(forTimeInterval: 0.02)
            }
            closeAll()
        }

        private func closeAll() {
            writeLock.lock()
            close(standardInput)
            writeLock.unlock()
            close(standardOutput)
            close(standardError)
        }

        private func watch(
            _ descriptor: Int32,
            isStandardOutput: Bool,
            _ body: @escaping @Sendable (Data) -> Void
        ) {
            let thread = Thread { [weak self] in
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                defer { self?.readers.leave() }
                while true {
                    var interest = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                    let ready = poll(&interest, 1, Subprocess.pollSliceMilliseconds)
                    guard ready > 0 else {
                        // A slice expiring is not EOF. Stop only once the child
                        // is gone, so an idle helper is not mistaken for a
                        // finished one.
                        if ready < 0 { return }
                        guard let self, self.isRunning else { return }
                        continue
                    }
                    let count = read(descriptor, &buffer, buffer.count)
                    guard count > 0 else { break }
                    body(Data(buffer[0..<count]))
                }
                // EOF or read error: this stream is finished, which is not the
                // same as the child being finished.
                if isStandardOutput { self?.onOutputClosed?() }
            }
            thread.name = "com.pulse.subprocess.reader"
            thread.start()
        }
    }

    // MARK: - Spawning

    struct Spawned {
        let pid: pid_t
        let standardInput: Int32
        let standardOutput: Int32
        let standardError: Int32
    }

    /// `posix_spawn` rather than `fork`/`exec`: there is no window in which the
    /// child shares this process's memory, which matters for a process that
    /// holds several threads and a lock around its caches.
    ///
    /// The child is put in **its own process group** (`POSIX_SPAWN_SETPGROUP`
    /// with pgroup 0). Everything that kills does it with `kill(-pid)`, so a
    /// helper that forks a descendant — `codex app-server` starting a sandbox,
    /// `arkcli` running a subcommand — leaves nothing behind.
    static func spawn(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String]?,
        keepStandardInput: Bool = false
    ) throws -> Spawned {
        var outputPipe: [Int32] = [0, 0]
        var errorPipe: [Int32] = [0, 0]
        var inputPipe: [Int32] = [0, 0]
        guard pipe(&outputPipe) == 0, pipe(&errorPipe) == 0 else {
            throw SubprocessError.pipeFailed(errno)
        }
        if keepStandardInput, pipe(&inputPipe) != 0 {
            throw SubprocessError.pipeFailed(errno)
        }

        // An opaque struct on Linux rather than the Optional pointer Darwin
        // imports, so it is zero-initialised here rather than made optional.
        var actions = posix_spawn_file_actions_t()
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }

        if keepStandardInput {
            posix_spawn_file_actions_adddup2(&actions, inputPipe[0], 0)
            posix_spawn_file_actions_addclose(&actions, inputPipe[0])
            posix_spawn_file_actions_addclose(&actions, inputPipe[1])
        } else {
            // Nothing to answer with, so a CLI that asks gets EOF rather than
            // blocking on a terminal that is not there.
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, outputPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errorPipe[1], 2)
        posix_spawn_file_actions_addclose(&actions, outputPipe[1])
        posix_spawn_file_actions_addclose(&actions, errorPipe[1])

        var attributes = posix_spawnattr_t()
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        // Group 0 means "lead a new group whose id is my pid", which is what
        // `terminate` then signals.
        posix_spawnattr_setpgroup(&attributes, 0)

        var pid: pid_t = 0
        // `argv[0]` is the program name, and it is not optional: without it the
        // first real argument takes its place, so `/bin/sh -c "..."` arrives as
        // a shell whose `$0` is `-c` and which was given no command string at
        // all. It then reads stdin — `/dev/null` — and exits silently, which
        // looks exactly like a child that ran and printed nothing.
        let code = withCStrings([executable.path] + arguments) { argv in
            withCStrings((environment ?? Self.inheritedEnvironment()).map { "\($0.key)=\($0.value)" }) { envp in
                withCString(executable.path) { path in
                    posix_spawn(&pid, path, &actions, &attributes, argv, envp)
                }
            }
        }

        guard code == 0 else {
            close(outputPipe[0]); close(outputPipe[1])
            close(errorPipe[0]); close(errorPipe[1])
            if keepStandardInput { close(inputPipe[0]); close(inputPipe[1]) }
            throw SubprocessError.spawnFailed(code)
        }

        // The parent's copies of the write ends are what would keep a reader
        // from ever seeing EOF. The child owns those descriptors now.
        close(outputPipe[1])
        close(errorPipe[1])
        if keepStandardInput { close(inputPipe[0]) }

        return Spawned(
            pid: pid,
            standardInput: keepStandardInput ? inputPipe[1] : -1,
            standardOutput: outputPipe[0],
            standardError: errorPipe[0]
        )
    }

    /// `POSIX_SPAWN_SETPGROUP` puts the child in group `pid`, so this signals
    /// the child **and anything it started**.
    static func terminate(_ pid: pid_t) {
        guard pid > 1 else { return }
        kill(-pid, SIGTERM)
        let until = Date().addingTimeInterval(graceAfterTerminate)
        while kill(-pid, 0) == 0, Date() < until {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if kill(-pid, 0) == 0 { kill(-pid, SIGKILL) }
    }

    /// Blocks until the child is reaped, or `within` seconds have passed.
    ///
    /// `nil` for the deadline means wait indefinitely, which is what the
    /// streaming child's reaper thread wants: it is a thread of its own and the
    /// child is expected to outlive this call.
    ///
    /// **This is the whole point of the file.** Foundation never reaped a child
    /// whose stdout EOF had been seen through a readability handler, so
    /// `isRunning` stayed true for a dead process. `waitpid` does not have that
    /// problem, and it cannot be missed because the waiter is the only reaper.
    @discardableResult
    static func reap(_ pid: pid_t, within: TimeInterval?) -> (exitCode: Int32, signal: Int32?)? {
        let until = within.map { Date().addingTimeInterval($0) }
        while true {
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid {
                if WaitStatus.signalled(status) {
                    return (-1, WaitStatus.signal(status))
                }
                return (WaitStatus.exitCode(status), nil)
            }
            if result == -1 { return nil }
            if let until, Date() >= until { return nil }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    // MARK: - Internals

    private static func closeReadingEnds(_ child: Spawned) {
        close(child.standardOutput)
        close(child.standardError)
    }

    private static func drain(
        _ child: Spawned,
        into collected: Collected,
        for seconds: TimeInterval,
        open: inout Set<Int32>,
        buffer: inout [UInt8]
    ) {
        let until = Date().addingTimeInterval(seconds)
        while !open.isEmpty, Date() < until {
            var interests = open.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            let descriptors = Array(open)
            let ready = interests.withUnsafeMutableBufferPointer { pointer in
                poll(pointer.baseAddress, nfds_t(pointer.count), 50)
            }
            guard ready > 0 else { break }
            for (index, descriptor) in descriptors.enumerated() {
                guard interests[index].revents != 0 else { continue }
                let count = read(descriptor, &buffer, buffer.count)
                guard count > 0 else {
                    open.remove(descriptor)
                    continue
                }
                collected.append(
                    Data(buffer[0..<count]),
                    isStandardError: descriptor == child.standardError
                )
            }
        }
    }

    private static func inheritedEnvironment() -> [String: String] {
        ProcessInfo.processInfo.environment
    }

    private static func withCString<T>(_ string: String, _ body: (UnsafePointer<CChar>) throws -> T) rethrows -> T {
        try string.withCString(body)
    }

    /// Builds a `NULL`-terminated vector of the strings, and frees it.
    ///
    /// `posix_spawn` does not copy `argv`/`envp`, so the storage has to outlive
    /// the call and be released after it — not before, which is the mistake
    /// that produces a child with a truncated environment.
    private static func withCStrings<T>(
        _ strings: [String],
        _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) throws -> T
    ) rethrows -> T {
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        pointers.append(nil)
        defer { for pointer in pointers where pointer != nil { free(pointer) } }
        return try pointers.withUnsafeBufferPointer { try body($0.baseAddress!) }
    }

    /// The captured output, capped.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private let ceiling: Int
        private var output = Data()
        private var error = Data()

        init(ceiling: Int) { self.ceiling = ceiling }

        func append(_ chunk: Data, isStandardError: Bool) {
            lock.lock()
            defer { lock.unlock() }
            // Past the ceiling the bytes are dropped, never the reading: a
            // child with more to say than anyone wants must still be allowed
            // to finish. See `VolcengineUsageService` for the case that
            // motivated it.
            if isStandardError {
                if error.count < ceiling { error.append(chunk) }
            } else if output.count < ceiling {
                output.append(chunk)
            }
        }

        var standardOutput: Data {
            lock.lock(); defer { lock.unlock() }
            return output
        }

        var standardError: Data {
            lock.lock(); defer { lock.unlock() }
            return error
        }
    }
}

/// The `WIFEXITED` and friends macros, written out.
///
/// They are C macros and Swift imports none of them. The encoding they read is
/// the same on Linux and Darwin, which is why there is one copy here rather
/// than a branch: the low seven bits hold the signal number when the child was
/// signalled and are zero when it exited, `0x7f` meaning it merely stopped, and
/// the exit code sits in the byte above.
private enum WaitStatus {
    static func exited(_ status: Int32) -> Bool {
        status & 0x7f == 0
    }

    static func exitCode(_ status: Int32) -> Int32 {
        (status >> 8) & 0xff
    }

    /// `(status & 0x7f) + 1` is even exactly when the low bits are a signal
    /// number rather than `0x7f`. The macro tests its sign rather than its
    /// parity, which is the same question asked of a signed char.
    static func signalled(_ status: Int32) -> Bool {
        (status & 0x7f) != 0x7f && (status & 0x7f) != 0
    }

    static func signal(_ status: Int32) -> Int32 {
        status & 0x7f
    }
}

/// `write(2)`, under a name that does not collide with any method called
/// `write` on the types here.
private func posixWrite(_ descriptor: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
    #if canImport(Glibc)
    return Glibc.write(descriptor, buffer, count)
    #else
    return Darwin.write(descriptor, buffer, count)
    #endif
}

enum SubprocessError: Error {
    case pipeFailed(Int32)
    case spawnFailed(Int32)
}
