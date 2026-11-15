import CoreGraphics

/// Shared on-canvas chrome for the blur / highlight region handles, in the
/// EditorTheme language. Purely decorative — every gesture stays in the handle
/// views that own the region bindings.
enum RegionHandleChrome {
    static let dotSize: CGFloat = 8
    static let dotHoverSize: CGFloat = 10
    /// Gap between the region's edge and the floating value pill.
    static let pillGap: CGFloat = 8
    /// Fixed so the pill's position can be clamped exactly against the canvas.
    static let pillHeight: CGFloat = 26
}

/// Where a region's floating pill should sit so it never clips off the canvas.
///
/// Preferred spot is centred just below the region. When there isn't room the
/// pill flips to just *inside* the region's bottom edge, and it is always
/// clamped horizontally to the canvas.
enum RegionPillPlacement {
    /// Offsets relative to the region box's bottom-centre anchor
    /// (`.overlay(alignment: .bottom)`), whose origin is the centre of the
    /// region's bottom edge.
    static func offset(
        regionRect: CGRect,
        containerRect: CGRect,
        pillWidth: CGFloat
    ) -> CGSize {
        let half = RegionHandleChrome.pillHeight / 2

        // Below the region if it fits, otherwise tucked inside the bottom edge.
        let below = half + RegionHandleChrome.pillGap
        let inside = -(half + RegionHandleChrome.pillGap)
        let fitsBelow = regionRect.maxY + RegionHandleChrome.pillGap
            + RegionHandleChrome.pillHeight <= containerRect.maxY
        let y = fitsBelow ? below : inside

        // Keep the whole pill on canvas horizontally.
        let centreX = regionRect.midX
        let lower = containerRect.minX + pillWidth / 2
        let upper = containerRect.maxX - pillWidth / 2
        let clampedCentre = upper >= lower
            ? min(max(centreX, lower), upper)
            : containerRect.midX
        return CGSize(width: clampedCentre - centreX, height: y)
    }
}
