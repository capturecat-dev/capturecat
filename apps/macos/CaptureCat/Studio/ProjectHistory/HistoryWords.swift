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
        if clock.isToday(day) { return String(localized: "Today", comment: "History pane: day section header") }
        if clock.isYesterday(day) { return String(localized: "Yesterday", comment: "History pane: day section header") }
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
        guard let date else { return String(localized: "an earlier version", comment: "History: stands in for a version's date when it has none (e.g. \"Restore the version from an earlier version?\")") }
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
        if let days = page.retention?.historyDays, days > 0 {
            parts.append(String(localized: "Kept for \(days) days", comment: "History pane footer: how long versions are kept"))
        }
        if let max = page.retention?.maxNamed, max > 0 {
            let named = page.retention?.namedCount ?? page.versions.filter(\.isNamed).count
            parts.append(String(localized: "\(named) of \(max) named", comment: "History pane footer: named versions used of the plan's limit"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func pinnedMediaCaption(_ page: CloudVersionPage) -> String {
        let size = bytes(page.pinnedMediaBytes)
        return String(localized: "History keeps \(size) of removed media", comment: "History pane footer; %@ is a file size such as 12 MB")
    }

    // MARK: Preview (VersionPreviewController)

    /// "Viewing Sep 28, 3:42 PM — Ana on Web"; an agent's or mixed save
    /// names the badge instead ("Ana (Agent via Web)").
    static func previewTitle(for version: CloudVersion, clock: HistoryClock = .current) -> String {
        let when = stamp(version.date, clock: clock)
        let client = version.clientLabel
        switch (version.actorName.map(HistoryWords.actorDisplayName), version.source) {
        case (let name?, "human"):
            return String(localized: "Viewing \(when) — \(name) on \(client)",
                          comment: "Version preview banner: date, person, app they used (Mac, Web, iOS)")
        case (let name?, _):
            return String(localized: "Viewing \(when) — \(name) (\(client))",
                          comment: "Version preview banner: date, person, client badge (e.g. Agent via Web)")
        default:
            return String(localized: "Viewing \(when) — \(client)",
                          comment: "Version preview banner: date, client badge (Mac, Web, Agent via Web)")
        }
    }

    /// A stored actor name for display: the iOS studio records its own
    /// saves as "You" (history identity — stays English on disk); that word
    /// is shown in the reader's language.
    static func actorDisplayName(_ stored: String) -> String {
        stored == "You" ? String(localized: "You", comment: "History: author of a version saved on this device") : stored
    }

    static let previewMessage = String(localized: "Read-only preview — edits here are not saved.", comment: "Version preview banner message")

    // MARK: Confirmations

    static func restoreTitle(_ version: CloudVersion, clock: HistoryClock = .current) -> String {
        let when = stamp(version.date, clock: clock)
        return String(localized: "Restore the version from \(when)?", comment: "History restore confirmation title; %@ is a date and time")
    }

    static let restoreMessage = String(localized: "Your current version stays in History — restoring adds this one as the newest version.", comment: "History restore confirmation message")

    static func restoredToast(_ version: CloudVersion, clock: HistoryClock = .current) -> String {
        let when = stamp(version.date, clock: clock)
        return String(localized: "Restored the version from \(when)", comment: "Toast after restoring a version; %@ is a date and time")
    }

    static let restoredToastMessage = String(localized: "The version before it is still in History.", comment: "Toast message after restoring a version")

    static func nameTitle(isNamed: Bool) -> String {
        isNamed ? String(localized: "Rename this version", comment: "History: prompt title")
            : String(localized: "Name this version", comment: "History: prompt title")
    }
    static let nameMessage = String(localized: "Named versions are kept beyond the history window, so you can always come back to them.", comment: "History: name-version prompt message")
    static let namePlaceholder = String(localized: "e.g. Sent to client", comment: "History: placeholder for a version name")

    static let deleteTitle = String(localized: "Delete this version?", comment: "History: delete confirmation title")
    static func deleteMessage(_ version: CloudVersion, clock: HistoryClock = .current) -> String {
        let when = stamp(version.date, clock: clock)
        return String(localized: "The version from \(when) is removed from History for everyone.", comment: "History delete confirmation message; %@ is a date and time")
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
        author = version.actorName.map(HistoryWords.actorDisplayName) ?? String(localized: "Someone", comment: "History row author when the name is unknown")
        summary = version.summary
        fullSummary = version.change.map { ChangeSummary.format($0) } ?? version.summary
        var list: [Badge] = [Badge(text: version.clientLabel, style: .subtle)]
        if let label = version.label, !label.isEmpty { list.insert(Badge(text: label, style: .primary), at: 0) }
        if isHead { list.append(Badge(text: String(localized: "Current", comment: "History row badge: the current version"), style: .outline)) }
        if version.kind == "merge" { list.append(Badge(text: String(localized: "Merge", comment: "History row badge: a version that merged edits"), style: .outline)) }
        if version.kind == "restore" { list.append(Badge(text: String(localized: "Restored", comment: "History row badge: a version restored from an earlier one"), style: .outline)) }
        badges = list
    }

    func accessibilityLabel(clientLabel: String) -> String {
        String(localized: "\(timeText), \(author), \(clientLabel). \(summary)",
               comment: "VoiceOver label for a History row: time, author, client badge, change summary")
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
        case .preview: return String(localized: "Preview", comment: "History row menu: preview this version")
        case .name(let isNamed):
            return isNamed ? String(localized: "Rename Version…", comment: "History row menu")
                : String(localized: "Name This Version…", comment: "History row menu")
        case .compareWithCurrent: return String(localized: "Compare with Current", comment: "History row menu")
        case .restore: return String(localized: "Restore This Version…", comment: "History row menu")
        case .delete: return String(localized: "Delete Version…", comment: "History row menu")
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
        ("background", String(localized: "Background", comment: "History Compare dialog: a group title (inspector tab)")), ("cursor", String(localized: "Cursor", comment: "History Compare dialog: a group title (inspector tab)")), ("camera", String(localized: "Camera", comment: "History Compare dialog: a group title (inspector tab)")), ("audio", String(localized: "Audio", comment: "History Compare dialog: a group title (inspector tab)")),
        ("effects", String(localized: "Effects", comment: "History Compare dialog: a group title (inspector tab)")), ("motion", String(localized: "Motion", comment: "History Compare dialog: a group title (inspector tab)")), ("subtitles", String(localized: "Caption style", comment: "History Compare dialog: a group title (inspector tab)")), ("brand", String(localized: "Brand", comment: "History Compare dialog: a group title (inspector tab)")),
        ("canvas", String(localized: "Canvas", comment: "History Compare dialog: a group title (inspector tab)")), ("export", String(localized: "Export", comment: "History Compare dialog: a group title (inspector tab)")), ("other", String(localized: "Other settings", comment: "History Compare dialog: a group title (inspector tab)")),
    ]

    /// "No differences…" / "1 change since this version." / "N changes since this version."
    static func summary(_ groups: [Group]) -> String {
        let count = groups.reduce(0) { $0 + $1.lines.count }
        return count == 0
            ? String(localized: "No differences — this version matches the current project.", comment: "History Compare dialog summary")
            : (count == 1 ? String(localized: "1 change since this version.", comment: "History Compare dialog summary")
                : String(localized: "\(count) changes since this version.", comment: "History Compare dialog summary"))
    }

    static func groups(from: JSONValue, to: JSONValue) -> [Group] {
        let cs = ProjectDiff.diff(from, to)
        var out: [Group] = []

        let clipFields: Set<String> = ["videoClipSegments", "splitPoints", "trimStart", "trimEnd"]
        let recordingFields: Set<String> = ["sourceSegments", "duration", "videoURL", "cursorDataURL", "keystrokeDataURL",
                                            "cameraVideoURL", "cameraTimeOffset", "recordingSourceKind"]
        var clipLines: [String] = []
        if cs.fields.contains(where: { ["videoClipSegments", "splitPoints"].contains($0) }) { clipLines.append(String(localized: "Clips edited", comment: "History Compare dialog line")) }
        if cs.fields.contains(where: { ["trimStart", "trimEnd"].contains($0) }) {
            let before = span(of: from), after = span(of: to)
            clipLines.append(String(localized: "Trim \(before) → \(after)", comment: "History Compare dialog line; old and new trim spans such as 0:02–1:30"))
        }
        if cs.fields.contains(where: recordingFields.contains) { clipLines.append(String(localized: "Recording replaced", comment: "History Compare dialog line")) }
        if !clipLines.isEmpty { out.append(Group(title: String(localized: "Clips & trim", comment: "History Compare dialog: a group title"), lines: clipLines)) }

        var timeline: [String] = []
        for (key, _) in laneOrder {
            guard let change = cs.items[key] else { continue }
            timeline += itemLines(change, key: key, from: from, to: to)
        }
        if !timeline.isEmpty {
            out.append(Group(title: String(localized: "Timeline", comment: "History Compare dialog: a group title"), lines: timeline))
        }

        if let change = cs.items["subtitles"] {
            out.append(Group(title: String(localized: "Captions", comment: "History Compare dialog: a group title"),
                             lines: itemLines(change, key: "subtitles", from: from, to: to)))
        }

        for (tab, title) in tabTitles {
            guard let keys = cs.settings[tab], !keys.isEmpty else { continue }
            out.append(Group(title: title, lines: keys.map { $0 == "*" ? String(localized: "Settings changed", comment: "History Compare dialog line") : changedLine(humanize($0)) }))
        }

        var other: [String] = []
        let claimed = clipFields.union(recordingFields)
        for field in cs.fields where !claimed.contains(field) {
            switch field {
            case "name":
                let oldName = from.get("name")?.stringValue ?? "", newName = to.get("name")?.stringValue ?? ""
                other.append(String(localized: "Renamed “\(oldName)” → “\(newName)”", comment: "History Compare dialog line: project renamed from, to"))
            case "*": other.append(String(localized: "Document replaced", comment: "History Compare dialog line"))
            default: other.append(changedLine(humanize(field)))
            }
        }
        let known = Set(laneOrder.map(\.key) + ["subtitles"])
        for key in cs.items.keys.sorted() where !known.contains(key) { other.append(changedLine(humanize(key))) }
        if !other.isEmpty { out.append(Group(title: String(localized: "Other", comment: "History Compare dialog: a group title"), lines: other)) }
        return out
    }

    private enum Verb: String { case added, removed, edited }

    private static func itemLines(_ change: CollectionChange, key: String,
                                  from: JSONValue, to: JSONValue) -> [String] {
        if change.replaced { return [replacedLine(key)] }
        if let counts = change.counts {
            var lines: [String] = []
            if counts.added > 0 { lines.append(countLine(key, .added, counts.added)) }
            if counts.removed > 0 { lines.append(countLine(key, .removed, counts.removed)) }
            if counts.changed > 0 { lines.append(countLine(key, .edited, counts.changed)) }
            if change.reordered { lines.append(reorderedLine(key)) }
            return lines
        }
        var lines: [String] = []
        for id in change.added { lines.append(elementLine(key, .added, timing(of: id, in: to.get(key)))) }
        for id in change.removed { lines.append(elementLine(key, .removed, timing(of: id, in: from.get(key)))) }
        for id in change.changed.keys.sorted() {
            let fields = (change.changed[id] ?? []).filter { $0 != "id" }.map(humanize).joined(separator: ", ")
            let timing = timing(of: id, in: to.get(key))
            lines.append(fields.isEmpty ? elementLine(key, .edited, timing) : editedFieldsLine(key, timing, fields.lowercased()))
        }
        if change.reordered { lines.append(reorderedLine(key)) }
        return lines
    }

    /// "Background padding changed" — `name` is a humanized project.json key.
    private static func changedLine(_ name: String) -> String {
        String(localized: "\(name) changed", comment: "History Compare dialog line; %@ is a setting's name, derived from its internal key")
    }

    // Generated per lane: each line is one whole localized sentence.
    private static func replacedLine(_ key: String) -> String {
        switch key {
        case "zoomRegions": return String(localized: "Zooms changed", comment: "History Compare dialog line")
        case "tiltRegions": return String(localized: "Tilts changed", comment: "History Compare dialog line")
        case "speedRegions": return String(localized: "Speed regions changed", comment: "History Compare dialog line")
        case "blurRegions": return String(localized: "Blurs changed", comment: "History Compare dialog line")
        case "highlightRegions": return String(localized: "Highlights changed", comment: "History Compare dialog line")
        case "focusRegions": return String(localized: "Depth focuss changed", comment: "History Compare dialog line")
        case "cameraLayoutRegions": return String(localized: "Camera layouts changed", comment: "History Compare dialog line")
        case "annotations": return String(localized: "Annotations changed", comment: "History Compare dialog line")
        case "voiceOverClips": return String(localized: "Voice-overs changed", comment: "History Compare dialog line")
        case "subtitles": return String(localized: "Captions changed", comment: "History Compare dialog line")
        default: return "\(key) changed"
        }
    }

    private static func reorderedLine(_ key: String) -> String {
        switch key {
        case "zoomRegions": return String(localized: "Zooms reordered", comment: "History Compare dialog line")
        case "tiltRegions": return String(localized: "Tilts reordered", comment: "History Compare dialog line")
        case "speedRegions": return String(localized: "Speed regions reordered", comment: "History Compare dialog line")
        case "blurRegions": return String(localized: "Blurs reordered", comment: "History Compare dialog line")
        case "highlightRegions": return String(localized: "Highlights reordered", comment: "History Compare dialog line")
        case "focusRegions": return String(localized: "Depth focuss reordered", comment: "History Compare dialog line")
        case "cameraLayoutRegions": return String(localized: "Camera layouts reordered", comment: "History Compare dialog line")
        case "annotations": return String(localized: "Annotations reordered", comment: "History Compare dialog line")
        case "voiceOverClips": return String(localized: "Voice-overs reordered", comment: "History Compare dialog line")
        case "subtitles": return String(localized: "Captions reordered", comment: "History Compare dialog line")
        default: return "\(key) reordered"
        }
    }

    /// "1 zoom added" / "3 zooms added".
    private static func countLine(_ key: String, _ verb: Verb, _ n: Int) -> String {
        switch (key, verb) {
        case ("zoomRegions", .added): return n == 1 ? String(localized: "1 zoom added", comment: "History Compare dialog line") : String(localized: "\(n) zooms added", comment: "History Compare dialog line")
        case ("zoomRegions", .removed): return n == 1 ? String(localized: "1 zoom removed", comment: "History Compare dialog line") : String(localized: "\(n) zooms removed", comment: "History Compare dialog line")
        case ("zoomRegions", .edited): return n == 1 ? String(localized: "1 zoom edited", comment: "History Compare dialog line") : String(localized: "\(n) zooms edited", comment: "History Compare dialog line")
        case ("tiltRegions", .added): return n == 1 ? String(localized: "1 tilt added", comment: "History Compare dialog line") : String(localized: "\(n) tilts added", comment: "History Compare dialog line")
        case ("tiltRegions", .removed): return n == 1 ? String(localized: "1 tilt removed", comment: "History Compare dialog line") : String(localized: "\(n) tilts removed", comment: "History Compare dialog line")
        case ("tiltRegions", .edited): return n == 1 ? String(localized: "1 tilt edited", comment: "History Compare dialog line") : String(localized: "\(n) tilts edited", comment: "History Compare dialog line")
        case ("speedRegions", .added): return n == 1 ? String(localized: "1 speed region added", comment: "History Compare dialog line") : String(localized: "\(n) speed regions added", comment: "History Compare dialog line")
        case ("speedRegions", .removed): return n == 1 ? String(localized: "1 speed region removed", comment: "History Compare dialog line") : String(localized: "\(n) speed regions removed", comment: "History Compare dialog line")
        case ("speedRegions", .edited): return n == 1 ? String(localized: "1 speed region edited", comment: "History Compare dialog line") : String(localized: "\(n) speed regions edited", comment: "History Compare dialog line")
        case ("blurRegions", .added): return n == 1 ? String(localized: "1 blur added", comment: "History Compare dialog line") : String(localized: "\(n) blurs added", comment: "History Compare dialog line")
        case ("blurRegions", .removed): return n == 1 ? String(localized: "1 blur removed", comment: "History Compare dialog line") : String(localized: "\(n) blurs removed", comment: "History Compare dialog line")
        case ("blurRegions", .edited): return n == 1 ? String(localized: "1 blur edited", comment: "History Compare dialog line") : String(localized: "\(n) blurs edited", comment: "History Compare dialog line")
        case ("highlightRegions", .added): return n == 1 ? String(localized: "1 highlight added", comment: "History Compare dialog line") : String(localized: "\(n) highlights added", comment: "History Compare dialog line")
        case ("highlightRegions", .removed): return n == 1 ? String(localized: "1 highlight removed", comment: "History Compare dialog line") : String(localized: "\(n) highlights removed", comment: "History Compare dialog line")
        case ("highlightRegions", .edited): return n == 1 ? String(localized: "1 highlight edited", comment: "History Compare dialog line") : String(localized: "\(n) highlights edited", comment: "History Compare dialog line")
        case ("focusRegions", .added): return n == 1 ? String(localized: "1 depth focus added", comment: "History Compare dialog line") : String(localized: "\(n) depth focuss added", comment: "History Compare dialog line")
        case ("focusRegions", .removed): return n == 1 ? String(localized: "1 depth focus removed", comment: "History Compare dialog line") : String(localized: "\(n) depth focuss removed", comment: "History Compare dialog line")
        case ("focusRegions", .edited): return n == 1 ? String(localized: "1 depth focus edited", comment: "History Compare dialog line") : String(localized: "\(n) depth focuss edited", comment: "History Compare dialog line")
        case ("cameraLayoutRegions", .added): return n == 1 ? String(localized: "1 camera layout added", comment: "History Compare dialog line") : String(localized: "\(n) camera layouts added", comment: "History Compare dialog line")
        case ("cameraLayoutRegions", .removed): return n == 1 ? String(localized: "1 camera layout removed", comment: "History Compare dialog line") : String(localized: "\(n) camera layouts removed", comment: "History Compare dialog line")
        case ("cameraLayoutRegions", .edited): return n == 1 ? String(localized: "1 camera layout edited", comment: "History Compare dialog line") : String(localized: "\(n) camera layouts edited", comment: "History Compare dialog line")
        case ("annotations", .added): return n == 1 ? String(localized: "1 annotation added", comment: "History Compare dialog line") : String(localized: "\(n) annotations added", comment: "History Compare dialog line")
        case ("annotations", .removed): return n == 1 ? String(localized: "1 annotation removed", comment: "History Compare dialog line") : String(localized: "\(n) annotations removed", comment: "History Compare dialog line")
        case ("annotations", .edited): return n == 1 ? String(localized: "1 annotation edited", comment: "History Compare dialog line") : String(localized: "\(n) annotations edited", comment: "History Compare dialog line")
        case ("voiceOverClips", .added): return n == 1 ? String(localized: "1 voice-over added", comment: "History Compare dialog line") : String(localized: "\(n) voice-overs added", comment: "History Compare dialog line")
        case ("voiceOverClips", .removed): return n == 1 ? String(localized: "1 voice-over removed", comment: "History Compare dialog line") : String(localized: "\(n) voice-overs removed", comment: "History Compare dialog line")
        case ("voiceOverClips", .edited): return n == 1 ? String(localized: "1 voice-over edited", comment: "History Compare dialog line") : String(localized: "\(n) voice-overs edited", comment: "History Compare dialog line")
        case ("subtitles", .added): return n == 1 ? String(localized: "1 caption added", comment: "History Compare dialog line") : String(localized: "\(n) captions added", comment: "History Compare dialog line")
        case ("subtitles", .removed): return n == 1 ? String(localized: "1 caption removed", comment: "History Compare dialog line") : String(localized: "\(n) captions removed", comment: "History Compare dialog line")
        case ("subtitles", .edited): return n == 1 ? String(localized: "1 caption edited", comment: "History Compare dialog line") : String(localized: "\(n) captions edited", comment: "History Compare dialog line")
        default: return "\(n) \(key) \(verb.rawValue)"
        }
    }

    /// "Zoom added · 0:12–0:15" (`timing` is " · 0:12–0:15" or empty).
    private static func elementLine(_ key: String, _ verb: Verb, _ timing: String) -> String {
        switch (key, verb) {
        case ("zoomRegions", .added): return String(localized: "Zoom added\(timing)", comment: "History Compare dialog line; %@ is \" · 0:12–0:15\" (the element's time span) or empty")
        case ("zoomRegions", .removed): return String(localized: "Zoom removed\(timing)", comment: "History Compare dialog line; %@ is \" · 0:12–0:15\" (the element's time span) or empty")
        case ("zoomRegions", .edited): return String(localized: "Zoom edited\(timing)", comment: "History Compare dialog line; %@ is \" · 0:12–0:15\" (the element's time span) or empty")
        case ("tiltRegions", .added): return String(localized: "Tilt added\(timing)", comment: "History Compare dialog line; %@ is \" · 0:12–0:15\" (the element's time span) or empty")
        case ("tiltRegions", .removed): return String(localized: "Tilt removed\(timing)", comment: "History Compare dialog line; %@ is \" · 0:12–0:15\" (the element's time span) or empty")
        case ("tiltRegions", .edited): return String(localized: "Tilt edited\(timing)", comment: "History Compare dialog line; %@ is \" · 0:12–0:15\" (the element's time span) or empty")
        case ("speedRegions", .added): return String(localized: "Speed region added\(timing)", comment: "History Compare dialog line; %@ is \" · 0:12–0:15\" (the element's time span) or empty")
        case ("speedRegions", .removed): return String(localized: "Speed region removed\(timing)", comment: "History Compare dialog line; %@ is \" · 0:12–0:15\" (the element's time span) or empty")
        case ("speedRegions", .edited): return String(localized: "Speed region edited\(timing)", comment: "History Compare dialog line; %@ is \" · 0:12–0:15\" (the element's time span) or empty")
        case ("blurRegions", .added): return String(localized: "Blur added\(timing)", comment: "History Compare dialog line; %@ is \" · 0:12–0:15\" (the element's time span) or empty")
        case ("blurRegions", .removed): return String(localized: "Blur removed\(timing)", comment: "History Compare dialog line; %@ is \" · 0:12–0:15\" (the element's time span) or empty")
        case ("blurRegions", .edited): return String(localized: "Blur edited\(timing)", comment: "History Compare dialog line; %@ is \" · 0:12–0:15\" (the element's time span) or empty")
        case ("highlightRegions", .added): return String(localized: "Highlight added\(timing)", comment: "History Compare dialog line; %@ is \" · 0:12–0:15\" (the element's time span) or empty")
        case ("highlightRegions", .removed): return String(localized: "Highlight removed\(timing)", comment: "History Compare dialog line; %@ is \" · 0:12–0:15\" (the element's time span) or empty")
        case ("highlightRegions", .edited): return String(localized: "Highlight edited\(timing)", comment: "History Compare dialog line; %@ is \" · 0:12–0:15\" (the element's time span) or empty")
        case ("focusRegions", .added): return String(localized: "Depth focus added\(timing)", comment: "History Compare dialog line; %@ is \" · 0:12–0:15\" (the element's time span) or empty")
        case ("focusRegions", .removed): return String(localized: "Depth focus removed\(timing)", comment: "History Compare dialog line; %@ is \" · 0:12–0:15\" (the element's time span) or empty")
        case ("focusRegions", .edited): return String(localized: "Depth focus edited\(timing)", comment: "History Compare dialog line; %@ is \" · 0:12–0:15\" (the element's time span) or empty")
        case ("cameraLayoutRegions", .added): return String(localized: "Camera layout added\(timing)", comment: "History Compare dialog line; %@ is \" · 0:12–0:15\" (the element's time span) or empty")
        case ("cameraLayoutRegions", .removed): return String(localized: "Camera layout removed\(timing)", comment: "History Compare dialog line; %@ is \" · 0:12–0:15\" (the element's time span) or empty")
        case ("cameraLayoutRegions", .edited): return String(localized: "Camera layout edited\(timing)", comment: "History Compare dialog line; %@ is \" · 0:12–0:15\" (the element's time span) or empty")
        case ("annotations", .added): return String(localized: "Annotation added\(timing)", comment: "History Compare dialog line; %@ is \" · 0:12–0:15\" (the element's time span) or empty")
        case ("annotations", .removed): return String(localized: "Annotation removed\(timing)", comment: "History Compare dialog line; %@ is \" · 0:12–0:15\" (the element's time span) or empty")
        case ("annotations", .edited): return String(localized: "Annotation edited\(timing)", comment: "History Compare dialog line; %@ is \" · 0:12–0:15\" (the element's time span) or empty")
        case ("voiceOverClips", .added): return String(localized: "Voice-over added\(timing)", comment: "History Compare dialog line; %@ is \" · 0:12–0:15\" (the element's time span) or empty")
        case ("voiceOverClips", .removed): return String(localized: "Voice-over removed\(timing)", comment: "History Compare dialog line; %@ is \" · 0:12–0:15\" (the element's time span) or empty")
        case ("voiceOverClips", .edited): return String(localized: "Voice-over edited\(timing)", comment: "History Compare dialog line; %@ is \" · 0:12–0:15\" (the element's time span) or empty")
        case ("subtitles", .added): return String(localized: "Caption added\(timing)", comment: "History Compare dialog line; %@ is \" · 0:12–0:15\" (the element's time span) or empty")
        case ("subtitles", .removed): return String(localized: "Caption removed\(timing)", comment: "History Compare dialog line; %@ is \" · 0:12–0:15\" (the element's time span) or empty")
        case ("subtitles", .edited): return String(localized: "Caption edited\(timing)", comment: "History Compare dialog line; %@ is \" · 0:12–0:15\" (the element's time span) or empty")
        default: return "\(key) \(verb.rawValue)\(timing)"
        }
    }

    /// "Zoom edited · 0:12–0:15 — focal x, scale".
    private static func editedFieldsLine(_ key: String, _ timing: String, _ fields: String) -> String {
        switch key {
        case "zoomRegions": return String(localized: "Zoom edited\(timing) — \(fields)", comment: "History Compare dialog line; first %@ is \" · 0:12–0:15\" or empty, second is the edited field names")
        case "tiltRegions": return String(localized: "Tilt edited\(timing) — \(fields)", comment: "History Compare dialog line; first %@ is \" · 0:12–0:15\" or empty, second is the edited field names")
        case "speedRegions": return String(localized: "Speed region edited\(timing) — \(fields)", comment: "History Compare dialog line; first %@ is \" · 0:12–0:15\" or empty, second is the edited field names")
        case "blurRegions": return String(localized: "Blur edited\(timing) — \(fields)", comment: "History Compare dialog line; first %@ is \" · 0:12–0:15\" or empty, second is the edited field names")
        case "highlightRegions": return String(localized: "Highlight edited\(timing) — \(fields)", comment: "History Compare dialog line; first %@ is \" · 0:12–0:15\" or empty, second is the edited field names")
        case "focusRegions": return String(localized: "Depth focus edited\(timing) — \(fields)", comment: "History Compare dialog line; first %@ is \" · 0:12–0:15\" or empty, second is the edited field names")
        case "cameraLayoutRegions": return String(localized: "Camera layout edited\(timing) — \(fields)", comment: "History Compare dialog line; first %@ is \" · 0:12–0:15\" or empty, second is the edited field names")
        case "annotations": return String(localized: "Annotation edited\(timing) — \(fields)", comment: "History Compare dialog line; first %@ is \" · 0:12–0:15\" or empty, second is the edited field names")
        case "voiceOverClips": return String(localized: "Voice-over edited\(timing) — \(fields)", comment: "History Compare dialog line; first %@ is \" · 0:12–0:15\" or empty, second is the edited field names")
        case "subtitles": return String(localized: "Caption edited\(timing) — \(fields)", comment: "History Compare dialog line; first %@ is \" · 0:12–0:15\" or empty, second is the edited field names")
        default: return "\(key) edited\(timing) — \(fields)"
        }
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
        count == 1 ? String(localized: "Review 1 conflict", comment: "Merge Review dialog title")
            : String(localized: "Review \(count) conflicts", comment: "Merge Review dialog title")
    }

    static func intro(theirs who: String, device: String) -> String {
        String(localized: "\(who) changed this project while it was also edited on this \(device). Choose which side to keep where the two can't be combined — everything else is already merged.",
               comment: "Merge Review intro. First %@ is who else edited, second is the device (Mac, iPad, iPhone).")
    }

    static let segments = [
        String(localized: "Mine", comment: "Merge Review segment: keep this device's side"),
        String(localized: "Theirs", comment: "Merge Review segment: keep the other editor's side"),
    ]

    static func autoResolvedTitle(_ n: Int) -> String {
        n == 1 ? String(localized: "1 clash settled automatically (latest edit wins)", comment: "Merge Review section title")
            : String(localized: "\(n) clashes settled automatically (latest edit wins)", comment: "Merge Review section title")
    }

    static func theirsName(author: CloudVersionAuthor?,
                           fallback: String = String(localized: "The web editor", comment: "Merge Review: who else edited, when the name is unknown")) -> String {
        if let name = author?.name, !name.isEmpty {
            if let label = author?.clientLabel, !label.isEmpty { return "\(name) (\(label))" }
            return name
        }
        return fallback
    }

    /// The collection key a conflict path names ("words" for a caption word).
    private static func nounKey(forPath path: String) -> String {
        let key = path.split(separator: "[").first.map(String.init) ?? path
        if path.contains(".words[") { return "words" }
        switch key {
        case "zoomRegions", "tiltRegions", "speedRegions", "blurRegions", "highlightRegions", "focusRegions",
             "cameraLayoutRegions", "annotations", "voiceOverClips", "subtitles": return key
        default: return "item"
        }
    }

    /// "Annotation", "Zoom", "Caption word"… for a collection path.
    static func noun(forPath path: String) -> String {
        nounText(nounKey(forPath: path))
    }

    static func title(for conflict: MergeConflict) -> String {
        switch conflict.kind {
        case "clipStructure": return String(localized: "Clips and trim", comment: "Merge Review conflict title")
        case "deleteVsModify": return noun(forPath: conflict.path)
        case "subtitlesRegenerated": return String(localized: "Captions", comment: "Merge Review conflict title")
        case "laneOverlap":
            switch conflict.lane {
            case nil: return String(localized: "Timeline lane overlap", comment: "Merge Review conflict title")
            case "effects": return String(localized: "Effects lane overlap", comment: "Merge Review conflict title (the zoom/tilt lane)")
            case "focus": return String(localized: "Focus lane overlap", comment: "Merge Review conflict title (the blur/highlight/focus lane)")
            case "speed": return String(localized: "Speed lane overlap", comment: "Merge Review conflict title")
            case let raw?:
                let lane = raw.prefix(1).uppercased() + raw.dropFirst()
                return String(localized: "\(lane) lane overlap", comment: "Merge Review conflict title; %@ is the timeline lane's internal name")
            }
        default: return conflict.path
        }
    }

    static func detail(for conflict: MergeConflict, theirs: String, device: String = "Mac") -> String {
        switch conflict.kind {
        case "clipStructure":
            return String(localized: "The clips were cut or trimmed on both sides. Mine keeps this \(device)'s clips; Theirs keeps \(theirs)'s.",
                          comment: "Merge Review conflict detail. First %@ is the device (Mac, iPad, iPhone), second is who else edited. Mine / Theirs are the segment titles.")
        case "deleteVsModify":
            let key = nounKey(forPath: conflict.path)
            return conflict.deletedBy == .mine
                ? deletedMineDetail(key, device: device, theirs: theirs)
                : deletedTheirsDetail(key, device: device, theirs: theirs)
        case "subtitlesRegenerated":
            switch conflict.regeneratedBy {
            case "mine":
                return String(localized: "Captions were regenerated on this \(device) and edited on the other side. Pick one set of captions.",
                              comment: "Merge Review conflict detail; %@ is the device (Mac, iPad, iPhone)")
            case "theirs":
                return String(localized: "Captions were regenerated by \(theirs) and edited on the other side. Pick one set of captions.",
                              comment: "Merge Review conflict detail; %@ is who else edited")
            default:
                return String(localized: "Captions were regenerated on both sides and edited on the other side. Pick one set of captions.",
                              comment: "Merge Review conflict detail")
            }
        case "laneOverlap":
            return String(localized: "Combining both sides would make two items overlap on this lane. Pick whose timing to keep for both.",
                          comment: "Merge Review conflict detail")
        default:
            return String(localized: "Both sides changed this.", comment: "Merge Review conflict detail")
        }
    }

    static func describe(_ item: MergeAutoResolved, device: String = "Mac") -> String {
        let what: String
        switch item.kind {
        case "order": what = orderText(nounKey(forPath: item.path))
        default: what = item.path
        }
        return item.winner == .mine
            ? String(localized: "• \(what) — kept this \(device)",
                     comment: "Merge Review: an automatically settled clash. First %@ is what (e.g. Zoom order), second the device (Mac, iPad, iPhone)")
            : String(localized: "• \(what) — kept theirs",
                     comment: "Merge Review: an automatically settled clash; %@ is what (e.g. Zoom order)")
    }

    // Generated per item kind: each sentence is one whole localized key.
    private static func nounText(_ key: String) -> String {
        switch key {
        case "zoomRegions": return String(localized: "Zoom", comment: "Merge Review: a timeline item kind")
        case "tiltRegions": return String(localized: "Tilt", comment: "Merge Review: a timeline item kind")
        case "speedRegions": return String(localized: "Speed region", comment: "Merge Review: a timeline item kind")
        case "blurRegions": return String(localized: "Blur", comment: "Merge Review: a timeline item kind")
        case "highlightRegions": return String(localized: "Highlight", comment: "Merge Review: a timeline item kind")
        case "focusRegions": return String(localized: "Depth focus", comment: "Merge Review: a timeline item kind")
        case "cameraLayoutRegions": return String(localized: "Camera layout", comment: "Merge Review: a timeline item kind")
        case "annotations": return String(localized: "Annotation", comment: "Merge Review: a timeline item kind")
        case "voiceOverClips": return String(localized: "Voice-over", comment: "Merge Review: a timeline item kind")
        case "subtitles": return String(localized: "Caption", comment: "Merge Review: a timeline item kind")
        case "words": return String(localized: "Caption word", comment: "Merge Review: a timeline item kind")
        case "item": return String(localized: "Item", comment: "Merge Review: a timeline item kind")
        default: return String(localized: "Item", comment: "Merge Review: a timeline item kind")
        }
    }

    private static func deletedMineDetail(_ key: String, device: String, theirs: String) -> String {
        switch key {
        case "zoomRegions": return String(localized: "Deleted on this \(device) but edited by \(theirs). Mine deletes the zoom; Theirs keeps the edit.", comment: "Merge Review conflict detail. First %@ is the device (Mac, iPad, iPhone), second is who else edited. Mine / Theirs are the segment titles.")
        case "tiltRegions": return String(localized: "Deleted on this \(device) but edited by \(theirs). Mine deletes the tilt; Theirs keeps the edit.", comment: "Merge Review conflict detail. First %@ is the device (Mac, iPad, iPhone), second is who else edited. Mine / Theirs are the segment titles.")
        case "speedRegions": return String(localized: "Deleted on this \(device) but edited by \(theirs). Mine deletes the speed region; Theirs keeps the edit.", comment: "Merge Review conflict detail. First %@ is the device (Mac, iPad, iPhone), second is who else edited. Mine / Theirs are the segment titles.")
        case "blurRegions": return String(localized: "Deleted on this \(device) but edited by \(theirs). Mine deletes the blur; Theirs keeps the edit.", comment: "Merge Review conflict detail. First %@ is the device (Mac, iPad, iPhone), second is who else edited. Mine / Theirs are the segment titles.")
        case "highlightRegions": return String(localized: "Deleted on this \(device) but edited by \(theirs). Mine deletes the highlight; Theirs keeps the edit.", comment: "Merge Review conflict detail. First %@ is the device (Mac, iPad, iPhone), second is who else edited. Mine / Theirs are the segment titles.")
        case "focusRegions": return String(localized: "Deleted on this \(device) but edited by \(theirs). Mine deletes the depth focus; Theirs keeps the edit.", comment: "Merge Review conflict detail. First %@ is the device (Mac, iPad, iPhone), second is who else edited. Mine / Theirs are the segment titles.")
        case "cameraLayoutRegions": return String(localized: "Deleted on this \(device) but edited by \(theirs). Mine deletes the camera layout; Theirs keeps the edit.", comment: "Merge Review conflict detail. First %@ is the device (Mac, iPad, iPhone), second is who else edited. Mine / Theirs are the segment titles.")
        case "annotations": return String(localized: "Deleted on this \(device) but edited by \(theirs). Mine deletes the annotation; Theirs keeps the edit.", comment: "Merge Review conflict detail. First %@ is the device (Mac, iPad, iPhone), second is who else edited. Mine / Theirs are the segment titles.")
        case "voiceOverClips": return String(localized: "Deleted on this \(device) but edited by \(theirs). Mine deletes the voice-over; Theirs keeps the edit.", comment: "Merge Review conflict detail. First %@ is the device (Mac, iPad, iPhone), second is who else edited. Mine / Theirs are the segment titles.")
        case "subtitles": return String(localized: "Deleted on this \(device) but edited by \(theirs). Mine deletes the caption; Theirs keeps the edit.", comment: "Merge Review conflict detail. First %@ is the device (Mac, iPad, iPhone), second is who else edited. Mine / Theirs are the segment titles.")
        case "words": return String(localized: "Deleted on this \(device) but edited by \(theirs). Mine deletes the caption word; Theirs keeps the edit.", comment: "Merge Review conflict detail. First %@ is the device (Mac, iPad, iPhone), second is who else edited. Mine / Theirs are the segment titles.")
        case "item": return String(localized: "Deleted on this \(device) but edited by \(theirs). Mine deletes the item; Theirs keeps the edit.", comment: "Merge Review conflict detail. First %@ is the device (Mac, iPad, iPhone), second is who else edited. Mine / Theirs are the segment titles.")
        default: return deletedMineDetail("item", device: device, theirs: theirs)
        }
    }

    private static func deletedTheirsDetail(_ key: String, device: String, theirs: String) -> String {
        switch key {
        case "zoomRegions": return String(localized: "Deleted by \(theirs) but edited on this \(device). Mine keeps the edit; Theirs deletes the zoom.", comment: "Merge Review conflict detail. First %@ is who else edited, second is the device (Mac, iPad, iPhone). Mine / Theirs are the segment titles.")
        case "tiltRegions": return String(localized: "Deleted by \(theirs) but edited on this \(device). Mine keeps the edit; Theirs deletes the tilt.", comment: "Merge Review conflict detail. First %@ is who else edited, second is the device (Mac, iPad, iPhone). Mine / Theirs are the segment titles.")
        case "speedRegions": return String(localized: "Deleted by \(theirs) but edited on this \(device). Mine keeps the edit; Theirs deletes the speed region.", comment: "Merge Review conflict detail. First %@ is who else edited, second is the device (Mac, iPad, iPhone). Mine / Theirs are the segment titles.")
        case "blurRegions": return String(localized: "Deleted by \(theirs) but edited on this \(device). Mine keeps the edit; Theirs deletes the blur.", comment: "Merge Review conflict detail. First %@ is who else edited, second is the device (Mac, iPad, iPhone). Mine / Theirs are the segment titles.")
        case "highlightRegions": return String(localized: "Deleted by \(theirs) but edited on this \(device). Mine keeps the edit; Theirs deletes the highlight.", comment: "Merge Review conflict detail. First %@ is who else edited, second is the device (Mac, iPad, iPhone). Mine / Theirs are the segment titles.")
        case "focusRegions": return String(localized: "Deleted by \(theirs) but edited on this \(device). Mine keeps the edit; Theirs deletes the depth focus.", comment: "Merge Review conflict detail. First %@ is who else edited, second is the device (Mac, iPad, iPhone). Mine / Theirs are the segment titles.")
        case "cameraLayoutRegions": return String(localized: "Deleted by \(theirs) but edited on this \(device). Mine keeps the edit; Theirs deletes the camera layout.", comment: "Merge Review conflict detail. First %@ is who else edited, second is the device (Mac, iPad, iPhone). Mine / Theirs are the segment titles.")
        case "annotations": return String(localized: "Deleted by \(theirs) but edited on this \(device). Mine keeps the edit; Theirs deletes the annotation.", comment: "Merge Review conflict detail. First %@ is who else edited, second is the device (Mac, iPad, iPhone). Mine / Theirs are the segment titles.")
        case "voiceOverClips": return String(localized: "Deleted by \(theirs) but edited on this \(device). Mine keeps the edit; Theirs deletes the voice-over.", comment: "Merge Review conflict detail. First %@ is who else edited, second is the device (Mac, iPad, iPhone). Mine / Theirs are the segment titles.")
        case "subtitles": return String(localized: "Deleted by \(theirs) but edited on this \(device). Mine keeps the edit; Theirs deletes the caption.", comment: "Merge Review conflict detail. First %@ is who else edited, second is the device (Mac, iPad, iPhone). Mine / Theirs are the segment titles.")
        case "words": return String(localized: "Deleted by \(theirs) but edited on this \(device). Mine keeps the edit; Theirs deletes the caption word.", comment: "Merge Review conflict detail. First %@ is who else edited, second is the device (Mac, iPad, iPhone). Mine / Theirs are the segment titles.")
        case "item": return String(localized: "Deleted by \(theirs) but edited on this \(device). Mine keeps the edit; Theirs deletes the item.", comment: "Merge Review conflict detail. First %@ is who else edited, second is the device (Mac, iPad, iPhone). Mine / Theirs are the segment titles.")
        default: return deletedTheirsDetail("item", device: device, theirs: theirs)
        }
    }

    private static func orderText(_ key: String) -> String {
        switch key {
        case "zoomRegions": return String(localized: "Zoom order", comment: "Merge Review: an automatically settled clash about the order of items")
        case "tiltRegions": return String(localized: "Tilt order", comment: "Merge Review: an automatically settled clash about the order of items")
        case "speedRegions": return String(localized: "Speed region order", comment: "Merge Review: an automatically settled clash about the order of items")
        case "blurRegions": return String(localized: "Blur order", comment: "Merge Review: an automatically settled clash about the order of items")
        case "highlightRegions": return String(localized: "Highlight order", comment: "Merge Review: an automatically settled clash about the order of items")
        case "focusRegions": return String(localized: "Depth focus order", comment: "Merge Review: an automatically settled clash about the order of items")
        case "cameraLayoutRegions": return String(localized: "Camera layout order", comment: "Merge Review: an automatically settled clash about the order of items")
        case "annotations": return String(localized: "Annotation order", comment: "Merge Review: an automatically settled clash about the order of items")
        case "voiceOverClips": return String(localized: "Voice-over order", comment: "Merge Review: an automatically settled clash about the order of items")
        case "subtitles": return String(localized: "Caption order", comment: "Merge Review: an automatically settled clash about the order of items")
        case "words": return String(localized: "Caption word order", comment: "Merge Review: an automatically settled clash about the order of items")
        case "item": return String(localized: "Item order", comment: "Merge Review: an automatically settled clash about the order of items")
        default: return orderText("item")
        }
    }
}
