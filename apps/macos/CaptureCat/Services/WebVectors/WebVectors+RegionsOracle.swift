import AppKit
import CoreGraphics
import Foundation

// VERBATIM ORACLES for the REGIONS cluster — exporter/renderer math that only
// exists as locals inside larger functions (private `VideoExporter` methods,
// locals inside `VideoExporter.export`, CGContext draw calls inside
// `DeviceBezelRenderer`, the NSImage drawing handler in `MenuBarRenderer`).
// Every oracle calls the REAL shared helpers (BlurRegion, HighlightRegion,
// FocusMath, BlurStyleMath, DeviceFrameLayout, DeviceSegmentDip, Easing) and
// copies only the glue, line for line, from commit
// da569841c7b63175bffa46d897457f157224774d. Keep them in lockstep with the
// cited lines: a change there must be mirrored here AND in the TS port.
extension WebVectors {
    static var regionOracleUnits: [WebVectorUnit] {
        [
            WebVectorUnit(
                name: "exportActiveRegions",
                notes: "verbatim oracle — VideoExporter.swift export(): activeBlurs (1614-1616), activeFocusRegions (1630-1632), activeHighlights (1783-1785): `currentTime >= start && currentTime <= end`, project order preserved",
                build: exportActiveRegionCases),
            WebVectorUnit(
                name: "exportRegionBlur",
                notes: "verbatim oracle — VideoExporter.swift applyRegionBlur (2636-2724): pixelRect guard, CIGaussianBlur inputRadius (= blurRadius, NOT halved), CIPixellate scale/center, feather sigma + >0.01 gate; real BlurRegion/BlurStyleMath helpers",
                build: exportRegionBlurCases),
            WebVectorUnit(
                name: "exportRegionHighlight",
                notes: "verbatim oracle — VideoExporter.swift applyRegionHighlight (2726-2804) + highlightOutsideMaskImage geometry (2806-2877): pixelRect guard, corner radius, Easing.regionEnvelope, sRGB→linear dim opacity, mask raster size + adjusted dim/hole rects",
                build: exportRegionHighlightCases),
            WebVectorUnit(
                name: "exportFocusPlan",
                notes: "verbatim oracle — VideoExporter.swift export() Depth Focus block (1633-1664): REAL FocusMath.maskImage raster size, mask CI transform (scale to video rect, translate to its origin), FocusMath.blurSigma",
                build: exportFocusPlanCases),
            WebVectorUnit(
                name: "deviceSegmentExport",
                notes: "verbatim oracle — VideoExporter.swift export(): deviceFrameActive (743), segmentDeviceAssets (929-981; subRect from the FIRST device segment), deviceSegmentActive/deviceBoundaryDip (1018-1027), dip hot spans (1296-1300), dip transform + fade (2013-2027, fadeImage 3181-3189), curtain device screen rect (1871-1886); real DeviceFrameLayout/DeviceSegmentDip",
                build: deviceSegmentExportCases),
            WebVectorUnit(
                name: "deviceBezelRecipe",
                notes: "verbatim oracle — DeviceBezelRenderer.swift drawSideButtons (171-209), drawSideSlab (215-228), drawBody (233-320), drawIsland (323-362), fillVertical (367-387) as draw-recipe data; DeviceFrameRenderer.swift flip (75-78) for the exporter's CI rects; real DeviceFrameLayout.metrics",
                build: deviceBezelRecipeCases),
            WebVectorUnit(
                name: "menuBarLayout",
                notes: "verbatim oracle — MenuBarRenderer.swift image(for:) (19-116): guard, colours (calibrated + sRGB-converted), font sizes, pad, clock / status-icon / logo / title positions (NSImage y-up space) from REAL NSAttributedString.size() + SF Symbol sizes (the measured sizes are inputs)",
                build: menuBarLayoutCases),
            WebVectorUnit(
                name: "menuBarTextMetrics",
                notes: "MenuBarRenderer.swift fonts — reference table of REAL AppKit measurements (NSAttributedString.size(), SF Symbol sizes, font names) per bar height; the TS port reproduces the font requests, the sizes are calibration data for the browser",
                build: menuBarTextMetricCases),
            WebVectorUnit(
                name: "menuBarExportPlacement",
                notes: "verbatim oracle — VideoExporter.swift export(): menuBarCrop (386-395), cachedMenuBar spec + placement (987-1010) with the REAL MenuBarRenderer raster size",
                build: menuBarExportPlacementCases),
        ]
    }

    // MARK: - Active regions (VideoExporter.swift 1614-1616, 1630-1632, 1783-1785)

    private static func exportActiveRegionCases() -> [WV] {
        var rng = WVRandom(seed: "exportActiveRegions")
        var cases: [WV] = []
        for i in 0..<800 {
            let blurs = (0..<(i % 25 == 0 ? 0 : rng.int(0, 5))).map { _ in randomBlurRegion(&rng) }
            let focus = (0..<(i % 23 == 0 ? 0 : rng.int(0, 4))).map { _ in randomFocusRegion(&rng) }
            let highlights = (0..<(i % 21 == 0 ? 0 : rng.int(0, 5))).map { _ in randomHighlightRegion(&rng) }
            let edges = (blurs.flatMap { [$0.startTime, $0.endTime] }
                + focus.flatMap { [$0.startTime, $0.endTime] }
                + highlights.flatMap { [$0.startTime, $0.endTime] })
            let times: [Double] = (0..<10).map { _ in rng.edgy(-2, 70, edges: edges + edges.map { $0.nextUp } + edges.map { $0.nextDown }) }
            let perTime: [WV] = times.map { currentTime in
                // ── verbatim filters ──
                let activeBlurs = blurs.indices.filter { idx in
                    let region = blurs[idx]
                    return currentTime >= region.startTime && currentTime <= region.endTime
                }
                let activeFocusRegions = focus.indices.filter { idx in
                    let region = focus[idx]
                    return currentTime >= region.startTime && currentTime <= region.endTime
                }
                let activeHighlights = highlights.indices.filter { idx in
                    let region = highlights[idx]
                    return currentTime >= region.startTime && currentTime <= region.endTime
                }
                return ["blur": activeBlurs.wv, "focus": activeFocusRegions.wv, "highlight": activeHighlights.wv]
            }
            cases.append(vcase(
                [
                    "blurRegions": .arr(blurs.map(WVModel.blurRegion)),
                    "focusRegions": .arr(focus.map(WVModel.focusRegion)),
                    "highlightRegions": .arr(highlights.map(WVModel.highlightRegion)),
                    "times": times.wv,
                ],
                ["active": .arr(perTime)]
            ))
        }
        return cases
    }

    // MARK: - applyRegionBlur (VideoExporter.swift 2636-2724)

    /// Verbatim numbers of `applyRegionBlur(to:region:containerRect:at:)`.
    static func exportRegionBlurOracle(region: BlurRegion, containerRect: CGRect, at currentTime: TimeInterval) -> WV {
        let pixelRect = region.rectInImageSpace(in: containerRect)
        guard pixelRect.width > 0, pixelRect.height > 0 else {
            return ["applied": false, "pixelRect": pixelRect.wv]
        }
        var gaussianRadius: WV = .null
        var pixellate: WV = .null
        switch region.style {
        case .blur:
            let blurRadius = region.blurRadius(in: containerRect.size)
            gaussianRadius = blurRadius.wv
        case .pixelate:
            let block = BlurStyleMath.pixelScale(
                strength: region.intensity, regionSize: pixelRect.size)
            let jitter = BlurStyleMath.gridJitter(
                at: currentTime, animated: region.animated, blockSize: block)
            pixellate = [
                "scale": block.wv,
                "center": CGPoint(x: pixelRect.minX + jitter.x, y: pixelRect.minY + jitter.y).wv,
            ]
        }
        let featherSigma = region.featherSigma(in: containerRect.size)
        return [
            "applied": true,
            "pixelRect": pixelRect.wv,
            "style": .str(region.style.rawValue),
            "gaussianRadius": gaussianRadius,
            "pixellate": pixellate,
            "featherSigma": featherSigma.wv,
            "feathered": (featherSigma > 0.01).wv,
        ]
    }

    private static func exportRegionBlurCases() -> [WV] {
        var rng = WVRandom(seed: "exportRegionBlur")
        var cases: [WV] = []
        for i in 0..<1500 {
            let region = randomBlurRegion(&rng)
            let container = i % 4 == 0 ? randomContainerRect(&rng) : randomPixelVideoRect(&rng)
            let t = rng.edgy(region.startTime - 0.5, region.endTime + 0.5,
                             edges: [region.startTime, region.endTime, 0, 0.125, 1.0625])
            cases.append(vcase(
                ["region": WVModel.blurRegion(region), "containerRect": container.wv, "time": t.wv],
                exportRegionBlurOracle(region: region, containerRect: container, at: t)
            ))
        }
        return cases
    }

    // MARK: - applyRegionHighlight + highlightOutsideMaskImage (2726-2877)

    static func exportRegionHighlightOracle(
        region: HighlightRegion, imageExtent: CGRect, dimRect: CGRect, containerRect: CGRect,
        currentTime: TimeInterval, transitionDuration: Double
    ) -> WV {
        let pixelRect = region.rectInImageSpace(in: containerRect)
        guard pixelRect.width > 0, pixelRect.height > 0 else {
            return ["applied": false, "pixelRect": pixelRect.wv]
        }
        let cornerRadius = region.cornerRadius(in: containerRect)

        let envelope = Easing.regionEnvelope(
            at: currentTime,
            startTime: region.startTime,
            endTime: region.endTime,
            transitionDuration: transitionDuration
        )
        guard envelope > 0 else {
            return ["applied": false, "pixelRect": pixelRect.wv, "cornerRadius": cornerRadius.wv, "envelope": envelope.wv]
        }
        let srgbOpacity = region.dimOpacity * envelope
        let linearOpacity = 1.0 - pow(1.0 - srgbOpacity, 2.2)

        // highlightOutsideMaskImage(extent: image.extent, dimRect:, holeRect: pixelRect, cornerRadius:)
        let extent = imageExtent
        let holeRect = pixelRect
        let width = Int(ceil(extent.width))
        let height = Int(ceil(extent.height))
        var mask: WV = .null
        var maskBuilt = false
        if width > 0, height > 0 {
            maskBuilt = true
            let adjustedDimRect = CGRect(
                x: dimRect.minX - extent.minX,
                y: dimRect.minY - extent.minY,
                width: dimRect.width,
                height: dimRect.height
            )
            let adjustedHoleRect = CGRect(
                x: holeRect.minX - extent.minX,
                y: holeRect.minY - extent.minY,
                width: holeRect.width,
                height: holeRect.height
            )
            mask = [
                "width": .int(width), "height": .int(height),
                "dimRect": adjustedDimRect.wv, "holeRect": adjustedHoleRect.wv,
                "cornerRadius": cornerRadius.wv,
                "translate": CGPoint(x: extent.minX, y: extent.minY).wv,
            ]
        }
        return [
            "applied": maskBuilt.wv,
            "pixelRect": pixelRect.wv,
            "cornerRadius": cornerRadius.wv,
            "envelope": envelope.wv,
            "srgbOpacity": srgbOpacity.wv,
            "linearOpacity": linearOpacity.wv,
            "mask": mask,
        ]
    }

    private static func exportRegionHighlightCases() -> [WV] {
        var rng = WVRandom(seed: "exportRegionHighlight")
        var cases: [WV] = []
        for i in 0..<1500 {
            let region = randomHighlightRegion(&rng)
            let container = i % 4 == 0 ? randomContainerRect(&rng) : randomPixelVideoRect(&rng)
            let extent: CGRect = i % 17 == 0
                ? CGRect(x: 0, y: 0, width: rng.edgy(-1, 1, edges: [0, 0.5]), height: rng.edgy(0, 2000, edges: [0]))
                : CGRect(x: 0, y: 0, width: rng.edgy(1, 4000, edges: [1920, 1080]), height: rng.edgy(1, 4000, edges: [1080, 1920, 1079.5]))
            let td = rng.pick([1.2, 0.8, 0.5, 0.3, rng.double(0, 2)])
            let t = rng.edgy(region.startTime - 0.3, region.endTime + 0.3,
                             edges: [region.startTime, region.endTime, region.startTime + 0.06, region.endTime - td])
            cases.append(vcase(
                [
                    "region": WVModel.highlightRegion(region), "containerRect": container.wv,
                    "imageExtent": extent.wv, "time": t.wv, "transitionDuration": td.wv,
                ],
                exportRegionHighlightOracle(
                    region: region, imageExtent: extent, dimRect: container, containerRect: container,
                    currentTime: t, transitionDuration: td)
            ))
        }
        return cases
    }

    // MARK: - Depth Focus plan (VideoExporter.swift 1633-1664)

    private static func exportFocusPlanCases() -> [WV] {
        var rng = WVRandom(seed: "exportFocusPlan")
        var cases: [WV] = []
        for i in 0..<400 {
            let region = randomFocusRegion(&rng)
            let vr: CGRect = i % 20 == 0
                ? CGRect(x: rng.double(0, 100), y: rng.double(0, 100), width: rng.edgy(-1, 3, edges: [1, 1.5, 2]), height: rng.edgy(0, 3, edges: [1, 2]))
                : randomPixelVideoRect(&rng)
            var mask: WV = .null
            if let cg = FocusMath.maskImage(
                regionRect: region.rect, style: region.style,
                angleDegrees: region.angle, falloff: region.falloff,
                cornerRadius: region.cornerRadius,
                videoSize: vr.size
            ) {
                let rawExtent = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
                let transform = CGAffineTransform(
                    scaleX: vr.width / rawExtent.width,
                    y: vr.height / rawExtent.height)
                    .concatenating(CGAffineTransform(translationX: vr.minX, y: vr.minY))
                mask = ["width": .int(cg.width), "height": .int(cg.height), "transform": transform.wv]
            }
            let sigma = FocusMath.blurSigma(intensity: region.intensity, videoSize: vr.size)
            cases.append(vcase(
                ["region": WVModel.focusRegion(region), "videoRect": vr.wv],
                ["mask": mask, "sigma": sigma.wv]
            ))
        }
        return cases
    }

    // MARK: - Device segments in export (VideoExporter.swift 743, 929-1027, 1296-1300, 1871-1886, 2013-2027)

    private static func deviceSegmentExportCases() -> [WV] {
        var rng = WVRandom(seed: "deviceSegmentExport")
        var cases: [WV] = []
        let kinds: [RecordingSourceKind] = [.display, .window, .area, .device]
        for i in 0..<900 {
            let showDeviceFrame = rng.bool(0.8)
            let recordingSourceKind: RecordingSourceKind = rng.bool(0.8) ? .display : rng.pick(kinds)
            var segments: [ProjectSourceSegment] = []
            var t = rng.edgy(0, 3, edges: [0])
            for _ in 0..<(i % 19 == 0 ? 0 : rng.int(1, 5)) {
                let d = rng.edgy(0, 12, edges: [0, 0.3, 0.02])
                let kind: RecordingSourceKind = rng.bool(0.5) ? .device : rng.pick(kinds)
                let cw = rng.edgy(0.05, 1, edges: [1, 0.3164, 0.4613])
                let ch = rng.edgy(0.05, 1, edges: [1, 0.9])
                segments.append(ProjectSourceSegment(
                    startTime: t, duration: d, kind: kind,
                    contentX: rng.edgy(0, 1 - cw, edges: [0, (1 - cw) / 2]),
                    contentY: rng.edgy(0, 1 - ch, edges: [0, (1 - ch) / 2]),
                    contentWidth: rng.bool(0.03) ? -cw : cw,
                    contentHeight: ch))
                t += d
            }
            let vr = randomPixelVideoRect(&rng)
            let boundaryEdges = segments.flatMap { [$0.startTime, $0.endTime, $0.startTime - 0.01, $0.endTime + 0.01, $0.endTime + 0.15] }
            let queries: [Double] = (0..<10).map { _ in rng.edgy(-1, t + 1, edges: boundaryEdges + [0]) }

            // ── verbatim (743) ──
            let deviceFrameActive = recordingSourceKind == .device && showDeviceFrame
            // ── verbatim (929-981), minus the CIImage builds ──
            var subRectOut: CGRect?
            var screenRadiusOut: CGFloat = 0
            var ranges: [(start: TimeInterval, end: TimeInterval)] = []
            var assetsWV: WV = .null
            if !deviceFrameActive, showDeviceFrame {
                let deviceSegments = segments.filter { $0.kind == .device }
                if let first = deviceSegments.first {
                    let normalized = first.normalizedContentRect
                    let subRect = CGRect(
                        x: vr.minX + normalized.minX * vr.width,
                        y: vr.minY + (1 - normalized.minY - normalized.height) * vr.height,
                        width: normalized.width * vr.width,
                        height: normalized.height * vr.height
                    )
                    let screenRadius = DeviceFrameLayout.screenCornerRadius(
                        forVideoSize: subRect.size)
                    ranges = deviceSegments.map { ($0.startTime, $0.endTime) }
                    subRectOut = subRect
                    screenRadiusOut = screenRadius
                    assetsWV = [
                        "subRect": subRect.wv,
                        "screenCornerRadius": screenRadius.wv,
                        "bezelShadowRect": DeviceFrameLayout.bezelRect(forVideoRect: subRect).wv,
                        "bezelShadowCornerRadius": DeviceFrameLayout.bezelCornerRadius(forVideoSize: subRect.size).wv,
                        "hasIsland": DeviceFrameLayout.isPhoneAspect(subRect.size).wv,
                        "ranges": .arr(ranges.map { ["start": $0.start.wv, "end": $0.end.wv] }),
                        "sideVideoWidth": subRect.width.wv,
                    ]
                }
            }
            let hasAssets = subRectOut != nil
            // ── verbatim (1018-1027) ──
            func deviceSegmentActive(_ time: TimeInterval) -> Bool {
                hasAssets ? ranges.contains { time >= $0.start - 0.01 && time <= $0.end + 0.01 } : false
            }
            func deviceBoundaryDip(_ time: TimeInterval) -> Double {
                guard hasAssets else { return 0 }
                return DeviceSegmentDip.phase(
                    at: time,
                    boundaries: ranges.flatMap { [$0.start, $0.end] }
                )
            }
            // ── verbatim (1296-1300) ──
            var hotSpans: [WV] = []
            if hasAssets {
                let dipHalf = DeviceSegmentDip.sigma * 4
                for boundary in ranges.flatMap({ [$0.start, $0.end] }) {
                    hotSpans.append(["start": (boundary - dipHalf).wv, "end": (boundary + dipHalf).wv])
                }
            }
            let perQuery: [WV] = queries.map { currentTime in
                let active = deviceSegmentActive(currentTime)
                // ── verbatim (2015-2026) + fadeImage clamp (3182) ──
                let dip = deviceBoundaryDip(currentTime)
                var dipWV: WV = .null
                if dip > 0.01 {
                    let s = DeviceSegmentDip.scale(dip)
                    let c = CGPoint(x: vr.midX, y: vr.midY)
                    let t = CGAffineTransform.identity
                        .translatedBy(x: c.x, y: c.y)
                        .scaledBy(x: s, y: s)
                        .translatedBy(x: -c.x, y: -c.y)
                    let alpha = DeviceSegmentDip.opacity(dip)
                    let a = CGFloat(min(1, max(0, alpha)))
                    dipWV = ["scale": s.wv, "transform": t.wv, "alpha": a.wv]
                }
                // ── verbatim (1871-1886) ──
                var curtainScreen: WV = .null
                if let sub = subRectOut, active {
                    let local = CGRect(
                        x: sub.minX - vr.minX,
                        y: vr.maxY - sub.maxY,
                        width: sub.width,
                        height: sub.height)
                    curtainScreen = ["rect": local.wv, "cornerRadius": DeviceFrameLayout.screenCornerRadius(forVideoSize: sub.size).wv]
                } else if deviceFrameActive {
                    curtainScreen = ["rect": CGRect(origin: .zero, size: vr.size).wv,
                                     "cornerRadius": DeviceFrameLayout.screenCornerRadius(forVideoSize: vr.size).wv]
                }
                return [
                    "active": active.wv,
                    "segmentFlag": (hasAssets && active).wv,
                    "menuBarVisible": (!active).wv,
                    "dipPhase": dip.wv,
                    "dip": dipWV,
                    "curtainDeviceScreen": curtainScreen,
                ]
            }
            _ = screenRadiusOut
            cases.append(vcase(
                [
                    "showDeviceFrame": showDeviceFrame.wv,
                    "recordingSourceKind": .str(recordingSourceKind.rawValue),
                    "sourceSegments": .arr(segments.map { WV.encoded($0) }),
                    "videoRect": vr.wv,
                    "queries": queries.wv,
                ],
                [
                    "deviceFrameActive": deviceFrameActive.wv,
                    "assets": assetsWV,
                    "hotSpans": .arr(hotSpans),
                    "perQuery": .arr(perQuery),
                ]
            ))
        }
        return cases
    }

    // MARK: - DeviceBezelRenderer recipe (DeviceBezelRenderer.swift 171-387)

    private static func white(_ alpha: CGFloat) -> SRGBA { SRGBA(white: 1, alpha: alpha) }

    /// fillVertical (367-387): three-stop Oklab ramp, top → bottom of `rect`.
    private static func fillVerticalWV(rect: CGRect, top: DeviceFrameLayout.RGB, mid: DeviceFrameLayout.RGB, bottom: DeviceFrameLayout.RGB) -> WV {
        [
            "stops": .arr([
                ["location": 0.0, "color": srgbaWV(top.srgba)],
                ["location": 0.5, "color": srgbaWV(mid.srgba)],
                ["location": 1.0, "color": srgbaWV(bottom.srgba)],
            ]),
            "start": CGPoint(x: rect.midX, y: rect.minY).wv,
            "end": CGPoint(x: rect.midX, y: rect.maxY).wv,
        ]
    }

    private static func sideButtonsRecipe(videoRect: CGRect) -> WV {
        let m = DeviceFrameLayout.metrics(forVideoRect: videoRect)
        let bezelRect = m.bodyRect
        guard bezelRect.width > 0, bezelRect.height > 0 else { return .arr([]) }
        var out: [WV] = []
        if m.isPhone {
            for button in DeviceFrameLayout.sideButtons {
                let thickness = max(1, m.value(button.thicknessFraction))
                let w = thickness + 1
                let h = bezelRect.height * button.lengthFraction
                let cx = button.isLeft
                    ? bezelRect.minX - w / 2 + 1
                    : bezelRect.maxX + w / 2 - 1
                let cy = bezelRect.minY + bezelRect.height * button.centerFraction
                let rect = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
                let lw = max(0.75, thickness * 0.16)
                out.append([
                    "rect": rect.wv,
                    "cornerRadius": (thickness / 2).wv,
                    "fill": fillVerticalWV(
                        rect: rect, top: DeviceFrameLayout.buttonTop,
                        mid: DeviceFrameLayout.RGB.mix(DeviceFrameLayout.buttonTop, DeviceFrameLayout.buttonBottom),
                        bottom: DeviceFrameLayout.buttonBottom),
                    "hairline": [
                        "rect": rect.insetBy(dx: lw / 2, dy: lw / 2).wv,
                        "cornerRadius": max(0, thickness / 2 - lw / 2).wv,
                        "lineWidth": lw.wv,
                        "color": srgbaWV(white(DeviceFrameLayout.buttonRim)),
                    ],
                ])
            }
        }
        return .arr(out)
    }

    private static func sideSlabRecipe(videoRect: CGRect, offset: CGSize) -> WV {
        let m = DeviceFrameLayout.metrics(forVideoRect: videoRect)
        let sideRect = m.bodyRect.offsetBy(dx: offset.width, dy: offset.height)
        guard sideRect.width > 0, sideRect.height > 0 else { return .null }
        return [
            "rect": sideRect.wv,
            "cornerRadius": m.bodyCornerRadius.wv,
            "fill": fillVerticalWV(
                rect: sideRect, top: DeviceFrameLayout.sideTop,
                mid: DeviceFrameLayout.RGB.mix(DeviceFrameLayout.sideTop, DeviceFrameLayout.sideBottom),
                bottom: DeviceFrameLayout.sideBottom),
        ]
    }

    private static func bodyRecipe(videoRect: CGRect, shadowRadius: CGFloat, shadowOpacity: CGFloat, deviceScale: CGFloat) -> WV {
        let m = DeviceFrameLayout.metrics(forVideoRect: videoRect)
        let bezelRect = m.bodyRect
        let radius = m.bodyCornerRadius
        guard bezelRect.width > 0, bezelRect.height > 0 else { return .null }
        let rimWidth = m.rimWidth
        let aoInset = rimWidth * 1.5
        var glass: WV = .null
        if m.isPhone, m.glassRect != m.screenRect {
            glass = ["rect": m.glassRect.wv, "cornerRadius": m.glassCornerRadius.wv,
                     "color": srgbaWV(DeviceFrameLayout.glassColor.srgba)]
        }
        return [
            "rect": bezelRect.wv,
            "cornerRadius": radius.wv,
            "shadow": [
                "offset": CGSize(width: 0, height: shadowRadius / 3).wv,
                "blur": (shadowRadius * DeviceBezelRenderer.shadowBlurFactor * deviceScale).wv,
                "color": srgbaWV(SRGBA(white: 0, alpha: 0.45 * shadowOpacity)),
            ],
            "band": fillVerticalWV(rect: bezelRect, top: DeviceFrameLayout.bandTop,
                                   mid: DeviceFrameLayout.bandMid, bottom: DeviceFrameLayout.bandBottom),
            "rim": [
                "rect": bezelRect.insetBy(dx: rimWidth / 2, dy: rimWidth / 2).wv,
                "cornerRadius": max(0, radius - rimWidth / 2).wv,
                "lineWidth": rimWidth.wv,
                "gradient": [
                    "stops": .arr([
                        ["location": 0.0, "color": srgbaWV(white(DeviceFrameLayout.rimHighlight))],
                        ["location": 0.5, "color": srgbaWV(white(DeviceFrameLayout.rimMid))],
                        ["location": 1.0, "color": srgbaWV(white(DeviceFrameLayout.rimShadowSide))],
                    ]),
                    "start": CGPoint(x: bezelRect.minX, y: bezelRect.minY).wv,
                    "end": CGPoint(x: bezelRect.maxX, y: bezelRect.maxY).wv,
                ],
            ],
            "ao": [
                "rect": bezelRect.insetBy(dx: aoInset, dy: aoInset).wv,
                "cornerRadius": max(0, radius - 2 * aoInset).wv,
                "lineWidth": max(1, rimWidth * 0.6).wv,
                "color": srgbaWV(SRGBA(white: 0, alpha: DeviceFrameLayout.innerShadow)),
            ],
            "glass": glass,
        ]
    }

    private static func islandRecipe(videoRect: CGRect) -> WV {
        guard DeviceFrameLayout.isPhoneAspect(videoRect.size) else { return .null }
        let m = DeviceFrameLayout.metrics(forVideoRect: videoRect)
        let seamWidth = m.seamWidth
        let size = DeviceFrameLayout.islandSize(forVideoWidth: videoRect.width)
        let topInset = DeviceFrameLayout.islandTopInset(forVideoWidth: videoRect.width)
        let rect = CGRect(
            x: videoRect.midX - size.width / 2,
            y: videoRect.minY + topInset,
            width: size.width, height: size.height
        )
        let dot = m.value(DeviceFrameLayout.cameraDotFraction)
        let dotRect = CGRect(
            x: rect.midX + m.value(DeviceFrameLayout.cameraDotOffsetFraction) - dot / 2,
            y: rect.midY - dot / 2,
            width: dot, height: dot
        )
        return [
            "seam": [
                "rect": videoRect.insetBy(dx: seamWidth / 2, dy: seamWidth / 2).wv,
                "cornerRadius": m.screenCornerRadius.wv,
                "lineWidth": seamWidth.wv,
                "color": srgbaWV(SRGBA(white: 0, alpha: 0.55)),
            ],
            "pill": [
                "rect": rect.wv,
                "cornerRadius": (size.height / 2).wv,
                "color": srgbaWV(SRGBA(white: 0)),
            ],
            "lens": ["rect": dotRect.wv, "color": srgbaWV(SRGBA(red: 0.07, green: 0.08, blue: 0.11))],
            "lensRing": [
                "rect": dotRect.insetBy(dx: dot * 0.05, dy: dot * 0.05).wv,
                "lineWidth": max(0.5, dot * 0.10).wv,
                "color": srgbaWV(SRGBA(white: 1, alpha: 0.13)),
            ],
        ]
    }

    private static func deviceBezelRecipeCases() -> [WV] {
        var rng = WVRandom(seed: "deviceBezelRecipe")
        var cases: [WV] = []
        for i in 0..<700 {
            let extent = CGRect(x: 0, y: 0, width: rng.edgy(200, 4000, edges: [1920, 1080]), height: rng.edgy(200, 4000, edges: [1080, 1920]))
            let ci: CGRect = i % 11 == 0 ? randomContainerRect(&rng) : randomPixelVideoRect(&rng)
            // DeviceFrameRenderer.flip (75-78)
            let yDown = CGRect(x: ci.minX, y: extent.height - ci.maxY, width: ci.width, height: ci.height)
            let offset = CGSize(width: rng.edgy(-60, 60, edges: [0]), height: rng.edgy(-60, 60, edges: [0]))
            let shadowRadius = CGFloat(rng.edgy(0, 80, edges: [0, 20]))
            let shadowOpacity = CGFloat(rng.edgy(0, 1, edges: [0, 0.5, 1]))
            let deviceScale = CGFloat(rng.pick([1.0, 2.0, 3.0, rng.double(0.5, 4)]))
            cases.append(vcase(
                [
                    "videoRectCI": ci.wv, "extent": extent.wv, "slabOffset": offset.wv,
                    "shadowRadius": shadowRadius.wv, "shadowOpacity": shadowOpacity.wv, "deviceScale": deviceScale.wv,
                ],
                [
                    "videoRect": yDown.wv,
                    "sideButtons": sideButtonsRecipe(videoRect: yDown),
                    "sideSlab": sideSlabRecipe(videoRect: yDown, offset: offset),
                    "body": bodyRecipe(videoRect: yDown, shadowRadius: shadowRadius, shadowOpacity: shadowOpacity, deviceScale: deviceScale),
                    "island": islandRecipe(videoRect: yDown),
                ]
            ))
        }
        return cases
    }

    // MARK: - MenuBarRenderer (MenuBarRenderer.swift 19-116)

    private static func sizeOf(_ s: String, _ font: NSFont) -> CGSize {
        NSAttributedString(string: s, attributes: [.font: font]).size()
    }

    private static func symbolSize(_ name: String, pointSize: CGFloat) -> CGSize? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)?.size
    }

    private static func colorWV(_ c: NSColor) -> WV {
        let s = c.usingColorSpace(.sRGB)
        return [
            "calibrated": c.usingColorSpace(.genericRGB).map {
                ["red": $0.redComponent.wv, "green": $0.greenComponent.wv, "blue": $0.blueComponent.wv, "alpha": $0.alphaComponent.wv] as WV
            } ?? .null,
            "srgb": s.map {
                ["red": $0.redComponent.wv, "green": $0.greenComponent.wv, "blue": $0.blueComponent.wv, "alpha": $0.alphaComponent.wv] as WV
            } ?? .null,
        ]
    }

    static let menuBarTitles = ["CaptureCat", "Finder", "Safari", "Xcode", "My App — Demo", "", "W", "Übersicht Ñ", "A very long product title that overruns"]
    static let menuBarClocks = ["Mon 9:41 AM", "9:41", "Tue 12:00", "", "Wed Sep 30  10:08 PM", "00:00:00"]

    private static func menuBarLayoutCases() -> [WV] {
        var rng = WVRandom(seed: "menuBarLayout")
        var cases: [WV] = []
        let styles: [ProjectSettings.MenuBarReplacement] = [.dark, .light, .off, .hidden]
        let aligns: [ProjectSettings.MenuBarTitleAlignment] = [.left, .center, .right]
        for i in 0..<500 {
            let style: ProjectSettings.MenuBarReplacement = i % 13 == 0 ? rng.pick(styles) : rng.pick([.dark, .light])
            let title = rng.pick(menuBarTitles)
            let clock = rng.pick(menuBarClocks)
            let align = rng.pick(aligns)
            let icons = rng.bool(0.7)
            let width = i % 29 == 0 ? rng.int(0, 6) : rng.int(100, 3840)
            let height = i % 31 == 0 ? rng.int(0, 6) : rng.int(8, 80)
            let spec = MenuBarRenderer.Spec(style: style, title: title, titleAlignment: align,
                                            showStatusIcons: icons, clock: clock, width: width, height: height)
            let specWV: WV = [
                "style": .str(style.rawValue), "title": .str(title), "titleAlignment": .str(align.rawValue),
                "showStatusIcons": icons.wv, "clock": .str(clock), "width": .int(width), "height": .int(height),
            ]
            // Guard (20-21) — the REAL renderer agrees.
            let renders = MenuBarRenderer.image(for: spec) != nil
            guard spec.style == .dark || spec.style == .light, spec.width > 4, spec.height > 4 else {
                cases.append(vcase(["spec": specWV, "measured": .null], ["renders": renders.wv, "layout": .null]))
                continue
            }
            // ── verbatim geometry (24-111); `rect` is the image rect in points ──
            let rect = CGRect(x: 0, y: 0, width: spec.width, height: spec.height)
            let h = CGFloat(spec.height)
            let isDark = spec.style == .dark
            let barColor = isDark
                ? NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
                : NSColor(calibratedRed: 0.96, green: 0.96, blue: 0.97, alpha: 1)
            let textColor = isDark ? NSColor.white : NSColor.black
            let fontSize = h * 0.52
            let pad = h * 0.55
            var measured: [(String, WV)] = []
            var rightX = rect.width - pad
            var clockWV: WV = .null
            if !spec.clock.isEmpty {
                let size = sizeOf(spec.clock, NSFont.systemFont(ofSize: fontSize, weight: .medium))
                measured.append(("clock", size.wv))
                rightX -= size.width
                clockWV = CGRect(x: rightX, y: (rect.height - size.height) / 2, width: size.width, height: size.height).wv
                rightX -= fontSize * 0.9
            } else {
                measured.append(("clock", .null))
            }
            var iconsWV: [WV] = []
            var symbolMeasures: [WV] = []
            if spec.showStatusIcons {
                for name in ["battery.100", "wifi"] {
                    guard let size = symbolSize(name, pointSize: fontSize * 0.95) else { continue }
                    symbolMeasures.append(["name": .str(name), "size": size.wv])
                    rightX -= size.width
                    iconsWV.append(["name": .str(name), "rect": CGRect(
                        x: rightX, y: (rect.height - size.height) / 2, width: size.width, height: size.height).wv])
                    rightX -= fontSize * 0.7
                }
            }
            measured.append(("symbols", .arr(symbolMeasures)))
            var x = pad
            let logoSize = sizeOf("\u{F8FF}", NSFont.systemFont(ofSize: fontSize * 1.05))
            measured.append(("logo", logoSize.wv))
            let logoWV = CGRect(x: x, y: (rect.height - logoSize.height) / 2, width: logoSize.width, height: logoSize.height).wv
            x += logoSize.width + fontSize * 0.7
            var titleWV: WV = .null
            if !spec.title.isEmpty {
                let size = sizeOf(spec.title, NSFont.systemFont(ofSize: fontSize, weight: .bold))
                measured.append(("title", size.wv))
                let titleX: CGFloat
                switch spec.titleAlignment {
                case .left: titleX = x
                case .center: titleX = (rect.width - size.width) / 2
                case .right: titleX = rightX - size.width
                }
                titleWV = CGRect(x: titleX, y: (rect.height - size.height) / 2, width: size.width, height: size.height).wv
            } else {
                measured.append(("title", .null))
            }
            cases.append(vcase(
                ["spec": specWV, "measured": .obj(measured)],
                [
                    "renders": renders.wv,
                    "layout": [
                        "fontSize": fontSize.wv, "pad": pad.wv,
                        "barColor": colorWV(barColor), "textColor": colorWV(textColor),
                        "clock": clockWV, "icons": .arr(iconsWV), "logo": logoWV, "title": titleWV,
                        "finalRightX": rightX.wv,
                    ],
                ]
            ))
        }
        return cases
    }

    private static func menuBarTextMetricCases() -> [WV] {
        var cases: [WV] = []
        for height in [8, 12, 16, 20, 22, 24, 28, 32, 36, 44, 56, 72] {
            let h = CGFloat(height)
            let fontSize = h * 0.52
            let medium = NSFont.systemFont(ofSize: fontSize, weight: .medium)
            let bold = NSFont.systemFont(ofSize: fontSize, weight: .bold)
            let logoFont = NSFont.systemFont(ofSize: fontSize * 1.05)
            func fontWV(_ f: NSFont) -> WV {
                ["fontName": .str(f.fontName), "familyName": .str(f.familyName ?? ""), "pointSize": f.pointSize.wv,
                 "ascender": f.ascender.wv, "descender": f.descender.wv, "leading": f.leading.wv,
                 "capHeight": f.capHeight.wv, "xHeight": f.xHeight.wv]
            }
            cases.append(vcase(
                ["height": .int(height)],
                [
                    "clockFont": fontWV(medium),
                    "titleFont": fontWV(bold),
                    "logoFont": fontWV(logoFont),
                    "symbolPointSize": (fontSize * 0.95).wv,
                    "clocks": .arr(menuBarClocks.map { ["text": .str($0), "size": sizeOf($0, medium).wv] }),
                    "titles": .arr(menuBarTitles.map { ["text": .str($0), "size": sizeOf($0, bold).wv] }),
                    "logo": sizeOf("\u{F8FF}", logoFont).wv,
                    "symbols": .arr(["battery.100", "wifi"].map { name in
                        ["name": .str(name), "size": symbolSize(name, pointSize: fontSize * 0.95).map { $0.wv } ?? .null]
                    }),
                ]
            ))
        }
        return cases
    }

    private static func menuBarExportPlacementCases() -> [WV] {
        var rng = WVRandom(seed: "menuBarExportPlacement")
        var cases: [WV] = []
        let kinds: [RecordingSourceKind] = [.display, .window, .area, .device]
        let styles: [ProjectSettings.MenuBarReplacement] = [.dark, .light, .off, .hidden]
        var rasterCache: [MenuBarRenderer.Spec: CGSize] = [:]
        for i in 0..<500 {
            let settings = ProjectSettings()
            settings.menuBarReplacement = rng.pick(styles)
            settings.menuBarHeight = rng.edgy(-5, 20, edges: [0, 2.5, 3.2, 12, 15])
            settings.menuBarTitle = rng.pick(menuBarTitles)
            settings.menuBarClock = rng.pick(menuBarClocks)
            settings.menuBarShowStatusIcons = rng.bool(0.6)
            settings.menuBarTitleAlignment = rng.pick([.left, .center, .right])
            settings.showDeviceFrame = rng.bool(0.7)
            let recordingSourceKind: RecordingSourceKind = rng.bool(0.8) ? .display : rng.pick(kinds)
            let segmentKinds: [RecordingSourceKind] = (0..<(i % 5 == 0 ? rng.int(1, 3) : 0)).map { _ in rng.pick(kinds) }
            let naturalSize = CGSize(width: rng.edgy(100, 4000, edges: [3024, 1920]), height: rng.edgy(100, 3000, edges: [1964, 1080]))
            let vr = randomPixelVideoRect(&rng)
            // ── verbatim (386-395) ──
            let menuBarCrop: CGFloat = {
                guard settings.menuBarReplacement == .hidden,
                      recordingSourceKind != .device,
                      !segmentKinds.contains(where: { $0 == .device }) else { return 0 }
                return min(0.12, max(0, settings.menuBarHeight / 100))
            }()
            let effectiveNaturalSize = CGSize(
                width: naturalSize.width,
                height: naturalSize.height * (1 - menuBarCrop)
            )
            // ── verbatim (743, 987-1010) ──
            let deviceFrameActive = recordingSourceKind == .device && settings.showDeviceFrame
            var barWV: WV = .null
            var rasterInput: WV = .null
            if settings.menuBarReplacement == .dark || settings.menuBarReplacement == .light, !deviceFrameActive {
                let barH = max(4, vr.height * CGFloat(settings.menuBarHeight) / 100)
                let spec = MenuBarRenderer.Spec(
                    style: settings.menuBarReplacement,
                    title: settings.menuBarTitle,
                    titleAlignment: settings.menuBarTitleAlignment,
                    showStatusIcons: settings.menuBarShowStatusIcons,
                    clock: settings.menuBarClock,
                    width: Int(vr.width.rounded()),
                    height: Int(barH.rounded()))
                var raster: CGSize? = rasterCache[spec]
                if raster == nil, let bar = MenuBarRenderer.image(for: spec),
                   let cg = bar.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    raster = CGSize(width: cg.width, height: cg.height)
                    rasterCache[spec] = raster
                }
                if let raster {
                    rasterInput = raster.wv
                    let sx = vr.width / max(1, raster.width)
                    let sy = barH / max(1, raster.height)
                    // ci.transformed(by: scale).transformed(by: translate) — the
                    // raster's extent lands at the translation with size raster × scale.
                    let placed = CGRect(x: vr.minX, y: vr.maxY - barH,
                                        width: raster.width * sx, height: raster.height * sy)
                    barWV = [
                        "barH": barH.wv, "specWidth": .int(spec.width), "specHeight": .int(spec.height),
                        "raster": raster.wv, "scale": CGSize(width: sx, height: sy).wv, "rect": placed.wv,
                    ]
                }
            }
            cases.append(vcase(
                [
                    "settings": [
                        "menuBarReplacement": .str(settings.menuBarReplacement.rawValue),
                        "menuBarHeight": settings.menuBarHeight.wv,
                        "menuBarTitle": .str(settings.menuBarTitle),
                        "menuBarClock": .str(settings.menuBarClock),
                        "menuBarShowStatusIcons": settings.menuBarShowStatusIcons.wv,
                        "menuBarTitleAlignment": .str(settings.menuBarTitleAlignment.rawValue),
                        "showDeviceFrame": settings.showDeviceFrame.wv,
                    ],
                    "recordingSourceKind": .str(recordingSourceKind.rawValue),
                    "sourceSegmentKinds": .arr(segmentKinds.map { .str($0.rawValue) }),
                    "naturalSize": naturalSize.wv,
                    "videoRect": vr.wv,
                    // The REAL MenuBarRenderer raster size (NSImage backing
                    // scale decides it) — measured, so it is an input.
                    "raster": rasterInput,
                ],
                [
                    "menuBarCrop": menuBarCrop.wv,
                    "effectiveNaturalSize": effectiveNaturalSize.wv,
                    "bar": barWV,
                ]
            ))
        }
        return cases
    }
}
