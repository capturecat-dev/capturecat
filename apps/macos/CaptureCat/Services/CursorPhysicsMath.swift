import Foundation
import CoreGraphics

/// Cursor motion physics — tilt, squash-and-stretch, and body drag — as a
/// PURE function of the recorded path and the timeline clock.
///
/// This is the single source of truth for both renderers (CLAUDE.md §2): the
/// preview compositor turns the pose into a CALayer transform and the exporter
/// turns the identical pose into a CIImage transform, so scrubbing, playback,
/// and the exported file always agree frame-for-frame.
///
/// # The invariant that must never break
///
/// The transform's FIXED POINT is the hotspot. Whatever the pose does, the
/// tip stays exactly on the recorded position — the body leans, squashes and
/// trails AROUND the point that clicks. `affineTransform(pose:tip:)` is built
/// so `M(tip) == tip` by construction.
///
/// # Coordinate space
///
/// Poses are produced in Y-DOWN view space (preview canvas). The exporter's
/// CIImage space is Y-up: negate `rotation` and `bodyOffset.dy` there — see
/// `yFlipped()`.
enum CursorPhysicsMath {
    /// Velocity sampling window. Finite-difference over a fixed timeline
    /// interval, so the pose is identical for playback, scrubbing and export.
    static let velocityWindow: TimeInterval = 1.0 / 30.0

    /// Response caps, at full sliders and weight 1. Kept modest: physics reads
    /// as life, not as a broken cursor.
    static let maxTiltRadians: CGFloat = 18 * .pi / 180
    static let maxStretch: CGFloat = 0.30
    /// Max body trail, as a fraction of the cursor sprite's height.
    static let maxDragFraction: CGFloat = 0.45

    /// Speed at which each response saturates, in VIDEO-WIDTHS per second —
    /// resolution-independent on purpose: the preview canvas and a 4K export
    /// must compute the identical response for the same recorded motion.
    static let saturationSpeed: Double = 1.25

    struct Pose: Equatable {
        /// Sprite-body trail, view points, Y-down. The tip does NOT move —
        /// the offset is folded into the tip-pinned transform's shear of the
        /// body, see `affineTransform`.
        var bodyOffset: CGVector = .zero
        /// Lean into horizontal motion. Y-down positive = clockwise on screen.
        var rotation: CGFloat = 0
        /// Scale along the motion direction (its perpendicular is compressed
        /// by the inverse root, preserving area).
        var stretch: CGFloat = 1
        /// Motion direction the stretch is aligned to.
        var motionAngle: CGFloat = 0

        var isIdentity: Bool {
            bodyOffset == .zero && rotation == 0 && stretch == 1
        }

        /// The same pose for a Y-up consumer (the exporter's CIImage space).
        func yFlipped() -> Pose {
            Pose(
                bodyOffset: CGVector(dx: bodyOffset.dx, dy: -bodyOffset.dy),
                rotation: -rotation,
                stretch: stretch,
                motionAngle: -motionAngle
            )
        }
    }

    /// Pose at `time`, derived from the recorded events.
    ///
    /// `videoRect` converts recorded coordinate-space velocity into on-screen
    /// points so the response is resolution-independent. `spriteHeight` (view
    /// points) scales the drag trail to the rendered cursor size.
    static func pose(
        events: [CursorEvent],
        at time: TimeInterval,
        coordinateSize: CGSize,
        videoRect: CGRect,
        spriteHeight: CGFloat,
        tilt: Double,
        stretch: Double,
        drag: Double,
        weight: Double
    ) -> Pose {
        let tiltAmount = CGFloat(max(0, min(1, tilt)))
        let stretchAmount = CGFloat(max(0, min(1, stretch)))
        let dragAmount = CGFloat(max(0, min(1, drag)))
        let weightAmount = CGFloat(max(0.5, min(3, weight)))
        guard tiltAmount > 0 || stretchAmount > 0 || dragAmount > 0,
              events.count > 1,
              coordinateSize.width > 0, coordinateSize.height > 0,
              videoRect.width > 0, videoRect.height > 0 else {
            return Pose()
        }

        // Central difference around `time` — symmetric, so the pose does not
        // lag the motion (the same reasoning as CursorSmoother's symmetric
        // window). A heavier cursor samples a wider window: its response
        // integrates more of the recent path, which reads as inertia.
        let dt = velocityWindow * Double(weightAmount)
        let smoother = CursorSmoother()
        let before = smoother.interpolate(events: events, at: time - dt / 2)
        let after = smoother.interpolate(events: events, at: time + dt / 2)

        // Velocity in VIDEO-WIDTHS per second: aspect-correct in view space
        // (scaleX/scaleY), then normalized by the video's on-screen width, so
        // the preview canvas and any export resolution agree exactly.
        let scaleX = videoRect.width / coordinateSize.width
        let scaleY = videoRect.height / coordinateSize.height
        let vx = Double((after.x - before.x) * scaleX / videoRect.width) / dt
        let vy = Double((after.y - before.y) * scaleY / videoRect.width) / dt
        let speed = (vx * vx + vy * vy).squareRoot()
        guard speed > 0.002 else { return Pose() }

        // Saturating response — heavier cursors respond harder but cap the
        // same, so weight changes character, not correctness.
        let response = CGFloat(min(1, speed * Double(weightAmount) / saturationSpeed))

        var pose = Pose()
        pose.motionAngle = CGFloat(atan2(vy, vx))
        // Tilt follows HORIZONTAL motion only — a cursor leaning while moving
        // straight down looks broken, not lively.
        let horizontal = CGFloat(max(-1, min(1, vx * Double(weightAmount) / saturationSpeed)))
        pose.rotation = maxTiltRadians * horizontal * tiltAmount
        pose.stretch = 1 + maxStretch * response * stretchAmount
        let trail = maxDragFraction * spriteHeight * response * dragAmount
        pose.bodyOffset = CGVector(
            dx: -CGFloat(vx / speed) * trail,
            dy: -CGFloat(vy / speed) * trail
        )
        return pose
    }

    /// The pose as an affine transform whose FIXED POINT is `tip` (both in the
    /// same space the pose was produced in — sprite-local, origin at the
    /// sprite's top-left, Y matching the pose's orientation).
    ///
    /// `M = T(tip) · Translate(bodyOffset·k) · R(rotation) · S(stretch about
    /// motionAngle) · T(-tip)` — except the body offset must not move the tip
    /// either, so it is applied as a linear falloff: points at the tip move by
    /// zero, points one sprite-height away move by the full offset. That is a
    /// shear, composed here from the same primitives.
    static func affineTransform(
        pose: Pose,
        tip: CGPoint,
        spriteHeight: CGFloat
    ) -> CGAffineTransform {
        guard !pose.isIdentity else { return .identity }

        // Rotation + area-preserving stretch about the motion axis.
        var linear = CGAffineTransform.identity
            .rotated(by: pose.motionAngle)
            .scaledBy(x: pose.stretch, y: 1 / max(0.0001, sqrt(pose.stretch)))
            .rotated(by: -pose.motionAngle)
            .rotated(by: pose.rotation)

        // Body drag as a shear anchored at the tip: displacement grows with
        // distance from the tip along the sprite, reaching `bodyOffset` at one
        // sprite-height. Rows: x' = x + (dx/h)·y_fromTip, likewise for y.
        if pose.bodyOffset != .zero, spriteHeight > 0 {
            let shear = CGAffineTransform(
                a: 1, b: pose.bodyOffset.dy / spriteHeight,
                c: pose.bodyOffset.dx / spriteHeight, d: 1,
                tx: 0, ty: 0
            )
            linear = linear.concatenating(shear)
        }

        // Pin the tip: conjugate the linear part by the tip translation.
        return CGAffineTransform(translationX: -tip.x, y: -tip.y)
            .concatenating(linear)
            .concatenating(CGAffineTransform(translationX: tip.x, y: tip.y))
    }
}
