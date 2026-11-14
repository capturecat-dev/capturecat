import UIKit

// CCKit motion — one vocabulary of Apple-feel animation (port of the Mac's
// CCMotion). Curves for UIView/constraint work (`settle` = the house ease-out
// with the long tail, `glide` = symmetric, `bounce` = growth with a ~10%
// overshoot) and springs (CASpringAnimation from SwiftUI-style response +
// damping) for layer properties.
//
// Laws: growth lands on the bounce and ONLY the pushed edge moves; press
// tints in place (never travels or scales); animation is curve-true — use
// `animate(constraint…)` for in-layout growth (a CADisplayLink driver that
// re-lays-out every frame, so dressed materials refit in lockstep).
enum CCMotion {
    // MARK: - Pace

    /// One knob for how fast the whole kit moves. Probes assume `.standard`.
    enum Pace: CGFloat {
        case relaxed = 0.7
        case standard = 1.0
        case brisk = 1.45
    }

    static var pace: Pace = .standard

    static func paced(_ duration: TimeInterval) -> TimeInterval { duration / Double(pace.rawValue) }

    #if DEBUG
    /// Probe seam — INJECTED DEFECT: springs land instantly (a snapped
    /// animation). The motion probe flips this to prove its mid-flight
    /// assertion can fail.
    static var probeSnap = false
    #endif

    private static func snapped(_ layer: CALayer, keyPath: String, to value: Any?) -> Bool {
        #if DEBUG
        guard probeSnap else { return false }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: "ccmotion.\(keyPath)")
        layer.setValue(value, forKeyPath: keyPath)
        CATransaction.commit()
        return true
        #else
        return false
        #endif
    }

    /// Reduce Motion: entrances become fades, springs land without travel.
    static var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    // MARK: - Curves

    struct Curve {
        let p1: CGPoint
        let p2: CGPoint
        var timingFunction: CAMediaTimingFunction {
            CAMediaTimingFunction(controlPoints: Float(p1.x), Float(p1.y), Float(p2.x), Float(p2.y))
        }
        var points: (CGFloat, CGFloat, CGFloat, CGFloat) { (p1.x, p1.y, p2.x, p2.y) }

        /// The house curve — fast start, long soft tail.
        static let settle = Curve(p1: CGPoint(x: 0.22, y: 1.0), p2: CGPoint(x: 0.36, y: 1.0))
        /// Symmetric ease for reversible state (washes, color fades).
        static let glide = Curve(p1: CGPoint(x: 0.4, y: 0.0), p2: CGPoint(x: 0.2, y: 1.0))
        /// Growth — settle with a soft overshoot (~10%).
        static let bounce = Curve(p1: CGPoint(x: 0.34, y: 1.56), p2: CGPoint(x: 0.64, y: 1.0))
    }

    static var settle: CAMediaTimingFunction { Curve.settle.timingFunction }
    static var glide: CAMediaTimingFunction { Curve.glide.timingFunction }
    static var bounce: CAMediaTimingFunction { Curve.bounce.timingFunction }

    /// Animate UIView-animatable changes on a house curve.
    static func run(
        duration: TimeInterval = 0.35,
        curve: Curve = .settle,
        delay: TimeInterval = 0,
        _ animations: @escaping () -> Void,
        completion: (() -> Void)? = nil
    ) {
        let animator = UIViewPropertyAnimator(
            duration: paced(duration),
            timingParameters: UICubicTimingParameters(controlPoint1: curve.p1, controlPoint2: curve.p2)
        )
        animator.isInterruptible = true
        animator.addAnimations(animations)
        animator.addCompletion { _ in completion?() }
        animator.startAnimation(afterDelay: paced(delay))
    }

    /// Short variant for press/state feedback.
    static func quick(_ animations: @escaping () -> Void, completion: (() -> Void)? = nil) {
        run(duration: 0.16, curve: .glide, animations, completion: completion)
    }

    /// UIView spring on the house spring vocabulary.
    static func springViews(
        _ spring: Spring = .smooth,
        delay: TimeInterval = 0,
        _ animations: @escaping () -> Void,
        completion: (() -> Void)? = nil
    ) {
        UIView.animate(
            springDuration: spring.response / pace.rawValue,
            bounce: max(0, 1 - spring.dampingRatio),
            initialSpringVelocity: 0,
            delay: paced(delay),
            options: [.allowUserInteraction, .beginFromCurrentState],
            animations: animations,
            completion: { _ in completion?() }
        )
    }

    // MARK: - Springs

    enum Spring {
        /// UI acknowledgement — fast, barely any bounce.
        case snappy
        /// Standard movement — a smooth glide between states.
        case smooth
        /// Playful — visible overshoot (pops).
        case bouncy
        /// Floating-surface ARRIVAL (sheets, menus): quick, slight overshoot.
        case arrive

        var response: CGFloat {
            switch self {
            case .snappy: return 0.28
            case .smooth: return 0.42
            case .bouncy: return 0.42
            case .arrive: return 0.3
            }
        }

        var dampingRatio: CGFloat {
            switch self {
            case .snappy: return 0.9
            case .smooth: return 1.0
            case .bouncy: return 0.68
            case .arrive: return 0.72
            }
        }
    }

    static func springAnimation(keyPath: String, _ spring: Spring = .smooth) -> CASpringAnimation {
        let animation = CASpringAnimation(keyPath: keyPath)
        let mass: CGFloat = 1
        let stiffness = pow(2 * .pi / (spring.response / pace.rawValue), 2) * mass
        animation.mass = mass
        animation.stiffness = stiffness
        animation.damping = 2 * spring.dampingRatio * sqrt(stiffness * mass)
        animation.duration = animation.settlingDuration
        return animation
    }

    /// Spring one key path from where it visibly IS to `value` (and set the
    /// model value) — retargeting mid-flight is seamless.
    static func spring(_ layer: CALayer, keyPath: String, to value: Any?, _ spring: Spring = .smooth) {
        if snapped(layer, keyPath: keyPath, to: value) { return }
        let animation = springAnimation(keyPath: keyPath, spring)
        animation.fromValue = layer.presentation()?.value(forKeyPath: keyPath) ?? layer.value(forKeyPath: keyPath)
        animation.toValue = value
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(value, forKeyPath: keyPath)
        CATransaction.commit()
        layer.add(animation, forKey: "ccmotion.\(keyPath)")
    }

    /// Spring from an explicit START (entrances), optionally delayed — the
    /// delayed animation holds its start value until it begins (staggers).
    static func spring(_ layer: CALayer, keyPath: String, from: Any?, to value: Any?, _ spring: Spring = .smooth, delay: TimeInterval = 0) {
        if snapped(layer, keyPath: keyPath, to: value) { return }
        let animation = springAnimation(keyPath: keyPath, spring)
        animation.fromValue = from
        animation.toValue = value
        if delay > 0 {
            animation.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + paced(delay)
            animation.fillMode = .backwards
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(value, forKeyPath: keyPath)
        CATransaction.commit()
        layer.add(animation, forKey: "ccmotion.\(keyPath)")
    }

    /// Cross-fade one layer property (backgroundColor, borderColor, opacity…).
    static func fade(_ layer: CALayer, keyPath: String, to value: Any?, duration: TimeInterval = 0.16, delay: TimeInterval = 0, from: Any? = nil) {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from ?? layer.presentation()?.value(forKeyPath: keyPath) ?? layer.value(forKeyPath: keyPath)
        animation.toValue = value
        animation.duration = paced(duration)
        animation.timingFunction = glide
        if delay > 0 {
            animation.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + paced(delay)
            animation.fillMode = .backwards
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(value, forKeyPath: keyPath)
        CATransaction.commit()
        layer.add(animation, forKey: "ccmotion.fade.\(keyPath)")
    }

    /// Fade a VIEW's alpha on the glide curve (model + presentation).
    static func fadeAlpha(_ view: UIView, to alpha: CGFloat, duration: TimeInterval = 0.2, delay: TimeInterval = 0, from: CGFloat? = nil) {
        guard view.window != nil else { view.alpha = alpha; return }
        let start = from.map { Float($0) } ?? (view.layer.presentation() ?? view.layer).opacity
        view.alpha = alpha
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = start
        animation.toValue = Float(alpha)
        animation.duration = paced(duration)
        animation.timingFunction = glide
        if delay > 0 {
            animation.beginTime = view.layer.convertTime(CACurrentMediaTime(), from: nil) + paced(delay)
            animation.fillMode = .backwards
        }
        view.layer.add(animation, forKey: "ccmotion.alpha")
    }

    /// Small spring POP about the center (badges, counters, chips).
    static func pop(_ view: UIView, from scale: CGFloat = 0.86) {
        guard view.window != nil, !reduceMotion else { return }
        spring(view.layer, keyPath: "transform.scale", from: scale, to: 1.0, .bouncy)
    }

    /// Staggered arrival: each view fades in and RISES `distance` pt.
    static func stagger(_ views: [UIView], distance: CGFloat = 8, interval: TimeInterval = 0.05) {
        for (index, view) in views.enumerated() where view.window != nil {
            let delay = interval * Double(index)
            if !reduceMotion {
                spring(view.layer, keyPath: "transform.translation.y", from: distance, to: 0, .smooth, delay: delay)
            }
            fadeAlpha(view, to: 1, duration: 0.24, delay: delay, from: 0)
        }
    }

    /// FLIP: the frame lands now (hit-testing's truth) and the VISUAL springs
    /// there from wherever it visibly was.
    static func glide(_ view: UIView, to frame: CGRect, _ spring: Spring = .smooth) {
        guard view.window != nil, !reduceMotion else { view.frame = frame; return }
        let shown = view.layer.presentation() ?? view.layer
        let tx = (shown.value(forKeyPath: "transform.translation.x") as? CGFloat) ?? 0
        let ty = (shown.value(forKeyPath: "transform.translation.y") as? CGFloat) ?? 0
        let visual = CGPoint(x: view.frame.minX + tx, y: view.frame.minY + ty)
        view.frame = frame
        let dx = visual.x - frame.minX, dy = visual.y - frame.minY
        if abs(dx) > 0.1 { self.spring(view.layer, keyPath: "transform.translation.x", from: dx, to: 0, spring) }
        if abs(dy) > 0.1 { self.spring(view.layer, keyPath: "transform.translation.y", from: dy, to: 0, spring) }
    }

    // MARK: - Entrances

    /// HOW a surface arrives and leaves. Transform-only; callers own the fade.
    enum Entrance {
        /// Settle in from 96% scale — the house default.
        case scaleIn
        /// Rises into place from `distance` pt below.
        case slideUp(distance: CGFloat = 24)
        /// Drops into place from `distance` pt above.
        case slideDown(distance: CGFloat = 24)
        /// No transform (pair with a fade).
        case fade
    }

    static func enter(_ layer: CALayer, _ entrance: Entrance = .scaleIn) {
        guard !reduceMotion else { return }
        switch entrance {
        case .scaleIn:
            spring(layer, keyPath: "transform.scale", from: 0.96, to: 1.0, .arrive)
        case .slideUp(let distance):
            spring(layer, keyPath: "transform.translation.y", from: distance, to: 0, .smooth)
        case .slideDown(let distance):
            spring(layer, keyPath: "transform.translation.y", from: -distance, to: 0, .smooth)
        case .fade:
            break
        }
    }

    static func exit(_ layer: CALayer, _ entrance: Entrance = .scaleIn) {
        guard !reduceMotion else { return }
        switch entrance {
        case .scaleIn:
            spring(layer, keyPath: "transform.scale", to: 0.97, .snappy)
        case .slideUp(let distance):
            spring(layer, keyPath: "transform.translation.y", to: distance / 2, .snappy)
        case .slideDown(let distance):
            spring(layer, keyPath: "transform.translation.y", to: -distance / 2, .snappy)
        case .fade:
            break
        }
    }

    // MARK: - Constraints (in-layout growth, curve-true)

    private static var drivers: [ObjectIdentifier: CCDisplayDriver] = [:]

    /// Drive `constraint.constant` along the exact bezier, re-laying-out
    /// `root` every frame (dressed surfaces refit each tick — an implicit
    /// bounds animation would park the material at its final size). Defaults
    /// to the growth bounce. Unmounted views apply instantly.
    static func animate(
        _ constraint: NSLayoutConstraint,
        to target: CGFloat,
        in root: UIView?,
        duration: TimeInterval = 0.38,
        curve: Curve = .bounce,
        completion: (() -> Void)? = nil
    ) {
        let key = ObjectIdentifier(constraint)
        drivers[key]?.stop()
        drivers[key] = nil
        let start = constraint.constant
        guard let root, root.window != nil, abs(target - start) > 0.01, !reduceMotion else {
            constraint.constant = target
            root?.layoutIfNeeded()
            completion?()
            return
        }
        let points = curve.points
        let driver = CCDisplayDriver(duration: paced(duration)) { [weak constraint, weak root] t in
            guard let constraint else { return }
            constraint.constant = t >= 1 ? target : start + (target - start) * bezierY(t, points)
            root?.layoutIfNeeded()
        } completion: {
            drivers[key] = nil
            completion?()
        }
        drivers[key] = driver
        driver.start()
    }

    static func isAnimating(_ constraint: NSLayoutConstraint) -> Bool {
        drivers[ObjectIdentifier(constraint)] != nil
    }

    /// Cubic timing curve y at progress x (P0 = 0, P3 = 1; bisection).
    static func bezierY(_ x: CGFloat, _ p: (CGFloat, CGFloat, CGFloat, CGFloat)) -> CGFloat {
        guard x > 0 else { return 0 }
        guard x < 1 else { return 1 }
        func coord(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
            let u = 1 - t
            return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
        }
        var lo: CGFloat = 0, hi: CGFloat = 1, t = x
        for _ in 0..<24 {
            let cx = coord(p.0, p.2, t)
            if abs(cx - x) < 0.0005 { break }
            if cx < x { lo = t } else { hi = t }
            t = (lo + hi) / 2
        }
        return coord(p.1, p.3, t)
    }
}

/// A CADisplayLink-driven 0→1 clock (extension-safe).
final class CCDisplayDriver: NSObject {
    private var link: CADisplayLink?
    private let duration: TimeInterval
    private let tick: (CGFloat) -> Void
    private let completion: () -> Void
    private var began: CFTimeInterval = 0

    init(duration: TimeInterval, tick: @escaping (CGFloat) -> Void, completion: @escaping () -> Void) {
        self.duration = max(duration, 0.001)
        self.tick = tick
        self.completion = completion
    }

    func start() {
        began = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func step() {
        let t = CGFloat(min(1, (CACurrentMediaTime() - began) / duration))
        tick(t)
        if t >= 1 {
            stop()
            completion()
        }
    }
}
