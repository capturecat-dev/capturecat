import UIKit

/// CCKit empty state — shadcn's Empty: a quiet well holding a centered icon
/// on a FLOATING tile, a title, a short description and up to two actions.
/// On arrival the pieces rise in one after another (staggered fade + lift).
///
///     let empty = CCEmptyState(symbol: "film-stack", title: "No recordings yet",
///                              message: "Capture your first take.",
///                              primary: CCButton(title: "Open Capture", style: .primary) { … })
final class CCEmptyState: UIView {
    var playsEntrance = true

    private let tile: CCIconTile
    private let titleLabel: UILabel
    private let messageLabel: UILabel
    private let buttonRow = UIStackView()
    private let stack = UIStackView()
    private var hasEntered = false
    /// Draw the surrounding well (off when the empty state fills a screen).
    let showsWell: Bool

    init(symbol: String, title: String, message: String? = nil, primary: CCButton? = nil, secondary: CCButton? = nil, showsWell: Bool = true) {
        tile = CCIconTile(symbol: symbol, side: 56, kind: .raised, tint: CCTheme.color.card, iconSize: 24,
                          iconTint: CCTheme.color.mutedForeground, radius: .lg)
        titleLabel = ccLabel(title, font: CCFont.header, color: CCTheme.color.foreground, lines: 2, alignment: .center)
        messageLabel = ccLabel(message ?? "", font: CCFont.label, color: CCTheme.color.mutedForeground, lines: 0, alignment: .center)
        self.showsWell = showsWell
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerCurve = .continuous
        messageLabel.isHidden = message == nil

        buttonRow.axis = .horizontal
        buttonRow.spacing = CCSpace.sm
        for button in [secondary, primary].compactMap({ $0 }) { buttonRow.addArrangedSubview(button) }
        buttonRow.isHidden = buttonRow.arrangedSubviews.isEmpty

        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = CCSpace.xs + 2
        for view in [tile, titleLabel, messageLabel, buttonRow] { stack.addArrangedSubview(view) }
        stack.setCustomSpacing(CCSpace.md + 4, after: tile)
        stack.setCustomSpacing(CCSpace.lg + 2, after: messageLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: CCSpace.xl + 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -(CCSpace.xl + 8)),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: CCSpace.lg),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -CCSpace.lg),
            messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
            titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
        ])
        accessibilityElements = [titleLabel, messageLabel, buttonRow]
        titleLabel.accessibilityTraits = .header
        ccOnThemeChange { [weak self] in self?.applyTheme() }
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var pieces: [UIView] { [tile, titleLabel, messageLabel, buttonRow].filter { !$0.isHidden } }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = CCTheme.radius(.xl)
        CCMaterial.refit(layer, radius: CCTheme.radius(.xl))
    }

    private func applyTheme() {
        let colors = CCTheme.color
        if showsWell {
            CCMaterial.dress(layer, as: .recessed(tint: colors.background.ccBlended(0.5, of: colors.elevated, traits: traitCollection)), radius: CCTheme.radius(.xl), traits: traitCollection)
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyTheme()
        guard window != nil, playsEntrance, !hasEntered else { return }
        hasEntered = true
        CCMotion.stagger(pieces, distance: 10, interval: 0.06)
    }
}
