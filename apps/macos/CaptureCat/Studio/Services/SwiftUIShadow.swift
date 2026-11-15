import CoreGraphics

/// `CGContext` shadows configured the way SwiftUI's `.shadow(radius:y:)`
/// renders them.
///
/// Two things bite, both measured rather than assumed (see `--raster-golden`):
///
/// 1. **Radius is not blur.** SwiftUI's radius and `setShadow(blur:)` are
///    different parameterizations of a near-Gaussian kernel. Sweeping the
///    device bezel against its SwiftUI golden puts the L1 optimum at 2.2×,
///    consistently, with a shallow minimum either side.
/// 2. **Blur is in DEVICE PIXELS.** Unlike the offset, `setShadow`'s blur is
///    not transformed by the CTM. Sweeping at 1x/2x/3x moved the optimum in
///    exact proportion to the scale until the scale was folded in here.
enum SwiftUIShadow {
    static var blurFactor: CGFloat = 2.2

    /// Applies a SwiftUI-equivalent shadow to `ctx`. `dy` is positive-DOWN in
    /// the context's own space, matching SwiftUI's `y:`.
    static func apply(to ctx: CGContext, radius: CGFloat, dy: CGFloat, color: SRGBA) {
        let ctm = ctx.ctm
        let deviceScale = sqrt(abs(ctm.a * ctm.d - ctm.b * ctm.c))
        ctx.setShadow(
            offset: CGSize(width: 0, height: dy),
            blur: radius * blurFactor * deviceScale,
            color: color.cgColor
        )
    }
}
