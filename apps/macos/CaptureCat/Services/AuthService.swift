import AppKit
import CryptoKit
import Foundation
import os

private let authLogger = Logger(subsystem: "so.capturecat.CaptureCat", category: "AuthService")

/// Where the CaptureCat API lives. Single source of truth for every client here.
nonisolated enum CaptureCatAPI {
    /// Debug talks to the local `wrangler dev` API; Release to production.
    /// A Debug build can be pointed at prod without rebuilding:
    ///   defaults write so.capturecat.CaptureCat apiBaseURL https://api.capturecat.so
    /// (and `defaults delete … apiBaseURL` to go back). Shares/uploads land in
    /// whichever stack this resolves to — a share made against localhost will
    /// never appear on the production dashboard.
    static var baseURL: String {
        // Debug-only, and https or loopback only. In a Release build this
        // override would let any local process (`defaults write …`) redirect
        // the session bearer token and the sign-in flow to an attacker host
        // over plain HTTP — the one way around the Keychain's protection.
        #if DEBUG
        if let override = UserDefaults.standard.string(forKey: "apiBaseURL"),
           let url = URL(string: override), let host = url.host,
           url.scheme == "https" || host == "localhost" || host == "127.0.0.1" {
            return override
        }
        return "http://localhost:8787"
        #else
        return "https://api.capturecat.so"
        #endif
    }
}

/// Desktop authentication against the CaptureCat API (Better Auth server-side).
///
/// FLOW (RFC 8252 native-app OAuth + RFC 7636 PKCE):
///  1. Generate a PKCE verifier/challenge and a random `state`.
///  2. Bind an ephemeral loopback port — BEFORE opening the browser, so no
///     other process can claim it — giving a redirect URI of
///     `http://127.0.0.1:<random port>/capturecat-auth/callback`.
///  3. Open the SYSTEM DEFAULT BROWSER at `/api/desktop/authorize`, which
///     starts the Google/Apple leg server-side. The default browser is
///     deliberate: it is RFC 8252 §7.3's prescribed pattern and it reuses the
///     user's existing provider session.
///  4. The browser is redirected back to the loopback listener with a
///     single-use `code`.
///  5. `POST /api/desktop/token` exchanges `code` + `code_verifier` for the
///     session token. The verifier never left this process, so a code observed
///     by anything else is worthless.
///  6. The token goes into the KEYCHAIN (see AuthKeychain) and is sent as
///     `Authorization: Bearer` on every API call.
///
/// No custom URL scheme is involved at any point — see LoopbackAuthServer for
/// why `capturecat://` would be a hijackable credential channel on macOS.
///
/// The public surface of this type is frozen: ExportSheetController,
/// StatusMenuBuilder, VideoExporter and AppState all call into it and are
/// owned by other work in flight.
@MainActor
final class AuthService: NSObject {
    /// The signed-in identity. Replaces the old SDK user object; callers only
    /// ever test it for nil or read `currentEmail` / `currentUID`.
    struct AuthenticatedUser: Equatable, Sendable {
        let uid: String
        let email: String?
        let name: String?
    }

    enum EntitlementState: String {
        case paid
        case tester
        case blocked
        case free
    }

    enum ExportAccessResult {
        case allowed
        case needsSignIn
        case blocked
        case notEntitled
        case requiresPublicEmail
    }

    enum AuthError: LocalizedError {
        case notSignedIn
        case signInAlreadyInProgress
        case loopbackUnavailable(String)
        case browserLaunchFailed
        case signInCancelled
        case signInTimedOut
        case stateMismatch
        case missingAuthorizationCode
        case providerRejected(String)
        case tokenExchangeFailed(String)
        case invalidServerResponse
        case sessionStorageFailed(String)
        case exportAccessDenied(String)

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                return "You are not signed in."
            case .signInAlreadyInProgress:
                return "A sign-in is already in progress. Finish it in your browser, or try again."
            case .loopbackUnavailable(let detail):
                return "Could not start the local sign-in listener: \(detail)"
            case .browserLaunchFailed:
                return "Could not open your browser to complete sign-in."
            case .signInCancelled:
                return "Sign-in was cancelled."
            case .signInTimedOut:
                return "Sign-in timed out. Try again and finish in the browser window."
            case .stateMismatch:
                return "Sign-in was rejected for security reasons (state mismatch). Please try again."
            case .missingAuthorizationCode:
                return "The sign-in callback did not include an authorization code."
            case .providerRejected(let detail):
                return detail.isEmpty ? "The identity provider rejected the sign-in." : detail
            case .tokenExchangeFailed(let detail):
                return "Could not complete sign-in: \(detail)"
            case .invalidServerResponse:
                return "Received an unexpected response from the CaptureCat server."
            case .sessionStorageFailed(let detail):
                return "Could not store your session securely: \(detail)"
            case .exportAccessDenied(let message):
                return message
            }
        }
    }

    // MARK: - Tunables

    /// How long the loopback listener waits for the browser round trip.
    private static let signInTimeout: TimeInterval = 5 * 60
    /// Offline export grace after the last successful entitlement check.
    private static let offlineExportGraceInterval: TimeInterval = 7 * 24 * 60 * 60
    /// How long a non-forced entitlement read may be served from memory.
    private static let entitlementCacheTTL: TimeInterval = 60

    private static let offlineExportNetworkErrorCodes: Set<Int> = [
        NSURLErrorNotConnectedToInternet,
        NSURLErrorTimedOut,
        NSURLErrorNetworkConnectionLost,
        NSURLErrorCannotConnectToHost,
        NSURLErrorCannotFindHost,
        NSURLErrorDNSLookupFailed,
        NSURLErrorDataNotAllowed,
        NSURLErrorInternationalRoamingOff,
        NSURLErrorSecureConnectionFailed,
    ]

    // MARK: - State

    var onAuthStateChange: (() -> Void)?
    /// Non-nil only when the client is misconfigured in a way that makes
    /// sign-in impossible. The old "missing config plist" failure mode is gone
    /// (nothing has to be bundled any more), so in practice this stays nil —
    /// the surface is kept because the export sheet and status menu render a
    /// banner from it.
    var configurationError: String?

    private(set) var currentUser: AuthenticatedUser?
    private(set) var currentEmail: String?
    private(set) var currentUID: String?

    private var activeServer: LoopbackAuthServer?
    private var signInInProgress = false
    private var cachedEntitlement: (state: EntitlementState, readAt: Date)?

    override init() {
        super.init()
    }

    // MARK: - Configuration / session restore

    /// Loads any stored session from the Keychain. `installAuthObserver` is
    /// retained for source compatibility: there is no external auth daemon to
    /// observe any more — every state change originates from this type.
    func configureIfNeeded(installAuthObserver: Bool = true) {
        _ = installAuthObserver
        configurationError = nil
        Self.scrubLegacyDefaults()
        restoreSessionFromKeychain()
    }

    /// One-time cleanup of the previous auth stack's plaintext cache. The
    /// export-access record lived in UserDefaults, where anyone with disk
    /// access could back-date it to extend the offline grace; it now rides
    /// inside the Keychain blob instead.
    private static func scrubLegacyDefaults() {
        UserDefaults.standard.removeObject(forKey: "AuthService.cachedExportAccess")
    }

    private func restoreSessionFromKeychain() {
        guard let stored = AuthKeychain.load() else {
            applyAuthState(nil)
            return
        }
        guard !stored.isExpired else {
            authLogger.info("stored session expired; clearing")
            AuthKeychain.clear()
            applyAuthState(nil)
            return
        }
        applyAuthState(AuthenticatedUser(uid: stored.userId, email: stored.email, name: stored.name))
    }

    var currentUserIdentityForAdmin: String? {
        guard let user = currentUser else { return nil }
        return "\(user.email ?? "no-email") (uid: \(user.uid))"
    }

    var usingPrivateRelayEmail: Bool {
        guard let email = currentEmail?.lowercased() else { return true }
        return email.hasSuffix("privaterelay.appleid.com")
    }

    // MARK: - Sign in

    /// Starts the one and only sign-in flow.
    ///
    /// The app deliberately does NOT name a provider. `/api/desktop/authorize`
    /// serves a chooser when the parameter is absent, so which identity
    /// providers exist — and which are offered first — is a server deploy
    /// rather than a macOS release. Everything security-relevant is unchanged:
    /// the loopback port is still reserved before the browser opens, and the
    /// PKCE verifier still never leaves this process.
    func signIn(presenting window: NSWindow? = nil) async throws {
        _ = window // The browser flow needs no NSWindow.
        guard !signInInProgress else { throw AuthError.signInAlreadyInProgress }
        signInInProgress = true

        // A previous abandoned attempt must not keep its port (or its pending
        // state) alive.
        activeServer?.cancel()
        activeServer = nil

        // 1. PKCE + state. The verifier stays in this frame and is never
        //    written anywhere; only its SHA-256 goes over the wire first.
        let pkce = OAuthPKCE.makeChallenge()
        let state = OAuthPKCE.randomURLSafeToken(byteCount: 16)

        // 2. Reserve the loopback port BEFORE the browser opens, so nothing
        //    else can claim it in between.
        let server: LoopbackAuthServer
        let port: UInt16
        do {
            (server, port) = try await Self.bindLoopbackServer()
        } catch {
            signInInProgress = false
            throw error
        }
        activeServer = server
        defer {
            server.cancel()
            if activeServer === server { activeServer = nil }
            signInInProgress = false
        }

        let redirectURI = OAuthPKCE.loopbackRedirectURI(port: port)
        guard OAuthPKCE.isValidLoopbackRedirectURI(redirectURI) else {
            throw AuthError.loopbackUnavailable("built an invalid redirect URI for port \(port)")
        }

        // 3. Hand off to the system default browser.
        guard let authorizeURL = Self.authorizeURL(
            redirectURI: redirectURI,
            challenge: pkce,
            state: state
        ) else {
            throw AuthError.invalidServerResponse
        }
        authLogger.info("opening browser for sign-in on port \(port, privacy: .public)")
        guard NSWorkspace.shared.open(authorizeURL) else {
            throw AuthError.browserLaunchFailed
        }

        // 4. Wait for the single loopback callback.
        let callback: LoopbackAuthServer.Callback
        do {
            callback = try await server.waitForCallback(timeout: Self.signInTimeout)
        } catch let error as LoopbackAuthServer.LoopbackError {
            switch error {
            case .timedOut: throw AuthError.signInTimedOut
            case .cancelled: throw AuthError.signInCancelled
            default: throw AuthError.loopbackUnavailable(error.localizedDescription)
            }
        }

        if let providerError = callback.error {
            throw AuthError.providerRejected(callback.errorDescription ?? providerError)
        }
        // Constant-time: never let the echoed state be probed byte by byte.
        guard let returnedState = callback.state,
              OAuthPKCE.constantTimeEquals(returnedState, state) else {
            throw AuthError.stateMismatch
        }
        guard let code = callback.code, !code.isEmpty else {
            throw AuthError.missingAuthorizationCode
        }

        // 5. Redeem the code. This is the only time the verifier is disclosed,
        //    and only to the CaptureCat API over TLS.
        let session = try await exchange(code: code, verifier: pkce.verifier, redirectURI: redirectURI)

        // 6. Persist in the Keychain.
        do {
            try AuthKeychain.save(session)
        } catch {
            throw AuthError.sessionStorageFailed(error.localizedDescription)
        }
        cachedEntitlement = nil
        applyAuthState(AuthenticatedUser(uid: session.userId, email: session.email, name: session.name))
        authLogger.info("signed in uid=\(session.userId, privacy: .public)")
    }

    /// Binds a loopback listener, retrying a couple of times. The kernel picks
    /// a different ephemeral port on each attempt, so a collision with another
    /// process is transient — retrying is strictly better than surfacing
    /// "port in use" to someone who just clicked Sign in.
    private static func bindLoopbackServer(attempts: Int = 3) async throws -> (LoopbackAuthServer, UInt16) {
        var lastError: Error?
        for attempt in 1...max(1, attempts) {
            let server = LoopbackAuthServer()
            do {
                return (server, try await server.start())
            } catch {
                server.cancel()
                lastError = error
                authLogger.error("loopback bind attempt \(attempt, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        throw AuthError.loopbackUnavailable(
            lastError?.localizedDescription ?? "no local port could be reserved"
        )
    }

    /// No `provider` query item on purpose — see `signIn()`. The server treats
    /// its absence as "show the chooser".
    /// `nonisolated` and non-private so `--auth-selftest` can assert its shape:
    /// it is a pure function of its arguments and touches no actor state.
    nonisolated static func authorizeURL(
        redirectURI: String,
        challenge: OAuthPKCE.Challenge,
        state: String
    ) -> URL? {
        var components = URLComponents(string: "\(CaptureCatAPI.baseURL)/api/desktop/authorize")
        components?.queryItems = [
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: challenge.challenge),
            URLQueryItem(name: "code_challenge_method", value: challenge.method),
            URLQueryItem(name: "state", value: state),
        ]
        return components?.url
    }

    private func exchange(
        code: String,
        verifier: String,
        redirectURI: String
    ) async throws -> AuthKeychain.StoredSession {
        var request = URLRequest(url: URL(string: "\(CaptureCatAPI.baseURL)/api/desktop/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "code": code,
            "code_verifier": verifier,
            // Binds the code to the exact port that requested it.
            "redirect_uri": redirectURI,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.invalidServerResponse
        }
        guard http.statusCode == 200 else {
            let detail = Self.errorMessage(from: data) ?? "HTTP \(http.statusCode)"
            authLogger.error("token exchange failed: \(detail, privacy: .public)")
            throw AuthError.tokenExchangeFailed(detail)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String, !token.isEmpty
        else {
            throw AuthError.invalidServerResponse
        }

        let user = json["user"] as? [String: Any]
        guard let uid = user?["id"] as? String, !uid.isEmpty else {
            throw AuthError.invalidServerResponse
        }

        return AuthKeychain.StoredSession(
            token: token,
            userId: uid,
            email: user?["email"] as? String,
            name: user?["name"] as? String,
            image: user?["image"] as? String,
            expiresAt: Self.parseDate(json["expiresAt"])
        )
    }

    // MARK: - Sign out

    /// Clears the Keychain immediately and revokes the session server-side in
    /// the background. Local state is dropped first on purpose: revocation
    /// must not be blockable by a flaky network.
    func signOut() throws {
        let token = AuthKeychain.load()?.token
        AuthKeychain.clear()
        activeServer?.cancel()
        activeServer = nil
        cachedEntitlement = nil
        applyAuthState(nil)

        guard let token else { return }
        Task.detached(priority: .utility) {
            await Self.revokeRemoteSession(token: token)
        }
    }

    private static func revokeRemoteSession(token: String) async {
        var request = URLRequest(url: URL(string: "\(CaptureCatAPI.baseURL)/api/desktop/revoke")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            authLogger.info("remote sign-out status=\(status, privacy: .public)")
        } catch {
            // The local credential is already gone; the server session will
            // lapse on its own.
            authLogger.warning("remote sign-out failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Entitlement

    /// Resolves the current tier from the server. The client is never the
    /// authority: `paid` comes from the Stripe-backed `subscription` table and
    /// `tester`/`blocked` are server-owned columns, so a cancelled subscription
    /// is revoked on the very next call (no cached claim to go stale).
    func refreshEntitlement(forceRefresh: Bool) async throws -> EntitlementState {
        guard let stored = AuthKeychain.load(), !stored.isExpired else {
            applyAuthState(nil)
            return .free
        }

        if !forceRefresh,
           let cached = cachedEntitlement,
           Date().timeIntervalSince(cached.readAt) < Self.entitlementCacheTTL {
            return cached.state
        }

        var request = URLRequest(url: URL(string: "\(CaptureCatAPI.baseURL)/api/me")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(stored.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.invalidServerResponse
        }

        if http.statusCode == 401 || http.statusCode == 403 {
            // The session was revoked, expired or the account was deleted.
            // 403 is the "blocked" answer from requireEntitlement, so keep the
            // session but report blocked; 401 means the credential is dead.
            if http.statusCode == 403, Self.errorMessage(from: data)?.lowercased().contains("blocked") == true {
                cachedEntitlement = (.blocked, Date())
                return .blocked
            }
            authLogger.info("session rejected by server; clearing local credential")
            AuthKeychain.clear()
            cachedEntitlement = nil
            applyAuthState(nil)
            return .free
        }

        guard http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw AuthError.tokenExchangeFailed(Self.errorMessage(from: data) ?? "HTTP \(http.statusCode)")
        }

        // Keep the local copy in step with the server's view. The expiry
        // matters most: Better Auth slides it forward as the session is used
        // WITHOUT changing the token, so mirroring it here is what stops an
        // active user being signed out on day 30 by a stale local timestamp.
        var refreshed = stored
        var changed = false

        if let serverExpiry = Self.parseDate(json["sessionExpiresAt"]),
           serverExpiry != stored.expiresAt {
            refreshed.expiresAt = serverExpiry
            changed = true
        }
        if let uid = json["uid"] as? String, !uid.isEmpty {
            let email = json["email"] as? String
            if uid != stored.userId || email != stored.email {
                refreshed.userId = uid
                refreshed.email = email
                changed = true
            }
            if uid != currentUID || email != currentEmail {
                applyAuthState(AuthenticatedUser(uid: uid, email: email, name: currentUser?.name))
            }
        }
        if changed {
            try? AuthKeychain.save(refreshed)
        }

        let state: EntitlementState
        if json["blocked"] as? Bool == true {
            state = .blocked
        } else {
            switch (json["tier"] as? String)?.lowercased() {
            case "paid": state = .paid
            case "tester": state = .tester
            case "blocked": state = .blocked
            default: state = .free
            }
        }

        cachedEntitlement = (state, Date())
        return state
    }

    func evaluateExportAccess() async throws -> ExportAccessResult {
        guard currentUser != nil else { return .needsSignIn }

        do {
            let entitlement = try await refreshEntitlement(forceRefresh: true)

            // refreshEntitlement clears local state when the server rejects the
            // credential — re-check rather than reporting "not entitled" for
            // what is really a signed-out session.
            guard currentUser != nil else { return .needsSignIn }

            if entitlement == .blocked {
                clearCachedExportAccess()
                return .blocked
            }

            if usingPrivateRelayEmail {
                clearCachedExportAccess()
                return .requiresPublicEmail
            }

            if entitlement == .paid || entitlement == .tester {
                cacheExportAccessForCurrentUser()
                return .allowed
            }

            clearCachedExportAccess()
            return .notEntitled
        } catch {
            if shouldAllowOfflineExport(using: error) {
                authLogger.info("evaluateExportAccess: allowing cached offline export access")
                return .allowed
            }
            throw error
        }
    }

    func exportAccessMessage(for result: ExportAccessResult) -> String {
        switch result {
        case .allowed:
            return ""
        case .needsSignIn:
            return "Export is available to paid users and approved testers. Sign in to continue."
        case .blocked:
            return "Your account is blocked. Contact support if you think this is a mistake."
        case .notEntitled:
            if let identity = currentUserIdentityForAdmin {
                return "Export is only available to paid users and approved testers.\n\nSigned in as:\n\(identity)\n\nSubscribe to CaptureCat Pro, or ask an admin to grant tester access to this account."
            }
            return "Export is only available to paid users and approved testers."
        case .requiresPublicEmail:
            return "Apple private relay email is not accepted for export access. Sign in with Google or use an Apple account that shares your real email."
        }
    }

    // MARK: - Offline grace

    private func shouldAllowOfflineExport(using error: Error) -> Bool {
        guard hasValidCachedExportAccessForCurrentUser() else { return false }
        return Self.isConnectivityError(error)
    }

    private func hasValidCachedExportAccessForCurrentUser() -> Bool {
        guard let uid = currentUID,
              let stored = AuthKeychain.load(),
              stored.userId == uid,
              let verifiedAt = stored.entitlementVerifiedAt
        else {
            return false
        }
        return Date().timeIntervalSince(verifiedAt) <= Self.offlineExportGraceInterval
    }

    private func cacheExportAccessForCurrentUser() {
        AuthKeychain.stampEntitlementVerified()
    }

    private func clearCachedExportAccess() {
        AuthKeychain.stampEntitlementVerified(at: nil)
    }

    // MARK: - State plumbing

    private func applyAuthState(_ user: AuthenticatedUser?) {
        let previousUID = currentUID
        let previousEmail = currentEmail

        currentUser = user
        currentUID = user?.uid
        currentEmail = user?.email

        if previousUID != currentUID || previousEmail != currentEmail {
            onAuthStateChange?()
        }
    }

    // MARK: - Error helpers

    /// True for errors the UI should swallow rather than raise an alert on:
    /// an explicit cancel, a dropped task, or the user simply walking away from
    /// the browser tab (which surfaces as the loopback timeout).
    nonisolated static func isUserCancellation(_ error: Error) -> Bool {
        if let authError = error as? AuthError {
            switch authError {
            case .signInCancelled, .signInTimedOut, .signInAlreadyInProgress:
                return true
            default:
                break
            }
        }

        if let loopbackError = error as? LoopbackAuthServer.LoopbackError {
            return loopbackError == .cancelled || loopbackError == .timedOut
        }

        if error is CancellationError { return true }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return true
        }
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSUserCancelledError {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isUserCancellation(underlying)
        }
        return false
    }

    private static func isConnectivityError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, offlineExportNetworkErrorCodes.contains(nsError.code) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isConnectivityError(underlying)
        }
        return false
    }

    /// Pulls a human-readable message out of an API error body without ever
    /// echoing raw HTML or a whole response back into an alert.
    static func errorMessage(from data: Data) -> String? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["error", "message", "error_description"] {
                if let value = json[key] as? String, !value.isEmpty {
                    return String(value.prefix(300))
                }
            }
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<") else { return nil }
        return String(trimmed.prefix(300))
    }

    static func parseDate(_ value: Any?) -> Date? {
        if let seconds = value as? Double { return Date(timeIntervalSince1970: seconds) }
        guard let text = value as? String, !text.isEmpty else { return nil }

        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}
