import Foundation
import Network
import os

private let loopbackLogger = Logger(subsystem: "so.capturecat.CaptureCat", category: "LoopbackAuth")

/// Ephemeral loopback HTTP listener that receives the OAuth authorization code
/// (RFC 8252 §7.3, "Loopback Interface Redirection").
///
/// WHY THIS AND NOT A `capturecat://` CUSTOM SCHEME: on macOS any application can
/// register any URL scheme in its Info.plist, and LaunchServices will happily
/// hand the callback to whichever bundle it resolves — so a hostile local app
/// can intercept a code (or a token) delivered that way, and the user sees
/// nothing. A loopback socket cannot be hijacked: this process binds the port
/// itself, exclusively, before the browser is ever opened, and the port is
/// unpredictable per run. `ASWebAuthenticationSession` is unusable here for the
/// same reason — its `callbackURLScheme:` only accepts a custom scheme (and the
/// macOS 14.4 `callback:` variant only adds https universal links); neither can
/// receive `http://127.0.0.1:<random port>`.
///
/// Hardening applied here:
///  • bound to the loopback interface only (`requiredLocalEndpoint` 127.0.0.1),
///    so the socket is not reachable from the network at all;
///  • `allowLocalEndpointReuse = false` — an exclusive bind, no SO_REUSEPORT
///    shadowing by another process;
///  • every accepted peer is re-checked to be a loopback address;
///  • exactly one matching callback is served, then the listener is torn down;
///  • anything that is not `GET /capturecat-auth/callback` gets a 404 and is
///    dropped (browsers speculatively fetch `/favicon.ico`);
///  • hard cap on request bytes, and a caller-supplied overall timeout.
///
/// `nonisolated`: Network.framework calls back on its own queue and the
/// headless self-test drives this off the main actor.
nonisolated final class LoopbackAuthServer: @unchecked Sendable {
    /// The one path this listener answers on. Must match the server's
    /// redirect-URI validation byte for byte.
    static let callbackPath = OAuthPKCE.callbackPath

    /// Query parameters of the received callback.
    struct Callback: Sendable, Equatable {
        let query: [String: String]

        var code: String? { query["code"] }
        var state: String? { query["state"] }
        var error: String? { query["error"] }
        var errorDescription: String? { query["error_description"] }
    }

    enum LoopbackError: LocalizedError, Equatable {
        case alreadyStarted
        case notStarted
        case portUnavailable(String)
        case listenerFailed(String)
        case timedOut
        case cancelled

        var errorDescription: String? {
            switch self {
            case .alreadyStarted:
                return "The sign-in listener is already running."
            case .notStarted:
                return "The sign-in listener is not running."
            case .portUnavailable(let detail):
                return "Could not reserve a local port for sign-in: \(detail)"
            case .listenerFailed(let detail):
                return "The local sign-in listener failed: \(detail)"
            case .timedOut:
                return "Timed out waiting for the browser to finish signing in."
            case .cancelled:
                return "Sign-in was cancelled."
            }
        }
    }

    private let queue = DispatchQueue(label: "co.capturecat.auth.loopback")
    private let maximumRequestBytes = 16 * 1024

    // All of the following are touched only on `queue`.
    private var listener: NWListener?
    private var connectionsByID: [ObjectIdentifier: NWConnection] = [:]
    private var startContinuation: CheckedContinuation<UInt16, Error>?
    private var callbackContinuation: CheckedContinuation<Callback, Error>?
    private var timeoutWork: DispatchWorkItem?
    private var pendingResult: Result<Callback, Error>?
    private var completed = false
    private var boundPort: UInt16 = 0

    init() {}

    // MARK: - Lifecycle

    /// Binds an ephemeral port on 127.0.0.1 and returns it. Throws
    /// `.portUnavailable` when the bind cannot be satisfied — the caller can
    /// simply retry, since the kernel picks a different port each time.
    ///
    /// `preferredPort` exists so `--auth-selftest` can prove the
    /// "port already taken" path; production always takes the ephemeral port.
    func start(preferredPort: UInt16? = nil) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            queue.async {
                guard self.listener == nil, !self.completed else {
                    continuation.resume(throwing: LoopbackError.alreadyStarted)
                    return
                }

                let requested: NWEndpoint.Port = preferredPort
                    .flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any

                let parameters = NWParameters.tcp
                // Exclusive bind: refuse to share the port with anything else.
                parameters.allowLocalEndpointReuse = false
                // Bind to the loopback interface, kernel-assigned port.
                parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: requested)
                if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
                    tcp.noDelay = true
                }

                let listener: NWListener
                do {
                    listener = try NWListener(using: parameters)
                } catch {
                    continuation.resume(throwing: LoopbackError.portUnavailable(String(describing: error)))
                    return
                }

                self.startContinuation = continuation
                self.listener = listener

                listener.stateUpdateHandler = { [weak self] state in
                    self?.handleListenerState(state)
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                // The handlers above are invoked on this same queue, so no
                // additional hop (or lock) is needed anywhere below.
                listener.start(queue: self.queue)
            }
        }
    }

    /// Waits for the single callback request. Honours Task cancellation (the
    /// user backing out of sign-in) and a hard timeout (the user abandoning the
    /// browser tab).
    func waitForCallback(timeout: TimeInterval = 300) async throws -> Callback {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Callback, Error>) in
                queue.async {
                    // The browser may have beaten us here.
                    if let pending = self.pendingResult {
                        self.pendingResult = nil
                        continuation.resume(with: pending)
                        return
                    }
                    guard self.listener != nil, !self.completed else {
                        continuation.resume(throwing: LoopbackError.notStarted)
                        return
                    }
                    guard self.callbackContinuation == nil else {
                        continuation.resume(throwing: LoopbackError.alreadyStarted)
                        return
                    }

                    self.callbackContinuation = continuation
                    let work = DispatchWorkItem { [weak self] in
                        self?.completeLocked(.failure(LoopbackError.timedOut))
                    }
                    self.timeoutWork = work
                    self.queue.asyncAfter(deadline: .now() + timeout, execute: work)
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    /// Tears everything down. Safe to call repeatedly and from any thread; a
    /// pending `waitForCallback` fails with `.cancelled`.
    func cancel() {
        queue.async { self.completeLocked(.failure(LoopbackError.cancelled)) }
    }

    /// The bound port (0 before `start()` succeeds).
    var port: UInt16 {
        queue.sync { boundPort }
    }

    /// The redirect URI to hand to the authorization server.
    var redirectURI: String? {
        let port = self.port
        guard port != 0 else { return nil }
        return OAuthPKCE.loopbackRedirectURI(port: port)
    }

    // MARK: - Listener

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let rawPort = listener?.port?.rawValue, rawPort != 0 else {
                resumeStart(.failure(LoopbackError.portUnavailable("listener became ready without a port")))
                return
            }
            boundPort = rawPort
            loopbackLogger.info("loopback listener ready on 127.0.0.1:\(rawPort, privacy: .public)")
            resumeStart(.success(rawPort))

        case .waiting(let error):
            // For a loopback listener this means the bind could not be
            // satisfied — in practice, the port is taken. Surface it so the
            // caller can retry with a fresh one instead of hanging.
            loopbackLogger.error("loopback listener waiting: \(String(describing: error), privacy: .public)")
            let failure = LoopbackError.portUnavailable(String(describing: error))
            if startContinuation != nil {
                resumeStart(.failure(failure))
                completeLocked(.failure(failure))
            }

        case .failed(let error):
            loopbackLogger.error("loopback listener failed: \(String(describing: error), privacy: .public)")
            let failure = LoopbackError.listenerFailed(String(describing: error))
            resumeStart(.failure(failure))
            completeLocked(.failure(failure))

        case .cancelled:
            resumeStart(.failure(LoopbackError.cancelled))

        case .setup:
            break

        @unknown default:
            break
        }
    }

    private func resumeStart(_ result: Result<UInt16, Error>) {
        guard let continuation = startContinuation else { return }
        startContinuation = nil
        continuation.resume(with: result)
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        guard !completed else {
            connection.cancel()
            return
        }
        guard Self.isLoopbackPeer(connection.endpoint) else {
            // Cannot normally happen (the socket is bound to 127.0.0.1), but a
            // callback is a credential delivery — verify rather than assume.
            loopbackLogger.error("rejecting non-loopback peer \(String(describing: connection.endpoint), privacy: .public)")
            connection.cancel()
            return
        }

        connectionsByID[ObjectIdentifier(connection)] = connection

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receive(on: connection, buffer: Data())
            case .failed, .cancelled:
                self?.forget(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func forget(_ connection: NWConnection) {
        connectionsByID[ObjectIdentifier(connection)] = nil
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            if error != nil {
                connection.cancel()
                self.forget(connection)
                return
            }

            var accumulated = buffer
            if let chunk { accumulated.append(chunk) }

            if accumulated.count > self.maximumRequestBytes {
                self.respond(on: connection, status: "431 Request Header Fields Too Large", html: Self.errorHTML)
                return
            }

            // Only the request line is needed, but wait for the full header
            // block so a split first line is never mis-parsed.
            if let headerEnd = accumulated.range(of: Data("\r\n\r\n".utf8)) ?? accumulated.range(of: Data("\n\n".utf8)) {
                let head = accumulated.subdata(in: accumulated.startIndex..<headerEnd.lowerBound)
                self.handle(head: head, on: connection)
                return
            }

            if isComplete {
                self.handle(head: accumulated, on: connection)
                return
            }

            self.receive(on: connection, buffer: accumulated)
        }
    }

    private func handle(head: Data, on connection: NWConnection) {
        guard !completed else {
            connection.cancel()
            forget(connection)
            return
        }

        guard let text = String(data: head, encoding: .utf8),
              let request = Self.parseRequestLine(Self.firstLine(of: text))
        else {
            respond(on: connection, status: "400 Bad Request", html: Self.errorHTML)
            return
        }

        guard request.method == "GET", request.path == Self.callbackPath else {
            // Favicon probes, stray scans, anything else — 404 and keep waiting.
            respond(on: connection, status: "404 Not Found", html: Self.notFoundHTML)
            return
        }

        let callback = Callback(query: request.query)
        // Flush the "you can close this window" page BEFORE tearing the
        // listener down, otherwise the browser shows a connection error on a
        // sign-in that actually succeeded.
        respond(
            on: connection,
            status: "200 OK",
            html: callback.error == nil ? Self.successHTML : Self.providerErrorHTML(callback.errorDescription ?? callback.error ?? ""),
            then: { [weak self] in self?.completeLocked(.success(callback)) }
        )
    }

    private func respond(
        on connection: NWConnection,
        status: String,
        html: String,
        then completion: (() -> Void)? = nil
    ) {
        let body = Data(html.utf8)
        let header = """
        HTTP/1.1 \(status)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.count)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r

        """
        var payload = Data(header.utf8)
        payload.append(body)

        connection.send(content: payload, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            guard let self else {
                completion?()
                return
            }
            self.queue.async {
                self.forget(connection)
                completion?()
            }
        })
    }

    // MARK: - Completion / teardown

    private func completeLocked(_ result: Result<Callback, Error>) {
        guard !completed else { return }
        completed = true

        timeoutWork?.cancel()
        timeoutWork = nil

        if let continuation = callbackContinuation {
            callbackContinuation = nil
            continuation.resume(with: result)
        } else {
            pendingResult = result
        }

        listener?.newConnectionHandler = nil
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil

        for connection in connectionsByID.values {
            connection.cancel()
        }
        connectionsByID.removeAll()
    }

    // MARK: - Parsing

    fileprivate struct ParsedRequest {
        let method: String
        let path: String
        let query: [String: String]
    }

    fileprivate static func firstLine(of text: String) -> String {
        if let carriageReturn = text.range(of: "\r\n") {
            return String(text[..<carriageReturn.lowerBound])
        }
        if let newline = text.range(of: "\n") {
            return String(text[..<newline.lowerBound])
        }
        return text
    }

    fileprivate static func parseRequestLine(_ line: String) -> ParsedRequest? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]).uppercased()
        let target = String(parts[1])
        guard target.hasPrefix("/") else { return nil }

        guard let components = URLComponents(string: "http://127.0.0.1" + target) else { return nil }

        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            // FIRST value wins: a smuggled duplicate `code=` must not be able
            // to override the real one.
            if query[item.name] == nil {
                query[item.name] = item.value ?? ""
            }
        }
        return ParsedRequest(method: method, path: components.path, query: query)
    }

    static func isLoopbackPeer(_ endpoint: NWEndpoint) -> Bool {
        switch endpoint {
        case .hostPort(let host, _):
            switch host {
            case .ipv4(let address):
                return address.isLoopback
            case .ipv6(let address):
                return address.isLoopback || address.asIPv4?.isLoopback == true
            case .name(let name, _):
                return name == "localhost" || name == "127.0.0.1" || name == "::1"
            @unknown default:
                return false
            }
        default:
            return false
        }
    }

    // MARK: - Pages

    private static func page(title: String, message: String, accent: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(title)</title>
        <style>
          :root { color-scheme: light dark; }
          body { margin:0; min-height:100vh; display:flex; align-items:center; justify-content:center;
                 font: 400 15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
                 background:#f5f5f7; color:#1d1d1f; }
          @media (prefers-color-scheme: dark) { body { background:#1c1c1e; color:#f5f5f7; } }
          .card { text-align:center; padding:40px 48px; }
          .dot { width:44px; height:44px; border-radius:50%; background:\(accent); margin:0 auto 20px; }
          h1 { font-size:19px; margin:0 0 8px; font-weight:600; }
          p  { margin:0; opacity:.65; }
        </style></head>
        <body><div class="card"><div class="dot"></div>
        <h1>\(title)</h1><p>\(message)</p></div></body></html>
        """
    }

    static let successHTML = page(
        title: "You're signed in",
        message: "You can close this window and go back to CaptureCat.",
        accent: "#34c759"
    )

    static let notFoundHTML = page(
        title: "Not found",
        message: "This local page only handles the CaptureCat sign-in callback.",
        accent: "#8e8e93"
    )

    static let errorHTML = page(
        title: "Sign-in failed",
        message: "The callback could not be read. Please try again from CaptureCat.",
        accent: "#ff3b30"
    )

    static func providerErrorHTML(_ detail: String) -> String {
        page(
            title: "Sign-in failed",
            message: detail.isEmpty ? "Please try again from CaptureCat." : detail,
            accent: "#ff3b30"
        )
    }
}
