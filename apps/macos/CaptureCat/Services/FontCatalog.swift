import AppKit

/// Typeface selection shared by subtitles and annotations.
///
/// A font is stored as an optional PostScript-ish family name; `nil` means the
/// system font, which is the historical behaviour and stays the default so
/// existing projects render unchanged. Resolution lives here so the preview
/// compositor and the exporter can never disagree about which face they drew —
/// same input, same `NSFont`.
enum FontCatalog {
    /// Label shown for the system default.
    static let systemName = "System"

    /// Curated list first (faces that ship with macOS and read well burned
    /// into video), then every other installed family. The curated set is
    /// filtered to what's actually available so the menu never offers a face
    /// that would silently fall back.
    static let curated: [String] = [
        "SF Pro", "SF Pro Rounded", "New York",
        "Helvetica Neue", "Avenir Next", "Futura", "Gill Sans",
        "Georgia", "Times New Roman", "Palatino",
        "Menlo", "SF Mono", "Courier New",
        "Impact", "Copperplate", "American Typewriter",
    ]

    /// Menu contents: "System" + available curated faces + the rest, deduped.
    static let menuNames: [String] = {
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        let available = curated.filter { installed.contains($0) }
        let rest = NSFontManager.shared.availableFontFamilies
            .filter { !available.contains($0) }
            .sorted()
        return [systemName] + available + rest
    }()

    /// Resolve a stored name + size + weight to a concrete font.
    /// Falls back to the system face whenever the stored family is missing
    /// (e.g. the project moved to a Mac without that font installed).
    static func font(named name: String?, size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let fallback = NSFont.systemFont(ofSize: size, weight: weight)
        guard let name, name != systemName, !name.isEmpty else { return fallback }

        // Ask the font manager for the family member closest to the requested
        // weight, so the weight chips keep working for non-system faces.
        let traits: NSFontTraitMask = weight >= .bold ? .boldFontMask : []
        let weightIndex = appKitWeight(for: weight)
        if let f = NSFontManager.shared.font(
            withFamily: name,
            traits: traits,
            weight: weightIndex,
            size: size
        ) {
            return f
        }
        return NSFont(name: name, size: size) ?? fallback
    }

    /// Maps SwiftUI-style weights onto AppKit's 0…15 font-manager scale.
    private static func appKitWeight(for weight: NSFont.Weight) -> Int {
        switch weight {
        case .ultraLight, .thin: return 2
        case .light: return 3
        case .regular: return 5
        case .medium: return 6
        case .semibold: return 8
        case .bold: return 9
        case .heavy: return 11
        case .black: return 13
        default: return 5
        }
    }

    /// Index of a stored name in `menuNames`, for driving a menu control.
    static func menuIndex(for name: String?) -> Int {
        guard let name, name != systemName else { return 0 }
        return menuNames.firstIndex(of: name) ?? 0
    }

    /// Stored value for a menu index (nil for System).
    static func storedName(forMenuIndex index: Int) -> String? {
        guard index > 0, index < menuNames.count else { return nil }
        return menuNames[index]
    }
}
