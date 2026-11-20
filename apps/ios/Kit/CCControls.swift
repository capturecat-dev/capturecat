import UIKit

// CCKit form controls — UIKit ports of the Mac's CCToggle (+ CCToggleRow),
// CCCheckbox, CCSearchField, CCPreviewPad and CCFormRow. Same anatomy and
// tokens as the Mac kit, at touch scale (~1.25×). The slider lives in
// CCSlider.swift, the stepper in CCStepper.swift.

/// Switch: a recessed pill track (accent when on) with a white floating
/// thumb that springs across on the bouncy spring. Mac 36×21 → 48×28.
///
/// Press STRETCHES the thumb toward the side it will travel to — only that
/// (pushed) edge moves; the resting edge stays put — then on release it
/// springs across and settles round. A 44 pt touch target around the track.
///
///     let toggle = CCToggle(isOn: true) { on in … }
///     toggle.setOn(false, animated: true)     // model push, no onChange echo
final class CCToggle: UIControl {
    // Keyboard (iPad, Studio 6a): Tab / arrows focus it; Space or Return
    // activates it — the same action a tap sends.
    override var canBecomeFocused: Bool { isEnabled && !isHidden && isUserInteractionEnabled && isAccessibilityElement }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if ccIsActivation(presses), isEnabled { sendActions(for: .touchUpInside); return }
        super.pressesEnded(presses, with: event)
    }

    var onChange: ((Bool) -> Void)?
    private(set) var isOn: Bool

    static let trackSize = CGSize(width: 48, height: 28)
    private static let inset: CGFloat = 2.5
    /// How far the pressed thumb stretches toward its destination.
    private static let stretch: CGFloat = 7
    private let thumb = CALayer()
    private var stretched = false
    /// Differentiate Without Color: "I" on the track when on, "O" when off
    /// (the switch reads by shape, not only by the accent fill).
    private let onGlyph = CALayer()
    private let offGlyph = CALayer()

    init(isOn: Bool = false, onChange: ((Bool) -> Void)? = nil) {
        self.isOn = isOn
        self.onChange = onChange
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerCurve = .continuous
        // A plain layer (no material sublayer): the thumb's bounds SPRING
        // during the stretch, and a child base layer would park at its final
        // size mid-flight. White + hairline + soft shadow = the raised face.
        let side = Self.trackSize.height - Self.inset * 2
        thumb.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        thumb.cornerRadius = side / 2
        thumb.cornerCurve = .continuous
        thumb.borderWidth = 0.5
        thumb.shadowColor = UIColor.black.cgColor
        thumb.shadowOpacity = 0.3
        thumb.shadowRadius = 2
        thumb.shadowOffset = CGSize(width: 0, height: 0.5)
        onGlyph.bounds = CGRect(x: 0, y: 0, width: 1.5, height: 10)
        onGlyph.cornerRadius = 0.75
        offGlyph.bounds = CGRect(x: 0, y: 0, width: 8, height: 8)
        offGlyph.cornerRadius = 4
        offGlyph.borderWidth = 1.5
        offGlyph.backgroundColor = UIColor.clear.cgColor
        layer.addSublayer(onGlyph)
        layer.addSublayer(offGlyph)
        layer.addSublayer(thumb)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.trackSize.width),
            heightAnchor.constraint(equalToConstant: Self.trackSize.height),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .toggleButton
        addAction(UIAction { [weak self] _ in self?.userToggle() }, for: .touchUpInside)
        ccOnThemeChange { [weak self] in self?.applyTheme() }
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: CGSize { Self.trackSize }

    override var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            CCMotion.fadeAlpha(self, to: isEnabled ? 1 : CCTheme.disabledAlpha, duration: 0.16)
            accessibilityTraits = isEnabled ? .toggleButton : [.toggleButton, .notEnabled]
        }
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            setStretched(isHighlighted && isEnabled)
        }
    }

    /// 44 pt touch target around the 48×28 track.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let dx = max(0, (44 - bounds.width) / 2), dy = max(0, (44 - bounds.height) / 2)
        return bounds.insetBy(dx: -dx, dy: -dy).contains(point)
    }

    /// The user flipped it (tap, or a CCToggleRow tap): animate, haptic, notify.
    func userToggle() {
        guard isEnabled else { return }
        stretched = false
        isOn.toggle()
        applyTheme(animated: true)
        moveThumb(animated: true)
        CCHaptics.selection()
        onChange?(isOn)
        sendActions(for: .valueChanged)
    }

    func setOn(_ on: Bool, animated: Bool) {
        guard on != isOn else { return }
        isOn = on
        stretched = false
        applyTheme(animated: animated)
        moveThumb(animated: animated)
    }

    /// Press feedback, driven by `isHighlighted` (and CCToggleRow's press).
    func setStretched(_ on: Bool) {
        guard on != stretched else { return }
        stretched = on
        moveThumb(animated: true, spring: .snappy)
    }

    private func thumbFrame(on: Bool, stretched: Bool) -> CGRect {
        let side = Self.trackSize.height - Self.inset * 2
        let width = stretched ? side + Self.stretch : side
        let x = on ? bounds.width - Self.inset - width : Self.inset
        return CGRect(x: x, y: (bounds.height - side) / 2, width: width, height: side)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let r = CCRadius.full.resolved(for: bounds.height)
        layer.cornerRadius = r
        CCMaterial.refit(layer, radius: r)
        if thumb.animation(forKey: "ccmotion.position") == nil { moveThumb(animated: false) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        onGlyph.position = CGPoint(x: Self.trackSize.width * 0.3, y: bounds.midY)
        offGlyph.position = CGPoint(x: Self.trackSize.width * 0.7, y: bounds.midY)
        CATransaction.commit()
    }

    private func moveThumb(animated: Bool, spring: CCMotion.Spring = .bouncy) {
        let frame = thumbFrame(on: isOn, stretched: stretched)
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let bounds = CGRect(origin: .zero, size: frame.size)
        if animated, window != nil {
            // Same spring on both key paths, so the resting edge holds still
            // while only the pushed edge travels.
            CCMotion.spring(thumb, keyPath: "position", to: NSValue(cgPoint: center), spring)
            CCMotion.spring(thumb, keyPath: "bounds", to: NSValue(cgRect: bounds), spring)
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            thumb.position = center
            thumb.bounds = bounds
            CATransaction.commit()
        }
    }

    private func applyTheme(animated: Bool = false) {
        let colors = CCTheme.color
        let track = isOn ? colors.primary : colors.active
        CCMaterial.dress(layer, as: .recessed(tint: track), radius: Self.trackSize.height / 2, traits: traitCollection)
        if animated, window != nil, let base = layer.sublayers?.first(where: { $0.name == "ccmat.base" }) {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = CCMotion.paced(0.2)
            base.add(fade, forKey: "cctoggle.track")
        }
        layer.borderWidth = 1
        layer.borderColor = cc(isOn ? .clear : colors.border)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        thumb.backgroundColor = UIColor.white.cgColor
        thumb.borderColor = CCMaterial.hairline(dark: CCTheme.isDark(traitCollection), onWell: false).cgColor
        let glyphs = CCAccessibility.differentiateWithoutColor
        onGlyph.backgroundColor = UIColor.white.cgColor
        offGlyph.borderColor = cc(colors.mutedForeground)
        onGlyph.opacity = glyphs && isOn ? 1 : 0
        offGlyph.opacity = glyphs && !isOn ? 1 : 0
        CATransaction.commit()
        accessibilityValue = isOn ? String(localized: "On", comment: "Switch state (VoiceOver)") : String(localized: "Off", comment: "Switch state (VoiceOver)")
    }

    /// Probe seam: the Differentiate Without Color glyph for this state shows.
    var probeShowsGlyph: Bool { (isOn ? onGlyph : offGlyph).opacity > 0.5 }

    var probeThumbLayer: CALayer { thumb }
    /// The thumb's resting frame for a state (probe expectations).
    func probeThumbFrame(on: Bool, stretched: Bool) -> CGRect { thumbFrame(on: on, stretched: stretched) }
}

/// The inspector's toggle row (the Mac's InspectorToggleControl): label
/// left (+ an optional muted detail line), CCToggle right. The WHOLE row is
/// the touch target and ONE VoiceOver element (label, On/Off, toggle trait);
/// pressing the row stretches the toggle's thumb like pressing the toggle.
final class CCToggleRow: UIControl {
    // Keyboard (iPad, Studio 6a): Tab / arrows focus it; Space or Return
    // activates it — the same action a tap sends.
    override var canBecomeFocused: Bool { isEnabled && !isHidden && isUserInteractionEnabled }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if ccIsActivation(presses), isEnabled { sendActions(for: .touchUpInside); return }
        super.pressesEnded(presses, with: event)
    }

    let toggle: CCToggle
    var onChange: ((Bool) -> Void)?
    private let titleLabel: UILabel
    private let detailLabel: UILabel

    var isOn: Bool { toggle.isOn }
    #if DEBUG
    /// Harness seam: the row's title as drawn.
    var probeTitle: String { titleLabel.text ?? "" }
    #endif

    init(title: String, detail: String? = nil, isOn: Bool = false, onChange: ((Bool) -> Void)? = nil) {
        toggle = CCToggle(isOn: isOn)
        self.onChange = onChange
        titleLabel = ccLabel(title, font: CCFont.body, color: CCTheme.color.foreground, lines: 0)
        detailLabel = ccLabel(detail ?? "", font: CCFont.caption, color: CCTheme.color.mutedForeground, lines: 0)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        detailLabel.isHidden = detail == nil
        let text = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        text.axis = .vertical
        text.spacing = 2
        text.isUserInteractionEnabled = false
        text.translatesAutoresizingMaskIntoConstraints = false
        toggle.isUserInteractionEnabled = false
        toggle.isAccessibilityElement = false
        addSubview(text)
        addSubview(toggle)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor),
            text.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: CCSpace.sm),
            text.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -CCSpace.sm),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggle.leadingAnchor.constraint(greaterThanOrEqualTo: text.trailingAnchor, constant: CCSpace.md),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityHint = detail
        accessibilityTraits = .toggleButton
        accessibilityValue = isOn ? String(localized: "On", comment: "Switch state (VoiceOver)") : String(localized: "Off", comment: "Switch state (VoiceOver)")
        toggle.onChange = { [weak self] on in
            guard let self else { return }
            self.accessibilityValue = on ? String(localized: "On", comment: "Switch state (VoiceOver)") : String(localized: "Off", comment: "Switch state (VoiceOver)")
            self.onChange?(on)
            self.sendActions(for: .valueChanged)
        }
        addAction(UIAction { [weak self] _ in self?.toggle.userToggle() }, for: .touchUpInside)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setOn(_ on: Bool, animated: Bool) {
        toggle.setOn(on, animated: animated)
        accessibilityValue = on ? String(localized: "On", comment: "Switch state (VoiceOver)") : String(localized: "Off", comment: "Switch state (VoiceOver)")
    }

    /// Change (or clear) the muted detail line.
    func setDetail(_ text: String?) {
        guard detailLabel.text != (text ?? "") || detailLabel.isHidden != (text == nil) else { return }
        detailLabel.text = text ?? ""
        detailLabel.isHidden = text == nil
    }

    var detailText: String? { detailLabel.isHidden ? nil : detailLabel.text }

    override var isHighlighted: Bool {
        didSet { toggle.setStretched(isHighlighted && isEnabled) }
    }

    override var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            toggle.isEnabled = isEnabled
            CCMotion.fadeAlpha(titleLabel, to: isEnabled ? 1 : CCTheme.disabledAlpha, duration: 0.16)
            CCMotion.fadeAlpha(detailLabel, to: isEnabled ? 1 : CCTheme.disabledAlpha, duration: 0.16)
            accessibilityTraits = isEnabled ? .toggleButton : [.toggleButton, .notEnabled]
        }
    }
}

/// Label left (+ optional muted detail), any control right — the inspector
/// row (the Mac's `InspectorKitViews.row`). For steppers, color wells,
/// selects. At least 44 pt tall.
final class CCControlRow: UIView {
    let control: UIView
    private let titleLabel: UILabel
    private let detailLabel: UILabel

    init(title: String, detail: String? = nil, control: UIView) {
        self.control = control
        titleLabel = ccLabel(title, font: CCFont.body, color: CCTheme.color.foreground, lines: 0)
        detailLabel = ccLabel(detail ?? "", font: CCFont.caption, color: CCTheme.color.mutedForeground, lines: 0)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        detailLabel.isHidden = detail == nil
        let text = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        text.axis = .vertical
        text.spacing = 2
        text.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(text)
        addSubview(control)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor),
            text.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: CCSpace.xs),
            text.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -CCSpace.xs),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            control.leadingAnchor.constraint(greaterThanOrEqualTo: text.trailingAnchor, constant: CCSpace.md),
            control.trailingAnchor.constraint(equalTo: trailingAnchor),
            control.centerYAnchor.constraint(equalTo: centerYAnchor),
            control.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            control.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        // The control speaks for the row: VoiceOver reads the row's title as
        // the control's label unless the control has its own.
        if control.accessibilityLabel?.isEmpty ?? true { control.accessibilityLabel = title }
        titleLabel.isAccessibilityElement = control.accessibilityLabel != title
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// Checkbox: a recessed box (accent + floating when checked) whose check
/// draws in with a spring. Mac 18 → 22 pt.
final class CCCheckbox: UIControl {
    // Keyboard (iPad, Studio 6a): Tab / arrows focus it; Space or Return
    // activates it — the same action a tap sends.
    override var canBecomeFocused: Bool { isEnabled && !isHidden && isUserInteractionEnabled }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if ccIsActivation(presses), isEnabled { sendActions(for: .touchUpInside); return }
        super.pressesEnded(presses, with: event)
    }

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
        accessibilityValue = isOn ? String(localized: "Checked", comment: "Checkbox state (VoiceOver)") : String(localized: "Not checked", comment: "Checkbox state (VoiceOver)")
    }

    override var isHighlighted: Bool {
        didSet { CCMaterial.press(box.layer, down: isHighlighted, traits: traitCollection) }
    }
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
        clear.accessibilityLabelOverride = String(localized: "Clear search")
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
