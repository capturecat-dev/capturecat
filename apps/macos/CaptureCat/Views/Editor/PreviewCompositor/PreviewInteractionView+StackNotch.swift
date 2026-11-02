import AppKit

/// The vertical stack's resize notch (docs/camera-cutout.md §12.12): hovering
/// the camera row shows a small pill on the seam between the rows; the seam
/// (or the pill) drags up and down to set `cameraStackRatio`. Editing chrome
/// only — it lives on the interaction layer, never in the composited frame.
extension PreviewInteractionView {
    /// Grab band around the seam, in points.
    static let stackSeamSlop: CGFloat = 8

    func stackSeamHit(_ p: CGPoint, _ stack: StackSeam) -> Bool {
        p.x >= stack.area.minX && p.x <= stack.area.maxX && abs(p.y - stack.seamY) <= Self.stackSeamSlop
            || stackNotchRect(stack).insetBy(dx: -6, dy: -6).contains(p)
    }

    /// The ratio whose camera row ends at canvas y (stackRows' inverse).
    func stackRatio(at y: CGFloat, area: CGRect, gap share: Double) -> Double {
        let gap = area.height * CGFloat(share)
        let usable = max(1, area.height - gap)
        return Double((y - area.minY) / usable)
    }

    func stackNotchRect(_ stack: StackSeam) -> CGRect {
        let w: CGFloat = 44, h: CGFloat = 8
        return CGRect(x: stack.cameraRow.midX - w / 2, y: stack.seamY - h / 2, width: w, height: h)
    }

    /// Shows / hides / places the notch for the pointer at `p` (nil = left).
    func updateStackNotch(pointer p: CGPoint?) {
        guard let stack = context?.stack, let p,
              stack.cameraRow.insetBy(dx: 0, dy: -Self.stackSeamSlop).contains(p) || stackSeamHit(p, stack) else {
            stackNotchLayer.opacity = 0
            if stackCursorPushed { NSCursor.pop(); stackCursorPushed = false }
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stackNotchLayer.frame = stackNotchRect(stack)
        stackNotchLayer.cornerRadius = 4
        CATransaction.commit()
        stackNotchLayer.opacity = 1
        let onSeam = stackSeamHit(p, stack)
        if onSeam, !stackCursorPushed { NSCursor.resizeUpDown.push(); stackCursorPushed = true }
        if !onSeam, stackCursorPushed { NSCursor.pop(); stackCursorPushed = false }
    }
}
