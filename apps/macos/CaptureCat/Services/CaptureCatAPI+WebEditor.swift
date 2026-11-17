import Foundation

// MARK: - Web editor URL

extension CaptureCatAPI {
    /// Prefix of the web editor route; the project id is appended.
    ///
    /// Release: https://app.capturecat.so/editor (the web Worker maps the app
    /// host onto its /app routes). Debug follows the API: against the local
    /// `wrangler dev` API it opens the local web dev server (TanStack Start on
    /// :3200, where the same route lives at /app/editor); against a remote API
    /// it opens production. Override without rebuilding (Debug only, https or
    /// loopback — same rule as `apiBaseURL`):
    ///   defaults write so.capturecat.CaptureCat webEditorBaseURL http://localhost:3201/app/editor
    nonisolated static var webEditorBaseURL: String {
        #if DEBUG
        if let override = UserDefaults.standard.string(forKey: "webEditorBaseURL"),
           let url = URL(string: override), let host = url.host,
           url.scheme == "https" || host == "localhost" || host == "127.0.0.1" {
            return override.hasSuffix("/") ? String(override.dropLast()) : override
        }
        if let host = URL(string: baseURL)?.host, host == "localhost" || host == "127.0.0.1" {
            return "http://localhost:3200/app/editor"
        }
        #endif
        return "https://app.capturecat.so/editor"
    }

    nonisolated static func webEditorURL(projectID: UUID) -> URL {
        URL(string: "\(webEditorBaseURL)/\(projectID.uuidString)")!
    }

    /// The web app's origin (scheme + host + port of `webEditorBaseURL`):
    /// app.capturecat.so, or the local dev server in Debug.
    nonisolated static var webAppOrigin: String {
        guard let url = URL(string: webEditorBaseURL), let scheme = url.scheme, let host = url.host else {
            return "https://app.capturecat.so"
        }
        return url.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
    }

    /// Where the sign-in browser tab ends (apps/web routes/connect.mac_.done.tsx):
    /// the loopback answers the callback with a redirect here, so the
    /// 127.0.0.1 hop is never the page anyone looks at.
    nonisolated static func signInDoneURL(result: String, detail: String? = nil) -> URL {
        var components = URLComponents(string: "\(webAppOrigin)/connect/mac/done")!
        components.queryItems = [URLQueryItem(name: "result", value: result)]
            + (detail.map { [URLQueryItem(name: "detail", value: String($0.prefix(300)))] } ?? [])
        return components.url!
    }
}
