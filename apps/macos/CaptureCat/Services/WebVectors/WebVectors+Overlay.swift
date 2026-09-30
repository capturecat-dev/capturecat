import AppKit
import CoreGraphics
import CoreText

// Golden-vector units for the OVERLAY cluster: AnnotationEffectMath (+ the
// Annotation helpers), KeystrokeOverlayMath/Renderer, CurtainUnveilMath,
// AnnotationRenderer and the exporter's subtitle burn. TS ports:
// apps/web/src/editor/core/math/{annotationEffectMath,keystrokeOverlay,
// curtainUnveilMath,annotationGeometry,exportText,overlaySupport}.ts.
//
// Draw recipes (keystroke pill, curtain, annotations) are recorded as ordered
// op lists by verbatim oracles (WebVectors+OverlayOracle.swift) that ALSO
// draw into a real CGContext; each recipe unit proves (a) the oracle's
// pixels == the REAL renderer's pixels and (b) replaying the recorded ops
// (WebVectors+OverlayDraw.swift) == the real pixels, byte for byte. The
// result travels in the vectors as `rasterMatchesReal` so a broken oracle
// fails the TS gate too.
extension WebVectors {
    static var overlayUnits: [WebVectorUnit] {
        [
            WebVectorUnit(
                name: "annotationEffectPhase",
                notes: "Models/Annotation.swift — AnnotationEffectMath.phase(effect:progress:), effectDuration, duration, drawOnDuration; every effect × progress grid incl. <0, >1, NaN, ±inf",
                build: annotationEffectPhaseCases),
            WebVectorUnit(
                name: "annotationEffectCombined",
                notes: "Models/Annotation.swift — AnnotationEffectMath.combined(enter:exit:start:end:at:) for all 64 enter×exit pairs, dense times around start/end (mid-flight + settled), via Annotation.effectPhase(at:); plus Annotation.effectAnchor + duration",
                build: annotationEffectCombinedCases),
            WebVectorUnit(
                name: "annotationDisplayText",
                notes: "Models/Annotation.swift — Annotation.displayText (Swift String.uppercased()) over ASCII + non-ASCII (ß, ǆ, final sigma, Turkish i, ligatures, Georgian, Cherokee, Adlam…)",
                build: annotationDisplayTextCases),
            WebVectorUnit(
                name: "keystrokeOverlayDisplayEvents",
                notes: "Services/KeystrokeOverlay.swift — KeystrokeOverlayMath.scopedEvents, displayEvents(from:) and displayEvents(from:scopedTo: Project)",
                build: keystrokeDisplayEventCases),
            WebVectorUnit(
                name: "keystrokeOverlayActivePill",
                notes: "Services/KeystrokeOverlay.swift — KeystrokeOverlayMath.activePill(displayEvents:currentTime:) over dense time sequences (fade-in / hold / fade-out mid-flight)",
                build: keystrokeActivePillCases),
            WebVectorUnit(
                name: "keystrokeOverlayPillGeometry",
                notes: "Services/KeystrokeOverlay.swift — KeystrokeOverlayMath.slideOffset, popScale, pillCenter, pillRect (all positions × animations)",
                build: keystrokePillGeometryCases),
            WebVectorUnit(
                name: "keystrokeOverlayPillMetrics",
                notes: "Services/KeystrokeOverlay.swift — KeystrokeOverlayRenderer.pillSize (REAL) + the CoreText metrics it measures (verbatim oracle of private makeLine: system font 17·size·scale semibold, kern 1.2·size·scale). TS checks pillSize from the recorded metrics; the metrics are the web's text-measurement reference",
                build: keystrokePillMetricsCases),
            WebVectorUnit(
                name: "keystrokeOverlayDrawRecipe",
                notes: "Services/KeystrokeOverlay.swift — KeystrokeOverlayRenderer.image/draw/drawPill as an ordered op list (verbatim oracle, lines 222–349); rasterMatchesReal proves oracle pixels == real image() and replay(ops) == real",
                build: keystrokeDrawRecipeCases),
            WebVectorUnit(
                name: "curtainUnveilCurves",
                notes: "Services/CurtainUnveilMath.swift — sweepEase, flapOverfoldRadians, flapReleaseOffset, flapOpacityValue, shadowWidthFraction, shadowStrengthValue + constants, dense p incl. flickStart/releaseStart/fade window edges",
                build: curtainCurveCases),
            WebVectorUnit(
                name: "curtainUnveilState",
                notes: "Services/CurtainUnveilMath.swift — state(corner:at:startTime:duration:) (+ private reflect/foldEndpoints through it), shadowPolygon, ambientShadowPolygon; time sequences per corner",
                build: curtainStateCases),
            WebVectorUnit(
                name: "curtainUnveilGeometry",
                notes: "Services/CurtainUnveilMath.swift — reflect(_:acrossLineThrough:_:), polygonArea, clip(_:keepWhere:) (linear half-planes), clipToUnitSquare, unitSquare, CurtainUnveilCorner.point",
                build: curtainGeometryCases),
            WebVectorUnit(
                name: "curtainUnveilCardClip",
                notes: "Services/CurtainUnveilMath.swift — cardClip(frameShape:cornerRadius:cardSize:deviceScreen:) + cardClipPath (CGPath elements, Y-UP raster space; ContinuousRoundedRect / CGPath(roundedRect:))",
                build: curtainCardClipCases),
            WebVectorUnit(
                name: "curtainUnveilCoverStyle",
                notes: "Services/CurtainUnveilMath.swift — coverStyle(settings:logo:cardClip:) (logo nil) + coverStops(base:) + colour constants",
                build: curtainCoverStyleCases),
            WebVectorUnit(
                name: "curtainUnveilDrawRecipe",
                notes: "Services/CurtainUnveilMath.swift — renderImage/draw as an ordered UNIT-space op list (verbatim oracle of draw, lines 492–713, incl. private centroid/revealedDirection); rasterMatchesReal proves oracle pixels == real renderImage and replay(ops) == real",
                build: curtainDrawRecipeCases),
            WebVectorUnit(
                name: "overlayPathPrimitives",
                notes: "CoreGraphics CGPath(rect:), CGPath(roundedRect:cornerWidth:cornerHeight:), CGPath(ellipseIn:) element lists + Services/ContinuousRoundedRect.swift path(rect:cornerRadius:) and circularPath",
                build: pathPrimitiveCases),
        ] + overlayDrawUnits
    }

    // MARK: - Shared encoders

    static func phaseWV(_ p: AnnotationEffectMath.Phase) -> WV {
        ["alpha": p.alpha.wv, "scale": p.scale.wv, "offsetY": p.offsetY.wv, "strokeProgress": p.strokeProgress.wv]
    }

    /// CGPath → ordered element list: ["M",x,y] ["L",x,y] ["Q",cx,cy,x,y]
    /// ["C",c1x,c1y,c2x,c2y,x,y] ["Z"].
    static func pathWV(_ p: CGPath) -> WV { .arr(pathElements(p)) }

    static func pathElements(_ p: CGPath) -> [WV] {
        var out: [WV] = []
        p.applyWithBlock { el in
            let e = el.pointee
            switch e.type {
            case .moveToPoint:
                out.append(["M", e.points[0].x.wv, e.points[0].y.wv])
            case .addLineToPoint:
                out.append(["L", e.points[0].x.wv, e.points[0].y.wv])
            case .addQuadCurveToPoint:
                out.append(["Q", e.points[0].x.wv, e.points[0].y.wv, e.points[1].x.wv, e.points[1].y.wv])
            case .addCurveToPoint:
                out.append(["C", e.points[0].x.wv, e.points[0].y.wv, e.points[1].x.wv, e.points[1].y.wv,
                            e.points[2].x.wv, e.points[2].y.wv])
            case .closeSubpath:
                out.append(["Z"])
            @unknown default:
                out.append(["?"])
            }
        }
        return out
    }

    // MARK: - AnnotationEffectMath

    private static func annotationEffectPhaseCases() -> [WV] {
        var rng = WVRandom(seed: "annotationEffectPhase")
        var cases: [WV] = []
        let edges: [Double] = [-1, -0.0, 0, 1e-12, 0.001, 0.1, 0.2, 0.25, 1.0 / 3, 0.5, 0.75, 0.9, 0.999,
                               1, 1.0000001, 2, .nan, .infinity, -.infinity]
        for effect in AnnotationEffect.allCases {
            var ps = edges
            for _ in 0..<130 { ps.append(rng.double(-0.2, 1.2)) }
            for p in ps {
                cases.append(vcase(
                    ["effect": .str(effect.rawValue), "progress": p.wv],
                    [
                        "phase": phaseWV(AnnotationEffectMath.phase(effect: effect, progress: p)),
                        "effectDuration": AnnotationEffectMath.effectDuration(effect).wv,
                        "duration": AnnotationEffectMath.duration.wv,
                        "drawOnDuration": AnnotationEffectMath.drawOnDuration.wv,
                    ]))
            }
        }
        return cases
    }

    private static func annotationEffectCombinedCases() -> [WV] {
        var rng = WVRandom(seed: "annotationEffectCombined")
        var cases: [WV] = []
        let types = AnnotationType.allCases
        for enter in AnnotationEffect.allCases {
            for exit in AnnotationEffect.allCases {
                for k in 0..<14 {
                    let start = rng.edgy(0, 30, edges: [0, 1, 2.5])
                    let len: Double = k == 0 ? -0.5 : rng.edgy(0, 6, edges: [0, 0.1, 0.3, 0.45, 0.6, 1.0, 1.3, 2, 10])
                    var a = Annotation(id: rng.uuid(), type: rng.pick(types), startTime: start, endTime: start + len)
                    a.enterEffect = enter
                    a.exitEffect = exit
                    a.x = rng.edgy(-0.2, 1.2, edges: [0, 0.5, 1])
                    a.y = rng.edgy(-0.2, 1.2, edges: [0, 0.5, 1])
                    a.arrowEndX = rng.edgy(-0.2, 1.2, edges: [0, 0.5, 1])
                    a.arrowEndY = rng.edgy(-0.2, 1.2, edges: [0, 0.5, 1])
                    let dIn = AnnotationEffectMath.effectDuration(enter)
                    let dOut = AnnotationEffectMath.effectDuration(exit)
                    var times: [Double] = [
                        start - 0.1, start, start + 1e-9, a.endTime, a.endTime + 0.1, a.endTime - 1e-9,
                        (start + a.endTime) / 2,
                    ]
                    for f in [0.1, 0.25, 0.5, 0.75, 0.999, 1.0] {
                        times.append(start + dIn * f)
                        times.append(a.endTime - dOut * f)
                    }
                    for _ in 0..<8 { times.append(rng.double(start - 0.5, a.endTime + 0.5)) }
                    let phases = times.map { phaseWV(a.effectPhase(at: $0)) }
                    let direct = times.map {
                        phaseWV(AnnotationEffectMath.combined(
                            enter: enter, exit: exit, start: a.startTime, end: a.endTime, at: $0))
                    }
                    cases.append(vcase(
                        ["annotation": WVModel.annotation(a), "times": times.wv],
                        [
                            "effectPhase": .arr(phases),
                            "combined": .arr(direct),
                            "effectAnchor": a.effectAnchor.wv,
                            "duration": a.duration.wv,
                        ]))
                }
            }
        }
        return cases
    }

    /// Strings whose uppercasing is interesting (full case mapping, Unicode
    /// version-sensitive letters) — shared with the text-measurement units.
    static let caseMappingSamples: [String] = [
        "", "hello world", "Label", "straße", "ß", "ẞ", "ǆ", "ǅ", "Ǆ", "Ǳ ǲ ǳ", "Ǉ ǈ ǉ",
        "ὀδυσσεύς", "σίσυφος", "ΣΊΣΥΦΟΣ", "istanbul ı İ i", "ﬁ ﬂ ﬀ ﬃ ﬄ ﬅ ﬆ", "ŉ", "ΐ ΰ", "ǰ",
        "ᾳ ᾀ ῳ ᾷ", "և", "ﬓ", "a\nb", "Ünïcödé àéîõü", "👋🏽 hi 🇸🇪", "ა ბ გ", "ꭰ ꭱ", "𞤢 𞤣",
        "ꞔ ꟑ", "ɪ ʀ", "ſ", "ı", "ǈ", "µ", "ÿ", "ŀ", "ǋ", "ɐ ɑ ɒ", "ⓐⓑ", "ｆｕｌｌ", "ǲ",
        "Crème brûlée", "iPhone 17 Pro", "⌘⇧S shortcut", "x²", "ⅰⅱⅲ", "ꙁ", "Ꙁ", "ⱥ", "ꝺ",
    ]

    private static func annotationDisplayTextCases() -> [WV] {
        var rng = WVRandom(seed: "annotationDisplayText")
        var cases: [WV] = []
        let pool = Array(caseMappingSamples.joined(separator: " ").unicodeScalars)
        var strings = caseMappingSamples
        for _ in 0..<500 {
            var s = String.UnicodeScalarView()
            for _ in 0..<rng.int(0, 12) { s.append(rng.pick(pool)) }
            strings.append(String(s))
        }
        for s in strings {
            for upper in [false, true] {
                var a = Annotation(id: rng.uuid(), type: .text, startTime: 0, endTime: 1)
                a.text = s
                a.uppercase = upper
                cases.append(vcase(["text": .str(s), "uppercase": upper.wv], ["displayText": .str(a.displayText)]))
            }
        }
        return cases
    }

    // MARK: - KeystrokeOverlay math

    static let shortcutPool: [String?] = ["⌘S", "⌘Z", "⌘⇧S", "⌃⌥⌘T", "⌘Z ×2", nil, "⌘C", "⌘V", "⇧⌘4", "⌘⌫", nil]

    static func keystrokeEventWV(_ e: KeystrokeEvent) -> WV {
        var o: WV = ["timestamp": e.timestamp.wv, "category": .str(e.category.rawValue)]
        if let s = e.shortcut { o = o.setting("shortcut", .str(s)) }
        if let b = e.frontmostBundleID { o = o.setting("frontmostBundleID", .str(b)) }
        return o
    }

    static func randomKeystrokeEvents(_ rng: inout WVRandom, count: Int) -> [KeystrokeEvent] {
        let cats: [KeystrokeEvent.Category] = [.key, .space, .return, .delete, .modifier, .scroll]
        var t = rng.edgy(0, 3, edges: [0])
        var out: [KeystrokeEvent] = []
        for _ in 0..<count {
            t += rng.pick([0, 0.05, 0.3, 0.79, 0.8, 0.8000001, 0.81, 1.5, 3, 0.12, 1.52])
            out.append(KeystrokeEvent(
                timestamp: t,
                category: rng.pick(cats),
                shortcut: rng.pick(shortcutPool),
                frontmostBundleID: rng.pick([nil, "com.a", "com.b", "com.a"])))
        }
        if rng.bool(0.3) {
            // Unsorted input (displayEvents sorts).
            for i in stride(from: out.count - 1, to: 0, by: -1) {
                out.swapAt(i, rng.int(0, i))
            }
        }
        return out
    }

    static func displayEventWV(_ d: KeystrokeOverlayMath.DisplayEvent) -> WV {
        ["time": d.time.wv, "text": .str(d.text)]
    }

    private static func keystrokeDisplayEventCases() -> [WV] {
        var rng = WVRandom(seed: "keystrokeOverlayDisplayEvents")
        var cases: [WV] = []
        let kinds: [RecordingSourceKind] = [.display, .window, .area, .device]
        for i in 0..<900 {
            let events = randomKeystrokeEvents(&rng, count: i % 40 == 0 ? 0 : rng.int(1, 40))
            let project = Project(id: rng.uuid(), duration: 60, recordingSourceKind: rng.pick(kinds))
            project.recordedAppBundleID = rng.pick([nil, "com.a", "com.c"])
            project.settings.keystrokeOverlayScopeToRecordedApp = rng.bool(0.7)
            let scoped = KeystrokeOverlayMath.scopedEvents(
                events,
                recordedAppBundleID: project.recordedAppBundleID,
                scopeToRecordedApp: project.settings.keystrokeOverlayScopeToRecordedApp,
                sourceKind: project.recordingSourceKind)
            cases.append(vcase(
                [
                    "events": .arr(events.map(keystrokeEventWV)),
                    "project": [
                        "recordedAppBundleID": project.recordedAppBundleID.map { WV.str($0) } ?? .null,
                        "recordingSourceKind": .str(project.recordingSourceKind.rawValue),
                        "settings": ["keystrokeOverlayScopeToRecordedApp": project.settings.keystrokeOverlayScopeToRecordedApp.wv],
                    ],
                ],
                [
                    "scopedEvents": .arr(scoped.map(keystrokeEventWV)),
                    "displayEvents": .arr(KeystrokeOverlayMath.displayEvents(from: events).map(displayEventWV)),
                    "displayEventsScoped": .arr(KeystrokeOverlayMath.displayEvents(from: events, scopedTo: project).map(displayEventWV)),
                ]))
        }
        return cases
    }

    private static func pillWV(_ p: KeystrokeOverlayMath.Pill?) -> WV {
        guard let p else { return .null }
        return ["text": .str(p.text), "alpha": p.alpha.wv, "entry": p.entry.wv]
    }

    private static func keystrokeActivePillCases() -> [WV] {
        var rng = WVRandom(seed: "keystrokeOverlayActivePill")
        var cases: [WV] = []
        let total = KeystrokeOverlayMath.fadeIn + KeystrokeOverlayMath.hold + KeystrokeOverlayMath.fadeOut
        for i in 0..<700 {
            let events = randomKeystrokeEvents(&rng, count: i % 50 == 0 ? 0 : rng.int(1, 25))
            let display = KeystrokeOverlayMath.displayEvents(from: events)
            var times: [Double] = []
            // Dense sweep: every 1/60 s from before the first to after the last.
            let first = display.first?.time ?? 0
            let last = display.last?.time ?? 0
            var t = first - 0.1
            while t <= last + total + 0.1, times.count < 400 {
                times.append(t)
                t += 1.0 / 60
            }
            for d in display.prefix(6) {
                let f = KeystrokeOverlayMath.fadeIn, h = KeystrokeOverlayMath.hold
                times += [d.time, d.time - 1e-9, d.time + f / 2, d.time + f, d.time + f * 2,
                          d.time + f + h, d.time + f + h + 0.15, d.time + total, d.time + total - 1e-9]
            }
            for _ in 0..<10 { times.append(rng.double(first - 1, last + 3)) }
            cases.append(vcase(
                ["displayEvents": .arr(display.map(displayEventWV)), "times": times.wv],
                [
                    "pills": .arr(times.map { pillWV(KeystrokeOverlayMath.activePill(displayEvents: display, currentTime: $0)) }),
                    "fadeIn": KeystrokeOverlayMath.fadeIn.wv,
                    "hold": KeystrokeOverlayMath.hold.wv,
                    "fadeOut": KeystrokeOverlayMath.fadeOut.wv,
                    "repeatWindow": KeystrokeOverlayMath.repeatWindow.wv,
                ]))
        }
        return cases
    }

    private static func keystrokePillGeometryCases() -> [WV] {
        var rng = WVRandom(seed: "keystrokeOverlayPillGeometry")
        var cases: [WV] = []
        let positions = KeystrokeOverlayPosition.allCases
        let animations = KeystrokeOverlayAnimation.allCases
        for i in 0..<1500 {
            let position = positions[i % positions.count]
            let animation = animations[(i / positions.count) % animations.count]
            let canvas = CGSize(width: rng.edgy(0, 4000, edges: [0, 1920, 1280, 3840]),
                                height: rng.edgy(0, 3000, edges: [0, 1080, 720, 2160]))
            let pill = CGSize(width: rng.edgy(0, 400, edges: [0, 28, 101.5]),
                              height: rng.edgy(0, 120, edges: [0, 37, 36.5]))
            let entry = rng.edgy(-0.2, 1.2, edges: [0, 0.5, 1, 0.999, 1.0000001, 0.25])
            let scale = CGFloat(rng.edgy(0, 4, edges: [0, 1, 2, 0.5, 1.5, 0.66666]))
            cases.append(vcase(
                [
                    "position": .str(position.rawValue), "animation": .str(animation.rawValue),
                    "canvasSize": canvas.wv, "pillSize": pill.wv, "entry": entry.wv, "scale": scale.wv,
                ],
                [
                    "slideOffset": KeystrokeOverlayMath.slideOffset(animation: animation, entry: entry, scale: scale).wv,
                    "popScale": KeystrokeOverlayMath.popScale(animation: animation, entry: entry).wv,
                    "pillCenter": KeystrokeOverlayMath.pillCenter(
                        position: position, canvasSize: canvas, pillSize: pill, entry: entry,
                        scale: scale, animation: animation).wv,
                    "pillCenterDefault": KeystrokeOverlayMath.pillCenter(
                        position: position, canvasSize: canvas, pillSize: pill, entry: entry, scale: scale).wv,
                    "pillRect": KeystrokeOverlayMath.pillRect(
                        position: position, canvasSize: canvas, pillSize: pill, entry: entry,
                        scale: scale, animation: animation).wv,
                ]))
        }
        return cases
    }

    static let keystrokeTextSamples: [String] = [
        "⌘S", "⌘⇧S", "⌃⌥⌘T", "⌘Z ×2", "⌘Z ×12", "⇧⌘4", "⌘⌫", "⌘←", "⌥⌘⎋", "fn F5", "⌘,",
        "⌘Space", "", "W", "⌘⇧⌥⌃K", "⌘⏎", "⌘⇥", "⌥⇧⌘V ×3",
    ]

    private static func keystrokePillMetricsCases() -> [WV] {
        var rng = WVRandom(seed: "keystrokeOverlayPillMetrics")
        var cases: [WV] = []
        var inputs: [(String, Double, CGFloat)] = []
        for text in keystrokeTextSamples {
            for size in [0.5, 0.75, 1.0, 1.25, 1.5, 2.0] {
                for scale in [0.5, 1.0, 1.3333333333333333, 2.0, 2.5] as [CGFloat] {
                    inputs.append((text, size, scale))
                }
            }
        }
        for _ in 0..<60 {
            inputs.append((rng.pick(keystrokeTextSamples), rng.double(0.4, 2.5), CGFloat(rng.double(0.3, 3))))
        }
        for (text, size, scale) in inputs {
            // Warm CoreText (first measurement at a new size is ~1e-10 off
            // the steady value; see WebVectors.textLineWV).
            _ = KeystrokeOverlayOracle.metrics(text: text, size: size, scale: scale)
            let m = KeystrokeOverlayOracle.metrics(text: text, size: size, scale: scale)
            let real = KeystrokeOverlayRenderer.pillSize(text: text, size: size, scale: scale)
            let oracleSize = KeystrokeOverlayOracle.pillSize(text: text, size: size, scale: scale)
            if oracleSize != real {
                print("WEB-VECTORS FAIL keystrokeOverlayPillMetrics: oracle pillSize \(oracleSize) != real \(real) for \(text)")
            }
            cases.append(vcase(
                ["text": .str(text), "size": size.wv, "scale": scale.wv],
                [
                    "metrics": [
                        "width": m.width.wv, "ascent": m.ascent.wv, "descent": m.descent.wv,
                        "fontName": .str(m.fontName), "familyName": .str(m.familyName),
                        "pointSize": m.pointSize.wv, "kern": m.kern.wv,
                    ],
                    "pillSize": real.wv,
                    "oracleMatchesReal": (oracleSize == real).wv,
                ]))
        }
        return cases
    }

    // MARK: - CurtainUnveilMath

    static func rgbaWV(_ c: CurtainUnveilMath.RGBA) -> WV {
        ["r": c.r.wv, "g": c.g.wv, "b": c.b.wv, "a": c.a.wv]
    }

    private static func curtainCurveCases() -> [WV] {
        var rng = WVRandom(seed: "curtainUnveilCurves")
        var ps: [Double] = [-1, -0.0, 0, 1e-9, 0.3, 0.5, 0.6, 0.6000001, 0.5999999, 0.75, 0.8, 0.8000001,
                            0.7999999, 0.88, 0.88000001, 0.87999999, 0.9, 0.95, 0.999, 1, 1.0000001, 2,
                            .nan, .infinity, -.infinity]
        for i in 0...200 { ps.append(Double(i) / 200) }
        for _ in 0..<500 { ps.append(rng.double(-0.1, 1.1)) }
        return ps.map { p in
            vcase(
                ["p": p.wv],
                [
                    "sweepEase": CurtainUnveilMath.sweepEase(p).wv,
                    "flapOverfoldRadians": CurtainUnveilMath.flapOverfoldRadians(p).wv,
                    "flapReleaseOffset": CurtainUnveilMath.flapReleaseOffset(p).wv,
                    "flapOpacityValue": CurtainUnveilMath.flapOpacityValue(p).wv,
                    "shadowWidthFraction": CurtainUnveilMath.shadowWidthFraction(p).wv,
                    "shadowStrengthValue": CurtainUnveilMath.shadowStrengthValue(p).wv,
                ])
        }
    }

    static func curtainStateWV(_ s: CurtainUnveilMath.State) -> WV {
        [
            "coverPolygon": s.coverPolygon.wv,
            "flapPolygon": s.flapPolygon.wv,
            "foldStart": s.foldStart.wv,
            "foldEnd": s.foldEnd.wv,
            "shadowStrength": s.shadowStrength.wv,
            "shadowWidth": s.shadowWidth.wv,
            "flapOpacity": s.flapOpacity.wv,
            "progress": s.progress.wv,
            "active": s.active.wv,
        ]
    }

    private static func curtainStateCases() -> [WV] {
        var rng = WVRandom(seed: "curtainUnveilState")
        var cases: [WV] = []
        let corners = CurtainUnveilCorner.allCases
        for i in 0..<120 {
            let corner = corners[i % corners.count]
            let start = rng.edgy(0, 5, edges: [0, 0.5])
            let duration = rng.edgy(0, 4, edges: [0, 0.05, 0.0500001, 0.7, 1.2, 2])
            // A 60 fps sequence through the whole effect (mid-flight frames).
            var times: [Double] = []
            var t = start - 0.05
            while t <= start + duration + 0.05, times.count < 260 {
                times.append(t)
                t += 1.0 / 60
            }
            for f in [0, 0.3, 0.6, 0.8, 0.88, 0.95, 0.999999, 1, 1.0000001] {
                times.append(start + duration * f)
            }
            for _ in 0..<5 { times.append(rng.double(start - 1, start + duration + 1)) }
            for time in times {
                let s = CurtainUnveilMath.state(corner: corner, at: time, startTime: start, duration: duration)
                cases.append(vcase(
                    ["corner": .str(corner.rawValue), "time": time.wv, "startTime": start.wv, "duration": duration.wv],
                    [
                        "state": curtainStateWV(s),
                        "shadowPolygon": CurtainUnveilMath.shadowPolygon(state: s).wv,
                        "ambientShadowPolygon": CurtainUnveilMath.ambientShadowPolygon(state: s).wv,
                    ]))
            }
        }
        return cases
    }

    private static func curtainGeometryCases() -> [WV] {
        var rng = WVRandom(seed: "curtainUnveilGeometry")
        var cases: [WV] = []
        for i in 0..<1200 {
            let n = i % 60 == 0 ? rng.int(0, 2) : rng.int(3, 9)
            let poly: [CGPoint] = (0..<n).map { _ in
                rng.bool(0.15) ? rng.pick([CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0.5, y: 0.5)])
                    : rng.point(-0.6, 1.6)
            }
            // Linear half-plane: keep a·x + b·y + c >= 0.
            let a = CGFloat(rng.edgy(-2, 2, edges: [0, 1, -1]))
            let b = CGFloat(rng.edgy(-2, 2, edges: [0, 1, -1]))
            let c = CGFloat(rng.edgy(-2, 2, edges: [0, 0.5, -0.5]))
            let p = rng.point(-1, 2)
            let la = rng.bool(0.1) ? p : rng.point(-1, 2)
            let lb = rng.bool(0.1) ? la : rng.point(-1, 2)
            let clipped = CurtainUnveilMath.clip(poly) { a * $0.x + b * $0.y + c }
            cases.append(vcase(
                ["polygon": poly.wv, "a": a.wv, "b": b.wv, "c": c.wv, "p": p.wv, "lineA": la.wv, "lineB": lb.wv],
                [
                    "reflect": CurtainUnveilMath.reflect(p, acrossLineThrough: la, lb).wv,
                    "polygonArea": CurtainUnveilMath.polygonArea(poly).wv,
                    "clip": clipped.wv,
                    "clipToUnitSquare": CurtainUnveilMath.clipToUnitSquare(poly).wv,
                    "unitSquare": CurtainUnveilMath.unitSquare.wv,
                    "cornerPoints": .arr(CurtainUnveilCorner.allCases.map { $0.point.wv }),
                ]))
        }
        return cases
    }

    private static func cardClipWV(_ c: CurtainUnveilMath.CardClip) -> WV {
        let shape: String
        switch c.shape {
        case .rectangle: shape = "rectangle"
        case .rounded: shape = "rounded"
        case .squircle: shape = "squircle"
        }
        return [
            "shape": .str(shape),
            "cornerRadiusFraction": c.cornerRadiusFraction.wv,
            "screenRectUnit": c.screenRectUnit.wv,
            "screenCornerRadiusFraction": c.screenCornerRadiusFraction.wv,
        ]
    }

    private static func curtainCardClipCases() -> [WV] {
        var rng = WVRandom(seed: "curtainUnveilCardClip")
        var cases: [WV] = []
        let shapes = ProjectSettings.FrameShape.allCases
        for i in 0..<1200 {
            let shape = shapes[i % shapes.count]
            let card = CGSize(width: rng.edgy(0, 2400, edges: [0, 0.5, 1, 1920, 800]),
                              height: rng.edgy(0, 1600, edges: [0, 0.5, 1, 1080, 800]))
            let radius = CGFloat(rng.edgy(-10, 400, edges: [0, 0.005, 0.02, 12, 10000]))
            var device: (rect: CGRect, cornerRadius: CGFloat)? = nil
            if rng.bool(0.3) {
                device = (CGRect(x: rng.double(-20, 200), y: rng.double(-20, 200),
                                 width: rng.edgy(-10, 1200, edges: [0]), height: rng.edgy(-10, 1200, edges: [0])),
                          CGFloat(rng.edgy(-5, 80, edges: [0, 55])))
            }
            let clip = CurtainUnveilMath.cardClip(frameShape: shape, cornerRadius: radius, cardSize: card, deviceScreen: device)
            let raster = CGSize(width: rng.edgy(1, 2400, edges: [1, 1920, card.width.rounded()]),
                                height: rng.edgy(1, 1600, edges: [1, 1080, card.height.rounded()]))
            let path = CurtainUnveilMath.cardClipPath(clip, size: raster)
            cases.append(vcase(
                [
                    "frameShape": .str(shape.rawValue), "cornerRadius": radius.wv, "cardSize": card.wv,
                    "deviceScreen": device.map { ["rect": $0.rect.wv, "cornerRadius": $0.cornerRadius.wv] as WV } ?? .null,
                    "rasterSize": raster.wv,
                ],
                ["cardClip": cardClipWV(clip), "cardClipPath": path.map(pathWV) ?? .null]))
        }
        return cases
    }

    private static func curtainCoverStyleCases() -> [WV] {
        var rng = WVRandom(seed: "curtainUnveilCoverStyle")
        var cases: [WV] = []
        for i in 0..<600 {
            let s = ProjectSettings()
            if i % 3 != 0 {
                s.curtainColor = CodableColor(red: rng.double(0, 1), green: rng.double(0, 1),
                                              blue: rng.double(0, 1), opacity: rng.edgy(0, 1, edges: [0, 1]))
            }
            if rng.bool(0.5) {
                s.curtainLogoTint = CodableColor(red: rng.double(0, 1), green: rng.double(0, 1),
                                                 blue: rng.double(0, 1), opacity: rng.double(0, 1))
            }
            s.curtainLogoOpacity = rng.edgy(-0.5, 1.5, edges: [0, 1, 0.001])
            s.curtainLogoScale = rng.edgy(0, 1.2, edges: [0, 0.25, 0.001])
            let style = CurtainUnveilMath.coverStyle(settings: s, logo: nil)
            let stops = CurtainUnveilMath.coverStops(base: style.baseColor)
            cases.append(vcase(
                [
                    "settings": [
                        "curtainColor": s.curtainColor.map(WVModel.color) ?? .null,
                        "curtainLogoTint": s.curtainLogoTint.map(WVModel.color) ?? .null,
                        "curtainLogoOpacity": s.curtainLogoOpacity.wv,
                        "curtainLogoScale": s.curtainLogoScale.wv,
                    ],
                ],
                [
                    "baseColor": style.baseColor.map(rgbaWV) ?? .null,
                    "logoOpacity": style.logoOpacity.wv,
                    "logoScale": style.logoScale.wv,
                    "logoTint": style.logoTint.map(rgbaWV) ?? .null,
                    "coverStops": ["top": rgbaWV(stops.top), "bottom": rgbaWV(stops.bottom)],
                    "constants": [
                        "coverColorTop": rgbaWV(CurtainUnveilMath.coverColorTop),
                        "coverColorBottom": rgbaWV(CurtainUnveilMath.coverColorBottom),
                        "flapColorNear": rgbaWV(CurtainUnveilMath.flapColorNear),
                        "flapColorFar": rgbaWV(CurtainUnveilMath.flapColorFar),
                        "foldShadowMaxOpacity": CurtainUnveilMath.foldShadowMaxOpacity.wv,
                        "shadowBandFraction": CurtainUnveilMath.shadowBandFraction.wv,
                        "coverDarkenFraction": CurtainUnveilMath.coverDarkenFraction.wv,
                        "sheenOpacity": CurtainUnveilMath.sheenOpacity.wv,
                        "sheenHalfWidth": CurtainUnveilMath.sheenHalfWidth.wv,
                        "vignetteOpacity": CurtainUnveilMath.vignetteOpacity.wv,
                        "vignetteRadiusFraction": CurtainUnveilMath.vignetteRadiusFraction.wv,
                        "ambientShadowWidthFraction": CurtainUnveilMath.ambientShadowWidthFraction.wv,
                        "ambientShadowMaxOpacity": CurtainUnveilMath.ambientShadowMaxOpacity.wv,
                        "foldSpecularOpacity": CurtainUnveilMath.foldSpecularOpacity.wv,
                        "foldSpecularWidthFactor": CurtainUnveilMath.foldSpecularWidthFactor.wv,
                        "flapSheenOpacity": CurtainUnveilMath.flapSheenOpacity.wv,
                        "flickStart": CurtainUnveilMath.flickStart.wv,
                        "flickJoin": CurtainUnveilMath.flickJoin.wv,
                        "releaseSlope": CurtainUnveilMath.releaseSlope.wv,
                        "releaseStart": CurtainUnveilMath.releaseStart.wv,
                        "releaseFadeWindow": CurtainUnveilMath.releaseFadeWindow.wv,
                        "baseOverfoldDegrees": CurtainUnveilMath.baseOverfoldDegrees.wv,
                        "whipOverfoldDegrees": CurtainUnveilMath.whipOverfoldDegrees.wv,
                        "releaseTravel": CurtainUnveilMath.releaseTravel.wv,
                        "whipShadowBoost": CurtainUnveilMath.whipShadowBoost.wv,
                    ],
                ]))
        }
        return cases
    }

    // MARK: - Path primitives

    private static func pathPrimitiveCases() -> [WV] {
        var rng = WVRandom(seed: "overlayPathPrimitives")
        var cases: [WV] = []
        for i in 0..<1500 {
            let rect: CGRect
            switch i % 10 {
            case 0: rect = CGRect(x: rng.double(-50, 50), y: rng.double(-50, 50), width: 0, height: rng.double(0, 50))
            case 1: rect = CGRect(x: rng.double(-50, 50), y: rng.double(-50, 50),
                                  width: rng.double(-100, 0), height: rng.double(-100, 100))
            default: rect = rng.rect(origin: -500, 1500, size: 0, 800)
            }
            let minSide = min(abs(rect.width), abs(rect.height))
            let r = CGFloat(rng.edgy(0, Double(minSide) * 0.7 + 1,
                                     edges: [0, 0.001, Double(minSide) / 2, Double(minSide) / 2 + 3, Double(minSide), -4]))
            let cgRounded: WV = r >= 0 && r * 2 <= abs(rect.width) + 1e-9 && r * 2 <= abs(rect.height) + 1e-9
                ? pathWV(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
                : .null
            // Oversized radii (CG clamps per axis) — only on standardized, non-degenerate rects.
            let cgRoundedClamped: WV = rect.width > 0 && rect.height > 0 && r > 0
                ? pathWV(CGPath(roundedRect: rect, cornerWidth: min(r, rect.width / 2 + 5),
                                cornerHeight: r, transform: nil))
                : .null
            cases.append(vcase(
                ["rect": rect.wv, "radius": r.wv],
                [
                    "rect": pathWV(CGPath(rect: rect, transform: nil)),
                    "ellipse": pathWV(CGPath(ellipseIn: rect, transform: nil)),
                    "roundedRect": cgRounded,
                    "roundedRectClampedX": cgRoundedClamped,
                    "continuous": pathWV(ContinuousRoundedRect.path(rect: rect, cornerRadius: r)),
                    "circular": pathWV(ContinuousRoundedRect.circularPath(rect: rect, cornerRadius: r)),
                ]))
        }
        return cases
    }
}
