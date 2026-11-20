import AppKit

/// Debug probe for the AppKit inspector column.
///
///   CaptureCat --inspector-probe [annotate]
///
/// Builds the REAL hosting chain — `EditorInspectorViewController` inside a
/// split view, exactly how `EditorShellViewController` hosts it — rather than a
/// bare pre-sized window. A previous version of this probe used a standalone
/// window and masked an in-app layout collapse; the topology has to match.
///
/// Prints the resolved frames of the scroll view, document view, and every
/// pane, and saves a CARenderer capture beside the report. DEBUG tooling.
///
/// The old `pane-compare` mode rendered SwiftUI panes beside their AppKit twins
/// for the conversion parity check. It was removed with the SwiftUI panes —
/// there is nothing left to compare against.
@MainActor
enum InspectorProbeHarness {

    static func run() -> Never {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let project = Project(name: "probe")
        let selection = EditorShellSelection()

        // `--inspector-probe effects` — open the Effects tab (grouped effect
        // boxes render in their global, nothing-selected mode).
        if CommandLine.arguments.contains("effects") {
            selection.inspectorTab = .effects
        }

        // `--inspector-probe custom-placement` — seed a freeform card position
        // so the Background pane's Placement row must show "Custom", the
        // Reset button, and the card at the actual spot.
        if CommandLine.arguments.contains("custom-placement") {
            project.settings.videoCustomX = 0.82
            project.settings.videoCustomY = 0.25
        }

        // `--inspector-probe camera` — a project with a recorded camera and the
        // whole-video Cutout look, on the Camera tab, so the camera details
        // (Background chips included) render with a selection.
        if CommandLine.arguments.contains("camera") {
            project.cameraVideoURL = URL(fileURLWithPath: "/tmp/capturecat-probe-camera.mov")
            project.settings.showCamera = true
            project.settings.cameraShape = .squircle
            project.settings.cameraLook = .cutout
            selection.inspectorTab = .camera
        }

        // `--inspector-probe camera-popout` — the Pop-out card look with the
        // camera fill and an aurora border, so the Cutout & Pop-out section
        // (docs/camera-cutout.md §12.8) renders its card + border rows.
        if CommandLine.arguments.contains("camera-popout") {
            project.cameraVideoURL = URL(fileURLWithPath: "/tmp/capturecat-probe-camera.mov")
            project.settings.showCamera = true
            project.settings.cameraShape = .roundedRect
            project.settings.cameraLook = .popOut
            project.settings.cameraCardFill = .camera
            project.settings.cameraBackgroundBlur = 0.4
            project.settings.cameraCardBorder = .aurora
            project.settings.cameraPortraitStack = true
            selection.inspectorTab = .camera
        }

        // `--inspector-probe annotate` — seed a selected text annotation and
        // open the Annotate tab so the native pane's editor state renders.
        if CommandLine.arguments.contains("annotate") {
            var annotation = Annotation(type: .text, startTime: 0, endTime: 3)
            annotation.text = "Probe label"
            project.annotations = [annotation]
            selection.inspectorTab = .annotations
            selection.selectedAnnotationID = annotation.id
        }

        let inspector = EditorInspectorViewController(
            project: project,
            playback: EditorPlaybackController(appState: nil),
            selection: selection
        )

        // Stage stand-in + inspector in a split, mirroring the shell so the
        // column resolves its width against a real sibling.
        let stage = NSViewController()
        stage.view = NSView()
        stage.view.wantsLayer = true
        stage.view.layer?.backgroundColor = NSColor.black.cgColor

        let split = NSSplitViewController()
        split.addSplitViewItem(NSSplitViewItem(viewController: stage))
        let inspectorItem = NSSplitViewItem(viewController: inspector)
        inspectorItem.minimumThickness = 340
        inspectorItem.maximumThickness = 480
        split.addSplitViewItem(inspectorItem)

        let window = NSWindow(contentViewController: split)
        window.setContentSize(NSSize(width: 900, height: 640))
        window.orderFrontRegardless()

        // Two settles: constraint resolution then the observation re-arm.
        var reports = 0
        Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { timer in
            MainActor.assumeIsolated {
                reports += 1
                report(root: split.view)
                guard reports >= 2 else { return }
                guard CCLocalizationAudit.isEnabled else { exit(0) }
                // `--l10n-audit <dir>`: every tab of the real inspector, top
                // and scrolled to the end, in this launch's language.
                timer.invalidate()
                Task { @MainActor in
                    let suffix = CommandLine.arguments.contains("camera") ? "-camera"
                        : CommandLine.arguments.contains("annotate") ? "-annotate" : ""
                    for tab in InspectorTab.allCases {
                        selection.inspectorTab = tab
                        try? await Task.sleep(for: .milliseconds(450))
                        window.contentView?.layoutSubtreeIfNeeded()
                        CCLocalizationAudit.capture("inspector\(suffix)-\(tab.rawValue.lowercased())", window: window)
                        if let column = findView(ofType: InspectorColumnAppKit.self, in: split.view),
                           let scroll = findView(ofType: NSScrollView.self, in: column),
                           let doc = scroll.documentView, doc.frame.height > scroll.contentSize.height + 1 {
                            scroll.contentView.scroll(to: NSPoint(x: 0, y: doc.isFlipped ? doc.frame.height - scroll.contentSize.height : 0))
                            scroll.reflectScrolledClipView(scroll.contentView)
                            try? await Task.sleep(for: .milliseconds(150))
                            CCLocalizationAudit.capture("inspector\(suffix)-\(tab.rawValue.lowercased())-end", window: window)
                        }
                    }
                    // Every annotation type and every selectable region, so
                    // each type's own inspector section is read too.
                    @MainActor func audit(_ name: String) async {
                        try? await Task.sleep(for: .milliseconds(400))
                        window.contentView?.layoutSubtreeIfNeeded()
                        CCLocalizationAudit.capture("inspector\(suffix)-\(name)", window: window)
                        if let column = findView(ofType: InspectorColumnAppKit.self, in: split.view),
                           let scroll = findView(ofType: NSScrollView.self, in: column),
                           let doc = scroll.documentView, doc.frame.height > scroll.contentSize.height + 1 {
                            scroll.contentView.scroll(to: NSPoint(x: 0, y: doc.isFlipped ? doc.frame.height - scroll.contentSize.height : 0))
                            scroll.reflectScrolledClipView(scroll.contentView)
                            try? await Task.sleep(for: .milliseconds(150))
                            CCLocalizationAudit.capture("inspector\(suffix)-\(name)-end", window: window)
                        }
                    }
                    guard suffix.isEmpty else { exit(0) }
                    @MainActor func clear() {
                        selection.selectedAnnotationID = nil; selection.selectedZoomID = nil
                        selection.selectedTiltID = nil; selection.selectedBlurID = nil
                        selection.selectedHighlightID = nil; selection.selectedDepthFocusID = nil
                    }
                    for type in AnnotationType.allCases {
                        clear()
                        var annotation = Annotation(type: type, startTime: 0, endTime: 3)
                        if type == .text || type == .callout { annotation.text = "Probe label" }
                        project.annotations = [annotation]
                        selection.inspectorTab = .annotations
                        selection.selectedAnnotationID = annotation.id
                        await audit("annotation-\(type.rawValue)")
                    }
                    project.annotations = []
                    let zoom = ZoomRegion(startTime: 0.5, endTime: 2)
                    let tilt = TiltRegion(startTime: 2.2, endTime: 3)
                    let blur = BlurRegion(startTime: 0.5, endTime: 2, label: "Blur")  // l10n: verbatim — stored default
                    let highlight = HighlightRegion(startTime: 2.2, endTime: 3, label: "Highlight")  // l10n: verbatim — stored default
                    let focus = FocusRegion(startTime: 3.2, endTime: 3.8)
                    project.zoomRegions = [zoom]; project.tiltRegions = [tilt]
                    project.blurRegions = [blur]; project.highlightRegions = [highlight]
                    project.focusRegions = [focus]
                    let regions: [(String, @MainActor () -> Void)] = [
                        ("zoom", { selection.selectedZoomID = zoom.id }),
                        ("tilt", { selection.selectedTiltID = tilt.id }),
                        ("blur", { selection.selectedBlurID = blur.id }),
                        ("highlight", { selection.selectedHighlightID = highlight.id }),
                        ("depth-focus", { selection.selectedDepthFocusID = focus.id }),
                        ("slide", { selection.introSelected = true }),
                        ("curtain", { selection.curtainSelected = true }),
                    ]
                    for (name, select) in regions {
                        clear(); selection.introSelected = false; selection.curtainSelected = false
                        selection.inspectorTab = .effects
                        select()
                        await audit("region-\(name)")
                    }
                    exit(0)
                }
            }
        }
        app.run()
        exit(0)
    }

    private static func report(root: NSView) {
        guard let column = findView(ofType: InspectorColumnAppKit.self, in: root) else {
            print("PROBE no InspectorColumnAppKit in tree")
            return
        }
        print("PROBE column frame=\(column.frame)")
        if let scroll = findView(ofType: NSScrollView.self, in: column) {
            print("PROBE scroll frame=\(scroll.frame) contentSize=\(scroll.contentSize)")
            // `scroll=<points>` — capture further down a tall pane (the
            // Camera pane's Cutout & Pop-out section sits below the fold).
            if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("scroll=") }),
               let offset = Double(arg.dropFirst("scroll=".count)) {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
                scroll.reflectScrolledClipView(scroll.contentView)
                scroll.layoutSubtreeIfNeeded()
            }
            if let doc = scroll.documentView {
                print("PROBE documentView frame=\(doc.frame) tamic=\(doc.translatesAutoresizingMaskIntoConstraints)")
                for sub in doc.subviews {
                    print("PROBE pane \(type(of: sub)) frame=\(sub.frame) hidden=\(sub.isHidden)")
                }
            } else {
                print("PROBE documentView is nil")
            }
        }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("capturecat-inspector-probe.png")
        if let layer = root.layer,
           let img = CARendererSnapshot.render(layer: layer, size: root.bounds.size, scale: 1) {
            let rep = NSBitmapImageRep(cgImage: img)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir)
            print("PROBE capture \(dir.path)")
        }
    }

    private static func findView<T: NSView>(ofType type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        for sub in root.subviews {
            if let found = findView(ofType: type, in: sub) { return found }
        }
        return nil
    }
}
