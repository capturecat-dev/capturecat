import CoreGraphics
import CoreImage

/// The iPhone 16 Pro bezel drawn in CoreImage's Y-UP space — the screen's TOP
/// is `videoRect.maxY`. Lives in its own file so the exporter and offline
/// render harnesses share one implementation, and so every visual constant
/// traces back to `DeviceFrameLayout`.
///
/// Drawing itself lives in `DeviceBezelRenderer`, shared with the preview.
enum DeviceFrameRenderer {
    static func deviceFrameBitmapContext(extent: CGRect) -> CGContext? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(
            data: nil,
            width: Int(extent.width),
            height: Int(extent.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        )
    }

    /// The titanium body: metallic band, polished rim, contact shadow, and the
    /// black glass margin — plus the side buttons that peek out from behind
    /// the band.
    ///
    /// Drawing lives in `DeviceBezelRenderer` (y-DOWN), shared verbatim with
    /// the preview compositor, so the two renderers cannot drift. The exporter
    /// keeps its own LAYER SPLIT — body here, side slab and island in their own
    /// images, its own shadow layer — because those layers move independently
    /// per frame.
    static func makeDeviceBezelImage(extent: CGRect, videoRect: CGRect) -> CIImage? {
        guard let ctx = deviceFrameBitmapContext(extent: extent) else { return nil }
        DeviceBezelRenderer.withYDown(ctx, height: extent.height) { ctx in
            let rect = flip(videoRect, in: extent)
            DeviceBezelRenderer.drawSideButtons(in: ctx, videoRect: rect)
            // shadowOpacity 0: the exporter composites its own shadow layer
            // (makeFrameShadow) under this one.
            DeviceBezelRenderer.drawBody(in: ctx, videoRect: rect,
                                         shadowRadius: 0, shadowOpacity: 0)
        }
        guard let image = ctx.makeImage() else { return nil }
        return CIImage(cgImage: image)
    }

    /// The device's extruded SIDE faces as a standalone layer, baked once and
    /// translated per frame by the tilt offset, then composited UNDER the
    /// bezel.
    static func makeDeviceSideImage(extent: CGRect, videoRect: CGRect) -> CIImage? {
        guard let ctx = deviceFrameBitmapContext(extent: extent) else { return nil }
        DeviceBezelRenderer.withYDown(ctx, height: extent.height) { ctx in
            DeviceBezelRenderer.drawSideSlab(
                in: ctx, videoRect: flip(videoRect, in: extent), offset: .zero)
        }
        guard let image = ctx.makeImage() else { return nil }
        return CIImage(cgImage: image)
    }

    /// Screen seam + Dynamic Island — the layer that sits ABOVE the video.
    static func makeDeviceIslandImage(extent: CGRect, videoRect: CGRect) -> CIImage? {
        guard DeviceFrameLayout.isPhoneAspect(videoRect.size) else { return nil }
        guard let ctx = deviceFrameBitmapContext(extent: extent) else { return nil }
        DeviceBezelRenderer.withYDown(ctx, height: extent.height) { ctx in
            DeviceBezelRenderer.drawIsland(in: ctx, videoRect: flip(videoRect, in: extent))
        }
        guard let image = ctx.makeImage() else { return nil }
        return CIImage(cgImage: image)
    }

    // MARK: - Helpers

    /// CoreImage hands rects in y-UP space; the shared renderer works y-DOWN.
    private static func flip(_ rect: CGRect, in extent: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: extent.height - rect.maxY,
               width: rect.width, height: rect.height)
    }
}
