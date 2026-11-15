import CoreImage
import QuartzCore
import UIKit

/// The iOS stage's motion blur — Studio 2d, the owner-approved playback
/// exception: while PAUSED or SCRUBBING the stage shows the exporter's exact
/// blur; while playing, none (a per-frame CI blur of the card overruns the
/// 60 fps budget — Phase 0 measured 11.7 ms mean / 20.2 ms p95 on a phone).
///
/// iOS CoreAnimation ignores layer filters, so the core's CIMotionBlur on
/// the zoom group draws nothing here. Instead:
///
/// 1. A TWIN core — same code, same input, the main core's motion state
///    copied in (so the springs are identical, nothing steps) — renders ONLY
///    the zoom group into an off-screen view of the same window.
/// 2. `drawHierarchy` reads it back through the render server: the real
///    composite (card shadow, masks, 3D tilt) — not CPU `render(in:)`, which
///    drops shadows and 3D transforms (measured, StudioLab --renderin-probe).
/// 3. Core Image blurs it in the EXPORTER's convention (radius × canvas
///    width in screen pixels, along the motion, on gamma-encoded values —
///    VideoExporter's CIMotionBlur), and the core shows that still in the
///    zoom group's place.
///
/// `--preview-parity` scores the result against the Mac's frozen blur states
/// and the exporter's blur in pixels (MOTIONBLUR-PIXELS), defects injected.
@MainActor
final class PreviewStageMotionBlur {
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

    /// After every main render: show the blurred still, or clear it.
    func update(after input: PreviewCompositorCore.FrameInput) {
        guard let stage, let core = stage.core else { return }
        let radius = core.motionBlurScreenRadius
        guard !input.isPlaying, radius > 0, core.appliedMotionBlur.active,
              let still = blurredZoomGroup(input, stage: stage, core: core, radius: radius) else {
            core.showZoomGroupStill(nil)
            return
        }
        core.showZoomGroupStill(still)
    }

    private func blurredZoomGroup(
        _ input: PreviewCompositorCore.FrameInput, stage: PreviewStageView,
        core: PreviewCompositorCore, radius: Double
    ) -> CGImage? {
        guard let window = stage.window else { return nil }
        let canvas = stage.virtualCanvasSize
        // Off-screen in the SAME window (drawHierarchy needs a window; the
        // stage clips to its bounds, so the twin is never visible).
        if twinView.superview !== stage {
            stage.addSubview(twinView)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        twinView.bounds = CGRect(origin: .zero, size: canvas)
        twinView.layer.position = CGPoint(x: -canvas.width * 4 - 100, y: 0)
        CATransaction.commit()
        let twin: PreviewCompositorCore
        if let existing = twinCore {
            twin = existing
        } else {
            twin = PreviewCompositorCore(root: twinView.layer, chromeTheme: IOSStudioChromeTheme())
            twin.host = twinHost
            twin.zoomGroupOnly = true
            // The core paints its root black; the twin must be transparent
            // around the card, as the zoom group is over the backdrop.
            twinView.layer.backgroundColor = nil
            twinCore = twin
        }
        let scale = window.screen.scale * max(0.01, stage.magnification)
        twinHost.canvas = canvas
        twinHost.scale = scale
        twin.rasterScaleOverride = core.rasterScaleOverride
        twin.adoptMotionState(from: core)
        // No players in the twin: a second video output on the same item
        // would compete with the stage's. iOS renders posters today; when
        // iOS playback lands, hand the twin the DISPLAYED frame as its
        // poster (paused/scrubbing is exactly when it is not moving).
        var twinInput = input
        twinInput.player = nil
        twinInput.cameraPlayer = nil
        twin.render(twinInput)

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        format.preferredRange = .standard
        guard let crisp = UIGraphicsImageRenderer(bounds: twinView.bounds, format: format).image(actions: { _ in
            _ = twinView.drawHierarchy(in: twinView.bounds, afterScreenUpdates: true)
        }).cgImage else { return nil }
        return Self.exporterMotionBlur(
            crisp, radiusPx: radius * canvas.width * scale, angle: core.motionBlurScreenAngle,
            linear: PreviewCompositorCore.debugMotionBlurDefect == .linearLight)
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
        let context = linear ? linearContext : gammaContext
        return context.createCGImage(blurred, from: input.extent, format: .RGBA8, colorSpace: space)
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
