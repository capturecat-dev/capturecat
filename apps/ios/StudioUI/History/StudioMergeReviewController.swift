import UIKit

/// Merge Review (Studio 4f) — the touch twin of the Mac's
/// `MergeReviewDialog`: the structural conflicts of a three-way merge
/// (docs/project-history.md §1.4), one row each with a Mine / Theirs
/// `CCSegmented` starting on the side the merge already applied (the last
/// writer); same-field clashes the merge settled are listed, collapsed, for
/// the record. Apply hands back every row's choice; the caller re-merges
/// (`ProjectMergeSession.choose`) and applies the result as one undo step.
///
/// Words are the shared `MergeReviewWords` ("this iPad" where the Mac says
/// "this Mac"). Presented as a sheet on iPhone, a modal side panel on iPad
/// (`HistoryPresentation.presentReview`).
@available(iOS 26, *)
@MainActor
final class StudioMergeReviewController: UIViewController {
    #if DEBUG
    /// INJECTED DEFECT (`--history --inject merge-pick`): Apply reports the
    /// FIRST conflict on the side its control does NOT show.
    static var debugWrongPick = false
    #endif

    var onApply: (([String: MergeSide]) -> Void)?
    var onCancel: (() -> Void)?
    weak var container: HistorySheetController?

    let session: ProjectMergeSession
    let projectName: String
    let device: String
    private(set) var rows: [(conflict: MergeConflict, title: UILabel, detail: UILabel, control: CCSegmented)] = []
    private(set) var autoResolvedSection: HistoryDisclosureSection?
    let applyButton = CCButton(title: "Apply Merge", style: .primary, size: .regular, radius: .full)
    let cancelButton = CCButton(title: "Cancel", style: .secondary, size: .regular, radius: .full)
    private let introLabel: UILabel
    private var finished = false

    init(session: ProjectMergeSession, projectName: String, device: String) {
        self.session = session
        self.projectName = projectName
        self.device = device
        introLabel = ccLabel(MergeReviewWords.intro(theirs: session.theirsName, device: device),
                             font: CCFont.label, color: CCTheme.color.mutedForeground, lines: 0)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let root = UIView()
        root.backgroundColor = .clear
        view = root
        let title = ccLabel(MergeReviewWords.dialogTitle(conflicts: session.conflicts.count),
                            font: CCFont.header, color: CCTheme.color.foreground)
        title.accessibilityTraits = .header
        let subtitle = ccLabel(projectName, font: CCFont.caption, color: CCTheme.color.mutedForeground)
        let head = UIStackView(arrangedSubviews: [title, subtitle])
        head.axis = .vertical
        head.spacing = 2

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = CCSpace.lg
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(introLabel)
        let who = session.theirsName
        for conflict in session.conflicts {
            let rowTitle = ccLabel(MergeReviewWords.title(for: conflict), font: CCFont.labelSemibold,
                                   color: CCTheme.color.foreground, lines: 2)
            let detail = ccLabel(MergeReviewWords.detail(for: conflict, theirs: who, device: device),
                                 font: CCFont.caption, color: CCTheme.color.mutedForeground, lines: 0)
            let control = CCSegmented(segments: MergeReviewWords.segments,
                                      selectedIndex: conflict.resolution == .mine ? 0 : 1, size: .sm, radius: .full)
            control.accessibilityLabel = MergeReviewWords.title(for: conflict)
            let row = UIStackView(arrangedSubviews: [rowTitle, detail, control])
            row.axis = .vertical
            row.alignment = .leading
            row.spacing = CCSpace.xs + 2
            row.setCustomSpacing(CCSpace.sm, after: detail)
            control.widthAnchor.constraint(equalToConstant: 220).isActive = true
            detail.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
            stack.addArrangedSubview(row)
            rows.append((conflict, rowTitle, detail, control))
        }
        if !session.autoResolved.isEmpty {
            let section = HistoryDisclosureSection(
                title: MergeReviewWords.autoResolvedTitle(session.autoResolved.count),
                lines: session.autoResolved.map { MergeReviewWords.describe($0, device: device) }, expanded: false)
            autoResolvedSection = section
            stack.addArrangedSubview(section)
        }

        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = true
        scroll.showsHorizontalScrollIndicator = false
        scroll.addSubview(stack)
        cancelButton.onTap = { [weak self] in self?.cancel() }
        applyButton.onTap = { [weak self] in self?.apply() }
        let footer = UIStackView(arrangedSubviews: [UIView(), cancelButton, applyButton])
        footer.spacing = CCSpace.sm
        footer.alignment = .center
        for view in [head, scroll, footer] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        let pad = CCSpace.lg
        NSLayoutConstraint.activate([
            head.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),
            head.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad),
            head.topAnchor.constraint(equalTo: root.topAnchor, constant: pad),
            scroll.topAnchor.constraint(equalTo: head.bottomAnchor, constant: CCSpace.md),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -CCSpace.md),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: pad),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -pad),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -CCSpace.md),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -pad * 2),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad),
            footer.bottomAnchor.constraint(equalTo: root.safeAreaLayoutGuide.bottomAnchor, constant: -pad),
        ])
    }

    /// conflict id → the side each control shows now.
    var choices: [String: MergeSide] {
        Dictionary(uniqueKeysWithValues: rows.map { ($0.conflict.id, $0.control.selectedIndex == 0 ? MergeSide.mine : .theirs) })
    }

    func apply() {
        guard !finished else { return }
        finished = true
        var picked = choices
        #if DEBUG
        if Self.debugWrongPick, let first = rows.first {
            picked[first.conflict.id] = picked[first.conflict.id]?.opposite
        }
        #endif
        applyButton.isEnabled = false
        cancelButton.isEnabled = false
        let done = onApply
        close { done?(picked) }
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        let done = onCancel
        close { done?() }
    }

    private func close(_ then: @escaping () -> Void) {
        if let container { container.close(completion: then) } else { dismiss(animated: true, completion: then) }
    }

    override func accessibilityPerformEscape() -> Bool { cancel(); return true }

    // MARK: Probe seams

    var probeIntro: String { introLabel.text ?? "" }
}
