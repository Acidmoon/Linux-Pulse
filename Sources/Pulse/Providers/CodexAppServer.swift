import Foundation

/// A JSON-RPC client for `codex app-server`.
///
/// This is Codex's own documented protocol, and it is the reason Pulse doesn't
/// have to hold Codex credentials: the app server is already signed in, so
/// Pulse asks it for figures instead of reading `~/.codex/auth.json` and
/// calling an undocumented HTTP endpoint itself. It also pushes
/// `account/rateLimits/updated` when the numbers move, so the refresh loop is
/// a fallback rather than the main path.
///
/// The cost is a resident child process, started lazily on the first request
/// and restarted if it dies.
actor CodexAppServer {
    /// Called when the server reports that limits changed.
    private var onRateLimitsChanged: (@Sendable () -> Void)?

    /// The helper, or nil when none is running.
    ///
    /// A `Subprocess.Child` rather than a `Process` plus a pair of pipes plus a
    /// readability handler. The three properties that used to be here were the
    /// shape issue #25 came from, and on Linux they could not be made to work:
    /// a handler never delivered EOF on a busy pipe, and a child whose stdout
    /// EOF it had seen was never reaped, so `isRunning` stayed true for a dead
    /// process. See `Docs/decisions/linux-subprocess.md`.
    ///
    /// One object holds the pid, the stdin write end and the reading, which is
    /// also why the identity guard that `readerClosed` needed has gone: there
    /// is nothing left for a stale reader to be confused with.
    private var child: Subprocess.Child?
    // Keep IDs unique across helper restarts, including callbacks already
    // queued on the actor when an old request was completed or cancelled.
    private var nextID = 1
    // Results cross an actor boundary, and a JSON dictionary isn't Sendable,
    // so they travel as raw bytes and are decoded on the far side.
    private struct PendingRequest {
        let continuation: CheckedContinuation<Data, Error>
        let timeout: Task<Void, Never>
    }
    private var pending: [Int: PendingRequest] = [:]
    private var buffer = Data()
    private let executable: URL?
    private let arguments: [String]
    private let requestTimeout: Duration

    /// The arguments are a parameter so a test can drive this against `/bin/sh`
    /// and a script. That is a real code path rather than a seam bolted on
    /// beside it: the handshake, the framing, the restart and the EOF handling
    /// all run exactly as they do with `codex app-server`, which is the only
    /// way to test any of it without the tool installed and signed in.
    init(
        executable: URL? = nil,
        arguments: [String] = ["app-server"],
        requestTimeout: Duration = .seconds(20)
    ) {
        self.executable = executable
        self.arguments = arguments
        self.requestTimeout = requestTimeout
    }

    enum Failure: Error {
        /// Codex isn't installed, or isn't anywhere we thought to look.
        case executableNotFound
        case startFailed
        case timedOut
        case server(String)
    }

    func setRateLimitsChangedHandler(_ handler: @escaping @Sendable () -> Void) {
        onRateLimitsChanged = handler
    }

    /// The account's limits, as `account/rateLimits/read` reports them, still
    /// encoded as JSON.
    func rateLimits() async throws -> Data {
        try await ensureRunning()
        return try await send(method: "account/rateLimits/read")
    }

    /// The account's token history, as `account/usage/read` reports it, still
    /// encoded as JSON.
    func accountUsage() async throws -> Data {
        try await ensureRunning()
        return try await send(method: "account/usage/read")
    }

    func shutDown() {
        child?.terminate()
        child = nil
        buffer.removeAll(keepingCapacity: false)
        failAllPending()
    }

    private func failAllPending() {
        for id in Array(pending.keys) { finish(id, with: .failure(Failure.startFailed)) }
    }

    // MARK: - Process

    private func ensureRunning() async throws {
        if let child, child.isRunning { return }

        // **Before starting another one.** Getting here with a child set means
        // the last one died or was shut down. Without this, every restart left
        // one more reader behind: three of them was 290% of a CPU for eleven
        // hours, with no child process left to blame (issue #25).
        shutDown()

        guard let executable = executable ?? Self.locateCodex() else { throw Failure.executableNotFound }

        let child: Subprocess.Child
        do {
            child = try Subprocess.Child(
                executable: executable,
                arguments: arguments,
                environment: NetworkSession.subprocessEnvironment()
            )
        } catch {
            // **Said out loud, because this is the one failure here that carries
            // no information otherwise.** `Failure.startFailed` is what the
            // caller sees, and it stands for four different things: a spawn that
            // failed, a write that did not land, a helper that exited, and a
            // helper that closed its output. When this fired on CI once and
            // nowhere else, the errno underneath was the only thing that could
            // have said which — and it was being discarded right here.
            Diagnostic.note("could not start the Codex helper", error)
            throw Failure.startFailed
        }

        // Set before `start()`, or a chunk that arrives in between is dropped.
        child.onOutput = { [weak self] chunk in
            Task { await self?.consume(chunk) }
        }
        // EOF, or a child that died: either way nothing more will answer, so
        // everything still waiting is failed now rather than at the twenty
        // second timeout — and the child is terminated rather than forgotten,
        // because EOF on stdout can also mean a helper that is still running
        // with its output closed.
        child.onExit = { [weak self] _ in
            Task { await self?.helperGone() }
        }
        // EOF on stdout is **not** the same as the helper exiting: it can close
        // its output and carry on. Dropping the child there would leave it
        // running with nothing able to kill it, so it is terminated — and
        // terminating is also what makes `onExit` fire next.
        child.onOutputClosed = { [weak self] in
            Task { await self?.outputClosed() }
        }
        child.start()
        self.child = child

        // The protocol opens with a handshake before anything else is accepted.
        _ = try await send(
            method: "initialize",
            params: ["clientInfo": ["name": "Pulse", "title": "Pulse", "version": "0.1"]]
        )
        notify(method: "initialized")
    }

    /// The helper's stdout reached EOF, which it can do while still running.
    private func outputClosed() {
        child?.terminate()
        shutDown()
    }

    /// The helper is finished, one way or another.
    ///
    /// Called from `onExit`, which fires after the child has been reaped, so
    /// `isRunning` and `exitCode` are both settled by the time this runs —
    /// unlike the `Process` path, where a dead child could report itself alive
    /// for ever.
    private func helperGone() {
        guard child?.isRunning != true else { return }
        shutDown()
    }

    /// Where `codex` tends to live. A GUI app inherits almost no `PATH`, so
    /// the usual install locations have to be checked by hand rather than
    /// relying on the environment.
    private static func locateCodex() -> URL? {
        let home = NSHomeDirectory()
        var candidates: [String] = []

        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/codex" }
        }

        candidates += [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.local/bin/codex",
            "\(home)/.bun/bin/codex",
            "\(home)/.volta/bin/codex"
        ]

        // Node installs put it under a version directory, so glob those.
        let nvm = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            candidates += versions.map { "\(nvm)/\($0)/bin/codex" }
        }

        return candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    // MARK: - Messaging

    private func send(method: String, params: [String: Any] = [:]) async throws -> Data {
        let id = nextID
        nextID += 1

        let message: [String: Any] = [
            "jsonrpc": "2.0", "id": id, "method": method, "params": params
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: message) else {
            throw Failure.startFailed
        }

        return try await withCheckedThrowingContinuation { continuation in
            // Nothing to write to means nothing will ever answer, and a
            // continuation nobody answers suspends its caller for ever.
            guard let child, child.isRunning else {
                continuation.resume(throwing: Failure.startFailed)
                return
            }

            // Strongly held, deliberately. Weakly, this server going away
            // before the timeout fires leaves every request it was carrying
            // suspended with nobody left to resume them — which Swift reports
            // as a leaked continuation and the caller experiences as a hang.
            // A strong reference costs at most twenty seconds of lifetime and
            // makes that impossible.
            let timeout = Task { [self] in
                do { try await Task.sleep(for: requestTimeout) }
                catch { return }
                finish(id, with: .failure(Failure.timedOut))
            }
            pending[id] = PendingRequest(continuation: continuation, timeout: timeout)
            write(data)
        }
    }

    private func notify(method: String, params: [String: Any] = [:]) {
        let message: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        guard
            let data = try? JSONSerialization.data(withJSONObject: message),
            child != nil
        else { return }

        write(data)
    }

    /// One line to the helper's standard input; close the connection if it has gone.
    ///
    /// **Writing to a pipe whose far end has closed raises SIGPIPE, and the
    /// default for SIGPIPE is to kill the process.** The helper exiting — it
    /// crashed, it was killed with the terminal it was started from, the user
    /// quit Codex — would take Pulse down with it, and from the outside that
    /// looks like the app crashing at random. `SIGPIPE` is ignored process-wide
    /// (see `AppDelegate`) so the write returns an error instead; this is the
    /// half that then treats the error as "the helper is gone" rather than
    /// carrying on writing into a dead pipe.
    private func write(_ data: Data) {
        guard let child else { return }
        var line = data
        line.append(Data("\n".utf8))
        // False means the write did not land. Whatever is left of the helper is
        // not usable, and the next call will start a fresh one.
        if !child.write(line) {
            Diagnostic.note("the Codex helper's stdin would not take a request", nil)
            shutDown()
        }
    }

    private func finish(_ id: Int, with result: Result<Data, Error>) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeout.cancel()
        request.continuation.resume(with: result)
    }

    /// Messages arrive as newline-delimited JSON, and a read can land
    /// mid-line, so hold the remainder until the next chunk completes it.
    private func consume(_ chunk: Data) {
        buffer.append(chunk)

        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = buffer[buffer.index(after: newline)...]
            guard !line.isEmpty,
                  let message = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            else { continue }
            handle(message)
        }
    }

    private func handle(_ message: [String: Any]) {
        if let id = message["id"] as? Int, pending[id] != nil {
            if let error = message["error"] as? [String: Any] {
                let text = error["message"] as? String ?? "unknown"
                finish(id, with: .failure(Failure.server(text)))
            } else {
                let result = message["result"] as? [String: Any] ?? [:]
                let data = (try? JSONSerialization.data(withJSONObject: result)) ?? Data("{}".utf8)
                finish(id, with: .success(data))
            }
            return
        }

        if message["method"] as? String == "account/rateLimits/updated" {
            onRateLimitsChanged?()
        }
    }
}
