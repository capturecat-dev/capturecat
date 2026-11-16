import Foundation

// The History pane's words, rows, menus, Compare groups and Merge Review
// captions — ONE copy for the Mac (HistoryPaneAppKit, HistoryRowView,
// VersionPreviewController, VersionCompareDialog, MergeReviewDialog) and the
// iOS studio (apps/ios/StudioUI/History). Moved verbatim out of those Mac
// views; the only additions are a pinnable clock (so a transcript can name
// days without the wall clock) and the device noun ("this Mac" / "this iPad").

/// What "today", the time zone and the locale are when History formats a
/// date. `.current` is exactly the Mac pane's behaviour (wall clock, the
/// user's locale); transcripts pin all three.
nonisolated struct HistoryClock: Sendable {
    var calendar: Calendar
    var locale: Locale?
    var timeZone: TimeZone?
    var now: Date?

    static var current: HistoryClock { HistoryClock(calendar: .current, locale: nil, timeZone: nil, now: nil) }

    /// Gregorian, `en_US`, `timeZone`, today = `now` — what the Mac
    /// `--history-transcript` and StudioLab `--history` both use.
    static func pinned(now: Date, timeZone: TimeZone, locale: Locale = Locale(identifier: "en_US")) -> HistoryClock {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = locale
        return HistoryClock(calendar: calendar, locale: locale, timeZone: timeZone, now: now)
    }

    var isPinned: Bool { now != nil }
    var date: Date { now ?? Date() }

    func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        if let locale { formatter.locale = locale }
        if let timeZone { formatter.timeZone = timeZone }
        if isPinned { formatter.calendar = calendar }
        return formatter
    }

    func isToday(_ day: Date) -> Bool {
        guard let now else { return calendar.isDateInToday(day) }
        return calendar.isDate(day, inSameDayAs: now)
    }

    func isYesterday(_ day: Date) -> Bool {
        guard let now else { return calendar.isDateInYesterday(day) }
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else { return false }
        return calendar.isDate(day, inSameDayAs: yesterday)
    }
}

nonisolated enum HistoryWords {
    // MARK: Dates (HistoryPaneAppKit)

    static func dayTitle(_ day: Date, clock: HistoryClock = .current) -> String {
        if clock.isToday(day) { return "Today" }
        if clock.isYesterday(day) { return "Yesterday" }
        let formatter = clock.formatter()
        formatter.setLocalizedDateFormatFromTemplate(
            clock.calendar.isDate(day, equalTo: clock.date, toGranularity: .year) ? "EEEEMMMd" : "MMMdyyyy")
        return formatter.string(from: day)
    }

    static func timeText(_ date: Date?, clock: HistoryClock = .current) -> String {
        guard let date else { return "—" }
        let formatter = clock.formatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    /// "Sep 28, 3:42 PM".
    static func stamp(_ date: Date?, clock: HistoryClock = .current) -> String {
        guard let date else { return "an earlier version" }
        let formatter = clock.formatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMdjmm")
        return formatter.string(from: date)
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    /// The pane's day sections: versions (newest first) grouped by the start
    /// of their day, in order.
    static func days(_ versions: [CloudVersion], clock: HistoryClock = .current) -> [(day: Date, versions: [CloudVersion])] {
        var days: [(day: Date, versions: [CloudVersion])] = []
        for version in versions {
            let day = clock.calendar.startOfDay(for: version.date ?? Date())
            if let last = days.last, last.day == day {
                days[days.count - 1].versions.append(version)
            } else {
                days.append((day, [version]))
            }
        }
        return days
    }

    /// The head the pane marks Current.
    static func headID(of page: CloudVersionPage) -> String? {
        page.headVersionID ?? page.versions.first?.id
    }

    // MARK: Footer

    /// "Kept for 30 days · 1 of 25 named".
    static func retentionCaption(_ page: CloudVersionPage) -> String? {
        var parts: [String] = []
        if let days = page.retention?.historyDays, days > 0 { parts.append("Kept for \(days) days") }
        if let max = page.retention?.maxNamed, max > 0 {
            parts.append("\(page.retention?.namedCount ?? page.versions.filter(\.isNamed).count) of \(max) named")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func pinnedMediaCaption(_ page: CloudVersionPage) -> String {
        "History keeps \(bytes(page.pinnedMediaBytes)) of removed media"
    }

    // MARK: Preview (VersionPreviewController)

    /// "Viewing Sep 28, 3:42 PM — Ana on Web"; an agent's or mixed save
    /// names the badge instead ("Ana (Agent via Web)").
    static func previewTitle(for version: CloudVersion, clock: HistoryClock = .current) -> String {
        let who: String
        switch (version.actorName, version.source) {
        case (let name?, "human"): who = "\(name) on \(version.clientLabel)"
        case (let name?, _): who = "\(name) (\(version.clientLabel))"
        default: who = version.clientLabel
        }
        return "Viewing \(stamp(version.date, clock: clock)) — \(who)"
    }

    static let previewMessage = "Read-only preview — edits here are not saved."

    // MARK: Confirmations

    static func restoreTitle(_ version: CloudVersion, clock: HistoryClock = .current) -> String {
        "Restore the version from \(stamp(version.date, clock: clock))?"
    }

    static let restoreMessage = "Your current version stays in History — restoring adds this one as the newest version."

    static func restoredToast(_ version: CloudVersion, clock: HistoryClock = .current) -> String {
        "Restored the version from \(stamp(version.date, clock: clock))"
    }

    static let restoredToastMessage = "The version before it is still in History."

    static func nameTitle(isNamed: Bool) -> String { isNamed ? "Rename this version" : "Name this version" }
    static let nameMessage = "Named versions are kept beyond the history window, so you can always come back to them."
    static let namePlaceholder = "e.g. Sent to client"

    static let deleteTitle = "Delete this version?"
    static func deleteMessage(_ version: CloudVersion, clock: HistoryClock = .current) -> String {
        "The version from \(stamp(version.date, clock: clock)) is removed from History for everyone."
    }
}

// MARK: - Rows (HistoryRowView)

/// What one History row shows: author, time, badges, summary.
nonisolated struct HistoryRowModel: Equatable, Sendable {
    enum BadgeStyle: String, Sendable { case subtle, primary, outline }

    struct Badge: Equatable, Sendable {
        let text: String
        let style: BadgeStyle
    }

    let versionID: String
    let isHead: Bool
    let timeText: String
    let author: String
    let summary: String
    /// The full summary (no phrase limit) — the Mac's tooltip.
    let fullSummary: String
    let badges: [Badge]

    init(version: CloudVersion, isHead: Bool, timeText: String) {
        versionID = version.id
        self.isHead = isHead
        self.timeText = timeText
        author = version.actorName ?? "Someone"
        summary = version.summary
        fullSummary = version.change.map { ChangeSummary.format($0) } ?? version.summary
        var list: [Badge] = [Badge(text: version.clientLabel, style: .subtle)]
        if let label = version.label, !label.isEmpty { list.insert(Badge(text: label, style: .primary), at: 0) }
        if isHead { list.append(Badge(text: "Current", style: .outline)) }
        if version.kind == "merge" { list.append(Badge(text: "Merge", style: .outline)) }
        if version.kind == "restore" { list.append(Badge(text: "Restored", style: .outline)) }
        badges = list
    }

    func accessibilityLabel(clientLabel: String) -> String {
        "\(timeText), \(author), \(clientLabel). \(summary)"
    }
}

// MARK: - Row menu (HistoryPaneAppKit.showMenu)

nonisolated enum HistoryRowAction: Equatable, Sendable {
    case preview
    case name(isNamed: Bool)
    case compareWithCurrent
    case restore
    case delete

    var title: String {
        switch self {
        case .preview: return "Preview"
        case .name(let isNamed): return isNamed ? "Rename Version…" : "Name This Version…"
        case .compareWithCurrent: return "Compare with Current"
        case .restore: return "Restore This Version…"
        case .delete: return "Delete Version…"
        }
    }

    /// The Mac row menu, in order (a separator goes before `.restore`).
    static func items(isHead: Bool, isNamed: Bool, isOwner: Bool?) -> [HistoryRowAction] {
        var items: [HistoryRowAction] = []
        if !isHead { items.append(.preview) }
        items.append(.name(isNamed: isNamed))
        if !isHead {
            items.append(.compareWithCurrent)
            items.append(.restore)
            if isOwner != false { items.append(.delete) }
        }
        return items
    }
}

// MARK: - Compare (VersionCompareDialog)

/// "Compare" — what changed between two documents, grouped by where you
/// would edit it (Clips & trim, Timeline, Captions, each inspector tab). The
/// diff is the shared `ProjectDiff` on raw JSON (the same change-set the
/// server stores); element lines name their time span ("Zoom added · 0:12–0:15").
nonisolated enum VersionCompareGroups {
    struct Group: Equatable, Sendable {
        let title: String
        let lines: [String]
    }

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

    /// "No differences…" / "1 change since this version." / "N changes since this version."
    static func summary(_ groups: [Group]) -> String {
        let count = groups.reduce(0) { $0 + $1.lines.count }
        return count == 0
            ? "No differences — this version matches the current project."
            : (count == 1 ? "1 change since this version." : "\(count) changes since this version.")
    }

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

// MARK: - Merge Review (MergeReviewDialog)

/// Merge Review's captions. `device` is the noun for THIS side ("Mac" on the
/// Mac — the dialog's original words — "iPad" / "iPhone" on iOS).
nonisolated enum MergeReviewWords {
    static func dialogTitle(conflicts count: Int) -> String {
        count == 1 ? "Review 1 conflict" : "Review \(count) conflicts"
    }

    static func intro(theirs who: String, device: String) -> String {
        "\(who) changed this project while it was also edited on this \(device). "
            + "Choose which side to keep where the two can't be combined — everything else is already merged."
    }

    static let segments = ["Mine", "Theirs"]

    static func autoResolvedTitle(_ n: Int) -> String {
        n == 1 ? "1 clash settled automatically (latest edit wins)"
            : "\(n) clashes settled automatically (latest edit wins)"
    }

    static func theirsName(author: CloudVersionAuthor?, fallback: String = "The web editor") -> String {
        if let name = author?.name, !name.isEmpty {
            if let label = author?.clientLabel, !label.isEmpty { return "\(name) (\(label))" }
            return name
        }
        return fallback
    }

    /// "Annotation", "Zoom", "Caption word"… for a collection path.
    static func noun(forPath path: String) -> String {
        let key = path.split(separator: "[").first.map(String.init) ?? path
        if path.contains(".words[") { return "Caption word" }
        switch key {
        case "zoomRegions": return "Zoom"
        case "tiltRegions": return "Tilt"
        case "speedRegions": return "Speed region"
        case "blurRegions": return "Blur"
        case "highlightRegions": return "Highlight"
        case "focusRegions": return "Depth focus"
        case "cameraLayoutRegions": return "Camera layout"
        case "annotations": return "Annotation"
        case "voiceOverClips": return "Voice-over"
        case "subtitles": return "Caption"
        default: return "Item"
        }
    }

    static func title(for conflict: MergeConflict) -> String {
        switch conflict.kind {
        case "clipStructure": return "Clips and trim"
        case "deleteVsModify": return noun(forPath: conflict.path)
        case "subtitlesRegenerated": return "Captions"
        case "laneOverlap":
            let lane = conflict.lane.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Timeline"
            return "\(lane) lane overlap"
        default: return conflict.path
        }
    }

    static func detail(for conflict: MergeConflict, theirs: String, device: String = "Mac") -> String {
        switch conflict.kind {
        case "clipStructure":
            return "The clips were cut or trimmed on both sides. Mine keeps this \(device)'s clips; Theirs keeps \(theirs)'s."
        case "deleteVsModify":
            let noun = noun(forPath: conflict.path).lowercased()
            return conflict.deletedBy == .mine
                ? "Deleted on this \(device) but edited by \(theirs). Mine deletes the \(noun); Theirs keeps the edit."
                : "Deleted by \(theirs) but edited on this \(device). Mine keeps the edit; Theirs deletes the \(noun)."
        case "subtitlesRegenerated":
            let by = conflict.regeneratedBy == "mine" ? "on this \(device)" : conflict.regeneratedBy == "theirs" ? "by \(theirs)" : "on both sides"
            return "Captions were regenerated \(by) and edited on the other side. Pick one set of captions."
        case "laneOverlap":
            return "Combining both sides would make two items overlap on this lane. Pick whose timing to keep for both."
        default:
            return "Both sides changed this."
        }
    }

    static func describe(_ item: MergeAutoResolved, device: String = "Mac") -> String {
        let side = item.winner == .mine ? "this \(device)" : "theirs"
        let what: String
        switch item.kind {
        case "order": what = "\(noun(forPath: item.path)) order"
        default: what = item.path
        }
        return "• \(what) — kept \(side)"
    }
}
