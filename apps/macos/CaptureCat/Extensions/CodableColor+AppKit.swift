import AppKit

extension CodableColor {
    /// The stored triple as an `NSColor`, with no SwiftUI round-trip.
    ///
    /// Behaviour-identical to the old `NSColor(codableColor.color)`: the
    /// `Color` that produced went through `Color(red:green:blue:opacity:)`,
    /// which is sRGB, so the components are read back as sRGB here too.
    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: opacity)
    }

    var srgba: SRGBA { SRGBA(self) }

    /// Stable identity for render caches — replaces `Color.description`.
    var cacheKey: String {
        String(format: "%.4f,%.4f,%.4f,%.4f", red, green, blue, opacity)
    }
}
