import AppKit
import AVFoundation
import CoreImage

/// Preview↔export CURSOR gate: `CaptureCat --cursor-export-parity`.
///
/// The only cursor checks the other gates run are preview-vs-preview (hotspot
/// pinning, slider response) — nothing ever compared the arrow the editor
/// shows against the arrow the exporter burns in, which is how the export
/// shipped a visibly smaller cursor while every gate was green.
///
/// This harness builds ONE deterministic project (still movie + saved cursor
/// recording), then measures the drawn sprite on both sides the same way:
/// render the frame with `showCursor` on and off, diff, and take the bounding
/// box of every pixel that moved by more than the shadow can move it. The
/// preview is snapshotted at 2x from a 960x540 pane, so its capture is the
/// SAME 1920x1080 pixel grid the 1080p export writes — the two boxes must
/// match in size (and position) to within antialiasing.
///
/// Never reached in a normal launch.
enum CursorExportParityHarness {
    struct Case {
        let name: String
        /// Recorded cursor coordinate space. `.zero` exercises the legacy
        /// fallback (source pixels / 2).
        let coordinateSize: CGSize
        let cursorScale: Double
        let style: ProjectSettings.CursorStyle
        /// Cursor position as a fraction of the coordinate space (Y-down).
        let fraction: CGPoint
    }

    struct Box: CustomStringConvertible {
        let minX: Int, minY: Int, maxX: Int, maxY: Int
        var width: Int { maxX - minX + 1 }
        var height: Int { maxY - minY + 1 }
        var description: String { "x=\(minX)…\(maxX) y=\(minY)…\(maxY) \(width)×\(height)" }
        func mirroredVertically(height: Int) -> Box {
            Box(minX: minX, minY: height - 1 - maxY, maxX: maxX, maxY: height - 1 - minY)
        }
        /// The same box on a 2× pixel grid (a 1× pixel spans two 2× pixels).
        var doubled: Box { Box(minX: minX * 2, minY: minY * 2, maxX: maxX * 2 + 1, maxY: maxY * 2 + 1) }
    }

    static func run() -> Never {
        // Harnesses run before main.swift builds the app object.
        _ = NSApplication.shared
        Task { @MainActor in
            let code: Int32
            do { code = try await gate() } catch {
                print("CURSOR-EXPORT-PARITY FAILED: \(error.localizedDescription)")
                code = 1
            }
            exit(code)
        }
        RunLoop.main.run()
        fatalError("unreachable")
    }

    // MARK: - Gate

    @MainActor
    private static func gate() async throws -> Int32 {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("capturecat-cursor-export-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        print("CAPTUREDIR \(dir.path)")
        var failures = 0

        // Structural check on the exporter's sprite raster itself: asking for
        // an N× pixel density must produce the 1× sprite's opaque footprint
        // scaled by N, not a 1× sprite parked in one corner of an N× bitmap
        // (the shipped defect — the bitmap context's CTM was fixed before the
        // point size was assigned, so the export scaled a mostly-transparent
        // bitmap into the layout rect and the visible arrow came out
        // 1/rasterScale of the preview's). Measured against each style's own
        // 1× footprint so art with a wide transparent margin (the system
        // pointing hand) is judged by the same rule as the tight vector arrow.
        for (style, scale) in [(ProjectSettings.CursorStyle.system, CGFloat(3.75)),
                               (.inverted, 2.5), (.dot, 7.5), (.hand, 3.0)] {
            let base = CursorStyleProvider.asset(for: style).image.size
            guard let one = CursorStyleProvider.rasterizedCGImage(for: style, pixelSize: base),
                  let oneBox = opaqueBox(one),
                  let big = CursorStyleProvider.rasterizedCGImage(
                      for: style, pixelSize: CGSize(width: base.width * scale, height: base.height * scale)),
                  let bigBox = opaqueBox(big) else {
                print("FAIL raster-density \(style) no raster")
                failures += 1
                continue
            }
            let wantW = Double(oneBox.width) * scale, wantH = Double(oneBox.height) * scale
            // Antialiased edges at two densities: one pixel per side, plus the
            // rounding of the 1× footprint itself scaled up.
            let tol = 2.0 + scale
            let ok = abs(Double(bigBox.width) - wantW) <= tol && abs(Double(bigBox.height) - wantH) <= tol
            print(String(format: "%@ raster-density %@ ×%.2f 1x-opaque=%d×%d %@-opaque=%d×%d want≈%.0f×%.0f",
                         ok ? "PASS" : "FAIL", "\(style)", scale, oneBox.width, oneBox.height,
                         "\(scale)", bigBox.width, bigBox.height, wantW, wantH))
            if !ok { failures += 1 }
        }

        // 16:9 source so the default `.widescreen` aspect letterboxes exactly
        // — the preview pane below is then a uniform 0.5× of the 1080p output.
        let naturalSize = CGSize(width: 1920, height: 1080)
        let frame = PreviewParityHarness.syntheticVideoFrame(size: naturalSize)
        guard let cgFrame = frame.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            print("CURSOR-EXPORT-PARITY FAILED: fixture frame")
            return 1
        }
        let duration: TimeInterval = 2
        let sourceURL = dir.appendingPathComponent("source.mp4")
        _ = try await StillMovieWriter.write(image: cgFrame, to: sourceURL, duration: duration)
        let sampleTime = 1.0

        let paneSize = CGSize(width: 960, height: 540)
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: paneSize.width, height: paneSize.height),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.title = "CaptureCat Cursor Export Gate"
        window.appearance = NSAppearance(named: .darkAqua)
        let container = FlippedContainer(frame: NSRect(origin: .zero, size: paneSize))
        container.wantsLayer = true
        let compositor = PreviewCompositorView(frame: NSRect(origin: .zero, size: paneSize))
        compositor.suppressImplicitAnimation = true
        compositor.rasterScaleOverride = 2
        container.addSubview(compositor)
        window.contentView = container
        window.orderFrontRegardless()
        await settle(0.3)

        let cases: [Case] = [
            Case(name: "retina-1.5x", coordinateSize: CGSize(width: 960, height: 540),
                 cursorScale: 1.5, style: .system, fraction: CGPoint(x: 0.30, y: 0.30)),
            Case(name: "1x-display-1.5x", coordinateSize: naturalSize,
                 cursorScale: 1.5, style: .system, fraction: CGPoint(x: 0.70, y: 0.30)),
            Case(name: "fallback-space-1.0x", coordinateSize: .zero,
                 cursorScale: 1.0, style: .inverted, fraction: CGPoint(x: 0.30, y: 0.72)),
            Case(name: "retina-3.0x-hand", coordinateSize: CGSize(width: 960, height: 540),
                 cursorScale: 3.0, style: .hand, fraction: CGPoint(x: 0.68, y: 0.70)),
        ]

        for c in cases {
            let project = PreviewParityHarness.makeFixtureProject(duration: duration)
            project.videoURL = sourceURL
            let s = project.settings
            s.showDeviceFrame = false
            s.showCamera = false
            s.showWatermark = false
            s.showSubtitles = false
            s.showClickRipple = false
            s.cursorFluidEnabled = false
            s.smoothCursor = false
            s.autoHideCursor = false
            s.cursorTilt = 0
            s.cursorStretch = 0
            s.cursorDrag = 0
            s.cursorStyle = c.style
            s.cursorScale = c.cursorScale
            s.exportSettings.resolution = .hd1080
            s.exportSettings.fps = 30
            s.exportSettings.collapseStaticSpans = false
            project.zoomRegions = []
            project.tiltRegions = []

            // Stationary cursor for the whole clip, 30 Hz, so the interpolated
            // position is identical at any sample time on either side.
            let space = CursorOverlayLayout.resolveCoordinateSize(
                recordedSize: c.coordinateSize, fallbackSourceSize: naturalSize)
            let point = CGPoint(x: space.width * c.fraction.x, y: space.height * c.fraction.y)
            var events: [CursorEvent] = []
            var t: TimeInterval = 0
            while t <= duration + 0.05 {
                events.append(CursorEvent(timestamp: t, x: point.x, y: point.y, isClick: false))
                t += 1.0 / 30.0
            }
            let recording = CursorRecording(
                version: 2,
                coordinateWidth: c.coordinateSize.width,
                coordinateHeight: c.coordinateSize.height,
                events: events
            )
            let cursorURL = dir.appendingPathComponent("\(c.name)-cursor.json")
            try JSONEncoder().encode(recording).write(to: cursorURL)
            project.cursorDataURL = cursorURL

            // ── Preview: 960×540 pane snapshot; the 1080p export is exactly
            //    2× of it, so preview boxes are doubled before comparing ───────
            func previewInput() -> PreviewCompositorView.FrameInput {
                PreviewCompositorView.FrameInput(
                    project: project,
                    currentTime: sampleTime,
                    isPlaying: false,
                    cursorEvents: events,
                    cursorCoordinateSize: c.coordinateSize,
                    videoSize: naturalSize,
                    player: nil,
                    cameraPlayer: nil,
                    cameraPosterImage: nil,
                    cameraVideoAspect: 4.0 / 3.0,
                    videoPosterImage: frame
                )
            }
            func capturePreview() async -> CGImage? {
                compositor.schedule(previewInput())
                await settle(0.3)
                compositor.schedule(previewInput())
                await settle(0.3)
                guard let layer = container.layer else { return nil }
                return CARendererSnapshot.render(layer: layer, size: container.bounds.size, scale: 1)
            }
            s.showCursor = true
            guard let previewOn = await capturePreview() else {
                print("FAIL \(c.name) preview capture (cursor on)")
                failures += 1
                continue
            }
            let previewVideoRect = compositor.debugVideoRect()
            s.showCursor = false
            guard let previewOff = await capturePreview() else {
                print("FAIL \(c.name) preview capture (cursor off)")
                failures += 1
                continue
            }
            savePNG(previewOn, dir.appendingPathComponent("\(c.name)-preview.png"))

            // ── Export: real VideoExporter pass, first-second frame ─────────
            func exportFrame(suffix: String) async throws -> CGImage {
                let url = dir.appendingPathComponent("\(c.name)-\(suffix).mp4")
                let exporter = VideoExporter()
                try await exporter.export(project: project, to: url)
                let asset = AVURLAsset(url: url)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                let time = CMTime(seconds: sampleTime, preferredTimescale: 600)
                return try await generator.image(at: time).image
            }
            s.showCursor = true
            let exportOn = try await exportFrame(suffix: "export-on")
            s.showCursor = false
            let exportOff = try await exportFrame(suffix: "export-off")
            savePNG(exportOn, dir.appendingPathComponent("\(c.name)-export.png"))

            // ── Measure ────────────────────────────────────────────────────
            guard exportOn.width == previewOn.width * 2, exportOn.height == previewOn.height * 2 else {
                print("FAIL \(c.name) frame size preview=\(previewOn.width)×\(previewOn.height) export=\(exportOn.width)×\(exportOn.height)")
                failures += 1
                continue
            }
            // CARenderer reads its texture Y-up, so the offscreen preview
            // capture is a vertical mirror of the on-screen frame (the parity
            // goldens carry the same mirror). Undo it before comparing rows.
            guard let previewBox = changedBox(on: previewOn, off: previewOff)
                    .map({ $0.mirroredVertically(height: previewOn.height).doubled }),
                  let exportBox = changedBox(on: exportOn, off: exportOff) else {
                print("FAIL \(c.name) cursor not found preview=\(String(describing: changedBox(on: previewOn, off: previewOff))) export=\(String(describing: changedBox(on: exportOn, off: exportOff)))")
                failures += 1
                continue
            }

            // Analytic size the shared layout predicts from the export's own
            // inputs — printed so a reader can tell WHICH side drifted.
            let asset = CursorStyleProvider.asset(for: c.style)
            let expected: String = {
                guard let rect = previewVideoRect else { return "n/a" }
                let pointToView = min(rect.width * 2 / space.width, rect.height * 2 / space.height) // preview rect is 1×
                let w = asset.image.size.width * CGFloat(c.cursorScale) * pointToView
                let h = asset.image.size.height * CGFloat(c.cursorScale) * pointToView
                return String(format: "%.1f×%.1f", w, h)
            }()

            let dw = abs(previewBox.width - exportBox.width)
            let dh = abs(previewBox.height - exportBox.height)
            let dx = abs(previewBox.minX - exportBox.minX)
            let dy = abs(previewBox.minY - exportBox.minY)
            // The preview box is measured on the 1× grid then doubled, so one
            // antialiased edge per side there is 4px here; position gets a
            // little more because the two rasterizers round the hotspot
            // differently.
            let sizeOK = dw <= 4 && dh <= 4
            let positionOK = dx <= 6 && dy <= 6
            let ratio = Double(exportBox.height) / Double(max(1, previewBox.height))
            print(String(
                format: "%@ %@ preview[%@] export[%@] expected=%@ Δsize=(%d,%d) Δpos=(%d,%d) export/preview=%.3f",
                (sizeOK && positionOK) ? "PASS" : "FAIL", c.name,
                previewBox.description, exportBox.description, expected,
                dw, dh, dx, dy, ratio
            ))
            if !(sizeOK && positionOK) { failures += 1 }
        }

        print(failures == 0 ? "CURSOR-EXPORT-PARITY PASS" : "CURSOR-EXPORT-PARITY FAIL count=\(failures)")
        return failures == 0 ? 0 : 1
    }

    // MARK: - Pixels

    /// Bounding box of pixels whose colour moved by more than the cursor's
    /// shadow can move them (0.3 opacity over the brightest fixture channel
    /// is ~65/255), i.e. the sprite's own opaque pixels.
    private static func changedBox(on: CGImage, off: CGImage, threshold: Int = 100) -> Box? {
        guard let a = rgba(on), let b = rgba(off), a.count == b.count else { return nil }
        let w = on.width, h = on.height
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<h {
            let row = y * w * 4
            for x in 0..<w {
                let i = row + x * 4
                let d = max(abs(Int(a[i]) - Int(b[i])),
                            abs(Int(a[i + 1]) - Int(b[i + 1])),
                            abs(Int(a[i + 2]) - Int(b[i + 2])))
                if d > threshold {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= 0 else { return nil }
        return Box(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }

    /// Bounding box of the at-least-half-covered pixels of a sprite raster.
    /// (Faint antialiased fringe pixels would let a 1× circle "fill" its
    /// whole bitmap and skew the density ratio.)
    private static func opaqueBox(_ image: CGImage) -> Box? {
        guard let a = rgba(image) else { return nil }
        let w = image.width, h = image.height
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where a[(y * w + x) * 4 + 3] >= 128 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return Box(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }

    /// Straight RGBA8 (sRGB, Y-down) readback regardless of the source
    /// image's byte order — the CARenderer texture is BGRA-little, the
    /// decoded export frame is whatever VideoToolbox hands back.
    private static func rgba(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                      | CGBitmapInfo.byteOrder32Big.rawValue
              ) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return data
    }

    private static func savePNG(_ image: CGImage, _ url: URL) {
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func settle(_ seconds: TimeInterval) async {
        let until = Date(timeIntervalSinceNow: seconds)
        while Date() < until {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
            await Task.yield()
        }
    }
}
