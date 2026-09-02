import AppKit

/// CCKit checkbox — shadcn's Checkbox: an 18pt rounded-sm box that fills
/// with `primary` and draws its checkmark as an animated stroke (the tick
/// literally gets drawn, Things-style), with the house press scale. An
/// optional title sits to the right; clicking either toggles.
///
///     let terms = CCCheckbox(title: "Also export captions") { on in ... }
@MainActor
final class CCCheckbox: NSControl {
    var onChange: ((Bool) -> Void)?

    var isOn: Bool {
        didSet {
            guard isOn != oldValue else { return }
            applyTheme(animated: true)
        }
    }

    var title: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            label.isHidden = newValue.isEmpty
            invalidateIntrinsicContentSize()
        }
    }

    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1 : CCTheme.current.disabledAlpha }
    }

    private static let boxSide: CGFloat = 18

    private let box = NSView()
    private let check = CAShapeLayer()
    private let label = NSTextField(labelWithString: "")
    private var themeObservation: CCThemeObservation?

    override var intrinsicContentSize: NSSize {
        let labelWidth = label.isHidden ? 0 : ceil(label.intrinsicContentSize.width) + CCSpace.sm
        return NSSize(width: Self.boxSide + labelWidth, height: max(Self.boxSide, 20))
    }

    init(title: String = "", isOn: Bool = false, onChange: ((Bool) -> Void)? = nil) {
        self.isOn = isOn
        self.onChange = onChange
        super.init(frame: .zero)

        box.wantsLayer = true
        box.layer?.cornerCurve = .continuous
        box.layer?.borderWidth = 1

        // Tick path in box-local coordinates (Y-up), drawn as a stroke so
        // strokeEnd can animate it in.
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 4.5, y: 9.5))
        path.addLine(to: CGPoint(x: 7.8, y: 5.8))
        path.addLine(to: CGPoint(x: 13.5, y: 12.5))
        check.path = path
        check.fillColor = nil
        check.lineWidth = 2
        check.lineCap = .round
        check.lineJoin = .round
        check.frame = CGRect(x: 0, y: 0, width: Self.boxSide, height: Self.boxSide)
        check.strokeEnd = isOn ? 1 : 0
        box.layer?.addSublayer(check)

        label.stringValue = title
        label.isHidden = title.isEmpty
        label.lineBreakMode = .byTruncatingTail

        for view in [box, label] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: leadingAnchor),
            box.centerYAnchor.constraint(equalTo: centerYAnchor),
            box.widthAnchor.constraint(equalToConstant: Self.boxSide),
            box.heightAnchor.constraint(equalToConstant: Self.boxSide),
            label.leadingAnchor.constraint(equalTo: box.trailingAnchor, constant: CCSpace.sm),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        box.layer?.cornerRadius = CCTheme.radius(.sm)
        if let boxLayer = box.layer { CCMaterial.refit(boxLayer, radius: CCTheme.radius(.sm)) }
    }

    private func applyTheme(animated: Bool = false) {
        guard let layer = box.layer else { return }
        let colors = CCTheme.color
        label.font = CCTheme.font.chip
        label.textColor = colors.foreground
        check.strokeColor = colors.primaryForeground.cgColor

        let fill = isOn ? colors.primary : colors.elevated
        let border = isOn ? NSColor.clear : colors.border
        if animated {
            CCMotion.fade(layer, keyPath: "backgroundColor", to: fill.cgColor)
            CCMotion.fade(layer, keyPath: "borderColor", to: border.cgColor)
            if isOn {
                // Draw the tick with a spring; the tiny box pop sells it.
                CCMotion.spring(check, keyPath: "strokeEnd", to: 1.0, .smooth)
                CCMotion.spring(layer, keyPath: "transform.scale", to: 1.0, .bouncy)
            } else {
                CCMotion.fade(check, keyPath: "strokeEnd", to: 0.0, duration: 0.12)
            }
        } else {
            layer.backgroundColor = fill.cgColor
            layer.borderColor = border.cgColor
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            check.strokeEnd = isOn ? 1 : 0
            CATransaction.commit()
        }
        // Skeuo: unchecked is an empty well; checking pops it out as a
        // glossy accent chip.
        CCMaterial.dress(layer, as: isOn ? .raised(tint: fill) : .recessed(tint: fill),
                         radius: CCTheme.radius(.sm))
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        CCMotion.pressScale(box, down: true, scale: 0.88)
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        CCMotion.pressScale(box, down: false, scale: 0.88)
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        isOn.toggle()
        onChange?(isOn)
    }

    // MARK: - Harness seams

    var probeCheckLayer: CAShapeLayer { check }
}
