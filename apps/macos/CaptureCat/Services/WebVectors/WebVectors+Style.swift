import Foundation
import CoreGraphics

// Golden-vector units for the STYLE cluster: camera placement/layout/styling,
// backgrounds (BackgroundLook, Oklab ramps, gradient axis, wallpaper names),
// continuous-corner geometry, SwiftUI-shadow parameters, the recording clock,
// and the exporter's private camera-bubble / frame compositing numbers.
// TS ports: apps/web/src/editor/core/math/ (see each module's doc comment).
//
// Files: this one (registry + ReactiveCameraLayout + CameraLayoutMath),
// WebVectors+StyleCamera.swift (CameraStyleMath), WebVectors+StyleBackground.swift
// (BackgroundLook / OklabGradient / BackgroundGradientRenderer / WallpaperCatalog),
// WebVectors+StyleGeometry.swift (ContinuousRoundedRect, SwiftUIShadow,
// RecordingClock, CGPath element encoding) and WebVectors+StyleOracle.swift
// (verbatim oracles of private VideoExporter / CameraStyleMath / BackgroundLook
// code at commit da569841c7b63175bffa46d897457f157224774d).
extension WebVectors {
    static var styleUnits: [WebVectorUnit] {
        [
            WebVectorUnit(
                name: "styleConstants",
                notes: "Every static constant of the Style cluster (ReactiveCameraLayout, CameraLayoutMath, CameraStyleMath, OklabGradient, BackgroundLook, ContinuousRoundedRect.fullReach, SwiftUIShadow.blurFactor) read from the real types",
                build: styleConstantsCases),
            WebVectorUnit(
                name: "reactiveCameraLayoutScalars",
                notes: "Services/ReactiveCameraLayout.swift — envelope(forZoom:), shapeAspect(shape:videoAspect:orientation:), bubbleSize(baseSize:aspect:), canvasFitScale(for:), fraction(for:)",
                build: reactiveCameraLayoutScalarCases),
            WebVectorUnit(
                name: "reactiveCameraLayoutCameraRect",
                notes: "Services/ReactiveCameraLayout.swift — cameraRect(in:basePosition:customPosition:baseSize:zoom:padding:aspect:yAxisIsUp:)",
                build: reactiveCameraLayoutCameraRectCases),
            WebVectorUnit(
                name: "cameraLayoutMathBasics",
                notes: "Services/CameraLayoutMath.swift — ease(_:), bubbleApproxCornerRadius(shape:customRadius:size:), columns(in:)",
                build: cameraLayoutMathBasicsCases),
            WebVectorUnit(
                name: "cameraLayoutResolve",
                notes: "Services/CameraLayoutMath.swift — resolve(at:regions:videoRect:bubbleRect:bubbleCornerRadius:cardCornerRadius:hasCamera:stack:stackZoom:) (private target/lerp through it), cardTransform(_:videoRect:), region(at:regions:) (as id), mode(at:regions:); queries cluster on edges and mid-morph. Optional `stack` {camera, screen} (§12.12) and `stackZoom` {zoom, focalX, focalY} (§12.13: the stacked screen zooms inside its row — scale fill × max(1, zoom), the clamped focal easing by envelope(zoom) to its own fraction of the row; the row order gives the Y convention; zoom ≤ 1 is the plain fill exactly)",
                build: cameraLayoutResolveCases),
            WebVectorUnit(
                name: "cameraLayoutBoundaries",
                notes: "Services/CameraLayoutMath.swift — boundaries(_:duration:)",
                build: cameraLayoutBoundariesCases),
        ] + styleCameraUnits + styleBackgroundUnits + styleGeometryUnits + styleExportUnits + cameraLookUnits
    }

    // MARK: - Shared helpers

    static let styleShapes = ProjectSettings.CameraShape.allCases
    static let styleOrientations = ProjectSettings.CameraOrientation.allCases
    static let stylePositions = ProjectSettings.CameraPosition.allCases
    static let styleLayoutModes = CameraLayoutMode.allCases

    /// Exact-double region encoding. (`WVModel.cameraLayoutRegion` goes through
    /// JSONEncoder + JSONSerialization, which can move a double by one ulp —
    /// e.g. 0.003630753602538505 came back as 0.0036307536025385044 — so a
    /// query sitting exactly on an edge flipped sides in the TS port.)
    static func styleRegionWV(_ r: CameraLayoutRegion) -> WV {
        let base: WV = ["id": .str(r.id.uuidString), "startTime": r.startTime.wv, "endTime": r.endTime.wv, "mode": .str(r.mode.rawValue)]
        // `look` / `cameraSide` only when set — exactly as project.json stores them.
        let withLook = r.look.map { base.setting("look", .str($0.rawValue)) } ?? base
        let withSide = r.cameraSide.map { withLook.setting("cameraSide", .str($0.rawValue)) } ?? withLook
        return r.splitStyle.map { withSide.setting("splitStyle", .str($0.rawValue)) } ?? withSide
    }

    /// A split style for a generated region (§12.11), from its own id-seeded
    /// stream like `randomSide`. Any mode may carry one (ignored off sideBySide).
    static func randomSplit(for id: UUID) -> CameraSplitStyle? {
        var splitRng = WVRandom(seed: "split-\(id.uuidString)")
        let roll = splitRng.unit()
        return roll < 0.5 ? nil : (roll < 0.85 ? .full : .tiles)
    }

    /// A Side by Side camera side for a generated region (§12.6), from a
    /// stream seeded by the region's id like `randomLook`, so the existing
    /// inputs stay unchanged. Any mode may carry one (ignored off sideBySide).
    static func randomSide(for id: UUID) -> CameraSide? {
        var sideRng = WVRandom(seed: "side-\(id.uuidString)")
        let roll = sideRng.unit()
        return roll < 0.5 ? nil : (roll < 0.85 ? .leading : .trailing)
    }

    /// A camera look for a generated region, drawn from a stream seeded by the
    /// region's id — NOT the unit's main stream — so adding looks to the
    /// generators left every other input of the existing units unchanged.
    /// About half the regions carry one, on any mode (a look on a non-Bubble
    /// mode is kept but ignored, which the vectors must exercise too).
    static func randomLook(for id: UUID) -> CameraBubbleLook? {
        var lookRng = WVRandom(seed: "look-\(id.uuidString)")
        let roll = lookRng.unit()
        return roll < 0.5 ? nil : (roll < 0.75 ? .cutout : .popOut)
    }

    static func randomLayoutRegions(_ rng: inout WVRandom, duration: Double) -> [CameraLayoutRegion] {
        let count = rng.int(0, 6)
        var regions: [CameraLayoutRegion] = []
        var cursor = rng.edgy(0, 3, edges: [0, 0.05, 0.0501, 0.04, 1])
        for _ in 0..<count {
            let overlapping = rng.bool(0.12)
            let start: Double
            if overlapping, let last = regions.last {
                start = rng.double(last.startTime, last.endTime + 0.01)
            } else {
                start = cursor + rng.edgy(0, 4, edges: [0, 0, 0.0005, 0.3, 0.45, 0.46])
            }
            let len = rng.edgy(0, 6, edges: [0, 0.2, 0.45, 0.449, 0.9, 0.001])
            let inverted = rng.bool(0.03)
            let end = inverted ? start - len : start + len
            let id = rng.uuid()
            regions.append(CameraLayoutRegion(id: id, startTime: start, endTime: end, mode: rng.pick(styleLayoutModes),
                                              look: randomLook(for: id), cameraSide: randomSide(for: id),
                                              splitStyle: randomSplit(for: id)))
            cursor = max(cursor, end)
        }
        _ = duration
        return regions
    }

    // MARK: - Constants

    private static func styleConstantsCases() -> [WV] {
        [vcase(
            ["note": "constants"],
            [
                "reactiveCameraLayout": [
                    "minSizeFactor": ReactiveCameraLayout.minSizeFactor.wv,
                    "squircleMaxAspect": ReactiveCameraLayout.squircleMaxAspect.wv,
                    "verticalAspect": ReactiveCameraLayout.verticalAspect.wv,
                ],
                "cameraLayoutMath": [
                    "transitionDuration": CameraLayoutMath.transitionDuration.wv,
                    "sideBySideScreenFraction": CameraLayoutMath.sideBySideScreenFraction.wv,
                    "sideBySideGapFraction": CameraLayoutMath.sideBySideGapFraction.wv,
                ],
                "cameraStyleMath": [
                    "squircleExponent": CameraStyleMath.squircleExponent.wv,
                    "squircleSamples": CameraStyleMath.squircleSamples.wv,
                    "ringOutsideFraction": CameraStyleMath.ringOutsideFraction.wv,
                    "ringColor": ["r": CameraStyleMath.ringColor.r.wv, "g": CameraStyleMath.ringColor.g.wv, "b": CameraStyleMath.ringColor.b.wv],
                    "ringPeakAlpha": CameraStyleMath.ringPeakAlpha.wv,
                    "ringSigmaFraction": CameraStyleMath.ringSigmaFraction.wv,
                    "tagFontFraction": CameraStyleMath.tagFontFraction.wv,
                    "tagSubtextFontScale": CameraStyleMath.tagSubtextFontScale.wv,
                    "tagHPaddingFactor": CameraStyleMath.tagHPaddingFactor.wv,
                    "tagVPaddingFactor": CameraStyleMath.tagVPaddingFactor.wv,
                    "tagGapFactor": CameraStyleMath.tagGapFactor.wv,
                ],
                "oklabGradient": ["resolution": OklabGradient.resolution.wv],
                "backgroundLook": ["maxImageEdge": BackgroundLook.maxImageEdge.wv],
                "continuousRoundedRect": ["fullReach": ContinuousRoundedRect.fullReach.wv],
                "swiftUIShadow": ["blurFactor": SwiftUIShadow.blurFactor.wv],
            ]
        )]
    }

    // MARK: - ReactiveCameraLayout

    private static func reactiveCameraLayoutScalarCases() -> [WV] {
        var rng = WVRandom(seed: "reactiveCameraLayoutScalars")
        var cases: [WV] = []
        let zoomEdges: [Double] = [1, 1.5, 0.5, 0, -1, 1.25, 1.0000001, 1.4999999, 3, 100, .infinity, -.infinity]
        let aspectEdges: [Double] = [1, 1.2, 1 / 1.2, 0.8, 16.0 / 9, 9.0 / 16, 0, -1, 0.01, 0.005, 100, 4.0 / 3]
        for i in 0..<1500 {
            let zoom = i == 0 ? Double.nan : rng.edgy(0, 4, edges: zoomEdges, edgeP: 0.3)
            let shape = rng.pick(styleShapes)
            let orientation = rng.pick(styleOrientations)
            let videoAspect = rng.edgy(0.2, 3, edges: aspectEdges, edgeP: 0.3)
            let baseSize = rng.edgy(-50, 900, edges: [0, 1, 0.5, 120, 1e6], edgeP: 0.15)
            let aspect = rng.edgy(0, 4, edges: aspectEdges, edgeP: 0.3)
            let canvas = CGSize(
                width: rng.edgy(-10, 4000, edges: [0, 1456, 728, -1], edgeP: 0.15),
                height: rng.edgy(-10, 3000, edges: [0, 728, 1456, -1], edgeP: 0.15))
            let position = rng.pick(stylePositions)
            cases.append(vcase(
                [
                    "zoom": zoom.wv, "shape": .str(shape.rawValue), "orientation": .str(orientation.rawValue),
                    "videoAspect": videoAspect.wv, "baseSize": baseSize.wv, "aspect": aspect.wv,
                    "canvas": canvas.wv, "position": .str(position.rawValue),
                ],
                [
                    "envelope": ReactiveCameraLayout.envelope(forZoom: zoom).wv,
                    "shapeAspect": ReactiveCameraLayout.shapeAspect(shape: shape, videoAspect: videoAspect, orientation: orientation).wv,
                    "bubbleSize": ReactiveCameraLayout.bubbleSize(baseSize: baseSize, aspect: aspect).wv,
                    "canvasFitScale": ReactiveCameraLayout.canvasFitScale(for: canvas).wv,
                    "fraction": ReactiveCameraLayout.fraction(for: position).wv,
                ]
            ))
        }
        return cases
    }

    private static func reactiveCameraLayoutCameraRectCases() -> [WV] {
        var rng = WVRandom(seed: "reactiveCameraLayoutCameraRect")
        var cases: [WV] = []
        for i in 0..<2500 {
            let content: CGRect
            switch i % 10 {
            case 0: content = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            case 1: content = CGRect(x: rng.double(-50, 50), y: rng.double(-50, 50), width: rng.double(-400, 0), height: rng.double(-300, 300)) // negative sizes
            case 2: content = CGRect(x: 0, y: 0, width: rng.edgy(0, 60, edges: [0]), height: rng.edgy(0, 60, edges: [0])) // tiny canvas
            default: content = rng.rect(origin: -100, 200, size: 50, 4000)
            }
            let position = rng.pick(stylePositions)
            let custom: CGPoint? = rng.bool(0.4)
                ? CGPoint(x: rng.edgy(-0.3, 1.3, edges: [0, 1, 0.5, -0.0]), y: rng.edgy(-0.3, 1.3, edges: [0, 1, 0.5]))
                : nil
            let baseSize = rng.edgy(0, 900, edges: [120, 0, 1, 2000], edgeP: 0.2)
            let zoom = rng.edgy(0.5, 3, edges: [1, 1.5, 1.2, 2, 1.0001], edgeP: 0.3)
            let padding = rng.edgy(0, 60, edges: [0, 12, 24, -5], edgeP: 0.2)
            let aspect = rng.edgy(0.3, 2.5, edges: [1, 16.0 / 9, 0.8, 1.2, 0, 0.009], edgeP: 0.3)
            let yUp = rng.bool()
            let rect = ReactiveCameraLayout.cameraRect(
                in: content, basePosition: position, customPosition: custom,
                baseSize: baseSize, zoom: zoom, padding: padding, aspect: aspect, yAxisIsUp: yUp)
            cases.append(vcase(
                [
                    "contentRect": content.wv, "basePosition": .str(position.rawValue),
                    "customPosition": custom.wv, "baseSize": baseSize.wv, "zoom": zoom.wv,
                    "padding": padding.wv, "aspect": aspect.wv, "yAxisIsUp": yUp.wv,
                ],
                ["rect": rect.wv]
            ))
        }
        return cases
    }

    // MARK: - CameraLayoutMath

    private static func cameraLayoutMathBasicsCases() -> [WV] {
        var rng = WVRandom(seed: "cameraLayoutMathBasics")
        var cases: [WV] = []
        for i in 0..<1500 {
            let t = i == 0 ? Double.nan : rng.edgy(-0.5, 1.5, edges: [0, 1, 0.5, -0.0, 0.25, 0.999999, 1e-9], edgeP: 0.25)
            let shape = rng.pick(styleShapes)
            let customRadius = CGFloat(rng.edgy(-20, 300, edges: [0, 12, 24, -1], edgeP: 0.2))
            let size = CGSize(width: rng.edgy(-10, 600, edges: [0, 120], edgeP: 0.1),
                              height: rng.edgy(-10, 600, edges: [0, 120], edgeP: 0.1))
            let videoRect = i % 7 == 0
                ? CGRect(x: rng.double(-100, 100), y: rng.double(-100, 100), width: rng.double(-800, 800), height: rng.double(-600, 600))
                : rng.rect(origin: -200, 400, size: 0, 3000)
            let cols = CameraLayoutMath.columns(in: videoRect)
            let leading = CameraLayoutMath.columns(in: videoRect, side: .leading)
            let fullCols = CameraLayoutMath.columns(in: videoRect, style: .full)
            let fullLeading = CameraLayoutMath.columns(in: videoRect, side: .leading, style: .full)
            cases.append(vcase(
                ["t": t.wv, "shape": .str(shape.rawValue), "customRadius": customRadius.wv, "size": size.wv, "videoRect": videoRect.wv],
                [
                    "ease": CameraLayoutMath.ease(t).wv,
                    "bubbleApproxCornerRadius": CameraLayoutMath.bubbleApproxCornerRadius(shape: shape, customRadius: customRadius, size: size).wv,
                    "columns": ["screen": cols.screen.wv, "camera": cols.camera.wv],
                    "columnsLeading": ["screen": leading.screen.wv, "camera": leading.camera.wv],
                    "columnsFull": ["screen": fullCols.screen.wv, "camera": fullCols.camera.wv],
                    "columnsFullLeading": ["screen": fullLeading.screen.wv, "camera": fullLeading.camera.wv],
                ]
            ))
        }
        return cases
    }

    static func resolvedWV(_ r: CameraLayoutMath.Resolved) -> WV {
        [
            "cameraRect": r.cameraRect.wv,
            "cameraCornerRadius": r.cameraCornerRadius.wv,
            "cameraOpacity": r.cameraOpacity.wv,
            "chromeOpacity": r.chromeOpacity.wv,
            "cardScale": r.cardScale.wv,
            "cardTranslationX": r.cardTranslationX.wv,
            "cardTranslationY": r.cardTranslationY.wv,
            "cardClip": r.cardClip.wv,
            "cardClipCornerRadius": r.cardClipCornerRadius.wv,
            "cameraShapeRect": r.cameraShapeRect.wv,
            "cardClipShapeRect": r.cardClipShapeRect.wv,
            "seamJoin": r.seamJoin.wv,
            "isPlainBubble": r.isPlainBubble.wv,
        ]
    }

    private static func cameraLayoutResolveCases() -> [WV] {
        var rng = WVRandom(seed: "cameraLayoutResolve")
        var cases: [WV] = []
        for i in 0..<900 {
            let duration = rng.edgy(1, 60, edges: [10, 30])
            let regions = i % 25 == 0 ? [] : randomLayoutRegions(&rng, duration: duration)
            let videoRect = i % 13 == 0
                ? CGRect(x: rng.double(-50, 50), y: rng.double(-50, 50), width: rng.double(-900, 900), height: rng.double(-600, 600))
                : rng.rect(origin: -50, 200, size: 0, 2000)
            let bubbleRect = rng.rect(origin: -50, 1800, size: 0, 500)
            let bubbleRadius = CGFloat(rng.edgy(0, 250, edges: [0, 60]))
            let cardRadius = CGFloat(rng.edgy(0, 60, edges: [0, 12]))
            let hasCamera = rng.bool(0.9)
            // Queries: every edge, just around it, deep into and just past the morph.
            var queries: [Double] = []
            let edges = regions.flatMap { [$0.startTime, $0.endTime] }
            for e in edges.prefix(8) {
                queries.append(e)
                queries.append(rng.pick([e - 0.001, e - 1e-7, e + 1e-7, e + 0.0009, e + 0.001]))
                queries.append(e + rng.double(0.0, 0.45))          // mid-morph
                queries.append(e + rng.pick([0.1, 0.225, 0.3, 0.449999, 0.45, 0.4500001]))
            }
            for _ in 0..<6 { queries.append(rng.edgy(-1, duration + 1, edges: [0, 0.05, 0.0501, duration])) }
            // Vertical stack (§12.12) on a quarter of the cases, from its own
            // stream so every other input above is unchanged.
            var stackRng = WVRandom(seed: "cameraLayoutResolve-stack-\(i)")
            let stack: CameraLayoutMath.StackRows? = i % 4 == 1
                ? CameraLayoutMath.stackRows(
                    area: stackRng.rect(origin: -40, 120, size: 50, 2000),
                    ratio: stackRng.edgy(0, 1, edges: [0.25, 0.42, 0.7]), yAxisIsUp: stackRng.bool(),
                    // §12.14: a joined stack (gap 0) on a third of them, drawn
                    // after the other inputs so those streams are unchanged.
                    gap: stackRng.bool(0.33) ? 0 : nil)
                : nil
            var input: WV = [
                "regions": .arr(regions.map(styleRegionWV)),
                "videoRect": videoRect.wv, "bubbleRect": bubbleRect.wv,
                "bubbleCornerRadius": bubbleRadius.wv, "cardCornerRadius": cardRadius.wv,
                "hasCamera": hasCamera.wv, "queries": queries.wv,
            ]
            if let stack { input = input.setting("stack", ["camera": stack.camera.wv, "screen": stack.screen.wv]) }
            cases.append(vcase(
                input,
                [
                    "results": .arr(queries.map { t in
                        let r = CameraLayoutMath.resolve(
                            at: t, regions: regions, videoRect: videoRect, bubbleRect: bubbleRect,
                            bubbleCornerRadius: bubbleRadius, cardCornerRadius: cardRadius, hasCamera: hasCamera,
                            stack: stack)
                        return [
                            "resolved": resolvedWV(r),
                            "cardTransform": CameraLayoutMath.cardTransform(r, videoRect: videoRect).wv,
                            "regionID": CameraLayoutMath.region(at: t, regions: regions).map { WV.str($0.id.uuidString) } ?? .null,
                            "mode": .str(CameraLayoutMath.mode(at: t, regions: regions).rawValue),
                        ]
                    }),
                ]
            ))
        }
        // §12.13: the screen zooming inside its stacked row (a yielded
        // camera row, a zoom and a focal) — its own stream, so every case
        // above is unchanged.
        var zoomRng = WVRandom(seed: "cameraLayoutResolve-stackZoom")
        for i in 0..<300 {
            let duration = zoomRng.edgy(1, 60, edges: [10, 30])
            let regions = i % 5 == 0 ? [] : randomLayoutRegions(&zoomRng, duration: duration)
            let videoRect = zoomRng.rect(origin: -50, 200, size: 50, 2000)
            let bubbleRect = zoomRng.rect(origin: -50, 1800, size: 0, 500)
            let cardRadius = CGFloat(zoomRng.edgy(0, 60, edges: [0, 12]))
            let stack = CameraLayoutMath.stackRows(
                area: zoomRng.rect(origin: -40, 120, size: 50, 2000),
                ratio: zoomRng.edgy(0, 1, edges: [0.25, 0.42, 0.7]), yAxisIsUp: zoomRng.bool(),
                yield: zoomRng.edgy(0.75, 1, edges: [0.75, 1], edgeP: 0.3),
                gap: zoomRng.bool(0.3) ? 0 : zoomRng.edgy(0, 0.1, edges: [0.02, 0.08]))
            let zoom = CameraLayoutMath.StackZoom(
                zoom: zoomRng.edgy(0.5, 3.5, edges: [1, 1.0001, 1.25, 1.5, 2.4], edgeP: 0.3),
                focalX: zoomRng.edgy(-0.2, 1.2, edges: [0, 0.5, 1], edgeP: 0.2),
                focalY: zoomRng.edgy(-0.2, 1.2, edges: [0, 0.5, 1], edgeP: 0.2))
            var queries: [Double] = []
            for e in regions.flatMap({ [$0.startTime, $0.endTime] }).prefix(6) {
                queries.append(e + zoomRng.double(0.0, 0.45))
                queries.append(e + zoomRng.pick([0.1, 0.225, 0.4500001]))
            }
            for _ in 0..<4 { queries.append(zoomRng.edgy(-1, duration + 1, edges: [0, duration])) }
            cases.append(vcase(
                [
                    "regions": .arr(regions.map(styleRegionWV)),
                    "videoRect": videoRect.wv, "bubbleRect": bubbleRect.wv,
                    "bubbleCornerRadius": CGFloat(40).wv, "cardCornerRadius": cardRadius.wv,
                    "hasCamera": true.wv, "queries": queries.wv,
                    "stack": ["camera": stack.camera.wv, "screen": stack.screen.wv],
                    "stackZoom": ["zoom": zoom.zoom.wv, "focalX": zoom.focalX.wv, "focalY": zoom.focalY.wv],
                ],
                [
                    "results": .arr(queries.map { t in
                        let r = CameraLayoutMath.resolve(
                            at: t, regions: regions, videoRect: videoRect, bubbleRect: bubbleRect,
                            bubbleCornerRadius: 40, cardCornerRadius: cardRadius, hasCamera: true,
                            stack: stack, stackZoom: zoom)
                        return [
                            "resolved": resolvedWV(r),
                            "cardTransform": CameraLayoutMath.cardTransform(r, videoRect: videoRect).wv,
                            "regionID": CameraLayoutMath.region(at: t, regions: regions).map { WV.str($0.id.uuidString) } ?? .null,
                            "mode": .str(CameraLayoutMath.mode(at: t, regions: regions).rawValue),
                        ]
                    }),
                ]
            ))
        }
        return cases
    }

    private static func cameraLayoutBoundariesCases() -> [WV] {
        var rng = WVRandom(seed: "cameraLayoutBoundaries")
        var cases: [WV] = []
        for i in 0..<700 {
            let duration = i % 17 == 0 ? rng.edgy(-1, 0.2, edges: [0, 0.1]) : rng.edgy(0, 60, edges: [10, 0.1])
            let regions = i % 29 == 0 ? [] : randomLayoutRegions(&rng, duration: duration)
            cases.append(vcase(
                ["regions": .arr(regions.map(styleRegionWV)), "duration": duration.wv],
                ["boundaries": CameraLayoutMath.boundaries(regions, duration: duration).wv]
            ))
        }
        return cases
    }
}
