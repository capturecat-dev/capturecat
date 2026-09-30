import Foundation
import CoreGraphics

// Verbatim oracles for the "CameraMotion" cluster — Swift math that only
// exists INLINE (VideoExporter.export locals) or as `private` members, so the
// golden vectors cannot call it directly. Each oracle is a byte-for-byte copy
// of the cited source at commit da569841c7b63175bffa46d897457f157224774d; if
// the source changes, re-copy it (the coordinator's `--web-parity-fixtures`
// cross-checks WebCameraPathOracle against the REAL exporter's
// `CAPTURECAT_DUMP_CAMERA=1` dump, so drift is caught).

/// Top-level alias so callers can name the key type unqualified too.
typealias WebCameraKey = WebCameraPathOracle.WebCameraKey

/// VERBATIM oracle of the exporter's per-frame camera path:
/// Services/VideoExporter.swift lines 410–614 (the spring state vars,
/// `tiltSpringTarget`, `tiltRegionTarget`, `combinedTiltKey` and the
/// `cameraPath` map) + `private struct CameraKey` (line 3922), at
/// da569841c7b63175bffa46d897457f157224774d.
///
/// The only adaptations are the inputs the exporter computes earlier in
/// `export(...)`: `settings` (= project.settings), `cursorSmoother`
/// (= CursorSmoother(factor: settings.smoothingFactor)), `displayWidth` /
/// `displayHeight` (= the resolved, menu-bar-crop-scaled cursor coordinate
/// size), `cursorEvents` (already crop-shifted), `scrollTimes` (sorted), and
/// `outputFrameTimes` as seconds (`CMTime.seconds` of `exportFrameTimes`) —
/// the fileprivate `Double.seconds` below keeps the copied body byte-identical.
/// TS port: apps/web/src/editor/core/math/exportCameraPath.ts.
enum WebCameraPathOracle {
    /// `VideoExporter.CameraKey` (line 3922), same fields and defaults.
    struct WebCameraKey: Equatable {
        var zoom: Double
        var focalX: Double
        var focalY: Double
        /// Card position excursion, canvas fractions, Y-down (preview space).
        var offsetX: Double = 0
        var offsetY: Double = 0
        // Final combined skew angles for the frame (mode skew + tilt regions).
        var tiltPitch: Double = 0
        var tiltYaw: Double = 0
        var tiltRoll: Double = 0
    }

    static func cameraPath(
        project: Project,
        outputFrameTimes: [Double],
        timelineSourceTimes: [Double],
        cursorEvents: [CursorEvent],
        displaySize: CGSize,
        scrollTimes: [TimeInterval]
    ) -> [WebCameraKey] {
        typealias CameraKey = WebCameraKey
        let settings = project.settings
        let cursorSmoother = CursorSmoother(factor: settings.smoothingFactor)
        let displayWidth = displaySize.width
        let displayHeight = displaySize.height

        // ── BEGIN verbatim VideoExporter.swift 410–614 ──────────────────────
        // Pre-compute the camera path using the same spring physics as PreviewView
        // so the exported video matches the editor preview exactly.
        let animDur = max(0.2, settings.animationSpeed.duration)
        var springZoom     = 1.0;  var springZoomVel  = 0.0
        var springOffsetX  = 0.0;  var springOffsetVelX = 0.0
        var springOffsetY  = 0.0;  var springOffsetVelY = 0.0
        var springFocalX   = 0.5;  var springFocalY   = 0.5
        var springRegionMemory = ZoomFocalMath.RegionMemory()
        var springFocalVelX = 0.0; var springFocalVelY = 0.0
        var lastSpringTime: TimeInterval? = nil

        // Screen skew — mirrors PreviewView: a sprung normalized 0…1 amount
        // for zoomed-out modes (scaling all three angles together), plus a
        // deterministic intro envelope keyed to OUTPUT time (t=0 = trim start).
        let tiltMode = settings.screenTiltMode
        let tiltPitch = settings.screenTiltAngle
        let tiltYaw = settings.screenTiltYaw
        let tiltRoll = settings.screenTiltRoll
        let tiltActive = (tiltMode != .off
            && max(abs(tiltPitch), abs(tiltYaw), abs(tiltRoll)) > 0.01)
            || !project.tiltRegions.isEmpty
        _ = tiltActive // consumed later in the real export loop, not by the camera path
        var springTilt = 0.0; var springTiltVel = 0.0
        // Timeline tilt-region springs (degrees per axis, matching PreviewView)
        var springRegionPitch = 0.0; var springRegionPitchVel = 0.0
        var springTiltStyleMemory: (omega: Double, damping: Double) = (1, 0.88)
        var springRegionYaw = 0.0; var springRegionYawVel = 0.0
        var springRegionRoll = 0.0; var springRegionRollVel = 0.0
        func tiltSpringTarget(forZoomTarget targetZoom: Double) -> Double {
            guard tiltMode == .zoomedOut || tiltMode == .both else { return 0 }
            return targetZoom > 1.0 ? 0 : 1
        }
        func tiltRegionTarget(at t: TimeInterval) -> (pitch: Double, yaw: Double, roll: Double) {
            for region in project.tiltRegions {
                if t >= region.startTime && t <= region.endTime {
                    // Same eased in-block ramp-out as the zoom (see
                    // PreviewMotionModel / TiltMath.rampOutScale).
                    let scale = TiltMath.rampOutScale(
                        time: t, blockStart: region.startTime,
                        blockEnd: region.endTime, animationDuration: animDur)
                    return (region.pitch * scale, region.yaw * scale, region.roll * scale)
                }
            }
            return (0, 0, 0)
        }
        func combinedTiltKey(zoom: Double, focalX: Double, focalY: Double, atOutputTime outputTime: Double) -> CameraKey {
            var amount = (tiltMode == .zoomedOut || tiltMode == .both) ? springTilt : 0
            if tiltMode == .intro || tiltMode == .both {
                amount = max(amount, TiltMath.introAmount(at: outputTime, animationDuration: animDur))
            }
            amount = max(0, min(1, amount))
            return CameraKey(
                zoom: zoom, focalX: focalX, focalY: focalY,
                offsetX: springOffsetX, offsetY: springOffsetY,
                tiltPitch: amount * tiltPitch + springRegionPitch,
                tiltYaw: amount * tiltYaw + springRegionYaw,
                tiltRoll: amount * tiltRoll + springRegionRoll
            )
        }

        let cameraPath = timelineSourceTimes.enumerated().map { frameIdx, t -> CameraKey in

            // Discrete zoom target — SHARED with PreviewMotionModel.targets
            // via ZoomFocalMath.regionTargets, including the held outgoing
            // focal that makes the zoom-out glide straight back to centre.
            let regionTargets = ZoomFocalMath.regionTargets(
                zoomRegions: project.zoomRegions,
                at: t,
                currentZoom: springZoom,
                animationDuration: animDur,
                memory: &springRegionMemory
            )
            let targetZoom = regionTargets.zoom

            // Cursor-blended focal target (spring provides all smoothing) —
            // held steady during scroll bursts, same rule as the preview.
            let scrolling = scrollTimes.isEmpty ? false : {
                var lo = 0, hi = scrollTimes.count - 1
                while lo < hi {
                    let mid = (lo + hi) / 2
                    if scrollTimes[mid] < t { lo = mid + 1 } else { hi = mid }
                }
                var best = abs(scrollTimes[lo] - t)
                if lo > 0 { best = min(best, abs(scrollTimes[lo - 1] - t)) }
                return best < 0.35
            }()
            let cursorPos: CGPoint? = (scrolling || cursorEvents.isEmpty) ? nil
                : cursorSmoother.interpolateIfFresh(events: cursorEvents, at: t)
            let focalTarget = ZoomFocalMath.blendedFocalPoint(
                regionFocal: regionTargets.focal,
                cursorPosition: cursorPos,
                displayWidth: displayWidth,
                displayHeight: displayHeight,
                zoom: springZoom,
                envelope: regionTargets.envelope,
                followCursor: regionTargets.cursorFollow
            )

            guard let lastTime = lastSpringTime else {
                springZoom   = targetZoom
                springOffsetX = regionTargets.offset.x
                springOffsetY = regionTargets.offset.y
                springFocalX = focalTarget.x
                springFocalY = focalTarget.y
                springTilt   = tiltSpringTarget(forZoomTarget: targetZoom)
                let regionTarget = tiltRegionTarget(at: t)
                springRegionPitch = regionTarget.pitch
                springRegionYaw = regionTarget.yaw
                springRegionRoll = regionTarget.roll
                lastSpringTime = t
                return combinedTiltKey(zoom: springZoom, focalX: springFocalX, focalY: springFocalY,
                                       atOutputTime: outputFrameTimes[frameIdx].seconds)
            }

            let dt = t - lastTime
            lastSpringTime = t

            if dt > 0 && dt <= 0.35 {
                // Zoom spring — per-block animation style sets response
                // and damping, identical to PreviewMotionModel.
                let zOmega = 2.5 / animDur * regionTargets.omegaMultiplier
                let zZeta  = regionTargets.damping
                let zAcc   = zOmega * zOmega * (targetZoom - springZoom)
                           - 2 * zZeta * zOmega * springZoomVel
                springZoomVel += zAcc * dt
                // Floor matches PreviewMotionModel's (scale-down effects go
                // to 0.3) — the old 0.85 clamped shrinks in EXPORT only.
                springZoom     = max(0.25, springZoom + springZoomVel * dt)
                // Smooth landing — see ZoomFocalMath.settleTowardRest.
                if targetZoom == 1,
                   abs(springZoom - 1) < ZoomFocalMath.restLandingBand {
                    ZoomFocalMath.settleTowardRest(
                        zoom: &springZoom, velocity: &springZoomVel, dt: dt)
                }

                // Card offset — same spring as the zoom, so the slide and the
                // push move as one gesture (identical to PreviewMotionModel).
                let oxAcc = zOmega * zOmega * (regionTargets.offset.x - springOffsetX)
                          - 2 * zZeta * zOmega * springOffsetVelX
                let oyAcc = zOmega * zOmega * (regionTargets.offset.y - springOffsetY)
                          - 2 * zZeta * zOmega * springOffsetVelY
                springOffsetVelX += oxAcc * dt
                springOffsetVelY += oyAcc * dt
                springOffsetX += springOffsetVelX * dt
                springOffsetY += springOffsetVelY * dt

                // Focal spring — overdamped, slow weighted-camera pan
                // Shared follow-speed formula with PreviewMotionModel.
                let fOmega = 5.5 * (0.4 + 1.2 * max(0, min(1, settings.cameraFollowSpeed)))
                let fZeta = 0.90
                let fxAcc  = fOmega * fOmega * (focalTarget.x - springFocalX)
                           - 2 * fZeta * fOmega * springFocalVelX
                let fyAcc  = fOmega * fOmega * (focalTarget.y - springFocalY)
                           - 2 * fZeta * fOmega * springFocalVelY
                springFocalVelX += fxAcc * dt
                springFocalVelY += fyAcc * dt
                springFocalX = max(0, min(1, springFocalX + springFocalVelX * dt))
                springFocalY = max(0, min(1, springFocalY + springFocalVelY * dt))

                // Tilt springs — same response as zoom, matching PreviewView
                let tiltTarget = tiltSpringTarget(forZoomTarget: targetZoom)
                let tAcc = zOmega * zOmega * (tiltTarget - springTilt)
                         - 2 * zZeta * zOmega * springTiltVel
                springTiltVel += tAcc * dt
                springTilt    += springTiltVel * dt

                let regionTarget = tiltRegionTarget(at: t)
                // Per-tilt-block animation style — identical resolution to
                // PreviewMotionModel via the ONE boundary-smooth resolver
                // (omega blends across the ramp-out to the exact post-block
                // floor; nothing steps the frame the block ends).
                let tiltParams = TiltMath.tiltReturnParams(
                    tiltRegions: project.tiltRegions, at: t,
                    animationDuration: animDur, memory: &springTiltStyleMemory)
                let tiltReturning = tiltParams.returning
                let rOmegaMult = tiltParams.omega
                let rZeta = tiltParams.damping
                let rOmega = 2.5 / animDur * rOmegaMult
                func springStep(_ value: inout Double, _ vel: inout Double, toward target: Double) {
                    let acc = rOmega * rOmega * (target - value) - 2 * rZeta * rOmega * vel
                    vel += acc * dt
                    value += vel * dt
                }
                springStep(&springRegionPitch, &springRegionPitchVel, toward: regionTarget.pitch)
                springStep(&springRegionYaw, &springRegionYawVel, toward: regionTarget.yaw)
                springStep(&springRegionRoll, &springRegionRollVel, toward: regionTarget.roll)
                if tiltReturning {
                    ZoomFocalMath.settleTowardZero(&springRegionPitch, &springRegionPitchVel, dt: dt, band: 1.5)
                    ZoomFocalMath.settleTowardZero(&springRegionYaw, &springRegionYawVel, dt: dt, band: 1.5)
                    ZoomFocalMath.settleTowardZero(&springRegionRoll, &springRegionRollVel, dt: dt, band: 1.5)
                }
            } else {
                // Large jump (trimmed segment boundary): snap
                springZoom = targetZoom; springZoomVel = 0
                springFocalX = focalTarget.x; springFocalVelX = 0
                springFocalY = focalTarget.y; springFocalVelY = 0
                springTilt = tiltSpringTarget(forZoomTarget: targetZoom); springTiltVel = 0
                let regionTarget = tiltRegionTarget(at: t)
                springRegionPitch = regionTarget.pitch; springRegionPitchVel = 0
                springRegionYaw = regionTarget.yaw; springRegionYawVel = 0
                springRegionRoll = regionTarget.roll; springRegionRollVel = 0
            }

            return combinedTiltKey(zoom: springZoom, focalX: springFocalX, focalY: springFocalY,
                                   atOutputTime: outputFrameTimes[frameIdx].seconds)
        }
        // ── END verbatim VideoExporter.swift 410–614 ────────────────────────

        return cameraPath
    }

    /// `cameraPath` flattened to `[zoom, focalX, focalY, offsetX, offsetY,
    /// tiltPitch, tiltYaw, tiltRoll]` rows — the exact shape of the
    /// `WebParityFixtures.cameraOracle` hook:
    /// `WebParityFixtures.cameraOracle = WebCameraPathOracle.cameraPathRows`.
    static func cameraPathRows(
        _ project: Project,
        _ outputFrameTimes: [Double],
        _ timelineSourceTimes: [Double],
        _ cursorEvents: [CursorEvent],
        _ displaySize: CGSize,
        _ scrollTimes: [TimeInterval]
    ) -> [[Double]] {
        cameraPath(
            project: project, outputFrameTimes: outputFrameTimes,
            timelineSourceTimes: timelineSourceTimes, cursorEvents: cursorEvents,
            displaySize: displaySize, scrollTimes: scrollTimes
        ).map { [$0.zoom, $0.focalX, $0.focalY, $0.offsetX, $0.offsetY, $0.tiltPitch, $0.tiltYaw, $0.tiltRoll] }
    }
}

/// Lets the verbatim body keep `outputFrameTimes[frameIdx].seconds` (the
/// exporter's are CMTimes; the oracle takes their seconds).
fileprivate extension Double {
    var seconds: Double { self }
}

// MARK: - Private-helper oracles

/// VERBATIM oracles of `private` helpers that the TS ports export:
/// - `ZoomFocalMath.smoothstep(_:_:_:)` — Services/ZoomFocalMath.swift 238–243
/// - `IntroSlideMath.easeOutBack(_:bounce:)`, `pulling(_:_:bounce:)`,
///   `arriving(_:_:startScale:startPitch:)` — Services/IntroSlideMath.swift 127–164
/// - `MotionBlurMath.mappedCenter(_:)` — Services/MotionBlurMath.swift 63–68
/// all at da569841c7b63175bffa46d897457f157224774d.
enum CameraMotionHelperOracle {
    static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> CGFloat {
        guard edge1 > edge0 else { return x <= edge0 ? 0 : 1 }
        let t = max(0, min(1, (x - edge0) / (edge1 - edge0)))
        let smooth = t * t * (3 - 2 * t)
        return CGFloat(smooth)
    }

    // IntroSlideMath (uses the REAL public constants).
    typealias State = IntroSlideMath.State
    static let travel = IntroSlideMath.travel
    static let depthStartScale = IntroSlideMath.depthStartScale
    static let depthStartPitch = IntroSlideMath.depthStartPitch

    static func easeOutBack(_ p: Double, bounce: Double) -> Double {
        let c1 = 3.4 * max(0, min(1, bounce))
        let c3 = c1 + 1
        return 1 + c3 * pow(p - 1, 3) + c1 * pow(p - 1, 2)
    }

    static func pulling(_ p: Double, _ v: CGPoint, bounce: Double) -> State {
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

    static func arriving(
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

    static func mappedCenter(_ s: MotionBlurMath.CameraSample) -> (x: Double, y: Double) {
        let q = 0.5
        let x = s.focalX + s.zoom * (q - s.focalX) + s.offsetX
        let y = s.focalY + s.zoom * (q - s.focalY) + s.offsetY
        return (x, y)
    }
}
