import UIKit

/// CCKit button — shadcn's Button variants in UIKit, house chrome.
///
///     let save = CCButton(title: "Save", style: .primary) { … }
///     let copy = CCButton(title: "Copy link", symbol: "link", style: .secondary, size: .sm)
///     let back = CCButton(symbol: "chevron-left", style: .ghost)   // icon-only square
///
/// Filled styles are FLOATING (raised material). Press TINTS IN PLACE (a darker
/// wash on light, lighter on dark) — the button never moves, scales or
/// restyles. Actions fire on touch-up inside. Ghost buttons have no surface
/// at rest; pressing washes them. `isBusy` swaps the content for a spinner.
final class CCButton: UIControl {
    enum Style {
        case primary
        case secondary
        case outline
        case ghost
        case link
        case destructive
    }

    enum Size {
        case sm
        case regular
        case lg

        var height: CGFloat {
            switch self {
            case .sm: return 34
            case .regular: return 42
            case .lg: return 50
            }
        }

        var hPadding: CGFloat {
            switch self {
            case .sm: return 12
            case .regular: return 16
            case .lg: return 20
            }
        }

        var symbolPointSize: CGFloat {
            switch self {
            case .sm: return 13
            case .regular: return 15
            case .lg: return 16
            }
        }

        var font: UIFont {
            switch self {
            case .sm: return CCFont.scaled(14, .medium, .footnote, max: 18)
            case .regular: return CCFont.scaled(15, .medium, .subheadline, max: 20)
            case .lg: return CCFont.scaled(17, .medium, .body, max: 22)
            }
        }
    }

    enum SymbolPlacement {
        case leading
        case trailing
    }

    var onTap: (() -> Void)?
    var symbolPlacement: SymbolPlacement = .leading { didSet { setNeedsLayout() } }
    /// Haptic acknowledgement (light impact) on tap — primary actions.
    var haptics: Bool

    var style: Style { didSet { applyTheme(animated: true) } }
    var size: Size {
        didSet {
            label.font = size.font
            refreshIcon()
            heightConstraint.constant = size.height
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }
    var radius: CCRadius { didSet { setNeedsLayout() } }

    var title: String {
        get { label.text ?? "" }
        set {
            guard newValue != label.text else { return }
            if window != nil {
                let fade = CATransition()
                fade.type = .fade
                fade.duration = CCMotion.paced(0.18)
                label.layer.add(fade, forKey: "ccbutton.title")
            }
            label.text = newValue
            if accessibilityLabelOverride == nil { accessibilityLabel = newValue }
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }

    var symbol: String? {
        didSet { refreshIcon(); invalidateIntrinsicContentSize(); setNeedsLayout() }
    }

    /// For icon-only buttons (VoiceOver).
    var accessibilityLabelOverride: String? {
        didSet { accessibilityLabel = accessibilityLabelOverride ?? title }
    }

    /// Replaces the content with a spinner and ignores taps.
    var isBusy = false {
        didSet {
            guard isBusy != oldValue else { return }
            isUserInteractionEnabled = !isBusy
            if isBusy { spinner.startAnimating() } else { spinner.stopAnimating() }
            let contentAlpha: CGFloat = isBusy ? 0 : 1
            CCMotion.quick {
                self.label.alpha = contentAlpha
                self.icon.alpha = contentAlpha
            }
            accessibilityValue = isBusy ? "In progress" : nil
        }
    }

    override var isEnabled: Bool {
        didSet {
            CCMotion.quick { self.alpha = self.isEnabled ? 1 : CCTheme.disabledAlpha }
            accessibilityTraits = isEnabled ? .button : [.button, .notEnabled]
        }
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            applyTheme(animated: true)
        }
    }

    private let label = UILabel()
    private let icon = UIImageView()
    private let spinner: CCSpinner
    private var heightConstraint: NSLayoutConstraint!
    private var isIconOnly: Bool { (label.text ?? "").isEmpty && symbol != nil }

    init(
        title: String = "",
        symbol: String? = nil,
        style: Style = .secondary,
        size: Size = .regular,
        radius: CCRadius = .md,
        haptics: Bool? = nil,
        onTap: (() -> Void)? = nil
    ) {
        self.style = style
        self.size = size
        self.radius = radius
        self.symbol = symbol
        self.onTap = onTap
        self.haptics = haptics ?? (style == .primary || style == .destructive)
        spinner = CCSpinner(diameter: 18)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerCurve = .continuous

        label.text = title
        label.font = size.font
        label.adjustsFontForContentSizeCategory = true
        label.lineBreakMode = .byTruncatingTail
        label.textAlignment = .center
        icon.contentMode = .center
        for view in [icon, label, spinner] as [UIView] {
            view.isUserInteractionEnabled = false
            addSubview(view)
        }
        refreshIcon()
        heightConstraint = heightAnchor.constraint(equalToConstant: size.height)
        heightConstraint.isActive = true
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
        // Labels around a button truncate before the button does.
        setContentCompressionResistancePriority(UILayoutPriority(760), for: .horizontal)

        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = title
        addAction(UIAction { [weak self] _ in
            guard let self, self.isEnabled, !self.isBusy else { return }
            if self.haptics { CCHaptics.light() }
            self.onTap?()
        }, for: .touchUpInside)
        ccOnThemeChange { [weak self] in self?.applyTheme() }
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { applyTheme() }
    }

    private func refreshIcon() {
        icon.image = symbol.flatMap { CCIcon.image($0, pointSize: size.symbolPointSize, weight: .semibold) }
        icon.isHidden = symbol == nil
    }

    private var titleWidth: CGFloat {
        guard let text = label.text, !text.isEmpty else { return 0 }
        return ceil((text as NSString).size(withAttributes: [.font: label.font as Any]).width) + 1
    }

    override var intrinsicContentSize: CGSize {
        if isIconOnly { return CGSize(width: size.height, height: size.height) }
        var width = titleWidth + size.hPadding * 2
        if symbol != nil { width += CCIcon.side(for: size.symbolPointSize) + CCSpace.xs + 2 }
        return CGSize(width: ceil(width), height: size.height)
    }

    /// Icon-only buttons keep a 44 pt touch target.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let dx = max(0, (44 - bounds.width) / 2), dy = max(0, (44 - bounds.height) / 2)
        return bounds.insetBy(dx: -dx, dy: -dy).contains(point)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let r = radius.resolved(for: bounds.height)
        layer.cornerRadius = r
        CCMaterial.refit(layer, radius: r)
        spinner.frame = CGRect(x: (bounds.width - 18) / 2, y: (bounds.height - 18) / 2, width: 18, height: 18)

        let iconSide = symbol != nil ? CCIcon.side(for: size.symbolPointSize) : 0
        if isIconOnly {
            icon.frame = CGRect(x: (bounds.width - iconSide) / 2, y: (bounds.height - iconSide) / 2, width: iconSide, height: iconSide)
            label.frame = .zero
            return
        }
        let gap: CGFloat = symbol != nil ? CCSpace.xs + 2 : 0
        let maxLabel = max(0, bounds.width - size.hPadding * 2 - iconSide - gap)
        let labelWidth = min(titleWidth, maxLabel)
        let labelHeight = ceil(label.font.lineHeight)
        let content = labelWidth + iconSide + gap
        var x = max((bounds.width - content) / 2, size.hPadding)
        if symbol != nil, symbolPlacement == .leading {
            icon.frame = CGRect(x: x, y: (bounds.height - iconSide) / 2, width: iconSide, height: iconSide)
            x += iconSide + gap
        }
        label.frame = CGRect(x: x, y: (bounds.height - labelHeight) / 2, width: labelWidth, height: labelHeight)
        if symbol != nil, symbolPlacement == .trailing {
            icon.frame = CGRect(x: x + labelWidth + gap, y: (bounds.height - iconSide) / 2, width: iconSide, height: iconSide)
        }
    }

    private func applyTheme(animated: Bool = false) {
        let colors = CCTheme.color
        let traits = traitCollection
        let dark = CCTheme.isDark(traits)
        var fill: UIColor
        let text: UIColor
        var border: UIColor = .clear
        switch style {
        case .primary:
            fill = colors.primary; text = colors.primaryForeground
        case .secondary:
            fill = colors.elevated; text = colors.foreground; border = colors.border
        case .outline:
            fill = .clear; text = colors.foreground; border = colors.border
        case .ghost:
            fill = .clear; text = colors.foreground
        case .link:
            fill = .clear; text = colors.primary
        case .destructive:
            fill = colors.destructive; text = .white
        }
        if isHighlighted {
            switch style {
            case .ghost, .outline:
                fill = colors.active
            case .link:
                break
            default:
                fill = fill.ccBlended(0.14, of: dark ? .white : .black, traits: traits)
            }
        }
        label.textColor = isHighlighted && style == .link ? text.withAlphaComponent(0.6) : text
        icon.tintColor = label.textColor
        spinner.color = text
        layer.borderWidth = (style == .outline || style == .secondary) ? 1 : 0
        layer.borderColor = cc(border)
        let resolved = fill.resolvedColor(with: traits)
        let r = radius.resolved(for: bounds.height)
        if resolved.cgColor.alpha < 0.01 {
            CCMaterial.strip(layer)
            if animated { CCMotion.fade(layer, keyPath: "backgroundColor", to: UIColor.clear.cgColor, duration: 0.2) } else { layer.backgroundColor = nil }
        } else if style == .ghost || style == .outline {
            // A wash, not a surface.
            CCMaterial.strip(layer)
            if animated {
                CCMotion.fade(layer, keyPath: "backgroundColor", to: resolved.cgColor, duration: isHighlighted ? 0.06 : 0.2)
            } else {
                layer.backgroundColor = resolved.cgColor
            }
        } else {
            layer.backgroundColor = nil
            CCMaterial.dress(layer, as: .raised(tint: resolved), radius: r, traits: traits)
            if animated, let base = layer.sublayers?.first(where: { $0.name == "ccmat.base" }) {
                let fadeIn = CATransition()
                fadeIn.type = .fade
                fadeIn.duration = CCMotion.paced(isHighlighted ? 0.06 : 0.2)
                base.add(fadeIn, forKey: "ccbutton.press")
            }
        }
    }
}

/// Light haptic acknowledgements for primary actions.
enum CCHaptics {
    static func light() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
    }

    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}
