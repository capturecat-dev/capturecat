import AVFoundation
import AppKit
import ImageIO

/// Reference-canvas gate (Studio 2e): `CaptureCat --reference-canvas-test [<outDir>]`.
///
/// A project's point-sized settings are laid out on its persisted reference
/// canvas (`ReferenceCanvas`), not on whatever the editor window shows. This
/// gate proves each link of that, against the REAL code:
///
///   1. Model — pre-2e projects decode with no reference and re-encode byte
///      for byte (the key is written only when set); new projects carry the
///      box; inits and decode never stamp one; unusable boxes fall back.
///   2. Canvas math — the box's canvas at every aspect, no drift when the
///      aspect changes back and forth, the exporter's canvas independent of
///      the window (and the pre-2e rule unchanged).
///   3. Real exports (lossless frame tap) — a reference project exports the
///      SAME frame at every editor window size and headless; it equals the
///      pre-2e export made from the default window; a pre-2e project still
///      follows the window (proving the comparison can see a difference);
///      with the reference ignored (injected defect) the check fails.
///   4. The real editor shell window (CLAUDE.md §3: probe in the app's own
///      hosting chain) at three window sizes — the compositor's canvas is the
///      reference canvas, it fills the card exactly as before, the preview
///      canvas IS the exporter's canvas, rasters are drawn at the magnified
///      density, the user's zoom still multiplies, an aspect change
///      re-letterboxes; and the card's PIXELS, scaled to one size, match
///      across window sizes — while a pre-2e project's do not.
///
/// Off-screen windows only — never touches the running app. DEBUG tooling;
/// never reached in a normal launch.
@MainActor
enum ReferenceCanvasHarness {
    private static var checks = 0
    private static var failures = 0

    static func run() -> Never {
        setbuf(stdout, nil)
        MainActor.assumeIsolated { CCTheme.setMode(.dark, persist: false) }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            await execute()
            exit(failures == 0 ? 0 : 1)
        }
        app.run()
        exit(0)
    }

    private static func check(_ name: String, _ pass: Bool, _ detail: String = "") {
        checks += 1
        if !pass { failures += 1 }
        print("\(pass ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    }

    private static func execute() async {
        CCTheme.setMode(.dark, persist: false)
        let outDir: URL = {
            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "--reference-canvas-test"), i + 1 < args.count,
               !args[i + 1].hasPrefix("-") {
                return URL(fileURLWithPath: args[i + 1])
            }
            return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("capturecat-reference-canvas")
        }()
        try? FileManager.default.removeItem(at: outDir)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        modelChecks()
        canvasMathChecks()

        let videoURL = outDir.appendingPathComponent("screen.mov")
        guard await PlaybackObserverHarness.writeVideo(
            to: videoURL, seconds: 2.0, size: sourceSize, tint: 0.35) else {
            check("fixture video", false, "could not synthesize")
            finish(outDir)
            return
        }
        await exportChecks(videoURL: videoURL, outDir: outDir)
        await editorChecks(videoURL: videoURL, outDir: outDir)
        finish(outDir)
    }

    private static func finish(_ outDir: URL) {
        print("REFERENCE-CANVAS outDir \(outDir.path)")
        print("REFERENCE-CANVAS \(checks - failures)/\(checks) checks passed")
    }

    private static let sourceSize = CGSize(width: 1280, height: 800)
    private static let box = ReferenceCanvas.newProjectBox
    private static let wide: CGFloat = 16.0 / 9.0

    // MARK: - 1. Model

    private static func modelChecks() {
        let legacy = Project(name: "legacy", duration: 3)
        check("model: a Project init never stamps a reference", legacy.referenceCanvasSize == nil)

        guard let legacyData = try? JSONEncoder().encode(legacy),
              let legacyObject = try? JSONSerialization.jsonObject(with: legacyData) as? [String: Any]
        else { check("model: encode", false); return }
        check("model: a pre-2e project encodes WITHOUT the key",
              legacyObject["referenceCanvasSize"] == nil)
        // JSONEncoder promises no key order, so both sides are written with
        // sorted keys: the claim is "the same JSON comes back".
        let sorted = JSONEncoder()
        sorted.outputFormatting = [.sortedKeys]
        if let decoded = try? JSONDecoder().decode(Project.self, from: legacyData),
           let before = try? sorted.encode(legacy),
           let again = try? sorted.encode(decoded) {
            check("model: a pre-2e project decodes with no reference", decoded.referenceCanvasSize == nil)
            check("model: a pre-2e project re-encodes to the same JSON (sorted keys)", again == before,
                  "\(before.count) → \(again.count) bytes")
        } else {
            check("model: pre-2e decode", false)
        }

        let fresh = Project(name: "new", duration: 3)
        fresh.adoptNewProjectReferenceCanvas()
        check("model: a new project carries the 803×330 box", fresh.referenceCanvasSize == box)
        if let data = try? JSONEncoder().encode(fresh),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let back = try? JSONDecoder().decode(Project.self, from: data) {
            let stored = object["referenceCanvasSize"] as? [Double]
            check("model: persisted as [width, height]", stored == [803, 330], "\(stored ?? [])")
            check("model: round-trips", back.referenceCanvasSize == box)
        } else {
            check("model: new-project round trip", false)
        }

        for (label, bad) in [("zero width", CGSize(width: 0, height: 330)),
                             ("negative", CGSize(width: -803, height: 330)),
                             ("infinite", CGSize(width: CGFloat.infinity, height: 330))] {
            let p = Project(name: "bad", duration: 3)
            p.referenceCanvasSize = bad
            p.previewCanvasSize = CGSize(width: 764.4, height: 430)
            check("model: an unusable box (\(label)) falls back to the pre-2e rule",
                  p.referenceCanvas(aspect: wide) == nil
                    && p.exportReferenceCanvas(outputSize: CGSize(width: 1920, height: 1080))
                        == p.previewCanvasSize)
        }
    }

    // MARK: - 2. Canvas math

    private static func canvasMathChecks() {
        func near(_ a: CGSize, _ b: CGSize, _ tol: CGFloat = 1e-9) -> Bool {
            abs(a.width - b.width) <= tol && abs(a.height - b.height) <= tol
        }
        let table: [(String, CGFloat, CGSize)] = [
            ("16:9", 16.0 / 9.0, CGSize(width: 330.0 * 16 / 9, height: 330)),
            ("9:16", 9.0 / 16.0, CGSize(width: 330.0 * 9 / 16, height: 330)),
            ("1:1", 1, CGSize(width: 330, height: 330)),
            ("4:3", 4.0 / 3.0, CGSize(width: 440, height: 330)),
            ("4:5", 4.0 / 5.0, CGSize(width: 264, height: 330)),
            ("21:9", 21.0 / 9.0, CGSize(width: 770, height: 330)),
            ("custom 1000×820", 1000.0 / 820.0, CGSize(width: 330.0 * 1000 / 820, height: 330)),
            ("32:9 (width-limited)", 32.0 / 9.0, CGSize(width: 803, height: 803.0 * 9 / 32)),
        ]
        for (label, aspect, expected) in table {
            let got = ReferenceCanvas.canvas(box: box, aspect: aspect)
            check("canvas: \(label) → \(fmt(expected))", near(got, expected), "got \(fmt(got))")
        }

        // Aspect changes never write back: 16:9 → 9:16 → 21:9 → 16:9 ends
        // where it started and the stored box is untouched.
        let p = Project(name: "drift", duration: 3)
        p.adoptNewProjectReferenceCanvas()
        let first = p.referenceCanvas(aspect: wide)
        for aspect: CGFloat in [9.0 / 16.0, 21.0 / 9.0, 1, 16.0 / 9.0] { _ = p.referenceCanvas(aspect: aspect) }
        check("canvas: no drift across aspect changes",
              p.referenceCanvas(aspect: wide) == first && p.referenceCanvasSize == box)

        // The exporter's canvas: the window no longer matters.
        let output = CGSize(width: 1920, height: 1080)
        let windows: [CGSize] = [CGSize(width: 330.0 * 16 / 9, height: 330),
                                 CGSize(width: 764.4, height: 430),
                                 CGSize(width: 1029.3, height: 579), .zero]
        let canvases = windows.map { w -> CGSize in
            p.previewCanvasSize = w
            return p.exportReferenceCanvas(outputSize: output)
        }
        check("export canvas: identical for every window size and headless",
              Set(canvases.map { "\($0)" }).count == 1 && near(canvases[0], table[0].2),
              canvases.map(fmt).joined(separator: ", "))

        // Pre-2e projects: exactly the old rule.
        let old = Project(name: "old", duration: 3)
        old.previewCanvasSize = CGSize(width: 764.4, height: 430)
        let oldWindow = old.exportReferenceCanvas(outputSize: output)
        old.previewCanvasSize = .zero
        let oldHeadless = old.exportReferenceCanvas(outputSize: output)
        check("export canvas: a pre-2e project keeps the live editor canvas / headless = output",
              oldWindow == CGSize(width: 764.4, height: 430) && oldHeadless == output)
    }

    // MARK: - 3. Real exports

    private static func exportProject(videoURL: URL, reference: Bool) -> Project {
        let project = Project(name: reference ? "ref" : "legacy", videoURL: videoURL, duration: 2.0)
        project.trimStart = 0
        project.trimEnd = 0.4
        project.settings.muteRecordedAudio = true
        project.settings.aspectRatio = .widescreen
        project.settings.exportSettings.resolution = .custom
        project.settings.exportSettings.customWidth = 640
        project.settings.exportSettings.customHeight = 360
        project.settings.exportSettings.fps = 30
        project.settings.exportSettings.collapseStaticSpans = false
        var annotation = Annotation(type: .text, startTime: 0, endTime: 2)
        annotation.text = "Reference canvas"
        project.annotations = [annotation]
        if reference { project.adoptNewProjectReferenceCanvas() }
        return project
    }

    /// The exporter's lossless pre-encode frame 3 for `project` exported as
    /// if from an editor whose canvas was `window` (.zero = headless).
    private static func exportFrame(_ project: Project, window: CGSize, outDir: URL, tag: String) async -> Pixels? {
        let tap = outDir.appendingPathComponent("tap-\(tag)", isDirectory: true)
        try? FileManager.default.removeItem(at: tap)
        setenv("CAPTURECAT_EXPORT_FRAME_TAP", tap.path, 1)
        setenv("CAPTURECAT_EXPORT_FRAME_TAP_INDICES", "3", 1)
        defer {
            unsetenv("CAPTURECAT_EXPORT_FRAME_TAP")
            unsetenv("CAPTURECAT_EXPORT_FRAME_TAP_INDICES")
        }
        project.previewCanvasSize = window
        let movie = outDir.appendingPathComponent("export-\(tag).mp4")
        do {
            try await VideoExporter().export(project: project, to: movie)
        } catch {
            print("export \(tag) failed: \(error)")
            return nil
        }
        try? FileManager.default.removeItem(at: movie)
        return Pixels(url: tap.appendingPathComponent("0003.png"))
    }

    private static func exportChecks(videoURL: URL, outDir: URL) async {
        let defaultWindow = CGSize(width: 330.0 * 16 / 9, height: 330)
        let windows: [(String, CGSize)] = [("default-window", defaultWindow),
                                           ("1400x800-window", CGSize(width: 764.4, height: 430)),
                                           ("fullscreen-window", CGSize(width: 1029.3, height: 579)),
                                           ("headless", .zero)]
        let ref = exportProject(videoURL: videoURL, reference: true)
        var refFrames: [(String, Pixels)] = []
        for (tag, window) in windows {
            guard let frame = await exportFrame(ref, window: window, outDir: outDir, tag: "ref-\(tag)") else {
                check("export: reference project from the \(tag)", false, "no frame")
                return
            }
            refFrames.append((tag, frame))
        }
        let base = refFrames[0].1
        for (tag, frame) in refFrames.dropFirst() {
            let d = base.diff(frame)
            check("export: reference project from the \(tag) == from the default window",
                  d.identical, d.description)
        }

        let legacy = exportProject(videoURL: videoURL, reference: false)
        guard let legacyDefault = await exportFrame(legacy, window: defaultWindow, outDir: outDir, tag: "legacy-default"),
              let legacyFull = await exportFrame(legacy, window: CGSize(width: 1029.3, height: 579),
                                                 outDir: outDir, tag: "legacy-fullscreen") else {
            check("export: pre-2e project", false, "no frame")
            return
        }
        let same = base.diff(legacyDefault)
        check("export: the reference canvas reproduces the default-window export exactly",
              same.identical, same.description)
        let moved = legacyDefault.diff(legacyFull)
        check("export: a pre-2e project still follows the window (the comparison can see it)",
              moved.mean > 1 && moved.over8 > 0.01, moved.description)

        // Injected defect: renderers ignore the reference → the window leaks back in.
        ReferenceCanvas.debugIgnoreReference = true
        let leakedDefault = await exportFrame(ref, window: defaultWindow, outDir: outDir, tag: "defect-default")
        let leakedFull = await exportFrame(ref, window: CGSize(width: 1029.3, height: 579), outDir: outDir, tag: "defect-full")
        ReferenceCanvas.debugIgnoreReference = false
        if let a = leakedDefault, let b = leakedFull {
            let d = a.diff(b)
            check("export: injected defect (reference ignored) is caught", !d.identical, d.description)
        } else {
            check("export: injected defect run", false, "no frame")
        }
        refFrames.last?.1.write(to: outDir.appendingPathComponent("export-ref.png"))
        legacyFull.write(to: outDir.appendingPathComponent("export-legacy-fullscreen.png"))
    }

    // MARK: - 4. The real editor shell

    private struct Sample {
        let window: CGSize
        let pixels: Pixels?
    }

    private static func editorChecks(videoURL: URL, outDir: URL) async {
        let sizes = [CGSize(width: 1100, height: 700), CGSize(width: 1400, height: 800),
                     CGSize(width: 1600, height: 950)]
        let refSamples = await shellPass(videoURL: videoURL, reference: true, sizes: sizes, outDir: outDir)
        let legacySamples = await shellPass(videoURL: videoURL, reference: false, sizes: sizes, outDir: outDir)

        // Window independence on screen: the card's pixels, scaled to one
        // size, match across windows for a reference project — and visibly
        // don't for a pre-2e one (so the comparison has teeth).
        let bar = 2.5
        func spread(_ samples: [Sample], label: String) -> [Pixels.Diff] {
            guard let first = samples.first?.pixels else { return [] }
            return samples.dropFirst().compactMap { s in
                guard let p = s.pixels else { return nil }
                let d = first.diff(p)
                print("  \(label) \(fmt(samples[0].window)) vs \(fmt(s.window)): \(d.description)")
                return d
            }
        }
        let refDiffs = spread(refSamples, label: "reference")
        let legacyDiffs = spread(legacySamples, label: "pre-2e")
        check("editor: a reference project's card looks the same at every window size",
              refDiffs.count == sizes.count - 1 && refDiffs.allSatisfy { $0.mean <= bar },
              "worst mean \(String(format: "%.3f", refDiffs.map(\.mean).max() ?? -1))/255, bar \(bar)")
        check("editor: a pre-2e project's card changes with the window (the comparison can see it)",
              legacyDiffs.count == sizes.count - 1 && legacyDiffs.allSatisfy { $0.mean > bar * 2 },
              "smallest mean \(String(format: "%.3f", legacyDiffs.map(\.mean).min() ?? -1))/255")
    }

    private static func shellPass(videoURL: URL, reference: Bool, sizes: [CGSize], outDir: URL) async -> [Sample] {
        let label = reference ? "reference" : "pre-2e"
        let project = Project(name: "Canvas \(label)", videoURL: videoURL, duration: 2.0)
        project.trimStart = 0
        project.trimEnd = 2.0
        project.settings.muteRecordedAudio = true
        project.settings.aspectRatio = .widescreen
        var annotation = Annotation(type: .text, startTime: 0, endTime: 2)
        annotation.text = "Reference canvas"
        project.annotations = [annotation]
        if reference { project.adoptNewProjectReferenceCanvas() }

        let shell = EditorShellViewController(appState: nil, project: project)
        let container = EditorShellProbeHarness.ProbeContentViewController(shell: shell)
        let window = EditorShellProbeHarness.makeWindow(content: container, title: project.name, x: 40)
        defer { window.orderOut(nil); window.close() }
        await settle(2.0)

        guard let content = window.contentView,
              let compositor = findView(ofType: PreviewCompositorView.self, in: content),
              let scroll = compositor.enclosingScrollView as? ZoomScrollView else {
            check("editor (\(label)): compositor in the shell", false)
            return []
        }
        let backing = window.backingScaleFactor
        var samples: [Sample] = []
        for size in sizes {
            window.setContentSize(size)
            await settle(1.2)
            let tag = "\(label) @ \(Int(size.width))×\(Int(size.height))"
            guard let aspect = ReferenceCanvas.outputAspect(settings: project.settings, sourceSize: sourceSize) else {
                check("editor (\(tag)): output aspect", false)
                continue
            }
            let letterbox = AspectRatio.letterboxRect(in: scroll.bounds, aspect: aspect)
            let onCard = scroll.convert(compositor.bounds, from: compositor)
            let fillsCard = abs(onCard.minX - letterbox.minX) < 0.75 && abs(onCard.minY - letterbox.minY) < 0.75
                && abs(onCard.width - letterbox.width) < 0.75 && abs(onCard.height - letterbox.height) < 0.75
            check("editor (\(tag)): the canvas fills the card's letterbox",
                  fillsCard, "on card \(fmt(onCard)), letterbox \(fmt(letterbox))")

            if reference {
                let canvas = project.referenceCanvas(aspect: aspect) ?? .zero
                let fit = letterbox.width / max(1, canvas.width)
                let output = project.settings.exportSettings.resolvedOutputSize(
                    for: project.settings.aspectRatio, sourceSize: sourceSize)
                check("editor (\(tag)): the compositor draws the reference canvas",
                      approx(compositor.bounds.size, canvas), "bounds \(fmt(compositor.bounds.size)), reference \(fmt(canvas))")
                check("editor (\(tag)): the preview canvas IS the exporter's canvas",
                      approx(project.previewCanvasSize, project.exportReferenceCanvas(outputSize: output)),
                      "preview \(fmt(project.previewCanvasSize))")
                check("editor (\(tag)): magnified to fit (fit \(String(format: "%.4f", fit)))",
                      abs(scroll.fitMagnification - fit) < 1e-6 && abs(scroll.magnification - fit) < 1e-4,
                      "fit \(scroll.fitMagnification), magnification \(scroll.magnification)")
                check("editor (\(tag)): rasters at backing × fit",
                      abs((compositor.compositorDisplayScale ?? 0) - backing * fit) < 1e-6
                        && compositor.canvasMagnification == scroll.fitMagnification,
                      "display scale \(compositor.compositorDisplayScale ?? 0)")
            } else {
                check("editor (\(tag)): pre-2e — the canvas is the letterbox, unmagnified",
                      approx(compositor.bounds.size, letterbox.size, tol: 0.5)
                        && scroll.fitMagnification == 1 && scroll.magnification == 1
                        && compositor.compositorDisplayScale == backing,
                      "bounds \(fmt(compositor.bounds.size)), magnification \(scroll.magnification)")
            }
            if reference {
                let hit = await clickSelectsLabel(shell: shell, project: project, compositor: compositor,
                                                  window: window, fit: scroll.fitMagnification)
                check("editor (\(tag)): a click on the drawn label selects it (events map through the magnification)",
                      hit.pass, hit.detail)
            }
            let pixels = captureCanvas(scroll: scroll, letterbox: letterbox)
            pixels?.write(to: outDir.appendingPathComponent(
                "editor-\(reference ? "ref" : "legacy")-\(Int(size.width))x\(Int(size.height)).png"))
            samples.append(Sample(window: size, pixels: pixels))
        }

        guard reference else { return samples }
        // The user's zoom still multiplies (100% = fit).
        shell.selection.previewZoom = 2
        await settle(0.6)
        check("editor (reference): user zoom 200% → magnification 2 × fit",
              abs(scroll.magnification - 2 * scroll.fitMagnification) < 1e-4,
              "magnification \(scroll.magnification), fit \(scroll.fitMagnification)")
        shell.selection.previewZoom = 1
        await settle(0.6)

        // An aspect change re-letterboxes the reference canvas.
        project.settings.aspectRatio = .vertical
        await settle(1.0)
        // The OUTPUT's aspect (1920×3413 — rounded), as every renderer uses.
        let vAspect = ReferenceCanvas.outputAspect(settings: project.settings, sourceSize: sourceSize) ?? 0
        let vertical = project.referenceCanvas(aspect: vAspect) ?? .zero
        let vLetterbox = AspectRatio.letterboxRect(in: scroll.bounds, aspect: vAspect)
        check("editor (reference): 9:16 re-letterboxes to the box's 9:16 canvas",
              approx(compositor.bounds.size, vertical, tol: 0.01)
                && abs(scroll.fitMagnification - vLetterbox.width / vertical.width) < 1e-4,
              "bounds \(fmt(compositor.bounds.size)), expected \(fmt(vertical)), fit \(scroll.fitMagnification)")
        return samples
    }

    /// Clicks land where things are DRAWN: the label's on-screen centre, hit-
    /// tested through the real window (the magnified clip view included) and
    /// delivered to whatever view AppKit finds, selects the label; at a fit
    /// ≠ 1 the UNMAGNIFIED position (where a mapping that ignored the
    /// magnification would look) must not. The view's own handlers are
    /// called with the hit-tested event — sending through the window would
    /// first need the off-screen probe window to become key.
    private static func clickSelectsLabel(
        shell: EditorShellViewController, project: Project, compositor: PreviewCompositorView,
        window: NSWindow, fit: CGFloat
    ) async -> (pass: Bool, detail: String) {
        guard let label = project.annotations.first(where: { $0.type == .text }),
              let frameView = window.contentView?.superview else { return (false, "no label") }
        shell.playback.currentTime = 1.0
        shell.selection.selectedAnnotationID = label.id
        await settle(0.4)
        guard let rect = compositor.selectedAnnotationViewRect() else { return (false, "no label rect") }
        shell.selection.selectedAnnotationID = nil
        await settle(0.4)

        func click(atWindow point: CGPoint) -> String {
            guard let target = frameView.hitTest(frameView.convert(point, from: nil)) else { return "nothing" }
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
                if type == .leftMouseDown { target.mouseDown(with: event) } else { target.mouseUp(with: event) }
            }
            return String(describing: type(of: target))
        }

        var detail = ""
        if abs(fit - 1) > 0.05 {
            let origin = compositor.convert(CGPoint.zero, to: nil)  // canvas top-left, window coords (y-up)
            let naive = CGPoint(x: origin.x + rect.midX, y: origin.y - rect.midY)
            let hitNaive = click(atWindow: naive)
            await settle(0.3)
            let wrong = shell.selection.selectedAnnotationID == label.id
            detail += "unmagnified point → \(hitNaive)\(wrong ? " SELECTED (wrong)" : ", not selected"); "
            if wrong { return (false, detail) }
            shell.selection.selectedAnnotationID = nil
            await settle(0.3)
        }
        let centre = compositor.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil)
        let hit = click(atWindow: centre)
        await settle(0.3)
        let selected = shell.selection.selectedAnnotationID == label.id
        detail += "label centre → \(hit)\(selected ? ", selected" : ", NOT selected")"
        shell.selection.selectedAnnotationID = nil
        await settle(0.2)
        return (selected, detail)
    }

    /// The card's letterboxed canvas exactly as the window server composites
    /// it (CARenderer of the scroll view, so the clip view's magnification is
    /// included), scaled to one comparison size. The letterbox is centred, so
    /// CARenderer's vertical flip does not move the crop.
    private static func captureCanvas(scroll: NSScrollView, letterbox: CGRect) -> Pixels? {
        scroll.wantsLayer = true
        guard let layer = scroll.layer else { return nil }
        // The first CARenderer pass over a freshly resized tree can come back
        // empty (observed: all-black at whichever size is captured first) —
        // a throwaway pass commits the tree, the second is the capture.
        _ = CARendererSnapshot.render(layer: layer, size: scroll.bounds.size, scale: 1)
        guard let shot = CARendererSnapshot.render(layer: layer, size: scroll.bounds.size, scale: 1),
              let crop = shot.cropping(to: letterbox.integral.insetBy(dx: 1, dy: 1)) else { return nil }
        return Pixels(image: crop, size: CGSize(width: 400, height: 225))
    }

    // MARK: - Helpers

    private static func settle(_ seconds: Double) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            try? await Task.sleep(for: .milliseconds(50))
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private static func findView<T: NSView>(ofType type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        for sub in root.subviews {
            if let found = findView(ofType: type, in: sub) { return found }
        }
        return nil
    }

    private static func approx(_ a: CGSize, _ b: CGSize, tol: CGFloat = 1e-6) -> Bool {
        abs(a.width - b.width) <= tol && abs(a.height - b.height) <= tol
    }

    private static func fmt(_ s: CGSize) -> String { String(format: "%.2f×%.2f", s.width, s.height) }
    private static func fmt(_ r: CGRect) -> String {
        String(format: "(%.2f,%.2f %.2f×%.2f)", r.minX, r.minY, r.width, r.height)
    }

    /// 8-bit sRGB RGBA pixels.
    private struct Pixels {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        init?(url: URL) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            self.init(image: image, size: CGSize(width: image.width, height: image.height))
        }

        init?(image: CGImage, size: CGSize) {
            let w = Int(size.width), h = Int(size.height)
            var buffer = [UInt8](repeating: 0, count: w * h * 4)
            let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
                guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                ctx.interpolationQuality = .high
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard ok else { return nil }
            width = w
            height = h
            bytes = buffer
        }

        struct Diff: CustomStringConvertible {
            var identical: Bool
            var mean: Double
            var over8: Double
            var description: String {
                identical ? "byte-identical"
                    : String(format: "mean %.3f/255, %.2f%% px > 8", mean, over8 * 100)
            }
        }

        func diff(_ other: Pixels) -> Diff {
            guard width == other.width, height == other.height else {
                return Diff(identical: false, mean: 255, over8: 1)
            }
            if bytes == other.bytes { return Diff(identical: true, mean: 0, over8: 0) }
            var total = 0
            var over = 0
            for i in stride(from: 0, to: bytes.count, by: 4) {
                var worst = 0
                for c in 0..<3 {
                    let d = abs(Int(bytes[i + c]) - Int(other.bytes[i + c]))
                    total += d
                    worst = max(worst, d)
                }
                if worst > 8 { over += 1 }
            }
            let px = width * height
            return Diff(identical: false, mean: Double(total) / Double(px * 3), over8: Double(over) / Double(px))
        }

        func write(to url: URL) {
            var copy = bytes
            copy.withUnsafeMutableBytes { raw in
                guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                      let image = ctx.makeImage(),
                      let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
                else { return }
                CGImageDestinationAddImage(dest, image, nil)
                CGImageDestinationFinalize(dest)
            }
        }
    }
}
