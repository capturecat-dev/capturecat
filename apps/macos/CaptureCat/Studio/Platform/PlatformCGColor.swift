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

    /// `NSColor.white.withAlphaComponent(alpha).cgColor`
    static func white(alpha: CGFloat) -> CGColor {
        PlatformColor.white.withAlphaComponent(alpha).cgColor
    }

    /// `NSColor(red:green:blue:alpha:).cgColor`
    static func rgb(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) -> CGColor {
        PlatformColor(red: red, green: green, blue: blue, alpha: alpha).cgColor
    }

    /// `NSColor(srgbRed:green:blue:alpha:).cgColor`
    static func srgb(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) -> CGColor {
        #if canImport(AppKit)
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha).cgColor
        #else
        // UIColor(red:green:blue:alpha:) is sRGB.
        return UIColor(red: red, green: green, blue: blue, alpha: alpha).cgColor
        #endif
    }

    /// A platform colour the studio already holds: `color.cgColor`.
    static func of(_ color: PlatformColor) -> CGColor {
        color.cgColor
    }

    /// `color.withAlphaComponent(alpha).cgColor`
    static func withAlpha(_ color: PlatformColor, _ alpha: CGFloat) -> CGColor {
        color.withAlphaComponent(alpha).cgColor
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
