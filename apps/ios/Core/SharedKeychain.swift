import Foundation
import Security

/// Generic-password items in the App Group's keychain access group, so the
/// app, the broadcast extension and the share extension read the same session
/// token and device link key. `AfterFirstUnlockThisDeviceOnly`: the broadcast
/// extension runs while the phone may be locked mid-stream, and nothing here
/// should ever migrate to another device through a backup.
nonisolated enum SharedKeychain {
    static let service = "so.capturecat.ios"

    enum Account {
        static let session = "session"
        static let wirelessLink = "wireless-link"
    }

    @discardableResult
    static func set(_ data: Data, account: String) -> Bool {
        delete(account: account)
        var query = baseQuery(account: account, group: AppGroup.identifier)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        var status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecMissingEntitlement {
            // Unsigned/Simulator builds without the group entitlement: keep
            // working for the app itself (extensions just won't see it).
            var local = baseQuery(account: account, group: nil)
            local[kSecValueData as String] = data
            local[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(local as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    static func get(account: String) -> Data? {
        for group in [AppGroup.identifier, nil] as [String?] {
            var query = baseQuery(account: account, group: group)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecSuccess, let data = result as? Data { return data }
            if status != errSecMissingEntitlement && status != errSecItemNotFound { return nil }
        }
        return nil
    }

    static func delete(account: String) {
        for group in [AppGroup.identifier, nil] as [String?] {
            SecItemDelete(baseQuery(account: account, group: group) as CFDictionary)
        }
    }

    private static func baseQuery(account: String, group: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let group { query[kSecAttrAccessGroup as String] = group }
        return query
    }
}
