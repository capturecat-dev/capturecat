import Foundation
import CoreGraphics
import CoreImage
import AppKit

// Golden-vector units for the CURSOR cluster (see WebVectorsHarness.swift):
// the shared cursor chain (smooth → spring → end behaviour), CursorSpringMath,
// CursorEndBehaviorMath, CursorPhysicsMath, CursorOverlayLayout, TapRippleMath,
// ClickRippleOverlay, CursorStyleProvider, and the exporter's private cursor
// pipeline (verbatim oracles in WebVectors+CursorOracle.swift).
// TS ports: apps/web/src/editor/core/math/{cursorSpringMath, cursorEndBehaviorMath,
// cursorChain, cursorPhysicsMath, cursorOverlayLayout, tapRippleMath,
// clickRippleOverlay, cursorStyleProvider, exportCursor, cursorSupport}.ts
extension WebVectors {
    static var cursorUnits: [WebVectorUnit] {
        [
            WebVectorUnit(
                name: "cursorHypot",
                notes: "Darwin libm hypot(x, y) (what Swift's hypot(CGFloat, CGFloat) calls in ClickRippleOverlay drag runs and VideoExporter.shouldHideCursor) — the TS chypot must match bit-for-bit",
                build: cursorHypotCases),
            WebVectorUnit(
                name: "cursorSpringSimulate",
                notes: "Services/CursorSpringMath.swift — CursorSpringMath.apply(events:settings:) (→ simulate(events:tension:friction:mass:) when cursorFluidEnabled), incl. out-of-range/NaN params, click pinning, 0/1/2-event and zero-duration inputs",
                build: cursorSpringCases),
            WebVectorUnit(
                name: "cursorEndBehavior",
                notes: "Services/CursorSpringMath.swift — CursorEndBehaviorMath.apply(events:trimEnd:loopToStart:stopAtEnd:)",
                build: cursorEndBehaviorCases),
            WebVectorUnit(
                name: "cursorChain",
                notes: "The shared chain of VideoExporter.export L125–143 == EditorPlaybackController.applyCursorSmoothing: smoothCursor ? CursorSmoother(factor:).smooth : events → CursorSpringMath.apply → CursorEndBehaviorMath.apply(trimEnd: project.effectiveTrimEnd) — real calls, real Project.effectiveTrimEnd",
                build: cursorChainCases),
            WebVectorUnit(
                name: "cursorMenuBarCrop",
                notes: "verbatim oracle of VideoExporter.export L345–408 (da569841): recording coordinate size (hasValidCoordinateSpace), real CursorOverlayLayout.resolveCoordinateSize, menuBarCrop, effectiveNaturalSize, resolvedCursorCoordinateSize, cursor-event Y shift",
                build: cursorMenuBarCropCases),
            WebVectorUnit(
                name: "cursorPhysicsPose",
                notes: "Services/CursorPhysicsMath.swift — pose(events:at:coordinateSize:videoRect:spriteHeight:tilt:stretch:drag:weight:), Pose.yFlipped/isIdentity, affineTransform(pose:tip:spriteHeight:) of the pose and of its Y-up flip",
                build: cursorPhysicsPoseCases),
            WebVectorUnit(
                name: "cursorPhysicsTransform",
                notes: "Services/CursorPhysicsMath.swift — affineTransform(pose:tip:spriteHeight:) over arbitrary poses (identity, zero body offset, spriteHeight ≤ 0, stretch ≤ 0/NaN), yFlipped, isIdentity",
                build: cursorPhysicsTransformCases),
            WebVectorUnit(
                name: "cursorOverlayLayout",
                notes: "Models/CursorEvent.swift — CursorOverlayLayout.make, imageRect/hotspotPoint, center, imageSpaceRect(in:), resolveCoordinateSize, viewRect(from:canvasHeight:)",
                build: cursorOverlayLayoutCases),
            WebVectorUnit(
                name: "tapRippleProgress",
                notes: "Views/Editor/ClickRippleOverlay.swift — TapRippleMath.progress(elapsed:) incl. cycle boundaries, negatives, NaN/±∞",
                build: tapRippleCases),
            WebVectorUnit(
                name: "clickRippleDiscrete",
                notes: "Views/Editor/ClickRippleOverlay.swift — discreteClickTimes, discreteClicks, dragHighlightRuns (real) + clickDragThreshold (private — verbatim oracle); click runs straddling the drag threshold, spring-resampled runs, coordinate sizes incl. zero/negative",
                build: clickRippleDiscreteCases),
            WebVectorUnit(
                name: "clickRippleActive",
                notes: "Views/Editor/ClickRippleOverlay.swift — activeRipples(cursorEvents:currentTime:coordinateSize:videoRect:rippleDuration:) and dragHighlightStrength(runs:at:) sequences around every click and drag edge",
                build: clickRippleActiveCases),
            WebVectorUnit(
                name: "clickRippleExportDraw",
                notes: "verbatim oracle of the numbers ClickRippleOverlay.renderForExport hands CoreGraphics (Y-up output px), SELF-CHECKED: the recorded ops re-drawn with the same CG calls equal the real renderForExport byte-for-byte",
                build: clickRippleExportDrawCases),
            WebVectorUnit(
                name: "cursorStyleAssets",
                notes: "Services/CursorStyleProvider.swift — asset(for:) size + hotspot (real), rasterizedCGImage pixel grid (real), and the private drawnArrow/drawnDot geometry (verbatim oracle, SELF-CHECKED: re-drawn raster bytes == real rasterizedCGImage at several sizes)",
                build: cursorStyleAssetCases),
            WebVectorUnit(
                name: "exportCursorShouldHide",
                notes: "verbatim oracle of VideoExporter.shouldHideCursor (L3240–3258, da569841)",
                build: exportCursorShouldHideCases),
            WebVectorUnit(
                name: "exportCursorSetup",
                notes: "verbatim oracle of VideoExporter.export L331–408 (canvasScale, fullCursorCoordinateSize, sourceToOutputScale, maximumZoom, cursorRasterScale, menu-bar crop) + makeCursorAsset L3557–3591 over the real CursorStyleProvider (da569841)",
                build: exportCursorSetupCases),
            WebVectorUnit(
                name: "exportCursorComposite",
                notes: "verbatim oracle of VideoExporter's per-frame cursor gate (L1486–1490, L1736–1781), renderCursorCI (L3354–3467; sprite bounds via real CGRect.applying), manualDropShadow (L3470–3490) and renderClickRipple (L3290–3350) over real CursorOverlayLayout/CursorPhysicsMath/ClickRippleOverlay (da569841)",
                build: exportCursorCompositeCases),
            WebVectorUnit(
                name: "exportCursorCGFallback",
                notes: "verbatim oracle of VideoExporter.renderCursor (L3492–3555) + drawFallbackCursor (L3593–3613) — the CoreGraphics fallback path (da569841)",
                build: exportCursorCGFallbackCases),
        ]
    }

    // MARK: - Helpers

    fileprivate static func cursorEventsWV(_ events: [CursorEvent]) -> WV {
        .arr(events.map(WVModel.cursorEvent))
    }

    fileprivate static func poseWV(_ p: CursorPhysicsMath.Pose) -> WV {
        [
            "bodyOffset": ["dx": p.bodyOffset.dx.wv, "dy": p.bodyOffset.dy.wv],
            "rotation": p.rotation.wv,
            "stretch": p.stretch.wv,
            "motionAngle": p.motionAngle.wv,
        ]
    }

    fileprivate static func layoutWV(_ l: CursorOverlayLayout?) -> WV {
        guard let l else { return .null }
        return ["imageRect": l.imageRect.wv, "hotspotPoint": l.hotspotPoint.wv]
    }

    fileprivate static let coordinateSizes: [CGSize] = [
        CGSize(width: 1512, height: 982), CGSize(width: 1920, height: 1080),
        CGSize(width: 3024, height: 1964), CGSize(width: 5120, height: 2880),
        CGSize(width: 2880, height: 5120), CGSize(width: 390, height: 844),
        CGSize(width: 800, height: 600), CGSize(width: 4000, height: 100),
        CGSize(width: 1666.6666666666667, height: 1666.6666666666667),
        CGSize(width: 4000, height: 4000), CGSize(width: 0, height: 0),
        CGSize(width: 0, height: 1080), CGSize(width: 1512, height: 0),
        CGSize(width: -100, height: 800), CGSize(width: 0.001, height: 0.001),
    ]

    /// Click-heavy cursor path: press-runs whose travel straddles the drag
    /// threshold (still, jitter just under/at/over, axis-exact and diagonal
    /// boundary hits, long drags), at 60 Hz with duplicate timestamps and gaps.
    fileprivate static func randomClickEvents(_ rng: inout WVRandom, count: Int, size: CGSize) -> [CursorEvent] {
        let threshold = Double(CursorOracle.clickDragThreshold(for: size))
        let w = max(10, Double(size.width)), h = max(10, Double(size.height))
        var events: [CursorEvent] = []
        var t = rng.edgy(0, 2, edges: [0])
        var x = rng.double(0, w), y = rng.double(0, h)
        var i = 0
        while i < count {
            // Idle stretch.
            for _ in 0..<rng.int(0, 6) where i < count {
                t += rng.pick([1.0 / 60, 1.0 / 60, 0, 0.25, 1.0 / 30])
                if rng.bool(0.7) { x += rng.double(-30, 30); y += rng.double(-30, 30) }
                events.append(CursorEvent(timestamp: t, x: CGFloat(x), y: CGFloat(y), isClick: false))
                i += 1
            }
            // Press run.
            let len = rng.pick([1, 1, 2, 3, 5, 8, 15, 30])
            let mode = rng.int(0, 6)
            let sx = x, sy = y
            let angle = rng.double(0, 2 * .pi)
            for k in 0..<len where i < count {
                if k > 0 { t += rng.pick([1.0 / 60, 1.0 / 60, 1.0 / 120, 0]) }
                var px = sx, py = sy
                switch mode {
                case 0: break  // perfectly still
                case 1:  // jitter within 0.3–1.1 × threshold
                    let r = threshold * rng.pick([0.3, 0.9, 0.999, 1.001, 1.1]) * rng.unit()
                    let a = rng.double(0, 2 * .pi)
                    px = sx + r * cos(a); py = sy + r * sin(a)
                case 2:  // axis-exact boundary on the last sample
                    if k == len - 1 {
                        let d = threshold + rng.pick([0.0, 0.0, 1e-9, -1e-9])
                        if rng.bool() { px = sx + d } else { py = sy - d }
                    }
                case 3:  // diagonal boundary on the last sample
                    if k == len - 1 {
                        px = sx + threshold * cos(angle); py = sy + threshold * sin(angle)
                    }
                case 4:  // drag: linear travel well past the threshold
                    let dist = threshold * rng.pick([1.5, 3, 20]) * Double(k) / Double(max(1, len - 1))
                    px = sx + dist * cos(angle); py = sy + dist * sin(angle)
                case 5:  // integer-pixel moves (6-8-10 style exact hits)
                    let steps = [(0.0, 0.0), (3.0, 4.0), (6.0, 8.0), (5.0, 12.0), (8.0, 15.0), (7.0, 24.0)]
                    let s = rng.pick(steps)
                    px = sx + s.0; py = sy + s.1
                default:  // drift that returns (max distance mid-run)
                    let r = threshold * rng.double(0.5, 1.5) * sin(Double.pi * Double(k) / Double(max(1, len - 1)))
                    px = sx + r * cos(angle); py = sy + r * sin(angle)
                }
                events.append(CursorEvent(timestamp: t, x: CGFloat(px), y: CGFloat(py), isClick: true))
                i += 1
                x = px; y = py
            }
            t += rng.pick([1.0 / 60, 0.05, 0.3])
        }
        return events
    }

    // MARK: - cursorHypot

    private static func cursorHypotCases() -> [WV] {
        var rng = WVRandom(seed: "cursorHypot")
        var cases: [WV] = []
        for _ in 0..<500 {
            var xs: [Double] = [], ys: [Double] = []
            for _ in 0..<40 {
                var x = 0.0, y = 0.0
                switch rng.int(0, 7) {
                case 0:
                    x = Double(rng.int(-50, 50)); y = Double(rng.int(-50, 50))
                case 1:
                    x = rng.double(-40, 40); y = rng.double(-40, 40)
                case 2:
                    let t = rng.pick([10.0, 12, 17.28, 24, 5, 5.892, 11.784])
                    let a = rng.double(0, 2 * .pi)
                    x = t * cos(a); y = t * sin(a)
                case 3:
                    x = rng.double(-5000, 5000); y = rng.double(-5000, 5000)
                case 4:
                    x = rng.double(-1e-3, 1e-3)
                    let tiny = rng.double(-1e-6, 1e-6)
                    y = rng.pick([0, -0.0, 1e-310, tiny])
                case 5:
                    x = rng.double(-40, 40); y = x * rng.pick([1, -1, 1e-9, 1e9])
                case 6:
                    x = rng.double(0, 1000); y = rng.double(0, 1e-8)
                default:
                    x = rng.pick([1e300, -1e300, 1e-300, 3e-320, .infinity, -.infinity, .nan, 0])
                    y = rng.pick([1e300, 2, -1e-300, .nan, .infinity, 0, -0.0])
                }
                xs.append(x); ys.append(y)
            }
            cases.append(vcase(
                ["x": xs.wv, "y": ys.wv],
                ["hypot": zip(xs, ys).map { hypot($0, $1) }.wv]
            ))
        }
        return cases
    }

    // MARK: - CursorSpringMath

    private static func springSettings(_ rng: inout WVRandom) -> ProjectSettings {
        let s = ProjectSettings()
        s.cursorFluidEnabled = rng.bool(0.85)
        s.cursorTension = rng.edgy(20, 600, edges: [220, 20, 600, 5, 1000, .nan, 0, 60])
        s.cursorFriction = rng.edgy(2, 80, edges: [24, 2, 80, 0, 200, .nan, 6])
        s.cursorMass = rng.edgy(0.2, 6, edges: [1, 0.2, 6, 0, 10, .nan, 3])
        return s
    }

    private static func springSettingsWV(_ s: ProjectSettings) -> WV {
        [
            "cursorFluidEnabled": s.cursorFluidEnabled.wv,
            "cursorTension": s.cursorTension.wv,
            "cursorFriction": s.cursorFriction.wv,
            "cursorMass": s.cursorMass.wv,
        ]
    }

    /// Structural variants of a random path: collapsed timestamps, clicks at
    /// the ends, all-click, click-free.
    private static func variant(_ events: [CursorEvent], _ i: Int) -> [CursorEvent] {
        guard !events.isEmpty else { return events }
        switch i % 11 {
        case 3:
            let t0 = events[0].timestamp
            return events.map { CursorEvent(timestamp: t0, x: $0.x, y: $0.y, isClick: $0.isClick) }
        case 5:
            var e = events
            e[0] = CursorEvent(timestamp: e[0].timestamp, x: e[0].x, y: e[0].y, isClick: true)
            return e
        case 7:
            var e = events
            let l = e.count - 1
            e[l] = CursorEvent(timestamp: e[l].timestamp, x: e[l].x, y: e[l].y, isClick: true)
            return e
        case 9:
            return events.map { CursorEvent(timestamp: $0.timestamp, x: $0.x, y: $0.y, isClick: true) }
        case 10:
            return events.map { CursorEvent(timestamp: $0.timestamp, x: $0.x, y: $0.y, isClick: false) }
        default:
            return events
        }
    }

    private static func cursorSpringCases() -> [WV] {
        var rng = WVRandom(seed: "cursorSpringSimulate")
        var cases: [WV] = []
        for i in 0..<500 {
            let count: Int
            if i < 12 { count = i % 3 }
            else if i % 60 == 0 { count = rng.int(150, 240) }
            else { count = rng.int(2, 28) }
            let events = variant(randomCursorEvents(&rng, count: count), i)
            let s = springSettings(&rng)
            if i < 24 { s.cursorFluidEnabled = true }
            let result = CursorSpringMath.apply(events: events, settings: s)
            cases.append(vcase(
                ["events": cursorEventsWV(events), "settings": springSettingsWV(s)],
                ["result": cursorEventsWV(result)]
            ))
        }
        return cases
    }

    // MARK: - CursorEndBehaviorMath

    private static func cursorEndBehaviorCases() -> [WV] {
        var rng = WVRandom(seed: "cursorEndBehavior")
        var cases: [WV] = []
        for i in 0..<800 {
            let count = i % 60 == 0 ? rng.int(0, 1) : rng.int(2, 60)
            let events = variant(randomCursorEvents(&rng, count: count), i)
            let first = events.first?.timestamp ?? 0
            let last = events.last?.timestamp ?? 0
            var edges: [Double] = [last, last - 0.5, last - 0.8, last + 0.2, first, 0, -1, first + 0.5, first + 0.8]
            if !events.isEmpty {
                let e = events[rng.int(0, events.count - 1)].timestamp
                edges += [e + 0.5, e + 0.8, e + 0.5 + 1e-12]
            }
            let trimEnd = rng.edgy(first - 1, last + 1, edges: edges, edgeP: 0.5)
            let loop = rng.bool(0.45)
            let stop = rng.bool(0.45)
            let result = CursorEndBehaviorMath.apply(
                events: events, trimEnd: trimEnd, loopToStart: loop, stopAtEnd: stop)
            cases.append(vcase(
                ["events": cursorEventsWV(events), "trimEnd": trimEnd.wv,
                 "loopToStart": loop.wv, "stopAtEnd": stop.wv],
                ["result": cursorEventsWV(result)]
            ))
        }
        return cases
    }

    // MARK: - Chain

    private static func cursorChainCases() -> [WV] {
        var rng = WVRandom(seed: "cursorChain")
        var cases: [WV] = []
        for i in 0..<500 {
            let count = i % 50 == 0 ? rng.int(0, 2) : rng.int(3, 28)
            let events = variant(randomCursorEvents(&rng, count: count), i)
            let last = events.last?.timestamp ?? 0
            let p = Project(id: rng.uuid(), name: "v", duration: rng.edgy(0, last + 2, edges: [last, 0, last + 0.3]))
            p.trimStart = rng.edgy(-1, p.duration, edges: [0, 0, p.duration])
            p.trimEnd = rng.edgy(-1, p.duration + 1, edges: [0, 0, p.duration, last - 0.6])
            let s = springSettings(&rng)
            s.smoothCursor = rng.bool(0.4)
            s.smoothingFactor = rng.edgy(0.02, 1, edges: [0.15, 0.5, 1, 0, 0.0333])
            s.cursorLoopToStart = rng.bool(0.3)
            s.cursorStopAtEnd = rng.bool(0.3)

            // The chain, as VideoExporter.export L130–143 runs it.
            var chained = events
            if s.smoothCursor {
                chained = CursorSmoother(factor: s.smoothingFactor).smooth(events: chained)
            }
            chained = CursorSpringMath.apply(events: chained, settings: s)
            chained = CursorEndBehaviorMath.apply(
                events: chained,
                trimEnd: p.effectiveTrimEnd,
                loopToStart: s.cursorLoopToStart,
                stopAtEnd: s.cursorStopAtEnd)

            let settingsWV = springSettingsWV(s)
                .setting("smoothCursor", s.smoothCursor.wv)
                .setting("smoothingFactor", s.smoothingFactor.wv)
                .setting("cursorLoopToStart", s.cursorLoopToStart.wv)
                .setting("cursorStopAtEnd", s.cursorStopAtEnd.wv)
            cases.append(vcase(
                [
                    "events": cursorEventsWV(events),
                    "settings": settingsWV,
                    "project": ["duration": p.duration.wv, "trimStart": p.trimStart.wv, "trimEnd": p.trimEnd.wv],
                ],
                ["effectiveTrimEnd": p.effectiveTrimEnd.wv, "result": cursorEventsWV(chained)]
            ))
        }
        return cases
    }

    // MARK: - Menu-bar crop

    private static let menuBarModes: [ProjectSettings.MenuBarReplacement] = [.off, .hidden, .hidden, .dark, .light]
    private static let sourceKinds: [RecordingSourceKind] = [.display, .display, .window, .area, .device]

    private static func randomSegments(_ rng: inout WVRandom) -> [ProjectSourceSegment] {
        (0..<rng.int(0, 3)).map { _ in
            ProjectSourceSegment(
                startTime: rng.double(0, 10), duration: rng.double(0, 5),
                kind: rng.pick(sourceKinds), contentX: 0, contentY: 0, contentWidth: 1, contentHeight: 1)
        }
    }

    private static func segmentsWV(_ segs: [ProjectSourceSegment]) -> WV {
        .arr(segs.map { WV.encoded($0) })
    }

    private static func cursorMenuBarCropCases() -> [WV] {
        var rng = WVRandom(seed: "cursorMenuBarCrop")
        var cases: [WV] = []
        for i in 0..<1200 {
            let p = Project(id: rng.uuid(), name: "v", duration: 10, recordingSourceKind: rng.pick(sourceKinds))
            p.sourceSegments = randomSegments(&rng)
            let s = ProjectSettings()
            s.menuBarReplacement = rng.pick(menuBarModes)
            s.menuBarHeight = rng.edgy(0, 20, edges: [3.8, 0, 12, 12.0000001, 15, 100, -5, .nan])
            let recW = rng.edgy(0, 4000, edges: [0, -5, 1512, 1920])
            let recH = rng.edgy(0, 3000, edges: [0, -5, 982, 1080])
            let recording = CursorRecording(version: 1, coordinateWidth: CGFloat(recW), coordinateHeight: CGFloat(recH), events: [])
            let natural = rng.bool(0.1) ? CGSize(width: rng.pick([0, 1, 1.5] as [Double]), height: rng.pick([0, 1, 3] as [Double])) : rng.size(100, 6000)
            let eventCount = i % 40 == 0 ? 0 : rng.int(1, 30)
            let events = randomCursorEvents(&rng, count: eventCount)
            // L127–128: the loader's coordinate size.
            let cursorCoordinateSize = recording.hasValidCoordinateSpace == true ? recording.coordinateSize : .zero
            let setup = CursorOracle.setup(
                project: p, settings: s, cursorCoordinateSize: cursorCoordinateSize,
                naturalSize: natural, outputSize: CGSize(width: 1920, height: 1080), cursorEvents: events)
            cases.append(vcase(
                [
                    "settings": ["menuBarReplacement": .str(s.menuBarReplacement.rawValue), "menuBarHeight": s.menuBarHeight.wv],
                    "project": ["recordingSourceKind": .str(p.recordingSourceKind.rawValue), "sourceSegments": segmentsWV(p.sourceSegments)],
                    "recording": ["coordinateWidth": recording.coordinateWidth.wv, "coordinateHeight": recording.coordinateHeight.wv],
                    "naturalSize": natural.wv,
                    "events": cursorEventsWV(events),
                ],
                [
                    "cursorCoordinateSize": cursorCoordinateSize.wv,
                    "fullCursorCoordinateSize": setup.fullCursorCoordinateSize.wv,
                    "menuBarCrop": setup.menuBarCrop.wv,
                    "effectiveNaturalSize": setup.effectiveNaturalSize.wv,
                    "resolvedCursorCoordinateSize": setup.resolvedCursorCoordinateSize.wv,
                    "shiftedEvents": cursorEventsWV(setup.shiftedEvents),
                ]
            ))
        }
        return cases
    }

    // MARK: - CursorPhysicsMath

    private static func randomYDownRect(_ rng: inout WVRandom) -> CGRect {
        switch rng.int(0, 12) {
        case 0: return CGRect(x: rng.double(-50, 50), y: rng.double(-50, 50), width: 0, height: rng.double(1, 500))
        case 1: return CGRect(x: rng.double(-50, 50), y: rng.double(-50, 50), width: -rng.double(100, 1000), height: rng.double(100, 800))
        case 2: return CGRect(x: rng.double(-50, 50), y: rng.double(-50, 50), width: rng.double(100, 1000), height: -rng.double(100, 800))
        default: return rng.rect(origin: -40, 400, size: 50, 3800)
        }
    }

    private static func cursorPhysicsPoseCases() -> [WV] {
        var rng = WVRandom(seed: "cursorPhysicsPose")
        var cases: [WV] = []
        for i in 0..<700 {
            let count = i % 40 == 0 ? rng.int(0, 1) : rng.int(2, 80)
            let events = randomCursorEvents(&rng, count: count)
            let coord: CGSize = rng.bool(0.9) ? rng.pick(coordinateSizes) : rng.size(1, 5000)
            let rect = randomYDownRect(&rng)
            let sprite = CGFloat(rng.edgy(0, 200, edges: [42, 28, 0, -10]))
            let tilt = rng.edgy(0, 1, edges: [0, 1, 0.5, -1, 2, .nan])
            let stretch = rng.edgy(0, 1, edges: [0, 1, 0.5, -1, 2, .nan])
            let drag = rng.edgy(0, 1, edges: [0, 1, 0.5, -1, 2, .nan])
            let weight = rng.edgy(0.5, 3, edges: [1, 0.5, 3, 0, 10, .nan])
            let first = events.first?.timestamp ?? 0, last = events.last?.timestamp ?? 0
            var queries: [WV] = []
            for _ in 0..<5 {
                let t = rng.edgy(first - 0.2, last + 0.2, edges: events.prefix(6).map(\.timestamp) + [first, last])
                let pose = CursorPhysicsMath.pose(
                    events: events, at: t, coordinateSize: coord, videoRect: rect,
                    spriteHeight: sprite, tilt: tilt, stretch: stretch, drag: drag, weight: weight)
                let flipped = pose.yFlipped()
                let tip = rng.point(-100, 3000)
                let tipUp = CGPoint(x: tip.x, y: 2000 - tip.y)
                queries.append([
                    "t": t.wv, "tip": tip.wv, "tipUp": tipUp.wv,
                    "pose": poseWV(pose),
                    "isIdentity": pose.isIdentity.wv,
                    "flipped": poseWV(flipped),
                    "transform": CursorPhysicsMath.affineTransform(pose: pose, tip: tip, spriteHeight: sprite).wv,
                    "flippedTransform": CursorPhysicsMath.affineTransform(pose: flipped, tip: tipUp, spriteHeight: sprite).wv,
                ])
            }
            cases.append(vcase(
                [
                    "events": cursorEventsWV(events), "coordinateSize": coord.wv, "videoRect": rect.wv,
                    "spriteHeight": sprite.wv, "tilt": tilt.wv, "stretch": stretch.wv, "drag": drag.wv,
                    "weight": weight.wv,
                    "queries": .arr(queries.map { $0.removing("pose", "isIdentity", "flipped", "transform", "flippedTransform") }),
                ],
                ["queries": .arr(queries.map { $0.removing("t", "tip", "tipUp") })]
            ))
        }
        return cases
    }

    private static func cursorPhysicsTransformCases() -> [WV] {
        var rng = WVRandom(seed: "cursorPhysicsTransform")
        var cases: [WV] = []
        for _ in 0..<1500 {
            var pose = CursorPhysicsMath.Pose()
            if rng.bool(0.8) {
                pose.bodyOffset = CGVector(dx: rng.edgy(-30, 30, edges: [0, -0.0]), dy: rng.edgy(-30, 30, edges: [0]))
            }
            if rng.bool(0.8) { pose.rotation = CGFloat(rng.edgy(-0.4, 0.4, edges: [0, -0.0, .pi / 10])) }
            if rng.bool(0.8) { pose.stretch = CGFloat(rng.edgy(0.5, 1.4, edges: [1, 1.3, 0, -1, .nan, 1e-12])) }
            if rng.bool(0.8) { pose.motionAngle = CGFloat(rng.edgy(-.pi, .pi, edges: [0, .pi, -.pi / 2, .pi / 4])) }
            let tip = rng.point(-200, 4000)
            let sprite = CGFloat(rng.edgy(0, 200, edges: [28, 42, 0, -5, 0.25]))
            cases.append(vcase(
                ["pose": poseWV(pose), "tip": tip.wv, "spriteHeight": sprite.wv],
                [
                    "isIdentity": pose.isIdentity.wv,
                    "yFlipped": poseWV(pose.yFlipped()),
                    "transform": CursorPhysicsMath.affineTransform(pose: pose, tip: tip, spriteHeight: sprite).wv,
                ]
            ))
        }
        return cases
    }

    // MARK: - CursorOverlayLayout

    private static func cursorOverlayLayoutCases() -> [WV] {
        var rng = WVRandom(seed: "cursorOverlayLayout")
        var cases: [WV] = []
        for _ in 0..<2000 {
            let coord: CGSize = rng.bool(0.85) ? rng.pick(coordinateSizes) : rng.size(-10, 5000)
            let pos = rng.bool(0.8)
                ? CGPoint(x: rng.double(-50, Double(max(1, coord.width)) + 50), y: rng.double(-50, Double(max(1, coord.height)) + 50))
                : CGPoint(x: rng.pick([0, -0.0, Double(coord.width), -1e9, 1e9]), y: rng.pick([0, Double(coord.height), 1e-12]))
            let rect = randomYDownRect(&rng)
            let cursorSize = rng.bool(0.9)
                ? rng.pick([CGSize(width: 20, height: 28), CGSize(width: 24, height: 24), CGSize(width: 32, height: 32)])
                : CGSize(width: rng.pick([0, -1, 5] as [Double]), height: rng.pick([0, 28, -2] as [Double]))
            let hotSpot = rng.bool(0.8) ? rng.pick([CGPoint(x: 2, y: 2), CGPoint(x: 12, y: 12), CGPoint(x: 13, y: 8)]) : rng.point(-5, 40)
            let scale = rng.edgy(0.5, 3, edges: [1.5, 1, 0, -1, 10])
            let canvasH = CGFloat(rng.edgy(0, 4000, edges: [1080, 0, -1]))
            let layout = CursorOverlayLayout.make(
                cursorPosition: pos, coordinateSize: coord, videoRect: rect,
                cursorSize: cursorSize, hotSpot: hotSpot, cursorScale: scale)
            let recorded = rng.bool(0.6) ? rng.pick(coordinateSizes) : rng.size(-100, 3000)
            let fallback = rng.bool(0.8) ? rng.size(0, 6000) : CGSize(width: rng.pick([0, 1, 2, -4] as [Double]), height: rng.pick([0, 1.5, 3] as [Double]))
            let anyRect = randomYDownRect(&rng)
            cases.append(vcase(
                [
                    "cursorPosition": pos.wv, "coordinateSize": coord.wv, "videoRect": rect.wv,
                    "cursorSize": cursorSize.wv, "hotSpot": hotSpot.wv, "cursorScale": scale.wv,
                    "canvasHeight": canvasH.wv, "recordedSize": recorded.wv, "fallbackSourceSize": fallback.wv,
                    "anyRect": anyRect.wv,
                ],
                [
                    "layout": layoutWV(layout),
                    "center": layout.map { $0.center.wv } ?? .null,
                    "imageSpaceRect": layout.map { $0.imageSpaceRect(in: canvasH).wv } ?? .null,
                    "resolveCoordinateSize": CursorOverlayLayout.resolveCoordinateSize(
                        recordedSize: recorded, fallbackSourceSize: fallback).wv,
                    "viewRect": CursorOverlayLayout.viewRect(from: anyRect, canvasHeight: canvasH).wv,
                ]
            ))
        }
        return cases
    }

    // MARK: - TapRippleMath

    private static func tapRippleCases() -> [WV] {
        var rng = WVRandom(seed: "tapRippleProgress")
        var cases: [WV] = []
        var fixed: [Double] = [0, -0.0, 0.45, 0.4499999999999999, 0.45000000000000007, 1.2, 1.65, 2.4, 2.85,
                               1.2 * 3, 1.2 * 3 + 0.45, -1e-12, -1, 1e-300, 1e300, 12345.678, .nan, .infinity, -.infinity]
        for k in 1..<40 {
            fixed.append(Double(k) * 1.2)
            fixed.append(Double(k) * 1.2 + 0.45)
            fixed.append(Double(k) * 1.2 - 1e-12)
        }
        for f in fixed {
            cases.append(vcase(["elapsed": f.wv], ["progress": TapRippleMath.progress(elapsed: f).wv]))
        }
        for _ in 0..<2500 {
            let e = rng.edgy(-2, 60, edges: [0, 0.45, 1.2, 0.2], edgeP: 0.05)
            cases.append(vcase(["elapsed": e.wv], ["progress": TapRippleMath.progress(elapsed: e).wv]))
        }
        return cases
    }

    // MARK: - ClickRippleOverlay

    private static func runsWV(_ runs: [(start: TimeInterval, end: TimeInterval)]) -> WV {
        .arr(runs.map { ["start": $0.start.wv, "end": $0.end.wv] })
    }

    private static func clickEventsForCase(_ rng: inout WVRandom, _ i: Int) -> (events: [CursorEvent], size: CGSize) {
        let size: CGSize = rng.bool(0.85) ? rng.pick(coordinateSizes) : rng.size(-50, 6000)
        var events: [CursorEvent]
        if i % 17 == 0 {
            let n = rng.int(0, 60)
            events = randomCursorEvents(&rng, count: n, size: CGSize(width: max(1, size.width), height: max(1, size.height)))
        } else {
            let n = i % 50 == 1 ? rng.int(0, 2) : rng.int(3, 90)
            events = randomClickEvents(&rng, count: n, size: size)
        }
        // Spring-resampled input (the export's real click source).
        if i % 5 == 2, events.count > 1 {
            events = CursorSpringMath.simulate(events: events, tension: rng.edgy(20, 600, edges: [220]),
                                               friction: rng.edgy(2, 80, edges: [24]), mass: rng.edgy(0.2, 6, edges: [1]))
        }
        return (events, size)
    }

    private static func clickRippleDiscreteCases() -> [WV] {
        var rng = WVRandom(seed: "clickRippleDiscrete")
        var cases: [WV] = []
        for i in 0..<1000 {
            let (events, size) = clickEventsForCase(&rng, i)
            cases.append(vcase(
                ["events": cursorEventsWV(events), "coordinateSize": size.wv],
                [
                    "clickDragThreshold": CursorOracle.clickDragThreshold(for: size).wv,
                    "discreteClickTimes": ClickRippleOverlay.discreteClickTimes(from: events, coordinateSize: size).wv,
                    "discreteClicks": cursorEventsWV(ClickRippleOverlay.discreteClicks(from: events, coordinateSize: size)),
                    "dragHighlightRuns": runsWV(ClickRippleOverlay.dragHighlightRuns(from: events, coordinateSize: size)),
                ]
            ))
        }
        return cases
    }

    /// Times that hit every ripple/drag edge of `events`.
    private static func interestingTimes(_ rng: inout WVRandom, events: [CursorEvent], size: CGSize, count: Int) -> [Double] {
        let clicks = ClickRippleOverlay.discreteClickTimes(from: events, coordinateSize: size)
        let runs = ClickRippleOverlay.dragHighlightRuns(from: events, coordinateSize: size)
        var edges: [Double] = []
        for c in clicks.prefix(8) { edges += [c, c + 0.45, c + 0.2, c - 0.001, c + 0.4500001, c + 0.15] }
        for r in runs.prefix(6) { edges += [r.start, r.end, r.start + 0.06, r.start + 0.12, r.end + 0.1, r.end + 0.25, r.end + 0.3] }
        let first = events.first?.timestamp ?? 0, last = events.last?.timestamp ?? 0
        return (0..<count).map { _ in rng.edgy(first - 0.3, last + 0.6, edges: edges, edgeP: 0.7) }
    }

    private static func clickRippleActiveCases() -> [WV] {
        var rng = WVRandom(seed: "clickRippleActive")
        var cases: [WV] = []
        for i in 0..<600 {
            let (events, size) = clickEventsForCase(&rng, i)
            let rect = randomYDownRect(&rng)
            let duration: Double? = rng.bool(0.8) ? nil : rng.edgy(0, 1, edges: [0, 0.45, 0.3])
            let times = interestingTimes(&rng, events: events, size: size, count: 12)
            let runs = ClickRippleOverlay.dragHighlightRuns(from: events, coordinateSize: size)
            let queries: [WV] = times.map { (t) -> WV in
                let ripples = duration.map {
                    ClickRippleOverlay.activeRipples(cursorEvents: events, currentTime: t, coordinateSize: size, videoRect: rect, rippleDuration: $0)
                } ?? ClickRippleOverlay.activeRipples(cursorEvents: events, currentTime: t, coordinateSize: size, videoRect: rect)
                return [
                    "activeRipples": .arr(ripples.map { ["position": $0.position.wv, "progress": $0.progress.wv, "id": $0.id.wv] }),
                    "dragHighlightStrength": ClickRippleOverlay.dragHighlightStrength(runs: runs, at: t).wv,
                ]
            }
            cases.append(vcase(
                ["events": cursorEventsWV(events), "coordinateSize": size.wv, "videoRect": rect.wv,
                 "rippleDuration": duration.wv, "times": times.wv],
                ["queries": .arr(queries)]
            ))
        }
        return cases
    }

    private static func rippleOpsWV(_ ops: [CursorOracle.RippleOp]) -> WV {
        .arr(ops.map {
            [
                "kind": .str($0.fill ? "fillEllipse" : "strokeEllipse"),
                "rect": $0.rect.wv,
                "lineWidth": $0.lineWidth.wv,
                "alpha": $0.alpha.wv,
            ]
        })
    }

    private static func clickRippleExportDrawCases() -> [WV] {
        var rng = WVRandom(seed: "clickRippleExportDraw")
        var cases: [WV] = []
        var selfChecked = 0
        for i in 0..<700 {
            let (events, size) = clickEventsForCase(&rng, i)
            let small = i % 3 == 0
            let output: CGSize = small
                ? CGSize(width: rng.int(80, 360), height: rng.int(60, 240))
                : rng.pick([CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1920),
                            CGSize(width: 3840, height: 2160), CGSize(width: 1280, height: 720)])
            let videoRect: CGRect = rng.bool(0.92)
                ? CGRect(x: rng.double(0, Double(output.width) * 0.2), y: rng.double(0, Double(output.height) * 0.2),
                         width: rng.double(Double(output.width) * 0.4, Double(output.width) * 0.8),
                         height: rng.double(Double(output.height) * 0.4, Double(output.height) * 0.8))
                : CGRect(x: 10, y: 10, width: rng.pick([0, -200, 300]), height: rng.pick([0, 200]))
            let rippleSize = rng.edgy(10, 120, edges: [40, 0, -20, 200])
            let color = CGColor(srgbRed: rng.unit(), green: rng.unit(), blue: rng.unit(), alpha: rng.pick([1, 0.5, 0.2]))
            let times = interestingTimes(&rng, events: events, size: size, count: 4)
            var queries: [WV] = []
            for t in times {
                let (ops, strength) = CursorOracle.renderForExportOps(
                    cursorEvents: events, currentTime: t, videoRect: videoRect,
                    sourceSize: size, rippleSize: rippleSize)
                // Self-check: every small case, and the first 60 full-size
                // ones that draw anything.
                if !ops.isEmpty, small || selfChecked < 60 {
                    if !CursorOracle.rippleOpsMatchReal(
                        cursorEvents: events, currentTime: t, videoRect: videoRect, sourceSize: size,
                        rippleColor: color, rippleSize: rippleSize, outputSize: output, ops: ops) {
                        print("WEB-VECTORS FAIL clickRippleExportDraw: oracle ops do not re-draw to the real renderForExport bytes (case \(i), t=\(t))")
                        return []
                    }
                    selfChecked += 1
                }
                queries.append(["ops": rippleOpsWV(ops), "dragStrength": strength.wv])
            }
            cases.append(vcase(
                ["events": cursorEventsWV(events), "sourceSize": size.wv, "videoRect": videoRect.wv,
                 "rippleSize": rippleSize.wv, "times": times.wv],
                ["queries": .arr(queries)]
            ))
        }
        print("WEB-VECTORS note: clickRippleExportDraw self-checked \(selfChecked) draws byte-exact against the real renderForExport")
        return cases
    }

    // MARK: - CursorStyleProvider

    private static let allStyles: [ProjectSettings.CursorStyle] = [.system, .inverted, .hand, .dot, .ring]

    private static func rgbaWV(_ c: CursorOracle.RGBA) -> WV {
        ["r": c.r.wv, "g": c.g.wv, "b": c.b.wv, "a": c.a.wv]
    }

    private static func artworkWV(_ art: CursorOracle.Artwork?) -> WV {
        guard let art else { return .null }
        let ops: [WV] = art.ops.map { (op) -> WV in
            switch op {
            case let .strokePath(points, lineWidth, color):
                return ["kind": "strokePath", "points": points.wv, "closed": true, "lineWidth": lineWidth.wv,
                        "lineJoin": "round", "color": rgbaWV(color)]
            case let .fillPath(points, color):
                return ["kind": "fillPath", "points": points.wv, "closed": true, "color": rgbaWV(color)]
            case let .strokeOval(rect, lineWidth, color):
                return ["kind": "strokeOval", "rect": rect.wv, "lineWidth": lineWidth.wv, "color": rgbaWV(color)]
            case let .fillOval(rect, color):
                return ["kind": "fillOval", "rect": rect.wv, "color": rgbaWV(color)]
            }
        }
        return ["flipped": art.flipped.wv, "size": art.size.wv, "ops": .arr(ops)]
    }

    private static func cursorStyleAssetCases() -> [WV] {
        var rng = WVRandom(seed: "cursorStyleAssets")
        var cases: [WV] = []
        for style in allStyles {
            let asset = CursorStyleProvider.asset(for: style)
            let art = CursorOracle.artwork(for: style)
            // Self-check the oracle geometry against the real raster.
            if let art {
                let image = CursorOracle.image(for: art)
                for scale in [1.0, 1.5, 2.25, 3.7, 6.0] {
                    let px = CGSize(width: art.size.width * scale, height: art.size.height * scale)
                    guard let real = CursorStyleProvider.rasterizedCGImage(for: style, pixelSize: px),
                          let mine = CursorOracle.rasterize(image, pixelSize: px),
                          let a = CursorOracle.bytes(real), let b = CursorOracle.bytes(mine),
                          real.width == mine.width, real.height == mine.height, a == b else {
                        print("WEB-VECTORS FAIL cursorStyleAssets: oracle artwork for \(style.rawValue) does not rasterize to the real bytes at ×\(scale)")
                        return []
                    }
                    if a.allSatisfy({ $0 == 0 }) {
                        print("WEB-VECTORS FAIL cursorStyleAssets: \(style.rawValue) raster is empty at ×\(scale) (self-check would be vacuous)")
                        return []
                    }
                }
            }
            // Raster pixel grids (real rasterizedCGImage dimensions).
            var sizes: [CGSize] = [
                asset.image.size, CGSize(width: 0, height: 0), CGSize(width: 0.5, height: 0.5),
                CGSize(width: 1.0000001, height: 27.999999), CGSize(width: -3, height: 40),
                CGSize(width: asset.image.size.width * 1.875, height: asset.image.size.height * 1.875),
            ]
            for _ in 0..<60 {
                let s = rng.edgy(0.5, 12, edges: [1, 2, 3, 1.25, 1.875])
                sizes.append(CGSize(width: asset.image.size.width * s, height: asset.image.size.height * s))
            }
            let grids: [WV] = sizes.map { (px) -> WV in
                guard let img = CursorStyleProvider.rasterizedCGImage(for: style, pixelSize: px) else { return .null }
                return ["width": .int(img.width), "height": .int(img.height)]
            }
            cases.append(vcase(
                ["style": .str(style.rawValue), "pixelSizes": sizes.wv],
                [
                    "imageSize": asset.image.size.wv,
                    "hotSpot": asset.hotSpot.wv,
                    "artwork": artworkWV(art),
                    "rasterPixelSizes": .arr(grids),
                ]
            ))
        }
        return cases
    }

    // MARK: - VideoExporter (private) — oracles

    private static func autoHideSettings(_ rng: inout WVRandom) -> ProjectSettings {
        let s = ProjectSettings()
        s.autoHideCursor = rng.bool(0.8)
        s.autoHideDelay = rng.edgy(0, 5, edges: [3, 0, 0.5, -1, 1e9, .nan])
        return s
    }

    private static func parkedDY(_ rng: inout WVRandom) -> Double {
        let r = rng.double(-3.6, 3.6)
        return rng.pick([0, 3, 4, 3.5355339059327378, r])
    }

    private static func exportCursorShouldHideCases() -> [WV] {
        var rng = WVRandom(seed: "exportCursorShouldHide")
        var cases: [WV] = []
        for i in 0..<1000 {
            let count = i % 30 == 0 ? rng.int(0, 1) : rng.int(2, 80)
            var events = randomCursorEvents(&rng, count: count)
            // Parked cursors: many samples within a few points (auto-hide bait).
            if i % 3 == 0, let e0 = events.first {
                events = events.map {
                    CursorEvent(timestamp: $0.timestamp, x: e0.x + CGFloat(rng.double(-3.6, 3.6)),
                                y: e0.y + CGFloat(parkedDY(&rng)),
                                isClick: $0.isClick)
                }
            }
            let s = autoHideSettings(&rng)
            let first = events.first?.timestamp ?? 0, last = events.last?.timestamp ?? 0
            let times: [Double] = (0..<8).map { _ in
                rng.edgy(first - 1, last + 4, edges: events.prefix(5).map(\.timestamp) + [last, last + s.autoHideDelay])
            }
            cases.append(vcase(
                ["events": cursorEventsWV(events),
                 "settings": ["autoHideCursor": s.autoHideCursor.wv, "autoHideDelay": s.autoHideDelay.wv],
                 "times": times.wv],
                ["hidden": times.map { CursorOracle.shouldHideCursor(at: $0, cursorEvents: events, settings: s) }.wv]
            ))
        }
        return cases
    }

    private static func exportCursorSetupCases() -> [WV] {
        var rng = WVRandom(seed: "exportCursorSetup")
        var cases: [WV] = []
        for i in 0..<1200 {
            let p = Project(id: rng.uuid(), name: "v", duration: 10, recordingSourceKind: rng.pick(sourceKinds))
            p.sourceSegments = randomSegments(&rng)
            p.zoomRegions = (0..<rng.int(0, 4)).map { _ in
                ZoomRegion(id: rng.uuid(), startTime: 0, endTime: 1,
                           zoomLevel: rng.edgy(1, 4, edges: [2, 1, 0.5, 1.0000001, 4]))
            }
            let s = ProjectSettings()
            s.cursorScale = rng.edgy(0.5, 3, edges: [1.5, 1, 0, -1, 5])
            s.cursorStyle = rng.pick(allStyles)
            s.menuBarReplacement = rng.pick(menuBarModes)
            s.menuBarHeight = rng.edgy(0, 15, edges: [3.8, 0, 12])
            let valid = rng.bool(0.75)
            let cursorCoordinateSize: CGSize = valid ? rng.pick(Array(coordinateSizes.prefix(10))) : .zero
            let natural: CGSize = rng.bool(0.9) ? rng.size(300, 6000) : CGSize(width: rng.pick([0, 1, 2] as [Double]), height: rng.pick([0, 1, 4] as [Double]))
            let output: CGSize = rng.bool(0.8)
                ? rng.pick([CGSize(width: 1920, height: 1080), CGSize(width: 3840, height: 2160),
                            CGSize(width: 1080, height: 1920), CGSize(width: 1280, height: 720), CGSize(width: 1080, height: 1080)])
                : rng.size(64, 4096)
            let preview: CGSize = rng.bool(0.5) ? .zero : rng.size(-10, 1600)
            let setup = CursorOracle.setup(
                project: p, settings: s, cursorCoordinateSize: cursorCoordinateSize,
                naturalSize: natural, outputSize: output, cursorEvents: [])
            // makeCursorAsset over the REAL provider when the raster is sane;
            // otherwise its pixel grid by the verbatim formula (a giant raster
            // is pointless to allocate — cursorStyleAssets locks the grid rule).
            let base = CursorStyleProvider.asset(for: s.cursorStyle).image.size
            let requested = CGSize(width: base.width * setup.cursorRasterScale, height: base.height * setup.cursorRasterScale)
            let grid: WV
            if max(requested.width, requested.height) <= 2048 {
                let asset = CursorOracle.makeCursorAsset(style: s.cursorStyle, rasterScale: setup.cursorRasterScale)
                grid = asset.cgImage.map { ["width": .int($0.width), "height": .int($0.height)] } ?? .null
            } else {
                grid = ["width": .int(max(1, Int(ceil(requested.width)))), "height": .int(max(1, Int(ceil(requested.height))))]
            }
            let asset = CursorStyleProvider.asset(for: s.cursorStyle)
            cases.append(vcase(
                [
                    "cursorCoordinateSize": cursorCoordinateSize.wv, "naturalSize": natural.wv,
                    "outputSize": output.wv, "previewCanvasSize": preview.wv,
                    "settings": ["cursorScale": s.cursorScale.wv, "cursorStyle": .str(s.cursorStyle.rawValue),
                                 "menuBarReplacement": .str(s.menuBarReplacement.rawValue), "menuBarHeight": s.menuBarHeight.wv],
                    "project": ["recordingSourceKind": .str(p.recordingSourceKind.rawValue),
                                "sourceSegments": segmentsWV(p.sourceSegments),
                                "zoomRegions": .arr(p.zoomRegions.map(WVModel.zoomRegion))],
                ],
                [
                    "canvasScale": CursorOracle.canvasScale(outputSize: output, previewCanvasSize: preview).wv,
                    "fullCursorCoordinateSize": setup.fullCursorCoordinateSize.wv,
                    "sourceToOutputScale": setup.sourceToOutputScale.wv,
                    "maximumZoom": setup.maximumZoom.wv,
                    "cursorRasterScale": setup.cursorRasterScale.wv,
                    "menuBarCrop": setup.menuBarCrop.wv,
                    "effectiveNaturalSize": setup.effectiveNaturalSize.wv,
                    "resolvedCursorCoordinateSize": setup.resolvedCursorCoordinateSize.wv,
                    "cursorAsset": ["baseSize": asset.image.size.wv, "hotSpot": asset.hotSpot.wv, "rasterPixelSize": grid],
                ]
            ))
        }
        return cases
    }

    /// One exporter frame scenario shared by the composite + CG fallback units.
    private struct FrameScenario {
        let events: [CursorEvent]
        let coord: CGSize
        let output: CGSize
        let layoutVideoRect: CGRect
        let canvasScale: CGFloat
        let settings: ProjectSettings
        let style: ProjectSettings.CursorStyle
        let rasterScale: CGFloat
        let times: [Double]
        let hasSourceFrame: Bool

        var inputWV: WV {
            [
                "events": WebVectors.cursorEventsWV(events),
                "cursorCoordinateSize": coord.wv,
                "outputSize": output.wv,
                "layoutVideoRect": layoutVideoRect.wv,
                "canvasScale": canvasScale.wv,
                "style": .str(style.rawValue),
                "rasterScale": rasterScale.wv,
                "hasSourceFrame": hasSourceFrame.wv,
                "times": times.wv,
                "settings": [
                    "showCursor": settings.showCursor.wv, "showClickRipple": settings.showClickRipple.wv,
                    "autoHideCursor": settings.autoHideCursor.wv, "autoHideDelay": settings.autoHideDelay.wv,
                    "cursorScale": settings.cursorScale.wv, "cursorTilt": settings.cursorTilt.wv,
                    "cursorStretch": settings.cursorStretch.wv, "cursorDrag": settings.cursorDrag.wv,
                    "cursorWeight": settings.cursorWeight.wv, "clickRippleSize": settings.clickRippleSize.wv,
                ],
            ]
        }
    }

    private static func frameScenario(_ rng: inout WVRandom, _ i: Int) -> FrameScenario {
        let odd = rng.size(1, 3000)
        let coord: CGSize = rng.bool(0.9) ? rng.pick(Array(coordinateSizes.prefix(10))) : rng.pick([.zero, CGSize(width: 0, height: 900), odd])
        let base = CGSize(width: max(1, coord.width), height: max(1, coord.height))
        var events: [CursorEvent]
        if i % 2 == 0 {
            let n = rng.int(2, 70)
            events = randomClickEvents(&rng, count: n, size: base)
            if i % 4 == 0, events.count > 1 {
                events = CursorSpringMath.simulate(events: events, tension: 220, friction: 24, mass: 1)
            }
        } else {
            let n = i % 40 == 1 ? rng.int(0, 1) : rng.int(2, 70)
            events = randomCursorEvents(&rng, count: n, size: base)
        }
        let output: CGSize = rng.pick([CGSize(width: 1920, height: 1080), CGSize(width: 3840, height: 2160),
                                       CGSize(width: 1080, height: 1920), CGSize(width: 1280, height: 720),
                                       CGSize(width: 1080, height: 1080)])
        let w = Double(output.width), h = Double(output.height)
        let layoutVideoRect: CGRect = rng.bool(0.93)
            ? CGRect(x: rng.double(0, w * 0.2), y: rng.double(0, h * 0.2),
                     width: rng.double(w * 0.3, w * 0.8), height: rng.double(h * 0.3, h * 0.8))
            : CGRect(x: 50, y: 60, width: rng.pick([0, -400, 800]), height: rng.pick([0, 500, -300]))
        let s = ProjectSettings()
        s.showCursor = rng.bool(0.9)
        s.showClickRipple = rng.bool(0.8)
        s.autoHideCursor = rng.bool(0.25)
        s.autoHideDelay = rng.edgy(0, 4, edges: [3, 0.5])
        s.cursorScale = rng.edgy(0.5, 3, edges: [1.5, 1, 0, -1])
        s.cursorTilt = rng.edgy(0, 1, edges: [0, 0, 1, 0.5])
        s.cursorStretch = rng.edgy(0, 1, edges: [0, 0, 1, 0.5])
        s.cursorDrag = rng.edgy(0, 1, edges: [0, 0, 1, 0.5])
        s.cursorWeight = rng.edgy(0.5, 3, edges: [1, 3])
        s.clickRippleSize = rng.edgy(10, 120, edges: [40, 0])
        let style = rng.pick(allStyles)
        let rasterScale = CGFloat(rng.edgy(1, 5, edges: [1, 1.875, 2.8125]))
        let first = events.first?.timestamp ?? 0, last = events.last?.timestamp ?? 0
        let clicks = ClickRippleOverlay.discreteClickTimes(from: events, coordinateSize: coord)
        var edges: [Double] = [first, last, last + 0.12, last + 0.1200001]
        for c in clicks.prefix(6) { edges += [c, c + 0.2, c + 0.45] }
        for r in ClickRippleOverlay.dragHighlightRuns(from: events, coordinateSize: coord).prefix(4) {
            edges += [r.start + 0.05, r.end, r.end + 0.2]
        }
        let times = (0..<5).map { _ in rng.edgy(first - 0.2, last + 0.3, edges: edges, edgeP: 0.6) }
        let canvasScale = CGFloat(rng.edgy(0.5, 3, edges: [1, 2, 1.5, 0.75]))
        return FrameScenario(
            events: events, coord: coord, output: output, layoutVideoRect: layoutVideoRect,
            canvasScale: canvasScale, settings: s, style: style, rasterScale: rasterScale,
            times: times, hasSourceFrame: rng.bool(0.95))
    }

    private static func affineWV(_ t: CGAffineTransform) -> WV { t.wv }

    private static func exportCursorCompositeCases() -> [WV] {
        var rng = WVRandom(seed: "exportCursorComposite")
        var cases: [WV] = []
        for i in 0..<600 {
            let sc = frameScenario(&rng, i)
            let asset = CursorOracle.makeCursorAsset(style: sc.style, rasterScale: sc.rasterScale)
            guard let cg = asset.cgImage else {
                print("WEB-VECTORS FAIL exportCursorComposite: rasterization failed for \(sc.style.rawValue)")
                return []
            }
            let rasterPixelSize = CGSize(width: cg.width, height: cg.height)
            let smoother = CursorSmoother(factor: sc.settings.smoothingFactor)
            var frames: [WV] = []
            for t in sc.times {
                // L1486–1490 + L1736–1741: the per-frame gate.
                let cursorPosition: CGPoint? = if !sc.events.isEmpty {
                    smoother.interpolateIfFresh(events: sc.events, at: t)
                } else {
                    nil
                }
                let drawCursor = sc.settings.showCursor && cursorPosition != nil && sc.hasSourceFrame
                let drawRipples = drawCursor && sc.settings.showClickRipple
                var composite: WV = .null
                if let cursorPosition, let c = CursorOracle.renderCursorCI(
                    at: t, cursorPosition: cursorPosition, cursorEvents: sc.events, cursorAsset: asset,
                    rasterPixelSize: rasterPixelSize, cursorCoordinateSize: sc.coord,
                    layoutVideoRect: sc.layoutVideoRect, outputSize: sc.output,
                    settings: sc.settings, canvasScale: sc.canvasScale) {
                    composite = [
                        "videoRectInViewSpace": c.videoRectInViewSpace.wv,
                        "layout": layoutWV(c.layout),
                        "drawRect": c.drawRect.wv,
                        "rasterScaleX": c.scaleX.wv,
                        "rasterScaleY": c.scaleY.wv,
                        "placeTransform": affineWV(c.placeTransform),
                        "pose": poseWV(c.pose),
                        "ciPose": poseWV(c.ciPose),
                        "poseIsIdentity": c.poseIsIdentity.wv,
                        "tipCI": c.tipCI.wv,
                        "physicsTransform": affineWV(c.physicsTransform),
                        "spriteTransform": affineWV(c.spriteTransform),
                        "spriteTransformYDown": affineWV(c.spriteTransformYDown),
                        "spriteBounds": c.spriteBounds.wv,
                        "shadowPad": c.shadowPad.wv,
                        "paddedBounds": c.paddedBounds.wv,
                        "dropShadow": ["radius": c.dropShadowRadius.wv, "opacity": c.dropShadowOpacity.wv,
                                       "offsetX": c.dropShadowOffset.dx.wv, "offsetY": c.dropShadowOffset.dy.wv],
                        "shadow": ["opacity": c.manualAlpha.wv, "sigma": c.manualSigma.wv,
                                   "offsetX": c.manualOffset.dx.wv, "offsetYUp": c.manualOffset.dy.wv,
                                   "offsetYDown": (-c.manualOffset.dy).wv],
                    ]
                }
                let skip = CursorOracle.renderClickRippleDraws(
                    at: t, cursorEvents: sc.events, cursorCoordinateSize: sc.coord, layoutVideoRect: sc.layoutVideoRect)
                var draw: WV = .null
                if skip.draws {
                    let (ops, strength) = CursorOracle.renderForExportOps(
                        cursorEvents: sc.events, currentTime: t, videoRect: sc.layoutVideoRect,
                        sourceSize: sc.coord, rippleSize: sc.settings.clickRippleSize)
                    draw = ["ops": rippleOpsWV(ops), "dragStrength": strength.wv]
                }
                frames.append([
                    "frame": ["cursorPosition": cursorPosition.wv, "drawCursor": drawCursor.wv, "drawRipples": drawRipples.wv],
                    "hidden": CursorOracle.shouldHideCursor(at: t, cursorEvents: sc.events, settings: sc.settings).wv,
                    "composite": composite,
                    "ripple": ["hasRipple": skip.hasRipple.wv, "dragStrength": skip.dragStrength.wv,
                               "draws": skip.draws.wv, "draw": draw],
                ])
            }
            cases.append(vcase(
                sc.inputWV.setting("rasterPixelSize", rasterPixelSize.wv)
                    .setting("baseSize", asset.baseSize.wv).setting("hotSpot", asset.hotSpot.wv),
                ["frames": .arr(frames)]
            ))
        }
        return cases
    }

    private static func exportCursorCGFallbackCases() -> [WV] {
        var rng = WVRandom(seed: "exportCursorCGFallback")
        var cases: [WV] = []
        for i in 0..<500 {
            let sc = frameScenario(&rng, i)
            let real = CursorStyleProvider.asset(for: sc.style)
            let hasRaster = rng.bool(0.5)
            // The fallback path runs only when the raster is missing; model
            // both (the asset's cgImage presence is the only switch).
            let asset = CursorOracle.CursorAsset(
                cgImage: hasRaster ? CursorStyleProvider.rasterizedCGImage(for: sc.style, pixelSize: real.image.size) : nil,
                baseSize: real.image.size, hotSpot: real.hotSpot)
            let smoother = CursorSmoother(factor: sc.settings.smoothingFactor)
            var frames: [WV] = []
            for t in sc.times {
                guard !sc.events.isEmpty, let pos = smoother.interpolateIfFresh(events: sc.events, at: t) else {
                    frames.append(["cursorPosition": .null, "fallback": .null])
                    continue
                }
                let f = CursorOracle.renderCursor(
                    at: t, cursorPosition: pos, cursorEvents: sc.events, cursorAsset: asset,
                    cursorCoordinateSize: sc.coord, layoutVideoRect: sc.layoutVideoRect,
                    outputSize: sc.output, settings: sc.settings, canvasScale: sc.canvasScale)
                let fallback: WV = f.map { (f) -> WV in
                    [
                        "drawRect": f.drawRect.wv,
                        "shadowOffset": f.shadowOffset.wv,
                        "shadowBlur": f.shadowBlur.wv,
                        "shadowAlpha": f.shadowAlpha.wv,
                        "fallbackPath": f.fallbackPath.map { $0.wv } ?? .null,
                        "fallbackLineWidth": f.fallbackLineWidth.wv,
                    ]
                } ?? .null
                frames.append(["cursorPosition": pos.wv, "fallback": fallback])
            }
            cases.append(vcase(
                sc.inputWV.setting("hasRaster", hasRaster.wv)
                    .setting("baseSize", real.image.size.wv).setting("hotSpot", real.hotSpot.wv),
                ["frames": .arr(frames)]
            ))
        }
        return cases
    }
}
