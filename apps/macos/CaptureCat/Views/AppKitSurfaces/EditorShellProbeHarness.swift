import AVFoundation
import AppKit

/// Acceptance probe for the editor SHELL.
///
///     CaptureCat --editor-shell-shot [<outDir>]
///
/// Builds `EditorShellViewController` at a fixed window size, writes a PNG plus
/// a resolved-frame report, then runs the behaviour checks a screenshot cannot
/// cover (inspector collapse, focus target, player lifecycle, autosave).
///
/// This probe used to render a SwiftUI `EditorShellView` alongside the native
/// shell and diff the two. That reference arm was deleted with the SwiftUI
/// shell itself — there is only one shell now, so the report is absolute
/// rather than comparative.
///
/// Standalone off-screen window — never touches the running app.
/// DEBUG tooling; never reached in a normal launch.
@MainActor
enum EditorShellProbeHarness {

    /// Kept at the size the two-shell comparison used, so frame reports stay
    /// comparable against previously captured baselines.
    static let windowSize = NSSize(width: 1400, height: 800)

    static func run() -> Never {
        setbuf(stdout, nil)
        if CommandLine.arguments.contains("--light") {
            MainActor.assumeIsolated { CCTheme.setMode(.light, persist: false) }
        } else if CommandLine.arguments.contains("--dark") {
            MainActor.assumeIsolated { CCTheme.setMode(.dark, persist: false) }
        } else {
            // A persisted "system" mode resolves LIGHT in this headless
            // process (no Aqua session), while the user's GUI resolves dark —
            // probe shots then look nothing like the app. Default the probe
            // to the app's dark-first look; --light opts out.
            MainActor.assumeIsolated { CCTheme.setMode(.dark, persist: false) }
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        Task { @MainActor in
            await execute()
            exit(0)
        }
        app.run()
        exit(0)
    }

    // MARK: - Run

    private static func execute() async {
        // Re-seed HERE, after app launch: applicationDidFinishLaunching
        // re-applies the persisted mode ("system" resolves LIGHT in this
        // headless process), overwriting the seed run() set before launch.
        if CommandLine.arguments.contains("--light") {
            CCTheme.setMode(.light, persist: false)
        } else {
            CCTheme.setMode(.dark, persist: false)
        }
        let outDir: URL = {
            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "--editor-shell-shot"), i + 1 < args.count,
               !args[i + 1].hasPrefix("-") {
                return URL(fileURLWithPath: args[i + 1])
            }
            return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("capturecat-editor-shell")
        }()
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let fixtureDir = outDir.appendingPathComponent("fixture")
        try? FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
        let videoURL = fixtureDir.appendingPathComponent("screen.mov")
        guard await PlaybackObserverHarness.writeVideo(
            to: videoURL, seconds: 4.0, size: CGSize(width: 1280, height: 800), tint: 0.35
        ) else {
            print("SHELLSHOT FAIL could not synthesize fixture video")
            return
        }

        let nativeProject = makeProject(videoURL: videoURL, name: "Shell Probe")

        // ── Native shell window (real editor topology: top bar + shell) ──
        let native = EditorShellViewController(appState: nil, project: nativeProject)
        let container = ProbeContentViewController(shell: native)
        let nativeWindow = makeWindow(content: container, title: nativeProject.name, x: 40)

        // Let AVFoundation decode and AppKit lay out. The size is re-asserted
        // mid-settle so the report is taken at exactly `windowSize`.
        for i in 0..<14 {
            try? await Task.sleep(for: .milliseconds(250))
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            if i == 6 { nativeWindow.setContentSize(windowSize) }
        }

        report(label: "NATIVE ", window: nativeWindow)

        let nativeShot = capture(window: nativeWindow)
        write(nativeShot, to: outDir.appendingPathComponent("shell-native.png"), label: "NATIVE")

        framingChecks(shot: nativeShot, window: nativeWindow)

        // Top bar: CARenderer sees nothing in the titlebar (it is not layer
        // hosted), so the toolbar strip is captured through `cacheDisplay`.
        writeRaw(titlebar(of: nativeWindow), to: outDir.appendingPathComponent("toolbar-native.png"), label: "TOOLBAR-NATIVE")

        // Behaviours a screenshot cannot show.
        await behaviourChecks(shell: native, window: nativeWindow)

        // ── In-place editor probe ─────────────────────────────────────────
        // The editor must REPLACE the drawn label (Chrome.editingID), sit on
        // the exact label rect, and the drawn twin must not peek out anywhere.
        await inlineEditProbe(shell: native, project: nativeProject,
                              window: nativeWindow, outDir: outDir)

        await annotateScrollProbe(shell: native, project: nativeProject)

        print("SHELLSHOT outDir \(outDir.path)")
    }

    /// Stacked annotations grow the timeline canvas past its viewport; the
    /// scroll view must actually scroll to them (this clipped silently once —
    /// the lane grew but the viewport pinned at y=0 with no vertical scroller).
    private static func annotateScrollProbe(
        shell: EditorShellViewController, project: Project
    ) async {
        // Three overlapping annotations → three full-height sub-rows.
        var a2 = Annotation(type: .rectangle, startTime: 1.0, endTime: 2.5)
        a2.x = 0.2; a2.y = 0.2; a2.arrowEndX = 0.4; a2.arrowEndY = 0.4
        var a3 = Annotation(type: .ellipse, startTime: 1.2, endTime: 2.4)
        a3.x = 0.5; a3.y = 0.5; a3.arrowEndX = 0.7; a3.arrowEndY = 0.7
        project.annotations.append(contentsOf: [a2, a3])
        await settle(0.8)

        guard let scroll = findSubview(ofType: TimelineScrollView.self, in: shell.view),
              let doc = scroll.documentView else {
            print("ANNOTATE-SCROLL FAIL no timeline scroll view")
            return
        }
        let overflow = doc.frame.height - scroll.contentView.bounds.height
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, overflow)))
        scroll.reflectScrolledClipView(scroll.contentView)
        await settle(0.2)
        let scrolledY = scroll.contentView.bounds.origin.y
        let pass = overflow > 20 && scrolledY > overflow - 1
        print(String(
            format: "ANNOTATE-SCROLL doc=%.0f viewport=%.0f overflow=%.0f scrolledY=%.0f %@",
            doc.frame.height, scroll.contentView.bounds.height, overflow, scrolledY,
            pass ? "PASS" : "FAIL"
        ))
    }

    /// Opens the in-place editor on the fixture's text annotation inside the
    /// REAL shell and captures the result — the probe topology rule: the
    /// grey-slab/double-label bugs never reproduced in a bare window.
    private static func inlineEditProbe(
        shell: EditorShellViewController, project: Project,
        window: NSWindow, outDir: URL
    ) async {
        guard let annotation = project.annotations.first(where: { $0.type == .text }) else {
            print("INLINE-EDIT SKIP no text annotation in fixture")
            return
        }
        guard let compositor = findSubview(ofType: PreviewCompositorView.self, in: shell.view) else {
            print("INLINE-EDIT FAIL no compositor in shell")
            return
        }

        // Playhead inside the annotation's span, selected, paused.
        shell.playback.currentTime = (annotation.startTime + annotation.endTime) / 2
        shell.selection.selectedAnnotationID = annotation.id
        await settle(0.6)

        compositor.beginInlineTextEdit(annotationID: annotation.id)
        await settle(0.6)

        let editing = findSubview(ofType: PreviewInteractionView.self, in: shell.view)?
            .inlineEditingID == annotation.id
        print(editing
            ? "INLINE-EDIT PASS editor open on the fixture annotation"
            : "INLINE-EDIT FAIL editor did not open")

        write(capture(window: window), to: outDir.appendingPathComponent("inline-edit.png"),
              label: "INLINE-EDIT")
    }

    /// Framing checks (user call 2026-08-26, "extra frame around it"):
    ///
    /// 1. canvas-flush — the letterbox bars between the stage card's edge and
    ///    the canvas must be the PANEL surface (part of the card), never the
    ///    window background (a second frame). Pixel-sampled, not eyeballed.
    /// 2. right-margin-symmetry — the inspector panel's gap to the window's
    ///    right edge must equal the stage card's gap to the left edge.
    private static func framingChecks(shot: CGImage?, window: NSWindow) {
        guard let content = window.contentView,
              let preview = findSubview(ofType: PreviewCompositorView.self, in: content),
              let stageCard = findSubview(ofType: ZoomScrollView.self, in: content)?.superview,
              let inspectorPanel = findSubview(ofType: InspectorColumnAppKit.self, in: content)?.superview
        else {
            print("BEHAVIOUR FAIL framing — shell views not found")
            return
        }
        let cardRect = stageCard.convert(stageCard.bounds, to: content)
        let panelRect = inspectorPanel.convert(inspectorPanel.bounds, to: content)
        let previewRect = preview.convert(preview.bounds, to: content)

        // 2. Symmetry (geometric).
        let leftMargin = cardRect.minX
        let rightMargin = content.bounds.width - panelRect.maxX
        let symmetric = abs(leftMargin - rightMargin) < 0.5
        print(String(
            format: "BEHAVIOUR %@ right-margin-symmetry — left=%.1f right=%.1f",
            symmetric ? "PASS" : "FAIL", leftMargin, rightMargin
        ))

        // 1. Letterbox bar surface (pixel-sampled from the actual shot).
        guard let shot else {
            print("BEHAVIOUR FAIL canvas-flush — no capture to sample")
            return
        }
        func srgb(_ color: NSColor) -> (CGFloat, CGFloat, CGFloat) {
            let c = color.usingColorSpace(.sRGB) ?? color
            return (c.redComponent * 255, c.greenComponent * 255, c.blueComponent * 255)
        }
        func pixel(_ x: CGFloat, _ yUp: CGFloat) -> (CGFloat, CGFloat, CGFloat)? {
            // CARenderer buffer is bottom-up: y-up view coords index directly.
            guard let data = shot.dataProvider?.data as Data?,
                  x >= 0, yUp >= 0, Int(x) < shot.width, Int(yUp) < shot.height else { return nil }
            let i = Int(yUp) * shot.bytesPerRow + Int(x) * 4
            // premultipliedFirst little-endian (BGRA) or ARGB — probe both by
            // treating channel order via alphaInfo/byteOrder.
            let littleEndian = shot.bitmapInfo.contains(.byteOrder32Little)
            let b0 = CGFloat(data[i]), b1 = CGFloat(data[i + 1])
            let b2 = CGFloat(data[i + 2]), b3 = CGFloat(data[i + 3])
            return littleEndian ? (b2, b1, b0) : (b1, b2, b3)  // → (r,g,b)
        }
        func close(_ a: (CGFloat, CGFloat, CGFloat), _ b: (CGFloat, CGFloat, CGFloat), tol: CGFloat) -> Bool {
            abs(a.0 - b.0) <= tol && abs(a.1 - b.1) <= tol && abs(a.2 - b.2) <= tol
        }
        let panelColor = srgb(EditorThemeKit.panel)
        let windowColor = srgb(EditorThemeKit.windowBackground)
        let midY = previewRect.midY
        // Sample every bar the letterbox leaves (>=4pt wide), on all four sides.
        var samples: [(String, CGFloat, CGFloat)] = []
        if previewRect.minX - cardRect.minX >= 4 {
            samples.append(("left", (cardRect.minX + previewRect.minX) / 2, midY))
        }
        if cardRect.maxX - previewRect.maxX >= 4 {
            samples.append(("right", (previewRect.maxX + cardRect.maxX) / 2, midY))
        }
        if previewRect.minY - cardRect.minY >= 4 {
            samples.append(("bottom", previewRect.midX, (cardRect.minY + previewRect.minY) / 2))
        }
        if cardRect.maxY - previewRect.maxY >= 4 {
            samples.append(("top", previewRect.midX, (previewRect.maxY + cardRect.maxY) / 2))
        }
        var flushPass = true
        var detail = samples.isEmpty ? "no letterbox bars (canvas fills card)" : ""
        for (side, x, y) in samples {
            guard let got = pixel(x, y) else { flushPass = false; detail += "\(side)=unsampled "; continue }
            let isPanel = close(got, panelColor, tol: 8)
            let isMoat = close(got, windowColor, tol: 4) && !close(panelColor, windowColor, tol: 4)
            if !isPanel || isMoat { flushPass = false }
            detail += String(format: "%@=(%.0f,%.0f,%.0f)%@ ", side, got.0, got.1, got.2, isPanel ? "" : "≠panel")
        }
        print("BEHAVIOUR \(flushPass ? "PASS" : "FAIL") canvas-flush — bars read as panel surface: \(detail)panel=(\(Int(panelColor.0)),\(Int(panelColor.1)),\(Int(panelColor.2)))")
    }

    private static func settle(_ seconds: Double) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            try? await Task.sleep(for: .milliseconds(50))
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private static func findSubview<T: NSView>(ofType type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        for sub in root.subviews {
            if let found = findSubview(ofType: type, in: sub) { return found }
        }
        return nil
    }

    private static func makeProject(videoURL: URL, name: String) -> Project {
        let project = Project(name: name, videoURL: videoURL, duration: 4.0)
        project.trimStart = 0
        project.trimEnd = 4.0
        project.settings.muteRecordedAudio = true
        project.zoomRegions = [ZoomRegion(startTime: 0.5, endTime: 1.5)]
        project.speedRegions = [VideoSpeedRegion(startTime: 2.0, endTime: 3.0, speed: 2.0)]
        var annotation = Annotation(type: .text, startTime: 1.0, endTime: 2.5)
        annotation.text = "Probe label"
        project.annotations = [annotation]
        return project
    }

    /// Container mirroring EditorWindowContentViewController's editor
    /// topology exactly: the shell's in-content top bar pinned at 52 pt with
    /// the shell below it. The probe previously made the shell the window
    /// content directly, which put it UNDER the transparent titlebar — the
    /// split items then resolved different safe-area insets than in the real
    /// app, and the inspector-vs-preview top misalignment never reproduced
    /// (CLAUDE.md §3, wrong topology).
    private final class ProbeContentViewController: NSViewController {
        let shell: EditorShellViewController
        init(shell: EditorShellViewController) {
            self.shell = shell
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func loadView() {
            let root = NSView()
            root.wantsLayer = true
            view = root
            addChild(shell)
            shell.view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(shell.view)
            let bar = shell.topBarView
            bar.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(bar)
            NSLayoutConstraint.activate([
                bar.topAnchor.constraint(equalTo: root.topAnchor),
                bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                bar.heightAnchor.constraint(equalToConstant: 52),
                shell.view.topAnchor.constraint(equalTo: bar.bottomAnchor),
                shell.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                shell.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                shell.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
        }
    }

    /// Window configured exactly like EditorWindowController's real editor
    /// window — same styleMask, transparent titlebar, hidden title. Any config
    /// this probe skips is a topology the checks silently stop covering.
    private static func makeWindow(content: NSViewController, title: String, x: CGFloat) -> NSWindow {
        let window = NSWindow(contentViewController: content)
        window.styleMask.insert(.fullSizeContentView)
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = title
        window.isReleasedWhenClosed = false
        // `--light` renders the probe in the light theme (CCTheme is flipped
        // in run()); default stays the dark fixture the goldens froze.
        let light = CommandLine.arguments.contains("--light")
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        window.setContentSize(windowSize)
        // Park the probe windows off the visible desktop — the real app must
        // never be covered by them.
        window.setFrameOrigin(NSPoint(x: -20_000 + x, y: 200))
        window.orderFrontRegardless()
        window.contentView?.superview?.wantsLayer = true
        return window
    }

    // MARK: - Reporting

    private static func report(label: String, window: NSWindow) {
        guard let content = window.contentView else { return }
        print("\(label) contentView=\(fmt(content.frame)) safeInsets=\(content.safeAreaInsets)")
        if let toolbar = window.toolbar {
            print("\(label) toolbar items=\(toolbar.items.map(\.itemIdentifier.rawValue))")
        } else {
            print("\(label) toolbar none")
        }
        var found: [String: CGRect] = [:]
        walk(content) { view in
            let name = String(describing: type(of: view))
            switch name {
            case "PreviewCompositorView":
                found["preview"] = view.convert(view.bounds, to: content)
                // The flip context the SHIPPING shell resolves for the
                // compositor. `--preview-parity` must host it the same way or
                // it is testing a different view than the app renders
                // (CLAUDE.md §3, wrong topology).
                print("\(label) preview-flip superviewFlipped=\(view.superview?.isFlipped ?? false) geometryFlipped=\(view.layer?.isGeometryFlipped ?? false) contentsFlipped=\(view.layer?.contentsAreFlipped() ?? false)")
            case "InspectorColumnAppKit":
                found["inspector"] = view.convert(view.bounds, to: content)
            case "TimelineCanvasView":
                found["timelineCanvas"] = view.convert(view.bounds, to: content)
            case "TimelineRootView":
                found["timelinePanel"] = view.convert(view.bounds, to: content)
                // The panel's intrinsic height is what the preview card's height
                // is derived FROM (the card has no height constraint of its own),
                // so a wrong value silently collapses the whole stage. 42 toolbar
                // + 10 + 296 canvas + 8.
                print("\(label) timeline-intrinsic=\(view.intrinsicContentSize.height) resolved=\(view.frame.height)")
            case "PreviewZoomPill":
                found["zoomPill"] = view.convert(view.bounds, to: content)
            default:
                break
            }
        }
        // Card top alignment — the user-visible regression this probe missed
        // under the old bare-shell topology: the preview card and the
        // inspector card must start at the same window Y.
        let stageCard = (findSubview(ofType: ZoomScrollView.self, in: content))?.superview
        let inspectorPanel = (findSubview(ofType: InspectorColumnAppKit.self, in: content))?.superview
        if let stageCard, let inspectorPanel {
            let stageTop = stageCard.convert(stageCard.bounds, to: content).maxY
            let inspectorTop = inspectorPanel.convert(inspectorPanel.bounds, to: content).maxY
            let pass = abs(stageTop - inspectorTop) < 0.5
            print(String(
                format: "BEHAVIOUR %@ card-top-alignment — previewCardTop=%.1f inspectorCardTop=%.1f",
                pass ? "PASS" : "FAIL", stageTop, inspectorTop
            ))
        } else {
            print("BEHAVIOUR FAIL card-top-alignment — cards not found")
        }
        for key in ["preview", "inspector", "timelineCanvas", "zoomPill"] {
            if let rect = found[key] {
                print("\(label) \(key)=\(fmt(rect))")
            } else {
                print("\(label) \(key)=MISSING")
            }
        }
    }

    private static func fmt(_ r: CGRect) -> String {
        String(
            format: "(%.1f, %.1f, %.1f×%.1f)",
            r.origin.x, r.origin.y, r.size.width, r.size.height
        )
    }

    private static func walk(_ view: NSView, _ body: (NSView) -> Void) {
        body(view)
        for sub in view.subviews { walk(sub, body) }
    }

    // MARK: - Capture

    /// Content-view capture. The window's theme frame (which owns the
    /// toolbar) has no populated layer tree off-screen, so the top bar is
    /// verified separately through the toolbar item report; the pixels here
    /// are the stage / inspector / timeline arrangement.
    private static func capture(window: NSWindow) -> CGImage? {
        guard let content = window.contentView else { return nil }
        content.wantsLayer = true
        guard let layer = content.layer else { return nil }
        return CARendererSnapshot.render(layer: layer, size: content.bounds.size, scale: 1)
    }

    private static func write(_ image: CGImage?, to url: URL, label: String) {
        guard let image = image.flatMap(flipVertically) else {
            print("SHELLSHOT \(label) capture FAILED")
            return
        }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("SHELLSHOT \(label) \(url.path) \(image.width)×\(image.height)")
    }

    /// Draw-based capture of the window's titlebar/toolbar strip. `cacheDisplay`
    /// works off-screen for AppKit-drawn chrome, where CARenderer sees an empty
    /// tree.
    private static func titlebar(of window: NSWindow) -> NSImage? {
        guard let frameView = window.contentView?.superview else { return nil }
        guard let container = findView(in: frameView, named: "NSTitlebarContainerView") else { return nil }
        container.displayIfNeeded()
        guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else { return nil }
        // cacheDisplay redraws outside the window's appearance context, which
        // would hand back a LIGHT toolbar for a dark window.
        container.effectiveAppearance.performAsCurrentDrawingAppearance {
            container.cacheDisplay(in: container.bounds, to: rep)
        }
        let image = NSImage(size: container.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    private static func findView(in root: NSView, named: String) -> NSView? {
        if String(describing: type(of: root)) == named { return root }
        for sub in root.subviews {
            if let hit = findView(in: sub, named: named) { return hit }
        }
        return nil
    }

    private static func writeRaw(_ image: NSImage?, to url: URL, label: String) {
        guard let image,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("SHELLSHOT \(label) capture FAILED")
            return
        }
        try? png.write(to: url)
        print("SHELLSHOT \(label) \(url.path) \(Int(image.size.width))×\(Int(image.size.height))")
    }

    /// The parts of the port a screenshot cannot cover: the inspector
    /// show/hide, the keyboard focus target, and the close→reopen player
    /// lifecycle (the editor window is ordered out, not released).
    private static func behaviourChecks(shell: EditorShellViewController, window: NSWindow) async {
        func settle(_ turns: Int = 6) async {
            for _ in 0..<turns {
                try? await Task.sleep(for: .milliseconds(120))
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
        }
        func check(_ name: String, _ pass: Bool, _ detail: String) {
            print("BEHAVIOUR \(pass ? "PASS" : "FAIL") \(name) — \(detail)")
        }

        // 1. Inspector collapse / restore — the toggle must hide the WHOLE
        //    sidebar (column + icon rail), hand the space to the stage, and
        //    surface the slim reveal tab at the window's right edge; the
        //    tab's click must bring the sidebar back.
        let priorInspectorDefault = UserDefaults.standard
            .object(forKey: EditorShellViewController.inspectorVisibleDefaultsKey)
        let openWidth = shell.inspectorItem.viewController.view.frame.width
        let stageOpenWidth = shell.splitViewItems[0].viewController.view.frame.width
        shell.selection.showInspector = false
        await settle()
        let collapsed = shell.inspectorItem.isCollapsed
        let stageHiddenWidth = shell.splitViewItems[0].viewController.view.frame.width
        let tabShown = shell.revealTab?.isHidden == false
        check("inspector-collapse", collapsed, "isCollapsed=\(collapsed) after showInspector=false")
        check(
            "inspector-hide-stage-expands",
            stageHiddenWidth > stageOpenWidth + 300,
            "stage width \(stageOpenWidth)→\(stageHiddenWidth) with sidebar hidden"
        )
        check("inspector-reveal-tab-shown", tabShown, "revealTab.isHidden=\(String(describing: shell.revealTab?.isHidden))")
        // Click the reveal tab (a real mouseDown, not the state setter).
        if let tab = shell.revealTab,
           let down = NSEvent.mouseEvent(
               with: .leftMouseDown,
               location: tab.convert(NSPoint(x: 9, y: 32), to: nil),
               modifierFlags: [], timestamp: 0,
               windowNumber: window.windowNumber, context: nil,
               eventNumber: 0, clickCount: 1, pressure: 1) {
            tab.mouseDown(with: down)
        }
        await settle()
        let restored = !shell.inspectorItem.isCollapsed
        let restoredWidth = shell.inspectorItem.viewController.view.frame.width
        let tabHidden = shell.revealTab?.isHidden == true
        check(
            "inspector-restore",
            restored && abs(restoredWidth - openWidth) < 1,
            "isCollapsed=\(shell.inspectorItem.isCollapsed) width \(openWidth)→\(restoredWidth) (via reveal-tab click)"
        )
        check("inspector-reveal-tab-hidden", tabHidden, "revealTab hidden again once sidebar is back")
        // Menu path (⌥⌘I twin): the responder-chain action must flip state.
        shell.toggleInspectorFromMenu(nil)
        await settle()
        let menuCollapsed = shell.inspectorItem.isCollapsed
        shell.toggleInspectorFromMenu(nil)
        await settle()
        check(
            "inspector-menu-toggle",
            menuCollapsed && !shell.inspectorItem.isCollapsed,
            "toggleInspectorFromMenu collapsed=\(menuCollapsed) then restored"
        )
        // The toggles above wrote session persistence — put the user's actual
        // preference back so the probe never restyles their editor.
        if let prior = priorInspectorDefault as? Bool {
            UserDefaults.standard.set(prior, forKey: EditorShellViewController.inspectorVisibleDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: EditorShellViewController.inspectorVisibleDefaultsKey)
        }

        // 2. Keyboard focus target — must be the timeline's root view, which is
        //    the single first responder for the whole panel.
        //
        //    This assertion INVERTED when the timeline stopped being hosted: it
        //    used to require an NSHostingView, because SwiftUI's focus chain
        //    lived inside one and focusing the plain container starved it. Now
        //    an NSHosting* focus target would mean a hosting view had crept back
        //    in, so it is asserted against.
        let focus = shell.focusTarget
        let focusName = focus.map { String(describing: type(of: $0)) } ?? "nil"
        check("focus-target", focus is TimelineRootView, "focusTarget=\(focusName)")
        check("focus-not-hosted", !focusName.contains("NSHosting"), "focusTarget=\(focusName)")
        if let focus {
            let accepted = window.makeFirstResponder(focus)
            check("focus-accepts", accepted, "makeFirstResponder=\(accepted)")
        }

        // 3. Close → reopen must rebuild the player.
        let hadPlayer = shell.playback.player != nil
        shell.viewWillDisappear()
        let tornDown = shell.playback.player == nil
        shell.viewDidAppear()
        await settle(20)
        let rebuilt = shell.playback.player != nil
        check("player-setup", hadPlayer, "player present after first appear")
        check("player-teardown", tornDown, "player released on disappear")
        check("player-reopen", rebuilt, "player rebuilt on re-appear")

        // 4. Autosave: the AppKit twin of AutoSaveModifier must stay quiet on
        //    prime and fire on an edit (a store-backed instance would write to
        //    the user's library, so the sink is injected).
        let autosaveProject = Project(name: "autosave-probe", duration: 1)
        var dirtyCount = 0
        let observer = EditorAutoSaveObserver(project: autosaveProject) { dirtyCount += 1 }
        await settle(3)
        let primedQuiet = dirtyCount == 0
        autosaveProject.settings.cornerRadius += 4
        await settle(3)
        let afterVisual = dirtyCount
        autosaveProject.annotations.append(Annotation(type: .text, startTime: 0, endTime: 1))
        await settle(3)
        let afterEdit = dirtyCount
        check("autosave-prime-quiet", primedQuiet, "0 saves on the priming pass")
        check("autosave-visual", afterVisual >= 1, "cornerRadius change → \(afterVisual) save(s)")
        check("autosave-edits", afterEdit > afterVisual, "annotation append → \(afterVisual)→\(afterEdit) save(s)")
        // The signature is now the full Codable encoding — close/quit saves
        // are dirty-gated (saveIfDirty), so a field outside the old legacy
        // signature (shadowOpacity) MUST still dirty the project, and a
        // runtime-only @ObservationIgnored field must not.
        autosaveProject.settings.shadowOpacity += 0.1
        await settle(3)
        let afterShadow = dirtyCount
        autosaveProject.previewCanvasSize = CGSize(width: 123, height: 456)
        autosaveProject.hasUnsavedChanges = true
        await settle(3)
        let afterRuntime = dirtyCount
        check("autosave-full-coverage", afterShadow > afterEdit, "shadowOpacity change → \(afterEdit)→\(afterShadow) save(s)")
        check("autosave-runtime-quiet", afterRuntime == afterShadow, "runtime-only fields → no save (\(afterShadow)→\(afterRuntime))")
        _ = observer
    }

    /// CARenderer hands back a bottom-up buffer; flip so the PNGs read the
    /// way the window does.
    private static func flipVertically(_ image: CGImage) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(image.height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

}
