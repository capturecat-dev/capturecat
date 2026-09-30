import AppKit

/// CCKit skeleton — shadcn's Skeleton: recessed placeholder wells that
/// breathe with shadcn's opacity pulse (1 → 0.5 → 1 over 2s, `animate-pulse`
/// curve). No shimmer sweep — the house language has no sheen. Every
/// skeleton pulses on the SAME absolute phase, so a screenful of them
/// breathes in unison instead of flickering out of step.
///
///     let avatar = CCSkeleton(.circle(diameter: 40))
///     let text = CCSkeleton.lines(3)                 // last line shorter
///     let loading = CCSkeletonReveal(placeholder: text, content: realView)
///     loading.reveal()                               // crossfade when data lands
@MainActor
final class CCSkeleton: NSView {
    enum Shape {
        /// A text line: full width of its column, `height` tall.
        case line(height: CGFloat = 12)
        /// A block (image/card placeholder): full width, `height` tall.
        case block(height: CGFloat)
        case circle(diameter: CGFloat)

        var radius: CCRadius {
            switch self {
            case .line: return .sm
            case .block: return .lg
            case .circle: return .full
            }
        }
    }

    /// shadcn's animate-pulse period.
    static let pulsePeriod: CFTimeInterval = 2

    let shape: Shape
    private var themeObservation: CCThemeObservation?

    override var intrinsicContentSize: NSSize {
        switch shape {
        case .line(let height): return NSSize(width: NSView.noIntrinsicMetric, height: height)
        case .block(let height): return NSSize(width: NSView.noIntrinsicMetric, height: height)
        case .circle(let diameter): return NSSize(width: diameter, height: diameter)
        }
    }

    init(_ shape: Shape) {
        self.shape = shape
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        let size = intrinsicContentSize
        heightAnchor.constraint(equalToConstant: size.height).isActive = true
        if case .circle = shape {
            widthAnchor.constraint(equalToConstant: size.width).isActive = true
        }
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// A paragraph placeholder: `count` lines, the last one `lastFraction`
    /// of the width (like the ragged end of real text).
    static func lines(_ count: Int, lineHeight: CGFloat = 12, spacing: CGFloat = 8,
                      lastFraction: CGFloat = 0.62) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        for index in 0..<max(count, 1) {
            let line = CCSkeleton(.line(height: lineHeight))
            stack.addArrangedSubview(line)
            let fraction = index == count - 1 && count > 1 ? lastFraction : 1
            line.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: fraction).isActive = true
        }
        return stack
    }

    private var radius: CGFloat { shape.radius.resolved(for: bounds.height) }

    override func layout() {
        super.layout()
        layer?.cornerRadius = radius
        if let layer { CCMaterial.refit(layer, radius: radius) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window == nil ? layer?.removeAnimation(forKey: "ccskeleton.pulse") : startPulse()
    }

    private func applyTheme() {
        guard let layer else { return }
        let colors = CCTheme.color
        // Placeholders are holes the content will fill: recessed wells a
        // step brighter (dark) / darker (light) than the elevated tone —
        // elevated alone vanished against dark surfaces. Opaque by
        // construction (translucent fills are never dressed).
        let ink: NSColor = CCTheme.isDark ? .white : .black
        let fill = colors.elevated.blended(withFraction: CCTheme.isDark ? 0.08 : 0.035, of: ink)
            ?? colors.elevated
        layer.backgroundColor = fill.cgColor
        CCMaterial.dress(layer, as: .recessed(tint: fill), radius: radius)
    }

    private func startPulse() {
        guard let layer, layer.animation(forKey: "ccskeleton.pulse") == nil else { return }
        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        pulse.values = [1.0, 0.5, 1.0]
        pulse.keyTimes = [0, 0.5, 1]
        // Tailwind's animate-pulse curve: cubic-bezier(0.4, 0, 0.6, 1).
        let curve = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.6, 1)
        pulse.timingFunctions = [curve, curve]
        pulse.duration = Self.pulsePeriod
        pulse.repeatCount = .infinity
        // Phase-lock to absolute time so every skeleton breathes together.
        let now = layer.convertTime(CACurrentMediaTime(), from: nil)
        pulse.beginTime = now - fmod(CACurrentMediaTime(), Self.pulsePeriod)
        pulse.isRemovedOnCompletion = false
        layer.add(pulse, forKey: "ccskeleton.pulse")
    }

    // MARK: - Harness seams

    var probePulseOpacity: Float { (layer?.presentation() ?? layer)?.opacity ?? -1 }
}

/// Holds a skeleton placeholder and the real content in the same slot;
/// `reveal()` crossfades placeholder → content while the slot's bottom edge
/// glides to the content's height (growth lands on the house bounce).
///
///     let slot = CCSkeletonReveal(placeholder: CCSkeleton.lines(3), content: bio)
///     api.load { bio.stringValue = $0; slot.reveal() }
@MainActor
final class CCSkeletonReveal: NSView {
    let placeholder: NSView
    let content: NSView
    private(set) var isRevealed = false
    private var height: NSLayoutConstraint!

    init(placeholder: NSView, content: NSView) {
        self.placeholder = placeholder
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        for view in [placeholder, content] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.wantsLayer = true
            addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: topAnchor),
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }
        content.isHidden = true
        height = heightAnchor.constraint(equalToConstant: 0)
        height.isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var shown: NSView { isRevealed ? content : placeholder }

    override func layout() {
        super.layout()
        guard !CCMotion.isAnimating(height) else { return }
        let target = shown.frame.height
        if abs(height.constant - target) > 0.5 { height.constant = target }
    }

    /// Crossfade to the content (or back to the placeholder for a reload).
    func reveal(_ revealed: Bool = true) {
        guard revealed != isRevealed else { return }
        layoutSubtreeIfNeeded()
        isRevealed = revealed
        let incoming = revealed ? content : placeholder
        let outgoing = revealed ? placeholder : content
        incoming.isHidden = false
        layoutSubtreeIfNeeded()
        guard window != nil else {
            outgoing.isHidden = true
            needsLayout = true
            return
        }
        CCMotion.fadeAlpha(outgoing, to: 0, duration: 0.18)
        CCMotion.fadeAlpha(incoming, to: 1, duration: 0.28, delay: 0.06, from: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + CCMotion.paced(0.26)) { [weak self, weak outgoing] in
            guard let self, let outgoing, outgoing !== self.shown else { return }
            outgoing.isHidden = true
            outgoing.alphaValue = 1
        }
        let target = incoming.frame.height
        let growing = target > height.constant
        CCMotion.animate(height, to: target, in: window?.contentView,
                         duration: growing ? 0.4 : 0.28,
                         curve: growing ? CCMotion.bouncePoints : CCMotion.glidePoints)
    }
}
