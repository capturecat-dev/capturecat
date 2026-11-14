#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// The platform half of `CameraStyleMath`: border colour, name-tag face, tag
/// fill and the tag's text drawing. The Mac branches are CameraStyleMath's
/// original AppKit code, verbatim.
enum CameraStylePlatform {
    /// Effective border stroke colour: nil setting = the historical white 30%.
    static func borderColor(_ color: CodableColor?) -> PlatformColor {
        #if canImport(AppKit)
        return color?.nsColor ?? NSColor(white: 1, alpha: 0.3)
        #else
        return color.map { UIColor(red: $0.red, green: $0.green, blue: $0.blue, alpha: $0.opacity) }
            ?? UIColor(white: 1, alpha: 0.3)
        #endif
    }

    /// The tag's face: the named font when it exists, else system semibold.
    static func tagFont(named name: String?, size: CGFloat) -> PlatformFont {
        #if canImport(AppKit)
        if let name, let custom = NSFont(name: name, size: size) { return custom }
        return NSFont.systemFont(ofSize: size, weight: .semibold)
        #else
        if let name, let custom = UIFont(name: name, size: size) { return custom }
        return UIFont.systemFont(ofSize: size, weight: .semibold)
        #endif
    }

    /// The pill's fill: the tag background read back as sRGB components.
    static func tagBackgroundCGColor(_ color: CodableColor) -> CGColor {
        #if canImport(AppKit)
        let bg = color.nsColor.usingColorSpace(.sRGB) ?? .black
        return CGColor(
            srgbRed: bg.redComponent, green: bg.greenComponent,
            blue: bg.blueComponent, alpha: bg.alphaComponent
        )
        #else
        return CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.opacity)
        #endif
    }

    /// The tag's one or two centred text lines, drawn into `ctx` — y-UP and
    /// already scaled to layout units (CameraStyleMath.tagBitmap).
    static func drawTagText(
        in ctx: CGContext,
        settings s: ProjectSettings,
        layout: CameraStyleMath.TagLayout,
        pill: CGSize
    ) {
        #if canImport(AppKit)
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
        #else
        let c = s.cameraTagTextColor
        let textColor = UIColor(red: c.red, green: c.green, blue: c.blue, alpha: c.opacity)
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
                .foregroundColor: textColor.withAlphaComponent(textColor.cgColor.alpha * 0.75),
                .paragraphStyle: para,
            ]
        )
        let mainH = ceil(mainLine.size().height)
        let subH = subLine.map { ceil($0.size().height) } ?? 0
        let totalH = mainH + subH
        let topY = (pill.height + totalH) / 2   // Y-up: top edge of the text block
        let inset = layout.fontSize * 0.3
        PlatformText.draw(
            mainLine,
            in: CGRect(x: inset, y: topY - mainH, width: pill.width - 2 * inset, height: mainH),
            of: ctx
        )
        if let subLine {
            PlatformText.draw(
                subLine,
                in: CGRect(x: inset, y: topY - mainH - subH, width: pill.width - 2 * inset, height: subH),
                of: ctx
            )
        }
        #endif
    }
}
