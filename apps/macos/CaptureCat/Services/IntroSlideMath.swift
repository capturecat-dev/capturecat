import CoreGraphics
import Foundation

/// Card entrance direction. Raw values are persistence identity — never
/// rename one (old projects must always still load).
enum IntroSlideStyle: String, CaseIterable, Codable, Sendable {
    case off = "Off"
    case top = "Top"
    case bottom = "Bottom"
    case left = "Left"
    case right = "Right"

    /// Unit direction the card ARRIVES FROM, canvas fractions, Y-down.
    var vector: CGPoint {
        switch self {
        case .off: return .zero
        case .top: return CGPoint(x: 0, y: -1)
        case .bottom: return CGPoint(x: 0, y: 1)
        case .left: return CGPoint(x: -1, y: 0)
        case .right: return CGPoint(x: 1, y: 0)
        }
    }
}

/// The card slides in from an edge with an eased overshoot and a slight
/// scale-up — the CapCut-style entrance. Deterministic from OUTPUT time
/// (t = 0 is the trim start), like `TiltMath.introAmount`, so scrubbing,
/// playback and export all agree. SHARED by the preview compositor and the
/// exporter; the state rides each side's existing card transform, never a
/// forked copy of this curve.
///
/// `depth` layers a 3D back-to-front pull onto ANY direction: the card starts
/// small, deep, and tipped back, then dollies toward the viewer as it lands.
/// The pull is a perspective warp (see State.pitch) plus the scale-up, applied
/// identically by both renderers through the shared TiltMath homography.
enum IntroSlideMath {
    struct State: Equatable {
        /// Canvas-fraction translation, Y-down (same space as card offset).
        var offset: CGPoint = .zero
        var scale: CGFloat = 1
        /// Forward-tip angle in DEGREES (top edge away from viewer at positive),
        /// applied as a perspective warp about the canvas centre by both
        /// renderers. 0 for a flat slide; ramps to 0 as a depth pull settles.
        /// Same TiltMath sign convention as screen tilt.
        var pitch: Double = 0
        /// False once the entrance has fully settled — callers skip work.
        var active = false
    }

    /// 1.2 canvas fractions of travel clears the canvas including shadow.
    static let travel: CGFloat = 1.2
    static let startScale: CGFloat = 0.9
    /// Depth (back-to-front) pull: the card starts THIS small and deep in the
    /// scene, tipped back this many degrees, then dollies to full size / flat.
    /// Small start scale makes the approach unmistakable — the "from the back,
    /// to the front" read the flat slide's gentle 0.9 scale-up never gave.
    static let depthStartScale: CGFloat = 0.42
    static let depthStartPitch: Double = 20

    /// `startTime` places the slide anywhere on the timeline. At 0 it is the
    /// clip's ENTRANCE: the card starts offscreen and slides in. Anywhere
    /// else it is a slide-away-and-back: the card glides out to the chosen
    /// edge, kisses offscreen, and slides back with the same punchy settle —
    /// usable mid-clip (e.g. to cover a cut) without any jump, because both
    /// ends of the gesture are the resting card.
    /// `bounce` 0…1 scales the arrival overshoot: 0 = pure ease-out (no
    /// overshoot), 0.5 = the classic easeOutBack feel, 1 = springy.
    /// `depth` adds the 3D back-to-front pull on top of the chosen direction.
    /// `speed` ≥ 1 compresses the animation into the FIRST 1/speed of the
    /// block — the card lands early and holds settled for the remainder. The
    /// division lives HERE so preview and export cannot drift.
    static func state(
        style: IntroSlideStyle,
        at outputTime: TimeInterval,
        startTime: TimeInterval = 0,
        duration rawDuration: Double,
        bounce: Double = 0.5,
        depth: Bool = false,
        speed: Double = 1.0
    ) -> State {
        let duration = rawDuration / max(1.0, speed)
        guard style != .off, duration > 0.05 else { return State() }
        let v = style.vector
        let entryScale = depth ? depthStartScale : startScale
        let entryPitch = depth ? depthStartPitch : 0
        if startTime <= 0.01 {
            let p = outputTime / duration
            guard p < 1 else { return State() }
            guard p > 0 else {
                return State(
                    offset: CGPoint(x: v.x * travel, y: v.y * travel),
                    scale: entryScale, pitch: entryPitch, active: true)
            }
            if depth {
                return pulling(p, v, bounce: bounce)
            }
            return arriving(easeOutBack(p, bounce: bounce), v,
                            startScale: entryScale, startPitch: entryPitch)
        }
        // Mid-timeline: out (0…0.45), offscreen beat (0.45…0.55), in (0.55…1).
        let p = (outputTime - startTime) / duration
        guard p > 0, p < 1 else { return State() }
        if p < 0.45 {
            let q = p / 0.45
            let eased = CGFloat(q * q * (3 - 2 * q))
            return State(
                offset: CGPoint(x: v.x * travel * eased, y: v.y * travel * eased),
                scale: 1 + (entryScale - 1) * eased,
                pitch: entryPitch * Double(eased),
                active: true)
        }
        if p < 0.55 {
            return State(
                offset: CGPoint(x: v.x * travel, y: v.y * travel),
                scale: entryScale, pitch: entryPitch, active: true)
        }
        if depth {
            return pulling((p - 0.55) / 0.45, v, bounce: bounce)
        }
        return arriving(easeOutBack((p - 0.55) / 0.45, bounce: bounce), v,
                        startScale: entryScale, startPitch: entryPitch)
    }

    /// easeOutBack — decelerates past the resting spot and settles: the
    /// punchy arrive-and-sit feel. `bounce` scales the overshoot constant
    /// (0 → none, 0.5 → the classic 1.70158, 1 → springy).
    private static func easeOutBack(_ p: Double, bounce: Double) -> Double {
        let c1 = 3.4 * max(0, min(1, bounce))
        let c3 = c1 + 1
        return 1 + c3 * pow(p - 1, 3) + c1 * pow(p - 1, 2)
    }

    /// Depth entrance: the directional slide arrives on the usual punchy
    /// easeOutBack, while the card is drawn from the BACK to the FRONT on a
    /// slower ease-in-out — it lingers small and tipped early (reads as far
    /// away), then pulls forward to full size and flat. The slide lands before
    /// the pull finishes, so it reads as "in from the edge, THEN toward you".
    private static func pulling(_ p: Double, _ v: CGPoint, bounce: Double) -> State {
        let slide = easeOutBack(p, bounce: bounce)
        let remaining = CGFloat(1 - slide)
        // Ease-in-out (smoothstep) holds the card back early, then pulls it in.
        let q = max(0, min(1, p))
        let pull = q * q * (3 - 2 * q)
        return State(
            offset: CGPoint(x: v.x * travel * remaining, y: v.y * travel * remaining),
            scale: depthStartScale + (1 - depthStartScale) * CGFloat(pull),
            pitch: depthStartPitch * (1 - pull),
            active: true)
    }

    private static func arriving(
        _ e: Double, _ v: CGPoint,
        startScale: CGFloat, startPitch: Double
    ) -> State {
        let remaining = CGFloat(1 - e)
        // Scale and pitch are clamped so the card never renders above native
        // size, and the tip settles flat without inverting past the overshoot.
        let settled = max(0, min(1, e))
        return State(
            offset: CGPoint(x: v.x * travel * remaining, y: v.y * travel * remaining),
            scale: startScale + (1 - startScale) * CGFloat(settled),
            pitch: startPitch * (1 - settled),
            active: true)
    }
}
