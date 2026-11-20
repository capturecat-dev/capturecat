import Foundation

/// `ChangeSummary.format(_:)` — the History row caption, e.g.
/// "Zoom added · Background changed · 3 captions edited".
///
/// Twin of apps/web/src/editor/core/merge/changeSummary.ts; golden-tested.
/// Phrase order (fixed): clip structure / trim / recording, timeline items
/// (lane order), settings by inspector tab (InspectorTab order, then aspect
/// ratio, export, other), captions, then document fields.
nonisolated enum ChangeSummary {
    static let separator = " \u{00B7} "

    /// (project.json key, singular capitalized, plural lowercase) in lane order.
    private static let timelineNouns: [(String, String, String)] = [
        ("zoomRegions", "Zoom", "zooms"),
        ("tiltRegions", "Tilt", "tilts"),
        ("speedRegions", "Speed region", "speed regions"),
        ("blurRegions", "Blur", "blurs"),
        ("highlightRegions", "Highlight", "highlights"),
        ("focusRegions", "Depth focus", "depth focus regions"),
        ("cameraLayoutRegions", "Camera layout", "camera layouts"),
        ("annotations", "Annotation", "annotations"),
        ("voiceOverClips", "Voice-over", "voice-overs"),
    ]

    private static let captionNoun = ("subtitles", "Caption", "captions")

    private static let tabPhrases: [(String, String)] = [
        ("background", String(localized: "Background changed", comment: "History row caption phrase (phrases are joined with \" · \")")),
        ("cursor", String(localized: "Cursor changed", comment: "History row caption phrase (phrases are joined with \" · \")")),
        ("camera", String(localized: "Camera changed", comment: "History row caption phrase (phrases are joined with \" · \")")),
        ("audio", String(localized: "Audio changed", comment: "History row caption phrase (phrases are joined with \" · \")")),
        ("effects", String(localized: "Effects changed", comment: "History row caption phrase (phrases are joined with \" · \")")),
        ("motion", String(localized: "Motion changed", comment: "History row caption phrase (phrases are joined with \" · \")")),
        ("subtitles", String(localized: "Caption style changed", comment: "History row caption phrase (phrases are joined with \" · \")")),
        ("brand", String(localized: "Brand changed", comment: "History row caption phrase (phrases are joined with \" · \")")),
        ("canvas", String(localized: "Aspect ratio changed", comment: "History row caption phrase (phrases are joined with \" · \")")),
        ("export", String(localized: "Export settings changed", comment: "History row caption phrase (phrases are joined with \" · \")")),
    ]
    private static let otherSettingsPhrase = String(localized: "Settings changed", comment: "History row caption phrase (phrases are joined with \" · \")")

    private static let clipFields = ["videoClipSegments", "splitPoints"]
    private static let trimFields = ["trimStart", "trimEnd"]
    private static let recordingFields = [
        "sourceSegments", "duration", "videoURL", "cursorDataURL", "keystrokeDataURL",
        "cameraVideoURL", "cameraTimeOffset", "recordingSourceKind",
    ]
    private static let trailingFields: [(String, String)] = [
        ("name", String(localized: "Renamed", comment: "History row caption phrase (phrases are joined with \" · \")")),
        ("stillTreatment", String(localized: "Image/video mode changed", comment: "History row caption phrase (phrases are joined with \" · \")")),
        ("reminderDate", String(localized: "Reminder changed", comment: "History row caption phrase (phrases are joined with \" · \")")),
    ]
    private static let otherPhrase = String(localized: "Other changes", comment: "History row caption phrase (phrases are joined with \" · \")")

    private static func capitalize(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }

    private enum Verb: String { case added, removed, edited }

    private static func collectionPhrases(_ c: CollectionChange, _ key: String) -> [String] {
        if c.replaced { return [replacedPhrase(key)] }
        let n = c.countsValue
        var out: [String] = []
        if n.added > 0 { out.append(countedPhrase(key, .added, n.added)) }
        if n.removed > 0 { out.append(countedPhrase(key, .removed, n.removed)) }
        if n.changed > 0 { out.append(countedPhrase(key, .edited, n.changed)) }
        if c.reordered { out.append(reorderedPhrase(key)) }
        return out
    }

    // Generated per lane: each phrase is one whole localized sentence.
    private static func replacedPhrase(_ key: String) -> String {
        switch key {
        case "zoomRegions": return String(localized: "Zooms changed", comment: "History row caption phrase (phrases are joined with \" · \")")
        case "tiltRegions": return String(localized: "Tilts changed", comment: "History row caption phrase (phrases are joined with \" · \")")
        case "speedRegions": return String(localized: "Speed regions changed", comment: "History row caption phrase (phrases are joined with \" · \")")
        case "blurRegions": return String(localized: "Blurs changed", comment: "History row caption phrase (phrases are joined with \" · \")")
        case "highlightRegions": return String(localized: "Highlights changed", comment: "History row caption phrase (phrases are joined with \" · \")")
        case "focusRegions": return String(localized: "Depth focus regions changed", comment: "History row caption phrase (phrases are joined with \" · \")")
        case "cameraLayoutRegions": return String(localized: "Camera layouts changed", comment: "History row caption phrase (phrases are joined with \" · \")")
        case "annotations": return String(localized: "Annotations changed", comment: "History row caption phrase (phrases are joined with \" · \")")
        case "voiceOverClips": return String(localized: "Voice-overs changed", comment: "History row caption phrase (phrases are joined with \" · \")")
        case "subtitles": return String(localized: "Captions changed", comment: "History row caption phrase (phrases are joined with \" · \")")
        default: return "\(capitalize(key)) changed"
        }
    }

    private static func reorderedPhrase(_ key: String) -> String {
        switch key {
        case "zoomRegions": return String(localized: "Zooms reordered", comment: "History row caption phrase (phrases are joined with \" · \")")
        case "tiltRegions": return String(localized: "Tilts reordered", comment: "History row caption phrase (phrases are joined with \" · \")")
        case "speedRegions": return String(localized: "Speed regions reordered", comment: "History row caption phrase (phrases are joined with \" · \")")
        case "blurRegions": return String(localized: "Blurs reordered", comment: "History row caption phrase (phrases are joined with \" · \")")
        case "highlightRegions": return String(localized: "Highlights reordered", comment: "History row caption phrase (phrases are joined with \" · \")")
        case "focusRegions": return String(localized: "Depth focus regions reordered", comment: "History row caption phrase (phrases are joined with \" · \")")
        case "cameraLayoutRegions": return String(localized: "Camera layouts reordered", comment: "History row caption phrase (phrases are joined with \" · \")")
        case "annotations": return String(localized: "Annotations reordered", comment: "History row caption phrase (phrases are joined with \" · \")")
        case "voiceOverClips": return String(localized: "Voice-overs reordered", comment: "History row caption phrase (phrases are joined with \" · \")")
        case "subtitles": return String(localized: "Captions reordered", comment: "History row caption phrase (phrases are joined with \" · \")")
        default: return "\(capitalize(key)) reordered"
        }
    }

    /// `k == 1` → "Zoom added"; otherwise "3 zooms added".
    private static func countedPhrase(_ key: String, _ verb: Verb, _ k: Int) -> String {
        switch (key, verb) {
        case ("zoomRegions", .added): return k == 1 ? String(localized: "Zoom added", comment: "History row caption phrase (phrases are joined with \" · \")") : String(localized: "\(k) zooms added", comment: "History row caption phrase (phrases are joined with \" · \")")
        case ("zoomRegions", .removed): return k == 1 ? String(localized: "Zoom removed", comment: "History row caption phrase (phrases are joined with \" · \")") : String(localized: "\(k) zooms removed", comment: "History row caption phrase (phrases are joined with \" · \")")
        case ("zoomRegions", .edited): return k == 1 ? String(localized: "Zoom edited", comment: "History row caption phrase (phrases are joined with \" · \")") : String(localized: "\(k) zooms edited", comment: "History row caption phrase (phrases are joined with \" · \")")
        case ("tiltRegions", .added): return k == 1 ? String(localized: "Tilt added", comment: "History row caption phrase (phrases are joined with \" · \")") : String(localized: "\(k) tilts added", comment: "History row caption phrase (phrases are joined with \" · \")")
        case ("tiltRegions", .removed): return k == 1 ? String(localized: "Tilt removed", comment: "History row caption phrase (phrases are joined with \" · \")") : String(localized: "\(k) tilts removed", comment: "History row caption phrase (phrases are joined with \" · \")")
        case ("tiltRegions", .edited): return k == 1 ? String(localized: "Tilt edited", comment: "History row caption phrase (phrases are joined with \" · \")") : String(localized: "\(k) tilts edited", comment: "History row caption phrase (phrases are joined with \" · \")")
        case ("speedRegions", .added): return k == 1 ? String(localized: "Speed region added", comment: "History row caption phrase (phrases are joined with \" · \")") : String(localized: "\(k) speed regions added", comment: "History row caption phrase (phrases are joined with \" · \")")
        case ("speedRegions", .removed): return k == 1 ? String(localized: "Speed region removed", comment: "History row caption phrase (phrases are joined with \" · \")") : String(localized: "\(k) speed regions removed", comment: "History row caption phrase (phrases are joined with \" · \")")
        case ("speedRegions", .edited): return k == 1 ? String(localized: "Speed region edited", comment: "History row caption phrase (phrases are joined with \" · \")") : String(localized: "\(k) speed regions edited", comment: "History row caption phrase (phrases are joined with \" · \")")
        case ("blurRegions", .added): return k == 1 ? String(localized: "Blur added", comment: "History row caption phrase (phrases are joined with \" · \")") : String(localized: "\(k) blurs added", comment: "History row caption phrase (phrases are joined with \" · \")")
        case ("blurRegions", .removed): return k == 1 ? String(localized: "Blur removed", comment: "History row caption phrase (phrases are joined with \" · \")") : String(localized: "\(k) blurs removed", comment: "History row caption phrase (phrases are joined with \" · \")")
        case ("blurRegions", .edited): return k == 1 ? String(localized: "Blur edited", comment: "History row caption phrase (phrases are joined with \" · \")") : String(localized: "\(k) blurs edited", comment: "History row caption phrase (phrases are joined with \" · \")")
        case ("highlightRegions", .added): return k == 1 ? String(localized: "Highlight added", comment: "History row caption phrase (phrases are joined with \" · \")") : String(localized: "\(k) highlights added", comment: "History row caption phrase (phrases are joined with \" · \")")
        case ("highlightRegions", .removed): return k == 1 ? String(localized: "Highlight removed", comment: "History row caption phrase (phrases are joined with \" · \")") : String(localized: "\(k) highlights removed", comment: "History row caption phrase (phrases are joined with \" · \")")
        case ("highlightRegions", .edited): return k == 1 ? String(localized: "Highlight edited", comment: "History row caption phrase (phrases are joined with \" · \")") : String(localized: "\(k) highlights edited", comment: "History row caption phrase (phrases are joined with \" · \")")
        case ("focusRegions", .added): return k == 1 ? String(localized: "Depth focus added", comment: "History row caption phrase (phrases are joined with \" · \")") : String(localized: "\(k) depth focus regions added", comment: "History row caption phrase (phrases are joined with \" · \")")
        case ("focusRegions", .removed): return k == 1 ? String(localized: "Depth focus removed", comment: "History row caption phrase (phrases are joined with \" · \")") : String(localized: "\(k) depth focus regions removed", comment: "History row caption phrase (phrases are joined with \" · \")")
        case ("focusRegions", .edited): return k == 1 ? String(localized: "Depth focus edited", comment: "History row caption phrase (phrases are joined with \" · \")") : String(localized: "\(k) depth focus regions edited", comment: "History row caption phrase (phrases are joined with \" · \")")
        case ("cameraLayoutRegions", .added): return k == 1 ? String(localized: "Camera layout added", comment: "History row caption phrase (phrases are joined with \" · \")") : String(localized: "\(k) camera layouts added", comment: "History row caption phrase (phrases are joined with \" · \")")
        case ("cameraLayoutRegions", .removed): return k == 1 ? String(localized: "Camera layout removed", comment: "History row caption phrase (phrases are joined with \" · \")") : String(localized: "\(k) camera layouts removed", comment: "History row caption phrase (phrases are joined with \" · \")")
        case ("cameraLayoutRegions", .edited): return k == 1 ? String(localized: "Camera layout edited", comment: "History row caption phrase (phrases are joined with \" · \")") : String(localized: "\(k) camera layouts edited", comment: "History row caption phrase (phrases are joined with \" · \")")
        case ("annotations", .added): return k == 1 ? String(localized: "Annotation added", comment: "History row caption phrase (phrases are joined with \" · \")") : String(localized: "\(k) annotations added", comment: "History row caption phrase (phrases are joined with \" · \")")
        case ("annotations", .removed): return k == 1 ? String(localized: "Annotation removed", comment: "History row caption phrase (phrases are joined with \" · \")") : String(localized: "\(k) annotations removed", comment: "History row caption phrase (phrases are joined with \" · \")")
        case ("annotations", .edited): return k == 1 ? String(localized: "Annotation edited", comment: "History row caption phrase (phrases are joined with \" · \")") : String(localized: "\(k) annotations edited", comment: "History row caption phrase (phrases are joined with \" · \")")
        case ("voiceOverClips", .added): return k == 1 ? String(localized: "Voice-over added", comment: "History row caption phrase (phrases are joined with \" · \")") : String(localized: "\(k) voice-overs added", comment: "History row caption phrase (phrases are joined with \" · \")")
        case ("voiceOverClips", .removed): return k == 1 ? String(localized: "Voice-over removed", comment: "History row caption phrase (phrases are joined with \" · \")") : String(localized: "\(k) voice-overs removed", comment: "History row caption phrase (phrases are joined with \" · \")")
        case ("voiceOverClips", .edited): return k == 1 ? String(localized: "Voice-over edited", comment: "History row caption phrase (phrases are joined with \" · \")") : String(localized: "\(k) voice-overs edited", comment: "History row caption phrase (phrases are joined with \" · \")")
        case ("subtitles", .added): return k == 1 ? String(localized: "Caption added", comment: "History row caption phrase (phrases are joined with \" · \")") : String(localized: "\(k) captions added", comment: "History row caption phrase (phrases are joined with \" · \")")
        case ("subtitles", .removed): return k == 1 ? String(localized: "Caption removed", comment: "History row caption phrase (phrases are joined with \" · \")") : String(localized: "\(k) captions removed", comment: "History row caption phrase (phrases are joined with \" · \")")
        case ("subtitles", .edited): return k == 1 ? String(localized: "Caption edited", comment: "History row caption phrase (phrases are joined with \" · \")") : String(localized: "\(k) captions edited", comment: "History row caption phrase (phrases are joined with \" · \")")
        default: return k == 1 ? "\(key) \(verb.rawValue)" : "\(k) \(key) \(verb.rawValue)"
        }
    }

    private static func phrases(_ cs: ChangeSet) -> [String] {
        let fields = Set(cs.fields)
        var parts: [String] = []
        if clipFields.contains(where: fields.contains) { parts.append(String(localized: "Clips edited", comment: "History row caption phrase (phrases are joined with \" · \")")) }
        if trimFields.contains(where: fields.contains) { parts.append(String(localized: "Trim changed", comment: "History row caption phrase (phrases are joined with \" · \")")) }
        if recordingFields.contains(where: fields.contains) { parts.append(String(localized: "Recording replaced", comment: "History row caption phrase (phrases are joined with \" · \")")) }

        var known: Set<String> = [captionNoun.0]
        for (key, _, _) in timelineNouns {
            known.insert(key)
            if let c = cs.items[key] { parts += collectionPhrases(c, key) }
        }

        var knownTabs = Set<String>()
        for (tab, phrase) in tabPhrases {
            knownTabs.insert(tab)
            if let keys = cs.settings[tab], !keys.isEmpty { parts.append(phrase) }
        }
        if cs.settings.contains(where: { !knownTabs.contains($0.key) && !$0.value.isEmpty }) {
            parts.append(otherSettingsPhrase)
        }

        if let c = cs.items[captionNoun.0] { parts += collectionPhrases(c, captionNoun.0) }

        var claimed = Set(clipFields + trimFields + recordingFields)
        for (field, phrase) in trailingFields {
            claimed.insert(field)
            if fields.contains(field) { parts.append(phrase) }
        }
        let otherField = cs.fields.contains { !claimed.contains($0) }
        let otherItem = cs.items.keys.contains { !known.contains($0) }
        if otherField || otherItem { parts.append(otherPhrase) }
        return parts
    }

    /// With `maxParts` > 0 and more phrases than that, the rest collapse into
    /// "+N more". An empty change-set reads "No changes".
    static func format(_ cs: ChangeSet, maxParts: Int = 0) -> String {
        let parts = phrases(cs)
        if parts.isEmpty { return String(localized: "No changes", comment: "History row caption: a version with no changes") }
        if maxParts > 0 && parts.count > maxParts {
            return (Array(parts.prefix(maxParts)) + [String(localized: "+\(parts.count - maxParts) more", comment: "History row caption: how many more change phrases are hidden")]).joined(separator: separator)
        }
        return parts.joined(separator: separator)
    }

    /// Each added / removed / edited element, a reorder or a replaced legacy
    /// collection counts 1; each changed settings tab 1; each field phrase 1.
    static func countChanges(_ cs: ChangeSet) -> Int {
        var n = 0
        for (_, c) in cs.items {
            if c.replaced {
                n += 1
                continue
            }
            let k = c.countsValue
            n += k.added + k.removed + k.changed + (c.reordered ? 1 : 0)
        }
        n += cs.settings.values.filter { !$0.isEmpty }.count
        let fields = Set(cs.fields)
        if clipFields.contains(where: fields.contains) { n += 1 }
        if trimFields.contains(where: fields.contains) { n += 1 }
        if recordingFields.contains(where: fields.contains) { n += 1 }
        var claimed = Set(clipFields + trimFields + recordingFields)
        for (field, _) in trailingFields {
            claimed.insert(field)
            if fields.contains(field) { n += 1 }
        }
        if cs.fields.contains(where: { !claimed.contains($0) }) { n += 1 }
        return n
    }
}
