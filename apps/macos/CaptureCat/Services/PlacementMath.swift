import CoreGraphics

/// Single source of truth for the nine-way video placement grid.
///
/// This snapping used to exist in three copies — the preview drag gesture, the
/// SwiftUI placement pad, and the native placement pad. The preview and the
/// inspector must agree on which cell a point lands in, so the grid lives here
/// and both consume it.
///
/// Fractions are normalized and Y-down: the preview canvas and the (flipped)
/// placement pad share that convention.
enum PlacementMath {
    /// Normalized anchor for each placement, Y-down.
    static let fractions: [ProjectSettings.VideoPlacement: (x: CGFloat, y: CGFloat)] = [
        .topLeft: (0, 0), .top: (0.5, 0), .topRight: (1, 0),
        .left: (0, 0.5), .center: (0.5, 0.5), .right: (1, 0.5),
        .bottomLeft: (0, 1), .bottom: (0.5, 1), .bottomRight: (1, 1),
    ]

    /// Snaps a normalized coordinate onto one of the three grid fractions.
    static func snap(_ f: CGFloat) -> CGFloat { f < 1.0 / 3 ? 0 : (f > 2.0 / 3 ? 1 : 0.5) }

    /// Nearest of the nine placements for a normalized (Y-down) canvas point.
    static func nearest(fx: CGFloat, fy: CGFloat) -> ProjectSettings.VideoPlacement {
        let target = (x: snap(fx), y: snap(fy))
        return fractions.first { $0.value == target }?.key ?? .center
    }

    /// Grid-anchor magnetism for a freeform drop: within this distance of an
    /// anchor fraction (per axis), the drop collapses back to the clean enum —
    /// same feel as the camera's corner magnetism.
    static let magnetism: CGFloat = 0.05

    /// Whether the freeform (drag-anywhere) override is active.
    static func isCustom(_ settings: ProjectSettings) -> Bool {
        settings.videoCustomX != nil && settings.videoCustomY != nil
    }

    /// How far beyond the canvas a freeform card may travel: the centre can
    /// go a full canvas dimension past either edge — the card can sit
    /// completely off-screen ("allow me to place anywhere"). The old
    /// -0.4…1.4 kept a sliver pinned on-canvas, which read as the drag
    /// hitting an invisible wall. The bound exists only so a corrupt value
    /// cannot fling the card to infinity.
    static let customFractionRange: ClosedRange<CGFloat> = -1.0...2.0

    /// Freeform card origin. The fraction is the CARD CENTRE as a fraction of
    /// the canvas — (0.5, 0.5) is centred, 0/1 put the centre on an edge, and
    /// values outside 0…1 slide the card off the canvas. Centre semantics
    /// (rather than slack-relative alignment) are what make the drag track
    /// the pointer 1:1 and off-canvas placement expressible at all. Y-DOWN.
    static func customOrigin(
        fraction: (x: CGFloat, y: CGFloat),
        canvas: CGSize,
        video: CGSize
    ) -> CGPoint {
        CGPoint(
            x: canvas.width * fraction.x - video.width / 2,
            y: canvas.height * fraction.y - video.height / 2
        )
    }

    /// The effective alignment fractions (Y-DOWN, preview convention): the
    /// freeform override when set, else the placement enum's anchor.
    ///
    /// SINGLE SOURCE for both renderers — the preview reads it directly and
    /// the exporter flips Y (its content math is Y-up). Forking this per
    /// renderer is how the card ends up in two different places.
    static func alignment(for settings: ProjectSettings) -> (x: CGFloat, y: CGFloat) {
        if let x = settings.videoCustomX, let y = settings.videoCustomY {
            let range = customFractionRange
            return (
                min(range.upperBound, max(range.lowerBound, CGFloat(x))),
                min(range.upperBound, max(range.lowerBound, CGFloat(y)))
            )
        }
        return fractions[settings.videoPlacement] ?? (0.5, 0.5)
    }
}
