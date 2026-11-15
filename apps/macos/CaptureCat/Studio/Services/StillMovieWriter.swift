import AVFoundation
import CoreImage
import Foundation

/// Encodes a single still image into a short H.264 movie.
///
/// # Why a movie and not an image project
///
/// `Project` is built around `videoURL`: the editor's preview compositor, the
/// timeline, the playback clock and `VideoExporter` all assume a decodable
/// track. Teaching every one of those about a second, image-shaped source would
/// fork the preview/export math that CLAUDE.md §2 exists to keep unified.
///
/// Encoding the still as a few seconds of video means a screenshot arrives in
/// the editor as an ordinary project and inherits zooms, tilts, annotations,
/// device frames, subtitles and the export path with no special cases. The cost
/// is a small encode up front and a file larger than a PNG — both trivial next
/// to maintaining a parallel still pipeline.
enum StillMovieWriter {
    /// Long enough to place a few annotations against, short enough that the
    /// encode is instant and the file stays small.
    nonisolated static let defaultDuration: TimeInterval = 8
    static let fps: Int32 = 30

    enum WriteError: LocalizedError {
        case cannotCreateWriter(String)
        case encodeFailed(String)

        var errorDescription: String? {
            switch self {
            case .cannotCreateWriter(let s): return "Could not start the encoder: \(s)"
            case .encodeFailed(let s): return "Could not encode the capture: \(s)"
            }
        }
    }

    static func write(
        image: CGImage,
        to url: URL,
        duration: TimeInterval = defaultDuration
    ) async throws -> CGSize {
        // H.264 requires even dimensions; an odd width silently produces a
        // green column down one edge on some decoders.
        let width = image.width - (image.width % 2)
        let height = image.height - (image.height % 2)
        let size = CGSize(width: width, height: height)

        try? FileManager.default.removeItem(at: url)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            throw WriteError.cannotCreateWriter(error.localizedDescription)
        }

        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ]
        )
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )

        guard writer.canAdd(input) else {
            throw WriteError.cannotCreateWriter("writer rejected the video input")
        }
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        guard let pool = adaptor.pixelBufferPool,
              let buffer = makeBuffer(from: image, pool: pool, size: size) else {
            writer.cancelWriting()
            throw WriteError.encodeFailed("could not build a pixel buffer")
        }

        // The SAME buffer is appended at the first and last frame only. A still
        // needs no in-between frames: H.264 encodes the gap as a run of
        // near-zero-cost P-frames, so an 8s clip lands in a few hundred KB
        // instead of 240 full frames.
        let last = CMTime(value: CMTimeValue(duration * Double(fps)), timescale: fps)
        for time in [CMTime.zero, last] {
            while !input.isReadyForMoreMediaData {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            if !adaptor.append(buffer, withPresentationTime: time) {
                writer.cancelWriting()
                throw WriteError.encodeFailed(
                    writer.error?.localizedDescription ?? "append was rejected")
            }
        }

        input.markAsFinished()
        writer.endSession(atSourceTime: last)
        await writer.finishWriting()

        if writer.status != .completed {
            throw WriteError.encodeFailed(
                writer.error?.localizedDescription ?? "writer finished in state \(writer.status.rawValue)")
        }
        return size
    }

    private static func makeBuffer(from image: CGImage, pool: CVPixelBufferPool, size: CGSize) -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess,
              let buffer = out else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        return buffer
    }
}
