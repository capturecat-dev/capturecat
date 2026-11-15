import CoreGraphics
import Foundation

/// The camera styles of docs/camera-cutout.md §12, resolved from the project
/// settings with every default applied and every number clamped — the ONE
/// place both renderers read them from (house rule #2), so the preview and
/// the exporter cannot clamp or default differently.
struct CameraCardStyle: Equatable {
    /// sRGB components, alpha dropped (every §12 colour draws opaque).
    struct RGB: Equatable {
        var r: CGFloat, g: CGFloat, b: CGFloat
        init(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) { self.r = r; self.g = g; self.b = b }
        init(_ c: CodableColor) { self.init(CGFloat(c.red), CGFloat(c.green), CGFloat(c.blue)) }
    }

    /// nil = 0.5 (geometry keeps today's 22 % headroom exactly).
    var popOutAmount: Double?
    var fill: CameraCardFill
    var gradientTop: RGB
    var gradientBottom: RGB
    var color: RGB
    /// Path for the `image` fill (nil / unreadable → the gradient, §12.3).
    var imagePath: String?
    /// Portrait blur of the `camera` fill, 0…1 (0 for every other fill).
    var backgroundBlur: Double
    var edgeSoftness: Double
    var edgeInset: Double
    /// nil = no border ring.
    var border: CameraCardBorder?
    /// Border thickness 0…1 (only meaningful with `border`).
    var borderThickness: Double
    var borderColor: RGB
    var shrinkOnZoom: Bool

    static let defaultCardColor = RGB(0.11, 0.11, 0.13)
    /// §12.3 border gradient presets, sRGB, top → bottom.
    static let auroraTop = RGB(0.36, 0.91, 1.00)
    static let auroraBottom = RGB(0.29, 0.40, 1.00)
    static let goldTop = RGB(1.00, 0.89, 0.52)
    static let goldBottom = RGB(0.85, 0.55, 0.16)

    private static func unit(_ v: Double?) -> Double { min(1, max(0, v ?? 0)) }

    init(_ s: ProjectSettings) {
        let top = CameraCutoutMath.cardTopColor, bottom = CameraCutoutMath.cardBottomColor
        popOutAmount = s.cameraPopOutAmount.map { min(1, max(0, $0)) }
        fill = s.cameraCardFill ?? .gradient
        gradientTop = s.cameraCardGradientStart.map(RGB.init) ?? RGB(top.r, top.g, top.b)
        gradientBottom = s.cameraCardGradientEnd.map(RGB.init) ?? RGB(bottom.r, bottom.g, bottom.b)
        color = s.cameraCardColor.map(RGB.init) ?? Self.defaultCardColor
        imagePath = s.cameraCardImagePath.flatMap { $0.isEmpty ? nil : $0 }
        backgroundBlur = fill == .camera ? Self.unit(s.cameraBackgroundBlur) : 0
        edgeSoftness = Self.unit(s.cameraEdgeSoftness)
        edgeInset = Self.unit(s.cameraEdgeInset)
        border = s.cameraCardBorder
        borderThickness = min(1, max(0, s.cameraCardBorderWidth ?? 0.5))
        borderColor = s.cameraCardBorderColor.map(RGB.init) ?? RGB(1, 1, 1)
        shrinkOnZoom = s.cameraShrinkOnZoom ?? true
    }

    /// The thickness handed to `CameraCutoutMath.geometry` (nil = no ring).
    var geometryBorderWidth: Double? { border == nil ? nil : borderThickness }

    /// The ring's colours top → bottom (solid: the same colour twice).
    var borderColors: (top: RGB, bottom: RGB) {
        switch border {
        case .aurora: return (Self.auroraTop, Self.auroraBottom)
        case .gold: return (Self.goldTop, Self.goldBottom)
        case .solid, nil: return (borderColor, borderColor)
        }
    }

    /// §12.3 camera-fill blur σ in CAMERA pixels for a frame `height` tall.
    func blurSigma(cameraHeight: CGFloat) -> CGFloat {
        Self.blurSigma(blur: backgroundBlur, cameraHeight: cameraHeight)
    }

    static func blurSigma(blur: Double, cameraHeight: CGFloat) -> CGFloat {
        CGFloat(min(1, max(0, blur))) * 0.03 * cameraHeight
    }

    /// True when the person mask needs §12.4 edge processing at all.
    var processesMaskEdge: Bool { edgeSoftness > 0 || edgeInset > 0 }

    private static let imageCache = NSCache<NSString, CGImage>()

    /// The `image` fill's bitmap (§12.3): decoded once with EXIF orientation
    /// (BackgroundLook's decoder), redrawn as sRGB 8-bit. The preview uses it
    /// as layer contents and the exporter wraps it in a CIImage — the same
    /// pixels on both sides. nil = missing/unreadable (→ gradient fill).
    static func cardImage(path: String) -> CGImage? {
        if let hit = imageCache.object(forKey: path as NSString) { return hit }
        guard let decoded = BackgroundLook.decodedImage(path: path),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil, width: decoded.width, height: decoded.height,
                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.draw(decoded, in: CGRect(x: 0, y: 0, width: decoded.width, height: decoded.height))
        guard let image = ctx.makeImage() else { return nil }
        imageCache.setObject(image, forKey: path as NSString)
        return image
    }

    /// The image aspect-filled into the card (§12.3): s = max(C.w / iw,
    /// C.h / ih), centred on C. Same in Y-down and Y-up space.
    static func imageFillRect(imageSize: CGSize, card: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return card }
        let s = max(card.width / imageSize.width, card.height / imageSize.height)
        let w = imageSize.width * s, h = imageSize.height * s
        return CGRect(x: card.midX - w / 2, y: card.midY - h / 2, width: w, height: h)
    }
}
