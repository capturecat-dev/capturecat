import Foundation
import CoreGraphics
import Observation

/// The preview's camera-motion state machine — zoom/focal/tilt springs —
/// extracted from PreviewView so the SwiftUI preview and the CoreAnimation
/// compositor (AppKit Phase 4) step the IDENTICAL integrators. Pure Swift:
/// no SwiftUI, no AppKit. @Observable so SwiftUI re-renders on spring steps
/// exactly as it did when these were @State vars.
///
/// Every constant and update rule in here is a verbatim port of the original
/// PreviewView spring code; the exporter's camera pre-pass mirrors the same
/// math. Do not tune one consumer without the others.
@Observable
final class PreviewMotionModel {
    /// Inputs the springs need each tick — assembled by the owner from the
    /// project + settings. `cursorEvents` are the EFFECTIVE events (already
    /// shifted for the Hidden-menu-bar crop), `coordinateSize` the resolved
    /// (and crop-scaled) cursor coordinate space.
    struct Env {
        var currentTime: TimeInterval
        var zoomRegions: [ZoomRegion]
        var tiltRegions: [TiltRegion]
        var animationDuration: Double
        var screenTiltMode: ProjectSettings.ScreenTiltMode
        var smoothingFactor: Double
        var followSpeed: Double = 0.5
        /// Sorted scroll-tick timestamps — the camera holds its aim during a
        /// scroll burst instead of chasing the (parked) cursor's jitter.
        var scrollTimes: [TimeInterval] = []
        var cursorEvents: [CursorEvent]
        var coordinateSize: CGSize
    }

    // Spring state — zoom
    private(set) var zoom: Double = 1.0
    private var zoomVel: Double = 0.0
    // Spring state — focal
    private(set) var focalX: Double = 0.5
    private(set) var focalY: Double = 0.5
    private var focalVelX: Double = 0.0
    private var focalVelY: Double = 0.0
    /// Focal + animation style of the most recent zoom region — held while
    /// the zoom glides back to rest (see ZoomFocalMath.regionTargets).
    private var regionMemory = ZoomFocalMath.RegionMemory()
    // Spring state — card position excursion (canvas fractions, Y-down)
    private(set) var cardOffsetX: Double = 0
    private var cardOffsetVelX: Double = 0
    private(set) var cardOffsetY: Double = 0
    private var cardOffsetVelY: Double = 0

    var cardOffset: CGPoint { CGPoint(x: cardOffsetX, y: cardOffsetY) }
    /// Spring style of the most recent TILT region (TiltMath.tiltStyleParams).
    private var tiltStyleMemory: (omega: Double, damping: Double) = (1, 0.88)
    // Spring state — screen tilt (normalized 0…1 for the settings-level modes)
    private(set) var tilt: Double = 0.0
    private var tiltVel: Double = 0.0
    // Spring state — timeline tilt regions (degrees, per axis)
    private(set) var regionPitch: Double = 0.0
    private var regionPitchVel: Double = 0.0
    private(set) var regionYaw: Double = 0.0
    private var regionYawVel: Double = 0.0
    private(set) var regionRoll: Double = 0.0
    private var regionRollVel: Double = 0.0
    private var lastTime: TimeInterval?

    var focal: CGPoint { CGPoint(x: focalX, y: focalY) }

    /// Snap to current target instantly (seek, region edit, etc.)
    /// Two-pass: fix zoom first, THEN compute the focal blend — the blend
    /// depends on the current zoom, so a single pass bakes the PRIOR spring
    /// state into the result and reset stops being deterministic (the
    /// SwiftUI preview and the CA compositor would land on different focal
    /// points depending on what each rendered before the reset).
    func reset(env: Env) {
        let (targetZoom, _, _, _, offsetTarget) = targets(env: env)
        zoom = targetZoom
        zoomVel = 0
        cardOffsetX = offsetTarget.x; cardOffsetVelX = 0
        cardOffsetY = offsetTarget.y; cardOffsetVelY = 0
        let (_, focalTarget, _, _, _) = targets(env: env)
        focalX = focalTarget.x
        focalY = focalTarget.y
        focalVelX = 0
        focalVelY = 0
        tilt = tiltSpringTarget(forZoomTarget: targetZoom, env: env)
        tiltVel = 0
        let regionTarget = tiltRegionTarget(env: env)
        regionPitch = regionTarget.pitch; regionPitchVel = 0
        regionYaw = regionTarget.yaw; regionYawVel = 0
        regionRoll = regionTarget.roll; regionRollVel = 0
        lastTime = env.currentTime
    }

    /// One integrator step to `env.currentTime` — call once per time-observer
    /// tick. Verbatim port of PreviewView.updateSpring().
    func step(env: Env) {
        let (targetZoom, focalTarget, zoomOmegaMult, zoomDamping, offsetTarget) = targets(env: env)

        guard let last = lastTime else {
            zoom = targetZoom
            cardOffsetX = offsetTarget.x
            cardOffsetY = offsetTarget.y
            focalX = focalTarget.x
            focalY = focalTarget.y
            tilt = tiltSpringTarget(forZoomTarget: targetZoom, env: env)
            let regionTarget = tiltRegionTarget(env: env)
            regionPitch = regionTarget.pitch
            regionYaw = regionTarget.yaw
            regionRoll = regionTarget.roll
            lastTime = env.currentTime
            return
        }

        let tickDt = env.currentTime - last
        lastTime = env.currentTime

        // On seek / large jump: snap immediately. The threshold is a full
        // second — a LATE tick from a main-thread hitch is not a seek, and
        // snapping on it was a preview-only mid-flight click the exporter
        // could never reproduce (its clock is uniform).
        if tickDt <= 0 || tickDt > 1.0 {
            zoom = targetZoom
            zoomVel = 0
            cardOffsetX = offsetTarget.x; cardOffsetVelX = 0
            cardOffsetY = offsetTarget.y; cardOffsetVelY = 0
            focalX = focalTarget.x
            focalY = focalTarget.y
            focalVelX = 0
            focalVelY = 0
            tilt = tiltSpringTarget(forZoomTarget: targetZoom, env: env)
            tiltVel = 0
            let regionTarget = tiltRegionTarget(env: env)
            regionPitch = regionTarget.pitch; regionPitchVel = 0
            regionYaw = regionTarget.yaw; regionYawVel = 0
            regionRoll = regionTarget.roll; regionRollVel = 0
            return
        }

        // Integrate late ticks in ≤1/60 substeps so the springs catch up
        // along their own curve instead of jumping.
        let substeps = max(1, Int((tickDt * 60).rounded(.up)))
        let subDt = tickDt / Double(substeps)
        for _ in 0..<substeps {
        let dt = subDt

        // ── Zoom spring ───────────────────────────────────────────────────
        // Asymmetric: snappy pop on zoom-in, slow cinematic release on zoom-out.
        let animDur   = max(0.2, env.animationDuration)
        // Per-block animation style scales the spring's response and sets
        // its damping (Snappy pops, Slow Glide/Cinematic never overshoot).
        let zOmega    = 2.5 / animDur * zoomOmegaMult
        let zZeta     = zoomDamping
        let zAcc      = zOmega * zOmega * (targetZoom - zoom)
                      - 2 * zZeta * zOmega * zoomVel
        zoomVel += zAcc * dt
        zoom    += zoomVel * dt
        zoom     = max(0.25, zoom) // safety floor (scale-down effects go to 0.3)
        // Smooth landing — see ZoomFocalMath.settleTowardRest.
        if targetZoom == 1, abs(zoom - 1) < ZoomFocalMath.restLandingBand {
            ZoomFocalMath.settleTowardRest(zoom: &zoom, velocity: &zoomVel, dt: dt)
        }

        // ── Tilt springs ──────────────────────────────────────────────────
        // Same response as zoom so skews flatten in step with zoom transitions.
        let tiltTarget = tiltSpringTarget(forZoomTarget: targetZoom, env: env)
        let tAcc      = zOmega * zOmega * (tiltTarget - tilt)
                      - 2 * zZeta * zOmega * tiltVel
        tiltVel += tAcc * dt
        tilt    += tiltVel * dt

        let regionTarget = tiltRegionTarget(env: env)
        // Timeline tilt blocks carry their OWN animation style (shared enum
        // with zoom blocks). Boundary-smooth return parameters come from the
        // ONE shared resolver — omega blends across the in-block ramp-out to
        // the exact post-block floor, so nothing steps the frame the block
        // ends (the "clicks after it ends" bug). Exporter twin: identical
        // call in the cameraPath loop.
        let tiltParams = TiltMath.tiltReturnParams(
            tiltRegions: env.tiltRegions, at: env.currentTime,
            animationDuration: animDur, memory: &tiltStyleMemory)
        let tiltReturning = tiltParams.returning
        let rOmegaMult = tiltParams.omega
        let rZeta = tiltParams.damping
        let rOmega = 2.5 / animDur * rOmegaMult
        func springStep(_ value: inout Double, _ vel: inout Double, toward target: Double) {
            let acc = rOmega * rOmega * (target - value) - 2 * rZeta * rOmega * vel
            vel += acc * dt
            value += vel * dt
        }
        springStep(&regionPitch, &regionPitchVel, toward: regionTarget.pitch)
        springStep(&regionYaw, &regionYawVel, toward: regionTarget.yaw)
        springStep(&regionRoll, &regionRollVel, toward: regionTarget.roll)
        if tiltReturning {
            ZoomFocalMath.settleTowardZero(&regionPitch, &regionPitchVel, dt: dt, band: 1.5)
            ZoomFocalMath.settleTowardZero(&regionYaw, &regionYawVel, dt: dt, band: 1.5)
            ZoomFocalMath.settleTowardZero(&regionRoll, &regionRollVel, dt: dt, band: 1.5)
        }
        // Card offset rides the ZOOM spring (slide and push are one gesture)
        // — the exporter already did; the preview had forked onto the tilt
        // spring, invisibly, because both default to (1, 0.88).
        let oxAcc = zOmega * zOmega * (Double(offsetTarget.x) - cardOffsetX)
                  - 2 * zZeta * zOmega * cardOffsetVelX
        let oyAcc = zOmega * zOmega * (Double(offsetTarget.y) - cardOffsetY)
                  - 2 * zZeta * zOmega * cardOffsetVelY
        cardOffsetVelX += oxAcc * dt; cardOffsetX += cardOffsetVelX * dt
        cardOffsetVelY += oyAcc * dt; cardOffsetY += cardOffsetVelY * dt

        // ── Focal spring ──────────────────────────────────────────────────
        // Slow, overdamped (zeta = 0.90) so the view pans like a weighted
        // camera, absorbing cursor jitter rather than chasing every twitch.
        // Follow speed: 0 → weighted/slow (2.2), 0.5 → the historical 5.5,
        // 1 → tight (8.8). Shared formula with the exporter.
        let fOmega   = 5.5 * (0.4 + 1.2 * max(0, min(1, env.followSpeed)))
        let fZeta    = 0.90
        let fxAcc    = fOmega * fOmega * (focalTarget.x - focalX)
                     - 2 * fZeta * fOmega   * focalVelX
        let fyAcc    = fOmega * fOmega * (focalTarget.y - focalY)
                     - 2 * fZeta * fOmega   * focalVelY
        focalVelX += fxAcc * dt
        focalVelY += fyAcc * dt
        focalX = max(0, min(1, focalX + focalVelX * dt))
        focalY = max(0, min(1, focalY + focalVelY * dt))
        } // substep loop
    }

    /// Reconstructs the spring state at an arbitrary timeline position so a
    /// paused scrub shows the same in-flight zoom/tilt animation as playback.
    /// Replaying a bounded history is fast enough for mouse tracking and avoids
    /// the old seek behaviour, which snapped straight to the region target on
    /// backward or large jumps.
    func scrub(env targetEnv: Env, from projectStart: TimeInterval) {
        let targetTime = targetEnv.currentTime
        let history = max(3.0, targetEnv.animationDuration * 5.0)
        let replayStart = max(projectStart, targetTime - history)
        var env = targetEnv
        env.currentTime = replayStart
        reset(env: env)

        let tick = 1.0 / 60.0
        var time = replayStart
        while time + tick < targetTime {
            time += tick
            env.currentTime = time
            step(env: env)
        }
        if time < targetTime {
            env.currentTime = targetTime
            step(env: env)
        }
    }

    // MARK: - Targets (verbatim ports)

    /// Discrete zoom target and cursor-blended focal for the current time.
    private func targets(env: Env) -> (zoom: Double, focal: CGPoint, omegaMultiplier: Double, damping: Double, offset: CGPoint) {
        // Shared with the exporter's camera path (ZoomFocalMath.regionTargets)
        // — including the held outgoing focal that makes a zoom-out glide
        // straight back to the middle instead of swinging via centre.
        let region = ZoomFocalMath.regionTargets(
            zoomRegions: env.zoomRegions,
            at: env.currentTime,
            currentZoom: zoom,
            animationDuration: env.animationDuration,
            memory: &regionMemory
        )

        // Cursor-blended focal target (instantaneous — spring provides smoothing).
        // During a scroll burst (a tick within 0.35s) the camera holds its
        // aim: the cursor sits still while content moves, and chasing its
        // micro-jitter reads as swimming.
        let scrolling = nearestScroll(to: env.currentTime, in: env.scrollTimes) < 0.35
        let cursorPosition: CGPoint?
        if scrolling {
            cursorPosition = nil
        } else if !env.cursorEvents.isEmpty {
            let smoother = CursorSmoother(factor: env.smoothingFactor)
            cursorPosition = smoother.interpolateIfFresh(events: env.cursorEvents, at: env.currentTime)
        } else {
            cursorPosition = nil
        }
        let cs = env.coordinateSize
        let focalTarget = ZoomFocalMath.blendedFocalPoint(
            regionFocal: region.focal,
            cursorPosition: cursorPosition,
            displayWidth: cs.width,
            displayHeight: cs.height,
            zoom: zoom,
            envelope: region.envelope,
            followCursor: region.cursorFollow
        )
        return (region.zoom, focalTarget, region.omegaMultiplier, region.damping, region.offset)
    }

    /// Target angles from the timeline TILT track: the active region's angles
    /// inside a region, flat outside. Springs carry the transition.
    private func nearestScroll(to time: TimeInterval, in times: [TimeInterval]) -> TimeInterval {
        guard !times.isEmpty else { return .infinity }
        var lo = 0, hi = times.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if times[mid] < time { lo = mid + 1 } else { hi = mid }
        }
        var best = abs(times[lo] - time)
        if lo > 0 { best = min(best, abs(times[lo - 1] - time)) }
        return best
    }

    private func tiltRegionTarget(env: Env) -> (pitch: Double, yaw: Double, roll: Double) {
        for region in env.tiltRegions {
            if env.currentTime >= region.startTime && env.currentTime <= region.endTime {
                // Same eased in-block ramp-out as the zoom: the TARGET glides
                // to flat (no step for the spring to chase — see
                // TiltMath.rampOutScale) and reaches 0 by the block's end.
                let scale = TiltMath.rampOutScale(
                    time: env.currentTime, blockStart: region.startTime,
                    blockEnd: region.endTime,
                    animationDuration: env.animationDuration)
                return (region.pitch * scale, region.yaw * scale, region.roll * scale)
            }
        }
        return (0, 0, 0)
    }

    /// Skew the card whenever the camera is NOT zoomed in (zoomed-out modes
    /// only). The spring animates a normalized 0…1 amount scaling all three
    /// skew angles together.
    private func tiltSpringTarget(forZoomTarget targetZoom: Double, env: Env) -> Double {
        let mode = env.screenTiltMode
        guard mode == .zoomedOut || mode == .both else { return 0 }
        return targetZoom > 1.0 ? 0 : 1
    }

    // MARK: - Derived tilt (shared by preview + compositor)

    /// Normalized skew amount (0 = flat, 1 = full slider angles). The intro
    /// component is a deterministic envelope, not a spring, so scrubbing
    /// lands on the exact frame the export renders.
    func effectiveTiltAmount(
        mode: ProjectSettings.ScreenTiltMode,
        currentTime: TimeInterval,
        effectiveTrimStart: TimeInterval,
        animationDuration: Double,
        isWithinVisibleVideoClip: Bool
    ) -> Double {
        guard mode != .off, isWithinVisibleVideoClip else { return 0 }
        var amount = (mode == .zoomedOut || mode == .both) ? tilt : 0
        if mode == .intro || mode == .both {
            let t = currentTime - effectiveTrimStart
            amount = max(amount, TiltMath.introAmount(
                at: t,
                animationDuration: animationDuration
            ))
        }
        return max(0, min(1, amount))
    }

    /// Final skew angles: settings-level mode skew + timeline tilt regions.
    func effectiveTiltAngles(
        mode: ProjectSettings.ScreenTiltMode,
        settingsAngle: Double,
        settingsYaw: Double,
        settingsRoll: Double,
        currentTime: TimeInterval,
        effectiveTrimStart: TimeInterval,
        animationDuration: Double,
        isWithinVisibleVideoClip: Bool,
        timelineTiltOverride: (pitch: Double, yaw: Double, roll: Double)? = nil
    ) -> (pitch: Double, yaw: Double, roll: Double) {
        guard isWithinVisibleVideoClip else { return (0, 0, 0) }
        let amount = effectiveTiltAmount(
            mode: mode,
            currentTime: currentTime,
            effectiveTrimStart: effectiveTrimStart,
            animationDuration: animationDuration,
            isWithinVisibleVideoClip: isWithinVisibleVideoClip
        )
        let timelineTilt = timelineTiltOverride
            ?? (pitch: regionPitch, yaw: regionYaw, roll: regionRoll)
        return (
            amount * settingsAngle + timelineTilt.pitch,
            amount * settingsYaw + timelineTilt.yaw,
            amount * settingsRoll + timelineTilt.roll
        )
    }
}
