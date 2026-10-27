import AppKit
import AVFoundation
import CoreImage
import Vision

/// `CaptureCat --camera-mask-bench <camera.mov> --variants` — producer-side
/// size experiments on a REAL Vision matte: segments a copy of the file once
/// (keeping every raw matte), then re-produces the track under each candidate
/// (resolution × `CameraMaskConditioning.Rule`) and reports MB/min, how many
/// frames became deltas, and the alpha error against the unconditioned 288-row
/// matte. A contact sheet (bubble-sized cutout + a 2× zoom on the head edge,
/// one row per candidate, all at the SAME settled frame, through the shared
/// `CameraStyleMath.maskedImage`) is printed as base64 PNG between
/// `CAMERA-MASK-BENCH-PNG-BEGIN/END` (the sandboxed app can only write into
/// its own container). Never reached in a normal launch.
extension CameraMaskBenchHarness {
    struct Variant {
        let height: Int
        let rule: CameraMaskConditioning.Rule
        var kfi = 15
        var label: String { "h\(height) \(rule) k\(kfi)" }
    }

    static let variants: [Variant] = [
        Variant(height: 288, rule: .none),
        Variant(height: 288, rule: .init(deadZone: 12, levels: 8, hold: 24), kfi: 30),
        Variant(height: 288, rule: .init(deadZone: 16, levels: 8, hold: 32), kfi: 30),
        Variant(height: 288, rule: .init(deadZone: 16, levels: 4, hold: 40), kfi: 30),
        Variant(height: 240, rule: .init(deadZone: 16, levels: 8, hold: 32), kfi: 30),
        Variant(height: 216, rule: .init(deadZone: 16, levels: 8, hold: 32), kfi: 30),
        Variant(height: 192, rule: .init(deadZone: 12, levels: 8, hold: 24), kfi: 30),
        Variant(height: 192, rule: .init(deadZone: 16, levels: 8, hold: 32), kfi: 30),
        Variant(height: 192, rule: .init(deadZone: 16, levels: 8, hold: 32), kfi: 60),
    ]

    private struct RawMatte {
        let pts: Double
        let bytes: [UInt8]
    }

    @MainActor
    static func executeVariants(source: URL) async -> Bool {
        let fm = FileManager.default
        let work = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("capturecat-mask-variants-\(UUID().uuidString.prefix(6))", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            let copy = work.appendingPathComponent("camera.\(source.pathExtension.isEmpty ? "mov" : source.pathExtension)")
            try fm.copyItem(at: source, to: copy)
            let result = try await Task.detached(priority: .userInitiated) { try await segmentRaw(copy) }.value
            let (mattes, mw, mh, natural, duration, snapshot, snapIndex) = result
            let aspect = Double(natural.width / natural.height)
            let minutes = max(1e-9, duration / 60)
            print("CAMERA-MASK-BENCH variants: \(mattes.count) frames, Vision matte \(mw)x\(mh), camera \(Int(natural.width))x\(Int(natural.height)), \(String(format: "%.2f", duration)) s, snapshot frame \(snapIndex)")

            // Reference for the error column: unconditioned 288-row alpha.
            let refSize = CameraMaskTrack.maskSize(cameraAspect: aspect)
            let reference = mattes[snapIndex].bytes.withUnsafeBytes {
                CameraSegmenter.resample($0.baseAddress!, width: mw, height: mh, rowBytes: mw,
                                         toWidth: refSize.width, toHeight: refSize.height)
            }

            var rows: [(label: String, alpha: [UInt8], w: Int, h: Int)] = []
            print("CAMERA-MASK-BENCH | variant | size | bytes | B/frame | MB/min | deltas | mean |Δα| | p99 |Δα| |")
            for v in variants {
                let w = min(Int((Double(v.height) * aspect).rounded()), Int((512.0 * Double(v.height) / 288).rounded()))
                let encoder = CameraMaskTrack.Encoder(width: w, height: v.height, keyframeInterval: v.kfi)
                var previous: [UInt8]?
                var snapAlpha: [UInt8] = []
                for (i, matte) in mattes.enumerated() {
                    var alpha = matte.bytes.withUnsafeBytes {
                        CameraSegmenter.resample($0.baseAddress!, width: mw, height: mh, rowBytes: mw,
                                                 toWidth: w, toHeight: v.height)
                    }
                    CameraMaskConditioning.condition(&alpha, previous: previous, rule: v.rule)
                    try encoder.append(time: matte.pts, alpha: alpha)
                    previous = alpha
                    if i == snapIndex { snapAlpha = alpha }
                }
                let data = encoder.finish(sourceDuration: duration, sourceByteSize: 0)
                let track = try CameraMaskTrack(data: data)
                let deltas = track.index.filter(\.delta).count
                // Error vs the unconditioned 288 alpha (upsampled when smaller).
                let compare = (w == refSize.width && v.height == refSize.height) ? snapAlpha
                    : snapAlpha.withUnsafeBytes {
                        CameraSegmenter.resample($0.baseAddress!, width: w, height: v.height, rowBytes: w,
                                                 toWidth: refSize.width, toHeight: refSize.height)
                    }
                var errors = zip(compare, reference).map { abs(Int($0) - Int($1)) }
                let mean = Double(errors.reduce(0, +)) / Double(max(1, errors.count))
                errors.sort()
                let p99 = errors.isEmpty ? 0 : errors[Int(Double(errors.count - 1) * 0.99)]
                print(String(format: "CAMERA-MASK-BENCH | %@ | %dx%d | %d | %.0f | %.2f | %d/%d | %.2f | %d |",
                             v.label, w, v.height, data.count, Double(data.count) / Double(mattes.count),
                             Double(data.count) / minutes / 1_000_000, deltas, mattes.count, mean, p99))
                rows.append((v.label, snapAlpha, w, v.height))
            }

            if let sheet = contactSheet(rows: rows, camera: snapshot, reference: reference, refSize: refSize) {
                print("CAMERA-MASK-BENCH-PNG-BEGIN")
                print(sheet.base64EncodedString())
                print("CAMERA-MASK-BENCH-PNG-END")
            }
            print("CAMERA-MASK-BENCH OK")
            return true
        } catch {
            print("CAMERA-MASK-BENCH FAILED \(error)")
            return false
        }
    }

    /// Vision over every frame (BGRA decode, sequence handler, .balanced,
    /// OneComponent8 — the production request), keeping the raw mattes, and
    /// one camera frame (40 % into the clip) for the visual check.
    nonisolated private static func segmentRaw(_ url: URL) async throws
        -> ([RawMatte], Int, Int, CGSize, Double, CGImage, Int) {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CameraSegmenter.SegmentError(message: "no video track")
        }
        let natural = try await track.load(.naturalSize)
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        let fps = Double(try await track.load(.nominalFrameRate))
        let expected = Int(duration * (fps > 0 ? fps : 30))
        let snapIndex = max(0, Int(Double(expected) * 0.4))
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(output)
        reader.startReading()
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let sequence = VNSequenceRequestHandler()
        let ciContext = CIContext()
        var mattes: [RawMatte] = []
        var mw = 0, mh = 0
        var snapshot: CGImage?
        while let sample = output.copyNextSampleBuffer() {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            guard pts.isFinite, mattes.last.map({ pts > $0.pts }) ?? true else { continue }
            try autoreleasepool {
                try sequence.perform([request], on: pixelBuffer)
                guard let m = request.results?.first?.pixelBuffer else { return }
                CVPixelBufferLockBaseAddress(m, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(m, .readOnly) }
                mw = CVPixelBufferGetWidth(m); mh = CVPixelBufferGetHeight(m)
                let rb = CVPixelBufferGetBytesPerRow(m)
                let base = CVPixelBufferGetBaseAddress(m)!.assumingMemoryBound(to: UInt8.self)
                var bytes = [UInt8](repeating: 0, count: mw * mh)
                for y in 0..<mh { for x in 0..<mw { bytes[y * mw + x] = base[y * rb + x] } }
                if mattes.count == snapIndex {
                    let ci = CIImage(cvPixelBuffer: pixelBuffer)
                    snapshot = ciContext.createCGImage(ci, from: ci.extent)
                }
                mattes.append(RawMatte(pts: pts, bytes: bytes))
            }
        }
        guard let snapshot, !mattes.isEmpty else { throw CameraSegmenter.SegmentError(message: "no frames") }
        return (mattes, mw, mh, natural, duration, snapshot, min(snapIndex, mattes.count - 1))
    }

    /// One row per variant: the masked camera at bubble size (320 wide) over a
    /// saturated "screen" colour, and a 2× zoom on the head edge.
    @MainActor
    private static func contactSheet(rows: [(label: String, alpha: [UInt8], w: Int, h: Int)],
                                     camera: CGImage, reference: [UInt8], refSize: (width: Int, height: Int)) -> Data? {
        let ci = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        let frame = CIImage(cgImage: camera)
        let e = frame.extent
        // Head edge: the topmost reference row with alpha > 128 near centre.
        var headTop = refSize.height / 4
        var headX = refSize.width / 2
        search: for y in 0..<refSize.height {
            for x in stride(from: refSize.width / 3, to: refSize.width * 2 / 3, by: 1) where reference[y * refSize.width + x] > 128 {
                headTop = y; headX = x; break search
            }
        }
        let zoomW = e.width / 6, zoomH = zoomW * 9 / 16
        let zx = CGFloat(headX) / CGFloat(refSize.width) * e.width
        let zyDown = CGFloat(headTop) / CGFloat(refSize.height) * e.height
        let zoomRect = CGRect(x: zx - zoomW / 2, y: e.height - zyDown - zoomH / 2, width: zoomW, height: zoomH)
            .intersection(e)
        let bubbleW: CGFloat = 320, zoomOutW: CGFloat = 480
        let rowH = Int(max(bubbleW * e.height / e.width, zoomOutW * zoomRect.height / zoomRect.width)) + 22
        let sheetW = Int(bubbleW + zoomOutW) + 12
        let sheetH = rowH * rows.count
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: sheetW, height: sheetH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: sheetW, height: sheetH))
        let backdrop = CIImage(color: CIColor(red: 0.12, green: 0.55, blue: 0.95)).cropped(to: e)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        for (i, row) in rows.enumerated() {
            guard let mask = CameraStyleMath.maskCIImage(alpha: row.alpha, width: row.w, height: row.h) else { continue }
            let composed = CameraStyleMath.maskedImage(frame, mask: mask, mirrored: false).composited(over: backdrop)
            let top = CGFloat(sheetH - i * rowH)
            if let full = ci.createCGImage(composed, from: e) {
                let h = bubbleW * e.height / e.width
                ctx.interpolationQuality = .high
                ctx.draw(full, in: CGRect(x: 0, y: top - 20 - h, width: bubbleW, height: h))
            }
            if let zoom = ci.createCGImage(composed, from: zoomRect) {
                let h = zoomOutW * zoomRect.height / zoomRect.width
                ctx.interpolationQuality = .none
                ctx.draw(zoom, in: CGRect(x: bubbleW + 12, y: top - 20 - h, width: zoomOutW, height: h))
            }
            (row.label as NSString).draw(at: CGPoint(x: 4, y: top - 17), withAttributes: [
                .foregroundColor: NSColor.white, .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
            ])
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let image = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
