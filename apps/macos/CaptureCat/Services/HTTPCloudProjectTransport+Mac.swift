import Foundation

// The Mac's session for the shared sync core (Studio/Sync): the Keychain's
// bearer token against `CaptureCatAPI.baseURL`.

extension HTTPCloudProjectTransport {
    convenience init(baseURL: String = CaptureCatAPI.baseURL) {
        self.init(baseURL: baseURL, token: { AuthKeychain.currentToken() })
    }
}

extension CloudProjectSync {
    /// The Mac's sync: this API, this install's client id.
    convenience init(transport: CloudProjectTransport) {
        self.init(transport: transport, apiBaseURL: CaptureCatAPI.baseURL)
    }
}
