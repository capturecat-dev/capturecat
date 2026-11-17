import UIKit

/// "16:9 ↕" — the Mac editor bar's aspect select (`CCSelect`, plain chrome):
/// the ratio in the bar's type with the up-down chevron, no well. Tapping
/// opens the house action sheet (each ratio with its platform hint, the
/// current one checked). Draws compact, answers across 44 pt.
final class EditorAspectChip: UIControl {
    var onSelect: ((AspectRatio) -> Void)?
    weak var presenter: UIViewController?
    private(set) var ratio: AspectRatio = .auto

    private let label = ccLabel("Auto", font: CCFont.scaled(14, .semibold, .subheadline, max: 22), color: CCTheme.color.foreground)
    private let chevron = CCIconView("chevron-up-down", pointSize: 11, weight: .semibold, tint: CCTheme.color.mutedForeground)

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        accessibilityIdentifier = "studio.aspect"
        label.adjustsFontForContentSizeCategory = true
        let row = UIStackView(arrangedSubviews: [label, chevron])
        row.spacing = 6
        row.alignment = .center
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 34),
        ])
        layer.cornerRadius = CCTheme.radius(.md)
        layer.cornerCurve = .continuous
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "Aspect Ratio"
        accessibilityHint = "Chooses the video's shape."
        addAction(UIAction { [weak self] _ in self?.open() }, for: .touchUpInside)
        setRatio(.auto)
        ccInstallPointerHover { [weak self] in self?.layer.cornerRadius ?? 0 }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setRatio(_ ratio: AspectRatio) {
        self.ratio = ratio
        if label.text != ratio.rawValue { label.text = ratio.rawValue }
        accessibilityValue = ratio.rawValue
    }

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? CCTheme.color.active : .clear }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -max(0, (44 - bounds.width) / 2), dy: -max(0, (44 - bounds.height) / 2)).contains(point)
    }

    override var canBecomeFocused: Bool { isEnabled && !isHidden }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if ccIsActivation(presses), isEnabled { sendActions(for: .touchUpInside); return }
        super.pressesEnded(presses, with: event)
    }

    private func open() {
        guard let presenter else { return }
        let sheet = CCActionSheet(title: "Aspect Ratio")
        for option in AspectRatio.allCases {
            let title = option.platformHint.map { "\(option.rawValue)  ·  \($0)" } ?? option.rawValue
            sheet.addAction(title, checked: option == ratio) { [weak self] in
                guard let self else { return }
                self.setRatio(option)
                CCMotion.pop(self.label, from: 0.92)
                self.onSelect?(option)
            }
        }
        sheet.present(from: presenter, source: self)
    }
}
