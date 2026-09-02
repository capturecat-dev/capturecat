import AppKit

// CCKit progress — the house replacements for NSProgressIndicator.
// Both are API-compatible enough (`doubleValue`, `startAnimation`/`stop…`)
// that stock indicators swap out one line at a time.

/// Indeterminate activity spinner: an arc orbiting on the house curve.
@MainActor
final class CCSpinner: NSView {
    var isDisplayedWhenStopped = false {
        didSet { refreshVisibility() }
    }

    private let arc = CAShapeLayer()
    private var spinning = false
    private let diameter: CGFloat
    private var themeObservation: CCThemeObservation?

    override var intrinsicContentSize: NSSize { NSSize(width: diameter, height: diameter) }

    init(diameter: CGFloat = 16) {
        self.diameter = diameter
        super.init(frame: .zero)
        wantsLayer = true
        arc.fillColor = nil
        arc.lineWidth = 2
        themeObservation = CCThemeObservation { [weak self] in
            self?.arc.strokeColor = CCTheme.color.foreground.cgColor
        }
        arc.lineCap = .round
        arc.strokeStart = 0
        arc.strokeEnd = 0.72
        layer?.addSublayer(arc)
        refreshVisibility()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        let inset: CGFloat = 2
        arc.frame = bounds
        arc.path = CGPath(
            ellipseIn: bounds.insetBy(dx: inset, dy: inset),
            transform: nil
        )
    }

    func startAnimation(_ sender: Any?) {
        guard !spinning else { return }
        spinning = true
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi
        spin.duration = 0.9
        spin.repeatCount = .infinity
        arc.add(spin, forKey: "capspinner")
        refreshVisibility()
    }

    func stopAnimation(_ sender: Any?) {
        spinning = false
        arc.removeAnimation(forKey: "capspinner")
        refreshVisibility()
    }

    private func refreshVisibility() {
        isHidden = !spinning && !isDisplayedWhenStopped
    }
}

/// Determinate progress bar: a hairline pill track with a primary fill that
/// glides to each new value on the house settle curve.
@MainActor
final class CCProgressBar: NSView {
    var minValue: Double = 0
    var maxValue: Double = 1
    var doubleValue: Double = 0 {
        didSet { needsLayout = true }
    }

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
        fill.cornerCurve = .continuous
        layer?.addSublayer(fill)
        themeObservation = CCThemeObservation { [weak self] in
            self?.layer?.backgroundColor = CCTheme.color.active.cgColor
            self?.fill.backgroundColor = CCTheme.color.primary.cgColor
        }
        heightAnchor.constraint(equalToConstant: barHeight).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        let radius = CCRadius.full.resolved(for: bounds.height)
        layer?.cornerRadius = radius
        // Skeuo: the track is a groove; the fill is a raised glossy bar.
        if let layer {
            CCMaterial.dress(layer, as: .recessed(tint: CCTheme.color.active), radius: radius)
        }
        CCMaterial.dress(fill, as: .raised(tint: CCTheme.color.primary), radius: radius)
        let span = maxValue - minValue
        let fraction = span > 0 ? min(max((doubleValue - minValue) / span, 0), 1) : 0
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.28)
        CATransaction.setAnimationTimingFunction(CCMotion.settle)
        fill.frame = CGRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height)
        fill.cornerRadius = radius
        CATransaction.commit()
        CCMaterial.refit(fill, radius: radius)
    }
}
