import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import VideoToolbox

/// ReplayKit frames → upright H.264 samples for the Mac (WirelessDeviceProtocol:
/// frames are UPRIGHT, a dimension change is announced with a new
/// `videoFormat` and always followed by a keyframe).
///
/// Hardware encode, real-time, no B-frames (the Mac decodes in arrival order),
/// a keyframe at least every 2 s so a Mac that joins mid-stream locks on fast,
/// and one immediately whenever the Mac asks (`requestKeyframe`).
nonisolated final class StreamEncoder: @unchecked Sendable {
    var onFormat: ((WirelessVideoFormat) -> Void)?
    var onFrame: ((WirelessVideoFrame) -> Void)?

    private let lock = NSLock()
    private var session: VTCompressionSession?
    private var width = 0
    private var height = 0
    private var forceKeyframe = true
    private var lastParameterSets: [Data] = []
    private var rotation: VTPixelRotationSession?
    private var rotationPool: CVPixelBufferPool?
    private var poolSize = (0, 0)
    static let frameRate = 30.0

    func requestKeyframe() {
        lock.lock(); forceKeyframe = true; lock.unlock()
    }

    /// A (re)connected Mac knows nothing: resend the format with the next
    /// keyframe, which is forced now.
    func restartStream() {
        lock.lock(); lastParameterSets = []; forceKeyframe = true; lock.unlock()
    }

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        if let rotation { VTPixelRotationSessionInvalidate(rotation) }
        rotation = nil
        rotationPool = nil
    }

    /// Encode one screen frame. `orientation` is ReplayKit's
    /// RPVideoSampleOrientationKey (how the buffer is rotated from upright).
    func encode(_ buffer: CVPixelBuffer, pts: CMTime, orientation: CGImagePropertyOrientation) {
        guard let upright = rotate(buffer, orientation: orientation) else { return }
        let w = CVPixelBufferGetWidth(upright), h = CVPixelBufferGetHeight(upright)

        lock.lock()
        if session == nil || w != width || h != height {
            makeSession(width: w, height: h)
        }
        guard let session else { lock.unlock(); return }
        let properties: CFDictionary? = forceKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        forceKeyframe = false
        lock.unlock()

        VTCompressionSessionEncodeFrame(session, imageBuffer: upright, presentationTimeStamp: pts, duration: .invalid,
                                        frameProperties: properties, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard status == noErr, let sample, let self else { return }
            self.emit(sample)
        }
    }

    // MARK: Session

    /// Caller holds `lock`.
    private func makeSession(width w: Int, height h: Int) {
        if let session {
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        width = w
        height = h
        lastParameterSets = []
        forceKeyframe = true

        var created: VTCompressionSession?
        let spec = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue] as CFDictionary
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h), codecType: kCMVideoCodecType_H264,
                                                encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        guard status == noErr, let created else { return }
        // ~0.12 bits per pixel per frame: ≈11 Mbps for a 1206×2622 screen at
        // 30 fps — crisp UI text on a LAN, clamped for small/huge screens.
        let bitrate = min(16_000_000, max(4_000_000, Int(Double(w * h) * Self.frameRate * 0.12)))
        let settings: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: kCFBooleanTrue!,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_AllowFrameReordering: kCFBooleanFalse!,
            kVTCompressionPropertyKey_AverageBitRate: bitrate,
            kVTCompressionPropertyKey_DataRateLimits: [bitrate * 2 / 8, 1] as CFArray,
            kVTCompressionPropertyKey_ExpectedFrameRate: Self.frameRate,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: Int(Self.frameRate * 2),
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 2,
        ]
        for (key, value) in settings {
            VTSessionSetProperty(created, key: key, value: value as CFTypeRef)
        }
        VTCompressionSessionPrepareToEncodeFrames(created)
        session = created
    }

    // MARK: Output

    private func emit(_ sample: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sample), let format = CMSampleBufferGetFormatDescription(sample) else { return }
        var isKeyframe = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first, first[kCMSampleAttachmentKey_NotSync] as? Bool == true {
            isKeyframe = false
        }
        if isKeyframe {
            let sets = Self.parameterSets(format)
            lock.lock()
            let changed = sets != lastParameterSets
            if changed { lastParameterSets = sets }
            let w = width, h = height
            lock.unlock()
            if changed, !sets.isEmpty {
                onFormat?(WirelessVideoFormat(codec: "avc1", width: w, height: h, parameterSets: sets, frameRate: Self.frameRate))
            }
        }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
              let pointer else { return }
        let data = Data(bytes: pointer, count: length)
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        onFrame?(WirelessVideoFrame(pts: Self.nanos(pts), isKeyframe: isKeyframe, data: data))
    }

    static func parameterSets(_ format: CMFormatDescription) -> [Data] {
        var count = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                                 parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                                 nalUnitHeaderLengthOut: nil) == noErr else { return [] }
        return (0..<count).compactMap { index in
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                     parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                     nalUnitHeaderLengthOut: nil) == noErr, let pointer else { return nil }
            return Data(bytes: pointer, count: size)
        }
    }

    static func nanos(_ time: CMTime) -> Int64 {
        guard time.isValid, time.timescale != 0 else { return 0 }
        return Int64((Double(time.value) / Double(time.timescale)) * 1_000_000_000)
    }

    // MARK: Rotation

    /// Upright copy of `buffer` (or `buffer` itself when already upright).
    /// CGImagePropertyOrientation says how the STORED pixels relate to the
    /// intended display: `.right` needs a 90° clockwise turn, `.left` 90°
    /// counter-clockwise, `.down` 180°.
    private func rotate(_ buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> CVPixelBuffer? {
        let turn: CFString
        switch orientation {
        case .up, .upMirrored: return buffer
        case .right, .rightMirrored: turn = kVTRotation_CW90
        case .left, .leftMirrored: turn = kVTRotation_CCW90
        case .down, .downMirrored: turn = kVTRotation_180
        @unknown default: return buffer
        }
        lock.lock(); defer { lock.unlock() }
        if rotation == nil {
            var created: VTPixelRotationSession?
            guard VTPixelRotationSessionCreate(nil, &created) == noErr, let created else { return buffer }
            rotation = created
        }
        guard let rotation else { return buffer }
        VTSessionSetProperty(rotation, key: kVTPixelRotationPropertyKey_Rotation, value: turn)
        let srcW = CVPixelBufferGetWidth(buffer), srcH = CVPixelBufferGetHeight(buffer)
        let quarter = turn == kVTRotation_CW90 || turn == kVTRotation_CCW90
        let dstW = quarter ? srcH : srcW, dstH = quarter ? srcW : srcH
        if rotationPool == nil || poolSize != (dstW, dstH) {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: CVPixelBufferGetPixelFormatType(buffer),
                kCVPixelBufferWidthKey: dstW,
                kCVPixelBufferHeightKey: dstH,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary, attributes as CFDictionary, &pool)
            rotationPool = pool
            poolSize = (dstW, dstH)
        }
        guard let rotationPool else { return buffer }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, rotationPool, &out) == kCVReturnSuccess, let out,
              VTPixelRotationSessionRotateImage(rotation, buffer, out) == noErr else { return nil }
        return out
    }
}
