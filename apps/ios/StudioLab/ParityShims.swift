import QuartzCore
import UIKit

// iOS stand-ins for the AppKit names the shared parity script uses
// (StudioHarness/PreviewParityHarness*.swift). Harness glue only — what is
// under test is the shipping PreviewStageView and the shared core.

typealias NSColor = UIColor
typealias NSImage = UIImage
typealias NSView = UIView
typealias NSRect = CGRect

/// The Mac script's `NSColorSpace.sRGB` argument.
enum ParityColorSpace { case sRGB }

extension UIColor {
    func usingColorSpace(_ space: ParityColorSpace) -> UIColor? {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = cgColor.converted(to: srgb, intent: .defaultIntent, options: nil) else { return nil }
        return UIColor(cgColor: converted)
    }
    private var rgba: (CGFloat, CGFloat, CGFloat, CGFloat) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b, a)
    }
    var redComponent: CGFloat { rgba.0 }
    var greenComponent: CGFloat { rgba.1 }
    var blueComponent: CGFloat { rgba.2 }
    var alphaComponent: CGFloat { rgba.3 }
}

extension SelectionChromeKit {
    /// The Mac's editor-themed convenience (MacStudioChromeTheme) — here the
    /// studio's iOS theme.
    static func image(size: CGSize, regions: [Region], containerRect: CGRect, scale: CGFloat) -> CGImage? {
        image(size: size, regions: regions, containerRect: containerRect, scale: scale, theme: IOSStudioChromeTheme())
    }
}

extension UIImage {
    /// NSImage(size:) — the script's empty fallback.
    convenience init(size: CGSize) { self.init() }
    /// NSImage(cgImage:size:) — same mapping as LayerContents.image.
    convenience init(cgImage: CGImage, size: CGSize) {
        let scale = size.width > 0 ? CGFloat(cgImage.width) / size.width : 1
        self.init(cgImage: cgImage, scale: scale, orientation: .up)
    }
}

func NSStringFromPoint(_ p: CGPoint) -> String { NSCoder.string(for: p) }
func NSStringFromRect(_ r: CGRect) -> String { NSCoder.string(for: r) }

extension UIWindow {
    /// The script resizes the Mac window for its portrait checks; here the
    /// pane (container) takes the size.
    func setContentSize(_ size: CGSize) {
        ParityLab.current?.container.frame.size = size
    }
}

/// The Mac's flipped container — UIKit views are already Y-down.
final class FlippedContainer: UIView {}

/// The Mac host's API over the shipping iOS stage: the canvas is the view's
/// bounds (as on the Mac), so the stage renders at magnification 1.
final class PreviewCompositorView: PreviewStageView {
    override func layoutSubviews() {
        if bounds.size.width > 1, bounds.size.height > 1 { virtualCanvasSize = bounds.size }
        super.layoutSubviews()
    }

    var motion: PreviewMotionModel { core.motion }
    var suppressImplicitAnimation: Bool {
        get { core.suppressImplicitAnimation }
        set { core.suppressImplicitAnimation = newValue }
    }
    var lastVideoRect: CGRect { core.lastVideoRect }
    var lastStackRows: CameraLayoutMath.StackRows? { core.lastStackRows }
    var lastStackArea: CGRect { core.lastStackArea }

    func debugCursorLayer() -> CALayer? { core.debugCursorLayer() }
    func debugTiltAngles() -> (pitch: Double, yaw: Double, roll: Double) { core.debugTiltAngles() }
    func debugVideoRect() -> CGRect? { core.debugVideoRect() }
    func debugCursorHotspot() -> CGPoint? { core.debugCursorHotspot() }
    func debugWarpedCursorCenter() -> CGPoint? { core.debugWarpedCursorCenter() }
    func debugCameraRect() -> CGRect? { core.debugCameraRect() }
    func debugCameraStroke() -> CAShapeLayer { core.debugCameraStroke() }
    func debugCameraRingLayer() -> CALayer { core.debugCameraRingLayer() }
    func debugCameraTagLayer() -> CALayer { core.debugCameraTagLayer() }
    func debugCameraGroupOpacity() -> Float { core.debugCameraGroupOpacity() }
    func debugCameraLookWeights() -> CameraLayoutMath.LookWeights { core.debugCameraLookWeights() }
    func debugCameraStackOpacities() -> (bubble: Float, cutout: Float, popOut: Float) { core.debugCameraStackOpacities() }
    func debugCameraGroupTransform() -> CATransform3D { core.debugCameraGroupTransform() }
    func debugCameraLayout() -> CameraLayoutMath.Resolved { core.debugCameraLayout() }
    func debugLayoutClipPath() -> CGPath? { core.debugLayoutClipPath() }
    func debugCameraMaskPath() -> CGPath? { core.debugCameraMaskPath() }

    static var renderTiming: Bool { PreviewCompositorCore.renderTiming }
    static var renderCount: Int { PreviewCompositorCore.renderCount }
    static var renderTotal: CFTimeInterval { PreviewCompositorCore.renderTotal }
    static var debugUnmaskedLooks: Bool {
        get { PreviewCompositorCore.debugUnmaskedLooks }
        set { PreviewCompositorCore.debugUnmaskedLooks = newValue }
    }
    static var debugDisableLayoutClip: Bool {
        get { PreviewCompositorCore.debugDisableLayoutClip }
        set { PreviewCompositorCore.debugDisableLayoutClip = newValue }
    }
    static var debugStackZoomOutside: Bool {
        get { PreviewCompositorCore.debugStackZoomOutside }
        set { PreviewCompositorCore.debugStackZoomOutside = newValue }
    }
    static var debugIgnoreSeamShapes: Bool {
        get { PreviewCompositorCore.debugIgnoreSeamShapes }
        set { PreviewCompositorCore.debugIgnoreSeamShapes = newValue }
    }
}

/// The Mac script captures through CARenderer; here the capture goes
/// through the REAL window (`drawHierarchy`: the render server's composite,
/// 3D transforms and masks included). CARenderer's frames are Y-flipped
/// relative to the screen, and the frozen Mac fingerprints are in that row
/// order, so the iOS capture is flipped into it before scoring.
enum CARendererSnapshot {
    @MainActor
    static func render(layer: CALayer, size: CGSize, scale: CGFloat) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { ctx in
            if let view = ParityLab.current?.container, view.layer === layer {
                _ = view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
            } else {
                layer.render(in: ctx.cgContext)
            }
        }
        guard let cg = image.cgImage else { return nil }
        return flippedVertically(cg)
    }

    private static func flippedVertically(_ image: CGImage) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(image.height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }
}
