import CoreGraphics
import Foundation
import ScreenCaptureKit

/// One-frame capture of a display, window or area.
///
/// Uses `SCScreenshotManager` rather than the deprecated `CGDisplayCreateImage`
/// or `CGWindowListCreateImage`: those bypass ScreenCaptureKit's picker and are
/// increasingly restricted, and they cannot capture a window that is occluded.
///
/// Shares `CaptureSource` with the recorder so the panel's source selection
/// means exactly the same thing whether you press Record or the shutter.
enum ScreenStillCapture {
    static func capture(_ source: CaptureSource) async throws -> CGImage? {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)

        let filter: SCContentFilter
        var width: Int
        var height: Int
        var cropRect: CGRect?

        switch source {
        case .display(let display):
            filter = SCContentFilter(display: display, excludingWindows: [])
            width = display.width
            height = display.height

        case .window(let window):
            filter = SCContentFilter(desktopIndependentWindow: window)
            width = Int(window.frame.width)
            height = Int(window.frame.height)

        case .area(let display, let rect):
            filter = SCContentFilter(display: display, excludingWindows: [])
            width = display.width
            height = display.height
            cropRect = rect
        case .iosDevice:
            // A connected iPhone is a live CoreMediaIO stream, not a shareable
            // display, so ScreenCaptureKit cannot photograph it. The panel
            // already steers away from this tab in screenshot mode; returning
            // nil keeps that from becoming a crash if it is ever reached.
            return nil
        }
        // `content` is loaded so ScreenCaptureKit has fresh window/display
        // handles; the filter is built from the caller's already-resolved
        // objects, so nothing else needs it.
        _ = content

        let config = SCStreamConfiguration()
        config.width = max(2, width)
        config.height = max(2, height)
        // Capture at the display's real pixel density; a Retina display
        // otherwise yields a soft, half-resolution still.
        config.scalesToFit = false
        config.showsCursor = false
        config.capturesAudio = false

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config)

        guard let crop = cropRect else { return image }
        return image.cropping(to: crop) ?? image
    }
}
