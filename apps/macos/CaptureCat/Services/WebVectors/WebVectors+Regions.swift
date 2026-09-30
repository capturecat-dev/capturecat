import Foundation
import CoreGraphics
import CoreImage

// Golden-vector units for the REGIONS cluster (see WebVectorsHarness.swift):
// DeviceFrameLayout (+ ContinuousRoundedRect), region geometry
// (BlurRegion / BlurRegion+Feather / HighlightRegion / FocusRegion),
// FocusMath (scalars + the rendered mask), BlurStyleMath, DeviceSegmentDip.
// Exporter-private region compositing, the device-segment export rules, the
// bezel draw recipe and the menu bar layout are verbatim oracles in
// WebVectors+RegionsOracle.swift.
//
// TS ports: apps/web/src/editor/core/math/{deviceFrameLayout,regionGeometry,
// focusMath,blurStyleMath,deviceSegmentDip,deviceBezel,menuBarRenderer,
// exportRegions,regionsSupport}.ts — suite core/vectors/regions.test.ts.
extension WebVectors {
    static var regionUnits: [WebVectorUnit] {
        [
            WebVectorUnit(
                name: "deviceFrameLayoutConstants",
                notes: "Services/DeviceFrameLayout.swift — every static constant (RGB tones, rim/button alphas, side buttons, fractions) + ContinuousRoundedRect.fullReach + DeviceBezelRenderer.shadowBlurFactor",
                build: deviceFrameLayoutConstantCases),
            WebVectorUnit(
                name: "deviceFrameLayoutRGB",
                notes: "Services/DeviceFrameLayout.swift — RGB.init(hex:alpha:), RGB.mix(_:_:_:) (explicit t and default 0.5)",
                build: deviceFrameLayoutRGBCases),
            WebVectorUnit(
                name: "deviceFrameLayoutScalars",
                notes: "Services/DeviceFrameLayout.swift — rimWidth, seamWidth, isPhoneAspect, bezelWidth, screenCornerRadius, bezelCornerRadius, islandSize, islandTopInset",
                build: deviceFrameLayoutScalarCases),
            WebVectorUnit(
                name: "deviceFrameLayoutMetrics",
                notes: "Services/DeviceFrameLayout.swift — bezelRect(forVideoRect:), metrics(forVideoRect:) incl. Metrics.value(_:)",
                build: deviceFrameLayoutMetricsCases),
            WebVectorUnit(
                name: "continuousRoundedPath",
                notes: "Services/DeviceFrameLayout.swift continuousRoundedPath → Services/ContinuousRoundedRect.swift path(rect:cornerRadius:) — every CGPath element (CGPath.applyWithBlock) incl. the CGPath(rect:) fallback",
                build: continuousRoundedPathCases),
            WebVectorUnit(
                name: "regionConstants",
                notes: "Static constants: BlurRegion(+Feather), HighlightRegion, FocusMath, BlurStyleMath, DeviceSegmentDip",
                build: regionConstantCases),
            WebVectorUnit(
                name: "blurRegionGeometry",
                notes: "Models/BlurRegion.swift rectInViewSpace, rectInImageSpace, blurRadius(in:), duration + Models/BlurRegion+Feather.swift featherRadius(in:), featherSigma(in:)",
                build: blurRegionGeometryCases),
            WebVectorUnit(
                name: "highlightRegionGeometry",
                notes: "Models/HighlightRegion.swift rectInViewSpace, rectInImageSpace, cornerRadius(for:in:) (static), cornerRadius(in:), dimOpacity, duration",
                build: highlightRegionGeometryCases),
            WebVectorUnit(
                name: "focusRegionGeometry",
                notes: "Models/FocusRegion.swift rectInViewSpace(in:), duration",
                build: focusRegionGeometryCases),
            WebVectorUnit(
                name: "focusMathScalars",
                notes: "Services/FocusMath.swift bandWidth, blurRadius, blurSigma, blurAmount (area + tiltShift, default cornerRadius), roundedRectOutsideDistance",
                build: focusMathScalarCases),
            WebVectorUnit(
                name: "focusMathMask",
                notes: "Services/FocusMath.swift maskImage — the REAL CGImage: size, raw 8-bit bytes at sampled pixels (exact), full-raster byte sum + FNV-1a-32, and the same pixels RENDERED through a CIContext (linear sRGB working + output space, RGBAf) — float tolerance 1e-6 (Float32 quantization of byte/255)",
                build: focusMathMaskCases),
            WebVectorUnit(
                name: "blurStyleMath",
                notes: "Services/BlurStyleMath.swift pixelScale, quantizedStep, gridJitter, hash01",
                build: blurStyleMathCases),
            WebVectorUnit(
                name: "deviceSegmentDip",
                notes: "Services/DeviceSegmentDip.swift phase(at:boundaries:), scale(_:), opacity(_:)",
                build: deviceSegmentDipCases),
            WebVectorUnit(
                name: "regionEnvelope",
                notes: "Services/EasingFunctions.swift Easing.regionEnvelope (highlight dim fade) + Easing.smootherStep",
                build: regionEnvelopeCases),
        ] + regionOracleUnits
    }

    // MARK: - Shared encoders / generators

    static func rgbWV(_ c: DeviceFrameLayout.RGB) -> WV {
        ["r": c.r.wv, "g": c.g.wv, "b": c.b.wv, "a": c.a.wv]
    }

    static func srgbaWV(_ c: SRGBA) -> WV {
        ["red": c.red.wv, "green": c.green.wv, "blue": c.blue.wv, "alpha": c.alpha.wv]
    }

    /// CGPath → [{type, points}] in emission order.
    static func pathElementsWV(_ path: CGPath) -> WV {
        var out: [WV] = []
        path.applyWithBlock { el in
            let e = el.pointee
            let type: String
            let n: Int
            switch e.type {
            case .moveToPoint: type = "move"; n = 1
            case .addLineToPoint: type = "line"; n = 1
            case .addQuadCurveToPoint: type = "quad"; n = 2
            case .addCurveToPoint: type = "curve"; n = 3
            case .closeSubpath: type = "close"; n = 0
            @unknown default: type = "unknown"; n = 0
            }
            var pts: [WV] = []
            for i in 0..<n { pts.append(e.points[i].wv) }
            out.append(["type": .str(type), "points": .arr(pts)])
        }
        return .arr(out)
    }

    /// A normalized region rect (0…1, Y-down) with the shapes real projects
    /// have plus degenerate/negative/out-of-frame edges.
    static func randomRegionRect(_ rng: inout WVRandom) -> CGRect {
        let x = rng.edgy(-0.2, 1.1, edges: [0, 1, 0.5, 0.25])
        let y = rng.edgy(-0.2, 1.1, edges: [0, 1, 0.5, 0.75])
        var w = rng.edgy(0, 1.1, edges: [0, 1, 1e-9, 0.00001, 0.4])
        var h = rng.edgy(0, 1.1, edges: [0, 1, 1e-9, 0.00001, 0.15])
        if rng.bool(0.06) { w = -w }
        if rng.bool(0.06) { h = -h }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// A container / video rect in points or pixels.
    static func randomContainerRect(_ rng: inout WVRandom) -> CGRect {
        let x = rng.edgy(-400, 3000, edges: [0, 12.5, 160])
        let y = rng.edgy(-400, 3000, edges: [0, 7.25, 90])
        var w = rng.edgy(0, 4000, edges: [0, 1, 1920, 1280, 402, 390.5, 3840])
        var h = rng.edgy(0, 4000, edges: [0, 1, 1080, 720, 874, 844.25, 2160])
        if rng.bool(0.04) { w = -w }
        if rng.bool(0.04) { h = -h }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    static func randomPixelVideoRect(_ rng: inout WVRandom) -> CGRect {
        let phone = rng.bool(0.4)
        let w = phone ? rng.edgy(80, 1400, edges: [402, 390, 590.25]) : rng.edgy(100, 3800, edges: [1920, 1280, 1728])
        let h = phone ? w * rng.edgy(1.5, 2.3, edges: [2.174, 1.5, 1.5000001]) : w * rng.edgy(0.3, 1.5, edges: [0.5625, 0.75, 1, 1.5])
        return CGRect(x: rng.edgy(0, 800, edges: [0, 96]), y: rng.edgy(0, 600, edges: [0, 54.5]), width: w, height: h)
    }

    // MARK: - DeviceFrameLayout

    private static func deviceFrameLayoutConstantCases() -> [WV] {
        typealias L = DeviceFrameLayout
        let buttons: [WV] = L.sideButtons.map {
            ["centerFraction": $0.centerFraction.wv, "lengthFraction": $0.lengthFraction.wv,
             "isLeft": $0.isLeft.wv, "thicknessFraction": $0.thicknessFraction.wv]
        }
        return [vcase(
            [:],
            [
                "bandTop": rgbWV(L.bandTop), "bandMid": rgbWV(L.bandMid), "bandBottom": rgbWV(L.bandBottom),
                "sideTop": rgbWV(L.sideTop), "sideBottom": rgbWV(L.sideBottom),
                "glassColor": rgbWV(L.glassColor),
                "rimHighlight": L.rimHighlight.wv, "rimMid": L.rimMid.wv,
                "rimShadowSide": L.rimShadowSide.wv, "innerShadow": L.innerShadow.wv,
                "buttonTop": rgbWV(L.buttonTop), "buttonBottom": rgbWV(L.buttonBottom),
                "buttonRim": L.buttonRim.wv,
                "sideButtons": .arr(buttons),
                "borderFraction": L.borderFraction.wv,
                "glassMarginFraction": L.glassMarginFraction.wv,
                "screenCornerFraction": L.screenCornerFraction.wv,
                "islandWidthFraction": L.islandWidthFraction.wv,
                "islandHeightFraction": L.islandHeightFraction.wv,
                "islandTopFraction": L.islandTopFraction.wv,
                "cameraDotFraction": L.cameraDotFraction.wv,
                "cameraDotOffsetFraction": L.cameraDotOffsetFraction.wv,
                "padCornerFraction": L.padCornerFraction.wv,
                "continuousFullReach": ContinuousRoundedRect.fullReach.wv,
                "shadowBlurFactor": DeviceBezelRenderer.shadowBlurFactor.wv,
            ]
        )]
    }

    private static func deviceFrameLayoutRGBCases() -> [WV] {
        var rng = WVRandom(seed: "deviceFrameLayoutRGB")
        var cases: [WV] = []
        let hexEdges: [UInt32] = [0, 0xFFFFFF, 0x4C4A47, 0x0A0A0B, 0xFF0000, 0x00FF00, 0x0000FF, 0xFFFFFFFF, 0x12345678]
        for i in 0..<800 {
            let hex: UInt32 = i < hexEdges.count ? hexEdges[i] : UInt32(truncatingIfNeeded: rng.next())
            let alpha = CGFloat(rng.edgy(0, 1, edges: [0, 1, 0.5]))
            func rnd(_ rng: inout WVRandom) -> DeviceFrameLayout.RGB {
                DeviceFrameLayout.RGB(rng.cg(-0.2, 1.2), rng.cg(0, 1), rng.cg(0, 1), rng.bool(0.7) ? 1 : rng.cg(0, 1))
            }
            let x = rnd(&rng), y = rnd(&rng)
            let t = CGFloat(rng.edgy(-0.5, 1.5, edges: [0, 0.5, 1]))
            cases.append(vcase(
                ["hex": .int(Int(hex)), "alpha": alpha.wv, "x": rgbWV(x), "y": rgbWV(y), "t": t.wv],
                [
                    "fromHex": rgbWV(DeviceFrameLayout.RGB(hex: hex, alpha: alpha)),
                    "mix": rgbWV(DeviceFrameLayout.RGB.mix(x, y, t)),
                    "mixDefault": rgbWV(DeviceFrameLayout.RGB.mix(x, y)),
                ]
            ))
        }
        return cases
    }

    private static func deviceFrameLayoutScalarCases() -> [WV] {
        var rng = WVRandom(seed: "deviceFrameLayoutScalars")
        var cases: [WV] = []
        for i in 0..<1500 {
            let width = CGFloat(i < 6 ? [0, -1, .nan, .infinity, 1e-300, 95.2380952380952][i]
                : rng.edgy(-100, 4000, edges: [0, 1, 222.2222, 222.22222222222223, 95.23809523809524, 402, 1920]))
            let w = CGFloat(rng.edgy(-50, 3000, edges: [0, 402, 1000]))
            let hFactor = rng.edgy(0, 3, edges: [1.5, 1.4999999, 1.5000001, 0, 2.174])
            let size = CGSize(width: w, height: i % 37 == 0 ? CGFloat(rng.double(-100, 100)) : w * CGFloat(hFactor))
            cases.append(vcase(
                ["width": width.wv, "size": size.wv],
                [
                    "rimWidth": DeviceFrameLayout.rimWidth(forVideoWidth: width).wv,
                    "seamWidth": DeviceFrameLayout.seamWidth(forVideoWidth: width).wv,
                    "bezelWidth": DeviceFrameLayout.bezelWidth(forVideoWidth: width).wv,
                    "islandSize": DeviceFrameLayout.islandSize(forVideoWidth: width).wv,
                    "islandTopInset": DeviceFrameLayout.islandTopInset(forVideoWidth: width).wv,
                    "isPhoneAspect": DeviceFrameLayout.isPhoneAspect(size).wv,
                    "screenCornerRadius": DeviceFrameLayout.screenCornerRadius(forVideoSize: size).wv,
                    "bezelCornerRadius": DeviceFrameLayout.bezelCornerRadius(forVideoSize: size).wv,
                ]
            ))
        }
        return cases
    }

    static func metricsWV(_ m: DeviceFrameLayout.Metrics) -> WV {
        [
            "isPhone": m.isPhone.wv, "unit": m.unit.wv,
            "screenRect": m.screenRect.wv, "screenCornerRadius": m.screenCornerRadius.wv,
            "bodyRect": m.bodyRect.wv, "bodyCornerRadius": m.bodyCornerRadius.wv,
            "glassRect": m.glassRect.wv, "glassCornerRadius": m.glassCornerRadius.wv,
            "rimWidth": m.rimWidth.wv, "seamWidth": m.seamWidth.wv,
        ]
    }

    private static func deviceFrameLayoutMetricsCases() -> [WV] {
        var rng = WVRandom(seed: "deviceFrameLayoutMetrics")
        var cases: [WV] = []
        for i in 0..<1500 {
            let r: CGRect = i % 3 == 0 ? randomContainerRect(&rng) : randomPixelVideoRect(&rng)
            let fraction = CGFloat(rng.edgy(0, 0.5, edges: [DeviceFrameLayout.cameraDotFraction, 0]))
            let m = DeviceFrameLayout.metrics(forVideoRect: r)
            cases.append(vcase(
                ["videoRect": r.wv, "fraction": fraction.wv],
                [
                    "bezelRect": DeviceFrameLayout.bezelRect(forVideoRect: r).wv,
                    "metrics": metricsWV(m),
                    "value": m.value(fraction).wv,
                ]
            ))
        }
        return cases
    }

    private static func continuousRoundedPathCases() -> [WV] {
        var rng = WVRandom(seed: "continuousRoundedPath")
        var cases: [WV] = []
        for i in 0..<1200 {
            var rect = CGRect(
                x: rng.edgy(-300, 2000, edges: [0, 10.5]),
                y: rng.edgy(-300, 2000, edges: [0, 20.25]),
                width: rng.edgy(0, 2000, edges: [0, 1, 2, 402, 100]),
                height: rng.edgy(0, 2000, edges: [0, 1, 2, 874, 100]))
            if i % 41 == 0 { rect.size.width = -rect.size.width }
            if i % 43 == 0 { rect.size.height = -rect.size.height }
            let short = min(rect.width, rect.height)
            let radius = CGFloat(i == 7 ? .nan : rng.edgy(-10, 600, edges: [
                0, -1, Double(short / 2), Double(short / 2) + 1e-9, Double(short / 3.057330), Double(short) * 0.155,
                Double(short / 2 / 1.528665), 1e9, 62,
            ]))
            cases.append(vcase(
                ["rect": rect.wv, "cornerRadius": radius.wv],
                ["elements": pathElementsWV(DeviceFrameLayout.continuousRoundedPath(rect: rect, cornerRadius: radius))]
            ))
        }
        return cases
    }

    // MARK: - Region geometry

    private static func regionConstantCases() -> [WV] {
        [vcase(
            [:],
            [
                "blurRegion": [
                    "previewCornerRadius": BlurRegion.previewCornerRadius.wv,
                    "blurFeatherFraction": BlurRegion.blurFeatherFraction.wv,
                    "blurFeatherMinimum": BlurRegion.blurFeatherMinimum.wv,
                    "blurFeatherMaxFraction": BlurRegion.blurFeatherMaxFraction.wv,
                ],
                "highlightRegion": [
                    "previewCornerRadius": HighlightRegion.previewCornerRadius.wv,
                    "cornerRadiusRatio": HighlightRegion.cornerRadiusRatio.wv,
                ],
                "focusMath": [
                    "defaultCornerRadius": FocusMath.defaultCornerRadius.wv,
                    "minBandFraction": FocusMath.minBandFraction.wv,
                    "maxBandFraction": FocusMath.maxBandFraction.wv,
                    "maxBlurRadiusFraction": FocusMath.maxBlurRadiusFraction.wv,
                    "maskResolution": FocusMath.maskResolution.wv,
                ],
                "blurStyleMath": [
                    "animationStep": BlurStyleMath.animationStep.wv,
                    "minBlockFraction": BlurStyleMath.minBlockFraction.wv,
                    "maxBlockFraction": BlurStyleMath.maxBlockFraction.wv,
                    "minBlockPoints": BlurStyleMath.minBlockPoints.wv,
                ],
                "deviceSegmentDip": [
                    "sigma": DeviceSegmentDip.sigma.wv,
                    "scaleDrop": DeviceSegmentDip.scaleDrop.wv,
                    "opacityDrop": DeviceSegmentDip.opacityDrop.wv,
                ],
            ]
        )]
    }

    static func randomBlurRegion(_ rng: inout WVRandom) -> BlurRegion {
        let s = rng.edgy(-1, 60, edges: [0, 1])
        let e = s + rng.edgy(-0.5, 10, edges: [0, 0.001, 2])
        return BlurRegion(
            id: rng.uuid(), startTime: s, endTime: e, label: rng.pick(["Blur", "Secret", ""]),
            rect: randomRegionRect(&rng),
            intensity: rng.edgy(-0.2, 1.2, edges: [0, 0.1, 0.6, 1, 0.05]),
            style: rng.bool(0.5) ? .blur : .pixelate,
            animated: rng.bool(0.5))
    }

    static func randomHighlightRegion(_ rng: inout WVRandom) -> HighlightRegion {
        let s = rng.edgy(-1, 60, edges: [0, 1])
        let e = s + rng.edgy(-0.5, 10, edges: [0, 0.001, 0.24, 0.12, 2])
        return HighlightRegion(
            id: rng.uuid(), startTime: s, endTime: e, label: "Highlight",
            rect: randomRegionRect(&rng),
            opacity: rng.edgy(-0.2, 1.2, edges: [0, 0.05, 0.55, 0.95, 1]))
    }

    static func randomFocusRegion(_ rng: inout WVRandom) -> FocusRegion {
        let s = rng.edgy(-1, 60, edges: [0, 1])
        let e = s + rng.edgy(-0.5, 10, edges: [0, 0.001, 2])
        return FocusRegion(
            id: rng.uuid(), startTime: s, endTime: e, label: "Focus",
            rect: randomRegionRect(&rng),
            intensity: rng.edgy(-0.2, 1.2, edges: [0, 0.7, 1]),
            falloff: rng.edgy(-0.2, 1.2, edges: [0, 0.45, 1]),
            style: rng.bool(0.5) ? .area : .tiltShift,
            angle: rng.edgy(-120, 120, edges: [0, 90, -90, 45]),
            cornerRadius: rng.edgy(-0.2, 1.2, edges: [0, 0.24, 1]))
    }

    private static func blurRegionGeometryCases() -> [WV] {
        var rng = WVRandom(seed: "blurRegionGeometry")
        var cases: [WV] = []
        for _ in 0..<1500 {
            let region = randomBlurRegion(&rng)
            let container = randomContainerRect(&rng)
            let size = rng.bool(0.5) ? container.size : CGSize(width: rng.double(-10, 4000), height: rng.double(0, 4000))
            cases.append(vcase(
                ["region": WVModel.blurRegion(region), "containerRect": container.wv, "containerSize": size.wv],
                [
                    "rectInViewSpace": region.rectInViewSpace(in: container).wv,
                    "rectInImageSpace": region.rectInImageSpace(in: container).wv,
                    "blurRadius": region.blurRadius(in: size).wv,
                    "featherRadius": region.featherRadius(in: size).wv,
                    "featherSigma": region.featherSigma(in: size).wv,
                    "duration": region.duration.wv,
                ]
            ))
        }
        return cases
    }

    private static func highlightRegionGeometryCases() -> [WV] {
        var rng = WVRandom(seed: "highlightRegionGeometry")
        var cases: [WV] = []
        for _ in 0..<1500 {
            let region = randomHighlightRegion(&rng)
            let container = randomContainerRect(&rng)
            let other = randomRegionRect(&rng)
            cases.append(vcase(
                ["region": WVModel.highlightRegion(region), "containerRect": container.wv, "otherRect": other.wv],
                [
                    "rectInViewSpace": region.rectInViewSpace(in: container).wv,
                    "rectInImageSpace": region.rectInImageSpace(in: container).wv,
                    "cornerRadius": region.cornerRadius(in: container).wv,
                    "cornerRadiusFor": HighlightRegion.cornerRadius(for: other, in: container).wv,
                    "dimOpacity": region.dimOpacity.wv,
                    "duration": region.duration.wv,
                ]
            ))
        }
        return cases
    }

    private static func focusRegionGeometryCases() -> [WV] {
        var rng = WVRandom(seed: "focusRegionGeometry")
        var cases: [WV] = []
        for _ in 0..<800 {
            let region = randomFocusRegion(&rng)
            let container = randomContainerRect(&rng)
            cases.append(vcase(
                ["region": WVModel.focusRegion(region), "containerRect": container.wv],
                ["rectInViewSpace": region.rectInViewSpace(in: container).wv, "duration": region.duration.wv]
            ))
        }
        return cases
    }

    // MARK: - FocusMath

    private static func randomVideoSize(_ rng: inout WVRandom) -> CGSize {
        CGSize(width: rng.edgy(2, 4000, edges: [1920, 1280, 402, 2, 3]),
               height: rng.edgy(2, 4000, edges: [1080, 720, 874, 2, 3]))
    }

    private static func focusMathScalarCases() -> [WV] {
        var rng = WVRandom(seed: "focusMathScalars")
        var cases: [WV] = []
        for i in 0..<2000 {
            let videoSize = i % 50 == 0 ? CGSize(width: rng.double(-10, 10), height: rng.double(0, 10)) : randomVideoSize(&rng)
            let falloff = rng.edgy(-0.5, 1.5, edges: [0, 1, 0.45])
            let intensity = rng.edgy(-0.5, 1.5, edges: [0, 1, 0.7])
            let region = randomRegionRect(&rng)
            let style: FocusRegionStyle = rng.bool(0.5) ? .area : .tiltShift
            let angle = rng.edgy(-180, 180, edges: [0, 90, -90, 45, 30])
            let corner = rng.edgy(-0.5, 1.5, edges: [0, 1, 0.24])
            let points: [CGPoint] = (0..<6).map { _ in
                CGPoint(x: rng.edgy(-0.3, 1.3, edges: [Double(region.minX), Double(region.maxX), Double(region.midX), 0, 1]),
                        y: rng.edgy(-0.3, 1.3, edges: [Double(region.minY), Double(region.maxY), Double(region.midY), 0, 1]))
            }
            let rr = CGRect(x: rng.double(-100, 1000), y: rng.double(-100, 1000),
                            width: rng.edgy(0, 800, edges: [0]), height: rng.edgy(0, 800, edges: [0]))
            let rp = CGPoint(x: rng.double(-200, 1200), y: rng.double(-200, 1200))
            let rc = CGFloat(rng.edgy(-10, 500, edges: [0, 1e6]))
            cases.append(vcase(
                [
                    "videoSize": videoSize.wv, "falloff": falloff.wv, "intensity": intensity.wv,
                    "regionRect": region.wv, "style": .str(style.rawValue), "angle": angle.wv,
                    "cornerRadius": corner.wv, "points": points.wv,
                    "distRect": rr.wv, "distPoint": rp.wv, "distCorner": rc.wv,
                ],
                [
                    "bandWidth": FocusMath.bandWidth(falloff: falloff, videoSize: videoSize).wv,
                    "blurRadius": FocusMath.blurRadius(intensity: intensity, videoSize: videoSize).wv,
                    "blurSigma": FocusMath.blurSigma(intensity: intensity, videoSize: videoSize).wv,
                    "blurAmount": points.map {
                        FocusMath.blurAmount(at: $0, regionRect: region, style: style, angleDegrees: angle,
                                             falloff: falloff, cornerRadius: corner, videoSize: videoSize)
                    }.wv,
                    "blurAmountDefaultCorner": points.map {
                        FocusMath.blurAmount(at: $0, regionRect: region, style: style, angleDegrees: angle,
                                             falloff: falloff, videoSize: videoSize)
                    }.wv,
                    "roundedRectOutsideDistance": FocusMath.roundedRectOutsideDistance(rp, rect: rr, cornerRadius: rc).wv,
                ]
            ))
        }
        return cases
    }

    /// Renders a CGImage through a CIContext into linear-sRGB RGBAf and
    /// returns the red channel (gray mask → R = G = B).
    private static func ciRenderGrayMask(_ cg: CGImage, context: CIContext) -> [Float]? {
        let image = CIImage(cgImage: cg)
        let w = cg.width, h = cg.height
        var buf = [Float](repeating: 0, count: w * h * 4)
        guard let linear = CGColorSpace(name: CGColorSpace.linearSRGB) else { return nil }
        buf.withUnsafeMutableBytes { raw in
            context.render(image, toBitmap: raw.baseAddress!, rowBytes: w * 16,
                           bounds: CGRect(x: 0, y: 0, width: w, height: h),
                           format: .RGBAf, colorSpace: linear)
        }
        // CI bitmaps are written top row first (row 0 = image top).
        return (0..<(w * h)).map { buf[$0 * 4] }
    }

    private static func focusMathMaskCases() -> [WV] {
        var rng = WVRandom(seed: "focusMathMask")
        var cases: [WV] = []
        guard let linear = CGColorSpace(name: CGColorSpace.linearSRGB) else { return [] }
        let context = CIContext(options: [
            .workingColorSpace: linear, .workingFormat: NSNumber(value: CIFormat.RGBAf.rawValue), .useSoftwareRenderer: false,
        ])
        for i in 0..<360 {
            let videoSize: CGSize = i % 45 == 0
                ? CGSize(width: rng.edgy(-2, 3, edges: [1, 1.0000001, 2]), height: rng.edgy(0, 3, edges: [1, 2]))
                : CGSize(width: rng.edgy(3, 4000, edges: [1920, 402, 3]), height: rng.edgy(3, 4000, edges: [1080, 874, 3, 2000]))
            let region = randomRegionRect(&rng)
            let style: FocusRegionStyle = rng.bool(0.5) ? .area : .tiltShift
            let angle = rng.edgy(-180, 180, edges: [0, 90, -90, 45])
            let falloff = rng.edgy(-0.2, 1.2, edges: [0, 1, 0.45])
            let corner = rng.edgy(-0.2, 1.2, edges: [0, 1, 0.24])
            let input: WV = [
                "videoSize": videoSize.wv, "regionRect": region.wv, "style": .str(style.rawValue),
                "angle": angle.wv, "falloff": falloff.wv, "cornerRadius": corner.wv,
            ]
            guard let cg = FocusMath.maskImage(
                regionRect: region, style: style, angleDegrees: angle, falloff: falloff,
                cornerRadius: corner, videoSize: videoSize)
            else {
                cases.append(vcase(input.setting("samples", .arr([])), ["mask": .null]))
                continue
            }
            let w = cg.width, h = cg.height
            // The raw bytes the exporter hands to CIImage(cgImage:).
            guard let data = cg.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { continue }
            let rowBytes = cg.bytesPerRow
            var bytes = [UInt8](repeating: 0, count: w * h)
            for j in 0..<h { for k in 0..<w { bytes[j * w + k] = ptr[j * rowBytes + k] } }
            var sum = 0
            var fnv: UInt32 = 0x811C9DC5
            for b in bytes {
                sum += Int(b)
                fnv ^= UInt32(b)
                fnv = fnv &* 0x01000193
            }
            let rendered = ciRenderGrayMask(cg, context: context)
            // Deterministic sample points: corners, centre, the region's edges
            // mapped to raster indices, and random pixels.
            var samples: [(Int, Int)] = [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1), (w / 2, h / 2)]
            for fx in [region.minX, region.midX, region.maxX] {
                for fy in [region.minY, region.midY, region.maxY] {
                    let si = Int(max(0, min(CGFloat(w - 1), (fx * CGFloat(w)).rounded(.down))))
                    let sj = Int(max(0, min(CGFloat(h - 1), (fy * CGFloat(h)).rounded(.down))))
                    samples.append((si, sj))
                }
            }
            for _ in 0..<34 { samples.append((rng.int(0, w - 1), rng.int(0, h - 1))) }
            let sampleWV: [WV] = samples.map { ["i": .int($0.0), "j": .int($0.1)] }
            var renderedWV: WV = .null
            if let r = rendered {
                renderedWV = .arr(samples.map { .num(Double(r[$0.1 * w + $0.0])) })
                // Self-check: the CI render must reproduce byte/255 (catches a
                // flipped readback or colour conversion in this harness).
                let worst = (0..<(w * h)).reduce(0.0) { acc, k in max(acc, abs(Double(r[k]) - Double(bytes[k]) / 255)) }
                if worst > 1e-6 { print("WEB-VECTORS note: focusMathMask case \(i) CI render deviates by \(worst)") }
            }
            cases.append(vcase(
                input.setting("samples", .arr(sampleWV)),
                [
                    "mask": [
                        "width": .int(w), "height": .int(h),
                        "bytes": .arr(samples.map { .int(Int(bytes[$0.1 * w + $0.0])) }),
                        "rendered": renderedWV,
                        "byteSum": .int(sum),
                        "fnv1a32": .int(Int(fnv)),
                    ],
                ]
            ))
        }
        return cases
    }

    // MARK: - BlurStyleMath

    private static func blurStyleMathCases() -> [WV] {
        var rng = WVRandom(seed: "blurStyleMath")
        var cases: [WV] = []
        for i in 0..<2000 {
            let strength = rng.edgy(-0.5, 1.5, edges: [0, 1, 0.6])
            let regionSize = CGSize(width: rng.edgy(-10, 3000, edges: [0, 10, 100]), height: rng.edgy(-10, 3000, edges: [0, 10, 100]))
            let time = i < 12
                ? [0, 0.125, -0.125, 0.12499999999999999, 0.125000000001, -1e-12, 1e9, -1e9, 7.875, 3.0000000000000004, 1e15, -0.0][i]
                : rng.edgy(-100, 1000, edges: [0, 0.125, 1, 1.125, -0.0625, 1000.125])
            let animated = rng.bool(0.7)
            let block = CGFloat(rng.edgy(-5, 200, edges: [0, 3, 1e-9, 64]))
            let step = rng.int(-1_000_000, 1_000_000)
            let salt = rng.pick([0x51, 0xA7, 0, -1, Int.max, Int.min, rng.int(-1_000_000_000, 1_000_000_000)])
            cases.append(vcase(
                [
                    "strength": strength.wv, "regionSize": regionSize.wv, "time": time.wv,
                    "animated": animated.wv, "blockSize": block.wv,
                    "step": .str(String(step)), "salt": .str(String(salt)),
                ],
                [
                    "pixelScale": BlurStyleMath.pixelScale(strength: strength, regionSize: regionSize).wv,
                    "quantizedStep": .int(BlurStyleMath.quantizedStep(at: time)),
                    "gridJitter": BlurStyleMath.gridJitter(at: time, animated: animated, blockSize: block).wv,
                    "hash01": BlurStyleMath.hash01(step, salt).wv,
                ]
            ))
        }
        return cases
    }

    // MARK: - DeviceSegmentDip

    private static func deviceSegmentDipCases() -> [WV] {
        var rng = WVRandom(seed: "deviceSegmentDip")
        var cases: [WV] = []
        for i in 0..<1500 {
            let n = i % 40 == 0 ? 0 : rng.int(1, 8)
            var boundaries: [Double] = []
            var t = rng.edgy(-2, 20, edges: [0])
            for _ in 0..<n {
                boundaries.append(t)
                t += rng.edgy(0, 10, edges: [0, 0.15, 0.3, 0.001])
            }
            let queries: [Double] = (0..<10).map { _ in
                rng.edgy(-3, t + 3, edges: boundaries + boundaries.map { $0 + 0.15 } + boundaries.map { $0 - 0.6 } + [0])
            }
            let phases = queries.map { DeviceSegmentDip.phase(at: $0, boundaries: boundaries) }
            let extraPhases: [Double] = [0, 1, 0.5, rng.double(-1, 2)]
            cases.append(vcase(
                ["boundaries": boundaries.wv, "queries": queries.wv, "extraPhases": extraPhases.wv],
                [
                    "phase": phases.wv,
                    "scale": phases.map { DeviceSegmentDip.scale($0) }.wv,
                    "opacity": phases.map { DeviceSegmentDip.opacity($0) }.wv,
                    "extraScale": extraPhases.map { DeviceSegmentDip.scale($0) }.wv,
                    "extraOpacity": extraPhases.map { DeviceSegmentDip.opacity($0) }.wv,
                ]
            ))
        }
        return cases
    }

    // MARK: - Easing.regionEnvelope

    private static func regionEnvelopeCases() -> [WV] {
        var rng = WVRandom(seed: "regionEnvelope")
        var cases: [WV] = []
        for i in 0..<2500 {
            let s = rng.edgy(-5, 60, edges: [0, 1])
            let e = i % 29 == 0 ? s - rng.double(0, 1) : s + rng.edgy(0, 12, edges: [0, 0.12, 0.24, 0.2400001, 0.5, 1.6, 2.4])
            let td = rng.edgy(-0.5, 2, edges: [0.3, 0.5, 0.8, 1.2, 0, 0.12])
            let queries: [Double] = (0..<8).map { _ in
                rng.edgy(s - 1, e + 1, edges: [s, e, s + td, e - td, s + 0.12, e - 0.12, (s + e) / 2])
            }
            let smooth: [Double] = [rng.double(-0.5, 1.5), 0, 1, 0.5]
            cases.append(vcase(
                ["startTime": s.wv, "endTime": e.wv, "transitionDuration": td.wv, "queries": queries.wv, "smoothInputs": smooth.wv],
                [
                    "envelope": queries.map {
                        Easing.regionEnvelope(at: $0, startTime: s, endTime: e, transitionDuration: td)
                    }.wv,
                    "smootherStep": smooth.map { Easing.smootherStep($0) }.wv,
                ]
            ))
        }
        return cases
    }
}
