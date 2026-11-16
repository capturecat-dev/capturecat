import AppKit

/// The Mac host of the preview compositor: a layer-backed, flipped NSView
/// whose backing layer IS the compositor's root. Everything that draws —
/// every sublayer, the caches, `render(_:)`, the springs, the video-frame
/// driver and the probe readbacks — lives in `PreviewCompositorCore`
/// (AppKit-free; the iOS studio hosts the same core in a UIView). This view
/// supplies the canvas (`bounds.size`) and display scale
/// (`window?.backingScaleFactor`), triggers renders on layout and re-scales
/// on backing changes, and owns the edit-gesture surface
/// (`PreviewInteractionView`) above the layers.
final class PreviewCompositorView: NSView {
    override var isFlipped: Bool { true } // Y-down everywhere, like SwiftUI

    /// Everything one frame needs (see `PreviewCompositorCore.FrameInput`).
    typealias FrameInput = PreviewCompositorCore.FrameInput

    /// The compositor, built on this view's backing layer in `init`.
    private(set) var core: PreviewCompositorCore!

    /// Last input from the bridge — re-rendered on layout so early updates
    /// (before the view has a size) aren't lost.
    var pendingInput: FrameInput?

    /// How much the editor's scroll view magnifies this canvas to fill the
    /// card at 100% (Studio 2e: a reference-canvas project renders at its
    /// reference canvas and is magnified to the window — see
    /// `ZoomScrollView.fitMagnification`). Rasters are drawn this much denser
    /// so text and the cursor stay sharp at any window size. 1 for a project
    /// from before 2e, whose canvas is the card itself.
    var canvasMagnification: CGFloat = 1 {
        didSet {
            guard canvasMagnification != oldValue else { return }
            core.refreshContentsScale()
            if let input = pendingInput, bounds.width > 1, bounds.height > 1 {
                render(input)
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Required for CIFilters on sublayers (motion blur on zoomGroup) —
        // must be set before the layer tree is built to take effect.
        layerUsesCoreImageFilters = true
        wantsLayer = true
        // `wantsLayer` makes AppKit build the backing layer synchronously; the
        // core adopts it as its root and builds the whole tree on it, here.
        core = PreviewCompositorCore(root: layer ?? CALayer(), chromeTheme: MacStudioChromeTheme())
        core.host = self
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        if let input = pendingInput, bounds.width > 1, bounds.height > 1 {
            input.project.previewCanvasSize = bounds.size
            render(input)
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        core.refreshContentsScale()
    }

    func render(_ input: FrameInput) {
        core.render(input)
    }

    /// Renders now if laid out; re-renders on the next layout pass otherwise
    /// (a frame can be scheduled before the view has a size).
    func schedule(_ input: FrameInput) {
        pendingInput = input
        if bounds.width > 1, bounds.height > 1 {
            // Keep the shared canvas-size contract other surfaces read.
            input.project.previewCanvasSize = bounds.size
            render(input)
        }
    }

    // MARK: - Interaction

    /// Edit-gesture surface above the layers (added lazily on first render).
    private var interactionView: PreviewInteractionView?
    private var renderRequestQueued = false
    /// Blur selection is preview-local state (matches PreviewView's private
    /// @State selectedBlurID).
    private(set) var localSelectedBlurID: UUID?
    var onSelectHighlight: ((UUID?) -> Void)?
    var onSelectDepthFocus: ((UUID?) -> Void)?
    /// Blur selection stays preview-local for canvas chrome, but the shell
    /// mirrors it into shared selection so the inspector section opens.
    var onSelectBlurRegion: ((UUID?) -> Void)?
    var onSelectAnnotation: ((UUID?) -> Void)?
    /// Drag of the on-canvas focal target — unit point in video space.
    var onSetZoomFocal: ((CGPoint) -> Void)?
    /// Completed drag-to-draw blur pass — normalized rect + popover style.
    var onCreateBlurRegion: ((CGRect, BlurStyle) -> Void)?

    /// Arm one drag-to-draw blur/pixelate pass on the canvas (popover entry).
    func armBlurDraw(style: BlurStyle) {
        ensureInteractionView().armBlurDraw(style: style)
    }

    /// Blur selection made OUTSIDE the canvas (a freshly drawn region, the
    /// timeline lane, the inspector) — mirrors shared state back into the
    /// preview-local ID so the on-canvas chrome appears immediately.
    func syncBlurSelection(_ id: UUID?) {
        localSelectedBlurID = id
    }

    /// Floating-pill entry: open the in-place label editor for a text/callout
    /// annotation that was just added (see PreviewInteractionView).
    func beginInlineTextEdit(annotationID: UUID) {
        interactionView?.beginInlineEdit(annotationID: annotationID)
    }

    /// Selected annotation's rect in this view's coordinates, for the shell's
    /// contextual toolbar placement. Nil when nothing is selected.
    func selectedAnnotationViewRect() -> CGRect? {
        interactionView?.selectedAnnotationViewRect()
    }

    /// True while the user is dragging on the canvas — the shell hides the
    /// contextual toolbar for the duration (presentation-app behaviour, and zero
    /// toolbar layout work per mouse-move).
    var isDraggingOnCanvas: Bool {
        interactionView?.isActivelyDragging ?? false
    }

    /// Forwarded from the interaction layer's mouse-up so the shell can bring
    /// contextual UI back — nothing observable changes on a plain mouse-up.
    var onCanvasDragEnded: (() -> Void)?

    private func ensureInteractionView() -> PreviewInteractionView {
        if let interactionView { return interactionView }
        let v = PreviewInteractionView(frame: bounds)
        v.autoresizingMask = [.width, .height]
        v.onSelectHighlight = { [weak self] id in self?.onSelectHighlight?(id) }
        v.onSelectDepthFocus = { [weak self] id in self?.onSelectDepthFocus?(id) }
        v.onSelectAnnotation = { [weak self] id in self?.onSelectAnnotation?(id) }
        v.onSetZoomFocal = { [weak self] p in self?.onSetZoomFocal?(p) }
        v.onDragEnded = { [weak self] in self?.onCanvasDragEnded?() }
        v.onCreateBlurRegion = { [weak self] rect, style in self?.onCreateBlurRegion?(rect, style) }
        v.onSelectBlur = { [weak self] id in
            self?.localSelectedBlurID = id
            self?.onSelectBlurRegion?(id)
            if let self, let input = self.pendingInput { self.render(input) }
        }
        // Coalesced to one render per runloop turn: a drag delivers mouse
        // events faster than a full render pass completes, and rendering
        // every event is what made direct manipulation feel laggy.
        v.requestRender = { [weak self] in
            guard let self, !self.renderRequestQueued else { return }
            self.renderRequestQueued = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.renderRequestQueued = false
                if var input = self.pendingInput {
                    input.selectedBlurID = self.localSelectedBlurID
                    self.render(input)
                }
            }
        }
        addSubview(v)
        interactionView = v
        return v
    }

    // MARK: - Compositor surface (forwarded to the core)

    /// Shared spring integrators — identical to the SwiftUI preview's.
    var motion: PreviewMotionModel { core.motion }

    /// Forces the rasterisation scale, ignoring the window's backing scale
    /// (see `PreviewCompositorCore.rasterScaleOverride`).
    var rasterScaleOverride: CGFloat? {
        get { core.rasterScaleOverride }
        set { core.rasterScaleOverride = newValue }
    }

    /// Set by the headless gates: they capture settled frames and assert on the
    /// model values, so an in-flight interpolation is pure noise there.
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
    func debugCameraStackOpacities() -> (bubble: Float, cutout: Float, popOut: Float) {
        core.debugCameraStackOpacities()
    }
    func debugCameraGroupTransform() -> CATransform3D { core.debugCameraGroupTransform() }
    func debugCameraLayout() -> CameraLayoutMath.Resolved { core.debugCameraLayout() }
    func debugLayoutClipPath() -> CGPath? { core.debugLayoutClipPath() }
    func debugCameraMaskPath() -> CGPath? { core.debugCameraMaskPath() }

    /// `CAPTURECAT_RENDER_TIMING=1` render counters (see the core).
    static var renderTiming: Bool { PreviewCompositorCore.renderTiming }
    static var renderCount: Int { PreviewCompositorCore.renderCount }
    static var renderTotal: CFTimeInterval { PreviewCompositorCore.renderTotal }

    /// Defect injections for `--preview-parity`'s self-tests (see the core).
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

// MARK: - PreviewCompositorHost

extension PreviewCompositorView: PreviewCompositorHost {
    var compositorCanvasSize: CGSize { bounds.size }
    var compositorDisplayScale: CGFloat? { window.map { $0.backingScaleFactor * canvasMagnification } }
    var compositorIsDraggingOnCanvas: Bool { interactionView?.isActivelyDragging == true }
    var compositorInlineEditingID: UUID? { interactionView?.inlineEditingID }

    /// Hit context for the interaction layer (canvas-space geometry from
    /// THIS render, so gestures always match the pixels on screen). Built by
    /// the core (Studio 4b) — the iOS touch surface builds it the same way.
    func compositorDidRender(_ frame: PreviewCompositorCore.RenderedFrame) {
        let interaction = ensureInteractionView()
        interaction.context = core.hitContext(for: frame, selectedBlurID: localSelectedBlurID)
    }
}
