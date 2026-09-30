import AppKit

/// CCKit radio group — shadcn's RadioGroup: recessed round wells, the
/// selected one holding a raised accent dot that SPRINGS in (bouncy scale)
/// while the outgoing dot shrinks away. Vertical or horizontal; the group
/// takes keyboard focus and ←/→/↑/↓ move the selection (wrapping), space
/// re-affirms it. Clicks select on mouseUp with an inside check.
///
///     let density = CCRadioGroup(options: ["Default", "Comfortable", "Compact"]) { index in ... }
///     let plans = CCRadioGroup(options: [
///         .init(title: "Starter", detail: "For individuals"),
///         .init(title: "Team", detail: "Up to 10 seats"),
///     ], orientation: .horizontal)
@MainActor
final class CCRadioGroup: NSView {
    struct Option {
        var title: String
        var detail: String? = nil
    }

    enum Orientation {
        case vertical
        case horizontal
    }

    var onChange: ((Int) -> Void)?

    var selectedIndex: Int? {
        didSet {
            guard selectedIndex != oldValue else { return }
            for (index, item) in items.enumerated() {
                item.setSelected(index == selectedIndex, animated: true)
            }
        }
    }

    var isEnabled = true {
        didSet { alphaValue = isEnabled ? 1 : CCTheme.current.disabledAlpha }
    }

    private let stack = NSStackView()
    private var items: [CCRadioItem] = []

    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { isEnabled }

    convenience init(
        options: [String],
        selectedIndex: Int? = 0,
        orientation: Orientation = .vertical,
        onChange: ((Int) -> Void)? = nil
    ) {
        self.init(options: options.map { Option(title: $0) }, selectedIndex: selectedIndex,
                  orientation: orientation, onChange: onChange)
    }

    init(
        options: [Option],
        selectedIndex: Int? = 0,
        orientation: Orientation = .vertical,
        onChange: ((Int) -> Void)? = nil
    ) {
        self.selectedIndex = selectedIndex
        self.onChange = onChange
        super.init(frame: .zero)
        stack.orientation = orientation == .vertical ? .vertical : .horizontal
        stack.alignment = orientation == .vertical ? .leading : .top
        stack.spacing = orientation == .vertical ? CCSpace.sm + 2 : CCSpace.lg
        // Items keep their fitting size and pack to the leading edge; spare
        // width goes to the gravity area, never into one stretched item.
        stack.distribution = .gravityAreas
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for (index, option) in options.enumerated() {
            let item = CCRadioItem(option: option, selected: index == selectedIndex)
            item.onPick = { [weak self] in self?.pick(index) }
            stack.addArrangedSubview(item)
            items.append(item)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func pick(_ index: Int) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        guard index != selectedIndex else { return }
        selectedIndex = index
        onChange?(index)
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled, !items.isEmpty else { return super.keyDown(with: event) }
        let delta: Int
        switch event.keyCode {
        case 124, 125: delta = 1   // → ↓
        case 123, 126: delta = -1  // ← ↑
        case 49:                    // space: select the focused/first item
            pick(selectedIndex ?? 0)
            return
        default:
            return super.keyDown(with: event)
        }
        let next = ((selectedIndex ?? (delta > 0 ? -1 : 0)) + delta + items.count) % items.count
        pick(next)
    }

    // MARK: - Harness seams

    func probeDotLayer(_ index: Int) -> CALayer { items[index].probeDot }
    func probeWellLayer(_ index: Int) -> CALayer? { items[index].probeWell }
}

// MARK: - Item

@MainActor
private final class CCRadioItem: NSView {
    static let side: CGFloat = 18
    static let dotSide: CGFloat = 8

    var onPick: (() -> Void)?

    private let well = NSView()
    /// Leaf host for the dot: animated sublayers never ride a view with
    /// subviews (AppKit rebuilds those sublayer arrays on relayout).
    private let dotHost = NSView()
    private let dot = CALayer()
    private let titleField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")
    private var isSelected: Bool
    private var themeObservation: CCThemeObservation?

    init(option: CCRadioGroup.Option, selected: Bool) {
        isSelected = selected
        super.init(frame: .zero)
        well.wantsLayer = true
        well.layer?.cornerCurve = .continuous
        well.layer?.borderWidth = 1
        dotHost.wantsLayer = true
        dot.bounds = CGRect(x: 0, y: 0, width: Self.dotSide, height: Self.dotSide)
        dot.cornerRadius = Self.dotSide / 2
        dot.setValue(selected ? 1 : 0, forKeyPath: "transform.scale")
        dot.opacity = selected ? 1 : 0
        dotHost.layer?.addSublayer(dot)

        titleField.stringValue = option.title
        titleField.lineBreakMode = .byTruncatingTail
        detailField.stringValue = option.detail ?? ""
        detailField.isHidden = option.detail == nil

        for view in [well, dotHost, titleField, detailField] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        var constraints: [NSLayoutConstraint] = [
            well.leadingAnchor.constraint(equalTo: leadingAnchor),
            well.widthAnchor.constraint(equalToConstant: Self.side),
            well.heightAnchor.constraint(equalToConstant: Self.side),
            well.centerYAnchor.constraint(equalTo: titleField.centerYAnchor),
            dotHost.centerXAnchor.constraint(equalTo: well.centerXAnchor),
            dotHost.centerYAnchor.constraint(equalTo: well.centerYAnchor),
            dotHost.widthAnchor.constraint(equalToConstant: Self.side),
            dotHost.heightAnchor.constraint(equalToConstant: Self.side),
            titleField.leadingAnchor.constraint(equalTo: well.trailingAnchor, constant: CCSpace.sm),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            titleField.topAnchor.constraint(equalTo: topAnchor, constant: 1),
        ]
        if option.detail != nil {
            constraints += [
                detailField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
                detailField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
                detailField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 1),
                detailField.bottomAnchor.constraint(equalTo: bottomAnchor),
            ]
        } else {
            constraints.append(titleField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1))
        }
        // Hug the text: without a (weak) equality the item's width is
        // ambiguous and a horizontal group stretches its first item.
        let hug = titleField.trailingAnchor.constraint(equalTo: trailingAnchor)
        hug.priority = .init(300)   // above NSStackView's orthogonal fill pull
        constraints.append(hug)
        NSLayoutConstraint.activate(constraints)
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        well.layer?.cornerRadius = CCRadius.full.resolved(for: Self.side)
        if let layer = well.layer { CCMaterial.refit(layer, radius: CCRadius.full.resolved(for: Self.side)) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.position = CGPoint(x: dotHost.bounds.midX, y: dotHost.bounds.midY)
        CATransaction.commit()
    }

    private func applyTheme() {
        let colors = CCTheme.color
        titleField.font = CCTheme.font.chip
        titleField.textColor = colors.foreground
        detailField.font = CCTheme.font.caption
        detailField.textColor = colors.mutedForeground
        if let layer = well.layer {
            // Skeuo: an empty well; selection drops a raised accent bead in.
            layer.backgroundColor = colors.elevated.cgColor
            // Neutral border in every state — selection is the bead alone
            // (no selection rings in the house language).
            layer.borderColor = colors.border.cgColor
            CCMaterial.dress(layer, as: .recessed(tint: colors.elevated),
                             radius: CCRadius.full.resolved(for: Self.side))
        }
        dot.backgroundColor = colors.primary.cgColor
        CCMaterial.dress(dot, as: .raised(tint: colors.primary), radius: Self.dotSide / 2)
    }

    func setSelected(_ selected: Bool, animated: Bool) {
        guard selected != isSelected else { return }
        isSelected = selected
        guard animated, window != nil else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            dot.setValue(selected ? 1 : 0, forKeyPath: "transform.scale")
            dot.opacity = selected ? 1 : 0
            CATransaction.commit()
            return
        }
        if selected {
            // The bead springs in from nothing with a visible overshoot.
            CCMotion.spring(dot, keyPath: "transform.scale", from: 0.2, to: 1.0, .bouncy)
            CCMotion.fade(dot, keyPath: "opacity", to: 1, duration: 0.1)
        } else {
            // The outgoing bead shrinks away quickly — no bounce on exit.
            CCMotion.spring(dot, keyPath: "transform.scale", to: 0.0, .snappy)
            CCMotion.fade(dot, keyPath: "opacity", to: 0, duration: 0.18)
        }
    }

    // Press tints the well in place; the pick fires on mouseUp inside.
    override func mouseDown(with event: NSEvent) {
        if let layer = well.layer { CCMaterial.press(layer, down: true) }
    }

    override func mouseUp(with event: NSEvent) {
        if let layer = well.layer { CCMaterial.press(layer, down: false) }
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPick?() }
    }

    var probeDot: CALayer { dot }
    var probeWell: CALayer? { well.layer }
}
