#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Attributed-string text for the CG renderers. The attribute keys
/// (`.font`, `.foregroundColor`, …), `size()`, `boundingRect` and `draw(in:)`
/// are declared by AppKit/UIKit, so studio code builds, measures and draws
/// text through here. On the Mac each helper is the exact AppKit expression
/// its caller used inline.
enum PlatformText {
    /// `NSAttributedString(string: string, attributes: [.font: font])`
    static func string(_ string: String, font: PlatformFont) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: font])
    }

    /// `attributed.size()` — on iOS, AppKit's measurement (AppKitTextLayout).
    static func size(of attributed: NSAttributedString) -> CGSize {
        #if canImport(AppKit)
        return attributed.size()
        #else
        return AppKitTextLayout.size(of: attributed, platformWidth: attributed.size().width)
        #endif
    }

    /// `font.ascender` — on iOS, the Mac's ascender (AppKitTextLayout).
    static func ascender(of font: PlatformFont) -> CGFloat {
        #if canImport(AppKit)
        return font.ascender
        #else
        return AppKitTextLayout.metrics(of: font as CTFont).ascent
        #endif
    }

    /// A copy of `attributed` with an sRGB `.foregroundColor` over its whole
    /// length (AnnotationRenderer.TextLine).
    static func colored(_ attributed: NSAttributedString, _ color: SRGBA) -> NSAttributedString {
        let colored = NSMutableAttributedString(attributedString: attributed)
        #if canImport(AppKit)
        colored.addAttribute(
            .foregroundColor,
            value: NSColor(srgbRed: color.red, green: color.green,
                           blue: color.blue, alpha: color.alpha),
            range: NSRange(location: 0, length: colored.length)
        )
        #else
        // UIColor(red:green:blue:alpha:) is sRGB.
        colored.addAttribute(
            .foregroundColor,
            value: UIColor(red: color.red, green: color.green,
                           blue: color.blue, alpha: color.alpha),
            range: NSRange(location: 0, length: colored.length)
        )
        #endif
        return colored
    }

    /// The laid-out bounds of `attributed` wrapped to `size`:
    /// `boundingRect(with: size, options: [.usesLineFragmentOrigin, .usesFontLeading])`.
    static func boundingRect(of attributed: NSAttributedString, size: CGSize) -> CGRect {
        #if canImport(AppKit)
        return attributed.boundingRect(
            with: size,
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        #else
        let platform = attributed.boundingRect(
            with: size,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        return AppKitTextLayout.boundingRect(of: attributed, size: size, platformWidth: platform.width)
        #endif
    }

    /// Draws `attributed` into `rect` of a y-UP CGContext, glyphs upright —
    /// AppKit's unflipped NSGraphicsContext over the CG context.
    static func draw(_ attributed: NSAttributedString, in rect: CGRect, of ctx: CGContext) {
        #if canImport(AppKit)
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.current = nsCtx
        attributed.draw(in: rect)
        NSGraphicsContext.current = nil
        #else
        // AppKit's layout (AppKitTextLayout), drawn with CoreText — glyphs
        // upright in the y-up context, baselines where the Mac puts them.
        AppKitTextLayout.draw(attributed, in: rect, of: ctx)
        #endif
    }

    /// `CTLineGetTypographicBounds(line, &ascent, &descent, nil)` — on iOS with
    /// the Mac's system-face metrics (AppKitTextLayout).
    static func typographicBounds(_ line: CTLine) -> (width: CGFloat, ascent: CGFloat, descent: CGFloat) {
        #if canImport(AppKit)
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        return (width, ascent, descent)
        #else
        return AppKitTextLayout.typographicBounds(line)
        #endif
    }

    /// The keyboard-shortcut pill's text run (KeystrokeOverlayRenderer):
    /// system semibold at 17·size·scale, white, kerned 1.2·size·scale.
    static func keystrokePill(_ text: String, size: Double, scale: CGFloat) -> NSAttributedString {
        #if canImport(AppKit)
        let font = NSFont.systemFont(ofSize: 17 * CGFloat(size) * scale, weight: .semibold)
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.white,
            .kern: 1.2 * CGFloat(size) * scale,
        ])
        return attributed
        #else
        let font = UIFont.systemFont(ofSize: 17 * CGFloat(size) * scale, weight: .semibold)
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: UIColor.white,
            .kern: 1.2 * CGFloat(size) * scale,
        ])
        return attributed
        #endif
    }
}
