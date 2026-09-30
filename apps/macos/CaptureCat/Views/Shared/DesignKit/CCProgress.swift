import AppKit

// CCKit progress — the house replacements for NSProgressIndicator.
// Both are API-compatible enough (`doubleValue`, `startAnimation`/`stop…`)
// that stock indicators swap out one line at a time.

/// Indeterminate activity spinner — an Apple-like BREATHING arc: it turns
/// steadily while its length swells and eases back, on a faint track.
@MainActor
final class CCSpinner: NSView {
    var isDisplayedWhenStopped = false {
        didSet { refreshVisibility() }
    }

    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    private var spinning = false
    private let diameter: CGFloat
    private var themeObservation: CCThemeObservation?

    override var intrinsicContentSize: NSSize { NSSize(width: diameter, height: diameter) }

    init(diameter: CGFloat = 16) {
        self.diameter = diameter
        super.init(frame: .zero)
        wantsLayer = true
        for shape in [track, arc] {
            shape.fillColor = nil
            shape.lineWidth = diameter >= 24 ? 2.5 : 2
            shape.lineCap = .round
            layer?.addSublayer(shape)
        }
        arc.strokeStart = 0
        arc.strokeEnd = 0.72
        themeObservation = CCThemeObservation { [weak self] in
            self?.arc.strokeColor = CCTheme.color.foreground.cgColor
            self?.track.strokeColor = CCTheme.color.foreground.withAlphaComponent(0.1).cgColor
        }
        refreshVisibility()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// True when this layer's sublayer space runs Y-down ON SCREEN. The
    /// EFFECTIVE flip — `isGeometryFlipped` is relative to the parent (AppKit
    /// toggles it to match each view's own isFlipped), so it lies under a
    /// flipped parent.
    private var sublayersFlipped: Bool { layer?.contentsAreFlipped() ?? false }

    override func layout() {
        super.layout()
        let inset = arc.lineWidth / 2 + 0.5
        let rect = bounds.insetBy(dx: inset, dy: inset)
        // Drawn CLOCKWISE from 12 o'clock, the same way it turns — so the
        // swelling head leads the rotation instead of fighting it.
        let path = CGMutablePath()
        let top: CGFloat = sublayersFlipped ? -.pi / 2 : .pi / 2
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2,
                    startAngle: top, endAngle: top + (sublayersFlipped ? 2 : -2) * .pi, clockwise: !sublayersFlipped)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shape in [track, arc] {
            shape.frame = bounds
            shape.path = path
        }
        CATransaction.commit()
    }

    func startAnimation(_ sender: Any?) {
        guard !spinning else { return }
        spinning = true
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = (sublayersFlipped ? 2 : -2) * Double.pi
        spin.duration = 0.9
        spin.repeatCount = .infinity
        arc.add(spin, forKey: "capspinner")
        // The breath: the arc swells long and eases back while it turns —
        // alive, never a stutter.
        let breathe = CABasicAnimation(keyPath: "strokeEnd")
        breathe.fromValue = 0.2
        breathe.toValue = 0.78
        breathe.duration = 0.7
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        arc.add(breathe, forKey: "capspinner.breathe")
        refreshVisibility()
    }

    func stopAnimation(_ sender: Any?) {
        spinning = false
        arc.removeAnimation(forKey: "capspinner")
        arc.removeAnimation(forKey: "capspinner.breathe")
        refreshVisibility()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Re-arm after re-hosting: a layer tree moving between windows (or
        // render contexts) can come back with its animations dropped.
        if spinning, window != nil, arc.animation(forKey: "capspinner") == nil {
            spinning = false
            startAnimation(nil)
        }
    }

    private func refreshVisibility() {
        isHidden = !spinning && !isDisplayedWhenStopped
    }

    // MARK: - Harness seams

    var probeArcLayer: CAShapeLayer { arc }
}

/// Progress bar: a recessed pill groove with a raised accent fill that
/// SPRINGS to each new value (continuous retargeting — rapid updates glide
/// instead of stuttering). `isIndeterminate` sweeps a segment through the
/// groove for work of unknown length.
@MainActor
final class CCProgressBar: NSView {
    var minValue: Double = 0 {
        didSet { needsLayout = true }
    }
    var maxValue: Double = 1 {
        didSet { needsLayout = true }
    }
    var doubleValue: Double = 0 {
        didSet {
            guard doubleValue != oldValue else { return }
            refreshFill(animated: true)
        }
    }

    var isIndeterminate = false {
        didSet {
            guard isIndeterminate != oldValue else { return }
            refreshMode()
        }
    }

    /// The fill's visible extent — its width springs; the dressed fill
    /// inside stays track-sized, so the material never stretches or snaps.
    private let fillClip = CALayer()
    private let fill = CALayer()
    private let barHeight: CGFloat = 5
    private var themeObservation: CCThemeObservation?

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: barHeight)
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        // The groove clips the sweep and the fill's extruded edge.
        layer?.masksToBounds = true
        fillClip.anchorPoint = CGPoint(x: 0, y: 0.5)
        fillClip.masksToBounds = true
        fillClip.cornerCurve = .continuous
        fill.cornerCurve = .continuous
        fillClip.addSublayer(fill)
        layer?.addSublayer(fillClip)
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
        heightAnchor.constraint(equalToConstant: barHeight).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var fraction: CGFloat {
        let span = maxValue - minValue
        return span > 0 ? CGFloat(min(max((doubleValue - minValue) / span, 0), 1)) : 0
    }

    private var radius: CGFloat { CCRadius.full.resolved(for: max(bounds.height, barHeight)) }

    private func applyTheme() {
        guard let layer else { return }
        let colors = CCTheme.color
        layer.backgroundColor = colors.active.cgColor
        // Skeuo: the track is a groove; the fill is a raised bar.
        CCMaterial.dress(layer, as: .recessed(tint: colors.active), radius: radius)
        fill.backgroundColor = colors.primary.cgColor
        CCMaterial.dress(fill, as: .raised(tint: colors.primary), radius: radius)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = radius
        if let layer { CCMaterial.refit(layer, radius: radius) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        fill.cornerRadius = radius
        fillClip.cornerRadius = radius
        fillClip.bounds.size.height = bounds.height
        if isIndeterminate {
            fillClip.bounds.size.width = bounds.width * 0.32
            fillClip.position.y = bounds.midY
        } else {
            fillClip.position = CGPoint(x: 0, y: bounds.midY)
            // Never clobber an in-flight spring; its model value is already
            // the target (a resize simply re-targets after it lands).
            if fillClip.animation(forKey: "capmotion.bounds.size.width") == nil {
                fillClip.bounds.size.width = bounds.width * fraction
            }
        }
        CATransaction.commit()
        CCMaterial.refit(fill, radius: radius)
        if isIndeterminate, fillClip.animation(forKey: "ccprogress.sweep") == nil { refreshMode() }
    }

    private func refreshFill(animated: Bool) {
        guard !isIndeterminate else { return }
        let target = bounds.width * fraction
        if animated, window != nil, bounds.width > 0 {
            CCMotion.spring(fillClip, keyPath: "bounds.size.width", to: target, .smooth)
        } else {
            needsLayout = true
        }
    }

    private func refreshMode() {
        fillClip.removeAnimation(forKey: "ccprogress.sweep")
        guard isIndeterminate else {
            needsLayout = true
            refreshFill(animated: true)
            return
        }
        guard bounds.width > 0 else { needsLayout = true; return }
        let segment = bounds.width * 0.32
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillClip.bounds.size.width = segment
        CATransaction.commit()
        // A segment glides through the groove, easing in and out of each
        // pass (the anchor is its leading edge: it starts fully off-stage).
        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = -segment
        sweep.toValue = bounds.width
        sweep.duration = 1.25
        sweep.timingFunction = CCMotion.glide
        sweep.repeatCount = .infinity
        fillClip.add(sweep, forKey: "ccprogress.sweep")
    }

    // MARK: - Harness seams

    var probeFillWidth: CGFloat { (fillClip.presentation() ?? fillClip).bounds.width }
    var probeFillX: CGFloat { (fillClip.presentation() ?? fillClip).position.x }
    var probeFillLayer: CALayer { fill }
}
