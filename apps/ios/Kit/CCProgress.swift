import UIKit

/// Activity spinner — the house BREATHING arc: it turns steadily while its
/// length swells and eases back, on a faint track. Replaces
/// UIActivityIndicatorView (stock chrome).
final class CCSpinner: UIView {
    /// Arc color (defaults to the foreground ink).
    var color: UIColor = CCTheme.color.foreground {
        didSet { applyTheme() }
    }

    /// Pull-to-refresh drives the arc by hand while dragging.
    var progress: CGFloat = 0.72 {
        didSet {
            guard !isAnimating else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            arc.strokeEnd = max(0.02, min(0.78, progress))
            CATransaction.commit()
        }
    }

    private(set) var isAnimating = false
    var hidesWhenStopped = true { didSet { refreshVisibility() } }

    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    let diameter: CGFloat

    init(diameter: CGFloat = 20) {
        self.diameter = diameter
        super.init(frame: CGRect(x: 0, y: 0, width: diameter, height: diameter))
        isUserInteractionEnabled = false
        for shape in [track, arc] {
            shape.fillColor = nil
            shape.lineWidth = diameter >= 28 ? 2.5 : 2
            shape.lineCap = .round
            layer.addSublayer(shape)
        }
        arc.strokeStart = 0
        arc.strokeEnd = 0.72
        isAccessibilityElement = false
        ccOnThemeChange { [weak self] in self?.applyTheme() }
        applyTheme()
        refreshVisibility()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: CGSize { CGSize(width: diameter, height: diameter) }

    private func applyTheme() {
        arc.strokeColor = cc(color)
        track.strokeColor = color.resolvedColor(with: traitCollection).withAlphaComponent(0.12).cgColor
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = arc.lineWidth / 2 + 0.5
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let path = UIBezierPath(arcCenter: CGPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2,
                                startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: true).cgPath
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shape in [track, arc] {
            shape.frame = bounds
            shape.path = path
        }
        CATransaction.commit()
    }

    func startAnimating() {
        guard !isAnimating else { return }
        isAnimating = true
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = 2 * Double.pi
        spin.duration = 0.9
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        arc.add(spin, forKey: "ccspinner")
        let breathe = CABasicAnimation(keyPath: "strokeEnd")
        breathe.fromValue = 0.2
        breathe.toValue = 0.78
        breathe.duration = 0.7
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.isRemovedOnCompletion = false
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        arc.add(breathe, forKey: "ccspinner.breathe")
        refreshVisibility()
    }

    func stopAnimating() {
        isAnimating = false
        arc.removeAnimation(forKey: "ccspinner")
        arc.removeAnimation(forKey: "ccspinner.breathe")
        refreshVisibility()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Re-arm after re-hosting (a moved layer tree can drop animations).
        if isAnimating, window != nil, arc.animation(forKey: "ccspinner") == nil {
            isAnimating = false
            startAnimating()
        }
    }

    private func refreshVisibility() {
        isHidden = hidesWhenStopped && !isAnimating
    }
}

/// Progress bar: a recessed pill groove with a raised accent fill that
/// SPRINGS to each new value; `isIndeterminate` sweeps a segment through.
final class CCProgressBar: UIView {
    var value: Double = 0 {
        didSet {
            guard value != oldValue else { return }
            refreshFill(animated: true)
            refreshAccessibilityValue()
        }
    }

    var isIndeterminate = false {
        didSet {
            guard isIndeterminate != oldValue else { return }
            refreshMode()
            refreshAccessibilityValue()
        }
    }

    var tint: UIColor = CCTheme.color.primary { didSet { applyTheme() } }

    private let fillClip = CALayer()
    private let fill = CALayer()
    static let barHeight: CGFloat = 6

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        fillClip.anchorPoint = CGPoint(x: 0, y: 0.5)
        fillClip.masksToBounds = true
        fillClip.cornerCurve = .continuous
        fill.cornerCurve = .continuous
        fillClip.addSublayer(fill)
        layer.addSublayer(fillClip)
        heightAnchor.constraint(equalToConstant: Self.barHeight).isActive = true
        isAccessibilityElement = true
        accessibilityTraits = .updatesFrequently
        // Hosts may name it better ("Upload progress"); it is never nameless.
        accessibilityLabel = String(localized: "Progress", comment: "Progress bar (VoiceOver)")
        refreshAccessibilityValue()
        ccOnThemeChange { [weak self] in self?.applyTheme() }
        applyTheme()
    }

    private func refreshAccessibilityValue() {
        accessibilityValue = isIndeterminate ? String(localized: "In progress", comment: "Indeterminate progress (VoiceOver)") : String(localized: "\(Int((max(0, min(1, value)) * 100).rounded())) percent", comment: "Progress value (VoiceOver)")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var fraction: CGFloat { CGFloat(min(max(value, 0), 1)) }
    private var radius: CGFloat { CCRadius.full.resolved(for: max(bounds.height, Self.barHeight)) }

    private func applyTheme() {
        CCMaterial.dress(layer, as: .recessed(tint: CCTheme.color.active), radius: radius, traits: traitCollection)
        CCMaterial.dress(fill, as: .raisedMatte(tint: tint), radius: radius, traits: traitCollection)
        accessibilityValue = isIndeterminate ? String(localized: "In progress", comment: "Indeterminate progress (VoiceOver)") : String(localized: "\(Int((fraction * 100).rounded())) percent", comment: "Progress value (VoiceOver)")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = radius
        CCMaterial.refit(layer, radius: radius)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = bounds
        fill.cornerRadius = radius
        fillClip.cornerRadius = radius
        fillClip.bounds.size.height = bounds.height
        if isIndeterminate {
            fillClip.bounds.size.width = bounds.width * 0.32
            fillClip.position.y = bounds.midY
        } else {
            fillClip.position = CGPoint(x: 0, y: bounds.midY)
            if fillClip.animation(forKey: "ccmotion.bounds.size.width") == nil {
                fillClip.bounds.size.width = bounds.width * fraction
            }
        }
        CATransaction.commit()
        CCMaterial.refit(fill, radius: radius)
        if isIndeterminate, fillClip.animation(forKey: "ccprogress.sweep") == nil { refreshMode() }
    }

    private func refreshFill(animated: Bool) {
        accessibilityValue = String(localized: "\(Int((fraction * 100).rounded())) percent", comment: "Progress value (VoiceOver)")
        guard !isIndeterminate else { return }
        let target = bounds.width * fraction
        if animated, window != nil, bounds.width > 0 {
            CCMotion.spring(fillClip, keyPath: "bounds.size.width", to: target, .smooth)
        } else {
            setNeedsLayout()
        }
    }

    private func refreshMode() {
        fillClip.removeAnimation(forKey: "ccprogress.sweep")
        guard isIndeterminate else {
            setNeedsLayout()
            refreshFill(animated: true)
            return
        }
        guard bounds.width > 0 else { setNeedsLayout(); return }
        let segment = bounds.width * 0.32
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillClip.bounds.size.width = segment
        CATransaction.commit()
        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = -segment
        sweep.toValue = bounds.width
        sweep.duration = 1.25
        sweep.timingFunction = CCMotion.glide
        sweep.repeatCount = .infinity
        sweep.isRemovedOnCompletion = false
        fillClip.add(sweep, forKey: "ccprogress.sweep")
    }

    // Probe seam.
    var probeFillWidth: CGFloat { (fillClip.presentation() ?? fillClip).bounds.width }
}
