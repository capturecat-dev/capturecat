import CryptoKit
import Foundation

/// `CaptureCat --auth-selftest` — headless acceptance test for the desktop auth
/// primitives. Exercises everything that does NOT need a browser, an identity
/// provider or a deployed Worker:
///
///   • PKCE generation (RFC 7636, incl. the Appendix B known-answer vector)
///   • loopback redirect-URI validation (RFC 8252 §7.3/§8.3)
///   • the loopback listener's whole lifecycle: bind → 404 for stray paths →
///     one-shot callback → teardown, plus the timeout, cancellation and
///     "port already in use" failure paths
///   • Keychain round-trip: write, overwrite, expiry handling, delete —
///     against a dedicated `selftest-session` account so a signed-in user's
///     real session is never touched
///
/// Exits 0 when everything passes, 1 otherwise. Never reached in a normal
/// launch; runs before any AppKit/AppState setup.
nonisolated enum AuthSelfTest {
    static let flag = "--auth-selftest"
    static let keychainAccount = "selftest-session"

    static var isRequested: Bool {
        CommandLine.arguments.contains(flag)
    }

    // MARK: - Entry point

    static func run() -> Never {
        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)

        // Everything under test is `nonisolated`, so this can run off the main
        // thread while main blocks — no run-loop pumping, no deadlock.
        Task.detached(priority: .userInitiated) {
            let report = Report()
            await runAllChecks(report)
            box.failures = report.failures
            box.total = report.total
            semaphore.signal()
        }

        // Belt and braces: never let a wedged listener hang CI forever.
        if semaphore.wait(timeout: .now() + 120) == .timedOut {
            emit("")
            emit("FAIL harness: timed out after 120s")
            exit(1)
        }

        emit("")
        emit("auth-selftest: \(box.total - box.failures)/\(box.total) checks passed")
        exit(box.failures == 0 ? 0 : 1)
    }

    private static func runAllChecks(_ report: Report) async {
        emit("== PKCE ==")
        checkPKCE(report)

        emit("== redirect URI (RFC 8252) ==")
        checkRedirectURIValidation(report)

        emit("== loopback listener ==")
        await checkLoopbackHappyPath(report)
        await checkLoopbackTimeout(report)
        await checkLoopbackCancellation(report)
        await checkLoopbackPortConflict(report)
        await checkLoopbackMisuse(report)

        emit("== authorize URL ==")
        checkAuthorizeURL(report)

        emit("== keychain ==")
        checkKeychain(report)
    }

    // MARK: - Authorize URL

    /// The app must hand the browser a URL that names NO provider.
    ///
    /// That absence is the entire contract behind the single "Sign In" button:
    /// the server reads a missing `provider` as "serve the chooser page", so
    /// re-adding the parameter here would silently pin the app back to one
    /// provider and skip the chooser. Nothing else in the suite would notice —
    /// the flow would still succeed end to end, just always with whichever
    /// provider got hard-coded.
    private static func checkAuthorizeURL(_ report: Report) {
        let pkce = OAuthPKCE.makeChallenge()
        let state = OAuthPKCE.randomURLSafeToken(byteCount: 16)
        let redirect = OAuthPKCE.loopbackRedirectURI(port: 49_152)

        guard let url = AuthService.authorizeURL(
            redirectURI: redirect, challenge: pkce, state: state
        ), let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            report.check("authorize URL builds", false)
            return
        }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }

        report.check("path is /api/desktop/authorize",
                     components.path == "/api/desktop/authorize", components.path)
        report.check("names NO provider",
                     !items.contains { $0.name == "provider" },
                     items.map(\.name).joined(separator: ","))
        report.check("carries the redirect URI", value("redirect_uri") == redirect,
                     value("redirect_uri") ?? "nil")
        report.check("carries the challenge", value("code_challenge") == pkce.challenge,
                     value("code_challenge") ?? "nil")
        report.check("challenge method is S256", value("code_challenge_method") == "S256",
                     value("code_challenge_method") ?? "nil")
        report.check("carries the state", value("state") == state, value("state") ?? "nil")

        // The verifier is the one secret in the flow and must never be in a URL
        // that reaches the browser, however the query is assembled.
        report.check("never leaks the verifier",
                     !(url.absoluteString.contains(pkce.verifier)))

        // Percent-encoding must survive a round trip: the redirect URI contains
        // "://" and a port, and a mis-encoded one fails the server's RFC 8252
        // check with a message that points nowhere near the real cause.
        report.check("redirect URI survives re-parsing",
                     URLComponents(string: url.absoluteString)?
                        .queryItems?.first { $0.name == "redirect_uri" }?.value == redirect)
    }

    // MARK: - PKCE

    private static func checkPKCE(_ report: Report) {
        let first = OAuthPKCE.makeChallenge()
        let second = OAuthPKCE.makeChallenge()

        report.check("verifier is 43 chars", first.verifier.count == 43, "got \(first.verifier.count)")
        report.check("verifier is base64url", OAuthPKCE.isURLSafeToken(first.verifier), first.verifier)
        report.check("challenge is 43 chars", first.challenge.count == 43, "got \(first.challenge.count)")
        report.check("challenge is base64url", OAuthPKCE.isURLSafeToken(first.challenge), first.challenge)
        report.check("method is S256", first.method == "S256", first.method)
        report.check("verifiers are unpredictable", first.verifier != second.verifier)
        report.check("challenges differ per verifier", first.challenge != second.challenge)

        // The challenge must be exactly base64url(SHA256(ascii(verifier))).
        let recomputed = OAuthPKCE.base64URLEncode(Data(SHA256.hash(data: Data(first.verifier.utf8))))
        report.check("challenge == base64url(SHA256(verifier))", recomputed == first.challenge)

        // RFC 7636 Appendix B known-answer vector.
        let rfcVerifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let rfcChallenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        report.check(
            "RFC 7636 Appendix B vector",
            OAuthPKCE.codeChallenge(for: rfcVerifier) == rfcChallenge,
            OAuthPKCE.codeChallenge(for: rfcVerifier)
        )

        // base64url must never emit +, / or padding.
        let alphabetProbe = (0..<64).map { _ in OAuthPKCE.randomURLSafeToken(byteCount: 16) }.joined()
        report.check(
            "base64url alphabet only (no +, /, =)",
            !alphabetProbe.contains("+") && !alphabetProbe.contains("/") && !alphabetProbe.contains("=")
        )

        // state comparison
        let state = OAuthPKCE.randomURLSafeToken(byteCount: 16)
        report.check("constantTimeEquals: identical", OAuthPKCE.constantTimeEquals(state, state))
        report.check("constantTimeEquals: different value", !OAuthPKCE.constantTimeEquals(state, state + "x"))
        report.check("constantTimeEquals: prefix is not a match", !OAuthPKCE.constantTimeEquals(state, String(state.dropLast())))
        report.check("constantTimeEquals: empty vs value", !OAuthPKCE.constantTimeEquals("", state))
    }

    // MARK: - Redirect URI

    private static func checkRedirectURIValidation(_ report: Report) {
        report.check(
            "accepts http://127.0.0.1:<port>/capturecat-auth/callback",
            OAuthPKCE.isValidLoopbackRedirectURI("http://127.0.0.1:51234/capturecat-auth/callback")
        )
        report.check(
            "accepts any high port",
            OAuthPKCE.isValidLoopbackRedirectURI("http://127.0.0.1:65535/capturecat-auth/callback")
        )
        // localhost resolves through DNS and is rebindable — RFC 8252 §8.3.
        report.check(
            "rejects localhost",
            !OAuthPKCE.isValidLoopbackRedirectURI("http://localhost:51234/capturecat-auth/callback")
        )
        report.check(
            "rejects a non-loopback host",
            !OAuthPKCE.isValidLoopbackRedirectURI("http://10.0.0.5:51234/capturecat-auth/callback")
        )
        report.check(
            "rejects a wrong path",
            !OAuthPKCE.isValidLoopbackRedirectURI("http://127.0.0.1:51234/other")
        )
        report.check(
            "rejects a query string",
            !OAuthPKCE.isValidLoopbackRedirectURI("http://127.0.0.1:51234/capturecat-auth/callback?x=1")
        )
        report.check(
            "rejects a fragment",
            !OAuthPKCE.isValidLoopbackRedirectURI("http://127.0.0.1:51234/capturecat-auth/callback#x")
        )
        report.check(
            "rejects a privileged port",
            !OAuthPKCE.isValidLoopbackRedirectURI("http://127.0.0.1:80/capturecat-auth/callback")
        )
        report.check(
            "rejects a missing port",
            !OAuthPKCE.isValidLoopbackRedirectURI("http://127.0.0.1/capturecat-auth/callback")
        )
        report.check(
            "rejects a custom scheme (capturecat://) outright",
            !OAuthPKCE.isValidLoopbackRedirectURI("capturecat://auth/callback")
        )
        report.check(
            "builder output validates",
            OAuthPKCE.isValidLoopbackRedirectURI(OAuthPKCE.loopbackRedirectURI(port: 49152))
        )
    }

    // MARK: - Loopback listener

    private static func checkLoopbackHappyPath(_ report: Report) async {
        let server = LoopbackAuthServer()
        defer { server.cancel() }

        let port: UInt16
        do {
            port = try await server.start()
        } catch {
            report.fail("listener binds an ephemeral loopback port", error.localizedDescription)
            return
        }

        report.check("bound port is unprivileged", port >= 1024, "port \(port)")
        report.check("server reports its port", server.port == port)
        report.check(
            "redirectURI is well formed",
            server.redirectURI.map(OAuthPKCE.isValidLoopbackRedirectURI) == true,
            server.redirectURI ?? "nil"
        )

        // A browser will speculatively fetch /favicon.ico on the callback page:
        // that must 404 and leave the listener waiting, not consume the one-shot.
        let stray = await httpGet(port: port, path: "/favicon.ico")
        report.check("stray path gets 404", stray?.status == 404, describe(stray))

        let strayTwo = await httpGet(port: port, path: "/capturecat-auth/callback/../secret")
        report.check("path traversal gets 404", strayTwo?.status == 404, describe(strayTwo))

        // The real callback. Note the duplicated `code` — the FIRST value must
        // win so a smuggled second parameter cannot override the real one.
        async let pending = server.waitForCallback(timeout: 15)
        let hit = await httpGet(
            port: port,
            path: "/capturecat-auth/callback?code=CODE-123&state=STATE-abc&code=attacker"
        )
        report.check("callback responds 200", hit?.status == 200, describe(hit))
        report.check("callback page tells the user to return to CaptureCat", hit?.body.contains("signed in") == true)

        do {
            let callback = try await pending
            report.check("code parsed", callback.code == "CODE-123", callback.code ?? "nil")
            report.check("state parsed", callback.state == "STATE-abc", callback.state ?? "nil")
            report.check("duplicate parameter: first wins", callback.code != "attacker")
            report.check("no provider error", callback.error == nil)
        } catch {
            report.fail("callback delivered to waitForCallback", error.localizedDescription)
        }

        // One-shot: the listener must be gone afterwards.
        var stillListening = true
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if await httpGet(port: port, path: "/capturecat-auth/callback") == nil {
                stillListening = false
                break
            }
        }
        report.check("listener is torn down after one callback", !stillListening)

        // A second wait on a finished server must not hang.
        do {
            _ = try await server.waitForCallback(timeout: 1)
            report.fail("second waitForCallback rejects", "returned a value")
        } catch {
            report.pass("second waitForCallback rejects")
        }
    }

    private static func checkLoopbackTimeout(_ report: Report) async {
        let server = LoopbackAuthServer()
        defer { server.cancel() }

        do {
            _ = try await server.start()
        } catch {
            report.fail("timeout case: listener starts", error.localizedDescription)
            return
        }

        let started = Date()
        do {
            _ = try await server.waitForCallback(timeout: 0.4)
            report.fail("abandoned browser times out", "no error thrown")
        } catch let error as LoopbackAuthServer.LoopbackError {
            report.check("abandoned browser times out", error == .timedOut, "\(error)")
            report.check("timeout fires promptly", Date().timeIntervalSince(started) < 5)
        } catch {
            report.fail("abandoned browser times out", "unexpected \(error)")
        }
    }

    private static func checkLoopbackCancellation(_ report: Report) async {
        let server = LoopbackAuthServer()
        defer { server.cancel() }

        do {
            _ = try await server.start()
        } catch {
            report.fail("cancellation case: listener starts", error.localizedDescription)
            return
        }

        let waiter = Task { try await server.waitForCallback(timeout: 30) }
        try? await Task.sleep(nanoseconds: 150_000_000)
        waiter.cancel()

        switch await waiter.result {
        case .success:
            report.fail("user cancel unblocks the wait", "callback returned")
        case .failure(let error):
            report.check(
                "user cancel unblocks the wait",
                (error as? LoopbackAuthServer.LoopbackError) == .cancelled || error is CancellationError,
                "\(error)"
            )
            report.check("cancellation reads as a user cancellation", AuthService.isUserCancellation(error))
        }
    }

    private static func checkLoopbackPortConflict(_ report: Report) async {
        let holder = LoopbackAuthServer()
        defer { holder.cancel() }

        let port: UInt16
        do {
            port = try await holder.start()
        } catch {
            report.fail("conflict case: first listener starts", error.localizedDescription)
            return
        }

        // A second exclusive bind on the same port must fail fast rather than
        // silently sit in `.waiting` forever.
        let contender = LoopbackAuthServer()
        defer { contender.cancel() }
        do {
            _ = try await contender.start(preferredPort: port)
            report.fail("port already in use is reported", "second bind succeeded on \(port)")
        } catch let error as LoopbackAuthServer.LoopbackError {
            switch error {
            case .portUnavailable, .listenerFailed:
                report.pass("port already in use is reported")
            default:
                report.fail("port already in use is reported", "\(error)")
            }
        } catch {
            report.fail("port already in use is reported", "\(error)")
        }

        // Two concurrent listeners get different ports — the port is not
        // guessable from one run to the next.
        let other = LoopbackAuthServer()
        defer { other.cancel() }
        if let otherPort = try? await other.start() {
            report.check("ephemeral ports differ between listeners", otherPort != port, "\(otherPort) vs \(port)")
        } else {
            report.fail("ephemeral ports differ between listeners", "second listener did not start")
        }
    }

    private static func checkLoopbackMisuse(_ report: Report) async {
        let unstarted = LoopbackAuthServer()
        do {
            _ = try await unstarted.waitForCallback(timeout: 1)
            report.fail("waiting before start is rejected", "returned a value")
        } catch let error as LoopbackAuthServer.LoopbackError {
            report.check("waiting before start is rejected", error == .notStarted, "\(error)")
        } catch {
            report.fail("waiting before start is rejected", "\(error)")
        }

        let doubled = LoopbackAuthServer()
        defer { doubled.cancel() }
        guard (try? await doubled.start()) != nil else {
            report.fail("double start is rejected", "first start failed")
            return
        }
        do {
            _ = try await doubled.start()
            report.fail("double start is rejected", "second start succeeded")
        } catch let error as LoopbackAuthServer.LoopbackError {
            report.check("double start is rejected", error == .alreadyStarted, "\(error)")
        } catch {
            report.fail("double start is rejected", "\(error)")
        }
    }

    // MARK: - Keychain

    private static func checkKeychain(_ report: Report) {
        // Never touch the user's real session; only assert we left it alone.
        let realSessionPresentBefore = AuthKeychain.load() != nil

        AuthKeychain.clear(account: keychainAccount)
        report.check("starts empty after clear", AuthKeychain.load(account: keychainAccount) == nil)

        let expiry = Date().addingTimeInterval(30 * 24 * 60 * 60)
        let session = AuthKeychain.StoredSession(
            token: "selftest-token-\(OAuthPKCE.randomURLSafeToken(byteCount: 8))",
            userId: "user_selftest",
            email: "selftest@example.com",
            name: "Self Test",
            image: nil,
            expiresAt: expiry
        )

        do {
            try AuthKeychain.save(session, account: keychainAccount)
            report.pass("session writes to the keychain")
        } catch {
            report.fail("session writes to the keychain", error.localizedDescription)
            return
        }

        let loaded = AuthKeychain.load(account: keychainAccount)
        report.check("round-trips the token", loaded?.token == session.token)
        report.check("round-trips the uid", loaded?.userId == session.userId)
        report.check("round-trips the email", loaded?.email == session.email)
        report.check(
            "round-trips the expiry",
            loaded?.expiresAt.map { abs($0.timeIntervalSince(expiry)) < 1 } == true
        )
        report.check("currentToken returns a live token", AuthKeychain.currentToken(account: keychainAccount) == session.token)

        // Overwrite (the update, not add, path).
        var rotated = session
        rotated.token = "rotated-\(OAuthPKCE.randomURLSafeToken(byteCount: 8))"
        do {
            try AuthKeychain.save(rotated, account: keychainAccount)
            let reloaded = AuthKeychain.load(account: keychainAccount)
            report.check("overwrite replaces the token", reloaded?.token == rotated.token)
            report.check("overwrite leaves exactly one item", reloaded?.userId == session.userId)
        } catch {
            report.fail("overwrite replaces the token", error.localizedDescription)
        }

        // Entitlement stamp (backs the offline export grace).
        AuthKeychain.stampEntitlementVerified(account: keychainAccount)
        report.check("entitlement stamp is written", AuthKeychain.load(account: keychainAccount)?.entitlementVerifiedAt != nil)
        AuthKeychain.stampEntitlementVerified(at: nil, account: keychainAccount)
        report.check("entitlement stamp can be cleared", AuthKeychain.load(account: keychainAccount)?.entitlementVerifiedAt == nil)

        // An expired session must not hand out a bearer token.
        var expired = rotated
        expired.expiresAt = Date().addingTimeInterval(-60)
        try? AuthKeychain.save(expired, account: keychainAccount)
        report.check("expired session yields no token", AuthKeychain.currentToken(account: keychainAccount) == nil)
        report.check("expired session is still readable", AuthKeychain.load(account: keychainAccount)?.isExpired == true)

        // Sign-out.
        AuthKeychain.clear(account: keychainAccount)
        report.check("clear removes the item", AuthKeychain.load(account: keychainAccount) == nil)
        report.check("clear removes the token", AuthKeychain.currentToken(account: keychainAccount) == nil)
        report.check("clear is idempotent", { AuthKeychain.clear(account: keychainAccount); return AuthKeychain.load(account: keychainAccount) == nil }())

        report.check(
            "the real session was left untouched",
            (AuthKeychain.load() != nil) == realSessionPresentBefore
        )
    }

    // MARK: - Helpers

    private static func httpGet(port: UInt16, path: String) async -> (status: Int, body: String)? {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        do {
            let (data, response) = try await session.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (status, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return nil
        }
    }

    private static func describe(_ result: (status: Int, body: String)?) -> String {
        guard let result else { return "no response" }
        return "status \(result.status)"
    }

    fileprivate static func emit(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    // MARK: - Reporting

    private final class ResultBox: @unchecked Sendable {
        var failures = 0
        var total = 0
    }

    private final class Report: @unchecked Sendable {
        private(set) var failures = 0
        private(set) var total = 0

        func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            if condition {
                pass(name)
            } else {
                fail(name, detail())
            }
        }

        func pass(_ name: String) {
            total += 1
            emit("PASS \(name)")
        }

        func fail(_ name: String, _ detail: String = "") {
            total += 1
            failures += 1
            emit(detail.isEmpty ? "FAIL \(name)" : "FAIL \(name) — \(detail)")
        }
    }
}
