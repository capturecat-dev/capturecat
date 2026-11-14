import Foundation

/// The App Group shared by the app, the broadcast extension and the share
/// extension: one UserDefaults suite, one container (the take inbox), and the
/// keychain access group the session token and the device link key live in.
nonisolated enum AppGroup {
    static let identifier = "group.so.capturecat.ios"

    enum Keys {
        static let apiBaseURL = "apiBaseURL"
        static let deviceID = "deviceID"
        static let preferredMacID = "preferredMacID"
        static let lastLinkKeyID = "lastLinkKeyID"
        /// "auto" | "stream" | "record" — set by the app right before it
        /// opens the broadcast picker; the extension reads and clears it.
        static let broadcastMode = "broadcastMode"
    }

    static var defaults: UserDefaults {
        UserDefaults(suiteName: identifier) ?? .standard
    }

    /// The shared container, or this process's Application Support when the
    /// group is unavailable (unsigned builds) — degraded but never a crash.
    static var containerURL: URL {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) {
            return url
        }
        let fallback = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CaptureCatGroup", isDirectory: true)
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    static func directory(_ name: String) -> URL {
        let url = containerURL.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
        ])
        return url
    }
}
