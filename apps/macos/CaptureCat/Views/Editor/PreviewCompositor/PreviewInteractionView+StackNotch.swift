import AppKit

/// The vertical stack's resize notch (docs/camera-cutout.md §12.12): hovering
/// the camera row shows a small pill on the seam between the rows; the seam
/// (or the pill) drags up and down to set `cameraStackRatio`. Editing chrome
/// only — it lives on the interaction layer, never in the composited frame.
/// The seam geometry is PreviewHitMath's; the drag is PreviewGestureCore's.
extension PreviewInteractionView {
    /// Shows / hides / places the notch for the pointer at `p` (nil = left).
    func updateStackNotch(pointer p: CGPoint?) {
        guard let stack = context?.stack, let p,
              stack.cameraRow.insetBy(dx: 0, dy: -PreviewHitMath.stackSeamSlop).contains(p)
                  || PreviewHitMath.stackSeamHit(p, stack) else {
            stackNotchLayer.opacity = 0
            if stackCursorPushed { NSCursor.pop(); stackCursorPushed = false }
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stackNotchLayer.frame = PreviewHitMath.stackNotchRect(stack)
        stackNotchLayer.cornerRadius = 4
        CATransaction.commit()
        stackNotchLayer.opacity = 1
        let onSeam = PreviewHitMath.stackSeamHit(p, stack)
        if onSeam, !stackCursorPushed { NSCursor.resizeUpDown.push(); stackCursorPushed = true }
        if !onSeam, stackCursorPushed { NSCursor.pop(); stackCursorPushed = false }
    }
}
