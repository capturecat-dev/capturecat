import AppKit
import AVFoundation

/// AppKit Phase 4: pure CoreAnimation preview compositor. Mirrors
/// PreviewView's composition byte-for-byte where math is concerned — every
/// geometric formula here is a port of the SwiftUI original, and the springs
/// are the SAME `PreviewMotionModel` the SwiftUI preview steps.
///
/// Scope (flag `useAppKitPreview`, default false): background, video card
/// (clip/shadow/menu-bar/hidden-crop), tilt warp, card-only zoom about the
/// tilt-projected anchor, cursor + click ripple INSIDE the warped subtree
/// (CA does not suffer SwiftUI's hosted-view subtree split), subtitles,
/// watermark, camera bubble with reactive shrink. Deferred: device bezel +
/// keynote dip, blur/highlight regions, annotations, and edit gestures —
/// see the P4 report.
final class PreviewCompositorView: NSView {
    override var isFlipped: Bool { true } // Y-down everywhere, like SwiftUI

    // Shared spring integrators — identical to the SwiftUI preview's.
    let motion = PreviewMotionModel()

    /// Everything one frame needs. Mirrors PreviewView's inputs.
    struct FrameInput {
        var project: Project
        var currentTime: TimeInterval
        var isPlaying: Bool
        var isScrubbing: Bool = false
        var cursorEvents: [CursorEvent]
        /// Sorted scroll-tick timestamps (source time) — camera steadying.
        var scrollTimes: [TimeInterval] = []
        /// Raw keystroke stream — the shortcut overlay reads `.shortcut`.
        var keystrokeEvents: [KeystrokeEvent] = []
        var cursorCoordinateSize: CGSize
        var videoSize: CGSize
        var player: AVPlayer?
        var cameraPlayer: AVPlayer?
        var cameraPosterImage: NSImage?
        var cameraVideoAspect: CGFloat
        var videoPosterImage: NSImage?
        // Editor selection — drives the same chrome PreviewView draws
        // (annotation selection ring, highlight outline suppression).
        var selectedAnnotationID: UUID?
        var selectedHighlightID: UUID?
        var selectedBlurID: UUID?
        var selectedDepthFocusID: UUID?
        /// Selected EFFECTS-lane zoom block — shows the on-canvas focal
        /// target (drag it on the preview to aim the zoom, CapCut-style).
        var selectedZoomID: UUID?
    }

    // MARK: - Layers

    private let backgroundSolid = CALayer()
    private let backgroundGradient = CAGradientLayer()
    private let backgroundImage = CALayer()

    /// Card-only zoom happens here (transform about the projected anchor).
    private let zoomGroup = CALayer()
    /// Previous camera sample fed to MotionBlurMath (timeline time, not wall
    /// clock) — nil until the second render after open/reset.
    private var lastBlurSample: (sample: MotionBlurMath.CameraSample, time: TimeInterval)?
    /// Whether zoomGroup currently carries the named CIMotionBlur filter —
    /// installed once, then mutated via setValue(forKeyPath:) per render so
    /// the filter pipeline isn't rebuilt every frame.
    private var motionBlurFilterInstalled = false
    /// Tilt homography happens here; its coordinate space = the padded
    /// content area, exactly the GeometryEffect's local space in SwiftUI.
    private let contentGroup = CALayer()
    /// Keynote-dip target: bezel + shadow + video + island (the exact subtree
    /// PreviewView's phaseAnimator scales/fades at device-segment boundaries).
    private let cardGroup = CALayer()
    private let bezelButtonsLayer = CALayer()
    private let bezelSlabLayer = CALayer()
    private let bezelLayer = CALayer()
    private let cardShadow = CALayer()
    private let videoClip = CALayer()
    private let screenClip = CALayer()
    private let videoLayer = CALayer()
    private let posterLayer = CALayer()
    private let menuBarLayer = CALayer()
    private let islandLayer = CALayer()
    /// Card-level clip for highlight dims + blur patches (they live inside
    /// the card's clip shape in SwiftUI, but outside the dip subtree).
    private let overlayClip = CALayer()
    private let highlightGroup = CALayer()
    private let blurGroup = CALayer()
    private let annotationLayer = CALayer()
    private let cursorLayer = CALayer()
    private let backdropDimLayer = CALayer()
    private let rippleGroup = CALayer()
    /// Curtain Unveil — topmost card-space layer; shows the SHARED
    /// CurtainUnveilMath raster so preview and export cannot drift.
    private let curtainLayer = CALayer()

    private let subtitleLayer = CALayer()
    /// Shortcut pill ("⌘⇧S") — canvas chrome like subtitles, above them.
    private let keystrokeLayer = CALayer()
    private let cameraGroup = CALayer()
    private let cameraShadow = CALayer()
    private let cameraCardShadow = CALayer()
    private let cameraClip = CALayer()
    private let cameraVideo = CALayer()
    private let cameraPoster = CALayer()
    /// Ring-light glow inside the clip, above the video (CameraStyleMath).
    private let cameraRing = CALayer()
    private let cameraStroke = CAShapeLayer()
    /// Name-tag pill riding the bubble (outside the clip — it may overhang).
    private let cameraTag = CALayer()
    private let watermarkLayer = CALayer()

    private var videoDriver: VideoFrameLayerDriver?
    private var cameraDriver: VideoFrameLayerDriver?

    /// Last input from the bridge — re-rendered on layout so early updates
    /// (before the view has a size) aren't lost.
    var pendingInput: FrameInput?

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
    /// contextual toolbar for the duration (Keynote behaviour, and zero
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

    /// Parity-harness hook.
    func debugCursorLayer() -> CALayer? { cursorLayer }

    /// Forces the rasterisation scale, ignoring the window's backing scale.
    ///
    /// Every hand-rasterised layer here derives its pixel size from
    /// `window?.backingScaleFactor ?? 2`, so the SAME code renders differently
    /// on a 1x external monitor than on a Retina panel. That is correct in the
    /// app and fatal in a gate: the frozen goldens silently encode whichever
    /// display the machine happened to be driving when they were captured.
    /// The harness pins this so the gate scores the renderer, not the desk.
    var rasterScaleOverride: CGFloat?
    private var effectiveScale: CGFloat { rasterScaleOverride ?? window?.backingScaleFactor ?? 2 }

    /// Last tilt angles applied by `render`. `--preview-parity` uses these to
    /// pin the spring MID-FLIGHT before asserting the chrome re-rasterized
    /// nothing — a frozen tilt would pass that assertion trivially.
    private(set) var lastAppliedTiltAngles: (pitch: Double, yaw: Double, roll: Double) = (0, 0, 0)

    /// The video rect this frame was laid out against. Read by the cursor
    /// mapping gate; see `debugVideoRect()`.
    private(set) var lastVideoRect: CGRect = .zero

    /// Hotspot offset inside the cursor layer, in layer points. Recorded when
    /// the sprite is laid out so the gate can measure the point that actually
    /// has to be accurate.
    private(set) var lastCursorHotspotInLayer: CGPoint?
    func debugTiltAngles() -> (pitch: Double, yaw: Double, roll: Double) { lastAppliedTiltAngles }

    override func layout() {
        super.layout()
        if let input = pendingInput, bounds.width > 1, bounds.height > 1 {
            input.project.previewCanvasSize = bounds.size
            render(input)
        }
    }

    // Caches
    private var cachedBackground: CGImage?
    private var cachedBackgroundKey: String?
    /// Key of the styled-backdrop render currently in flight (latest wins).
    private var backgroundInflightKey: String?
    private var cachedWatermark: NSImage?
    private var cachedWatermarkName: String??
    /// Curtain logo loaded once per file name (double-optional: outer = cache
    /// unprimed, inner = no logo) — never decoded per frame.
    private var cachedCurtainLogoName: String??
    private var cachedCurtainLogoImage: CGImage?
    private var cachedSubtitleBitmap: (key: String, image: NSImage, pillSize: CGSize)?
    private var cachedKeystrokeBitmap: (key: String, image: NSImage, pillSize: CGSize)?
    private var cachedKeystrokeDisplay: (count: Int, scoped: Bool, events: [KeystrokeOverlayMath.DisplayEvent])?
    /// Camera styling caches — keyed bitmaps so the per-frame path stays cheap.
    private var cachedCameraRing: (key: String, image: NSImage)?
    private var cachedCameraTag: (key: String, image: NSImage, pillSize: CGSize)?
    private var cachedAdjustedPoster: (key: String, image: NSImage)?
    private var lastResetSignature: String?
    /// Last clock value the motion model was stepped at — same-time renders
    /// must NOT step the springs (see render()).
    private var lastMotionTime: TimeInterval?
    private var cachedBezel: (key: String, buttons: CGImage, slab: CGImage, body: CGImage)?
    private var cachedAnnotations: (key: String, image: CGImage)?
    private var cachedBlurPatches: [UUID: (key: String, image: CGImage)] = [:]
    private var cachedFocusPatches: [UUID: (key: String, image: CGImage)] = [:]
    /// Depth-focus gradient masks (FocusMath.maskImage), rebuilt only when a
    /// region's shape parameters change — never per frame.
    private var cachedFocusMasks: [UUID: (key: String, image: CIImage)] = [:]
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    // Keynote dip — transient wall-clock animation on device-segment change,
    // replicating PreviewView's phaseAnimator([0,1], easeInOut 0.15 per phase).
    private var lastVideoPlacement: ProjectSettings.VideoPlacement?

    /// `CAPTURECAT_RENDER_TIMING=1` — counts renders and total time so the cost per
    /// frame can be measured instead of guessed at.
    static let renderTiming = ProcessInfo.processInfo.environment["CAPTURECAT_RENDER_TIMING"] != nil
    nonisolated(unsafe) static var renderCount = 0
    nonisolated(unsafe) static var renderTotal: CFTimeInterval = 0
    /// Last target handed to `interpolate`, per layer+keyPath. See `interpolate`.
    private var lastAnimationTarget: [String: NSValue] = [:]

    // MARK: - Implicit animation

    /// The card's glide between the nine placement anchors.
    /// Was `.animation(.easeOut(duration: 0.18), value: videoPlacement)`.
    static let placementGlide: CFTimeInterval = 0.18
    // NOTE there is deliberately NO tick-bridge on zoom/tilt.
    //
    // The SwiftUI preview had `.animation(.linear(0.08), value: [zoom, focalX,
    // focalY])` and a matching one on the tilt effect, and porting them looked
    // like the right thing to do. It is not: the compositor already renders once
    // per time-observer tick (~16ms) and the spring produces a NEW target every
    // one of those ticks, so an 80ms animation toward each new target never
    // completes — every frame restarts it from wherever the pixels currently
    // are. That composes into a first-order lag filter with tau ~= 70ms, which
    // reads as floaty, behind-the-cursor motion during zoom, tilt and scrub.
    //
    // The spring IS the smoothing. Let the transforms land on the value the
    // model computed for this tick.

    /// Re-adds one of the implicit animations the SwiftUI preview had.
    ///
    /// `render()` runs inside `CATransaction.setDisableActions(true)` — which is
    /// correct for the ~200 layer properties that must land exactly on the value
    /// the frame math produced. But three of them are MOTION, and the SwiftUI
    /// preview interpolated them; dropping the interpolation in the CA port made
    /// the card jump between placements and the zoom/tilt staircase between
    /// ticks. This restores exactly those three, and only those.
    ///
    /// Preview-vs-export is unaffected: the exporter evaluates the springs at
    /// EVERY output frame, so its motion is already continuous. This makes the
    /// preview continuous the same way, rather than showing the raw tick values.
    ///
    /// `from` must be read before the model value is assigned, and from the
    /// PRESENTATION layer when one is in flight, or a new tick restarts the
    /// interpolation from the previous target and the motion stutters.
    private func interpolate(
        _ layer: CALayer,
        keyPath: String,
        from: NSValue,
        to: NSValue,
        duration: CFTimeInterval,
        timing: CAMediaTimingFunctionName
    ) {
        guard !suppressImplicitAnimation, !from.isEqual(to) else { return }
        // Only re-animate when the TARGET moved. `from` is the presentation
        // value, so it differs from `to` on every frame an animation is already
        // in flight — restarting on that alone turns an 80ms bridge into a
        // permanent ~70ms exponential lag filter, because render() runs once per
        // time-observer tick (~16ms) and each pass would rewind the animation to
        // wherever the pixels currently are.
        let targetKey = "\(keyPath)@\(ObjectIdentifier(layer).hashValue)"
        if let last = lastAnimationTarget[targetKey], last.isEqual(to) { return }
        lastAnimationTarget[targetKey] = to
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: timing)
        // The model value is already the target; this only paints the journey.
        animation.isRemovedOnCompletion = true
        layer.add(animation, forKey: keyPath)
    }

    /// Set by the headless gates: they capture settled frames and assert on the
    /// model values, so an in-flight interpolation is pure noise there.
    var suppressImplicitAnimation = false

    // Last-render hit geometry (canvas space) for the interaction layer.
    private var lastCameraRect: CGRect?
    private var lastSubtitleRect: CGRect?
    private var lastWatermarkRect: CGRect?
    private var cachedFocusChrome: (key: String, image: CGImage)?
    private let focusChromeLayer = CALayer()
    /// On-canvas focal target for the selected zoom block.
    private let focalReticleLayer = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Required for CIFilters on sublayers (motion blur on zoomGroup) —
        // must be set before the layer tree is built to take effect.
        layerUsesCoreImageFilters = true
        wantsLayer = true
        guard let root = layer else { return }
        root.masksToBounds = true
        root.backgroundColor = NSColor.black.cgColor

        for l in [backgroundSolid, backgroundGradient, backgroundImage] {
            l.anchorPoint = .zero
            root.addSublayer(l)
        }
        backgroundImage.contentsGravity = .resizeAspectFill
        backgroundImage.masksToBounds = true
        backgroundGradient.startPoint = CGPoint(x: 0, y: 0) // topLeading (flipped)
        backgroundGradient.endPoint = CGPoint(x: 1, y: 1)   // bottomTrailing

        // Annotation blackout, canvas half: dims the BACKGROUND (everything
        // under the card). The card dims itself via AnnotationRenderer's
        // card-space backdrop, so together the whole frame goes dark except
        // the annotation's shape — and neither half needs warping, because
        // the card exactly covers the hole this layer leaves under it.
        backdropDimLayer.anchorPoint = .zero
        backdropDimLayer.backgroundColor = NSColor.black.cgColor
        backdropDimLayer.opacity = 0
        backdropDimLayer.isHidden = true
        root.addSublayer(backdropDimLayer)

        zoomGroup.anchorPoint = .zero
        root.addSublayer(zoomGroup)
        contentGroup.anchorPoint = .zero
        zoomGroup.addSublayer(contentGroup)

        cardGroup.anchorPoint = .zero
        contentGroup.addSublayer(cardGroup)
        // ZStack order from `drawYDown`: buttons, then the extruded side slab,
        // then the body (whose drop shadow falls over both).
        for layer in [bezelButtonsLayer, bezelSlabLayer, bezelLayer] {
            layer.contentsGravity = .resize
            cardGroup.addSublayer(layer)
        }
        cardShadow.shadowColor = NSColor.black.cgColor
        cardGroup.addSublayer(cardShadow)
        videoClip.masksToBounds = false // outer frame clip via mask only
        cardGroup.addSublayer(videoClip)
        screenClip.masksToBounds = true
        videoClip.addSublayer(screenClip)
        videoLayer.contentsGravity = .resize
        screenClip.addSublayer(videoLayer)
        posterLayer.contentsGravity = .resize
        screenClip.addSublayer(posterLayer)
        menuBarLayer.contentsGravity = .resize
        screenClip.addSublayer(menuBarLayer)
        // The video layer shows the NATIVE-resolution IOSurface (often 3–4×
        // the card's size on screen). Default linear minification aliases
        // that hard — worse under tilt and scale-down effects, where the
        // shimmer reads as "blurry". Trilinear samples through mipmaps and
        // keeps the minified card crystal; edge AA cleans the warped borders.
        for l in [videoLayer, posterLayer, menuBarLayer] {
            l.minificationFilter = .trilinear
            l.magnificationFilter = .linear
        }
        for l in [contentGroup, cardGroup, videoClip, screenClip] {
            l.allowsEdgeAntialiasing = true
        }
        cardGroup.addSublayer(islandLayer)

        // Highlight dims + blur patches — clipped by the card's frame shape,
        // NOT part of the dip subtree (SwiftUI z-order: video card →
        // highlight dim → blur patches).
        overlayClip.anchorPoint = .zero
        contentGroup.addSublayer(overlayClip)
        highlightGroup.anchorPoint = .zero
        overlayClip.addSublayer(highlightGroup)
        blurGroup.anchorPoint = .zero
        overlayClip.addSublayer(blurGroup)
        focusChromeLayer.contentsGravity = .resize
        overlayClip.addSublayer(focusChromeLayer)
        overlayClip.addSublayer(focalReticleLayer)
        focalReticleLayer.isHidden = true

        // Annotations follow the skewed card, above the card overlays.
        annotationLayer.contentsGravity = .resize
        contentGroup.addSublayer(annotationLayer)

        // Cursor + ripple: siblings of the card INSIDE the tilted content
        // space — the parent transform warps them with the content, so the
        // arrow can never detach (the CA answer to the GeometryEffect
        // subtree-split bug).
        contentGroup.addSublayer(cursorLayer)
        contentGroup.addSublayer(rippleGroup)
        // Curtain Unveil rides zoom/tilt with the content — TOPMOST card-space
        // sublayer, above the cursor (the curtain covers everything on the card).
        curtainLayer.contentsGravity = .resize
        contentGroup.addSublayer(curtainLayer)
        cursorLayer.shadowColor = NSColor.black.cgColor
        cursorLayer.shadowOpacity = Float(CursorOverlayLayout.shadowOpacity)
        cursorLayer.shadowRadius = CursorOverlayLayout.shadowBlurRadius
        cursorLayer.shadowOffset = CursorOverlayLayout.shadowOffset

        // Canvas-level chrome in exporter order: subtitles, camera, watermark.
        subtitleLayer.anchorPoint = .zero
        root.addSublayer(subtitleLayer)

        keystrokeLayer.anchorPoint = .zero
        root.addSublayer(keystrokeLayer)

        cameraGroup.anchorPoint = .zero
        root.addSublayer(cameraGroup)
        cameraShadow.shadowColor = NSColor.black.cgColor
        cameraShadow.shadowOpacity = 0.33 // SwiftUI .shadow(radius:) default alpha
        cameraGroup.addSublayer(cameraShadow)
        // Card-style shadow for camera layout overrides — the camera tile
        // gets the FRAME's shadow treatment (radius/opacity/offset from the
        // card settings). Kept as a second layer so the morph is a crossfade
        // of two shadows, exactly like the exporter blends its two shadow
        // images — one lerped shadow here would diverge mid-morph.
        cameraCardShadow.shadowColor = NSColor.black.cgColor
        cameraCardShadow.shadowOpacity = 0
        cameraGroup.addSublayer(cameraCardShadow)
        // Outer ring-light glow — around the bubble, above the shadow, below
        // the clipped video (a physical ring light behind the camera).
        cameraRing.contentsGravity = .resize
        cameraGroup.addSublayer(cameraRing)
        cameraClip.masksToBounds = true
        cameraGroup.addSublayer(cameraClip)
        cameraClip.addSublayer(cameraVideo)
        cameraPoster.contentsGravity = .resizeAspectFill
        cameraClip.addSublayer(cameraPoster)
        cameraStroke.fillColor = nil
        cameraStroke.strokeColor = NSColor.white.withAlphaComponent(0.3).cgColor
        cameraGroup.addSublayer(cameraStroke)
        cameraTag.contentsGravity = .resize
        cameraGroup.addSublayer(cameraTag)

        watermarkLayer.contentsGravity = .resizeAspect
        root.addSublayer(watermarkLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = effectiveScale
        for l in [subtitleLayer, keystrokeLayer, menuBarLayer, cursorLayer, watermarkLayer, posterLayer, cameraPoster, cameraRing, cameraTag, backgroundImage] {
            l.contentsScale = scale
        }
    }

    // MARK: - Render

    func render(_ input: FrameInput) {
        let canvas = bounds.size
        guard canvas.width > 0, canvas.height > 0 else { return }
        let renderStart = PreviewCompositorView.renderTiming ? CACurrentMediaTime() : 0
        defer {
            if PreviewCompositorView.renderTiming {
                PreviewCompositorView.renderCount += 1
                PreviewCompositorView.renderTotal += CACurrentMediaTime() - renderStart
            }
        }
        let s = input.project.settings

        // Spring lifecycle — mirrors PreviewView's onChange(reset)/onChange(step).
        // CRITICAL: step ONLY when the clock advances. render() also fires for
        // same-time SwiftUI updates (selection, hover, and the re-render each
        // @Observable spring step itself triggers); feeding those to step()
        // makes dt == 0 hit the model's seek guard and SNAP every transition
        // to its target — the "motion just snaps" regression.
        let resetSignature = motionResetSignature(input)
        let env = motionEnv(input)
        if input.isScrubbing {
            lastResetSignature = resetSignature
            motion.scrub(env: env, from: input.project.effectiveTrimStart)
            lastMotionTime = input.currentTime
        } else if lastResetSignature != resetSignature {
            lastResetSignature = resetSignature
            motion.reset(env: env)
            lastMotionTime = input.currentTime
        } else if lastMotionTime != input.currentTime {
            lastMotionTime = input.currentTime
            motion.step(env: env)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        renderBackground(input, canvas: canvas)

        // ── Geometry (ported formulas) ────────────────────────────────────
        let pad = clampedBackgroundPadding(s, canvas: canvas)
        let insets = placementPaddingInsets(s, pad: pad)
        let contentRect = CGRect(
            x: insets.leading, y: insets.top,
            width: max(1, canvas.width - insets.leading - insets.trailing),
            height: max(1, canvas.height - insets.top - insets.bottom)
        )
        var videoRect = previewVideoRect(input, in: contentRect.size)
        // Freeform placement ranges over the WHOLE canvas (the anchor system
        // only redistributes padding). Same override in the exporter's
        // frameLayout — via the shared PlacementMath.customOrigin.
        if PlacementMath.isCustom(s) {
            let f = PlacementMath.alignment(for: s)
            let canvasOrigin = PlacementMath.customOrigin(
                fraction: f, canvas: canvas, video: videoRect.size)
            videoRect.origin = CGPoint(
                x: canvasOrigin.x - contentRect.minX,
                y: canvasOrigin.y - contentRect.minY
            )
        }
        // Stored in CANVAS space. `previewVideoRect` works in content space
        // (inside the frame padding), while every debug readback of a composited
        // point is canvas space — comparing the two reports an offset exactly
        // equal to the padding and makes a correct renderer look broken.
        lastVideoRect = videoRect.offsetBy(dx: contentRect.minX, dy: contentRect.minY)
        let visible = input.project.hasVisibleVideo(at: input.currentTime)
            && isWithinTrimRange(input)

        // A timeline tilt authored at the visible project head has no pre-roll
        // in which to spring in. AVPlayer can briefly publish a pre-trim
        // timestamp while an exact head seek settles; if that flat sample is
        // allowed to seed the spring, playback appears to ignore the tilt at
        // 0:00 and eases into it late. Keep a head-anchored block authoritative
        // as the clip's OPENING STATE — full angles from frame zero, matching
        // the exporter's first-frame snap — but ONLY until its in-block
        // ramp-out begins: from there the spring owns the release exactly like
        // any mid-timeline block. (The override previously held raw angles for
        // the WHOLE span, skipping the ramp-out and cliff-dropping ~18° in one
        // frame at endTime — the head-block "doesn't animate / snaps" bug.)
        let head = input.project.effectiveTrimStart
        let headTilt = input.project.tiltRegions.first { region in
            let lead = TiltMath.rampOutLead(
                blockStart: region.startTime, blockEnd: region.endTime,
                animationDuration: s.animationSpeed.duration)
            return region.startTime <= head + 0.0005
                && region.endTime >= head
                && input.currentTime >= head - (1.0 / 120.0)
                && input.currentTime <= region.endTime - lead
        }.map { (pitch: $0.pitch, yaw: $0.yaw, roll: $0.roll) }
        let angles = motion.effectiveTiltAngles(
            mode: s.screenTiltMode,
            settingsAngle: s.screenTiltAngle,
            settingsYaw: s.screenTiltYaw,
            settingsRoll: s.screenTiltRoll,
            currentTime: input.currentTime,
            effectiveTrimStart: input.project.effectiveTrimStart,
            animationDuration: s.animationSpeed.duration,
            isWithinVisibleVideoClip: visible,
            timelineTiltOverride: headTilt
        )
        lastAppliedTiltAngles = angles
        let distance = TiltMath.perspectiveDistance(for: videoRect.size)
        let tiltCenter = CGPoint(x: videoRect.midX, y: videoRect.midY)

        // ── Content group: geometry + tilt ────────────────────────────────
        // NEVER set .frame on transformed layers: frame is derived through
        // the current transform, so re-setting it while a tilt/zoom is active
        // corrupts position cumulatively. bounds + position are exact.
        //
        // Values are read BEFORE assignment (from the presentation layer when
        // an interpolation is already in flight) so `interpolate` can animate
        // from where the pixels actually are — see `interpolate`.
        let priorPosition = contentGroup.presentation()?.position ?? contentGroup.position

        contentGroup.bounds = CGRect(origin: .zero, size: contentRect.size)
        contentGroup.position = contentRect.origin
        contentGroup.transform = CATransform3D(TiltMath.projectionTransform(
            pitchDegrees: angles.pitch,
            yawDegrees: angles.yaw,
            rollDegrees: angles.roll,
            center: tiltCenter,
            distance: distance
        ))

        // Placement glide: dragging the card snaps `videoPlacement` between
        // nine discrete anchors, so without this it jumps.
        // `lastVideoPlacement == nil` is the FIRST render — there is nothing to
        // glide from, so the card would slide in from the centre on open.
        let placementChanged = lastVideoPlacement != nil && lastVideoPlacement != s.videoPlacement
        lastVideoPlacement = s.videoPlacement
        if placementChanged {
            interpolate(
                contentGroup, keyPath: "position",
                from: NSValue(point: NSPoint(x: priorPosition.x, y: priorPosition.y)),
                to: NSValue(point: NSPoint(x: contentRect.origin.x, y: contentRect.origin.y)),
                duration: Self.placementGlide, timing: .easeOut
            )
        }

        // ── Card-only zoom about the tilt-projected anchor ────────────────
        // Cover-compensated: zooming while tilted/rotated must never expose
        // the canvas behind the card's corners (TiltMath.effectiveCoverZoom —
        // the exporter applies the identical function).
        let zoom = TiltMath.effectiveCoverZoom(
            zoom: visible ? motion.zoom : 1.0,
            pitchDegrees: angles.pitch,
            yawDegrees: angles.yaw,
            rollDegrees: angles.roll,
            aspect: canvas.width / max(1, canvas.height)
        )
        let anchor = zoomAnchor(input, canvas: canvas, contentRect: contentRect,
                                videoRect: videoRect, angles: angles,
                                distance: distance, tiltCenter: tiltCenter, pad: pad)
        zoomGroup.bounds = CGRect(origin: .zero, size: canvas)
        zoomGroup.position = .zero
        // Card offset excursion rides OUTSIDE the zoom (canvas-space
        // slide of the whole zoomed card) — exporter mirrors this exactly.
        let cardOffset = motion.cardOffset
        var zt = CATransform3DMakeTranslation(
            anchor.x + CGFloat(cardOffset.x) * canvas.width,
            anchor.y + CGFloat(cardOffset.y) * canvas.height, 0)
        zt = CATransform3DScale(zt, zoom, zoom, 1)
        zt = CATransform3DTranslate(zt, -anchor.x, -anchor.y, 0)
        // Intro slide: eased entrance from an edge, deterministic from
        // OUTPUT time — same IntroSlideMath the exporter consumes.
        let intro = IntroSlideMath.state(
            style: s.introSlideStyle,
            at: input.currentTime - input.project.effectiveTrimStart,
            startTime: s.introSlideStart,
            duration: s.introSlideDuration,
            bounce: s.introSlideBounce,
            depth: s.introSlideDepth,
            speed: s.introSlideSpeed)
        if intro.active {
            let cx = canvas.width / 2, cy = canvas.height / 2
            var it = CATransform3DMakeTranslation(
                cx + intro.offset.x * canvas.width,
                cy + intro.offset.y * canvas.height, 0)
            it = CATransform3DScale(it, intro.scale, intro.scale, 1)
            it = CATransform3DTranslate(it, -cx, -cy, 0)
            zt = CATransform3DConcat(zt, it)
            // Rise entrance: a 3D forward tip applied OUTERMOST about the canvas
            // centre — the same TiltMath homography the exporter warps the card
            // corners through, so preview and export land on the identical warp.
            if abs(intro.pitch) > 0.01 {
                let perspective = CATransform3D(TiltMath.projectionTransform(
                    pitchDegrees: intro.pitch, yawDegrees: 0, rollDegrees: 0,
                    center: CGPoint(x: cx, y: cy),
                    distance: TiltMath.perspectiveDistance(for: canvas)))
                zt = CATransform3DConcat(perspective, zt)
            }
        }
        zoomGroup.transform = zt

        // ── Motion blur — SHARED MotionBlurMath on the zoom group ─────────
        // Finite difference of the spring camera across timeline time (works
        // for playback AND scrubbing — motion replays deterministically, so
        // adjacent scrub positions yield the same velocities playback sees).
        renderMotionBlur(input, s: s, canvas: canvas)

        // Background parallax — the backdrop drifts gently with the zoom for
        // depth (identical scale in the exporter via ZoomFocalMath).
        let parallax = ZoomFocalMath.parallaxScale(
            zoom: Double(zoom), strength: s.parallaxStrength)
        var bt = CATransform3DIdentity
        if parallax > 1.001 {
            bt = CATransform3DMakeTranslation(anchor.x, anchor.y, 0)
            bt = CATransform3DScale(bt, parallax, parallax, 1)
            bt = CATransform3DTranslate(bt, -anchor.x, -anchor.y, 0)
        }
        for backgroundLayer in [backgroundSolid, backgroundGradient, backgroundImage] {
            backgroundLayer.transform = bt
        }

        if ProcessInfo.processInfo.environment["CAPTURECAT_COMPOSITOR_DEBUG"] != nil {
            print("CDBG t=\(String(format: "%.2f", input.currentTime)) zoom=\(String(format: "%.3f", zoom)) anchor=\(anchor) angles=\(angles) contentRect=\(contentRect) videoRect=\(videoRect)")
        }

        // Camera layout must resolve BEFORE applyDip — the side-by-side
        // squeeze rides the same card transform the keynote dip owns.
        lastContentOrigin = contentRect.origin
        resolveCameraLayout(
            input, canvas: canvas,
            cardRectInCanvas: videoRect.offsetBy(dx: contentRect.minX, dy: contentRect.minY))

        // Keynote dip: device-segment index change triggers the transient
        // scale/opacity dip on the card subtree (same curve as phaseAnimator).
        let segmentIndex = activeDeviceSegmentIndex(input)
        applyDip(input, contentSize: contentRect.size)

        cardGroup.bounds = CGRect(origin: .zero, size: contentRect.size)
        overlayClip.bounds = CGRect(origin: .zero, size: contentRect.size)
        overlayClip.position = .zero

        renderCard(input, videoRect: videoRect, visible: visible, angles: angles, segmentIndex: segmentIndex)
        renderFocusOverlays(input, videoRect: videoRect, contentSize: contentRect.size, visible: visible, segmentIndex: segmentIndex)
        renderAnnotations(input, videoRect: videoRect, contentSize: contentRect.size, visible: visible)

        // Canvas half of the annotation blackout — see the layer's setup note.
        // Paused renders the dim settled, matching the annotations themselves
        // (Chrome.rendersSettled).
        let backdropAlpha = visible
            ? AnnotationRenderer.backdropAlpha(
                annotations: input.project.annotations, at: input.currentTime,
                settled: !input.isPlaying)
            : 0
        backdropDimLayer.isHidden = backdropAlpha <= 0.001
        backdropDimLayer.opacity = Float(backdropAlpha)
        backdropDimLayer.frame = CGRect(origin: .zero, size: canvas)
        renderCursorAndRipple(input, videoRect: videoRect, visible: visible)
        renderCurtain(input, videoRect: videoRect, visible: visible)
        renderSubtitle(input, canvas: canvas, visible: visible)
        renderKeystrokes(input, canvas: canvas, visible: visible)
        renderCamera(input, canvas: canvas, visible: visible)
        renderWatermark(input, canvas: canvas)

        CATransaction.commit()

        // On-canvas focal target: the selected zoom block's aim point, drawn
        // in content space so it rides every card transform. Screen-constant
        // size (radius divided by zoom), CapCut-style ring + crosshair.
        if visible,
           let zoomID = input.selectedZoomID,
           let region = input.project.zoomRegions.first(where: { $0.id == zoomID }) {
            let center = CGPoint(
                x: videoRect.minX + region.focalPoint.x * videoRect.width,
                y: videoRect.minY + region.focalPoint.y * videoRect.height)
            let r: CGFloat = 16 / max(1, zoom)
            let path = CGMutablePath()
            path.addEllipse(in: CGRect(
                x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
            for (dx, dy): (CGFloat, CGFloat) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                path.move(to: CGPoint(x: center.x + dx * r * 0.62, y: center.y + dy * r * 0.62))
                path.addLine(to: CGPoint(x: center.x + dx * r * 1.38, y: center.y + dy * r * 1.38))
            }
            let dotR = r * 0.12
            path.addEllipse(in: CGRect(
                x: center.x - dotR, y: center.y - dotR, width: 2 * dotR, height: 2 * dotR))
            focalReticleLayer.path = path
            focalReticleLayer.fillColor = nil
            focalReticleLayer.strokeColor = NSColor.white.cgColor
            focalReticleLayer.lineWidth = 2 / max(1, zoom)
            focalReticleLayer.lineCap = .round
            focalReticleLayer.shadowColor = NSColor.black.cgColor
            focalReticleLayer.shadowOpacity = 0.6
            focalReticleLayer.shadowOffset = .zero
            focalReticleLayer.shadowRadius = 2
            focalReticleLayer.isHidden = false
        } else {
            focalReticleLayer.isHidden = true
        }

        // Hit context for the interaction layer (canvas-space geometry from
        // THIS render, so gestures always match the pixels on screen).
        let interaction = ensureInteractionView()
        interaction.context = PreviewInteractionView.HitContext(
            project: input.project,
            isPlaying: input.isPlaying,
            canvas: canvas,
            contentRect: contentRect,
            videoRect: videoRect,
            zoom: zoom,
            zoomAnchor: anchor,
            cameraRect: lastCameraRect,
            subtitleRect: lastSubtitleRect,
            watermarkRect: lastWatermarkRect,
            selectedBlurID: localSelectedBlurID,
            selectedHighlightID: input.selectedHighlightID,
            selectedDepthFocusID: input.selectedDepthFocusID,
            selectedAnnotationID: input.selectedAnnotationID,
            cameraFitScale: ReactiveCameraLayout.canvasFitScale(for: canvas),
            cameraAspect: input.cameraVideoAspect,
            tiltPitch: angles.pitch,
            tiltYaw: angles.yaw,
            tiltRoll: angles.roll,
            tiltCenter: tiltCenter,
            tiltDistance: distance,
            selectedZoomFocal: input.selectedZoomID.flatMap { id in
                input.project.zoomRegions.first { $0.id == id }?.focalPoint
            },
            cardOffset: motion.cardOffset,
            activeZoomID: input.project.zoomRegions.first(where: {
                input.currentTime >= $0.startTime && input.currentTime <= $0.endTime
            })?.id
        )
    }

    // MARK: - Device chrome geometry (ports of PreviewView)

    private func showsDeviceFrame(_ input: FrameInput) -> Bool {
        input.project.recordingSourceKind == .device && input.project.settings.showDeviceFrame
    }

    /// Port of PreviewView.activeDeviceSegmentIndex (-2 = not applicable).
    private func activeDeviceSegmentIndex(_ input: FrameInput) -> Int {
        guard input.project.settings.showDeviceFrame,
              input.project.recordingSourceKind != .device else { return -2 }
        return input.project.sourceSegments.firstIndex {
            $0.kind == .device
                && input.currentTime >= $0.startTime - 0.01
                && input.currentTime <= $0.endTime + 0.01
        } ?? -1
    }

    /// Port of PreviewView.deviceFrameRect(for:).
    private func deviceFrameRect(_ input: FrameInput, videoRect: CGRect) -> CGRect? {
        guard input.project.settings.showDeviceFrame else { return nil }
        if input.project.recordingSourceKind == .device { return videoRect }
        guard let segment = input.project.sourceSegments.first(where: {
            $0.kind == .device
                && input.currentTime >= $0.startTime - 0.01
                && input.currentTime <= $0.endTime + 0.01
        }) else { return nil }
        let n = segment.normalizedContentRect
        return CGRect(
            x: videoRect.minX + n.minX * videoRect.width,
            y: videoRect.minY + n.minY * videoRect.height,
            width: n.width * videoRect.width,
            height: n.height * videoRect.height
        )
    }

    // MARK: - Keynote dip (device-segment cut)

    /// Evaluates `DeviceSegmentDip` for this frame's timeline position.
    ///
    /// This used to be a wall-clock ramp kicked off by a 60Hz `Timer` when the
    /// active segment index CHANGED. That was wrong three ways: the ramp began
    /// at the cut instead of straddling it, so the content swap played at full
    /// opacity and popped; the piecewise ease-in-out turned around through a
    /// corner at the trough; and a free-running timer beat against vsync. It
    /// also forked the curve away from the exporter's, which is a §2 violation.
    private func applyDip(_ input: FrameInput, contentSize: CGSize) {
        var boundaries: [TimeInterval] = []
        if input.project.settings.showDeviceFrame,
           input.project.recordingSourceKind != .device {
            for segment in input.project.sourceSegments where segment.kind == .device {
                boundaries.append(segment.startTime)
                boundaries.append(segment.endTime)
            }
        }
        let phase = DeviceSegmentDip.phase(at: input.currentTime, boundaries: boundaries)
        let scale = DeviceSegmentDip.scale(phase)
        let cx = contentSize.width / 2, cy = contentSize.height / 2
        var t = CATransform3DMakeTranslation(cx, cy, 0)
        t = CATransform3DScale(t, scale, scale, 1)
        t = CATransform3DTranslate(t, -cx, -cy, 0)

        // Side-by-side squeeze: the card scales toward the leading column
        // while the background stays put. Concatenated with the dip on the
        // SAME layer the exporter transforms at its card-over-transparency
        // seam, from the same shared CameraLayoutMath transform.
        let layout = lastCameraLayout
        if layout.cardScale != 1 || layout.cardTranslationX != 0 {
            // contentSize-local: the card rect the transform is defined about
            // is in canvas space, and cardGroup is laid out in content space —
            // a uniform scale about the centre plus an X shift is the same in
            // both, so only the translation needs no conversion.
            let s = layout.cardScale
            var l = CATransform3DMakeTranslation(cx + layout.cardTranslationX, cy, 0)
            l = CATransform3DScale(l, s, s, 1)
            l = CATransform3DTranslate(l, -cx, -cy, 0)
            t = CATransform3DConcat(l, t)
        }
        cardGroup.transform = t
        cardGroup.opacity = Float(DeviceSegmentDip.opacity(phase))
    }

    // MARK: - Background

    private func renderBackground(_ input: FrameInput, canvas: CGSize) {
        let s = input.project.settings
        let full = CGRect(origin: .zero, size: canvas)
        backgroundSolid.frame = full
        backgroundGradient.frame = full
        backgroundImage.frame = full
        backgroundSolid.isHidden = true
        backgroundGradient.isHidden = true
        backgroundImage.isHidden = true

        // SHARED BackgroundLook draws the whole backdrop (fill + look) into
        // one bitmap that the exporter uses byte-for-byte. NOT a
        // CAGradientLayer (gamma-sRGB ramp; the app's ramp is Oklab) and NOT
        // per-layer CIFilters (they would have to be mirrored by hand).
        let spec = BackgroundLook.Spec(s)
        guard spec.type != .transparent else { return }
        let scale = effectiveScale
        let key = "\(spec.cacheKey)|\(Int(canvas.width))x\(Int(canvas.height))|\(scale)"
        if cachedBackgroundKey != key, backgroundInflightKey != key {
            // Styled backdrops (blur/halftone/grain…) are whole-canvas bitmap
            // renders — far too slow for the main thread while a Look slider
            // streams ticks. Render off-main, latest wins; the previous
            // bitmap stays up meanwhile, so a drag shows a briefly-stale
            // backdrop instead of a frozen app. A PLAIN look stays sync:
            // it's a cheap CG ramp, and the settled state must never lag.
            if spec.isPlainLook {
                backgroundInflightKey = nil
                cachedBackgroundKey = key
                cachedBackground = BackgroundLook.cgImage(for: spec, size: canvas, scale: scale)
            } else {
                backgroundInflightKey = key
                Task.detached(priority: .userInitiated) { [weak self] in
                    let img = BackgroundLook.cgImage(for: spec, size: canvas, scale: scale)
                    await MainActor.run { [weak self] in
                        guard let self, self.backgroundInflightKey == key else { return }
                        self.backgroundInflightKey = nil
                        self.cachedBackgroundKey = key
                        self.cachedBackground = img
                        self.backgroundImage.contents = img
                        // A newer spec may have arrived while rendering — the
                        // observation loop will call renderBackground again
                        // with it, which re-kicks; nothing to do here.
                    }
                }
            }
        }
        backgroundImage.isHidden = false
        backgroundImage.contentsGravity = .resize
        backgroundImage.contents = cachedBackground
    }

    // MARK: - Card

    private func renderCard(
        _ input: FrameInput,
        videoRect: CGRect,
        visible: Bool,
        angles: (pitch: Double, yaw: Double, roll: Double),
        segmentIndex: Int
    ) {
        let s = input.project.settings
        cardGroup.position = .zero
        cardShadow.isHidden = !visible
        videoClip.isHidden = !visible
        bezelButtonsLayer.isHidden = true
        bezelSlabLayer.isHidden = true
        bezelLayer.isHidden = true
        islandLayer.isHidden = true
        guard visible else { return }

        let frameRect = deviceFrameRect(input, videoRect: videoRect)
        let deviceChrome = showsDeviceFrame(input) || segmentIndex >= 0

        videoClip.frame = videoRect

        // Inner clip (videoSurfaceClipShape): phone-screen rounded rect over
        // the device sub-rect, else the window shape at windowCornerRadius.
        screenClip.frame = CGRect(origin: .zero, size: videoRect.size)
        let screenMask = CAShapeLayer()
        if let frameRect {
            let local = CGRect(
                x: frameRect.minX - videoRect.minX,
                y: frameRect.minY - videoRect.minY,
                width: frameRect.width, height: frameRect.height
            )
            let r = DeviceFrameLayout.screenCornerRadius(forVideoSize: frameRect.size)
            screenMask.path = ContinuousRoundedRect.path(rect: local, cornerRadius: r)
        } else {
            let r = max(0, s.windowCornerRadius)
            screenMask.path = r > 0
                ? ContinuousRoundedRect.path(rect: CGRect(origin: .zero, size: videoRect.size), cornerRadius: r)
                : CGPath(rect: CGRect(origin: .zero, size: videoRect.size), transform: nil)
        }
        screenClip.mask = screenMask

        // Outer clip (frameClipShape) — dropped entirely for device chrome so
        // the bezel/shadow aren't amputated (SwiftUI insets the clip -10000).
        if deviceChrome {
            videoClip.mask = nil
            cardShadow.isHidden = true
        } else {
            let clipPath = cardClipPath(s, size: videoRect.size)
            let mask = CAShapeLayer()
            mask.path = clipPath
            videoClip.mask = mask
            cardShadow.isHidden = false
            cardShadow.frame = videoRect
            cardShadow.shadowPath = clipPath
            cardShadow.shadowOpacity = Float(0.45 * s.shadowOpacity)
            cardShadow.shadowRadius = s.shadowRadius
            cardShadow.shadowOffset = CGSize(width: 0, height: s.shadowRadius / 3)
        }

        // Device bezel + island: the EXACT SwiftUI chrome, rasterized at
        // content size (parity by construction) and composited around the
        // video. Bezel behind (carries its own shadow), island above.
        if let frameRect {
            let contentSize = cardGroup.bounds.size
            renderDeviceChrome(input, frameRect: frameRect, contentSize: contentSize, angles: angles)
        }

        // Hidden-menu-bar crop: video draws OVERSIZED and bottom-aligned.
        let crop = menuBarCropFraction(input)
        let fullVideoHeight = max(1, videoRect.height) / max(0.01, 1 - crop)
        videoLayer.frame = CGRect(
            x: 0, y: videoRect.height - fullVideoHeight,
            width: videoRect.width, height: fullVideoHeight
        )
        posterLayer.frame = videoLayer.frame

        if let player = input.player {
            if videoDriver?.player !== player {
                videoDriver = VideoFrameLayerDriver(player: player, layer: videoLayer)
            }
            posterLayer.isHidden = videoDriver?.hasFrame == true
            posterLayer.contents = input.videoPosterImage
        } else {
            posterLayer.isHidden = input.videoPosterImage == nil
            posterLayer.contents = input.videoPosterImage
        }

        // Menu bar replacement (dark/light) — same renderer as the exporter.
        // Hidden while a device segment fills the frame (SwiftUI gate).
        if (s.menuBarReplacement == .dark || s.menuBarReplacement == .light),
           input.project.recordingSourceKind != .device,
           segmentIndex < 0 {
            let barH = max(4, videoRect.height * CGFloat(s.menuBarHeight) / 100)
            if let bar = MenuBarRenderer.image(for: .init(
                style: s.menuBarReplacement,
                title: s.menuBarTitle,
                titleAlignment: s.menuBarTitleAlignment,
                showStatusIcons: s.menuBarShowStatusIcons,
                clock: s.menuBarClock,
                width: Int(videoRect.width.rounded()),
                height: Int(barH.rounded())
            )) {
                menuBarLayer.isHidden = false
                menuBarLayer.contents = bar
                menuBarLayer.frame = CGRect(x: 0, y: 0, width: videoRect.width, height: barH)
            } else {
                menuBarLayer.isHidden = true
            }
        } else {
            menuBarLayer.isHidden = true
        }
    }

    private func cardClipPath(_ s: ProjectSettings, size: CGSize) -> CGPath {
        let rect = CGRect(origin: .zero, size: size)
        switch s.frameShape {
        case .rectangle:
            return CGPath(rect: rect, transform: nil)
        case .roundedRect:
            let r = min(max(0, s.cornerRadius), min(size.width, size.height) / 2)
            return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
        case .squircle:
            let r = min(max(0, s.cornerRadius), min(size.width, size.height) / 2)
            return ContinuousRoundedRect.path(rect: rect, cornerRadius: r)
        }
    }

    // MARK: - Device chrome (rasterized SwiftUI — parity by construction)

    private func renderDeviceChrome(
        _ input: FrameInput,
        frameRect: CGRect,
        contentSize: CGSize,
        angles: (pitch: Double, yaw: Double, roll: Double)
    ) {
        let s = input.project.settings
        // Raster slack: the bezel's soft shadow and the tilt side slab extend
        // BEYOND the content bounds — an exactly content-sized raster clips
        // them (visible as a missing shadow and a hard-edged slab under tilt).
        let slack = ceil(s.shadowRadius * 3 + frameRect.width * 0.12 + 24)
        // Raster bounds stay the FULL content rect plus slack, exactly as the
        // single-raster version had them. Cropping to the bezel's own bounds is
        // tempting (a phone is a narrow strip of a 16:9 canvas) but it measurably
        // changes output: the body's drop shadow is blurred inside a
        // context-sized transparency layer, and a tighter context clips the tail
        // the full canvas gave room for. Measured 1-2/255 against the goldens.
        let rasterSize = CGSize(width: contentSize.width + 2 * slack,
                                height: contentSize.height + 2 * slack)
        let localVideoRect = frameRect.offsetBy(dx: slack, dy: slack)
        let bezelScale = effectiveScale

        // NOTE the key deliberately omits pitch/yaw. `drawSideButtons` and
        // `drawBody` take no angles at all, and tilt enters `drawSideSlab`
        // purely as a TRANSLATION of the same pixels — so the chrome is
        // tilt-independent up to moving one layer. The old key quantized the
        // angles into itself, which meant every 0.1 degree of a tilt spring
        // threw away the cache and re-rasterized the whole chrome mid-animation
        // at ~53ms a frame. That is the device-segment lag.
        let bezelKey = "\(frameRect)|\(contentSize)|\(s.shadowRadius)|\(s.shadowOpacity)|\(bezelScale)"
        if cachedBezel?.key != bezelKey {
            let buttons = DeviceBezelRenderer.layerImage(size: rasterSize, scale: bezelScale) {
                DeviceBezelRenderer.drawSideButtons(in: $0, videoRect: localVideoRect)
            }
            let slab = DeviceBezelRenderer.layerImage(size: rasterSize, scale: bezelScale) {
                DeviceBezelRenderer.drawSideSlab(in: $0, videoRect: localVideoRect, offset: .zero)
            }
            let body = DeviceBezelRenderer.layerImage(size: rasterSize, scale: bezelScale) {
                DeviceBezelRenderer.drawBody(in: $0, videoRect: localVideoRect,
                                             shadowRadius: s.shadowRadius,
                                             shadowOpacity: s.shadowOpacity)
            }
            if let buttons, let slab, let body {
                cachedBezel = (bezelKey, buttons, slab, body)
            }
        }
        if let cached = cachedBezel {
            let slabOffset = TiltMath.deviceSideOffset(
                pitchDegrees: angles.pitch,
                yawDegrees: angles.yaw,
                videoWidth: frameRect.width
            )
            let base = CGRect(x: -slack, y: -slack, width: rasterSize.width, height: rasterSize.height)
            bezelButtonsLayer.isHidden = false
            bezelSlabLayer.isHidden = false
            bezelLayer.isHidden = false
            bezelButtonsLayer.contents = cached.buttons
            bezelSlabLayer.contents = cached.slab
            bezelLayer.contents = cached.body
            bezelButtonsLayer.frame = base
            bezelLayer.frame = base
            // The slab raster is baked at offset .zero; tilt is applied here as
            // a layer move, which is free and continuous.
            bezelSlabLayer.frame = base.offsetBy(dx: slabOffset.width, dy: slabOffset.height)
        }

        // Screen seam + Dynamic Island — phone aspect only (SwiftUI gate).
        //
        // ROOT CAUSE of the duplicated-island report, and why it must stay
        // this way: the island used to be rasterized (ImageRenderer → an
        // NSImage assigned to `islandLayer.contents`). Two things go wrong
        // with that, and only together do they produce TWO pills:
        //  1. A CALayer composites `contents` AND its sublayers — contents is
        //     NOT replaced by sublayers, it is drawn UNDER them. So the
        //     moment the native seam/capsule shapes were added alongside a
        //     still-assigned raster, both pills drew at once.
        //  2. The raster lands at the wrong Y in this flipped hierarchy
        //     (measured: pill centroid canvas y≈50 → y≈166, ~116pt lower —
        //     "floating mid-screen over the recording"), and on the
        //     device-SEGMENT shape, where frameRect is a sub-rect of the
        //     video, SwiftUI's Group + .frame collapses the layout and the
        //     pill disappears entirely.
        // The bezel raster is NOT a second source (DeviceBezelView draws body
        // + side slab + glass margin only, no island), and the recording's
        // own pixels are not either (device captures carry ordinary app
        // content in the island band, no baked pill) — both verified.
        // Native shape layers in the card's own y-down space are the fix, and
        // `contents` is wiped on every pass so a raster can never coexist.
        if DeviceFrameLayout.isPhoneAspect(frameRect.size) {
            islandLayer.isHidden = false
            islandLayer.frame = CGRect(origin: .zero, size: contentSize)
            islandLayer.contents = nil // see above: contents + sublayers = 2 pills
            islandLayer.sublayers?.forEach { $0.removeFromSuperlayer() }

            let unit = frameRect.width
            let cutout = DeviceFrameLayout.islandSize(forVideoWidth: unit)
            let dot = unit * DeviceFrameLayout.cameraDotFraction
            let cutoutCenterY = frameRect.minY
                + DeviceFrameLayout.islandTopInset(forVideoWidth: unit)
                + cutout.height / 2

            // Seam — continuous-corner rounded-rect stroke around the screen.
            let seam = CAShapeLayer()
            let seamWidth = DeviceFrameLayout.seamWidth(forVideoWidth: unit)
            let seamRect = frameRect.insetBy(dx: seamWidth / 2, dy: seamWidth / 2)
            seam.path = ContinuousRoundedRect.path(
                rect: seamRect,
                cornerRadius: DeviceFrameLayout.screenCornerRadius(forVideoSize: frameRect.size)
            )
            seam.fillColor = nil
            seam.strokeColor = NSColor.black.withAlphaComponent(0.55).cgColor
            seam.lineWidth = seamWidth
            islandLayer.addSublayer(seam)

            // Dynamic Island capsule.
            let capsule = CAShapeLayer()
            capsule.path = CGPath(
                roundedRect: CGRect(
                    x: frameRect.midX - cutout.width / 2,
                    y: cutoutCenterY - cutout.height / 2,
                    width: cutout.width, height: cutout.height
                ),
                cornerWidth: cutout.height / 2, cornerHeight: cutout.height / 2,
                transform: nil
            )
            capsule.fillColor = NSColor.black.cgColor
            islandLayer.addSublayer(capsule)

            // Front-camera lens + faint ring.
            let dotCenter = CGPoint(
                x: frameRect.midX + unit * DeviceFrameLayout.cameraDotOffsetFraction,
                y: cutoutCenterY
            )
            let lens = CAShapeLayer()
            lens.path = CGPath(ellipseIn: CGRect(
                x: dotCenter.x - dot / 2, y: dotCenter.y - dot / 2, width: dot, height: dot
            ), transform: nil)
            lens.fillColor = NSColor(srgbRed: 0.07, green: 0.08, blue: 0.11, alpha: 1).cgColor
            islandLayer.addSublayer(lens)
            let ring = CAShapeLayer()
            let ringInset = dot * 0.05
            ring.path = CGPath(ellipseIn: CGRect(
                x: dotCenter.x - dot / 2 + ringInset, y: dotCenter.y - dot / 2 + ringInset,
                width: dot - 2 * ringInset, height: dot - 2 * ringInset
            ), transform: nil)
            ring.fillColor = nil
            ring.strokeColor = NSColor.white.withAlphaComponent(0.13).cgColor
            ring.lineWidth = max(0.5, dot * 0.10)
            islandLayer.addSublayer(ring)
        }
    }

    // MARK: - Highlight dims + blur patches (card overlays)

    private func renderFocusOverlays(
        _ input: FrameInput,
        videoRect: CGRect,
        contentSize: CGSize,
        visible: Bool,
        segmentIndex: Int
    ) {
        let s = input.project.settings
        highlightGroup.sublayers?.forEach { $0.removeFromSuperlayer() }
        blurGroup.sublayers?.forEach { $0.removeFromSuperlayer() }
        overlayClip.isHidden = !visible
        guard visible else { return }

        // The overlays share the CARD-level clip: frame shape normally,
        // unclipped when device chrome is active.
        let deviceChrome = showsDeviceFrame(input) || segmentIndex >= 0
        if deviceChrome {
            overlayClip.mask = nil
        } else {
            let mask = CAShapeLayer()
            let path = cardClipPath(s, size: videoRect.size)
            var shift = CGAffineTransform(translationX: videoRect.minX, y: videoRect.minY)
            mask.path = path.copy(using: &shift) ?? path
            overlayClip.mask = mask
        }

        let time = input.currentTime
        let transitionDuration = s.animationSpeed.duration

        // ── Highlights: full-card dim with a punched hole (destinationOut),
        // plus the paused-editor outline. SwiftUI z-order: below blur patches.
        let activeHighlights = input.project.highlightRegions.filter {
            time >= $0.startTime && time <= $0.endTime
        }
        for region in activeHighlights {
            let regionRect = region.rectInViewSpace(in: videoRect)
            let cornerRadius = region.cornerRadius(in: videoRect)
            let envelope = Easing.regionEnvelope(
                at: time, startTime: region.startTime, endTime: region.endTime,
                transitionDuration: transitionDuration
            )

            let dim = CALayer()
            dim.frame = videoRect
            dim.backgroundColor = NSColor.black.cgColor
            dim.opacity = Float(region.dimOpacity * envelope)
            // Punch the hole via an even-odd mask (CA's destinationOut).
            let holePath = CGMutablePath()
            holePath.addRect(CGRect(origin: .zero, size: videoRect.size))
            let localHole = CGRect(
                x: regionRect.minX - videoRect.minX,
                y: regionRect.minY - videoRect.minY,
                width: max(1, regionRect.width), height: max(1, regionRect.height)
            )
            holePath.addPath(CGPath(
                roundedRect: localHole,
                cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil
            ))
            let holeMask = CAShapeLayer()
            holeMask.path = holePath
            holeMask.fillRule = .evenOdd
            dim.mask = holeMask
            highlightGroup.addSublayer(dim)


        }

        // ── Blur regions: the CURRENT video frame, blurred with the shared
        // radius convention (CI sigma = SwiftUI radius / 2), masked by the
        // feather-blurred region rect. Same pipeline as the exporter.
        let activeBlurs = input.project.blurRegions.filter {
            time >= $0.startTime && time <= $0.endTime
        }
        let activeFocus = input.project.focusRegions.filter {
            time >= $0.startTime && time <= $0.endTime
        }

        // ONE selection-chrome contract: chrome exists only for the SELECTED
        // object — blur and highlight lose their old always-on faint
        // outlines, exactly like depth focus.
        renderFocusChrome(
            input, videoRect: videoRect, contentSize: contentSize,
            blurs: activeBlurs.filter { input.selectedBlurID == $0.id },
            highlights: activeHighlights.filter { input.selectedHighlightID == $0.id },
            focus: activeFocus.filter { input.selectedDepthFocusID == $0.id }
        )

        guard !activeBlurs.isEmpty || !activeFocus.isEmpty else { return }
        guard let sourceCI = currentVideoCIImage(input) else { return }

        // ── Depth Focus: the current frame through the SHARED FocusMath
        // profile (CIMaskedVariableBlur over the one shared gradient mask) —
        // same per-frameToken patch caching as the blur regions below.
        for region in activeFocus {
            let key = "\(region.rect)|\(region.intensity)|\(region.falloff)|\(region.style.rawValue)|\(region.angle)|\(region.cornerRadius)|\(Int(videoRect.width))x\(Int(videoRect.height))|\(videoDriver?.frameToken ?? -1)"
            let patch: CGImage
            if let cached = cachedFocusPatches[region.id], cached.key == key {
                patch = cached.image
            } else if let built = buildFocusPatch(
                source: sourceCI, region: region, videoRect: videoRect,
                windowCornerRadius: max(0, s.windowCornerRadius)
            ) {
                cachedFocusPatches[region.id] = (key, built)
                patch = built
            } else { continue }
            let l = CALayer()
            l.frame = videoRect
            l.contents = patch
            l.contentsGravity = .resize
            blurGroup.addSublayer(l)
        }
        let activeFocusIDs = Set(activeFocus.map(\.id))
        cachedFocusPatches = cachedFocusPatches.filter { activeFocusIDs.contains($0.key) }
        cachedFocusMasks = cachedFocusMasks.filter { activeFocusIDs.contains($0.key) }

        guard !activeBlurs.isEmpty else { return }

        for region in activeBlurs {
            let regionRect = region.rectInViewSpace(in: videoRect)
            let key = blurPatchKey(region: region, videoRect: videoRect,
                                   frameToken: videoDriver?.frameToken ?? -1, time: time)
            let patch: CGImage
            if let cached = cachedBlurPatches[region.id], cached.key == key {
                patch = cached.image
            } else if let built = buildBlurPatch(
                source: sourceCI, region: region, videoRect: videoRect,
                windowCornerRadius: max(0, s.windowCornerRadius), time: time
            ) {
                cachedBlurPatches[region.id] = (key, built)
                patch = built
            } else { continue }

            let l = CALayer()
            l.frame = videoRect
            l.contents = patch
            l.contentsGravity = .resize
            blurGroup.addSublayer(l)
            _ = regionRect // (patch already masked at the region rect)
        }
        // Drop cache entries for regions no longer active.
        let activeIDs = Set(activeBlurs.map(\.id))
        cachedBlurPatches = cachedBlurPatches.filter { activeIDs.contains($0.key) }
    }

    /// Region outlines / handle dots / value pills, drawn by
    /// `SelectionChromeKit` (pure CoreGraphics); the interaction view owns
    /// the matching hit zones.
    private func renderFocusChrome(
        _ input: FrameInput,
        videoRect: CGRect,
        contentSize: CGSize,
        blurs: [BlurRegion],
        highlights: [HighlightRegion],
        focus: [FocusRegion]
    ) {
        focusChromeLayer.isHidden = true
        guard !blurs.isEmpty || !highlights.isEmpty || !focus.isEmpty else { return }
        let rasterScale = effectiveScale
        var key = blurs.map { "\($0.id):\($0.rect):\($0.intensity)" }.joined(separator: ",")
        key += "|" + highlights.map { "\($0.id):\($0.rect):\($0.opacity)" }.joined(separator: ",")
        key += "|" + focus.map { "\($0.id):\($0.rect):\($0.intensity):\($0.style.rawValue):\($0.angle)" }.joined(separator: ",")
        key += "|\(input.selectedBlurID?.uuidString ?? "-")"
        key += "|\(input.selectedHighlightID?.uuidString ?? "-")"
        key += "|\(input.selectedDepthFocusID?.uuidString ?? "-")"
        key += "|\(videoRect)|\(contentSize)|\(rasterScale)"
        if cachedFocusChrome?.key != key {
            var regions: [SelectionChromeKit.Region] = blurs.map {
                .init(rect: $0.rect, cornerRadius: 10,
                      isSelected: input.selectedBlurID == $0.id,
                      sliderValue: $0.intensity, sliderRange: 0.1...1.0,
                      leadingIcon: "eye", trailingIcon: "eye.slash.fill")
            }
            regions += focus.map { region in
                let rendered = region.rectInViewSpace(in: videoRect)
                // SAME radius rule as FocusMath's SDF, so the outline traces
                // the exact blur boundary the user set.
                let corner = region.style == .area
                    ? CGFloat(max(0, min(1, region.cornerRadius)))
                        * min(rendered.width, rendered.height) / 2
                    : 0
                return .init(rect: region.rect,
                             cornerRadius: corner,
                             isSelected: input.selectedDepthFocusID == region.id,
                             sliderValue: region.intensity, sliderRange: 0.1...1.0,
                             leadingIcon: "circle.dashed", trailingIcon: "camera.aperture")
            }
            regions += highlights.map {
                let rendered = $0.rectInViewSpace(in: videoRect)
                return .init(rect: $0.rect,
                             cornerRadius: HighlightRegion.cornerRadius(for: rendered, in: videoRect),
                             isSelected: input.selectedHighlightID == $0.id,
                             sliderValue: $0.opacity, sliderRange: 0.1...0.9,
                             leadingIcon: "circle.lefthalf.filled", trailingIcon: "circle.fill")
            }
            if let img = SelectionChromeKit.image(
                size: contentSize, regions: regions,
                containerRect: videoRect, scale: rasterScale
            ) {
                cachedFocusChrome = (key, img)
            }
        }
        if let img = cachedFocusChrome?.image {
            focusChromeLayer.isHidden = false
            focusChromeLayer.contents = img
            focusChromeLayer.frame = CGRect(origin: .zero, size: contentSize)
        }
    }

    private func blurPatchKey(
        region: BlurRegion, videoRect: CGRect, frameToken: Int, time: TimeInterval
    ) -> String {
        // Time enters the key ONLY for the animated mosaic, quantized to the
        // shared step — at 8 steps/s that is 8 patch renders/s max, not 60.
        let stepKey = region.animated && region.style == .pixelate
            ? "\(BlurStyleMath.quantizedStep(at: time))" : "-"
        return "\(region.rect)|\(region.intensity)|\(region.style.rawValue)|\(region.animated)|\(stepKey)|\(Int(videoRect.width))x\(Int(videoRect.height))|\(frameToken)"
    }

    /// The video frame the card is currently showing, as a CIImage.
    private func currentVideoCIImage(_ input: FrameInput) -> CIImage? {
        if let buffer = videoDriver?.currentPixelBuffer {
            return CIImage(cvPixelBuffer: buffer)
        }
        if let poster = input.videoPosterImage,
           let cg = poster.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return CIImage(cgImage: cg)
        }
        return nil
    }

    /// SwiftUI recipe: video clipped to the window shape → .blur(radius R) →
    /// masked by the region rect blurred by featherRadius. CI equivalents:
    /// sigma = R/2 and featherSigma = featherRadius/2 (house convention).
    private func buildBlurPatch(
        source: CIImage,
        region: BlurRegion,
        videoRect: CGRect,
        windowCornerRadius: CGFloat,
        time: TimeInterval
    ) -> CGImage? {
        let targetSize = videoRect.size
        guard targetSize.width > 2, targetSize.height > 2 else { return nil }
        let srcExtent = source.extent
        guard srcExtent.width > 0, srcExtent.height > 0 else { return nil }

        // Scale source → videoRect points (1×; the layer stretches nothing).
        let sx = targetSize.width / srcExtent.width
        let sy = targetSize.height / srcExtent.height
        var img = source.transformed(by: CGAffineTransform(scaleX: sx, y: sy)
            .translatedBy(x: -srcExtent.minX, y: -srcExtent.minY))
        let frame = CGRect(origin: .zero, size: targetSize)

        // Clip to the window shape BEFORE blurring (SwiftUI order), so the
        // blur bleeds over the shape edge exactly like `.clipShape().blur()`.
        if windowCornerRadius > 0 {
            if let clipMask = rasterMask(
                rect: frame, hole: nil,
                rounded: CGRect(origin: .zero, size: targetSize),
                cornerRadius: windowCornerRadius, blurSigma: 0
            ) {
                img = img.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: frame),
                    kCIInputMaskImageKey: clipMask,
                ])
            }
        }

        let regionLocal = CGRect(
            x: region.rect.minX * targetSize.width,
            y: region.rect.minY * targetSize.height,
            width: region.rect.width * targetSize.width,
            height: region.rect.height * targetSize.height
        )
        // CI is Y-up: flip the region rect vertically inside the frame.
        let flipped = CGRect(
            x: regionLocal.minX,
            y: targetSize.height - regionLocal.maxY,
            width: regionLocal.width, height: regionLocal.height
        )

        switch region.style {
        case .blur:
            // ORIGINAL gaussian pipeline, untouched — legacy regions render
            // byte-identically (radius/2 = the house CI-sigma convention).
            let radius = region.blurRadius(in: targetSize)
            img = img.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius / 2])
                .cropped(to: frame)
        case .pixelate:
            // Mosaic censor look — block size and (optional) per-step grid
            // jitter from the SHARED BlurStyleMath; the grid is anchored to
            // the region's origin so blocks don't swim when the region moves.
            let block = BlurStyleMath.pixelScale(
                strength: region.intensity, regionSize: regionLocal.size)
            let jitter = BlurStyleMath.gridJitter(
                at: time, animated: region.animated, blockSize: block)
            img = img.clampedToExtent()
                .applyingFilter("CIPixellate", parameters: [
                    kCIInputScaleKey: block,
                    kCIInputCenterKey: CIVector(
                        x: flipped.minX + jitter.x, y: flipped.minY + jitter.y),
                ])
                .cropped(to: frame)
        }
        guard let feather = rasterMask(
            rect: frame, hole: nil, rounded: flipped,
            cornerRadius: BlurRegion.previewCornerRadius,
            blurSigma: region.featherRadius(in: targetSize) / 2
        ) else { return nil }

        let masked = img.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: frame),
            kCIInputMaskImageKey: feather,
        ])
        return ciContext.createCGImage(masked, from: frame)
    }

    /// Depth Focus patch: video → window clip → CIMaskedVariableBlur with the
    /// SHARED FocusMath gradient mask and the SHARED intensity→sigma mapping.
    /// The exporter runs the identical filters over the identical mask.
    private func buildFocusPatch(
        source: CIImage,
        region: FocusRegion,
        videoRect: CGRect,
        windowCornerRadius: CGFloat
    ) -> CGImage? {
        let targetSize = videoRect.size
        guard targetSize.width > 2, targetSize.height > 2 else { return nil }
        let srcExtent = source.extent
        guard srcExtent.width > 0, srcExtent.height > 0 else { return nil }

        let sx = targetSize.width / srcExtent.width
        let sy = targetSize.height / srcExtent.height
        var img = source.transformed(by: CGAffineTransform(scaleX: sx, y: sy)
            .translatedBy(x: -srcExtent.minX, y: -srcExtent.minY))
        let frame = CGRect(origin: .zero, size: targetSize)

        // Clip to the window shape BEFORE blurring (same order as blur patches).
        if windowCornerRadius > 0 {
            if let clipMask = rasterMask(
                rect: frame, hole: nil,
                rounded: CGRect(origin: .zero, size: targetSize),
                cornerRadius: windowCornerRadius, blurSigma: 0
            ) {
                img = img.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: frame),
                    kCIInputMaskImageKey: clipMask,
                ])
            }
        }

        let maskKey = "\(region.rect)|\(region.style.rawValue)|\(region.angle)|\(region.falloff)|\(region.cornerRadius)|\(Int(targetSize.width))x\(Int(targetSize.height))"
        let maskCI: CIImage
        if let cached = cachedFocusMasks[region.id], cached.key == maskKey {
            maskCI = cached.image
        } else if let cg = FocusMath.maskImage(
            regionRect: region.rect, style: region.style,
            angleDegrees: region.angle, falloff: region.falloff,
            cornerRadius: region.cornerRadius,
            videoSize: targetSize
        ) {
            let raw = CIImage(cgImage: cg)
            let scaled = raw.transformed(by: CGAffineTransform(
                scaleX: targetSize.width / raw.extent.width,
                y: targetSize.height / raw.extent.height))
            cachedFocusMasks[region.id] = (maskKey, scaled)
            maskCI = scaled
        } else { return nil }

        let sigma = FocusMath.blurSigma(intensity: region.intensity, videoSize: targetSize)
        let out = img.clampedToExtent()
            .applyingFilter("CIMaskedVariableBlur", parameters: [
                "inputMask": maskCI,
                kCIInputRadiusKey: sigma,
            ])
            .cropped(to: frame)
        return ciContext.createCGImage(out, from: frame)
    }

    /// White rounded-rect mask (optionally gaussian-feathered) on clear.
    private func rasterMask(
        rect: CGRect, hole: CGRect?, rounded: CGRect,
        cornerRadius: CGFloat, blurSigma: CGFloat
    ) -> CIImage? {
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1))
        let r = min(cornerRadius, min(rounded.width, rounded.height) / 2)
        var shape: CIImage
        if r > 0 {
            // Rounded rect via CIRoundedRectangleGenerator.
            guard let gen = CIFilter(name: "CIRoundedRectangleGenerator") else { return nil }
            gen.setValue(CIVector(cgRect: rounded), forKey: "inputExtent")
            gen.setValue(r, forKey: "inputRadius")
            gen.setValue(CIColor.white, forKey: "inputColor")
            guard let out = gen.outputImage else { return nil }
            shape = out
        } else {
            shape = white.cropped(to: rounded)
        }
        if blurSigma > 0 {
            shape = shape.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurSigma])
        }
        return shape.cropped(to: rect)
    }

    // MARK: - Annotations (AnnotationRenderer — shared with the exporter)

    private func renderAnnotations(
        _ input: FrameInput,
        videoRect: CGRect,
        contentSize: CGSize,
        visible: Bool
    ) {
        annotationLayer.isHidden = true
        guard visible, !input.project.annotations.isEmpty else { return }
        let active = input.project.annotations.contains {
            input.currentTime >= $0.startTime && input.currentTime <= $0.endTime
        }
        guard active else { return }

        // Tap ripples AND Keynote build effects animate off the timeline
        // clock — include quantized time in the key whenever any live
        // annotation needs the clock (tap, or inside its enter/exit build
        // window), so static overlays still never re-raster during playback.
        let needsClock = input.project.annotations.contains { a in
            guard input.currentTime >= a.startTime, input.currentTime <= a.endTime else { return false }
            if a.type == .tap { return true }
            // Paused renders settled (Chrome.rendersSettled) — build windows
            // only animate, and therefore only re-key, during playback.
            guard input.isPlaying else { return false }
            // Per-effect windows: Draw On animates for a full second, so it
            // must keep re-keying past the standard 0.3s build window.
            let entering = a.enterEffect != .none
                && input.currentTime - a.startTime < AnnotationEffectMath.effectDuration(a.enterEffect)
            let exiting = a.exitEffect != .none
                && a.endTime - input.currentTime < AnnotationEffectMath.effectDuration(a.exitEffect)
            return entering || exiting
        }
        // Animated frames re-key at 30fps, not per millisecond — a 60Hz+
        // display was re-rastering EVERY frame through tap spans and build
        // windows, which is exactly what playback lag with annotations was.
        let timeKey = needsClock ? Int((input.currentTime * 30).rounded()) : -1
        // Hasher, not a string: the signature is rebuilt every frame just to
        // COMPARE against the cache key, and interpolating a multi-hundred-
        // byte string per annotation per frame was pure allocation churn.
        var hasher = Hasher()
        for a in input.project.annotations {
            hasher.combine(a.id); hasher.combine(a.startTime); hasher.combine(a.endTime)
            hasher.combine(a.x); hasher.combine(a.y)
            hasher.combine(a.arrowEndX); hasher.combine(a.arrowEndY)
            hasher.combine(a.type.rawValue); hasher.combine(a.text)
            hasher.combine(a.fontSize); hasher.combine(a.fontWeight.rawValue)
            hasher.combine(a.fontName); hasher.combine(a.uppercase)
            hasher.combine(a.lineWidth); hasher.combine(a.cornerRadius)
            hasher.combine(a.opacity); hasher.combine(a.showBackground); hasher.combine(a.showShadow)
            hasher.combine(a.enterEffect.rawValue); hasher.combine(a.exitEffect.rawValue)
            hasher.combine(a.color.red); hasher.combine(a.color.green)
            hasher.combine(a.color.blue); hasher.combine(a.color.opacity)
            hasher.combine(a.backgroundColor.red); hasher.combine(a.backgroundColor.green)
            hasher.combine(a.backgroundColor.blue); hasher.combine(a.backgroundColor.opacity)
            // Stroke COUNT alone misses points appended to the live stroke
            // mid-draw — total point count makes the pen paint.
            hasher.combine(a.drawingStrokes.count)
            hasher.combine(a.drawingStrokes.reduce(0) { $0 + $1.count })
            hasher.combine(a.backdropOpacity)
        }
        let sig = hasher.finalize()
        // Motion rasters at 1x — live drags AND animated playback spans; half
        // the pixels per dimension is what keeps both at frame rate, and the
        // settled frame after (mouse-up, pause, build completing) re-rasters
        // crisp. `rasterScaleOverride` (the harness pin) always wins, so the
        // parity/golden gates keep scoring the full-resolution renderer.
        let liveMotion = interactionView?.isActivelyDragging == true
            || (input.isPlaying && needsClock)
        let rasterScale = rasterScaleOverride ?? (liveMotion ? 1 : effectiveScale)
        // The blackout backdrop hugs the card's rounded corners — same
        // device-frame / frame-shape rules as `cardClipPath`.
        let dimCornerRadius: CGFloat = {
            let s = input.project.settings
            if showsDeviceFrame(input) { return 0 }
            if s.frameShape == .rectangle { return 0 }
            return min(max(0, s.cornerRadius), min(videoRect.width, videoRect.height) / 2)
        }()
        // POSITION-INDEPENDENT raster: draw in a videoRect-anchored image
        // (with a margin for overhanging text/arrows) and move it with the
        // layer's frame. Keying the raster on the videoRect's ORIGIN meant a
        // placement drag re-rastered every annotation on every mouse move —
        // the "not buttery" placement drag.
        let margin = (max(120, max(videoRect.width, videoRect.height) * 0.35)).rounded()
        let rasterRect = videoRect.insetBy(dx: -margin, dy: -margin)
        let localVideoRect = CGRect(origin: CGPoint(x: margin, y: margin), size: videoRect.size)
        // While a label is open in the in-place editor the annotation is
        // omitted from the raster (Chrome.editingID) — the editor field IS it.
        let editingID = interactionView?.inlineEditingID
        let key = "\(sig)|\(timeKey)|\(videoRect.size)|\(margin)|\(input.isPlaying)"
            + "|\(input.selectedAnnotationID?.uuidString ?? "-")|\(rasterScale)|\(dimCornerRadius)"
            + "|\(editingID?.uuidString ?? "-")"

        if cachedAnnotations?.key != key {
            // Annotation sizes are authored in canvas points, so the preview's
            // unit scale is 1; the exporter passes its own (see
            // AnnotationRenderer).
            if let img = AnnotationRenderer.image(
                size: rasterRect.size,
                annotations: input.project.annotations,
                currentTime: input.currentTime,
                videoRect: localVideoRect,
                scale: 1,
                chrome: .init(isPlaying: input.isPlaying, selectedID: input.selectedAnnotationID,
                              editingID: editingID),
                rasterScale: rasterScale,
                videoCornerRadius: dimCornerRadius
            ) {
                cachedAnnotations = (key, img)
            }
        }
        if let img = cachedAnnotations?.image {
            annotationLayer.isHidden = false
            annotationLayer.contents = img
            annotationLayer.frame = rasterRect
        }
    }

    // MARK: - Cursor + ripple

    /// Curtain Unveil — the shared CurtainUnveilMath state rendered by the
    /// shared rasterizer, shown as NSImage layer contents (raw CGImage
    /// contents orient differently in harness vs real window). Deterministic
    /// from OUTPUT time, so scrubbing, playback and export agree.
    private func renderCurtain(_ input: FrameInput, videoRect: CGRect, visible: Bool) {
        let s = input.project.settings
        let state = CurtainUnveilMath.state(
            corner: s.curtainUnveilCorner,
            at: input.currentTime - input.project.effectiveTrimStart,
            startTime: s.curtainUnveilStart,
            duration: s.curtainUnveilDuration)
        guard visible, state.active, videoRect.width > 1, videoRect.height > 1 else {
            curtainLayer.isHidden = true
            curtainLayer.contents = nil
            return
        }
        curtainLayer.frame = videoRect
        if cachedCurtainLogoName != s.curtainLogoFileName {
            cachedCurtainLogoName = s.curtainLogoFileName
            cachedCurtainLogoImage = input.project.curtainLogoImageURL
                .flatMap { NSImage(contentsOf: $0) }
                .flatMap { $0.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        }
        // Confine the curtain to the card's silhouette — the SAME sources the
        // card clip masks use (device screen rect + radius, else frame shape
        // + corner radius), through the one shared CardClip mapping.
        let clip = CurtainUnveilMath.cardClip(
            frameShape: s.frameShape,
            cornerRadius: s.cornerRadius,
            cardSize: videoRect.size,
            deviceScreen: deviceFrameRect(input, videoRect: videoRect).map { fr in
                (rect: CGRect(x: fr.minX - videoRect.minX, y: fr.minY - videoRect.minY,
                              width: fr.width, height: fr.height),
                 cornerRadius: DeviceFrameLayout.screenCornerRadius(forVideoSize: fr.size))
            })
        let style = CurtainUnveilMath.coverStyle(
            settings: s, logo: cachedCurtainLogoImage, cardClip: clip)
        let scale = window?.backingScaleFactor ?? 2
        let pixels = CGSize(width: videoRect.width * scale, height: videoRect.height * scale)
        guard let cg = CurtainUnveilMath.renderImage(state: state, size: pixels, style: style) else {
            curtainLayer.isHidden = true
            curtainLayer.contents = nil
            return
        }
        curtainLayer.isHidden = false
        curtainLayer.contents = NSImage(cgImage: cg, size: videoRect.size)
    }

    private func renderCursorAndRipple(_ input: FrameInput, videoRect: CGRect, visible: Bool) {
        let s = input.project.settings
        rippleGroup.sublayers?.forEach { $0.removeFromSuperlayer() }
        cursorLayer.isHidden = true
        guard visible, s.showCursor, !input.cursorEvents.isEmpty, input.videoSize.width > 0 else { return }

        let events = effectiveCursorEvents(input)
        let coordinateSize = resolvedCursorCoordinateSize(input)
        guard coordinateSize.width > 0, coordinateSize.height > 0 else { return }

        // Auto-hide (verbatim port)
        if s.autoHideCursor, input.cursorEvents.count > 1 {
            let window = s.autoHideDelay
            let recent = events.filter { $0.timestamp >= input.currentTime - window && $0.timestamp <= input.currentTime }
            if recent.count > 1, let first = recent.first, let last = recent.last,
               hypot(last.x - first.x, last.y - first.y) < 5 {
                return
            }
        }

        let smoother = CursorSmoother(factor: s.smoothingFactor)
        guard let pos = smoother.interpolateIfFresh(events: events, at: input.currentTime) else { return }

        let asset = CursorStyleProvider.asset(for: s.cursorStyle)
        if let layout = CursorOverlayLayout.make(
            cursorPosition: pos,
            coordinateSize: coordinateSize,
            videoRect: videoRect,
            cursorSize: asset.image.size,
            hotSpot: asset.hotSpot,
            cursorScale: s.cursorScale
        ) {
            cursorLayer.isHidden = false
            // NSImage contents + frame, exactly like the pre-raster code that
            // shipped correct: AppKit orients NSImage contents for this flipped
            // hierarchy, and `imageRect` is derived from the hotspot every
            // frame, so the tip stays on the recorded point at any size. The
            // CGImage/anchorPoint rewrite passed the offscreen harness but
            // rendered mirrored and ignored resizes in the real window chain.
            cursorLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            cursorLayer.contents = asset.image
            let hotspotInLayer = CGPoint(
                x: layout.hotspotPoint.x - layout.imageRect.minX,
                y: layout.hotspotPoint.y - layout.imageRect.minY
            )
            // Motion physics: identical pose math to the exporter
            // (CursorPhysicsMath). The transform's fixed point is the tip, so
            // the recorded click point NEVER moves — only the body leans,
            // squashes, and trails around it.
            let pose = CursorPhysicsMath.pose(
                events: events,
                at: input.currentTime,
                coordinateSize: coordinateSize,
                videoRect: videoRect,
                spriteHeight: layout.imageRect.height,
                tilt: s.cursorTilt,
                stretch: s.cursorStretch,
                drag: s.cursorDrag,
                weight: s.cursorWeight
            )
            if pose.isIdentity {
                cursorLayer.setAffineTransform(.identity)
                cursorLayer.frame = layout.imageRect
            } else {
                // `frame` is undefined under a non-identity transform — set
                // the equivalent bounds+position, then pin the tip. The layer
                // transform operates in ANCHOR-relative (centre) coordinates,
                // so the pinned point is the tip's offset from the centre.
                cursorLayer.setAffineTransform(.identity)
                cursorLayer.bounds = CGRect(origin: .zero, size: layout.imageRect.size)
                cursorLayer.position = CGPoint(x: layout.imageRect.midX, y: layout.imageRect.midY)
                let tipFromCenter = CGPoint(
                    x: hotspotInLayer.x - layout.imageRect.width / 2,
                    y: hotspotInLayer.y - layout.imageRect.height / 2
                )
                cursorLayer.setAffineTransform(CursorPhysicsMath.affineTransform(
                    pose: pose,
                    tip: tipFromCenter,
                    spriteHeight: layout.imageRect.height
                ))
            }
            lastCursorHotspotInLayer = hotspotInLayer
        }

        // Click ripple ABOVE the cursor (export layer order) — port of
        // ClickRippleOverlay's rings.
        guard s.showClickRipple else { return }
        let color = s.clickRippleColor.nsColor
        let size = CGFloat(s.clickRippleSize)
        // Sustained glow while the button is held-and-dragging (text
        // highlights): the same treatment a click gets, minus the ripple —
        // otherwise highlighting reads as nothing happening.
        let dragRuns = ClickRippleOverlay.dragHighlightRuns(from: events, coordinateSize: coordinateSize)
        let dragStrength = ClickRippleOverlay.dragHighlightStrength(runs: dragRuns, at: input.currentTime)
        if dragStrength > 0.01,
           let dragLayout = CursorOverlayLayout.make(
               cursorPosition: pos,
               coordinateSize: coordinateSize,
               videoRect: videoRect,
               cursorSize: asset.image.size,
               hotSpot: asset.hotSpot,
               cursorScale: s.cursorScale
           ) {
            let center = dragLayout.hotspotPoint
            let d = size * 0.55
            let glow = CAGradientLayer()
            glow.type = .radial
            glow.frame = CGRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d)
            glow.colors = [
                color.withAlphaComponent(0.30 * dragStrength).cgColor,
                color.withAlphaComponent(0).cgColor,
            ]
            glow.startPoint = CGPoint(x: 0.5, y: 0.5)
            glow.endPoint = CGPoint(x: 1, y: 1)
            rippleGroup.addSublayer(glow)
            let ringLayer = CAShapeLayer()
            let ringD = d * 0.6
            ringLayer.path = CGPath(
                ellipseIn: CGRect(x: center.x - ringD / 2, y: center.y - ringD / 2, width: ringD, height: ringD),
                transform: nil
            )
            ringLayer.fillColor = nil
            ringLayer.strokeColor = color.withAlphaComponent(0.55 * dragStrength).cgColor
            ringLayer.lineWidth = 2
            rippleGroup.addSublayer(ringLayer)
        }

        for ripple in ClickRippleOverlay.activeRipples(
            cursorEvents: events,
            currentTime: input.currentTime,
            coordinateSize: coordinateSize,
            videoRect: videoRect
        ) {
            let p = ripple.progress
            let center = ripple.position

            func ring(diameter: CGFloat, width: CGFloat, alpha: CGFloat) {
                guard alpha > 0 else { return }
                let l = CAShapeLayer()
                let r = diameter / 2
                l.path = CGPath(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: diameter, height: diameter), transform: nil)
                l.fillColor = nil
                l.strokeColor = color.withAlphaComponent(alpha).cgColor
                l.lineWidth = width
                rippleGroup.addSublayer(l)
            }

            let outerScale = 0.2 + p * 0.8
            let outerOpacity = 1.0 - p
            ring(diameter: size * outerScale, width: 2, alpha: outerOpacity * 0.7)

            let innerProgress = max(0, p - 0.1) / 0.9
            let innerScale = 0.15 + innerProgress * 0.5
            let innerOpacity = max(0, 1.0 - innerProgress * 1.5)
            ring(diameter: size * 0.6 * innerScale, width: 1.5, alpha: innerOpacity * 0.5)

            let dotOpacity = max(0, 1.0 - p * 3)
            if dotOpacity > 0 {
                let dot = CAShapeLayer()
                dot.path = CGPath(ellipseIn: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6), transform: nil)
                dot.fillColor = color.withAlphaComponent(dotOpacity * 0.6).cgColor
                rippleGroup.addSublayer(dot)
            }

            // Soft glow fill
            let glow = CAGradientLayer()
            glow.type = .radial
            let gd = size * outerScale
            glow.frame = CGRect(x: center.x - gd / 2, y: center.y - gd / 2, width: gd, height: gd)
            glow.colors = [
                color.withAlphaComponent(outerOpacity * 0.12).cgColor,
                color.withAlphaComponent(0).cgColor,
            ]
            glow.startPoint = CGPoint(x: 0.5, y: 0.5)
            glow.endPoint = CGPoint(x: 1, y: 1)
            glow.cornerRadius = gd / 2
            glow.masksToBounds = true
            rippleGroup.addSublayer(glow)
        }
    }

    // MARK: - Subtitle (exporter-identical geometry, NSAttributedString raster)

    private func renderSubtitle(_ input: FrameInput, canvas: CGSize, visible: Bool) {
        let s = input.project.settings
        subtitleLayer.isHidden = true
        lastSubtitleRect = nil
        guard visible, s.showSubtitles,
              let sub = input.project.subtitles.first(where: {
                  input.currentTime >= $0.startTime && input.currentTime <= $0.endTime
              }) else { return }

        // Scale belongs in the key: the bitmap is rasterised at it, so moving
        // the window to a display with a different backing scale must not reuse
        // the old pixels.
        let key = subtitleKey(sub, s: s, currentTime: input.currentTime) + "|\(effectiveScale)"
        let bitmap: (key: String, image: NSImage, pillSize: CGSize)
        if let cached = cachedSubtitleBitmap, cached.key == key {
            bitmap = cached
        } else if let built = SubtitlePillRasterizer.render(subtitle: sub, settings: s, currentTime: input.currentTime, maxWidth: canvas.width - 2 * (20 + 12), scale: effectiveScale) {
            bitmap = (key, built.image, built.pillSize)
            cachedSubtitleBitmap = bitmap
        } else {
            return
        }

        // Free placement — identical origin interpolation to PreviewView /
        // exporter (Y-down here).
        let f: CGPoint
        if let x = s.subtitleCustomX, let y = s.subtitleCustomY {
            f = CGPoint(x: min(1, max(0, x)), y: min(1, max(0, y)))
        } else {
            switch s.subtitlePosition {
            case .top: f = CGPoint(x: 0.5, y: 0)
            case .center: f = CGPoint(x: 0.5, y: 0.5)
            case .bottom: f = CGPoint(x: 0.5, y: 1)
            }
        }
        let pill = bitmap.pillSize
        let usableW = max(0, canvas.width - 40 - pill.width)
        let usableH = max(0, canvas.height - 40 - pill.height)
        lastSubtitleRect = CGRect(
            x: 20 + f.x * usableW, y: 20 + f.y * usableH,
            width: pill.width, height: pill.height
        )
        subtitleLayer.isHidden = false
        subtitleLayer.contents = bitmap.image
        // The raster includes shadow slack around the pill — center the
        // oversized bitmap on the pill's rect.
        let slackX = (bitmap.image.size.width - pill.width) / 2
        let slackY = (bitmap.image.size.height - pill.height) / 2
        subtitleLayer.frame = CGRect(
            x: 20 + f.x * usableW - slackX,
            y: 20 + f.y * usableH - slackY,
            width: bitmap.image.size.width,
            height: bitmap.image.size.height
        )
    }

    private func subtitleKey(_ sub: SubtitleSegment, s: ProjectSettings, currentTime: TimeInterval) -> String {
        // Karaoke highlighting changes per word boundary — include the count
        // of active words so the raster refreshes exactly when needed.
        let activeWords = s.highlightWords ? sub.words.filter { currentTime >= $0.startTime }.count : -1
        return "\(sub.id):\(sub.text):\(activeWords):\(s.subtitleFontSize):\(s.subtitleWeight.rawValue):\(s.subtitleFontName ?? "sys"):\(s.subtitleUppercase):\(s.subtitleStyle.rawValue):\(s.subtitleColor.cacheKey):\(s.subtitleBackgroundColor.cacheKey):\(s.subtitleHighlightColor.cacheKey)"
    }

    // MARK: - Keystroke overlay

    /// Shortcut pill — all timing/placement comes from KeystrokeOverlayMath
    /// and the pixels from KeystrokeOverlayRenderer.drawPill, both shared
    /// verbatim with VideoExporter (preview == export).
    private func renderKeystrokes(_ input: FrameInput, canvas: CGSize, visible: Bool) {
        let s = input.project.settings
        keystrokeLayer.isHidden = true
        guard visible, s.showKeystrokes, !input.keystrokeEvents.isEmpty else { return }

        let display: [KeystrokeOverlayMath.DisplayEvent]
        let scoped = s.keystrokeOverlayScopeToRecordedApp
        if let cached = cachedKeystrokeDisplay,
           cached.count == input.keystrokeEvents.count, cached.scoped == scoped {
            display = cached.events
        } else {
            // Scope filter + collapse via the ONE shared derivation —
            // VideoExporter calls the identical function (preview == export).
            display = KeystrokeOverlayMath.displayEvents(
                from: input.keystrokeEvents, scopedTo: input.project
            )
            cachedKeystrokeDisplay = (input.keystrokeEvents.count, scoped, display)
        }
        guard let pill = KeystrokeOverlayMath.activePill(
            displayEvents: display, currentTime: input.currentTime
        ) else { return }

        let key = "\(pill.text)|\(s.keystrokeOverlaySize)|\(effectiveScale)"
        let bitmap: (key: String, image: NSImage, pillSize: CGSize)
        if let cached = cachedKeystrokeBitmap, cached.key == key {
            bitmap = cached
        } else if let built = KeystrokeOverlayRenderer.pillImage(
            text: pill.text, size: s.keystrokeOverlaySize, scale: 1, rasterScale: effectiveScale
        ) {
            // NSImage contents, not raw CGImage — raw CGImage layer contents
            // orient differently in the harness vs a real window.
            let image = NSImage(cgImage: built.image, size: built.size)
            bitmap = (key, image, built.size)
            cachedKeystrokeBitmap = bitmap
        } else {
            return
        }

        keystrokeLayer.isHidden = false
        keystrokeLayer.contents = bitmap.image
        keystrokeLayer.opacity = Float(pill.alpha)
        // Same pixel-snapped rect the exporter draws into — see pillRect.
        // bounds+position, not frame: the pop entry sets a scale transform,
        // and frame is undefined under a non-identity transform.
        let rect = KeystrokeOverlayMath.pillRect(
            position: s.keystrokeOverlayPosition, canvasSize: canvas,
            pillSize: bitmap.pillSize, entry: pill.entry, scale: 1,
            animation: s.keystrokeOverlayAnimation
        )
        // Centre anchor is REQUIRED here: the setup pass leaves layers at
        // anchorPoint .zero, where `position` is the bottom-left corner and a
        // scale transform grows from the corner — the pill would sit half its
        // size off the exporter's rect and pop asymmetrically.
        keystrokeLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        keystrokeLayer.bounds = CGRect(origin: .zero, size: rect.size)
        keystrokeLayer.position = CGPoint(x: rect.midX, y: rect.midY)
        let pop = KeystrokeOverlayMath.popScale(
            animation: s.keystrokeOverlayAnimation, entry: pill.entry
        )
        keystrokeLayer.transform = CATransform3DMakeScale(pop, pop, 1)
    }

    // MARK: - Camera

    /// Interpolated camera layout for the frame being rendered. Resolved in
    /// `render()` BEFORE the card transform is applied, because the
    /// side-by-side squeeze moves the card, not the camera.
    private var lastCameraLayout = CameraLayoutMath.Resolved(
        cameraRect: nil, cameraCornerRadius: 0, cameraOpacity: 0, chromeOpacity: 0,
        cardScale: 1, cardTranslationX: 0, isPlainBubble: true)

    /// Resolves the layout for this frame. Must run before `applyDip`.
    /// `cardRectInCanvas` is the padded card rect in CANVAS space — resolving
    /// against the raw canvas ignored frame padding, so a full-screen camera
    /// bled past the card while the exporter (which uses the padded layout)
    /// disagreed.
    private var lastContentOrigin = CGPoint.zero

    func resolveCameraLayout(_ input: FrameInput, canvas: CGSize, cardRectInCanvas: CGRect) {
        let s = input.project.settings
        let hasCamera = s.showCamera
            && (input.cameraPlayer != nil || input.cameraPosterImage != nil)
        guard hasCamera, !input.project.cameraLayoutRegions.isEmpty else {
            lastCameraLayout = CameraLayoutMath.Resolved(
                cameraRect: nil, cameraCornerRadius: 0,
                cameraOpacity: hasCamera ? 1 : 0, chromeOpacity: 1,
                cardScale: 1, cardTranslationX: 0, isPlainBubble: hasCamera)
            return
        }
        let fit = ReactiveCameraLayout.canvasFitScale(for: canvas)
        let scaledBase = s.effectiveCameraSize * fit
        let custom: CGPoint? = {
            guard let x = s.cameraCustomX, let y = s.cameraCustomY else { return nil }
            return CGPoint(x: x, y: y)
        }()
        let bubbleRect = ReactiveCameraLayout.cameraRect(
            in: CGRect(origin: .zero, size: canvas),
            basePosition: s.cameraPosition,
            customPosition: custom,
            baseSize: scaledBase,
            zoom: motion.zoom,
            padding: 12 * fit,
            aspect: ReactiveCameraLayout.shapeAspect(
                shape: s.cameraShape, videoAspect: Double(input.cameraVideoAspect),
                orientation: s.cameraOrientation),
            yAxisIsUp: false
        )
        lastCameraLayout = CameraLayoutMath.resolve(
            at: input.currentTime,
            regions: input.project.cameraLayoutRegions,
            videoRect: cardRectInCanvas,
            bubbleRect: bubbleRect,
            bubbleCornerRadius: CameraLayoutMath.bubbleApproxCornerRadius(
                shape: s.cameraShape,
                customRadius: CGFloat(s.cameraCornerRadius),
                size: bubbleRect.size),
            cardCornerRadius: CGFloat(max(0, s.cornerRadius)),
            hasCamera: true
        )
    }

    private func renderCamera(_ input: FrameInput, canvas: CGSize, visible: Bool) {
        let s = input.project.settings
        let camLayout = lastCameraLayout
        let show = visible && s.showCamera
            && (input.cameraPlayer != nil || input.cameraPosterImage != nil)
            && camLayout.cameraOpacity > 0.001

        cameraGroup.isHidden = !show
        lastCameraRect = nil
        guard show else { return }

        if !camLayout.isPlainBubble, let overrideRect = camLayout.cameraRect {
            // The camera IS the card here: card corner treatment, no bubble
            // chrome (ring/stroke/tag/shadow — the card's own shadow is
            // already beneath), no bubble tilt, no zoom-reactive shrink.
            // Morphing / override geometry. Radius animates with the rect —
            // the exporter generates the identical rounded rect on the GPU.
            // Bubble chrome (ring, border, tag, drop shadow, bubble tilt)
            // fades out with `chromeOpacity`: at card scale it is all wrong,
            // because the card carries its own shadow and corners.
            lastCameraRect = overrideRect
            // Effects apply to whatever occupies the card: parenting into
            // contentGroup makes the tile ride the card's zoom and tilt
            // (zoomGroup/contentGroup transforms) — the exporter composites
            // its tile before the same transform stage. cardGroup is NOT the
            // parent: the side-by-side squeeze must move only the screen.
            if cameraGroup.superlayer !== contentGroup {
                contentGroup.addSublayer(cameraGroup)
            }
            cameraGroup.bounds = CGRect(origin: .zero, size: overrideRect.size)
            cameraGroup.position = CGPoint(
                x: overrideRect.origin.x - lastContentOrigin.x,
                y: overrideRect.origin.y - lastContentOrigin.y
            )
            cameraGroup.transform = CATransform3DIdentity
            cameraGroup.opacity = Float(min(1, max(0, s.cameraOpacity * camLayout.cameraOpacity)))

            let local = CGRect(origin: .zero, size: overrideRect.size)
            let radius = min(
                camLayout.cameraCornerRadius,
                min(local.width, local.height) / 2
            )
            let path = CGPath(
                roundedRect: local, cornerWidth: radius, cornerHeight: radius, transform: nil)
            cameraClip.frame = local
            let mask = CAShapeLayer()
            mask.path = path
            cameraClip.mask = mask
            cameraClip.backgroundColor = NSColor.black.withAlphaComponent(0.2).cgColor

            let chrome = Float(min(1, max(0, camLayout.chromeOpacity)))
            let cardness = 1 - CGFloat(chrome)
            cameraShadow.frame = local
            cameraShadow.shadowPath = path
            cameraShadow.shadowRadius = 6
            cameraShadow.shadowOffset = .zero
            cameraShadow.opacity = 1
            cameraShadow.shadowOpacity = 0.33 * chrome
            // The frame's own shadow treatment, fading in as the camera
            // becomes card-like — same values renderCard uses.
            cameraCardShadow.frame = local
            cameraCardShadow.shadowPath = path
            cameraCardShadow.shadowRadius = s.shadowRadius
            cameraCardShadow.shadowOffset = CGSize(width: 0, height: s.shadowRadius / 3)
            cameraCardShadow.shadowOpacity = Float(0.45 * s.shadowOpacity * cardness)
            cameraStroke.frame = local
            cameraStroke.path = path
            cameraStroke.strokeColor = CameraStyleMath.borderNSColor(s).cgColor
            cameraStroke.lineWidth = CGFloat(max(0, s.cameraBorderWidth))
            cameraStroke.isHidden = s.cameraBorderWidth <= 0 || chrome < 0.01
            cameraStroke.opacity = chrome
            cameraRing.isHidden = true
            cameraRing.contents = nil
            cameraTag.isHidden = true
            cameraTag.contents = nil

            // Same video/poster tail as the bubble path below, at the
            // override rect. Aspect-fill comes from the driver's gravity.
            cameraVideo.frame = local
            if s.cameraMirrored {
                cameraVideo.transform = CATransform3DConcat(
                    CATransform3DMakeScale(-1, 1, 1),
                    CATransform3DMakeTranslation(overrideRect.width, 0, 0)
                )
            } else {
                cameraVideo.transform = CATransform3DIdentity
            }
            let adjustments = CameraStyleMath.Adjustments(settings: s)
            if let player = input.cameraPlayer {
                if cameraDriver?.player !== player {
                    cameraDriver = VideoFrameLayerDriver(
                        player: player, layer: cameraVideo, gravity: .resizeAspectFill)
                }
                cameraDriver?.cameraAdjustments = adjustments
                cameraPoster.isHidden = cameraDriver?.hasFrame == true
            } else {
                cameraPoster.isHidden = input.cameraPosterImage == nil
            }
            cameraPoster.frame = local
            cameraPoster.contents = adjustedPosterImage(input.cameraPosterImage, adjustments: adjustments)
            return
        }

        let custom: CGPoint? = {
            guard let x = s.cameraCustomX, let y = s.cameraCustomY else { return nil }
            return CGPoint(x: x, y: y)
        }()
        // Canvas-fit scaling matches PreviewView/exporter — the bubble keeps
        // its relative footprint when the window resizes.
        let fit = ReactiveCameraLayout.canvasFitScale(for: canvas)
        let scaledBase = s.effectiveCameraSize * fit
        let rect = ReactiveCameraLayout.cameraRect(
            in: CGRect(origin: .zero, size: canvas),
            basePosition: s.cameraPosition,
            customPosition: custom,
            baseSize: scaledBase,
            zoom: motion.zoom,
            padding: 12 * fit,
            aspect: ReactiveCameraLayout.shapeAspect(
                shape: s.cameraShape, videoAspect: Double(input.cameraVideoAspect),
                orientation: s.cameraOrientation),
            yAxisIsUp: false
        )
        let sizeFactor = scaledBase > 0 ? max(rect.width, rect.height) / scaledBase : 1

        lastCameraRect = rect
        // bounds + position, never .frame: the group can carry a perspective
        // transform (camera tilt), and frame is derived THROUGH the transform
        // (see the contentGroup note above).
        cameraGroup.bounds = CGRect(origin: .zero, size: rect.size)
        cameraGroup.position = rect.origin   // anchorPoint is .zero
        // 3D bubble tilt — the SAME TiltMath homography the screen tilt uses,
        // anchored at the bubble centre; the exporter warps the composited
        // camera stack through TiltMath.projectedPoint with identical inputs.
        if abs(s.cameraTiltPitch) > 0.01 || abs(s.cameraTiltYaw) > 0.01 {
            cameraGroup.transform = CATransform3D(TiltMath.projectionTransform(
                pitchDegrees: s.cameraTiltPitch,
                yawDegrees: s.cameraTiltYaw,
                rollDegrees: 0,
                center: CGPoint(x: rect.width / 2, y: rect.height / 2),
                distance: TiltMath.perspectiveDistance(for: rect.size)
            ))
        } else {
            cameraGroup.transform = CATransform3DIdentity
        }
        let local = CGRect(origin: .zero, size: rect.size)
        let path = cameraClipPath(s, size: rect.size)

        cameraClip.frame = local
        let mask = CAShapeLayer()
        mask.path = path
        cameraClip.mask = mask
        cameraClip.backgroundColor = NSColor.black.withAlphaComponent(0.2).cgColor

        cameraShadow.frame = local
        cameraShadow.shadowPath = path
        cameraShadow.shadowRadius = 6 * sizeFactor
        cameraShadow.shadowOffset = .zero
        // Shared layers — the override path re-targets these, so restore them.
        if cameraGroup.superlayer === contentGroup, let root = subtitleLayer.superlayer {
            root.insertSublayer(cameraGroup, above: subtitleLayer)
        }
        cameraShadow.opacity = 1
        cameraShadow.shadowOpacity = 0.33
        cameraCardShadow.shadowOpacity = 0
        cameraStroke.opacity = 1

        // Whole-bubble opacity (group opacity fades the composited stack —
        // matching the exporter's fade of the composed camera overlay).
        cameraGroup.opacity = Float(min(1, max(0, s.cameraOpacity)))

        cameraStroke.frame = local
        cameraStroke.path = path
        cameraStroke.strokeColor = CameraStyleMath.borderNSColor(s).cgColor
        cameraStroke.lineWidth = CGFloat(max(0, s.cameraBorderWidth)) * sizeFactor
        cameraStroke.isHidden = s.cameraBorderWidth <= 0

        // Ring light — baked at the BASE bubble size and stretched by the zoom
        // envelope, exactly like the exporter's affine-scaled static asset.
        let baseBubble = ReactiveCameraLayout.bubbleSize(
            baseSize: scaledBase,
            aspect: ReactiveCameraLayout.shapeAspect(
                shape: s.cameraShape, videoAspect: Double(input.cameraVideoAspect),
                orientation: s.cameraOrientation)
        )
        // The glow lives OUTSIDE the bubble: the raster is padded by
        // ringPadding on every side, so the layer frame is the (scaled)
        // outset of the bubble rect.
        let ringPad = CameraStyleMath.ringPadding(for: baseBubble) * sizeFactor
        cameraRing.frame = local.insetBy(dx: -ringPad, dy: -ringPad)
        if s.cameraRingLight > 0 {
            let ringKey = "\(s.cameraShape.rawValue):\(s.cameraCornerRadius):\(s.cameraRingLight):\(Int(baseBubble.width))x\(Int(baseBubble.height)):\(effectiveScale)"
            if cachedCameraRing?.key != ringKey {
                if let cg = CameraStyleMath.ringImage(
                    size: baseBubble, shape: s.cameraShape,
                    customRadius: s.cameraCornerRadius,
                    intensity: s.cameraRingLight, scale: effectiveScale
                ) {
                    cachedCameraRing = (ringKey, NSImage(cgImage: cg, size: baseBubble))
                } else {
                    cachedCameraRing = nil
                }
            }
            cameraRing.contents = cachedCameraRing?.image
            cameraRing.isHidden = cachedCameraRing == nil
        } else {
            cameraRing.isHidden = true
            cameraRing.contents = nil
        }

        // Name tag — CameraStyleMath owns pill measurement and placement; the
        // bitmap is baked at the base bubble width and the frame is scaled by
        // the zoom envelope (sizeFactor), so the tag rides every movement.
        if let layout = CameraStyleMath.tagLayout(settings: s, bubbleWidth: baseBubble.width) {
            let tagKey = "\(s.cameraTagText)|\(s.cameraTagSubtext)|\(s.cameraTagFontName ?? "sys")|\(s.cameraTagTextColor.cacheKey)|\(s.cameraTagBackgroundColor.cacheKey)|\(Int(baseBubble.width))|\(effectiveScale)"
            if cachedCameraTag?.key != tagKey {
                if let built = CameraStyleMath.tagBitmap(
                    settings: s, bubbleWidth: baseBubble.width, scale: effectiveScale
                ) {
                    cachedCameraTag = (tagKey, NSImage(cgImage: built.image, size: built.pillSize), built.pillSize)
                } else {
                    cachedCameraTag = nil
                }
            }
            if let tag = cachedCameraTag {
                let baseLocal = CGRect(origin: .zero, size: baseBubble)
                let baseTagRect = CameraStyleMath.tagRect(
                    bubbleRect: baseLocal, pillSize: layout.pillSize,
                    position: s.cameraTagPosition, yAxisIsUp: false
                )
                cameraTag.isHidden = false
                cameraTag.contents = tag.image
                cameraTag.frame = CGRect(
                    x: baseTagRect.minX * sizeFactor,
                    y: baseTagRect.minY * sizeFactor,
                    width: baseTagRect.width * sizeFactor,
                    height: baseTagRect.height * sizeFactor
                )
            } else {
                cameraTag.isHidden = true
            }
        } else {
            cameraTag.isHidden = true
            cameraTag.contents = nil
        }

        // Mirrored video fills the clip (aspect-fill semantics come from the
        // driver's gravity).
        cameraVideo.frame = local
        if s.cameraMirrored {
            cameraVideo.transform = CATransform3DConcat(
                CATransform3DMakeScale(-1, 1, 1),
                CATransform3DMakeTranslation(rect.width, 0, 0)
            )
        } else {
            cameraVideo.transform = CATransform3DIdentity
        }

        // Color adjustments — the driver runs live frames through the SAME
        // CameraStyleMath pipeline the exporter uses; the poster is processed
        // through it here (cached). Identity short-circuits both.
        let adjustments = CameraStyleMath.Adjustments(settings: s)
        if let player = input.cameraPlayer {
            if cameraDriver?.player !== player {
                cameraDriver = VideoFrameLayerDriver(player: player, layer: cameraVideo, gravity: .resizeAspectFill)
            }
            cameraDriver?.cameraAdjustments = adjustments
            cameraPoster.isHidden = cameraDriver?.hasFrame == true
        } else {
            cameraPoster.isHidden = input.cameraPosterImage == nil
        }
        cameraPoster.frame = local
        cameraPoster.contents = adjustedPosterImage(input.cameraPosterImage, adjustments: adjustments)
    }

    /// Poster through the shared CameraStyleMath pipeline (identity = the
    /// original object, untouched — byte-stable for the parity goldens).
    private func adjustedPosterImage(_ poster: NSImage?, adjustments: CameraStyleMath.Adjustments) -> NSImage? {
        guard let poster else { return nil }
        guard !adjustments.isIdentity else { return poster }
        let key = "\(ObjectIdentifier(poster).hashValue):\(adjustments.brightness):\(adjustments.contrast):\(adjustments.saturation):\(adjustments.hue):\(adjustments.filter.rawValue)"
        if let cached = cachedAdjustedPoster, cached.key == key { return cached.image }
        guard let cg = poster.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return poster }
        let adjusted = CameraStyleMath.adjustedImage(CIImage(cgImage: cg), adjustments: adjustments)
        guard let out = VideoFrameLayerDriver.sharedCIContext.createCGImage(adjusted, from: adjusted.extent) else {
            return poster
        }
        let image = NSImage(cgImage: out, size: poster.size)
        cachedAdjustedPoster = (key, image)
        return image
    }

    /// Bubble shadow radius scales with the bubble's own size factor; during
    /// a morph the rect is growing, so scale by how bubble-like it still is.
    private func chromeScaleFactor(_ layout: CameraLayoutMath.Resolved) -> CGFloat {
        CGFloat(max(0.2, layout.chromeOpacity))
    }

    private func cameraClipPath(_ s: ProjectSettings, size: CGSize) -> CGPath {
        // Shared shape source of truth — the exporter builds the same path
        // (scaled to output pixels) from CameraStyleMath.
        CameraStyleMath.clipPath(
            shape: s.cameraShape,
            customRadius: s.cameraCornerRadius,
            rect: CGRect(origin: .zero, size: size),
            scale: 1
        )
    }

    /// Parity-harness hooks — camera styling wiring.
    func debugCameraRect() -> CGRect? { lastCameraRect }
    func debugCameraStroke() -> CAShapeLayer { cameraStroke }
    func debugCameraRingLayer() -> CALayer { cameraRing }
    func debugCameraTagLayer() -> CALayer { cameraTag }
    func debugCameraGroupOpacity() -> Float { cameraGroup.opacity }
    func debugCameraGroupTransform() -> CATransform3D { cameraGroup.transform }

    // MARK: - Watermark

    private func renderWatermark(_ input: FrameInput, canvas: CGSize) {
        let s = input.project.settings
        watermarkLayer.isHidden = true
        lastWatermarkRect = nil
        guard s.showWatermark else { return }
        if cachedWatermarkName != s.watermarkFileName {
            cachedWatermarkName = s.watermarkFileName
            cachedWatermark = input.project.watermarkImageURL.flatMap { NSImage(contentsOf: $0) }
        }
        guard let logo = cachedWatermark else { return }

        let aspect = logo.size.height > 0 ? logo.size.width / logo.size.height : 1
        let w = min(CGFloat(s.watermarkSize), max(1, canvas.width - 40))
        let h = w / max(0.01, aspect)
        let usableW = max(0, canvas.width - 40 - w)
        let usableH = max(0, canvas.height - 40 - h)
        let fx = CGFloat(min(1, max(0, s.watermarkX)))
        let fy = CGFloat(min(1, max(0, s.watermarkY)))
        watermarkLayer.isHidden = false
        watermarkLayer.contents = logo
        watermarkLayer.opacity = Float(s.watermarkOpacity)
        watermarkLayer.frame = CGRect(x: 20 + fx * usableW, y: 20 + fy * usableH, width: w, height: h)
        lastWatermarkRect = watermarkLayer.frame
    }

    // MARK: - Ported geometry (formula-identical to PreviewView)

    private func clampedBackgroundPadding(_ s: ProjectSettings, canvas: CGSize) -> CGFloat {
        let requested = max(0, s.backgroundPadding)
        guard canvas.width > 0, canvas.height > 0 else { return requested }
        return min(requested, min(canvas.width, canvas.height) * 0.35)
    }

    private struct Insets { var top: CGFloat; var leading: CGFloat; var bottom: CGFloat; var trailing: CGFloat }

    private func placementPaddingInsets(_ s: ProjectSettings, pad: CGFloat) -> Insets {
        let f = alignmentFractions(for: s)
        return Insets(
            top: pad * (0.5 + f.y),
            leading: pad * (0.5 + f.x),
            bottom: pad * (1.5 - f.y),
            trailing: pad * (1.5 - f.x)
        )
    }

    private func alignmentFractions(for settings: ProjectSettings) -> (x: CGFloat, y: CGFloat) {
        // Shared with the exporter via PlacementMath — includes the freeform
        // (drag-anywhere) override.
        PlacementMath.alignment(for: settings)
    }

    private func menuBarCropFraction(_ input: FrameInput) -> CGFloat {
        let s = input.project.settings
        guard s.menuBarReplacement == .hidden,
              input.project.recordingSourceKind != .device,
              !input.project.sourceSegments.contains(where: { $0.kind == .device }) else { return 0 }
        return min(0.12, max(0, s.menuBarHeight / 100))
    }

    private func effectiveVideoSize(_ input: FrameInput) -> CGSize {
        CGSize(width: input.videoSize.width,
               height: input.videoSize.height * (1 - menuBarCropFraction(input)))
    }

    private func resolvedCursorCoordinateSize(_ input: FrameInput) -> CGSize {
        let full = CursorOverlayLayout.resolveCoordinateSize(
            recordedSize: input.cursorCoordinateSize,
            fallbackSourceSize: input.videoSize
        )
        return CGSize(width: full.width, height: full.height * (1 - menuBarCropFraction(input)))
    }

    private func effectiveCursorEvents(_ input: FrameInput) -> [CursorEvent] {
        let crop = menuBarCropFraction(input)
        guard crop > 0 else { return input.cursorEvents }
        let full = CursorOverlayLayout.resolveCoordinateSize(
            recordedSize: input.cursorCoordinateSize,
            fallbackSourceSize: input.videoSize
        )
        let shift = full.height * crop
        return input.cursorEvents.map {
            CursorEvent(timestamp: $0.timestamp, x: $0.x, y: $0.y - shift, isClick: $0.isClick)
        }
    }

    /// Aspect-fit of the (crop-adjusted) source into the content area —
    /// full port of PreviewView.previewVideoRect including the device-frame
    /// bezel reservation.
    private func previewVideoRect(_ input: FrameInput, in containerSize: CGSize) -> CGRect {
        let videoSize = effectiveVideoSize(input)
        guard videoSize.width > 0, videoSize.height > 0,
              containerSize.width > 0, containerSize.height > 0 else {
            return CGRect(origin: .zero, size: containerSize)
        }
        var scale = min(containerSize.width / videoSize.width, containerSize.height / videoSize.height)

        // With the device frame on, the bezel extends beyond the video on all
        // sides — reserve room for it so the phone is never clipped.
        let deviceFramed = showsDeviceFrame(input)
        if deviceFramed {
            for _ in 0..<3 { // bezel width depends on final width; converges fast
                let bezel = DeviceFrameLayout.bezelWidth(forVideoWidth: videoSize.width * scale)
                scale = min(
                    (containerSize.width - 2 * bezel) / videoSize.width,
                    (containerSize.height - 2 * bezel) / videoSize.height
                )
            }
            scale = max(0.01, scale)
        }

        let width = videoSize.width * scale
        let height = videoSize.height * scale
        let alignment = alignmentFractions(for: input.project.settings)
        let inset = deviceFramed
            ? DeviceFrameLayout.bezelWidth(forVideoWidth: width)
            : 0
        let originX = inset + (containerSize.width - width - 2 * inset) * alignment.x
        let originY = inset + (containerSize.height - height - 2 * inset) * alignment.y
        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    private func isWithinTrimRange(_ input: FrameInput) -> Bool {
        input.currentTime >= input.project.effectiveTrimStart - (1.0 / 120.0)
            && input.currentTime <= input.project.effectiveTrimEnd + (1.0 / 120.0)
    }

    /// Zoom anchor in CANVAS space — port of PreviewView.canvasAnchor (which
    /// projects the focal through the tilt homography).
    /// Motion blur on the zoom group — the CALayer twin of the exporter's
    /// CIMotionBlur over the composited card. Same MotionBlurMath, same
    /// CIMotionBlur kernel; radius converted to pixels with the canvas width
    /// (the exporter uses its output width, so fractions agree by design).
    private func renderMotionBlur(_ input: FrameInput, s: ProjectSettings, canvas: CGSize) {
        let sample = MotionBlurMath.CameraSample(
            zoom: motion.zoom, focalX: motion.focalX, focalY: motion.focalY,
            offsetX: motion.cardOffsetX, offsetY: motion.cardOffsetY)
        var blur = MotionBlurMath.Blur.none
        if s.motionBlur {
            if let last = lastBlurSample, input.currentTime > last.time {
                blur = MotionBlurMath.blur(
                    previous: last.sample, current: sample,
                    dt: input.currentTime - last.time,
                    strength: s.motionBlurStrength)
            } else if let last = lastBlurSample, input.currentTime == last.time {
                // Same-time re-render (selection/hover) — keep the current
                // filter untouched; no new velocity information exists.
                return
            }
        }
        if lastBlurSample?.time != input.currentTime {
            lastBlurSample = (sample, input.currentTime)
        }
        guard blur.active else {
            if motionBlurFilterInstalled {
                zoomGroup.filters = nil
                motionBlurFilterInstalled = false
            }
            return
        }
        if !motionBlurFilterInstalled {
            if let filter = CIFilter(name: "CIMotionBlur") {
                filter.name = "motionBlur"
                zoomGroup.filters = [filter]
                motionBlurFilterInstalled = true
            }
        }
        // MotionBlurMath's angle is Y-down (preview space); the layer's
        // backing store is rendered in CA's native Y-up space, the same
        // convention Core Image uses in the exporter — negate identically.
        zoomGroup.setValue(blur.radius * canvas.width, forKeyPath: "filters.motionBlur.inputRadius")
        zoomGroup.setValue(-blur.angle, forKeyPath: "filters.motionBlur.inputAngle")
    }

    private func zoomAnchor(
        _ input: FrameInput, canvas: CGSize, contentRect: CGRect,
        videoRect: CGRect, angles: (pitch: Double, yaw: Double, roll: Double),
        distance: CGFloat, tiltCenter: CGPoint, pad: CGFloat
    ) -> CGPoint {
        // PreviewView computes the focal against the video rect laid out in
        // the FULL canvas (no padding) — replicate exactly.
        let canvasVideoRect = previewVideoRect(input, in: canvas)
        var focal = CGPoint(
            x: canvasVideoRect.minX + motion.focal.x * canvasVideoRect.width,
            y: canvasVideoRect.minY + motion.focal.y * canvasVideoRect.height
        )
        if max(abs(angles.pitch), abs(angles.yaw), abs(angles.roll)) > 0.01 {
            focal = TiltMath.projectedPoint(
                focal,
                center: CGPoint(x: tiltCenter.x + pad, y: tiltCenter.y + pad),
                pitchDegrees: angles.pitch,
                yawDegrees: angles.yaw,
                rollDegrees: angles.roll,
                distance: distance,
                yUp: false
            )
        }
        return focal
    }

    // MARK: - Spring plumbing

    private func motionEnv(_ input: FrameInput) -> PreviewMotionModel.Env {
        PreviewMotionModel.Env(
            currentTime: input.currentTime,
            zoomRegions: input.project.zoomRegions,
            tiltRegions: input.project.tiltRegions,
            animationDuration: input.project.settings.animationSpeed.duration,
            screenTiltMode: input.project.settings.screenTiltMode,
            smoothingFactor: input.project.settings.smoothingFactor,
            followSpeed: input.project.settings.cameraFollowSpeed,
            scrollTimes: input.scrollTimes,
            cursorEvents: input.cursorEvents.isEmpty ? [] : effectiveCursorEvents(input),
            coordinateSize: resolvedCursorCoordinateSize(input)
        )
    }

    /// Mirrors the onChange(...) { resetSpring() } triggers in PreviewView.
    private func motionResetSignature(_ input: FrameInput) -> String {
        let p = input.project
        // cardOffsetX/Y MUST be part of the signature: a paused-drag
        // requestRender arrives with an unchanged clock, so the reset branch
        // is the ONLY motion branch it can take. Omitting the offset meant a
        // mid-block card drag (DragMode.blockOffset) wrote the model and then
        // re-rendered the identical frame — the drag felt completely dead.
        // Reset snaps offset target == value, which is exactly the direct
        // 1:1 tracking a live drag needs (same mechanism as the focal drag).
        let zooms = p.zoomRegions.map {
            "\($0.id.uuidString):\($0.startTime):\($0.endTime):\($0.zoomLevel):\($0.focalPoint.x):\($0.focalPoint.y):\($0.cardOffsetX ?? 0):\($0.cardOffsetY ?? 0)"
        }.joined(separator: "|")
        let tilts = p.tiltRegions.map {
            "\($0.id.uuidString):\($0.startTime):\($0.endTime):\($0.pitch):\($0.yaw):\($0.roll)"
        }.joined(separator: "|")
        return "\(input.videoSize.width)x\(input.videoSize.height)|\(input.cursorEvents.count)|"
            + "\(p.settings.animationSpeed.rawValue)|\(p.settings.smoothCursor)|\(p.settings.smoothingFactor)|\(p.settings.cameraFollowSpeed)|"
            + "\(p.settings.screenTiltMode.rawValue)|\(zooms)|\(tilts)"
    }
}

// MARK: - Video frame driver (layer-targeted port of VideoOutputNSView)

/// Pulls pixel buffers from AVPlayerItemVideoOutput into a target CALayer at
/// 60Hz — the same engine as VideoOutputNSView, addressed at a layer so the
/// compositor can place video anywhere in its tree.
final class VideoFrameLayerDriver {
    let player: AVPlayer
    private(set) var hasFrame = false
    /// Increments per delivered frame — cache token for derived bitmaps
    /// (e.g. blur patches).
    private(set) var frameToken = 0
    /// The most recently displayed frame — source for the blur pipeline.
    var currentPixelBuffer: CVPixelBuffer? { displayedPixelBuffer }

    private weak var layer: CALayer?
    private var output: AVPlayerItemVideoOutput?
    private weak var attachedItem: AVPlayerItem?
    private var pollTimer: Timer?
    private var displayedPixelBuffer: CVPixelBuffer?

    /// Camera color adjustments (CameraStyleMath) applied to every delivered
    /// frame — the SAME CIImage pipeline the exporter runs, so preview and
    /// export cannot diverge. `.identity` keeps the zero-copy IOSurface path.
    var cameraAdjustments: CameraStyleMath.Adjustments = .identity {
        didSet {
            guard cameraAdjustments != oldValue else { return }
            // Re-present the current frame with the new look immediately.
            if let buffer = displayedPixelBuffer { present(buffer) }
        }
    }
    /// One CIContext for all preview-side camera processing.
    static let sharedCIContext = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
        .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
    ])
    /// Reused destination buffer for adjusted frames (IOSurface-backed so the
    /// layer contents path stays identical to the raw path).
    private var adjustedBuffer: CVPixelBuffer?

    init(player: AVPlayer, layer: CALayer, gravity: CALayerContentsGravity = .resize) {
        self.player = player
        self.layer = layer
        layer.contentsGravity = gravity
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.pullFrame()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    deinit { pollTimer?.invalidate() }

    private func attachOutputIfNeeded() {
        guard let item = player.currentItem, attachedItem !== item else { return }
        if let output, let previous = attachedItem { previous.remove(output) }
        let newOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ])
        item.add(newOutput)
        output = newOutput
        attachedItem = item
        hasFrame = false
    }

    private func pullFrame() {
        attachOutputIfNeeded()
        guard let output else { return }
        let itemTime = player.currentTime()
        guard output.hasNewPixelBuffer(forItemTime: itemTime),
              let pixelBuffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) else { return }
        present(pixelBuffer)
    }

    /// Show a frame — raw IOSurface at identity, or run through the shared
    /// CameraStyleMath pipeline into a reused IOSurface-backed buffer when
    /// color adjustments are active.
    private func present(_ pixelBuffer: CVPixelBuffer) {
        let surface: IOSurface?
        if cameraAdjustments.isIdentity {
            surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
        } else {
            surface = adjustedSurface(for: pixelBuffer)
                ?? CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
        }
        guard let surface else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = surface
        CATransaction.commit()
        displayedPixelBuffer = pixelBuffer
        hasFrame = true
        frameToken &+= 1
    }

    private func adjustedSurface(for pixelBuffer: CVPixelBuffer) -> IOSurface? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        if adjustedBuffer == nil
            || CVPixelBufferGetWidth(adjustedBuffer!) != width
            || CVPixelBufferGetHeight(adjustedBuffer!) != height {
            var created: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, [
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ] as CFDictionary, &created)
            adjustedBuffer = created
        }
        guard let dest = adjustedBuffer else { return nil }
        let adjusted = CameraStyleMath.adjustedImage(
            CIImage(cvPixelBuffer: pixelBuffer), adjustments: cameraAdjustments
        )
        Self.sharedCIContext.render(
            adjusted, to: dest,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )
        return CVPixelBufferGetIOSurface(dest)?.takeUnretainedValue()
    }
}

// NOTE: the rasterizable `DeviceIslandOverlayView` that used to live here was
// DELETED, not merely unused. It was the second island source: an
// ImageRenderer bitmap of it assigned to `islandLayer.contents` composites
// UNDER the native seam/capsule sublayers instead of replacing them, and it
// lands at the wrong Y in the compositor's flipped hierarchy — the duplicated
// pill users saw. The island is drawn only by `renderDeviceChrome`'s shape
// layers, in the card's own coordinate space. Do not reintroduce a raster.

// MARK: - Subtitle rasterizer (exporter-identical recipe at 1× canvas scale)

enum SubtitlePillRasterizer {
    struct Result { var image: NSImage; var pillSize: CGSize }

    /// Renders the subtitle pill + text + shadow/glow into a bitmap using
    /// the SAME NSAttributedString recipe as VideoExporter.renderSubtitle
    /// (canvasScale = 1). The bitmap has uniform slack around the pill for
    /// the shadow/glow spill.
    static func render(
        subtitle: SubtitleSegment,
        settings s: ProjectSettings,
        currentTime: TimeInterval,
        maxWidth: CGFloat,
        scale: CGFloat
    ) -> Result? {
        let font = FontCatalog.font(named: s.subtitleFontName, size: max(1, s.subtitleFontSize), weight: s.subtitleWeight.nsWeight)
        let transform: (String) -> String = s.subtitleUppercase ? { $0.uppercased() } : { $0 }
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let textColor = s.subtitleColor.nsColor

        let attrString: NSAttributedString
        if s.highlightWords && !subtitle.words.isEmpty {
            let highlightColor = s.subtitleHighlightColor.nsColor
            let dimColor = textColor.withAlphaComponent(textColor.alphaComponent * 0.4)
            let spaceAttrs: [NSAttributedString.Key: Any] = [
                .font: font, .paragraphStyle: paragraphStyle, .foregroundColor: textColor,
            ]
            let mutable = NSMutableAttributedString()
            for (i, word) in subtitle.words.enumerated() {
                if i > 0 { mutable.append(NSAttributedString(string: " ", attributes: spaceAttrs)) }
                let isActive = currentTime >= word.startTime
                mutable.append(NSAttributedString(
                    string: transform(word.text),
                    attributes: [.font: font, .paragraphStyle: paragraphStyle,
                                 .foregroundColor: isActive ? highlightColor : dimColor]
                ))
            }
            attrString = mutable
        } else {
            attrString = NSAttributedString(
                string: transform(subtitle.text),
                attributes: [.font: font, .paragraphStyle: paragraphStyle, .foregroundColor: textColor]
            )
        }

        let textSize = attrString.boundingRect(
            with: CGSize(width: max(1, maxWidth), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let pillW = ceil(textSize.width) + 24  // 12pt horizontal padding
        let pillH = ceil(textSize.height) + 12 // 6pt vertical padding
        let slack: CGFloat = s.subtitleStyle == .glow ? 24 : 10
        let imgW = pillW + slack * 2
        let imgH = pillH + slack * 2

        // Rasterise into an EXPLICIT context rather than `NSImage.lockFocus`.
        //
        // lockFocus rasterises at the current SCREEN's backing scale, while the
        // shadow radii below are in device pixels and were hard-coded `* 2` —
        // i.e. the glow was only correct on a Retina display, and drew at half
        // strength on a 1x external monitor. It also made this gate score the
        // desk rather than the renderer.
        let pxW = Int((imgW * scale).rounded()), pxH = Int((imgH * scale).rounded())
        // deviceRGB, not sRGB: this replaced `NSImage.lockFocus`, which used
        // the device space, and the goldens encode that. Using sRGB here shifts
        // the glow by ~8/255.
        guard pxW > 0, pxH > 0,
              let ctx = CGContext(
                  data: nil, width: pxW, height: pxH, bitsPerComponent: 8, bytesPerRow: 0,
                  space: NSColorSpace.deviceRGB.cgColorSpace ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }
        ctx.scaleBy(x: scale, y: scale)

        let nsContext = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext
        defer { NSGraphicsContext.restoreGraphicsState() }

        // Shadow/glow — mirrors preview .shadow(): outline = black r2,
        // glow = text color at 0.8 r6. `setShadow` blur is in DEVICE pixels and
        // is not transformed by the CTM, so it carries the scale explicitly.
        switch s.subtitleStyle {
        case .outline:
            ctx.setShadow(offset: .zero, blur: 2 * scale, color: NSColor.black.cgColor)
        case .glow:
            ctx.setShadow(offset: .zero, blur: 6 * scale,
                          color: textColor.withAlphaComponent(0.8 * textColor.alphaComponent).cgColor)
        case .background, .plain:
            break
        }

        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        if s.subtitleStyle == .background {
            let bg = s.subtitleBackgroundColor.nsColor.withAlphaComponent(0.75)
            ctx.setFillColor(bg.cgColor)
            let pillRect = CGRect(x: slack, y: slack, width: pillW, height: pillH)
            ctx.addPath(CGPath(roundedRect: pillRect, cornerWidth: 6, cornerHeight: 6, transform: nil))
            ctx.fillPath()
        }
        attrString.draw(in: CGRect(x: slack + 12, y: slack + 6, width: textSize.width, height: textSize.height))
        ctx.endTransparencyLayer()

        guard let cg = ctx.makeImage() else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: imgW, height: imgH))
        return Result(image: image, pillSize: CGSize(width: pillW, height: pillH))
    }
}

extension PreviewCompositorView {
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
}
