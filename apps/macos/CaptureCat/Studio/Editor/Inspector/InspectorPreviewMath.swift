import CoreGraphics
import Foundation

/// The inspector's live preview pads — the looping mini cards that show the
/// FEEL of an effect's settings (Slide, Zoom, Parallax, Motion Blur, the
/// Highlight dim, the Motion tab's speed) — as ONE copy of their maths,
/// shared by the Mac pads (EffectPreviewPadControl, PropertyPreviewPadControl,
/// MotionSpeedPadControl) and the iOS preview rows (InspectorPreviewRow).
/// Each platform only draws: it asks this file where the card is, how big,
/// how tipped, how smeared, for the pad's size and the loop's elapsed time.
///
/// Coordinates are the pad's own, Y-DOWN (the Mac pads are flipped views,
/// UIKit layers are Y-down), in points.
enum InspectorPreviewMath {

    // MARK: - What a pad shows

    /// A pad's mode, read from the scope by `mode(for:…)` — the values each
    /// Mac pane pushed into its pad, in one place.
    enum Mode: Equatable {
        /// Slide entrance: direction, duration, bounce, 3D depth pull.
        case slide(style: IntroSlideStyle, duration: Double, bounce: Double, depth: Bool)
        /// Zoom block push-in with a style's spring (omega multiplier, zeta).
        case zoom(level: Double, omegaMultiplier: Double, damping: Double)
        case parallax(strength: Double)
        case motionBlur(on: Bool, strength: Double)
        case frameStyle(cornerRadius: Double, shadowRadius: Double, shadowOpacity: Double)
        case highlightMask(opacity: Double)
        /// The Motion tab's transition speed (the zoom spring's duration).
        case motionSpeed(duration: Double)

        #if DEBUG
        /// A stable one-line description (the parity gates compare it).
        var probeDescription: String {
            func f(_ v: Double) -> String { String(format: "%.3f", v) }
            switch self {
            case .slide(let style, let duration, let bounce, let depth):
                return "slide style=\(style.rawValue) duration=\(f(duration)) bounce=\(f(bounce)) depth=\(depth)"
            case .zoom(let level, let omega, let damping):
                return "zoom level=\(f(level)) omega=\(f(omega)) damping=\(f(damping))"
            case .parallax(let strength): return "parallax strength=\(f(strength))"
            case .motionBlur(let on, let strength): return "motionBlur on=\(on) strength=\(f(strength))"
            case .frameStyle(let c, let r, let o): return "frameStyle corner=\(f(c)) shadow=\(f(r)) opacity=\(f(o))"
            case .highlightMask(let opacity): return "highlightMask opacity=\(f(opacity))"
            case .motionSpeed(let duration): return "motionSpeed duration=\(f(duration))"
            }
        }
        #endif
    }

    /// The pad mode for a preview row id (`effects.slidePad`,
    /// `blocks.zoomPreviewPad` …), nil when it has nothing to show — the
    /// Mac panes' `pad.mode = …` lines, verbatim.
    @MainActor
    static func mode(for id: String, _ scope: InspectorScope) -> Mode? {
        let s = scope.settings
        switch id {
        case "effects.slidePad":
            return .slide(style: s.introSlideStyle, duration: s.introSlideDuration,
                          bounce: s.introSlideBounce, depth: s.introSlideDepth)
        case "effects.parallaxPad":
            return .parallax(strength: s.parallaxStrength)
        case "effects.motionBlurPad":
            return .motionBlur(on: s.motionBlur, strength: s.motionBlurStrength)
        case "blocks.zoomPreviewPad":
            guard let zoom = scope.motion?.zoomRegion.wrappedValue else { return nil }
            let style = zoom.animationStyle
            return .zoom(level: zoom.zoomLevel, omegaMultiplier: style?.omegaMultiplier ?? 1,
                         damping: style?.damping ?? 0.88)
        case "blocks.highlightPad":
            guard let highlight = scope.motion?.highlightRegion.wrappedValue else { return nil }
            return .highlightMask(opacity: highlight.opacity)
        case "motion.speedPad":
            return .motionSpeed(duration: s.animationSpeed.duration)
        case "background.framePad":
            return .frameStyle(cornerRadius: s.windowCornerRadius, shadowRadius: s.shadowRadius,
                               shadowOpacity: s.shadowOpacity)
        default:
            return nil
        }
    }

    // MARK: - Slide (EffectPreviewPadControl)

    struct SlideFrame: Equatable {
        var cardSize: CGSize
        var center: CGPoint
        var scale: CGFloat
        /// Perspective tip in degrees (0 = flat); drawn with m34 = −1/640.
        var pitch: Double
    }

    /// The card's perspective for the pad's depth tip.
    static let slidePerspective: CGFloat = -1.0 / 640

    /// Replays [pre-roll 0.2 s][slide][hold 0.8 s] on a loop, through the
    /// real IntroSlideMath curve.
    static func slide(elapsed: Double, size: CGSize, style: IntroSlideStyle, duration: Double,
                      bounce: Double, depth: Bool) -> SlideFrame {
        let cardSize = CGSize(width: size.width * 0.42, height: size.height * 0.52)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let cycle = 0.2 + duration + 0.8
        let t = elapsed.truncatingRemainder(dividingBy: cycle) - 0.2
        let state = IntroSlideMath.state(style: style, at: max(t, -0.001), duration: duration,
                                         bounce: bounce, depth: depth)
        // travel is in canvas fractions; the pad is the canvas here.
        let clamped = CGPoint(x: max(-1.2, min(1.2, state.offset.x)), y: max(-1.2, min(1.2, state.offset.y)))
        let s = t < 0 ? (depth ? IntroSlideMath.depthStartScale : IntroSlideMath.startScale) : state.scale
        return SlideFrame(cardSize: cardSize,
                          center: CGPoint(x: center.x + clamped.x * size.width, y: center.y + clamped.y * size.height),
                          scale: s, pitch: abs(state.pitch) > 0.01 ? state.pitch : 0)
    }

    // MARK: - Zoom (EffectPreviewPadControl)

    /// The block spring at inspector scale: push in, hold, release, on a
    /// 3.2 s loop, integrated frame by frame (re-armed when the mode changes).
    struct ZoomSpring: Equatable {
        var zoom = 1.0
        var velocity = 0.0

        /// Advances by `dt` (capped at 0.05 s) toward the loop's target at
        /// `elapsed`; returns the card's pad scale.
        mutating func step(elapsed: Double, dt: Double, level: Double, omegaMultiplier: Double,
                           damping: Double) -> CGFloat {
            let cycle = 3.2
            let phase = elapsed.truncatingRemainder(dividingBy: cycle)
            let target = phase < 1.6 ? max(0.3, min(2.2, level)) : 1.0
            let dt = min(0.05, dt)
            let omega = 2.5 / 0.8 * omegaMultiplier
            let acc = omega * omega * (target - zoom) - 2 * damping * omega * velocity
            velocity += acc * dt
            zoom += velocity * dt
            return scale
        }

        /// Zoom around 1 mapped into a visible pad scale.
        var scale: CGFloat { CGFloat(0.55 + (zoom - 1) * 0.35) }
    }

    static func zoomCardSize(_ size: CGSize) -> CGSize {
        CGSize(width: size.width * 0.42, height: size.height * 0.52)
    }

    // MARK: - Parallax (PropertyPreviewPadControl)

    struct ParallaxFrame: Equatable {
        var cardSize: CGSize
        var center: CGPoint
        var zoom: CGFloat
        /// The three background marks (4 × 4 pt squares, origin top-left).
        var marks: [CGRect]
    }

    /// A foreground card pulses zoom while background marks drift at a
    /// fraction of that motion — the depth cue parallax adds.
    static func parallax(elapsed: Double, size: CGSize, strength: Double) -> ParallaxFrame {
        let cycle = 2.6
        let p = (elapsed.truncatingRemainder(dividingBy: cycle)) / cycle
        let zoom = 1 + 0.18 * sin(p * .pi)
        let drift = CGFloat(zoom - 1) * CGFloat(strength) * 60
        let marks = (0..<3).map { i -> CGRect in
            let bx = size.width * (0.2 + CGFloat(i) * 0.3)
            return CGRect(x: bx - drift * 0.6 - 2, y: size.height - 16, width: 4, height: 4)
        }
        return ParallaxFrame(cardSize: CGSize(width: size.width * 0.4, height: size.height * 0.46),
                             center: CGPoint(x: size.width / 2, y: size.height / 2),
                             zoom: CGFloat(zoom), marks: marks)
    }

    // MARK: - Motion blur (PropertyPreviewPadControl)

    struct MotionBlurFrame: Equatable {
        static let dotSize: CGFloat = 12
        static let trailCount = 5
        var center: CGPoint
        /// Horizontal stretch of the dot along its motion.
        var stretch: CGFloat
        /// The smear's dots (frame, white alpha), empty at rest.
        var trail: [(frame: CGRect, alpha: Double)]

        static func == (a: MotionBlurFrame, b: MotionBlurFrame) -> Bool {
            a.center == b.center && a.stretch == b.stretch && a.trail.map(\.frame) == b.trail.map(\.frame)
                && a.trail.map(\.alpha) == b.trail.map(\.alpha)
        }
    }

    /// Sharp at rest, smeared only while moving fast: the dot glides
    /// left↔right on a cosine path (pausing at each end); the smear follows
    /// the instantaneous speed, scaled by Strength.
    static func motionBlur(elapsed: Double, size: CGSize, on: Bool, strength: Double) -> MotionBlurFrame {
        let cycle = 2.6
        let p = (elapsed.truncatingRemainder(dividingBy: cycle)) / cycle
        let phase = p * 2 * .pi
        let travel = size.width * 0.72
        let x = size.width * 0.14 + travel * CGFloat(0.5 - 0.5 * cos(phase))
        let speed = abs(sin(phase))
        let direction: CGFloat = sin(phase) >= 0 ? 1 : -1
        let shapeSize = MotionBlurFrame.dotSize
        let smear: CGFloat = on ? CGFloat(speed * max(0, min(1, strength))) * 34 : 0
        var trail: [(CGRect, Double)] = []
        if on && smear > 1 {
            for i in 0..<MotionBlurFrame.trailCount {
                let f = CGFloat(i + 1) / CGFloat(MotionBlurFrame.trailCount)
                let alpha = 0.45 * Double(speed) * Double(1 - f) * min(1, strength + 0.3)
                trail.append((CGRect(x: x - direction * smear * f - shapeSize / 2, y: size.height / 2 - shapeSize / 2,
                                     width: shapeSize, height: shapeSize), alpha))
            }
        }
        let stretch = 1 + (on ? CGFloat(speed) * 0.5 * CGFloat(min(1, strength)) : 0)
        return MotionBlurFrame(center: CGPoint(x: x, y: size.height / 2), stretch: stretch, trail: trail)
    }

    // MARK: - Highlight dim (PropertyPreviewPadControl)

    /// The bright hole the dim leaves (a 4 pt-radius card, centred).
    static func highlightHole(size: CGSize) -> CGRect {
        let hole = CGSize(width: size.width * 0.32, height: size.height * 0.4)
        return CGRect(x: size.width / 2 - hole.width / 2, y: size.height / 2 - hole.height / 2,
                      width: hole.width, height: hole.height)
    }

    // MARK: - Frame style (PropertyPreviewPadControl)

    struct FrameStyleFrame: Equatable {
        var cardSize: CGSize
        var cornerRadius: CGFloat
        var shadowRadius: CGFloat
        var shadowOpacity: Float
    }

    static func frameStyle(size: CGSize, cornerRadius: Double, shadowRadius: Double,
                           shadowOpacity: Double) -> FrameStyleFrame {
        let card = CGSize(width: size.width * 0.5, height: size.height * 0.6)
        let scale = min(card.width, card.height) / 80
        return FrameStyleFrame(cardSize: card, cornerRadius: CGFloat(cornerRadius) * scale * 0.6,
                               shadowRadius: CGFloat(shadowRadius) * scale * 0.3, shadowOpacity: Float(shadowOpacity))
    }

    // MARK: - Motion speed (MotionSpeedPadControl)

    /// Analytic response of the real zoom spring (ω = 2.5/animDur, ζ = 0.88).
    static func springResponse(_ u: Double, animDur: Double) -> Double {
        guard u > 0 else { return 0 }
        let omega = 2.5 / animDur
        let zeta = 0.88
        let damped = omega * (1 - zeta * zeta).squareRoot()
        return 1 - exp(-zeta * omega * u) * (cos(damped * u) + (zeta * omega / damped) * sin(damped * u))
    }

    struct MotionSpeedFrame: Equatable {
        var cardSize: CGSize
        /// The scale anchor (0.38, 0.42 of the card) and where it sits.
        var anchor: CGPoint
        var position: CGPoint
        var zoom: CGFloat
    }

    /// Loops a zoom-in / release on the EXACT spring the preview and exporter
    /// use, for the Motion tab's speed (`duration` = AnimationSpeed.duration).
    static func motionSpeed(elapsed: Double, size: CGSize, duration: Double) -> MotionSpeedFrame {
        let animDur = max(0.2, duration)
        let cycle = max(2.4, animDur * 2 + 1.2)
        let t = elapsed.truncatingRemainder(dividingBy: cycle)
        let half = cycle / 2
        let zoom = t < half
            ? 1 + 0.5 * springResponse(t - 0.2, animDur: animDur)
            : 1 + 0.5 * (1 - springResponse(t - half - 0.2, animDur: animDur))
        let w = size.width * 0.44
        let h = size.height * 0.62
        return MotionSpeedFrame(cardSize: CGSize(width: w, height: h), anchor: CGPoint(x: 0.38, y: 0.42),
                                position: CGPoint(x: size.width / 2 - w / 2 + w * 0.38, y: size.height / 2 - h / 2 + h * 0.42),
                                zoom: CGFloat(zoom))
    }
}
