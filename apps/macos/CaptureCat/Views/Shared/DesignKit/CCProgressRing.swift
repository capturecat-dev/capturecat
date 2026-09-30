import AppKit

/// CCKit progress ring — circular determinate progress: a RECESSED groove
/// with a raised accent arc that SPRINGS to each new value (continuous
/// retargeting, so fast updates never stutter), and an optional center
/// label that COUNTS to the new value instead of jumping. Indeterminate
/// mode spins a breathing arc.
///
///     let ring = CCProgressRing(diameter: 56)
///     ring.doubleValue = 0.42                  // arc springs, label counts up
///     ring.labelFormat = { "\(Int($0 * 100))%" }
///     ring.isIndeterminate = true              // unknown duration
@MainActor
final class CCProgressRing: NSView {
    var minValue: Double = 0
    var maxValue: Double = 1

    var doubleValue: Double = 0 {
        didSet {
            guard doubleValue != oldValue else { return }
            refreshArc(animated: true)
            countLabel(to: doubleValue)
        }
    }

    var isIndeterminate = false {
        didSet {
            guard isIndeterminate != oldValue else { return }
            refreshMode()
        }
    }

    /// Center readout; nil hides the label. Human units only.
    var labelFormat: ((Double) -> String)? = { "\(Int(($0 * 100).rounded()))%" } {
        didSet { refreshLabel(value: shownValue) }
    }

    let diameter: CGFloat
    let lineWidth: CGFloat

    /// Leaf host for every ring layer (a view with subviews gets its
    /// sublayer array rebuilt by AppKit; the label is a sibling).
    private let ringHost = NSView()
    private let groove = CAGradientLayer()
    private let grooveMask = CAShapeLayer()
    /// Rotates as a unit in indeterminate mode.
    private let spinner = CALayer()
    private let arcUnder = CAShapeLayer()
    private let arc = CAGradientLayer()
    private let arcMask = CAShapeLayer()
    private let label = NSTextField(labelWithString: "")
    private var shownValue: Double = 0
    private var counter: Timer?
    private var themeObservation: CCThemeObservation?

    override var intrinsicContentSize: NSSize { NSSize(width: diameter, height: diameter) }

    init(diameter: CGFloat = 56, lineWidth: CGFloat? = nil) {
        self.diameter = diameter
        self.lineWidth = lineWidth ?? max(3, (diameter * 0.1).rounded())
        super.init(frame: .zero)
        wantsLayer = true
        ringHost.wantsLayer = true
        for view in [ringHost, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: diameter),
            heightAnchor.constraint(equalToConstant: diameter),
            ringHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            ringHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            ringHost.topAnchor.constraint(equalTo: topAnchor),
            ringHost.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        for shape in [grooveMask, arcMask, arcUnder] {
            shape.fillColor = nil
            shape.lineWidth = self.lineWidth
        }
        grooveMask.strokeColor = NSColor.black.cgColor
        arcMask.strokeColor = NSColor.black.cgColor
        arcMask.lineCap = .round
        arcUnder.lineCap = .round
        arcMask.strokeEnd = 0
        arcUnder.strokeEnd = 0
        groove.mask = grooveMask
        arc.mask = arcMask
        ringHost.layer?.addSublayer(groove)
        ringHost.layer?.addSublayer(spinner)
        spinner.addSublayer(arcUnder)
        spinner.addSublayer(arc)

        label.alignment = .center
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
        refreshLabel(value: 0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var fraction: CGFloat {
        let span = maxValue - minValue
        guard span > 0 else { return 0 }
        return CGFloat(min(max((doubleValue - minValue) / span, 0), 1))
    }

    /// True when the host's sublayer space runs Y-down ON SCREEN — the
    /// EFFECTIVE flip (`isGeometryFlipped` is relative to the parent).
    private var sublayersFlipped: Bool { ringHost.layer?.contentsAreFlipped() ?? false }

    override func layout() {
        super.layout()
        let bounds = ringHost.bounds
        let inset = lineWidth / 2 + 1
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width / 2
        // Start at 12 o'clock and run CLOCKWISE on screen in either
        // sublayer orientation.
        let path = CGMutablePath()
        let top: CGFloat = sublayersFlipped ? -.pi / 2 : .pi / 2
        path.addArc(center: center, radius: radius, startAngle: top,
                    endAngle: top + (sublayersFlipped ? 2 : -2) * .pi, clockwise: !sublayersFlipped)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [groove, spinner, arc, grooveMask, arcMask, arcUnder] as [CALayer] {
            layer.frame = bounds
        }
        grooveMask.path = path
        arcMask.path = path
        arcUnder.path = path
        // The arc's darker under-edge peeks a point below it (the kit's key
        // "side"), selling the extrusion out of the groove.
        arcUnder.transform = CATransform3DMakeTranslation(0, sublayersFlipped ? 1 : -1, 0)
        let start = CGPoint(x: 0.5, y: sublayersFlipped ? 0 : 1)
        let end = CGPoint(x: 0.5, y: sublayersFlipped ? 1 : 0)
        groove.startPoint = start
        groove.endPoint = end
        arc.startPoint = start
        arc.endPoint = end
        CATransaction.commit()
        if arcMask.animation(forKey: "capmotion.strokeEnd") == nil, !isIndeterminate {
            refreshArc(animated: false)
        }
    }

    private func applyTheme() {
        let colors = CCTheme.color
        let dark = CCTheme.isDark
        func blend(_ a: NSColor, _ b: NSColor, _ f: CGFloat) -> NSColor { a.blended(withFraction: f, of: b) ?? a }
        // Groove = the recessed recipe (shaded at the top lip, a sliver of
        // light at the bottom) on the elevated tone.
        let well = colors.elevated
        groove.colors = [
            blend(well, .black, dark ? 0.22 : 0.12).cgColor,
            well.cgColor,
            blend(well, .white, dark ? 0.04 : 0.3).cgColor,
        ]
        groove.locations = [0, 0.5, 1]
        // Arc = the raised recipe: top-lit accent with a darker under-edge.
        let accent = colors.primary
        arc.colors = [
            blend(accent, .white, dark ? 0.14 : 0.16).cgColor,
            accent.cgColor,
            blend(accent, .black, dark ? 0.16 : 0.1).cgColor,
        ]
        arc.locations = [0, 0.5, 1]
        arcUnder.strokeColor = blend(accent, .black, dark ? 0.45 : 0.3).cgColor
        arcUnder.shadowColor = NSColor.black.cgColor
        arcUnder.shadowOpacity = dark ? 0.4 : 0.16
        arcUnder.shadowRadius = 1.5
        arcUnder.shadowOffset = CGSize(width: 0, height: sublayersFlipped ? 1 : -1)
        label.font = .monospacedDigitSystemFont(ofSize: max(9, (diameter * 0.22).rounded()), weight: .semibold)
        label.textColor = colors.foreground
    }

    private func refreshArc(animated: Bool) {
        guard !isIndeterminate else { return }
        let target = fraction
        if animated, window != nil {
            CCMotion.spring(arcMask, keyPath: "strokeEnd", to: target, .smooth)
            CCMotion.spring(arcUnder, keyPath: "strokeEnd", to: target, .smooth)
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            arcMask.strokeEnd = target
            arcUnder.strokeEnd = target
            CATransaction.commit()
        }
    }

    // MARK: - Counting label

    private func refreshLabel(value: Double) {
        guard let labelFormat, !isIndeterminate, diameter >= 32 else {
            label.isHidden = true
            return
        }
        label.isHidden = false
        let span = maxValue - minValue
        let normalized = span > 0 ? (value - minValue) / span : 0
        label.stringValue = labelFormat(min(max(normalized, 0), 1))
    }

    /// Tick the readout from what it SHOWS now to the target on the settle
    /// curve (~ the arc's spring), so the number and the arc arrive together.
    private func countLabel(to target: Double) {
        counter?.invalidate()
        guard window != nil else {
            shownValue = target
            refreshLabel(value: target)
            return
        }
        let from = shownValue
        let began = CACurrentMediaTime()
        let total = CCMotion.paced(0.55)
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let t = CGFloat(min(1, (CACurrentMediaTime() - began) / total))
                let eased = CCMotion.bezierY(t, (0.22, 1.0, 0.36, 1.0))
                self.shownValue = from + (target - from) * Double(eased)
                self.refreshLabel(value: self.shownValue)
                if t >= 1 {
                    self.shownValue = target
                    self.refreshLabel(value: target)
                    timer.invalidate()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        counter = timer
    }

    // MARK: - Indeterminate

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Re-arm the spin after re-hosting (animations can be dropped when a
        // layer tree moves between windows).
        if window != nil, isIndeterminate, spinner.animation(forKey: "ccring.spin") == nil {
            refreshMode()
        }
    }

    private func refreshMode() {
        spinner.removeAnimation(forKey: "ccring.spin")
        arcMask.removeAnimation(forKey: "ccring.breathe")
        arcUnder.removeAnimation(forKey: "ccring.breathe")
        refreshLabel(value: shownValue)
        guard isIndeterminate else {
            refreshArc(animated: true)
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arcMask.strokeEnd = 0.3
        arcUnder.strokeEnd = 0.3
        CATransaction.commit()
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = (sublayersFlipped ? 2 : -2) * Double.pi   // clockwise on screen
        spin.duration = 1.1
        spin.repeatCount = .infinity
        spinner.add(spin, forKey: "ccring.spin")
        // The arc breathes long/short while it turns.
        let breathe = CABasicAnimation(keyPath: "strokeEnd")
        breathe.fromValue = 0.14
        breathe.toValue = 0.62
        breathe.duration = 0.9
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        arcMask.add(breathe, forKey: "ccring.breathe")
        arcUnder.add(breathe, forKey: "ccring.breathe")
    }

    // MARK: - Harness seams

    var probeArcLayer: CAShapeLayer { arcMask }
    var probeGrooveLayer: CAGradientLayer { groove }
    var probeLabel: NSTextField { label }
}
