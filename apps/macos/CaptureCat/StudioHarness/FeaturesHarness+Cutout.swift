import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Background removal (the camera's person cutout). Three layers:
///
/// 1. Producer arithmetic — `CameraMaskConditioning` + `CameraMaskTrack
///    .Encoder` on a synthetic matte: the `.ccmask` bytes must be identical.
/// 2. The real producer — `CameraSegmenter.segment` (Vision person
///    segmentation) on a real camera clip: the header must match and the
///    matte must cover the same person (IoU / mean |Δ| — Vision runs on
///    different compute units per platform, so not byte-equal).
/// 3. Rendering — with the SAME mask, the cutout look's preview frame vs its
///    export frame on each platform (3c's relative bar), and the iOS export
///    vs the Mac's (3a's bar), with the camera on raw 4:2:0 on both sides
///    (`CAPTURECAT_EXPORT_SOURCE_YUV`, 3a).
///
/// The camera clip is a short stock clip bundled with iMovie
/// (Trailers/PreviewMovies/Teen/Movie-16.mov, 1.5 s of two people): read
/// from /Applications at gate time, never copied into the repository.
extension FeaturesHarness {
    enum CutoutFixture {
        static let defaultCamera = "/Applications/iMovie.app/Contents/Resources/Trailers/PreviewMovies/Teen/Movie-16.mov"
        static let camera = "camera.mov"
        static let screen = "screen.mov"
        static let projectID = UUID(uuidString: "4E4E0000-0000-4000-8000-00000000A400")!
        static let canvas = CGSize(width: 480, height: 270)
        static let scale: CGFloat = 2
        static let fps = 30
        /// The compared frame: the first. A paused preview shows the camera
        /// POSTER, which the compositor masks with mask frame 0 by design
        /// (`lookPosterImage`); the exporter masks each frame by its PTS —
        /// frame 0 is where both are the same input.
        static let frameIndex = 0
        static var time: TimeInterval { Double(frameIndex) / Double(fps) }
        /// Rendered cases: the plain bubble (control) and both looks.
        static let looks: [(name: String, look: CameraBubbleLook?)] = [("bubble", nil), ("cutout", .cutout), ("popOut", .popOut)]
        /// Producer comparison bars (Vision on two platforms): the person
        /// must be found in the same place.
        static let minMeanIoU = 0.95
        static let minFrameIoU = 0.90
        static let maxMeanAlphaDelta = 6.0

        /// The cutout project on `screen` + `camera` (mask beside the camera).
        static func project(screen: URL, camera: URL, cameraDuration: Double, look: CameraBubbleLook?) -> Project {
            let project = Project(id: projectID, name: "features-cutout", videoURL: screen,
                                  cameraVideoURL: camera, duration: cameraDuration)
            project.trimStart = 0
            project.trimEnd = cameraDuration
            let s = project.settings
            // Explicit sRGB background (the default gradient uses system
            // hues, a known iOS approximation outside this gate).
            s.backgroundType = .gradient
            s.gradientStartColor = CodableColor(red: 0.62, green: 0.28, blue: 0.86)
            s.gradientEndColor = CodableColor(red: 0.18, green: 0.47, blue: 0.96)
            s.showCamera = true
            s.cameraLook = look
            s.cameraSize = 220
            s.showWatermark = false; s.showSubtitles = false; s.showClickRipple = false
            s.motionBlur = false; s.showCursor = false
            s.introSlideStyle = .off; s.curtainUnveilCorner = .off
            s.exportSettings.resolution = .custom
            s.exportSettings.customWidth = Int(canvas.width * scale)
            s.exportSettings.customHeight = Int(canvas.height * scale)
            s.exportSettings.fps = fps
            s.exportSettings.collapseStaticSpans = false
            s.exportSettings.format = .mp4
            return project
        }
    }

    // MARK: - 1. Producer arithmetic

    /// A deterministic raw matte (a soft "head and shoulders" that drifts,
    /// with noise near the edge so the dead zone, hold and quantiser all
    /// act), conditioned and encoded the producer's way. Returns the bytes.
    static func conditionedSyntheticTrack(width: Int = 64, height: Int = 48, frames: Int = 24) throws -> Data {
        let encoder = CameraMaskTrack.Encoder(width: width, height: height,
                                              keyframeInterval: CameraMaskTrack.defaultKeyframeInterval)
        var previous: [UInt8]?
        var seed: UInt32 = 0x4E4E
        for f in 0..<frames {
            let cx = Double(width) * (0.4 + 0.2 * Double(f) / Double(frames))
            var alpha = [UInt8](repeating: 0, count: width * height)
            for y in 0..<height {
                for x in 0..<width {
                    let dx = (Double(x) + 0.5 - cx) / (Double(width) * 0.25)
                    let dy = (Double(y) + 0.5 - Double(height) * 0.65) / (Double(height) * 0.5)
                    let d = (dx * dx + dy * dy).squareRoot()
                    seed = seed &* 1_664_525 &+ 1_013_904_223
                    let noise = Double(Int(seed >> 24) - 128) / 128 * 9
                    let v = min(1, max(0, (1.1 - d) / 0.3)) * 255 + noise
                    alpha[y * width + x] = UInt8(min(255, max(0, v.rounded())))
                }
            }
            CameraMaskConditioning.condition(&alpha, previous: previous)
            previous = alpha
            try encoder.append(time: Double(f) / 30 + 0.0123, alpha: alpha)
        }
        return encoder.finish(sourceDuration: Double(frames) / 30, sourceByteSize: 123_456)
    }

    // MARK: - 2. The real producer

    struct MaskComparison {
        var headerEqual: Bool
        var headerDetail: String
        var meanIoU = 0.0
        var minIoU = 0.0
        var meanAlphaDelta = 255.0
        var coverage = (a: 0.0, b: 0.0)
    }

    static func compareMasks(_ a: CameraMaskTrack, _ b: CameraMaskTrack) -> MaskComparison {
        let ha = a.header, hb = b.header
        let timesEqual = a.index.map(\.time) == b.index.map(\.time)
        var result = MaskComparison(
            headerEqual: ha.width == hb.width && ha.height == hb.height && ha.frameCount == hb.frameCount
                && ha.keyframeInterval == hb.keyframeInterval && ha.sourceDuration == hb.sourceDuration
                && ha.sourceByteSize == hb.sourceByteSize && timesEqual,
            headerDetail: "\(ha.width)×\(ha.height) \(ha.frameCount) frames \(ha.sourceDuration) s \(Int(ha.sourceByteSize)) B"
                + " · \(hb.width)×\(hb.height) \(hb.frameCount) frames \(hb.sourceDuration) s \(Int(hb.sourceByteSize)) B"
                + (timesEqual ? "" : " · frame times differ"))
        guard ha.width == hb.width, ha.height == hb.height, ha.frameCount == hb.frameCount, ha.frameCount > 0 else {
            return result
        }
        let da = CameraMaskTrack.Decoder(track: a), db = CameraMaskTrack.Decoder(track: b)
        var iouSum = 0.0, iouMin = 1.0, deltaSum = 0.0, coverA = 0.0, coverB = 0.0
        for f in 0..<ha.frameCount {
            guard let fa = try? da.frame(f), let fb = try? db.frame(f) else { return result }
            var inter = 0, union = 0, delta = 0, ca = 0, cb = 0
            for i in 0..<fa.count {
                let ia = fa[i] > 127, ib = fb[i] > 127
                if ia { ca += 1 }
                if ib { cb += 1 }
                if ia && ib { inter += 1 }
                if ia || ib { union += 1 }
                delta += abs(Int(fa[i]) - Int(fb[i]))
            }
            let iou = union == 0 ? 1 : Double(inter) / Double(union)
            iouSum += iou
            iouMin = min(iouMin, iou)
            deltaSum += Double(delta) / Double(fa.count)
            coverA += Double(ca) / Double(fa.count)
            coverB += Double(cb) / Double(fa.count)
        }
        let n = Double(ha.frameCount)
        result.meanIoU = iouSum / n
        result.minIoU = iouMin
        result.meanAlphaDelta = deltaSum / n
        result.coverage = (coverA / n, coverB / n)
        return result
    }

    /// Vision's matte replayed from a mask track: frame `i` of `track` as the
    /// raw matte of decoded frame `i`, after `delay` (the work a frame takes).
    /// The producer conditioning is idempotent on conditioned frames, so the
    /// pipeline re-encodes `track` byte for byte — if everything around
    /// Vision (reader, frame times, conditioning, encoder, header) matches.
    static func replayMatte(_ track: CameraMaskTrack, delay: TimeInterval) -> CameraSegmenter.Matte {
        nonisolated final class Box: @unchecked Sendable {
            let lock = NSLock()
            let decoder: CameraMaskTrack.Decoder
            init(_ track: CameraMaskTrack) { decoder = CameraMaskTrack.Decoder(track: track) }
        }
        let box = Box(track)
        return { frame, _, width, height in
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            return try box.lock.withLock {
                guard width == box.decoder.track.header.width, height == box.decoder.track.header.height else {
                    throw CameraSegmenter.SegmentError(message: "replayed matte is \(box.decoder.track.header.width)×\(box.decoder.track.header.height), the pipeline wants \(width)×\(height)")
                }
                return try box.decoder.frame(frame)
            }
        }
    }

    /// Whether Vision's person segmentation runs here (it does not in the
    /// iOS Simulator: "E5RT is not supported").
    static func visionSegmentationAvailable(camera: URL) async -> (Bool, String) {
        let asset = AVURLAsset(url: camera)
        let generator = AVAssetImageGenerator(asset: asset)
        guard let image = try? await generator.image(at: .zero).image else { return (false, "no camera frame") }
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
            return (request.results?.first != nil, "ok")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    /// `mask-alpha` defect: the matte's soft edge thresholded away.
    static func damagedMask(_ track: CameraMaskTrack) throws -> Data {
        let h = track.header
        let decoder = CameraMaskTrack.Decoder(track: track)
        let encoder = CameraMaskTrack.Encoder(width: h.width, height: h.height, keyframeInterval: h.keyframeInterval)
        for (f, entry) in track.index.enumerated() {
            let alpha = try decoder.frame(f).map { $0 > 200 ? UInt8(255) : UInt8(0) }
            try encoder.append(time: entry.time, alpha: alpha)
        }
        return encoder.finish(sourceDuration: h.sourceDuration, sourceByteSize: h.sourceByteSize)
    }

    // MARK: - 3. Rendering

    struct RenderResult: Codable {
        var name: String
        var mean = 255.0
        var over8 = 1.0
        var maxDelta = 255
        /// Preview vs export inside the camera's box (where the look draws).
        var cameraMean: Double?
        /// How much the look changes the camera box against the plain bubble
        /// (export) — proof the look is really drawn.
        var lookEffect: Double?
        var error: String?
    }

    /// Bounding box (pixels, top-left origin) of what the look changed
    /// against the bubble in the export — the camera's box.
    static func cameraBox(bubble: CGImage, look: CGImage) -> CGRect? {
        guard let box = PreviewExportParityHarness.changedBox(on: look, off: bubble, threshold: 24) else { return nil }
        return CGRect(x: box.minX, y: box.minY, width: box.width, height: box.height)
    }

    /// Fills `cameraMean` / `lookEffect` for every look from the bubble's export.
    static func scoreCameraBoxes(_ results: inout [RenderResult], images: [String: (preview: CGImage, export: CGImage)]) {
        guard let bubble = images["bubble"]?.export else { return }
        for i in results.indices where results[i].name != "bubble" {
            guard let pair = images[results[i].name], let box = cameraBox(bubble: bubble, look: pair.export) else { continue }
            results[i].cameraMean = regionMean(pair.preview, pair.export, rect: box)
            results[i].lookEffect = regionMean(bubble, pair.export, rect: box)
        }
    }

    /// One look: the preview stepped at the export's frame times to the
    /// compared frame and captured at 2×, and the exporter's lossless tap of
    /// that frame. Writes `<name>-preview.png` / `<name>-export.png` to
    /// `out`. `mask` is what the preview is given; the exporter reads the
    /// file beside the camera itself.
    @MainActor
    static func renderCutout(name: String, project: Project, mask: CameraMaskTrack?, stage: PreviewExportStage,
                             screenPoster: PlatformImage, cameraPoster: PlatformImage, cameraAspect: CGFloat,
                             out: URL) async -> (result: RenderResult, preview: CGImage?, export: CGImage?) {
        var result = RenderResult(name: name)
        let fm = FileManager.default
        func input(_ t: TimeInterval) -> PreviewCompositorCore.FrameInput {
            PreviewCompositorCore.FrameInput(
                project: project, currentTime: t, isPlaying: false, cursorEvents: [],
                cursorCoordinateSize: .zero, videoSize: CGSize(width: 1280, height: 720),
                player: nil, cameraPlayer: nil, cameraPosterImage: cameraPoster,
                cameraVideoAspect: cameraAspect, videoPosterImage: screenPoster,
                cameraMask: mask)
        }
        let fps = Double(CutoutFixture.fps)
        for i in 0...CutoutFixture.frameIndex { stage.render(input(Double(i) / fps)) }
        await settle(0.3)
        stage.render(input(CutoutFixture.time))
        await settle(0.3)
        guard let preview = await stage.capture() else {
            result.error = "preview capture failed"
            return (result, nil, nil)
        }
        let tap = out.appendingPathComponent("tap-\(name)", isDirectory: true)
        try? fm.removeItem(at: tap)
        setenv("CAPTURECAT_EXPORT_FRAME_TAP", tap.path, 1)
        setenv("CAPTURECAT_EXPORT_FRAME_TAP_INDICES", "\(CutoutFixture.frameIndex)", 1)
        setenv("CAPTURECAT_EXPORT_SOURCE_YUV", "1", 1)
        defer {
            unsetenv("CAPTURECAT_EXPORT_FRAME_TAP"); unsetenv("CAPTURECAT_EXPORT_FRAME_TAP_INDICES")
            unsetenv("CAPTURECAT_EXPORT_SOURCE_YUV")
        }
        let movie = out.appendingPathComponent("export-\(name).mp4")
        do { try await VideoExporter().export(project: project, to: movie) } catch {
            result.error = "export failed: \(error)"
            return (result, preview, nil)
        }
        try? fm.removeItem(at: movie)
        guard let src = CGImageSourceCreateWithURL(
                  tap.appendingPathComponent(String(format: "%04d.png", CutoutFixture.frameIndex)) as CFURL, nil),
              let exported = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            result.error = "no tap frame"
            return (result, preview, nil)
        }
        writePNG(preview, out.appendingPathComponent("\(name)-preview.png"))
        writePNG(exported, out.appendingPathComponent("\(name)-export.png"))
        if let a = HarnessPixels.rgba(preview), let b = HarnessPixels.rgba(exported) {
            let score = ExportParityHarness.compare(a, b, index: CutoutFixture.frameIndex)
            result.mean = score.mean; result.over8 = score.over8; result.maxDelta = score.maxDelta
            a.deallocate(); b.deallocate()
        }
        return (result, preview, exported)
    }

    /// The screen and camera frames at the compared time, decoded the
    /// exporter's way on raw 4:2:0 (as the export below reads them), as the
    /// preview's posters.
    static func cutoutPosters(screen: URL, camera: URL) async -> (screen: PlatformImage, camera: PlatformImage, aspect: CGFloat)? {
        setenv("CAPTURECAT_EXPORT_SOURCE_YUV", "1", 1)
        defer { unsetenv("CAPTURECAT_EXPORT_SOURCE_YUV") }
        guard let s = await PreviewExportParityHarness.decodedFrame(screen, at: CutoutFixture.time),
              let c = await PreviewExportParityHarness.decodedFrame(camera, at: CutoutFixture.time) else { return nil }
        return (PreviewExportParityHarness.platformImage(s), PreviewExportParityHarness.platformImage(c),
                CGFloat(c.width) / CGFloat(max(1, c.height)))
    }

    /// Mean |Δ| inside a rectangle (pixels, top-left origin) — how much the
    /// look changes the camera region against the plain bubble.
    static func regionMean(_ a: CGImage, _ b: CGImage, rect: CGRect) -> Double {
        guard let pa = HarnessPixels.rgba(a), let pb = HarnessPixels.rgba(b),
              pa.width == pb.width, pa.height == pb.height else { return 0 }
        defer { pa.deallocate(); pb.deallocate() }
        let r = rect.integral.intersection(CGRect(x: 0, y: 0, width: pa.width, height: pa.height))
        guard !r.isEmpty else { return 0 }
        var total = 0, n = 0
        for y in Int(r.minY)..<Int(r.maxY) {
            let ra = pa.bytes + y * pa.bytesPerRow, rb = pb.bytes + y * pb.bytesPerRow
            for x in Int(r.minX)..<Int(r.maxX) {
                for c in 0..<3 { total += abs(Int(ra[x * 4 + c]) - Int(rb[x * 4 + c])) }
                n += 3
            }
        }
        return Double(total) / Double(max(1, n))
    }

    static func writePNG(_ image: CGImage, _ url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    static func loadPNG(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    @MainActor
    static func settle(_ seconds: Double) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            try? await Task.sleep(for: .milliseconds(30))
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }
}
