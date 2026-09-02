import Foundation
import Security
import os

private let keychainLogger = Logger(subsystem: "so.capturecat.CaptureCat", category: "AuthKeychain")

/// Keychain storage for the desktop session bearer token.
///
/// WHY NOT UserDefaults: a `defaults` plist is a world-readable file inside the
/// app container. Anything stored there is extractable by any process running
/// as the user, and by anything with disk access — this app already had to
/// scrub a plaintext API key out of defaults once. A session token is a
/// full-privilege credential for the API; it belongs in the Keychain and
/// nowhere else.
///
/// Item shape: `kSecClassGenericPassword`, service `co.capturecat.auth`, account
/// `session`, value = JSON `StoredSession`, accessible
/// `AfterFirstUnlockThisDeviceOnly` (never leaves this Mac, never syncs to
/// iCloud, unavailable before first unlock).
///
/// `nonisolated` so the sign-in flow, ShareService and the headless self-test
/// can all reach it without hopping to the main actor.
nonisolated enum AuthKeychain {
    static let service = "co.capturecat.auth"
    static let defaultAccount = "session"

    /// Everything the app needs about the signed-in user. Only `token` is
    /// secret, but the whole blob lives in the Keychain so the offline export
    /// grace timestamp can't be back-dated by editing a plist.
    struct StoredSession: Codable, Equatable, Sendable {
        var token: String
        var userId: String
        var email: String?
        var name: String?
        var image: String?
        /// Server-reported session expiry. Better Auth rolls this forward in
        /// place on use (30-day window, refreshed daily) WITHOUT changing the
        /// token, so an active user never has to sign in again.
        var expiresAt: Date?
        /// Last time the server confirmed an export-worthy entitlement. Backs
        /// the 7-day offline export grace.
        var entitlementVerifiedAt: Date?

        init(
            token: String,
            userId: String,
            email: String? = nil,
            name: String? = nil,
            image: String? = nil,
            expiresAt: Date? = nil,
            entitlementVerifiedAt: Date? = nil
        ) {
            self.token = token
            self.userId = userId
            self.email = email
            self.name = name
            self.image = image
            self.expiresAt = expiresAt
            self.entitlementVerifiedAt = entitlementVerifiedAt
        }

        /// True when the server-reported expiry is in the past. A nil expiry is
        /// treated as valid — the server is the authority, and every API call
        /// re-checks the session in D1 anyway.
        var isExpired: Bool {
            guard let expiresAt else { return false }
            return expiresAt <= Date()
        }
    }

    enum KeychainError: LocalizedError {
        case unhandled(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unhandled(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
                return "Keychain error \(status): \(message)"
            }
        }
    }

    // MARK: - Public API

    static func save(_ session: StoredSession, account: String = defaultAccount) throws {
        let data = try JSONEncoder().encode(session)
        var lastStatus: OSStatus = errSecSuccess

        for useDataProtection in storagePreferences() {
            let status = write(data: data, account: account, useDataProtection: useDataProtection)
            if status == errSecSuccess {
                rememberStorageMode(useDataProtection)
                return
            }
            lastStatus = status
            guard isStorageModeRejection(status) else { break }
        }

        keychainLogger.error("save failed status=\(lastStatus, privacy: .public)")
        throw KeychainError.unhandled(lastStatus)
    }

    static func load(account: String = defaultAccount) -> StoredSession? {
        for useDataProtection in storagePreferences() {
            var query = baseQuery(account: account, useDataProtection: useDataProtection)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne

            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecSuccess, let data = item as? Data {
                rememberStorageMode(useDataProtection)
                guard let session = try? JSONDecoder().decode(StoredSession.self, from: data) else {
                    // Corrupt/legacy blob — drop it rather than half-trusting it.
                    keychainLogger.error("stored session could not be decoded; discarding")
                    clear(account: account)
                    return nil
                }
                return session
            }
            if !isStorageModeRejection(status) && status != errSecItemNotFound {
                keychainLogger.error("load failed status=\(status, privacy: .public)")
                return nil
            }
        }
        return nil
    }

    @discardableResult
    static func clear(account: String = defaultAccount) -> Bool {
        var removed = false
        for useDataProtection in [true, false] {
            let status = SecItemDelete(baseQuery(account: account, useDataProtection: useDataProtection) as CFDictionary)
            if status == errSecSuccess { removed = true }
        }
        return removed
    }

    /// The bearer token for API calls, or nil when signed out / expired.
    static func currentToken(account: String = defaultAccount) -> String? {
        guard let session = load(account: account), !session.isExpired else { return nil }
        return session.token
    }

    /// Rewrites just the entitlement timestamp, preserving the token.
    static func stampEntitlementVerified(at date: Date? = Date(), account: String = defaultAccount) {
        guard var session = load(account: account) else { return }
        session.entitlementVerifiedAt = date
        try? save(session, account: account)
    }

    // MARK: - Storage mode

    // The data-protection keychain is the right store: it is the only one that
    // honours kSecAttrAccessible and it is partitioned by code signature. It
    // requires the process to be signed with an application-identifier
    // entitlement, which the sandboxed app always is. An ad-hoc/unsigned build
    // (some CI configurations) gets errSecMissingEntitlement instead — falling
    // back to the file-based keychain there keeps development working without
    // ever putting the token somewhere unprotected.
    private nonisolated(unsafe) static var resolvedUseDataProtection: Bool?
    private static let storageModeLock = NSLock()

    private static func storagePreferences() -> [Bool] {
        storageModeLock.lock()
        defer { storageModeLock.unlock() }
        if let resolved = resolvedUseDataProtection { return [resolved] }
        return [true, false]
    }

    private static func rememberStorageMode(_ useDataProtection: Bool) {
        storageModeLock.lock()
        defer { storageModeLock.unlock() }
        if resolvedUseDataProtection == nil {
            resolvedUseDataProtection = useDataProtection
            if !useDataProtection {
                keychainLogger.notice("using the file-based keychain (data protection unavailable for this build)")
            }
        }
    }

    /// Statuses that mean "this keychain flavour is not usable here", as
    /// opposed to a genuine failure.
    private static func isStorageModeRejection(_ status: OSStatus) -> Bool {
        status == errSecMissingEntitlement || status == errSecParam || status == errSecNotAvailable
    }

    // MARK: - Queries

    private static func baseQuery(account: String, useDataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if useDataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    private static func write(data: Data, account: String, useDataProtection: Bool) -> OSStatus {
        let query = baseQuery(account: account, useDataProtection: useDataProtection)

        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return errSecSuccess }
        if isStorageModeRejection(updateStatus) { return updateStatus }

        // errSecItemNotFound (first write) or a stale/duplicate item: replace it.
        SecItemDelete(query as CFDictionary)

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrLabel as String] = "CaptureCat sign-in session"
        if useDataProtection {
            // Available after the first unlock, never synced to iCloud, never
            // restored onto another Mac.
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        return SecItemAdd(insert as CFDictionary, nil)
    }
}
