import AppKit
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// `CaptureCat --web-parity-fixtures <dir> [--only name1,name2]` — reference
/// frames for the WEB renderer's parity gate.
///
/// Writes SYNTHETIC fixture bundles (never user media): a generated moving
/// source movie (structured pattern + a moving bar + a 12-bit frame-index
/// barcode, so the web can verify WHICH source frame it sampled), a synthetic
/// cursor.json, optional camera movie, and a project.json exercising one
/// feature family. Each project is exported by the REAL `VideoExporter`
/// in-process (the `HeadlessRunner.performExport` path), and reference PNGs
/// are extracted from the exported file at listed OUTPUT frame times. Per
/// fixture: `<dir>/<name>/{project.json, recording.mp4, cursor.json,
/// camera.mp4?, frames/NNNN.png, fixture.json}`; plus `<dir>/manifest.json`.
///
/// The exporter's per-frame camera path is captured from its own
/// `CAPTURECAT_DUMP_CAMERA` diagnostic (print precision) and stored in
/// fixture.json — and compared against the web-vector camera oracle when it
/// is linked in (`WebParityFixtures.cameraOracle`).
///
/// Reference PNGs are DECODED from the exported HEVC file (lossy), converted
/// to 8-bit sRGB: the web gate must compare with a tolerance, not exactly.
/// Sandboxed: an unwritable `<dir>` lands in the container tmp (printed).
/// Never reached in a normal launch.
enum WebParityFixtures {
    /// Optional hook: the camera-motion cluster's verbatim oracle
    /// (`WebCameraPathOracle.cameraPath`). Returns per-frame
    /// [zoom, fx, fy, ox, oy, pitch, yaw, roll] for a project, or nil.
    nonisolated(unsafe) static var cameraOracle: ((Project, [Double], [Double], [CursorEvent], CGSize, [TimeInterval]) -> [[Double]])?

    static let outputFPS = 30
    static let sourceFPS: Int32 = 30

    struct Fixture {
        let name: String
        let description: String
        let features: [String]
        let duration: TimeInterval
        let sourceSize: CGSize
        let withCursor: Bool
        let withCamera: Bool
        /// Output frame indices to extract (clamped to the frame count).
        let frames: [Int]
        let configure: (Project) -> Void
    }

    static func run() -> Never {
        let args = CommandLine.arguments
        var requested: String?
        if let i = args.firstIndex(of: "--web-parity-fixtures"), args.indices.contains(i + 1),
           !args[i + 1].hasPrefix("--") {
            requested = (args[i + 1] as NSString).expandingTildeInPath
        }
        var only: Set<String>?
        if let i = args.firstIndex(of: "--only"), args.indices.contains(i + 1) {
            only = Set(args[i + 1].split(separator: ",").map { String($0) })
        }
        let dir = WebVectorsHarness.resolveOutputDirectory(requested, prefix: "capturecat-web-parity")
        print("WEB-PARITY dir=\(dir.path)")
        // Cross-check the web-vector camera oracle against the REAL exporter.
        cameraOracle = WebCameraPathOracle.cameraPathRows

        Task { @MainActor in
            var failures = 0
            var written: [WV] = []
            for fixture in fixtures where only?.contains(fixture.name) ?? true {
                do {
                    let summary = try await build(fixture, root: dir)
                    written.append(summary)
                } catch {
                    failures += 1
                    print("WEB-PARITY FAIL \(fixture.name): \(error.localizedDescription)")
                }
            }
            let manifest: WV = [
                "generator": "CaptureCat --web-parity-fixtures",
                "sourceCommit": "da569841c7b63175bffa46d897457f157224774d",
                "notes": .str("Reference frames are decoded from the REAL VideoExporter output (HEVC, lossy) and converted to 8-bit sRGB; compare with a tolerance. Output times follow VideoExporter.exportFrameTimes (1/600 s grid, truncated). Spatial settings are exported headless: canvasScale = 1 (previewCanvasSize = .zero)."),
                "outputFPS": .int(outputFPS),
                "fixtures": .arr(written),
            ]
            try? Data(manifest.serialized().utf8).write(to: dir.appendingPathComponent("manifest.json"))
            print("WEB-PARITY \(failures == 0 ? "OK" : "FAILED") fixtures=\(written.count) dir=\(dir.path)")
            exit(failures == 0 ? 0 : 1)
        }
        RunLoop.main.run()
        fatalError("unreachable")
    }

    // MARK: - Build one fixture

    struct FixtureError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @MainActor
    private static func build(_ f: Fixture, root: URL) async throws -> WV {
        let fm = FileManager.default
        let dir = root.appendingPathComponent(f.name, isDirectory: true)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir.appendingPathComponent("frames"), withIntermediateDirectories: true)

        // Media.
        let videoURL = dir.appendingPathComponent("recording.mp4")
        try await SyntheticMovie.write(to: videoURL, size: f.sourceSize, duration: f.duration,
                                       fps: sourceFPS, style: .screen)
        var cameraURL: URL?
        if f.withCamera {
            let url = dir.appendingPathComponent("camera.mp4")
            try await SyntheticMovie.write(to: url, size: CGSize(width: 640, height: 480), duration: f.duration,
                                           fps: sourceFPS, style: .camera)
            cameraURL = url
        }
        var cursorURL: URL?
        var cursorEventsRaw: [CursorEvent] = []
        let coordinateSize = CGSize(width: f.sourceSize.width / 2, height: f.sourceSize.height / 2)
        if f.withCursor {
            cursorEventsRaw = syntheticCursorPath(duration: f.duration, size: coordinateSize)
            let recording = CursorRecording(version: 2, coordinateWidth: coordinateSize.width,
                                            coordinateHeight: coordinateSize.height, events: cursorEventsRaw)
            let url = dir.appendingPathComponent("cursor.json")
            try JSONEncoder().encode(recording).write(to: url)
            cursorURL = url
        }

        // Project.
        let project = Project(
            id: fixtureID(f.name), name: f.name, videoURL: videoURL, cursorDataURL: cursorURL,
            cameraVideoURL: cameraURL, duration: f.duration, recordingSourceKind: .display)
        project.createdAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        project.trimStart = 0
        project.trimEnd = f.duration
        let s = project.settings
        // Pin everything a system default could shift (NSColor system colours
        // resolve per appearance) — literal sRGB only.
        s.gradientStartColor = CodableColor(red: 0.42, green: 0.26, blue: 0.93)
        s.gradientEndColor = CodableColor(red: 0.13, green: 0.62, blue: 0.98)
        s.solidColor = CodableColor(red: 0.09, green: 0.1, blue: 0.13)
        s.subtitleHighlightColor = CodableColor(red: 1, green: 0.84, blue: 0.04)
        s.exportSettings.resolution = .hd720
        s.exportSettings.fps = outputFPS
        s.exportSettings.quality = 1.0
        s.exportSettings.collapseStaticSpans = false
        s.exportSettings.format = .mp4
        s.showCamera = cameraURL != nil
        f.configure(project)
        let projectURL = dir.appendingPathComponent("project.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(project).write(to: projectURL)

        // Export with the REAL exporter, capturing its camera-path dump.
        let exportURL = dir.appendingPathComponent("export.mp4")
        let dumpURL = dir.appendingPathComponent("export-log.txt")
        setenv("CAPTURECAT_DUMP_CAMERA", "1", 1)
        // Reference frames come from the exporter's pre-encode tap (lossless):
        // a decoded HEVC frame carries compression noise no renderer can match.
        let tapDir = dir.appendingPathComponent("tap", isDirectory: true)
        setenv("CAPTURECAT_EXPORT_FRAME_TAP", tapDir.path, 1)
        setenv("CAPTURECAT_EXPORT_FRAME_TAP_INDICES", f.frames.map(String.init).joined(separator: ","), 1)
        defer {
            unsetenv("CAPTURECAT_EXPORT_FRAME_TAP")
            unsetenv("CAPTURECAT_EXPORT_FRAME_TAP_INDICES")
            try? fm.removeItem(at: tapDir)
        }
        let exporter = VideoExporter()
        try await captureStdout(to: dumpURL) {
            try await exporter.export(project: project, to: exportURL)
        }
        let tapped = (try? fm.contentsOfDirectory(atPath: tapDir.path).count) ?? 0
        print("WEB-PARITY \(f.name) reference frames: \(tapped) lossless tap(s) at \(tapDir.path)")
        let camDump = parseCameraDump((try? String(contentsOf: dumpURL, encoding: .utf8)) ?? "")

        // Frame times exactly as the exporter computes them.
        let asset = AVURLAsset(url: videoURL)
        let assetDuration = try await asset.load(.duration).seconds
        let trimStart = project.effectiveTrimStart
        let trimEnd = project.effectiveTrimEnd > 0 ? project.effectiveTrimEnd : assetDuration
        let timeMap = SpeedTimeMap(sourceStart: trimStart, sourceEnd: trimEnd, regions: project.speedRegions)
        let lastVisibleOutput = project.effectiveVideoClipSegments
            .map { timeMap.outputTime(forSource: $0.endTime) }
            .max() ?? timeMap.outputDuration
        let totalSeconds = max(0.0001, min(timeMap.outputDuration, lastVisibleOutput))
        let frameTimes = WebVectors.oracleExportFrameTimes(duration: totalSeconds, fps: outputFPS)
        let sourceTimes = frameTimes.map { timeMap.sourceTime(forOutput: $0.seconds) }

        // Extract reference frames at exact PTS.
        let outAsset = AVURLAsset(url: exportURL)
        let naturalSize = try await outAsset.loadTracks(withMediaType: .video).first?.load(.naturalSize) ?? .zero
        let generator = AVAssetImageGenerator(asset: outAsset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.appliesPreferredTrackTransform = true
        var frames: [WV] = []
        let indices = Array(Set(f.frames.map { min(max(0, $0), frameTimes.count - 1) })).sorted()
        for index in indices {
            let t = frameTimes[index]
            let name = String(format: "frames/%04d.png", index)
            let tapURL = tapDir.appendingPathComponent(String(format: "%04d.png", index))
            let cg: CGImage
            let actual: CMTime
            if let src = CGImageSourceCreateWithURL(tapURL as CFURL, nil),
               let tapped = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                (cg, actual) = (tapped, t)
            } else {
                (cg, actual) = try await generator.image(at: t)
            }
            try writeSRGBPNG(cg, to: dir.appendingPathComponent(name))
            frames.append([
                "index": .int(index),
                "outputTime": t.seconds.wv,
                "ptsValue": .int(Int(t.value)),
                "ptsTimescale": .int(Int(t.timescale)),
                "decodedTime": actual.seconds.wv,
                "sourceTime": sourceTimes[index].wv,
                "hasVisibleVideo": project.hasVisibleVideo(at: sourceTimes[index]).wv,
                "png": .str(name),
            ])
        }

        // Camera path: exporter dump (print precision) vs the oracle, if linked.
        var cameraCheck: WV = ["oracle": "not linked"]
        if let oracle = cameraOracle {
            // The exporter's processed cursor chain (same as VideoExporter).
            var events = cursorEventsRaw
            if s.smoothCursor { events = CursorSmoother(factor: s.smoothingFactor).smooth(events: events) }
            events = CursorSpringMath.apply(events: events, settings: s)
            events = CursorEndBehaviorMath.apply(events: events, trimEnd: project.effectiveTrimEnd,
                                                 loopToStart: s.cursorLoopToStart, stopAtEnd: s.cursorStopAtEnd)
            let resolved = CursorOverlayLayout.resolveCoordinateSize(recordedSize: f.withCursor ? coordinateSize : .zero,
                                                                     fallbackSourceSize: f.sourceSize)
            let keys = oracle(project, frameTimes.map(\.seconds), sourceTimes, events, resolved, [])
            var maxDelta = 0.0
            var compared = 0
            for (i, dumped) in camDump.enumerated() where i < keys.count {
                let k = keys[i]
                // zoom %.5f; focal/offset %.4f; tilt %.3f
                let tolerances = [5e-6, 5e-5, 5e-5, 5e-5, 5e-5, 5e-4, 5e-4, 5e-4]
                for j in 0..<8 {
                    let d = abs(k[j] - dumped[j + 1])
                    maxDelta = max(maxDelta, d / tolerances[j])
                }
                compared += 1
            }
            cameraCheck = [
                "oracle": "WebCameraPathOracle.cameraPath",
                "framesCompared": .int(compared),
                "frameCountMatches": .bool(camDump.count == keys.count),
                // ≤ 1 means every value agrees within the dump's print precision.
                "maxDeltaInPrintUnits": maxDelta.wv,
            ]
            print("WEB-PARITY \(f.name) camera oracle vs exporter: frames=\(compared)/\(camDump.count) maxDeltaInPrintUnits=\(String(format: "%.3f", maxDelta))")
        }

        try? fm.removeItem(at: dumpURL)
        let summary: WV = [
            "name": .str(f.name),
            "description": .str(f.description),
            "features": .arr(f.features.map { .str($0) }),
            "dir": .str(f.name),
            "project": "project.json",
            "media": [
                "video": "recording.mp4",
                "cursor": f.withCursor ? "cursor.json" : .null,
                "camera": f.withCamera ? "camera.mp4" : .null,
                "export": "export.mp4",
            ],
            "sourceSize": f.sourceSize.wv,
            "sourceFPS": .int(Int(sourceFPS)),
            "sourceDuration": f.duration.wv,
            "outputSize": naturalSize.wv,
            "outputFPS": .int(outputFPS),
            "totalSeconds": totalSeconds.wv,
            "frameCount": .int(frameTimes.count),
            "frames": .arr(frames),
            "exporterCameraPath": .arr(camDump.map { row in
                ["t": row[0].wv, "zoom": row[1].wv, "focalX": row[2].wv, "focalY": row[3].wv,
                 "offsetX": row[4].wv, "offsetY": row[5].wv, "tiltPitch": row[6].wv,
                 "tiltYaw": row[7].wv, "tiltRoll": row[8].wv]
            }),
            "cameraOracleCheck": cameraCheck,
        ]
        try Data(summary.serialized().utf8).write(to: dir.appendingPathComponent("fixture.json"))
        print("WEB-PARITY fixture=\(f.name) frames=\(frames.count)/\(frameTimes.count) output=\(Int(naturalSize.width))x\(Int(naturalSize.height)) total=\(String(format: "%.3f", totalSeconds))s camDump=\(camDump.count)")
        return summary
    }

    // MARK: - Helpers

    private static func fixtureID(_ name: String) -> UUID {
        var rng = WVRandom(seed: "fixture-\(name)")
        return rng.uuid()
    }

    /// Redirects fd 1 into `url` while `body` runs (the exporter's diagnostic
    /// `print`s land there), then restores it.
    @MainActor
    private static func captureStdout(to url: URL, _ body: () async throws -> Void) async throws {
        fflush(stdout)
        let saved = dup(STDOUT_FILENO)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard saved >= 0, fd >= 0 else {
            try await body()
            return
        }
        dup2(fd, STDOUT_FILENO)
        close(fd)
        do {
            try await body()
        } catch {
            fflush(stdout); dup2(saved, STDOUT_FILENO); close(saved)
            throw error
        }
        fflush(stdout)
        dup2(saved, STDOUT_FILENO)
        close(saved)
    }

    /// `CAM t=… z=… fx=… fy=… ox=… oy=… p=… yw=… r=…` → [t, z, fx, fy, ox, oy, p, yw, r]
    private static func parseCameraDump(_ text: String) -> [[Double]] {
        text.split(separator: "\n").compactMap { line -> [Double]? in
            guard line.hasPrefix("CAM ") else { return nil }
            let values = line.split(separator: " ").dropFirst().compactMap { part -> Double? in
                guard let eq = part.firstIndex(of: "=") else { return nil }
                return Double(part[part.index(after: eq)...])
            }
            return values.count == 9 ? values : nil
        }
    }

    private static func writeSRGBPNG(_ image: CGImage, to url: URL) throws {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw FixtureError(message: "sRGB context")
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let out = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw FixtureError(message: "png destination")
        }
        CGImageDestinationAddImage(dest, out, nil)
        guard CGImageDestinationFinalize(dest) else { throw FixtureError(message: "png write") }
    }

    /// A smooth figure-eight glide at 60 Hz with a few click runs (4 samples
    /// each) — coordinates in the recording's POINT space (half the pixels).
    static func syntheticCursorPath(duration: TimeInterval, size: CGSize) -> [CursorEvent] {
        var events: [CursorEvent] = []
        let count = Int(duration * 60)
        let clickStarts: Set<Int> = [Int(0.9 * 60), Int(2.4 * 60), Int(3.6 * 60), Int(4.8 * 60)]
        var clickLeft = 0
        for i in 0...count {
            let t = Double(i) / 60
            let u = t / max(duration, 0.001)
            let x = 0.5 + 0.32 * sin(2 * .pi * u * 1.0)
            let y = 0.5 + 0.28 * sin(2 * .pi * u * 2.0 + 0.6)
            if clickStarts.contains(i) { clickLeft = 4 }
            let isClick = clickLeft > 0
            if clickLeft > 0 { clickLeft -= 1 }
            events.append(CursorEvent(timestamp: t, x: CGFloat(x) * size.width, y: CGFloat(y) * size.height, isClick: isClick))
        }
        return events
    }
}

// MARK: - Synthetic moving movie

/// H.264 mp4 at a fixed frame rate: the parity harness's structured frame
/// (quadrants, grid, black band) plus a moving white bar and a 12-bit
/// frame-index barcode (bottom-right, 20 px cells, MSB first, white = 1)
/// framed by a white border, so a renderer can prove which source frame it
/// sampled. Tagged sRGB/709 like pre-P3 recordings.
enum SyntheticMovie {
    enum Style { case screen, camera }

    static func write(to url: URL, size: CGSize, duration: TimeInterval, fps: Int32, style: Style) async throws {
        try? FileManager.default.removeItem(at: url)
        let width = Int(size.width) - Int(size.width) % 2
        let height = Int(size.height) - Int(size.height) % 2
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: VideoColorTags.colorProperties(p3: false),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let base: CGImage? = style == .screen
            ? PreviewParityHarness.syntheticVideoFrame(size: CGSize(width: width, height: height))
                .cgImage(forProposedRect: nil, context: nil, hints: nil)
            : nil
        let frameCount = max(1, Int((duration * Double(fps)).rounded()))
        for index in 0..<frameCount {
            while !input.isReadyForMoreMediaData { try? await Task.sleep(nanoseconds: 2_000_000) }
            guard let pool = adaptor.pixelBufferPool else { throw WebParityFixtures.FixtureError(message: "no pool") }
            var out: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
            guard let buffer = out else { throw WebParityFixtures.FixtureError(message: "no buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let ctx = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                draw(ctx, width: width, height: height, index: index, frameCount: frameCount, base: base, style: style)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let pts = CMTime(value: CMTimeValue(index), timescale: fps)
            if !adaptor.append(buffer, withPresentationTime: pts) {
                throw WebParityFixtures.FixtureError(message: writer.error?.localizedDescription ?? "append failed")
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frameCount), timescale: fps))
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw WebParityFixtures.FixtureError(message: writer.error?.localizedDescription ?? "writer failed")
        }
    }

    private static func draw(_ ctx: CGContext, width: Int, height: Int, index: Int, frameCount: Int,
                             base: CGImage?, style: Style) {
        let w = CGFloat(width), h = CGFloat(height)
        if let base {
            ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
        } else {
            // Camera: warm backdrop + a "head" circle that drifts.
            ctx.setFillColor(CGColor(srgbRed: 0.78, green: 0.62, blue: 0.5, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let u = CGFloat(index) / CGFloat(max(1, frameCount - 1))
            ctx.setFillColor(CGColor(srgbRed: 0.25, green: 0.2, blue: 0.3, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: w * (0.3 + 0.1 * u), y: h * 0.25, width: w * 0.35, height: h * 0.5))
        }
        // Moving bar (left → right over the clip).
        let u = CGFloat(index) / CGFloat(max(1, frameCount - 1))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: (w - 16) * u, y: 0, width: 16, height: h * 0.18))
        // 12-bit frame index barcode, bottom-right (CG is Y-up: y small = bottom).
        let cell: CGFloat = style == .screen ? 20 : 12
        let bits = 12
        let originX = w - cell * CGFloat(bits) - cell
        let originY = cell / 2
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: originX - 4, y: originY - 4, width: cell * CGFloat(bits) + 8, height: cell + 8))
        for bit in 0..<bits {
            let on = (index >> (bits - 1 - bit)) & 1 == 1
            ctx.setFillColor(on ? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
                                : CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: originX + CGFloat(bit) * cell, y: originY, width: cell, height: cell))
        }
    }
}
