import CoreImage
import QuartzCore
import UIKit

/// The two compositor effects iOS CoreAnimation cannot draw (Studio 2d), each
/// rebuilt from the render server's own pixels and finished in Core Image the
/// exporter's way:
///
/// - **Motion blur** — iOS ignores the core's CIMotionBlur layer filter.
///   Owner-approved playback exception: none while PLAYING; while paused or
///   scrubbing, the exporter's exact blur (a per-frame CI blur of the card
///   overruns 60 fps — Phase 0: 11.7 ms mean / 20.2 ms p95 on a phone).
/// - **Camera-look cross-dissolve** — iOS ignores the stacks'
///   CIAdditionCompositing, so source-over would let the screen show through
///   a fade between two opaque stacks (Phase 0: up to 38/255). Approved: a CI
///   pass, always — Σ stack × weight with the exporter's own `scaleStack` +
///   CIAdditionCompositing.
///
/// How: a TWIN compositor core — same code, same input, the main core's
/// motion state copied in so its springs step exactly as the main core's
/// will — renders off-screen in the same window, in an isolation mode (only
/// the zoom group; or only one camera stack, untransformed). `drawHierarchy`
/// reads it back through the render server: the real composite, shadows,
/// masks and 3D included. CPU `CALayer.render(in:)` is not used — it drops
/// layer shadows and 3D transforms (measured, StudioLab --renderin-probe).
///
/// The twin runs BEFORE the main render and the main core applies the stills
/// at the end of its own render, so a read-back's commit never shows a frame
/// without them. The twin only runs when an effect is possible (blur on and
/// not playing; a look transition in progress) — zero cost otherwise.
///
/// Limits (docs/ios-studio-plan.md): the twin gets no players — iOS renders
/// posters today; when iOS playback lands it must be handed the displayed
/// frames, and the dissolve's per-frame read-backs want a cache. Stacking
/// layouts (the camera inside the card) keep the plain composite.
@MainActor
final class PreviewStageTwin {
    struct Stills {
        var zoomGroup: CGImage?
        var cameraDissolve: (image: CGImage, rect: CGRect, weights: CameraLayoutMath.LookWeights)?
    }

    private weak var stage: PreviewStageView?
    private let twinView = UIView()
    private var twinCore: PreviewCompositorCore?
    private let twinHost = TwinHost()

    init(stage: PreviewStageView) {
        self.stage = stage
        twinView.isUserInteractionEnabled = false
        twinView.isOpaque = false
        twinView.layer.anchorPoint = .zero
    }

    /// The stills for `input`, computed from the twin — call before the main
    /// core renders `input`.
    func prepare(_ input: PreviewCompositorCore.FrameInput) -> Stills {
        guard let stage, let core = stage.core, let window = stage.window else { return Stills() }
        let blurPossible = !input.isPlaying && input.project.settings.motionBlur
        let dissolvePossible = Self.lookTransitionPossible(input)
        guard blurPossible || dissolvePossible else { return Stills() }

        let canvas = stage.virtualCanvasSize
        let scale = window.screen.scale * max(0.01, stage.magnification)
        let twin = prepareTwin(stage: stage, canvas: canvas, scale: scale)
        twin.rasterScaleOverride = core.rasterScaleOverride
        twin.adoptMotionState(from: core)
        // No players in the twin: a second video output on the same item
        // would compete with the stage's (posters only on iOS today).
        var twinInput = input
        twinInput.player = nil
        twinInput.cameraPlayer = nil

        var stills = Stills()
        // 1 — the zoom group. Also the render that steps the twin's springs
        // (later renders are same-time and step nothing).
        twin.cameraStackIsolation = nil
        twin.zoomGroupOnly = true
        twin.render(twinInput)
        if blurPossible, twin.appliedMotionBlur.active, twin.motionBlurScreenRadius > 0,
           let crisp = readBack(scale: scale) {
            stills.zoomGroup = Self.exporterMotionBlur(
                crisp, radiusPx: twin.motionBlurScreenRadius * canvas.width * scale,
                angle: twin.motionBlurScreenAngle,
                linear: PreviewCompositorCore.debugMotionBlurDefect == .linearLight)
        }

        // 2 — the camera stacks, one at a time, summed the exporter's way.
        if dissolvePossible, twin.cameraStacksDissolving {
            let w = twin.debugCameraLookWeights()
            var parts: [(CGImage, Double)] = []
            var local: CGRect?
            twin.zoomGroupOnly = false
            for (kind, weight) in [(PreviewCompositorCore.CameraStackKind.bubble, w.bubble),
                                   (.cutout, w.cutout), (.popOut, w.popOut)] where weight > 0 {
                twin.cameraStackIsolation = kind
                twin.render(twinInput)
                guard let region = twin.isolatedCameraStackRegion(margin: 0.6),
                      let full = readBack(scale: scale) else { parts = []; break }
                // Whole pixels, so the still maps 1:1 onto what was read.
                let px = CGRect(x: region.root.minX * scale, y: region.root.minY * scale,
                                width: region.root.width * scale, height: region.root.height * scale)
                    .integral
                guard let crop = full.cropping(to: px) else { parts = []; break }
                let snappedRoot = CGRect(x: px.minX / scale, y: px.minY / scale,
                                         width: px.width / scale, height: px.height / scale)
                local = region.local.offsetBy(dx: snappedRoot.minX - region.root.minX,
                                              dy: snappedRoot.minY - region.root.minY)
                local?.size = snappedRoot.size
                parts.append((crop, weight))
            }
            if parts.count > 1, let local, let sum = Self.dissolve(parts) {
                stills.cameraDissolve = (sum, local, w)
            }
        }
        twin.cameraStackIsolation = nil
        twin.zoomGroupOnly = false
        return stills
    }

    /// A camera-look transition can be in progress at `input`'s time — the
    /// core's own gate (camera shown, a fresh mask) and the shared weights.
    static func lookTransitionPossible(_ input: PreviewCompositorCore.FrameInput) -> Bool {
        guard input.project.settings.showCamera, input.cameraMask != nil else { return false }
        let w = CameraLayoutMath.lookWeights(
            at: input.currentTime, regions: input.project.cameraLayoutRegions,
            defaultLook: input.project.settings.cameraLook, stacking: false)
        return [w.bubble, w.cutout, w.popOut].filter { $0 > 0 }.count > 1
    }

    private func prepareTwin(stage: PreviewStageView, canvas: CGSize, scale: CGFloat) -> PreviewCompositorCore {
        // Off-screen in the SAME window (drawHierarchy needs one; the stage
        // clips to its bounds, so the twin is never visible).
        if twinView.superview !== stage { stage.addSubview(twinView) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        twinView.bounds = CGRect(origin: .zero, size: canvas)
        twinView.layer.position = CGPoint(x: -canvas.width * 4 - 100, y: 0)
        CATransaction.commit()
        twinHost.canvas = canvas
        twinHost.scale = scale
        if let twinCore { return twinCore }
        let twin = PreviewCompositorCore(root: twinView.layer, chromeTheme: IOSStudioChromeTheme())
        twin.host = twinHost
        // The core paints its root black; read-backs must be transparent
        // around what they isolate.
        twinView.layer.backgroundColor = nil
        twinCore = twin
        return twin
    }

    /// The twin as the render server composites it, 8-bit sRGB.
    private func readBack(scale: CGFloat) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(bounds: twinView.bounds, format: format).image { _ in
            _ = twinView.drawHierarchy(in: twinView.bounds, afterScreenUpdates: true)
        }.cgImage
    }

    /// VideoExporter's CIMotionBlur, in its convention: clamped, radius in
    /// pixels, `−angle` (an upright UIKit image is Y-up to Core Image), on
    /// gamma-encoded values (the exporter's working space is non-linear).
    static func exporterMotionBlur(_ image: CGImage, radiusPx: Double, angle: Double, linear: Bool) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard let blurred = CIFilter(name: "CIMotionBlur", parameters: [
            kCIInputImageKey: input.clampedToExtent(),
            kCIInputRadiusKey: radiusPx,
            kCIInputAngleKey: -angle,
        ])?.outputImage?.cropped(to: input.extent) else { return nil }
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return (linear ? linearContext : gammaContext)
            .createCGImage(blurred, from: input.extent, format: .RGBA8, colorSpace: space)
    }

    /// The exporter's camera-look cross-dissolve (VideoExporter.compositeCamera):
    /// each stack scaled by its weight (`scaleStack` — premultiplied RGBA × w),
    /// then SUMMED with CIAdditionCompositing, on gamma-encoded values.
    static func dissolve(_ parts: [(CGImage, Double)]) -> CGImage? {
        guard let first = parts.first?.0 else { return nil }
        var sum: CIImage?
        for (image, weight) in parts {
            let scaled = VideoExporter.scaleStack(CIImage(cgImage: image), by: weight)
            sum = sum.map {
                scaled.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: $0])
            } ?? scaled
        }
        guard let sum else { return nil }
        let extent = CGRect(x: 0, y: 0, width: first.width, height: first.height)
        let space = first.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return gammaContext.createCGImage(sum.cropped(to: extent), from: extent, format: .RGBA8, colorSpace: space)
    }

    private static let gammaContext = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    private static let linearContext = CIContext()

    private final class TwinHost: PreviewCompositorHost {
        var canvas: CGSize = .zero
        var scale: CGFloat = 2
        var compositorCanvasSize: CGSize { canvas }
        var compositorDisplayScale: CGFloat? { scale }
        var compositorIsDraggingOnCanvas: Bool { false }
        var compositorInlineEditingID: UUID? { nil }
        func compositorDidRender(_ frame: PreviewCompositorCore.RenderedFrame) {}
    }
}
