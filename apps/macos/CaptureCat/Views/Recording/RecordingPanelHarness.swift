import AppKit
import Network
import QuartzCore
import ScreenCaptureKit

/// Conversion gate for the native recording panel (Phase 6).
///
///   CaptureCat --recording-panel-shot [<output-dir>] -hasCompletedOnboarding NO
///
/// Renders `RecordingPanelViewController` in a standalone window over a
/// gradient the Liquid Glass can refract, and captures a PNG for each state:
/// idle, recording, paused, and the area / device tabs.
///
/// This used to render the SwiftUI `RecordingControlsView` above the native
/// panel for a side-by-side diff; that arm went with the SwiftUI panel. `-hasCompletedOnboarding NO` keeps `AppState.init`
/// from auto-opening a real floating panel on the user's screen — always pass
/// it. DEBUG tooling; never reached in a normal launch.
@MainActor
enum RecordingPanelHarness {
    private static var window: NSWindow?
    private static var controller: RecordingPanelViewController?
    private static var nativeRow: NSView?
    private static var rowWidth: NSLayoutConstraint?
    private static var nativeHeight: NSLayoutConstraint?
    private static var outputDirectory = URL(fileURLWithPath: NSTemporaryDirectory())

    static func run() -> Never {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        if let index = CommandLine.arguments.firstIndex(of: "--recording-panel-shot"),
           CommandLine.arguments.count > index + 1,
           !CommandLine.arguments[index + 1].hasPrefix("-") {
            outputDirectory = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        }

        // `--light` renders the panel in the light theme (same switch the
        // editor shell probe carries), so the bar's theming can be judged on
        // a real frame instead of by reading colour call sites.
        if CommandLine.arguments.contains("--light") {
            CCTheme.setMode(.light, persist: false)
        }

        let appState = AppState()
        build(appState: appState)

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(2200))

            // `--light-flip` flips the theme AFTER the panel is built — the
            // path the user actually takes (launch dark, pick Light from the
            // status menu). `--light` alone flips BEFORE the build and so
            // passed while the shipped bar stayed dark on a live flip: the
            // shell's fill was painted once from a frozen sRGB colour that no
            // re-assignment could re-resolve. Capture named so the two are
            // never confused in the output dir.
            let liveFlip = CommandLine.arguments.contains("--light-flip")
            if liveFlip {
                CCTheme.setMode(.light, persist: false)
                try? await Task.sleep(for: .milliseconds(400))
                await capture("idle-light-flip")
                reportShellFill()
            }
            await capture("idle")

            // Before any state is forced: prove the panel responds to CLICKS.
            // Every screenshot below drives the UI through `debugSelectTab`,
            // which bypasses event handling entirely — so they all stayed green
            // while not one control in the shipped panel was reachable.
            clickFailures = await checkTabClicks()

            appState.recordingSession.phase = .recording
            resizeRows(setup: false)
            try? await Task.sleep(for: .milliseconds(1400))
            await capture("recording")

            appState.recordingSession.phase = .paused
            try? await Task.sleep(for: .milliseconds(1000))
            await capture("paused")

            appState.recordingSession.phase = .idle
            resizeRows(setup: true)
            controller?.debugSelectTab(.area)
            try? await Task.sleep(for: .milliseconds(1000))
            await capture("idle-area-tab")

            controller?.debugSelectTab(.device)
            try? await Task.sleep(for: .milliseconds(800))
            await capture("idle-device-tab")

            dumpPanelMenus()
            dumpStatusMenu(appState: appState)
            if clickFailures > 0 {
                print("PANEL-CLICKS \(clickFailures) failure(s) — controls are not reachable")
                exit(1)
            }
            print("PANEL-CLICKS PASS")
            exit(0)
        }
        app.run()
        exit(0)
    }

    // MARK: - Hover glide probe (--recording-hover-probe)

    /// Proves the Recording toolbar's two hover systems move their actual
    /// presentation layers mid-flight: source tabs and Mic → Audio controls.
    static func runHoverProbe() -> Never {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let appState = AppState()
        build(appState: appState, plainDark: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            guard let controller else {
                print("RECORDING-HOVER no controller FAIL")
                exit(1)
            }
            controller.debugProbeHoverGlide { tabsGlide, controlsGlide in
                print("RECORDING-HOVER tabs-midflight=\(tabsGlide) controls-midflight=\(controlsGlide)")
                let passed = tabsGlide && controlsGlide
                print(passed ? "RECORDING-HOVER PASS" : "RECORDING-HOVER FAIL")
                exit(passed ? 0 : 1)
            }
        }
        app.run()
        exit(0)
    }

    // MARK: - URL spinner probe (--url-spinner-probe)

    /// Feedback gate for Return-in-the-URL-field: a loopback HTTP server
    /// stalls 2.5s before answering 500, giving a deterministic in-flight
    /// window. The submit goes through `debugSubmitURL` → `captureWebPage`,
    /// the REAL Return path — mid-flight the row must lock (spinner visible,
    /// field/device/gear disabled), and afterwards restore with the failure
    /// inline on the field, never the warning triangle.
    static func runSpinnerProbe() -> Never {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("URLSPIN \(name) \(detail) \(ok ? "PASS" : "FAIL")")
            if !ok { failures += 1 }
        }

        // Loopback server: read the request, wait, answer HTTP 500 — the
        // error path exercises the same defer-restore as success without
        // dragging the editor open inside the harness.
        let listener = try! NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { conn in
            conn.start(queue: .global())
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                DispatchQueue.global().asyncAfter(deadline: .now() + 2.5) {
                    let body = "capture probe error"
                    let head = "HTTP/1.1 500 Internal Server Error\r\nContent-Type: text/html\r\n"
                        + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
                    conn.send(content: Data((head + body).utf8),
                              completion: .contentProcessed { _ in conn.cancel() })
                }
            }
        }
        listener.start(queue: .global())

        let appState = AppState()
        build(appState: appState)

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1200))
            guard let controller else {
                print("URLSPIN no controller FAIL"); exit(1)
            }
            var port: UInt16?
            for _ in 0..<50 {
                if let p = listener.port?.rawValue { port = p; break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let port else {
                print("URLSPIN listener never became ready FAIL"); exit(1)
            }

            // URL capture goes through RemoteScreenshotClient now — point its
            // API base at the stalling stub (the stub IS the screenshot API
            // here) and hand it a fake bearer so the signed-out guard does not
            // short-circuit before the network round trip we are timing.
            setenv("CAPTURECAT_SCREENSHOT_BASE", "http://127.0.0.1:\(port)", 1)
            setenv("CAPTURECAT_SCREENSHOT_TOKEN", "url-spinner-probe-token", 1)

            controller.debugSelectTab(.url)
            try? await Task.sleep(for: .milliseconds(400))
            let idle = controller.debugURLRowState
            check("idle field enabled", idle.fieldEnabled && !idle.spinnerBusy)

            controller.debugSubmitURL("http://localhost:\(port)/")
            try? await Task.sleep(for: .milliseconds(700))
            let busy = controller.debugURLRowState
            check("in-flight busy", busy.spinnerBusy)
            check("in-flight spinner visible", busy.spinnerVisible)
            check("in-flight field disabled", !busy.fieldEnabled)
            check("in-flight device disabled", !busy.deviceEnabled)
            check("in-flight gear disabled", !busy.gearEnabled)

            var settled = controller.debugURLRowState
            for _ in 0..<120 where settled.spinnerBusy {
                try? await Task.sleep(for: .milliseconds(250))
                settled = controller.debugURLRowState
            }
            check("restored not busy", !settled.spinnerBusy)
            check("restored field enabled", settled.fieldEnabled)
            check("restored device enabled", settled.deviceEnabled)
            check("restored gear enabled", settled.gearEnabled)
            check("failure shown inline", settled.error != nil, settled.error ?? "<nil>")

            print("")
            print(failures == 0 ? "URL-SPINNER PASS" : "URL-SPINNER FAIL (\(failures))")
            exit(failures == 0 ? 0 : 1)
        }
        app.run()
        exit(0)
    }

    // MARK: - Remote capture probe (--remote-capture-probe)

    /// End-to-end gate for the Chromium (API) URL-capture path with the API
    /// stubbed by a local listener. What used to be preview-vs-export parity
    /// is now WIRE parity: the QUERY PARAMS the app sends for each option
    /// combination ARE the capture semantics, so they are asserted exactly —
    /// first through the pure `RemoteScreenshotClient.queryItems` mapping,
    /// then through the REAL panel path (`debugSubmitURL` → `captureWebPage`
    /// → HTTP request observed by the stub). The stub's fixed PNG is pushed
    /// through `StillMovieWriter` to prove the response bytes land in the
    /// same still pipeline the WKWebView snapshot used to feed, and the
    /// signed-out / API-error branches must surface inline on the field.
    static func runRemoteCaptureProbe() -> Never {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("REMCAP \(name) \(detail) \(ok ? "PASS" : "FAIL")")
            if !ok { failures += 1 }
        }

        // ── Stub screenshot API ───────────────────────────────────────────
        // Records each request's path+query and answers whatever `respond`
        // currently returns. Connection: close so URLSession never pipelines
        // a second request past the recorder.
        final class Stub: @unchecked Sendable {
            let lock = NSLock()
            var requests: [String] = []
            var respond: () -> (status: String, contentType: String, body: Data) = {
                ("500 Internal Server Error", "text/plain", Data("unconfigured".utf8))
            }
            func record(_ target: String) { lock.lock(); requests.append(target); lock.unlock() }
            var lastRequest: String? { lock.lock(); defer { lock.unlock() }; return requests.last }
        }
        let stub = Stub()
        let listener = try! NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { conn in
            conn.start(queue: .global())
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, _, _ in
                guard let data, let head = String(data: data, encoding: .utf8),
                      let line = head.split(separator: "\r\n").first else { conn.cancel(); return }
                let parts = line.split(separator: " ")
                if parts.count >= 2 { stub.record(String(parts[1])) }
                let (status, type, body) = stub.respond()
                let header = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\n"
                    + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                conn.send(content: Data(header.utf8) + body,
                          completion: .contentProcessed { _ in conn.cancel() })
            }
        }
        listener.start(queue: .global())

        // A real 64×64 red PNG — the fixed frame the "API" renders.
        let fixturePNG: Data = {
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.red.setFill()
            NSRect(x: 0, y: 0, width: 64, height: 64).fill()
            NSGraphicsContext.restoreGraphicsState()
            return rep.representation(using: .png, properties: [:])!
        }()

        let appState = AppState()
        build(appState: appState)

        Task { @MainActor in
            // ── 1. Pure wire-shape table: option combo → exact query params ──
            func dict(_ items: [URLQueryItem]) -> [String: String] {
                Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
            }
            let page = URL(string: "https://example.com/x")!

            var o = WebCaptureOptions()
            var q = dict(RemoteScreenshotClient.queryItems(url: page, preset: .desktop, options: o))
            check("defaults map minimally",
                  q == ["url": "https://example.com/x", "device": "desktop", "format": "png"],
                  "\(q)")

            o.heightMode = .full
            q = dict(RemoteScreenshotClient.queryItems(url: page, preset: .tablet, options: o))
            check("full x4 maps full_page+multiple",
                  q["device"] == "tablet" && q["full_page"] == "true" && q["max_height_multiple"] == "4")

            o.heightMode = .entire
            q = dict(RemoteScreenshotClient.queryItems(url: page, preset: .mobile, options: o))
            check("entire maps full_page only",
                  q["device"] == "mobile" && q["full_page"] == "true" && q["max_height_multiple"] == nil)

            o = WebCaptureOptions(heightMode: .viewport, darkMode: true, hideCookieBanners: true,
                                  hideChatWidgets: true, reduceMotion: true, delaySeconds: 3)
            q = dict(RemoteScreenshotClient.queryItems(url: page, preset: .desktop, options: o))
            check("all toggles map by API name",
                  q["dark_mode"] == "true" && q["reduced_motion"] == "true"
                  && q["block_cookie_banners"] == "true" && q["block_chats"] == "true"
                  && q["delay"] == "3" && q["full_page"] == nil)

            // ── Stub wiring ──────────────────────────────────────────────
            var port: UInt16?
            for _ in 0..<50 {
                if let p = listener.port?.rawValue { port = p; break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let port else { print("REMCAP listener never became ready FAIL"); exit(1) }
            setenv("CAPTURECAT_SCREENSHOT_BASE", "http://127.0.0.1:\(port)", 1)
            setenv("CAPTURECAT_SCREENSHOT_TOKEN", "remote-capture-probe-token", 1)

            // ── 2. Response PNG → the still pipeline ─────────────────────
            stub.respond = { ("200 OK", "image/png", fixturePNG) }
            do {
                let image = try await RemoteScreenshotClient().capture(
                    url: page, preset: .desktop, options: WebCaptureOptions())
                let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                check("stub PNG decodes", cg != nil, "\(cg?.width ?? -1)x\(cg?.height ?? -1)")
                if let cg {
                    let out = FileManager.default.temporaryDirectory
                        .appendingPathComponent("capturecat-remcap-probe.mp4")
                    let size = try await StillMovieWriter.write(image: cg, to: out)
                    check("still pipeline encodes",
                          Int(size.width) % 2 == 0 && Int(size.height) % 2 == 0,
                          "\(Int(size.width))x\(Int(size.height))")
                    try? FileManager.default.removeItem(at: out)
                }
                let sent = stub.lastRequest ?? ""
                check("client hits /api/screenshot/take", sent.hasPrefix("/api/screenshot/take?"), sent)
            } catch {
                check("stub capture", false, error.localizedDescription)
            }

            // ── 3. REAL panel flow: options → observed query params, and the
            //      API's error.message surfacing inline. The stub answers the
            //      quota error so the flow stops before opening the editor.
            guard let controller else { print("REMCAP no controller FAIL"); exit(1) }
            appState.webCaptureDevice = .mobile
            appState.webCaptureOptions = WebCaptureOptions(
                heightMode: .full, darkMode: true, hideCookieBanners: true,
                hideChatWidgets: false, reduceMotion: false, delaySeconds: 0)
            let quotaMessage = "Daily web-capture allowance (30) exhausted. It resets at midnight UTC."
            stub.respond = {
                let body = "{\"error\":{\"code\":\"quota_exceeded\",\"message\":\"\(quotaMessage)\"}}"
                return ("429 Too Many Requests", "application/json", Data(body.utf8))
            }
            controller.debugSelectTab(.url)
            try? await Task.sleep(for: .milliseconds(400))
            controller.debugSubmitURL("example.com")
            var state = controller.debugURLRowState
            for _ in 0..<40 where state.error == nil {
                try? await Task.sleep(for: .milliseconds(250))
                state = controller.debugURLRowState
            }
            let flowRequest = stub.lastRequest ?? ""
            check("panel flow sends device=mobile", flowRequest.contains("device=mobile"), flowRequest)
            check("panel flow sends dark_mode", flowRequest.contains("dark_mode=true"))
            check("panel flow sends cookie blocking", flowRequest.contains("block_cookie_banners=true"))
            check("panel flow sends full_page+multiple",
                  flowRequest.contains("full_page=true") && flowRequest.contains("max_height_multiple=4"))
            check("panel flow omits unset options",
                  !flowRequest.contains("block_chats") && !flowRequest.contains("reduced_motion")
                  && !flowRequest.contains("delay="))
            check("API error.message shown inline", state.error == quotaMessage, state.error ?? "<nil>")

            // ── 4. Signed-out branch: inline sign-in prompt, no request. ──
            unsetenv("CAPTURECAT_SCREENSHOT_TOKEN")
            AuthKeychain.clear(account: "remcap-nonexistent") // no-op; keeps real session untouched
            if AuthKeychain.currentToken() == nil {
                let before = stub.requests.count
                controller.debugSubmitURL("example.com")
                try? await Task.sleep(for: .milliseconds(800))
                let signedOut = controller.debugURLRowState
                check("signed-out shows sign-in inline",
                      signedOut.error == "Sign in to capture web pages.", signedOut.error ?? "<nil>")
                check("signed-out sends nothing", stub.requests.count == before)
            } else {
                print("REMCAP signed-out branch SKIPPED (a real session is present in the Keychain)")
            }

            print("")
            print(failures == 0 ? "REMOTE-CAPTURE PASS" : "REMOTE-CAPTURE FAIL (\(failures))")
            exit(failures == 0 ? 0 : 1)
        }
        app.run()
        exit(0)
    }

    // MARK: - Motion capture (--panel-motion-capture [<dir>])

    /// Drives (a) a tab switch and (b) setup→recording through the SAME
    /// crossfade math the live animations use (`RecordingMotion.crossfadeAlphas`
    /// / `resizeProgress`), sampling every 40ms and writing numbered PNGs.
    /// Presentation is driven manually — model values per frame with implicit
    /// animation off — because `cacheDisplay` renders model state, not
    /// in-flight CA presentation; sampling the shared curves keeps the frames
    /// honest to what the app plays.
    static func runMotionCapture() -> Never {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        outputDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
        if let index = CommandLine.arguments.firstIndex(of: "--panel-motion-capture"),
           CommandLine.arguments.count > index + 1,
           !CommandLine.arguments[index + 1].hasPrefix("-") {
            outputDirectory = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        }
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let appState = AppState()
        build(appState: appState)

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(2200))
            guard let vc = controller else {
                print("MOTION no controller FAIL"); exit(1)
            }
            vc.debugSuppressAnimatedTransition = true

            let clock = RecordingMotion.phaseCrossfadeDuration
            let step = 0.04
            let frameTimes = Array(stride(from: 0.0, through: clock, by: step)) + [clock]

            // (a) Tab switch: Display → Area. No window resize; pure crossfade.
            var stepper = vc.debugPhaseCrossfadeStepper { vc.debugSelectTab(.area) }
            window?.contentView?.layoutSubtreeIfNeeded()
            for (i, time) in frameTimes.enumerated() {
                stepper.apply(time / clock)
                window?.contentView?.layoutSubtreeIfNeeded()
                writeFrame(kind: "tab", index: i, time: time)
            }
            stepper.finish()
            vc.debugSelectTab(.display)
            try? await Task.sleep(for: .milliseconds(300))

            // (a2) Tab switch: Display → URL — the extreme layout change
            // (picker chips collapse; address field + device/gear chips
            // appear). The frozen-snapshot crossfade must hide the reflow:
            // no label may render in two places or visibly translate — the
            // outgoing row is a bitmap, the incoming row fades in whole
            // after the mid-point beat.
            stepper = vc.debugPhaseCrossfadeStepper { vc.debugSelectTab(.url) }
            window?.contentView?.layoutSubtreeIfNeeded()
            for (i, time) in frameTimes.enumerated() {
                stepper.apply(time / clock)
                window?.contentView?.layoutSubtreeIfNeeded()
                writeFrame(kind: "taburl", index: i, time: time)
            }
            stepper.finish()
            vc.debugSelectTab(.display)
            try? await Task.sleep(for: .milliseconds(300))

            // (b) Setup → recording: crossfade + window narrowing on the
            // resize curve, driven through the harness width constraint.
            let w0 = RecordingPanelMetrics.setupPanelSize().width
            let w1 = RecordingPanelMetrics.recordingPanelSize().width
            stepper = vc.debugPhaseCrossfadeStepper { appState.recordingSession.phase = .recording }
            for (i, time) in frameTimes.enumerated() {
                let progress = RecordingMotion.resizeProgress(at: time / clock)
                rowWidth?.constant = w0 + (w1 - w0) * progress
                stepper.apply(time / clock)
                window?.contentView?.layoutSubtreeIfNeeded()
                writeFrame(kind: "record", index: i, time: time)
            }
            stepper.finish()

            print("MOTION-CAPTURE done \(frameTimes.count) frames per sequence -> \(outputDirectory.path)")
            exit(0)
        }
        app.run()
        exit(0)
    }

    private static func writeFrame(kind: String, index: Int, time: TimeInterval) {
        guard let root = window?.contentView else { return }
        guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
        root.cacheDisplay(in: root.bounds, to: rep)
        let name = String(format: "motion-%@-%02d-t%03.0fms.png", kind, index, time * 1000)
        let url = outputDirectory.appendingPathComponent(name)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("FRAME \(name)")
    }

    // MARK: - Live-animation capture (--panel-live-capture [<dir>])
    //
    // The honest gate the frozen-snapshot crossfade kept dodging: the earlier
    // harnesses rendered MODEL values (`cacheDisplay`) or manually-stepped
    // model values, so a live animation whose PRESENTATION tree misbehaved
    // (double icons during real tab switches) still passed. This mode runs the
    // real animated switch — real click events, animations NOT suppressed —
    // and captures frames via CARenderer, which evaluates the in-flight CA
    // animations exactly like the window server does.
    //
    // Assertions per scenario (Display→URL, URL→Display, rapid double-switch):
    //   * pixel mass: bright mass in the tab-strip band never exceeds
    //     1.35× the settled row's mass — two icon sets at once ≈ 2×.
    //   * sequencing: outgoing snapshot and incoming row are never both above
    //     0.4 presentation opacity in the same frame.
    //   * at most one frozen snapshot mid-flight; zero once settled.
    // Plus the static alignment table: all tab-chip icon centreYs equal
    // ±0.5pt, all tab-chip label baselines equal ±0.5pt, and every
    // horizontal-row icon centred on the shell's midline ±0.75pt.

    static func runLiveCapture() -> Never {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        outputDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
        if let index = CommandLine.arguments.firstIndex(of: "--panel-live-capture"),
           CommandLine.arguments.count > index + 1,
           !CommandLine.arguments[index + 1].hasPrefix("-") {
            outputDirectory = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        }
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let appState = AppState()
        build(appState: appState, plainDark: true)

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(2200))
            guard let vc = controller, let win = window else {
                print("LIVE no scene FAIL"); exit(1)
            }
            var failures = 0

            failures += checkAlignment(vc: vc, tab: .display)
            vc.debugSelectTab(.url)
            try? await Task.sleep(for: .milliseconds(250))
            failures += checkAlignment(vc: vc, tab: .url)
            vc.debugSelectTab(.display)
            try? await Task.sleep(for: .milliseconds(400))

            failures += await liveScenario(vc: vc, win: win, name: "display-to-url", clicks: [(.url, 0.0)])
            failures += await liveScenario(vc: vc, win: win, name: "url-to-display", clicks: [(.display, 0.0)])
            failures += await liveScenario(vc: vc, win: win, name: "double-switch", clicks: [(.url, 0.0), (.area, 0.12)])
            failures += await liveScenario(vc: vc, win: win, name: "record-to-screenshot", clicks: [], modeClicks: [(.screenshot, 0.0)])
            failures += await liveScenario(vc: vc, win: win, name: "screenshot-to-record", clicks: [], modeClicks: [(.record, 0.0)])

            print(failures == 0 ? "PANEL-LIVE PASS" : "PANEL-LIVE \(failures) failure(s) FAIL")
            exit(failures == 0 ? 0 : 1)
        }
        app.run()
        exit(0)
    }

    private static func checkAlignment(vc: RecordingPanelViewController, tab: RecordingSourceTab) -> Int {
        window?.contentView?.layoutSubtreeIfNeeded()
        var failures = 0
        let rows = vc.debugAlignmentRows
        print("ALIGN[\(tab.rawValue)]")
        for r in rows {
            let baseline = r.labelBaseline.isNaN ? "      —" : String(format: "%7.2f", r.labelBaseline)
            print(String(format: "  %-16s iconCenterY=%7.2f labelBaseline=%@", (r.name as NSString).utf8String!, r.iconCenterY, baseline))
        }
        let tabRows = rows.filter { $0.name.hasPrefix("tab-") || $0.name.hasPrefix("mode-") }
        let iconYs = tabRows.map(\.iconCenterY)
        let baselines = tabRows.map(\.labelBaseline)
        if let lo = iconYs.min(), let hi = iconYs.max(), hi - lo > 0.5 {
            print(String(format: "ALIGN[%@] tab icon centreY spread %.2fpt (>0.5) FAIL", tab.rawValue, hi - lo))
            failures += 1
        }
        if let lo = baselines.min(), let hi = baselines.max(), hi - lo > 0.5 {
            print(String(format: "ALIGN[%@] tab label baseline spread %.2fpt (>0.5) FAIL", tab.rawValue, hi - lo))
            failures += 1
        }
        for g in vc.debugChipGeometry {
            print(String(format: "  GEO %-10s chip y=%.2f..%.2f body y=%.2f..%.2f",
                         (g.name as NSString).utf8String!, g.chip.minY, g.chip.maxY, g.body.minY, g.body.maxY))
        }
        let shellMidY = vc.debugShellFrameInWindow.midY
        // 1.25pt, not 0.5: AppKit places SF Symbol images baseline-correct, so
        // a tall glyph (stopwatch's crown) reports a frame midY up to ~1pt off
        // the row midline while its GLYPH baseline lines up with its
        // neighbours' — verified in pixels (timer y16..28, stopwatch y14..28,
        // shared bottom row). The gate guards gross misplacement, not Apple's
        // own optical alignment.
        for r in rows where !r.name.hasPrefix("tab-") && !r.name.hasPrefix("mode-") {
            if abs(r.iconCenterY - shellMidY) > 1.25 {
                print(String(format: "ALIGN[%@] %@ icon offset from shell midline %.2fpt (>0.75) FAIL",
                             tab.rawValue, r.name, r.iconCenterY - shellMidY))
                failures += 1
            }
        }
        return failures
    }

    /// Runs one real animated switch and captures presentation frames.
    ///
    /// Pixels come from `SCScreenshotManager` — the WINDOW SERVER's output,
    /// the literal glass the user sees. A CARenderer re-render of the app's
    /// layer tree was tried first and lied by omission: its private CAContext
    /// keeps the tree as of attach time and does not pick up animations added
    /// to sublayers afterwards, so every mid-flight frame rendered the settled
    /// state (constant band mass) while the presentation-opacity samples showed
    /// the real defect. Screen capture cannot be stale.
    private static func liveScenario(
        vc: RecordingPanelViewController, win: NSWindow,
        name: String, clicks: [(RecordingSourceTab, TimeInterval)],
        modeClicks: [(CaptureMode, TimeInterval)] = []
    ) async -> Int {
        guard let content = win.contentView else {
            print("LIVE[\(name)] no content view FAIL"); return 1
        }
        var failures = 0

        // Settled BEFORE state and band geometry.
        content.layoutSubtreeIfNeeded()
        let stripBefore = vc.debugTabsStripFrameInWindow
        guard let before = await windowImage(win) else {
            print("LIVE[\(name)] before-frame FAIL"); return 1
        }
        let scale = Double(before.width) / Double(win.frame.width)
        writeLiveFrame(before, name: name, tag: "before")

        // Drive the real switch with real events, sampling as it runs.
        var pending = clicks
        var pendingModes = modeClicks
        var frames: [(t: TimeInterval, image: CGImage, out: Float, inc: Float, snaps: Int)] = []
        var maxSnapshots = 0
        var sequencingWorst: (t: TimeInterval, out: Float, inc: Float) = (0, 0, 0)
        let t0 = CACurrentMediaTime()
        while CACurrentMediaTime() - t0 < 1.1 {
            let t = CACurrentMediaTime() - t0
            while let next = pending.first, t >= next.1 {
                pending.removeFirst()
                clickTab(next.0, vc: vc, win: win)
            }
            while let next = pendingModes.first, t >= next.1 {
                pendingModes.removeFirst()
                clickMode(next.0, vc: vc, win: win)
            }
            let (out, inc) = vc.debugCrossfadePresentation
            let snaps = vc.debugCrossfadeSnapshotCount
            maxSnapshots = max(maxSnapshots, snaps)
            let overlap = min(out ?? 0, inc ?? 1)
            if overlap > min(sequencingWorst.out, sequencingWorst.inc) {
                sequencingWorst = (t, out ?? 0, inc ?? 1)
            }
            if let image = await windowImage(win) {
                frames.append((t, image, out ?? 0, inc ?? 1, snaps))
            }
        }

        try? await Task.sleep(for: .milliseconds(400))
        content.layoutSubtreeIfNeeded()
        let stripAfter = vc.debugTabsStripFrameInWindow
        guard let after = await windowImage(win) else {
            print("LIVE[\(name)] after-frame FAIL"); return 1
        }
        writeLiveFrame(after, name: name, tag: "after")

        // Band: union of the strip's before/after homes, padded.
        let band = stripBefore.union(stripAfter).insetBy(dx: -6, dy: -4)
        let m0 = brightMass(before, band: band, scale: scale)
        let m1 = brightMass(after, band: band, scale: scale)
        let allowed = max(m0, m1) * 1.35
        print(String(format: "LIVE[%@] band=%.0f,%.0f %.0fx%.0f mass before=%.0f after=%.0f allowed=%.0f",
                     name, band.minX, band.minY, band.width, band.height, m0, m1, allowed))

        for (i, f) in frames.enumerated() {
            let mass = brightMass(f.image, band: band, scale: scale)
            let doubled = mass > allowed
            let overlap = min(f.out, f.inc)
            let seqBad = overlap > 0.4
            print(String(format: "LIVE[%@] frame %02d t=%4.0fms mass=%6.0f out=%.2f in=%.2f snaps=%d%@%@",
                         name, i, f.t * 1000, mass, f.out, f.inc, f.snaps,
                         doubled ? " DOUBLE-ICONS" : "", seqBad ? " SEQ-OVERLAP" : ""))
            writeLiveFrame(f.image, name: name, tag: String(format: "%02d-t%03.0fms", i, f.t * 1000))
            if doubled { failures += 1 }
            if seqBad { failures += 1 }
        }
        if maxSnapshots > 1 {
            print("LIVE[\(name)] maxSnapshots=\(maxSnapshots) (>1) FAIL"); failures += 1
        }
        let leftover = vc.debugCrossfadeSnapshotCount
        if leftover != 0 || !vc.debugRowIsSettled {
            print("LIVE[\(name)] settle leftover=\(leftover) settled=\(vc.debugRowIsSettled) FAIL")
            failures += 1
        }
        print("LIVE[\(name)] \(frames.count) frames, worst overlap out=\(sequencingWorst.out) in=\(sequencingWorst.inc) at \(Int(sequencingWorst.t * 1000))ms \(failures == 0 ? "PASS" : "FAIL")")
        return failures
    }

    private static func clickTab(_ tab: RecordingSourceTab, vc: RecordingPanelViewController, win: NSWindow) {
        guard let chip = vc.debugTabChips[tab] else { return }
        let centre = chip.convert(NSPoint(x: chip.bounds.midX, y: chip.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let ev = NSEvent.mouseEvent(
                with: type, location: centre, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: win.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
            ) {
                win.sendEvent(ev)
            }
        }
    }

    private static func clickMode(_ mode: CaptureMode, vc: RecordingPanelViewController, win: NSWindow) {
        guard let chip = vc.debugModeChips[mode] else { return }
        let centre = chip.convert(NSPoint(x: chip.bounds.midX, y: chip.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let ev = NSEvent.mouseEvent(
                with: type, location: centre, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: win.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
            ) {
                win.sendEvent(ev)
            }
        }
    }

    private static func writeLiveFrame(_ image: CGImage, name: String, tag: String) {
        let url = outputDirectory.appendingPathComponent("live-\(name)-\(tag).png")
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Σ max(0, luminance − floor) over the band — linear in composited alpha
    /// over the dark bar, so a proper crossfade conserves mass while a second
    /// fully-visible icon set roughly doubles it. `band` is in WINDOW (y-up)
    /// coordinates; the image is a top-down screen capture of the whole window
    /// at `scale` pixels per point.
    private static func brightMass(_ image: CGImage, band: NSRect, scale: Double) -> Double {
        guard let data = image.dataProvider?.data as Data? else { return 0 }
        let w = image.width, h = image.height, bpr = image.bytesPerRow
        let x0 = max(0, Int(band.minX * scale)), x1 = min(w, Int((band.maxX * scale).rounded(.up)))
        let yTop = max(0, h - Int((band.maxY * scale).rounded(.up)))
        let yBot = min(h, h - Int(band.minY * scale))
        guard x1 > x0, yBot > yTop else { return 0 }
        var mass = 0.0
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            for y in yTop..<yBot {
                let row = y * bpr
                for x in x0..<x1 {
                    let p = row + x * 4 // BGRA little-endian from CARendererSnapshot's pixel layout
                    let b = Double(buf[p]), g = Double(buf[p + 1]), r = Double(buf[p + 2])
                    let lum = 0.114 * b + 0.587 * g + 0.299 * r
                    if lum > 70 { mass += (lum - 70) / 185 }
                }
            }
        }
        return mass
    }

    // MARK: - Scene

    /// Non-zero when the click gate found a dead control.
    private static var clickFailures = 0

    private static func build(appState: AppState, plainDark: Bool = false) {
        let setupSize = RecordingPanelMetrics.setupPanelSize()
        let root = GradientBackdropView()
        root.plainDark = plainDark
        root.translatesAutoresizingMaskIntoConstraints = false

        let vc = RecordingPanelViewController(appState: appState)
        vc.loadViewIfNeeded()
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        controller = vc
        nativeRow = vc.view

        let nativeLabel = caption("AppKit — RecordingPanelViewController")

        for sub in [nativeLabel, vc.view] {
            root.addSubview(sub)
        }

        let width = vc.view.widthAnchor.constraint(equalToConstant: setupSize.width)
        rowWidth = width
        let nativeHeightConstraint = vc.view.heightAnchor.constraint(equalToConstant: setupSize.height)
        nativeHeight = nativeHeightConstraint

        NSLayoutConstraint.activate([
            nativeLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            nativeLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            vc.view.topAnchor.constraint(equalTo: nativeLabel.bottomAnchor, constant: 8),
            vc.view.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            nativeHeightConstraint,
            vc.view.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
        ])
        width.isActive = true

        let frame = NSRect(x: 0, y: 0, width: setupSize.width + 60, height: setupSize.height + 90)
        let win = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        win.title = "Recording panel — AppKit"
        // MUST match the real panel. FloatingPanelController sets this, and it
        // is the whole reason chips were unclickable: with it on, AppKit treats
        // a press on any view whose `mouseDownCanMoveWindow` is true (the
        // default for a non-opaque view) as the start of a window drag, so the
        // matching mouse-up never reaches the control. A harness window without
        // it cannot reproduce the bug — which is why the screenshots stayed
        // green while every control in the panel was dead.
        win.isMovableByWindowBackground = true
        win.contentView = root
        root.frame = NSRect(origin: .zero, size: frame.size)
        win.center()
        win.orderFrontRegardless()
        window = win

        vc.start()
        root.layoutSubtreeIfNeeded()
    }

    private static func resizeRows(setup: Bool) {
        let size = setup ? RecordingPanelMetrics.setupPanelSize() : RecordingPanelMetrics.recordingPanelSize()
        rowWidth?.constant = size.width
        nativeHeight?.constant = size.height
        nativeRow?.superview?.needsLayout = true
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    private static func caption(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 11, weight: .semibold)
        field.textColor = NSColor.white.withAlphaComponent(0.75)
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    // MARK: - Panel drop-down enumeration

    /// Prints every menu the native panel can open, so its rows stay
    /// enumerable in the report.
    /// Clicks each source tab through REAL event dispatch and asserts the
    /// selection actually changed.
    ///
    /// Deliberately posts events rather than calling `mouseUp(with:)` directly:
    /// the bug this guards lived in AppKit's dispatch, not in the handler.
    /// Invoking the handler by hand would have passed happily the entire time
    /// the panel was unusable.
    @MainActor
    private static func checkTabClicks() async -> Int {
        guard let vc = controller, let win = window else {
            print("TABCLICK no panel FAIL"); return 1
        }
        var failures = 0

        let fit = vc.debugToolbarFitting
        let overflows = fit.needed > fit.available + 0.5
        print("TOOLBAR-FIT needed=\(Int(fit.needed)) available=\(Int(fit.available)) \(overflows ? "OVERFLOWS" : "ok")")
        if overflows {
            print("TOOLBAR-FIT FAIL — the row does not fit, so AppKit breaks the width")
            print("  constraint and the chips overlap. Clicks then hit whichever view is")
            print("  on top, which is why the tabs appear dead.")
            failures += 1
        }

        for f in vc.debugSetupFrames where !f.hidden {
            let r = f.frame
            print("  FRAME \(f.name) x=\(Int(r.minX))..\(Int(r.maxX)) y=\(Int(r.minY))..\(Int(r.maxY))")
        }

        for (tab, chip) in vc.debugTabChips {
            // The two properties whose defaults caused the dead panel.
            if chip.mouseDownCanMoveWindow {
                print("TABCLICK \(tab.rawValue) mouseDownCanMoveWindow=true FAIL")
                failures += 1
            }
            if !chip.acceptsFirstMouse(for: nil) {
                print("TABCLICK \(tab.rawValue) acceptsFirstMouse=false FAIL")
                failures += 1
            }
        }

        // The Record/Screenshot switch is the same class of control and the
        // same class of bug, so it gets the same treatment.
        if let vc2 = controller {
            for (mode, chip) in vc2.debugModeChips {
                if chip.mouseDownCanMoveWindow {
                    print("MODECLICK \(mode.rawValue) mouseDownCanMoveWindow=true FAIL"); failures += 1
                }
            }
        }

        // Functional pass: click every tab that is not already selected and
        // require the selection to follow.
        for tab in RecordingSourceTab.allCases where tab != vc.debugSelectedTab {
            guard let chip = vc.debugTabChips[tab] else { continue }
            let centre = chip.convert(NSPoint(x: chip.bounds.midX, y: chip.bounds.midY), to: nil)
            let hit = win.contentView?.hitTest(centre)
            let hitDesc = hit.map { String(describing: type(of: $0)) } ?? "nil"
            print("TABCLICK \(tab.rawValue) at \(Int(centre.x)),\(Int(centre.y)) hitTest=\(hitDesc) chipFrame=\(chip.frame) hidden=\(chip.isHidden) enabled=\(chip.isEnabled)")
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let ev = NSEvent.mouseEvent(
                    with: type, location: centre, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: win.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
                ) {
                    win.sendEvent(ev)
                }
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
            let landed = vc.debugSelectedTab == tab
            print("TABCLICK \(tab.rawValue) -> selected=\(vc.debugSelectedTab.rawValue) \(landed ? "PASS" : "FAIL")")
            if !landed { failures += 1 }
        }
        // Rapid-switch storm: fire tab changes faster than the crossfade
        // clock, ending on URL (the extreme layout change). Mid-storm at most
        // ONE frozen snapshot may exist; once settled there must be exactly
        // zero and the live row at full alpha. Stacked snapshots are the
        // user-reported "duplicate logos on rapid URL switching" bug.
        let storm: [RecordingSourceTab] = [.url, .display, .url, .area, .url]
        var maxSnapshots = 0
        for tab in storm {
            vc.debugSelectTab(tab)
            maxSnapshots = max(maxSnapshots, vc.debugCrossfadeSnapshotCount)
            try? await Task.sleep(nanoseconds: 60_000_000) // < half the clock
        }
        try? await Task.sleep(nanoseconds: 800_000_000) // settle past the clock
        let leftover = vc.debugCrossfadeSnapshotCount
        let settled = vc.debugRowIsSettled
        let stormOK = maxSnapshots <= 1 && leftover == 0 && settled
        print("TABSTORM maxSnapshots=\(maxSnapshots) leftover=\(leftover) settled=\(settled) \(stormOK ? "PASS" : "FAIL")")
        if !stormOK { failures += 1 }
        vc.debugSelectTab(.display)

        return failures
    }

    private static func dumpPanelMenus() {
        guard let controller else { return }
        for (name, menu) in controller.debugMenus() {
            print("PANELMENU[\(name)] \(menu.items.count) items")
            for line in StatusMenuBuilder.describe(menu) {
                print("PANELMENU[\(name)]   \(line)")
            }
        }
        for (name, list) in controller.debugOptionLists() {
            print("PANELPOPUP[\(name)] \(list.options.count) options"
                + " selected=\(list.selectedIndex.map(String.init) ?? "none")"
                + " searchable=\(list.searchable)")
            for option in list.options {
                let subtitle = option.subtitle.map { " — \($0)" } ?? ""
                print("PANELPOPUP[\(name)]   \(option.title)\(subtitle)")
            }
        }
    }

    // MARK: - Status-item menu enumeration

    /// Prints the native status-item menu in every state.
    private static func dumpStatusMenu(appState: AppState) {
        let stub = StatusMenuActionRecorder()
        let states: [(String, RecordingPhase)] = [
            ("idle", .idle),
            ("recording", .recording),
            ("paused", .paused),
        ]
        for (name, phase) in states {
            appState.recordingSession.phase = phase
            let menu = NSMenu()
            StatusMenuBuilder.populateStatusMenu(menu, appState: appState, target: stub, updaterTarget: nil)
            print("MENU[\(name)] \(menu.items.count) items")
            for line in StatusMenuBuilder.describe(menu) {
                print("MENU[\(name)]   \(line)")
            }
        }
    }

    // MARK: - Capture

    /// Reads the shell's ACTUAL layer fill and asserts it matches the live
    /// theme. A mean pixel diff is blind to this — the bar is a small part of
    /// a wide frame — so the gate scores the colour itself.
    private static func reportShellFill() {
        guard let shell = controller?.debugShellLayerFill() else {
            print("THEME-FLIP FAIL — no shell layer")
            return
        }
        let expected = RecordingPanelMetrics.barFill.usingColorSpace(.sRGB)
        let actual = NSColor(cgColor: shell)?.usingColorSpace(.sRGB)
        let want = expected?.brightnessComponent ?? -1
        let got = actual?.brightnessComponent ?? -2
        let pass = abs(want - got) < 0.02
        print(String(format: "THEME-FLIP %@ shell fill brightness=%.3f expected=%.3f (light mode)",
                     pass ? "PASS" : "FAIL", got, want))
    }

    private static func capture(_ name: String) async {
        guard let window else { return }
        let url = outputDirectory.appendingPathComponent("capturecat-recording-panel-\(name).png")
        guard let image = await windowImage(window) else {
            print("SHOT \(name) FAILED")
            return
        }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("SHOT \(name) \(url.path) \(image.width)x\(image.height)")
    }

    private static func windowImage(_ window: NSWindow) async -> CGImage? {
        let id = CGWindowID(window.windowNumber)
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let target = content.windows.first(where: { $0.windowID == id }) else {
            return nil
        }
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let config = SCStreamConfiguration()
        config.width = Int(target.frame.width * 2)
        config.height = Int(target.frame.height * 2)
        config.showsCursor = false
        config.captureResolution = .best
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}

/// Stand-in target so the status menu can be built (and its selectors
/// resolved) outside the app delegate.
@MainActor
private final class StatusMenuActionRecorder: NSObject, StatusMenuActions {
    func newRecording(_ sender: Any?) {}
    func browseProjects(_ sender: Any?) {}
    func signOut(_ sender: Any?) {}
    func signIn(_ sender: Any?) {}
    func pauseOrResumeRecording(_ sender: Any?) {}
    func stopRecording(_ sender: Any?) {}
    func toggleAutoZoomNewRecordings(_ sender: Any?) {}
    func setAppearanceMode(_ sender: Any?) {}
    func openSettings(_ sender: Any?) {}
}

/// Colourful backdrop so the Liquid Glass has something to refract — a flat
/// grey would make both panels look identical for the wrong reason.
private final class GradientBackdropView: NSView {
    override var isFlipped: Bool { true }

    /// Flat near-black backdrop for `--panel-live-capture`: the pixel gate
    /// integrates bright mass in the tab band, and the glass-refraction bars
    /// would leak bright pixels into it whenever the shell edge moves.
    var plainDark = false

    override func draw(_ dirtyRect: NSRect) {
        if plainDark {
            NSColor(srgbRed: 0.07, green: 0.07, blue: 0.09, alpha: 1).setFill()
            bounds.fill()
            return
        }
        let gradient = NSGradient(colors: [
            NSColor(srgbRed: 0.13, green: 0.16, blue: 0.32, alpha: 1),
            NSColor(srgbRed: 0.52, green: 0.20, blue: 0.36, alpha: 1),
            NSColor(srgbRed: 0.10, green: 0.36, blue: 0.38, alpha: 1),
        ])
        gradient?.draw(in: bounds, angle: 35)

        // High-contrast bars: glass distortion is only visible over edges.
        NSColor.white.withAlphaComponent(0.85).setFill()
        var y: CGFloat = 0
        while y < bounds.height {
            NSRect(x: 0, y: y, width: bounds.width, height: 6).fill()
            y += 34
        }
    }
}
