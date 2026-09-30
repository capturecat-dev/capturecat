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
        ("background", "Background changed"),
        ("cursor", "Cursor changed"),
        ("camera", "Camera changed"),
        ("audio", "Audio changed"),
        ("effects", "Effects changed"),
        ("motion", "Motion changed"),
        ("subtitles", "Caption style changed"),
        ("brand", "Brand changed"),
        ("canvas", "Aspect ratio changed"),
        ("export", "Export settings changed"),
    ]
    private static let otherSettingsPhrase = "Settings changed"

    private static let clipFields = ["videoClipSegments", "splitPoints"]
    private static let trimFields = ["trimStart", "trimEnd"]
    private static let recordingFields = [
        "sourceSegments", "duration", "videoURL", "cursorDataURL", "keystrokeDataURL",
        "cameraVideoURL", "cameraTimeOffset", "recordingSourceKind",
    ]
    private static let trailingFields: [(String, String)] = [
        ("name", "Renamed"),
        ("stillTreatment", "Image/video mode changed"),
        ("reminderDate", "Reminder changed"),
    ]
    private static let otherPhrase = "Other changes"

    private static func capitalize(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }

    private static func collectionPhrases(_ c: CollectionChange, _ singular: String, _ plural: String) -> [String] {
        if c.replaced { return ["\(capitalize(plural)) changed"] }
        let n = c.countsValue
        var out: [String] = []
        func counted(_ k: Int, _ verb: String) -> String {
            k == 1 ? "\(singular) \(verb)" : "\(k) \(plural) \(verb)"
        }
        if n.added > 0 { out.append(counted(n.added, "added")) }
        if n.removed > 0 { out.append(counted(n.removed, "removed")) }
        if n.changed > 0 { out.append(counted(n.changed, "edited")) }
        if c.reordered { out.append("\(capitalize(plural)) reordered") }
        return out
    }

    private static func phrases(_ cs: ChangeSet) -> [String] {
        let fields = Set(cs.fields)
        var parts: [String] = []
        if clipFields.contains(where: fields.contains) { parts.append("Clips edited") }
        if trimFields.contains(where: fields.contains) { parts.append("Trim changed") }
        if recordingFields.contains(where: fields.contains) { parts.append("Recording replaced") }

        var known: Set<String> = [captionNoun.0]
        for (key, singular, plural) in timelineNouns {
            known.insert(key)
            if let c = cs.items[key] { parts += collectionPhrases(c, singular, plural) }
        }

        var knownTabs = Set<String>()
        for (tab, phrase) in tabPhrases {
            knownTabs.insert(tab)
            if let keys = cs.settings[tab], !keys.isEmpty { parts.append(phrase) }
        }
        if cs.settings.contains(where: { !knownTabs.contains($0.key) && !$0.value.isEmpty }) {
            parts.append(otherSettingsPhrase)
        }

        if let c = cs.items[captionNoun.0] { parts += collectionPhrases(c, captionNoun.1, captionNoun.2) }

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
        if parts.isEmpty { return "No changes" }
        if maxParts > 0 && parts.count > maxParts {
            return (Array(parts.prefix(maxParts)) + ["+\(parts.count - maxParts) more"]).joined(separator: separator)
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
