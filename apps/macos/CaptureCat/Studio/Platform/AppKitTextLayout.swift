#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import CoreGraphics
import CoreText
import Foundation

/// The Mac's text metrics and AppKit's line layout, for every studio renderer.
///
/// Text measured or drawn on iOS must land where the Mac puts it — preview,
/// export and the frozen goldens are all Mac renders. Two things differ:
///
/// 1. **The system face's vertical metrics.** macOS's system designs
///    (`.SFNS-*`, `.AppleSystemUIFontMonospaced/Rounded-*`) report ascent
///    1980/2048 em, descent 432/2048, leading 0; iOS's (`.SFUI-*`, …) report
///    1950/2048 and 494/2048 — same advances, different line box. Named
///    families (Helvetica Neue, Avenir Next, Georgia, Menlo, …) and New York
///    are identical on both (measured, apps/ios-spikes + 2c).
/// 2. **AppKit's rounding.** NSStringDrawing on the Mac measures a line as
///    `round(ascent) + round(descent)`, wraps lines `round(ascent) +
///    round(descent) + leading` apart (`.usesFontLeading`), and puts the first
///    baseline `round(ascent)` below the top of the rect. UIKit doesn't round.
///    (Measured on macOS 26 at 13/17.3/18/24.5/34 pt, five families, three
///    weights; `--font-table-test` re-checks the system row on every run.)
///
/// So on iOS `PlatformText` measures and draws through here; the Mac keeps
/// its AppKit calls (each `PlatformText` helper's macOS branch is the exact
/// expression its caller used). Widths and line breaks are the platform's —
/// advances are identical on both.
enum AppKitTextLayout {
    /// The Mac system designs' line metrics, per em (units/2048).
    static let macSystemAscent: CGFloat = 1980.0 / 2048.0
    static let macSystemDescent: CGFloat = 432.0 / 2048.0
    static let macSystemLeading: CGFloat = 0

    /// True for the platform's system-design faces (not New York, whose
    /// metrics match the Mac already).
    static func isSystemDesign(_ postScriptName: String) -> Bool {
        postScriptName.hasPrefix(".SFUI") || postScriptName.hasPrefix(".SFNS")
            || postScriptName.hasPrefix(".AppleSystemUIFont")
    }

    /// The font's line metrics as the Mac reports them (unrounded, points).
    static func metrics(of font: CTFont) -> (ascent: CGFloat, descent: CGFloat, leading: CGFloat) {
        if isSystemDesign(CTFontCopyPostScriptName(font) as String) {
            let size = CTFontGetSize(font)
            return (macSystemAscent * size, macSystemDescent * size, macSystemLeading * size)
        }
        return (CTFontGetAscent(font), CTFontGetDescent(font), CTFontGetLeading(font))
    }

    /// The line box AppKit gives `attributed`: rounded ascent and descent (the
    /// largest over its fonts) and the largest leading, unrounded.
    static func lineBox(_ attributed: NSAttributedString) -> (ascent: CGFloat, descent: CGFloat, leading: CGFloat) {
        var a: CGFloat = 0, d: CGFloat = 0, l: CGFloat = 0
        var sawFont = false
        let all = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttribute(.font, in: all) { value, _, _ in
            guard let value else { return }
            let font = value as! CTFont  // UIFont/NSFont toll-free bridge to CTFont
            let m = metrics(of: font)
            a = max(a, m.ascent.rounded()); d = max(d, m.descent.rounded()); l = max(l, m.leading)
            sawFont = true
        }
        if !sawFont {
            // AppKit's default: Helvetica 12 — never hit by the studio (every
            // run carries a font), kept so an empty attribute set still measures.
            let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
            let m = metrics(of: font)
            return (m.ascent.rounded(), m.descent.rounded(), m.leading)
        }
        return (a, d, l)
    }

    /// `NSAttributedString.size()` as AppKit returns it (one line).
    static func size(of attributed: NSAttributedString, platformWidth: CGFloat) -> CGSize {
        let box = lineBox(attributed)
        return CGSize(width: platformWidth, height: box.ascent + box.descent)
    }

    /// The lines `attributed` breaks into at `width` (CoreText typesetter —
    /// the same breaker TextKit uses for this text).
    static func lines(_ attributed: NSAttributedString, width: CGFloat) -> [CTLine] {
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        var lines: [CTLine] = []
        var start = 0
        let length = attributed.length
        while start < length {
            let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(max(1, width)))
            guard count > 0 else { break }
            lines.append(CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count)))
            start += count
        }
        return lines
    }

    /// `boundingRect(with:options:[.usesLineFragmentOrigin, .usesFontLeading])`
    /// as AppKit returns it: the platform's width, AppKit's line stacking.
    static func boundingRect(of attributed: NSAttributedString, size: CGSize, platformWidth: CGFloat) -> CGRect {
        let box = lineBox(attributed)
        let count = max(1, lines(attributed, width: size.width).count)
        return CGRect(x: 0, y: 0, width: platformWidth,
                      height: CGFloat(count) * (box.ascent + box.descent + box.leading))
    }

    /// `attributed.draw(in: rect)` into a y-UP context, the way AppKit lays it
    /// out: lines broken at `rect.width`, the first baseline `round(ascent)`
    /// below `rect.maxY`, then `round(ascent) + round(descent)` apart (no
    /// leading — draw(in:) doesn't use font leading), each line placed by the
    /// paragraph style's alignment.
    static func draw(_ attributed: NSAttributedString, in rect: CGRect, of ctx: CGContext) {
        let box = lineBox(attributed)
        // draw(in:) lays out WITHOUT .usesFontLeading: lines stack
        // round(ascent) + round(descent) apart (measured: Helvetica Neue
        // 24.5 pt baselines 23/51/79/107 — leading 0.686 not applied).
        let lineStep = box.ascent + box.descent
        var flush: CGFloat = 0
        if attributed.length > 0,
           let style = attributed.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle {
            switch style.alignment {
            case .center: flush = 0.5
            case .right: flush = 1
            default: flush = 0
            }
        }
        ctx.saveGState()
        ctx.textMatrix = .identity
        var baseline = rect.maxY - box.ascent
        for line in lines(attributed, width: rect.width) {
            let x = rect.minX + CGFloat(CTLineGetPenOffsetForFlush(line, flush, Double(rect.width)))
            ctx.textPosition = CGPoint(x: x, y: baseline)
            CTLineDraw(line, ctx)
            baseline -= lineStep
        }
        ctx.restoreGState()
    }

    /// `CTLineGetTypographicBounds` with the Mac's metrics for system faces.
    static func typographicBounds(_ line: CTLine) -> (width: CGFloat, ascent: CGFloat, descent: CGFloat) {
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        for run in runs {
            let attrs = CTRunGetAttributes(run) as NSDictionary
            guard let value = attrs[kCTFontAttributeName] else { continue }
            let m = metrics(of: value as! CTFont)
            ascent = max(ascent, m.ascent); descent = max(descent, m.descent)
        }
        return (width, ascent, descent)
    }
}
