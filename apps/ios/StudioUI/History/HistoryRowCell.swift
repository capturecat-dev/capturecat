import UIKit

/// One version in the History panel — the touch twin of the Mac's
/// `HistoryRowView`: `CCAvatar` for the author, the time, `CCBadge`s for
/// the client / name / kind, and the change summary. Words and badges come
/// from the shared `HistoryRowModel`, so the two platforms list the same row.
/// A tap opens the row's house action sheet (the Mac's click / right-click
/// menu); pressing washes the row.
final class HistoryRowCell: UIControl {
    let version: CloudVersion
    let model: HistoryRowModel
    var onActivate: ((HistoryRowCell) -> Void)?

    private let avatar: CCAvatar
    private let timeLabel: UILabel
    private let authorLabel: UILabel
    private let summaryLabel: UILabel
    private let badgeRow = UIStackView()
    private(set) var badges: [CCBadge] = []
    private let wash = UIView()

    static let minHeight: CGFloat = 64

    init(version: CloudVersion, model: HistoryRowModel) {
        self.version = version
        self.model = model
        avatar = CCAvatar(name: model.author, side: 32)
        timeLabel = ccLabel(model.timeText, font: CCFont.labelSemibold, color: CCTheme.color.foreground)
        authorLabel = ccLabel(model.author, font: CCFont.label, color: CCTheme.color.mutedForeground)
        summaryLabel = ccLabel(model.summary, font: CCFont.caption, color: CCTheme.color.mutedForeground)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        wash.isUserInteractionEnabled = false
        wash.alpha = 0
        wash.layer.cornerCurve = .continuous
        wash.translatesAutoresizingMaskIntoConstraints = false
        addSubview(wash)

        badgeRow.axis = .horizontal
        badgeRow.spacing = CCSpace.xs
        badgeRow.alignment = .center
        badgeRow.isUserInteractionEnabled = false
        for badge in model.badges {
            let variant: CCBadge.Variant
            switch badge.style {
            case .subtle: variant = .subtle
            case .primary: variant = .primary
            case .outline: variant = .outline
            }
            let view = CCBadge(badge.text, variant: variant)
            badgeRow.addArrangedSubview(view)
            badges.append(view)
        }
        authorLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.lineBreakMode = .byTruncatingTail
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        authorLabel.setContentCompressionResistancePriority(UILayoutPriority(200), for: .horizontal)
        authorLabel.setContentHuggingPriority(UILayoutPriority(200), for: .horizontal)
        summaryLabel.setContentCompressionResistancePriority(UILayoutPriority(200), for: .horizontal)
        badgeRow.setContentCompressionResistancePriority(UILayoutPriority(750), for: .horizontal)
        badgeRow.setContentHuggingPriority(.required, for: .horizontal)

        for view in [avatar, timeLabel, authorLabel, badgeRow, summaryLabel] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.isUserInteractionEnabled = false
            addSubview(view)
        }
        let pad = CCSpace.md
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minHeight),
            wash.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            wash.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            wash.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            wash.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),

            avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            avatar.topAnchor.constraint(equalTo: topAnchor, constant: 12),

            timeLabel.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: CCSpace.sm + 2),
            timeLabel.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            authorLabel.leadingAnchor.constraint(equalTo: timeLabel.trailingAnchor, constant: CCSpace.xs + 2),
            authorLabel.firstBaselineAnchor.constraint(equalTo: timeLabel.firstBaselineAnchor),
            authorLabel.trailingAnchor.constraint(lessThanOrEqualTo: badgeRow.leadingAnchor, constant: -CCSpace.xs),
            badgeRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            badgeRow.centerYAnchor.constraint(equalTo: timeLabel.centerYAnchor),

            summaryLabel.leadingAnchor.constraint(equalTo: timeLabel.leadingAnchor),
            summaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -pad),
            summaryLabel.topAnchor.constraint(equalTo: timeLabel.bottomAnchor, constant: 3),
            summaryLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10),
        ])

        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = model.accessibilityLabel(clientLabel: version.clientLabel)
        accessibilityHint = "Shows what you can do with this version"
        addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onActivate?(self)
        }, for: .touchUpInside)
        ccOnThemeChange { [weak self] in self?.applyTheme() }
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        wash.layer.cornerRadius = CCTheme.radius(.md)
    }

    private func applyTheme() {
        wash.backgroundColor = CCTheme.color.active
        timeLabel.textColor = CCTheme.color.foreground
        authorLabel.textColor = CCTheme.color.mutedForeground
        summaryLabel.textColor = CCTheme.color.mutedForeground
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            CCMotion.fadeAlpha(wash, to: isHighlighted ? 1 : 0, duration: isHighlighted ? 0.08 : 0.22)
        }
    }

    /// Marks the row whose menu / preview is open (the Mac's held wash).
    func setActive(_ active: Bool) {
        CCMotion.fadeAlpha(wash, to: active ? 0.7 : 0, duration: 0.18)
    }

    // MARK: Probe seams

    var probeTime: String { timeLabel.text ?? "" }
    var probeAuthor: String { authorLabel.text ?? "" }
    var probeSummary: String { summaryLabel.text ?? "" }
    var probeAvatar: CCAvatar { avatar }
}

/// A row the panel shows above the versions when project.json changed
/// outside this editor (another window of the app, Files): what changed and
/// [Review] — the iOS twin of the Mac's "On this Mac — not synced" row.
final class HistoryExternalRow: UIView {
    var onReview: (() -> Void)?
    private let icon = CCIconView("arrow.triangle.merge", pointSize: 15, weight: .medium, tint: CCTheme.color.primary)
    let titleLabel = ccLabel("Changed outside this editor", font: CCFont.labelSemibold, color: CCTheme.color.foreground)
    let summaryLabel: UILabel
    let reviewButton = CCButton(title: "Review", symbol: "merge", style: .secondary, size: .sm, radius: .full)

    init(summary: String) {
        summaryLabel = ccLabel(summary, font: CCFont.caption, color: CCTheme.color.mutedForeground, lines: 2)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        reviewButton.onTap = { [weak self] in self?.onReview?() }
        for view in [icon, titleLabel, summaryLabel, reviewButton] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        titleLabel.setContentCompressionResistancePriority(UILayoutPriority(200), for: .horizontal)
        let pad = CCSpace.md
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 64),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad + 6),
            icon.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad + 32 + CCSpace.sm + 2 - 6),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: reviewButton.leadingAnchor, constant: -CCSpace.sm),
            summaryLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            summaryLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            summaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: reviewButton.leadingAnchor, constant: -CCSpace.sm),
            summaryLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10),
            reviewButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            reviewButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
