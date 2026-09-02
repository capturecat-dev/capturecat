import CoreImage
import Foundation
import CoreGraphics
import ImageIO

/// The backdrop behind the video card — base fill PLUS the "look" the user
/// dials in (gradient angle, blur, brightness, saturation, tint, vignette).
///
/// # One renderer, two consumers
///
/// The preview compositor sets the result as `CALayer.contents`; the exporter
/// wraps it in a `CIImage`. Both call `cgImage(for:size:scale:)`, so the
/// styled backdrop is *literally the same bitmap* on both sides — the
/// preview==export invariant for the background rests on this file, not on
/// two filter chains kept in sync by hand.
///
/// Sizes are canvas points; `scale` is the backing scale. Every look
/// parameter that has a pixel unit (blur sigma, vignette radius) is derived
/// from the *pixel* size, so a 2× preview and a 1× export agree
/// proportionally.
enum BackgroundLook {
    struct Spec: Equatable {
        var type: ProjectSettings.BackgroundType
        var gradientStart: SRGBA
        var gradientEnd: SRGBA
        /// nil = legacy topLeading→bottomTrailing diagonal.
        var gradientAngle: Double?
        var solid: SRGBA
        var imagePath: String?
        var blur: Double
        var brightness: Double
        var saturation: Double
        var tint: SRGBA
        var tintOpacity: Double
        var vignette: Double
        var pixelate: Double
        var halftone: Double
        var noise: Double
        var contrast: Double
        var hue: Double

        init(_ s: ProjectSettings) {
            type = s.backgroundType
            gradientStart = SRGBA(s.gradientStartColor)
            gradientEnd = SRGBA(s.gradientEndColor)
            gradientAngle = s.gradientAngle
            solid = SRGBA(s.solidColor)
            imagePath = s.backgroundImagePath
            blur = s.backgroundBlur
            brightness = s.backgroundBrightness
            saturation = s.backgroundSaturation
            tint = SRGBA(s.backgroundTintColor)
            tintOpacity = s.backgroundTintOpacity
            vignette = s.backgroundVignette
            pixelate = s.backgroundPixelate
            halftone = s.backgroundHalftone
            noise = s.backgroundNoise
            contrast = s.backgroundContrast
            hue = s.backgroundHue
        }

        /// True when no look adjustment is active — the base fill is used
        /// untouched (and old projects render exactly as before).
        var isPlainLook: Bool {
            noise <= 0 && isPlainLookExceptNoise
        }

        /// Grain runs as a CG post-pass, so a grain-only look can still skip
        /// the CoreImage round trip.
        var isPlainLookExceptNoise: Bool {
            blur <= 0 && abs(brightness) < 0.0005 && abs(saturation - 1) < 0.0005
                && tintOpacity <= 0 && vignette <= 0
                && pixelate <= 0 && halftone <= 0
                && abs(contrast - 1) < 0.0005 && abs(hue) < 0.0005
        }

        var cacheKey: String {
            "\(type.rawValue)|\(gradientStart)|\(gradientEnd)|\(gradientAngle.map { "\($0)" } ?? "diag")|\(solid)|\(imagePath ?? "")|\(blur)|\(brightness)|\(saturation)|\(tint)|\(tintOpacity)|\(vignette)|\(pixelate)|\(halftone)|\(noise)|\(contrast)|\(hue)"
        }
    }

    /// Largest edge the source image is decoded at. Covers a 4K export; the
    /// preview uses the SAME decode so both sides see identical pixels.
    static let maxImageEdge = 4096

    /// Blur strength 0…1 → Gaussian sigma in pixels, as a fraction of the
    /// shorter canvas edge (1.0 ≈ a heavily frosted backdrop).
    static func blurSigma(_ blur: Double, pixelSize: CGSize) -> Double {
        max(0, min(1, blur)) * 0.06 * Double(min(pixelSize.width, pixelSize.height))
    }

    // MARK: - Rendering

    private static let context = CIContext(options: [
        .cacheIntermediates: false,
        .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    ])

    private static let imageCache = NSCache<NSString, CGImage>()

    /// The styled backdrop as a bitmap of `size × scale` pixels. nil for the
    /// transparent type (nothing to draw).
    static func cgImage(for spec: Spec, size: CGSize, scale: CGFloat) -> CGImage? {
        guard spec.type != .transparent else { return nil }
        let pixelSize = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        guard pixelSize.width > 0, pixelSize.height > 0 else { return nil }
        let rect = CGRect(origin: .zero, size: pixelSize)

        // Fast path: a plain look that is already a CGImage stays one — no
        // CoreImage round trip, so untouched projects keep their old bytes.
        if spec.isPlainLook, let base = baseCGImage(for: spec, pixelSize: pixelSize) {
            return base
        }
        var out: CGImage?
        if spec.isPlainLookExceptNoise, let base = baseCGImage(for: spec, pixelSize: pixelSize) {
            out = base
        } else {
            let image = styled(base: baseCIImage(for: spec, pixelSize: pixelSize), spec: spec, pixelSize: pixelSize)
            out = context.createCGImage(
                image, from: rect, format: .BGRA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
            )
        }
        if spec.noise > 0, let img = out {
            out = grained(img, amount: spec.noise, scale: scale)
        }
        return out
    }

    /// Fine paper grain (Mike's mesh reference, 2026-09-02), applied on the
    /// finished gamma-space bitmap — NOT a CIFilter: CI composites in linear
    /// light, which made the amplitude luminance-dependent and ~4× stronger
    /// than requested. The value is hashed from the pixel's 1×-grid
    /// coordinate, so a 2× preview and a 1× export show the IDENTICAL grain
    /// pattern (each 1× cell covers a scale² block), and every render of the
    /// same canvas is byte-identical — no shimmer across frames or scrubs.
    /// Unit noise field for one virtual row, cached — the hash is the hot
    /// part of the grain pass, and it depends only on geometry, never on the
    /// amount, so slider drags reuse it wholesale.
    private static var noiseRowCache: (key: String, rows: [[Float]])?
    /// The cache is hit from the preview's detached render tasks and the
    /// exporter's queue concurrently.
    private static let noiseLock = NSLock()

    private static func noiseRows(width: Int, height: Int, cell: Int) -> [[Float]] {
        let key = "\(width)x\(height)/\(cell)"
        noiseLock.lock()
        let hit = noiseRowCache
        noiseLock.unlock()
        if let hit, hit.key == key { return hit.rows }
        let vw = (width + cell - 1) / cell
        let vh = (height + cell - 1) / cell
        var rows = [[Float]](repeating: [], count: vh)
        for vy in 0..<vh {
            var row = [Float](repeating: 0, count: vw)
            for vx in 0..<vw {
                // SplitMix-style scramble of the virtual coordinate.
                var v = UInt64(vx) &* 0x9E3779B97F4A7C15 ^ UInt64(vy) &* 0xBF58476D1CE4E5B9
                v ^= v >> 30; v = v &* 0x94D049BB133111EB; v ^= v >> 27
                row[vx] = Float(v & 0xFFFF) / 65535 * 2 - 1
            }
            rows[vy] = row
        }
        noiseLock.lock()
        noiseRowCache = (key, rows)
        noiseLock.unlock()
        return rows
    }

    private static func grained(_ image: CGImage, amount: Double, scale: CGFloat) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = makeContext(CGSize(width: w, height: h)),
              let data = ctx.data.map({ $0.assumingMemoryBound(to: UInt8.self) }) ?? nil
        else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // ±14/255 at full slider — std ≈ 8/255, the reference's visibility.
        let amplitude = Float(max(0, min(1, amount)) * 14.5)
        let bpr = ctx.bytesPerRow
        let s = max(1, Int(scale.rounded()))
        let rows = noiseRows(width: w, height: h, cell: s)
        for y in 0..<h {
            let row = data + y * bpr
            let noise = rows[y / s]
            for x in 0..<w {
                let delta = Int(noise[x / s] * amplitude)
                let p = row + x * 4
                // BGRA little-endian premultipliedFirst: B,G,R at 0,1,2.
                p[0] = UInt8(max(0, min(255, Int(p[0]) + delta)))
                p[1] = UInt8(max(0, min(255, Int(p[1]) + delta)))
                p[2] = UInt8(max(0, min(255, Int(p[2]) + delta)))
            }
        }
        return ctx.makeImage()
    }

    /// The exporter's form of the same bitmap, in y-up CI space.
    static func ciImage(for spec: Spec, size: CGSize) -> CIImage {
        let rect = CGRect(origin: .zero, size: size)
        guard let cg = cgImage(for: spec, size: size, scale: 1) else {
            return CIImage(color: .clear).cropped(to: rect)
        }
        return CIImage(cgImage: cg).cropped(to: rect)
    }

    // MARK: - Base fill

    /// Gradient and placeholder ramps come straight from CoreGraphics (Oklab
    /// ramp — see BackgroundGradientRenderer). Solid and image fills return
    /// nil here and are built as CIImages instead.
    private static func baseCGImage(for spec: Spec, pixelSize: CGSize) -> CGImage? {
        switch spec.type {
        case .gradient:
            return BackgroundGradientRenderer.image(
                start: spec.gradientStart, end: spec.gradientEnd,
                size: pixelSize, axis: gradientAxis(spec), scale: 1)
        case .mesh:
            return meshImage(start: spec.gradientStart, end: spec.gradientEnd, pixelSize: pixelSize)
        case .solid:
            return solidImage(spec.solid, pixelSize: pixelSize)
        case .image, .wallpaper:
            if let path = spec.imagePath, let src = decodedImage(path: path) {
                return aspectFill(src, pixelSize: pixelSize)
            }
            if spec.type == .wallpaper {
                return BackgroundGradientRenderer.image(
                    start: SRGBA(white: 0.16), end: SRGBA(white: 0.09),
                    size: pixelSize, axis: .vertical, scale: 1)
            }
            return solidImage(SRGBA(white: 0), pixelSize: pixelSize)
        case .transparent:
            return nil
        }
    }

    private static func baseCIImage(for spec: Spec, pixelSize: CGSize) -> CIImage {
        let rect = CGRect(origin: .zero, size: pixelSize)
        if let cg = baseCGImage(for: spec, pixelSize: pixelSize) {
            return CIImage(cgImage: cg).cropped(to: rect)
        }
        return CIImage(color: .black).cropped(to: rect)
    }

    static func gradientAxis(_ spec: Spec) -> BackgroundGradientRenderer.Axis {
        spec.gradientAngle.map { .angle($0) } ?? .diagonal
    }

    /// Soft mesh gradient: the base ramp with deterministic radial pools of
    /// Oklab blends breathing through it — the "aurora" backdrop of the
    /// grainy-gradient aesthetic. Anchors are fixed unit-space fractions, so
    /// the same two colours always produce the same mesh at any resolution
    /// (and the preview/export bitmaps agree).
    private static func meshImage(start: SRGBA, end: SRGBA, pixelSize: CGSize) -> CGImage? {
        guard let ctx = makeContext(pixelSize) else { return nil }
        let rect = CGRect(origin: .zero, size: pixelSize)
        BackgroundGradientRenderer.draw(in: ctx, rect: rect, start: start, end: end, axis: .diagonal)

        func ramp(_ t: CGFloat) -> SRGBA { OklabGradient.mix(start, end, t) }
        let mid = ramp(0.5)
        // One gentle lift and one sink; every other pool colour sits ON the
        // start→end ramp. Off-ramp (whitened) pool colours compounded into a
        // full-canvas pastel wash — measured +80/255 against the base ramp.
        let lift = OklabGradient.mix(mid, SRGBA(white: 1), 0.18)
        let sink = OklabGradient.mix(mid, SRGBA(white: 0), 0.3)
        // (cx, cy, radius as fraction of the SHORTER edge, colour, peak
        // alpha). Radii off the min edge — diagonal-sized pools each covered
        // the whole canvas.
        let pools: [(Double, Double, Double, SRGBA, Double)] = [
            (0.18, 0.20, 0.85, ramp(0.15), 0.45),
            (0.85, 0.12, 0.75, ramp(0.85), 0.45),
            (0.50, 0.55, 0.80, lift, 0.15),
            (0.15, 0.85, 0.75, sink, 0.45),
            (0.88, 0.82, 0.80, ramp(0.65), 0.45),
            (0.60, 0.32, 0.45, mid, 0.25),
        ]
        let minEdge = min(pixelSize.width, pixelSize.height)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        for (fx, fy, fr, color, alpha) in pools {
            // Radial fade colour→clear, eased by intermediate stops so the
            // pools have no visible rim.
            let stops: [(CGFloat, CGFloat)] = [(0, 1), (0.4, 0.7), (0.75, 0.25), (1, 0)]
            let colors = stops.map { color.cgColor.copy(alpha: $0.1 * alpha)! } as CFArray
            guard let grad = CGGradient(
                colorsSpace: space, colors: colors,
                locations: stops.map(\.0)
            ) else { continue }
            let center = CGPoint(x: fx * pixelSize.width, y: (1 - fy) * pixelSize.height)
            ctx.drawRadialGradient(
                grad, startCenter: center, startRadius: 0,
                endCenter: center, endRadius: fr * minEdge,
                options: [])
        }
        return ctx.makeImage()
    }

    private static func solidImage(_ color: SRGBA, pixelSize: CGSize) -> CGImage? {
        guard let ctx = makeContext(pixelSize) else { return nil }
        ctx.setFillColor(color.cgColor)
        ctx.fill(CGRect(origin: .zero, size: pixelSize))
        return ctx.makeImage()
    }

    /// Scale-to-fill, centred — `contentsGravity = .resizeAspectFill` and the
    /// exporter's `max(scaleX, scaleY)` transform, done once, identically.
    private static func aspectFill(_ src: CGImage, pixelSize: CGSize) -> CGImage? {
        guard let ctx = makeContext(pixelSize) else { return nil }
        let sw = CGFloat(src.width), sh = CGFloat(src.height)
        let scale = max(pixelSize.width / sw, pixelSize.height / sh)
        let w = sw * scale, h = sh * scale
        ctx.interpolationQuality = .high
        ctx.draw(src, in: CGRect(x: (pixelSize.width - w) / 2, y: (pixelSize.height - h) / 2, width: w, height: h))
        return ctx.makeImage()
    }

    private static func makeContext(_ pixelSize: CGSize) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(
            data: nil, width: Int(pixelSize.width), height: Int(pixelSize.height),
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    /// One decode per path (orientation applied, capped at `maxImageEdge`).
    static func decodedImage(path: String) -> CGImage? {
        if let hit = imageCache.object(forKey: path as NSString) { return hit }
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxImageEdge,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        imageCache.setObject(img, forKey: path as NSString)
        return img
    }

    // MARK: - Look

    /// Mosaic block edge in pixels for `pixelate` 0…1 (fraction of the
    /// shorter canvas edge, so preview and export agree proportionally).
    static func pixelateScale(_ v: Double, pixelSize: CGSize) -> Double {
        max(0, min(1, v)) * 0.08 * Double(min(pixelSize.width, pixelSize.height))
    }

    /// Halftone cell width in pixels for `halftone` 0…1.
    static func halftoneWidth(_ v: Double, pixelSize: CGSize) -> Double {
        (2 + max(0, min(1, v)) * 0.04 * Double(min(pixelSize.width, pixelSize.height)))
    }

    /// pixelate → halftone → blur → brightness/contrast/saturation → hue →
    /// tint → grain → vignette. Order is part of the contract; both
    /// consumers get it from here.
    static func styled(base: CIImage, spec: Spec, pixelSize: CGSize) -> CIImage {
        let rect = CGRect(origin: .zero, size: pixelSize)
        var img = base

        let block = pixelateScale(spec.pixelate, pixelSize: pixelSize)
        if block >= 1 {
            img = img.clampedToExtent()
                .applyingFilter("CIPixellate", parameters: [
                    kCIInputCenterKey: CIVector(x: 0, y: 0),
                    kCIInputScaleKey: block,
                ])
                .cropped(to: rect)
        }

        if spec.halftone > 0 {
            img = img.clampedToExtent()
                .applyingFilter("CIDotScreen", parameters: [
                    kCIInputCenterKey: CIVector(x: 0, y: 0),
                    kCIInputAngleKey: 0,
                    kCIInputWidthKey: halftoneWidth(spec.halftone, pixelSize: pixelSize),
                    kCIInputSharpnessKey: 0.7,
                ])
                .cropped(to: rect)
        }

        let sigma = blurSigma(spec.blur, pixelSize: pixelSize)
        if sigma > 0.01 {
            // Clamp first so the edges stay filled instead of fading to clear.
            img = img.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: sigma])
                .cropped(to: rect)
        }

        if abs(spec.brightness) >= 0.0005 || abs(spec.saturation - 1) >= 0.0005
            || abs(spec.contrast - 1) >= 0.0005 {
            img = img.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: spec.brightness,
                kCIInputSaturationKey: spec.saturation,
                kCIInputContrastKey: spec.contrast,
            ])
        }

        if abs(spec.hue) >= 0.0005 {
            img = img.applyingFilter("CIHueAdjust", parameters: [
                kCIInputAngleKey: spec.hue * .pi / 180,
            ])
        }

        if spec.tintOpacity > 0 {
            let t = spec.tint
            let tint = CIImage(color: CIColor(
                red: t.red, green: t.green, blue: t.blue,
                alpha: t.alpha * CGFloat(max(0, min(1, spec.tintOpacity)))
            )).cropped(to: rect)
            img = tint.composited(over: img)
        }

        if spec.vignette > 0 {
            let v: CGFloat = CGFloat(max(0, min(1, spec.vignette)))
            let radius: CGFloat = hypot(rect.width, rect.height) * 0.5 * (1.1 - 0.5 * v)
            img = img.applyingFilter("CIVignetteEffect", parameters: [
                kCIInputCenterKey: CIVector(x: rect.midX, y: rect.midY),
                kCIInputRadiusKey: radius,
                kCIInputIntensityKey: v,
                "inputFalloff": 0.5,
            ])
        }

        return img.cropped(to: rect)
    }
}
