import AppKit
import CoreGraphics
import CoreMedia

// Exporter camera-bubble compositing numbers — VERBATIM ORACLES of the
// private/inline code in Services/VideoExporter.swift at commit
// da569841c7b63175bffa46d897457f157224774d:
//   canvasScale / camera statics          336-342, 1079-1155
//   camera reader advance                 1425-1441
//   per-frame layout + composite          1445-1475, 1919-1990, 2197-2240
//   frameShapeCGPath ... makeFrameShadow  2879-3238
// Every non-private call (ReactiveCameraLayout, CameraLayoutMath,
// CameraStyleMath, DeviceFrameLayout, CGPath, CMTime) is the REAL code.
// TS port: apps/web/src/editor/core/math/exportCameraBubble.ts.
extension WebVectors {
    static var styleExportCameraUnits: [WebVectorUnit] {
        [
            WebVectorUnit(
                name: "exportMaskGeometry",
                notes: "VERBATIM ORACLE of VideoExporter frameShapeCGPath, roundedRectangleMaskImage, cameraShapeMaskImage, cameraShapeStrokeImage, cameraShapeShadowImage, makeFrameShadow (2879-3238): bitmap size, adjusted rect, REAL CGPath / CameraStyleMath.clipPath / DeviceFrameLayout.continuousRoundedPath elements, alphas and sigmas",
                build: exportMaskGeometryCases),
            WebVectorUnit(
                name: "exportCompositeCamera",
                notes: "VERBATIM ORACLE of VideoExporter.compositeCamera numbers (3097-3177) + fadeImage alpha (3181)",
                build: exportCompositeCameraCases),
            WebVectorUnit(
                name: "exportCameraStatics",
                notes: "VERBATIM ORACLE of VideoExporter.export canvasScale (336-342) + camera statics / baked asset geometry (1079-1155) calling the REAL ReactiveCameraLayout / CameraStyleMath (tag text sizes recorded in input.measurements)",
                build: exportCameraStaticsCases),
            WebVectorUnit(
                name: "exportCameraFrame",
                notes: "VERBATIM ORACLE of the per-frame camera flow (1445-1475, 1919-1990, 2197-2240): REAL cameraRect / bubbleApproxCornerRadius / CameraLayoutMath.resolve / cardTransform, then the override-tile vs plain-bubble decision, asset transform, card shadow, opacity and tilt",
                build: exportCameraFrameCases),
            WebVectorUnit(
                name: "exportCameraReader",
                notes: "VERBATIM ORACLE of the forward-only camera reader advance (1425-1441) with REAL CMTime(seconds:preferredTimescale: 600) and CMTime <= comparison over sample PTS lists at mixed timescales",
                build: exportCameraReaderCases),
        ]
    }

    // MARK: helpers

    private static func nsColorWV(_ color: NSColor) -> WV {
        let c = color.usingColorSpace(.sRGB) ?? color
        return ["red": c.redComponent.wv, "green": c.greenComponent.wv, "blue": c.blueComponent.wv, "alpha": c.alphaComponent.wv]
    }

    /// VERBATIM: frameShapeCGPath(rect:cornerRadius:frameShape:)
    static func oracleFrameShapeCGPath(rect: CGRect, cornerRadius: CGFloat, frameShape: ProjectSettings.FrameShape) -> CGPath {
        switch frameShape {
        case .rectangle:
            return CGPath(rect: rect, transform: nil)
        case .roundedRect:
            return CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        case .squircle:
            return DeviceFrameLayout.continuousRoundedPath(rect: rect, cornerRadius: cornerRadius)
        }
    }

    /// VERBATIM: the bitmap prelude every mask helper shares.
    private static func oracleMaskPrelude(extent: CGRect, rect: CGRect) -> (width: Int, height: Int, adjusted: CGRect)? {
        let width = Int(ceil(extent.width))
        let height = Int(ceil(extent.height))
        guard width > 0, height > 0 else { return nil }
        let adjusted = CGRect(x: rect.minX - extent.minX, y: rect.minY - extent.minY, width: rect.width, height: rect.height)
        return (width, height, adjusted)
    }

    private static func maskWV(_ p: (width: Int, height: Int, adjusted: CGRect), path: CGPath) -> WV {
        ["width": .int(p.width), "height": .int(p.height), "adjustedRect": p.adjusted.wv, "path": stylePathWV(path)]
    }

    static func oracleCameraMaskWV(extent: CGRect, rect: CGRect, shape: ProjectSettings.CameraShape,
                                   cornerRadius: Double, scale: CGFloat) -> WV {
        guard let p = oracleMaskPrelude(extent: extent, rect: rect) else { return .null }
        return maskWV(p, path: CameraStyleMath.clipPath(shape: shape, customRadius: cornerRadius, rect: p.adjusted, scale: scale))
    }

    static func oracleCameraStrokeWV(extent: CGRect, rect: CGRect, shape: ProjectSettings.CameraShape,
                                     cornerRadius: Double, scale: CGFloat, lineWidth: CGFloat, strokeColor: NSColor) -> WV {
        guard lineWidth > 0, let p = oracleMaskPrelude(extent: extent, rect: rect) else { return .null }
        return maskWV(p, path: CameraStyleMath.clipPath(shape: shape, customRadius: cornerRadius, rect: p.adjusted, scale: scale))
            .setting("lineWidth", lineWidth.wv)
            .setting("color", nsColorWV(strokeColor))
    }

    static func oracleCameraShadowWV(extent: CGRect, rect: CGRect, shape: ProjectSettings.CameraShape,
                                     cornerRadius: Double, scale: CGFloat, shadowRadius: CGFloat) -> WV {
        guard shadowRadius > 0 else { return .null }
        let mask = oracleCameraMaskWV(extent: extent, rect: rect, shape: shape, cornerRadius: cornerRadius, scale: scale)
        if case .null = mask { return .null }
        return ["mask": mask, "alpha": 0.45, "sigma": shadowRadius.wv]
    }

    private static func exportMaskGeometryCases() -> [WV] {
        var rng = WVRandom(seed: "exportMaskGeometry")
        var cases: [WV] = []
        for i in 0..<1500 {
            let rect = i % 25 == 0
                ? CGRect(x: rng.double(-50, 50), y: rng.double(-50, 50), width: rng.edgy(-5, 5, edges: [0]), height: rng.edgy(-5, 5, edges: [0]))
                : rng.rect(origin: -100, 1800, size: 1, 900)
            let slack = rng.edgy(-3, 80, edges: [0, 0.4, 24])
            let extent = i % 31 == 0
                ? CGRect(x: rng.double(-10, 10), y: rng.double(-10, 10), width: rng.edgy(-2, 1, edges: [0, 0.2]), height: rng.edgy(-2, 1, edges: [0, 1]))
                : rect.insetBy(dx: -slack, dy: -slack).standardized
            let cornerRadius = CGFloat(rng.edgy(-5, 300, edges: [0, 12, 1e6]))
            let frameShape = rng.pick(ProjectSettings.FrameShape.allCases)
            let cameraShape = rng.pick(ProjectSettings.CameraShape.allCases)
            let camRadius = rng.edgy(-5, 60, edges: [0, 12])
            let scale = rng.cg(0.25, 3)
            let lineWidth = CGFloat(rng.edgy(-1, 8, edges: [0, 2]))
            let shadowRadius = CGFloat(rng.edgy(-2, 60, edges: [0, 6]))
            let shadowOpacity = CGFloat(rng.edgy(-0.2, 1, edges: [0, 0.5]))
            let inverted = rng.bool()
            let strokeColor = rng.bool(0.5) ? NSColor(white: 1, alpha: 0.3)
                : NSColor(srgbRed: rng.cg(0, 1), green: rng.cg(0, 1), blue: rng.cg(0, 1), alpha: rng.cg(0, 1))

            var rounded: WV = .null
            if let p = oracleMaskPrelude(extent: extent, rect: rect) {
                rounded = maskWV(p, path: oracleFrameShapeCGPath(rect: p.adjusted, cornerRadius: cornerRadius, frameShape: frameShape))
                    .setting("inverted", inverted.wv)
            }
            var frameShadow: WV = .null
            if shadowRadius > 0, shadowOpacity > 0, let p = oracleMaskPrelude(extent: extent, rect: rect) {
                frameShadow = [
                    "mask": maskWV(p, path: oracleFrameShapeCGPath(rect: p.adjusted, cornerRadius: cornerRadius, frameShape: frameShape)),
                    "alpha": (shadowOpacity * 0.45).wv,
                    "sigma": (shadowRadius / 2).wv,
                    "offsetY": (-(shadowRadius / 3)).wv,
                ]
            }
            cases.append(vcase(
                [
                    "extent": extent.wv, "rect": rect.wv, "cornerRadius": cornerRadius.wv,
                    "frameShape": .str(frameShape.rawValue), "inverted": inverted.wv,
                    "cameraShape": .str(cameraShape.rawValue), "cameraCornerRadius": camRadius.wv, "scale": scale.wv,
                    "lineWidth": lineWidth.wv, "strokeColor": nsColorWV(strokeColor),
                    "shadowRadius": shadowRadius.wv, "shadowOpacity": shadowOpacity.wv,
                ],
                [
                    "roundedRectangleMask": rounded,
                    "cameraShapeMask": oracleCameraMaskWV(extent: extent, rect: rect, shape: cameraShape, cornerRadius: camRadius, scale: scale),
                    "cameraShapeStroke": oracleCameraStrokeWV(extent: extent, rect: rect, shape: cameraShape, cornerRadius: camRadius,
                                                              scale: scale, lineWidth: lineWidth, strokeColor: strokeColor),
                    "cameraShapeShadow": oracleCameraShadowWV(extent: extent, rect: rect, shape: cameraShape, cornerRadius: camRadius,
                                                              scale: scale, shadowRadius: shadowRadius),
                    "frameShadow": frameShadow,
                ]
            ))
        }
        return cases
    }

    // MARK: compositeCamera

    private static func exportCompositeCameraCases() -> [WV] {
        var rng = WVRandom(seed: "exportCompositeCamera")
        var cases: [WV] = []
        for i in 0..<1500 {
            let camExtent = i % 20 == 0
                ? CGRect(x: 0, y: 0, width: rng.edgy(-10, 10, edges: [0]), height: rng.edgy(-10, 10, edges: [0]))
                : CGRect(x: rng.edgy(-20, 20, edges: [0]), y: rng.edgy(-20, 20, edges: [0]),
                         width: rng.pick([640.0, 1280, 1920, 480, 1080]), height: rng.pick([480.0, 720, 1080, 640, 1920]))
            let rect = rng.rect(origin: -50, 1800, size: 1, 900)
            let opacity = rng.edgy(-0.5, 1.5, edges: [1, 0.999, 0, 0.5])
            let pitch = rng.edgy(-30, 30, edges: [0, 0.01, 0.0100001, -0.01])
            let yaw = rng.edgy(-30, 30, edges: [0, 0.01, -0.0100001])
            var out: WV = .null
            // VERBATIM compositeCamera prelude
            if camExtent.width > 0, camExtent.height > 0 {
                let fillScale = max(rect.width / camExtent.width, rect.height / camExtent.height)
                let scaledW = camExtent.width * fillScale
                let scaledH = camExtent.height * fillScale
                let dx = rect.minX - (scaledW - rect.width) / 2 - camExtent.minX * fillScale
                let dy = rect.minY - (scaledH - rect.height) / 2 - camExtent.minY * fillScale
                let t = CGAffineTransform(scaleX: fillScale, y: fillScale).concatenating(CGAffineTransform(translationX: dx, y: dy))
                out = [
                    "fillScale": fillScale.wv, "scaledW": scaledW.wv, "scaledH": scaledH.wv, "dx": dx.wv, "dy": dy.wv,
                    "transform": t.wv,
                    "applyTilt": (abs(pitch) > 0.01 || abs(yaw) > 0.01).wv,
                    "fade": opacity < 1 ? CGFloat(min(1, max(0, opacity))).wv : .null,
                ]
            }
            cases.append(vcase(
                ["camExtent": camExtent.wv, "rect": rect.wv, "opacity": opacity.wv, "tiltPitch": pitch.wv, "tiltYaw": yaw.wv],
                ["geometry": out]
            ))
        }
        return cases
    }

    // MARK: statics

    struct OracleCameraStatics {
        var referenceCanvas: CGSize
        var canvasScale: CGFloat
        var cameraFit: CGFloat
        var cameraBaseSize: CGFloat
        var cameraPadding: CGFloat
        var cameraAspect: Double
        var baseRect: CGRect?
        var assets: WV
    }

    /// VERBATIM oracle of the export statics (336-342, 1079-1155).
    static func oracleCameraStatics(settings: ProjectSettings, outputSize: CGSize, previewCanvasSize: CGSize,
                                    cameraNaturalSize: CGSize, hasCameraReader: Bool) -> OracleCameraStatics {
        let referenceCanvas: CGSize = {
            let previewSize = previewCanvasSize
            guard previewSize.width > 0, previewSize.height > 0 else { return outputSize }
            return previewSize
        }()
        let canvasScale = min(outputSize.width / referenceCanvas.width, outputSize.height / referenceCanvas.height)
        let outputRect = CGRect(origin: .zero, size: outputSize)
        let cameraFit = ReactiveCameraLayout.canvasFitScale(for: referenceCanvas)
        let cameraBaseSize = max(1, settings.effectiveCameraSize * cameraFit * canvasScale)
        let cameraPadding: CGFloat = 12 * cameraFit * canvasScale
        let cameraAspect: Double = ReactiveCameraLayout.shapeAspect(
            shape: settings.cameraShape,
            videoAspect: cameraNaturalSize.width > 0 && cameraNaturalSize.height > 0
                ? Double(cameraNaturalSize.width / cameraNaturalSize.height)
                : 1,
            orientation: settings.cameraOrientation
        )
        var out = OracleCameraStatics(referenceCanvas: referenceCanvas, canvasScale: canvasScale, cameraFit: cameraFit,
                                      cameraBaseSize: cameraBaseSize, cameraPadding: cameraPadding,
                                      cameraAspect: cameraAspect, baseRect: nil, assets: .null)
        guard hasCameraReader else { return out }
        let cr = outputRect
        let baseBubble = ReactiveCameraLayout.bubbleSize(baseSize: Double(cameraBaseSize), aspect: cameraAspect)
        let baseRect = CGRect(x: cr.maxX - cameraPadding - baseBubble.width, y: cr.minY + cameraPadding,
                              width: baseBubble.width, height: baseBubble.height)
        let shadowRadius = 6 * canvasScale
        let shadowSlack = shadowRadius * 4 + 4
        let shadowExtent = baseRect.insetBy(dx: -shadowSlack, dy: -shadowSlack)
        let mask = oracleCameraMaskWV(extent: baseRect, rect: baseRect, shape: settings.cameraShape,
                                      cornerRadius: settings.cameraCornerRadius, scale: canvasScale)
        let stroke: WV = settings.cameraBorderWidth > 0
            ? oracleCameraStrokeWV(extent: baseRect, rect: baseRect, shape: settings.cameraShape,
                                   cornerRadius: settings.cameraCornerRadius, scale: canvasScale,
                                   lineWidth: settings.cameraBorderWidth * canvasScale,
                                   strokeColor: CameraStyleMath.borderNSColor(settings))
            : .null
        let shadow = oracleCameraShadowWV(extent: shadowExtent, rect: baseRect, shape: settings.cameraShape,
                                          cornerRadius: settings.cameraCornerRadius, scale: canvasScale, shadowRadius: shadowRadius)
        var ring: WV = .null
        if CameraStyleMath.ringImage(size: baseRect.size, shape: settings.cameraShape,
                                     customRadius: settings.cameraCornerRadius * Double(canvasScale),
                                     intensity: settings.cameraRingLight, scale: 1) != nil {
            let pad = CameraStyleMath.ringPadding(for: baseRect.size)
            ring = ["origin": CGPoint(x: baseRect.minX - pad, y: baseRect.minY - pad).wv,
                    "crop": baseRect.insetBy(dx: -pad, dy: -pad).wv]
        }
        var tag: WV = .null
        if let built = CameraStyleMath.tagBitmap(settings: settings, bubbleWidth: baseRect.width, scale: 1) {
            let tr = CameraStyleMath.tagRect(bubbleRect: baseRect, pillSize: built.pillSize,
                                             position: settings.cameraTagPosition, yAxisIsUp: true)
            tag = ["pillSize": built.pillSize.wv, "rect": tr.wv]
        }
        out.baseRect = baseRect
        out.assets = [
            "baseRect": baseRect.wv, "shadowRadius": shadowRadius.wv, "shadowSlack": shadowSlack.wv,
            "shadowExtent": shadowExtent.wv, "mask": mask, "stroke": stroke, "shadow": shadow, "ring": ring, "tag": tag,
        ]
        return out
    }

    private static func staticsWV(_ o: OracleCameraStatics) -> WV {
        [
            "referenceCanvas": o.referenceCanvas.wv, "canvasScale": o.canvasScale.wv, "cameraFit": o.cameraFit.wv,
            "cameraBaseSize": o.cameraBaseSize.wv, "cameraPadding": o.cameraPadding.wv, "cameraAspect": o.cameraAspect.wv,
            "assets": o.assets,
        ]
    }

    private static func randomCameraSettings(_ rng: inout WVRandom) -> ProjectSettings {
        let s = randomTagSettings(&rng)
        if rng.bool(0.4) { s.cameraTagText = "" }
        s.cameraSize = rng.edgy(20, 400, edges: [120, 60, 119.9])
        s.cameraShape = rng.pick(ProjectSettings.CameraShape.allCases)
        s.cameraOrientation = rng.pick(ProjectSettings.CameraOrientation.allCases)
        s.cameraCornerRadius = rng.edgy(-2, 60, edges: [0, 12])
        s.cameraBorderWidth = rng.edgy(-1, 8, edges: [0, 2])
        s.cameraBorderColor = rng.bool(0.5) ? nil : randomCodableColor(&rng)
        s.cameraRingLight = rng.edgy(0, 1, edges: [0, 0.001, 1])
        s.cameraPosition = rng.pick(ProjectSettings.CameraPosition.allCases)
        if rng.bool(0.3) {
            s.cameraCustomX = rng.edgy(-0.2, 1.2, edges: [0, 1])
            s.cameraCustomY = rng.edgy(-0.2, 1.2, edges: [0, 1])
        }
        s.cornerRadius = rng.edgy(-2, 40, edges: [0, 12])
        s.shadowRadius = rng.edgy(-2, 60, edges: [0, 20])
        s.shadowOpacity = rng.edgy(-0.1, 1, edges: [0, 0.5])
        s.cameraOpacity = rng.edgy(0, 1.2, edges: [1, 0.2])
        s.cameraTiltPitch = rng.edgy(-25, 25, edges: [0])
        s.cameraTiltYaw = rng.edgy(-25, 25, edges: [0])
        return s
    }

    private static func cameraSettingsWV(_ s: ProjectSettings) -> WV {
        tagSettingsWV(s)
            .setting("cameraSize", s.cameraSize.wv)
            .setting("cameraShape", .str(s.cameraShape.rawValue))
            .setting("cameraOrientation", .str(s.cameraOrientation.rawValue))
            .setting("cameraCornerRadius", s.cameraCornerRadius.wv)
            .setting("cameraBorderWidth", s.cameraBorderWidth.wv)
            .setting("cameraBorderColor", s.cameraBorderColor.map(codableColorWV) ?? .null)
            .setting("cameraRingLight", s.cameraRingLight.wv)
            .setting("cameraPosition", .str(s.cameraPosition.rawValue))
            .setting("cameraCustomX", s.cameraCustomX.wv)
            .setting("cameraCustomY", s.cameraCustomY.wv)
            .setting("cornerRadius", s.cornerRadius.wv)
            .setting("shadowRadius", s.shadowRadius.wv)
            .setting("shadowOpacity", s.shadowOpacity.wv)
            .setting("cameraOpacity", s.cameraOpacity.wv)
            .setting("cameraTiltPitch", s.cameraTiltPitch.wv)
            .setting("cameraTiltYaw", s.cameraTiltYaw.wv)
    }

    private static let cameraOutputSizes: [CGSize] = [
        CGSize(width: 1920, height: 1080), CGSize(width: 1280, height: 720), CGSize(width: 3840, height: 2160),
        CGSize(width: 1080, height: 1920), CGSize(width: 1080, height: 1080), CGSize(width: 2, height: 2),
    ]

    private static func exportCameraStaticsCases() -> [WV] {
        var rng = WVRandom(seed: "exportCameraStatics")
        var cases: [WV] = []
        for _ in 0..<1200 {
            let s = randomCameraSettings(&rng)
            let output = rng.pick(cameraOutputSizes)
            let preview: CGSize = rng.bool(0.5) ? .zero : rng.size(0, 2000)
            let natural: CGSize = rng.bool(0.8)
                ? rng.pick([CGSize(width: 1280, height: 720), CGSize(width: 640, height: 480),
                            CGSize(width: 1080, height: 1920), CGSize(width: 1920, height: 1080)])
                : (rng.bool() ? .zero : rng.size(0, 100))
            let hasReader = rng.bool(0.85)
            let o = oracleCameraStatics(settings: s, outputSize: output, previewCanvasSize: preview,
                                        cameraNaturalSize: natural, hasCameraReader: hasReader)
            let measurements = o.baseRect.map { tagMeasurements(s, bubbleWidth: $0.width) } ?? []
            cases.append(vcase(
                ["settings": cameraSettingsWV(s), "outputSize": output.wv, "previewCanvasSize": preview.wv,
                 "cameraNaturalSize": natural.wv, "hasCameraReader": hasReader.wv, "measurements": .arr(measurements)],
                staticsWV(o)
            ))
        }
        return cases
    }

    // MARK: per-frame flow

    private static func exportCameraFrameCases() -> [WV] {
        var rng = WVRandom(seed: "exportCameraFrame")
        var cases: [WV] = []
        for _ in 0..<500 {
            let s = randomCameraSettings(&rng)
            let output = rng.pick(Array(cameraOutputSizes.dropLast()))
            let preview: CGSize = rng.bool(0.6) ? .zero : rng.size(200, 2000)
            let natural = rng.pick([CGSize(width: 1280, height: 720), CGSize(width: 640, height: 480), CGSize.zero])
            let hasReader = rng.bool(0.9)
            let o = oracleCameraStatics(settings: s, outputSize: output, previewCanvasSize: preview,
                                        cameraNaturalSize: natural, hasCameraReader: hasReader)
            let regions = randomLayoutRegions(&rng, duration: 10)
            let videoRect = CGRect(x: rng.double(0, 200), y: rng.double(0, 150),
                                   width: output.width * rng.cg(0.4, 0.95), height: output.height * rng.cg(0.4, 0.95))
            let offset = rng.edgy(-1, 1, edges: [0])
            let canvasScale = o.canvasScale
            var frameInputs: [WV] = []
            var frameOutputs: [WV] = []
            var t = rng.double(-0.2, 1)
            for _ in 0..<12 {
                t += rng.edgy(0, 1.2, edges: [0.0333, 0.45, 0])
                let zoom = rng.edgy(0.3, 3, edges: [1, 2, 1.0001])
                let sourceVisible = rng.bool(0.9)
                let decoded = rng.bool(0.8)
                let poster = rng.bool(0.5)
                let outputRect = CGRect(origin: .zero, size: output)
                // VERBATIM per-frame flow
                let bubbleRectNow = ReactiveCameraLayout.cameraRect(
                    in: outputRect,
                    basePosition: s.cameraPosition,
                    customPosition: s.cameraCustomX.flatMap { x in s.cameraCustomY.map { CGPoint(x: x, y: $0) } },
                    baseSize: Double(o.cameraBaseSize),
                    zoom: Double(zoom),
                    padding: Double(o.cameraPadding),
                    aspect: o.cameraAspect,
                    yAxisIsUp: true
                )
                let bubbleCornerRadius = CameraLayoutMath.bubbleApproxCornerRadius(
                    shape: s.cameraShape, customRadius: CGFloat(s.cameraCornerRadius) * canvasScale, size: bubbleRectNow.size)
                let cardCornerRadius = max(0, s.cornerRadius * canvasScale)
                let camLayout = CameraLayoutMath.resolve(
                    at: t, regions: regions, videoRect: videoRect, bubbleRect: bubbleRectNow,
                    bubbleCornerRadius: bubbleCornerRadius, cardCornerRadius: cardCornerRadius,
                    hasCamera: o.baseRect != nil)
                let cameraTargetTime = t - offset
                let source: String = (cameraTargetTime >= 0 && decoded) ? "live" : (poster ? "poster" : "none")
                var path = "none"
                var plain: WV = .null
                var override: WV = .null
                if sourceVisible, let baseRect = o.baseRect, source != "none" {
                    if !camLayout.isPlainBubble, camLayout.cameraOpacity > 0.001, let rect = camLayout.cameraRect {
                        let radius = min(camLayout.cameraCornerRadius, min(rect.width, rect.height) / 2)
                        let chrome = camLayout.chromeOpacity
                        let sx = baseRect.width > 0 ? rect.width / baseRect.width : 1
                        let sy = baseRect.height > 0 ? rect.height / baseRect.height : 1
                        let assetXform = CGAffineTransform(scaleX: sx, y: sy)
                            .concatenating(CGAffineTransform(
                                translationX: rect.minX - baseRect.minX * sx,
                                y: rect.minY - baseRect.minY * sy))
                        let cardness = 1 - chrome
                        var cardShadow: WV = .null
                        if cardness > 0.01, s.shadowRadius > 0, s.shadowOpacity > 0 {
                            let slack = ceil(s.shadowRadius * canvasScale * 2 + 24)
                            cardShadow = [
                                "extent": rect.insetBy(dx: -slack, dy: -slack).wv, "rect": rect.wv, "cornerRadius": radius.wv,
                                "shadowRadius": max(0, s.shadowRadius * canvasScale).wv,
                                "shadowOpacity": (max(0, s.shadowOpacity) * cardness).wv,
                            ]
                        }
                        path = "override"
                        override = [
                            "rect": rect.wv, "maskRadius": max(0, radius).wv, "radius": radius.wv, "chrome": chrome.wv,
                            "chromeVisible": (chrome > 0.01).wv, "assetTransform": assetXform.wv, "cardness": cardness.wv,
                            "cardShadow": cardShadow, "opacity": (s.cameraOpacity * camLayout.cameraOpacity).wv,
                            "tiltPitch": (s.cameraTiltPitch * chrome).wv, "tiltYaw": (s.cameraTiltYaw * chrome).wv,
                        ]
                    } else if camLayout.cameraOpacity > 0.001, camLayout.isPlainBubble {
                        let dynRect = bubbleRectNow
                        let sx = baseRect.width > 0 ? dynRect.width / baseRect.width : 1
                        let sy = baseRect.height > 0 ? dynRect.height / baseRect.height : 1
                        let tx = dynRect.minX - baseRect.minX * sx
                        let ty = dynRect.minY - baseRect.minY * sy
                        let assetXform = CGAffineTransform(scaleX: sx, y: sy)
                            .concatenating(CGAffineTransform(translationX: tx, y: ty))
                        path = "plain"
                        plain = ["rect": dynRect.wv, "assetTransform": assetXform.wv, "opacity": s.cameraOpacity.wv,
                                 "tiltPitch": s.cameraTiltPitch.wv, "tiltYaw": s.cameraTiltYaw.wv]
                    }
                }
                frameInputs.append(["currentTime": t.wv, "zoom": zoom.wv, "sourceVisible": sourceVisible.wv,
                                    "cameraFrameDecoded": decoded.wv, "posterAvailable": poster.wv])
                frameOutputs.append([
                    "bubbleRectNow": bubbleRectNow.wv, "bubbleCornerRadius": bubbleCornerRadius.wv,
                    "cardCornerRadius": cardCornerRadius.wv, "layout": resolvedWV(camLayout),
                    "cardTransform": CameraLayoutMath.cardTransform(camLayout, videoRect: videoRect).wv,
                    "cameraTargetTime": cameraTargetTime.wv, "source": .str(source), "path": .str(path),
                    "plain": plain, "override": override,
                ])
            }
            let measurements = o.baseRect.map { tagMeasurements(s, bubbleWidth: $0.width) } ?? []
            cases.append(vcase(
                ["settings": cameraSettingsWV(s), "outputSize": output.wv, "previewCanvasSize": preview.wv,
                 "cameraNaturalSize": natural.wv, "hasCameraReader": hasReader.wv, "measurements": .arr(measurements),
                 "regions": .arr(regions.map(styleRegionWV)), "videoRect": videoRect.wv, "cameraTimeOffset": offset.wv,
                 "frames": .arr(frameInputs)],
                ["frames": .arr(frameOutputs)]
            ))
        }
        return cases
    }

    // MARK: camera reader

    private static func exportCameraReaderCases() -> [WV] {
        var rng = WVRandom(seed: "exportCameraReader")
        var cases: [WV] = []
        for _ in 0..<700 {
            let timescale = rng.pick([Int32(600), 30, 30000, 90000, 1_000_000_000, 25])
            let fps = rng.pick([24.0, 25, 29.97, 30, 60])
            var samples: [CMTime] = []
            var v: Double = rng.bool(0.8) ? 0 : rng.double(0, 0.5)
            for _ in 0..<rng.int(0, 60) {
                samples.append(CMTime(value: CMTimeValue((v * Double(timescale)).rounded()), timescale: timescale))
                v += (1 / fps) * rng.pick([1.0, 1, 1, 0.5, 2])
            }
            let offset = rng.edgy(-1, 1, edges: [0, 1.0 / 1200])
            var next = 0
            var current = -1
            var times: [WV] = []
            var steps: [WV] = []
            var t = rng.double(-0.5, 0.5)
            for _ in 0..<30 {
                t += rng.pick([1.0 / 30, 1.0 / 60, 0.0, -0.5, 0.25, 1.0 / 29.97])
                // VERBATIM advance
                let cameraTargetTime = t - offset
                var camValue: WV = .null
                if cameraTargetTime >= 0 {
                    let camCMTime = CMTime(seconds: cameraTargetTime, preferredTimescale: 600)
                    camValue = .int(Int(camCMTime.value))
                    while next < samples.count, samples[next] <= camCMTime {
                        current = next
                        next += 1
                    }
                }
                times.append(t.wv)
                steps.append(["target": cameraTargetTime.wv, "camValue": camValue, "current": .int(current),
                              "usesLive": (cameraTargetTime >= 0 && current >= 0).wv])
            }
            cases.append(vcase(
                ["samples": .arr(samples.map { ["value": .int(Int($0.value)), "timescale": .int(Int($0.timescale))] }),
                 "cameraTimeOffset": offset.wv, "times": .arr(times)],
                ["steps": .arr(steps)]
            ))
        }
        return cases
    }
}
