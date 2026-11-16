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
class PreviewStageView: UIView {
    /// Everything one frame needs (see `PreviewCompositorCore.FrameInput`).
    typealias FrameInput = PreviewCompositorCore.FrameInput

    /// The core's root layer: virtual-canvas sized, magnified to fit.
    let canvasLayer = CALayer()
    /// The shared compositor, built on `canvasLayer`.
    private(set) var core: PreviewCompositorCore!

    /// The canvas the project renders against (points). Changing it
    /// re-renders at the new size on the next layout. A studio screen sets it
    /// from the project (`virtualCanvas(for:sourceSize:)`); harnesses pin it.
    var virtualCanvasSize: CGSize = PreviewStageView.virtualCanvas(
        box: ReferenceCanvas.newProjectBox, aspect: 16.0 / 9.0) {
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

    /// The canvas `project` lays out on (Studio 2e): its reference canvas at
    /// the output's aspect — the canvas the Mac editor draws (at any window
    /// size) and the exporter scales against, so the iOS preview frames the
    /// project exactly as they do. A project from before 2e (no reference)
    /// gets the new-project box's canvas: iOS has no window size to inherit,
    /// and that is the canvas most of those projects' exports used.
    static func virtualCanvas(for project: Project, sourceSize: CGSize) -> CGSize {
        let aspect = ReferenceCanvas.outputAspect(settings: project.settings, sourceSize: sourceSize)
            ?? 16.0 / 9.0
        return project.referenceCanvas(aspect: aspect)
            ?? virtualCanvas(box: ReferenceCanvas.newProjectBox, aspect: aspect)
    }

    private static func virtualCanvas(box: CGSize, aspect: CGFloat) -> CGSize {
        ReferenceCanvas.canvas(box: box, aspect: aspect)
    }

    /// Magnification from the virtual canvas to the view that FITS it
    /// (centred) — the Mac's `ZoomScrollView.fitMagnification`. Rasters are
    /// drawn at screen scale × this.
    var fitMagnification: CGFloat {
        guard virtualCanvasSize.width > 0, virtualCanvasSize.height > 0 else { return 1 }
        return min(bounds.width / virtualCanvasSize.width, bounds.height / virtualCanvasSize.height)
    }

    /// The user's zoom on top of the fit (the editor's pinch, Studio 4b):
    /// 1 = fit, as on the Mac (100% = fit, the user's zoom multiplies). Pure
    /// magnification — like the Mac's scroll-view zoom it never re-lays the
    /// project out and never re-rasters (rasters stay at screen × fit).
    var userZoom: CGFloat = 1 {
        didSet { if userZoom != oldValue { applyCanvasTransform() } }
    }

    /// Pan of the magnified canvas away from centred, in view points (only
    /// meaningful while `userZoom` > 1; the editor clamps it).
    var panOffset: CGPoint = .zero {
        didSet { if panOffset != oldValue { applyCanvasTransform() } }
    }

    /// Magnification from the virtual canvas to the view: fit × user zoom.
    var magnification: CGFloat { fitMagnification * userZoom }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyCanvasTransform()
        core.refreshContentsScale()
        if let input = pendingInput, bounds.width > 1, bounds.height > 1 {
            render(input)
        }
    }

    /// Places the canvas: magnified about its top-left, centred, then panned.
    private func applyCanvasTransform() {
        let m = magnification
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        canvasLayer.bounds = CGRect(origin: .zero, size: virtualCanvasSize)
        canvasLayer.position = CGPoint(
            x: (bounds.width - virtualCanvasSize.width * m) / 2 + panOffset.x,
            y: (bounds.height - virtualCanvasSize.height * m) / 2 + panOffset.y)
        canvasLayer.setAffineTransform(CGAffineTransform(scaleX: m, y: m))
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        core.refreshContentsScale()
    }

    func render(_ input: FrameInput) {
        // Not re-entrant: the twin's read-backs (drawHierarchy) run a layout
        // pass, and layoutSubviews would render again mid-render — a nested
        // twin pass then leaves the twin in ITS last isolation, and the outer
        // read-back captures the wrong stack. The outer render finishes the
        // frame; a nested request is dropped (the input is still pending).
        guard !rendering else { return }
        rendering = true
        defer { rendering = false }
        input.project.previewCanvasSize = virtualCanvasSize
        // The twin first (it steps exactly as the core will), then the core
        // renders and applies the stills in the same transaction.
        let stills = twin.prepare(input)
        core.hostZoomGroupStill = stills.zoomGroup
        core.hostCameraDissolve = stills.cameraDissolve
        core.render(input)
        lastRenderedTime = input.currentTime
    }

    /// The timeline time of the last frame rendered (the twin tells a
    /// same-time re-render from a step).
    private(set) var lastRenderedTime: TimeInterval?

    private var rendering = false

    /// What iOS CoreAnimation cannot draw — paused motion blur and the
    /// camera-look cross-dissolve — rebuilt from a twin core (Studio 2d).
    private lazy var twin = PreviewStageTwin(stage: self)

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

    /// Canvas space → this view (the inverse of `canvasPoint(fromView:)`).
    func viewPoint(fromCanvas point: CGPoint) -> CGPoint {
        let m = magnification
        return CGPoint(x: canvasLayer.position.x + point.x * m,
                       y: canvasLayer.position.y + point.y * m)
    }

    /// A canvas-space rect in this view's coordinates.
    func viewRect(fromCanvas rect: CGRect) -> CGRect {
        let origin = viewPoint(fromCanvas: rect.origin)
        let m = magnification
        return CGRect(x: origin.x, y: origin.y, width: rect.width * m, height: rect.height * m)
    }

    // MARK: - Edit-surface state the core reads (Studio 4b)

    /// The touch front end above the stage (`EditorCanvasView`) reports a
    /// live canvas drag here (the core drops live-motion rasters to 1x for
    /// it) and the annotation open in its in-place editor (omitted from the
    /// raster — the editor IS it). Nil providers = neither, as before 4b.
    var isDraggingOnCanvasProvider: (() -> Bool)?
    var inlineEditingIDProvider: (() -> UUID?)?
}

extension PreviewStageView: PreviewCompositorHost {
    var compositorCanvasSize: CGSize { virtualCanvasSize }

    /// Screen pixels per canvas point: the display scale times the FIT
    /// magnification, so rasters match the pixels they land on at 100%
    /// (the user's pinch zoom magnifies them, as the Mac's scroll view does).
    var compositorDisplayScale: CGFloat? {
        guard let window else { return nil }
        return window.screen.scale * max(0.01, fitMagnification)
    }

    var compositorIsDraggingOnCanvas: Bool { isDraggingOnCanvasProvider?() ?? false }
    var compositorInlineEditingID: UUID? { inlineEditingIDProvider?() }

    func compositorDidRender(_ frame: PreviewCompositorCore.RenderedFrame) {
        onRender?(frame)
    }
}
