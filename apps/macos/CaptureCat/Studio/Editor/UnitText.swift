import Foundation

/// Compact unit readouts — a clip's "3.5s", a zoom's "1.8x" — in the reader's
/// language: the number in the app language's digits and separator, the unit
/// through the catalog ("%@s" → ja "%@秒", de "%@ s"). One source for the
/// timeline, the inspector readouts and the menus on both front ends; with no
/// catalog (the Mac today) it is exactly the old `String(format: "%.1fs")`.
nonisolated enum UnitText {
    /// The language the strings resolved to, so digits match the words around
    /// them (a Mac without a catalog stays "en": "3.5").
    private static let locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")

    static func number(_ value: Double, digits: Int) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.minimumFractionDigits = digits
        f.maximumFractionDigits = digits
        return f.string(from: NSNumber(value: value)) ?? String(format: "%.\(digits)f", value)
    }

    /// "3.5s"
    static func seconds(_ value: Double, digits: Int = 1) -> String {
        let n = number(value, digits: digits)
        return String(localized: "\(n)s", comment: "Compact duration in seconds, e.g. 3.5s (timeline clip badge, inspector readout)")
    }

    /// "1.8x"
    static func multiplier(_ value: Double, digits: Int = 1) -> String {
        let n = number(value, digits: digits)
        return String(localized: "\(n)x", comment: "Compact multiplier, e.g. 1.8x zoom or 2x speed")
    }
}
