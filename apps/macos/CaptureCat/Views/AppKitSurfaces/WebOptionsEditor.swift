import AppKit

/// Flat options popover for URL captures — the gear chip next to the device
/// chip pops this. House style (CustomLimitEditor's): EditorThemeKit panel
/// surface, small rounded rects, hand-built flat controls, no stock chrome.
/// Every change applies immediately via `onChange` (no Set button — these are
/// toggles, not a form).
final class WebOptionsEditorViewController: NSViewController {
    private let onChange: (WebCaptureOptions) -> Void
    private var options: WebCaptureOptions

    private var heightButtons: [WebHeightMode: FlatOptionButton] = [:]
    private var delayButtons: [Int: FlatOptionButton] = [:]
    private var toggleRows: [FlatToggleRow] = []

    // Retheme the popover chrome live (init-baked layer colors).
    private var themeObservation: CCThemeObservation?

    init(options: WebCaptureOptions, onChange: @escaping (WebCaptureOptions) -> Void) {
        self.options = options
        self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true

        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10
        column.translatesAutoresizingMaskIntoConstraints = false

        column.addArrangedSubview(caption("Height"))
        let heightRow = NSStackView()
        heightRow.orientation = .horizontal
        heightRow.spacing = 2
        for mode in WebHeightMode.allCases {
            let button = FlatOptionButton(title: mode.title)
            button.onClick = { [weak self] in self?.set { $0.heightMode = mode } }
            heightButtons[mode] = button
            heightRow.addArrangedSubview(button)
        }
        column.addArrangedSubview(heightRow)

        column.addArrangedSubview(caption("Page"))
        let toggles: [(String, WritableKeyPath<WebCaptureOptions, Bool>)] = [
            ("Dark Mode", \.darkMode),
            ("Hide Cookie Banners", \.hideCookieBanners),
            ("Hide Chat Widgets", \.hideChatWidgets),
            ("Reduce Motion", \.reduceMotion),
        ]
        for (title, keyPath) in toggles {
            let row = FlatToggleRow(title: title) { [weak self] in
                self?.set { $0[keyPath: keyPath].toggle() }
            }
            row.readState = { [weak self] in self?.options[keyPath: keyPath] ?? false }
            toggleRows.append(row)
            column.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            if keyPath == \WebCaptureOptions.darkMode {
                // Expectation-setter: dark mode is the SITE'S dark theme, not
                // an invented restyle — sites without one stay as designed.
                let note = NSTextField(labelWithString: "Uses the site's own dark theme when it has one.")
                note.font = .systemFont(ofSize: 10)
                note.textColor = .tertiaryLabelColor
                column.setCustomSpacing(2, after: row)
                column.addArrangedSubview(note)
            }
        }

        column.addArrangedSubview(caption("Delay Before Capture"))
        let delayRow = NSStackView()
        delayRow.orientation = .horizontal
        delayRow.spacing = 2
        for seconds in [0, 1, 2, 5] {
            let button = FlatOptionButton(title: seconds == 0 ? "None" : "\(seconds)s")
            button.onClick = { [weak self] in self?.set { $0.delaySeconds = seconds } }
            delayButtons[seconds] = button
            delayRow.addArrangedSubview(button)
        }
        column.addArrangedSubview(delayRow)

        root.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            column.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            column.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
        ])
        view = root
        // Fires once now, then again on every theme change: root surface plus
        // every flat control's state colors.
        themeObservation = CCThemeObservation { [weak self] in
            guard let self else { return }
            self.view.layer?.backgroundColor = EditorThemeKit.panel.cgColor
            self.restyle()
        }
    }

    private func caption(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 11, weight: .semibold)
        field.textColor = .secondaryLabelColor
        return field
    }

    private func set(_ mutate: (inout WebCaptureOptions) -> Void) {
        mutate(&options)
        restyle()
        onChange(options)
    }

    private func restyle() {
        for (mode, button) in heightButtons { button.isSelected = mode == options.heightMode }
        for (seconds, button) in delayButtons { button.isSelected = seconds == options.delaySeconds }
        for row in toggleRows { row.restyle() }
    }
}

// MARK: - Flat controls (CustomLimitEditor's language)

/// Small flat segment button: quiet at rest, soft white wash when selected.
private final class FlatOptionButton: NSView {
    var onClick: (() -> Void)?
    var isSelected: Bool = false {
        didSet { restyle() }
    }

    private let label: NSTextField

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
            heightAnchor.constraint(equalToConstant: 26),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 36),
        ])
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func restyle() {
        // Selection wash is ink-relative so it reads in both themes.
        let ink: NSColor = CCTheme.isDark ? .white : .black
        layer?.backgroundColor = isSelected ? ink.withAlphaComponent(0.12).cgColor : nil
        label.textColor = isSelected ? .labelColor : .secondaryLabelColor
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }
}

/// Label + trailing state dot, clickable across the whole row — the panel's
/// quiet-toggle idiom (indicator dot, no stock checkbox).
private final class FlatToggleRow: NSView {
    var readState: (() -> Bool)?
    private let onToggle: () -> Void
    private let label: NSTextField
    private let dot = NSView()

    init(title: String, onToggle: @escaping () -> Void) {
        label = NSTextField(labelWithString: title)
        self.onToggle = onToggle
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = RecordingPanelMetrics.tabRadius
        label.font = RecordingPanelMetrics.toolbarText()
        label.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        addSubview(dot)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
        ])
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func restyle() {
        let on = readState?() ?? false
        label.textColor = on ? .labelColor : .secondaryLabelColor
        dot.layer?.backgroundColor = (on ? RecordingPanelMetrics.accentOn : RecordingPanelMetrics.dotOff).cgColor
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onToggle()
    }
}
