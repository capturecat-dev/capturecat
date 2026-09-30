import AppKit
import CoreGraphics
import CoreMedia

// Style cluster — geometry + clock: CoreGraphics path primitives (element
// emission of CGPath(rect:) / (ellipseIn:) / (roundedRect:…), which the camera
// and frame clip paths are built from), ContinuousRoundedRect, SwiftUIShadow,
// RecordingClock.
extension WebVectors {
    static var styleGeometryUnits: [WebVectorUnit] {
        [
            WebVectorUnit(
                name: "cgPathPrimitives",
                notes: "CoreGraphics CGPath(rect:transform:nil), CGPath(ellipseIn:transform:nil), CGPath(roundedRect:cornerWidth:cornerHeight:transform:nil) — element-for-element (move/line/curve/close + points), the primitives CameraStyleMath.clipPath / VideoExporter.frameShapeCGPath / ContinuousRoundedRect emit",
                build: cgPathPrimitiveCases),
            WebVectorUnit(
                name: "continuousRoundedRectPath",
                notes: "Services/ContinuousRoundedRect.swift — path(rect:cornerRadius:) and circularPath(rect:cornerRadius:) element-for-element (DeviceFrameLayout.continuousRoundedPath is the same call)",
                build: continuousRoundedRectCases),
            WebVectorUnit(
                name: "swiftUIShadow",
                notes: "Services/SwiftUIShadow.swift apply(to:radius:dy:color:) — setShadow(offset:blur:color:) parameters from the REAL context CTM (verbatim oracle: CGContext has no shadow getter; CROSS-CHECKED by rendering a shape with the real apply() vs setShadow(oracle params), byte-for-byte)",
                build: swiftUIShadowCases),
            WebVectorUnit(
                name: "recordingClockSequences",
                notes: "Services/RecordingClock.swift — a REAL RecordingClock driven through restart/pause/resume/timelineTime(forHostTime:) sequences with explicit host times (the nil → now() defaults are not vectored); state after every op",
                build: recordingClockSequenceCases),
            WebVectorUnit(
                name: "recordingClockEventTimestamp",
                notes: "Services/RecordingClock.swift — hostTimeSeconds(forEventTimestamp:now:) (mach-units vs nanoseconds plausibility window) and eventTimestamp(forHostTimeSeconds:); CGEventTimestamp travels as a decimal string; the machine's mach timebase is in every case's input",
                build: recordingClockEventTimestampCases),
        ]
    }

    // MARK: CGPath encoding

    static func stylePathWV(_ path: CGPath) -> WV {
        var els: [WV] = []
        path.applyWithBlock { ptr in
            let e = ptr.pointee
            switch e.type {
            case .moveToPoint: els.append(["op": "move", "pts": [e.points[0].wv]])
            case .addLineToPoint: els.append(["op": "line", "pts": [e.points[0].wv]])
            case .addQuadCurveToPoint: els.append(["op": "quad", "pts": [e.points[0].wv, e.points[1].wv]])
            case .addCurveToPoint: els.append(["op": "curve", "pts": [e.points[0].wv, e.points[1].wv, e.points[2].wv]])
            case .closeSubpath: els.append(["op": "close", "pts": []])
            @unknown default: els.append(["op": "unknown", "pts": []])
            }
        }
        return .arr(els)
    }

    static func randomPathRect(_ rng: inout WVRandom, index i: Int) -> CGRect {
        switch i % 8 {
        case 0: return CGRect(x: rng.double(-50, 50), y: rng.double(-50, 50), width: rng.double(-300, 300), height: rng.double(-300, 300))
        case 1: return CGRect(x: rng.double(-50, 50), y: rng.double(-50, 50), width: rng.edgy(0, 2, edges: [0]), height: rng.edgy(0, 2, edges: [0]))
        case 2: return CGRect(x: 0, y: 0, width: rng.int(1, 600), height: rng.int(1, 600))
        default: return rng.rect(origin: -500, 2000, size: 0.01, 1200)
        }
    }

    // MARK: CG primitives

    private static func cgPathPrimitiveCases() -> [WV] {
        var rng = WVRandom(seed: "cgPathPrimitives")
        var cases: [WV] = []
        for i in 0..<1200 {
            let rect = randomPathRect(&rng, index: i)
            // CG documents 0 ≤ corner ≤ half the side; out-of-range corners
            // (oversize, negative) are vectored too — CG clamps / falls back.
            let halfW = rect.width / 2, halfH = rect.height / 2
            let cw = rng.bool(0.2) ? rng.pick([0, halfW, halfW * 0.999, halfW * 1.5, -1, halfW + 1]) : CGFloat(rng.double(0, 1)) * halfW
            let ch = rng.bool(0.5) ? cw : (rng.bool(0.2) ? rng.pick([0, halfH, halfH * 2, -0.5]) : CGFloat(rng.double(0, 1)) * halfH)
            let validCh = ch
            cases.append(vcase(
                ["rect": rect.wv, "cornerWidth": cw.wv, "cornerHeight": validCh.wv],
                [
                    "rect": stylePathWV(CGPath(rect: rect, transform: nil)),
                    "ellipse": stylePathWV(CGPath(ellipseIn: rect, transform: nil)),
                    "roundedRect": stylePathWV(CGPath(roundedRect: rect, cornerWidth: cw, cornerHeight: validCh, transform: nil)),
                ]
            ))
        }
        return cases
    }

    // MARK: ContinuousRoundedRect

    private static func continuousRoundedRectCases() -> [WV] {
        var rng = WVRandom(seed: "continuousRoundedRectPath")
        var cases: [WV] = []
        for i in 0..<1200 {
            let rect = randomPathRect(&rng, index: i)
            let short = min(rect.width, rect.height)
            let radius = CGFloat(rng.edgy(-10, 400, edges: [0, Double(short / 2), Double(short / 2 / 1.528665), Double(short / 3), -1, 1e6], edgeP: 0.3))
            cases.append(vcase(
                ["rect": rect.wv, "cornerRadius": radius.wv],
                [
                    "path": stylePathWV(ContinuousRoundedRect.path(rect: rect, cornerRadius: radius)),
                    "circularPath": stylePathWV(ContinuousRoundedRect.circularPath(rect: rect, cornerRadius: radius)),
                    "deviceFramePath": stylePathWV(DeviceFrameLayout.continuousRoundedPath(rect: rect, cornerRadius: radius)),
                ]
            ))
        }
        return cases
    }

    // MARK: SwiftUIShadow

    private static func swiftUIShadowCases() -> [WV] {
        let unit = "swiftUIShadow"
        var rng = WVRandom(seed: unit)
        var cases: [WV] = []
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return [] }
        func makeCtx() -> CGContext? {
            CGContext(data: nil, width: 48, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        for i in 0..<600 {
            guard let ctx = makeCtx(), let check = makeCtx() else { continue }
            // Random CTM: scale (incl. flips), rotation, translation.
            let sx = CGFloat(rng.edgy(0.25, 4, edges: [1, 2, 3, -1, -2], edgeP: 0.3))
            let sy = rng.bool(0.7) ? sx : CGFloat(rng.edgy(0.25, 4, edges: [1, -1, 2], edgeP: 0.3))
            let rot = CGFloat(rng.bool(0.6) ? 0 : rng.double(-.pi, .pi))
            let tx = CGFloat(rng.double(-4, 4)), ty = CGFloat(rng.double(-4, 4))
            for c in [ctx, check] {
                c.translateBy(x: 24 + tx, y: 24 + ty)
                c.rotate(by: rot)
                c.scaleBy(x: sx, y: sy)
            }
            let radius = CGFloat(rng.edgy(0, 12, edges: [0, 6, 1], edgeP: 0.2))
            let dy = CGFloat(rng.edgy(-6, 6, edges: [0, 2], edgeP: 0.2))
            let color = SRGBA(red: rng.cg(0, 1), green: rng.cg(0, 1), blue: rng.cg(0, 1), alpha: rng.cg(0.1, 1))
            let ctm = ctx.ctm
            // Oracle — SwiftUIShadow.swift:20-28.
            let deviceScale = sqrt(abs(ctm.a * ctm.d - ctm.b * ctm.c))
            let blur = radius * SwiftUIShadow.blurFactor * deviceScale

            // Cross-check: same shape with the real apply() and with the oracle.
            if i % 3 == 0 {
                SwiftUIShadow.apply(to: ctx, radius: radius, dy: dy, color: color)
                check.setShadow(offset: CGSize(width: 0, height: dy), blur: blur, color: color.cgColor)
                for c in [ctx, check] {
                    c.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.9, alpha: 1))
                    c.fill(CGRect(x: -3, y: -2, width: 6, height: 4))
                }
                if let a = ctx.makeImage(), let b = check.makeImage(), rgbaBytes(a) != rgbaBytes(b) {
                    styleOracleFail("\(unit): shadow render diverges case \(i)")
                }
            }
            cases.append(vcase(
                ["ctm": ctm.wv, "radius": radius.wv, "dy": dy.wv, "color": srgbaWV(color)],
                [
                    "deviceScale": deviceScale.wv,
                    "offset": CGSize(width: 0, height: dy).wv,
                    "blur": blur.wv,
                    "color": srgbaWV(color),
                ]
            ))
        }
        return cases + styleOracleSentinel(unit)
    }

    // MARK: RecordingClock

    private static func recordingClockSequenceCases() -> [WV] {
        var rng = WVRandom(seed: "recordingClockSequences")
        var cases: [WV] = []
        for _ in 0..<700 {
            let origin = rng.edgy(0, 1e6, edges: [0, 1000, 123456.789, 1e9], edgeP: 0.2)
            let clock = RecordingClock(originHostTimeSeconds: origin)
            var now = origin + rng.double(-5, 5)
            var ops: [WV] = []
            var states: [WV] = []
            for _ in 0..<rng.int(1, 30) {
                now += rng.edgy(-2, 10, edges: [0, 0.0000001, -0.5], edgeP: 0.2)
                let op: WV
                var value: WV = .null
                switch rng.int(0, 9) {
                case 0:
                    let o = rng.bool(0.5) ? now : now + rng.double(-3, 3)
                    clock.restart(originHostTimeSeconds: o)
                    op = ["op": "restart", "at": o.wv]
                case 1, 2:
                    let at = rng.bool(0.8) ? now : now + rng.double(-3, 1)
                    clock.pause(at: at)
                    op = ["op": "pause", "at": at.wv]
                case 3, 4:
                    let at = rng.bool(0.8) ? now : now + rng.double(-3, 1)
                    clock.resume(at: at)
                    op = ["op": "resume", "at": at.wv]
                default:
                    let q = rng.edgy(now - 20, now + 5, edges: [now, origin, 0, -1], edgeP: 0.2)
                    value = clock.timelineTime(forHostTime: q).wv
                    op = ["op": "timelineTime", "at": q.wv]
                }
                ops.append(op)
                states.append([
                    "value": value,
                    "originHostTimeSeconds": clock.originHostTimeSeconds.wv,
                    "isPaused": clock.isPaused.wv,
                    "accumulatedPauseSeconds": clock.accumulatedPauseSeconds.wv,
                ])
            }
            cases.append(vcase(["origin": origin.wv, "ops": .arr(ops)], ["states": .arr(states)]))
        }
        return cases
    }

    private static func recordingClockEventTimestampCases() -> [WV] {
        var rng = WVRandom(seed: "recordingClockEventTimestamp")
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        var cases: [WV] = []
        for i in 0..<1500 {
            let host = rng.edgy(0, 2e6, edges: [0.001, 1, 86400, 2592000], edgeP: 0.15)
            let raw: UInt64
            switch i % 6 {
            case 0: raw = 0
            case 1, 2: raw = RecordingClock.eventTimestamp(forHostTimeSeconds: host)
            case 3: raw = UInt64(max(0, host * 1_000_000_000).rounded())
            case 4:
                // Around the Int64 overflow of raw·numer and of raw·numer/denom.
                let edges: [UInt64] = [73_786_976_294_838_206, 73_786_976_294_838_207, 73_786_976_294_838_208,
                                       150_000_000_000_000_000, 221_360_928_884_514_619, 221_360_928_884_514_620,
                                       221_360_928_884_514_621, UInt64(Int64.max), UInt64.max, 1, 2, 3,
                                       UInt64(Int64.max) + 1, UInt64(Int64.max) + 2, UInt64.max - 100_000_000_000_000_000,
                                       UInt64.max - 221_360_928_884_514_620, UInt64.max - 221_360_928_884_514_621, UInt64.max - 2]
                raw = rng.bool(0.5) ? rng.pick(edges) : UInt64(rng.int(0, Int.max / 4))
            default: raw = UInt64(rng.int(1, 5_000_000_000_000))
            }
            let now: Double
            switch rng.int(0, 5) {
            case 0: now = host
            case 1: now = host + rng.double(0, 30)
            case 2: now = host + rng.pick([30, 30.0000001, -0.05, -0.0500001, 29.999999, 0.05])
            case 3: now = host - rng.double(0, 0.2)
            default: now = rng.double(0, 2e6)
            }
            let cm = CMClockMakeHostTimeFromSystemUnits(raw)
            let back = RecordingClock.eventTimestamp(forHostTimeSeconds: host)
            cases.append(vcase(
                [
                    "raw": .str(String(raw)), "now": now.wv, "hostTime": host.wv,
                    "timebaseNumer": .int(Int(info.numer)), "timebaseDenom": .int(Int(info.denom)),
                ],
                [
                    "hostTimeSeconds": RecordingClock.hostTimeSeconds(forEventTimestamp: raw, now: now).wv,
                    "machUnitsCMTime": ["value": .str(String(cm.value)), "timescale": .int(Int(cm.timescale))],
                    "machUnitsSeconds": CMTimeGetSeconds(cm).wv,
                    "eventTimestamp": .str(String(back)),
                ]
            ))
        }
        return cases
    }
}
