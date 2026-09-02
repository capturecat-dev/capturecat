import AppKit

// CCKit motion — one vocabulary of Apple-feel animation for every control.
//
// Two families:
//  • Curves (bezier) for NSAnimationContext-driven work: constraints, frames,
//    alpha. `easeOutQuint` is the Keynote "settle" — fast start, long soft tail.
//  • Springs (CASpringAnimation) for layer properties where a bit of physical
//    overshoot reads as alive: toggle thumbs, knobs, press scale.

@MainActor
enum CCMotion {
    // MARK: - Pace

    /// One knob for how fast the whole kit moves — the motion counterpart of
    /// a theme token. Scales EVERY CCMotion duration and spring response, so
    /// hover washes, glides, dialog springs and fades all shift together:
    ///
    ///     CCMotion.pace = .brisk      // snappier everything
    ///
    /// `.standard` is the shipped feel; probes assert mid-flight timings
    /// against it, so harnesses must not change it.
    enum Pace: CGFloat, CaseIterable {
        /// Slower, showier — presentation/demo feel.
        case relaxed = 0.7
        /// The house feel.
        case standard = 1.0
        /// Snappier — power-user feel.
        case brisk = 1.45
    }

    static var pace: Pace = .standard

    /// Divide a standard-pace duration by the current pace.
    static func paced(_ duration: TimeInterval) -> TimeInterval {
        duration / Double(pace.rawValue)
    }

    // MARK: - Curves

    /// The house curve — Keynote-style ease-out with a long tail.
    static let settle = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
    /// Symmetric ease for reversible state (hover washes, color fades).
    static let glide = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 0.2, 1.0)
    /// Growth curve — settle with a soft spring overshoot (~10%): expanding
    /// content lands with a gentle bounce instead of a flat stop. The y > 1
    /// control point is what makes a bezier overshoot. NOTE: window-frame
    /// animators IGNORE timing functions — animate window frames through
    /// `animateFrame(of:to:)` below, never `window.animator()`.
    static let bounce = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1.0)
    static let bouncePoints: (CGFloat, CGFloat, CGFloat, CGFloat) = (0.34, 1.56, 0.64, 1.0)
    static let glidePoints: (CGFloat, CGFloat, CGFloat, CGFloat) = (0.4, 0.0, 0.2, 1.0)

    /// Animate any implicitly-animatable change (constraints, alpha, colors)
    /// with the house curve. Wraps NSAnimationContext so call sites never
    /// hand-pick durations.
    static func run(
        duration: TimeInterval = 0.35,
        curve: CAMediaTimingFunction? = nil,
        _ changes: @escaping () -> Void,
        completion: (() -> Void)? = nil
    ) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = paced(duration)
            context.timingFunction = curve ?? settle
            context.allowsImplicitAnimation = true
            changes()
        }, completionHandler: completion.map { done in
            { DispatchQueue.main.async { done() } }
        })
    }

    /// Short variant for hover/press feedback.
    static func quick(_ changes: @escaping () -> Void) {
        run(duration: 0.16, curve: glide, changes)
    }

    /// Animate a control's size change through autolayout: call after
    /// `invalidateIntrinsicContentSize()` and the new width settles in on
    /// the house curve instead of snapping. No-ops (and stays instant) when
    /// the view isn't mounted yet, so init-time configuration never animates.
    static func animateLayout(
        _ view: NSView,
        duration: TimeInterval = 0.3,
        curve: CAMediaTimingFunction? = nil
    ) {
        guard view.window != nil, let superview = view.superview else { return }
        run(duration: duration, curve: curve) {
            superview.layoutSubtreeIfNeeded()
        }
    }

    /// Animate a GROWTH — expanding dialogs, revealed rows, widening titles —
    /// on the house bounce, so the new size lands with a soft spring instead
    /// of a flat stop. The shrink direction reads fine on the same curve (a
    /// slight tuck under the target), so callers don't need to branch.
    static func expand(_ view: NSView, duration: TimeInterval = 0.38) {
        animateLayout(view, duration: duration, curve: bounce)
    }

    /// Crossfade a label's content swap so old and new text never overdraw
    /// mid-resize — pair with `animateLayout` for the width change.
    static func fadeContentSwap(_ view: NSView, duration: TimeInterval = 0.18) {
        guard view.window != nil, let layer = view.layer else { return }
        let transition = CATransition()
        transition.type = .fade
        transition.duration = paced(duration)
        transition.timingFunction = glide
        layer.add(transition, forKey: "capmotion.contentSwap")
    }

    // MARK: - Springs

    enum Spring {
        /// UI acknowledgement — fast, barely any bounce.
        case snappy
        /// Standard movement — Keynote "magic move" feel.
        case smooth
        /// Playful — visible overshoot (toggle thumbs, pops).
        case bouncy

        var response: CGFloat {
            switch self {
            case .snappy: return 0.28
            case .smooth: return 0.42
            case .bouncy: return 0.42
            }
        }

        var dampingRatio: CGFloat {
            switch self {
            case .snappy: return 0.9
            case .smooth: return 1.0
            case .bouncy: return 0.68
            }
        }
    }

    /// Spring-animate one layer key path to a new value and set the model
    /// value, in one call.
    static func spring(
        _ layer: CALayer,
        keyPath: String,
        to value: Any?,
        _ spring: Spring = .smooth
    ) {
        let animation = springAnimation(keyPath: keyPath, spring)
        animation.fromValue = layer.presentation()?.value(forKeyPath: keyPath)
            ?? layer.value(forKeyPath: keyPath)
        animation.toValue = value
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(value, forKeyPath: keyPath)
        CATransaction.commit()
        layer.add(animation, forKey: "capmotion.\(keyPath)")
    }

    static func springAnimation(keyPath: String, _ spring: Spring = .smooth) -> CASpringAnimation {
        let animation = CASpringAnimation(keyPath: keyPath)
        // Convert SwiftUI-style (response, dampingRatio) to mass/stiffness/damping.
        // Response scales with the kit pace (see Pace) — shorter response = faster.
        let mass: CGFloat = 1
        let stiffness = pow(2 * .pi / (spring.response / pace.rawValue), 2) * mass
        animation.mass = mass
        animation.stiffness = stiffness
        animation.damping = 2 * spring.dampingRatio * sqrt(stiffness * mass)
        animation.duration = animation.settlingDuration
        return animation
    }

    /// Cross-fade one layer property (backgroundColor, borderColor, opacity…).
    /// View-backing layers suppress implicit animations, so hover washes and
    /// state tints need this explicit fade to move smoothly.
    static func fade(
        _ layer: CALayer,
        keyPath: String,
        to value: Any?,
        duration: TimeInterval = 0.16
    ) {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = layer.presentation()?.value(forKeyPath: keyPath)
            ?? layer.value(forKeyPath: keyPath)
        animation.toValue = value
        animation.duration = paced(duration)
        animation.timingFunction = glide
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(value, forKeyPath: keyPath)
        CATransaction.commit()
        layer.add(animation, forKey: "capmotion.fade.\(keyPath)")
    }

    /// Press feedback: springs the view's layer scale down and back.
    static func pressScale(_ view: NSView, down: Bool, scale: CGFloat = 0.965) {
        guard let layer = view.layer else { return }
        recenterAnchor(layer)
        spring(
            layer,
            keyPath: "transform.scale",
            to: down ? scale : 1.0,
            down ? .snappy : .bouncy
        )
    }

    // MARK: - Window frames

    private static var windowFrameTimers: [ObjectIdentifier: Timer] = [:]

    /// Animate a window's frame on a house curve. `window.animator()` rides
    /// the legacy NSAnimation path and IGNORES CAMediaTimingFunction — the
    /// growth bounce silently flattened to a stock ease until this driver
    /// existed (caught by --capdialog-shot's overshoot assert). Drives
    /// `setFrame` at 120 Hz along the exact bezier; a new call on the same
    /// window supersedes the previous one.
    static func animateFrame(
        of window: NSWindow,
        to target: NSRect,
        duration: TimeInterval = 0.38,
        curve: (CGFloat, CGFloat, CGFloat, CGFloat) = bouncePoints,
        completion: (() -> Void)? = nil
    ) {
        let key = ObjectIdentifier(window)
        windowFrameTimers[key]?.invalidate()
        let start = window.frame
        let total = paced(duration)
        let began = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak window] timer in
            MainActor.assumeIsolated {
                guard let window else { timer.invalidate(); return }
                let t = CGFloat(min(1, (CACurrentMediaTime() - began) / total))
                let y = bezierY(t, curve)
                // Interpolate and round EDGES, not origin+size: rounding
                // y and height independently makes a pinned edge (y + h)
                // jitter ±1px every tick — visible as a glitchy top border
                // while the bottom grows.
                let minX = (start.minX + (target.minX - start.minX) * y).rounded()
                let maxX = (start.maxX + (target.maxX - start.maxX) * y).rounded()
                let minY = (start.minY + (target.minY - start.minY) * y).rounded()
                let maxY = (start.maxY + (target.maxY - start.maxY) * y).rounded()
                window.setFrame(
                    NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
                    display: true
                )
                if t >= 1 {
                    timer.invalidate()
                    windowFrameTimers[ObjectIdentifier(window)] = nil
                    completion?()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        windowFrameTimers[key] = timer
    }

    /// Which edges a size change may move — the edges the CONTENT pushes.
    /// The growth law (Mike, 2026-09-01): only the pushed edge animates;
    /// every other edge stays pinned so existing content never shifts.
    struct MovingEdges: OptionSet {
        let rawValue: Int
        static let top = MovingEdges(rawValue: 1)
        static let bottom = MovingEdges(rawValue: 2)
        static let left = MovingEdges(rawValue: 4)
        static let right = MovingEdges(rawValue: 8)
    }

    /// Animate a window to `size`, moving only `edges` (default `.bottom` —
    /// stacked content pushes downward). Pinned edges hold their screen
    /// position for the whole animation.
    static func resize(
        _ window: NSWindow,
        to size: NSSize,
        moving edges: MovingEdges = .bottom,
        duration: TimeInterval = 0.38,
        curve: (CGFloat, CGFloat, CGFloat, CGFloat) = bouncePoints
    ) {
        let current = window.frame
        let dw = size.width - current.width
        let dh = size.height - current.height
        var x = current.origin.x
        var y = current.origin.y
        if edges.contains(.left) && edges.contains(.right) { x -= dw / 2 }
        else if edges.contains(.left) { x -= dw }
        // AppKit y is up: the bottom edge IS origin.y, the top edge is maxY.
        if edges.contains(.top) && edges.contains(.bottom) { y -= dh / 2 }
        else if edges.contains(.bottom) { y -= dh }
        animateFrame(
            of: window,
            to: NSRect(x: x, y: y, width: size.width, height: size.height),
            duration: duration, curve: curve
        )
    }

    /// Evaluate a cubic timing curve's y at progress x (P0 = 0, P3 = 1;
    /// bisection on the x polynomial).
    private static func bezierY(
        _ x: CGFloat, _ p: (CGFloat, CGFloat, CGFloat, CGFloat)
    ) -> CGFloat {
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

    /// Re-anchor to center without moving the layer on screen — transforms
    /// (scale, entrance slides) must pivot around the middle.
    static func recenterAnchor(_ layer: CALayer) {
        guard layer.anchorPoint != CGPoint(x: 0.5, y: 0.5) else { return }
        let frame = layer.frame
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.frame = frame
    }

    // MARK: - Entrances

    /// Presentation vocabulary — HOW a surface arrives and leaves. One
    /// entrance style covers both directions so a card that slid up also
    /// slides away. Transform-only by design: the surface's opacity fade
    /// stays with the caller (dialogs fade their WINDOW alpha; an in-window
    /// view pairs this with `fade(_:keyPath:"opacity"…)`).
    ///
    ///     dialog.entrance = .slideUp()          // CCDialog / CCAlert knob
    ///     CCMotion.enter(toast.layer!, .slideDown(distance: 16))
    enum Entrance {
        /// Keynote settle: spring in from 96% scale — the house default.
        case scaleIn
        /// Rises into place from `distance` pt below.
        case slideUp(distance: CGFloat = 24)
        /// Drops into place from `distance` pt above.
        case slideDown(distance: CGFloat = 24)
        /// No transform — for anchored surfaces that must not move; pair
        /// with an opacity fade.
        case fade
    }

    /// Play an arrival on `layer`: sets the off-stage transform, then springs
    /// to identity on `.smooth`.
    static func enter(_ layer: CALayer, _ entrance: Entrance = .scaleIn) {
        recenterAnchor(layer)
        switch entrance {
        case .scaleIn:
            layer.transform = CATransform3DMakeScale(0.96, 0.96, 1)
            spring(layer, keyPath: "transform.scale", to: 1.0, .smooth)
        case .slideUp(let distance):
            // Layer Y is up in unflipped hosts: starting BELOW = negative.
            layer.transform = CATransform3DMakeTranslation(0, -distance, 0)
            spring(layer, keyPath: "transform.translation.y", to: 0, .smooth)
        case .slideDown(let distance):
            layer.transform = CATransform3DMakeTranslation(0, distance, 0)
            spring(layer, keyPath: "transform.translation.y", to: 0, .smooth)
        case .fade:
            break
        }
    }

    /// Play the matching departure: a short `.snappy` move back toward
    /// off-stage (partial — the caller's alpha fade completes the exit).
    static func exit(_ layer: CALayer, _ entrance: Entrance = .scaleIn) {
        recenterAnchor(layer)
        switch entrance {
        case .scaleIn:
            spring(layer, keyPath: "transform.scale", to: 0.97, .snappy)
        case .slideUp(let distance):
            spring(layer, keyPath: "transform.translation.y", to: -distance / 2, .snappy)
        case .slideDown(let distance):
            spring(layer, keyPath: "transform.translation.y", to: distance / 2, .snappy)
        case .fade:
            break
        }
    }
}
