import AVFoundation
import CoreVideo
import Metal
import QuartzCore
import UIKit

/// (a) Video surface: can the compositor's video layer be fed the way the Mac
/// feeds it — `CALayer.contents = IOSurface` from AVPlayerItemVideoOutput —
/// at 60 fps on iOS, and what do the fallbacks look like?
///
/// Variants (one per launch):
///   timer        EXACT Mac path (VideoFrameLayerDriver): a 60 Hz Timer polls
///                player.currentTime(), hasNewPixelBuffer → copyPixelBuffer →
///                layer.contents = IOSurface.
///   displaylink  same contents path, driven by CADisplayLink (60 Hz) with
///                itemTime(forHostTime: targetTimestamp).
///   sbdl         AVSampleBufferDisplayLayer fed COMPRESSED samples from an
///                AVAssetReader under an AVSampleBufferRenderSynchronizer (the
///                system decodes and presents on its own clock).
///   metal        CAMetalLayer: copyPixelBuffer → CVMetalTexture → blit into
///                the drawable; presentation timestamps from addPresentedHandler.
///
/// The video layer sits under a perspective transform like the compositor's
/// tilt group, so the render server does real 3D compositing.
/// Arguments: --file <media> (default screen-3456x2234-60.mov) --seconds 10.
@MainActor
enum SpikeA {
    static func run(variant: String) async throws -> [String: Any] {
        let h = Harness.shared
        let file = h.value("--file") ?? "screen-3456x2234-60.mov"
        let seconds = h.double("--seconds", default: 10)
        let url = try h.media(file)

        // Stage: card layer with a mild 3D tilt, like the compositor's tilt group.
        let stage = h.stage
        stage.layoutIfNeeded()
        let tilt = CATransformLayer()
        tilt.frame = stage.bounds
        var t = CATransform3DIdentity
        t.m34 = -1.0 / 1200
        t = CATransform3DRotate(t, 8 * .pi / 180, 1, 0, 0)
        t = CATransform3DRotate(t, -6 * .pi / 180, 0, 1, 0)
        tilt.transform = t
        stage.layer.addSublayer(tilt)
        let card = stage.bounds.insetBy(dx: stage.bounds.width * 0.08, dy: stage.bounds.height * 0.08)
        defer { tilt.removeFromSuperlayer() }

        var result: [String: Any] = ["file": file, "seconds": seconds, "stagePoints": "\(Int(card.width))x\(Int(card.height))"]
        switch variant {
        case "timer", "displaylink":
            let layer = CALayer()
            layer.frame = card
            layer.contentsGravity = .resizeAspect
            layer.cornerRadius = 12
            layer.masksToBounds = true
            tilt.addSublayer(layer)
            let r = try await ContentsDriver(url: url, layer: layer, useDisplayLink: variant == "displaylink")
                .run(seconds: seconds)
            result.merge(r) { $1 }
            result["onScreenCheck"] = onScreenCheck(stage)
        case "sbdl":
            let layer = AVSampleBufferDisplayLayer()
            layer.frame = card
            layer.videoGravity = .resizeAspect
            tilt.addSublayer(layer)
            result.merge(try await SBDLDriver(url: url, layer: layer).run(seconds: seconds)) { $1 }
            result["onScreenCheck"] = onScreenCheck(stage)
        case "metal":
            let layer = CAMetalLayer()
            layer.frame = card
            layer.contentsGravity = .resizeAspect
            tilt.addSublayer(layer)
            result.merge(try await MetalDriver(url: url, layer: layer).run(seconds: seconds)) { $1 }
            result["onScreenCheck"] = onScreenCheck(stage)
        default:
            throw SpikeError("variant must be timer|displaylink|sbdl|metal")
        }
        return result
    }

    /// Proves the frames actually reached the screen: snapshot the stage
    /// through the render server and measure non-background coverage.
    static func onScreenCheck(_ view: UIView) -> [String: Any] {
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
        let image = renderer.image { _ in _ = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true) }
        guard let cg = image.cgImage, let px = Pixels(cg) else { return ["ok": false] }
        var lit = 0, total = 0
        for y in stride(from: 0, to: px.height, by: 4) {
            for x in stride(from: 0, to: px.width, by: 4) {
                let (r, g, b, _) = px[x, y]
                total += 1
                if max(r, g, b) > 40 { lit += 1 }
            }
        }
        let frac = Double(lit) / Double(max(1, total))
        return ["ok": frac > 0.2, "litFraction": frac]
    }
}

/// Mac-identical contents path (timer) or its display-link sibling.
@MainActor
final class ContentsDriver {
    let player: AVPlayer
    let output: AVPlayerItemVideoOutput
    let layer: CALayer
    let useDisplayLink: Bool
    private var timer: Timer?
    private var link: CADisplayLink?
    private var updates: [(host: CFTimeInterval, item: Double)] = []
    private var tickCount = 0
    private var noFrameTicks = 0
    private var copyCostMs: [Double] = []
    private var sourceFPS: Double = 60

    init(url: URL, layer: CALayer, useDisplayLink: Bool) async throws {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video).first
        sourceFPS = Double(try await track?.load(.nominalFrameRate) ?? 60)
        let item = AVPlayerItem(asset: asset)
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ])
        item.add(output)
        player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        self.layer = layer
        self.useDisplayLink = useDisplayLink
    }

    func run(seconds: Double) async throws -> [String: Any] {
        // Wait for readiness.
        while player.currentItem?.status == .unknown { try await Task.sleep(nanoseconds: 20_000_000) }
        if player.currentItem?.status == .failed {
            throw SpikeError("player item failed: \(String(describing: player.currentItem?.error))")
        }
        await player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        if useDisplayLink {
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            self.link = link
        } else {
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pull(itemTime: self?.player.currentTime() ?? .zero) }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        player.play()
        try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
        player.pause()
        timer?.invalidate()
        link?.invalidate()
        return summarize(seconds: seconds)
    }

    @objc private func tick(_ link: CADisplayLink) {
        pull(itemTime: output.itemTime(forHostTime: link.targetTimestamp))
    }

    private func pull(itemTime: CMTime) {
        tickCount += 1
        let start = CACurrentMediaTime()
        var displayTime = CMTime.invalid
        guard output.hasNewPixelBuffer(forItemTime: itemTime),
              let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &displayTime),
              let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else {
            noFrameTicks += 1
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = surface
        CATransaction.commit()
        let end = CACurrentMediaTime()
        copyCostMs.append((end - start) * 1000)
        updates.append((end, displayTime.isValid ? displayTime.seconds : itemTime.seconds))
    }

    private func summarize(seconds: Double) -> [String: Any] {
        let intervals = zip(updates, updates.dropFirst()).map { ($1.host - $0.host) * 1000 }
        let frameDur = 1.0 / sourceFPS
        // Source frames the display skipped: gaps in the displayed item time.
        let skipped = zip(updates, updates.dropFirst()).reduce(0) { acc, p in
            acc + max(0, Int(((p.1.item - p.0.item) / frameDur).rounded()) - 1)
        }
        let duplicatesOrStalls = intervals.filter { $0 > 1.5 * 1000 * frameDur }.count
        let span = (updates.last?.item ?? 0) - (updates.first?.item ?? 0)
        return [
            "driver": useDisplayLink ? "CADisplayLink 60Hz" : "Timer 60Hz (Mac VideoFrameLayerDriver)",
            "sourceFPS": sourceFPS,
            "framesDisplayed": updates.count,
            "displayedPerSecond": Double(updates.count) / seconds,
            "sourceFramesSpanned": Int((span / frameDur).rounded()) + 1,
            "sourceFramesSkipped": skipped,
            "intervalsOver1_5Frames": duplicatesOrStalls,
            "updateIntervalMs": Metrics.stats(intervals),
            "copyAndCommitMs": Metrics.stats(copyCostMs),
            "ticks": tickCount,
            "ticksWithoutNewFrame": noFrameTicks,
        ]
    }
}

/// AVSampleBufferDisplayLayer: the system decodes and presents.
@MainActor
final class SBDLDriver {
    let url: URL
    let layer: AVSampleBufferDisplayLayer
    init(url: URL, layer: AVSampleBufferDisplayLayer) { self.url = url; self.layer = layer }

    func run(seconds: Double) async throws -> [String: Any] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw SpikeError("no video track") }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil) // compressed passthrough
        out.alwaysCopiesSampleData = false
        reader.add(out)
        guard reader.startReading() else { throw SpikeError("reader: \(String(describing: reader.error))") }
        let sync = AVSampleBufferRenderSynchronizer()
        sync.addRenderer(layer)
        let renderer = layer.sampleBufferRenderer
        var enqueued = 0
        var failures = 0
        let token = NotificationCenter.default.addObserver(
            forName: AVSampleBufferVideoRenderer.didFailToDecodeNotification, object: renderer, queue: nil) { _ in
            failures += 1
        }
        defer { NotificationCenter.default.removeObserver(token) }
        let feed = DispatchQueue(label: "spike.sbdl")
        let start = CACurrentMediaTime()
        renderer.requestMediaDataWhenReady(on: feed) {
            while renderer.isReadyForMoreMediaData {
                guard let sample = out.copyNextSampleBuffer() else {
                    renderer.stopRequestingMediaData()
                    return
                }
                renderer.enqueue(sample)
                enqueued += 1
            }
        }
        // Start the clock once a little data is queued.
        try await Task.sleep(nanoseconds: 200_000_000)
        sync.setRate(1, time: .zero)
        // Sample the synchronizer clock against the host clock at 60 Hz:
        // a renderer that falls behind drags its timebase (or stalls).
        var clock: [(host: Double, media: Double)] = []
        let deadline = CACurrentMediaTime() + seconds
        while CACurrentMediaTime() < deadline {
            clock.append((CACurrentMediaTime(), sync.currentTime().seconds))
            try await Task.sleep(nanoseconds: 16_666_666)
        }
        sync.setRate(0, time: sync.currentTime())
        renderer.stopRequestingMediaData()
        let drift = (clock.last!.media - clock.first!.media) - (clock.last!.host - clock.first!.host)
        return [
            "driver": "AVSampleBufferDisplayLayer + AVSampleBufferRenderSynchronizer (compressed samples)",
            "samplesEnqueued": enqueued,
            "decodeFailures": failures,
            "status": layer.status == .failed ? "failed: \(String(describing: layer.error))" : "ok",
            "requiresFlushToResumeDecoding": renderer.requiresFlushToResumeDecoding,
            "clockDriftSeconds": drift,
            "note": "pacing is owned by the render server; no per-frame presentation API while rate != 0 (copyDisplayedPixelBuffer returns nil)",
            "setupToStartSeconds": CACurrentMediaTime() - start - seconds,
        ]
    }
}

/// CAMetalLayer with real presentation timestamps.
@MainActor
final class MetalDriver {
    let player: AVPlayer
    let output: AVPlayerItemVideoOutput
    let layer: CAMetalLayer
    let device: MTLDevice
    let queue: MTLCommandQueue
    var cache: CVMetalTextureCache?
    private var link: CADisplayLink?
    private var presented: [Double] = []
    private var encodeMs: [Double] = []
    private var ticks = 0, noFrame = 0, noDrawable = 0
    private let lock = NSLock()

    init(url: URL, layer: CAMetalLayer) async throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw SpikeError("no Metal")
        }
        self.device = device
        self.queue = queue
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video).first
        let size = try await track?.load(.naturalSize) ?? CGSize(width: 1920, height: 1080)
        let item = AVPlayerItem(asset: asset)
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ])
        item.add(output)
        player = AVPlayer(playerItem: item)
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.drawableSize = size
        layer.maximumDrawableCount = 3
        self.layer = layer
    }

    func run(seconds: Double) async throws -> [String: Any] {
        while player.currentItem?.status == .unknown { try await Task.sleep(nanoseconds: 20_000_000) }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
        player.play()
        try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
        player.pause()
        link.invalidate()
        try await Task.sleep(nanoseconds: 100_000_000)
        let p = lock.withLock { presented.filter { $0 > 0 } }
        let intervals = zip(p, p.dropFirst()).map { ($1 - $0) * 1000 }
        return [
            "driver": "CAMetalLayer blit, CADisplayLink 60Hz, addPresentedHandler timestamps",
            "framesPresented": p.count,
            "presentedPerSecond": Double(p.count) / seconds,
            "presentIntervalMs": Metrics.stats(intervals),
            "intervalsOver25ms": intervals.filter { $0 > 25 }.count,
            "encodeMs": Metrics.stats(encodeMs),
            "ticks": ticks, "ticksWithoutNewFrame": noFrame, "ticksWithoutDrawable": noDrawable,
        ]
    }

    @objc private func tick(_ link: CADisplayLink) {
        ticks += 1
        let itemTime = output.itemTime(forHostTime: link.targetTimestamp)
        guard output.hasNewPixelBuffer(forItemTime: itemTime),
              let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil),
              let cache else { noFrame += 1; return }
        let start = CACurrentMediaTime()
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        var cvTex: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, .bgra8Unorm, w, h, 0, &cvTex)
        guard let cvTex, let src = CVMetalTextureGetTexture(cvTex) else { noFrame += 1; return }
        guard let drawable = layer.nextDrawable() else { noDrawable += 1; return }
        guard let cmd = queue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() else { return }
        let dst = drawable.texture
        let cw = min(w, dst.width), ch = min(h, dst.height)
        blit.copy(from: src, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: cw, height: ch, depth: 1),
                  to: dst, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        #if targetEnvironment(simulator)
        // The Simulator SDK has no presented handler; record commit time instead.
        let committed = CACurrentMediaTime()
        lock.withLock { presented.append(committed) }
        #else
        drawable.addPresentedHandler { [weak self] d in
            guard let self else { return }
            self.lock.withLock { self.presented.append(d.presentedTime) }
        }
        #endif
        cmd.present(drawable)
        cmd.addCompletedHandler { _ in _ = cvTex } // keep the CV texture alive until the GPU is done
        cmd.commit()
        encodeMs.append((CACurrentMediaTime() - start) * 1000)
    }
}

/// Minimal RGBA8 reader for snapshot checks.
struct Pixels {
    let width: Int, height: Int
    private let data: [UInt8]
    init?(_ image: CGImage) {
        let width = image.width, height = image.height
        self.width = width; self.height = height
        var buf = [UInt8](repeating: 0, count: width * height * 4)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
        data = buf
    }
    /// Top-down coordinates.
    subscript(x: Int, y: Int) -> (Int, Int, Int, Int) {
        let i = (y * width + x) * 4
        return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]), Int(data[i + 3]))
    }
}
