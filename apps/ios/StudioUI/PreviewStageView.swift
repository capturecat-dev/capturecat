import QuartzCore
import UIKit

/// The iOS host of the shared preview compositor (`PreviewCompositorCore`,
/// Studio/Compositor) — the UIKit counterpart of the Mac's
/// `PreviewCompositorView`. The core draws exactly what it draws on the Mac;
/// this view supplies the canvas, the display scale and the magnification.
///
/// Virtual canvas (docs/ios-studio-plan.md, decision 3): the core renders at
/// `virtualCanvasSize` — the size the project's point-sized settings
/// (padding, corners, shadow, cursor, text) are authored against — and this
/// view MAGNIFIES that canvas to fit its bounds. A phone stage never re-lays
/// the project out at its own size, so an iPhone preview frames the project
/// the way the Mac preview and the export do; "preview zoom is pure
/// magnification", as on the Mac.
///
/// Geometry: UIKit layers are top-left / Y-down, which is the compositor's
/// space (the Mac gets it from a flipped NSView). The core's root is
/// `canvasLayer`, a plain sublayer sized to the virtual canvas and scaled
/// about its top-left corner; rasters are drawn at
/// `screen scale × magnification`, so the magnified preview stays sharp.
final class PreviewStageView: UIView {
    /// Everything one frame needs (see `PreviewCompositorCore.FrameInput`).
    typealias FrameInput = PreviewCompositorCore.FrameInput

    /// The core's root layer: virtual-canvas sized, magnified to fit.
    let canvasLayer = CALayer()
    /// The shared compositor, built on `canvasLayer`.
    private(set) var core: PreviewCompositorCore!

    /// The canvas the project renders against (points). Changing it
    /// re-renders at the new size on the next layout.
    var virtualCanvasSize: CGSize = CGSize(width: 586.7, height: 330) {
        didSet {
            guard virtualCanvasSize != oldValue else { return }
            setNeedsLayout()
        }
    }

    /// Last scheduled input — re-rendered on layout, so an input scheduled
    /// before the view has a size is not lost.
    private(set) var pendingInput: FrameInput?

    /// Called after every render that drew a frame — this frame's hit
    /// geometry, for a touch front end (PreviewGestureCore) above the stage.
    var onRender: ((PreviewCompositorCore.RenderedFrame) -> Void)?

    /// Overrides the raster scale (harnesses pin it; nil = the display's).
    var rasterScaleOverride: CGFloat? {
        get { core.rasterScaleOverride }
        set { core.rasterScaleOverride = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        clipsToBounds = true
        canvasLayer.anchorPoint = .zero
        canvasLayer.masksToBounds = true
        layer.addSublayer(canvasLayer)
        core = PreviewCompositorCore(root: canvasLayer, chromeTheme: IOSStudioChromeTheme())
        core.host = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Magnification from the virtual canvas to the view (fit, centred).
    var magnification: CGFloat {
        guard virtualCanvasSize.width > 0, virtualCanvasSize.height > 0 else { return 1 }
        return min(bounds.width / virtualCanvasSize.width, bounds.height / virtualCanvasSize.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let m = magnification
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        canvasLayer.bounds = CGRect(origin: .zero, size: virtualCanvasSize)
        canvasLayer.position = CGPoint(
            x: (bounds.width - virtualCanvasSize.width * m) / 2,
            y: (bounds.height - virtualCanvasSize.height * m) / 2)
        canvasLayer.setAffineTransform(CGAffineTransform(scaleX: m, y: m))
        CATransaction.commit()
        core.refreshContentsScale()
        if let input = pendingInput, bounds.width > 1, bounds.height > 1 {
            render(input)
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        core.refreshContentsScale()
    }

    func render(_ input: FrameInput) {
        input.project.previewCanvasSize = virtualCanvasSize
        core.render(input)
    }

    /// Renders now when laid out, otherwise on the next layout pass.
    func schedule(_ input: FrameInput) {
        pendingInput = input
        if bounds.width > 1, bounds.height > 1 {
            render(input)
        }
    }

    /// Converts a point in this view to the compositor's canvas space (the
    /// space PreviewHitMath works in).
    func canvasPoint(fromView point: CGPoint) -> CGPoint {
        let m = max(0.0001, magnification)
        return CGPoint(x: (point.x - canvasLayer.position.x) / m,
                       y: (point.y - canvasLayer.position.y) / m)
    }
}

extension PreviewStageView: PreviewCompositorHost {
    var compositorCanvasSize: CGSize { virtualCanvasSize }

    /// Screen pixels per canvas point: the display scale times the
    /// magnification, so rasters match the pixels they land on.
    var compositorDisplayScale: CGFloat? {
        guard let window else { return nil }
        return window.screen.scale * max(0.01, magnification)
    }

    var compositorIsDraggingOnCanvas: Bool { false }
    var compositorInlineEditingID: UUID? { nil }

    func compositorDidRender(_ frame: PreviewCompositorCore.RenderedFrame) {
        onRender?(frame)
    }
}
