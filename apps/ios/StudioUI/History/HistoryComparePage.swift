import UIKit

/// History ▸ Compare: what changed between two versions (or a version and
/// the project now), grouped by where you would edit it — the shared
/// `VersionCompareGroups`, exactly the Mac's "Compare with Current" dialog
/// groups. One disclosure section per group, the first open (the Mac's
/// accordion); sections open and close on the house growth bounce.
///
/// It slides over the version list inside the History panel (the panel
/// drives the transition); Back slides it away.
final class HistoryComparePage: UIView {
    var onBack: (() -> Void)?

    let groups: [VersionCompareGroups.Group]
    let summaryText: String
    let backButton = CCButton(title: "History", symbol: "chevron-left", style: .ghost, size: .sm, radius: .full)
    private let titleLabel = ccLabel("Compare", font: CCFont.header, color: CCTheme.color.foreground)
    private let subtitleLabel: UILabel
    private let summaryLabel: UILabel
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private(set) var sections: [HistoryDisclosureSection] = []

    /// `fromTitle` → `toTitle` ("Sep 28, 3:42 PM" → "now").
    init(from: JSONValue, to: JSONValue, fromTitle: String, toTitle: String) {
        groups = VersionCompareGroups.groups(from: from, to: to)
        summaryText = VersionCompareGroups.summary(groups)
        subtitleLabel = ccLabel("\(fromTitle) → \(toTitle)", font: CCFont.caption, color: CCTheme.color.mutedForeground, lines: 2)
        summaryLabel = ccLabel(summaryText, font: CCFont.label, color: CCTheme.color.mutedForeground, lines: 0)
        super.init(frame: .zero)
        backButton.onTap = { [weak self] in self?.onBack?() }
        backButton.accessibilityLabelOverride = "Back to History"
        titleLabel.accessibilityTraits = .header

        stack.axis = .vertical
        stack.spacing = CCSpace.sm
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        scroll.showsHorizontalScrollIndicator = false
        scroll.addSubview(stack)
        stack.addArrangedSubview(summaryLabel)
        stack.setCustomSpacing(CCSpace.md, after: summaryLabel)
        for (index, group) in groups.enumerated() {
            let section = HistoryDisclosureSection(title: "\(group.title) (\(group.lines.count))",
                                                   lines: group.lines.map { "• \($0)" }, expanded: index == 0)
            sections.append(section)
            stack.addArrangedSubview(section)
        }

        let head = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        head.axis = .vertical
        head.spacing = 2
        for view in [backButton, head, scroll] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let pad = CCSpace.lg
        NSLayoutConstraint.activate([
            backButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CCSpace.sm),
            backButton.topAnchor.constraint(equalTo: topAnchor, constant: CCSpace.sm),
            head.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            head.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            head.topAnchor.constraint(equalTo: backButton.bottomAnchor, constant: CCSpace.xs),
            scroll.topAnchor.constraint(equalTo: head.bottomAnchor, constant: CCSpace.md),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: pad),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -pad),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -CCSpace.lg),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -pad * 2),
        ])
        accessibilityViewIsModal = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var probeSummary: String { summaryLabel.text ?? "" }
}

/// A disclosure card: a header key (title + chevron) and a body of lines.
/// Opening grows the card downward on the house bounce; only the bottom
/// edge moves.
final class HistoryDisclosureSection: CCSurface {
    let title: String
    let lines: [String]
    private(set) var isExpanded: Bool
    private let header = UIControl()
    private let titleLabel: UILabel
    private let chevron = CCIconView("chevron-down", pointSize: 13, weight: .semibold, tint: CCTheme.color.mutedForeground)
    private let body: UILabel
    private var collapsed: NSLayoutConstraint!

    init(title: String, lines: [String], expanded: Bool) {
        self.title = title
        self.lines = lines
        isExpanded = expanded
        titleLabel = ccLabel(title, font: CCFont.labelSemibold, color: CCTheme.color.foreground, lines: 2)
        body = ccLabel(lines.joined(separator: "\n"), font: CCFont.caption, color: CCTheme.color.mutedForeground, lines: 0)
        super.init(.recessed, tint: CCTheme.color.elevated, radius: .lg)
        translatesAutoresizingMaskIntoConstraints = false
        clipsToBounds = true
        header.translatesAutoresizingMaskIntoConstraints = false
        for view in [titleLabel, chevron] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.isUserInteractionEnabled = false
            header.addSubview(view)
        }
        body.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        addSubview(body)
        collapsed = bottomAnchor.constraint(equalTo: header.bottomAnchor)
        let open = body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -CCSpace.md)
        open.priority = .defaultHigh
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            header.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: CCSpace.md),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -CCSpace.sm),
            titleLabel.topAnchor.constraint(equalTo: header.topAnchor, constant: 14),
            titleLabel.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -14),
            chevron.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -CCSpace.md),
            chevron.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CCSpace.md),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CCSpace.md),
            body.topAnchor.constraint(equalTo: header.bottomAnchor),
            open,
        ])
        collapsed.isActive = !expanded
        body.alpha = expanded ? 1 : 0
        chevron.transform = expanded ? .identity : CGAffineTransform(rotationAngle: -.pi / 2)
        header.isAccessibilityElement = true
        header.accessibilityTraits = .button
        header.accessibilityLabel = title
        header.accessibilityValue = expanded ? "Expanded" : "Collapsed"
        header.addAction(UIAction { [weak self] _ in self?.toggle() }, for: .touchUpInside)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func toggle() { setExpanded(!isExpanded, animated: true) }

    func setExpanded(_ expanded: Bool, animated: Bool) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        header.accessibilityValue = expanded ? "Expanded" : "Collapsed"
        collapsed.isActive = !expanded
        let root = ccLayoutRoot
        let changes = {
            self.body.alpha = expanded ? 1 : 0
            self.chevron.transform = expanded ? .identity : CGAffineTransform(rotationAngle: -.pi / 2)
            root.layoutIfNeeded()
        }
        if animated {
            CCMotion.run(duration: 0.34, curve: expanded ? .bounce : .settle, changes)
        } else {
            changes()
        }
    }

    var probeHeader: UIControl { header }
    var probeBody: String { body.text ?? "" }
}
