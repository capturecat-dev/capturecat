// Mac half of spike (e): resolves FontCatalog.curated × SubtitleWeight with the
// REAL Studio/Services/FontCatalog.swift (compiled alongside this file by
// font-report-mac.sh) and prints JSON in the same shape SpikeE writes on iOS.
import AppKit

let weights: [(String, NSFont.Weight)] = [
    ("Regular", .regular), ("Medium", .medium), ("Semibold", .semibold), ("Bold", .bold), ("Heavy", .heavy),
]
let sample = "The quick brown fox jumps 0123456789"
let size: CGFloat = 48
func width(_ f: NSFont) -> Double { Double(NSAttributedString(string: sample, attributes: [.font: f]).size().width) }

let installed = Set(NSFontManager.shared.availableFontFamilies)
var families: [[String: Any]] = []
for family in FontCatalog.curated {
    let rows: [[String: Any]] = weights.map { (name, w) in
        let f = FontCatalog.font(named: family, size: size, weight: w)
        return ["weight": name, "postScriptName": f.fontName, "resolvedFamily": f.familyName ?? "",
                "fellBack": (f.familyName ?? "") != family, "advanceWidth": width(f),
                "ascender": f.ascender, "descender": f.descender]
    }
    families.append(["family": family, "installed": installed.contains(family),
                     "members": NSFontManager.shared.availableMembers(ofFontFamily: family)?.compactMap { $0.first as? String } ?? [],
                     "weights": rows])
}
let system: [[String: Any]] = weights.map { (name, w) in
    let f = FontCatalog.font(named: nil, size: size, weight: w)
    return ["weight": name, "postScriptName": f.fontName, "advanceWidth": width(f), "ascender": f.ascender, "descender": f.descender]
}
let out: [String: Any] = ["sample": sample, "pointSize": size, "families": families, "system": system,
                          "macOS": ProcessInfo.processInfo.operatingSystemVersionString]
let data = try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
print(String(data: data, encoding: .utf8)!)
