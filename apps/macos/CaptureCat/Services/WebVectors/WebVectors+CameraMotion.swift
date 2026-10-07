import Foundation
import CoreGraphics
import CoreMedia
import QuartzCore

// Golden-vector units for the "CameraMotion" cluster (see WebVectorsHarness.swift):
// the exporter's per-frame camera path, ZoomFocalMath, TiltMath,
// PreviewMotionModel, Easing, IntroSlideMath and MotionBlurMath.
// TS ports: apps/web/src/editor/core/math/{exportCameraPath,zoomFocalMath,
// tiltMath,previewMotionModel,easing,introSlideMath,motionBlurMath}.ts;
// suite: apps/web/src/editor/core/vectors/cameraMotion.test.ts.
// Inline/private Swift is reached through the VERBATIM oracles in
// WebVectors+CameraMotionOracle.swift.
extension WebVectors {
    static var cameraMotionUnits: [WebVectorUnit] {
        [
            WebVectorUnit(
                name: "exportCameraPath",
                notes: "VERBATIM ORACLE WebCameraPathOracle.cameraPath (WebVectors+CameraMotionOracle.swift) of the inline camera pre-pass in VideoExporter.export — Services/VideoExporter.swift lines 410–614 + CameraKey (line 3922) at da569841c7b63175bffa46d897457f157224774d — over random projects (every ZoomAnimationStyle, followsCursor nil/true/false, card offsets, isAuto, overlapping/adjacent blocks, tilt regions, all screenTiltModes/animationSpeeds, cameraFollowSpeed), 24/25/30/60 fps output frames through speed-mapped source times with injected dt==0 duplicates, backward jumps, >0.35 s jumps, scroll bursts, empty/non-empty cursor paths. Output: the whole per-frame CameraKey array.",
                build: exportCameraPathCases),
            WebVectorUnit(
                name: "zoomFocalMathScalars",
                notes: "Services/ZoomFocalMath.swift — cardOffsetLimit, restSnapZoomEpsilon, restSnapVelocityEpsilon, restLandingBand, clampCardOffset, returnOmega, parallaxScale, clampedUnitPoint, cursorFollowBlend, blendedFocalPoint (+defaults), temporalSmoothFocal (+default zoom), scaledRect",
                build: zoomFocalMathScalarCases),
            WebVectorUnit(
                name: "zoomFocalMathSettle",
                notes: "Services/ZoomFocalMath.swift — settleTowardRest(zoom:velocity:dt:) and settleTowardZero(_:_:dt:band:) as 20-step inout SEQUENCES (state after every call)",
                build: zoomFocalMathSettleCases),
            WebVectorUnit(
                name: "zoomFocalMathRegionTargets",
                notes: "Services/ZoomFocalMath.swift — regionTargets(zoomRegions:at:currentZoom:animationDuration:memory:) as 30-call sequences carrying the inout RegionMemory (targets + memory after every call; default and explicit animationDuration)",
                build: zoomFocalMathRegionTargetCases),
            WebVectorUnit(
                name: "zoomFocalMathSmoothstepOracle",
                notes: "VERBATIM ORACLE CameraMotionHelperOracle.smoothstep of the private ZoomFocalMath.smoothstep(_:_:_:) — Services/ZoomFocalMath.swift 238–243 at da569841c7b63175bffa46d897457f157224774d",
                build: zoomFocalMathSmoothstepOracleCases),
            WebVectorUnit(
                name: "tiltMathScalars",
                notes: "Services/TiltMath.swift — perspectiveDistance, introAmount, springStep, deviceSideOffset, rampOutLead, rampOutScale, coverZoomMultiplier, effectiveCoverZoom",
                build: tiltMathScalarCases),
            WebVectorUnit(
                name: "tiltMathStyleParams",
                notes: "Services/TiltMath.swift — tiltStyleParams(tiltRegions:at:memory:) and tiltReturnParams(tiltRegions:at:animationDuration:memory:) as 30-call sequences carrying their inout (omega, damping) memories",
                build: tiltMathStyleParamCases),
            WebVectorUnit(
                name: "tiltMathHomography",
                notes: "Services/TiltMath.swift — Homography.identity, init(CGAffineTransform), applied(to:) (incl. |w|≈1e-6 guard), inverted() (incl. singular → nil), concatenating(_:)",
                build: tiltMathHomographyCases),
            WebVectorUnit(
                name: "tiltMathProjection",
                notes: "Services/TiltMath.swift — projectionTransform(pitchDegrees:yawDegrees:rollDegrees:center:distance:), projectedPoint(... yUp: false/true), Homography.applied on the projection, and CATransform3D.init(_ p: TiltMath.Homography) (all 16 fields)",
                build: tiltMathProjectionCases),
            WebVectorUnit(
                name: "previewMotionModel",
                notes: "Services/PreviewMotionModel.swift — 48-op SEQUENCES (170 random envs) of reset(env:) / step(env:) (1/120…0.5 s ticks → substeps, 0/negative/>1 s snaps, exactly 1.0 s) / scrub(env:from:) on one model, recording the FULL state after every op (incl. private velocities, RegionMemory, tilt-style memory and lastTime via Mirror) plus effectiveTiltAmount / effectiveTiltAngles (with and without timelineTiltOverride)",
                build: previewMotionModelCases),
            WebVectorUnit(
                name: "easingCurves",
                notes: "Services/EasingFunctions.swift — easeInOutCubic, smootherStep, easeOutCubic, easeInCubic, easeOutQuart, easeOutExpo, spring (defaults + explicit damping/frequency)",
                build: easingCurveCases),
            WebVectorUnit(
                name: "easingEnvelopes",
                notes: "Services/EasingFunctions.swift — regionEnvelope(at:startTime:endTime:transitionDuration:), zoomEnvelope(at:startTime:endTime:transitionDuration:)",
                build: easingEnvelopeCases),
            WebVectorUnit(
                name: "easingZoomLevel",
                notes: "Services/EasingFunctions.swift — zoomLevel(at:regions:transitionDuration:)",
                build: easingZoomLevelCases),
            WebVectorUnit(
                name: "introSlideMath",
                notes: "Services/IntroSlideMath.swift — IntroSlideMath.state(style:at:startTime:duration:bounce:depth:speed:) (+ the all-defaults overload) and IntroSlideStyle.vector",
                build: introSlideMathCases),
            WebVectorUnit(
                name: "introSlideMathHelpersOracle",
                notes: "VERBATIM ORACLE CameraMotionHelperOracle.easeOutBack / pulling / arriving of the private IntroSlideMath helpers — Services/IntroSlideMath.swift 127–164 at da569841c7b63175bffa46d897457f157224774d (uses the real public constants)",
                build: introSlideHelperOracleCases),
            WebVectorUnit(
                name: "motionBlurMath",
                notes: "Services/MotionBlurMath.swift — constants + blur(previous:current:dt:strength:); the `mappedCenter` field is a VERBATIM ORACLE (CameraMotionHelperOracle.mappedCenter) of the private mappedCenter(_:) — MotionBlurMath.swift 63–68 at da569841c7b63175bffa46d897457f157224774d",
                build: motionBlurMathCases),
        ]
    }

    // MARK: - Shared random models

    private static func cmRandomZoomRegions(_ rng: inout WVRandom, span: Double, maxCount: Int = 5) -> [ZoomRegion] {
        let count = rng.int(0, maxCount)
        var regions: [ZoomRegion] = []
        var prevEnd = rng.double(-0.3, 0.6)
        for _ in 0..<count {
            let start: Double = rng.bool(0.3)
                ? prevEnd // adjacent block
                : rng.edgy(-0.5, span, edges: [0, prevEnd - 0.2, span * 0.5])
            let len = rng.edgy(0, min(6, span + 0.5), edges: [0, 0.05, 0.3, 0.8, 1.44, 2.16, 3])
            let style: ZoomAnimationStyle? = rng.bool(0.25) ? nil : rng.pick(ZoomAnimationStyle.allCases)
            let zoomLevel = rng.edgy(0.3, 4, edges: [1, 2, 1.5, 0.5, 1.003, 3])
            let focal = rng.bool(0.15)
                ? CGPoint(x: rng.double(-0.3, 1.3), y: rng.double(-0.3, 1.3))
                : rng.point()
            let offX: Double? = rng.bool(0.5) ? nil : rng.edgy(-2, 2, edges: [0, 1.5, -1.5, 0.3])
            let offY: Double? = rng.bool(0.5) ? nil : rng.edgy(-2, 2, edges: [0, 1.5, -1.5, -0.3])
            let follows: Bool? = rng.pick([nil, true, false])
            let isAuto: Bool? = rng.pick([nil, true, false])
            regions.append(ZoomRegion(
                id: rng.uuid(), startTime: start, endTime: start + len,
                zoomLevel: zoomLevel, focalPoint: focal, animationStyle: style,
                cardOffsetX: offX, cardOffsetY: offY, followsCursor: follows, isAuto: isAuto))
            prevEnd = start + len
        }
        return regions
    }

    private static func cmRandomTiltRegions(_ rng: inout WVRandom, span: Double, maxCount: Int = 3) -> [TiltRegion] {
        let count = rng.int(0, maxCount)
        var regions: [TiltRegion] = []
        var prevEnd = rng.double(-0.3, 0.6)
        for _ in 0..<count {
            let start: Double = rng.bool(0.3)
                ? prevEnd
                : rng.edgy(-0.5, span, edges: [0, prevEnd - 0.2, span * 0.5])
            let len = rng.edgy(0, min(6, span + 0.5), edges: [0, 0.05, 0.8, 1.44, 2.16, 3])
            let style: ZoomAnimationStyle? = rng.bool(0.3) ? nil : rng.pick(ZoomAnimationStyle.allCases)
            let pitch = rng.edgy(-40, 40, edges: [0, 20, -20, 1, 0.5])
            let yaw = rng.edgy(-40, 40, edges: [0, 15, -1])
            let roll = rng.edgy(-30, 30, edges: [0, 5, -0.3])
            regions.append(TiltRegion(
                id: rng.uuid(), startTime: start, endTime: start + len,
                pitch: pitch, yaw: yaw, roll: roll, animationStyle: style))
            prevEnd = start + len
        }
        return regions
    }

    private static func cmRandomScrollTimes(_ rng: inout WVRandom, span: Double) -> [TimeInterval] {
        guard rng.bool(0.5) else { return [] }
        var times: [Double] = []
        for _ in 0..<rng.int(1, 3) {
            var t = rng.double(-0.5, span)
            for _ in 0..<rng.int(1, 12) {
                times.append(t)
                t += rng.pick([0.016, 0.05, 0.1, 0.3, 0.34, 0.5])
            }
        }
        return times.sorted()
    }

    /// Exact-precision twins of `WVModel.zoomRegion` / `WVModel.tiltRegion`
    /// (same TS in-memory shape; nil optionals omitted like the synthesized
    /// encodeIfPresent). WVModel goes through JSONEncoder → JSONSerialization,
    /// which parses numbers as NSDecimalNumber and loses the last bits of some
    /// doubles (-0.011762005244476348 → …344) — fatal for queries that sit
    /// EXACTLY on a region boundary. The key sets are asserted equal to
    /// WVModel's so the shapes cannot drift.
    private static func cmZoomRegionWV(_ r: ZoomRegion) -> WV {
        var wv: WV = [
            "id": .str(r.id.uuidString), "startTime": r.startTime.wv, "endTime": r.endTime.wv,
            "zoomLevel": r.zoomLevel.wv, "focalPoint": r.focalPoint.wv,
        ]
        if let s = r.animationStyle { wv = wv.setting("animationStyle", .str(s.rawValue)) }
        if let v = r.cardOffsetX { wv = wv.setting("cardOffsetX", v.wv) }
        if let v = r.cardOffsetY { wv = wv.setting("cardOffsetY", v.wv) }
        if let v = r.followsCursor { wv = wv.setting("followsCursor", v.wv) }
        if let v = r.isAuto { wv = wv.setting("isAuto", v.wv) }
        cmAssertSameKeys(wv, WVModel.zoomRegion(r), "ZoomRegion")
        return wv
    }

    private static func cmTiltRegionWV(_ r: TiltRegion) -> WV {
        var wv: WV = [
            "id": .str(r.id.uuidString), "startTime": r.startTime.wv, "endTime": r.endTime.wv,
            "pitch": r.pitch.wv, "yaw": r.yaw.wv, "roll": r.roll.wv,
        ]
        if let s = r.animationStyle { wv = wv.setting("animationStyle", .str(s.rawValue)) }
        cmAssertSameKeys(wv, WVModel.tiltRegion(r), "TiltRegion")
        return wv
    }

    private static func cmAssertSameKeys(_ a: WV, _ b: WV, _ what: String) {
        guard case .obj(let pa) = a, case .obj(let pb) = b else {
            fatalError("WEB-VECTORS cameraMotion: \(what) is not an object")
        }
        let ka = Set(pa.map(\.0)), kb = Set(pb.map(\.0))
        precondition(ka == kb, "WEB-VECTORS cameraMotion: \(what) keys \(ka.sorted()) != WVModel \(kb.sorted())")
    }

    private static func cmTargetsWV(_ t: ZoomFocalMath.RegionTargets) -> WV {
        [
            "zoom": t.zoom.wv, "focal": t.focal.wv, "envelope": t.envelope.wv,
            "omegaMultiplier": t.omegaMultiplier.wv, "damping": t.damping.wv,
            "offset": t.offset.wv, "cursorFollow": t.cursorFollow.wv,
        ]
    }

    private static func cmMemoryWV(_ m: ZoomFocalMath.RegionMemory) -> WV {
        [
            "focal": m.focal.wv, "omegaMultiplier": m.omegaMultiplier.wv,
            "damping": m.damping.wv, "cursorFollow": m.cursorFollow.wv,
        ]
    }

    private static func cmHomographyWV(_ h: TiltMath.Homography) -> WV {
        [
            "m11": h.m11.wv, "m12": h.m12.wv, "m13": h.m13.wv,
            "m21": h.m21.wv, "m22": h.m22.wv, "m23": h.m23.wv,
            "m31": h.m31.wv, "m32": h.m32.wv, "m33": h.m33.wv,
        ]
    }

    private static func cmIntroStateWV(_ s: IntroSlideMath.State) -> WV {
        ["offset": s.offset.wv, "scale": s.scale.wv, "pitch": s.pitch.wv, "active": s.active.wv]
    }

    // MARK: - exportCameraPath (verbatim oracle)

    private static func exportCameraPathCases() -> [WV] {
        var rng = WVRandom(seed: "exportCameraPath")
        var cases: [WV] = []
        for i in 0..<520 {
            let fixedSpans: [Double] = [0.0001, 0.01, 0.5, 1]
            let span = i < fixedSpans.count ? fixedSpans[i] : (i % 10 == 0 ? rng.edgy(4, 9, edges: [6]) : rng.edgy(0.5, 4, edges: [1.5, 2, 3]))
            let trimStart = rng.edgy(0, 2, edges: [0])
            let p = Project(id: rng.uuid(), name: "v", duration: trimStart + span + 1)
            p.zoomRegions = cmRandomZoomRegions(&rng, span: trimStart + span, maxCount: i % 9 == 0 ? 0 : 5)
            p.tiltRegions = cmRandomTiltRegions(&rng, span: trimStart + span)
            let s = p.settings
            s.animationSpeed = rng.pick(ProjectSettings.AnimationSpeed.allCases)
            s.screenTiltMode = rng.pick(ProjectSettings.ScreenTiltMode.allCases)
            s.screenTiltAngle = rng.edgy(-35, 35, edges: [0, 12, -8])
            s.screenTiltYaw = rng.edgy(-35, 35, edges: [0, 10])
            s.screenTiltRoll = rng.edgy(-20, 20, edges: [0, -4])
            s.cameraFollowSpeed = rng.edgy(0, 1, edges: [0, 0.5, 1, -0.3, 1.4])
            s.smoothingFactor = rng.edgy(0.02, 1, edges: [0.15])

            let fps = rng.pick([30, 60, 24, 25])
            let speedRegions: [VideoSpeedRegion] = (0..<rng.int(0, 3)).map { _ in
                let a = rng.double(trimStart, trimStart + span)
                let len = rng.edgy(0.1, span * 0.5 + 0.2, edges: [0.5, 1])
                let speed = rng.pick([0.25, 0.5, 2, 4, 8, 12, 16, 1.5])
                return VideoSpeedRegion(id: rng.uuid(), startTime: a, endTime: a + len, speed: speed)
            }
            let map = SpeedTimeMap(sourceStart: trimStart, sourceEnd: trimStart + span, regions: speedRegions)
            // The exporter's exportFrameTimes(duration:fps:startOffset:) cadence.
            let totalSeconds = max(0.0001, map.outputDuration)
            let safeFPS = max(1, fps)
            let totalFrames = max(1, Int(ceil(max(0, totalSeconds) * Double(safeFPS))))
            let outputFrameTimes: [Double] = (0..<totalFrames).map { index in
                CMTime(seconds: Double(index) / Double(safeFPS), preferredTimescale: 600).seconds
            }
            var sourceTimes = outputFrameTimes.map { map.sourceTime(forOutput: $0) }
            // Inject the discontinuities real exports hit (cuts, duplicates).
            if rng.bool(0.4) {
                for _ in 0..<rng.int(1, 4) {
                    guard sourceTimes.count > 3 else { break }
                    let k = rng.int(1, sourceTimes.count - 1)
                    switch rng.int(0, 4) {
                    case 0:
                        sourceTimes[k] = sourceTimes[k - 1] // dt == 0
                    case 1:
                        let jump = rng.pick([0.35, 0.36, 0.6, 2.0])
                        for j in k..<sourceTimes.count { sourceTimes[j] += jump }
                    case 2:
                        let jump = rng.pick([0.2, 0.5, 3.0])
                        for j in k..<sourceTimes.count { sourceTimes[j] -= jump }
                    case 3:
                        let delta = 0.35 - (sourceTimes[k] - sourceTimes[k - 1])
                        for j in k..<sourceTimes.count { sourceTimes[j] += delta }
                    default:
                        sourceTimes[k] += 1.0
                    }
                }
            }

            let cursorCount = rng.bool(0.2) ? 0 : rng.int(2, 160)
            var events = randomCursorEvents(&rng, count: cursorCount)
            if rng.bool(0.3), let first = events.first {
                let shift = trimStart - first.timestamp + rng.double(-0.5, 1)
                events = events.map { CursorEvent(timestamp: $0.timestamp + shift, x: $0.x, y: $0.y, isClick: $0.isClick) }
            }
            let displaySize: CGSize = rng.bool(0.8)
                ? CGSize(width: 1512, height: 982)
                : rng.pick([CGSize(width: 0, height: 982), CGSize(width: 2880, height: 1800 * 0.9),
                            CGSize(width: 800, height: 0), CGSize(width: 1170, height: 2532)])
            let scrollTimes = cmRandomScrollTimes(&rng, span: trimStart + span)

            let keys = WebCameraPathOracle.cameraPath(
                project: p, outputFrameTimes: outputFrameTimes, timelineSourceTimes: sourceTimes,
                cursorEvents: events, displaySize: displaySize, scrollTimes: scrollTimes)

            cases.append(vcase(
                [
                    "zoomRegions": .arr(p.zoomRegions.map(cmZoomRegionWV)),
                    "tiltRegions": .arr(p.tiltRegions.map(cmTiltRegionWV)),
                    "settings": [
                        "animationSpeed": .str(s.animationSpeed.rawValue),
                        "screenTiltMode": .str(s.screenTiltMode.rawValue),
                        "screenTiltAngle": s.screenTiltAngle.wv,
                        "screenTiltYaw": s.screenTiltYaw.wv,
                        "screenTiltRoll": s.screenTiltRoll.wv,
                        "cameraFollowSpeed": s.cameraFollowSpeed.wv,
                    ],
                    "outputFrameTimes": outputFrameTimes.wv,
                    "timelineSourceTimes": sourceTimes.wv,
                    "cursorEvents": .arr(events.map(WVModel.cursorEvent)),
                    "displayWidth": displaySize.width.wv,
                    "displayHeight": displaySize.height.wv,
                    "scrollTimes": scrollTimes.wv,
                ],
                .arr(keys.map {
                    [
                        "zoom": $0.zoom.wv, "focalX": $0.focalX.wv, "focalY": $0.focalY.wv,
                        "offsetX": $0.offsetX.wv, "offsetY": $0.offsetY.wv,
                        "tiltPitch": $0.tiltPitch.wv, "tiltYaw": $0.tiltYaw.wv, "tiltRoll": $0.tiltRoll.wv,
                    ]
                })
            ))
        }
        // Degenerate: no frames at all.
        let empty = Project(id: rng.uuid(), name: "v", duration: 1)
        let none = WebCameraPathOracle.cameraPath(
            project: empty, outputFrameTimes: [], timelineSourceTimes: [],
            cursorEvents: [], displaySize: .zero, scrollTimes: [])
        cases.append(vcase(
            [
                "zoomRegions": [], "tiltRegions": [],
                "settings": [
                    "animationSpeed": .str(empty.settings.animationSpeed.rawValue),
                    "screenTiltMode": .str(empty.settings.screenTiltMode.rawValue),
                    "screenTiltAngle": empty.settings.screenTiltAngle.wv,
                    "screenTiltYaw": empty.settings.screenTiltYaw.wv,
                    "screenTiltRoll": empty.settings.screenTiltRoll.wv,
                    "cameraFollowSpeed": empty.settings.cameraFollowSpeed.wv,
                ],
                "outputFrameTimes": [], "timelineSourceTimes": [], "cursorEvents": [],
                "displayWidth": 0.0, "displayHeight": 0.0, "scrollTimes": [],
            ],
            .arr(none.map { $0.zoom.wv })
        ))
        return cases
    }

    // MARK: - ZoomFocalMath

    private static func zoomFocalMathScalarCases() -> [WV] {
        var rng = WVRandom(seed: "zoomFocalMathScalars")
        var cases: [WV] = []
        let specials: [Double] = [0, -0.0, 1.5, -1.5, 1.5000000000000002, -1.4999999999999998, .nan, .infinity, -.infinity, 1e300]
        let ulp = Double.ulpOfOne
        for i in 0..<2200 {
            let v = i < specials.count ? specials[i] : rng.edgy(-3, 3, edges: [1.5, -1.5, 0, 1e9, -1e9])
            // returnOmega
            let time = rng.edgy(-1, 10, edges: [0])
            let rampStart = rng.edgy(-1, 10, edges: [time, time - 0.0001, time + 1])
            let lead = rng.edgy(-0.1, 2, edges: [0, 0.0001, 0.00005, 0.4, -1])
            let style = rng.edgy(0, 10, edges: [1, 8, 1.5, 0.75, 0.6, 1.25])
            // parallaxScale
            let pz = rng.edgy(0, 5, edges: [1, 0.5, 1.0000001])
            let ps = rng.edgy(-0.5, 1.5, edges: [0, 1, 0.5])
            // clampedUnitPoint / cursorFollowBlend
            let pt = rng.point(-0.5, 1.5)
            let cz = rng.edgy(0.5, 2, edges: [1, 1.5, 1.25, 0.9999999])
            // blendedFocalPoint
            let regionFocal = rng.point(-0.3, 1.3)
            let cursor: CGPoint? = rng.bool(0.2) ? nil : CGPoint(x: rng.double(-200, 1800), y: rng.double(-200, 1200))
            let dw = CGFloat(rng.edgy(-10, 2000, edges: [0, 1512, 1]))
            let dh = CGFloat(rng.edgy(-10, 1200, edges: [0, 982]))
            let bz = rng.edgy(0.5, 3, edges: [1, 1.5])
            let envelope = rng.edgy(-0.2, 1.2, edges: [0.2, 0.85, 1, 0, 0.5])
            let follow = rng.bool(0.8)
            // temporalSmoothFocal
            let target = rng.point(-0.3, 1.3)
            let previous: CGPoint? = rng.bool(0.15) ? nil : rng.point(0, 1)
            let deltaTime = rng.edgy(-0.1, 0.5, edges: [0, 1.0 / 240, 0.2, 1.0 / 60])
            let smoothCursor = rng.bool()
            let smoothingFactor = rng.edgy(-0.5, 1.5, edges: [0, 1, 0.15])
            let tz = rng.edgy(0.5, 3, edges: [1, 1.01, 1.0100001, 2, 2.5])
            // scaledRect
            let rect = CGRect(
                x: rng.double(-500, 500), y: rng.double(-500, 500),
                width: rng.edgy(-300, 800, edges: [0]), height: rng.edgy(-300, 800, edges: [0]))
            let scale = rng.edgy(-1, 4, edges: [1, 1 + ulp, 1 + 2 * ulp, 1 - ulp / 2, 0.01, 0, 0.005, 2])
            let anchor = rng.point(-500, 500)

            var output: WV = [
                "clampCardOffset": ZoomFocalMath.clampCardOffset(v).wv,
                "returnOmega": ZoomFocalMath.returnOmega(time: time, rampStart: rampStart, lead: lead, style: style).wv,
                "parallaxScale": ZoomFocalMath.parallaxScale(zoom: pz, strength: ps).wv,
                "clampedUnitPoint": ZoomFocalMath.clampedUnitPoint(pt).wv,
                "cursorFollowBlend": ZoomFocalMath.cursorFollowBlend(for: cz).wv,
                "blendedFocalPoint": ZoomFocalMath.blendedFocalPoint(
                    regionFocal: regionFocal, cursorPosition: cursor, displayWidth: dw, displayHeight: dh,
                    zoom: bz, envelope: envelope, followCursor: follow).wv,
                "blendedFocalPointDefaults": ZoomFocalMath.blendedFocalPoint(
                    regionFocal: regionFocal, cursorPosition: cursor, displayWidth: dw, displayHeight: dh,
                    zoom: bz).wv,
                "temporalSmoothFocal": ZoomFocalMath.temporalSmoothFocal(
                    target: target, previous: previous, deltaTime: deltaTime,
                    smoothCursor: smoothCursor, smoothingFactor: smoothingFactor, zoom: tz).wv,
                "temporalSmoothFocalDefaultZoom": ZoomFocalMath.temporalSmoothFocal(
                    target: target, previous: previous, deltaTime: deltaTime,
                    smoothCursor: smoothCursor, smoothingFactor: smoothingFactor).wv,
                "scaledRect": ZoomFocalMath.scaledRect(rect, scale: scale, anchor: anchor).wv,
            ]
            if i == 0 {
                output = output.setting("constants", [
                    "cardOffsetLimit": ZoomFocalMath.cardOffsetLimit.wv,
                    "restSnapZoomEpsilon": ZoomFocalMath.restSnapZoomEpsilon.wv,
                    "restSnapVelocityEpsilon": ZoomFocalMath.restSnapVelocityEpsilon.wv,
                    "restLandingBand": ZoomFocalMath.restLandingBand.wv,
                ])
            }
            cases.append(vcase(
                [
                    "v": v.wv,
                    "time": time.wv, "rampStart": rampStart.wv, "lead": lead.wv, "style": style.wv,
                    "parallaxZoom": pz.wv, "parallaxStrength": ps.wv,
                    "point": pt.wv, "blendZoom": cz.wv,
                    "regionFocal": regionFocal.wv, "cursorPosition": cursor.wv,
                    "displayWidth": dw.wv, "displayHeight": dh.wv, "zoom": bz.wv,
                    "envelope": envelope.wv, "followCursor": follow.wv,
                    "target": target.wv, "previous": previous.wv, "deltaTime": deltaTime.wv,
                    "smoothCursor": smoothCursor.wv, "smoothingFactor": smoothingFactor.wv, "smoothZoom": tz.wv,
                    "rect": rect.wv, "scale": scale.wv, "anchor": anchor.wv,
                ],
                output
            ))
        }
        return cases
    }

    private static func zoomFocalMathSettleCases() -> [WV] {
        var rng = WVRandom(seed: "zoomFocalMathSettle")
        var cases: [WV] = []
        for _ in 0..<800 {
            let zoom0 = rng.edgy(0.97, 1.03, edges: [1, 1.0002, 0.9998, 1.02, 0.98, 1.0199, 1.5, 0.5, 1.00019])
            let vel0 = rng.edgy(-0.5, 0.5, edges: [0, 0.005, -0.005, 0.004, 0.0049])
            let dts: [Double] = (0..<20).map { _ in rng.edgy(0, 0.1, edges: [1.0 / 60, 1.0 / 30, 0, 0.35, -0.01]) }
            var zoom = zoom0, vel = vel0
            var restSeq: [WV] = []
            for dt in dts {
                ZoomFocalMath.settleTowardRest(zoom: &zoom, velocity: &vel, dt: dt)
                restSeq.append(["zoom": zoom.wv, "velocity": vel.wv])
            }
            let value0 = rng.edgy(-2, 2, edges: [0, 1.5, -1.5, 1.4999, 0.03, -0.029, 0.0299])
            let v20 = rng.edgy(-1, 1, edges: [0, 0.75, -0.74, 0.7499])
            let band = rng.edgy(0, 3, edges: [1.5, 0, -1, 0.5])
            var value = value0, v2 = v20
            var zeroSeq: [WV] = []
            for dt in dts {
                ZoomFocalMath.settleTowardZero(&value, &v2, dt: dt, band: band)
                zeroSeq.append(["value": value.wv, "velocity": v2.wv])
            }
            cases.append(vcase(
                ["zoom": zoom0.wv, "velocity": vel0.wv, "dts": dts.wv,
                 "value": value0.wv, "valueVelocity": v20.wv, "band": band.wv],
                ["rest": .arr(restSeq), "zero": .arr(zeroSeq)]
            ))
        }
        return cases
    }

    private static func zoomFocalMathRegionTargetCases() -> [WV] {
        var rng = WVRandom(seed: "zoomFocalMathRegionTargets")
        var cases: [WV] = []
        for _ in 0..<520 {
            let span = rng.edgy(1, 10, edges: [4])
            let regions = cmRandomZoomRegions(&rng, span: span, maxCount: 6)
            let useDefaultDuration = rng.bool(0.15)
            let animDur = rng.edgy(0, 1.5, edges: [0.3, 0.5, 0.8, 1.2, 0.2])
            let effDur = useDefaultDuration ? 0.8 : animDur
            var memory = ZoomFocalMath.RegionMemory()
            if rng.bool(0.3) {
                memory.focal = rng.point(-0.2, 1.2)
                memory.omegaMultiplier = rng.pick([1, 8, 1.5, 0.75, 0.6, 3.3])
                memory.damping = rng.pick([0.88, 1, 0.72, 1.05, 0.97])
                memory.cursorFollow = rng.bool()
            }
            let initialMemory = cmMemoryWV(memory)
            let edges: [Double] = regions.flatMap { r -> [Double] in
                let lead = TiltMath.rampOutLead(blockStart: r.startTime, blockEnd: r.endTime, animationDuration: effDur)
                return [r.startTime, r.endTime, r.endTime - lead, (r.endTime - lead).nextUp, r.endTime - lead * 0.5]
            }
            var queries: [WV] = []
            var outs: [WV] = []
            for _ in 0..<30 {
                let t = rng.edgy(-0.5, span + 0.5, edges: edges, edgeP: 0.35)
                let z = rng.edgy(0.2, 4, edges: [1, 1.004, 0.996, 1.0041, 1.0039, 2])
                let targets = useDefaultDuration
                    ? ZoomFocalMath.regionTargets(zoomRegions: regions, at: t, currentZoom: z, memory: &memory)
                    : ZoomFocalMath.regionTargets(
                        zoomRegions: regions, at: t, currentZoom: z, animationDuration: animDur, memory: &memory)
                queries.append(["time": t.wv, "currentZoom": z.wv])
                outs.append(["targets": cmTargetsWV(targets), "memory": cmMemoryWV(memory)])
            }
            cases.append(vcase(
                [
                    "zoomRegions": .arr(regions.map(cmZoomRegionWV)),
                    "animationDuration": useDefaultDuration ? .null : animDur.wv,
                    "memory": initialMemory,
                    "queries": .arr(queries),
                ],
                .arr(outs)
            ))
        }
        return cases
    }

    private static func zoomFocalMathSmoothstepOracleCases() -> [WV] {
        var rng = WVRandom(seed: "zoomFocalMathSmoothstepOracle")
        var cases: [WV] = []
        for i in 0..<800 {
            let e0 = rng.edgy(-1, 1, edges: [0.2, 0, 0.5])
            let e1 = i % 7 == 0 ? e0 : (i % 11 == 0 ? e0 - rng.double(0, 1) : rng.edgy(e0, e0 + 2, edges: [0.85, 1]))
            let x = rng.edgy(e0 - 1, e1 + 1, edges: [e0, e1, 0.5])
            cases.append(vcase(
                ["edge0": e0.wv, "edge1": e1.wv, "x": x.wv],
                CameraMotionHelperOracle.smoothstep(e0, e1, x).wv
            ))
        }
        return cases
    }

    // MARK: - TiltMath

    private static func tiltMathScalarCases() -> [WV] {
        var rng = WVRandom(seed: "tiltMathScalars")
        var cases: [WV] = []
        let angleEdges: [Double] = [0, 0.01, 0.0099, 0.0100001, 57.29577951308232, 60, -45, 90, -90, 20]
        for _ in 0..<2200 {
            let size = CGSize(width: rng.edgy(-100, 3000, edges: [0, 1, 0.5]),
                              height: rng.edgy(-100, 3000, edges: [0, 1, 2]))
            let introTime = rng.edgy(-1, 10, edges: [0, -0.0, 1e-9, 100, 1000])
            let introDur = rng.edgy(0, 2, edges: [0.3, 0.5, 0.8, 1.2, 0.2, 0.1, 0])
            let st = rng.edgy(-1, 5, edges: [0, 1e-9])
            let response = rng.edgy(0, 2, edges: [0.05, 0.01, 0.42, 0.28])
            let damping = rng.edgy(-0.5, 1.5, edges: [0.9, 1, 0.999, 0.01, 0, 0.68])
            let dsPitch = rng.edgy(-90, 90, edges: [0, 20])
            let dsYaw = rng.edgy(-90, 90, edges: [0, -15])
            let videoWidth = CGFloat(rng.edgy(0, 2000, edges: [0, 54.5, 100, 54.54545454545454]))
            let blockStart = rng.edgy(-1, 10, edges: [0])
            let blockEnd = rng.bool(0.1) ? blockStart - rng.double(0, 1) : blockStart + rng.edgy(0, 6, edges: [0, 0.8, 1.44, 2.88])
            let animDur = rng.edgy(0, 1.5, edges: [0.3, 0.5, 0.8, 1.2, 0.2])
            let lead = TiltMath.rampOutLead(blockStart: blockStart, blockEnd: blockEnd, animationDuration: animDur)
            let rampTime = rng.edgy(blockStart - 0.5, blockEnd + 0.5,
                                    edges: [blockEnd - lead, (blockEnd - lead).nextUp, blockEnd, blockStart])
            let p = rng.edgy(-90, 90, edges: angleEdges)
            let y = rng.edgy(-90, 90, edges: angleEdges)
            let r = rng.edgy(-180, 180, edges: angleEdges)
            let aspect = CGFloat(rng.edgy(-1, 4, edges: [0.1, 0, 16.0 / 9, 0.05, 1]))
            let zoom = CGFloat(rng.edgy(0.5, 4, edges: [1.001, 1.0010001, 1, 1.6, 1.3]))
            cases.append(vcase(
                [
                    "size": size.wv,
                    "introTime": introTime.wv, "introDuration": introDur.wv,
                    "springT": st.wv, "response": response.wv, "damping": damping.wv,
                    "sidePitch": dsPitch.wv, "sideYaw": dsYaw.wv, "videoWidth": videoWidth.wv,
                    "blockStart": blockStart.wv, "blockEnd": blockEnd.wv, "animationDuration": animDur.wv,
                    "rampTime": rampTime.wv,
                    "pitch": p.wv, "yaw": y.wv, "roll": r.wv, "aspect": aspect.wv, "zoom": zoom.wv,
                ],
                [
                    "perspectiveDistance": TiltMath.perspectiveDistance(for: size).wv,
                    "introAmount": TiltMath.introAmount(at: introTime, animationDuration: introDur).wv,
                    "springStep": TiltMath.springStep(st, response: response, damping: damping).wv,
                    "deviceSideOffset": TiltMath.deviceSideOffset(
                        pitchDegrees: dsPitch, yawDegrees: dsYaw, videoWidth: videoWidth).wv,
                    "rampOutLead": lead.wv,
                    "rampOutScale": TiltMath.rampOutScale(
                        time: rampTime, blockStart: blockStart, blockEnd: blockEnd, animationDuration: animDur).wv,
                    "coverZoomMultiplier": TiltMath.coverZoomMultiplier(
                        pitchDegrees: p, yawDegrees: y, rollDegrees: r, aspect: aspect).wv,
                    "effectiveCoverZoom": TiltMath.effectiveCoverZoom(
                        zoom: zoom, pitchDegrees: p, yawDegrees: y, rollDegrees: r, aspect: aspect).wv,
                ]
            ))
        }
        return cases
    }

    private static func tiltMathStyleParamCases() -> [WV] {
        var rng = WVRandom(seed: "tiltMathStyleParams")
        var cases: [WV] = []
        for _ in 0..<520 {
            let span = rng.edgy(1, 10, edges: [4])
            let regions = cmRandomTiltRegions(&rng, span: span, maxCount: 5)
            let animDur = rng.edgy(0, 1.5, edges: [0.3, 0.5, 0.8, 1.2, 0.2])
            var styleMemory: (omega: Double, damping: Double) = (1, 0.88)
            if rng.bool(0.3) { styleMemory = (rng.pick([1, 8, 1.5, 0.75, 0.6]), rng.pick([0.88, 1, 0.72, 1.05])) }
            var returnMemory = styleMemory
            let initial: WV = ["omega": styleMemory.omega.wv, "damping": styleMemory.damping.wv]
            let edges: [Double] = regions.flatMap { r -> [Double] in
                let lead = TiltMath.rampOutLead(blockStart: r.startTime, blockEnd: r.endTime, animationDuration: animDur)
                return [r.startTime, r.endTime, r.endTime - lead, (r.endTime - lead).nextDown]
            }
            var queries: [WV] = []
            var outs: [WV] = []
            for _ in 0..<30 {
                let t = rng.edgy(-0.5, span + 0.5, edges: edges, edgeP: 0.35)
                let sp = TiltMath.tiltStyleParams(tiltRegions: regions, at: t, memory: &styleMemory)
                let rp = TiltMath.tiltReturnParams(
                    tiltRegions: regions, at: t, animationDuration: animDur, memory: &returnMemory)
                queries.append(t.wv)
                outs.append([
                    "style": ["omega": sp.omega.wv, "damping": sp.damping.wv],
                    "styleMemory": ["omega": styleMemory.omega.wv, "damping": styleMemory.damping.wv],
                    "return": ["omega": rp.omega.wv, "damping": rp.damping.wv, "returning": rp.returning.wv],
                    "returnMemory": ["omega": returnMemory.omega.wv, "damping": returnMemory.damping.wv],
                ])
            }
            cases.append(vcase(
                [
                    "tiltRegions": .arr(regions.map(cmTiltRegionWV)),
                    "animationDuration": animDur.wv,
                    "memory": initial,
                    "times": .arr(queries),
                ],
                .arr(outs)
            ))
        }
        return cases
    }

    private static func tiltMathHomographyCases() -> [WV] {
        var rng = WVRandom(seed: "tiltMathHomography")
        var cases: [WV] = []
        for i in 0..<1500 {
            let affine: CGAffineTransform
            switch rng.int(0, 4) {
            case 0:
                affine = CGAffineTransform(a: rng.double(-3, 3), b: rng.double(-3, 3), c: rng.double(-3, 3),
                                           d: rng.double(-3, 3), tx: rng.double(-900, 900), ty: rng.double(-900, 900))
            case 1:
                affine = CGAffineTransform(rotationAngle: rng.double(-7, 7))
                    .translatedBy(x: rng.double(-500, 500), y: rng.double(-500, 500))
                    .scaledBy(x: rng.double(0.1, 3), y: rng.double(0.1, 3))
            case 2:
                affine = .identity
            case 3:
                let k = rng.double(-2, 2) // singular: second column ∝ first
                let a = rng.double(-2, 2), b = rng.double(-2, 2)
                affine = CGAffineTransform(a: a, b: b, c: a * k, d: b * k, tx: rng.double(-9, 9), ty: rng.double(-9, 9))
            default:
                affine = CGAffineTransform(translationX: rng.double(-900, 900), y: rng.double(-900, 900))
            }
            let h1 = TiltMath.Homography(affine)
            var h2 = TiltMath.Homography()
            h2.m11 = rng.double(-2, 2); h2.m12 = rng.double(-2, 2); h2.m13 = rng.edgy(-0.002, 0.002, edges: [0])
            h2.m21 = rng.double(-2, 2); h2.m22 = rng.double(-2, 2); h2.m23 = rng.edgy(-0.002, 0.002, edges: [0])
            h2.m31 = rng.double(-800, 800); h2.m32 = rng.double(-800, 800); h2.m33 = rng.edgy(0.5, 1.5, edges: [1, 0])
            if i % 13 == 0 { // exactly singular: third row ∝ first
                let k = rng.double(-3, 3)
                h2.m31 = h2.m11 * k; h2.m32 = h2.m12 * k; h2.m33 = h2.m13 * k
            }
            var pts: [CGPoint] = (0..<4).map { _ in rng.point(-2000, 2000) }
            if h2.m13 != 0 { // hit the |w| > 1e-6 guard from both sides
                for w in [0.0, 1e-6, 2e-6, -5e-7] {
                    pts.append(CGPoint(x: (w - h2.m33) / h2.m13, y: 0))
                }
            }
            let inv1 = h1.inverted()
            let inv2 = h2.inverted()
            var output: WV = [
                "fromAffine": cmHomographyWV(h1),
                "appliedAffine": pts.map { h1.applied(to: $0) }.wv,
                "applied": pts.map { h2.applied(to: $0) }.wv,
                "invertedAffine": inv1.map(cmHomographyWV) ?? .null,
                "inverted": inv2.map(cmHomographyWV) ?? .null,
                "concatenating12": cmHomographyWV(h1.concatenating(h2)),
                "concatenating21": cmHomographyWV(h2.concatenating(h1)),
                "roundTrip": inv2.map { inv in pts.map { inv.applied(to: h2.applied(to: $0)) }.wv } ?? .null,
            ]
            if i == 0 { output = output.setting("identity", cmHomographyWV(.identity)) }
            cases.append(vcase(
                ["affine": affine.wv, "homography": cmHomographyWV(h2), "points": pts.wv],
                output
            ))
        }
        return cases
    }

    private static func tiltMathProjectionCases() -> [WV] {
        var rng = WVRandom(seed: "tiltMathProjection")
        var cases: [WV] = []
        let angleEdges: [Double] = [0, 0.01, 0.0100001, 0.0099, 20, -15, 90, -90, 45]
        for _ in 0..<1500 {
            let pitch = rng.edgy(-80, 80, edges: angleEdges)
            let yaw = rng.edgy(-80, 80, edges: angleEdges)
            let roll = rng.edgy(-180, 180, edges: angleEdges)
            let size = CGSize(width: rng.double(10, 3000), height: rng.double(10, 3000))
            let center = rng.bool(0.7) ? CGPoint(x: size.width / 2, y: size.height / 2) : rng.point(-100, 2000)
            let distance: CGFloat = rng.bool(0.85)
                ? TiltMath.perspectiveDistance(for: size)
                : CGFloat(rng.edgy(-100, 5000, edges: [0, 1, 100, 50]))
            let h = TiltMath.projectionTransform(
                pitchDegrees: pitch, yawDegrees: yaw, rollDegrees: roll, center: center, distance: distance)
            let ca = CATransform3D(h)
            let corners = [
                CGPoint(x: 0, y: 0), CGPoint(x: size.width, y: 0),
                CGPoint(x: 0, y: size.height), CGPoint(x: size.width, y: size.height),
            ]
            let pts = corners + (0..<3).map { _ in rng.point(-500, 3000) }
            cases.append(vcase(
                [
                    "pitch": pitch.wv, "yaw": yaw.wv, "roll": roll.wv,
                    "center": center.wv, "distance": distance.wv, "points": pts.wv,
                ],
                [
                    "projection": cmHomographyWV(h),
                    "caTransform3D": [
                        "m11": ca.m11.wv, "m12": ca.m12.wv, "m13": ca.m13.wv, "m14": ca.m14.wv,
                        "m21": ca.m21.wv, "m22": ca.m22.wv, "m23": ca.m23.wv, "m24": ca.m24.wv,
                        "m31": ca.m31.wv, "m32": ca.m32.wv, "m33": ca.m33.wv, "m34": ca.m34.wv,
                        "m41": ca.m41.wv, "m42": ca.m42.wv, "m43": ca.m43.wv, "m44": ca.m44.wv,
                    ],
                    "caTransform3DArray": [
                        ca.m11, ca.m12, ca.m13, ca.m14, ca.m21, ca.m22, ca.m23, ca.m24,
                        ca.m31, ca.m32, ca.m33, ca.m34, ca.m41, ca.m42, ca.m43, ca.m44,
                    ].wv,
                    "appliedProjection": pts.map { h.applied(to: $0) }.wv,
                    "projectedDown": pts.map {
                        TiltMath.projectedPoint($0, center: center, pitchDegrees: pitch, yawDegrees: yaw,
                                                rollDegrees: roll, distance: distance, yUp: false)
                    }.wv,
                    "projectedUp": pts.map {
                        TiltMath.projectedPoint($0, center: center, pitchDegrees: pitch, yawDegrees: yaw,
                                                rollDegrees: roll, distance: distance, yUp: true)
                    }.wv,
                ]
            ))
        }
        return cases
    }

    // MARK: - PreviewMotionModel

    /// Full model state, including the Swift-`private` springs and memories,
    /// read through Mirror (the @Observable storage is `_name`).
    private static func cmPreviewState(_ model: PreviewMotionModel) -> WV {
        var fields: [String: Any] = [:]
        for child in Mirror(reflecting: model).children {
            guard var label = child.label else { continue }
            if label.hasPrefix("_") { label.removeFirst() }
            fields[label] = child.value
        }
        func num(_ key: String) -> WV {
            guard let v = fields[key] as? Double else {
                fatalError("WEB-VECTORS previewMotionModel: Mirror has no Double field \(key) (have \(fields.keys.sorted()))")
            }
            return v.wv
        }
        guard let memory = fields["regionMemory"] as? ZoomFocalMath.RegionMemory else {
            fatalError("WEB-VECTORS previewMotionModel: Mirror has no regionMemory")
        }
        guard let tiltMemory = fields["tiltStyleMemory"] as? (omega: Double, damping: Double) else {
            fatalError("WEB-VECTORS previewMotionModel: Mirror has no tiltStyleMemory")
        }
        guard fields.keys.contains("lastTime") else {
            fatalError("WEB-VECTORS previewMotionModel: Mirror has no lastTime")
        }
        let lastTime: WV = (fields["lastTime"] as? Double).map { .num($0) } ?? .null
        // Cross-check the Mirror read against the public accessors.
        precondition(num("zoom").serialized() == model.zoom.wv.serialized())
        precondition(num("regionRoll").serialized() == model.regionRoll.wv.serialized())
        return [
            "zoom": num("zoom"), "zoomVel": num("zoomVel"),
            "focalX": num("focalX"), "focalY": num("focalY"),
            "focalVelX": num("focalVelX"), "focalVelY": num("focalVelY"),
            "regionMemory": cmMemoryWV(memory),
            "cardOffsetX": num("cardOffsetX"), "cardOffsetVelX": num("cardOffsetVelX"),
            "cardOffsetY": num("cardOffsetY"), "cardOffsetVelY": num("cardOffsetVelY"),
            "tiltStyleMemory": ["omega": tiltMemory.omega.wv, "damping": tiltMemory.damping.wv],
            "tilt": num("tilt"), "tiltVel": num("tiltVel"),
            "regionPitch": num("regionPitch"), "regionPitchVel": num("regionPitchVel"),
            "regionYaw": num("regionYaw"), "regionYawVel": num("regionYawVel"),
            "regionRoll": num("regionRoll"), "regionRollVel": num("regionRollVel"),
            "lastTime": lastTime,
        ]
    }

    private static func previewMotionModelCases() -> [WV] {
        var rng = WVRandom(seed: "previewMotionModel")
        var cases: [WV] = []
        let modes = ProjectSettings.ScreenTiltMode.allCases
        for _ in 0..<170 {
            let span = rng.edgy(2, 10, edges: [4, 6])
            var zoomRegions = cmRandomZoomRegions(&rng, span: span)
            if zoomRegions.isEmpty {
                zoomRegions = [ZoomRegion(id: rng.uuid(), startTime: rng.double(0, span / 2),
                                          endTime: span / 2 + rng.double(0.5, 2), zoomLevel: 2,
                                          focalPoint: rng.point(), animationStyle: rng.pick(ZoomAnimationStyle.allCases))]
            }
            let tiltRegions = cmRandomTiltRegions(&rng, span: span)
            let animDur = rng.pick([1.2, 0.8, 0.5, 0.3, 0.15, 1.0])
            let mode = rng.pick(modes)
            let smoothing = rng.edgy(0.02, 1, edges: [0.15])
            let follow = rng.edgy(-0.2, 1.2, edges: [0, 0.5, 1])
            let scroll = cmRandomScrollTimes(&rng, span: span)
            let events = rng.bool(0.2) ? [] : randomCursorEvents(&rng, count: rng.int(2, 300))
            let coord: CGSize = rng.bool(0.8)
                ? CGSize(width: 1512, height: 982)
                : rng.pick([CGSize.zero, CGSize(width: 800, height: 600), CGSize(width: -1, height: 982)])
            var env = PreviewMotionModel.Env(
                currentTime: 0, zoomRegions: zoomRegions, tiltRegions: tiltRegions,
                animationDuration: animDur, screenTiltMode: mode, smoothingFactor: smoothing,
                followSpeed: follow, scrollTimes: scroll, cursorEvents: events, coordinateSize: coord)
            let model = PreviewMotionModel()

            let starts = zoomRegions.map { $0.startTime - 0.4 } + tiltRegions.map { $0.startTime - 0.3 }
            var time = rng.edgy(-0.5, span, edges: starts, edgeP: 0.6)
            var ops: [WV] = []
            var records: [WV] = []
            for k in 0..<48 {
                var op: WV
                let r = rng.unit()
                if k == 0 && r < 0.5 {
                    env.currentTime = time
                    model.step(env: env) // lastTime == nil path
                    op = ["op": "step", "time": time.wv]
                } else if r < 0.035 {
                    time = rng.edgy(-0.5, span + 0.5, edges: starts)
                    env.currentTime = time
                    model.reset(env: env)
                    op = ["op": "reset", "time": time.wv]
                } else if r < 0.07 {
                    time = rng.edgy(-0.5, span + 0.5, edges: starts)
                    let projectStart = rng.edgy(-1, span, edges: [0, time, time - 1, time - 3.5])
                    env.currentTime = time
                    model.scrub(env: env, from: projectStart)
                    op = ["op": "scrub", "time": time.wv, "projectStart": projectStart.wv]
                } else if k == 0 {
                    env.currentTime = time
                    model.reset(env: env)
                    op = ["op": "reset", "time": time.wv]
                } else {
                    // Typed arrays: the untyped literal ternary trips Xcode 27's
                    // "unable to type-check in reasonable time".
                    let oddSteps: [Double] = [0, -0.1, 1.0, 1.0000001, 1.5, 0.35]
                    let frameSteps: [Double] = [1.0 / 60, 1.0 / 60, 1.0 / 60, 1.0 / 120, 1.0 / 30, 1.0 / 30, 0.05, 0.1, 0.2, 0.5]
                    let dt: Double = rng.bool(0.04) ? rng.pick(oddSteps) : rng.pick(frameSteps)
                    time += dt
                    env.currentTime = time
                    model.step(env: env)
                    op = ["op": "step", "time": time.wv]
                }
                // Derived tilt queries against the new state.
                let qMode = rng.pick(modes)
                let qAngle = rng.edgy(-30, 30, edges: [0, 12])
                let qYaw = rng.edgy(-30, 30, edges: [0])
                let qRoll = rng.edgy(-20, 20, edges: [0])
                let qTime = rng.bool(0.7) ? time : rng.edgy(-1, span, edges: [0])
                let qTrim = rng.edgy(0, 2, edges: [0, time])
                let qDur = rng.pick([animDur, 0.8, 0.1, 1.2])
                let qVisible = rng.bool(0.85)
                let qOverride: (pitch: Double, yaw: Double, roll: Double)? = rng.bool(0.25)
                    ? (rng.double(-20, 20), rng.double(-20, 20), rng.double(-10, 10)) : nil
                let amount = model.effectiveTiltAmount(
                    mode: qMode, currentTime: qTime, effectiveTrimStart: qTrim,
                    animationDuration: qDur, isWithinVisibleVideoClip: qVisible)
                let angles = model.effectiveTiltAngles(
                    mode: qMode, settingsAngle: qAngle, settingsYaw: qYaw, settingsRoll: qRoll,
                    currentTime: qTime, effectiveTrimStart: qTrim, animationDuration: qDur,
                    isWithinVisibleVideoClip: qVisible, timelineTiltOverride: qOverride)
                op = op.setting("query", [
                    "mode": .str(qMode.rawValue), "settingsAngle": qAngle.wv, "settingsYaw": qYaw.wv,
                    "settingsRoll": qRoll.wv, "currentTime": qTime.wv, "effectiveTrimStart": qTrim.wv,
                    "animationDuration": qDur.wv, "isWithinVisibleVideoClip": qVisible.wv,
                    "timelineTiltOverride": qOverride.map { ["pitch": $0.pitch.wv, "yaw": $0.yaw.wv, "roll": $0.roll.wv] } ?? .null,
                ])
                ops.append(op)
                records.append([
                    "state": cmPreviewState(model),
                    "tiltAmount": amount.wv,
                    "tiltAngles": ["pitch": angles.pitch.wv, "yaw": angles.yaw.wv, "roll": angles.roll.wv],
                ])
            }
            cases.append(vcase(
                [
                    "env": [
                        "zoomRegions": .arr(zoomRegions.map(cmZoomRegionWV)),
                        "tiltRegions": .arr(tiltRegions.map(cmTiltRegionWV)),
                        "animationDuration": animDur.wv,
                        "screenTiltMode": .str(mode.rawValue),
                        "smoothingFactor": smoothing.wv,
                        "followSpeed": follow.wv,
                        "scrollTimes": scroll.wv,
                        "cursorEvents": .arr(events.map(WVModel.cursorEvent)),
                        "coordinateSize": coord.wv,
                    ],
                    "ops": .arr(ops),
                ],
                .arr(records)
            ))
        }
        return cases
    }

    // MARK: - Easing

    private static func easingCurveCases() -> [WV] {
        var rng = WVRandom(seed: "easingCurves")
        var cases: [WV] = []
        let fixed: [Double] = [0, -0.0, 1, 0.5, 0.49999999999999994, 0.25, 0.75, -1, 2, 1e-12, 1 - 1e-12, 10, -10, 100, 1000]
        for i in 0..<1500 {
            let t = i < fixed.count ? fixed[i] : rng.edgy(-0.5, 1.5, edges: [0, 0.5, 1, 0.1, 0.9, 3, 7.5])
            let damping = rng.edgy(0, 1.2, edges: [0.7, 0, 1, 0.99])
            let frequency = rng.edgy(0, 4, edges: [1.5, 0, 1])
            cases.append(vcase(
                ["t": t.wv, "damping": damping.wv, "frequency": frequency.wv],
                [
                    "easeInOutCubic": Easing.easeInOutCubic(t).wv,
                    "smootherStep": Easing.smootherStep(t).wv,
                    "easeOutCubic": Easing.easeOutCubic(t).wv,
                    "easeInCubic": Easing.easeInCubic(t).wv,
                    "easeOutQuart": Easing.easeOutQuart(t).wv,
                    "easeOutExpo": Easing.easeOutExpo(t).wv,
                    "springDefault": Easing.spring(t).wv,
                    "spring": Easing.spring(t, damping: damping, frequency: frequency).wv,
                ]
            ))
        }
        return cases
    }

    private static func easingEnvelopeCases() -> [WV] {
        var rng = WVRandom(seed: "easingEnvelopes")
        var cases: [WV] = []
        for i in 0..<2500 {
            let start = rng.edgy(-2, 10, edges: [0])
            let end = i % 17 == 0 ? start - rng.double(0, 2) : start + rng.edgy(0, 6, edges: [0, 0.1, 0.24, 0.25, 0.5, 1])
            let transition = rng.edgy(-0.5, 2, edges: [0, 0.3, 0.5, 0.8, 1.2, 0.12, 0.08])
            let time = rng.edgy(start - 1, end + 1, edges: [start, end, start + 0.08, end - 0.12, (start + end) / 2])
            cases.append(vcase(
                ["time": time.wv, "startTime": start.wv, "endTime": end.wv, "transitionDuration": transition.wv],
                [
                    "regionEnvelope": Easing.regionEnvelope(
                        at: time, startTime: start, endTime: end, transitionDuration: transition).wv,
                    "zoomEnvelope": Easing.zoomEnvelope(
                        at: time, startTime: start, endTime: end, transitionDuration: transition).wv,
                ]
            ))
        }
        return cases
    }

    private static func easingZoomLevelCases() -> [WV] {
        var rng = WVRandom(seed: "easingZoomLevel")
        var cases: [WV] = []
        for _ in 0..<600 {
            let span = rng.edgy(1, 10, edges: [4])
            let regions = cmRandomZoomRegions(&rng, span: span, maxCount: 5)
            let transition = rng.edgy(0, 1.5, edges: [0.3, 0.5, 0.8, 1.2])
            let edges = regions.flatMap { [$0.startTime, $0.endTime] }
            let times: [Double] = (0..<12).map { _ in rng.edgy(-0.5, span + 0.5, edges: edges, edgeP: 0.3) }
            cases.append(vcase(
                ["zoomRegions": .arr(regions.map(cmZoomRegionWV)), "transitionDuration": transition.wv, "times": times.wv],
                .arr(times.map { t in
                    let r = Easing.zoomLevel(at: t, regions: regions, transitionDuration: transition)
                    return ["zoom": r.zoom.wv, "focalPoint": r.focalPoint.wv, "envelope": r.envelope.wv]
                })
            ))
        }
        return cases
    }

    // MARK: - IntroSlideMath

    private static func introSlideMathCases() -> [WV] {
        var rng = WVRandom(seed: "introSlideMath")
        var cases: [WV] = []
        for _ in 0..<3000 {
            let style = rng.pick(IntroSlideStyle.allCases)
            let duration = rng.edgy(-0.5, 3, edges: [0, 0.05, 0.0500001, 0.6, 1])
            let speed = rng.edgy(0, 5, edges: [1, 0.5, 2, 4])
            let startTime = rng.edgy(-1, 10, edges: [0, 0.01, 0.0100001, -0.5, 2])
            let eff = duration / max(1.0, speed)
            let outputTime = rng.edgy(-0.5, max(startTime, 0) + eff + 0.5, edges: [
                startTime, startTime + eff * 0.45, startTime + eff * 0.55, startTime + eff,
                0, eff, startTime + eff * 0.2, startTime + eff * 0.8, eff * 0.5,
            ], edgeP: 0.35)
            let bounce = rng.edgy(-0.5, 1.5, edges: [0, 0.5, 1])
            let depth = rng.bool()
            let useDefaults = rng.bool(0.1)
            let st = useDefaults
                ? IntroSlideMath.state(style: style, at: outputTime, duration: duration)
                : IntroSlideMath.state(style: style, at: outputTime, startTime: startTime, duration: duration,
                                       bounce: bounce, depth: depth, speed: speed)
            cases.append(vcase(
                [
                    "style": .str(style.rawValue), "outputTime": outputTime.wv, "startTime": startTime.wv,
                    "duration": duration.wv, "bounce": bounce.wv, "depth": depth.wv, "speed": speed.wv,
                    "useDefaults": useDefaults.wv,
                ],
                ["state": cmIntroStateWV(st), "vector": style.vector.wv]
            ))
        }
        // The constants, once.
        cases.append(vcase(
            ["constants": true],
            [
                "travel": IntroSlideMath.travel.wv, "startScale": IntroSlideMath.startScale.wv,
                "depthStartScale": IntroSlideMath.depthStartScale.wv,
                "depthStartPitch": IntroSlideMath.depthStartPitch.wv,
                "resting": cmIntroStateWV(IntroSlideMath.State()),
            ]
        ))
        return cases
    }

    private static func introSlideHelperOracleCases() -> [WV] {
        var rng = WVRandom(seed: "introSlideMathHelpersOracle")
        var cases: [WV] = []
        let vectors: [CGPoint] = IntroSlideStyle.allCases.map(\.vector)
        for _ in 0..<1500 {
            let p = rng.edgy(-0.5, 1.5, edges: [0, 1, 0.5, 0.9999])
            let bounce = rng.edgy(-0.5, 1.5, edges: [0, 0.5, 1])
            let v = rng.bool(0.8) ? rng.pick(vectors) : rng.point(-2, 2)
            let startScale = CGFloat(rng.edgy(0, 1.2, edges: [0.9, 0.42, 1]))
            let startPitch = rng.edgy(-30, 30, edges: [0, 20])
            let e = rng.edgy(-0.5, 1.5, edges: [0, 1])
            cases.append(vcase(
                ["p": p.wv, "bounce": bounce.wv, "v": v.wv, "e": e.wv, "startScale": startScale.wv, "startPitch": startPitch.wv],
                [
                    "easeOutBack": CameraMotionHelperOracle.easeOutBack(p, bounce: bounce).wv,
                    "pulling": cmIntroStateWV(CameraMotionHelperOracle.pulling(p, v, bounce: bounce)),
                    "arriving": cmIntroStateWV(CameraMotionHelperOracle.arriving(
                        e, v, startScale: startScale, startPitch: startPitch)),
                ]
            ))
        }
        return cases
    }

    // MARK: - MotionBlurMath

    private static func motionBlurMathCases() -> [WV] {
        var rng = WVRandom(seed: "motionBlurMath")
        var cases: [WV] = []
        func sampleWV(_ s: MotionBlurMath.CameraSample) -> WV {
            ["zoom": s.zoom.wv, "focalX": s.focalX.wv, "focalY": s.focalY.wv, "offsetX": s.offsetX.wv, "offsetY": s.offsetY.wv]
        }
        for i in 0..<2500 {
            let prev = MotionBlurMath.CameraSample(
                zoom: rng.edgy(0.5, 4, edges: [1, 2]), focalX: rng.edgy(0, 1, edges: [0.5]),
                focalY: rng.edgy(0, 1, edges: [0.5]), offsetX: rng.edgy(-1.5, 1.5, edges: [0]),
                offsetY: rng.edgy(-1.5, 1.5, edges: [0]))
            var cur = prev
            let dt = rng.edgy(-0.1, 0.6, edges: [0, 1e-6, 1e-7, 0.5, 0.5000001, 1.0 / 60, 1.0 / 30, 1.0 / 60])
            // Small deltas so the speed sweeps the threshold → cap range.
            let scale = rng.pick([0.0001, 0.001, 0.003, 0.01, 0.03, 0.1, 0.5])
            switch i % 4 {
            case 0: // pure zoom about the centre (no translation → angle 0 branch)
                cur.focalX = 0.5; cur.focalY = 0.5
                cur.zoom = prev.zoom + rng.double(-1, 1) * scale
                cur.offsetX = prev.offsetX; cur.offsetY = prev.offsetY
                var p2 = prev; p2.focalX = 0.5; p2.focalY = 0.5
                cases.append(blurCase(p2, cur, dt: dt, rng: &rng, sampleWV))
                continue
            case 1:
                cur.offsetX += rng.double(-1, 1) * scale
                cur.offsetY += rng.double(-1, 1) * scale
            case 2:
                cur.focalX += rng.double(-1, 1) * scale
                cur.zoom += rng.double(-1, 1) * scale
            default:
                cur = MotionBlurMath.CameraSample(
                    zoom: rng.double(0.5, 4), focalX: rng.double(0, 1), focalY: rng.double(0, 1),
                    offsetX: rng.double(-1.5, 1.5), offsetY: rng.double(-1.5, 1.5))
            }
            cases.append(blurCase(prev, cur, dt: dt, rng: &rng, sampleWV))
        }
        cases.append(vcase(
            ["constants": true],
            [
                "velocityThreshold": MotionBlurMath.velocityThreshold.wv,
                "velocityAtMax": MotionBlurMath.velocityAtMax.wv,
                "maxRadiusFraction": MotionBlurMath.maxRadiusFraction.wv,
                "zoomLeverArm": MotionBlurMath.zoomLeverArm.wv,
                "maxSampleGap": MotionBlurMath.maxSampleGap.wv,
                "none": ["radius": MotionBlurMath.Blur.none.radius.wv, "angle": MotionBlurMath.Blur.none.angle.wv,
                         "active": MotionBlurMath.Blur.none.active.wv],
            ]
        ))
        return cases
    }

    private static func blurCase(
        _ prev: MotionBlurMath.CameraSample, _ cur: MotionBlurMath.CameraSample,
        dt: Double, rng: inout WVRandom, _ sampleWV: (MotionBlurMath.CameraSample) -> WV
    ) -> WV {
        let strength = rng.edgy(-0.5, 1.5, edges: [0, 0.001, 0.0011, 1, 2, 0.5])
        let b = MotionBlurMath.blur(previous: prev, current: cur, dt: dt, strength: strength)
        let c0 = CameraMotionHelperOracle.mappedCenter(prev)
        let c1 = CameraMotionHelperOracle.mappedCenter(cur)
        return vcase(
            ["previous": sampleWV(prev), "current": sampleWV(cur), "dt": dt.wv, "strength": strength.wv],
            [
                "blur": ["radius": b.radius.wv, "angle": b.angle.wv, "active": b.active.wv],
                "mappedCenterPrevious": ["x": c0.x.wv, "y": c0.y.wv],
                "mappedCenterCurrent": ["x": c1.x.wv, "y": c1.y.wv],
            ]
        )
    }
}
