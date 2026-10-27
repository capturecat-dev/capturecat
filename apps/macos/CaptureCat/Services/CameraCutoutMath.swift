import CoreGraphics
import Foundation

/// Geometry of the two camera LOOKS — Cutout and Pop-out card
/// (docs/camera-cutout.md §3). The Swift original; the web's TS port is
/// locked to it by the `cameraCutoutGeometry` golden-vector unit.
///
/// Shared source of truth (house rule #2): the preview compositor and the
/// exporter both feed `geometry` the bubble rect `B` they already have (from
/// ReactiveCameraLayout, or CameraLayoutMath's mid-morph `cameraRect`) and draw
/// exactly what comes back. Everything is stated Y-DOWN; the exporter asks for
/// `yAxisIsUp: true`, which is the same geometry flipped about B (the card
/// keeps the BOTTOM of B and gives up its TOP — the headroom the head rises
/// into — in both spaces).
enum CameraCutoutMath {
    /// Headroom above the pop-out card, as a fraction of B's height.
    static let headroomFraction: CGFloat = 0.22
    /// Card corner radius, as a fraction of the card's shorter side.
    static let cardCornerFraction: CGFloat = 0.16
    /// Card gradient, sRGB, top → bottom (vertical, linear in sRGB values).
    static let cardTopColor: (r: CGFloat, g: CGFloat, b: CGFloat) = (1.00, 0.58, 0.34)
    static let cardBottomColor: (r: CGFloat, g: CGFloat, b: CGFloat) = (0.42, 0.33, 0.96)
    /// The card's shadow IS the bubble's shadow: radius 6 × sizeFactor at
    /// opacity 0.33 (CALayer terms). Export terms (what the web matches):
    /// black at alpha 0.45 through the card's rounded rect, CIGaussianBlur
    /// σ = 6 × canvasScale × B.width / baseRect.width, no offset, cropped to
    /// the card outset by 4σ + 4.
    static let cardShadowRadius: CGFloat = 6
    static let cardShadowOpacity: Float = 0.33
    static let cardShadowExportAlpha: CGFloat = 0.45

    struct Geometry: Equatable {
        /// The camera image scaled to cover B, centred (aspect-fill). The
        /// mask is scaled to exactly this rect.
        var personRect: CGRect
        /// Where the person is clipped: always B.
        var clipRect: CGRect
        /// Rounding of the clip's two BOTTOM corners (pop-out); 0 = square.
        var clipBottomCornerRadius: CGFloat
        /// The pop-out card (nil for the cutout).
        var cardRect: CGRect?
        /// The card's corner radius (all four corners; 0 for the cutout).
        var cardCornerRadius: CGFloat
    }

    /// `aspectFill(a, B)`: the camera image scaled to cover B, centred —
    /// EXACTLY the exporter's `compositeCamera` fill with camExtent =
    /// (0, 0, a, 1): fillScale = max(B.width / a, B.height / 1), size
    /// (a·fillScale, fillScale), origin (B.minX − (w − B.width)/2,
    /// B.minY − (h − B.height)/2). No guards — a degenerate aspect gives the
    /// same non-finite numbers on both platforms (the vectors cover it).
    static func aspectFill(aspect: Double, in b: CGRect) -> CGRect {
        let a = CGFloat(aspect)
        let fillScale = max(b.width / a, b.height / 1)
        let w = a * fillScale
        let h = 1 * fillScale
        return CGRect(x: b.minX - (w - b.width) / 2, y: b.minY - (h - b.height) / 2, width: w, height: h)
    }

    static func geometry(
        look: CameraBubbleLook,
        bubbleRect b: CGRect,
        cameraAspect: Double,
        yAxisIsUp: Bool = false
    ) -> Geometry {
        let person = aspectFill(aspect: cameraAspect, in: b)
        switch look {
        case .cutout:
            return Geometry(personRect: person, clipRect: b, clipBottomCornerRadius: 0,
                            cardRect: nil, cardCornerRadius: 0)
        case .popOut:
            let headroom = headroomFraction * b.height
            // Y-down: the TOP edge (minY) moves down. Y-up: the top is maxY,
            // so the card keeps minY and loses the headroom off its height.
            let card = CGRect(
                x: b.minX,
                y: yAxisIsUp ? b.minY : b.minY + headroom,
                width: b.width,
                height: b.height - headroom)
            let r = cardCornerFraction * min(card.width, card.height)
            return Geometry(personRect: person, clipRect: b, clipBottomCornerRadius: r,
                            cardRect: card, cardCornerRadius: r)
        }
    }

    /// The pop-out person clip as a path: the rounded rect over
    /// `personClipMaskRect` (B extended up by r). Intersected with B — the
    /// person never draws outside B — only the BOTTOM corners are rounded.
    static func personClipPath(_ g: Geometry, yAxisIsUp: Bool) -> CGPath {
        let rect = personClipMaskRect(g, yAxisIsUp: yAxisIsUp)
        let r = min(max(0, g.clipBottomCornerRadius), min(rect.width, rect.height) / 2)
        return r > 0
            ? CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
            : CGPath(rect: rect, transform: nil)
    }

    /// The card's rounded rect (nil for the cutout).
    static func cardPath(_ g: Geometry) -> CGPath? {
        guard let card = g.cardRect, card.width > 0, card.height > 0 else { return nil }
        let r = min(max(0, g.cardCornerRadius), min(card.width, card.height) / 2)
        return r > 0
            ? CGPath(roundedRect: card, cornerWidth: r, cornerHeight: r, transform: nil)
            : CGPath(rect: card, transform: nil)
    }

    /// The pop-out person clip's mask rect: B extended UP by r (so the
    /// rounded-rect generator's TOP corners fall outside B and only the
    /// bottom two round once it is cropped back to B). Y-down: y − r,
    /// height + r; Y-up: height + r.
    static func personClipMaskRect(_ g: Geometry, yAxisIsUp: Bool) -> CGRect {
        let b = g.clipRect
        let r = g.clipBottomCornerRadius
        return yAxisIsUp
            ? CGRect(x: b.minX, y: b.minY, width: b.width, height: b.height + r)
            : CGRect(x: b.minX, y: b.minY - r, width: b.width, height: b.height + r)
    }

    /// Bubble-shadow size factor for a look drawn at `rect`: B.width ÷ the
    /// base bubble's width — how the exporter's baked bubble shadow scales
    /// with the bubble (contract §3), and the preview bubble's `sizeFactor`.
    static func sizeFactor(rect: CGRect, baseWidth: CGFloat) -> CGFloat {
        baseWidth > 0 ? rect.width / baseWidth : 1
    }
}
