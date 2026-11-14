#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// `CGColor`s the renderers used to spell as platform colours inline
/// (`NSColor.white.cgColor` and friends), which member import visibility no
/// longer lets them write. On the Mac each is that exact expression, evaluated
/// per use, so it keeps the platform colour's own colour space: NSColor's
/// white and black are calibrated-white colours, not sRGB literals.
enum PlatformCGColor {
    /// `NSColor.white.cgColor`
    static var white: CGColor { PlatformColor.white.cgColor }

    /// `NSColor.black.cgColor`
    static var black: CGColor { PlatformColor.black.cgColor }

    /// `NSColor.black.withAlphaComponent(alpha).cgColor`
    static func black(alpha: CGFloat) -> CGColor {
        PlatformColor.black.withAlphaComponent(alpha).cgColor
    }

    /// `NSColor(red:green:blue:alpha:).cgColor`
    static func rgb(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) -> CGColor {
        PlatformColor(red: red, green: green, blue: blue, alpha: alpha).cgColor
    }

    /// The colour converted to sRGB first: `(color.usingColorSpace(.sRGB) ?? color).cgColor`.
    static func sRGB(_ color: PlatformColor) -> CGColor {
        #if canImport(AppKit)
        let srgb = color.usingColorSpace(.sRGB) ?? color
        return srgb.cgColor
        #else
        // A UIColor's CGColor is already in (extended) sRGB.
        return color.cgColor
        #endif
    }
}
