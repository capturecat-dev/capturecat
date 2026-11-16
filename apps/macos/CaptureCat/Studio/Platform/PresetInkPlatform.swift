#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

extension PlatformColor {
    /// `NSColor(srgbRed:green:blue:alpha:)` on the Mac; UIKit's
    /// `UIColor(red:green:blue:alpha:)` is sRGB too.
    static func studioSRGB(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> PlatformColor {
        #if canImport(AppKit)
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
        #else
        return UIColor(red: r, green: g, blue: b, alpha: a)
        #endif
    }
}

extension PresetInk {
    /// The colour a preset card draws with (dynamic system colours stay dynamic).
    var platformColor: PlatformColor {
        switch self {
        case .white: return .white
        case .black: return .black
        case .systemYellow: return .systemYellow
        case .srgb(let r, let g, let b): return .studioSRGB(r, g, b, 1)
        }
    }
}
