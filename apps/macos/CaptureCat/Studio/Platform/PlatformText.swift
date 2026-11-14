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

    /// `attributed.size()`
    static func size(of attributed: NSAttributedString) -> CGSize {
        attributed.size()
    }

    /// `font.ascender`
    static func ascender(of font: PlatformFont) -> CGFloat {
        font.ascender
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
        return attributed.boundingRect(
            with: size,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
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
        // UIKit draws y-down: mirror the context about the rect's horizontal
        // centre line so the rect maps onto itself with its top edge at maxY.
        ctx.saveGState()
        ctx.translateBy(x: 0, y: rect.minY + rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(ctx)
        attributed.draw(in: rect)
        UIGraphicsPopContext()
        ctx.restoreGState()
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
