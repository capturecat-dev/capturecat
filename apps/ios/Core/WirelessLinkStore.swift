import Foundation

/// The account's device link key (see WirelessDeviceProtocol.swift): fetched
/// from the API with this app's session, cached in the shared keychain so the
/// broadcast extension can stream with no network round trip — and offline.
nonisolated enum WirelessLinkStore {
    static func cached() -> WirelessLink? {
        guard let data = SharedKeychain.get(account: SharedKeychain.Account.wirelessLink) else { return nil }
        return WirelessLink(key: data)
    }

    /// Fetch the current link from the API and cache it. Throws when signed
    /// out or offline; the keyId the API reports must match ours, or the key
    /// was decoded wrong and is never cached.
    @discardableResult
    static func refresh(api: APIClient = .shared) async throws -> WirelessLink {
        let response = try await api.wirelessLink()
        return try adopt(response)
    }

    /// "Forget my devices": a fresh key for the whole account.
    @discardableResult
    static func rotate(api: APIClient = .shared) async throws -> WirelessLink {
        try adopt(try await api.rotateWirelessLink())
    }

    /// Cached link, else one fetch.
    static func current(api: APIClient = .shared) async -> WirelessLink? {
        if let link = cached() { return link }
        return try? await refresh(api: api)
    }

    static func clear() {
        SharedKeychain.delete(account: SharedKeychain.Account.wirelessLink)
    }

    private static func adopt(_ response: WirelessLinkResponse) throws -> WirelessLink {
        guard let link = WirelessLink(base64URLKey: response.key), link.keyID == response.keyId else {
            throw APIError.invalidResponse
        }
        SharedKeychain.set(link.key, account: SharedKeychain.Account.wirelessLink)
        AppGroup.defaults.set(link.keyID, forKey: AppGroup.Keys.lastLinkKeyID)
        return link
    }
}
