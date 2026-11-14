#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Font lookup behind `FontCatalog`: the installed families, the frozen
/// `FontFaceTable` faces, and the live family resolution for everything the
/// table doesn't cover. The Mac's live path is FontCatalog's original
/// NSFontManager code, verbatim.
enum PlatformFonts {
    /// Every installed font family: `NSFontManager.shared.availableFontFamilies`.
    static func availableFamilies() -> [String] {
        #if canImport(AppKit)
        return NSFontManager.shared.availableFontFamilies
        #else
        return UIFont.familyNames
        #endif
    }

    /// The font a table face names at `size`, or nil when it doesn't
    /// instantiate here. Used as-is by `--font-table-test` to prove each
    /// entry against the live resolution.
    static func font(for face: FontFaceTable.Face, size: CGFloat, weight: PlatformFontWeight) -> PlatformFont? {
        #if canImport(AppKit)
        switch face {
        case .system:
            return NSFont.systemFont(ofSize: size, weight: weight)
        case .named(let name), .monospacedSystem(let name):
            return NSFont(name: name, size: size)
        }
        #else
        switch face {
        case .system:
            return UIFont.systemFont(ofSize: size, weight: weight)
        case .named(let name):
            return UIFont(name: name, size: size)
        case .monospacedSystem:
            // iOS ships SF Mono only as the system font's monospaced design.
            return UIFont.monospacedSystemFont(ofSize: size, weight: weight)
        }
        #endif
    }

    /// The font FontCatalog takes from a table face, or nil to fall through
    /// to `liveFont`.
    ///
    /// On the Mac a `.system` entry falls through: it records that the family
    /// wasn't installed on the Mac the table was made on, and the live path
    /// draws exactly that system face when the family is missing, while still
    /// honouring the real family on a Mac that has it installed.
    static func tableFont(for face: FontFaceTable.Face, size: CGFloat, weight: PlatformFontWeight) -> PlatformFont? {
        #if canImport(AppKit)
        if case .system = face { return nil }
        #endif
        return font(for: face, size: size, weight: weight)
    }

    /// FontCatalog's resolution without the table: the family member closest
    /// to the weight, else a face of that name, else the system face.
    static func liveFont(named name: String?, size: CGFloat, weight: PlatformFontWeight) -> PlatformFont {
        #if canImport(AppKit)
        let fallback = NSFont.systemFont(ofSize: size, weight: weight)
        guard let name, name != FontCatalog.systemName, !name.isEmpty else { return fallback }

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
        #else
        let fallback = UIFont.systemFont(ofSize: size, weight: weight)
        guard let name, name != FontCatalog.systemName, !name.isEmpty else { return fallback }

        // The family's member closest to the weight, as UIKit matches it.
        if UIFont.familyNames.contains(name) {
            let descriptor = UIFontDescriptor(fontAttributes: [
                .family: name,
                .traits: [UIFontDescriptor.TraitKey.weight: weight.rawValue],
            ])
            return UIFont(descriptor: descriptor, size: size)
        }
        return UIFont(name: name, size: size) ?? fallback
        #endif
    }

    #if canImport(AppKit)
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
    #endif
}
