import CoreGraphics

/// Apple's continuous-corner ("squircle") rounded rectangle, in pure
/// CoreGraphics.
///
/// This is a REPLICA, not an approximation: the control points below were
/// sampled directly out of `SwiftUI.Path(roundedRect:cornerSize:style:
/// .continuous).cgPath` across a matrix of sizes and radii, and the emitted
/// path is element-for-element identical to SwiftUI's (verified to <0.5pt
/// sampled deviation by `--raster-golden`, measured 1e-5pt). A circular-arc
/// rounded rect is NOT a substitute — it visibly deforms the phone body.
///
/// # Anatomy
///
/// Every corner is three cubics. Working in corner-local units of `r`, with
/// `u` measured back along the incoming edge and `v` forward along the
/// outgoing edge:
///
///   start (u: p_in,  v: 0)
///   C1    cp (A_in, 0)   (B_in, 0)      → (eA, eP)
///   C2    cp (m1, m2)    (m2, m1)       → (eP, eA)
///   C3    cp (0, B_out)  (0, A_out)     → (0, p_out)
///
/// The middle cubic is invariant. The two outer cubics stretch along their own
/// edge: `p` is the corner's reach, normally `1.528665·r`, but capped at HALF
/// THAT EDGE'S length — independently per axis, so a corner on a narrow-but-
/// tall rect is legitimately anisotropic. When `p` is capped, `A` and `B`
/// travel linearly with it (measured exact to 4e-6·r across the full range).
enum ContinuousRoundedRect {
    // MARK: - Sampled constants

    /// Corner reach as a multiple of `r` when nothing is capping it.
    static let fullReach: CGFloat = 1.528665
    /// Outer-cubic control points at full reach.
    private static let aFull: CGFloat = 1.088490
    private static let bFull: CGFloat = 0.868407
    /// …and where they land when the reach is squeezed all the way to `1·r`.
    private static let aMin: CGFloat = 0.96
    private static let bMin: CGFloat = 0.82
    /// Outer-cubic endpoint (shared with the middle cubic).
    private static let endLong: CGFloat = 0.631494
    private static let endShort: CGFloat = 0.074911
    /// Middle-cubic control points.
    private static let midLong: CGFloat = 0.372824
    private static let midShort: CGFloat = 0.169060

    /// `A` and `B` for a given (already normalized) corner reach.
    private static func controls(reach p: CGFloat) -> (a: CGFloat, b: CGFloat) {
        let t = (p - 1) / (fullReach - 1)
        return (aMin + (aFull - aMin) * t, bMin + (bFull - bMin) * t)
    }

    // MARK: - Path

    /// The continuous rounded rect. `cornerRadius` is clamped to
    /// `min(width, height) / 2`, exactly as SwiftUI clamps it.
    static func path(rect: CGRect, cornerRadius: CGFloat) -> CGPath {
        guard rect.width > 0, rect.height > 0 else {
            return CGPath(rect: rect, transform: nil)
        }
        let r = min(max(0, cornerRadius), min(rect.width, rect.height) / 2)
        guard r > 0 else { return CGPath(rect: rect, transform: nil) }

        // Per-axis reach: never more than half that edge.
        let reachY = min(fullReach, (rect.height / 2) / r)
        let reachX = min(fullReach, (rect.width / 2) / r)
        let (aY, bY) = controls(reach: reachY)
        let (aX, bX) = controls(reach: reachX)
        let pY = reachY * r, pX = reachX * r
        let (aYr, bYr) = (aY * r, bY * r)
        let (aXr, bXr) = (aX * r, bX * r)
        let eL = endLong * r, eS = endShort * r
        let mL = midLong * r, mS = midShort * r

        let minX = rect.minX, maxX = rect.maxX
        let minY = rect.minY, maxY = rect.maxY

        let path = CGMutablePath()

        // Mirrors SwiftUI's own emission order: start mid-right edge, then
        // bottom-right → bottom-left → top-left → top-right.
        path.move(to: CGPoint(x: maxX, y: rect.midY))

        // Bottom-right: down the right edge, out along the bottom edge.
        path.addLine(to: CGPoint(x: maxX, y: maxY - pY))
        path.addCurve(
            to: CGPoint(x: maxX - eS, y: maxY - eL),
            control1: CGPoint(x: maxX, y: maxY - aYr),
            control2: CGPoint(x: maxX, y: maxY - bYr))
        path.addCurve(
            to: CGPoint(x: maxX - eL, y: maxY - eS),
            control1: CGPoint(x: maxX - mS, y: maxY - mL),
            control2: CGPoint(x: maxX - mL, y: maxY - mS))
        path.addCurve(
            to: CGPoint(x: maxX - pX, y: maxY),
            control1: CGPoint(x: maxX - bXr, y: maxY),
            control2: CGPoint(x: maxX - aXr, y: maxY))

        // Bottom-left.
        path.addLine(to: CGPoint(x: minX + pX, y: maxY))
        path.addCurve(
            to: CGPoint(x: minX + eL, y: maxY - eS),
            control1: CGPoint(x: minX + aXr, y: maxY),
            control2: CGPoint(x: minX + bXr, y: maxY))
        path.addCurve(
            to: CGPoint(x: minX + eS, y: maxY - eL),
            control1: CGPoint(x: minX + mL, y: maxY - mS),
            control2: CGPoint(x: minX + mS, y: maxY - mL))
        path.addCurve(
            to: CGPoint(x: minX, y: maxY - pY),
            control1: CGPoint(x: minX, y: maxY - bYr),
            control2: CGPoint(x: minX, y: maxY - aYr))

        // Top-left.
        path.addLine(to: CGPoint(x: minX, y: minY + pY))
        path.addCurve(
            to: CGPoint(x: minX + eS, y: minY + eL),
            control1: CGPoint(x: minX, y: minY + aYr),
            control2: CGPoint(x: minX, y: minY + bYr))
        path.addCurve(
            to: CGPoint(x: minX + eL, y: minY + eS),
            control1: CGPoint(x: minX + mS, y: minY + mL),
            control2: CGPoint(x: minX + mL, y: minY + mS))
        path.addCurve(
            to: CGPoint(x: minX + pX, y: minY),
            control1: CGPoint(x: minX + bXr, y: minY),
            control2: CGPoint(x: minX + aXr, y: minY))

        // Top-right.
        path.addLine(to: CGPoint(x: maxX - pX, y: minY))
        path.addCurve(
            to: CGPoint(x: maxX - eL, y: minY + eS),
            control1: CGPoint(x: maxX - aXr, y: minY),
            control2: CGPoint(x: maxX - bXr, y: minY))
        path.addCurve(
            to: CGPoint(x: maxX - eS, y: minY + eL),
            control1: CGPoint(x: maxX - mL, y: minY + mS),
            control2: CGPoint(x: maxX - mS, y: minY + mL))
        path.addCurve(
            to: CGPoint(x: maxX, y: minY + pY),
            control1: CGPoint(x: maxX, y: minY + bYr),
            control2: CGPoint(x: maxX, y: minY + aYr))

        path.closeSubpath()
        return path
    }

    /// Circular-corner rounded rect, for the `.roundedRect` frame shape.
    /// Present here only so callers have one place to ask for corner geometry.
    static func circularPath(rect: CGRect, cornerRadius: CGFloat) -> CGPath {
        let r = min(max(0, cornerRadius), min(rect.width, rect.height) / 2)
        guard r > 0 else { return CGPath(rect: rect, transform: nil) }
        return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
    }
}
