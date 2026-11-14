import AppKit

/// Headless gate for the frozen font table (docs/ios-studio-phase0.md §3.6):
///
///   CaptureCat --font-table-test
///
/// FontCatalog takes curated families at the five subtitle weights from
/// `FontFaceTable` instead of asking NSFontManager each time. This proves, on
/// the Mac it runs on, that the table still says what the live resolution
/// picks, so the switch changed no Mac output:
///  • completeness — every curated family has all five weights, and nothing
///    else is in the table;
///  • every entry instantiates and IS the live font (fontName, pointSize and
///    the same NSFont) at several sizes;
///  • `FontCatalog.font`, the routed path the renderers call, equals the live
///    font for every entry and for inputs the table doesn't cover;
///  • the comparison catches a wrong entry (injected defects must fail it).
enum FontTableHarness {
    static func run() -> Never {
        setbuf(stdout, nil)
        var failures: [String] = []
        func check(_ ok: Bool, _ label: String) {
            print("FONTTABLE \(ok ? "ok" : "FAIL") \(label)")
            if !ok { failures.append(label) }
        }
        let sizes: [CGFloat] = [9, 17, 48, 120]
        let weights = ProjectSettings.SubtitleWeight.allCases

        func same(_ font: NSFont?, _ live: NSFont) -> Bool {
            guard let font else { return false }
            return font.fontName == live.fontName
                && font.pointSize == live.pointSize
                && font.isEqual(live)
        }
        /// The table entry, instantiated as data, against the live resolution
        /// at every size.
        func entryMatchesLive(_ face: FontFaceTable.Face, family: String,
                              weight: ProjectSettings.SubtitleWeight) -> Bool {
            sizes.allSatisfy { size in
                let live = PlatformFonts.liveFont(named: family, size: size, weight: weight.nsWeight)
                return same(PlatformFonts.font(for: face, size: size, weight: weight.nsWeight), live)
            }
        }

        // — completeness —
        let missing = FontCatalog.curated.flatMap { family in
            weights.compactMap { FontFaceTable.face(family: family, weight: $0) == nil ? "\(family) \($0.rawValue)" : nil }
        }
        check(missing.isEmpty, "every curated family × 5 weights has an entry (missing: \(missing))")
        let stray = Set(FontFaceTable.faces.keys).subtracting(FontCatalog.curated)
        check(stray.isEmpty, "table holds only curated families (stray: \(stray.sorted()))")

        // — every entry equals the live resolution —
        var entries = 0
        for family in FontCatalog.curated {
            for weight in weights {
                guard let face = FontFaceTable.face(family: family, weight: weight) else { continue }
                entries += 1
                let live = PlatformFonts.liveFont(named: family, size: 17, weight: weight.nsWeight)
                check(entryMatchesLive(face, family: family, weight: weight),
                      "\(family) \(weight.rawValue): table \(face) == live \(live.fontName) at \(sizes.map { Int($0) }) pt")
                let routed = sizes.allSatisfy { size in
                    same(FontCatalog.font(named: family, size: size, weight: weight.nsWeight),
                         PlatformFonts.liveFont(named: family, size: size, weight: weight.nsWeight))
                }
                check(routed, "\(family) \(weight.rawValue): FontCatalog.font == live")
            }
        }
        check(entries == FontCatalog.curated.count * weights.count, "\(entries) entries checked")

        // — inputs the table doesn't cover still resolve live —
        let offTable: [(String?, NSFont.Weight, String)] = [
            (nil, .semibold, "nil family"),
            (FontCatalog.systemName, .bold, "System"),
            ("", .regular, "empty name"),
            ("Zapfino", .regular, "uncurated family"),
            ("No Such Family", .medium, "missing family"),
            ("Futura", .light, "curated family, off-table weight"),
        ]
        for (name, weight, label) in offTable {
            let ok = sizes.allSatisfy { size in
                same(FontCatalog.font(named: name, size: size, weight: weight),
                     PlatformFonts.liveFont(named: name, size: size, weight: weight))
            }
            check(ok, "off-table input resolves live: \(label)")
        }

        // — the comparison catches wrong entries (injected defects) —
        let injected: [(FontFaceTable.Face, String, ProjectSettings.SubtitleWeight)] = [
            (.named("Futura-Bold"), "Futura", .medium),         // UIKit's pick, not the Mac's
            (.system, "Helvetica Neue", .regular),              // a real face mislabelled system
            (.named("HelveticaNeue-Bold"), "Helvetica Neue", .heavy),
            (.named("NoSuchFace-Regular"), "Georgia", .regular), // a face that doesn't instantiate
        ]
        for (face, family, weight) in injected {
            check(!entryMatchesLive(face, family: family, weight: weight),
                  "injected wrong entry is caught: \(family) \(weight.rawValue) as \(face)")
        }

        print(failures.isEmpty
              ? "FONTTABLE PASS \(entries) entries × \(sizes.count) sizes"
              : "FONTTABLE FAIL \(failures.count): \(failures.joined(separator: " | "))")
        exit(failures.isEmpty ? 0 : 1)
    }
}
