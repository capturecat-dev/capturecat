import CoreGraphics
import Foundation

/// Depth Focus — the shared blur PROFILE both renderers consume. Inside the
/// focus shape the blur is 0; outside it ramps to full intensity with a
/// smoothstep over a falloff band. Two shapes:
///  - `.area`: rounded-rect signed distance from the region's edge;
///  - `.tiltShift`: perpendicular distance from a band through the rect's
///    centre at `angle` degrees (sharp band width = the rect's SHORT side).
///
/// The intensity→radius mapping lives HERE ONLY (house rule: CIGaussianBlur's
/// inputRadius is a sigma ≈ half a SwiftUI/CG blur radius), and the mask both
/// renderers feed to CIMaskedVariableBlur is rendered by the ONE
/// `maskImage(...)` below — preview and export cannot fork.
enum FocusMath {
    /// Default corner rounding, normalized 0…1 of HALF the rect's short side
    /// (0 = sharp, 1 = capsule). 0.24 reproduces the original fixed look of
    /// 12% of the short side — existing regions decode to this and render
    /// byte-identically.
    static let defaultCornerRadius: Double = 0.24
    /// Falloff band width, fraction of min(video dims): falloff 0 → hard-ish
    /// edge, 1 → dreamy wide ramp.
    static let minBandFraction: CGFloat = 0.02
    static let maxBandFraction: CGFloat = 0.35
    /// SwiftUI-style blur radius at intensity 1, fraction of min(video dims).
    static let maxBlurRadiusFraction: CGFloat = 0.09
    /// Mask raster resolution (long side): the mask is a smooth gradient, so
    /// a modest raster upscaled by CI is indistinguishable and cheap.
    static let maskResolution = 384

    /// Falloff band width in video units.
    static func bandWidth(falloff: Double, videoSize: CGSize) -> CGFloat {
        let f = CGFloat(max(0, min(1, falloff)))
        return (minBandFraction + f * (maxBandFraction - minBandFraction))
            * min(videoSize.width, videoSize.height)
    }

    /// Max blur as a SwiftUI/CG-style radius in video units.
    static func blurRadius(intensity: Double, videoSize: CGSize) -> CGFloat {
        CGFloat(max(0, min(1, intensity))) * maxBlurRadiusFraction
            * min(videoSize.width, videoSize.height)
    }

    /// The CI sigma for that radius — the ONLY place the ≈half convention
    /// is applied for Depth Focus.
    static func blurSigma(intensity: Double, videoSize: CGSize) -> CGFloat {
        blurRadius(intensity: intensity, videoSize: videoSize) / 2
    }

    /// Normalized blur amount 0…1 at `unitPoint` (unit video space, Y-down,
    /// top-left origin — the region-rect convention). 0 = sharp, 1 = full
    /// blur. Distances are evaluated in absolute video units via `videoSize`
    /// so the profile is aspect-correct.
    static func blurAmount(
        at unitPoint: CGPoint,
        regionRect: CGRect,
        style: FocusRegionStyle,
        angleDegrees: Double,
        falloff: Double,
        cornerRadius: Double = defaultCornerRadius,
        videoSize: CGSize
    ) -> CGFloat {
        let p = CGPoint(x: unitPoint.x * videoSize.width,
                        y: unitPoint.y * videoSize.height)
        let r = CGRect(x: regionRect.minX * videoSize.width,
                       y: regionRect.minY * videoSize.height,
                       width: regionRect.width * videoSize.width,
                       height: regionRect.height * videoSize.height)
        let d: CGFloat
        switch style {
        case .area:
            let corner = CGFloat(max(0, min(1, cornerRadius)))
                * min(r.width, r.height) / 2
            d = roundedRectOutsideDistance(p, rect: r, cornerRadius: corner)
        case .tiltShift:
            let c = CGPoint(x: r.midX, y: r.midY)
            let a = angleDegrees * .pi / 180
            // Band runs along (cos a, sin a) in Y-down space; distance is
            // measured along the perpendicular. Sharp half-width = the rect's
            // short dimension / 2.
            let nx = -sin(a), ny = cos(a)
            let dist = abs((p.x - c.x) * CGFloat(nx) + (p.y - c.y) * CGFloat(ny))
            d = dist - min(r.width, r.height) / 2
        }
        guard d > 0 else { return 0 }
        let band = max(0.0001, bandWidth(falloff: falloff, videoSize: videoSize))
        let t = min(1, d / band)
        return t * t * (3 - 2 * t) // smoothstep 0→1 across the band
    }

    /// Distance OUTSIDE a rounded rect (0 inside or on the edge).
    static func roundedRectOutsideDistance(
        _ p: CGPoint, rect: CGRect, cornerRadius: CGFloat
    ) -> CGFloat {
        let r = max(0, min(cornerRadius, min(rect.width, rect.height) / 2))
        let inner = rect.insetBy(dx: r, dy: r)
        let dx = max(inner.minX - p.x, 0, p.x - inner.maxX)
        let dy = max(inner.minY - p.y, 0, p.y - inner.maxY)
        let d = CGFloat(hypot(dx, dy)) - r
        return max(0, d)
    }

    /// The graduated blur MASK (white = full blur, black = sharp) for a
    /// region over the full video frame. Rendered ONCE per region parameters
    /// and cached by callers; both renderers scale this SAME image to their
    /// video rect and feed CIMaskedVariableBlur. Row 0 of the raster is the
    /// video's TOP — the single Y orientation decision for this mask lives
    /// HERE (unit space is Y-down; CGImage rows read top-down).
    static func maskImage(
        regionRect: CGRect,
        style: FocusRegionStyle,
        angleDegrees: Double,
        falloff: Double,
        cornerRadius: Double = defaultCornerRadius,
        videoSize: CGSize
    ) -> CGImage? {
        guard videoSize.width > 1, videoSize.height > 1 else { return nil }
        let aspect = videoSize.height / videoSize.width
        let nx: Int
        let ny: Int
        if aspect <= 1 {
            nx = maskResolution
            ny = max(2, Int((CGFloat(maskResolution) * aspect).rounded()))
        } else {
            ny = maskResolution
            nx = max(2, Int((CGFloat(maskResolution) / aspect).rounded()))
        }
        var pixels = [UInt8](repeating: 0, count: nx * ny)
        for j in 0..<ny {
            let uy = (CGFloat(j) + 0.5) / CGFloat(ny) // row 0 = video top
            for i in 0..<nx {
                let ux = (CGFloat(i) + 0.5) / CGFloat(nx)
                let amount = blurAmount(
                    at: CGPoint(x: ux, y: uy),
                    regionRect: regionRect,
                    style: style,
                    angleDegrees: angleDegrees,
                    falloff: falloff,
                    cornerRadius: cornerRadius,
                    videoSize: videoSize)
                pixels[j * nx + i] = UInt8(max(0, min(255, (amount * 255).rounded())))
            }
        }
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData),
              let gray = CGColorSpace(name: CGColorSpace.linearGray)
        else { return nil }
        return CGImage(
            width: nx, height: ny, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: nx, space: gray,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true,
            intent: .defaultIntent)
    }
}
