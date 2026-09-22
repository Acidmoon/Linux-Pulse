import Foundation
#if canImport(Network)
import Network
#endif
#if canImport(Glibc)
import Glibc
#endif

/// The other half of a browser sign-in: a listener on this Mac that the
/// provider redirects back to, carrying the authorization code.
///
/// Loopback only, for one request, and gone the moment it has what it came
/// for. The redirect is the one place in the flow the code passes through
/// something Pulse controls, so it is held for as short a time as possible.
///
/// **Starting is a separate step from waiting, and has to be.** The port is
/// only known once the listener is ready, and the redirect address — which
/// goes into the authorize request, before the browser is even opened — is
/// built from it. Folding the two together produced a redirect to port 0.
final class LoopbackCallback: @unchecked Sendable {
    /// The port actually bound, once `start()` has returned. A provider whose
    /// client is registered for one specific loopback address gets that or
    /// nothing; the rest take whatever is free, which is what the CLIs
    /// themselves do.
    private(set) var port: UInt16 = 0

    private let path: String
    private let requestedPort: UInt16?
    #if canImport(Network)
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.pulse.oauth-callback")
    #else
    /// The listening socket, or -1 once `stop()` has closed it.
    ///
    /// Closing it is also what unwedges the accept loop: `accept(2)` returns
    /// -1 on a descriptor that has been closed, so there is no separate
    /// cancellation flag to keep in step with the socket.
    private var listenFD: Int32 = -1
    private var acceptThread: Thread?
    #endif

    private let lock = NSLock()
    private var ready: CheckedContinuation<Void, Error>?
    private var waiting: CheckedContinuation<String, Error>?
    private var expectedState = ""
    private var captured: Result<String, Error>?
    private var settled = false

    init(port fixed: UInt16?, path: String) throws {
        self.path = path
        self.requestedPort = fixed

        #if canImport(Network)
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true

        let wanted = fixed.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any
        guard let listener = try? NWListener(using: parameters, on: wanted) else {
            throw OAuthLogin.Failure.portBusy(fixed ?? 0)
        }
        self.listener = listener
        #else
        // POSIX sockets, because Network.framework does not exist on Linux.
        //
        // The bind happens here rather than in `start()` on purpose: the port
        // has to be known before the redirect address is built, and a `bind`
        // that fails is the same `portBusy` the Network.framework path
        // reports. An address that cannot be taken is an ordinary outcome for
        // a fixed-port provider — usually the CLI's own sign-in holds it — not
        // an error to dress up as something else.
        //
        // 127.0.0.1 and not `INADDR_ANY`: this is the POSIX spelling of
        // `requiredInterfaceType = .loopback`, and it is what keeps an
        // authorization code off every other interface the machine has.
        //
        // Backlog 1, matching what the Network.framework path asks for: one
        // browser redirect arrives, or none does.
        let (fd, boundPort) = try Self.bindLoopback(to: fixed)
        self.listenFD = fd
        self.port = boundPort
        #endif
    }

    #if !canImport(Network)
    /// Binds a loopback listener and reports the descriptor and the port that
    /// was actually taken — which differs from the requested one when the
    /// caller passed nil and let the kernel choose.
    private static func bindLoopback(to fixed: UInt16?) throws -> (Int32, UInt16) {
        let failure = OAuthLogin.Failure.portBusy(fixed ?? 0)

        // `SOCK_STREAM` is an enum on Linux and an Int32 on Darwin, so the
        // raw value is taken rather than the case itself.
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { throw failure }

        // The POSIX form of `allowLocalEndpointReuse`. Without it a sign-in
        // retried straight after a failure hits TIME_WAIT and reports the port
        // as busy when nothing is listening on it any more.
        var reuse: Int32 = 1
        _ = withUnsafePointer(to: &reuse) {
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, $0, socklen_t(MemoryLayout<Int32>.size))
        }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = (fixed ?? 0).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 1) == 0 else {
            close(fd)
            throw failure
        }

        // The port the kernel picked, which is the whole reason `start()` is a
        // separate step from `awaitCode()`. Reporting 0 here is the bug the
        // comment at the top of this file records.
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else {
            close(fd)
            throw failure
        }

        return (fd, UInt16(bigEndian: actual.sin_port))
    }
    #endif

    /// Binds, and returns once the port is known.
    ///
    /// The `state` is taken here rather than at `awaitCode`, because the
    /// browser can beat that call: the redirect is answered on the listener's
    /// own queue as soon as it arrives, and until this sign-in's value is
    /// known every arrival is a mismatch. Set it before anything can come
    /// back, which is before the browser is even opened.
    func start(expecting state: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            expectedState = state
            ready = continuation
            lock.unlock()

            #if canImport(Network)
            listener.newConnectionHandler = { [weak self] connection in
                self?.serve(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.port = self.listener.port?.rawValue ?? self.requestedPort ?? 0
                    self.resumeReady(.success(()))
                case .failed, .cancelled, .waiting:
                    // The one address this provider accepts is taken, almost
                    // always by the CLI's own sign-in running right now.
                    //
                    // `.waiting` counts. A busy port does not fail a listener,
                    // it parks it there to retry — so a fixed-port sign-in
                    // would have hung with nothing on screen but a button that
                    // had stopped working.
                    let failure = OAuthLogin.Failure.portBusy(self.requestedPort ?? 0)
                    self.resumeReady(.failure(failure))
                    self.finish(.failure(failure))
                default:
                    break
                }
            }
            listener.start(queue: queue)
            #else
            // The socket is already bound and listening — see `init` — so the
            // port is known and readiness is immediate. What is left is to
            // start taking connections. That is also why the `.waiting` case
            // above has no counterpart here: a busy address failed the `bind`
            // and threw, rather than parking this and retrying.
            self.startAccepting()
            self.resumeReady(.success(()))
            #endif
        }
    }

    /// Resolves once the browser comes back.
    ///
    /// The `state` is checked here rather than by the caller: a redirect that
    /// does not carry the value this sign-in generated did not come from this
    /// sign-in, and the code in it is not ours to use.
    func awaitCode(giveUpAfter patience: Duration) async throws -> String {
        // Nothing here can tell a sign-in still being typed from one that
        // ended on the provider's own error page — that page never reaches
        // this listener at all. So the wait is bounded, and giving up is
        // reported rather than left to look like a button that stopped working.
        let timeout = Task {
            try? await Task.sleep(for: patience)
            guard !Task.isCancelled else { return }
            self.finish(.failure(OAuthLogin.Failure.timedOut))
        }
        defer { timeout.cancel() }

        // **Cancelling has to unwind this, not merely mark it cancelled.** A
        // bare continuation ignores cancellation entirely, so pressing Cancel
        // left the attempt running with its listener still bound — and five
        // minutes later the abandoned one's cleanup cleared the pane and wrote
        // a timeout into it, over the top of a second sign-in the user had
        // since started.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                lock.lock()

                // The browser can beat this call — a redirect that has already
                // arrived is answered from what was kept rather than waited for.
                if let captured {
                    lock.unlock()
                    continuation.resume(with: captured)
                    return
                }

                waiting = continuation
                lock.unlock()
            }
        } onCancel: {
            finish(.failure(CancellationError()))
            stop()
        }
    }

    func stop() {
        #if canImport(Network)
        listener.cancel()
        #else
        // Closing the descriptor is the whole of it: the blocked `accept(2)`
        // returns -1 and the loop below ends. Guarded so a second `stop()`
        // cannot close a descriptor number the process has since reused.
        lock.lock()
        let fd = listenFD
        listenFD = -1
        lock.unlock()

        if fd >= 0 { close(fd) }
        #endif
    }

    // MARK: - One request, then done

    #if canImport(Network)
    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, accumulated: Data())
    }

    private func receive(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8 * 1024) { [weak self] chunk, _, done, _ in
            guard let self else { return }

            var buffer = accumulated
            if let chunk { buffer.append(chunk) }

            // The request line is all this needs and it arrives in the first
            // packet; the rest is read only so the browser isn't left writing
            // into a socket nobody is reading.
            guard
                let text = String(data: buffer, encoding: .utf8),
                text.contains("\r\n\r\n") || done,
                let line = text.split(separator: "\r\n").first
            else {
                if done {
                    connection.cancel()
                } else {
                    self.receive(on: connection, accumulated: buffer)
                }
                return
            }

            self.answer(connection, with: self.handle(requestLine: String(line)))
        }
    }

    private func answer(_ connection: NWConnection, with message: String) {
        let body = Self.page(for: message)
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """

        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
    #endif

    /// Returns what to tell the browser, and settles the sign-in.
    private func handle(requestLine: String) -> String {
        let parts = requestLine.split(separator: " ")
        guard
            parts.count >= 2,
            let components = URLComponents(string: "http://localhost\(parts[1])"),
            components.path == path
        else { return String.localized("This page can be closed.") }

        // Read from the *encoded* items and decoded here, because a query
        // string spells a space as "+" and `URLComponents` will not undo that
        // — a provider's "User+declined" arrives verbatim otherwise. Doing it
        // before decoding rather than after is what keeps a literal plus in a
        // code (which arrives as "%2B") from being turned into a space.
        let items = components.percentEncodedQueryItems ?? []
        func value(_ name: String) -> String? {
            guard let raw = items.first(where: { $0.name == name })?.value else { return nil }
            return raw.replacingOccurrences(of: "+", with: "%20").removingPercentEncoding
        }

        if let error = value("error_description") ?? value("error") {
            finish(.failure(OAuthLogin.Failure.refused(error)))
            return String.localized("Sign-in failed. You can close this page.")
        }

        lock.lock()
        let expected = expectedState
        lock.unlock()

        guard let code = value("code"), value("state") == expected else {
            finish(.failure(OAuthLogin.Failure.cancelled))
            return String.localized("Sign-in failed. You can close this page.")
        }

        finish(.success(code))
        return String.localized("Signed in. You can close this page and go back to Pulse.")
    }

    /// The page a browser is left looking at.
    ///
    /// Shared by both transports so the two cannot drift into answering with
    /// different copy — the message is the whole of what the user sees.
    private static func page(for message: String) -> String {
        """
        <!doctype html><meta charset="utf-8"><title>Pulse</title>
        <body style="font:16px system-ui,sans-serif;display:grid;place-items:center;height:90vh;margin:0">
        <p>\(message)</p>
        """
    }

    #if !canImport(Network)
    /// Serves connections one at a time until `stop()` closes the socket.
    ///
    /// A dedicated thread rather than a `DispatchSource`, because the work is
    /// a blocking read on a blocking descriptor and there is exactly one
    /// expected connection. Serialising them is a feature: two arrivals are
    /// either a browser retry or a stray request, and both want the same
    /// idempotent `finish` the rest of this file already guarantees.
    private func startAccepting() {
        let thread = Thread { [weak self] in
            while let self, self.listenFD >= 0 {
                let client = accept(self.listenFD, nil, nil)
                guard client >= 0 else { break }
                self.serveDescriptor(client)
            }
        }
        thread.name = "com.pulse.oauth-callback"
        acceptThread = thread
        thread.start()
    }

    /// Reads the request line, answers it, and closes.
    private func serveDescriptor(_ client: Int32) {
        defer { close(client) }

        // The request line is all this needs and it arrives in the first
        // packet. Reading on to the blank line is only so the browser is not
        // left writing into a socket nobody is reading; the cap stops a
        // request with no header terminator from growing without bound.
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8 * 1024)
        while buffer.count < 64 * 1024 {
            let read_ = read(client, &chunk, chunk.count)
            guard read_ > 0 else { break }
            buffer.append(contentsOf: chunk[0..<read_])
            if let text = String(data: buffer, encoding: .utf8), text.contains("\r\n\r\n") {
                break
            }
        }

        let request = String(data: buffer, encoding: .utf8) ?? ""
        let line = request.split(separator: "\r\n").first.map(String.init) ?? ""
        let message = handle(requestLine: line)

        writeResponse(message, to: client)
    }

    private func writeResponse(_ message: String, to client: Int32) {
        let body = Self.page(for: message)
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """

        let bytes = Array(response.utf8)
        var written = 0
        // `write` may take fewer bytes than it was given. A browser sitting on
        // a half-written response would show a blank page rather than the
        // "you can close this" line, so the remainder is written out.
        while written < bytes.count {
            let result = bytes.withUnsafeBufferPointer { pointer in
                write(client, pointer.baseAddress! + written, bytes.count - written)
            }
            guard result > 0 else { break }
            written += result
        }
    }
    #endif

    private func resumeReady(_ result: Result<Void, Error>) {
        lock.lock()
        guard let continuation = ready else { lock.unlock(); return }
        ready = nil
        lock.unlock()

        continuation.resume(with: result)
    }

    /// Settles once and once only: a browser that retries the redirect, or a
    /// listener failing after the code has already arrived, must not resume a
    /// continuation twice.
    private func finish(_ result: Result<String, Error>) {
        lock.lock()
        guard !settled else { lock.unlock(); return }
        settled = true

        guard let continuation = waiting else {
            // Nobody is waiting yet; keep it for whoever asks.
            captured = result
            lock.unlock()
            return
        }
        waiting = nil
        lock.unlock()

        continuation.resume(with: result)
    }
}
