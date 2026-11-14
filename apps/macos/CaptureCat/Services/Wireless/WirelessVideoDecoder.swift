import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import os

nonisolated private let decoderLogger = Logger(subsystem: "so.capturecat.CaptureCat", category: "WirelessDecoder")

/// Decodes a phone's `videoFrame` stream with VideoToolbox. Built from a
/// `videoFormat` message's parameter sets; the owner makes a NEW decoder when
/// the format changes (rotation), never patches one. Not thread-safe: the
/// owner calls it from one serial queue.
nonisolated final class WirelessVideoDecoder {
    let format: WirelessVideoFormat
    let formatDescription: CMVideoFormatDescription
    private var session: VTDecompressionSession?

    enum DecoderError: Error {
        case unsupportedCodec(String)
        case badParameterSets(OSStatus)
        case sessionFailed(OSStatus)
    }

    init(format: WirelessVideoFormat) throws {
        self.format = format
        formatDescription = try Self.makeFormatDescription(format)
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &created
        )
        guard status == noErr, let created else { throw DecoderError.sessionFailed(status) }
        VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = created
    }

    deinit {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
    }

    /// Format description for the parameter sets (no start codes, 4-byte
    /// NAL length prefixes in the samples).
    static func makeFormatDescription(_ format: WirelessVideoFormat) throws -> CMVideoFormatDescription {
        let sets = format.parameterSets
        guard !sets.isEmpty else { throw DecoderError.badParameterSets(-1) }
        var description: CMFormatDescription?
        let status: OSStatus = withPointers(sets) { pointers, sizes in
            switch format.codec {
            case "avc1":
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: sets.count,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description
                )
            case "hvc1":
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: sets.count,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    extensions: nil,
                    formatDescriptionOut: &description
                )
            default:
                return kCMFormatDescriptionError_InvalidParameter
            }
        }
        if format.codec != "avc1" && format.codec != "hvc1" { throw DecoderError.unsupportedCodec(format.codec) }
        guard status == noErr, let description else { throw DecoderError.badParameterSets(status) }
        return description
    }

    private static func withPointers<R>(
        _ sets: [Data],
        _ body: (UnsafePointer<UnsafePointer<UInt8>>, UnsafePointer<Int>) -> R
    ) -> R {
        // Copy into stable buffers for the duration of the call.
        let buffers = sets.map { data -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, data.count))
            data.copyBytes(to: p, count: data.count)
            return p
        }
        defer { buffers.forEach { $0.deallocate() } }
        let pointers = buffers.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)
        return pointers.withUnsafeBufferPointer { p in
            sizes.withUnsafeBufferPointer { s in body(p.baseAddress!, s.baseAddress!) }
        }
    }

    /// Decode one AVCC sample synchronously. Returns the decoded frame, or
    /// nil when VideoToolbox produced none (a decode error — the owner asks
    /// the phone for a keyframe).
    func decode(_ frame: WirelessVideoFrame) -> CVPixelBuffer? {
        guard let session, !frame.data.isEmpty else { return nil }
        var blockBuffer: CMBlockBuffer?
        let length = frame.data.count
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let blockBuffer else { return nil }
        status = frame.data.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: blockBuffer,
                                          offsetIntoDestination: 0, dataLength: length)
        }
        guard status == noErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: frame.pts, timescale: 1_000_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = length
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer,
            formatDescription: formatDescription, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample
        )
        guard status == noErr, let sample else { return nil }

        var output: CVPixelBuffer?
        var infoFlags = VTDecodeInfoFlags()
        status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: [], infoFlagsOut: &infoFlags
        ) { decodeStatus, _, imageBuffer, _, _ in
            if decodeStatus == noErr, let imageBuffer { output = imageBuffer }
        }
        if status != noErr {
            decoderLogger.info("decode failed: \(status, privacy: .public)")
            return nil
        }
        return output
    }
}
