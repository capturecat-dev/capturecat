import Foundation
import CoreGraphics

enum ZoomFocalMath {
    /// Card-position excursion bound (canvas fractions, centre-relative,
    /// Y-down). ±1.5 lets the card centre travel one-and-a-half canvases
    /// away — fully off-canvas in any direction even at high zoom.
    /// Composition is the user's business, not the clamp's ("allow me to
    /// place anywhere"); the bound exists only so a corrupt value cannot
    /// fling the card to infinity. SHARED source of truth: the interaction
    /// drag clamp, the MCP schema bounds and this file's target clamps must
    /// all quote it — a tighter copy anywhere reintroduces the "stuck at
    /// the edge" drag.
    static let cardOffsetLimit: Double = 1.5

    /// Clamp a card-offset component to the shared excursion bound.
    static func clampCardOffset(_ v: Double) -> Double {
        min(cardOffsetLimit, max(-cardOffsetLimit, v))
    }

    /// Per-tick zoom-region targets, SHARED by the preview motion model and
    /// the exporter's camera-path simulation (they had drifted into copies).
    struct RegionTargets {
        var zoom: Double
        var focal: CGPoint
        var envelope: Double
        /// Spring frequency multiplier from the block's animation style.
        var omegaMultiplier: Double = 1
        /// Spring damping (zeta) from the block's animation style.
        var damping: Double = 0.88
        /// Card position excursion target, canvas fractions, Y-down.
        var offset: CGPoint = .zero
        /// Whether the focal may blend toward the cursor (block's
        /// followsCursor; false = fixed focus).
        var cursorFollow: Bool = true
    }

    /// Carried spring memory between ticks: the outgoing block's focal AND
    /// its animation style, so both the framing and the FEEL of the zoom-out
    /// match the block that started it.
    struct RegionMemory {
        var focal = CGPoint(x: 0.5, y: 0.5)
        var omegaMultiplier: Double = 1
        var damping: Double = 0.88
        var cursorFollow = true
    }

    /// Return-leg stiffness, blended over TIME through the ramp-out window.
    /// A constant 1.25× floor released a Slow Glide block with 5× the
    /// acceleration of its own push-in — the "click" at the start of every
    /// zoom-out. Blending by zoom POSITION fixed the click but self-trapped:
    /// a Cinematic block returned at its own crawl speed, so the zoom barely
    /// moved, so the stiffness never ramped — on a short clip it never
    /// reached centre at all. Time-keyed, the release still starts at the
    /// block's own gentle response (jerk-free) and is guaranteed to reach
    /// the decisive floor by the end of the lead, regardless of style.
    static func returnOmega(
        time: TimeInterval, rampStart: TimeInterval, lead: TimeInterval,
        style: Double
    ) -> Double {
        let floorOmega = max(1.25, style)
        let raw = min(1, max(0, (time - rampStart) / max(0.0001, lead)))
        let eased = raw * raw * (3 - 2 * raw)
        return style + (floorOmega - style) * eased
    }

    /// Rest snap: once the returning zoom is this close to 1× (and slow),
    /// both integrators hard-land it. An exponential tail asymptotically
    /// "arrives" without ever LOOKING arrived — the last frames of a clip
    /// must be exactly the centred rest state, not 98% of it.
    /// Tight on purpose: the snap must be SUB-PIXEL. At 1.5% it was a
    /// visible ~12px jump on a large card — an ugly click at the end of
    /// every zoom-out. 0.4% of an 800px card is ~3px, under the motion
    /// threshold at the speeds the spring still has here.
    static let restSnapZoomEpsilon = 0.004
    static let restSnapVelocityEpsilon = 0.04

    /// C¹-smooth landing for a return-to-rest zoom. A hard snap — even a
    /// sub-pixel one — freezes whatever velocity the spring still carries in
    /// a single frame, and at the speeds a 1.25×-response return arrives with
    /// that reads as a click. Instead, once the zoom is inside `restLandingBand`
    /// of 1×, an exponential pull takes over from the spring: position and
    /// velocity both decay continuously, so motion tapers to nothing rather
    /// than stopping. The terminal snap below is truly invisible: 0.04% of the
    /// card, at near-zero velocity.
    /// The pull's strength ramps in with depth into the band (smoothstep from
    /// 0 at the band edge to full at rest). A constant-strength pull kicked in
    /// with a one-frame 3× acceleration at band entry — measured −2.05px/frame
    /// → −6.53px/frame on a 1500px card — which read as exactly the snap it
    /// was meant to remove. Ramped, per-frame motion tapers monotonically to
    /// sub-half-pixel before the terminal snap.
    static let restLandingBand = 0.02
    static func settleTowardRest(zoom: inout Double, velocity: inout Double, dt: Double) {
        let depth = 1 - min(1, abs(zoom - 1) / restLandingBand)
        let weight = depth * depth * (3 - 2 * depth)
        let decay = exp(-10.0 * weight * dt)
        zoom = 1 + (zoom - 1) * decay
        velocity *= decay
        if abs(zoom - 1) < 0.0002, abs(velocity) < 0.005 {
            zoom = 1
            velocity = 0
        }
    }

    /// Same smooth landing for any channel returning to zero (tilt degrees,
    /// offsets). Without it the tilt return was still 4.5° skewed when the
    /// zoom landed and crept toward flat for seconds — an exponential tail
    /// that never visibly arrives.
    static func settleTowardZero(
        _ value: inout Double, _ velocity: inout Double,
        dt: Double, band: Double
    ) {
        guard abs(value) < band else { return }
        let depth = 1 - abs(value) / band
        let weight = depth * depth * (3 - 2 * depth)
        let decay = exp(-10.0 * weight * dt)
        value *= decay
        velocity *= decay
        if abs(value) < band * 0.02, abs(velocity) < band * 0.5 {
            value = 0
            velocity = 0
        }
    }

    /// Background parallax: the backdrop drifts gently with the zoom — scale
    /// `1` at rest, growing with zoom by `strength` (0…1). Deliberately
    /// subtle: 12% of the zoom excess at full strength.
    static func parallaxScale(zoom: Double, strength: Double) -> CGFloat {
        let s = max(0, min(1, strength))
        return CGFloat(1 + max(0, zoom - 1) * 0.12 * s)
    }

    /// The region-focal driving the blend at `time`: the ACTIVE region's
    /// focal — or, while the zoom is still gliding back to rest, the focal of
    /// the region that just ended (held in `lastRegionFocal`). Retargeting
    /// the focal to centre the instant a block ends swings the camera
    /// sideways on its way out; holding the outgoing focal makes the return
    /// glide straight back to the middle, because at zoom 1 the focal has no
    /// influence and the landing is centred by construction.
    static func regionTargets(
        zoomRegions: [ZoomRegion],
        at time: TimeInterval,
        currentZoom: Double,
        animationDuration: Double = 0.8,
        memory: inout RegionMemory
    ) -> RegionTargets {
        for region in zoomRegions
        where time >= region.startTime && time <= region.endTime {
            let style = region.animationStyle
            memory.focal = region.focalPoint
            memory.omegaMultiplier = style?.omegaMultiplier ?? 1
            memory.damping = style?.damping ?? 0.88
            memory.cursorFollow = region.followsCursor ?? true

            // The ramp-out lives INSIDE the block: within the final lead the
            // target flips to rest, so the camera is HOME the moment the
            // block ends — not starting the trip home. Without this, a block
            // near the clip's end leaves the final frames visibly zoomed
            // (the spring's return needs more runway than remains).
            let lead = TiltMath.rampOutLead(
                blockStart: region.startTime, blockEnd: region.endTime,
                animationDuration: animationDuration)
            if time > region.endTime - lead {
                // Eased release: the target itself glides from the block's
                // values to rest (TiltMath.rampOutScale) so the spring never
                // gets a step to chase — zero acceleration at the release,
                // S-curve motion, exact rest at the ramp's end.
                let scale = TiltMath.rampOutScale(
                    time: time, blockStart: region.startTime,
                    blockEnd: region.endTime, animationDuration: animationDuration)
                let offset = CGPoint(
                    x: clampCardOffset(region.cardOffsetX ?? 0) * scale,
                    y: clampCardOffset(region.cardOffsetY ?? 0) * scale
                )
                return RegionTargets(
                    zoom: 1 + (region.zoomLevel - 1) * scale,
                    focal: region.focalPoint, envelope: 1,
                    omegaMultiplier: returnOmega(
                        time: time, rampStart: region.endTime - lead,
                        lead: lead, style: memory.omegaMultiplier),
                    damping: min(memory.damping, 0.95),
                    offset: offset,
                    cursorFollow: memory.cursorFollow
                )
            }
            let offset = CGPoint(
                x: clampCardOffset(region.cardOffsetX ?? 0),
                y: clampCardOffset(region.cardOffsetY ?? 0)
            )
            return RegionTargets(
                zoom: region.zoomLevel, focal: region.focalPoint, envelope: 1,
                omegaMultiplier: memory.omegaMultiplier, damping: memory.damping,
                offset: offset,
                cursorFollow: memory.cursorFollow
            )
        }
        // Between regions but the spring hasn't settled: keep the outgoing
        // framing and cursor blend alive until the zoom lands — but the
        // RETURN leg never responds slower than the default. A Slow Glide /
        // Cinematic block should ease IN slowly and still land decisively:
        // at 0.6–0.75× response the critically-damped tail visibly never
        // reaches centre inside a short clip.
        //
        // The rest threshold matches the snap epsilon: the focal only
        // retargets to centre once zoom is EXACTLY 1, where a focal change
        // has zero visual effect — flipping it at 5% residual zoom yanked
        // the final moments of every zoom-out sideways.
        // Past the block entirely: the ramp window is over, so the return
        // runs at the full decisive floor — no style may crawl here.
        if abs(currentZoom - 1) > restSnapZoomEpsilon {
            return RegionTargets(
                zoom: 1, focal: memory.focal, envelope: 1,
                omegaMultiplier: max(1.25, memory.omegaMultiplier),
                damping: min(memory.damping, 0.95),
                cursorFollow: memory.cursorFollow
            )
        }
        return RegionTargets(zoom: 1, focal: CGPoint(x: 0.5, y: 0.5), envelope: 0)
    }

    static func clampedUnitPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: max(0, min(1, point.x)),
            y: max(0, min(1, point.y))
        )
    }

    static func cursorFollowBlend(for zoom: Double) -> CGFloat {
        // Ramp cursor-follow in gradually — Screen Studio keeps region focal
        // dominant at low zoom levels and only fully tracks cursor at higher zoom.
        let start: Double = 1.0
        let full: Double = 1.5
        let t = max(0, min(1, (zoom - start) / (full - start)))
        let smooth = t * t * (3 - 2 * t) // smoothstep
        return CGFloat(smooth)
    }

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> CGFloat {
        guard edge1 > edge0 else { return x <= edge0 ? 0 : 1 }
        let t = max(0, min(1, (x - edge0) / (edge1 - edge0)))
        let smooth = t * t * (3 - 2 * t)
        return CGFloat(smooth)
    }

    static func blendedFocalPoint(
        regionFocal: CGPoint,
        cursorPosition: CGPoint?,
        displayWidth: CGFloat,
        displayHeight: CGFloat,
        zoom: Double,
        envelope: Double = 1.0,
        followCursor: Bool = true
    ) -> CGPoint {
        let region = clampedUnitPoint(regionFocal)
        // Fixed focus: the user aimed this block explicitly (on-canvas focal
        // target) — cursor-follow must not fight the aim.
        guard followCursor, let cursorPosition, displayWidth > 0, displayHeight > 0 else {
            return region
        }

        let cursor = CGPoint(
            x: max(0, min(1, cursorPosition.x / displayWidth)),
            y: max(0, min(1, cursorPosition.y / displayHeight))
        )
        // Allow cursor-follow during the transition with a soft gate.
        // Hard-gating at envelope==1 causes visible "lag then catch-up".
        let envelopeGate = smoothstep(0.2, 0.85, envelope)
        let blend = cursorFollowBlend(for: zoom) * envelopeGate

        return CGPoint(
            x: region.x + (cursor.x - region.x) * blend,
            y: region.y + (cursor.y - region.y) * blend
        )
    }

    static func temporalSmoothFocal(
        target: CGPoint,
        previous: CGPoint?,
        deltaTime: TimeInterval,
        smoothCursor: Bool,
        smoothingFactor: Double,
        zoom: Double = 1.0
    ) -> CGPoint {
        guard let previous else { return clampedUnitPoint(target) }

        let dt = max(1.0 / 240.0, min(0.2, deltaTime))

        // When zoomed: heavy "weighted camera" smoothing so the view pans
        // slowly and cinematically instead of chasing every cursor twitch.
        // tau = ~0.30s at 1× rising to ~0.45s at 2× — far slower than the
        // old ~0.05s that made any cursor movement snap through.
        let tau: Double
        if zoom > 1.01 {
            let zoomExtra = min(1.0, zoom - 1.0)   // 0 at 1×, 1 at 2×
            tau = 0.30 + zoomExtra * 0.15
        } else {
            let factor = max(0.0, min(1.0, smoothingFactor))
            tau = smoothCursor ? max(0.02, 0.055 - factor * 0.025) : 0.028
        }

        let targetPoint = clampedUnitPoint(target)
        let alpha = CGFloat(1 - exp(-dt / tau))

        return CGPoint(
            x: previous.x + (targetPoint.x - previous.x) * alpha,
            y: previous.y + (targetPoint.y - previous.y) * alpha
        )
    }

    static func scaledRect(
        _ rect: CGRect,
        scale: Double,
        anchor: CGPoint
    ) -> CGRect {
        let safeScale = CGFloat(max(scale, 0.01))
        guard abs(safeScale - 1) > .ulpOfOne else { return rect }

        return CGRect(
            x: anchor.x + (rect.minX - anchor.x) * safeScale,
            y: anchor.y + (rect.minY - anchor.y) * safeScale,
            width: rect.width * safeScale,
            height: rect.height * safeScale
        )
    }
}
