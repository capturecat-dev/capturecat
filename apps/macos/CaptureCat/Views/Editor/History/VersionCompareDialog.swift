import AppKit

/// "Compare with Current" — what changed between a version and the project
/// as it is now, grouped by where you would edit it (Clips & trim, Timeline,
/// Captions, each inspector tab), one `CCAccordion` item per group inside a
/// `CCDialog`. The diff is the shared `ProjectDiff` on raw JSON (the same
/// change-set the server stores); element lines name their time span
/// ("Zoom added · 0:12–0:15").
@MainActor
final class VersionCompareDialog {
    /// The grouping is shared with iOS (Studio/ProjectHistory/HistoryWords.swift).
    typealias Group = VersionCompareGroups.Group

    private let dialog: CCDialog
    private let accordion = CCAccordion(mode: .multiple, chrome: .card)
    private let summary = CCWrappingLabel()
    let groups: [Group]
    private var themeObservation: CCThemeObservation?

    init(version: CloudVersion, versionDocument: Data, currentDocument: Data, projectName: String) {
        let from = (try? JSONValue.parse(data: versionDocument)) ?? .object(JSONObject())
        let to = (try? JSONValue.parse(data: currentDocument)) ?? .object(JSONObject())
        groups = Self.groups(from: from, to: to)
        dialog = CCDialog(title: String(localized: "Compare with current", comment: "Dialog title: compares a history version with the current project"),
                          subtitle: String(localized: "\(projectName) · \(HistoryPaneAppKit.stamp(version.date)) → now", comment: "Compare dialog subtitle: project name, the version's date and time, an arrow, and the word now (the current state)"),
                          width: 520)
        dialog.entrance = .slideUp()

        summary.stringValue = VersionCompareGroups.summary(groups)
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
        let close = CCButton(title: String(localized: "Done", comment: "Dialog button: closes the compare dialog"), style: .primary, size: .regular)
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

    // MARK: - Grouping (pure, shared — `--history-panel-shot` checks it)

    static func groups(from: JSONValue, to: JSONValue) -> [Group] { VersionCompareGroups.groups(from: from, to: to) }

    static func clock(_ seconds: Double) -> String { VersionCompareGroups.clock(seconds) }

    /// "backgroundPadding" → "Background padding".
    static func humanize(_ key: String) -> String { VersionCompareGroups.humanize(key) }
}
