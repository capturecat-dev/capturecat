import Foundation
import CoreGraphics

/// Motion blur — SHARED math between the editor preview (CALayer CIFilter on
/// the zoom group) and the exporter (CIMotionBlur on the composited card).
/// Preview must equal export exactly, so everything that decides "how much
/// blur, in which direction" lives here and NOWHERE else.
///
/// Inputs are two adjacent camera samples on the OUTPUT TIMELINE (never wall
/// clock) plus the time between them. The math is deliberately STATELESS and
/// closed-form: radius is a smooth function of the instantaneous apparent
/// velocity, and the camera springs themselves are already critically-damped
/// smooth trajectories, so the radius inherits their smoothness — no internal
/// follower whose state could diverge between the preview's display-cadence
/// samples and the exporter's fixed-fps samples. Scrubbing therefore shows
/// the same blur a playing preview shows at that time (the preview's
/// motion model replays springs deterministically on scrub).
///
/// Units: radius is a fraction of CANVAS WIDTH (convert to pixels at the
/// call site with the actual canvas/output width so both sides agree).
/// Angle is radians in the preview's Y-DOWN canvas space; Core Image is
/// Y-up, so CI call sites (exporter AND the CALayer filter, which renders
/// in CA's native Y-up backing space) must pass `-angle`.
enum MotionBlurMath {

    /// One camera sample: raw spring zoom (1 = none), focal point in 0…1 of
    /// the video rect, and card offset excursion in canvas fractions (Y-down,
    /// the preview's space — the exporter's CameraKey stores the same).
    struct CameraSample: Equatable {
        var zoom: Double
        var focalX: Double
        var focalY: Double
        var offsetX: Double
        var offsetY: Double
    }

    struct Blur: Equatable {
        /// Blur radius as a fraction of canvas width. 0 when inactive.
        var radius: Double
        /// Direction of apparent motion, radians, Y-down canvas space.
        var angle: Double
        var active: Bool
        static let none = Blur(radius: 0, angle: 0, active: false)
    }

    /// Apparent speed (canvas fractions / second) below which no blur engages.
    static let velocityThreshold = 0.06
    /// Speed at which the blur reaches its cap.
    static let velocityAtMax = 1.2
    /// Maximum radius at strength 1 — ~2.5% of canvas width.
    static let maxRadiusFraction = 0.025
    /// Mean lever arm of card content from the zoom anchor (canvas fractions)
    /// — converts zoom rate into an apparent-translation-equivalent speed.
    static let zoomLeverArm = 0.25
    /// dt outside this range means a seek/scrub discontinuity — no blur.
    static let maxSampleGap = 0.5

    /// Where the canvas centre lands after the card transform: the zoom is
    /// applied about the focal anchor, then the whole card slides by the
    /// offset excursion. Canvas fractions, Y-down. Both sides transform the
    /// card with exactly this composition (preview zoomGroup / exporter
    /// affine), so its derivative IS the apparent on-screen motion.
    private static func mappedCenter(_ s: CameraSample) -> (x: Double, y: Double) {
        let q = 0.5
        let x = s.focalX + s.zoom * (q - s.focalX) + s.offsetX
        let y = s.focalY + s.zoom * (q - s.focalY) + s.offsetY
        return (x, y)
    }

    static func blur(
        previous: CameraSample,
        current: CameraSample,
        dt: Double,
        strength: Double
    ) -> Blur {
        guard strength > 0.001, dt > 1e-6, dt <= maxSampleGap else { return .none }
        let p0 = mappedCenter(previous)
        let p1 = mappedCenter(current)
        let vx = (p1.x - p0.x) / dt
        let vy = (p1.y - p0.y) / dt
        let translational = (vx * vx + vy * vy).squareRoot()
        // Zoom rate reads as radial smear — fold it into the magnitude with
        // a mean lever arm so a fast zoom push blurs even when the centre
        // barely translates.
        let zoomSpeed = abs(current.zoom - previous.zoom) / dt * zoomLeverArm
        let speed = translational + zoomSpeed
        guard speed > velocityThreshold else { return .none }
        // Smoothstep from the threshold to the cap — no pops at engage.
        let t = min(1, (speed - velocityThreshold) / (velocityAtMax - velocityThreshold))
        let eased = t * t * (3 - 2 * t)
        let radius = eased * maxRadiusFraction * min(1, max(0, strength))
        guard radius > 0.0002 else { return .none }
        // Direction of apparent motion. A pure zoom (no translation) has no
        // single direction — bias horizontal, which reads neutrally.
        let angle = translational > 1e-9 ? atan2(vy, vx) : 0
        return Blur(radius: radius, angle: angle, active: true)
    }
}
