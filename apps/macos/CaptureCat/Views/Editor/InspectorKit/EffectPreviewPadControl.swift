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
    private var springZoom = 1.0
    private var springVel = 0.0
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
        springZoom = 1
        springVel = 0
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
        let cardSize = CGSize(width: bounds.width * 0.42, height: bounds.height * 0.52)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cardLayer.bounds = CGRect(origin: .zero, size: cardSize)

        switch mode {
        case .slide(let style, let duration, let bounce, let depth):
            // Replay [pre-roll 0.2s][slide][hold 0.8s] on a loop, through the
            // real curve.
            let cycle = 0.2 + duration + 0.8
            let t = (now - loopStart).truncatingRemainder(dividingBy: cycle) - 0.2
            let state = IntroSlideMath.state(
                style: style, at: max(t, -0.001), duration: duration,
                bounce: bounce, depth: depth)
            // travel is in canvas fractions; the pad is the canvas here.
            let clamped = CGPoint(
                x: max(-1.2, min(1.2, state.offset.x)),
                y: max(-1.2, min(1.2, state.offset.y)))
            cardLayer.position = CGPoint(
                x: center.x + clamped.x * bounds.width,
                y: center.y + clamped.y * bounds.height)
            let s = t < 0
                ? (depth ? IntroSlideMath.depthStartScale : IntroSlideMath.startScale)
                : state.scale
            // A small perspective tip conveys the depth pull in the mini pad.
            var transform = CATransform3DIdentity
            if abs(state.pitch) > 0.01 {
                transform.m34 = -1.0 / 640
                transform = CATransform3DRotate(
                    transform, CGFloat(state.pitch * .pi / 180), 1, 0, 0)
            }
            transform = CATransform3DScale(transform, s, s, 1)
            cardLayer.transform = transform

        case .zoom(let level, let omegaMultiplier, let damping):
            // Push in, hold, release — the block spring at inspector scale.
            let cycle = 3.2
            let phase = (now - loopStart).truncatingRemainder(dividingBy: cycle)
            let target = phase < 1.6 ? max(0.3, min(2.2, level)) : 1.0
            let dt = min(0.05, now - lastTick)
            let omega = 2.5 / 0.8 * omegaMultiplier
            let acc = omega * omega * (target - springZoom)
                    - 2 * damping * omega * springVel
            springVel += acc * dt
            springZoom += springVel * dt
            cardLayer.position = center
            // Map zoom around 1 into a visible pad scale.
            let s = CGFloat(0.55 + (springZoom - 1) * 0.35)
            cardLayer.transform = CATransform3DMakeScale(s, s, 1)
        }
        CATransaction.commit()
        lastTick = now
    }
}
