import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Metal
import QuartzCore
import UIKit

/// (c) Exporter cost on device: 4K (3840×2160) CoreImage → HEVC throughput and
/// peak memory at pipeline depths 2/3/5/8.
///
/// The per-frame graph is shaped like VideoExporter's (not a copy of it):
///   BGRA source frame from AVAssetReader (as the exporter reads it)
///   → zoom affine (time-varying, like a zoom region) → crop to the card
///   → CIBlendWithMask with a CACHED rounded-rect mask
///   → over a CACHED blurred drop shadow → over a CACHED gradient background
///   → cursor CGImage composited at a moving point
///   → CIMotionBlur on the card every other second (the exporter's blur)
///   → CIContext(mtlCommandQueue:) startTask into an NV12 pool buffer, the
///     wait parked on GCD (exactly the exporter's pattern) → PTS-ordered
///     append through a serial actor with writer backpressure.
/// Up to `depth` frames are in flight, like VideoExporter's `pipelineDepth`
/// (8 on the Mac today).
///
/// Variants: depth2 | depth3 | depth5 | depth8. Arguments: --frames (300),
/// --file (source, default screen-3456x2234-60.mov), --fps (30).
@MainActor
enum SpikeC {
    static func run(variant: String) async throws -> [String: Any] {
        guard variant.hasPrefix("depth"), let depth = Int(variant.dropFirst(5)) else {
            throw SpikeError("variant must be depth<N>")
        }
        let h = Harness.shared
        let frames = h.int("--frames", default: 300)
        let fps = h.int("--fps", default: 30)
        let source = try h.media(h.value("--file") ?? "screen-3456x2234-60.mov")
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("spike-c-\(depth).mp4")
        try? FileManager.default.removeItem(at: out)
        let exporter = try ShapedExporter(source: source, output: out, size: CGSize(width: 3840, height: 2160), fps: fps)
        let r = try await exporter.export(frames: frames, depth: depth, progress: nil)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
        try? FileManager.default.removeItem(at: out)
        var result = r
        result["depth"] = depth
        result["outputBytes"] = bytes
        return result
    }
}

/// The 4K CI → HEVC pipeline used by spikes c and g.
final class ShapedExporter: @unchecked Sendable {
    let source: URL, output: URL, size: CGSize, fps: Int
    let device: MTLDevice
    let queue: MTLCommandQueue
    let context: CIContext
    private let background: CIImage
    private let cardMask: CIImage
    private let shadow: CIImage
    private let cursor: CIImage
    private let cardRect: CGRect

    init(source: URL, output: URL, size: CGSize, fps: Int) throws {
        self.source = source; self.output = output; self.size = size; self.fps = fps
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw SpikeError("no Metal device")
        }
        self.device = device; self.queue = queue
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CIContext(mtlCommandQueue: queue, options: [.workingColorSpace: space, .cacheIntermediates: false])
        context = ctx
        let extent = CGRect(origin: .zero, size: size)
        // Cached statics, as VideoExporter caches its mask / shadow / backdrop.
        let grad = CIFilter.linearGradient()
        grad.point0 = CGPoint(x: 0, y: 0); grad.point1 = CGPoint(x: size.width, y: size.height)
        grad.color0 = CIColor(red: 0.42, green: 0.26, blue: 0.93); grad.color1 = CIColor(red: 0.13, green: 0.62, blue: 0.98)
        background = grad.outputImage!.cropped(to: extent)
        let pad = size.width * 0.06
        let cardRect = extent.insetBy(dx: pad, dy: pad * size.height / size.width)
        self.cardRect = cardRect
        let rr = CIFilter.roundedRectangleGenerator()
        rr.extent = cardRect; rr.radius = Float(24 * size.width / 1600); rr.color = .white
        cardMask = rr.outputImage!
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = cardMask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.45),
        ]).transformed(by: CGAffineTransform(translationX: 0, y: -size.height * 0.012))
        blur.radius = Float(size.width * 0.012)
        let shadowImg = blur.outputImage!.cropped(to: extent)
        // Materialize the statics once (like the exporter's cached CGImages).
        func bake(_ img: CIImage) -> CIImage {
            guard let cg = ctx.createCGImage(img, from: img.extent.intersection(extent)) else { return img }
            return CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: img.extent.intersection(extent).minX,
                                                                           y: img.extent.intersection(extent).minY))
        }
        shadow = bake(shadowImg)
        // Cursor: a 64×64 arrow-ish glyph drawn once.
        let cursorSize = CGSize(width: 72, height: 72)
        let renderer = UIGraphicsImageRenderer(size: cursorSize, format: {
            let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f
        }())
        let img = renderer.image { ctx in
            let p = UIBezierPath()
            p.move(to: CGPoint(x: 8, y: 4)); p.addLine(to: CGPoint(x: 8, y: 60)); p.addLine(to: CGPoint(x: 22, y: 46))
            p.addLine(to: CGPoint(x: 34, y: 68)); p.addLine(to: CGPoint(x: 42, y: 64)); p.addLine(to: CGPoint(x: 30, y: 42))
            p.addLine(to: CGPoint(x: 50, y: 42)); p.close()
            UIColor.black.setFill(); p.fill(); UIColor.white.setStroke(); p.lineWidth = 3; p.stroke()
        }
        cursor = CIImage(cgImage: img.cgImage!)
    }

    struct Result: Sendable { var frames: Int; var seconds: Double }

    /// Exports `frames` output frames; `progress(frame)` is called per append.
    func export(frames: Int, depth: Int, progress: (@Sendable (Int) -> Void)?) async throws -> [String: Any] {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw SpikeError("no video") }
        let srcSize = try await track.load(.naturalSize)
        let reader = try AVAssetReader(asset: asset)
        let readerOut = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ])
        readerOut.alwaysCopiesSampleData = false
        reader.add(readerOut)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 40_000_000],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        writer.add(input)
        guard reader.startReading() else { throw SpikeError("reader: \(String(describing: reader.error))") }
        guard writer.startWriting() else { throw SpikeError("writer: \(String(describing: writer.error))") }
        writer.startSession(atSourceTime: .zero)

        let appender = OrderedAppender(input: input, adaptor: adaptor)
        var tasks: [Task<Void, Never>] = []
        var lastSource: CVPixelBuffer?
        var sourceFrame = 0
        var buildMs: [Double] = []
        var gpuMs = [Double](repeating: 0, count: frames)
        let gpuLock = NSLock()
        var failures = 0
        let start = CACurrentMediaTime()
        var perSecond: [Double] = []
        var lastMark = start, lastMarkFrame = 0

        for i in 0..<frames {
            let t = Double(i) / Double(fps)
            // Advance the source to t (source is 60 fps; output 30 fps by default).
            while Double(sourceFrame) / 60.0 <= t, let s = readerOut.copyNextSampleBuffer() {
                if let pb = CMSampleBufferGetImageBuffer(s) { lastSource = pb }
                sourceFrame += 1
            }
            // Past the end of a short source the last frame is reused.
            if lastSource == nil { break }
            let b0 = CACurrentMediaTime()
            let composed = compose(source: CIImage(cvPixelBuffer: lastSource!), srcSize: srcSize, t: t)
            buildMs.append((CACurrentMediaTime() - b0) * 1000)

            guard let pool = adaptor.pixelBufferPool else { throw SpikeError("no pool") }
            var outBuf: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuf)
            guard let outBuf else { failures += 1; continue }
            if tasks.count >= depth { await tasks.removeFirst().value }
            let pts = CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps))
            let ctx = context
            let index = i
            tasks.append(Task {
                let g0 = CACurrentMediaTime()
                let dest = CIRenderDestination(pixelBuffer: outBuf)
                dest.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
                if let task = try? ctx.startTask(toRender: composed, to: dest) {
                    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                        DispatchQueue.global(qos: .userInitiated).async { _ = try? task.waitUntilCompleted(); c.resume() }
                    }
                }
                let g = (CACurrentMediaTime() - g0) * 1000
                gpuLock.withLock { gpuMs[index] = g }
                await appender.append(outBuf, at: pts, index: index)
                progress?(index + 1)
            })
            let now = CACurrentMediaTime()
            if now - lastMark >= 1 {
                perSecond.append(Double(i - lastMarkFrame) / (now - lastMark))
                lastMark = now; lastMarkFrame = i
            }
        }
        for task in tasks { await task.value }
        input.markAsFinished()
        await writer.finishWriting()
        reader.cancelReading()
        let elapsed = CACurrentMediaTime() - start
        let written = await appender.appended
        if writer.status != .completed { throw SpikeError("writer: \(String(describing: writer.error))") }
        return [
            "outputSize": "\(Int(size.width))x\(Int(size.height))", "fps": fps,
            "framesWritten": written, "seconds": elapsed,
            "exportFPS": Double(written) / elapsed,
            "realtimeFactor": Double(written) / Double(fps) / elapsed,
            "perSecondFPS": perSecond,
            "graphBuildMs": Metrics.stats(buildMs),
            "renderWaitMs": Metrics.stats(gpuMs.filter { $0 > 0 }),
            "poolFailures": failures,
        ]
    }

    /// One frame of the exporter-shaped graph.
    func compose(source: CIImage, srcSize: CGSize, t: Double) -> CIImage {
        // Fit the source into the card, then a zoom that eases 1 → 1.8 → 1 every 4 s.
        let fit = min(cardRect.width / srcSize.width, cardRect.height / srcSize.height)
        let phase = (t.truncatingRemainder(dividingBy: 4)) / 4
        let zoom = 1 + 0.8 * (0.5 - 0.5 * cos(2 * .pi * phase))
        let focal = CGPoint(x: cardRect.midX + cardRect.width * 0.15 * sin(t), y: cardRect.midY)
        var tr = CGAffineTransform(scaleX: fit, y: fit)
        tr = tr.concatenating(CGAffineTransform(translationX: cardRect.midX - srcSize.width * fit / 2,
                                                y: cardRect.midY - srcSize.height * fit / 2))
        tr = tr.concatenating(CGAffineTransform(translationX: -focal.x, y: -focal.y))
            .concatenating(CGAffineTransform(scaleX: zoom, y: zoom))
            .concatenating(CGAffineTransform(translationX: focal.x, y: focal.y))
        var card = source.transformed(by: tr).cropped(to: cardRect)
        // Motion blur on alternate seconds (the exporter blurs the composited card).
        if Int(t) % 2 == 1 {
            card = card.clampedToExtent().applyingFilter("CIMotionBlur", parameters: [
                kCIInputRadiusKey: 18.0, kCIInputAngleKey: 0.3,
            ]).cropped(to: cardRect)
        }
        let masked = card.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: cardMask,
        ])
        var composed = masked.composited(over: shadow).composited(over: background)
        let cursorPoint = CGPoint(x: cardRect.midX + cardRect.width * 0.3 * cos(t * 1.3),
                                  y: cardRect.midY + cardRect.height * 0.3 * sin(t * 0.9))
        composed = cursor.transformed(by: CGAffineTransform(translationX: cursorPoint.x, y: cursorPoint.y))
            .composited(over: composed)
        return composed.cropped(to: CGRect(origin: .zero, size: size))
    }
}

/// PTS-ordered appends with writer backpressure (VideoExporter's SerialAppender pattern).
actor OrderedAppender {
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var next = 0
    private var pending: [Int: (CVPixelBuffer, CMTime)] = [:]
    private(set) var appended = 0
    private var draining = false

    init(input: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor) {
        self.input = input; self.adaptor = adaptor
    }

    func append(_ buffer: CVPixelBuffer, at time: CMTime, index: Int) async {
        pending[index] = (buffer, time)
        // Actor reentrancy: only one caller drains (the sleep below suspends).
        guard !draining else { return }
        draining = true
        defer { draining = false }
        while let (b, t) = pending[next] {
            while !input.isReadyForMoreMediaData { try? await Task.sleep(nanoseconds: 1_000_000) }
            if adaptor.append(b, withPresentationTime: t) { appended += 1 }
            pending[next] = nil
            next += 1
        }
    }
}
