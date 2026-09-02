import Foundation
import AVFoundation

/// Applies Auto Zoom to a project from its recorded interaction data: loads
/// cursor/keystroke files, mirrors the preview's smoothing, runs
/// `AutoZoomGenerator`, and merges the result with the project's MANUAL
/// zoom blocks (only earlier auto regions are replaced; generation routes
/// around the user's own blocks).
///
/// One implementation shared by the editor's Auto Zoom button, the MCP
/// `auto_zoom` tool, and the record-stop hook — three call sites that must
/// never drift in how they derive screen size or smoothing.
enum AutoZoomApplier {

    /// Generates and installs auto zoom regions. Returns how many regions
    /// were created (0 = no cursor data or no zoom-worthy activity; the
    /// project is untouched in that case).
    @discardableResult
    static func apply(to project: Project, zoomLevel: Double? = nil) -> Int {
        guard let cursorURL = project.cursorDataURL,
              var cursorEvents = try? CursorTracker.load(from: cursorURL),
              !cursorEvents.isEmpty else { return 0 }

        // Mirrors the preview exactly: smoothing is applied here from the
        // CURRENT settings, never baked in at load, so the two cannot
        // disagree about where the cursor was.
        if project.settings.smoothCursor {
            let smoother = CursorSmoother(factor: project.settings.smoothingFactor)
            cursorEvents = smoother.smooth(events: cursorEvents)
        }

        let screenSize: CGSize
        if let videoURL = project.videoURL {
            let asset = AVURLAsset(url: videoURL)
            let natural = asset.tracks(withMediaType: .video).first?.naturalSize
                ?? CGSize(width: 3840, height: 2160)
            screenSize = CGSize(width: natural.width / 2, height: natural.height / 2)
        } else {
            screenSize = CGSize(width: 1920, height: 1080)
        }

        let keystrokes = project.keystrokeDataURL
            .flatMap { try? KeystrokeTracker.loadRecording(from: $0).events } ?? []

        let manualRegions = project.zoomRegions.filter { $0.isAuto != true }
        let regions = AutoZoomGenerator.generateZoomRegions(
            from: cursorEvents,
            videoDuration: project.duration,
            screenSize: screenSize,
            zoomLevel: zoomLevel ?? project.settings.autoZoomLevel,
            keystrokes: keystrokes,
            existingRegions: manualRegions
        )
        guard !regions.isEmpty else { return 0 }

        project.zoomRegions = (manualRegions + regions).sorted { $0.startTime < $1.startTime }
        return regions.count
    }
}
