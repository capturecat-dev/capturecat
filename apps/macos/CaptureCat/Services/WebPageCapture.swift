import AppKit
import AVFoundation
import WebKit

/// Which device's layout a web capture renders. The preset governs the LAYOUT
/// viewport (CSS width media queries), the user agent (UA-sniffing sites), and
/// the output pixel density — Desktop is the default and must produce the
/// desktop design of a desktop-class site.
///
/// Raw values are persistence identity (UserDefaults `webCaptureDevice`) —
/// never rename one.
enum WebDevicePreset: String, CaseIterable {
    case desktop
    case tablet
    case mobile

    var title: String {
        switch self {
        case .desktop: return "Desktop"
        case .tablet: return "Tablet"
        case .mobile: return "Mobile"
        }
    }

    var symbol: String {
        switch self {
        case .desktop: return "desktopcomputer"
        case .tablet: return "ipad.landscape"
        case .mobile: return "iphone"
        }
    }

    /// CSS layout viewport width in points — what media queries see.
    var viewportWidth: CGFloat {
        switch self {
        case .desktop: return 1440
        case .tablet: return 834
        case .mobile: return 390
        }
    }

    /// Initial (pre-measure) viewport height.
    var viewportHeight: CGFloat {
        switch self {
        case .desktop: return 900
        case .tablet: return 1194
        case .mobile: return 844
        }
    }

    /// Output pixels per layout point (2x desktop/tablet, 3x phone).
    var scaleFactor: CGFloat {
        switch self {
        case .desktop, .tablet: return 2
        case .mobile: return 3
        }
    }

    /// Explicit UA per device. NEVER left at WKWebView's default: that UA has
    /// no `Version/… Safari/…` tokens, and UA-sniffing sites treat it as an
    /// unknown/bot browser and serve their fallback (often mobile) markup even
    /// at a 1440pt viewport — the stripe.com bug.
    var userAgent: String {
        switch self {
        case .desktop:
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"
        case .tablet:
            return "Mozilla/5.0 (iPad; CPU OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
        case .mobile:
            return "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
        }
    }
}

/// Loads a URL offscreen and returns a full-page screenshot.
///
/// ## HARNESS-ONLY since 2026-08-10
///
/// The user-facing URL capture path renders via the CaptureCat API's Chromium
/// engine (`RemoteScreenshotClient` → `/api/screenshot/take`) — product
/// decision: 100% Chromium, no WebKit fallback. This type stays compiled
/// because the `--url-capture-test` / `--web-device-test` harness fixtures
/// exercise it (and `normalize` remains the shared pure URL normalizer), but
/// nothing reachable from the UI may call `capture` any more.
///
/// # Why WKWebView and not a headless service (historical)
///
/// Rendering a page needs a browser engine. Doing it here means no new
/// infrastructure and no per-capture cost, it works offline, and — the part
/// that actually matters to a user — the page renders as THIS Mac sees it:
/// their fonts, their cookies, their logged-in sessions. A server-side renderer
/// would always screenshot a logged-out stranger's view of the page.
///
/// The trade is that this is Safari's engine on the user's machine, so a heavy
/// page is as slow here as it would be in a browser tab.
///
/// # Full page, not viewport
///
/// `WKSnapshotConfiguration` captures the visible viewport unless the web view
/// is itself as tall as the document. So the view is resized to the measured
/// content height before snapshotting rather than scrolling and stitching,
/// which avoids seams and repeated sticky headers.
/// How tall a web capture is.
///
/// Default is `.viewport`: a full-page grab of a long site is a 10–14:1
/// sliver (stripe.com measured 834×12,000pt — `naturalSize (1112, 16000)` in
/// the editor after the density cap squashed the scale), which is almost
/// never what "screenshot stripe.com" means. The framed viewport shot is; the
/// long forms stay one toggle away. Raw values are persistence identity.
nonisolated enum WebHeightMode: String, CaseIterable {
    /// Exactly the device viewport (e.g. desktop 1440×900).
    case viewport
    /// Page height up to 4× the viewport — long enough to read as "the page",
    /// short enough to keep a sane aspect and full 2x/3x density.
    case full
    /// The old unbounded behavior (scrollHeight up to 12,000pt); very tall
    /// pages trade density for encodability here.
    case entire

    var title: String {
        switch self {
        case .viewport: return "Viewport"
        case .full: return "Full ×4"
        case .entire: return "Entire Page"
        }
    }
}

/// The screenshotone-style options a URL capture honors, applied inside
/// `WebPageCapture` before the snapshot. Persisted by AppState.
nonisolated struct WebCaptureOptions: Equatable {
    var heightMode: WebHeightMode = .viewport
    var darkMode = false
    var hideCookieBanners = false
    var hideChatWidgets = false
    var reduceMotion = false
    /// Seconds to wait before snapshotting (lazy-loading content).
    var delaySeconds: Int = 0
}

/// Curated CSS hide-lists for cookie banners / chat widgets.
///
/// Cookie-banner coverage is `CookieRuleCatalog` (the generated EasyList
/// Cookie List artifact, shared byte-for-byte with the API worker) PLUS the
/// hand-verified selectors below — kept as a local overrides layer for what
/// we have proven by eye (Google/Stripe interstitials etc.).
///
/// KEEP IN SYNC BY HAND with `apps/api/src/lib/screenshot/hide-rules.ts` —
/// the API worker's copy is the source of truth; both files carry this
/// comment. Last synced 2026-08-10.
enum WebHideRules {
    static let cookieBanners: [String] = [
        // OneTrust
        "#onetrust-consent-sdk", "#onetrust-banner-sdk",
        // Cookiebot
        "#CybotCookiebotDialog", "#CybotCookiebotDialogBodyUnderlay",
        // Quantcast / TCF CMPs
        "#qc-cmp2-container", ".qc-cmp2-container",
        // TrustArc
        "#truste-consent-track", ".truste_box_overlay", ".truste_overlay",
        // Didomi
        "#didomi-host", "#didomi-popup",
        // Usercentrics
        "#usercentrics-root", "#usercentrics-cmp-ui",
        // Sourcepoint
        ".sp-message-container", "[id^='sp_message_container']",
        // Osano
        ".osano-cm-window",
        // CookieYes
        ".cky-consent-container", ".cky-overlay",
        // Complianz
        "#cmplz-cookiebanner-container",
        // Borlabs
        "#BorlabsCookieBox",
        // iubenda
        "#iubenda-cs-banner",
        // Termly
        "#termly-code-snippet-support",
        // Google consent interstitial ("Before you continue to Google…"):
        // #xe7COe is the dialog wrapper, #KjcHPc its scrim, #CXQnmb the card;
        // the aria-label rule is the fallback for when the obfuscated ids rotate.
        "#xe7COe", "#CXQnmb", "#KjcHPc",
        "div[aria-modal='true'][aria-label*='Before you continue']",
        // Stripe (self-hosted CookieSettings card, bottom-right)
        "#cookie-settings-notification",
        "[data-testid='cookie-settings-notification']",
        "[class*='CookieSettings_CookieSettings_']",
        // Generic patterns
        "[class*='cookie-banner']", "[id*='cookie-banner']",
        "[class*='cookie-consent']", "[id*='cookie-consent']",
        "[aria-label='cookieconsent']",
    ]

    /// Scroll-lock releases paired with `cookieBanners`: consent managers that
    /// lock body scroll while their modal is up. Hiding the modal alone leaves
    /// `overflow:hidden` behind, which truncates full/entire-height measures.
    /// Scoped to verified lock classes — never a bare `body` override.
    static let cookieBannerScrollRestore: [String] = [
        // Google consent: body gets .EM1Mrb { overflow: hidden }
        "body.EM1Mrb",
    ]

    static let chatWidgets: [String] = [
        // Intercom
        "#intercom-container", ".intercom-lightweight-app",
        "iframe[name='intercom-launcher-frame']",
        // Drift
        "#drift-frame-controller", "#drift-frame-chat", "#drift-widget-container",
        // Zendesk
        "iframe#launcher", "iframe[title='Button to launch messaging window']", "#webWidget",
        // Crisp
        "#crisp-chatbox",
        // Tawk.to
        "iframe[title='chat widget']", "#tawkchat-container",
        // HubSpot
        "#hubspot-messages-iframe-container",
        // LiveChat
        "#chat-widget-container",
        // Tidio
        "#tidio-chat", "iframe#tidio-chat-iframe",
        // Freshchat
        "#fc_frame",
        // Olark
        "#olark-wrapper",
        // Gorgias
        "#gorgias-chat-container",
    ]
}

@MainActor
final class WebPageCapture: NSObject, WKNavigationDelegate {
    enum CaptureError: LocalizedError {
        case invalidURL(String)
        case navigationFailed(String)
        case timedOut
        case snapshotFailed(String)
        case httpError(Int, String)

        var errorDescription: String? {
            switch self {
            case .invalidURL(let s): return "\"\(s)\" is not a valid web address."
            case .navigationFailed(let s): return "The page could not be loaded: \(s)"
            case .timedOut: return "The page took too long to load."
            case .snapshotFailed(let s): return "The page could not be captured: \(s)"
            case .httpError(let code, let host):
                if code == 403 || code == 401 {
                    return "\(host) refused the request (HTTP \(code)). Sites behind bot protection often block automated browsers."
                }
                return "\(host) returned HTTP \(code)."
            }
        }
    }

    /// Viewport used while loading. Width drives responsive layout, so it is a
    /// desktop width on purpose — a narrow one would capture the mobile design.
    static let viewportWidth: CGFloat = 1440
    static let viewportHeight: CGFloat = 900
    /// Cap on the rendered height. Some pages are effectively infinite
    /// (endless scroll); without a ceiling the snapshot allocates until it dies.
    static let maxPageHeight: CGFloat = 12_000
    /// Cap on the OUTPUT pixel height. The capture is encoded into a movie by
    /// StillMovieWriter, and the video encoder rejects dimensions past ~16k —
    /// a 12,000pt page at 2x is 24,000px and failed to encode. On such pages
    /// the effective device scale drops instead (layout is unaffected; only
    /// output density is).
    static let maxOutputPixels: CGFloat = 16_000

    private var webView: WKWebView?
    /// Status of the MAIN-FRAME response. A 403 or 404 navigates and finishes
    /// perfectly happily — the failure is the page's content, not the load —
    /// so this is the only signal that we are about to screenshot an error page.
    private var mainFrameStatus: Int?
    private var mainFrameHost: String = ""
    private var continuation: CheckedContinuation<Void, Error>?
    private var finished = false

    /// Normalises what a person actually types: `example.com`,
    /// `www.example.com/x`, or a full URL. A bare host with no scheme is the
    /// common case and `URL(string:)` accepts it while producing something with
    /// no host, which then fails much later and confusingly.
    static func normalize(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: withScheme),
              let host = url.host, host.contains(".") || host == "localhost" else { return nil }
        return url
    }

    func capture(_ raw: String, preset: WebDevicePreset = .desktop,
                 options: WebCaptureOptions = WebCaptureOptions(), timeout: TimeInterval = 30) async throws -> NSImage {
        guard let url = Self.normalize(raw) else { throw CaptureError.invalidURL(raw) }
        return try await capture(url: url, preset: preset, options: options, timeout: timeout)
    }

    /// Direct-URL entry (also used by the harness with file:// fixtures, which
    /// `normalize` rightly rejects for typed input).
    func capture(url: URL, preset: WebDevicePreset = .desktop,
                 options: WebCaptureOptions = WebCaptureOptions(), timeout: TimeInterval = 30) async throws -> NSImage {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true
        if options.darkMode {
            // Belt-and-braces beside the NSAppearance override below: sites
            // like google.com read `window.matchMedia('(prefers-color-scheme:
            // dark)')` in script that executes while the document is still
            // parsing, and the appearance's trip through the web content
            // process is not guaranteed to have landed by that first tick.
            // A `.atDocumentStart` user script pins the JS answer to dark
            // before ANY page code runs. Media-query lists still come from
            // the real (dark) appearance, so listeners keep working.
            let source = """
            (() => {
              const orig = window.matchMedia.bind(window);
              window.matchMedia = (q) => {
                const m = orig(q);
                if (String(q).includes('prefers-color-scheme')) {
                  const matches = String(q).includes('dark');
                  try { Object.defineProperty(m, 'matches', { get: () => matches }); } catch (e) {}
                }
                return m;
              };
              document.documentElement.style.colorScheme = 'dark';
            })();
            """
            config.userContentController.addUserScript(WKUserScript(
                source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        let view = WKWebView(
            frame: NSRect(x: 0, y: 0, width: preset.viewportWidth, height: preset.viewportHeight),
            configuration: config
        )
        // Composition: the PRESET governs the layout viewport (frame width +
        // UA + output density). The frame width is what CSS media queries see;
        // the UA is what UA-sniffing sites branch on. Both must agree or a
        // responsive site and a sniffing site would disagree about the device.
        view.customUserAgent = preset.userAgent
        // The view's effective appearance is what WebKit maps to
        // `prefers-color-scheme` — a real media-query flip, not a CSS filter.
        // ALWAYS explicit: left to inherit, the web view picks up the app's
        // own dark appearance and "light" captures come back dark on a
        // dark-mode Mac (caught by the WEBDEV `light default` fixture).
        view.appearance = NSAppearance(named: options.darkMode ? .darkAqua : .aqua)
        view.navigationDelegate = self
        webView = view

        view.load(URLRequest(url: url, timeoutInterval: timeout))

        // Wait for didFinish / didFail, with our own ceiling — WKWebView's
        // request timeout does not cover a page that loads forever in JS.
        let waiter = Task { [weak self] in
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                self?.continuation = c
            }
        }
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self.finish(.failure(CaptureError.timedOut))
        }
        defer { timer.cancel(); webView = nil }
        try await waiter.value

        // Let webfonts settle and above-the-fold animations land. Without this
        // the capture regularly catches a flash of unstyled text.
        try? await Task.sleep(nanoseconds: 700_000_000)

        if options.darkMode {
            let probe = try? await view.evaluateJavaScript(
                "window.matchMedia('(prefers-color-scheme: dark)').matches")
            print("WEBCAP dark-probe matchMedia=\((probe as? Bool).map(String.init) ?? "nil")")
        }

        // Option CSS goes in BEFORE the height measure — a hidden cookie
        // banner changes the page height.
        if let css = Self.optionCSS(options, host: url.host) {
            let escaped = String(decoding: (try? JSONEncoder().encode(css)) ?? Data("\"\"".utf8), as: UTF8.self)
            let js = """
            (function(){var s=document.createElement('style');s.id='capturecat-options';\
            s.textContent=\(escaped);document.documentElement.appendChild(s);})(); true
            """
            _ = try? await view.evaluateJavaScript(js)
        }

        // User-requested settle for lazy-loading content.
        if options.delaySeconds > 0 {
            try? await Task.sleep(nanoseconds: UInt64(options.delaySeconds) * 1_000_000_000)
        }

        let height: CGFloat
        switch options.heightMode {
        case .viewport:
            height = preset.viewportHeight
        case .full:
            let measured = try await measuredHeight(of: view, minimum: preset.viewportHeight)
            height = min(measured, preset.viewportHeight * 4)
        case .entire:
            height = try await measuredHeight(of: view, minimum: preset.viewportHeight)
        }
        view.frame = NSRect(x: 0, y: 0, width: preset.viewportWidth, height: height)
        // A resize reflows; give layout a beat before snapshotting.
        try? await Task.sleep(nanoseconds: 350_000_000)

        let shot = WKSnapshotConfiguration()
        shot.rect = CGRect(x: 0, y: 0, width: preset.viewportWidth, height: height)
        shot.afterScreenUpdates = true
        // Output pixels = layout points × the preset's device scale. Layout is
        // unaffected — snapshotWidth only scales the rendered raster. Very
        // tall pages trade density for encodability (maxOutputPixels).
        let scale = min(preset.scaleFactor, Self.maxOutputPixels / max(1, height))
        // snapshotWidth is in POINTS and WebKit rasterises it at the main
        // screen's backing scale (the offscreen view has no window of its
        // own). Divide that back out so the output pixel width is exactly
        // viewportWidth × the preset scale on any display — on a 2x Mac the
        // undivided value came back double (5760 instead of 2880).
        let backing = NSScreen.main?.backingScaleFactor ?? 1
        shot.snapshotWidth = NSNumber(value: Double(preset.viewportWidth * scale / backing))

        return try await withCheckedThrowingContinuation { c in
            view.takeSnapshot(with: shot) { image, error in
                if let image {
                    c.resume(returning: image)
                } else {
                    c.resume(throwing: CaptureError.snapshotFailed(
                        error?.localizedDescription ?? "no image returned"))
                }
            }
        }
    }

    /// One `<style>` payload for the enabled options; nil when nothing is on.
    /// Mirrors the API worker's `buildHideCss` composition.
    private static func optionCSS(_ options: WebCaptureOptions, host: String?) -> String? {
        var blocks: [String] = []
        var hidden: [String] = []
        if options.hideCookieBanners {
            // EasyList Cookie List: pre-joined generic block + this host's
            // domain-scoped rules, then the curated overrides below.
            if let generic = CookieRuleCatalog.genericCSS { blocks.append(generic) }
            hidden += CookieRuleCatalog.domainSelectors(forHost: host)
            hidden += WebHideRules.cookieBanners
        }
        if options.hideChatWidgets { hidden += WebHideRules.chatWidgets }
        if !hidden.isEmpty {
            blocks.append("\(hidden.joined(separator: ",\n")) { display: none !important; visibility: hidden !important; }")
        }
        if options.hideCookieBanners {
            blocks.append("\(WebHideRules.cookieBannerScrollRestore.joined(separator: ",\n")) { overflow: visible !important; }")
        }
        if options.reduceMotion {
            blocks.append("*, *::before, *::after { animation: none !important; transition: none !important; scroll-behavior: auto !important; }")
        }
        if options.darkMode {
            // Best effort beside the appearance override: opt UA styling into
            // the dark palette on pages that rely on `color-scheme`.
            blocks.append(":root { color-scheme: dark; }")
        }
        return blocks.isEmpty ? nil : blocks.joined(separator: "\n")
    }

    private func measuredHeight(of view: WKWebView, minimum: CGFloat) async throws -> CGFloat {
        let js = """
        Math.max(
          document.body ? document.body.scrollHeight : 0,
          document.documentElement ? document.documentElement.scrollHeight : 0
        )
        """
        let value = try? await view.evaluateJavaScript(js)
        let measured = (value as? NSNumber)?.doubleValue ?? Double(minimum)
        return min(Self.maxPageHeight, max(minimum, CGFloat(measured)))
    }

    private func finish(_ result: Result<Void, Error>) {
        guard !finished else { return }
        finished = true
        switch result {
        case .success: continuation?.resume()
        case .failure(let e): continuation?.resume(throwing: e)
        }
        continuation = nil
    }

    // MARK: - WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if navigationResponse.isForMainFrame,
           let http = navigationResponse.response as? HTTPURLResponse {
            mainFrameStatus = http.statusCode
            mainFrameHost = http.url?.host ?? ""
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let status = mainFrameStatus, status >= 400 {
            finish(.failure(CaptureError.httpError(status, mainFrameHost)))
            return
        }
        finish(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(CaptureError.navigationFailed(error.localizedDescription)))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(CaptureError.navigationFailed(error.localizedDescription)))
    }
}


/// `CaptureCat --url-capture-test [url]` — proves the URL pipeline end to end.
///
/// Exercises the real path: normalise, load offscreen in WKWebView, measure the
/// document height, snapshot, then encode through `StillMovieWriter` and read
/// the result back with AVFoundation. A unit test of `normalize` alone would
/// pass while the capture produced a blank frame.
@MainActor
enum WebCaptureHarness {
    nonisolated static let flag = "--url-capture-test"

    /// A content-rich page on purpose. The obvious choice, example.com, is
    /// legitimately ~99% white, so the blank-page assertion below fails on it —
    /// and that assertion is worth keeping strict, because a capture that
    /// "succeeds" and returns a white frame is the failure most worth catching.
    static let defaultTarget = "https://capturecat.so"
    /// `nonisolated`: main.swift checks this before the app (and the main actor)
    /// is running, and it only reads the argument vector.
    nonisolated static var isRequested: Bool { CommandLine.arguments.contains(flag) }

    static func run() -> Never {
        let args = CommandLine.arguments
        let target: String = {
            guard let i = args.firstIndex(of: flag), args.count > i + 1,
                  !args[i + 1].hasPrefix("-") else { return defaultTarget }
            return args[i + 1]
        }()

        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("URLCAP \(name) \(detail) \(ok ? "PASS" : "FAIL")")
            if !ok { failures += 1 }
        }

        // Normalisation: the cases people actually type.
        check("bare host", WebPageCapture.normalize("example.com")?.scheme == "https")
        check("with scheme", WebPageCapture.normalize("http://example.com")?.scheme == "http")
        check("with path", WebPageCapture.normalize("example.com/a/b")?.path == "/a/b")
        check("rejects empty", WebPageCapture.normalize("   ") == nil)
        check("rejects bare word", WebPageCapture.normalize("notahost") == nil)
        check("allows localhost", WebPageCapture.normalize("localhost:3000") != nil)

        // Optional device preset: --device desktop|tablet|mobile
        let preset: WebDevicePreset = {
            guard let i = args.firstIndex(of: "--device"), args.count > i + 1,
                  let p = WebDevicePreset(rawValue: args[i + 1]) else { return .desktop }
            return p
        }()

        // Optional: --hide-banners applies the cookie-banner hide CSS (used by
        // the real-site battery to compare before/after on live pages).
        var harnessOptions = WebCaptureOptions()
        harnessOptions.hideCookieBanners = args.contains("--hide-banners")
        harnessOptions.darkMode = args.contains("--dark")

        Task { @MainActor in
            do {
                let start = Date()
                let image = try await WebPageCapture().capture(target, preset: preset, options: harnessOptions, timeout: 30)
                print("URLCAP capture-seconds \(String(format: "%.2f", Date().timeIntervalSince(start)))")
                guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    check("snapshot", false, "no bitmap"); finish(failures + 1)
                }
                check("snapshot", cg.width > 0 && cg.height > 0, "\(cg.width)x\(cg.height)")

                // Optional visual dump for eyeballing layout regressions:
                //   --url-capture-test <url> --save-png <path>
                if let i = args.firstIndex(of: "--save-png"), args.count > i + 1 {
                    let url = URL(fileURLWithPath: args[i + 1])
                    let rep = NSBitmapImageRep(cgImage: cg)
                    try? rep.representation(using: .png, properties: [:])?.write(to: url)
                    print("URLCAP saved \(url.path)")
                }

                // A blank page is the failure this harness exists to catch: the
                // load can "succeed" and still snapshot white.
                check("page is not blank", !isBlank(cg))

                let out = FileManager.default.temporaryDirectory
                    .appendingPathComponent("capturecat-urltest.mp4")
                let size = try await StillMovieWriter.write(image: cg, to: out, duration: 4)
                check("encoded even dimensions",
                      Int(size.width) % 2 == 0 && Int(size.height) % 2 == 0,
                      "\(Int(size.width))x\(Int(size.height))")

                let asset = AVURLAsset(url: out)
                let dur = try await asset.load(.duration).seconds
                let tracks = try await asset.loadTracks(withMediaType: .video)
                check("movie is readable", tracks.count == 1, "tracks=\(tracks.count)")
                check("movie has duration", dur > 3.5, String(format: "%.2fs", dur))
                let bytes = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
                print("URLCAP file \(bytes ?? 0) bytes")
                try? FileManager.default.removeItem(at: out)
            } catch {
                check("capture", false, error.localizedDescription)
            }
            finish(failures)
        }
        RunLoop.main.run()
        exit(0)
    }

    /// True when nearly every pixel is the same colour — a white or blank page.
    private static func isBlank(_ image: CGImage) -> Bool {
        guard let data = image.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return true }
        let count = CFDataGetLength(data)
        guard count > 0 else { return true }
        let stride = max(4, (count / 4 / 5000) * 4)
        var first: (UInt8, UInt8, UInt8)?
        var differing = 0, sampled = 0
        var i = 0
        while i + 3 < count {
            let px = (ptr[i], ptr[i + 1], ptr[i + 2])
            if let f = first {
                if abs(Int(px.0) - Int(f.0)) + abs(Int(px.1) - Int(f.1)) + abs(Int(px.2) - Int(f.2)) > 24 {
                    differing += 1
                }
            } else { first = px }
            sampled += 1
            i += stride
        }
        return sampled == 0 || Double(differing) / Double(sampled) < 0.01
    }

    private static func finish(_ failures: Int) -> Never {
        print("")
        print(failures == 0 ? "URL-CAPTURE PASS" : "URL-CAPTURE FAIL (\(failures))")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Device-preset layout gate (--web-device-test)

    nonisolated static let deviceFlag = "--web-device-test"
    nonisolated static var isDeviceTestRequested: Bool { CommandLine.arguments.contains(deviceFlag) }

    /// Proves each preset renders the LAYOUT viewport it claims: a local
    /// fixture page paints its body red below 500pt, green at 500–1000pt and
    /// blue above via CSS media queries, so the dominant capture colour is a
    /// real layout-viewport assertion — not a pixel-size check that could pass
    /// while a site still saw a phone-sized viewport. Also prints the default
    /// WKWebView UA next to the presets' (evidence for the stripe.com bug).
    static func runDeviceTest() -> Never {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("WEBDEV \(name) \(detail) \(ok ? "PASS" : "FAIL")")
            if !ok { failures += 1 }
        }

        let fixture = """
        <!doctype html><meta name="viewport" content="width=device-width">
        <style>
          html, body { margin: 0; height: 1200px; background: rgb(0,0,255); }
          @media (max-width: 1000px) { html, body { background: rgb(0,128,0); } }
          @media (max-width: 500px)  { html, body { background: rgb(255,0,0); } }
        </style>
        """
        let fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("capturecat-webdev-fixture.html")
        try? fixture.data(using: .utf8)?.write(to: fixtureURL)

        Task { @MainActor in
            // Evidence: the UA WKWebView would send if we did not set one.
            let probe = WKWebView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
            let defaultUA = (try? await probe.evaluateJavaScript("navigator.userAgent")) as? String
            print("WEBDEV default-ua \(defaultUA ?? "<none>")")

            let expected: [(WebDevicePreset, (UInt8, UInt8, UInt8), String)] = [
                (.desktop, (0, 0, 255), "blue"),
                (.tablet, (0, 128, 0), "green"),
                (.mobile, (255, 0, 0), "red"),
            ]
            for (preset, color, colorName) in expected {
                do {
                    let image = try await WebPageCapture().capture(url: fixtureURL, preset: preset, timeout: 15)
                    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                        check("\(preset.rawValue) snapshot", false, "no bitmap"); continue
                    }
                    let expectedWidth = Int(preset.viewportWidth * preset.scaleFactor)
                    check("\(preset.rawValue) pixel width", cg.width == expectedWidth,
                          "got \(cg.width) want \(expectedWidth)")
                    let dominant = dominantColor(cg)
                    let ok = dominant.map {
                        abs(Int($0.0) - Int(color.0)) < 40 &&
                        abs(Int($0.1) - Int(color.1)) < 40 &&
                        abs(Int($0.2) - Int(color.2)) < 40
                    } ?? false
                    check("\(preset.rawValue) layout is \(colorName)", ok,
                          dominant.map { "rgb(\($0.0),\($0.1),\($0.2))" } ?? "unreadable")
                } catch {
                    check("\(preset.rawValue) capture", false, error.localizedDescription)
                }
            }
            try? FileManager.default.removeItem(at: fixtureURL)

            // ── Option assertions ─────────────────────────────────────────
            func writeFixture(_ html: String, _ name: String) -> URL {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("capturecat-webdev-\(name).html")
                try? html.data(using: .utf8)?.write(to: url)
                return url
            }
            func grab(_ url: URL, _ options: WebCaptureOptions) async -> CGImage? {
                let image = try? await WebPageCapture().capture(url: url, preset: .desktop, options: options, timeout: 20)
                return image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            }
            func matches(_ cg: CGImage?, _ color: (UInt8, UInt8, UInt8)) -> Bool {
                guard let cg, let d = dominantColor(cg) else { return false }
                return abs(Int(d.0) - Int(color.0)) < 40 && abs(Int(d.1) - Int(color.1)) < 40
                    && abs(Int(d.2) - Int(color.2)) < 40
            }

            // Height modes: viewport == exactly the viewport; full == 4× cap.
            let tall = writeFixture(
                "<style>html,body{margin:0;height:5000px;background:rgb(0,0,255)}</style>", "tall")
            var opts = WebCaptureOptions()
            var cg = await grab(tall, opts)
            check("viewport height", cg?.height == Int(900 * 2), "got \(cg?.height ?? -1) want 1800")
            opts.heightMode = .full
            cg = await grab(tall, opts)
            check("full x4 height", cg?.height == Int(900 * 4 * 2), "got \(cg?.height ?? -1) want 7200")
            try? FileManager.default.removeItem(at: tall)

            // Dark mode: media query must actually flip.
            let dark = writeFixture("""
            <style>html,body{margin:0;height:1200px;background:rgb(255,255,255)}
            @media (prefers-color-scheme: dark){html,body{background:rgb(20,20,20)}}</style>
            """, "dark")
            check("light default", matches(await grab(dark, WebCaptureOptions()), (255, 255, 255)))
            var darkOpts = WebCaptureOptions()
            darkOpts.darkMode = true
            check("dark mode flips", matches(await grab(dark, darkOpts), (20, 20, 20)))
            try? FileManager.default.removeItem(at: dark)

            // Dark mode is the SITE'S OWN dark theme, never an invented one:
            // a page with no dark styles must render exactly as designed —
            // light — even with the option on. (Product rule: "the website's
            // official dark mode, not what we invented".)
            let noDark = writeFixture("""
            <style>html,body{margin:0;height:1200px;background:rgb(255,255,255);color:#111}</style>
            <p>A page with no dark styles at all.</p>
            """, "nodark")
            check("no-dark page stays light with dark on",
                  matches(await grab(noDark, darkOpts), (255, 255, 255)))
            try? FileManager.default.removeItem(at: noDark)

            // JS tier of the same mechanism: sites like google.com read
            // `window.matchMedia('(prefers-color-scheme: dark)')` in script
            // that runs while the document is still parsing. This fixture
            // paints from a matchMedia check made at the FIRST script tick —
            // it fails if the dark environment arrives any later than that.
            let earlyJS = writeFixture("""
            <script>var dark = window.matchMedia('(prefers-color-scheme: dark)').matches;
            document.write('<style>html,body{margin:0;height:1200px;background:'
              + (dark ? 'rgb(20,20,20)' : 'rgb(255,255,255)') + '}</style>')</script>
            """, "earlyjs")
            check("early matchMedia sees dark", matches(await grab(earlyJS, darkOpts), (20, 20, 20)))
            check("early matchMedia sees light by default",
                  matches(await grab(earlyJS, WebCaptureOptions()), (255, 255, 255)))
            try? FileManager.default.removeItem(at: earlyJS)

            // Cookie banner hide: a full-viewport banner with a curated
            // selector id must vanish, revealing the page beneath.
            let banner = writeFixture("""
            <style>html,body{margin:0;height:1200px;background:rgb(0,128,0)}</style>
            <div id="onetrust-consent-sdk" style="position:fixed;inset:0;background:rgb(255,0,0)"></div>
            """, "banner")
            check("banner visible by default", matches(await grab(banner, WebCaptureOptions()), (255, 0, 0)))
            var hideOpts = WebCaptureOptions()
            hideOpts.hideCookieBanners = true
            check("banner hidden", matches(await grab(banner, hideOpts), (0, 128, 0)))
            try? FileManager.default.removeItem(at: banner)

            // EasyList catalog: the bundled artifact must load, and a selector
            // that exists ONLY in the generated list (never in the curated
            // WebHideRules) must hide — proves the generic block is injected.
            check("easylist catalog loaded", CookieRuleCatalog.isLoaded,
                  "generic=\(CookieRuleCatalog.genericCount) domains=\(CookieRuleCatalog.domainCount)")
            check("easylist has real volume",
                  CookieRuleCatalog.genericCount > 10_000 && CookieRuleCatalog.domainCount > 10_000)
            let easylist = writeFixture("""
            <style>html,body{margin:0;height:1200px;background:rgb(0,128,0)}</style>
            <div id="ACCETTA_COOKIES" style="position:fixed;inset:0;background:rgb(255,0,0)"></div>
            """, "easylist")
            check("easylist-only banner visible by default",
                  matches(await grab(easylist, WebCaptureOptions()), (255, 0, 0)))
            check("easylist-only banner hidden", matches(await grab(easylist, hideOpts), (0, 128, 0)))
            try? FileManager.default.removeItem(at: easylist)

            // Delay: page turns red 3s after load; no delay catches blue
            // (snapshot lands ~1s in), a 5s delay catches red.
            let lazy = writeFixture("""
            <style>html,body{margin:0;height:1200px;background:rgb(0,0,255)}</style>
            <script>setTimeout(function(){document.documentElement.style.background='rgb(255,0,0)';\
            document.body.style.background='rgb(255,0,0)';}, 3000)</script>
            """, "lazy")
            check("no delay is early", matches(await grab(lazy, WebCaptureOptions()), (0, 0, 255)))
            var delayOpts = WebCaptureOptions()
            delayOpts.delaySeconds = 5
            check("5s delay is late", matches(await grab(lazy, delayOpts), (255, 0, 0)))
            try? FileManager.default.removeItem(at: lazy)

            print("")
            print(failures == 0 ? "WEB-DEVICE PASS" : "WEB-DEVICE FAIL (\(failures))")
            exit(failures == 0 ? 0 : 1)
        }
        RunLoop.main.run()
        exit(0)
    }

    /// Most common sampled pixel colour (quantised), returned as true RGB —
    /// the byte order is decoded from the bitmap info, because red-vs-blue is
    /// exactly the distinction the desktop/mobile assertions hinge on and a
    /// BGRA buffer read naively would swap them.
    private nonisolated static func dominantColor(_ image: CGImage) -> (UInt8, UInt8, UInt8)? {
        guard image.bitsPerPixel == 32,
              let data = image.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return nil }
        let count = CFDataGetLength(data)
        guard count >= 4 else { return nil }

        let little = image.bitmapInfo.contains(.byteOrder32Little)
        let alphaInfo = image.alphaInfo
        let alphaFirst = alphaInfo == .premultipliedFirst || alphaInfo == .first || alphaInfo == .noneSkipFirst
        // Memory offsets of R,G,B for each 32bpp layout.
        let (r, g, b): (Int, Int, Int)
        switch (little, alphaFirst) {
        case (false, true): (r, g, b) = (1, 2, 3)  // A R G B
        case (false, false): (r, g, b) = (0, 1, 2) // R G B A
        case (true, true): (r, g, b) = (2, 1, 0)   // B G R A
        case (true, false): (r, g, b) = (3, 2, 1)  // A B G R
        }

        var buckets: [UInt32: Int] = [:]
        let stride = max(4, (count / 4 / 4000) * 4)
        var i = 0
        while i + 3 < count {
            let key = UInt32(ptr[i + r] / 16) << 16 | UInt32(ptr[i + g] / 16) << 8 | UInt32(ptr[i + b] / 16)
            buckets[key, default: 0] += 1
            i += stride
        }
        guard let top = buckets.max(by: { $0.value < $1.value })?.key else { return nil }
        return (
            UInt8(min(255, Int(top >> 16 & 0xFF) * 16 + 8)),
            UInt8(min(255, Int(top >> 8 & 0xFF) * 16 + 8)),
            UInt8(min(255, Int(top & 0xFF) * 16 + 8))
        )
    }
}
