import AppKit

/// Merge Review — the structural conflicts of a three-way cloud merge
/// (docs/project-history.md §1.4), one row each with a Mine / Theirs
/// `CCSegmented` defaulting to the last writer. Same-field clashes the merge
/// already settled are listed collapsed (`CCAccordion`) for the record.
///
/// All CCKit: a `CCDialog` (scrim, spring entrance, Escape = Cancel),
/// segmented controls dressed by CCMaterial, the accordion's growth bounce.
@MainActor
final class MergeReviewDialog {
    /// Apply with every conflict's choice (conflict id → side).
    var onApply: (([String: MergeSide]) -> Void)?
    var onCancel: (() -> Void)?

    let review: CloudMergeReview
    private let dialog: CCDialog
    private var rows: [(conflict: MergeConflict, control: CCSegmented)] = []
    private let applyButton = CCButton(title: "Apply Merge", style: .primary, size: .regular)
    private let cancelButton = CCButton(title: "Cancel", style: .secondary, size: .regular)
    private var accordion: CCAccordion?
    private var labels: [NSTextField] = []
    private var captions: [NSTextField] = []
    private var themeObservation: CCThemeObservation?

    init(review: CloudMergeReview, projectName: String) {
        self.review = review
        let count = review.conflicts.count
        dialog = CCDialog(
            title: count == 1 ? "Review 1 conflict" : "Review \(count) conflicts",
            subtitle: projectName,
            width: 500)
        dialog.entrance = .slideUp()

        let who = Self.theirsName(review)
        let intro = CCWrappingLabel()
        intro.stringValue = "\(who) changed this project while it was also edited on this Mac. "
            + "Choose which side to keep where the two can't be combined — everything else is already merged."
        captions.append(intro)
        dialog.addContent(intro)

        for conflict in review.conflicts {
            let row = NSStackView()
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = CCSpace.xs
            let title = NSTextField(labelWithString: Self.title(for: conflict))
            title.lineBreakMode = .byTruncatingTail
            labels.append(title)
            let detail = CCWrappingLabel()
            detail.stringValue = Self.detail(for: conflict, theirs: who)
            captions.append(detail)
            let control = CCSegmented(
                segments: ["Mine", "Theirs"],
                selectedIndex: conflict.resolution == .mine ? 0 : 1,
                size: .sm,
                hoverWash: true)
            control.translatesAutoresizingMaskIntoConstraints = false
            row.addArrangedSubview(title)
            row.addArrangedSubview(detail)
            row.addArrangedSubview(control)
            detail.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
            control.widthAnchor.constraint(equalToConstant: 200).isActive = true
            rows.append((conflict, control))
            dialog.addContent(row)
        }

        if !review.autoResolved.isEmpty {
            let list = review.autoResolved.map(Self.describe).joined(separator: "\n")
            let accordion = CCAccordion(mode: .single, chrome: .card)
            let n = review.autoResolved.count
            accordion.addItem(
                title: n == 1 ? "1 clash settled automatically (latest edit wins)"
                    : "\(n) clashes settled automatically (latest edit wins)",
                text: list)
            self.accordion = accordion
            dialog.addContent(accordion)
        }

        dialog.setMaxContentHeight(380)
        cancelButton.onClick = { [weak self] in self?.cancel() }
        applyButton.onClick = { [weak self] in self?.apply() }
        dialog.addFooter(cancelButton)
        dialog.addFooter(applyButton)
        dialog.onEscape = { [weak self] in self?.cancel() }

        themeObservation = CCThemeObservation { [weak self] in
            guard let self else { return }
            for label in self.labels {
                label.font = NSFont.systemFont(ofSize: CCTheme.font.chip.pointSize, weight: .semibold)
                label.textColor = CCTheme.color.foreground
            }
            for caption in self.captions {
                caption.font = CCTheme.font.label
                caption.textColor = CCTheme.color.mutedForeground
            }
        }
    }

    /// conflict id → the side each control shows now.
    var choices: [String: MergeSide] {
        Dictionary(uniqueKeysWithValues: rows.map { ($0.conflict.id, $0.control.selectedIndex == 0 ? MergeSide.mine : .theirs) })
    }

    func present(over window: NSWindow) {
        dialog.present(over: window)
    }

    func dismiss(completion: (() -> Void)? = nil) {
        dialog.dismiss(completion: completion)
    }

    private func apply() {
        let picked = choices
        applyButton.isEnabled = false
        cancelButton.isEnabled = false
        dialog.dismiss { [weak self] in self?.onApply?(picked) }
    }

    private func cancel() {
        dialog.dismiss { [weak self] in self?.onCancel?() }
    }

    // MARK: - Probe seams (`--cloud-sync-test`)

    var probeCard: NSView { dialog.card }
    var probeSegments: [CCSegmented] { rows.map(\.control) }
    var probeApplyButton: CCButton { applyButton }
    var probeCancelButton: CCButton { cancelButton }
    var probeTitles: [String] { labels.map(\.stringValue) }
    var probeAccordion: CCAccordion? { accordion }

    // MARK: - Words

    static func theirsName(_ review: CloudMergeReview) -> String {
        if let name = review.author?.name, !name.isEmpty {
            if let label = review.author?.clientLabel, !label.isEmpty { return "\(name) (\(label))" }
            return name
        }
        return "The web editor"
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

    static func detail(for conflict: MergeConflict, theirs: String) -> String {
        switch conflict.kind {
        case "clipStructure":
            return "The clips were cut or trimmed on both sides. Mine keeps this Mac's clips; Theirs keeps \(theirs)'s."
        case "deleteVsModify":
            let noun = noun(forPath: conflict.path).lowercased()
            return conflict.deletedBy == .mine
                ? "Deleted on this Mac but edited by \(theirs). Mine deletes the \(noun); Theirs keeps the edit."
                : "Deleted by \(theirs) but edited on this Mac. Mine keeps the edit; Theirs deletes the \(noun)."
        case "subtitlesRegenerated":
            let by = conflict.regeneratedBy == "mine" ? "on this Mac" : conflict.regeneratedBy == "theirs" ? "by \(theirs)" : "on both sides"
            return "Captions were regenerated \(by) and edited on the other side. Pick one set of captions."
        case "laneOverlap":
            return "Combining both sides would make two items overlap on this lane. Pick whose timing to keep for both."
        default:
            return "Both sides changed this."
        }
    }

    static func describe(_ item: MergeAutoResolved) -> String {
        let side = item.winner == .mine ? "this Mac" : "theirs"
        let what: String
        switch item.kind {
        case "order": what = "\(noun(forPath: item.path)) order"
        default: what = item.path
        }
        return "• \(what) — kept \(side)"
    }
}
