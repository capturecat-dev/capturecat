import AppKit

/// Wizard / carousel progress — a row of dots where the CURRENT step
/// stretches into an accent capsule. Moving the index springs every dot to
/// its new geometry at once, so the capsule reads as one liquid shape
/// flowing between positions; completed steps keep a brighter ink than the
/// steps still ahead.
///
///     let steps = CCStepIndicator(count: 5)
///     steps.index = 2                      // springs
///     steps.onSelect = { i in goBack(to: i) } // completed dots are clickable
@MainActor
final class CCStepIndicator: NSView {
    var onSelect: ((Int) -> Void)?

    let count: Int

    var index: Int {
        didSet {
            index = min(max(index, 0), max(count - 1, 0))
            guard index != oldValue else { return }
            layoutDots(animated: window != nil)
            applyTheme(animated: window != nil)
        }
    }

    static let dotSide: CGFloat = 7
    static let activeWidth: CGFloat = 24
    static let spacing: CGFloat = 7

    private var dots: [CALayer] = []
    private var themeObservation: CCThemeObservation?

    override var intrinsicContentSize: NSSize {
        let width = CGFloat(max(count - 1, 0)) * (Self.dotSide + Self.spacing) + Self.activeWidth
        // Taller than the dots: the whole row is a comfortable click target.
        return NSSize(width: width, height: 16)
    }

    override var isFlipped: Bool { false }

    init(count: Int, index: Int = 0) {
        self.count = max(count, 1)
        self.index = min(max(index, 0), max(count - 1, 0))
        super.init(frame: .zero)
        wantsLayer = true
        for _ in 0..<self.count {
            let dot = CALayer()
            dot.cornerCurve = .continuous
            dot.cornerRadius = Self.dotSide / 2
            dot.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer?.addSublayer(dot)
            dots.append(dot)
        }
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme(animated: false) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        // Never clobber an in-flight spring from a stray layout pass — the
        // model values already ARE the targets.
        if dots.allSatisfy({ $0.animation(forKey: "capmotion.bounds") == nil }) {
            layoutDots(animated: false)
        }
    }

    private func frames() -> [CGRect] {
        var x = (bounds.width - intrinsicContentSize.width) / 2
        let y = (bounds.height - Self.dotSide) / 2
        return (0..<count).map { i in
            let width = i == index ? Self.activeWidth : Self.dotSide
            defer { x += width + Self.spacing }
            return CGRect(x: x, y: y, width: width, height: Self.dotSide)
        }
    }

    private func layoutDots(animated: Bool) {
        for (dot, frame) in zip(dots, frames()) {
            let bounds = CGRect(origin: .zero, size: frame.size)
            let position = CGPoint(x: frame.midX, y: frame.midY)
            if animated {
                CCMotion.spring(dot, keyPath: "bounds", to: NSValue(rect: bounds), .smooth)
                CCMotion.spring(dot, keyPath: "position", to: NSValue(point: position), .smooth)
            } else {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                dot.bounds = bounds
                dot.position = position
                CATransaction.commit()
            }
        }
    }

    private func applyTheme(animated: Bool) {
        let colors = CCTheme.color
        let ink: NSColor = CCTheme.isDark ? .white : .black
        for (i, dot) in dots.enumerated() {
            let color: NSColor = i == index ? colors.primary
                : i < index ? ink.withAlphaComponent(0.42)
                : ink.withAlphaComponent(0.16)
            if animated {
                CCMotion.fade(dot, keyPath: "backgroundColor", to: color.cgColor, duration: 0.24)
            } else {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                dot.backgroundColor = color.cgColor
                CATransaction.commit()
            }
        }
    }

    // Completed steps are clickable — the usual "jump back" affordance.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point), let hit = hitDot(at: point), hit < index else { return }
        onSelect?(hit)
    }

    private func hitDot(at point: CGPoint) -> Int? {
        // Each dot claims half the gap on either side (gap-tolerant hits,
        // the glide-highlight lesson).
        for (i, frame) in frames().enumerated()
        where point.x >= frame.minX - Self.spacing / 2 && point.x <= frame.maxX + Self.spacing / 2 {
            return i
        }
        return nil
    }

    // MARK: - Harness seams

    /// The capsule for the current step (read `presentation()` mid-spring).
    var probeActiveDot: CALayer { dots[index] }
    func probeDot(_ i: Int) -> CALayer { dots[i] }
}
