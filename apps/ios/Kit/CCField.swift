import UIKit

/// CCKit text field — shadcn's Input: a flat recessed WELL with real text
/// padding. The kit's ONLY ring lives here: an ink focus ring while editing
/// (never accent-blue). `isError` cross-fades a destructive border.
///
///     let name = CCField(placeholder: "Project name")
///     name.onReturn = { text in … }
final class CCField: UITextField {
    var onTextChange: ((String) -> Void)?
    var onReturn: ((String) -> Void)?

    var radius: CCRadius = .md { didSet { setNeedsLayout() } }

    var isError = false {
        didSet {
            guard isError != oldValue else { return }
            applyTheme(animated: true)
        }
    }

    var placeholderText: String {
        didSet { applyTheme() }
    }

    /// Optional kit icon inside the leading edge.
    private let leadingIcon: CCIconView?
    private let hInset: CGFloat = 12
    static let height: CGFloat = 46

    init(placeholder: String = "", value: String = "", icon: String? = nil) {
        placeholderText = placeholder
        leadingIcon = icon.map { CCIconView($0, pointSize: 15, weight: .medium, tint: CCTheme.color.mutedForeground) }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        text = value
        font = CCFont.chip
        adjustsFontForContentSizeCategory = true
        borderStyle = .none
        clearButtonMode = .never
        layer.cornerCurve = .continuous
        textColor = CCTheme.color.foreground
        // Ink caret + selection, like the Mac CCTextArea (insertionPointColor = foreground): never accent blue.
        tintColor = CCTheme.color.foreground
        if let leadingIcon {
            leadingIcon.translatesAutoresizingMaskIntoConstraints = true
            addSubview(leadingIcon)
        }
        heightAnchor.constraint(greaterThanOrEqualToConstant: Self.height).isActive = true
        addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onTextChange?(self.text ?? "")
        }, for: .editingChanged)
        addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onReturn?(self.text ?? "")
        }, for: .editingDidEndOnExit)
        ccOnThemeChange { [weak self] in self?.applyTheme() }
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var leadingPad: CGFloat {
        leadingIcon == nil ? hInset : hInset + CCIcon.side(for: 15) + CCSpace.sm
    }

    override func textRect(forBounds bounds: CGRect) -> CGRect {
        bounds.inset(by: UIEdgeInsets(top: 0, left: leadingPad, bottom: 0, right: hInset))
    }

    override func editingRect(forBounds bounds: CGRect) -> CGRect { textRect(forBounds: bounds) }
    override func placeholderRect(forBounds bounds: CGRect) -> CGRect { textRect(forBounds: bounds) }

    override func layoutSubviews() {
        super.layoutSubviews()
        let r = radius.resolved(for: bounds.height)
        layer.cornerRadius = r
        CCMaterial.refit(layer, radius: r)
        if let leadingIcon {
            let side = CCIcon.side(for: 15)
            leadingIcon.frame = CGRect(x: hInset, y: (bounds.height - side) / 2, width: side, height: side)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { applyTheme(animated: true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { applyTheme(animated: true) }
        return resigned
    }

    private func applyTheme(animated: Bool = false) {
        let colors = CCTheme.color
        CCMaterial.dress(layer, as: .recessed(tint: colors.elevated), radius: radius.resolved(for: bounds.height), traits: traitCollection)
        attributedPlaceholder = NSAttributedString(string: placeholderText, attributes: [
            .foregroundColor: colors.faintForeground,
            .font: font ?? CCFont.body,
        ])
        let focused = isFirstResponder
        let border: UIColor = focused ? colors.ring : (isError ? colors.destructive : colors.border)
        layer.borderWidth = 1
        if animated, window != nil {
            CCMotion.fade(layer, keyPath: "borderColor", to: cc(border), duration: 0.18)
        } else {
            layer.borderColor = cc(border)
        }
    }
}
