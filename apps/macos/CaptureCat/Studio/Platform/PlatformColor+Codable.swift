#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

extension CodableColor {
    /// sRGB to match the `nsColor` accessor in `CodableColor+AppKit`, so a
    /// colour survives a round trip unchanged.
    init(_ color: PlatformColor) {
        #if canImport(AppKit)
        let rgb = color.usingColorSpace(.sRGB) ?? color
        self.init(red: Double(rgb.redComponent),
                  green: Double(rgb.greenComponent),
                  blue: Double(rgb.blueComponent),
                  opacity: Double(rgb.alphaComponent))
        #else
        // UIKit reads components in extended sRGB, the same space.
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        _ = color.getRed(&r, green: &g, blue: &b, alpha: &a)
        self.init(red: Double(r), green: Double(g), blue: Double(b), opacity: Double(a))
        #endif
    }
}
