import AppKit
import Foundation
import os

private let remoteShotLogger = Logger(subsystem: "so.capturecat.CaptureCat", category: "RemoteScreenshotClient")

/// URL capture via the CaptureCat API's Chromium renderer —
/// `GET /api/screenshot/take` (Cloudflare Browser Rendering).
///
/// This replaced the local WKWebView path (`WebPageCapture`, now harness-only)
/// as the ONLY user-facing URL capture engine: the product decision is that a
/// captured page renders exactly what Chromium renders, on every plan, with no
/// silent WebKit fallback. The app authenticates exactly like every other API
/// call — the desktop session bearer token from `AuthKeychain` against
/// `CaptureCatAPI.baseURL` (Debug talks to `wrangler dev` on :8787; a Debug
/// build can be pointed at prod via `defaults write … apiBaseURL`).
///
/// Option → query-param mapping (must stay in lockstep with
/// `apps/api/src/lib/screenshot/params.ts`):
///   device preset      → `device` (desktop | tablet | mobile)
///   height .viewport   → (no full_page)
///   height .full       → `full_page=true` + `max_height_multiple=4`
///   height .entire     → `full_page=true`
///   darkMode           → `dark_mode=true`
///   reduceMotion       → `reduced_motion=true`
///   hideCookieBanners  → `block_cookie_banners=true`
///   hideChatWidgets    → `block_chats=true`
///   delaySeconds > 0   → `delay=<seconds>`
///   always             → `format=png`
@MainActor
final class RemoteScreenshotClient {
    enum ClientError: LocalizedError {
        case notSignedIn
        case unreachable(String)
        case api(String)
        case badResponse

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                return "Sign in to capture web pages."
            case .unreachable(let detail):
                return "The CaptureCat capture service could not be reached. \(detail)"
            case .api(let message):
                return message
            case .badResponse:
                return "The capture service returned an unexpected response."
            }
        }
    }

    /// Base URL for the screenshot endpoint. `CAPTURECAT_SCREENSHOT_BASE` is a
    /// live (getenv) override the headless probes set AFTER binding their stub
    /// listener; everything else resolves through `CaptureCatAPI.baseURL`
    /// (which itself honors the `apiBaseURL` defaults override for dev).
    nonisolated static var baseURL: String {
        if let raw = getenv("CAPTURECAT_SCREENSHOT_BASE"), let s = String(validatingUTF8: raw), s.hasPrefix("http") {
            return s
        }
        return CaptureCatAPI.baseURL
    }

    /// Bearer token: harness override first (the probes have no Keychain
    /// session), then the real desktop session.
    nonisolated static func currentToken() -> String? {
        if let raw = getenv("CAPTURECAT_SCREENSHOT_TOKEN"), let s = String(validatingUTF8: raw), !s.isEmpty {
            return s
        }
        return AuthKeychain.currentToken()
    }

    /// PURE option → query-param mapping, separated out so the probe can
    /// assert the exact wire shape for every option combination.
    nonisolated static func queryItems(
        url: URL,
        preset: WebDevicePreset,
        options: WebCaptureOptions
    ) -> [URLQueryItem] {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "url", value: url.absoluteString),
            URLQueryItem(name: "device", value: preset.rawValue),
            URLQueryItem(name: "format", value: "png"),
        ]
        switch options.heightMode {
        case .viewport:
            break // viewport-only is the endpoint's default
        case .full:
            items.append(URLQueryItem(name: "full_page", value: "true"))
            items.append(URLQueryItem(name: "max_height_multiple", value: "4"))
        case .entire:
            items.append(URLQueryItem(name: "full_page", value: "true"))
        }
        if options.darkMode { items.append(URLQueryItem(name: "dark_mode", value: "true")) }
        if options.reduceMotion { items.append(URLQueryItem(name: "reduced_motion", value: "true")) }
        if options.hideCookieBanners { items.append(URLQueryItem(name: "block_cookie_banners", value: "true")) }
        if options.hideChatWidgets { items.append(URLQueryItem(name: "block_chats", value: "true")) }
        if options.delaySeconds > 0 {
            items.append(URLQueryItem(name: "delay", value: String(options.delaySeconds)))
        }
        return items
    }

    /// Renders `url` via the API and returns the PNG as an NSImage, ready for
    /// the same StillMovieWriter pipeline the WKWebView snapshot used to feed.
    func capture(
        url: URL,
        preset: WebDevicePreset,
        options: WebCaptureOptions,
        timeout: TimeInterval = 75
    ) async throws -> NSImage {
        guard let token = Self.currentToken() else { throw ClientError.notSignedIn }

        var components = URLComponents(string: "\(Self.baseURL)/api/screenshot/take")
        components?.queryItems = Self.queryItems(url: url, preset: preset, options: options)
        guard let endpoint = components?.url else { throw ClientError.badResponse }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // Render time = navigation (≤30s) + user delay + Chromium spin-up.
        request.timeoutInterval = timeout + TimeInterval(options.delaySeconds)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            remoteShotLogger.error("screenshot fetch failed: \(error.localizedDescription, privacy: .public)")
            throw ClientError.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw ClientError.badResponse }

        guard http.statusCode == 200 else {
            if http.statusCode == 401 { throw ClientError.notSignedIn }
            // Quota / entitlement / render errors arrive screenshotone-shaped:
            // { error: { code, message } } — surface the API's message inline.
            let message = Self.apiErrorMessage(from: data) ?? "The page could not be captured (HTTP \(http.statusCode))."
            remoteShotLogger.error("screenshot API \(http.statusCode, privacy: .public): \(message, privacy: .public)")
            throw ClientError.api(message)
        }

        guard let image = NSImage(data: data), image.isValid else {
            throw ClientError.badResponse
        }
        return image
    }

    /// Pulls `error.message` out of the API's nested error envelope, falling
    /// back to AuthService's flat-body extraction.
    static func apiErrorMessage(from data: Data) -> String? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String, !message.isEmpty {
            return String(message.prefix(300))
        }
        return AuthService.errorMessage(from: data)
    }
}
