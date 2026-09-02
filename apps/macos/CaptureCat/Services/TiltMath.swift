import CoreGraphics
import QuartzCore

/// Shared 3D screen-tilt math used by both the SwiftUI preview and the
/// Core Image exporter so the two render the identical perspective warp.
///
/// The tilt is a roll (in-plane rotation) followed by a pitch/yaw rotation
/// about the card's center, projected with a pinhole camera at `distance`.
/// A rotated plane under perspective projection is exactly a 2D homography,
/// so the preview (ProjectionTransform) and the export (CIPerspectiveTransform
/// mapping the image's corners through `projectedPoint`) produce the same
/// image, and the warp is independent of the extent it's applied to.
///
/// Sign conventions (as seen in the preview): positive pitch tips the TOP
/// edge away from the viewer, positive yaw tips the RIGHT edge toward the
/// viewer, positive roll rotates clockwise.
enum TiltMath {
    /// Camera distance relative to the card size — controls perspective strength.
    static func perspectiveDistance(for size: CGSize) -> CGFloat {
        2.0 * max(size.width, size.height, 1)
    }

    /// Intro envelope: full skew (1) at t = 0 settling to flat (0) with the
    /// EXACT same damped-spring response as the zoom spring (ω = 2.5/animDur,
    /// ζ = 0.88), so the intro flattens at the same speed zoom transitions
    /// animate. Analytic (not integrated) so scrubbing and export agree.
    static func introAmount(at time: Double, animationDuration: Double) -> Double {
        guard time > 0 else { return 1 }
        let omega = 2.5 / max(0.2, animationDuration)
        let zeta = 0.88
        let dampedOmega = omega * (1 - zeta * zeta).squareRoot()
        let amount = exp(-zeta * omega * time)
            * (cos(dampedOmega * time) + (zeta * omega / dampedOmega) * sin(dampedOmega * time))
        return max(0, min(1, amount))
    }

    /// Analytic step response of SwiftUI's `.spring(response:dampingFraction:)`
    /// — used by the exporter to reproduce preview spring animations
    /// deterministically (e.g. the desktop → device segment morph).
    static func springStep(_ t: Double, response: Double, damping: Double) -> Double {
        guard t > 0 else { return 0 }
        let omega0 = 2 * Double.pi / max(0.05, response)
        let zeta = min(0.999, max(0.01, damping))
        let omegaD = omega0 * (1 - zeta * zeta).squareRoot()
        let s = 1 - exp(-zeta * omega0 * t)
            * (cos(omegaD * t) + (zeta * omega0 / omegaD) * sin(omegaD * t))
        return min(1, max(0, s))
    }

    /// Offset of the drawn device's visible SIDE face (the extrusion slab
    /// behind the bezel body), in preview (Y-DOWN) space. Shared by the
    /// preview and the exporter so both show the same faces at the same size.
    ///
    /// Positive yaw tips the RIGHT edge toward the viewer → the right side
    /// face shows → slab moves +x. Positive pitch tips the TOP edge away →
    /// the BOTTOM edge comes toward the viewer → slab moves +y (downward in
    /// Y-down space; the exporter negates this for CI's Y-up space). Roll is
    /// in-plane and does not change which faces are visible, so it's ignored.
    /// At zero tilt the offset is zero and the slab hides behind the bezel.
    static func deviceSideOffset(
        pitchDegrees: Double,
        yawDegrees: Double,
        videoWidth: CGFloat
    ) -> CGSize {
        // True-to-scale: an iPhone is ~8mm deep on a ~72mm body — the side
        // face at full tilt is ~11% of the device width.
        let thickness = max(6, videoWidth * 0.11)
        return CGSize(
            width: thickness * CGFloat(sin(yawDegrees * .pi / 180)),
            height: thickness * CGFloat(sin(pitchDegrees * .pi / 180))
        )
    }

    /// Spring parameters for the tilt-region springs at `time` — the ACTIVE
    /// tilt block's animation style, held through the settle after the block
    /// ends (same reasoning as the zoom style hold: the way OUT of a skew
    /// should feel like the way in). SHARED by the preview motion model and
    /// the exporter's camera path.
    static func tiltStyleParams(
        tiltRegions: [TiltRegion],
        at time: TimeInterval,
        memory: inout (omega: Double, damping: Double)
    ) -> (omega: Double, damping: Double) {
        for region in tiltRegions
        where time >= region.startTime && time <= region.endTime {
            let style = region.animationStyle
            memory = (style?.omegaMultiplier ?? 1, style?.damping ?? 0.88)
            return memory
        }
        return memory
    }

    /// Spring parameters for the timeline TILT springs at `time` — the ONE
    /// boundary-smooth resolution both renderers consume. Inside a block the
    /// region's own style applies; from the ramp-out start the omega blends
    /// along `ZoomFocalMath.returnOmega`'s eased curve to the decisive floor
    /// (max(1.25, style)), which is EXACTLY the post-block value — so the
    /// stiffness is continuous through the block's end instead of stepping
    /// the frame the block expires (the measured 3.6× omega step that made a
    /// Cinematic 20° tilt "click" at its boundary while the spring still
    /// carried ~10° of lag). `returning` also turns on at the ramp start so
    /// the settle assist engages while the target glides home, matching the
    /// zoom's discipline (ZoomFocalMath.regionTargets).
    static func tiltReturnParams(
        tiltRegions: [TiltRegion],
        at time: TimeInterval,
        animationDuration: Double,
        memory: inout (omega: Double, damping: Double)
    ) -> (omega: Double, damping: Double, returning: Bool) {
        let style = tiltStyleParams(tiltRegions: tiltRegions, at: time, memory: &memory)
        if let region = tiltRegions.first(where: {
            time >= $0.startTime && time <= $0.endTime
        }) {
            let lead = rampOutLead(
                blockStart: region.startTime, blockEnd: region.endTime,
                animationDuration: animationDuration)
            let rampStart = region.endTime - lead
            guard time >= rampStart else {
                return (style.omega, style.damping, false)
            }
            return (ZoomFocalMath.returnOmega(
                        time: time, rampStart: rampStart,
                        lead: lead, style: style.omega),
                    min(style.damping, 0.95), true)
        }
        // Past the block: the blend's own endpoint — no discontinuity.
        return (max(1.25, style.omega), min(style.damping, 0.95), true)
    }

    /// In-block ramp-out lead: how long before a block's end its targets
    /// flip to rest, so the camera (zoom, tilt, offset alike) is HOME the
    /// moment the block ends. Adaptive: at least the spring's realistic
    /// settle time, never more than half the block.
    static func rampOutLead(
        blockStart: TimeInterval,
        blockEnd: TimeInterval,
        animationDuration: Double
    ) -> TimeInterval {
        min(0.5 * max(0, blockEnd - blockStart), max(0.4, 1.8 * animationDuration))
    }

    /// 1 → 0 smoothstep through the ramp-out window. The ramp-out TARGET is
    /// eased, not stepped: a spring chasing a step target takes its maximum
    /// acceleration on the very first frame — the "clicks first, then moves"
    /// feel — while a spring tracking this eased path starts with zero
    /// acceleration and moves in a Keynote-style S-curve. Shared by zoom,
    /// offset and tilt so the whole camera releases as one gesture.
    static func rampOutScale(
        time: TimeInterval,
        blockStart: TimeInterval,
        blockEnd: TimeInterval,
        animationDuration: Double
    ) -> Double {
        let lead = rampOutLead(
            blockStart: blockStart, blockEnd: blockEnd,
            animationDuration: animationDuration)
        let rampStart = blockEnd - lead
        guard time > rampStart else { return 1 }
        let p = min(1, max(0, (time - rampStart) / max(0.0001, lead)))
        let eased = p * p * (3 - 2 * p)
        return 1 - eased
    }

    /// Extra zoom so a card that is rotated/tilted WHILE ZOOMED IN still
    /// covers the whole canvas. Without it a rotated zoom exposes black
    /// wedges at the corners — the single thing that makes zoom+tilt read as
    /// broken instead of cinematic. Roll uses the exact 2D rotation cover
    /// bound; pitch/yaw add the receding edge's perspective margin.
    static func coverZoomMultiplier(
        pitchDegrees: Double,
        yawDegrees: Double,
        rollDegrees: Double,
        aspect: CGFloat
    ) -> CGFloat {
        guard max(abs(pitchDegrees), abs(yawDegrees), abs(rollDegrees)) > 0.01 else { return 1 }
        let r = abs(rollDegrees) * .pi / 180
        let c = CGFloat(cos(r)), s = CGFloat(sin(r))
        let a = max(0.1, aspect) // width / height
        // Rotated W×H must span W×H: needW = W·c + H·s, needH = W·s + H·c.
        let fx = c + s / a
        let fy = c + s * a
        var multiplier = max(fx, fy)
        // Perspective: the edge tipping away shrinks by ~cos(angle).
        let pitchMargin = CGFloat(cos(min(1.0, abs(pitchDegrees) * .pi / 180)))
        let yawMargin = CGFloat(cos(min(1.0, abs(yawDegrees) * .pi / 180)))
        multiplier /= max(0.5, pitchMargin)
        multiplier /= max(0.5, yawMargin)
        return min(2.5, multiplier)
    }

    /// The zoom both renderers actually apply: the requested zoom, cover-
    /// compensated once it exceeds 1. The compensation RAMPS in over the
    /// first 0.6 zoom units so a spring animating from rest stays continuous
    /// instead of jumping the moment it crosses 1.
    static func effectiveCoverZoom(
        zoom: CGFloat,
        pitchDegrees: Double,
        yawDegrees: Double,
        rollDegrees: Double,
        aspect: CGFloat
    ) -> CGFloat {
        guard zoom > 1.001 else { return zoom }
        let multiplier = coverZoomMultiplier(
            pitchDegrees: pitchDegrees, yawDegrees: yawDegrees,
            rollDegrees: rollDegrees, aspect: aspect
        )
        let progress = min(1, (zoom - 1) / 0.6)
        let smooth = progress * progress * (3 - 2 * progress)
        return zoom * (1 + (multiplier - 1) * smooth)
    }

    /// A 3×3 row-vector homography — `(x, y, 1) · M`, perspective in the third
    /// column.
    ///
    /// This is a drop-in replacement for SwiftUI's `ProjectionTransform`, with
    /// the same field names and the same `concatenating` order, so the shared
    /// tilt math carries no SwiftUI type. `--raster-golden` asserts the two
    /// agree element-for-element across the angle matrix.
    struct Homography: Equatable, Sendable {
        var m11: CGFloat = 1, m12: CGFloat = 0, m13: CGFloat = 0
        var m21: CGFloat = 0, m22: CGFloat = 1, m23: CGFloat = 0
        var m31: CGFloat = 0, m32: CGFloat = 0, m33: CGFloat = 1

        static let identity = Homography()

        init() {}

        /// `CGAffineTransform` is row-vector too: x' = a·x + c·y + tx.
        init(_ t: CGAffineTransform) {
            m11 = t.a;  m12 = t.b;  m13 = 0
            m21 = t.c;  m22 = t.d;  m23 = 0
            m31 = t.tx; m32 = t.ty; m33 = 1
        }

        /// Applies the row-vector homography to a point, with the perspective
        /// divide: `(x, y, 1) · M`, then /w.
        func applied(to p: CGPoint) -> CGPoint {
            let w = p.x * m13 + p.y * m23 + m33
            guard abs(w) > 0.000_001 else { return p }
            return CGPoint(
                x: (p.x * m11 + p.y * m21 + m31) / w,
                y: (p.x * m12 + p.y * m22 + m32) / w
            )
        }

        /// The 3×3 inverse (adjugate / determinant) — maps a WARPED on-screen
        /// point back onto the unwarped plane. `nil` when singular. This is
        /// what hit-testing needs: the user clicks the shape where it is
        /// DRAWN, and the geometry lives where it was AUTHORED.
        func inverted() -> Homography? {
            let a = m11, b = m12, c = m13
            let d = m21, e = m22, f = m23
            let g = m31, h = m32, i = m33
            let det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
            guard abs(det) > 0.000_000_001 else { return nil }
            var r = Homography()
            r.m11 = (e * i - f * h) / det
            r.m12 = (c * h - b * i) / det
            r.m13 = (b * f - c * e) / det
            r.m21 = (f * g - d * i) / det
            r.m22 = (a * i - c * g) / det
            r.m23 = (c * d - a * f) / det
            r.m31 = (d * h - e * g) / det
            r.m32 = (b * g - a * h) / det
            r.m33 = (a * e - b * d) / det
            return r
        }

        /// `self` first, then `other` — the row-vector product `self · other`.
        func concatenating(_ o: Homography) -> Homography {
            var r = Homography()
            r.m11 = m11 * o.m11 + m12 * o.m21 + m13 * o.m31
            r.m12 = m11 * o.m12 + m12 * o.m22 + m13 * o.m32
            r.m13 = m11 * o.m13 + m12 * o.m23 + m13 * o.m33
            r.m21 = m21 * o.m11 + m22 * o.m21 + m23 * o.m31
            r.m22 = m21 * o.m12 + m22 * o.m22 + m23 * o.m32
            r.m23 = m21 * o.m13 + m22 * o.m23 + m23 * o.m33
            r.m31 = m31 * o.m11 + m32 * o.m21 + m33 * o.m31
            r.m32 = m31 * o.m12 + m32 * o.m22 + m33 * o.m32
            r.m33 = m31 * o.m13 + m32 * o.m23 + m33 * o.m33
            return r
        }
    }

    /// Homography for the roll → pitch/yaw rotation about `center`, in a
    /// Y-DOWN coordinate space.
    static func projectionTransform(
        pitchDegrees: Double,
        yawDegrees: Double,
        rollDegrees: Double,
        center: CGPoint,
        distance: CGFloat
    ) -> Homography {
        guard max(abs(pitchDegrees), abs(yawDegrees), abs(rollDegrees)) > 0.01 else {
            return Homography.identity
        }
        let sa = CGFloat(sin(pitchDegrees * .pi / 180))
        let ca = CGFloat(cos(pitchDegrees * .pi / 180))
        let sb = CGFloat(sin(yawDegrees * .pi / 180))
        let cb = CGFloat(cos(yawDegrees * .pi / 180))

        // Row-vector convention: (x, y, 1)·M, so mRC maps input R → output C.
        var m = Homography()
        m.m11 = cb
        m.m21 = -sa * sb
        m.m12 = 0
        m.m22 = ca
        m.m13 = -sb / distance
        m.m23 = -sa * cb / distance

        let roll = Homography(CGAffineTransform(rotationAngle: rollDegrees * .pi / 180))
        let toCenter = Homography(CGAffineTransform(translationX: -center.x, y: -center.y))
        let fromCenter = Homography(CGAffineTransform(translationX: center.x, y: center.y))
        return toCenter.concatenating(roll).concatenating(m).concatenating(fromCenter)
    }

    /// Projects a single point through the same skew. `yUp: true` for Core
    /// Image coordinates (export), `false` for SwiftUI (preview). The yUp
    /// path mirrors into Y-down space and back so both look identical.
    static func projectedPoint(
        _ point: CGPoint,
        center: CGPoint,
        pitchDegrees: Double,
        yawDegrees: Double,
        rollDegrees: Double,
        distance: CGFloat,
        yUp: Bool
    ) -> CGPoint {
        let sa = CGFloat(sin(pitchDegrees * .pi / 180))
        let ca = CGFloat(cos(pitchDegrees * .pi / 180))
        let sb = CGFloat(sin(yawDegrees * .pi / 180))
        let cb = CGFloat(cos(yawDegrees * .pi / 180))
        let sg = CGFloat(sin(rollDegrees * .pi / 180))
        let cg = CGFloat(cos(rollDegrees * .pi / 180))

        let dx = point.x - center.x
        let dy0 = point.y - center.y
        let dy = yUp ? -dy0 : dy0 // work in Y-down space

        // Roll (in-plane), then pitch/yaw with perspective divide.
        let x1 = dx * cg - dy * sg
        let y1 = dx * sg + dy * cg
        let w = 1 - (sb * x1) / distance - (sa * cb * y1) / distance
        guard w > 0.01 else { return point }
        let xOut = (x1 * cb - y1 * sa * sb) / w
        let yOut = (y1 * ca) / w

        return CGPoint(x: center.x + xOut, y: center.y + (yUp ? -yOut : yOut))
    }
}

extension CATransform3D {
    /// Maps the row-vector homography (3×3 with perspective in m13/m23) onto
    /// CA's 4×4 — m13/m23 land in m14/m24, translation in m4x. Shared by the
    /// AppKit tilt pad and the CA preview compositor.
    init(_ p: TiltMath.Homography) {
        self = CATransform3DIdentity
        m11 = p.m11; m12 = p.m12; m14 = p.m13
        m21 = p.m21; m22 = p.m22; m24 = p.m23
        m41 = p.m31; m42 = p.m32; m44 = p.m33
    }
}
