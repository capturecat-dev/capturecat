import UIKit

/// CCKit select — a trigger well showing the current choice with a
/// chevron-up-down; tapping opens the house action sheet with the current
/// value checked (far right). For small pickers ("Which Mac?").
final class CCSelect: UIControl {
    // Keyboard (iPad, Studio 6a): Tab / arrows focus it; Space or Return
    // activates it — the same action a tap sends.
    override var canBecomeFocused: Bool { isEnabled && !isHidden && isUserInteractionEnabled }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if ccIsActivation(presses), isEnabled { sendActions(for: .touchUpInside); return }
        super.pressesEnded(presses, with: event)
    }

    var options: [String] { didSet { refresh() } }
    private(set) var selectedIndex: Int
    var onSelect: ((Int) -> Void)?
    /// The sheet title.
    var prompt: String?
    /// Shown in place of the selected option while set — e.g. "Custom" while
    /// a freeform value supersedes the list (the Mac menu's overrideTitle).
    var overrideTitle: String? { didSet { if overrideTitle != oldValue { refresh() } } }
    weak var presenter: UIViewController?

    private let valueLabel: UILabel
    private let leadingIcon: CCIconView?
    private let chevron = CCIconView("chevron-up-down", pointSize: 11, weight: .semibold, tint: CCTheme.color.mutedForeground)

    init(options: [String], selectedIndex: Int = 0, symbol: String? = nil) {
        self.options = options
        self.selectedIndex = selectedIndex
        valueLabel = ccLabel("", font: CCFont.chip, color: CCTheme.color.foreground)
        // Big Dynamic Type: a long choice shrinks to fit (≥ 60%) instead of losing its end.
        valueLabel.adjustsFontSizeToFitWidth = true
        valueLabel.minimumScaleFactor = 0.6
        leadingIcon = symbol.map { CCIconView($0, pointSize: 15, weight: .medium, tint: CCTheme.color.mutedForeground) }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerCurve = .continuous
        let row = UIStackView(arrangedSubviews: [leadingIcon, valueLabel, chevron].compactMap { $0 })
        row.spacing = CCSpace.sm
        row.alignment = .center
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        addAction(UIAction { [weak self] _ in self?.open() }, for: .touchUpInside)
        ccOnThemeChange { [weak self] in self?.applyTheme() }
        applyTheme()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setSelectedIndex(_ index: Int) {
        guard options.indices.contains(index) else { return }
        selectedIndex = index
        refresh()
    }

    private func refresh() {
        valueLabel.text = overrideTitle ?? (options.indices.contains(selectedIndex) ? options[selectedIndex] : "")
        accessibilityLabel = prompt ?? String(localized: "Choose", comment: "Pop-up menu with no prompt (VoiceOver label)")
        accessibilityValue = valueLabel.text
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = CCTheme.radius(.md)
        CCMaterial.refit(layer, radius: CCTheme.radius(.md))
    }

    private func applyTheme() {
        CCMaterial.dress(layer, as: .recessed(tint: CCTheme.color.elevated), radius: CCTheme.radius(.md), traits: traitCollection)
        layer.borderWidth = 1
        layer.borderColor = cc(CCTheme.color.border)
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            CCMaterial.press(layer, down: isHighlighted, traits: traitCollection)
        }
    }

    private func open() {
        guard let presenter else { return }
        let sheet = CCActionSheet(title: prompt)
        for (index, option) in options.enumerated() {
            sheet.addAction(option, checked: index == selectedIndex) { [weak self] in
                guard let self else { return }
                self.selectedIndex = index
                self.refresh()
                CCMotion.pop(self.valueLabel, from: 0.92)
                self.onSelect?(index)
            }
        }
        sheet.present(from: presenter, source: self)
    }
}
