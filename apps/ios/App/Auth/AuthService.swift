import AuthenticationServices
import UIKit

/// Sign in to CaptureCat — the Mac's flow (RFC 8252 loopback + RFC 7636 PKCE,
/// apps/api/src/routes/desktop.ts) with the SAME listener and PKCE code,
/// compiled from the Mac tree:
///
///  1. PKCE verifier/challenge + random state.
///  2. Bind 127.0.0.1:<random port> BEFORE opening the browser (the app is in
///     the foreground for the whole flow, so the listener is never suspended).
///  3. ASWebAuthenticationSession opens `/api/desktop/authorize?client=ios`,
///     which sends the browser to the consent page on app.capturecat.so
///     ("Allow CaptureCat for iPhone and iPad…"). It shares Safari's cookies, so
///     someone already signed in on the web just taps Allow.
///  4. The consent page redirects to the loopback with the one-time code; the
///     listener answers 303 → `capturecat://auth-done?result=…`, the scheme
///     the session is watching, so the sheet closes by itself. The code itself
///     never travels through the custom scheme.
///  5. `/api/desktop/token` redeems code + verifier for a NEW session of the
///     phone's own (signing out of the browser never signs the phone out).
@MainActor
final class AuthService: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = AuthService()

    enum AuthError: LocalizedError {
        case cancelled
        case denied
        case stateMismatch
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled: return String(localized: "Sign-in was cancelled.")
            case .denied: return String(localized: "CaptureCat wasn't given access.")
            case .stateMismatch: return String(localized: "Sign-in couldn't be verified. Try again.")
            case let .failed(message): return message
            }
        }
    }

    private weak var anchorWindow: UIWindow?
    private var webSession: ASWebAuthenticationSession?
    private(set) var isSigningIn = false

    var session: AuthSession? { SessionStore.load() }
    var isSignedIn: Bool { session != nil }

    /// Run the whole flow. Resolves with the stored session.
    func signIn(from window: UIWindow?) async throws -> AuthSession {
        guard !isSigningIn else { throw AuthError.failed(String(localized: "Sign-in is already in progress.")) }
        isSigningIn = true
        defer { isSigningIn = false; webSession = nil }
        anchorWindow = window

        let pkce = OAuthPKCE.makeChallenge()
        let state = OAuthPKCE.randomURLSafeToken(byteCount: 24)
        let listener = LoopbackAuthServer()
        let port: UInt16
        do {
            port = try await listener.start()
        } catch {
            throw AuthError.failed(String(localized: "Couldn't start sign-in on this device. Try again."))
        }
        let redirectURI = OAuthPKCE.loopbackRedirectURI(port: port)

        var components = URLComponents(string: CaptureCatAPI.baseURL + "/api/desktop/authorize")!
        components.queryItems = [
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: pkce.method),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "client", value: "ios"),
        ]

        let web = ASWebAuthenticationSession(url: components.url!, callbackURLScheme: CaptureCatAPI.callbackScheme) { _, error in
            // The loopback is the source of truth; the sheet closing without a
            // callback (the user swiped it away) cancels the wait.
            if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                listener.cancel()
            }
        }
        web.presentationContextProvider = self
        web.prefersEphemeralWebBrowserSession = false
        webSession = web
        guard web.start() else {
            listener.cancel()
            throw AuthError.failed(String(localized: "Couldn't open the sign-in page."))
        }

        let callback: LoopbackAuthServer.Callback
        do {
            callback = try await listener.waitForCallback(timeout: 600)
        } catch LoopbackAuthServer.LoopbackError.cancelled {
            web.cancel()
            throw AuthError.cancelled
        } catch {
            web.cancel()
            throw AuthError.failed(error.localizedDescription)
        }

        if let error = callback.error {
            throw error == "access_denied" ? AuthError.denied : AuthError.failed(callback.errorDescription ?? String(localized: "Sign-in failed."))
        }
        guard let returned = callback.state, OAuthPKCE.constantTimeEquals(returned, state) else {
            throw AuthError.stateMismatch
        }
        guard let code = callback.code else { throw AuthError.failed(String(localized: "Sign-in didn't return a code.")) }

        let session = try await APIClient.shared.redeem(code: code, verifier: pkce.verifier, redirectURI: redirectURI)
        SessionStore.save(session)
        Task { await DeviceRegistry.shared.register() }
        Task { try? await WirelessLinkStore.refresh() }
        return session
    }

    /// Sign this phone out: forget its device row (no more pushes), end the
    /// server session, then drop every credential from the shared keychain.
    func signOut() async {
        await DeviceRegistry.shared.unregister()
        await APIClient.shared.revoke()
        WirelessLinkStore.clear()
        SessionStore.clear()
    }

    /// The account was deleted: the server already dropped the session, the
    /// device rows and the link key, so nothing is asked of it — this only
    /// forgets this device's copies (shared keychain, so the extensions stop
    /// too). Posts `.ccSessionDidChange`.
    func forgetCredentials() {
        WirelessLinkStore.clear()
        SessionStore.clear()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if let anchorWindow { return anchorWindow }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}
