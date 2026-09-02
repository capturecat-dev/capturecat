import AppKit

/// Single source for the rendered cursor artwork — the preview overlay, the
/// Cursor tab's demo box, and the exporter all pull the same image + hotspot,
/// so every style looks identical everywhere.
enum CursorStyleProvider {
    private static var cache: [ProjectSettings.CursorStyle: (image: NSImage, hotSpot: CGPoint)] = [:]
    private struct RasterKey: Hashable {
        let style: ProjectSettings.CursorStyle
        let width: Int
        let height: Int
    }
    private static var rasterCache: [RasterKey: CGImage] = [:]

    static func asset(for style: ProjectSettings.CursorStyle) -> (image: NSImage, hotSpot: CGPoint) {
        switch style {
        case .hand:
            return (NSCursor.pointingHand.image, NSCursor.pointingHand.hotSpot)
        default:
            break
        }
        if let cached = cache[style] { return cached }
        let built: (NSImage, CGPoint)
        switch style {
        case .system:
            // NSCursor.arrow.image is a tiny raster. Scaling it for the editor's
            // 3× cursor option visibly blurs the edge, so draw the same classic
            // silhouette as vector artwork instead.
            built = (
                drawnArrow(fill: .black, outline: .white, outerOutline: .black),
                CGPoint(x: 2, y: 2)
            )
        case .hand:
            built = (NSCursor.pointingHand.image, NSCursor.pointingHand.hotSpot)
        case .inverted:
            built = (drawnArrow(fill: .white, outline: .black), CGPoint(x: 2, y: 2))
        case .dot:
            built = (drawnDot(filled: true), CGPoint(x: 12, y: 12))
        case .ring:
            built = (drawnDot(filled: false), CGPoint(x: 12, y: 12))
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
        guard asset.image.size.width > 0,
              asset.image.size.height > 0,
              let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixelWidth,
                pixelsHigh: pixelHeight,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bitmapFormat: [],
                bytesPerRow: 0,
                bitsPerPixel: 0
              ),
              let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap)
        else { return nil }

        // Giving the rep the cursor's point size makes AppKit apply the pixel
        // density while invoking the NSImage drawing handler. Vector-backed
        // styles are therefore drawn directly at the requested resolution.
        bitmap.size = asset.image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        graphicsContext.imageInterpolation = .high
        graphicsContext.cgContext.setShouldAntialias(true)
        graphicsContext.cgContext.setAllowsAntialiasing(true)
        asset.image.draw(
            in: CGRect(origin: .zero, size: asset.image.size),
            from: CGRect(origin: .zero, size: asset.image.size),
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        graphicsContext.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let cgImage = bitmap.cgImage else { return nil }
        // Live window resizing can produce many adjacent pixel sizes. Cursor
        // rasters are cheap to rebuild; keep the cache bounded instead of
        // retaining every intermediate resize forever.
        if rasterCache.count >= 64 {
            rasterCache.removeAll(keepingCapacity: true)
        }
        rasterCache[key] = cgImage
        return cgImage
    }

    /// Classic macOS arrow silhouette, drawn as a vector so it stays crisp at
    /// any cursor scale. Tip at (2, 2).
    private static func drawnArrow(
        fill: NSColor,
        outline: NSColor,
        outerOutline: NSColor? = nil
    ) -> NSImage {
        let size = NSSize(width: 20, height: 28)
        return NSImage(size: size, flipped: true) { _ in
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 2, y: 2))
            path.line(to: NSPoint(x: 2, y: 23.6))
            path.line(to: NSPoint(x: 7.0, y: 19.0))
            path.line(to: NSPoint(x: 10.6, y: 26.4))
            path.line(to: NSPoint(x: 14.2, y: 24.7))
            path.line(to: NSPoint(x: 10.6, y: 17.5))
            path.line(to: NSPoint(x: 17.2, y: 17.5))
            path.close()
            path.lineJoinStyle = .round
            if let outerOutline {
                outerOutline.setStroke()
                path.lineWidth = 4
                path.stroke()
            }
            outline.setStroke()
            path.lineWidth = 2.4
            path.stroke()
            fill.setFill()
            path.fill()
            return true
        }
    }

    /// Round pointer — high-visibility dot (or hollow ring), hotspot centered.
    private static func drawnDot(filled: Bool) -> NSImage {
        let size = NSSize(width: 24, height: 24)
        return NSImage(size: size, flipped: false) { _ in
            if filled {
                let outer = NSBezierPath(ovalIn: NSRect(x: 1.5, y: 1.5, width: 21, height: 21))
                NSColor.black.withAlphaComponent(0.55).setStroke()
                outer.lineWidth = 1.5
                outer.stroke()
                NSColor.white.setFill()
                NSBezierPath(ovalIn: NSRect(x: 2.5, y: 2.5, width: 19, height: 19)).fill()
                NSColor.black.withAlphaComponent(0.25).setFill()
                NSBezierPath(ovalIn: NSRect(x: 8.5, y: 8.5, width: 7, height: 7)).fill()
            } else {
                let ring = NSBezierPath(ovalIn: NSRect(x: 3, y: 3, width: 18, height: 18))
                NSColor.black.withAlphaComponent(0.55).setStroke()
                ring.lineWidth = 5
                ring.stroke()
                NSColor.white.setStroke()
                ring.lineWidth = 3
                ring.stroke()
            }
            return true
        }
    }
}
