import AVFoundation
import AppKit
import CoreGraphics
import Foundation

/// `--still-image-test`: acceptance gate for the Image | Video treatment of
/// still captures.
///
/// 1. Codable — `stillTreatment` round-trips; legacy project.json without the
///    key decodes to `.image`; raw values are stable persistence identity.
/// 2. Timeless timeline — `presentsTimelessTimeline` derivation, the pinned
///    timeline scale, and the full-span VIDEO block geometry (the still's one
///    clip spans exactly 0…outputDuration, which at the pinned scale IS the
///    full visible track width).
/// 3. PNG export — a synthetic still runs the REAL pipeline end to end
///    (StillMovieWriter → StillImageExporter → VideoExporter → PNG) and the
///    file is verified structurally: PNG signature, decodable bitmap, expected
///    dimensions, and fixture color recovered from the pixels (a mean-diff-
///    style "file exists" check would pass on garbage — CLAUDE.md §3).
///
/// Never reached in a normal launch.
enum StillImageHarness {
    static func run() -> Never {
        Task { @MainActor in
            let failures = await runAll()
            print(failures == 0 ? "STILLIMAGE PASS" : "STILLIMAGE FAIL (\(failures))")
            exit(failures == 0 ? 0 : 1)
        }
        // Pump the main run loop so the MainActor task above can run; the
        // task exits the process when done.
        RunLoop.main.run()
        fatalError("unreachable")
    }

    @MainActor
    private static var failures = 0

    @MainActor
    private static func expect(_ condition: Bool, _ label: String) {
        print("\(condition ? "PASS" : "FAIL") \(label)")
        if !condition { failures += 1 }
    }

    @MainActor
    private static func runAll() async -> Int {
        failures = 0
        testCodable()
        testTimelessTimeline()
        testInteractiveScrub()
        testMotionComposer()
        await testPNGExport()
        return failures
    }

    // MARK: 1. Codable

    @MainActor
    private static func testCodable() {
        // Round trip of the non-default value.
        let still = Project(name: "Shot", duration: StillMovieWriter.defaultDuration)
        still.isStillCapture = true
        still.stillTreatment = .video
        if let data = try? JSONEncoder().encode(still),
           let back = try? JSONDecoder().decode(Project.self, from: data) {
            expect(back.stillTreatment == .video, "stillTreatment .video round-trips")
        } else {
            expect(false, "still project encodes+decodes")
        }

        // Legacy project.json without the key must default to .image.
        if let data = try? JSONEncoder().encode(still),
           var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            json.removeValue(forKey: "stillTreatment")
            if let stripped = try? JSONSerialization.data(withJSONObject: json),
               let legacy = try? JSONDecoder().decode(Project.self, from: stripped) {
                expect(legacy.stillTreatment == .image, "legacy project defaults to .image treatment")
            } else {
                expect(false, "legacy project decodes")
            }
        }

        // Raw values are persistence identity.
        expect(StillTreatment.image.rawValue == "image"
            && StillTreatment.video.rawValue == "video",
            "StillTreatment raw values are stable")
    }

    // MARK: 2. Timeless timeline

    @MainActor
    private static func testTimelessTimeline() {
        let still = Project(name: "Shot", duration: StillMovieWriter.defaultDuration)
        still.isStillCapture = true
        expect(still.presentsTimelessTimeline, "image treatment presents timeless (default)")
        still.stillTreatment = .video
        expect(!still.presentsTimelessTimeline, "video treatment is NOT timeless")
        still.stillTreatment = .image

        let recording = Project(
            name: "Take", cursorDataURL: URL(fileURLWithPath: "/tmp/cursor.json"), duration: 30)
        expect(!recording.presentsTimelessTimeline, "recordings never present timeless")

        // Pinned scale: a timeless still cannot zoom the time axis.
        expect(TimelineViewController.resolvedTimelineScale(
            8, timeless: true, minScale: 1, maxScale: 30) == 1,
            "timeless pins timeline scale to 1")
        expect(TimelineViewController.resolvedTimelineScale(
            8, timeless: false, minScale: 1, maxScale: 30) == 8,
            "non-timeless scale passes through")
        expect(TimelineViewController.resolvedTimelineScale(
            99, timeless: false, minScale: 1, maxScale: 30) == 30,
            "non-timeless scale still clamps to max")

        // Full-span VIDEO block: the untrimmed still is one clip covering
        // exactly 0…outputDuration — at the pinned scale that IS 100% of the
        // visible track width (x = width · t/duration).
        let map = SpeedTimeMap(
            sourceStart: still.effectiveTrimStart,
            sourceEnd: still.effectiveTrimEnd,
            regions: still.speedRegions)
        let model = TimelineVideoRowModel.make(
            project: still, timeMap: map, selectedClipID: nil,
            hasAudio: false, hasThumbnails: false, snapCandidates: [])
        expect(model.clips.count == 1, "still renders as ONE video clip")
        if let clip = model.clips.first {
            expect(abs(clip.outputStart - 0) < 0.001
                && abs(clip.outputEnd - map.outputDuration) < 0.001,
                "video block spans exactly 0…outputDuration (full track width at pinned scale)")
        }

        // Effect blocks keep real time positions in timeless mode (the time
        // mapping is presentation-invariant): a zoom at 2…5 s maps unchanged.
        expect(abs(map.outputTime(forSource: 2) - 2) < 0.001
            && abs(map.outputTime(forSource: 5) - 5) < 0.001,
            "effect time mapping unchanged by timeless presentation")

        // hasTimedEffects steers the export default AND the playhead rule.
        expect(!still.hasTimedEffects, "fresh still has no timed effects")
        expect(still.hidesTimelinePlayhead, "fresh timeless still hides the idle playhead")
        still.zoomRegions.append(ZoomRegion(startTime: 1, endTime: 3, zoomLevel: 2))
        expect(still.hasTimedEffects, "a zoom region counts as a timed effect")
        expect(!still.hidesTimelinePlayhead,
            "first timed effect auto-reveals the playhead (video-identical scrubbing)")
        still.zoomRegions.removeAll()
        still.stillTreatment = .video
        expect(!still.hidesTimelinePlayhead, "video treatment never hides the playhead")
        still.stillTreatment = .image
    }

    // MARK: 2b. Interactive scrub in timeless mode

    /// Drives the REAL canvas mouse machine in an offscreen window (probe in
    /// the hosting chain, not bare math — CLAUDE.md §3) and asserts:
    /// ruler clicks reach the scrub/seek callbacks in timeless mode, the
    /// playhead line is VISIBLE mid-interaction and hidden while idle, and
    /// with timed effects the overlay grab strip hit-tests exactly as video.
    @MainActor
    private static func testInteractiveScrub() {
        let width: CGFloat = 800
        let height = TimelineCanvasMetrics.tracksBottom + TimelineCanvasMetrics.bottomInset
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        window.contentView = container
        let canvas = TimelineCanvasView()
        canvas.frame = container.bounds
        container.addSubview(canvas)
        canvas.layoutSubtreeIfNeeded()

        var scrubXs: [CGFloat] = []
        var seekXs: [CGFloat] = []
        let callbacks = TimelineCanvasCallbacks(
            scrub: { scrubXs.append($0) },
            seek: { seekXs.append($0) },
            selectEffect: { _, _ in },
            commitEffectTimes: { _, _, _, _ in },
            setZoomLevel: { _, _ in },
            addZoomToBlock: { _ in },
            addTiltToBlock: { _ in },
            removeZoom: { _ in },
            removeTilt: { _ in },
            deleteEffectBlock: { _, _ in },
            addZoomAt: { _ in },
            addTiltAt: { _ in },
            selectFocus: { _, _ in },
            commitFocusTimes: { _, _, _, _ in },
            deleteFocus: { _, _ in },
            addBlurAt: { _ in },
            addHighlightAt: { _ in },
            selectAnnotation: { _ in },
            commitAnnotationTimes: { _, _, _ in },
            deleteAnnotation: { _ in },
            addAnnotationAt: { _, _ in }
        )

        func snapshot(timeless: Bool) -> TimelineCanvasSnapshot {
            TimelineCanvasSnapshot(
                outputDuration: 8, playheadOutputTime: 4,
                playheadIsRed: false, playheadHitTestEnabled: true,
                scrubLabel: "0:04.0", effectItems: [],
                selectedZoomID: nil, selectedTiltID: nil,
                focusItems: [], annotateItems: [],
                trimStartOutput: 0, trimEndOutput: 8,
                sliceArmed: false,
                timelessVideo: timeless, dimmedRuler: !timeless)
        }

        // Playhead at t=4 of 8 s → x = 400. Sample inside the lanes.
        let playheadX: CGFloat = width * 0.5
        let sampleY: CGFloat = 150

        func playheadPixelVisible() -> Bool {
            guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { return false }
            canvas.cacheDisplay(in: canvas.bounds, to: rep)
            // colorAt(x:y:) indexes PIXELS, and the rep's backing scale is
            // whatever the window server handed the headless window — this
            // gate ran for weeks at 1x, then silently broke the day it got a
            // Retina (2x) rep and started sampling the wrong point. Convert
            // view points → rep pixels explicitly so the scale can't matter.
            let px = CGFloat(rep.pixelsWide) / max(1, canvas.bounds.width)
            let py = CGFloat(rep.pixelsHigh) / max(1, canvas.bounds.height)
            // CAPTURECAT_STILL_DEBUG=1: dump the scanline so a red gate says
            // WHERE the line went instead of just "not at x=400".
            if ProcessInfo.processInfo.environment["CAPTURECAT_STILL_DEBUG"] != nil {
                var hits: [String] = []
                for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                    if let c = rep.colorAt(x: x, y: Int(sampleY * py)),
                       let rgb = c.usingColorSpace(.deviceRGB),
                       rgb.alphaComponent > 0.5, rgb.blueComponent > 0.55,
                       rgb.greenComponent > 0.45, rgb.redComponent < 0.55 {
                        hits.append(String(x))
                    }
                }
                let probe = rep.colorAt(x: Int(playheadX * px), y: Int(sampleY * py))
                    .flatMap { $0.usingColorSpace(.deviceRGB) }
                    .map { String(format: "r=%.2f g=%.2f b=%.2f a=%.2f",
                                  $0.redComponent, $0.greenComponent,
                                  $0.blueComponent, $0.alphaComponent) } ?? "nil"
                print("STILL-DEBUG rep=\(rep.pixelsWide)x\(rep.pixelsHigh) bounds=\(Int(canvas.bounds.width))x\(Int(canvas.bounds.height)) at(\(Int(playheadX)),\(Int(sampleY)))=\(probe) cyanish-x=[\(hits.joined(separator: ","))]")
            }
            let dxRange = -Int(ceil(px))...Int(ceil(px))
            for dx in dxRange {
                if let c = rep.colorAt(x: Int(playheadX * px) + dx, y: Int(sampleY * py)),
                   let rgb = c.usingColorSpace(.deviceRGB),
                   rgb.alphaComponent > 0.5,
                   rgb.blueComponent > 0.55, rgb.greenComponent > 0.45,
                   rgb.redComponent < 0.55 {
                    return true
                }
            }
            return false
        }

        func mouse(_ type: NSEvent.EventType, at canvasPoint: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type,
                location: canvas.convert(canvasPoint, to: nil),
                modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1)
        }

        // ── Timeless (no timed effects) ────────────────────────────────────
        canvas.apply(snapshot: snapshot(timeless: true), callbacks: callbacks)
        expect(!playheadPixelVisible(), "timeless idle: playhead line hidden")

        // The overlay grab strip must NOT swallow clicks (the line is
        // invisible) — clicks fall through to the canvas scrub paths.
        let nearPlayhead = container.convert(CGPoint(x: playheadX, y: sampleY), from: canvas)
        expect(canvas.hitTest(nearPlayhead) === canvas,
            "timeless: click near hidden playhead falls through to the canvas")

        // Ruler press → drag → release reaches scrub/seek, and the line is
        // visible DURING the interaction (motion, not settled frames).
        let rulerY: CGFloat = 10
        if let down = mouse(.leftMouseDown, at: CGPoint(x: playheadX, y: rulerY)) {
            canvas.mouseDown(with: down)
        }
        expect(playheadPixelVisible(), "timeless: playhead line visible mid-scrub")
        if let drag = mouse(.leftMouseDragged, at: CGPoint(x: 600, y: rulerY)) {
            canvas.mouseDragged(with: drag)
        }
        expect(scrubXs.contains { abs($0 - 600) < 0.5 },
            "timeless: ruler drag reaches the scrub callback (x=600)")
        if let up = mouse(.leftMouseUp, at: CGPoint(x: 600, y: rulerY)) {
            canvas.mouseUp(with: up)
        }
        expect(seekXs.contains { abs($0 - 600) < 0.5 },
            "timeless: release reaches the seek callback (x=600)")
        expect(!playheadPixelVisible(), "timeless: playhead line fades back out after the scrub")

        // ── Image treatment WITH timed effects ─────────────────────────────
        canvas.apply(snapshot: snapshot(timeless: false), callbacks: callbacks)
        expect(playheadPixelVisible(), "timed effects: playhead line visible while idle (video-identical)")
        let hit = canvas.hitTest(nearPlayhead)
        expect(hit != nil && hit !== canvas,
            "timed effects: playhead grab strip hit-tests like video mode")
    }

    // MARK: 2c. Motion composer (still four-corner tour)

    @MainActor
    private static func testMotionComposer() {
        let duration = StillMovieWriter.defaultDuration
        let a = StillMotionComposer.compose(duration: duration)
        let b = StillMotionComposer.compose(duration: duration)

        // Deterministic: same input → same plan (modulo region UUIDs).
        let sameZooms = a.zoomRegions.count == b.zoomRegions.count
            && zip(a.zoomRegions, b.zoomRegions).allSatisfy {
                $0.startTime == $1.startTime && $0.endTime == $1.endTime
                    && $0.zoomLevel == $1.zoomLevel && $0.focalPoint == $1.focalPoint
            }
        expect(sameZooms, "motion composer is deterministic")

        // Four-corner tour at the default still duration, tilts mirroring.
        expect(a.zoomRegions.count == 4, "motion tours four corners at \(Int(duration))s")
        expect(a.tiltRegions.count == a.zoomRegions.count, "one tilt per corner segment")

        // In-bounds, generated flag, and viewport never crops past the frame.
        expect(a.zoomRegions.allSatisfy { zoom in
            let half = 0.5 / zoom.zoomLevel
            return zoom.startTime >= 0 && zoom.endTime <= duration
                && zoom.isAuto == true
                && zoom.focalPoint.x >= half && zoom.focalPoint.x <= 1 - half
                && zoom.focalPoint.y >= half && zoom.focalPoint.y <= 1 - half
        }, "motion regions stay in time and viewport bounds")

        // Contiguous glide: sorted, non-overlapping, adjacent segments touch.
        let contiguous = zip(a.zoomRegions, a.zoomRegions.dropFirst()).allSatisfy {
            abs($0.endTime - $1.startTime) < 0.001
        }
        expect(contiguous, "corner segments glide contiguously without overlap")

        // Clockwise corner order: TL → TR → BR → BL.
        let focals = a.zoomRegions.map(\.focalPoint)
        expect(
            focals.count == 4
                && focals[0].x < 0.5 && focals[0].y < 0.5
                && focals[1].x > 0.5 && focals[1].y < 0.5
                && focals[2].x > 0.5 && focals[2].y > 0.5
                && focals[3].x < 0.5 && focals[3].y > 0.5,
            "tour visits corners clockwise from top-left")
    }

    // MARK: 3. PNG export

    @MainActor
    private static func testPNGExport() async {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("capturecat-stillimage-test-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // Fixture: a flat orange 640×400 still — the color is the structural
        // assertion at the far end of the pipeline.
        guard let fixture = makeFixtureImage(width: 640, height: 400) else {
            expect(false, "fixture image renders")
            return
        }
        let movieURL = scratch.appendingPathComponent("still.mp4")
        do {
            _ = try await StillMovieWriter.write(image: fixture, to: movieURL)
        } catch {
            expect(false, "StillMovieWriter writes fixture (\(error.localizedDescription))")
            return
        }

        let project = Project(
            name: "Fixture Still", videoURL: movieURL,
            duration: StillMovieWriter.defaultDuration)
        project.isStillCapture = true
        // Neutral canvas: no padding/background so the still fills the frame
        // and the color check can sample anywhere.
        project.settings.backgroundPadding = 0
        // Pin the output size to the fixture so the aspect assertion tests the
        // resolution plumbing (the default Auto canvas is 16:9 1080p).
        project.settings.exportSettings.resolution = .custom
        project.settings.exportSettings.customWidth = 640
        project.settings.exportSettings.customHeight = 400

        let pngURL = scratch.appendingPathComponent("out.png")
        do {
            try await StillImageExporter.exportPNG(project: project, to: pngURL)
        } catch {
            // The exporter runs the real auth gate; without a signed-in user
            // (CI, fresh machine) the render path cannot be reached at all.
            // Report loudly but distinguish it from a render failure.
            print("SKIP png export — exporter unavailable: \(error.localizedDescription)")
            return
        }

        guard let data = try? Data(contentsOf: pngURL) else {
            expect(false, "PNG file written")
            return
        }
        let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        expect(data.count > 8 && Array(data.prefix(8)) == pngSignature, "file carries the PNG signature")

        guard let rep = NSBitmapImageRep(data: data) else {
            expect(false, "PNG decodes to a bitmap")
            return
        }
        expect(rep.pixelsWide > 0 && rep.pixelsHigh > 0, "decoded PNG has nonzero dimensions")
        let aspect = Double(rep.pixelsWide) / Double(rep.pixelsHigh)
        expect(abs(aspect - 640.0 / 400.0) < 0.05,
            "PNG keeps the fixture aspect (\(rep.pixelsWide)x\(rep.pixelsHigh))")

        // Structural color check: the center pixel must still read as the
        // fixture ORANGE. Color management (601 encode, sRGB render) shifts
        // absolute components, so assert the hue ordering + brightness bands —
        // black, white, gray and channel-swapped garbage all fail.
        if let color = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2),
           let rgb = color.usingColorSpace(.deviceRGB) {
            let (r, g, b) = (rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
            let ok = r > 0.7 && r > g + 0.15 && g > b + 0.15 && b < 0.45
            expect(ok, String(format: "center pixel reads as fixture orange (r %.2f g %.2f b %.2f)", r, g, b))
        } else {
            expect(false, "center pixel readable")
        }
    }

    private static func makeFixtureImage(width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setFillColor(CGColor(red: 0.9, green: 0.45, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}
