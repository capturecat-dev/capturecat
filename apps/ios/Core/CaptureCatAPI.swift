import Foundation

/// Where the CaptureCat API lives — the iOS twin of the Mac's `CaptureCatAPI`
/// (apps/macos/CaptureCat/Services/AuthService.swift + CloudProjectSync.swift).
///
/// The shared `LoopbackAuthServer.swift` (compiled from the Mac tree) calls
/// `CaptureCatAPI.signInDoneURL(result:detail:)` to answer the loopback
/// callback with a redirect. On the Mac that is the web "done" page; here it is
/// `capturecat://auth-done…`, the scheme the ASWebAuthenticationSession is
/// watching, so the sign-in sheet closes itself the moment the code lands.
nonisolated enum CaptureCatAPI {
    /// Release: production. Debug: production too (a phone cannot reach the
    /// Mac's localhost), unless an override is set — launch with
    /// `-apiBaseURL http://127.0.0.1:8799` (the Simulator shares the Mac's
    /// loopback) and the app copies it into the App Group so the extensions
    /// follow. https or loopback only: an override must never send the bearer
    /// token over plain HTTP to another host.
    static var baseURL: String {
        #if DEBUG
        if let override = AppGroup.defaults.string(forKey: AppGroup.Keys.apiBaseURL), isAllowedOverride(override) {
            return override.hasSuffix("/") ? String(override.dropLast()) : override
        }
        #endif
        return "https://api.capturecat.so"
    }

    /// The web app's origin, for "Open on the web" links.
    static var webAppOrigin: String {
        #if DEBUG
        // A loopback API override pairs with the local web app (Debug only:
        // Release never carries a dev origin).
        if let host = URL(string: baseURL)?.host, host == "127.0.0.1" || host == "localhost" {
            return "http://localhost:3200"
        }
        #endif
        return "https://app.capturecat.so"
    }

    static func webEditorURL(projectID: String) -> URL {
        #if DEBUG
        let path = webAppOrigin.contains("localhost") ? "/app/editor/" : "/editor/"
        #else
        let path = "/editor/"
        #endif
        return URL(string: webAppOrigin + path + projectID.uppercased())!
    }

    /// The scheme the sign-in sheet watches; also the app's deep-link scheme.
    static let callbackScheme = "capturecat"

    /// Where the loopback listener sends the sign-in browser when the code
    /// (or an error) arrives. See the type comment.
    static func signInDoneURL(result: String, detail: String? = nil) -> URL {
        var components = URLComponents()
        components.scheme = callbackScheme
        components.host = "auth-done"
        components.queryItems = [URLQueryItem(name: "result", value: result)]
            + (detail.map { [URLQueryItem(name: "detail", value: String($0.prefix(300)))] } ?? [])
        return components.url!
    }

    #if DEBUG
    static func isAllowedOverride(_ value: String) -> Bool {
        guard let url = URL(string: value), let host = url.host else { return false }
        return url.scheme == "https" || host == "127.0.0.1" || host == "localhost"
    }

    /// Copy a `-apiBaseURL` launch argument into the App Group (or clear it
    /// with `-apiBaseURL ""`). Called once at app launch.
    static func adoptLaunchOverride() {
        guard let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-apiBaseURL") else { return }
        let args = ProcessInfo.processInfo.arguments
        let value = index + 1 < args.count ? args[index + 1] : ""
        if value.isEmpty {
            AppGroup.defaults.removeObject(forKey: AppGroup.Keys.apiBaseURL)
        } else if isAllowedOverride(value) {
            AppGroup.defaults.set(value, forKey: AppGroup.Keys.apiBaseURL)
        }
    }
    #endif
}
