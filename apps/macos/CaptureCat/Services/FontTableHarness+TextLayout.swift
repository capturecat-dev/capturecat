import AppKit
import CoreText

/// `--font-table-test`, part 2 — AppKitTextLayout against the real AppKit.
///
/// iOS measures and draws studio text through AppKitTextLayout (the Mac's
/// system-face metrics + AppKit's rounding rules). This runs the SAME code on
/// the Mac, where real AppKit is the reference, so any rule it gets wrong
/// fails here, on the platform that defines the right answer:
///
///  • the frozen system-design row equals the live macOS fonts (every weight,
///    monospaced, rounded) — an OS update that moves it fails the gate;
///  • `size()` and wrapped `boundingRect` agree with NSAttributedString for
///    five families, three system weights, six sizes, left/centre alignment;
///  • `draw(in:)` lands on AppKit's pixels (bitmap compare) — baseline,
///    line stacking, alignment, wrapping;
///  • an injected wrong rule (unrounded ascent) is caught.
extension FontTableHarness {
    static func textLayoutChecks(_ check: (Bool, String) -> Void) -> Int {
        var cases = 0

        // 1 — the frozen row is the live macOS system face.
        let weights: [NSFont.Weight] = [.ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black]
        for size in [9.0, 13, 17.3, 18, 48] as [CGFloat] {
            var faces: [NSFont] = weights.map { NSFont.systemFont(ofSize: size, weight: $0) }
            faces.append(NSFont.monospacedSystemFont(ofSize: size, weight: .regular))
            if let d = NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.rounded),
               let rounded = NSFont(descriptor: d, size: size) { faces.append(rounded) }
            for f in faces {
                let ct = f as CTFont
                let name = CTFontCopyPostScriptName(ct) as String
                let frozen = AppKitTextLayout.metrics(of: ct)
                let live = (CTFontGetAscent(ct), CTFontGetDescent(ct), CTFontGetLeading(ct))
                cases += 1
                check(AppKitTextLayout.isSystemDesign(name)
                      && abs(frozen.ascent - live.0) < 1e-9 && abs(frozen.descent - live.1) < 1e-9
                      && abs(frozen.leading - live.2) < 1e-9,
                      "text: frozen system metrics == live \(name) @\(size)")
            }
        }

        // 2/3/4 — measurement and drawing against NSAttributedString.
        var fonts: [(String, (CGFloat) -> NSFont)] = [
            ("system", { NSFont.systemFont(ofSize: $0) }),
            ("system-semibold", { NSFont.systemFont(ofSize: $0, weight: .semibold) }),
            ("system-heavy", { NSFont.systemFont(ofSize: $0, weight: .heavy) }),
            ("mono", { NSFont.monospacedSystemFont(ofSize: $0, weight: .regular) }),
        ]
        for name in ["HelveticaNeue", "AvenirNext-Regular", "Georgia", "Menlo-Regular"] where NSFont(name: name, size: 12) != nil {
            fonts.append((name, { NSFont(name: name, size: $0)! }))
        }
        let strings = ["Hello world", "Ag 9:41", "Parity check — glyphs"]
        let wrapping = "The quick brown fox jumps over the lazy dog while the caption wraps"
        for (label, make) in fonts {
            for size in [9.0, 13, 17.3, 18, 24.5, 48] as [CGFloat] {
                let font = make(size)
                for text in strings {
                    let attr = NSAttributedString(string: text, attributes: [.font: font])
                    let real = attr.size()
                    let emulated = AppKitTextLayout.size(of: attr, platformWidth: real.width)
                    cases += 1
                    check(emulated == real, "text: size() \(label) @\(size) \"\(text)\" real=\(real) emulated=\(emulated)")
                }
                for alignment in [NSTextAlignment.left, .center] {
                    let style = NSMutableParagraphStyle()
                    style.alignment = alignment
                    let attr = NSAttributedString(string: wrapping, attributes: [
                        .font: font, .paragraphStyle: style, .foregroundColor: NSColor.white,
                    ])
                    let width = size * 9
                    let real = attr.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                 options: [.usesLineFragmentOrigin, .usesFontLeading])
                    let emulated = AppKitTextLayout.boundingRect(
                        of: attr, size: CGSize(width: width, height: .greatestFiniteMagnitude), platformWidth: real.width)
                    cases += 1
                    check(abs(emulated.height - real.height) < 1e-9,
                          "text: boundingRect \(label) @\(size) \(alignment == .center ? "centre" : "left") real.h=\(real.height) emulated.h=\(emulated.height)")
                    if size == 13 || size == 24.5 {
                        let rect = CGRect(x: 6, y: 4, width: width, height: ceil(real.height))
                        let a = raster(rect: rect) { attr.draw(in: rect) }
                        let b = raster(rect: rect) { ctx in AppKitTextLayout.draw(attr, in: rect, of: ctx) }
                        let diff = maxDiff(a, b)
                        cases += 1
                        check(diff <= 1, "text: draw(in:) pixels \(label) @\(size) \(alignment == .center ? "centre" : "left") max|Δ|=\(diff)")
                    }
                }
            }
        }

        // Gate power: an unrounded ascent (UIKit's rule) must be caught.
        let probe = NSFont.systemFont(ofSize: 17.3)
        let probeAttr = NSAttributedString(string: "Hello", attributes: [.font: probe])
        let wrongHeight = CTFontGetAscent(probe) + CTFontGetDescent(probe)
        cases += 1
        check(wrongHeight != probeAttr.size().height,
              "text: injected unrounded line box (\(wrongHeight)) differs from AppKit (\(probeAttr.size().height))")
        return cases
    }

    /// An sRGB RGBA raster of `body` drawn into a y-up context sized to `rect`
    /// (+ a margin), through NSGraphicsContext when `body` takes no context.
    private static func raster(rect: CGRect, _ body: () -> Void) -> [UInt8] {
        raster(rect: rect) { (_: CGContext) in body() }
    }

    private static func raster(rect: CGRect, _ body: (CGContext) -> Void) -> [UInt8] {
        let w = Int(rect.maxX + 6), h = Int(rect.maxY + 4)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        body(ctx)
        NSGraphicsContext.current = previous
        guard let data = ctx.data else { return [] }
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: w * h * 4))
    }

    private static func maxDiff(_ a: [UInt8], _ b: [UInt8]) -> Int {
        guard a.count == b.count, !a.isEmpty else { return 255 }
        var worst = 0
        for i in 0..<a.count { worst = max(worst, abs(Int(a[i]) - Int(b[i]))) }
        return worst
    }
}
