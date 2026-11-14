#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

// MARK: - Subtitle rasterizer (exporter-identical recipe at 1× canvas scale)

/// The preview compositor's subtitle pill raster. The Mac branch is the
/// compositor's original NSAttributedString / NSGraphicsContext code,
/// verbatim (its deviceRGB context is what the goldens encode); the iOS
/// branch draws the same recipe through UIKit.
enum SubtitlePillRasterizer {
    struct Result { var image: PlatformImage; var pillSize: CGSize }

    /// Renders the subtitle pill + text + shadow/glow into a bitmap using
    /// the SAME NSAttributedString recipe as VideoExporter.renderSubtitle
    /// (canvasScale = 1). The bitmap has uniform slack around the pill for
    /// the shadow/glow spill.
    static func render(
        subtitle: SubtitleSegment,
        settings s: ProjectSettings,
        currentTime: TimeInterval,
        maxWidth: CGFloat,
        scale: CGFloat
    ) -> Result? {
        #if canImport(AppKit)
        let font = FontCatalog.font(named: s.subtitleFontName, size: max(1, s.subtitleFontSize), weight: s.subtitleWeight.nsWeight)
        let transform: (String) -> String = s.subtitleUppercase ? { $0.uppercased() } : { $0 }
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let textColor = s.subtitleColor.nsColor

        let attrString: NSAttributedString
        if s.highlightWords && !subtitle.words.isEmpty {
            let highlightColor = s.subtitleHighlightColor.nsColor
            let dimColor = textColor.withAlphaComponent(textColor.alphaComponent * 0.4)
            let spaceAttrs: [NSAttributedString.Key: Any] = [
                .font: font, .paragraphStyle: paragraphStyle, .foregroundColor: textColor,
            ]
            let mutable = NSMutableAttributedString()
            for (i, word) in subtitle.words.enumerated() {
                if i > 0 { mutable.append(NSAttributedString(string: " ", attributes: spaceAttrs)) }
                let isActive = currentTime >= word.startTime
                mutable.append(NSAttributedString(
                    string: transform(word.text),
                    attributes: [.font: font, .paragraphStyle: paragraphStyle,
                                 .foregroundColor: isActive ? highlightColor : dimColor]
                ))
            }
            attrString = mutable
        } else {
            attrString = NSAttributedString(
                string: transform(subtitle.text),
                attributes: [.font: font, .paragraphStyle: paragraphStyle, .foregroundColor: textColor]
            )
        }

        let textSize = attrString.boundingRect(
            with: CGSize(width: max(1, maxWidth), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let pillW = ceil(textSize.width) + 24  // 12pt horizontal padding
        let pillH = ceil(textSize.height) + 12 // 6pt vertical padding
        let slack: CGFloat = s.subtitleStyle == .glow ? 24 : 10
        let imgW = pillW + slack * 2
        let imgH = pillH + slack * 2

        // Rasterise into an EXPLICIT context rather than `NSImage.lockFocus`.
        //
        // lockFocus rasterises at the current SCREEN's backing scale, while the
        // shadow radii below are in device pixels and were hard-coded `* 2` —
        // i.e. the glow was only correct on a Retina display, and drew at half
        // strength on a 1x external monitor. It also made this gate score the
        // desk rather than the renderer.
        let pxW = Int((imgW * scale).rounded()), pxH = Int((imgH * scale).rounded())
        // deviceRGB, not sRGB: this replaced `NSImage.lockFocus`, which used
        // the device space, and the goldens encode that. Using sRGB here shifts
        // the glow by ~8/255.
        guard pxW > 0, pxH > 0,
              let ctx = CGContext(
                  data: nil, width: pxW, height: pxH, bitsPerComponent: 8, bytesPerRow: 0,
                  space: NSColorSpace.deviceRGB.cgColorSpace ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }
        ctx.scaleBy(x: scale, y: scale)

        let nsContext = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext
        defer { NSGraphicsContext.restoreGraphicsState() }

        // Shadow/glow — mirrors preview .shadow(): outline = black r2,
        // glow = text color at 0.8 r6. `setShadow` blur is in DEVICE pixels and
        // is not transformed by the CTM, so it carries the scale explicitly.
        switch s.subtitleStyle {
        case .outline:
            ctx.setShadow(offset: .zero, blur: 2 * scale, color: NSColor.black.cgColor)
        case .glow:
            ctx.setShadow(offset: .zero, blur: 6 * scale,
                          color: textColor.withAlphaComponent(0.8 * textColor.alphaComponent).cgColor)
        case .background, .plain:
            break
        }

        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        if s.subtitleStyle == .background {
            let bg = s.subtitleBackgroundColor.nsColor.withAlphaComponent(0.75)
            ctx.setFillColor(bg.cgColor)
            let pillRect = CGRect(x: slack, y: slack, width: pillW, height: pillH)
            ctx.addPath(CGPath(roundedRect: pillRect, cornerWidth: 6, cornerHeight: 6, transform: nil))
            ctx.fillPath()
        }
        attrString.draw(in: CGRect(x: slack + 12, y: slack + 6, width: textSize.width, height: textSize.height))
        ctx.endTransparencyLayer()

        guard let cg = ctx.makeImage() else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: imgW, height: imgH))
        return Result(image: image, pillSize: CGSize(width: pillW, height: pillH))
        #else
        let font = FontCatalog.font(named: s.subtitleFontName, size: max(1, s.subtitleFontSize), weight: s.subtitleWeight.nsWeight)
        let transform: (String) -> String = s.subtitleUppercase ? { $0.uppercased() } : { $0 }
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        // UIColor(red:green:blue:alpha:) is sRGB, like CodableColor.nsColor.
        let opacity = s.subtitleColor.opacity
        let textColor = UIColor(red: s.subtitleColor.red, green: s.subtitleColor.green,
                                blue: s.subtitleColor.blue, alpha: opacity)

        let attrString: NSAttributedString
        if s.highlightWords && !subtitle.words.isEmpty {
            let h = s.subtitleHighlightColor
            let highlightColor = UIColor(red: h.red, green: h.green, blue: h.blue, alpha: h.opacity)
            let dimColor = textColor.withAlphaComponent(opacity * 0.4)
            let spaceAttrs: [NSAttributedString.Key: Any] = [
                .font: font, .paragraphStyle: paragraphStyle, .foregroundColor: textColor,
            ]
            let mutable = NSMutableAttributedString()
            for (i, word) in subtitle.words.enumerated() {
                if i > 0 { mutable.append(NSAttributedString(string: " ", attributes: spaceAttrs)) }
                let isActive = currentTime >= word.startTime
                mutable.append(NSAttributedString(
                    string: transform(word.text),
                    attributes: [.font: font, .paragraphStyle: paragraphStyle,
                                 .foregroundColor: isActive ? highlightColor : dimColor]
                ))
            }
            attrString = mutable
        } else {
            attrString = NSAttributedString(
                string: transform(subtitle.text),
                attributes: [.font: font, .paragraphStyle: paragraphStyle, .foregroundColor: textColor]
            )
        }

        let textSize = attrString.boundingRect(
            with: CGSize(width: max(1, maxWidth), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        let pillW = ceil(textSize.width) + 24  // 12pt horizontal padding
        let pillH = ceil(textSize.height) + 12 // 6pt vertical padding
        let slack: CGFloat = s.subtitleStyle == .glow ? 24 : 10
        let imgW = pillW + slack * 2
        let imgH = pillH + slack * 2

        let pxW = Int((imgW * scale).rounded()), pxH = Int((imgH * scale).rounded())
        guard pxW > 0, pxH > 0,
              let ctx = CGContext(
                  data: nil, width: pxW, height: pxH, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }
        ctx.scaleBy(x: scale, y: scale)

        switch s.subtitleStyle {
        case .outline:
            ctx.setShadow(offset: .zero, blur: 2 * scale, color: UIColor.black.cgColor)
        case .glow:
            ctx.setShadow(offset: .zero, blur: 6 * scale,
                          color: textColor.withAlphaComponent(0.8 * opacity).cgColor)
        case .background, .plain:
            break
        }

        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        if s.subtitleStyle == .background {
            let b = s.subtitleBackgroundColor
            let bg = UIColor(red: b.red, green: b.green, blue: b.blue, alpha: b.opacity)
                .withAlphaComponent(0.75)
            ctx.setFillColor(bg.cgColor)
            let pillRect = CGRect(x: slack, y: slack, width: pillW, height: pillH)
            ctx.addPath(CGPath(roundedRect: pillRect, cornerWidth: 6, cornerHeight: 6, transform: nil))
            ctx.fillPath()
        }
        // The context is y-up, like the Mac's unflipped NSGraphicsContext.
        PlatformText.draw(
            attrString,
            in: CGRect(x: slack + 12, y: slack + 6, width: textSize.width, height: textSize.height),
            of: ctx)
        ctx.endTransparencyLayer()

        guard let cg = ctx.makeImage() else { return nil }
        let image = LayerContents.image(cg, size: CGSize(width: imgW, height: imgH))
        return Result(image: image, pillSize: CGSize(width: pillW, height: pillH))
        #endif
    }
}
