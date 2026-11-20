import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// What the export sheet offers and the rules behind its rows — ONE
/// definition for the Mac's `ExportSheetController` and the iOS export sheet
/// (Studio 3d, `apps/ios/StudioUI/Export/`). Both sheets edit the same
/// `ExportSettings` and hand it to the same `VideoExporter` /
/// `StillImageExporter`; this keeps their choices, captions and file types
/// from drifting.
enum ExportSheetSpec {
    /// What the sheet produces. `.image` (a PNG through `StillImageExporter`)
    /// is offered only for still captures in Image treatment.
    enum OutputKind: Equatable {
        case image
        case video
    }

    static let formats = ExportSettings.Format.allCases
    static let resolutions = ExportSettings.Resolution.allCases
    /// The frame-rate choices (a GIF runs at `GIFExportPolicy.frameRate`).
    static let frameRates = [30, 60]
    static let typeTitles = [
        String(localized: "Image (PNG)", comment: "Export sheet: output type segment"),
        String(localized: "Video (MP4)", comment: "Export sheet: output type segment"),
    ]

    static func frameRateTitle(_ fps: Int) -> String {
        String(localized: "\(fps) fps", comment: "Export sheet: frame rate option, frames per second")
    }

    /// The index of `fps` among `frameRates` (anything else reads as 60, the Mac's rule).
    static func frameRateIndex(_ fps: Int) -> Int { fps == 30 ? 0 : 1 }

    /// The Type row (Image (PNG) | Video (MP4)) is built only for still
    /// captures in Image treatment.
    static func offersImage(_ project: Project) -> Bool {
        project.isImageCapture && project.stillTreatment == .image
    }

    /// With no timed effects the still IS an image, so PNG is the default;
    /// any motion (zoom, curtain, …) defaults the sheet back to video.
    static func defaultOutputKind(for project: Project) -> OutputKind {
        guard offersImage(project) else { return .video }
        return project.hasTimedEffects ? .video : .image
    }

    static func title(for kind: OutputKind) -> String {
        kind == .image
            ? String(localized: "Export Image", comment: "Export sheet title / background task title")
            : String(localized: "Export Video", comment: "Export sheet title / background task title")
    }

    /// Share links carry video only: never for a PNG or a GIF.
    static func canShare(kind: OutputKind, format: ExportSettings.Format) -> Bool {
        kind == .video && format != .gif
    }

    /// The caption under the quality row: the GIF's size / rate, or the
    /// video's preset, size, rate and bit rate. The letterboxed preview canvas
    /// carries the resolved output aspect (Auto = source aspect), so it stands
    /// in for the source size and the caption's W×H is what the exporter writes.
    static func caption(settings: ExportSettings, project: Project) -> String {
        if settings.format == .gif {
            return GIFExportPolicy.caption(
                outputSize: settings.resolvedOutputSize(
                    for: project.settings.aspectRatio, sourceSize: project.previewCanvasSize),
                requestedFPS: settings.fps)
        }
        return settings.estimatedBitRateDescription(
            for: project.settings.aspectRatio, sourceSize: project.previewCanvasSize)
    }

    /// The file the export writes: extension and type by format (`VideoExporter`
    /// picks the GIF path by the destination's extension).
    static func fileType(kind: OutputKind, format: ExportSettings.Format) -> (contentType: UTType, ext: String) {
        if kind == .image { return (.png, "png") }
        switch format {
        case .mp4: return (.mpeg4Movie, "mp4")
        case .mov: return (.quickTimeMovie, "mov")
        case .gif: return (.gif, "gif")
        }
    }

    /// The settings an iPhone's sheet opens with (docs/ios-studio-plan.md,
    /// "iOS-specific concerns": 1080p30 by default on iPhone — a phone's
    /// memory and heat budget, ExportTuning). Format, quality, custom size and
    /// fast export keep the project's values; the user can still pick any
    /// resolution and rate for the export.
    static func phoneDefaults(_ saved: ExportSettings) -> ExportSettings {
        var settings = saved
        settings.resolution = .hd1080
        settings.fps = 30
        return settings
    }
}
