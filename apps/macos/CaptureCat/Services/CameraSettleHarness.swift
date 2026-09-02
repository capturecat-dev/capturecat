import AppKit
import AVFoundation
import QuartzCore

/// `--camera-settle-test`: camera release gate.
///
/// Repro: a still-image project with ONE linked zoom+tilt block 0…3 s
/// (zoom 1.6, focal (0.3, 0.7), card offset (−0.18, +0.15), tilt
/// 10/−14/−5°, Cinematic style, Mellow speed) must return to the CENTRED
/// rest framing shortly after the block ends and stay there to the final
/// frame — the bug this gate exists for showed the card small and pushed
/// off-centre a full second after the block released.
///
/// Two layers, per CLAUDE.md §3:
/// 1. PURE MATH — steps the real `PreviewMotionModel` (the exporter shares
///    every formula via ZoomFocalMath/TiltMath) at 60 Hz and 30 Hz and
///    asserts settle bounds, monotonic release and the final frame.
/// 2. STRUCTURE — drives the REAL `PreviewCompositorView` inside the same
///    flipped hosting chain the app uses, measures the card's pixel
///    bounding box after release, and asserts it matches the no-effects
///    rest framing. The gate proves its own power by asserting the SAME
///    measurement reports off-centre mid-block (t = 1 s).
///
/// Never reached in a normal launch.
enum CameraSettleHarness {
    static let paneSize = CGSize(width: 720, height: 405)

    @MainActor private static var failures = 0
    @MainActor private static func expect(_ condition: Bool, _ label: String) {
        print("\(condition ? "PASS" : "FAIL") \(label)")
        if !condition { failures += 1 }
    }

    static func run() -> Never {
        setbuf(stdout, nil)
        Task { @MainActor in
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            runMathGate(hz: 60)
            runMathGate(hz: 30)
            runMaxExcursionGate()
            runInverseGate()
            await runCompositorGate()
            print(failures == 0 ? "CAMERA-SETTLE PASS" : "CAMERA-SETTLE FAIL (\(failures))")
            exit(failures == 0 ? 0 : 1)
        }
        // Pump the main run loop so the MainActor task above can run; the
        // task exits the process when done (StillImageHarness pattern).
        RunLoop.main.run()
        fatalError("unreachable")
    }

    // MARK: - Fixture

    static let blockEnd: TimeInterval = 3.0
    static let clipEnd: TimeInterval = 8.0

    @MainActor private static func makeProject(
        withBlock: Bool,
        offset: (x: Double, y: Double) = (-0.18, 0.15)
    ) -> Project {
        let project = Project(
            id: UUID(uuidString: "00000000-0000-4000-A000-0000CA5E7712")!,
            name: "settle-fixture",
            duration: clipEnd,
            recordingSourceKind: .display
        )
        project.trimStart = 0
        project.trimEnd = clipEnd
        project.isStillCapture = true
        let s = project.settings
        s.backgroundType = .gradient
        s.backgroundPadding = 18
        s.videoPlacement = .center
        s.animationSpeed = .mellow
        s.screenTiltMode = .off
        s.showCursor = false
        s.showCamera = false
        if withBlock {
            project.zoomRegions = [ZoomRegion(
                startTime: 0, endTime: blockEnd, zoomLevel: 1.6,
                focalPoint: CGPoint(x: 0.3, y: 0.7),
                animationStyle: .cinematic,
                cardOffsetX: offset.x, cardOffsetY: offset.y,
                followsCursor: false
            )]
            project.tiltRegions = [TiltRegion(
                startTime: 0, endTime: blockEnd,
                pitch: 10, yaw: -14, roll: -5,
                animationStyle: .cinematic
            )]
        }
        return project
    }

    @MainActor private static func env(_ project: Project, at t: TimeInterval) -> PreviewMotionModel.Env {
        PreviewMotionModel.Env(
            currentTime: t,
            zoomRegions: project.zoomRegions,
            tiltRegions: project.tiltRegions,
            animationDuration: project.settings.animationSpeed.duration,
            screenTiltMode: project.settings.screenTiltMode,
            smoothingFactor: project.settings.smoothingFactor,
            followSpeed: project.settings.cameraFollowSpeed,
            scrollTimes: [],
            cursorEvents: [],
            coordinateSize: CGSize(width: 1920, height: 1050)
        )
    }

    // MARK: - 1. Pure math

    @MainActor private static func runMathGate(hz: Double) {
        let project = makeProject(withBlock: true)
        let model = PreviewMotionModel()
        model.reset(env: env(project, at: 0))

        // Spring settle bounds: zoom 1 ± 0.005, |offset| ≤ 0.005 canvas
        // fractions, |tilt| ≤ 0.1° on every axis — and once reached, HELD.
        func settled() -> Bool {
            abs(model.zoom - 1) <= 0.005
                && abs(model.cardOffsetX) <= 0.005 && abs(model.cardOffsetY) <= 0.005
                && abs(model.regionPitch) <= 0.1 && abs(model.regionYaw) <= 0.1
                && abs(model.regionRoll) <= 0.1
        }

        let dt = 1.0 / hz
        var t = 0.0
        var settleTime: TimeInterval?
        var brokeAfterSettle = false
        // Sign-overshoot bounds: the release must not swing past rest by more
        // than a spring-appropriate margin (ζ ≥ 0.95 ⇒ ≤ ~2% of excursion).
        var overshootX = 0.0, overshootY = 0.0, overshootZoom = 0.0
        while t < clipEnd - dt / 2 {
            t += dt
            model.step(env: env(project, at: t))
            if t > blockEnd {
                if settleTime == nil, settled() { settleTime = t }
                if settleTime != nil, !settled() { brokeAfterSettle = true }
                // Original excursion signs: x ≤ 0, y ≥ 0, zoom ≥ 1.
                overshootX = max(overshootX, model.cardOffsetX)
                overshootY = max(overshootY, -model.cardOffsetY)
                overshootZoom = max(overshootZoom, 1 - model.zoom)
            }
        }
        let settleBy = blockEnd + 2.0
        expect(settleTime != nil && settleTime! <= settleBy,
               "\(Int(hz))Hz: camera settles by \(settleBy)s (settled at \(settleTime.map { String(format: "%.2f", $0) } ?? "never"))")
        expect(!brokeAfterSettle, "\(Int(hz))Hz: settle is held once reached")
        expect(overshootX <= 0.004 && overshootY <= 0.004,
               String(format: "%dHz: offset release has no sign overshoot (x %.4f, y %.4f)", Int(hz), overshootX, overshootY))
        expect(overshootZoom <= 0.01,
               String(format: "%dHz: zoom release has no undershoot below 1 (%.4f)", Int(hz), overshootZoom))
        expect(settled(),
               String(format: "%dHz: final frame at t=8 is rest (zoom %.4f off %.4f,%.4f tilt %.2f,%.2f,%.2f)",
                      Int(hz), model.zoom, model.cardOffsetX, model.cardOffsetY,
                      model.regionPitch, model.regionYaw, model.regionRoll))

        // Paused-scrub reconstruction must agree: a seek to t=4 shows rest.
        let scrubModel = PreviewMotionModel()
        scrubModel.scrub(env: env(project, at: blockEnd + 1.0), from: 0)
        expect(abs(scrubModel.zoom - 1) <= 0.005
                   && abs(scrubModel.cardOffsetX) <= 0.005
                   && abs(scrubModel.cardOffsetY) <= 0.005
                   && abs(scrubModel.regionPitch) <= 0.1
                   && abs(scrubModel.regionYaw) <= 0.1
                   && abs(scrubModel.regionRoll) <= 0.1,
               String(format: "%dHz: scrub to t=4 reconstructs rest (zoom %.4f off %.4f,%.4f)",
                      Int(hz), scrubModel.zoom, scrubModel.cardOffsetX, scrubModel.cardOffsetY))
    }

    // MARK: - 1a. Max excursion settle

    /// The excursion clamp is ±ZoomFocalMath.cardOffsetLimit ("place
    /// anywhere" — fully off-canvas allowed). The settle-home guarantee must
    /// hold from the EXTREME corner of that range, not just the modest
    /// fixture offset: the release is the same exponential spring, so the
    /// trip home from 1.5 only costs ~ln(1.5/0.18) extra time constants.
    @MainActor private static func runMaxExcursionGate() {
        let limit = ZoomFocalMath.cardOffsetLimit
        let project = makeProject(withBlock: true, offset: (-limit, limit))
        let model = PreviewMotionModel()
        model.reset(env: env(project, at: 0))
        let dt = 1.0 / 60.0
        var t = 0.0
        var settleTime: TimeInterval?
        var brokeAfterSettle = false
        func settled() -> Bool {
            abs(model.zoom - 1) <= 0.005
                && abs(model.cardOffsetX) <= 0.005 && abs(model.cardOffsetY) <= 0.005
        }
        while t < clipEnd - dt / 2 {
            t += dt
            model.step(env: env(project, at: t))
            if t > blockEnd {
                if settleTime == nil, settled() { settleTime = t }
                if settleTime != nil, !settled() { brokeAfterSettle = true }
            }
        }
        // Mid-block the target must be honoured unclamped by the math.
        let probe = PreviewMotionModel()
        probe.scrub(env: env(project, at: 2.0), from: 0)
        // 2% of the excursion: the Cinematic spring is asymptotic — at t=2 s
        // it is ~98.5% of the way to a 1.5-canvas slide.
        expect(abs(probe.cardOffsetX - (-limit)) <= 0.03 && abs(probe.cardOffsetY - limit) <= 0.03,
               String(format: "max excursion ±%.1f is reached mid-block (off %.3f, %.3f)",
                      limit, probe.cardOffsetX, probe.cardOffsetY))
        let settleBy = blockEnd + 2.0
        expect(settleTime != nil && settleTime! <= settleBy,
               "max excursion: camera settles by \(settleBy)s (settled at \(settleTime.map { String(format: "%.2f", $0) } ?? "never"))")
        expect(!brokeAfterSettle, "max excursion: settle is held once reached")
        expect(settled(),
               String(format: "max excursion: final frame is rest (zoom %.4f off %.4f,%.4f)",
                      model.zoom, model.cardOffsetX, model.cardOffsetY))
    }

    // MARK: - 1b. Camera inverse round-trip

    /// The interaction layer's inverse of the card camera transform must
    /// round-trip the compositor's forward transform exactly — the missing
    /// cardOffset term made every mid-block hit test and drag mapping miss
    /// by ~(81, 38) px for the repro block.
    @MainActor private static func runInverseGate() {
        let canvas = CGSize(width: 720, height: 405)
        let anchor = CGPoint(x: 216, y: 283.5) // focal (0.3, 0.7) of canvas
        let zoom: CGFloat = 1.6
        let off = CGPoint(x: -0.18, y: 0.15)

        // Forward: EXACTLY the compositor's zoomGroup transform.
        func forward(_ q: CGPoint) -> CGPoint {
            CGPoint(
                x: anchor.x + off.x * canvas.width + zoom * (q.x - anchor.x),
                y: anchor.y + off.y * canvas.height + zoom * (q.y - anchor.y)
            )
        }

        var worst: CGFloat = 0
        for q in [CGPoint(x: 100, y: 80), CGPoint(x: 360, y: 202.5), CGPoint(x: 650, y: 380)] {
            let back = PreviewInteractionView.inverseCameraPoint(
                forward(q), zoom: zoom, anchor: anchor, cardOffset: off, canvas: canvas)
            worst = max(worst, max(abs(back.x - q.x), abs(back.y - q.y)))
        }
        expect(worst < 0.01,
               String(format: "inverse round-trips the camera transform (worst %.3f px)", worst))

        // Gate power: the PRE-FIX formula (no cardOffset term) must be caught
        // — it misses by |off·canvas|/zoom, ~81 px here.
        let q = CGPoint(x: 360, y: 202.5)
        let old = PreviewInteractionView.inverseCameraPoint(
            forward(q), zoom: zoom, anchor: anchor, cardOffset: .zero, canvas: canvas)
        let miss = max(abs(old.x - q.x), abs(old.y - q.y))
        expect(miss > 50,
               String(format: "round-trip check detects the offset-less inverse (miss %.1f px)", miss))
    }

    // MARK: - 2. Real compositor structure

    @MainActor private static func runCompositorGate() async {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: paneSize.width, height: paneSize.height),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        let container = FlippedContainer(frame: NSRect(origin: .zero, size: paneSize))
        container.wantsLayer = true
        let compositor = PreviewCompositorView(frame: NSRect(origin: .zero, size: paneSize))
        compositor.suppressImplicitAnimation = true
        container.addSubview(compositor)
        window.contentView = container
        window.orderFrontRegardless()
        await settle(0.3)

        let videoSize = CGSize(width: 1920, height: 1050)
        let poster = PreviewParityHarness.syntheticVideoFrame(size: videoSize)

        func input(_ project: Project, at t: TimeInterval) -> PreviewCompositorView.FrameInput {
            PreviewCompositorView.FrameInput(
                project: project, currentTime: t, isPlaying: true,
                cursorEvents: [], cursorCoordinateSize: videoSize,
                videoSize: videoSize, player: nil, cameraPlayer: nil,
                cameraPosterImage: nil, cameraVideoAspect: 4.0 / 3.0,
                videoPosterImage: poster
            )
        }

        /// Ticks the compositor's real spring lifecycle to `target` (30 Hz
        /// playback-style clock) and returns the card's pixel bounding box.
        func cardBox(_ project: Project, playTo target: TimeInterval) async -> CGRect? {
            compositor.schedule(input(project, at: 0))
            await settle(0.15)
            var t = 0.0
            let tick = 1.0 / 30.0
            while t + tick <= target {
                t += tick
                compositor.schedule(input(project, at: t))
                await settle(0.005)
            }
            compositor.schedule(input(project, at: target))
            await settle(0.25)
            compositor.schedule(input(project, at: target))
            await settle(0.25)
            guard let layer = container.layer,
                  let frame = CARendererSnapshot.render(
                      layer: layer, size: container.bounds.size, scale: 1
                  ) else { return nil }
            return cardBoundingBox(frame)
        }

        // Orientation probes (debug): enum .bottom vs custom y=0.81.
        if ProcessInfo.processInfo.environment["CAPTURECAT_SETTLE_DEBUG"] != nil {
            let pBottom = makeProject(withBlock: false)
            pBottom.settings.videoPlacement = .bottom
            if let b = await cardBox(pBottom, playTo: 1.0) {
                print(String(format: "ENUM-BOTTOM box=(%.0f,%.0f %.0fx%.0f)", b.origin.x, b.origin.y, b.width, b.height))
            }
            let pCustom = makeProject(withBlock: false)
            pCustom.settings.videoCustomX = 0.4215
            pCustom.settings.videoCustomY = 0.8141
            if let b = await cardBox(pCustom, playTo: 1.0) {
                print(String(format: "CUSTOM-0.81 box=(%.0f,%.0f %.0fx%.0f)", b.origin.x, b.origin.y, b.width, b.height))
            }
        }

        // Debug aid: CAPTURECAT_SETTLE_PROJECT=<project.json path> renders the
        // REAL project through the same compositor and dumps frames + boxes.
        if let path = ProcessInfo.processInfo.environment["CAPTURECAT_SETTLE_PROJECT"],
           let data = FileManager.default.contents(atPath: path),
           let real = try? JSONDecoder().decode(Project.self, from: data) {
            var realPoster: NSImage?
            var realSize = videoSize
            if let videoURL = real.videoURL {
                let gen = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
                gen.requestedTimeToleranceBefore = CMTime.zero
                gen.requestedTimeToleranceAfter = CMTime.zero
                if let cg = try? gen.copyCGImage(at: CMTime(seconds: 0.1, preferredTimescale: 600), actualTime: nil) {
                    realSize = CGSize(width: cg.width, height: cg.height)
                    realPoster = NSImage(cgImage: cg, size: realSize)
                }
            }
            let outDir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("capturecat-settle-debug", isDirectory: true)
            try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            for target in [1.0, 3.0, 3.5, 4.0, 6.0, 8.0] {
                compositor.schedule(PreviewCompositorView.FrameInput(
                    project: real, currentTime: 0, isPlaying: true,
                    cursorEvents: [], cursorCoordinateSize: realSize,
                    videoSize: realSize, player: nil, cameraPlayer: nil,
                    cameraPosterImage: nil, cameraVideoAspect: 4.0 / 3.0,
                    videoPosterImage: realPoster))
                await settle(0.15)
                var t = 0.0
                while t + 1.0 / 30.0 <= target {
                    t += 1.0 / 30.0
                    compositor.schedule(PreviewCompositorView.FrameInput(
                        project: real, currentTime: t, isPlaying: true,
                        cursorEvents: [], cursorCoordinateSize: realSize,
                        videoSize: realSize, player: nil, cameraPlayer: nil,
                        cameraPosterImage: nil, cameraVideoAspect: 4.0 / 3.0,
                        videoPosterImage: realPoster))
                    await settle(0.005)
                }
                await settle(0.3)
                if let layer = container.layer,
                   let frame = CARendererSnapshot.render(
                       layer: layer, size: container.bounds.size, scale: 1) {
                    let url = outDir.appendingPathComponent(String(format: "real-t%.1f.png", target))
                    if let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                        CGImageDestinationAddImage(dest, frame, nil)
                        CGImageDestinationFinalize(dest)
                    }
                    print("REAL-FRAME t=\(target) -> \(url.path)")
                }
            }
        }

        guard let restBox = await cardBox(makeProject(withBlock: false), playTo: 4.0) else {
            expect(false, "compositor: rest baseline renders")
            return
        }
        print(String(format: "REST box=(%.0f,%.0f %.0fx%.0f)", restBox.origin.x, restBox.origin.y, restBox.width, restBox.height))

        // Gate power: mid-block the same measurement must be far from rest.
        if let midBox = await cardBox(makeProject(withBlock: true), playTo: 1.0) {
            let moved = abs(midBox.midX - restBox.midX) > 8 || abs(midBox.midY - restBox.midY) > 8
                || abs(midBox.width - restBox.width) > 12
            print(String(format: "MID  box=(%.0f,%.0f %.0fx%.0f)", midBox.origin.x, midBox.origin.y, midBox.width, midBox.height))
            expect(moved, "compositor: measurement detects the mid-block excursion (gate power)")
        } else {
            expect(false, "compositor: mid-block frame renders")
        }

        for target in [4.0, clipEnd] {
            guard let box = await cardBox(makeProject(withBlock: true), playTo: target) else {
                expect(false, "compositor: t=\(target) frame renders")
                continue
            }
            let dx = abs(box.midX - restBox.midX)
            let dy = abs(box.midY - restBox.midY)
            let dw = abs(box.width - restBox.width)
            let dh = abs(box.height - restBox.height)
            print(String(format: "T=%.1f box=(%.0f,%.0f %.0fx%.0f) d=(%.1f,%.1f) size-d=(%.1f,%.1f)",
                         target, box.origin.x, box.origin.y, box.width, box.height, dx, dy, dw, dh))
            expect(dx <= 2 && dy <= 2 && dw <= 4 && dh <= 4,
                   "compositor: card back at rest framing at t=\(target) after the block")
        }

        // ── Drag attribution mid-block (real events, real hosting chain) ──
        // Dragging the card while the playhead is inside a zoom block must
        // compose the BLOCK's cardOffset and must NOT write the permanent
        // base placement (videoCustomX/Y) — the pollution that made the
        // release spring home to an off-centre base.
        let dragProject = makeProject(withBlock: true)
        _ = await cardBox(dragProject, playTo: 1.0) // settle springs at t=1
        compositor.schedule(input(dragProject, at: 1.0))
        await settle(0.3)
        guard let interaction = compositor.subviews
            .compactMap({ $0 as? PreviewInteractionView }).first else {
            expect(false, "compositor: interaction view present")
            return
        }
        let initialOffset = (dragProject.zoomRegions[0].cardOffsetX ?? 0,
                             dragProject.zoomRegions[0].cardOffsetY ?? 0)
        func mouse(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type,
                location: interaction.convert(point, to: nil),
                modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1)
        }
        let start = CGPoint(x: 360, y: 202.5)   // card body, canvas centre
        let end = CGPoint(x: 396, y: 242.5)     // +36, +40 px drag
        if let down = mouse(.leftMouseDown, at: start),
           let drag = mouse(.leftMouseDragged, at: end),
           let up = mouse(.leftMouseUp, at: end) {
            interaction.mouseDown(with: down)
            interaction.mouseDragged(with: drag)
            interaction.mouseUp(with: up)
        }
        let s = dragProject.settings
        expect(s.videoCustomX == nil && s.videoCustomY == nil,
               "mid-block card drag does NOT write base placement (videoCustomX/Y stay nil)")
        let newOffset = (dragProject.zoomRegions[0].cardOffsetX ?? 0,
                        dragProject.zoomRegions[0].cardOffsetY ?? 0)
        let expectedDX = 36.0 / 720.0, expectedDY = 40.0 / 405.0
        expect(abs(newOffset.0 - initialOffset.0 - expectedDX) < 0.002
                   && abs(newOffset.1 - initialOffset.1 - expectedDY) < 0.002,
               String(format: "mid-block card drag edits the block's excursion 1:1 (Δ %.4f, %.4f)",
                      newOffset.0 - initialOffset.0, newOffset.1 - initialOffset.1))

        // And the composition still returns home: after the (now larger)
        // excursion, the final frame matches the rest framing.
        if let box = await cardBox(dragProject, playTo: clipEnd) {
            expect(abs(box.midX - restBox.midX) <= 2 && abs(box.midY - restBox.midY) <= 2,
                   "card still returns to rest framing after a mid-block offset drag")
        } else {
            expect(false, "post-drag final frame renders")
        }

        // ── Live render feedback while PAUSED (the user-visible symptom) ──
        // A mid-block card drag must move the RENDERED frame before mouse-up,
        // with the playhead paused — the model write alone is not the feature.
        // Regression this guards: motionResetSignature omitted cardOffsetX/Y,
        // so a paused-drag requestRender took none of the motion branches and
        // re-rendered the identical frame — the drag felt completely dead.
        //
        // Measurement: the CROSS POINT where all four synthetic quadrants
        // meet (the card's content centre). The zoomed card overflows the
        // canvas mid-block, so bounding boxes and extreme-pixel corners
        // saturate at the clip edges; the cross point stays in view before
        // and after and translates exactly 1:1 with the cardOffset (which
        // rides OUTSIDE the zoom and tilt), warp or no warp.
        let feedbackProject = makeProject(withBlock: true)
        compositor.schedule(PreviewCompositorView.FrameInput(
            project: feedbackProject, currentTime: 1.5, isPlaying: false,
            cursorEvents: [], cursorCoordinateSize: videoSize,
            videoSize: videoSize, player: nil, cameraPlayer: nil,
            cameraPosterImage: nil, cameraVideoAspect: 4.0 / 3.0,
            videoPosterImage: poster))
        await settle(0.3)
        func quadrantCrossPoint() -> CGPoint? {
            guard let layer = container.layer,
                  let frame = CARendererSnapshot.render(
                      layer: layer, size: container.bounds.size, scale: 1
                  ) else { return nil }
            let w = frame.width, h = frame.height
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(
                      data: nil, width: w, height: h, bitsPerComponent: 8,
                      bytesPerRow: w * 4, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return nil }
            ctx.draw(frame, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let data = ctx.data else { return nil }
            let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
            // Classify each pixel into one of the four quadrant fills.
            let targets: [(Double, Double, Double)] = [
                (0.35, 0.34, 0.84), (0.19, 0.69, 0.78),
                (0.91, 0.30, 0.44), (0.22, 0.72, 0.40),
            ]
            var cls = [UInt8](repeating: 0, count: w * h)
            for i in 0..<(w * h) {
                let r = Double(px[i * 4]) / 255, g = Double(px[i * 4 + 1]) / 255, b = Double(px[i * 4 + 2]) / 255
                for (k, t) in targets.enumerated()
                where abs(r - t.0) < 0.10 && abs(g - t.1) < 0.10 && abs(b - t.2) < 0.10 {
                    cls[i] = UInt8(k + 1)
                    break
                }
            }
            // Centroid of pixels whose 7x7 neighbourhood contains all four
            // quadrant colours — that only happens at the cross.
            var sumX = 0.0, sumY = 0.0, count = 0.0
            let rad = 3
            for y in rad..<(h - rad) {
                for x in rad..<(w - rad) {
                    var seen: UInt8 = 0
                    for dy in -rad...rad {
                        for dx in -rad...rad {
                            let c = cls[(y + dy) * w + (x + dx)]
                            if c > 0 { seen |= 1 << (c - 1) }
                        }
                    }
                    if seen == 0b1111 { sumX += Double(x); sumY += Double(y); count += 1 }
                }
            }
            guard count > 0 else { return nil }
            // CARenderer composites bottom-up relative to the flipped
            // (Y-down) canvas — verified with an ENUM-BOTTOM placement
            // probe measuring y≈1. Flip so deltas are canvas-space Y-down.
            return CGPoint(x: sumX / count, y: Double(h - 1) - sumY / count)
        }
        guard let cornerBefore = quadrantCrossPoint() else {
            expect(false, "paused mid-block frame renders (quadrant cross found)")
            return
        }
        if let down = mouse(.leftMouseDown, at: start),
           let drag = mouse(.leftMouseDragged, at: end) {
            interaction.mouseDown(with: down)
            interaction.mouseDragged(with: drag)
        }
        await settle(0.2) // requestRender is coalesced to the next runloop turn
        let cornerMidDrag = quadrantCrossPoint()
        if let up = mouse(.leftMouseUp, at: end) { interaction.mouseUp(with: up) }
        await settle(0.2)
        if let cornerMidDrag {
            let dx = cornerMidDrag.x - cornerBefore.x
            let dy = cornerMidDrag.y - cornerBefore.y
            expect(abs(dx - 36) <= 3 && abs(dy - 40) <= 3,
                   String(format: "PAUSED mid-block drag moves the RENDERED card 1:1 before mouse-up (Δ %.0f, %.0f px, want 36, 40)", dx, dy))
        } else {
            expect(false, "mid-drag frame renders (quadrant cross found)")
        }
    }

    /// Bounding box of pixels matching the synthetic frame's quadrant colours
    /// — a structural read of where the CARD is, blind to background gradient
    /// and shadow (CLAUDE.md §3: structural assertion, not a mean).
    private static func cardBoundingBox(_ image: CGImage) -> CGRect? {
        let w = image.width, h = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil, width: w, height: h, bitsPerComponent: 8,
                  bytesPerRow: w * 4, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        // The four quadrant fills of PreviewParityHarness.syntheticVideoFrame.
        let targets: [(Double, Double, Double)] = [
            (0.35, 0.34, 0.84), (0.19, 0.69, 0.78),
            (0.91, 0.30, 0.44), (0.22, 0.72, 0.40),
        ]
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let r = Double(px[i]) / 255, g = Double(px[i + 1]) / 255, b = Double(px[i + 2]) / 255
                for (tr, tg, tb) in targets
                where abs(r - tr) < 0.10 && abs(g - tg) < 0.10 && abs(b - tb) < 0.10 {
                    if x < minX { minX = x }; if x > maxX { maxX = x }
                    if y < minY { minY = y }; if y > maxY { maxY = y }
                    break
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    @MainActor private static func settle(_ seconds: TimeInterval) async {
        let until = Date(timeIntervalSinceNow: seconds)
        while Date() < until {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
            await Task.yield()
        }
    }
}
