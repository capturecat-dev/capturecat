import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Screenshots and videos → inbox takes, shaped exactly like the Mac's own
/// captures so they open there as ordinary projects:
/// • a screenshot becomes an 8-second still movie (`StillMovieWriter`, the
///   Mac's own writer, compiled from the Mac tree) with `isStillCapture`;
/// • a video is copied as-is.
/// iPhone-shaped frames are `recordingSourceKind: "device"` (bezel on Mac/web).
nonisolated enum MediaImport {
    enum ImportError: LocalizedError {
        case unreadableImage
        case unsupportedVideo

        var errorDescription: String? {
            switch self {
            case .unreadableImage: return "That image couldn't be read."
            case .unsupportedVideo: return "That video format isn't supported."
            }
        }
    }

    static func defaultName(for kind: PendingTake.Kind, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d 'at' h.mm.ss a"
        let stamp = formatter.string(from: date)
        switch kind {
        case .screenshot: return "Screenshot \(stamp)"
        case .screenRecording: return "Screen Recording \(stamp)"
        case .importedVideo: return "Video \(stamp)"
        }
    }

    /// Image bytes (PNG/JPEG/HEIC…) → a still-capture take in the inbox.
    static func screenshot(data: Data, name: String? = nil, createdAt: Date = Date()) async throws -> PendingTake {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 8192,
              ] as CFDictionary) else {
            throw ImportError.unreadableImage
        }
        let id = UUID().uuidString
        let folder = try TakeInbox.makeFolder(id: id)
        let movie = folder.appendingPathComponent("recording.mp4")
        let size = try await StillMovieWriter.write(image: image, to: movie)
        let take = PendingTake(
            id: id,
            kind: .screenshot,
            name: name ?? defaultName(for: .screenshot, date: createdAt),
            createdAt: createdAt,
            mediaFile: "recording.mp4",
            contentType: "video/mp4",
            duration: StillMovieWriter.defaultDuration,
            pixelWidth: Int(size.width),
            pixelHeight: Int(size.height),
            state: .pending,
            error: nil
        )
        try TakeInbox.save(take)
        return take
    }

    /// A movie file → a take (copied; the source is left alone).
    static func video(at url: URL, kind: PendingTake.Kind = .importedVideo, name: String? = nil, createdAt: Date = Date()) async throws -> PendingTake {
        let ext = url.pathExtension.lowercased()
        let contentType: String
        switch ext {
        case "mov": contentType = "video/quicktime"
        case "mp4": contentType = "video/mp4"
        case "m4v": contentType = "video/x-m4v"
        default: throw ImportError.unsupportedVideo
        }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        var width = 0, height = 0
        if let track = try await asset.loadTracks(withMediaType: .video).first {
            let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
            let rect = CGRect(origin: .zero, size: natural).applying(transform)
            width = Int(abs(rect.width).rounded())
            height = Int(abs(rect.height).rounded())
        }
        guard duration.isFinite, duration > 0, width > 0 else { throw ImportError.unsupportedVideo }

        let id = UUID().uuidString
        let folder = try TakeInbox.makeFolder(id: id)
        let file = "recording.\(ext)"
        let destination = folder.appendingPathComponent(file)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: url, to: destination)
        let take = PendingTake(
            id: id,
            kind: kind,
            name: name ?? defaultName(for: kind == .importedVideo && PendingTake.sourceKind(width: width, height: height) == "device" ? .screenRecording : kind, date: createdAt),
            createdAt: createdAt,
            mediaFile: file,
            contentType: contentType,
            duration: duration,
            pixelWidth: width,
            pixelHeight: height,
            state: .pending,
            error: nil
        )
        try TakeInbox.save(take)
        return take
    }
}
