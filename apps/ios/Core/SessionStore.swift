import Foundation

/// The signed-in account, as `/api/desktop/token` returned it.
nonisolated struct AccountUser: Codable, Equatable, Sendable {
    var id: String
    var email: String?
    var name: String?
    var image: String?
}

/// A Better Auth session of this app's own (the consent page mints a NEW
/// session for the app — signing out of the browser never signs the phone out).
nonisolated struct AuthSession: Codable, Equatable, Sendable {
    var token: String
    var expiresAt: Date?
    var user: AccountUser
    /// The API the token belongs to — a Debug override switch must never send
    /// a production token to a local server or vice versa.
    var apiBaseURL: String
}

extension Notification.Name {
    /// Posted (on the main queue) when the stored session appears, changes or
    /// goes away — including when the API answers 401.
    static let ccSessionDidChange = Notification.Name("so.capturecat.ios.sessionDidChange")
}

nonisolated enum SessionStore {
    static func load() -> AuthSession? {
        guard let data = SharedKeychain.get(account: SharedKeychain.Account.session),
              let session = try? JSONDecoder.iso.decode(AuthSession.self, from: data),
              session.apiBaseURL == CaptureCatAPI.baseURL else { return nil }
        if let expiry = session.expiresAt, expiry < Date() { return nil }
        return session
    }

    static func save(_ session: AuthSession) {
        if let data = try? JSONEncoder.iso.encode(session) {
            SharedKeychain.set(data, account: SharedKeychain.Account.session)
        }
        postChange()
    }

    /// Slide the stored expiry forward (`/api/me` reports the live value).
    static func refreshExpiry(_ expiresAt: Date?) {
        guard var session = load(), let expiresAt, session.expiresAt != expiresAt else { return }
        session.expiresAt = expiresAt
        if let data = try? JSONEncoder.iso.encode(session) {
            SharedKeychain.set(data, account: SharedKeychain.Account.session)
        }
    }

    static func clear() {
        SharedKeychain.delete(account: SharedKeychain.Account.session)
        SharedKeychain.delete(account: SharedKeychain.Account.wirelessLink)
        postChange()
    }

    private static func postChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .ccSessionDidChange, object: nil)
        }
    }
}

nonisolated extension JSONDecoder {
    /// ISO-8601 dates with or without fractional seconds (the API emits both).
    static var iso: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = ISO8601.parse(text) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Bad date \(text)")
        }
        return decoder
    }
}

nonisolated extension JSONEncoder {
    static var iso: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

nonisolated enum ISO8601 {
    static func parse(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}
