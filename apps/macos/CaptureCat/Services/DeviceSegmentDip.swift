import CoreGraphics
import Foundation

/// The Keynote dip across a device-segment cut — shared by the preview
/// compositor and the exporter.
///
/// The framing switches INSTANTLY at the boundary (morphing the mask would
/// expose the source's pillarboxed in-between frame), and the whole card eases
/// down in scale and opacity across the cut, the way Apple hides a hard content
/// swap.
///
/// Two properties carry the entire effect, and both are easy to lose in a port:
///
/// - It is centred **on** the boundary, so the dip is already at its deepest at
///   the instant the content swaps. A ramp that *starts* at the cut plays the
///   swap at full opacity, and the pop is completely visible — which is exactly
///   what "the transition is not smooth" looks like.
/// - It is a **Gaussian**, so its slope is zero at the peak. A piecewise
///   ease-in-out ramps up and then reverses through a corner, and that
///   derivative discontinuity reads as a kick at the trough.
///
/// It is a pure function of the **timeline** clock — never a wall clock — so
/// playback, scrubbing and export all agree (CLAUDE.md §2). Evaluating it per
/// rendered frame also means it needs no timer, no start-time bookkeeping and
/// no "did the segment index just change" edge detection.
enum DeviceSegmentDip {
    /// Half-width of the dip, in timeline seconds.
    static let sigma: TimeInterval = 0.15
    /// How much of the card's scale is given up at full dip.
    static let scaleDrop: CGFloat = 0.05
    /// How much of the card's opacity is given up at full dip.
    static let opacityDrop: CGFloat = 0.55

    /// 0 = undipped, 1 = fully dipped.
    ///
    /// `boundaries` are device-segment edge times; the two sides derive them
    /// from differently-shaped structures (the preview walks `sourceSegments`,
    /// the exporter its baked `segmentDeviceAssets.ranges`), so the lookup
    /// stays local and only the *curve* is shared.
    static func phase(at time: TimeInterval, boundaries: [TimeInterval]) -> Double {
        var g = 0.0
        for boundary in boundaries {
            let d = (time - boundary) / sigma
            g = max(g, exp(-d * d))
        }
        return min(1, g)
    }

    static func scale(_ phase: Double) -> CGFloat { 1 - scaleDrop * CGFloat(phase) }
    static func opacity(_ phase: Double) -> CGFloat { 1 - opacityDrop * CGFloat(phase) }
}
