import Foundation

/// A colour as four stored sRGB doubles.
///
/// PERSISTENCE IDENTITY: `red`, `green`, `blue`, `opacity` — these four names,
/// these four types, this order, synthesised `Codable`. On disk that is
/// `{"red":1,"green":1,"blue":1,"opacity":1}`. Nothing here may be renamed or
/// reordered; old projects must always still load.
///
/// The type used to carry a SwiftUI `Color` initialiser and accessor. Neither
/// ever participated in the encoding, so removing them does not touch the
/// format. They were also NOT round-trip safe with each other: the `Color`
/// initialiser stored `.deviceRGB` components while the `nsColor` accessor
/// reads them back as sRGB, so a colour picked on a wide-gamut display was
/// written in one space and read in another. Every caller now goes through the
/// platform-colour initialiser (`Studio/Platform/PlatformColor+Codable.swift`),
/// which is sRGB on both sides.
struct CodableColor: Codable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var opacity: Double

    /// Parses "#RRGGBB" or "#RRGGBBAA" (leading "#" optional) — the MCP
    /// tool's color input format. nil on malformed input.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let hasAlpha = s.count == 8
        let r = hasAlpha ? (v >> 24) & 0xFF : (v >> 16) & 0xFF
        let g = hasAlpha ? (v >> 16) & 0xFF : (v >> 8) & 0xFF
        let b = hasAlpha ? (v >> 8) & 0xFF : v & 0xFF
        let a = hasAlpha ? v & 0xFF : 0xFF
        self.red = Double(r) / 255
        self.green = Double(g) / 255
        self.blue = Double(b) / 255
        self.opacity = Double(a) / 255
    }

    init(red: Double, green: Double, blue: Double, opacity: Double = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.opacity = opacity
    }

    var srgba: SRGBA { SRGBA(self) }

    /// Stable identity for render caches — replaces `Color.description`.
    var cacheKey: String {
        String(format: "%.4f,%.4f,%.4f,%.4f", red, green, blue, opacity)
    }
}
