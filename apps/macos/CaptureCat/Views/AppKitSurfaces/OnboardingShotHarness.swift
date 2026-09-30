import AppKit

/// Headless acceptance probe for the onboarding wizard.
///
///   CaptureCat --onboarding-shot
///
/// Asserts what the visual gates have been burned by before:
///  • TOPOLOGY — the REAL controller in BOTH of its hosting chains: its own
///    960×600 window (CaptureCatAppDelegate) and the editor window's content
///    switcher (EditorWindowContentViewController, resizable, 900×600 floor).
///    Every step: content column inside the left panel and clear of the
///    footer, stage exactly the right half, footer controls un-collided.
///  • MOTION, mid-flight — the welcome camera genuinely pushes in (samples
///    strictly between 1× and the zoom depth, and reaching both ends over one
///    loop); a step change is caught mid-transition (page glide + scene
///    dissolve + step capsule stretch); an injected grant springs the stage's
///    mirrored switch mid-travel; the finish burst is live.
///  • LIVE THEME — dark→light repaints mounted chrome AND the stage.
///  • RESPONSIVE — the editor host is grown and shrunk; invariants re-checked.
/// Saves per-step captures (upright, 1×) and a welcome-loop contact sheet
/// to the container tmp dir. DEBUG tooling; never reached in a normal launch.
@MainActor
enum OnboardingShotHarness {
    private static var failures = 0
    private static let outDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("capturecat-onboarding-shot", isDirectory: true)

    static func run() -> Never {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        CCTheme.setMode(.dark, persist: false)
        Task { @MainActor in
            await execute()
            print(failures == 0 ? "ONBOARDING PASS" : "ONBOARDING FAIL (\(failures))")
            exit(failures == 0 ? 0 : 1)
        }
        app.run()
        exit(0)
    }

    private static func expect(_ condition: Bool, _ label: String) {
        print("ONBOARDING \(condition ? "PASS" : "FAIL") \(label)")
        if !condition { failures += 1 }
    }

    private static func pump(_ seconds: Double) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            try? await Task.sleep(for: .milliseconds(8))
        }
    }

    // MARK: - Flow

    private static func execute() async {
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        AppState.suppressAutoToolbar = true
        OnboardingViewController.harnessMode = true
        let appState = AppState()

        // ── Topology A: the dedicated onboarding window, exactly as the app
        // delegate builds it.
        let onboarding = OnboardingViewController(appState: appState)
        let window = NSWindow(contentViewController: onboarding)
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 960, height: 600))
        window.setFrameOrigin(NSPoint(x: -6000, y: -6000))
        window.orderFrontRegardless()
        onboarding.probeSetPermissions(screen: false, notifications: false, microphone: false, camera: false)
        await pump(0.3)

        let names = ["welcome", "permissions", "account", "shortcut", "finish"]
        for (index, name) in names.enumerated() {
            onboarding.jumpToStep(index)
            await pump(1.1)
            checkInvariants(onboarding, label: "window/\(name)")
            expect(onboarding.probeStage.currentID?.rawValue == index, "window/\(name) stage shows its scene")
            expect(onboarding.probeStepIndicator.index == index, "window/\(name) step indicator index")
            if name == "finish" {
                // First arrival celebrates (0.55s in; particles live ~1.5s).
                let finish = onboarding.probeStage.probeScene(.finish)
                let bursting = finish?.layer.sublayers?.filter { $0.animation(forKey: "burst") != nil }.count ?? 0
                expect(bursting >= 10, "finish celebration burst is live on first arrival (\(bursting) particles)")
            }
        }

        // Every MOTION probe runs before the first capture: a capture hands
        // the window's live layer tree to an offscreen CARenderer, and after
        // that the live window can stop vending presentation layers — a
        // later mid-flight probe then reads settled MODEL values and fails
        // (or worse, passes) for the wrong reason. Seen as a flaky
        // transition assert, diagnosed from per-sample `presentation() == nil`.
        materialShapeProbe(onboarding)
        await transitionProbe(onboarding)
        await permissionMirrorProbe(onboarding, window: window)
        await welcomeCameraProbe(onboarding)

        // ── Captures (after all motion probes).
        for (index, name) in names.enumerated() {
            onboarding.jumpToStep(index)
            // Account: wait into the share loop's "Copied" beat (1.85s+) so
            // the review shot shows the finished state, not the progress bar.
            await pump(index == 2 ? 2.6 : 1.1)
            capture(window, name: index == 1 ? "step-1-permissions-granted-dark" : "step-\(index)-\(name)-dark")
        }
        await captureWelcomeSheet(onboarding, window: window)
        await themeProbe(onboarding, window: window)
        window.orderOut(nil)

        // ── Topology B: the editor window's content switcher, resizable.
        await editorHostProbe(appState: appState)
    }

    // MARK: - Invariants

    private static func checkInvariants(_ onboarding: OnboardingViewController, label: String) {
        let root = onboarding.view
        let rootW = root.bounds.width, rootH = root.bounds.height
        let stageFrame = onboarding.probeStage.convert(onboarding.probeStage.bounds, to: root)
        let left = onboarding.probeLeftPanel.convert(onboarding.probeLeftPanel.bounds, to: root)
        let stageOK = abs(stageFrame.minX - rootW * OnboardingViewController.stageFraction) < 1
            && abs(stageFrame.maxX - rootW) < 1 && abs(stageFrame.height - rootH) < 1
        expect(stageOK, "\(label) stage is the right \(Int(OnboardingViewController.stageFraction * 100))% "
            + "(\(Int(stageFrame.minX))…\(Int(stageFrame.maxX)) of \(Int(rootW)))")

        guard let stack = onboarding.probePageStack else {
            expect(false, "\(label) page stack mounted")
            return
        }
        let content = stack.convert(stack.bounds, to: root)
        let next = onboarding.probeNextButton.convert(onboarding.probeNextButton.bounds, to: root)
        // Y-up root: the footer band sits BELOW next.maxY + margin.
        let footerTop = next.maxY + 16
        let inside = content.minX >= left.minX + 24 && content.maxX <= left.maxX - 24
        let clearOfFooter = content.minY >= footerTop
        let clearOfTitlebar = content.maxY <= rootH - 28
        expect(inside && clearOfFooter && clearOfTitlebar,
               "\(label) content column fits (x \(Int(content.minX))…\(Int(content.maxX)) in left "
               + "\(Int(left.minX))…\(Int(left.maxX)); y \(Int(content.minY))…\(Int(content.maxY)), "
               + "footer top \(Int(footerTop)), height \(Int(rootH)))")
        let degenerate = stack.arrangedSubviews.filter { !$0.isHidden }
            .filter { $0.frame.width < 10 || $0.frame.height < 1 }
        expect(degenerate.isEmpty, "\(label) no degenerate rows (\(degenerate.count))")
        let back = onboarding.probeBackButton.convert(onboarding.probeBackButton.bounds, to: root)
        let dots = onboarding.probeStepIndicator.convert(onboarding.probeStepIndicator.bounds, to: root)
        let footerOK = next.maxX <= left.maxX - 8 && next.minX > dots.maxX
            && (onboarding.probeBackButton.isHidden || back.maxX < dots.minX)
        expect(footerOK, "\(label) footer un-collided")
        let backButton = onboarding.probeBackButton
        let backShown = !backButton.isHidden && backButton.alphaValue > 0.9
        expect(onboarding.probeStepIndex == 0 ? !backShown : backShown,
               "\(label) Back visible exactly off the first step (hidden=\(backButton.isHidden) alpha=\(backButton.alphaValue))")
    }

    /// Structural, not pixel-mean: every material-dressed layer in every
    /// scene must round its OWN fill/shadow to the face's radius. A raw
    /// layer dressed with CCMaterial but left square paints a hard black
    /// rectangle behind the pill (shipped once in a capture — "the bg black
    /// stuff"); a mean pixel diff barely notices four corners.
    private static func materialShapeProbe(_ onboarding: OnboardingViewController) {
        var offenders: [String] = []
        var checked = 0
        func walk(_ layer: CALayer, path: String) {
            if layer.value(forKey: "ccmatStyle") != nil,
               let base = layer.sublayers?.first(where: { $0.name == "ccmat.base" }) {
                checked += 1
                let filled = (layer.backgroundColor?.alpha ?? 0) > 0.01 || layer.shadowOpacity > 0.01
                if filled && layer.cornerRadius + 0.5 < base.cornerRadius {
                    offenders.append("\(path) host r=\(layer.cornerRadius) face r=\(base.cornerRadius)")
                }
            }
            for (i, sub) in (layer.sublayers ?? []).enumerated() where sub.name?.hasPrefix("ccmat.") != true {
                walk(sub, path: "\(path)/\(i)")
            }
        }
        for id in OnboardingStageView.SceneID.allCases {
            guard let scene = onboarding.probeStage.probeScene(id) else {
                expect(false, "material shape: scene \(id) built")
                continue
            }
            walk(scene.layer, path: "\(id)")
            walk(scene.overlay, path: "\(id).overlay")
        }
        for offender in offenders { print("ONBOARDING square material host: \(offender)") }
        expect(offenders.isEmpty && checked >= 10,
               "stage material hosts follow their face shape (\(checked) checked, \(offenders.count) square)")
    }

    // MARK: - Motion probes

    /// The camera must genuinely push in and back out over one loop — and be
    /// caught BETWEEN the two ends (a snapped zoom passes a settled check).
    private static func welcomeCameraProbe(_ onboarding: OnboardingViewController) async {
        onboarding.jumpToStep(0)
        await pump(0.2)
        let camera = onboarding.probeStage.probeCamera
        let welcome = onboarding.probeStage.probeScene(.welcome) as? WelcomeScene
        var scales: [CGFloat] = []
        var cursorXs = Set<Int>()
        let start = Date()
        while Date().timeIntervalSince(start) < WelcomeScene.period + 0.3 {
            let t = (camera.presentation() ?? camera).transform
            scales.append(t.m11)
            if let cursor = welcome?.cursor {
                cursorXs.insert(Int((cursor.presentation() ?? cursor).position.x))
            }
            await pump(0.04)
        }
        let peak = scales.max() ?? 0
        let floor = scales.min() ?? 0
        let midFlight = scales.filter { $0 > 1.08 && $0 < WelcomeScene.zoomDepth - 0.08 }.count
        expect(abs(peak - WelcomeScene.zoomDepth) < 0.04 && abs(floor - 1) < 0.01 && midFlight >= 3,
               "welcome camera pushes in and out (min \(floor) peak \(peak), \(midFlight) mid-flight samples)")
        expect(cursorXs.count >= 12, "welcome cursor travels (\(cursorXs.count) distinct x)")
    }

    /// Eight frames across one welcome loop, for judging the choreography
    /// as a sequence. Capture-only — no assertions ride on it.
    private static func captureWelcomeSheet(_ onboarding: OnboardingViewController, window: NSWindow) async {
        onboarding.jumpToStep(2)
        await pump(0.3)
        onboarding.jumpToStep(0)
        var sheet: [CGImage] = []
        await pump(0.4)
        for _ in 0..<8 {
            if let image = render(window) { sheet.append(image) }
            await pump(0.9)
        }
        writeSheet(sheet, name: "welcome-loop-sheet")
    }

    /// A forward step caught mid-transition: page glides, scene dissolves,
    /// the step capsule stretches. Polled at ~60Hz across the whole
    /// transition (a single timed sample lands late on a loaded machine and
    /// reads settled values) — each quantity must be SEEN between its ends.
    private static func transitionProbe(_ onboarding: OnboardingViewController) async {
        onboarding.jumpToStep(0)
        await pump(0.5)
        let began = Date()
        onboarding.probeAdvance()
        guard let stack = onboarding.probePageStack, let first = stack.arrangedSubviews.first?.layer,
              let sceneLayer = onboarding.probeStage.probeScene(.permissions)?.layer else {
            expect(false, "transition page + scene mounted")
            return
        }
        let dot = onboarding.probeStepIndicator.probeActiveDot
        var pageSeen = false, sceneSeen = false, dotSeen = false
        var samples = 0
        var lastPage = "", lastScene: Float = -1, lastDot: CGFloat = -1
        while Date().timeIntervalSince(began) < 1.0 {
            let presented = first.presentation() ?? first
            let tx = (presented.value(forKeyPath: "transform.translation.x") as? CGFloat) ?? 0
            let opacity = presented.opacity
            if (tx > 0.5 && tx < 25.5) || (opacity > 0.02 && opacity < 0.98) { pageSeen = true }
            let sceneOpacity = (sceneLayer.presentation() ?? sceneLayer).opacity
            if sceneOpacity > 0.02 && sceneOpacity < 0.98 { sceneSeen = true }
            let width = (dot.presentation() ?? dot).bounds.width
            if width > CCStepIndicator.dotSide + 0.5 && width < CCStepIndicator.activeWidth - 0.5 { dotSeen = true }
            lastPage = "tx \(tx) opacity \(opacity)"
            lastScene = sceneOpacity
            lastDot = width
            samples += 1
            await pump(0.016)
        }
        expect(pageSeen, "transition page glides in (\(samples) samples, last \(lastPage))")
        expect(sceneSeen, "transition scene dissolves in (last opacity \(lastScene))")
        expect(dotSeen, "transition step capsule stretches (last width \(lastDot))")
    }

    /// Injecting a grant springs the mirrored switch — caught mid-travel —
    /// and the Continue gate opens; before it, a click on the disabled
    /// Continue fires the hint instead of a dead click.
    private static func permissionMirrorProbe(_ onboarding: OnboardingViewController, window: NSWindow) async {
        onboarding.jumpToStep(1)
        onboarding.probeSetPermissions(screen: false, notifications: true, microphone: false, camera: false)
        await pump(0.8)
        let next = onboarding.probeNextButton
        expect(!next.isEnabled, "permissions Continue gated while Screen Recording is missing")
        let point = next.convert(NSPoint(x: next.bounds.midX, y: next.bounds.midY), to: nil)
        if let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil,
                                         eventNumber: 0, clickCount: 1, pressure: 1) {
            next.mouseDown(with: down)
        }
        expect(next.layer?.animation(forKey: "hint-shake") != nil, "disabled Continue click fires the hint")

        guard let scene = onboarding.probeStage.probeScene(.permissions) as? PermissionsScene else {
            expect(false, "permissions scene mounted")
            return
        }
        let knob = scene.probeKnob(0)
        let offX = knob.position.x
        onboarding.probeSetPermissions(screen: true, notifications: true, microphone: false, camera: false)
        let onX = knob.position.x
        await pump(0.06)
        let midX = (knob.presentation() ?? knob).position.x
        expect(onX > offX + 5 && midX > offX + 0.5 && midX < onX - 0.5,
               "stage mirror switch springs mid-travel (\(offX) → \(onX), @60ms \(midX))")
        await pump(0.9)
        expect(next.isEnabled, "permissions Continue opens once Screen Recording is granted")
    }

    private static func themeProbe(_ onboarding: OnboardingViewController, window: NSWindow) async {
        onboarding.jumpToStep(0)
        await pump(0.5)
        let rootBefore = onboarding.view.layer?.backgroundColor
        let baseBefore = onboarding.probeStage.probeWallpaper.probeBase.colors?.first as! CGColor?
        CCTheme.setMode(.light, persist: false)
        await pump(0.6)
        let rootAfter = onboarding.view.layer?.backgroundColor
        let baseAfter = onboarding.probeStage.probeWallpaper.probeBase.colors?.first as! CGColor?
        expect(rootBefore != nil && rootAfter != nil && rootBefore != rootAfter, "theme swap repaints the panel")
        expect(baseBefore != nil && baseAfter != nil && baseBefore != baseAfter, "theme swap repaints the stage")
        capture(window, name: "step-0-welcome-light")
        onboarding.jumpToStep(1)
        await pump(1.0)
        capture(window, name: "step-1-permissions-light")
        CCTheme.setMode(.dark, persist: false)
        await pump(0.3)
    }

    // MARK: - Topology B

    private static func editorHostProbe(appState: AppState) async {
        appState.hasCompletedOnboarding = false   // in-memory only — never persisted here
        let content = EditorWindowContentViewController(appState: appState)
        let window = NSWindow(contentViewController: content)
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 900, height: 600)
        window.setContentSize(NSSize(width: 1100, height: 700))
        window.setFrameOrigin(NSPoint(x: -6000, y: -6000))
        window.orderFrontRegardless()
        await pump(0.6)
        guard let onboarding = content.children.first as? OnboardingViewController else {
            expect(false, "editor host mounts the onboarding child")
            return
        }
        onboarding.probeSetPermissions(screen: true, notifications: false, microphone: false, camera: false)
        for (size, tag) in [(NSSize(width: 1100, height: 700), "1100"), (NSSize(width: 1600, height: 1000), "1600"),
                            (NSSize(width: 900, height: 600), "900")] {
            window.setContentSize(size)
            onboarding.jumpToStep(1)
            await pump(1.0)
            checkInvariants(onboarding, label: "editor@\(tag)")
            capture(window, name: "editor-host-\(tag)")
        }
        // The stage re-arms its loop geometry on a real resize: the welcome
        // camera must still frame its click inside the stage.
        onboarding.jumpToStep(0)
        window.setContentSize(NSSize(width: 1400, height: 860))
        await pump(0.4)
        if let welcome = onboarding.probeStage.probeScene(.welcome) as? WelcomeScene {
            let stage = onboarding.probeStage.bounds
            expect(stage.contains(welcome.probeClickA), "editor resize re-lays the welcome demo (click \(welcome.probeClickA) in \(stage.size))")
        }
        window.orderOut(nil)
    }

    // MARK: - Captures

    /// CARenderer frames come back whole-frame Y-mirrored and at 1× (see
    /// CARendererSnapshot) — render at 1× and flip upright for review.
    private static func render(_ window: NSWindow) -> CGImage? {
        guard let content = window.contentView, let layer = content.layer,
              let raw = CARendererSnapshot.render(layer: layer, size: content.bounds.size, scale: 1)
        else { return nil }
        let w = raw.width, h = raw.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return raw }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(raw, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? raw
    }

    private static func capture(_ window: NSWindow, name: String) {
        guard let image = render(window) else {
            expect(false, "capture \(name)")
            return
        }
        write(image, name: name)
    }

    private static func write(_ image: CGImage, name: String) {
        let url = outDir.appendingPathComponent("\(name).png")
        let rep = NSBitmapImageRep(cgImage: image)
        if let png = rep.representation(using: .png, properties: [:]), (try? png.write(to: url)) != nil {
            print("ONBOARDING capture \(url.path)")
        }
    }

    /// 4×2 contact sheet of the welcome loop at half size — for judging the
    /// choreography as a sequence, never a single settled frame.
    private static func writeSheet(_ frames: [CGImage], name: String) {
        guard let first = frames.first else { return }
        let tw = first.width / 2, th = first.height / 2
        let cols = 4, rows = (frames.count + cols - 1) / cols
        guard let ctx = CGContext(data: nil, width: tw * cols, height: th * rows, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        for (i, frame) in frames.enumerated() {
            let col = i % cols, row = i / cols
            ctx.draw(frame, in: CGRect(x: col * tw, y: (rows - 1 - row) * th, width: tw, height: th))
        }
        if let image = ctx.makeImage() { write(image, name: name) }
    }
}
