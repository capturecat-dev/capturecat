import CoreGraphics

/// The preview canvas's background gradient, in pure CoreGraphics.
///
/// # Why this is not a `CAGradientLayer`
///
/// `CAGradientLayer` blends its stops in gamma-encoded sRGB; SwiftUI blends in
/// Oklab, and the two disagree by up to ~30/255 mid-ramp on saturated pairs —
/// which is why this gradient used to be rasterized by SwiftUI rather than
/// drawn natively. The fix is not to avoid CoreGraphics but to feed it the
/// right ramp: see `OklabGradient`.
enum BackgroundGradientRenderer {
    /// Axis of the ramp, in SwiftUI `UnitPoint` terms.
    enum Axis: Equatable {
        /// `.topLeading` → `.bottomTrailing`
        case diagonal
        /// `.top` → `.bottom`
        case vertical
        /// CSS-style angle in degrees: 0° = bottom→top, 90° = left→right,
        /// 180° = top→bottom. The gradient line spans the rect so the ramp
        /// starts and ends exactly at the farthest corners (like CSS).
        case angle(Double)
    }

    /// Draws the ramp into an existing (y-up) context over `rect`.
    static func draw(in ctx: CGContext, rect: CGRect, start: SRGBA, end: SRGBA, axis: Axis) {
        guard rect.width > 0, rect.height > 0 else { return }
        guard let gradient = OklabGradient.gradient(from: start, to: end) else {
            ctx.setFillColor(start.cgColor)
            ctx.fill(rect)
            return
        }
        // UnitPoints are y-DOWN; the context is y-UP.
        let p0: CGPoint, p1: CGPoint
        switch axis {
        case .diagonal:
            p0 = CGPoint(x: rect.minX, y: rect.maxY)
            p1 = CGPoint(x: rect.maxX, y: rect.minY)
        case .vertical:
            p0 = CGPoint(x: rect.midX, y: rect.maxY)
            p1 = CGPoint(x: rect.midX, y: rect.minY)
        case .angle(let degrees):
            // Unit direction in y-UP space (0° points up).
            let theta = degrees * .pi / 180
            let d = CGPoint(x: sin(theta), y: cos(theta))
            let length = abs(rect.width * d.x) + abs(rect.height * d.y)
            let c = CGPoint(x: rect.midX, y: rect.midY)
            p0 = CGPoint(x: c.x - d.x * length / 2, y: c.y - d.y * length / 2)
            p1 = CGPoint(x: c.x + d.x * length / 2, y: c.y + d.y * length / 2)
        }
        ctx.drawLinearGradient(
            gradient, start: p0, end: p1,
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }

    /// A standalone bitmap of the ramp, for use as `CALayer.contents`.
    static func image(start: SRGBA, end: SRGBA, size: CGSize, axis: Axis, scale: CGFloat) -> CGImage? {
        let w = Int((size.width * scale).rounded()), h = Int((size.height * scale).rounded())
        guard w > 0, h > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }
        draw(in: ctx, rect: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)),
             start: start, end: end, axis: axis)
        return ctx.makeImage()
    }
}
