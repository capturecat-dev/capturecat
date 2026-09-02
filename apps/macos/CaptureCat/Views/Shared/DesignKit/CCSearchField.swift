import AppKit

/// CCKit search field — the kit's one search input: loupe glyph + borderless
/// text field sharing a single inset and midline on an elevated well, with
/// the kit focus ring. `radius` picks the shape (`.full` pill by default,
/// any scale value for a softer rect). Command routing matches the combobox
/// popup (`moveUp/moveDown/commit/cancel`) so suggestion UIs drive the same
/// contract whether they hang off a search field or a combobox.
///
///     let search = CCSearchField(placeholder: "Search captures… (⌘K)")
///     search.radius = .lg
///     search.onQueryChange = { query in ... }
///     search.onCommand = { command in ... }   // true = swallowed
///
/// Built from a plain borderless NSTextField beside the loupe rather than
/// NSSearchField — NSSearchField's cell mis-centers in custom-height frames
/// (proven in the browser, which this component replaces the one-off for).
@MainActor
final class CCSearchField: NSView, NSTextFieldDelegate {
    enum Command {
        case moveUp
        case moveDown
        case commit
        case cancel
    }

    var onQueryChange: ((String) -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    /// Return true to swallow the key; false lets the field editor keep it.
    var onCommand: ((Command) -> Bool)?

    /// Corner scale; `.full` = capsule.
    var radius: CCRadius {
        didSet { needsLayout = true }
    }

    var placeholder: String {
        didSet { applyTheme() }
    }

    let textField = NSTextField()
    private let loupe = NSImageView()
    private let controlHeight: CGFloat
    private var themeObservation: CCThemeObservation?

    private(set) var isFocused = false {
        didSet {
            guard isFocused != oldValue else { return }
            refreshBorder(animated: true)
            onFocusChange?(isFocused)
        }
    }

    var query: String { textField.stringValue }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: controlHeight)
    }

    init(placeholder: String = "Search…", height: CGFloat = 36, radius: CCRadius = .full) {
        self.placeholder = placeholder
        self.controlHeight = height
        self.radius = radius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        loupe.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search")
        loupe.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        loupe.translatesAutoresizingMaskIntoConstraints = false
        addSubview(loupe)

        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.delegate = self
        textField.lineBreakMode = .byTruncatingTail
        textField.usesSingleLineMode = true
        textField.cell?.sendsActionOnEndEditing = false
        textField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textField)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: height),
            loupe.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            loupe.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Single-line field centered on the well's axis: glyph,
            // placeholder and typed text share the inset and midline.
            textField.leadingAnchor.constraint(equalTo: loupe.trailingAnchor, constant: CCSpace.sm),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        layer?.cornerRadius = radius.resolved(for: bounds.height)
        if let layer { CCMaterial.refit(layer, radius: radius.resolved(for: bounds.height)) }
    }

    private func applyTheme() {
        let colors = CCTheme.color
        layer?.backgroundColor = colors.elevated.cgColor
        // Skeuo: the search well is recessed like every input.
        if let layer {
            CCMaterial.dress(layer, as: .recessed(tint: colors.elevated),
                             radius: radius.resolved(for: bounds.height))
        }
        loupe.contentTintColor = colors.mutedForeground
        textField.font = CCTheme.font.chip
        textField.textColor = colors.foreground
        textField.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .font: CCTheme.font.chip,
                .foregroundColor: colors.mutedForeground,
            ]
        )
        refreshBorder()
    }

    private func refreshBorder(animated: Bool = false) {
        guard let layer else { return }
        let border = isFocused ? CCTheme.current.ringColor : CCTheme.color.border
        layer.borderWidth = isFocused ? max(CCTheme.current.ring.focusWidth, 1) : 1
        if animated {
            CCMotion.fade(layer, keyPath: "borderColor", to: border.cgColor)
        } else {
            layer.borderColor = border.cgColor
        }
    }

    func setQuery(_ query: String) {
        textField.stringValue = query
    }

    /// Focus + report. `controlTextDidBeginEditing` only fires on the first
    /// text CHANGE, so click-focus and shortcut-focus (⌘K) must set the
    /// state themselves — otherwise pre-typing UI (recents) never shows.
    func beginFocus() {
        window?.makeFirstResponder(textField)
        isFocused = true
    }

    /// Clicking anywhere on the well focuses the field.
    override func mouseDown(with event: NSEvent) {
        beginFocus()
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidBeginEditing(_ obj: Notification) { isFocused = true }
    func controlTextDidEndEditing(_ obj: Notification) { isFocused = false }
    func controlTextDidChange(_ obj: Notification) {
        if !isFocused { isFocused = true } // typing directly without a click
        onQueryChange?(textField.stringValue)
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        let command: Command
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)): command = .moveUp
        case #selector(NSResponder.moveDown(_:)): command = .moveDown
        case #selector(NSResponder.insertNewline(_:)): command = .commit
        case #selector(NSResponder.cancelOperation(_:)): command = .cancel
        default: return false
        }
        return onCommand?(command) ?? false
    }
}
