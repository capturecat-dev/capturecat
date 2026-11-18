import UIKit

/// The Effects and Motion panes' LIVE preview pads — the Mac's
/// EffectPreviewPadControl (Slide, the zoom block), PropertyPreviewPadControl
/// (Parallax, Motion Blur, the Highlight dim) and MotionSpeedPadControl (the
/// Motion tab's speed): a mini card looping inside the house preview well,
/// showing the FEEL of the current settings and following them the instant
/// they change. Every position, scale, tip and smear comes from the shared
/// `InspectorPreviewMath` (the Mac pads' own maths, moved there) — this view
/// only draws it, on the display's frames.
///
/// Display-only, like the Mac's: no touch, hidden from VoiceOver. Under
/// Reduce Motion the loop holds one telling frame instead of moving.
@MainActor
final class InspectorLivePreviewRow: InspectorCustomRow {
    static let ids: Set<String> = [
        "effects.slidePad", "effects.parallaxPad", "effects.motionBlurPad",
        "blocks.zoomPreviewPad", "blocks.highlightPad", "motion.speedPad",
    ]

    private let well = CCPreviewPad(showsGridDots: false)
    private let card = CALayer()
    private let dim = CALayer()
    private let trails = (0..<InspectorPreviewMath.MotionBlurFrame.trailCount).map { _ in CALayer() }
    /// The Motion tab's mini window: traffic lights + text lines (the Mac
    /// MotionSpeedPadControl's), ink-tinted.
    private var windowContent: [CALayer] = []
    private static let windowAlphas: [CGFloat] = [0.28, 0.28, 0.28, 0.28, 0.16, 0.16]
    private var link: CADisplayLink?
    private var loopStart = CACurrentMediaTime()
    private var lastTick = CACurrentMediaTime()
    private var spring = InspectorPreviewMath.ZoomSpring()
    private(set) var mode: InspectorPreviewMath.Mode?
    #if DEBUG
    /// Frames drawn (the harness asserts the loop runs).
    private(set) var probeTicks = 0
    #endif

    init(id: String, visible: @escaping (InspectorScope) -> Bool, host: InspectorHost) {
        super.init(id: id, visible: visible, host: host)
        let wellHeight: CGFloat = id == "motion.speedPad" ? 84 : 96
        well.ccInspectorHeight(wellHeight, compact: InspectorPadSize.compact(wellHeight))
        well.clipsToBounds = true
        addSubview(well)
        pinEdges(well, to: self)
        dim.backgroundColor = UIColor.black.withAlphaComponent(0.6).cgColor
        well.layer.addSublayer(dim)
        for trail in trails {
            trail.backgroundColor = UIColor.white.withAlphaComponent(0.9).cgColor
            trail.cornerRadius = 4
            well.layer.addSublayer(trail)
        }
        card.backgroundColor = UIColor.white.withAlphaComponent(0.9).cgColor
        card.cornerRadius = 3
        card.cornerCurve = .continuous
        well.layer.addSublayer(card)
        if id == "motion.speedPad" {
            for i in 0..<3 {
                let dot = CALayer()
                dot.frame = CGRect(x: 8 + CGFloat(i) * 7, y: 8, width: 4, height: 4)
                dot.cornerRadius = 2
                card.addSublayer(dot)
                windowContent.append(dot)
            }
            for (i, width) in [30, 46, 38].enumerated() {
                let line = CALayer()
                line.cornerRadius = 1.5
                line.frame = CGRect(x: 8, y: 18 + CGFloat(i) * 7.5, width: CGFloat(width), height: 3.5)
                card.addSublayer(line)
                windowContent.append(line)
            }
        }
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        accessibilityIdentifier = id
        ccOnThemeChange { [weak self] in self?.applyTheme() }
        applyTheme()
    }

    /// Only the Motion tab's window is ink (chrome); the other cards mimic
    /// footage and keep their colour in both themes (the Mac's rule).
    private func applyTheme() {
        guard !windowContent.isEmpty else { return }
        let ink: UIColor = CCTheme.isDark(traitCollection) ? .white : .black
        card.backgroundColor = ink.withAlphaComponent(0.10).cgColor
        for (layer, alpha) in zip(windowContent, Self.windowAlphas) {
            layer.backgroundColor = ink.withAlphaComponent(alpha).cgColor
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    #if DEBUG
    var probeMode: InspectorPreviewMath.Mode? { mode }
    /// The mini card as drawn now (motion probes sample it twice).
    var probeCardSignature: String {
        let t = card.transform
        return String(format: "%.2f,%.2f,%.3f,%.3f,%.3f", card.position.x, card.position.y, t.m11, t.m22, t.m24 + t.m34)
    }
    #endif

    override func refresh(_ scope: InspectorScope) {
        let next = InspectorPreviewMath.mode(for: rowID, scope)
        guard next != mode else { return }
        // The Mac pads restart the slide / zoom loop on a change (so the new
        // feel plays from its start) and keep the property loops' phase.
        switch next {
        case .slide?, .zoom?:
            loopStart = CACurrentMediaTime()
            spring = InspectorPreviewMath.ZoomSpring()
        default:
            break
        }
        mode = next
        tick()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            link?.invalidate()
            link = nil
        } else if link == nil {
            let link = CADisplayLink(target: self, selector: #selector(step))
            link.add(to: .main, forMode: .common)
            self.link = link
            lastTick = CACurrentMediaTime()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        tick()
    }

    @objc private func step() {
        // Off screen or hidden (a panel showing another option): idle.
        guard window != nil, !isHiddenOrHasHiddenAncestor else { lastTick = CACurrentMediaTime(); return }
        tick()
    }

    private var isHiddenOrHasHiddenAncestor: Bool {
        var v: UIView? = self
        while let current = v {
            if current.isHidden || current.alpha < 0.01 { return true }
            v = current.superview
        }
        return false
    }

    /// One frame: Reduce Motion holds a telling one (mid-move).
    private func tick() {
        let size = well.bounds.size
        guard size.width > 1, let mode else { return }
        let now = CACurrentMediaTime()
        let still = CCMotion.reduceMotion
        let elapsed = still ? stillElapsed(mode) : now - loopStart
        #if DEBUG
        probeTicks += 1
        #endif
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dim.isHidden = true
        for trail in trails { trail.isHidden = true }
        card.isHidden = false
        card.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        card.cornerRadius = 3
        card.zPosition = 0
        switch mode {
        case .slide(let style, let duration, let bounce, let depth):
            let f = InspectorPreviewMath.slide(elapsed: elapsed, size: size, style: style, duration: duration,
                                               bounce: bounce, depth: depth)
            card.bounds = CGRect(origin: .zero, size: f.cardSize)
            card.position = f.center
            var t = CATransform3DIdentity
            if f.pitch != 0 {
                t.m34 = InspectorPreviewMath.slidePerspective
                t = CATransform3DRotate(t, CGFloat(f.pitch * .pi / 180), 1, 0, 0)
            }
            card.transform = CATransform3DScale(t, f.scale, f.scale, 1)
        case .zoom(let level, let omega, let damping):
            card.bounds = CGRect(origin: .zero, size: InspectorPreviewMath.zoomCardSize(size))
            let s: CGFloat
            if still {
                var settled = InspectorPreviewMath.ZoomSpring()
                settled.zoom = max(0.3, min(2.2, level))
                s = settled.scale
            } else {
                s = spring.step(elapsed: elapsed, dt: now - lastTick, level: level, omegaMultiplier: omega, damping: damping)
            }
            card.position = CGPoint(x: size.width / 2, y: size.height / 2)
            card.transform = CATransform3DMakeScale(s, s, 1)
        case .parallax(let strength):
            let f = InspectorPreviewMath.parallax(elapsed: elapsed, size: size, strength: strength)
            for (trail, mark) in zip(trails.prefix(3), f.marks) {
                trail.isHidden = false
                trail.backgroundColor = UIColor.white.withAlphaComponent(0.3).cgColor
                trail.cornerRadius = 2
                trail.frame = mark
            }
            card.bounds = CGRect(origin: .zero, size: f.cardSize)
            card.position = f.center
            card.transform = CATransform3DMakeScale(f.zoom, f.zoom, 1)
        case .motionBlur(let on, let strength):
            let f = InspectorPreviewMath.motionBlur(elapsed: elapsed, size: size, on: on, strength: strength)
            let dot = InspectorPreviewMath.MotionBlurFrame.dotSize
            for (trail, smear) in zip(trails, f.trail) {
                trail.isHidden = false
                trail.backgroundColor = UIColor.white.withAlphaComponent(smear.alpha).cgColor
                trail.cornerRadius = dot / 2
                trail.frame = smear.frame
            }
            card.transform = CATransform3DMakeScale(f.stretch, 1, 1)
            card.bounds = CGRect(origin: .zero, size: CGSize(width: dot, height: dot))
            card.cornerRadius = dot / 2
            card.position = f.center
        case .highlightMask(let opacity):
            dim.isHidden = false
            dim.frame = CGRect(origin: .zero, size: size)
            dim.backgroundColor = UIColor.black.withAlphaComponent(opacity).cgColor
            let hole = InspectorPreviewMath.highlightHole(size: size)
            card.transform = CATransform3DIdentity
            card.bounds = CGRect(origin: .zero, size: hole.size)
            card.position = CGPoint(x: hole.midX, y: hole.midY)
            card.cornerRadius = 4
            card.zPosition = 1
        case .motionSpeed(let duration):
            let f = InspectorPreviewMath.motionSpeed(elapsed: elapsed, size: size, duration: duration)
            card.transform = CATransform3DIdentity
            card.bounds = CGRect(origin: .zero, size: f.cardSize)
            card.anchorPoint = f.anchor
            card.position = f.position
            card.cornerRadius = 5
            card.transform = CATransform3DMakeScale(f.zoom, f.zoom, 1)
        case .frameStyle:
            break
        }
        CATransaction.commit()
        lastTick = now
    }

    /// The frame Reduce Motion holds: the effect caught mid-move.
    private func stillElapsed(_ mode: InspectorPreviewMath.Mode) -> Double {
        switch mode {
        case .slide(_, let duration, _, _): return 0.2 + duration * 0.35
        case .parallax: return 1.3
        case .motionBlur: return 2.6 / 4
        case .motionSpeed(let duration): return 0.2 + max(0.2, duration) * 0.6
        default: return 0
        }
    }
}
