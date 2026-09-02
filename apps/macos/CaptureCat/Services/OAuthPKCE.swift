import CryptoKit
import Foundation
import Security

/// RFC 7636 PKCE primitives for the desktop OAuth flow.
///
/// The verifier NEVER leaves this process: only `base64url(SHA256(verifier))`
/// is sent to the server when the flow starts, and the verifier itself is
/// presented exactly once, over TLS, on the code→token exchange. That binding
/// is what makes an intercepted authorization code useless to another app on
/// this machine.
///
/// `nonisolated` on purpose — the harness (`--auth-selftest`) exercises these
/// off the main actor, and none of it touches UI state.
nonisolated enum OAuthPKCE {
    /// A verifier + its S256 challenge. `method` is fixed: the server rejects
    /// `plain`, and so should we.
    struct Challenge: Sendable, Equatable {
        let verifier: String
        let challenge: String
        var method: String { "S256" }
    }

    /// 32 random bytes → 43-character base64url verifier (RFC 7636 §4.1 allows
    /// 43–128 characters; 43 is the exact length of 32 base64url-encoded bytes).
    static func makeChallenge() -> Challenge {
        let verifier = randomURLSafeToken(byteCount: 32)
        return Challenge(verifier: verifier, challenge: codeChallenge(for: verifier))
    }

    /// `base64url(SHA256(ascii(verifier)))`, no padding — RFC 7636 §4.2.
    static func codeChallenge(for verifier: String) -> String {
        base64URLEncode(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// CSPRNG-backed base64url token. Used for the verifier and for the OAuth
    /// `state` value.
    static func randomURLSafeToken(byteCount: Int = 32) -> String {
        base64URLEncode(randomBytes(count: byteCount))
    }

    static func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else {
            // SecRandomCopyBytes failing means the system CSPRNG is unavailable.
            // Continuing with predictable bytes would silently destroy the
            // security of the whole flow, so refuse instead.
            fatalError("SecRandomCopyBytes failed with status \(status)")
        }
        return Data(bytes)
    }

    /// base64url without padding (RFC 4648 §5).
    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The base64url alphabet, for validation.
    static let urlSafeAlphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    static func isURLSafeToken(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { urlSafeAlphabet.contains($0) }
    }

    /// Length-independent, byte-wise constant-time comparison. Used for the
    /// `state` echo check so a returned value can't be probed character by
    /// character through timing.
    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        var difference = UInt8(a.count == b.count ? 0 : 1)
        let width = max(a.count, b.count)
        guard width > 0 else { return true }
        for index in 0..<width {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            difference |= (x ^ y)
        }
        return difference == 0
    }

    // MARK: - Loopback redirect URI (RFC 8252 §7.3 / §8.3)

    /// The single path the loopback listener answers on.
    static let callbackPath = "/capturecat-auth/callback"

    static func loopbackRedirectURI(port: UInt16) -> String {
        "http://127.0.0.1:\(port)\(callbackPath)"
    }

    /// Mirror of the server-side validation, so a malformed URI is caught here
    /// rather than as an opaque 400 halfway through the browser dance.
    ///
    /// Deliberately rejects `localhost`: it resolves through DNS and is
    /// therefore rebindable, which is why RFC 8252 §8.3 recommends the literal
    /// loopback IP instead.
    static func isValidLoopbackRedirectURI(_ value: String) -> Bool {
        guard let url = URL(string: value),
              url.scheme == "http",
              let host = url.host,
              host == "127.0.0.1" || host == "::1",
              url.path == callbackPath,
              url.query == nil,
              url.fragment == nil,
              let port = url.port,
              port >= 1024, port <= 65535
        else {
            return false
        }
        return true
    }
}
