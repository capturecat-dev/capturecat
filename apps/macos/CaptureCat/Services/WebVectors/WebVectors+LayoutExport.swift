import Foundation
import CoreGraphics
import CoreMedia

// Frame layout / placement / output-size units. VideoExporter's layout helpers
// are `private`, so they are exercised through VERBATIM ORACLES below (copied
// from Services/VideoExporter.swift at commit
// da569841c7b63175bffa46d897457f157224774d); everything they call —
// PlacementMath, DeviceFrameLayout, ExportSettings, AspectRatio, CMTime — is
// the REAL code. `--web-parity-fixtures` then checks the whole exporter
// end-to-end in pixels.
extension WebVectors {
    static var layoutMathUnits: [WebVectorUnit] {
        [
            WebVectorUnit(
                name: "placementMath",
                notes: "Services/PlacementMath.swift — snap, nearest, isCustom, customOrigin, alignment, constants",
                build: placementCases),
            WebVectorUnit(
                name: "exportFrameLayout",
                notes: "VERBATIM ORACLE of VideoExporter.frameLayout(sourceSize:outputSize:settings:canvasScale:) + alignmentFractions(for:) (VideoExporter.swift 2451-2533); calls the real PlacementMath",
                build: frameLayoutCases),
            WebVectorUnit(
                name: "exportCardTransform",
                notes: "VERBATIM ORACLE of VideoExporter.zoomAnchorPoint + compositeFrame's geometry (VideoExporter.swift 2518-2600): fit scale/translate, crop to videoRect, zoom about the focal anchor (Lanczos branch for zoom<1, affine sandwich otherwise), crop to contentRect",
                build: cardTransformCases),
            WebVectorUnit(
                name: "exportFrameTimes",
                notes: "VERBATIM ORACLE of VideoExporter.exportFrameTimes(duration:fps:startOffset:) (VideoExporter.swift 2508-2516) with the REAL CMTime(seconds:preferredTimescale: 600).seconds quantisation",
                build: frameTimeCases),
            WebVectorUnit(
                name: "exportOutputGeometry",
                notes: "Models/ExportSettings.swift (resolvedOutputSize, estimatedVideoBitRate, normalizedQuality, qualityPresetName, outputWidth) + Models/AspectRatio.swift (size, canvasAspect, letterboxRect, resolution(fitting:)) + VideoExporter.export's canvasScale and hidden-menu-bar crop (VERBATIM ORACLE, VideoExporter.swift 336-395)",
                build: outputGeometryCases),
            WebVectorUnit(
                name: "exportStaticLayout",
                notes: "VERBATIM ORACLE of VideoExporter.export's staticLayout device-bezel shrink + outer/inner corner radii (VideoExporter.swift 740-787) calling the REAL DeviceFrameLayout.bezelWidth/screenCornerRadius",
                build: staticLayoutCases),
        ]
    }

    // MARK: Random settings for placement

    private static func placementSettings(_ rng: inout WVRandom) -> ProjectSettings {
        let s = ProjectSettings()
        s.videoPlacement = rng.pick(ProjectSettings.VideoPlacement.allCases)
        s.backgroundPadding = rng.edgy(-20, 400, edges: [0, 48, 1000, 64])
        if rng.bool(0.4) {
            s.videoCustomX = rng.edgy(-3, 4, edges: [-1, 2, 0.5, 0, 1])
            s.videoCustomY = rng.edgy(-3, 4, edges: [-1, 2, 0.5, 0, 1])
        } else if rng.bool(0.1) {
            s.videoCustomX = rng.double(0, 1)  // only one axis set → not custom
        }
        return s
    }

    private static func placementSettingsWV(_ s: ProjectSettings) -> WV {
        [
            "videoPlacement": .str(s.videoPlacement.rawValue),
            "videoCustomX": s.videoCustomX.wv,
            "videoCustomY": s.videoCustomY.wv,
            "backgroundPadding": s.backgroundPadding.wv,
        ]
    }

    private static func placementCases() -> [WV] {
        var rng = WVRandom(seed: "placementMath")
        var cases: [WV] = []
        for _ in 0..<1500 {
            let s = placementSettings(&rng)
            let fx = rng.edgy(-0.5, 1.5, edges: [1.0 / 3, 2.0 / 3, 0, 1, 0.3333333333333333, 0.6666666666666666])
            let fy = rng.edgy(-0.5, 1.5, edges: [1.0 / 3, 2.0 / 3, 0, 1])
            let canvas = rng.size(0, 4000)
            let video = rng.size(0, 4000)
            let fraction = (x: rng.cg(-1.5, 2.5), y: rng.cg(-1.5, 2.5))
            let a = PlacementMath.alignment(for: s)
            let o = PlacementMath.customOrigin(fraction: fraction, canvas: canvas, video: video)
            cases.append(vcase(
                ["settings": placementSettingsWV(s), "fx": fx.wv, "fy": fy.wv,
                 "canvas": canvas.wv, "video": video.wv,
                 "fraction": ["x": fraction.x.wv, "y": fraction.y.wv]],
                [
                    "snapX": PlacementMath.snap(CGFloat(fx)).wv,
                    "nearest": .str(PlacementMath.nearest(fx: CGFloat(fx), fy: CGFloat(fy)).rawValue),
                    "isCustom": PlacementMath.isCustom(s).wv,
                    "alignment": ["x": a.x.wv, "y": a.y.wv],
                    "customOrigin": o.wv,
                    "magnetism": PlacementMath.magnetism.wv,
                ]
            ))
        }
        return cases
    }

    // MARK: Frame layout (oracle)

    struct OracleFrameLayout {
        let contentRect: CGRect
        let videoRect: CGRect
        let videoScale: CGFloat
    }

    /// VERBATIM: VideoExporter.alignmentFractions(for:)
    static func oracleAlignmentFractions(for settings: ProjectSettings) -> (x: CGFloat, y: CGFloat) {
        let f = PlacementMath.alignment(for: settings)
        return (f.x, 1 - f.y)
    }

    /// VERBATIM: VideoExporter.frameLayout(sourceSize:outputSize:settings:canvasScale:)
    static func oracleFrameLayout(
        sourceSize: CGSize,
        outputSize: CGSize,
        settings: ProjectSettings,
        canvasScale: CGFloat = 1
    ) -> OracleFrameLayout {
        let requested = max(0, settings.backgroundPadding * canvasScale)
        let padding = min(requested, min(outputSize.width, outputSize.height) * 0.35)
        let contentWidth = max(1, outputSize.width - padding * 2)
        let contentHeight = max(1, outputSize.height - padding * 2)
        let alignment = oracleAlignmentFractions(for: settings)
        let contentRect = CGRect(
            x: padding * (0.5 + alignment.x),
            y: padding * (0.5 + alignment.y),
            width: contentWidth,
            height: contentHeight
        )

        let sourceWidth = max(1, sourceSize.width)
        let sourceHeight = max(1, sourceSize.height)
        let videoScale = min(contentRect.width / sourceWidth, contentRect.height / sourceHeight)

        let videoWidth = sourceWidth * videoScale
        let videoHeight = sourceHeight * videoScale

        var videoX = contentRect.minX + (contentRect.width - videoWidth) * alignment.x
        var videoY = contentRect.minY + (contentRect.height - videoHeight) * alignment.y
        if PlacementMath.isCustom(settings) {
            let f = PlacementMath.alignment(for: settings) // Y-down fractions
            let origin = PlacementMath.customOrigin(
                fraction: f,
                canvas: outputSize,
                video: CGSize(width: videoWidth, height: videoHeight)
            )
            videoX = origin.x
            videoY = outputSize.height - origin.y - videoHeight
        }
        let videoRect = CGRect(x: videoX, y: videoY, width: videoWidth, height: videoHeight)

        return OracleFrameLayout(contentRect: contentRect, videoRect: videoRect, videoScale: videoScale)
    }

    private static func layoutWV(_ l: OracleFrameLayout) -> WV {
        ["contentRect": l.contentRect.wv, "videoRect": l.videoRect.wv, "videoScale": l.videoScale.wv]
    }

    private static func frameLayoutCases() -> [WV] {
        var rng = WVRandom(seed: "exportFrameLayout")
        var cases: [WV] = []
        let outputs: [CGSize] = [
            CGSize(width: 1920, height: 1080), CGSize(width: 1280, height: 720), CGSize(width: 3840, height: 2160),
            CGSize(width: 1080, height: 1920), CGSize(width: 1080, height: 1080), CGSize(width: 1920, height: 1440),
            CGSize(width: 2, height: 2),
        ]
        for _ in 0..<1500 {
            let s = placementSettings(&rng)
            let source = rng.bool(0.8)
                ? rng.pick([CGSize(width: 3024, height: 1964), CGSize(width: 2560, height: 1440),
                            CGSize(width: 1170, height: 2532), CGSize(width: 1920, height: 1080),
                            CGSize(width: 0, height: 0), CGSize(width: 800, height: 1)])
                : rng.size(0, 5000)
            let output = rng.bool(0.8) ? rng.pick(outputs) : rng.size(1, 5000)
            let canvasScale = rng.bool(0.6) ? 1 : rng.cg(0.1, 4)
            let l = oracleFrameLayout(sourceSize: source, outputSize: output, settings: s, canvasScale: canvasScale)
            let a = oracleAlignmentFractions(for: s)
            cases.append(vcase(
                ["settings": placementSettingsWV(s), "sourceSize": source.wv, "outputSize": output.wv,
                 "canvasScale": canvasScale.wv],
                layoutWV(l).setting("alignmentFractions", ["x": a.x.wv, "y": a.y.wv])
            ))
        }
        return cases
    }

    // MARK: Card transform (oracle)

    /// VERBATIM: VideoExporter.zoomAnchorPoint(focalPoint:videoRect:)
    static func oracleZoomAnchorPoint(focalPoint: CGPoint, videoRect: CGRect) -> CGPoint {
        let clampedX = max(0, min(1, focalPoint.x))
        let clampedY = max(0, min(1, focalPoint.y))
        return CGPoint(
            x: videoRect.minX + clampedX * videoRect.width,
            y: videoRect.maxY - clampedY * videoRect.height
        )
    }

    /// compositeFrame's zoom transform — both branches exactly as written
    /// (the Lanczos branch computes the translate as `anchor * (1 - z)`, the
    /// affine branch via CGAffineTransform concatenation).
    static func oracleZoomTransform(zoom: Double, anchor: CGPoint) -> (transform: CGAffineTransform, branch: String) {
        let safeZoom = max(zoom, 0.01)
        guard abs(safeZoom - 1) > .ulpOfOne else { return (.identity, "identity") }
        if safeZoom < 1 {
            // CILanczosScaleTransform scales about the origin, then translate.
            let t = CGAffineTransform(scaleX: safeZoom, y: safeZoom)
                .concatenating(CGAffineTransform(
                    translationX: anchor.x * (1 - safeZoom),
                    y: anchor.y * (1 - safeZoom)))
            return (t, "lanczos")
        }
        var zoomTransform = CGAffineTransform.identity
        zoomTransform = zoomTransform.translatedBy(x: anchor.x, y: anchor.y)
        zoomTransform = zoomTransform.scaledBy(x: safeZoom, y: safeZoom)
        zoomTransform = zoomTransform.translatedBy(x: -anchor.x, y: -anchor.y)
        return (zoomTransform, "affine")
    }

    private static func cardTransformCases() -> [WV] {
        var rng = WVRandom(seed: "exportCardTransform")
        var cases: [WV] = []
        for _ in 0..<1500 {
            let s = placementSettings(&rng)
            let source = rng.pick([CGSize(width: 3024, height: 1964), CGSize(width: 1170, height: 2532),
                                   CGSize(width: 1920, height: 1080), CGSize(width: 640, height: 480)])
            let output = rng.pick([CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1920),
                                   CGSize(width: 3840, height: 2160)])
            let l = oracleFrameLayout(sourceSize: source, outputSize: output, settings: s)
            let focal = CGPoint(x: rng.edgy(-0.5, 1.5, edges: [0, 1, 0.5]), y: rng.edgy(-0.5, 1.5, edges: [0, 1, 0.5]))
            let zoom = rng.edgy(0, 4, edges: [1, 1 + Double.ulpOfOne, 1 - 1e-17, 0.25, 0.005, 0.999, 1.0000001, 2])
            let anchor = oracleZoomAnchorPoint(focalPoint: focal, videoRect: l.videoRect)
            let z = oracleZoomTransform(zoom: zoom, anchor: anchor)
            // Where a source pixel lands: fitted (scale videoScale, translate to
            // videoRect.min) then the zoom transform. Recorded for a few points.
            let fit = CGAffineTransform(scaleX: l.videoScale, y: l.videoScale)
                .concatenating(CGAffineTransform(translationX: l.videoRect.minX, y: l.videoRect.minY))
            let full = fit.concatenating(z.transform)
            let probes: [CGPoint] = [.zero, CGPoint(x: source.width, y: source.height),
                                     CGPoint(x: source.width / 2, y: source.height / 3)]
            cases.append(vcase(
                ["settings": placementSettingsWV(s), "sourceSize": source.wv, "outputSize": output.wv,
                 "focalPoint": focal.wv, "zoom": zoom.wv],
                [
                    "layout": layoutWV(l),
                    "anchor": anchor.wv,
                    "safeZoom": max(zoom, 0.01).wv,
                    "branch": .str(z.branch),
                    "zoomTransform": z.transform.wv,
                    "fitTransform": fit.wv,
                    "sourceToOutput": full.wv,
                    "probes": .arr(probes.map { $0.applying(full).wv }),
                ]
            ))
        }
        return cases
    }

    // MARK: Frame times (oracle, real CMTime)

    /// VERBATIM: VideoExporter.exportFrameTimes(duration:fps:startOffset:)
    static func oracleExportFrameTimes(duration: TimeInterval, fps: Int, startOffset: TimeInterval = 0) -> [CMTime] {
        let safeFPS = max(1, fps)
        let timescale: Int32 = 600
        let totalFrames = max(1, Int(ceil(max(0, duration) * Double(safeFPS))))
        return (0..<totalFrames).map { index in
            let seconds = (Double(index) / Double(safeFPS)) + startOffset
            return CMTime(seconds: seconds, preferredTimescale: timescale)
        }
    }

    private static func frameTimeCases() -> [WV] {
        var rng = WVRandom(seed: "exportFrameTimes")
        var cases: [WV] = []
        for i in 0..<500 {
            let duration = rng.edgy(0, 20, edges: [0, 0.0001, 1.0 / 60, 1.0 / 30 + 1e-9, 8, -1])
            let fps = i % 10 == 0 ? rng.pick([0, 1, 7, 23, 29, 144, -5]) : rng.pick([24, 25, 30, 50, 60, 120])
            let offset = rng.bool(0.8) ? 0 : rng.edgy(-2, 5, edges: [1.0 / 1200, 0.5])
            let times = oracleExportFrameTimes(duration: duration, fps: fps, startOffset: offset)
            cases.append(vcase(
                ["duration": duration.wv, "fps": .int(fps), "startOffset": offset.wv],
                ["count": .int(times.count), "seconds": times.map(\.seconds).wv,
                 "values": .arr(times.map { .int(Int($0.value)) })]
            ))
        }
        return cases
    }

    // MARK: Output size / bitrate / aspect / canvasScale / menu-bar crop

    /// VERBATIM: the hidden-menu-bar crop in VideoExporter.export.
    static func oracleMenuBarCrop(settings: ProjectSettings, recordingSourceKind: RecordingSourceKind,
                                  sourceSegmentKinds: [RecordingSourceKind]) -> CGFloat {
        guard settings.menuBarReplacement == .hidden,
              recordingSourceKind != .device,
              !sourceSegmentKinds.contains(where: { $0 == .device }) else { return 0 }
        return min(0.12, max(0, settings.menuBarHeight / 100))
    }

    private static func outputGeometryCases() -> [WV] {
        var rng = WVRandom(seed: "exportOutputGeometry")
        var cases: [WV] = []
        for _ in 0..<1500 {
            var es = ExportSettings()
            es.resolution = rng.pick(ExportSettings.Resolution.allCases)
            es.fps = rng.pick([1, 24, 30, 60, 120, 0, -3])
            es.quality = rng.edgy(0, 1.5, edges: [0.5, 1, 0.85, 0.2, 0.4499])
            es.customWidth = rng.bool(0.8) ? rng.int(-10, 5000) : rng.pick([1, 2, 3, 1919, 1920])
            es.customHeight = rng.bool(0.8) ? rng.int(-10, 5000) : rng.pick([1, 2, 3, 1079, 1080])
            let aspect = rng.pick(AspectRatio.allCases)
            let source = rng.bool(0.85)
                ? rng.pick([CGSize(width: 3024, height: 1964), CGSize(width: 1170, height: 2532),
                            CGSize(width: 1920, height: 1080), CGSize.zero, CGSize(width: 0, height: 100)])
                : rng.size(0, 5000)
            let bounds = rng.rect(origin: -100, 100, size: -500, 2000)
            let letterboxAspect = rng.edgy(0, 4, edges: [16.0 / 9, 9.0 / 16, 1, 0])
            let fitWidth = rng.cg(0, 4000)
            let output = es.resolvedOutputSize(for: aspect, sourceSize: source)
            // canvasScale: headless exports have previewCanvasSize == .zero.
            let preview: CGSize = rng.bool(0.5) ? .zero : rng.size(0, 2000)
            let reference: CGSize = (preview.width > 0 && preview.height > 0) ? preview : output
            let canvasScale = min(output.width / reference.width, output.height / reference.height)
            let s = ProjectSettings()
            s.menuBarReplacement = rng.pick(ProjectSettings.MenuBarReplacement.allCases)
            s.menuBarHeight = rng.edgy(-5, 20, edges: [3.8, 2.6, 12, 0])
            let kind: RecordingSourceKind = rng.pick([.display, .window, .area, .device])
            let segKinds: [RecordingSourceKind] = rng.bool(0.2) ? [.display, .device] : []
            let crop = oracleMenuBarCrop(settings: s, recordingSourceKind: kind, sourceSegmentKinds: segKinds)
            cases.append(vcase(
                [
                    "exportSettings": WV.encoded(es), "aspectRatio": .str(aspect.rawValue),
                    "sourceSize": source.wv, "bounds": bounds.wv, "letterboxAspect": letterboxAspect.wv,
                    "fitWidth": fitWidth.wv, "previewCanvasSize": preview.wv,
                    "menuBarReplacement": .str(s.menuBarReplacement.rawValue), "menuBarHeight": s.menuBarHeight.wv,
                    "recordingSourceKind": .str(kind.rawValue), "sourceSegmentKinds": .arr(segKinds.map { .str($0.rawValue) }),
                ],
                [
                    "outputSize": output.wv,
                    "outputWidth": .int(es.outputWidth),
                    "normalizedQuality": es.normalizedQuality.wv,
                    "qualityPresetName": .str(es.qualityPresetName),
                    "estimatedVideoBitRate": .int(es.estimatedVideoBitRate(for: aspect, sourceSize: source)),
                    "aspectSize": aspect.size.wv,
                    "canvasAspect": aspect.canvasAspect(sourceSize: source).wv,
                    "letterboxRect": AspectRatio.letterboxRect(in: bounds, aspect: CGFloat(letterboxAspect)).wv,
                    "resolutionFitting": aspect.resolution(fitting: fitWidth).wv,
                    "canvasScale": canvasScale.wv,
                    "menuBarCrop": crop.wv,
                ]
            ))
        }
        return cases
    }

    // MARK: Static layout (device bezel shrink) — oracle, real DeviceFrameLayout

    /// VERBATIM: VideoExporter.export's `staticLayout` closure + corner radii.
    static func oracleStaticLayout(
        layout: OracleFrameLayout, deviceFrameActive: Bool, settings: ProjectSettings, canvasScale: CGFloat
    ) -> (layout: OracleFrameLayout, outer: CGFloat, inner: CGFloat) {
        let staticLayout: OracleFrameLayout = {
            guard deviceFrameActive else { return layout }
            var scale: CGFloat = 1
            for _ in 0..<3 {
                let bezel = DeviceFrameLayout.bezelWidth(
                    forVideoWidth: layout.videoRect.width * scale
                )
                scale = min(
                    (layout.contentRect.width - 2 * bezel) / layout.videoRect.width,
                    (layout.contentRect.height - 2 * bezel) / layout.videoRect.height
                )
            }
            scale = max(0.01, min(1, scale))
            let newWidth = layout.videoRect.width * scale
            let newHeight = layout.videoRect.height * scale
            let shrunk = CGRect(
                x: layout.videoRect.midX - newWidth / 2,
                y: layout.videoRect.midY - newHeight / 2,
                width: newWidth,
                height: newHeight
            )
            return OracleFrameLayout(
                contentRect: layout.contentRect,
                videoRect: shrunk,
                videoScale: layout.videoScale * scale
            )
        }()
        let outerCornerRadius: CGFloat = (deviceFrameActive || settings.frameShape == .rectangle)
            ? 0 : max(0, settings.cornerRadius * canvasScale)
        let innerCornerRadius: CGFloat = deviceFrameActive
            ? DeviceFrameLayout.screenCornerRadius(
                forVideoSize: staticLayout.videoRect.size)
            : max(0, settings.windowCornerRadius * canvasScale)
        return (staticLayout, outerCornerRadius, innerCornerRadius)
    }

    private static func staticLayoutCases() -> [WV] {
        var rng = WVRandom(seed: "exportStaticLayout")
        var cases: [WV] = []
        for _ in 0..<1200 {
            let s = placementSettings(&rng)
            s.frameShape = rng.pick(ProjectSettings.FrameShape.allCases)
            s.cornerRadius = rng.edgy(-5, 60, edges: [0, 12])
            s.windowCornerRadius = rng.edgy(-5, 40, edges: [0, 8])
            let source = rng.pick([CGSize(width: 1170, height: 2532), CGSize(width: 2048, height: 2732),
                                   CGSize(width: 1920, height: 1080), CGSize(width: 1179, height: 2556)])
            let output = rng.pick([CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1920),
                                   CGSize(width: 1080, height: 1080), CGSize(width: 3840, height: 2160)])
            let canvasScale = rng.bool(0.6) ? 1 : rng.cg(0.25, 3)
            let deviceFrameActive = rng.bool(0.7)
            let base = oracleFrameLayout(sourceSize: source, outputSize: output, settings: s, canvasScale: canvasScale)
            let r = oracleStaticLayout(layout: base, deviceFrameActive: deviceFrameActive, settings: s, canvasScale: canvasScale)
            cases.append(vcase(
                ["settings": placementSettingsWV(s)
                    .setting("frameShape", .str(s.frameShape.rawValue))
                    .setting("cornerRadius", s.cornerRadius.wv)
                    .setting("windowCornerRadius", s.windowCornerRadius.wv),
                 "sourceSize": source.wv, "outputSize": output.wv, "canvasScale": canvasScale.wv,
                 "deviceFrameActive": deviceFrameActive.wv],
                ["layout": layoutWV(r.layout), "outerCornerRadius": r.outer.wv, "innerCornerRadius": r.inner.wv]
            ))
        }
        return cases
    }
}
