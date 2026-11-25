import UIKit

/// The editor's preview card — the iOS twin of the Mac's
/// `EditorStageViewController` card: the letterboxed live stage
/// (`PreviewStageView`, the shared compositor), the touch edit surface over
/// it (`EditorCanvasView`, the shared gesture core) and a bottom-trailing
/// zoom pill. Pinch magnifies the stage (pure magnification about the
/// fingers, 25 %–400 % like the Mac's 0.25…4 scroll-view range); two fingers
/// pan it while magnified.
final class EditorStageCardView: UIView, UIGestureRecognizerDelegate {
    let stage = PreviewStageView(frame: .zero)
    let canvas = EditorCanvasView(frame: .zero)
    let zoomPill = EditorZoomPill()

    /// The user changed the magnification (pinch or pill); 1 = fit.
    var onZoomChange: ((CGFloat) -> Void)?

    #if DEBUG
    /// Probe seam — INJECTED DEFECT (`stage-card`): the stage is an inset
    /// rounded card again (the editor also insets it).
    static var probeCard = false
    /// Probe seam — INJECTED DEFECT (`glass-on-content`): the stage itself
    /// sits on glass (content must stay flat).
    static var probeGlassStage = false
    #endif

    static let zoomSteps: [CGFloat] = [0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 4.0]
    private var pinchStartZoom: CGFloat = 1
    private var pinchStartPan: CGPoint = .zero
    private var pinchAnchorCanvas: CGPoint = .zero
    private var panStart: CGPoint = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        // Edge to edge and flat (no inset card): the canvas fills the region
        // at its own aspect; any spare band is the editor's ground.
        backgroundColor = CCTheme.color.background
        clipsToBounds = true
        #if DEBUG
        if Self.probeCard {
            layer.cornerRadius = CCTheme.radii.lg
            layer.borderWidth = 1
            layer.borderColor = UIColor.gray.cgColor
        }
        #endif
        accessibilityIdentifier = "studio.stageCard"

        for view in [stage, canvas] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            stageLeft.append(view.leftAnchor.constraint(equalTo: leftAnchor))
            stageRight.append(view.rightAnchor.constraint(equalTo: rightAnchor))
        }
        NSLayoutConstraint.activate(stageLeft + stageRight)
        #if DEBUG
        if Self.probeGlassStage {
            let glass = CCGlassView(shape: .rounded(.md))
            glass.translatesAutoresizingMaskIntoConstraints = false
            insertSubview(glass, belowSubview: canvas)
            NSLayoutConstraint.activate([
                glass.leadingAnchor.constraint(equalTo: leadingAnchor), glass.trailingAnchor.constraint(equalTo: trailingAnchor),
                glass.topAnchor.constraint(equalTo: topAnchor), glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        #endif
        canvas.stage = stage
        stage.isDraggingOnCanvasProvider = { [weak canvas] in canvas?.isActivelyDragging ?? false }
        stage.inlineEditingIDProvider = { [weak canvas] in canvas?.inlineEditingID }

        addSubview(zoomPill)
        pillTrailing = zoomPill.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -4)
        pillLeading = zoomPill.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 4)
        NSLayoutConstraint.activate([
            pillTrailing,
            zoomPill.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        zoomPill.onZoomOut = { [weak self] in self?.stepZoom(-1) }
        zoomPill.onZoomIn = { [weak self] in self?.stepZoom(1) }
        zoomPill.onReset = { [weak self] in self?.setZoom(1, pan: .zero) }
        zoomPill.update(zoom: 1, canZoomOut: true, canZoomIn: true)
        // VoiceOver: stage objects never claim the pill's corner.
        canvas.accessibilityExclusions = { [weak self] in
            guard let self, !self.zoomPill.isHidden else { return [] }
            return [self.zoomPill.convert(self.zoomPill.bounds, to: self.canvas).insetBy(dx: -4, dy: -4)]
        }

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.delegate = self
        canvas.addGestureRecognizer(pinch)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        pan.delegate = self
        canvas.addGestureRecognizer(pan)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var stageLeft: [NSLayoutConstraint] = []
    private var stageRight: [NSLayoutConstraint] = []
    /// The system strip down ONE side of the screen (a folded iPhone Duo:
    /// the status items and the vertical bar), zero elsewhere. The card's
    /// ground stays edge to edge; the canvas keeps clear of the strip. The
    /// stage there is wide and short, so the zoom chip stands upright in
    /// the spare band beside the canvas instead of lying over its foot.
    var sideStrip: (left: CGFloat, right: CGFloat) = (0, 0) {
        didSet {
            guard sideStrip != oldValue else { return }
            for c in stageLeft { c.constant = sideStrip.left }
            for c in stageRight { c.constant = -sideStrip.right }
            zoomPill.axis = sideStrip == (0, 0) ? .horizontal : .vertical
            setNeedsLayout()
        }
    }

    private var pillTrailing: NSLayoutConstraint!
    private var pillLeading: NSLayoutConstraint!
    /// The zoom chip sits bottom-trailing (the Mac's corner); the stage is
    /// edge to edge, so when the camera bubble (or anything the editor
    /// names) is under that corner the chip moves to the leading corner —
    /// it never covers what you would grab.
    func keepZoomPillClear(of rect: CGRect?) {
        guard let rect, !rect.isEmpty else {
            if !pillTrailing.isActive { pillLeading.isActive = false; pillTrailing.isActive = true }
            return
        }
        let size = zoomPill.bounds.size
        let trailingSlot = CGRect(x: bounds.maxX - safeAreaInsets.right - 4 - size.width, y: bounds.maxY - 2 - size.height,
                                  width: size.width, height: size.height)
        let useLeading = trailingSlot.intersects(rect)
        guard useLeading != pillLeading.isActive else { return }
        pillTrailing.isActive = !useLeading
        pillLeading.isActive = useLeading
        setNeedsLayout()
    }

    // MARK: - Magnification

    func setZoom(_ zoom: CGFloat, pan: CGPoint) {
        // The in-place editor is placed in view space: commit it first.
        canvas.endInlineEdit(commit: true)
        let z = min(4, max(0.25, zoom))
        stage.userZoom = z
        stage.panOffset = clampedPan(pan, zoom: z)
        zoomPill.update(zoom: z, canZoomOut: z > Self.zoomSteps.first!, canZoomIn: z < Self.zoomSteps.last!)
        onZoomChange?(z)
        canvas.gestures.requestRender?()
    }

    private func stepZoom(_ direction: Int) {
        let zoom = stage.userZoom
        let next = direction > 0
            ? Self.zoomSteps.first(where: { $0 > zoom + 0.001 })
            : Self.zoomSteps.last(where: { $0 < zoom - 0.001 })
        if let next { setZoom(next, pan: next <= 1 ? .zero : stage.panOffset) }
    }

    /// Keeps a magnified canvas covering the stage's centre (no panning at
    /// or below fit).
    private func clampedPan(_ pan: CGPoint, zoom: CGFloat) -> CGPoint {
        let m = stage.fitMagnification * zoom
        let w = stage.virtualCanvasSize.width * m, h = stage.virtualCanvasSize.height * m
        let maxX = max(0, (w - stage.bounds.width) / 2), maxY = max(0, (h - stage.bounds.height) / 2)
        return CGPoint(x: min(maxX, max(-maxX, pan.x)), y: min(maxY, max(-maxY, pan.y)))
    }

    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            pinchStartZoom = stage.userZoom
            pinchStartPan = stage.panOffset
            pinchAnchorCanvas = stage.canvasPoint(fromView: g.location(in: stage))
        case .changed:
            let z = min(4, max(0.25, pinchStartZoom * g.scale))
            // Keep the canvas point under the fingers where it was.
            stage.userZoom = z
            stage.panOffset = .zero
            let unpanned = stage.viewPoint(fromCanvas: pinchAnchorCanvas)
            let finger = g.location(in: stage)
            setZoom(z, pan: CGPoint(x: finger.x - unpanned.x, y: finger.y - unpanned.y))
        default:
            break
        }
    }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began: panStart = stage.panOffset
        case .changed:
            guard stage.userZoom > 1 else { return }
            let t = g.translation(in: stage)
            setZoom(stage.userZoom, pan: CGPoint(x: panStart.x + t.x, y: panStart.y + t.y))
        default: break
        }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        (g is UIPinchGestureRecognizer && other is UIPanGestureRecognizer)
            || (g is UIPanGestureRecognizer && other is UIPinchGestureRecognizer)
    }
}

/// ⊖ 100% ⊕ — the Mac's `PreviewZoomPill`: a small glass capsule floating
/// over the stage (Liquid Glass; the kit's opaque material under Reduce
/// Transparency) with the magnifier icons and the percentage (tap it to
/// fit). Keys draw small and answer across 44 pt; spaced so their targets
/// never overlap.
final class EditorZoomPill: UIView {
    var onZoomOut: (() -> Void)?
    var onZoomIn: (() -> Void)?
    var onReset: (() -> Void)?

    private let minus = CCButton(symbol: "minus.magnifyingglass", style: .ghost, size: .regular, radius: .full)
    private let plus = CCButton(symbol: "plus.magnifyingglass", style: .ghost, size: .regular, radius: .full)
    private let row = UIStackView()
    /// Upright (zoom in on top) beside a wide, short stage.
    var axis: NSLayoutConstraint.Axis = .horizontal {
        didSet {
            guard axis != oldValue else { return }
            for key in axis == .vertical ? [plus, percent, minus] : [minus, percent, plus] { row.addArrangedSubview(key) }
            row.axis = axis
            percent.hPaddingOverride = axis == .vertical ? 4 : nil
            setNeedsLayout()
        }
    }
    private let percent = CCButton(title: "100%", style: .ghost, size: .sm, radius: .full)

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        accessibilityIdentifier = "studio.zoomPill"
        minus.accessibilityLabelOverride = String(localized: "Zoom out", comment: "Preview zoom pill: zoom the stage out (VoiceOver)")
        plus.accessibilityLabelOverride = String(localized: "Zoom in", comment: "Preview zoom pill: zoom the stage in (VoiceOver)")
        minus.onTap = { [weak self] in self?.onZoomOut?() }
        plus.onTap = { [weak self] in self?.onZoomIn?() }
        percent.onTap = { [weak self] in self?.onReset?() }
        percent.accessibilityLabelOverride = String(localized: "Fit", comment: "Preview zoom pill: reset the stage to fit the screen (VoiceOver)")
        for key in [minus, percent, plus] { row.addArrangedSubview(key) }
        row.spacing = 0
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 0),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            percent.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            minus.widthAnchor.constraint(equalToConstant: 44),
            plus.widthAnchor.constraint(equalToConstant: 44),
        ])
        layer.cornerCurve = .continuous
        glass.isUserInteractionEnabled = false
        glass.accessibilityIdentifier = "studio.zoomPill.glass"
        insertSubview(glass, at: 0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The visible capsule: the Mac chip's height, inside the 44 pt keys.
    let glass = CCGlassView(shape: .capsule)

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = axis == .vertical ? bounds.insetBy(dx: 2, dy: 0) : bounds.insetBy(dx: 0, dy: 7)
    }

    func update(zoom: CGFloat, canZoomOut: Bool, canZoomIn: Bool) {
        percent.title = "\(Int((zoom * 100).rounded()))%"
        percent.accessibilityValue = percent.title
        minus.isEnabled = canZoomOut
        plus.isEnabled = canZoomIn
    }
}
