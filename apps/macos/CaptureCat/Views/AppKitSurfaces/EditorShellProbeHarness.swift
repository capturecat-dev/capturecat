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
        let paneShotsMode = CommandLine.arguments.contains("--pane-shots")
        if paneShotsMode {
            // The Camera pane only builds its detail sections when the
            // project HAS a camera track (read once at column init), so the
            // pane-shot fixture carries one — the fixture clip stands in.
            nativeProject.cameraVideoURL = videoURL
            nativeProject.settings.showCamera = true
        }

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
        // `--l10n-audit`: the whole frame view, so the in-content top bar in
        // the titlebar is measured with the shell.
        if let frameView = nativeWindow.contentView?.superview {
            CCLocalizationAudit.capture("editor-shell", view: frameView)
            // The state people check translations in: a Text annotation
            // selected — its inspector section, the on-canvas toolbar pill,
            // the rail and the lanes together. Undone afterwards so the gate's
            // own checks see the fixture unchanged.
            if CCLocalizationAudit.isEnabled {
                var text = Annotation(type: .text, startTime: 0.5, endTime: 3)
                text.text = "Probe label"
                let before = nativeProject.annotations
                nativeProject.annotations.append(text)
                native.playback.currentTime = 1.5
                native.selection.inspectorTab = .annotations
                native.selection.selectedAnnotationID = text.id
                await settle(1.0)
                CCLocalizationAudit.capture("editor-shell-text-annotation", view: frameView)
                if let dir = CCLocalizationAudit.directory {
                    write(capture(window: nativeWindow), to: dir.appendingPathComponent("editor-shell-text-annotation-ca.png"), label: "L10N")
                }
                native.selection.selectedAnnotationID = nil
                native.selection.inspectorTab = .background
                nativeProject.annotations = before
                await settle(0.6)
            }
        }

        let nativeShot = capture(window: nativeWindow)
        write(nativeShot, to: outDir.appendingPathComponent("shell-native.png"), label: "NATIVE")

        if paneShotsMode {
            await paneShots(shell: native, project: nativeProject, window: nativeWindow, outDir: outDir)
            print("SHELLSHOT outDir \(outDir.path)")
            return
        }

        framingChecks(shot: nativeShot, window: nativeWindow)

        // Top bar: CARenderer sees nothing in the titlebar (it is not layer
        // hosted), so the toolbar strip is captured through `cacheDisplay`.
        writeRaw(titlebar(of: nativeWindow), to: outDir.appendingPathComponent("toolbar-native.png"), label: "TOOLBAR-NATIVE")

        // Behaviours a screenshot cannot show.
        await behaviourChecks(shell: native, window: nativeWindow)

        // Timeline lane accordion: motion sequence + label lockstep, in the
        // real shell (the label column and panel sizing are the app's own).
        await laneAccordionProbe(shell: native, project: nativeProject, window: nativeWindow, outDir: outDir)

        // ── In-place editor probe ─────────────────────────────────────────
        // The editor must REPLACE the drawn label (Chrome.editingID), sit on
        // the exact label rect, and the drawn twin must not peek out anywhere.
        await inlineEditProbe(shell: native, project: nativeProject,
                              window: nativeWindow, outDir: outDir)

        await annotateScrollProbe(shell: native, project: nativeProject)

        print("SHELLSHOT outDir \(outDir.path)")
    }

    /// Timeline lane accordion: the overlay lanes (EFFECTS / FOCUS / ANNOTATE)
    /// rest as strips; hovering one opens it (growing down, pushing the lanes
    /// below), moving off springs it shut. Probed in the REAL shell, sampled
    /// as a SEQUENCE (a settled frame can't tell a spring from a snap — §3),
    /// with the label column measured against the canvas lanes every sample.
    /// Defect injections that must FAIL: `--inject accordion-snap` (no
    /// motion) and `--inject accordion-labels` (label column frozen).
    private static func laneAccordionProbe(
        shell: EditorShellViewController, project: Project, window: NSWindow, outDir: URL
    ) async {
        typealias M = TimelineCanvasMetrics
        let args = CommandLine.arguments
        var failures = 0
        func check(_ name: String, _ pass: Bool, _ detail: String) {
            if !pass { failures += 1 }
            print("ACCORDION \(pass ? "PASS" : "FAIL") \(name) — \(detail)")
            if !pass, let canvas = findSubview(ofType: TimelineCanvasView.self, in: shell.view) {
                print("ACCORDION   state: \(canvas.probeHoverState) open=\(canvas.openOverlayLane)")
            }
        }
        guard let canvas = findSubview(ofType: TimelineCanvasView.self, in: shell.view),
              let panel = findSubview(ofType: TimelineRootView.self, in: shell.view),
              let content = window.contentView else {
            print("ACCORDION FAIL no timeline canvas in shell")
            return
        }
        let accordion = canvas.laneAccordion
        accordion.probeReduceMotion = false
        // The "parked off the desktop" window is clamped onto a real screen
        // on multi-display setups (it landed at x = -1920 on a left monitor),
        // so the user's cursor crossing it fed REAL mouseMoved / mouseExited
        // into the canvas between the synthetic ones — a flaky red. Detach
        // the canvas's tracking areas for the probe; only synthetic events
        // reach it (re-detached every step: AppKit re-adds them on any
        // visible-rect change). Restored at the end.
        func detachTracking() { canvas.trackingAreas.forEach(canvas.removeTrackingArea) }
        detachTracking()
        defer { canvas.updateTrackingAreas() }
        if args.contains("accordion-snap") { accordion.probeForceSnap = true }
        if args.contains("accordion-labels") { canvas.onLaneLayoutChange = nil }

        func send(_ type: NSEvent.EventType, at point: CGPoint) {
            detachTracking()
            let windowPoint = canvas.convert(point, to: nil)
            let event: NSEvent?
            if type == .mouseExited {
                event = NSEvent.enterExitEvent(
                    with: .mouseExited, location: windowPoint, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, trackingNumber: 0, userData: nil)
            } else {
                event = NSEvent.mouseEvent(
                    with: type, location: windowPoint, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 0, pressure: 0)
            }
            guard let event else { return }
            if type == .mouseExited { canvas.mouseExited(with: event) } else { canvas.mouseMoved(with: event) }
        }
        func centre(of lane: TimelineOverlayLane) -> CGPoint {
            let layout = canvas.laneLayout
            return CGPoint(x: canvas.visibleRect.midX,
                           y: layout.laneY(lane) + layout.laneHeight(lane) / 2)
        }
        /// Label row vs canvas lane, in window space: worst |Δtop| / |Δheight|.
        func labelDrift() -> CGFloat {
            let layout = canvas.laneLayout
            var worst: CGFloat = 0
            for (lane, name) in [(TimelineOverlayLane.effects, "EFFECTS"), (.focus, "FOCUS"), (.annotate, "ANNOTATE")] {
                guard let label = findLabel(name, in: panel), let row = label.superview else { return .infinity }
                let rowRect = row.convert(row.bounds, to: nil)
                let laneRect = canvas.convert(layout.laneRect(lane, width: canvas.bounds.width), to: nil)
                worst = max(worst, abs(rowRect.maxY - laneRect.maxY), abs(rowRect.height - laneRect.height))
            }
            return worst
        }
        struct Sample {
            var t: Double; var open: [CGFloat]; var band: CGFloat; var drift: CGFloat
            var bottom: CGFloat; var focusTop: CGFloat; var effectsHeight: CGFloat
        }
        /// Samples the accordion for `seconds` after an event, ~every 12 ms.
        func record(_ seconds: Double) async -> [Sample] {
            var samples: [Sample] = []
            let began = CACurrentMediaTime()
            while CACurrentMediaTime() - began < seconds {
                try? await Task.sleep(for: .milliseconds(12))
                detachTracking()
                content.layoutSubtreeIfNeeded()
                let layout = canvas.laneLayout
                samples.append(Sample(
                    t: CACurrentMediaTime() - began, open: layout.openness,
                    band: layout.tracksBottom - M.effectsLaneY, drift: labelDrift(),
                    bottom: layout.tracksBottom, focusTop: layout.laneY(.focus),
                    effectsHeight: layout.laneHeight(.effects)))
            }
            return samples
        }
        func fmt(_ v: CGFloat) -> String { String(format: "%.3f", v) }
        func spread(_ values: [CGFloat]) -> CGFloat { (values.max() ?? 0) - (values.min() ?? 0) }
        func heights(_ layout: TimelineLaneLayout) -> String {
            "E/F/A = \(layout.laneHeight(.effects))/\(layout.laneHeight(.focus))/\(layout.laneHeight(.annotate))"
        }
        let strip = TimelineLaneLayout.compactRowHeight
        func allStrips(_ layout: TimelineLaneLayout) -> Bool {
            TimelineOverlayLane.allCases.allSatisfy { abs(layout.laneHeight($0) - strip) < 0.5 }
        }

        // ── Rest: cursor off the timeline → EVERY overlay lane is a strip.
        shell.selection.selectedAnnotationID = nil
        shell.selection.selectedZoomID = nil
        send(.mouseExited, at: .zero)
        await settle(0.8)
        content.layoutSubtreeIfNeeded()
        let rest = canvas.laneLayout
        check("rest-all-strips", canvas.openOverlayLane == nil && allStrips(rest),
              "open=\(String(describing: canvas.openOverlayLane)) \(heights(rest))")
        check("labels-rest", labelDrift() < 0.75, "drift \(fmt(labelDrift()))pt")
        // The spare room an opening lane grows into must not itself open one.
        let spareY = rest.tracksBottom + 8
        check("spare-room-inert", rest.hoverLane(atY: spareY) == nil,
              "y=\(spareY) below the strips → \(String(describing: rest.hoverLane(atY: spareY)))")
        let panelHeightBefore = panel.frame.height

        // ── Hover FOCUS: it grows DOWN on the growth bounce; only the lanes
        // below it move (the pushed edge), nothing above it shifts.
        send(.mouseMoved, at: centre(of: .focus))
        let opening = await record(0.65)
        let focusOpen = opening.map { $0.open[TimelineOverlayLane.focus.rawValue] }
        let midFlight = focusOpen.filter { $0 > 0.08 && $0 < 0.92 }
        check("open-midflight", midFlight.count >= 2,
              "\(midFlight.count) samples strictly between strip and open (\(focusOpen.prefix(8).map(fmt).joined(separator: " ")) …)")
        let peak = focusOpen.max() ?? 0
        check("open-bounce", peak > 1.02 && peak < 1.25, "peak openness \(fmt(peak)) (house bounce overshoots ~10%)")
        let pinned = max(spread(opening.map(\.focusTop)), spread(opening.map(\.effectsHeight)))
        check("pushed-edge-only", pinned < 0.5,
              "FOCUS top / EFFECTS height moved \(fmt(pinned))pt mid-flight (only the edge FOCUS pushes may move)")
        let worstDrift = opening.map(\.drift).max() ?? .infinity
        check("labels-midflight", worstDrift < 0.75, "label rows vs lanes worst drift \(fmt(worstDrift))pt across \(opening.count) samples")
        let deepest = opening.map(\.bottom).max() ?? 0
        check("fits-panel", deepest <= canvas.bounds.height,
              "lanes reach y=\(fmt(deepest)) incl. overshoot; canvas is \(canvas.bounds.height)pt (no clipping)")
        let opened = canvas.laneLayout
        check("open-settled",
              canvas.openOverlayLane == .focus
                && abs(opened.laneHeight(.focus) - M.trackHeight) < 0.5
                && abs(opened.laneHeight(.effects) - strip) < 0.5
                && abs(opened.laneHeight(.annotate) - strip) < 0.5,
              heights(opened))
        check("panel-fixed", abs(panel.frame.height - panelHeightBefore) < 0.5,
              "timeline panel \(panelHeightBefore) → \(panel.frame.height) (a hover must never re-lay out the stage)")

        // Crossing an inter-lane gap must not drop the hover (flicker).
        let gapYs = [opened.laneY(.focus) - M.trackSpacing / 2, opened.laneY(.annotate) - M.trackSpacing / 2]
        let gapLanes = gapYs.map { opened.hoverLane(atY: $0) }
        check("gap-continuity", gapLanes.allSatisfy { $0 != nil }, "gap hover lanes \(gapLanes)")

        // ── Lane to lane: FOCUS hands off to ANNOTATE — one gives exactly
        // what the other takes, so the band holds its height.
        send(.mouseMoved, at: centre(of: .annotate))
        let handoff = await record(0.65)
        let handoffSpread = spread(handoff.map(\.band))
        check("handoff-band-constant", handoffSpread < 0.5 && canvas.openOverlayLane == .annotate,
              "band varies \(fmt(handoffSpread))pt FOCUS→ANNOTATE; open=\(String(describing: canvas.openOverlayLane))")

        // ── Move off the canvas: ANNOTATE springs back to a strip.
        send(.mouseExited, at: .zero)
        let closing = await record(0.65)
        let annotateShut = closing.map { $0.open[TimelineOverlayLane.annotate.rawValue] }
        check("close-midflight", annotateShut.contains { $0 > 0.08 && $0 < 0.92 },
              "\(annotateShut.prefix(8).map(fmt).joined(separator: " ")) …")
        check("close-settled", canvas.openOverlayLane == nil && allStrips(canvas.laneLayout),
              "open=\(String(describing: canvas.openOverlayLane)) \(heights(canvas.laneLayout))")

        // ── Moving off WITHIN the canvas (onto VIDEO) also springs back.
        send(.mouseMoved, at: centre(of: .effects))
        await settle(0.6)
        let effectsOpened = canvas.openOverlayLane == .effects
        send(.mouseMoved, at: CGPoint(x: canvas.visibleRect.midX, y: M.videoLaneY + M.trackHeight / 2))
        await settle(0.6)
        check("move-off-to-video", effectsOpened && canvas.openOverlayLane == nil && allStrips(canvas.laneLayout),
              "effects opened=\(effectsOpened), after VIDEO hover open=\(String(describing: canvas.openOverlayLane))")

        // ── A selection does NOT hold a lane open: all strips by default.
        if let annotation = project.annotations.first {
            shell.selection.selectedAnnotationID = annotation.id
            await settle(0.8)
            let held = canvas.openOverlayLane
            shell.selection.selectedAnnotationID = nil
            await settle(0.3)
            check("selection-stays-strip", held == nil,
                  "selected annotation → open=\(String(describing: held))")
        }

        // ── Reduce Motion: a short glide, never an overshoot.
        accordion.probeReduceMotion = true
        send(.mouseMoved, at: centre(of: .focus))
        let reduced = await record(0.4)
        let reducedPeak = reduced.map { $0.open[TimelineOverlayLane.focus.rawValue] }.max() ?? 0
        check("reduce-motion", reducedPeak <= 1.0001 && canvas.openOverlayLane == .focus
                && abs(canvas.laneLayout.openness(.focus) - 1) < 0.001,
              "peak \(fmt(reducedPeak)), settled within 0.4s")
        accordion.probeReduceMotion = false
        send(.mouseExited, at: .zero)
        await settle(0.8)

        // ── Pictures (after every numeric check — a capture costs a frame
        // budget): rest, the opening sequence, settled, and closing.
        let frameRect: CGRect = {
            let r = panel.convert(panel.bounds, to: content)
            return CGRect(x: r.minX, y: content.bounds.height - r.maxY, width: r.width, height: r.height)
        }()
        func shoot(_ name: String) {
            content.layoutSubtreeIfNeeded()
            canvas.displayIfNeeded()
            guard let image = capture(window: window).flatMap(flipVertically),
                  let crop = image.cropping(to: frameRect) else {
                print("ACCORDION capture \(name) FAILED")
                return
            }
            let url = outDir.appendingPathComponent("accordion-\(name).png")
            try? NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:])?.write(to: url)
        }
        shoot("0-rest")
        // ANNOTATE holds the fixture's text block, so the picture shows a
        // real block growing out of its strip while the zoom block tucks.
        send(.mouseMoved, at: centre(of: .annotate))
        let shotStart = CACurrentMediaTime()
        for _ in 1...5 {
            // Always yield at least a frame: a capture costs ~100 ms, and a
            // loop that never returns to the run loop starves the 120 Hz
            // driver — every "mid-flight" shot would show the same instant.
            try? await Task.sleep(for: .milliseconds(16))
            shoot(String(format: "1-open-%03dms", Int((CACurrentMediaTime() - shotStart) * 1000)))
        }
        await settle(0.4)
        shoot("2-annotate-open")
        send(.mouseExited, at: .zero)
        try? await Task.sleep(for: .milliseconds(90))
        shoot("3-closing")
        await settle(0.6)
        shoot("4-back-to-rest")
        print("ACCORDION \(failures == 0 ? "ALL PASS" : "\(failures) FAILED") — shots in \(outDir.path)/accordion-*.png")
    }

    private static func findLabel(_ text: String, in root: NSView) -> NSTextField? {
        if let field = root as? NSTextField, field.stringValue == text { return field }
        for sub in root.subviews {
            if let hit = findLabel(text, in: sub) { return hit }
        }
        return nil
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

    // MARK: - Pane shots (web-editor parity references)

    /// `--pane-shots`: every inspector tab, plus the selection-specific
    /// sections (zoom / tilt block, highlight, blur, depth focus, each
    /// annotation type) and the "everything switched on" variants, captured
    /// inside the REAL shell topology. Each state writes
    /// `panes-<theme>/<state>.png` at the probe window size and
    /// `<state>-tall.png` with the window grown so the whole pane is on
    /// screen. The web editor's lab renders the same fixture states for a
    /// side-by-side diff. Deterministic: synthetic project, no user data.
    private static func paneShots(
        shell: EditorShellViewController, project: Project, window: NSWindow, outDir: URL
    ) async {
        let theme = CommandLine.arguments.contains("--light") ? "light" : "dark"
        let dir = outDir.appendingPathComponent("panes-\(theme)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sel = shell.selection
        let settings = project.settings

        // Fixture regions (ids are fresh; the web lab mirrors the VALUES).
        guard let zoom = project.zoomRegions.first,
              let textAnnotation = project.annotations.first else { return }
        let tilt = TiltRegion(startTime: zoom.startTime, endTime: zoom.endTime, pitch: 12, yaw: 0, roll: -3)
        let highlight = HighlightRegion(startTime: 2.6, endTime: 3.2)
        let blur = BlurRegion(startTime: 1.6, endTime: 2.4, style: .pixelate)
        let focus = FocusRegion(startTime: 0.2, endTime: 1.2)
        let arrow = Annotation(type: .arrow, startTime: 0.2, endTime: 0.9)
        let rect = Annotation(type: .rectangle, startTime: 2.6, endTime: 3.4)
        var drawing = Annotation(type: .drawing, startTime: 3.0, endTime: 3.8)
        drawing.drawingStrokes = [
            [CodablePoint(x: 0.2, y: 0.2), CodablePoint(x: 0.3, y: 0.3)],
            [CodablePoint(x: 0.5, y: 0.5), CodablePoint(x: 0.6, y: 0.4)],
        ]
        let tap = Annotation(type: .tap, startTime: 3.4, endTime: 3.9)
        project.highlightRegions = [highlight]
        project.blurRegions = [blur]
        project.focusRegions = [focus]
        project.annotations = [textAnnotation, arrow, rect, drawing, tap]
        await settle(0.4)

        func clear() {
            sel.selectedZoomID = nil
            sel.selectedTiltID = nil
            sel.selectedHighlightID = nil
            sel.selectedBlurID = nil
            sel.selectedDepthFocusID = nil
            sel.selectedAnnotationID = nil
            sel.introSelected = false
            sel.curtainSelected = false
        }
        struct State {
            let name: String
            let tab: InspectorTab
            let setup: @MainActor () -> Void
            let teardown: @MainActor () -> Void
        }
        func state(_ name: String, _ tab: InspectorTab,
                   setup: @escaping @MainActor () -> Void = {},
                   teardown: @escaping @MainActor () -> Void = {}) -> State {
            State(name: name, tab: tab, setup: setup, teardown: teardown)
        }
        let states: [State] = [
            state("background", .background),
            state("cursor", .cursor),
            state("cursor-all", .cursor, setup: {
                settings.autoHideCursor = true
                settings.smoothCursor = true
                settings.clickSoundEnabled = true
                settings.keySoundEnabled = true
            }, teardown: {
                settings.autoHideCursor = false
                settings.smoothCursor = false
                settings.clickSoundEnabled = false
                settings.keySoundEnabled = false
            }),
            state("camera", .camera),
            state("audio", .audio),
            state("effects", .effects),
            state("effects-all", .effects, setup: {
                settings.introSlideStyle = .bottom
                settings.curtainUnveilCorner = .topLeft
                settings.parallaxStrength = 0.4
                settings.motionBlur = true
            }, teardown: {
                settings.introSlideStyle = .off
                settings.curtainUnveilCorner = .off
                settings.parallaxStrength = 0
                settings.motionBlur = false
            }),
            state("effects-zoom", .effects, setup: { sel.selectedZoomID = zoom.id }),
            state("effects-tilt", .effects, setup: {
                project.tiltRegions = [tilt]
                sel.selectedZoomID = zoom.id
                sel.selectedTiltID = tilt.id
            }, teardown: { project.tiltRegions = [] }),
            state("effects-highlight", .effects, setup: { sel.selectedHighlightID = highlight.id }),
            state("effects-blur", .effects, setup: { sel.selectedBlurID = blur.id }),
            state("effects-focus", .effects, setup: { sel.selectedDepthFocusID = focus.id }),
            state("motion", .motion),
            state("subtitles", .subtitles),
            state("subtitles-on", .subtitles, setup: {
                settings.showSubtitles = true
                project.subtitles = [
                    SubtitleSegment(startTime: 0.2, endTime: 1.4, text: "Welcome to the probe"),
                    SubtitleSegment(startTime: 1.6, endTime: 3.1, text: "Second caption line"),
                ]
            }, teardown: {
                settings.showSubtitles = false
                project.subtitles = []
            }),
            state("brand", .brand),
            state("brand-on", .brand, setup: {
                settings.showWatermark = true
                settings.watermarkFileName = "watermark-probe.png"
            }, teardown: {
                settings.showWatermark = false
                settings.watermarkFileName = nil
            }),
            state("annotations", .annotations),
            state("annotations-text", .annotations, setup: { sel.selectedAnnotationID = textAnnotation.id }),
            state("annotations-arrow", .annotations, setup: { sel.selectedAnnotationID = arrow.id }),
            state("annotations-rectangle", .annotations, setup: { sel.selectedAnnotationID = rect.id }),
            state("annotations-drawing", .annotations, setup: { sel.selectedAnnotationID = drawing.id }),
            state("annotations-tap", .annotations, setup: { sel.selectedAnnotationID = tap.id }),
        ]

        let only = CommandLine.arguments.firstIndex(of: "--pane-only")
            .flatMap { i in i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : nil }
            .map { Set($0.split(separator: ",").map(String.init)) }
        let tallSize = NSSize(width: windowSize.width, height: 3000)
        for s in states {
            if let only, !only.contains(s.name) { continue }
            clear()
            s.setup()
            sel.inspectorTab = s.tab
            await settle(0.9)
            write(capture(window: window), to: dir.appendingPathComponent("\(s.name).png"), label: "PANE \(s.name)")
            window.setContentSize(tallSize)
            await settle(0.9)
            write(capture(window: window), to: dir.appendingPathComponent("\(s.name)-tall.png"), label: "PANE \(s.name) tall")
            window.setContentSize(windowSize)
            await settle(0.3)
            s.teardown()
        }
        clear()
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

    /// Probe window that never clamps its frame to a screen (pane shots only).
    private final class UnclampedProbeWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    /// Container mirroring EditorWindowContentViewController's editor
    /// topology exactly: the shell's in-content top bar pinned at 52 pt with
    /// the shell below it. The probe previously made the shell the window
    /// content directly, which put it UNDER the transparent titlebar — the
    /// split items then resolved different safe-area insets than in the real
    /// app, and the inspector-vs-preview top misalignment never reproduced
    /// (CLAUDE.md §3, wrong topology).
    final class ProbeContentViewController: NSViewController {
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
    static func makeWindow(content: NSViewController, title: String, x: CGFloat) -> NSWindow {
        // `--pane-shots` grows the window past the screen to capture whole
        // panes; a stock window clamps its frame to the screen height.
        let window: NSWindow = CommandLine.arguments.contains("--pane-shots")
            ? UnclampedProbeWindow(contentViewController: content)
            : NSWindow(contentViewController: content)
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
