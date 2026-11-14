import AVFoundation
import QuartzCore
import UIKit
import VideoToolbox

/// (b) HEVC decode of Mac-recording-sized sources: 3456×2234 (16" MacBook Pro
/// native) and 5120×2880 (5K), both 60 fps synthetic screen content.
///
/// Variants:
///   reader-nv12   AVAssetReader decode as fast as possible, native 4:2:0
///   reader-bgra   same, BGRA output (what the compositor's video layer and
///                 the exporter's CI graph consume)
///   player        AVPlayer at 1× with AVPlayerItemVideoOutput (BGRA,
///                 IOSurface) pulled on a 60 Hz display link: frames obtained
///                 vs due, plus the access log's dropped-frame count.
/// Arguments: --file <media>, --seconds (player, default 10).
@MainActor
enum SpikeB {
    static func run(variant: String) async throws -> [String: Any] {
        let h = Harness.shared
        let file = h.value("--file") ?? "screen-3456x2234-60.mov"
        let url = try h.media(file)
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw SpikeError("no video") }
        let size = try await track.load(.naturalSize)
        let fps = try await track.load(.nominalFrameRate)
        let duration = try await asset.load(.duration).seconds
        let desc = try await track.load(.formatDescriptions).first
        var result: [String: Any] = [
            "file": file, "size": "\(Int(size.width))x\(Int(size.height))", "fps": fps, "duration": duration,
            "codec": desc.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "?",
            "hwHEVCDecodeSupported": VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC),
            "isDecodable": try await track.load(.isDecodable),
            "isPlayable": try await asset.load(.isPlayable),
        ]
        switch variant {
        case "reader-nv12": result.merge(try readAll(asset, track, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)) { $1 }
        case "reader-bgra": result.merge(try readAll(asset, track, format: kCVPixelFormatType_32BGRA)) { $1 }
        case "player": result.merge(try await play(asset, fps: Double(fps), seconds: h.double("--seconds", default: 10))) { $1 }
        default: throw SpikeError("variant must be reader-nv12|reader-bgra|player")
        }
        return result
    }

    static func fourCC(_ v: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((v >> $0) & 0xff) }
        return String(bytes: bytes, encoding: .ascii) ?? "\(v)"
    }

    nonisolated static func readAll(_ asset: AVAsset, _ track: AVAssetTrack, format: OSType) throws -> [String: Any] {
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: format,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ])
        out.alwaysCopiesSampleData = false
        reader.add(out)
        let start = CACurrentMediaTime()
        guard reader.startReading() else { throw SpikeError("reader: \(String(describing: reader.error))") }
        var frames = 0
        var firstFrameMs = 0.0
        var perFrame: [Double] = []
        var last = start
        while let sample = out.copyNextSampleBuffer() {
            guard CMSampleBufferGetImageBuffer(sample) != nil else { continue }
            let now = CACurrentMediaTime()
            if frames == 0 { firstFrameMs = (now - start) * 1000 } else { perFrame.append((now - last) * 1000) }
            last = now
            frames += 1
        }
        let elapsed = CACurrentMediaTime() - start
        if reader.status == .failed { throw SpikeError("reader failed after \(frames) frames: \(String(describing: reader.error))") }
        return [
            "mode": format == kCVPixelFormatType_32BGRA ? "AVAssetReader BGRA" : "AVAssetReader NV12",
            "frames": frames, "seconds": elapsed, "decodeFPS": Double(frames) / elapsed,
            "firstFrameMs": firstFrameMs, "frameMs": Metrics.stats(perFrame),
        ]
    }

    static func play(_ asset: AVAsset, fps: Double, seconds: Double) async throws -> [String: Any] {
        let item = AVPlayerItem(asset: asset)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        let created = CACurrentMediaTime()
        while item.status == .unknown { try await Task.sleep(nanoseconds: 10_000_000) }
        if item.status == .failed { throw SpikeError("item failed: \(String(describing: item.error))") }
        let ready = CACurrentMediaTime()
        let puller = FramePuller(output: output)
        player.play()
        let playStart = CACurrentMediaTime()
        try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
        player.pause()
        puller.stop()
        let played = player.currentTime().seconds
        let log = item.accessLog()?.events.last
        let frameDur = 1 / fps
        let items = puller.itemTimes
        let skipped = zip(items, items.dropFirst()).reduce(0) { $0 + max(0, Int((($1.1 - $1.0) / frameDur).rounded()) - 1) }
        return [
            "mode": "AVPlayer 1x + AVPlayerItemVideoOutput BGRA on CADisplayLink 60Hz",
            "readySeconds": ready - created,
            "firstFrameMs": puller.firstFrameHost.map { ($0 - playStart) * 1000 } ?? -1,
            "playedSeconds": played,
            "framesObtained": items.count,
            "framesDue": Int(played * fps),
            "sourceFramesSkipped": skipped,
            "accessLogDroppedFrames": log?.numberOfDroppedVideoFrames ?? -1,
            "accessLogStalls": log?.numberOfStalls ?? -1,
        ]
    }
}

@MainActor
final class FramePuller {
    let output: AVPlayerItemVideoOutput
    private var link: CADisplayLink?
    private(set) var itemTimes: [Double] = []
    private(set) var firstFrameHost: Double?

    init(output: AVPlayerItemVideoOutput) {
        self.output = output
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() { link?.invalidate() }

    @objc private func tick(_ link: CADisplayLink) {
        let t = output.itemTime(forHostTime: link.targetTimestamp)
        var shown = CMTime.invalid
        guard output.hasNewPixelBuffer(forItemTime: t),
              output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: &shown) != nil else { return }
        if firstFrameHost == nil { firstFrameHost = CACurrentMediaTime() }
        itemTimes.append(shown.isValid ? shown.seconds : t.seconds)
    }
}
