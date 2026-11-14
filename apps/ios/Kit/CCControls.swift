import UIKit

// CCKit form controls — UIKit ports of the Mac's CCToggle, CCCheckbox,
// CCSlider (the Weather-style pill), CCSearchField, CCPreviewPad and
// CCFormRow. Same anatomy and tokens as the Mac kit, at touch scale (~1.25×).

/// Switch: a recessed pill track (accent when on) with a white floating
/// thumb that springs across on the bouncy spring. Mac 36×21 → 48×28.
final class CCToggle: UIControl {
    var onChange: ((Bool) -> Void)?
    private(set) var isOn: Bool

    private static let trackSize = CGSize(width: 48, height: 28)
    private static let inset: CGFloat = 2.5
    private let thumb = CALayer()

    init(isOn: Bool = false, onChange: ((Bool) -> Void)? = nil) {
        self.isOn = isOn
        self.onChange = onChange
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerCurve = .continuous
        let side = Self.trackSize.height - Self.inset * 2
        thumb.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        thumb.cornerRadius = side / 2
        layer.addSublayer(thumb)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.trackSize.width),
            heightAnchor.constraint(equalToConstant: Self.trackSize.height),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .toggleButton
        addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.setOn(!self.isOn, animated: true)
            CCHaptics.selection()
            self.onChange?(self.isOn)
        }, for: .touchUpInside)
        ccOnThemeChange { [weak self] in self?.applyTheme() }
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: CGSize { Self.trackSize }

    func setOn(_ on: Bool, animated: Bool) {
        guard on != isOn else { return }
        isOn = on
        applyTheme()
        moveThumb(animated: animated)
    }

    private var thumbCenter: CGPoint {
        let side = thumb.bounds.height
        return CGPoint(x: isOn ? bounds.width - Self.inset - side / 2 : Self.inset + side / 2, y: bounds.midY)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let r = CCRadius.full.resolved(for: bounds.height)
        layer.cornerRadius = r
        CCMaterial.refit(layer, radius: r)
        if thumb.animation(forKey: "ccmotion.position") == nil { moveThumb(animated: false) }
    }

    private func moveThumb(animated: Bool) {
        if animated, window != nil {
            CCMotion.spring(thumb, keyPath: "position", to: NSValue(cgPoint: thumbCenter), .bouncy)
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            thumb.position = thumbCenter
            CATransaction.commit()
        }
    }

    private func applyTheme() {
        let colors = CCTheme.color
        let track = isOn ? colors.primary : colors.active
        CCMaterial.dress(layer, as: .recessed(tint: track), radius: Self.trackSize.height / 2, traits: traitCollection)
        layer.borderWidth = 1
        layer.borderColor = cc(isOn ? .clear : colors.border)
        CCMaterial.dress(thumb, as: .raised(tint: .white), radius: thumb.bounds.height / 2, traits: traitCollection)
        thumb.shadowColor = UIColor.black.cgColor
        thumb.shadowOpacity = 0.3
        thumb.shadowRadius = 2
        thumb.shadowOffset = CGSize(width: 0, height: 0.5)
        accessibilityValue = isOn ? "On" : "Off"
    }

    var probeThumbLayer: CALayer { thumb }
}

/// Checkbox: a recessed box (accent + floating when checked) whose check
/// draws in with a spring. Mac 18 → 22 pt.
final class CCCheckbox: UIControl {
    var onChange: ((Bool) -> Void)?
    private(set) var isOn: Bool
    private let box = CCSurface(.recessed, tint: CCTheme.color.elevated, radius: .sm)
    private let check = CAShapeLayer()
    private let label: UILabel
    private static let side: CGFloat = 22

    init(title: String, isOn: Bool = false, onChange: ((Bool) -> Void)? = nil) {
        self.isOn = isOn
        self.onChange = onChange
        label = ccLabel(title, font: CCFont.chip, color: CCTheme.color.foreground, lines: 2)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        box.isUserInteractionEnabled = false
        label.isUserInteractionEnabled = false
        addSubview(box)
        addSubview(label)
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 5.5, y: 11.5))
        path.addLine(to: CGPoint(x: 9.5, y: 15.5))
        path.addLine(to: CGPoint(x: 16.5, y: 7.0))
        check.path = path.cgPath
        check.fillColor = nil
        check.lineWidth = 2.4
        check.lineCap = .round
        check.lineJoin = .round
        check.strokeEnd = isOn ? 1 : 0
        check.frame = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
        box.layer.addSublayer(check)
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: Self.side),
            box.heightAnchor.constraint(equalToConstant: Self.side),
            box.leadingAnchor.constraint(equalTo: leadingAnchor),
            box.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: box.trailingAnchor, constant: CCSpace.sm + 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            label.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
        ])
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityTraits = .toggleButton
        addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.setOn(!self.isOn, animated: true)
            CCHaptics.selection()
            self.onChange?(self.isOn)
        }, for: .touchUpInside)
        ccOnThemeChange { [weak self] in self?.applyTheme(animated: false) }
        applyTheme(animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setOn(_ on: Bool, animated: Bool) {
        guard on != isOn else { return }
        isOn = on
        applyTheme(animated: animated)
    }

    private func applyTheme(animated: Bool) {
        let colors = CCTheme.color
        box.kind = isOn ? .raised : .recessed
        box.tint = isOn ? colors.primary : colors.elevated
        box.layer.borderWidth = isOn ? 0 : 1
        box.layer.borderColor = cc(colors.border)
        check.strokeColor = cc(colors.primaryForeground)
        if animated, window != nil {
            if isOn {
                CCMotion.spring(check, keyPath: "strokeEnd", to: 1.0, .smooth)
            } else {
                CCMotion.fade(check, keyPath: "strokeEnd", to: 0.0, duration: 0.12)
            }
        } else {
            check.strokeEnd = isOn ? 1 : 0
        }
        accessibilityValue = isOn ? "Checked" : "Not checked"
    }

    override var isHighlighted: Bool {
        didSet { CCMaterial.press(box.layer, down: isHighlighted, traits: traitCollection) }
    }
}

/// The Weather-style pill slider: title inside on the left, a normalized
/// readout on the right (0–100%, never px/pt), ticks along the track and a
/// slim floating thumb bar that grows while dragged. Mac pill 36 → 44 pt.
final class CCSlider: UIControl {
    var onChange: ((Double) -> Void)?
    var format: ((Double) -> String)? { didSet { refreshValue() } }
    var value: Double = 0.5 {
        didSet {
            value = min(max(value, 0), 1)
            refreshValue()
            setNeedsLayout()
        }
    }

    private static let pillHeight: CGFloat = 44
    private static let hPadding: CGFloat = 16
    private static let maxTicks = 9
    private let titleLabel: UILabel
    private let valueLabel = UILabel()
    private var ticks: [CALayer] = []
    private let thumb = CALayer()
    private var dragging = false

    init(title: String, value: Double = 0.5) {
        titleLabel = ccLabel(title, font: CCFont.scaled(15, .medium, .subheadline, max: 20), color: CCTheme.color.foreground)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerCurve = .continuous
        for _ in 0..<Self.maxTicks {
            let tick = CALayer()
            tick.cornerRadius = 0.5
            layer.addSublayer(tick)
            ticks.append(tick)
        }
        thumb.cornerRadius = 2.5
        layer.addSublayer(thumb)
        valueLabel.font = CCFont.mono
        valueLabel.adjustsFontForContentSizeCategory = true
        valueLabel.textAlignment = .right
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        addSubview(valueLabel)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.pillHeight),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.hPadding),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.hPadding),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 40),
        ])
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityTraits = .adjustable
        self.value = min(max(value, 0), 1)
        refreshValue()   // observers don't fire inside our own init
        ccOnThemeChange { [weak self] in self?.applyTheme() }
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func display(_ v: Double) -> String { format?(v) ?? "\(Int((v * 100).rounded()))%" }

    private func refreshValue() {
        valueLabel.text = display(value)
        accessibilityValue = valueLabel.text
    }

    private var travel: (origin: CGFloat, width: CGFloat) {
        let origin = Self.hPadding + titleLabel.intrinsicContentSize.width + CCSpace.lg
        let end = bounds.width - Self.hPadding - max(valueLabel.intrinsicContentSize.width, 40) - CCSpace.md
        return (origin, max(0, end - origin))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let r = CCRadius.full.resolved(for: bounds.height)
        layer.cornerRadius = r
        CCMaterial.refit(layer, radius: r)
        let (origin, width) = travel
        let midY = bounds.midY
        let visible = width < 64 ? 0 : min(Self.maxTicks, Int(width / 22))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, tick) in ticks.enumerated() {
            tick.isHidden = index >= visible
            guard index < visible else { continue }
            let t = CGFloat(index + 1) / CGFloat(visible + 1)
            tick.frame = CGRect(x: origin + width * t, y: midY - 5, width: 1, height: 10)
        }
        let barWidth: CGFloat = 5
        let barHeight: CGFloat = dragging ? 27 : 22
        if thumb.animation(forKey: "ccmotion.bounds.size.height") == nil {
            thumb.bounds = CGRect(x: 0, y: 0, width: barWidth, height: barHeight)
        }
        thumb.position = CGPoint(x: origin + (width - barWidth) * CGFloat(value) + barWidth / 2, y: midY)
        CATransaction.commit()
        CCMaterial.refit(thumb, radius: 2.5)
    }

    private func applyTheme() {
        let colors = CCTheme.color
        let dark = CCTheme.isDark(traitCollection)
        let fill = dragging ? colors.elevated.ccBlended(0.06, of: dark ? .white : .black, traits: traitCollection) : colors.elevated
        CCMaterial.dress(layer, as: .recessed(tint: fill), radius: Self.pillHeight / 2, traits: traitCollection)
        layer.borderWidth = 1
        layer.borderColor = cc(colors.border)
        for tick in ticks { tick.backgroundColor = colors.faintForeground.resolvedColor(with: traitCollection).withAlphaComponent(0.22).cgColor }
        // The Mac thumb: white on dark, a light-grey floating bar on light.
        CCMaterial.dress(thumb, as: .raised(tint: dark ? .white : .lightGray), radius: 2.5, traits: traitCollection)
        valueLabel.textColor = colors.mutedForeground
    }

    private func update(_ touch: UITouch) {
        let (origin, width) = travel
        guard width > 0 else { return }
        value = Double(min(max((touch.location(in: self).x - origin) / width, 0), 1))
        onChange?(value)
        sendActions(for: .valueChanged)
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        dragging = true
        applyTheme()
        CCMotion.spring(thumb, keyPath: "bounds.size.height", to: 27.0, .snappy)
        update(touch)
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        update(touch)
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        dragging = false
        applyTheme()
        CCMotion.spring(thumb, keyPath: "bounds.size.height", to: 22.0, .bouncy)
    }

    override func cancelTracking(with event: UIEvent?) { endTracking(nil, with: event) }

    override func accessibilityIncrement() { value += 0.05; onChange?(value) }
    override func accessibilityDecrement() { value -= 0.05; onChange?(value) }
}

/// Search well: a recessed pill with the kit loupe, an ink focus ring while
/// editing, and a ghost clear button once there's a query. Mac 36 → 44 pt.
final class CCSearchField: UIView, UITextFieldDelegate {
    var onQueryChange: ((String) -> Void)?
    let textField = UITextField()
    private let loupe = CCIconView("search", pointSize: 15, weight: .medium, tint: CCTheme.color.mutedForeground)
    private let clear = CCButton(symbol: "close", style: .ghost, size: .sm, radius: .full)
    private let placeholder: String
    static let height: CGFloat = 44

    var query: String { textField.text ?? "" }

    init(placeholder: String) {
        self.placeholder = placeholder
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerCurve = .continuous
        textField.font = CCFont.chip
        textField.adjustsFontForContentSizeCategory = true
        textField.textColor = CCTheme.color.foreground
        textField.tintColor = CCTheme.color.foreground // ink caret + selection (Mac rule)
        textField.returnKeyType = .search
        textField.autocorrectionType = .no
        textField.delegate = self
        textField.accessibilityLabel = placeholder
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.addAction(UIAction { [weak self] _ in self?.changed() }, for: .editingChanged)
        textField.addAction(UIAction { [weak self] _ in self?.applyTheme(animated: true) }, for: [.editingDidBegin, .editingDidEnd])
        clear.accessibilityLabelOverride = "Clear search"
        clear.alpha = 0
        clear.onTap = { [weak self] in
            self?.textField.text = ""
            self?.changed()
        }
        for view in [loupe, textField, clear] as [UIView] { addSubview(view) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            loupe.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15),
            loupe.centerYAnchor.constraint(equalTo: centerYAnchor),
            textField.leadingAnchor.constraint(equalTo: loupe.trailingAnchor, constant: 9),
            textField.topAnchor.constraint(equalTo: topAnchor),
            textField.bottomAnchor.constraint(equalTo: bottomAnchor),
            clear.leadingAnchor.constraint(equalTo: textField.trailingAnchor, constant: 4),
            clear.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            clear.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        ccOnThemeChange { [weak self] in self?.applyTheme(animated: false) }
        applyTheme(animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let r = CCRadius.full.resolved(for: bounds.height)
        layer.cornerRadius = r
        CCMaterial.refit(layer, radius: r)
    }

    private func changed() {
        CCMotion.fadeAlpha(clear, to: query.isEmpty ? 0 : 1, duration: 0.16)
        onQueryChange?(query)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    private func applyTheme(animated: Bool) {
        let colors = CCTheme.color
        CCMaterial.dress(layer, as: .recessed(tint: colors.elevated), radius: Self.height / 2, traits: traitCollection)
        textField.attributedPlaceholder = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: colors.mutedForeground, .font: CCFont.chip,
        ])
        let focused = textField.isFirstResponder
        layer.borderWidth = 1
        let border = cc(focused ? colors.ring : colors.border)
        if animated, window != nil {
            CCMotion.fade(layer, keyPath: "borderColor", to: border, duration: 0.18)
        } else {
            layer.borderColor = border
        }
    }
}

/// Recessed demo well with an optional 3×3 grid of dots (placement pads).
final class CCPreviewPad: UIView {
    private var dots: [CALayer] = []

    init(showsGridDots: Bool = false) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerCurve = .continuous
        if showsGridDots {
            for _ in 0..<9 {
                let dot = CALayer()
                dot.cornerRadius = 1.5
                layer.addSublayer(dot)
                dots.append(dot)
            }
        }
        isAccessibilityElement = false
        ccOnThemeChange { [weak self] in self?.applyTheme() }
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func applyTheme() {
        CCMaterial.dress(layer, as: .recessed(tint: CCTheme.color.elevated), radius: CCTheme.radius(.lg), traits: traitCollection)
        layer.borderWidth = 1
        layer.borderColor = cc(CCTheme.color.border)
        let ink: UIColor = CCTheme.isDark(traitCollection) ? .white : .black
        for dot in dots { dot.backgroundColor = ink.withAlphaComponent(0.18).cgColor }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = CCTheme.radius(.lg)
        CCMaterial.refit(layer, radius: CCTheme.radius(.lg))
        let rect = bounds.insetBy(dx: 14, dy: 14)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, dot) in dots.enumerated() {
            let fx = CGFloat(index % 3) / 2, fy = CGFloat(index / 3) / 2
            dot.frame = CGRect(x: rect.minX + fx * rect.width - 1.5, y: rect.minY + fy * rect.height - 1.5, width: 3, height: 3)
        }
        CATransaction.commit()
    }
}

/// Label + control + hint (+ an error line that grows in on the bounce and
/// tints a CCField's border).
final class CCFormRow: UIView {
    let control: UIView
    private let label: UILabel
    private let hint: UILabel
    private let error = ccLabel("", font: CCFont.caption, color: CCTheme.color.destructive, lines: 0)
    private let stack = UIStackView()

    init(label text: String, control: UIView, hint hintText: String? = nil) {
        self.control = control
        label = ccLabel(text, font: CCFont.labelMedium, color: CCTheme.color.foreground)
        hint = ccLabel(hintText ?? "", font: CCFont.caption, color: CCTheme.color.mutedForeground, lines: 0)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        hint.isHidden = hintText == nil
        error.isHidden = true
        stack.axis = .vertical
        stack.spacing = CCSpace.xs + 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        [label, control, hint, error].forEach(stack.addArrangedSubview)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setError(_ text: String?) {
        (control as? CCField)?.isError = text != nil
        let show = text != nil
        if let text { error.text = text }
        guard error.isHidden == show else { return }
        if show { error.alpha = 0; CCMotion.fadeAlpha(error, to: 1, duration: 0.2, delay: 0.08, from: 0) }
        CCMotion.run(duration: 0.38, curve: .bounce) {
            self.error.isHidden = !show
            self.superview?.layoutIfNeeded()
        }
    }
}
