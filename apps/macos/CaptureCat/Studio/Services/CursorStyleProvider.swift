import CoreGraphics
import Foundation

/// Single source for the rendered cursor artwork — the preview overlay, the
/// Cursor tab's demo box, and the exporter all pull the same image + hotspot,
/// so every style looks identical everywhere. The artwork itself is platform
/// drawing (`CursorArt`); on the Mac the image is an NSImage, which the
/// preview's cursor layer needs (raw CGImage contents orient differently).
enum CursorStyleProvider {
    private static var cache: [ProjectSettings.CursorStyle: (image: PlatformImage, hotSpot: CGPoint)] = [:]
    private struct RasterKey: Hashable {
        let style: ProjectSettings.CursorStyle
        let width: Int
        let height: Int
    }
    private static var rasterCache: [RasterKey: CGImage] = [:]

    static func asset(for style: ProjectSettings.CursorStyle) -> (image: PlatformImage, hotSpot: CGPoint) {
        switch style {
        case .hand:
            if let hand = CursorArt.systemPointingHand() { return hand }
        default:
            break
        }
        if let cached = cache[style] { return cached }
        let built: (PlatformImage, CGPoint)
        switch style {
        case .system:
            // NSCursor.arrow.image is a tiny raster. Scaling it for the editor's
            // 3× cursor option visibly blurs the edge, so draw the same classic
            // silhouette as vector artwork instead.
            built = (CursorArt.systemArrow(), CGPoint(x: 2, y: 2))
        case .hand:
            // Only reached when there is no hand art (iOS without its bundled
            // copy of the Mac's cursor): the drawn arrow stands in.
            built = CursorArt.systemPointingHand() ?? (CursorArt.systemArrow(), CGPoint(x: 2, y: 2))
        case .inverted:
            built = (CursorArt.invertedArrow(), CGPoint(x: 2, y: 2))
        case .dot:
            built = (CursorArt.dot(filled: true), CGPoint(x: 12, y: 12))
        case .ring:
            built = (CursorArt.dot(filled: false), CGPoint(x: 12, y: 12))
        }
        cache[style] = built
        return built
    }

    /// Rasterizes the shared cursor artwork at the exact pixel density a
    /// consumer needs. CALayer and CoreImage otherwise snapshot an NSImage at
    /// its small intrinsic size and enlarge that bitmap, which is what made the
    /// cursor soft in both the editor and exported video.
    static func rasterizedCGImage(
        for style: ProjectSettings.CursorStyle,
        pixelSize: CGSize
    ) -> CGImage? {
        let pixelWidth = max(1, Int(ceil(pixelSize.width)))
        let pixelHeight = max(1, Int(ceil(pixelSize.height)))
        let key = RasterKey(style: style, width: pixelWidth, height: pixelHeight)
        if let cached = rasterCache[key] { return cached }

        let asset = asset(for: style)
        guard let cgImage = CursorArt.rasterize(
            asset.image, style: style, pixelWidth: pixelWidth, pixelHeight: pixelHeight
        ) else { return nil }
        // Live window resizing can produce many adjacent pixel sizes. Cursor
        // rasters are cheap to rebuild; keep the cache bounded instead of
        // retaining every intermediate resize forever.
        if rasterCache.count >= 64 {
            rasterCache.removeAll(keepingCapacity: true)
        }
        rasterCache[key] = cgImage
        return cgImage
    }
}
