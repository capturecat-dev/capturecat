#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// The cursor artwork behind `CursorStyleProvider` (which keeps the style
/// mapping, hotspots and caches). The Mac branch is the provider's NSCursor /
/// NSBezierPath / NSBitmapImageRep code, verbatim.
enum CursorArt {
    /// The system pointing-hand cursor and its hotspot. nil on iOS, which has
    /// no system cursor; the provider draws the arrow there instead.
    static func systemPointingHand() -> (image: PlatformImage, hotSpot: CGPoint)? {
        #if canImport(AppKit)
        return (NSCursor.pointingHand.image, NSCursor.pointingHand.hotSpot)
        #else
        return nil
        #endif
    }

    /// `.system`: black arrow, white outline, black outer outline. Tip at (2, 2).
    static func systemArrow() -> PlatformImage {
        drawnArrow(fill: .black, outline: .white, outerOutline: .black)
    }

    /// `.inverted`: white arrow, black outline. Tip at (2, 2).
    static func invertedArrow() -> PlatformImage {
        drawnArrow(fill: .white, outline: .black)
    }

    /// `.dot` (filled) / `.ring` (hollow). Hotspot centred at (12, 12).
    static func dot(filled: Bool) -> PlatformImage {
        drawnDot(filled: filled)
    }

    /// Rasterizes `image` (the artwork of `style`) onto an exact
    /// `pixelWidth` × `pixelHeight` grid, upright, RGBA premultiplied.
    static func rasterize(
        _ image: PlatformImage,
        style: ProjectSettings.CursorStyle,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> CGImage? {
        #if canImport(AppKit)
        guard image.size.width > 0,
              image.size.height > 0,
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

        // The rep keeps the cursor's POINT size so the raster reports the same
        // dimensions as the NSImage it came from, but that alone does not scale
        // the drawing: `NSGraphicsContext(bitmapImageRep:)` fixed its CTM at
        // 1 pixel per point when it was created above, so the sprite used to
        // land as a 1× drawing in one corner of the larger bitmap. The exporter
        // then stretched that mostly-transparent bitmap into the layout rect and
        // the visible arrow came out 1/rasterScale of the preview's (measured
        // by `--cursor-export-parity`). Scale the CTM explicitly so the vector
        // artwork fills the requested pixel grid.
        bitmap.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        graphicsContext.imageInterpolation = .high
        graphicsContext.cgContext.setShouldAntialias(true)
        graphicsContext.cgContext.setAllowsAntialiasing(true)
        graphicsContext.cgContext.scaleBy(
            x: CGFloat(pixelWidth) / image.size.width,
            y: CGFloat(pixelHeight) / image.size.height
        )
        image.draw(
            in: CGRect(origin: .zero, size: image.size),
            from: CGRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        graphicsContext.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        return bitmap.cgImage
        #else
        // The Mac redraws its vector NSImage at the scaled CTM; a UIImage is
        // already a raster, so redraw the same vector paths instead.
        let size = image.size
        guard size.width > 0, size.height > 0,
              let ctx = CGContext(
                  data: nil, width: pixelWidth, height: pixelHeight,
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.setShouldAntialias(true)
        ctx.setAllowsAntialiasing(true)
        // UIKit drawing is y-down; the bitmap is y-up.
        ctx.translateBy(x: 0, y: CGFloat(pixelHeight))
        ctx.scaleBy(x: 1, y: -1)
        ctx.scaleBy(x: CGFloat(pixelWidth) / size.width, y: CGFloat(pixelHeight) / size.height)
        UIGraphicsPushContext(ctx)
        switch style {
        case .system, .hand:
            drawArrowPath(fill: .black, outline: .white, outerOutline: .black)
        case .inverted:
            drawArrowPath(fill: .white, outline: .black)
        case .dot:
            drawDotPath(filled: true)
        case .ring:
            drawDotPath(filled: false)
        }
        UIGraphicsPopContext()
        return ctx.makeImage()
        #endif
    }

    #if canImport(AppKit)
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
    #else
    /// UIKit twin of the Mac arrow (UIKit is y-down, like the Mac's flipped image).
    private static func drawnArrow(
        fill: UIColor,
        outline: UIColor,
        outerOutline: UIColor? = nil
    ) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 20, height: 28), format: rasterFormat()).image { _ in
            drawArrowPath(fill: fill, outline: outline, outerOutline: outerOutline)
        }
    }

    private static func drawnDot(filled: Bool) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24), format: rasterFormat()).image { _ in
            drawDotPath(filled: filled)
        }
    }

    /// The arrow path, stroked and filled into the current UIKit context.
    private static func drawArrowPath(fill: UIColor, outline: UIColor, outerOutline: UIColor? = nil) {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 2, y: 2))
        path.addLine(to: CGPoint(x: 2, y: 23.6))
        path.addLine(to: CGPoint(x: 7.0, y: 19.0))
        path.addLine(to: CGPoint(x: 10.6, y: 26.4))
        path.addLine(to: CGPoint(x: 14.2, y: 24.7))
        path.addLine(to: CGPoint(x: 10.6, y: 17.5))
        path.addLine(to: CGPoint(x: 17.2, y: 17.5))
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
    }

    /// The dot / ring, into the current UIKit context. Both are symmetric
    /// about the centre, so the Mac's unflipped image needs no flip here.
    private static func drawDotPath(filled: Bool) {
        if filled {
            let outer = UIBezierPath(ovalIn: CGRect(x: 1.5, y: 1.5, width: 21, height: 21))
            UIColor.black.withAlphaComponent(0.55).setStroke()
            outer.lineWidth = 1.5
            outer.stroke()
            UIColor.white.setFill()
            UIBezierPath(ovalIn: CGRect(x: 2.5, y: 2.5, width: 19, height: 19)).fill()
            UIColor.black.withAlphaComponent(0.25).setFill()
            UIBezierPath(ovalIn: CGRect(x: 8.5, y: 8.5, width: 7, height: 7)).fill()
        } else {
            let ring = UIBezierPath(ovalIn: CGRect(x: 3, y: 3, width: 18, height: 18))
            UIColor.black.withAlphaComponent(0.55).setStroke()
            ring.lineWidth = 5
            ring.stroke()
            UIColor.white.setStroke()
            ring.lineWidth = 3
            ring.stroke()
        }
    }

    /// The point-size image's own raster; export redraws the paths at the
    /// exact pixel size (`rasterize`), so this only feeds point sizes.
    private static func rasterFormat() -> UIGraphicsImageRendererFormat {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = false
        return format
    }
    #endif
}
