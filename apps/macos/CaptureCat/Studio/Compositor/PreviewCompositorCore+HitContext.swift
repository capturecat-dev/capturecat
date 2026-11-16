import CoreGraphics
import Foundation

extension PreviewCompositorCore {
    /// The hit context an edit-gesture surface works against — canvas-space
    /// geometry from THIS render, so gestures always match the pixels on
    /// screen. Shared by the Mac host (`PreviewCompositorView`, mouse) and the
    /// iOS editor (`EditorCanvasView`, touch), so a tap and a click hit-test
    /// the same targets. Moved verbatim from `PreviewCompositorView
    /// .compositorDidRender` (Studio 4b).
    ///
    /// `selectedBlurID` is the host's blur selection (the Mac keeps a
    /// preview-local copy, see `PreviewCompositorView.localSelectedBlurID`).
    func hitContext(for frame: RenderedFrame, selectedBlurID: UUID?) -> PreviewHitContext {
        let input = frame.input
        let canvas = frame.canvas
        let angles = frame.tiltAngles
        return PreviewHitContext(
            project: input.project,
            isPlaying: input.isPlaying,
            canvas: canvas,
            contentRect: frame.contentRect,
            videoRect: frame.videoRect,
            zoom: frame.zoom,
            zoomAnchor: frame.zoomAnchor,
            cameraRect: lastCameraRect,
            subtitleRect: lastSubtitleRect,
            watermarkRect: lastWatermarkRect,
            selectedBlurID: selectedBlurID,
            selectedHighlightID: input.selectedHighlightID,
            selectedDepthFocusID: input.selectedDepthFocusID,
            selectedAnnotationID: input.selectedAnnotationID,
            cameraFitScale: ReactiveCameraLayout.canvasFitScale(for: canvas),
            cameraAspect: input.cameraVideoAspect,
            tiltPitch: angles.pitch,
            tiltYaw: angles.yaw,
            tiltRoll: angles.roll,
            tiltCenter: frame.tiltCenter,
            tiltDistance: frame.tiltDistance,
            selectedZoomFocal: input.selectedZoomID.flatMap { id in
                input.project.zoomRegions.first { $0.id == id }?.focalPoint
            },
            cardOffset: motion.cardOffset,
            activeZoomID: input.project.zoomRegions.first(where: {
                input.currentTime >= $0.startTime && input.currentTime <= $0.endTime
            })?.id,
            // The resize notch only while the stack is settled on screen
            // (not mid-morph into or out of a Bubble block, and not while
            // the row yields to a zoom — a drag there would set the yielded
            // height).
            stack: lastStackRows.flatMap { rows in
                lastStackActive && lastStackYield > 0.999 && lastCameraLayout.cardClip == rows.screen
                    ? PreviewStackSeam(
                        cameraRow: rows.camera, area: lastStackArea,
                        gap: CameraLayoutMath.stackGap(input.project.settings.cameraStackGap)) : nil
            }
        )
    }
}
