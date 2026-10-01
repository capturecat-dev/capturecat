import AppKit

/// "Compare with Current" — what changed between a version and the project
/// as it is now, grouped by where you would edit it (Clips & trim, Timeline,
/// Captions, each inspector tab), one `CCAccordion` item per group inside a
/// `CCDialog`. The diff is the shared `ProjectDiff` on raw JSON (the same
/// change-set the server stores); element lines name their time span
/// ("Zoom added · 0:12–0:15").
@MainActor
final class VersionCompareDialog {
    struct Group: Equatable {
        let title: String
        let lines: [String]
    }

    private let dialog: CCDialog
    private let accordion = CCAccordion(mode: .multiple, chrome: .card)
    private let summary = CCWrappingLabel()
    let groups: [Group]
    private var themeObservation: CCThemeObservation?

    init(version: CloudVersion, versionDocument: Data, currentDocument: Data, projectName: String) {
        let from = (try? JSONValue.parse(data: versionDocument)) ?? .object(JSONObject())
        let to = (try? JSONValue.parse(data: currentDocument)) ?? .object(JSONObject())
        groups = Self.groups(from: from, to: to)
        dialog = CCDialog(title: "Compare with current",
                          subtitle: "\(projectName) · \(HistoryPaneAppKit.stamp(version.date)) → now",
                          width: 520)
        dialog.entrance = .slideUp()

        let count = groups.reduce(0) { $0 + $1.lines.count }
        summary.stringValue = count == 0
            ? "No differences — this version matches the current project."
            : (count == 1 ? "1 change since this version." : "\(count) changes since this version.")
        dialog.addContent(summary)
        if !groups.isEmpty {
            for group in groups {
                accordion.addItem(title: "\(group.title) (\(group.lines.count))",
                                  text: group.lines.map { "• \($0)" }.joined(separator: "\n"))
            }
            accordion.setExpanded(true, at: 0, animated: false)
            dialog.addContent(accordion)
        }
        dialog.setMaxContentHeight(420)
        let close = CCButton(title: "Done", style: .primary, size: .regular)
        close.onClick = { [weak self] in self?.dialog.dismiss() }
        dialog.addFooter(close)
        dialog.onEscape = { [weak self] in self?.dialog.dismiss() }
        themeObservation = CCThemeObservation { [weak self] in
            self?.summary.font = CCTheme.font.label
            self?.summary.textColor = CCTheme.color.mutedForeground
        }
    }

    func present(over window: NSWindow) { dialog.present(over: window) }
    func dismiss(completion: (() -> Void)? = nil) { dialog.dismiss(completion: completion) }

    var probeCard: NSView { dialog.card }
    var probeAccordion: CCAccordion { accordion }

    // MARK: - Grouping (pure — `--history-panel-shot` checks it)

    static let laneOrder: [(key: String, noun: String)] = [
        ("zoomRegions", "Zoom"), ("tiltRegions", "Tilt"), ("speedRegions", "Speed region"),
        ("blurRegions", "Blur"), ("highlightRegions", "Highlight"), ("focusRegions", "Depth focus"),
        ("cameraLayoutRegions", "Camera layout"), ("annotations", "Annotation"), ("voiceOverClips", "Voice-over"),
    ]

    static let tabTitles: [(tab: String, title: String)] = [
        ("background", "Background"), ("cursor", "Cursor"), ("camera", "Camera"), ("audio", "Audio"),
        ("effects", "Effects"), ("motion", "Motion"), ("subtitles", "Caption style"), ("brand", "Brand"),
        ("canvas", "Canvas"), ("export", "Export"), ("other", "Other settings"),
    ]

    static func groups(from: JSONValue, to: JSONValue) -> [Group] {
        let cs = ProjectDiff.diff(from, to)
        var out: [Group] = []

        let clipFields: Set<String> = ["videoClipSegments", "splitPoints", "trimStart", "trimEnd"]
        let recordingFields: Set<String> = ["sourceSegments", "duration", "videoURL", "cursorDataURL", "keystrokeDataURL",
                                            "cameraVideoURL", "cameraTimeOffset", "recordingSourceKind"]
        var clipLines: [String] = []
        if cs.fields.contains(where: { ["videoClipSegments", "splitPoints"].contains($0) }) { clipLines.append("Clips edited") }
        if cs.fields.contains(where: { ["trimStart", "trimEnd"].contains($0) }) {
            clipLines.append("Trim \(span(of: from)) → \(span(of: to))")
        }
        if cs.fields.contains(where: recordingFields.contains) { clipLines.append("Recording replaced") }
        if !clipLines.isEmpty { out.append(Group(title: "Clips & trim", lines: clipLines)) }

        var timeline: [String] = []
        for (key, noun) in laneOrder {
            guard let change = cs.items[key] else { continue }
            timeline += itemLines(change, key: key, noun: noun, from: from, to: to)
        }
        if !timeline.isEmpty { out.append(Group(title: "Timeline", lines: timeline)) }

        if let change = cs.items["subtitles"] {
            out.append(Group(title: "Captions", lines: itemLines(change, key: "subtitles", noun: "Caption", from: from, to: to)))
        }

        for (tab, title) in tabTitles {
            guard let keys = cs.settings[tab], !keys.isEmpty else { continue }
            out.append(Group(title: title, lines: keys.map { $0 == "*" ? "Settings changed" : humanize($0) + " changed" }))
        }

        var other: [String] = []
        let claimed = clipFields.union(recordingFields)
        for field in cs.fields where !claimed.contains(field) {
            switch field {
            case "name": other.append("Renamed “\(from.get("name")?.stringValue ?? "")” → “\(to.get("name")?.stringValue ?? "")”")
            case "*": other.append("Document replaced")
            default: other.append(humanize(field) + " changed")
            }
        }
        let known = Set(laneOrder.map(\.key) + ["subtitles"])
        for key in cs.items.keys.sorted() where !known.contains(key) { other.append(humanize(key) + " changed") }
        if !other.isEmpty { out.append(Group(title: "Other", lines: other)) }
        return out
    }

    private static func itemLines(_ change: CollectionChange, key: String, noun: String,
                                  from: JSONValue, to: JSONValue) -> [String] {
        if change.replaced { return ["\(noun)s changed"] }
        if let counts = change.counts {
            var lines: [String] = []
            if counts.added > 0 { lines.append("\(counts.added) \(plural(noun, counts.added)) added") }
            if counts.removed > 0 { lines.append("\(counts.removed) \(plural(noun, counts.removed)) removed") }
            if counts.changed > 0 { lines.append("\(counts.changed) \(plural(noun, counts.changed)) edited") }
            if change.reordered { lines.append("\(noun)s reordered") }
            return lines
        }
        var lines: [String] = []
        for id in change.added { lines.append("\(noun) added\(timing(of: id, in: to.get(key)))") }
        for id in change.removed { lines.append("\(noun) removed\(timing(of: id, in: from.get(key)))") }
        for id in change.changed.keys.sorted() {
            let fields = (change.changed[id] ?? []).filter { $0 != "id" }.map(humanize).joined(separator: ", ")
            lines.append("\(noun) edited\(timing(of: id, in: to.get(key)))" + (fields.isEmpty ? "" : " — \(fields.lowercased())"))
        }
        if change.reordered { lines.append("\(noun)s reordered") }
        return lines
    }

    private static func plural(_ noun: String, _ n: Int) -> String {
        n == 1 ? noun.lowercased() : noun.lowercased() + "s"
    }

    /// " · 0:12–0:15" for an element with a time span (voice-overs: start + duration).
    private static func timing(of id: String, in collection: JSONValue?) -> String {
        guard let element = collection?.arrayValue?.first(where: { $0.get("id")?.stringValue == id }),
              let start = element.get("startTime")?.numberValue else { return "" }
        let end = element.get("endTime")?.numberValue ?? element.get("duration")?.numberValue.map { start + $0 }
        guard let end else { return " · \(clock(start))" }
        return " · \(clock(start))–\(clock(end))"
    }

    private static func span(of doc: JSONValue) -> String {
        let start = doc.get("trimStart")?.numberValue ?? 0
        guard let end = doc.get("trimEnd")?.numberValue else { return clock(start) }
        return "\(clock(start))–\(clock(end))"
    }

    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }

    /// "backgroundPadding" → "Background padding".
    static func humanize(_ key: String) -> String {
        var words: [String] = []
        var current = ""
        for character in key {
            if character.isUppercase, !current.isEmpty {
                words.append(current)
                current = String(character).lowercased()
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        guard let first = words.first else { return key }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst()).joined(separator: " ")
    }
}
