import Accelerate
import AVFoundation
import Foundation
import Vision

/// Pause / cancel flags the main actor flips while a segmentation runs off
/// it. Lock-protected: the worker polls them between frames.
nonisolated final class CameraSegmentationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var pausedValue = false
    private var cancelledValue = false

    var isPaused: Bool {
        get { lock.withLock { pausedValue } }
        set { lock.withLock { pausedValue = newValue } }
    }

    var isCancelled: Bool {
        get { lock.withLock { cancelledValue } }
        set { lock.withLock { cancelledValue = newValue } }
    }
}

/// Per-phase wall time of one segmentation (`--camera-mask-bench`).
nonisolated final class CameraSegmentationStats: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Double] = [:]
    func add(_ phase: String, _ seconds: Double) { lock.withLock { values[phase, default: 0] += seconds } }
    var snapshot: [String: Double] { lock.withLock { values } }
}

/// The heavy half of the mask job (docs/camera-cutout.md §6): every camera
/// frame, at its native PTS, through Vision's person segmentation, resampled
/// to the contract's mask size and streamed into `CameraMaskTrack.Encoder`.
/// Runs on a detached utility task; never touches the main actor.
nonisolated enum CameraSegmenter {
    struct SegmentError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Segments `cameraURL` and returns the encoded `.ccmask` bytes.
    /// `progress` receives 0…1 (throttled to whole percents).
    static func segment(
        cameraURL: URL,
        gate: CameraSegmentationGate,
        keyframeInterval: Int = CameraMaskTrack.defaultKeyframeInterval,
        stats: CameraSegmentationStats? = nil,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Data {
        let asset = AVURLAsset(url: cameraURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw SegmentError(message: "the camera file has no video track")
        }
        let natural = try await track.load(.naturalSize)
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        let fps = Double(try await track.load(.nominalFrameRate))
        let byteSize = ((try? FileManager.default.attributesOfItem(atPath: cameraURL.path))?[.size] as? NSNumber)?.int64Value ?? 0
        guard natural.width > 0, natural.height > 0, duration.isFinite, duration > 0 else {
            throw SegmentError(message: "the camera file is empty")
        }
        let size = CameraMaskTrack.maskSize(cameraAspect: Double(natural.width / natural.height))

        let reader = try AVAssetReader(asset: asset)
        // The decoder's native bi-planar YUV — Vision reads it directly, so
        // no per-frame colour conversion is paid for.
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw SegmentError(message: "cannot read the camera file") }
        reader.add(output)
        guard reader.startReading() else {
            throw SegmentError(message: reader.error?.localizedDescription ?? "cannot read the camera file")
        }

        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        // A sequence handler lets Vision keep its temporal state across
        // frames (steadier edges than independent per-image requests).
        let sequence = VNSequenceRequestHandler()
        let encoder = CameraMaskTrack.Encoder(width: size.width, height: size.height, keyframeInterval: keyframeInterval)
        let expected = max(1, duration * (fps > 0 ? fps : 30))
        var lastReported = -1
        /// End of the last frame (PTS + its duration) — the header's
        /// sourceDuration (contract §6, same as the web's segmenter).
        var lastFrameEnd: Double = 0
        var previousPTS: Double?
        var previousAlpha: [UInt8]?

        var mark = CFAbsoluteTimeGetCurrent()
        func lap(_ phase: String) {
            guard let stats else { return }
            let now = CFAbsoluteTimeGetCurrent()
            stats.add(phase, now - mark)
            mark = now
        }
        while let sample = output.copyNextSampleBuffer() {
            lap("decode")
            while gate.isPaused, !gate.isCancelled {
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            if gate.isCancelled || Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            // Frame times must strictly increase (codec rule); drop anything else.
            guard pts.isFinite, encoder.lastTime.map({ pts > $0 }) ?? true else { continue }
            var alpha: [UInt8] = try autoreleasepool {
                try sequence.perform([request], on: pixelBuffer)
                lap("vision")
                guard let mask = request.results?.first?.pixelBuffer else {
                    return [UInt8](repeating: 0, count: size.width * size.height)
                }
                return resample(mask, width: size.width, height: size.height)
            }
            lap("resample")
            // Producer alpha conditioning (contract §6): dead zone, hold
            // against the previous conditioned frame, 8-level quantisation.
            CameraMaskConditioning.condition(&alpha, previous: previousAlpha)
            previousAlpha = alpha
            try encoder.append(time: pts, alpha: alpha)
            lap("encode")
            lastFrameEnd = frameEnd(pts: pts, duration: CMTimeGetSeconds(CMSampleBufferGetDuration(sample)),
                                    previousPTS: previousPTS, fps: fps)
            previousPTS = pts
            let percent = Int(min(0.99, Double(encoder.frameCount) / expected) * 100)
            if percent != lastReported {
                lastReported = percent
                progress(Double(percent) / 100)
            }
        }
        if reader.status == .failed {
            throw SegmentError(message: reader.error?.localizedDescription ?? "reading the camera file failed")
        }
        guard encoder.frameCount > 0 else { throw SegmentError(message: "the camera file has no frames") }
        progress(1)
        return encoder.finish(sourceDuration: lastFrameEnd, sourceByteSize: Double(byteSize))
    }

    /// End of a decoded frame: its own duration when the sample carries one
    /// (decoded buffers usually don't — NaN), else the gap since the
    /// previous frame, else one nominal frame.
    static func frameEnd(pts: Double, duration: Double, previousPTS: Double?, fps: Double) -> Double {
        if duration.isFinite, duration > 0 { return pts + duration }
        if let previousPTS, pts > previousPTS { return pts + (pts - previousPTS) }
        return pts + 1 / (fps > 0 ? fps : 30)
    }

    /// Vision's OneComponent8 mask → exactly `width`×`height` bytes (row 0 =
    /// top, same orientation as the camera buffer Vision was given).
    static func resample(_ mask: CVPixelBuffer, width: Int, height: Int) -> [UInt8] {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return [UInt8](repeating: 0, count: width * height) }
        return resample(base, width: CVPixelBufferGetWidth(mask), height: CVPixelBufferGetHeight(mask),
                        rowBytes: CVPixelBufferGetBytesPerRow(mask), toWidth: width, toHeight: height)
    }

    /// One 8-bit plane → exactly `toWidth`×`toHeight` bytes.
    static func resample(_ base: UnsafeRawPointer, width: Int, height: Int, rowBytes: Int,
                         toWidth: Int, toHeight: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: toWidth * toHeight)
        var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: base), height: vImagePixelCount(height),
                                width: vImagePixelCount(width), rowBytes: rowBytes)
        out.withUnsafeMutableBytes { raw in
            var dst = vImage_Buffer(
                data: raw.baseAddress, height: vImagePixelCount(toHeight),
                width: vImagePixelCount(toWidth), rowBytes: toWidth)
            _ = vImageScale_Planar8(&src, &dst, nil, vImage_Flags(kvImageNoFlags))
        }
        return out
    }
}
