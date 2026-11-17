#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// The cursor artwork behind `CursorStyleProvider` (which keeps the style
/// mapping, hotspots and caches). The Mac branch is the provider's NSCursor /
/// NSBezierPath / NSBitmapImageRep code, verbatim.
enum CursorArt {
    /// The system pointing-hand cursor and its hotspot. iOS has no system
    /// cursors: there it is the Mac's own NSCursor.pointingHand, bundled byte
    /// for byte (`BundledHand`). nil only if those resources are missing — the
    /// provider then draws the arrow.
    static func systemPointingHand() -> (image: PlatformImage, hotSpot: CGPoint)? {
        #if canImport(AppKit)
        return (NSCursor.pointingHand.image, NSCursor.pointingHand.hotSpot)
        #else
        guard let hand = BundledHand.shared else { return nil }
        return (hand.image, BundledHand.hotSpot)
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

    /// The preview cursor layer's contents: `image` shown at `size` points at
    /// `contentsScale`. The Mac hands Core Animation the vector NSImage, which
    /// CA re-renders at size × scale every time the layer resizes; iOS draws
    /// the same vector art (`rasterize`, byte-identical to the Mac's rasters)
    /// at that pixel grid, so a scaled cursor is as crisp as the Mac's.
    static func layerContents(
        _ image: PlatformImage,
        style: ProjectSettings.CursorStyle,
        size: CGSize,
        contentsScale: CGFloat
    ) -> Any? {
        #if canImport(AppKit)
        return image
        #else
        let w = max(1, Int((size.width * contentsScale).rounded(.up)))
        let h = max(1, Int((size.height * contentsScale).rounded(.up)))
        let key = "\(style.rawValue)|\(w)x\(h)"
        if let cached = layerContentsCache[key] { return cached }
        guard let raster = rasterize(image, style: style, pixelWidth: w, pixelHeight: h) else {
            return image.cgImage
        }
        if layerContentsCache.count > 32 { layerContentsCache.removeAll() }
        layerContentsCache[key] = raster
        return raster
        #endif
    }

    #if !canImport(AppKit)
    private static var layerContentsCache: [String: CGImage] = [:]
    #endif

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
        // The Hand is a bitmap on the Mac too: draw the Mac's rep the way
        // NSImage does (`BundledHand.rasterize`).
        if style == .hand, let hand = BundledHand.shared {
            return hand.rasterize(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        }
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
        case .system, .hand:  // .hand only without the bundled hand: the arrow stands in
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

    /// The dot / ring, into the current UIKit context, on the Mac's ovals
    /// (`appKitOval`).
    private static func drawDotPath(filled: Bool) {
        if filled {
            let outer = appKitOval(CGRect(x: 1.5, y: 1.5, width: 21, height: 21))
            UIColor.black.withAlphaComponent(0.55).setStroke()
            outer.lineWidth = 1.5
            outer.stroke()
            UIColor.white.setFill()
            appKitOval(CGRect(x: 2.5, y: 2.5, width: 19, height: 19)).fill()
            UIColor.black.withAlphaComponent(0.25).setFill()
            appKitOval(CGRect(x: 8.5, y: 8.5, width: 7, height: 7)).fill()
        } else {
            let ring = appKitOval(CGRect(x: 3, y: 3, width: 18, height: 18))
            UIColor.black.withAlphaComponent(0.55).setStroke()
            ring.lineWidth = 5
            ring.stroke()
            UIColor.white.setStroke()
            ring.lineWidth = 3
            ring.stroke()
        }
    }

    /// `NSBezierPath(ovalIn:)` of the Mac's unflipped 24 × 24 pt dot image,
    /// placed in UIKit's y-down drawing space. Not `UIBezierPath(ovalIn:)`:
    /// that is CGPath's ellipse (starts at 0°, closed), while AppKit's oval is
    /// four 90° arcs from −45°, counter-clockwise in its y-up space, and OPEN —
    /// the stroke's start/end and every curve's flattening differ, which moved
    /// the ring's and dot's anti-aliased edges by up to 36/255 (measured by
    /// ios-vectors.sh's cursor rasters). Points match AppKit's within 1e-14;
    /// mirrored (y → 24 − y) so they land on the Mac's bitmap pixels.
    private static func appKitOval(_ r: CGRect) -> UIBezierPath {
        let cx = r.midX, cy = r.midY, rx = r.width / 2, ry = r.height / 2
        let k = 4.0 / 3.0 * tan(Double.pi / 8)
        func p(_ t: Double) -> CGPoint { CGPoint(x: cx + rx * cos(t), y: cy + ry * sin(t)) }
        func d(_ t: Double) -> CGVector { CGVector(dx: -rx * sin(t), dy: ry * cos(t)) }
        func uikit(_ q: CGPoint) -> CGPoint { CGPoint(x: q.x, y: 24 - q.y) }
        let path = UIBezierPath()
        var t0 = -Double.pi / 4
        path.move(to: uikit(p(t0)))
        for _ in 0..<4 {
            let t1 = t0 + Double.pi / 2
            let a = p(t0), b = p(t1), da = d(t0), db = d(t1)
            path.addCurve(
                to: uikit(b),
                controlPoint1: uikit(CGPoint(x: a.x + k * da.dx, y: a.y + k * da.dy)),
                controlPoint2: uikit(CGPoint(x: b.x - k * db.dx, y: b.y - k * db.dy))
            )
            t0 = t1
        }
        return path
    }

    /// The point-size image's own raster; export redraws the paths at the
    /// exact pixel size (`rasterize`), so this only feeds point sizes.
    private static func rasterFormat() -> UIGraphicsImageRendererFormat {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = false
        return format
    }

    /// macOS's `NSCursor.pointingHand`, which iOS does not have: a 32 × 32 pt
    /// cursor, hotspot (13, 8), with a 32 px and a 64 px bitmap rep. Bundled as
    /// those reps exactly as the Mac's `rasterize` draws them at 1× and 2× —
    /// the premultiplied RGBA8 bytes (rows top-down) that the Mac's
    /// `--web-cursor-sprites` writes, the same bytes the web editor ships
    /// (apps/web/public/editor/cursors/manifest.json) — as `hand@1x.rgba` /
    /// `hand@2x.rgba` (apps/ios/StudioResources/Cursors/, added to the app and
    /// StudioLab by gen-xcodeproj.py). Raw bytes, not PNG: no decoder or
    /// re-premultiplication touches them.
    private struct BundledHand {
        static let hotSpot = CGPoint(x: 13, y: 8)
        static let shared: BundledHand? = load()

        let small: CGImage  // the 32 px rep
        let large: CGImage  // the 64 px rep
        /// The cursor at its 32 × 32 pt size (the 64 px rep at scale 2).
        let image: UIImage

        private static func load() -> BundledHand? {
            guard let small = rep("hand@1x", pixels: 32),
                  let large = rep("hand@2x", pixels: 64) else { return nil }
            return BundledHand(
                small: small, large: large,
                image: UIImage(cgImage: large, scale: 2, orientation: .up)
            )
        }

        /// A bundled raw raster as a CGImage over exactly its bytes:
        /// device RGB (the Mac raster's space), premultiplied last.
        private static func rep(_ name: String, pixels: Int) -> CGImage? {
            guard let url = Bundle.main.url(forResource: name, withExtension: "rgba"),
                  let data = try? Data(contentsOf: url),
                  data.count == pixels * pixels * 4,
                  let provider = CGDataProvider(data: data as CFData)
            else { return nil }
            return CGImage(
                width: pixels, height: pixels, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: pixels * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
            )
        }

        /// The Mac's `rasterize` of the hand: NSImage draws the rep that fits
        /// the destination's pixels — the 32 px rep up to 32 px, the 64 px rep
        /// above — scaled onto the grid with high-quality interpolation and
        /// `.copy` into a premultiplied device-RGB bitmap.
        func rasterize(pixelWidth: Int, pixelHeight: Int) -> CGImage? {
            let rep = pixelWidth <= small.width && pixelHeight <= small.height ? small : large
            guard let ctx = CGContext(
                data: nil, width: pixelWidth, height: pixelHeight,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            ctx.interpolationQuality = .high
            ctx.setBlendMode(.copy)
            ctx.draw(rep, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
            return ctx.makeImage()
        }
    }
    #endif
}
