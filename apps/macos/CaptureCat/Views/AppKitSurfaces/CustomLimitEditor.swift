import AppKit

/// Popover content for the recording bar's "Custom…" duration limit: a value
/// field plus a seconds/minutes selector, in the house flat style — solid
/// EditorThemeKit surfaces, small rounded rects, hand-built controls. No stock
/// AppKit chrome, no capsules (CLAUDE.md §1 / panel design rules).
@MainActor
final class CustomLimitEditorViewController: NSViewController, NSTextFieldDelegate {
    /// Fired once: parsed limit in seconds, or nil when dismissed unapplied.
    private let onCommit: (TimeInterval?) -> Void
    private let initialSeconds: TimeInterval

    private let field = NSTextField(string: "")
    private var unitButtons: [FlatUnitButton] = []
    private var unitIsMinutes = true
    private let fieldWell = NSView()

    // Retheme the popover chrome live (init-baked layer colors).
    private var themeObservation: CCThemeObservation?

    init(initialSeconds: TimeInterval, onCommit: @escaping (TimeInterval?) -> Void) {
        self.initialSeconds = initialSeconds
        self.onCommit = onCommit
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true

        let title = NSTextField(labelWithString: "Max Duration")
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor

        // Value field on a small elevated rounded rect — flat, no bezel.
        fieldWell.wantsLayer = true
        fieldWell.layer?.cornerRadius = RecordingPanelMetrics.tabRadius
        fieldWell.layer?.borderWidth = 1

        if initialSeconds > 0 {
            if initialSeconds >= 60, initialSeconds.truncatingRemainder(dividingBy: 60) == 0 {
                unitIsMinutes = true
                field.stringValue = String(Int(initialSeconds) / 60)
            } else {
                unitIsMinutes = false
                field.stringValue = String(Int(initialSeconds))
            }
        } else {
            unitIsMinutes = true
            field.stringValue = "2"
        }
        field.font = RecordingPanelMetrics.timer()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alignment = .center
        field.delegate = self

        fieldWell.translatesAutoresizingMaskIntoConstraints = false
        field.translatesAutoresizingMaskIntoConstraints = false
        fieldWell.addSubview(field)
        NSLayoutConstraint.activate([
            fieldWell.widthAnchor.constraint(equalToConstant: 64),
            fieldWell.heightAnchor.constraint(equalToConstant: 28),
            field.leadingAnchor.constraint(equalTo: fieldWell.leadingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: fieldWell.trailingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: fieldWell.centerYAnchor),
        ])

        // s / min selector: two flat toggles that read as one control.
        let unitStack = NSStackView()
        unitStack.orientation = .horizontal
        unitStack.spacing = 2
        for (label, minutes) in [("s", false), ("min", true)] {
            let button = FlatUnitButton(title: label)
            button.onClick = { [weak self] in self?.select(minutes: minutes) }
            unitButtons.append(button)
            unitStack.addArrangedSubview(button)
        }

        let apply = FlatUnitButton(title: "Set")
        apply.isAccent = true
        apply.onClick = { [weak self] in self?.commit() }

        let row = NSStackView(views: [fieldWell, unitStack, apply])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY

        let column = NSStackView(views: [title, row])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            column.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            column.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])

        view = root
        restyleUnits()
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    private func applyTheme() {
        view.layer?.backgroundColor = EditorThemeKit.panel.cgColor
        fieldWell.layer?.backgroundColor = EditorThemeKit.panelElevated.cgColor
        fieldWell.layer?.borderColor = RecordingPanelMetrics.barStroke.cgColor
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(field)
    }

    private func select(minutes: Bool) {
        unitIsMinutes = minutes
        restyleUnits()
    }

    private func restyleUnits() {
        for (index, button) in unitButtons.enumerated() {
            button.isSelected = (index == 1) == unitIsMinutes
        }
    }

    private func commit() {
        let raw = field.stringValue.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(raw), value > 0 else {
            onCommit(nil)
            return
        }
        let seconds = unitIsMinutes ? value * 60 : value
        // Clamp to something sane: 1s up to 8 hours.
        onCommit(min(max(seconds.rounded(), 1), 8 * 3600))
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            commit()
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            onCommit(nil)
            return true
        }
        return false
    }
}

/// Tiny flat toggle/action button: a label on a small rounded rect wash.
/// Deliberately not a stock NSButton — the bar's design language is flat
/// custom targets (see RecordingPanelKit).
private final class FlatUnitButton: NSView {
    var onClick: (() -> Void)?

    var isSelected: Bool = false {
        didSet { restyle() }
    }

    /// Accent fill for the primary action ("Set").
    var isAccent: Bool = false {
        didSet { restyle() }
    }

    private let label: NSTextField
    private var themeObservation: CCThemeObservation?

    init(title: String) {
        label = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = RecordingPanelMetrics.tabRadius
        label.font = RecordingPanelMetrics.toolbarText()
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 28),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 36),
        ])
        themeObservation = CCThemeObservation { [weak self] in self?.restyle() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func restyle() {
        guard let layer else { return }
        if isAccent {
            let fill = NSColor.systemBlue.withAlphaComponent(0.85)
            layer.backgroundColor = fill.cgColor
            label.textColor = .white
            CCMaterial.dress(layer, as: .raised(tint: fill), radius: RecordingPanelMetrics.tabRadius)
            CCMaterial.suppressShadow(layer)   // tight popover row — no smear
        } else if isSelected {
            // Selection wash is ink-relative so it reads in both themes —
            // and stays FLAT: raised material over a translucent wash
            // renders as smudges, not depth.
            let ink: NSColor = CCTheme.isDark ? .white : .black
            let fill = ink.withAlphaComponent(0.12)
            layer.backgroundColor = fill.cgColor
            label.textColor = .labelColor
            CCMaterial.strip(layer)
        } else {
            layer.backgroundColor = nil
            label.textColor = .secondaryLabelColor
            CCMaterial.strip(layer)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.01 else { return nil }
        guard let local = superview?.convert(point, to: self) else { return nil }
        return bounds.contains(local) ? self : nil
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if let layer { CCMaterial.press(layer, down: true) }
    }

    override func mouseUp(with event: NSEvent) {
        if let layer { CCMaterial.press(layer, down: false) }
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }
}
