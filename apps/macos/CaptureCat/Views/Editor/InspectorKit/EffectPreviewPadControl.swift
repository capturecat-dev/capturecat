import AppKit

/// Live preview pad for an effect's motion — a miniature card animating on a
/// loop inside the pad, driven by the SAME math the preview and exporter use
/// (IntroSlideMath for slides, the zoom spring constants for block styles).
/// The pad is display-only chrome, like the cursor's spring pad: it shows the
/// FEEL of the current parameters and updates the instant they change.
@MainActor
final class EffectPreviewPadControl: NSView {
    enum Mode {
        /// Slide entrance: direction, duration, bounce, 3D depth pull.
        case slide(style: IntroSlideStyle, duration: Double, bounce: Double, depth: Bool)
        /// Zoom block push-in with a style's spring (omega multiplier, zeta).
        case zoom(level: Double, omegaMultiplier: Double, damping: Double)
    }

    var mode: Mode = .slide(style: .bottom, duration: 0.9, bounce: 0.5, depth: false) {
        didSet { restartLoop() }
    }

    private let cardLayer = CALayer()
    private var timer: Timer?
    private var loopStart: CFTimeInterval = 0
    private var themeObservation: CCThemeObservation?
    /// Spring state for zoom mode (re-integrated each loop).
    private var spring = InspectorPreviewMath.ZoomSpring()
    private var lastTick: CFTimeInterval = 0

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 96) }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = EditorThemeKit.controlRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.masksToBounds = true

        cardLayer.backgroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
        cardLayer.cornerRadius = 3
        cardLayer.cornerCurve = .continuous
        layer?.addSublayer(cardLayer)

        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Pad chrome only — the mini card mimics exported footage and keeps its
    /// fixed color in both themes.
    private func applyTheme() {
        layer?.backgroundColor = EditorThemeKit.panelElevated.cgColor
        layer?.borderColor = EditorThemeKit.hairline.cgColor
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            timer?.invalidate()
            timer = nil
        } else {
            restartLoop()
        }
    }

    override func layout() {
        super.layout()
        tick()
    }

    private func restartLoop() {
        loopStart = CACurrentMediaTime()
        lastTick = loopStart
        spring = InspectorPreviewMath.ZoomSpring()
        if timer == nil, window != nil {
            let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self,
                          self.window?.occlusionState.contains(.visible) == true,
                          !self.isHiddenOrHasHiddenAncestor else { return }
                    self.tick()
                }
            }
            timer = t
            RunLoop.main.add(t, forMode: .common)
        }
    }

    private func tick() {
        guard bounds.width > 0 else { return }
        let now = CACurrentMediaTime()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The maths: InspectorPreviewMath (shared with the iOS preview rows).
        switch mode {
        case .slide(let style, let duration, let bounce, let depth):
            let f = InspectorPreviewMath.slide(elapsed: now - loopStart, size: bounds.size, style: style,
                                               duration: duration, bounce: bounce, depth: depth)
            cardLayer.bounds = CGRect(origin: .zero, size: f.cardSize)
            cardLayer.position = f.center
            // A small perspective tip conveys the depth pull in the mini pad.
            var transform = CATransform3DIdentity
            if f.pitch != 0 {
                transform.m34 = InspectorPreviewMath.slidePerspective
                transform = CATransform3DRotate(transform, CGFloat(f.pitch * .pi / 180), 1, 0, 0)
            }
            transform = CATransform3DScale(transform, f.scale, f.scale, 1)
            cardLayer.transform = transform

        case .zoom(let level, let omegaMultiplier, let damping):
            cardLayer.bounds = CGRect(origin: .zero, size: InspectorPreviewMath.zoomCardSize(bounds.size))
            let s = spring.step(elapsed: now - loopStart, dt: now - lastTick, level: level,
                                omegaMultiplier: omegaMultiplier, damping: damping)
            cardLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
            cardLayer.transform = CATransform3DMakeScale(s, s, 1)
        }
        CATransaction.commit()
        lastTick = now
    }

    #if DEBUG
    /// Harness seam: what the pad shows, in the shared vocabulary.
    var probeMode: InspectorPreviewMath.Mode {
        switch mode {
        case .slide(let style, let duration, let bounce, let depth):
            return .slide(style: style, duration: duration, bounce: bounce, depth: depth)
        case .zoom(let level, let omega, let damping):
            return .zoom(level: level, omegaMultiplier: omega, damping: damping)
        }
    }
    #endif
}
