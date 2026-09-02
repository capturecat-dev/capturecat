import AVFoundation
import AppKit
import Foundation

/// Exports one composed frame of a project as a PNG.
///
/// # Why this rides the video exporter
///
/// Preview must equal export (CLAUDE.md §2), and the ONLY renderer that is
/// gate-proven against the preview is `VideoExporter`. Rather than fork a
/// single-frame composition path out of its 3,500 lines (a copy that would
/// drift), the PNG is produced by running the REAL exporter over a micro clip
/// (a few frames of the still) and lifting one frame out of the result:
///
///   clone project → clamp trim to ~0.2 s → VideoExporter.export → grab the
///   last frame with AVAssetImageGenerator → PNG.
///
/// Every spatial effect — background, padding, shadow, device frame, camera
/// bubble, blur/focus/highlight regions, annotations, watermark — is composed
/// by exactly the code the MP4 path uses, so the PNG can never disagree with
/// the video of the same project. The cost is encoding ~6 H.264 frames at
/// export quality, which is trivial.
///
/// Entrance animations (intro slide, curtain unveil) are neutralized on the
/// clone: a PNG is the SETTLED frame, and at t≈0 those effects would cover it.
/// They are timed effects — the export sheet steers projects that use them to
/// Video anyway.
enum StillImageExporter {
    /// Long enough for a stable non-boundary sample frame, short enough that
    /// the intermediate encode is a handful of frames.
    static let microClipDuration: TimeInterval = 0.2

    enum StillExportError: LocalizedError {
        case cloneFailed
        case frameExtractionFailed(String)
        case pngEncodeFailed

        var errorDescription: String? {
            switch self {
            case .cloneFailed:
                return "Could not prepare the project for image export."
            case .frameExtractionFailed(let s):
                return "Could not read the rendered frame: \(s)"
            case .pngEncodeFailed:
                return "Could not encode the PNG."
            }
        }
    }

    /// Renders the composed frame at the head of the trim range and writes it
    /// as a PNG to `url`. Runs the same auth gate as a video export (the
    /// exporter asserts it internally).
    static func exportPNG(
        project: Project,
        to url: URL,
        exporter: VideoExporter? = nil
    ) async throws {
        // Default built here (not as a default argument) so nonisolated
        // callers don't evaluate the main-actor VideoExporter() initializer.
        let exporter = exporter ?? VideoExporter()
        // Codable round-trip clone: the ONE sanctioned way to copy a Project
        // (hand-rolled Codable is the persistence contract). The live project
        // is never mutated.
        guard let data = try? JSONEncoder().encode(project),
              let clone = try? JSONDecoder().decode(Project.self, from: data) else {
            throw StillExportError.cloneFailed
        }
        // Not part of Codable, but the exporter scales spatial settings by it.
        clone.previewCanvasSize = project.previewCanvasSize

        // Micro clip: first frames of the trim range only.
        let start = clone.effectiveTrimStart
        clone.trimEnd = min(clone.duration, start + microClipDuration)
        // Clip slices/speed only matter over time; drop them so the micro clip
        // is one plain segment regardless of how the still was carved up.
        clone.videoClipSegments = []
        clone.splitPoints = []
        clone.speedRegions = []
        // Settled frame: no entrance animations covering the composition.
        clone.settings.introSlideStyle = .off
        clone.settings.curtainUnveilCorner = .off

        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("capturecat-still-\(UUID().uuidString.prefix(8)).mp4")
        defer { try? FileManager.default.removeItem(at: temp) }

        try await exporter.export(project: clone, to: temp)

        let cgImage = try await lastFrame(of: temp)
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw StillExportError.pngEncodeFailed
        }
        try png.write(to: url, options: .atomic)
    }

    /// The final frame of the micro clip — the most settled sample (cursor
    /// intro fades, first-frame warm-ups etc. have run their course by then).
    private static func lastFrame(of movieURL: URL) async throws -> CGImage {
        let asset = AVURLAsset(url: movieURL)
        let duration: CMTime
        do {
            duration = try await asset.load(.duration)
        } catch {
            throw StillExportError.frameExtractionFailed(error.localizedDescription)
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .zero
        let target = CMTime(
            seconds: max(0, duration.seconds - 0.01), preferredTimescale: 600)
        do {
            var actual = CMTime.zero
            return try generator.copyCGImage(at: target, actualTime: &actual)
        } catch {
            throw StillExportError.frameExtractionFailed(error.localizedDescription)
        }
    }
}
