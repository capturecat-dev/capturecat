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
            title: MergeReviewWords.dialogTitle(conflicts: count),
            subtitle: projectName,
            width: 500)
        dialog.entrance = .slideUp()

        let who = Self.theirsName(review)
        let intro = CCWrappingLabel()
        intro.stringValue = MergeReviewWords.intro(theirs: who, device: "Mac")
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
                segments: MergeReviewWords.segments,
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
                title: MergeReviewWords.autoResolvedTitle(n),
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

    // MARK: - Words (shared: Studio/ProjectHistory/HistoryWords.swift)

    static func theirsName(_ review: CloudMergeReview) -> String { MergeReviewWords.theirsName(author: review.author) }

    /// "Annotation", "Zoom", "Caption word"… for a collection path.
    static func noun(forPath path: String) -> String { MergeReviewWords.noun(forPath: path) }

    static func title(for conflict: MergeConflict) -> String { MergeReviewWords.title(for: conflict) }

    static func detail(for conflict: MergeConflict, theirs: String) -> String {
        MergeReviewWords.detail(for: conflict, theirs: theirs, device: "Mac")
    }

    static func describe(_ item: MergeAutoResolved) -> String { MergeReviewWords.describe(item, device: "Mac") }
}
