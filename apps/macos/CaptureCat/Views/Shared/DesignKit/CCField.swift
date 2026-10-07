import AppKit

/// A CCKit text well — CCField or its secure twin CCSecureField. Lets forms
/// treat both alike (value, error state, change callback).
@MainActor
protocol CCTextWell: NSTextField {
    var isError: Bool { get set }
    var onCommit: ((String) -> Void)? { get set }
    var onTextChange: ((String) -> Void)? { get set }
}

/// CCKit text field — shadcn's Input: a flat elevated well with the kit
/// focus ring, no Aqua bezel. Colors re-apply live on theme change.
///
///     let name = CCField(placeholder: "Project name")
///     name.onCommit = { text in ... }
///
/// Passwords/secrets use `CCSecureField` (same well, real NSSecureTextField).
@MainActor
final class CCField: NSTextField, CCTextWell {
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
        CCFieldChrome.install(CCFieldCell(textCell: ""), in: self, placeholder: placeholder, value: value)
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        CCFieldChrome.layout(self, radius: radius)
    }

    private func applyTheme(focused: Bool = false, animated: Bool = false) {
        CCFieldChrome.applyTheme(self, radius: radius, focused: focused, isError: isError, animated: animated)
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

/// CCField's secure twin — the same recessed well, but a REAL
/// NSSecureTextField: bullets, no copy-out, secure event input while
/// editing. (It must be the control class, not just the cell: AppKit asserts
/// the secure field editor's delegate is an NSSecureTextField — a secure
/// cell inside a plain NSTextField throws the moment it takes focus.)
///
///     let secret = CCSecureField(placeholder: "Secret access key")
@MainActor
final class CCSecureField: NSSecureTextField, CCTextWell {
    var onCommit: ((String) -> Void)?
    var onTextChange: ((String) -> Void)?

    var radius: CCRadius = .md {
        didSet { needsLayout = true }
    }

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
        CCFieldChrome.install(CCSecureFieldCell(textCell: ""), in: self, placeholder: placeholder, value: value)
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        CCFieldChrome.layout(self, radius: radius)
    }

    private func applyTheme(focused: Bool = false, animated: Bool = false) {
        CCFieldChrome.applyTheme(self, radius: radius, focused: focused, isError: isError, animated: animated)
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

/// The well chrome both fields share — one source, so the plain and secure
/// wells can never drift apart.
@MainActor
private enum CCFieldChrome {
    static func install(_ cell: NSTextFieldCell, in field: NSTextField, placeholder: String, value: String) {
        cell.isEditable = true
        cell.isScrollable = true
        cell.usesSingleLineMode = true
        cell.lineBreakMode = .byTruncatingTail
        field.cell = cell
        field.isSelectable = true
        field.stringValue = value
        field.placeholderString = placeholder
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = CCTheme.font.chip
        field.wantsLayer = true
        field.layer?.cornerCurve = .continuous
        field.layer?.borderWidth = 1
    }

    static func layout(_ field: NSTextField, radius: CCRadius) {
        let r = radius.resolved(for: field.bounds.height)
        field.layer?.cornerRadius = r
        if let layer = field.layer { CCMaterial.refit(layer, radius: r) }
    }

    static func applyTheme(_ field: NSTextField, radius: CCRadius, focused: Bool, isError: Bool, animated: Bool) {
        let colors = CCTheme.color
        let border: NSColor = focused
            ? CCTheme.current.ringColor
            : (isError ? colors.destructive : colors.border)
        field.layer?.backgroundColor = colors.elevated.cgColor
        field.layer?.borderWidth = focused ? max(CCTheme.current.ring.focusWidth, 1) : 1
        // Skeuo: input wells are recessed.
        if let layer = field.layer {
            CCMaterial.dress(layer, as: .recessed(tint: colors.elevated),
                             radius: radius.resolved(for: field.bounds.height))
        }
        if animated, let layer = field.layer {
            CCMotion.fade(layer, keyPath: "borderColor", to: border.cgColor)
        } else {
            field.layer?.borderColor = border.cgColor
        }
        field.textColor = colors.foreground
    }
}

/// Insets the text from the well edge. The SAME inset rect must be applied at
/// every entry point: drawingRect covers static text and the placeholder, but
/// AppKit does NOT route edit/select/titleRect through drawingRect — the
/// field editor installs with the raw cell frame, so without all four
/// overrides the caret and typed text draw flush to the border while static
/// text keeps its padding. (Proven recipe — mirrors InspectorFieldCell.)
@MainActor
private enum CCFieldInset {
    static let hInset: CGFloat = 10

    /// Measured with a fixed "Xg" probe (never the current string) so empty,
    /// placeholder and filled states center identically.
    static func rect(forBounds rect: NSRect, font: NSFont?) -> NSRect {
        let inner = rect.insetBy(dx: hInset, dy: 0)
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
}

private final class CCFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        CCFieldInset.rect(forBounds: super.drawingRect(forBounds: rect), font: font)
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        CCFieldInset.rect(forBounds: super.titleRect(forBounds: rect), font: font)
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: CCFieldInset.rect(forBounds: rect, font: font), in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: CCFieldInset.rect(forBounds: rect, font: font), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
}

/// The secure twin of CCFieldCell — identical inset geometry on
/// NSSecureTextFieldCell, so a password well lines up with its neighbours.
private final class CCSecureFieldCell: NSSecureTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        CCFieldInset.rect(forBounds: super.drawingRect(forBounds: rect), font: font)
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        CCFieldInset.rect(forBounds: super.titleRect(forBounds: rect), font: font)
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: CCFieldInset.rect(forBounds: rect, font: font), in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: CCFieldInset.rect(forBounds: rect, font: font), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
}
