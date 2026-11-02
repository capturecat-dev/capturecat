import AppKit
import QuartzCore

// Debug-only geometry readbacks on the compositor, used by the parity gate.

extension PreviewCompositorView {
    /// The video's aspect-fitted rect inside the canvas — parity harness only.
    /// Paired with `debugWarpedCursorCenter()` so the gate can assert the
    /// cursor lands at the same FRACTION of the video that it occupies in the
    /// recorded coordinate space, rather than scoring it as pixels and letting
    /// a systematic offset hide in the noise.
    func debugVideoRect() -> CGRect? { lastVideoRect }

    /// Canvas-space position of the cursor's HOTSPOT — the point that must land
    /// exactly on the recorded position.
    ///
    /// Distinct from the sprite centre, and that distinction is the whole
    /// point: the arrow's hotspot sits near its top-left corner, so measuring
    /// the centre reports a constant offset of `halfSize - hotSpot` and makes a
    /// correct renderer look broken (and, worse, could make a broken one look
    /// correct if the two errors cancelled).
    func debugCursorHotspot() -> CGPoint? {
        guard let cursor = debugCursorLayer(), !cursor.isHidden,
              let hs = lastCursorHotspotInLayer else { return nil }
        return canvasPoint(fromRider: cursor, CGPoint(x: cursor.frame.minX + hs.x, y: cursor.frame.minY + hs.y))
    }

    /// A point in a card rider's parent space (the layout group: card +
    /// riders) → canvas: through the camera-layout transform, then the
    /// content (tilt) transform and the content origin, then the zoom.
    /// Every group on the way is anchored at the origin.
    private func canvasPoint(fromRider rider: CALayer, _ p: CGPoint) -> CGPoint? {
        guard let layout = rider.superlayer, let clip = layout.superlayer,
              let content = clip.superlayer, let zoomL = content.superlayer else { return nil }
        let inContent = apply(clip.transform, to: apply(layout.transform, to: p))
        let p1 = apply(content.transform, to: inContent)
        let inCanvas = CGPoint(x: p1.x + content.frame.origin.x, y: p1.y + content.frame.origin.y)
        return apply(zoomL.transform, to: inCanvas)
    }

    /// Canvas-space position of the (warped, zoomed) cursor center — parity
    /// harness only.
    func debugWarpedCursorCenter() -> CGPoint? {
        guard let cursor = debugCursorLayer(), !cursor.isHidden else { return nil }
        // Through the layout, tilt (content) and zoom transforms.
        return canvasPoint(fromRider: cursor, CGPoint(x: cursor.frame.midX, y: cursor.frame.midY))
    }

    private func apply(_ t: CATransform3D, to p: CGPoint) -> CGPoint {
        // Row-vector: [x y 0 1] * M
        let x = Double(p.x), y = Double(p.y)
        let ox = x * t.m11 + y * t.m21 + t.m41
        let oy = x * t.m12 + y * t.m22 + t.m42
        let ow = x * t.m14 + y * t.m24 + t.m44
        guard abs(ow) > 0.0001 else { return p }
        return CGPoint(x: ox / ow, y: oy / ow)
    }
}
