import AppKit

/// CCKit text field — shadcn's Input: a flat elevated well with the kit
/// focus ring, no Aqua bezel. Colors re-apply live on theme change.
///
///     let name = CCField(placeholder: "Project name")
///     name.onCommit = { text in ... }
@MainActor
final class CCField: NSTextField {
    var onCommit: ((String) -> Void)?
    var onTextChange: ((String) -> Void)?

    /// Corner scale for the well; `.full` = capsule.
    var radius: CCRadius = .md {
        didSet { needsLayout = true }
    }

    /// Error state (set by CCFormRow, or directly): destructive border that
    /// cross-fades in on the glide curve. Focus ring wins while editing.
    var isError: Bool = false {
        didSet {
            guard isError != oldValue else { return }
            applyTheme(focused: isFocused, animated: true)
        }
    }

    private var isFocused = false
    private var themeObservation: CCThemeObservation?

    override var intrinsicContentSize: NSSize {
        NSSize(width: super.intrinsicContentSize.width, height: 30)
    }

    init(placeholder: String = "", value: String = "") {
        super.init(frame: .zero)
        // Padded cell BEFORE any content: the inset is real text-machinery
        // geometry (drawing + editing + caret), not an alignment-rect trick —
        // negative alignmentRectInsets clipped the text against the well edge.
        let padded = CCFieldCell(textCell: "")
        padded.isEditable = true
        padded.isScrollable = true
        padded.usesSingleLineMode = true
        padded.lineBreakMode = .byTruncatingTail
        cell = padded
        isSelectable = true
        stringValue = value
        placeholderString = placeholder
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        font = CCTheme.font.chip
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        layer?.cornerRadius = radius.resolved(for: bounds.height)
        if let layer { CCMaterial.refit(layer, radius: radius.resolved(for: bounds.height)) }
    }

    private func applyTheme(focused: Bool = false, animated: Bool = false) {
        let colors = CCTheme.color
        let border: NSColor = focused
            ? CCTheme.current.ringColor
            : (isError ? colors.destructive : colors.border)
        layer?.backgroundColor = colors.elevated.cgColor
        layer?.borderWidth = focused ? max(CCTheme.current.ring.focusWidth, 1) : 1
        // Skeuo: input wells are recessed.
        if let layer {
            CCMaterial.dress(layer, as: .recessed(tint: colors.elevated),
                             radius: radius.resolved(for: bounds.height))
        }
        if animated, let layer {
            CCMotion.fade(layer, keyPath: "borderColor", to: border.cgColor)
        } else {
            layer?.borderColor = border.cgColor
        }
        textColor = colors.foreground
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            isFocused = true
            applyTheme(focused: true, animated: true)
        }
        return became
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        isFocused = false
        applyTheme(focused: false, animated: true)
        onCommit?(stringValue)
    }

    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        onTextChange?(stringValue)
    }

}

/// Insets the text from the well edge. The SAME inset rect must be applied at
/// every entry point: drawingRect covers static text and the placeholder, but
/// AppKit does NOT route edit/select/titleRect through drawingRect — the
/// field editor installs with the raw cell frame, so without all four
/// overrides the caret and typed text draw flush to the border while static
/// text keeps its padding. (Proven recipe — mirrors InspectorFieldCell.)
private final class CCFieldCell: NSTextFieldCell {
    static let hInset: CGFloat = 10

    /// Measured with a fixed "Xg" probe (never the current string) so empty,
    /// placeholder and filled states center identically.
    private func insetRect(forBounds rect: NSRect) -> NSRect {
        let inner = rect.insetBy(dx: Self.hInset, dy: 0)
        let probe = NSAttributedString(
            string: "Xg",
            attributes: [.font: font ?? NSFont.systemFont(ofSize: 13)]
        )
        let lineHeight = ceil(probe.size().height)
        return NSRect(
            x: inner.minX,
            y: inner.minY + (inner.height - lineHeight) / 2,
            width: inner.width,
            height: lineHeight
        )
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        insetRect(forBounds: super.drawingRect(forBounds: rect))
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        insetRect(forBounds: super.titleRect(forBounds: rect))
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: insetRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: insetRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
}
