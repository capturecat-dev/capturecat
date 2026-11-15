import UIKit

/// (e) Fonts: resolve every FontCatalog curated family × SubtitleWeight on iOS.
///
/// The Mac resolves a stored family with NSFontManager.font(withFamily:traits:
/// weight:size:) (Studio/Services/FontCatalog.swift). iOS has no NSFontManager; the
/// natural port is a UIFontDescriptor family + weight-trait match. For each
/// pair this records the face iOS picks and the advance width of a reference
/// string, so mac/merge-font-report.py can diff them against the Mac's own
/// resolution (mac/font-report-mac.sh runs the REAL FontCatalog.swift).
///
/// Keep `curated` in sync with FontCatalog.curated (Phase 0 copy; Phase 1
/// shares the file).
@MainActor
enum SpikeE {
    static let curated = [
        "SF Pro", "SF Pro Rounded", "New York",
        "Helvetica Neue", "Avenir Next", "Futura", "Gill Sans",
        "Georgia", "Times New Roman", "Palatino",
        "Menlo", "SF Mono", "Courier New",
        "Impact", "Copperplate", "American Typewriter",
    ]
    /// ProjectSettings.SubtitleWeight → UIFont.Weight (same mapping as nsWeight).
    static let weights: [(String, UIFont.Weight)] = [
        ("Regular", .regular), ("Medium", .medium), ("Semibold", .semibold), ("Bold", .bold), ("Heavy", .heavy),
    ]
    static let sample = "The quick brown fox jumps 0123456789"
    static let size: CGFloat = 48

    static func run(variant: String) async throws -> [String: Any] {
        let installed = Set(UIFont.familyNames)
        var families: [[String: Any]] = []
        for family in curated {
            let members = UIFont.fontNames(forFamilyName: family)
            var rows: [[String: Any]] = []
            for (name, weight) in weights {
                let descriptor = UIFontDescriptor(fontAttributes: [
                    .family: family,
                    .traits: [UIFontDescriptor.TraitKey.weight: weight],
                ])
                let font = UIFont(descriptor: descriptor, size: size)
                let resolvedFamily = font.familyName
                rows.append([
                    "weight": name,
                    "postScriptName": font.fontName,
                    "resolvedFamily": resolvedFamily,
                    "fellBack": resolvedFamily != family,
                    "advanceWidth": width(font),
                    "ascender": font.ascender, "descender": font.descender, "lineHeight": font.lineHeight,
                ])
            }
            families.append(["family": family, "installed": installed.contains(family), "members": members, "weights": rows])
        }
        let system = weights.map { (name, weight) -> [String: Any] in
            let font = UIFont.systemFont(ofSize: size, weight: weight)
            return ["weight": name, "postScriptName": font.fontName, "advanceWidth": width(font),
                    "ascender": font.ascender, "descender": font.descender, "lineHeight": font.lineHeight]
        }
        // How iOS exposes the SF variants that macOS installs as named families.
        func design(_ d: UIFontDescriptor.SystemDesign) -> [[String: Any]] {
            weights.map { (name, weight) in
                let base = UIFont.systemFont(ofSize: size, weight: weight).fontDescriptor.withDesign(d)!
                let f = UIFont(descriptor: base, size: size)
                return ["weight": name, "postScriptName": f.fontName, "advanceWidth": width(f)]
            }
        }
        return [
            "sample": sample, "pointSize": size,
            "families": families,
            "system": system,
            "systemDesigns": ["rounded": design(.rounded), "serif": design(.serif), "monospaced": design(.monospaced)],
            "installedFamilyCount": installed.count,
        ]
    }

    static func width(_ font: UIFont) -> Double {
        Double(NSAttributedString(string: sample, attributes: [.font: font]).size().width)
    }
}
