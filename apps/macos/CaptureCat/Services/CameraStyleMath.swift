import AppKit
import CoreImage

/// Shared camera-bubble styling math — the single source of truth for the
/// color adjustments, filter presets, ring light, shape corner radius, and
/// name-tag layout that BOTH the preview compositor and the video exporter
/// consume. Nothing here may be duplicated on either side (CLAUDE.md §2):
/// the preview feeds pixel buffers / posters through `adjustedImage`, and the
/// exporter feeds its per-frame camera CIImage through the SAME function, so
/// the two paths cannot drift.
enum CameraStyleMath {

    // MARK: - Color adjustments + filter presets

    /// Snapshot of every setting that changes the camera's PIXELS (not its
    /// geometry). Value-typed and Equatable so the preview can cheap-compare
    /// per frame and skip the CI pass entirely at identity.
    struct Adjustments: Equatable {
        var brightness: Double   // −1…1, 0 = neutral
        var contrast: Double     // 0.5…1.5, 1 = neutral
        var saturation: Double   // 0…2, 1 = neutral
        var hue: Double          // −180…180 degrees, 0 = neutral
        var filter: ProjectSettings.CameraFilterStyle

        static let identity = Adjustments(
            brightness: 0, contrast: 1, saturation: 1, hue: 0, filter: .none
        )

        init(brightness: Double, contrast: Double, saturation: Double,
             hue: Double, filter: ProjectSettings.CameraFilterStyle) {
            self.brightness = brightness
            self.contrast = contrast
            self.saturation = saturation
            self.hue = hue
            self.filter = filter
        }

        init(settings s: ProjectSettings) {
            self.brightness = s.cameraBrightness
            self.contrast = s.cameraContrast
            self.saturation = s.cameraSaturation
            self.hue = s.cameraHue
            self.filter = s.cameraFilter
        }

        var isIdentity: Bool { self == .identity }
    }

    /// Warm/Cool presets are CITemperatureAndTint neutral-target deltas
    /// (input neutral stays 6500K; the target shifts it).
    private static let warmTargetNeutral = CIVector(x: 5100, y: 0)
    private static let coolTargetNeutral = CIVector(x: 8200, y: 0)

    /// Apply the preset filter + manual sliders to a camera image. The preset
    /// runs FIRST (it defines the base look), then the manual sliders refine
    /// it — so "Mono + warm brightness lift" behaves the way users expect.
    /// Identity adjustments return the input image unchanged (same object).
    static func adjustedImage(_ image: CIImage, adjustments a: Adjustments) -> CIImage {
        guard !a.isIdentity else { return image }
        var out = image

        switch a.filter {
        case .none:
            break
        case .mono:
            out = out.applyingFilter("CIPhotoEffectMono")
        case .noir:
            out = out.applyingFilter("CIPhotoEffectNoir")
        case .fade:
            out = out.applyingFilter("CIPhotoEffectFade")
        case .warm:
            out = out.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": warmTargetNeutral,
            ])
        case .cool:
            out = out.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": coolTargetNeutral,
            ])
        }

        if a.brightness != 0 || a.contrast != 1 || a.saturation != 1 {
            out = out.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: a.brightness,
                kCIInputContrastKey: a.contrast,
                kCIInputSaturationKey: a.saturation,
            ])
        }
        if a.hue != 0 {
            out = out.applyingFilter("CIHueAdjust", parameters: [
                kCIInputAngleKey: a.hue * .pi / 180,
            ])
        }
        // The filters can expand the extent to infinity (color fills);
        // pin it back to the source extent so downstream crops stay cheap.
        if out.extent.isInfinite { out = out.cropped(to: image.extent) }
        return out
    }

    // MARK: - Shape / corner radius

    /// Corner radius per shape, in the SAME units as `rect` (multiply by the
    /// pixel scale before calling for the exporter). Wires the user's
    /// `cameraCornerRadius` to the rounded-rect shape. The squircle is a true
    /// superellipse (see `superellipsePath`) and has no discrete radius.
    static func cornerRadius(
        shape: ProjectSettings.CameraShape, customRadius: Double, scale: CGFloat
    ) -> CGFloat {
        switch shape {
        case .roundedRect: return CGFloat(max(0, customRadius)) * scale
        case .circle, .square, .squircle: return 0
        }
    }

    /// Superellipse exponent for the squircle: |x/a|ⁿ + |y/b|ⁿ = 1. 4.5 gives
    /// the app-icon/TV-tile look — continuously curved corners whose curvature
    /// occupies roughly 40% of the short side, with no straight-then-arc seam.
    static let squircleExponent: Double = 4.5
    /// Parametric samples per full outline — high enough that the polyline is
    /// visually indistinguishable from the analytic curve at export sizes.
    static let squircleSamples = 256

    /// Analytic superellipse path inscribed in `rect`. Identical function for
    /// the preview's CAShapeLayer/mask path and the exporter's CG raster mask,
    /// so the outline cannot fork. Parametrization: x = a·sgn(cos t)|cos t|^(2/n),
    /// y = b·sgn(sin t)|sin t|^(2/n) — uniform in t, dense enough everywhere.
    static func superellipsePath(in rect: CGRect) -> CGPath {
        let a = Double(rect.width) / 2
        let b = Double(rect.height) / 2
        let cx = Double(rect.midX)
        let cy = Double(rect.midY)
        let exponent = 2.0 / squircleExponent
        let path = CGMutablePath()
        for i in 0..<squircleSamples {
            let t = Double(i) / Double(squircleSamples) * 2 * .pi
            let c = cos(t), s = sin(t)
            let x = cx + a * (c < 0 ? -1 : 1) * pow(abs(c), exponent)
            let y = cy + b * (s < 0 ? -1 : 1) * pow(abs(s), exponent)
            let p = CGPoint(x: x, y: y)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }

    /// The one clip path both renderers use for the camera bubble.
    static func clipPath(
        shape: ProjectSettings.CameraShape,
        customRadius: Double,
        rect: CGRect,
        scale: CGFloat
    ) -> CGPath {
        switch shape {
        case .circle:
            return CGPath(ellipseIn: rect, transform: nil)
        case .squircle:
            return superellipsePath(in: rect)
        case .roundedRect:
            let r = min(
                cornerRadius(shape: .roundedRect, customRadius: customRadius, scale: scale),
                min(rect.width, rect.height) / 2
            )
            guard r > 0 else { return CGPath(rect: rect, transform: nil) }
            return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
        case .square:
            return CGPath(rect: rect, transform: nil)
        }
    }

    // MARK: - Border

    /// Effective border stroke color: nil setting = the historical white 30%.
    static func borderNSColor(_ settings: ProjectSettings) -> NSColor {
        settings.cameraBorderColor?.nsColor ?? NSColor(white: 1, alpha: 0.3)
    }

    // MARK: - Ring light

    /// How far the glow extends OUTWARD from the bubble edge, as a fraction
    /// of the bubble's shorter side. Tight on purpose: the light should hug
    /// the shape, with most of its energy in the first half of this reach.
    static let ringOutsideFraction: CGFloat = 0.12
    /// Warm white, leaning toward 3200K tungsten — soft backlight, not neon.
    static let ringColor: (r: CGFloat, g: CGFloat, b: CGFloat) = (1.0, 0.93, 0.82)
    /// Approximate alpha at the rim at intensity 1, decaying smoothly to zero
    /// with no outer edge (the falloff is a real gaussian of the silhouette).
    static let ringPeakAlpha: CGFloat = 0.55
    /// Blur sigma as a fraction of the outward reach — ~⅓ keeps most of the
    /// energy in the first half of the padding and the tail invisible.
    static let ringSigmaFraction: CGFloat = 0.34

    /// One CIContext for the shared glow bake (both renderers call through
    /// here, so there is nothing renderer-specific about it).
    private static let ringCIContext = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
        .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
    ])

    /// Outward reach of the glow for a bubble of `size`, in the same units.
    /// Both renderers use this to place the (padded) ring raster around the
    /// bubble rect.
    static func ringPadding(for size: CGSize) -> CGFloat {
        min(size.width, size.height) * ringOutsideFraction
    }

    /// Deterministic raster of the OUTER glow. The bitmap is `size` plus
    /// `ringPadding` on every side; the bubble's shape sits centered and a
    /// soft backlight hugs its outside — the interior is fully clear (the
    /// video is never washed). Both sides consume this SAME recipe (preview
    /// as layer contents, exporter as a CIImage), so the falloff cannot fork.
    /// The drawing is symmetric on both axes for every camera shape, so CG/CI
    /// orientation is a non-issue.
    ///
    /// Recipe: the shape's filled silhouette is gaussian-blurred (a true
    /// diffusion — brightest immediately at the rim, monotone smooth decay,
    /// NO band structure or traceable outer edge), then the interior is
    /// clipped away. Intensity scales the opacity and, gently, the spread.
    static func ringImage(
        size: CGSize,
        shape: ProjectSettings.CameraShape,
        customRadius: Double,
        intensity: Double,
        scale: CGFloat
    ) -> CGImage? {
        let level = min(1, max(0, intensity))
        guard level > 0, size.width >= 2, size.height >= 2 else { return nil }
        let pad = ringPadding(for: size)
        let padded = CGSize(width: size.width + 2 * pad, height: size.height + 2 * pad)
        let pxW = Int(ceil(padded.width * scale))
        let pxH = Int(ceil(padded.height * scale))
        guard pxW > 0, pxH > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        let bubbleRect = CGRect(x: pad, y: pad, width: size.width, height: size.height)
        let path = clipPath(shape: shape, customRadius: customRadius, rect: bubbleRect, scale: 1)

        // 1. Warm silhouette of the shape at full alpha.
        guard let silCtx = CGContext(
            data: nil, width: pxW, height: pxH,
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        silCtx.scaleBy(x: scale, y: scale)
        silCtx.addPath(path)
        silCtx.setFillColor(CGColor(
            srgbRed: ringColor.r, green: ringColor.g, blue: ringColor.b, alpha: 1
        ))
        silCtx.fillPath()
        guard let silhouette = silCtx.makeImage() else { return nil }

        // 2. Gaussian diffusion. Intensity nudges the spread a little (a
        // brighter light leaks slightly further), but the reach never exceeds
        // the padding, so the tail dies inside the raster with no hard cut.
        let sigma = pad * ringSigmaFraction * (0.8 + 0.4 * CGFloat(level)) * scale
        let blurred = CIImage(cgImage: silhouette)
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: sigma])
            .cropped(to: CGRect(x: 0, y: 0, width: pxW, height: pxH))
        guard let blurredCG = ringCIContext.createCGImage(blurred, from: blurred.extent) else {
            return nil
        }

        // 3. Keep only the OUTSIDE of the shape (even-odd clip) and scale the
        // whole diffusion so the rim lands at ≈ ringPeakAlpha × intensity.
        // (A gaussian of a half-plane edge sits at 0.5 exactly on the edge,
        // hence the ×2.)
        guard let outCtx = CGContext(
            data: nil, width: pxW, height: pxH,
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        outCtx.scaleBy(x: scale, y: scale)
        outCtx.addRect(CGRect(origin: .zero, size: padded))
        outCtx.addPath(path)
        outCtx.clip(using: .evenOdd)
        outCtx.setAlpha(min(1, 2 * ringPeakAlpha * CGFloat(level)))
        outCtx.draw(blurredCG, in: CGRect(origin: .zero, size: padded))
        return outCtx.makeImage()
    }

    // MARK: - Name tag

    /// Tag typography/geometry constants — all proportional to bubble width
    /// so the tag rides the zoom envelope with the bubble.
    static let tagFontFraction: CGFloat = 0.115      // main line font ÷ bubble width
    static let tagSubtextFontScale: CGFloat = 0.78   // subtext font ÷ main font
    static let tagHPaddingFactor: CGFloat = 0.9      // ÷ main font size
    static let tagVPaddingFactor: CGFloat = 0.42     // ÷ main font size
    static let tagGapFactor: CGFloat = 0.35          // bubble↔pill gap ÷ pill height

    struct TagLayout {
        /// Pill size in the same units as the bubble width fed in.
        var pillSize: CGSize
        var fontSize: CGFloat
        var subFontSize: CGFloat
    }

    private static func tagFont(named name: String?, size: CGFloat) -> NSFont {
        if let name, let custom = NSFont(name: name, size: size) { return custom }
        return NSFont.systemFont(ofSize: size, weight: .semibold)
    }

    /// Measure the pill for the given settings at a bubble width. Nil when the
    /// tag text is empty (the tag is hidden entirely).
    static func tagLayout(settings s: ProjectSettings, bubbleWidth: CGFloat) -> TagLayout? {
        let text = s.cameraTagText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, bubbleWidth > 8 else { return nil }
        let fontSize = max(8, bubbleWidth * tagFontFraction)
        let subSize = max(7, fontSize * tagSubtextFontScale)
        let sub = s.cameraTagSubtext.trimmingCharacters(in: .whitespacesAndNewlines)

        let main = NSAttributedString(
            string: text, attributes: [.font: tagFont(named: s.cameraTagFontName, size: fontSize)]
        )
        var textW = ceil(main.size().width)
        var textH = ceil(main.size().height)
        if !sub.isEmpty {
            let subLine = NSAttributedString(
                string: sub, attributes: [.font: tagFont(named: s.cameraTagFontName, size: subSize)]
            )
            textW = max(textW, ceil(subLine.size().width))
            textH += ceil(subLine.size().height)
        }
        let hPad = fontSize * tagHPaddingFactor
        let vPad = fontSize * tagVPaddingFactor
        // Cap the pill so a long name never dwarfs the bubble.
        let maxW = bubbleWidth * 2.2
        return TagLayout(
            pillSize: CGSize(width: min(textW + 2 * hPad, maxW), height: textH + 2 * vPad),
            fontSize: fontSize,
            subFontSize: subSize
        )
    }

    /// Where the pill sits relative to the bubble rect, in the SAME coordinate
    /// space as `bubbleRect`. Centered horizontally; vertical placement per
    /// the position enum. `yAxisIsUp` = true for the exporter's CI space.
    static func tagRect(
        bubbleRect: CGRect,
        pillSize: CGSize,
        position: ProjectSettings.CameraTagPosition,
        yAxisIsUp: Bool
    ) -> CGRect {
        let x = bubbleRect.midX - pillSize.width / 2
        let gap = pillSize.height * tagGapFactor
        let y: CGFloat
        switch position {
        case .below:
            y = yAxisIsUp ? bubbleRect.minY - gap - pillSize.height
                          : bubbleRect.maxY + gap
        case .above:
            y = yAxisIsUp ? bubbleRect.maxY + gap
                          : bubbleRect.minY - gap - pillSize.height
        case .overlapBottom:
            y = yAxisIsUp ? bubbleRect.minY - pillSize.height / 2
                          : bubbleRect.maxY - pillSize.height / 2
        }
        return CGRect(x: x, y: y, width: pillSize.width, height: pillSize.height)
    }

    /// Rasterize the tag pill (rounded pill background + one or two centered
    /// text lines) at `scale` px per unit. One recipe for both sides: the
    /// preview shows it as NSImage layer contents, the exporter as a CIImage.
    /// Returns the bitmap plus the pill size in layout units.
    static func tagBitmap(
        settings s: ProjectSettings,
        bubbleWidth: CGFloat,
        scale: CGFloat
    ) -> (image: CGImage, pillSize: CGSize)? {
        guard let layout = tagLayout(settings: s, bubbleWidth: bubbleWidth) else { return nil }
        let pill = layout.pillSize
        let pxW = Int(ceil(pill.width * scale))
        let pxH = Int(ceil(pill.height * scale))
        guard pxW > 0, pxH > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil, width: pxW, height: pxH,
                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        ctx.scaleBy(x: scale, y: scale)

        let rect = CGRect(origin: .zero, size: pill)
        let radius = pill.height / 2
        let bg = s.cameraTagBackgroundColor.nsColor.usingColorSpace(.sRGB) ?? .black
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setFillColor(CGColor(
            srgbRed: bg.redComponent, green: bg.greenComponent,
            blue: bg.blueComponent, alpha: bg.alphaComponent
        ))
        ctx.fillPath()

        // Text via NSGraphicsContext (unflipped — CG bottom-up, which is what
        // both NSImage layer contents and CIImage(cgImage:) expect upright).
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns

        let textColor = s.cameraTagTextColor.nsColor
        let para = NSMutableParagraphStyle()
        para.alignment = .center

        let text = s.cameraTagText.trimmingCharacters(in: .whitespacesAndNewlines)
        let sub = s.cameraTagSubtext.trimmingCharacters(in: .whitespacesAndNewlines)
        let mainLine = NSAttributedString(string: text, attributes: [
            .font: tagFont(named: s.cameraTagFontName, size: layout.fontSize),
            .foregroundColor: textColor,
            .paragraphStyle: para,
        ])
        let subLine: NSAttributedString? = sub.isEmpty ? nil : NSAttributedString(
            string: sub, attributes: [
                .font: tagFont(named: s.cameraTagFontName, size: layout.subFontSize),
                .foregroundColor: textColor.withAlphaComponent(textColor.alphaComponent * 0.75),
                .paragraphStyle: para,
            ]
        )
        let mainH = ceil(mainLine.size().height)
        let subH = subLine.map { ceil($0.size().height) } ?? 0
        let totalH = mainH + subH
        let topY = (pill.height + totalH) / 2   // Y-up: top edge of the text block
        let inset = layout.fontSize * 0.3
        // Main line sits above the subtext (Y-up drawing).
        mainLine.draw(in: CGRect(x: inset, y: topY - mainH, width: pill.width - 2 * inset, height: mainH))
        if let subLine {
            subLine.draw(in: CGRect(x: inset, y: topY - mainH - subH, width: pill.width - 2 * inset, height: subH))
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let image = ctx.makeImage() else { return nil }
        return (image, pill)
    }
}
