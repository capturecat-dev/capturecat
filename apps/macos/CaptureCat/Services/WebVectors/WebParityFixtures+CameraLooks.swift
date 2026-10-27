import AppKit
import AVFoundation
import CoreGraphics
import ImageIO

/// Parity fixture `14-camera-looks` support (docs/camera-cutout.md §8): the
/// synthetic person mask written beside the synthetic camera with THIS app's
/// `.ccmask` encoder (the web reads it from the fixture folder as
/// `camera-mask.ccmask`), and a STRUCTURAL check on the real exporter's
/// output — a settled cutout frame must show the camera inside the
/// silhouette and the untouched screen outside it (pixel-exact against a
/// camera-less export of the same frame), with a self-test proving the
/// predicate rejects an unmasked bubble.
extension WebParityFixtures {
    /// The synthetic silhouette — a "head" over the synthetic camera's drifting
    /// dark ellipse plus "shoulders" along the bottom edge — as an alpha in
    /// 0…1 at camera-image unit coords (Y-down, unmirrored). `u` is the clip
    /// progress 0…1 (same drift as SyntheticMovie's camera ellipse).
    static func syntheticSilhouette(x: Double, y: Double, progress u: Double) -> (alpha: Double, distance: Double) {
        let cx = 0.475 + 0.1 * u
        let hx = (x - cx) / 0.2, hy = (y - 0.5) / 0.3
        let sx = (x - cx) / 0.38, sy = (y - 1.0) / 0.28
        let d = min((hx * hx + hy * hy).squareRoot(), (sx * sx + sy * sy).squareRoot())
        return (min(1, max(0, (1.04 - d) / 0.08)), d)
    }

    /// Writes `camera-mask.ccmask` beside `cameraURL` against that file
    /// itself: one mask frame per DEMUXED camera sample at its PTS, the
    /// header's sourceByteSize = the file's size and sourceDuration = the end
    /// of its last frame (contract §6) — so the web reads it as fresh. The
    /// silhouette progress for sample i is i / (count − 1), matching
    /// SyntheticMovie's drift. keyframeInterval as the app writes it.
    static func writeSyntheticCameraMask(cameraURL: URL) async throws {
        let asset = AVURLAsset(url: cameraURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw FixtureError(message: "camera mask: no video track")
        }
        // DECODED samples, like the exporter's camera reader and the
        // segmentation job: their PTS has the edit list applied. (A
        // passthrough read returns raw media PTS — for this H.264 file that is
        // every frame +2 frames of composition offset, and the mask would
        // then pair each frame with its neighbour's silhouette.)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw FixtureError(message: "camera mask: cannot read camera") }
        var samples: [(pts: Double, end: Double)] = []
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            samples.append((pts, CameraSegmenter.frameEnd(
                pts: pts, duration: CMTimeGetSeconds(CMSampleBufferGetDuration(sample)),
                previousPTS: samples.last?.pts, fps: Double(sourceFPS))))
        }
        samples.sort { $0.pts < $1.pts }
        guard !samples.isEmpty else { throw FixtureError(message: "camera mask: no samples") }
        let natural = try await track.load(.naturalSize)
        let size = CameraMaskTrack.maskSize(cameraAspect: Double(natural.width / natural.height))
        let bytes = ((try FileManager.default.attributesOfItem(atPath: cameraURL.path))[.size] as? NSNumber)?.doubleValue ?? 0
        let encoder = CameraMaskTrack.Encoder(width: size.width, height: size.height)
        var previousAlpha: [UInt8]?
        for (index, sample) in samples.enumerated() {
            let u = Double(index) / Double(max(1, samples.count - 1))
            var alpha = [UInt8](repeating: 0, count: size.width * size.height)
            for py in 0..<size.height {
                for px in 0..<size.width {
                    let a = syntheticSilhouette(x: (Double(px) + 0.5) / Double(size.width),
                                                y: (Double(py) + 0.5) / Double(size.height), progress: u).alpha
                    alpha[py * size.width + px] = UInt8((a * 255).rounded())
                }
            }
            // Written as a producer writes (contract §6).
            CameraMaskConditioning.condition(&alpha, previous: previousAlpha)
            previousAlpha = alpha
            try encoder.append(time: sample.pts, alpha: alpha)
        }
        let data = encoder.finish(sourceDuration: samples.last!.end, sourceByteSize: bytes)
        try data.write(to: CameraMaskTrack.url(besideCamera: cameraURL), options: .atomic)
        let assetDuration = CMTimeGetSeconds(try await asset.load(.duration))
        print("WEB-PARITY camera mask: \(samples.count) frames \(size.width)x\(size.height), \(data.count) B (\(data.count / max(1, samples.count)) B/frame), sourceDuration \(samples.last!.end) vs asset \(assetDuration), fresh=\(CameraMaskTrack.isFresh(try CameraMaskTrack(data: data).header, cameraByteSize: Int64(bytes), cameraDuration: assetDuration))")
    }

    private static func loadPixels(_ url: URL) -> HarnessPixels.Pixels? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return HarnessPixels.rgba(image)
    }

    /// Exports `project` again WITHOUT the camera, taps `frameIndex`, and
    /// checks the settled-cutout frame against it (see the type comment).
    @MainActor
    static func verifySettledCutout(
        project: Project, fixtureDir: URL, frameIndex: Int, plainBubbleFrameIndex: Int
    ) async throws -> WV {
        // Camera-less reference of the same frame (lossless tap).
        let reference = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        reference.settings.showCamera = false
        let refTap = fixtureDir.appendingPathComponent("ref-tap", isDirectory: true)
        try? FileManager.default.removeItem(at: refTap)
        setenv("CAPTURECAT_EXPORT_FRAME_TAP", refTap.path, 1)
        setenv("CAPTURECAT_EXPORT_FRAME_TAP_INDICES", "\(frameIndex)", 1)
        defer {
            unsetenv("CAPTURECAT_EXPORT_FRAME_TAP")
            unsetenv("CAPTURECAT_EXPORT_FRAME_TAP_INDICES")
            try? FileManager.default.removeItem(at: refTap)
        }
        let refMovie = fixtureDir.appendingPathComponent("ref-export.mp4")
        defer { try? FileManager.default.removeItem(at: refMovie) }
        try await VideoExporter().export(project: reference, to: refMovie)
        guard let bare = loadPixels(refTap.appendingPathComponent(String(format: "%04d.png", frameIndex))),
              let look = loadPixels(fixtureDir.appendingPathComponent(String(format: "frames/%04d.png", frameIndex))),
              let plain = loadPixels(fixtureDir.appendingPathComponent(String(format: "frames/%04d.png", plainBubbleFrameIndex))),
              bare.width == look.width, bare.height == look.height else {
            throw FixtureError(message: "camera-looks check: reference frames missing")
        }
        defer { bare.deallocate(); look.deallocate(); plain.deallocate() }

        // The bubble rect exactly as the exporter places it (headless:
        // canvasScale 1, no zoom regions → zoom 1), flipped to PNG rows.
        let s = project.settings
        let output = CGSize(width: bare.width, height: bare.height)
        let fit = ReactiveCameraLayout.canvasFitScale(for: output)
        let aspect = ReactiveCameraLayout.shapeAspect(shape: s.cameraShape, videoAspect: 640.0 / 480.0,
                                                      orientation: s.cameraOrientation)
        let upRect = ReactiveCameraLayout.cameraRect(
            in: CGRect(origin: .zero, size: output), basePosition: s.cameraPosition,
            customPosition: s.cameraCustomX.flatMap { x in s.cameraCustomY.map { CGPoint(x: x, y: $0) } },
            baseSize: Double(max(1, s.effectiveCameraSize * fit)), zoom: 1,
            padding: Double(12 * fit), aspect: aspect, yAxisIsUp: true)
        let b = CGRect(x: upRect.minX, y: output.height - upRect.maxY, width: upRect.width, height: upRect.height)
        let person = CameraCutoutMath.aspectFill(aspect: 640.0 / 480.0, in: b)
        // The camera sample drawn at this output frame is sample `frameIndex`
        // (30 fps source and output, no trim/speed in this fixture).
        let cameraFrames = max(1, Int((project.duration * Double(sourceFPS)).rounded()))
        let u = Double(frameIndex) / Double(max(1, cameraFrames - 1))
        var inside: [(Int, Int)] = [], outside: [(Int, Int)] = []
        for y in stride(from: Int(b.minY) + 3, to: Int(b.maxY) - 3, by: 2) {
            for x in stride(from: Int(b.minX) + 3, to: Int(b.maxX) - 3, by: 2) {
                var cu = (Double(x) + 0.5 - person.minX) / person.width
                let cv = (Double(y) + 0.5 - person.minY) / person.height
                if s.cameraMirrored { cu = 1 - cu } // the mask is mirrored with the frame
                let d = syntheticSilhouette(x: cu, y: cv, progress: u).distance
                if d < 0.85 { inside.append((x, y)) } else if d > 1.2 { outside.append((x, y)) }
            }
        }
        func px(_ p: HarnessPixels.Pixels, _ x: Int, _ y: Int) -> (Int, Int, Int) {
            let q = p.bytes + y * p.bytesPerRow + x * 4
            return (Int(q[0]), Int(q[1]), Int(q[2]))
        }
        func delta(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Int {
            max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2))
        }
        func holds(_ frame: HarnessPixels.Pixels) -> (ok: Bool, clear: Double, opaque: Double) {
            let clear = Double(outside.filter { delta(px(frame, $0.0, $0.1), px(bare, $0.0, $0.1)) <= 3 }.count)
                / Double(max(1, outside.count))
            let opaque = Double(inside.filter { delta(px(frame, $0.0, $0.1), px(bare, $0.0, $0.1)) > 12 }.count)
                / Double(max(1, inside.count))
            return (inside.count >= 100 && outside.count >= 100 && clear >= 0.98 && opaque >= 0.85, clear, opaque)
        }
        let settled = holds(look)
        // Self-test: the plain bubble (an UNMASKED camera in the same rect)
        // must fail the same predicate, or the predicate proves nothing.
        let defect = holds(plain)
        print(String(format: "WEB-PARITY camera-looks structural: cutout frame %d inside n=%d opaque %.3f · outside n=%d clear %.3f → %@; self-test (unmasked bubble frame %d) clear %.3f → %@",
                     frameIndex, inside.count, settled.opaque, outside.count, settled.clear, settled.ok ? "PASS" : "FAIL",
                     plainBubbleFrameIndex, defect.clear, defect.ok ? "NOT TRIPPED (FAIL)" : "tripped (PASS)"))
        guard settled.ok, !defect.ok else {
            throw FixtureError(message: "camera-looks structural check failed (cutout ok=\(settled.ok), unmasked self-test tripped=\(!defect.ok))")
        }
        return [
            "frameIndex": .int(frameIndex), "bubbleRectYDown": b.wv,
            "insideSamples": .int(inside.count), "outsideSamples": .int(outside.count),
            "outsideMatchesCameraless": settled.clear.wv, "insideCovered": settled.opaque.wv,
            "selfTestUnmaskedOutsideMatches": defect.clear.wv,
        ]
    }
}
