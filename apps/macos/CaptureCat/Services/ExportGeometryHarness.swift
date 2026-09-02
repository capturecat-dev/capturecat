import AppKit
import Foundation

/// Preview↔export GEOMETRY gate: `CaptureCat --export-geometry-test`.
///
/// The editor letterboxes its canvas to the project's resolved output aspect
/// (`AspectRatio.canvasAspect` → `AspectRatio.letterboxRect`) and the exporter
/// derives its file size from the same function — so the exported frame must
/// be a UNIFORM scale of the preview canvas. This harness proves that
/// numerically for (source aspect × aspect setting × resolution × window
/// size) combos, then replays the camera-bubble geometry chain of BOTH
/// renderers (the shared ReactiveCameraLayout / CameraStyleMath math plus
/// each side's scale factors, verbatim) and asserts:
///
///   1. resolvedOutputSize dimensions are even and match the canvas aspect.
///   2. canvasScale = outputSize / previewCanvasSize is uniform (min == max
///      within rounding) — the historical bug was `.auto` hardcoding 16:9
///      while the preview canvas followed the window, which made min() crop
///      one axis of every spatial mapping.
///   3. The camera bubble rect, normalized to its canvas, is IDENTICAL in
///      preview and export (position and size), for corner and edge-adjacent
///      custom placements.
///   4. The bubble (and its ring-glow outset) stays inside the output frame
///      whenever it is inside the preview canvas — the exporter's final
///      `.cropped(to: outputRect)` must never shave a bubble the editor
///      shows whole.
///
/// Pure math — no rendering, no media. Never reached in a normal launch.
enum ExportGeometryHarness {
    static func run() -> Never {
        var failures = 0
        func expect(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL") \(label)")
            if !condition { failures += 1 }
        }

        let sourceSizes: [CGSize] = [
            CGSize(width: 3024, height: 1964),   // MacBook display (~1.54)
            CGSize(width: 1920, height: 1200),   // 16:10
            CGSize(width: 1920, height: 1080),   // 16:9
            CGSize(width: 1080, height: 1920),   // portrait device
            CGSize(width: 2560, height: 1080),   // ultrawide
        ]
        let aspects: [AspectRatio] = [.auto, .widescreen, .square, .vertical, .tallVertical]
        let cards: [CGSize] = [
            CGSize(width: 1456, height: 728),
            CGSize(width: 1052, height: 592),
            CGSize(width: 1244, height: 777),
            CGSize(width: 900, height: 720),
        ]
        var resolutions: [ExportSettings] = ExportSettings.Resolution.allCases.map {
            var s = ExportSettings(); s.resolution = $0; return s
        }
        resolutions[3].customWidth = 1000
        resolutions[3].customHeight = 820

        // Edge-adjacent camera placements (normalized, Y-down like the
        // preview): corners plus the near-edge drag the clip report showed.
        let placements: [CGPoint] = [
            CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 0),
            CGPoint(x: 1, y: 1), CGPoint(x: 0.9888, y: 0.9210),
            CGPoint(x: 0.97, y: 0.03),
        ]

        // Independent ground truth (NOT via canvasAspect, which both sides
        // share): `.auto` must follow the SOURCE aspect — the shipped bug was
        // `.auto` hardcoding 16:9 in the exporter while the editor followed
        // the source-shaped window canvas.
        for source in sourceSizes {
            let want = source.width / source.height
            let got = AspectRatio.auto.canvasAspect(sourceSize: source)
            expect(abs(got - want) / want < 0.001,
                "auto canvas aspect follows source \(Int(source.width))x\(Int(source.height)) (got \(got), want \(want))")
        }

        for source in sourceSizes {
            for aspect in aspects {
                for export in resolutions {
                    let out = export.resolvedOutputSize(for: aspect, sourceSize: source)
                    let tag = "src \(Int(source.width))x\(Int(source.height)) \(aspect.rawValue) \(export.resolution.rawValue)"

                    // 1 — even H.264-safe dimensions, aspect-true height.
                    expect(Int(out.width) % 2 == 0 && Int(out.height) % 2 == 0
                        && out.width >= 2 && out.height >= 2,
                        "\(tag): output \(Int(out.width))x\(Int(out.height)) even")
                    if export.resolution != .custom {
                        let want = aspect.canvasAspect(sourceSize: source)
                        let got = out.width / out.height
                        expect(abs(got - want) / want < 0.01,
                            "\(tag): output aspect \(got) ~ canvas aspect \(want)")
                    }

                    for card in cards {
                        // The EXACT letterbox the editor applies (shared code).
                        let canvas = AspectRatio.letterboxRect(
                            in: CGRect(origin: .zero, size: card),
                            aspect: out.width / out.height).size

                        // 2 — uniform preview→output scale.
                        let sx = out.width / canvas.width
                        let sy = out.height / canvas.height
                        expect(abs(sx - sy) / sx < 0.01,
                            "\(tag) card \(Int(card.width))x\(Int(card.height)): canvasScale uniform (\(sx) vs \(sy))")

                        // 3/4 — camera bubble parity + containment.
                        for placement in placements {
                            let (previewRect, exportRect, exportRing) = cameraRects(
                                previewCanvas: canvas, outputSize: out,
                                customPosition: placement, cameraSize: 320,
                                bubbleAspect: 0.8)
                            let p = normalized(previewRect, in: canvas, flipY: false)
                            let e = normalized(exportRect, in: out, flipY: true)
                            let delta = max(abs(p.minX - e.minX), abs(p.minY - e.minY),
                                            abs(p.width - e.width), abs(p.height - e.height))
                            expect(delta < 0.01,
                                "\(tag) card \(Int(card.width))x\(Int(card.height)) cam(\(placement.x),\(placement.y)): bubble parity (worst \(delta))")

                            let outputRect = CGRect(origin: .zero, size: out)
                            expect(outputRect.insetBy(dx: -0.5, dy: -0.5).contains(exportRect),
                                "\(tag) cam(\(placement.x),\(placement.y)): export bubble inside frame")
                            // Ring glow: clipped by the frame edge only as much
                            // as the preview clips it (normalized overhangs equal).
                            let pr = normalized(previewRing(previewRect), in: canvas, flipY: false)
                            let er = normalized(exportRing, in: out, flipY: true)
                            let ringDelta = max(abs(pr.minX - er.minX), abs(pr.minY - er.minY),
                                                abs(pr.width - er.width), abs(pr.height - er.height))
                            expect(ringDelta < 0.012,
                                "\(tag) cam(\(placement.x),\(placement.y)): ring-glow parity (worst \(ringDelta))")
                        }
                    }
                }
            }
        }

        print(failures == 0 ? "EXPORT-GEOMETRY OK" : "EXPORT-GEOMETRY FAILED (\(failures))")
        exit(failures == 0 ? 0 : 1)
    }

    /// Preview chain verbatim (PreviewCompositorView.renderCamera) and export
    /// chain verbatim (VideoExporter camera setup): the two scale-factor
    /// stacks this gate exists to keep in lockstep.
    private static func cameraRects(
        previewCanvas: CGSize, outputSize: CGSize,
        customPosition: CGPoint, cameraSize: Double, bubbleAspect: Double
    ) -> (preview: CGRect, export: CGRect, exportRing: CGRect) {
        // Preview.
        let fitP = ReactiveCameraLayout.canvasFitScale(for: previewCanvas)
        let baseP = max(120, cameraSize) * Double(fitP)
        let rectP = ReactiveCameraLayout.cameraRect(
            in: CGRect(origin: .zero, size: previewCanvas),
            basePosition: .bottomRight, customPosition: customPosition,
            baseSize: baseP, zoom: 1.0, padding: Double(12 * fitP),
            aspect: bubbleAspect, yAxisIsUp: false)

        // Export.
        let canvasScale = min(outputSize.width / previewCanvas.width,
                              outputSize.height / previewCanvas.height)
        let fitE = ReactiveCameraLayout.canvasFitScale(for: previewCanvas)
        let baseE = max(1, max(120, cameraSize) * Double(fitE) * Double(canvasScale))
        let rectE = ReactiveCameraLayout.cameraRect(
            in: CGRect(origin: .zero, size: outputSize),
            basePosition: .bottomRight, customPosition: customPosition,
            baseSize: baseE, zoom: 1.0, padding: Double(12 * fitE * canvasScale),
            aspect: bubbleAspect, yAxisIsUp: true)
        let ringE = rectE.insetBy(
            dx: -CameraStyleMath.ringPadding(for: rectE.size),
            dy: -CameraStyleMath.ringPadding(for: rectE.size))
        return (rectP, rectE, ringE)
    }

    private static func previewRing(_ bubble: CGRect) -> CGRect {
        let pad = CameraStyleMath.ringPadding(for: bubble.size)
        return bubble.insetBy(dx: -pad, dy: -pad)
    }

    /// Y-down normalized rect (the preview's space); export rects are Y-up
    /// and get flipped so both sides compare in one space.
    private static func normalized(_ rect: CGRect, in canvas: CGSize, flipY: Bool) -> CGRect {
        let top = flipY ? canvas.height - rect.maxY : rect.minY
        return CGRect(x: rect.minX / canvas.width, y: top / canvas.height,
                      width: rect.width / canvas.width, height: rect.height / canvas.height)
    }
}
