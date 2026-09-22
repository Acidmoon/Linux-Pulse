import Foundation

/// A short-lived connection to Kiro CLI's native Agent Client Protocol.
///
/// Authentication stays inside Kiro. Pulse starts the CLI, completes the ACP
/// handshake, asks for account usage, and then tears the helper down. Messages
/// are newline-delimited JSON; stderr is drained separately so a noisy helper
/// cannot fill its pipe and deadlock the request.
actor KiroACPClient {
    enum Failure: Error, Equatable {
        case executableNotFound
        case startFailed
        case timedOut
        case closed
        case server(String)
    }

    /// The helper, or nil when none is running.
    ///
    /// A `Subprocess.Child` rather than a `Process` and three pipes and two
    /// readability handlers. On this platform a handler never delivered EOF on
    /// a pipe that had carried bulk data, so a helper that wrote a partial line
    /// and exited left this client waiting out its whole deadline instead of
    /// reporting the connection closed. See `Docs/decisions/linux-subprocess.md`.
    private var child: Subprocess.Child?
    // IDs belong to the client, not the child process: a timeout already
    // queued on this actor must never find a new request under its old ID.
    private var nextID = 1
    private struct PendingRequest {
        let continuation: CheckedContinuation<Data, Error>
        let timeout: Task<Void, Never>
    }
    private var pending: [Int: PendingRequest] = [:]
    private var buffer = Data()
    private let executable: URL?
    private let requestTimeout: Duration

    // Tests use an isolated helper without changing PATH or touching a login.
    init(executable: URL? = nil, requestTimeout: Duration = .seconds(20)) {
        self.executable = executable
        self.requestTimeout = requestTimeout
    }

    func usage() async throws -> Data {
        try start()
        defer { shutDown() }

        // Kiro installs its auth connection while handling initialize. Sending
        // getUsage before that response arrives races with setConnection().
        _ = try await send(
            method: "initialize",
            params: [
                "protocolVersion": 1,
                "clientCapabilities": [:],
                "clientInfo": ["name": "Pulse", "version": "0.1"]
            ]
        )
        return try await send(method: "_kiro/account/getUsage")
    }

    func shutDown() {
        child?.terminate()
        child = nil
        buffer.removeAll(keepingCapacity: false)
        failAllPending(with: .closed)
    }

    private func start() throws {
        guard let executable = executable ?? Self.locateKiro() else { throw Failure.executableNotFound }

        let child: Subprocess.Child
        do {
            child = try Subprocess.Child(
                executable: executable,
                arguments: ["acp", "--agent-engine", "v3", "--auth-method", "cli"],
                environment: NetworkSession.subprocessEnvironment()
            )
        } catch {
            Diagnostic.note("could not start the Kiro helper", error)
            throw Failure.startFailed
        }

        // Before `start()`, or a chunk that arrives in between is dropped.
        child.onOutput = { [weak self] chunk in
            Task { await self?.consume(chunk) }
        }
        // stderr is not read into anything — Kiro writes diagnostics there and
        // nothing acts on them — but it still has to be drained, or a chatty
        // helper fills the 64 KiB pipe and blocks writing. The `Child` does
        // that with or without a handler set.
        //
        // EOF on stdout means the connection is gone, whether or not the process
        // is. Terminating rather than only failing the pending requests is the
        // same rule `CodexAppServer` follows: a helper with nothing to say must
        // not be left resident with nobody able to kill it.
        child.onOutputClosed = { [weak self] in
            Task { await self?.shutDown() }
        }
        child.start()
        self.child = child
    }

    private static func locateKiro() -> URL? {
        let home = NSHomeDirectory()
        var candidates: [String] = []
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/kiro-cli" }
        }
        candidates += [
            "/opt/homebrew/bin/kiro-cli",
            "/usr/local/bin/kiro-cli",
            "\(home)/bin/kiro-cli",
            "\(home)/.local/bin/kiro-cli",
            "/Applications/Kiro CLI.app/Contents/MacOS/kiro-cli",
            "/Applications/Kiro.app/Contents/Resources/app/bin/kiro-cli"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    private func send(method: String, params: [String: Any] = [:]) async throws -> Data {
        let id = nextID
        nextID += 1
        let message: [String: Any] = [
            "jsonrpc": "2.0", "id": id, "method": method, "params": params
        ]
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: message)
        } catch {
            throw Failure.startFailed
        }

        return try await withCheckedThrowingContinuation { continuation in
            guard let child, child.isRunning else {
                continuation.resume(throwing: Failure.closed)
                return
            }
            let timeout = Task { [self] in
                do { try await Task.sleep(for: requestTimeout) }
                catch { return }
                finish(id, with: .failure(Failure.timedOut))
            }
            pending[id] = PendingRequest(continuation: continuation, timeout: timeout)
            var line = data
            line.append(Data("\n".utf8))
            // False means the write did not land, so whatever is left of the
            // helper is not usable.
            if !child.write(line) {
                Diagnostic.note("the Kiro helper's stdin would not take a request", nil)
                shutDown()
            }
        }
    }

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
        guard let id = message["id"] as? Int, pending[id] != nil else { return }

        if let error = message["error"] as? [String: Any] {
            finish(id, with: .failure(Failure.server(error["message"] as? String ?? "unknown")))
            return
        }
        let result = message["result"] as? [String: Any] ?? [:]
        let data = (try? JSONSerialization.data(withJSONObject: result)) ?? Data("{}".utf8)
        finish(id, with: .success(data))
    }

    private func finish(_ id: Int, with result: Result<Data, Error>) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeout.cancel()
        request.continuation.resume(with: result)
    }

    private func failAllPending(with failure: Failure) {
        for id in Array(pending.keys) { finish(id, with: .failure(failure)) }
    }
}
