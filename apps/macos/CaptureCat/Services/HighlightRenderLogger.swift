import Foundation
import CoreGraphics
import OSLog

enum HighlightRenderLogger {
#if DEBUG
    private static let logger = Logger(subsystem: "so.capturecat.CaptureCat", category: "HighlightRender")
#endif

    static func logPreview(
        regionID: UUID,
        currentTime: TimeInterval,
        zoom: Double,
        canvasRect: CGRect,
        dimRect: CGRect,
        videoRect: CGRect,
        highlightRect: CGRect,
        isSelected: Bool
    ) {
#if DEBUG
        let timeString = String(format: "%.3f", currentTime)
        let zoomString = String(format: "%.3f", zoom)
        logger.debug(
            "preview id=\(regionID.uuidString, privacy: .public) t=\(timeString, privacy: .public) zoom=\(zoomString, privacy: .public) selected=\(isSelected, privacy: .public) canvas=\(String(describing: canvasRect), privacy: .public) dim=\(String(describing: dimRect), privacy: .public) video=\(String(describing: videoRect), privacy: .public) highlight=\(String(describing: highlightRect), privacy: .public)"
        )
#endif
    }

    static func logExport(
        regionID: UUID,
        currentTime: TimeInterval,
        frameExtent: CGRect,
        dimRect: CGRect,
        videoRect: CGRect,
        highlightRect: CGRect,
        opacity: CGFloat
    ) {
#if DEBUG
        let timeString = String(format: "%.3f", currentTime)
        let opacityString = String(format: "%.3f", opacity)
        logger.debug(
            "export id=\(regionID.uuidString, privacy: .public) t=\(timeString, privacy: .public) opacity=\(opacityString, privacy: .public) frame=\(String(describing: frameExtent), privacy: .public) dim=\(String(describing: dimRect), privacy: .public) video=\(String(describing: videoRect), privacy: .public) highlight=\(String(describing: highlightRect), privacy: .public)"
        )
#endif
    }
}
