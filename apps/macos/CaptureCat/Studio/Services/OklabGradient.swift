import CoreGraphics

/// An sRGB colour with straight (un-premultiplied) alpha — the currency every
/// native gradient in the app is expressed in.
struct SRGBA: Equatable, Sendable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var alpha: CGFloat

    init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }

    init(white: CGFloat, alpha: CGFloat = 1) {
        self.init(red: white, green: white, blue: white, alpha: alpha)
    }

    init(_ c: CodableColor) {
        self.init(red: c.red, green: c.green, blue: c.blue, alpha: c.opacity)
    }

    var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

/// Gradient ramps that land on the same pixels SwiftUI's `LinearGradient`
/// does.
///
/// # Why not just hand CoreGraphics the two end colours
///
/// SwiftUI interpolates gradient stops in **Oklab**, a perceptually uniform
/// space — NOT in gamma-encoded sRGB (what `CAGradientLayer` and a naive
/// `CGGradient` do) and NOT in linear light. The three disagree badly: a
/// black→white ramp reads 128 mid-way in gamma sRGB, 188 in linear light, and
/// **99** in Oklab. On saturated complements the spread is worse still. This
/// was measured directly out of `ImageRenderer`, and Oklab reproduces every
/// sample to ±1/255.
///
/// CoreGraphics can only interpolate linearly inside one colour space, so the
/// Oklab curve is pre-sampled into a dense sRGB stop table (`resolution`
/// steps). The residual chord error of that piecewise-linear approximation is
/// ~0.09/255 at 128 steps and scales with 1/n² — far below the point where it
/// could show up in a raster.
enum OklabGradient {
    /// Stops per gradient. 256 puts the approximation error ~0.02/255.
    static let resolution = 256

    // MARK: - Public

    /// A `CGGradient` in sRGB whose ramp follows SwiftUI's Oklab
    /// interpolation. `stops` must be sorted by location.
    static func gradient(stops: [(location: CGFloat, color: SRGBA)]) -> CGGradient? {
        guard stops.count >= 2,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var colors: [CGColor] = []
        var locations: [CGFloat] = []
        colors.reserveCapacity(resolution + 1)
        locations.reserveCapacity(resolution + 1)
        for i in 0...resolution {
            let t = CGFloat(i) / CGFloat(resolution)
            locations.append(t)
            colors.append(sample(stops, at: t).cgColor)
        }
        return CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)
    }

    static func gradient(from: SRGBA, to: SRGBA) -> CGGradient? {
        gradient(stops: [(0, from), (1, to)])
    }

    /// The colour SwiftUI would show at `t` along the ramp.
    static func sample(_ stops: [(location: CGFloat, color: SRGBA)], at t: CGFloat) -> SRGBA {
        guard let first = stops.first, let last = stops.last else {
            return SRGBA(white: 0, alpha: 0)
        }
        if t <= first.location { return first.color }
        if t >= last.location { return last.color }
        for i in 0..<(stops.count - 1) {
            let a = stops[i], b = stops[i + 1]
            guard t >= a.location, t <= b.location else { continue }
            let span = b.location - a.location
            let local = span > 0 ? (t - a.location) / span : 0
            return mix(a.color, b.color, local)
        }
        return last.color
    }

    /// Perceptual (Oklab) blend of two sRGB colours.
    ///
    /// The Lab coordinates are weighted by ALPHA as well as by `t` — i.e. the
    /// mix happens premultiplied in Oklab and is divided back out — and alpha
    /// itself travels linearly. Measured against SwiftUI on a 1.0→0.4 ramp:
    /// straight (unweighted) Oklab is 41/255 off, premultiplying in sRGB is
    /// 11/255 off, this is 2/255 off (i.e. dither). With equal alphas it
    /// reduces to the plain Oklab lerp.
    static func mix(_ a: SRGBA, _ b: SRGBA, _ t: CGFloat) -> SRGBA {
        let alpha = a.alpha + (b.alpha - a.alpha) * t
        let wa = a.alpha * (1 - t), wb = b.alpha * t
        let sum = wa + wb
        guard sum > 0 else { return SRGBA(white: 0, alpha: 0) }
        let la = oklab(a), lb = oklab(b)
        let lab = (
            (la.0 * wa + lb.0 * wb) / sum,
            (la.1 * wa + lb.1 * wb) / sum,
            (la.2 * wa + lb.2 * wb) / sum
        )
        var out = srgb(lab)
        out.alpha = alpha
        return out
    }

    // MARK: - Oklab

    static func linearize(_ c: CGFloat) -> CGFloat {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    static func encode(_ c: CGFloat) -> CGFloat {
        let v = max(0, min(1, c))
        return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    private static func cbrt(_ x: CGFloat) -> CGFloat {
        x < 0 ? -pow(-x, 1.0 / 3.0) : pow(x, 1.0 / 3.0)
    }

    /// sRGB → Oklab (Björn Ottosson's matrices).
    static func oklab(_ c: SRGBA) -> (CGFloat, CGFloat, CGFloat) {
        let r = linearize(c.red), g = linearize(c.green), b = linearize(c.blue)
        let l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
        let m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
        let s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
        let l_ = cbrt(l), m_ = cbrt(m), s_ = cbrt(s)
        return (
            0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
            1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
            0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
        )
    }

    /// Oklab → sRGB (alpha untouched — the caller sets it).
    static func srgb(_ lab: (CGFloat, CGFloat, CGFloat)) -> SRGBA {
        let l_ = lab.0 + 0.3963377774 * lab.1 + 0.2158037573 * lab.2
        let m_ = lab.0 - 0.1055613458 * lab.1 - 0.0638541728 * lab.2
        let s_ = lab.0 - 0.0894841775 * lab.1 - 1.2914855480 * lab.2
        let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
        return SRGBA(
            red: encode(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
            green: encode(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
            blue: encode(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
        )
    }
}
