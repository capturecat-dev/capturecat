import CoreGraphics
import Foundation

/// Typeface selection shared by subtitles and annotations.
///
/// A font is stored as an optional PostScript-ish family name; `nil` means the
/// system font, which is the historical behaviour and stays the default so
/// existing projects render unchanged. Resolution lives here so the preview
/// compositor and the exporter can never disagree about which face they drew —
/// same input, same font. Curated families at the five subtitle weights come
/// from the frozen `FontFaceTable`, so the Mac and iOS draw the same faces;
/// everything else resolves live (`PlatformFonts.liveFont`).
enum FontCatalog {
    /// Label shown for the system default.
    static let systemName = "System"

    /// `menuNames` as shown: the system entry in the reader's language (the
    /// stored name stays "System"; menus read and write by index).
    static var displayMenuNames: [String] {
        menuNames.map { $0 == systemName ? String(localized: "System", comment: "Font menu: the system font") : $0 }
    }

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
        let installed = Set(PlatformFonts.availableFamilies())
        let available = curated.filter { installed.contains($0) }
        let rest = PlatformFonts.availableFamilies()
            .filter { !available.contains($0) }
            .sorted()
        return [systemName] + available + rest
    }()

    /// Resolve a stored name + size + weight to a concrete font.
    /// Falls back to the system face whenever the stored family is missing
    /// (e.g. the project moved to a Mac without that font installed).
    static func font(named name: String?, size: CGFloat, weight: PlatformFontWeight) -> PlatformFont {
        // The frozen face for a curated family at one of the five weights…
        if let name,
           let tableWeight = ProjectSettings.SubtitleWeight(nsWeight: weight),
           let face = FontFaceTable.face(family: name, weight: tableWeight),
           let font = PlatformFonts.tableFont(for: face, size: size, weight: weight) {
            return font
        }
        // …otherwise ask the platform for the family member closest to the
        // requested weight, so the weight chips keep working for any face.
        return PlatformFonts.liveFont(named: name, size: size, weight: weight)
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
