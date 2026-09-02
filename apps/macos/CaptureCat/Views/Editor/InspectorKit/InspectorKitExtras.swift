import AppKit

// Shared small controls for the AppKit inspector panes (Phase 3).

// MARK: - Color well

/// Flat 22pt round swatch that opens `ColorPickerPopoverView` inside the shared
/// borderless floating panel anchored under the swatch.
/// One UI for color picking app-wide — this control only hosts it.
@MainActor
final class InspectorColorWellControl: NSControl {
    var supportsOpacity: Bool = true
    /// Read the current color (called on open and on redraw).
    var getColor: (() -> NSColor) = { .white }
    /// Write a picked color back to the model.
    var setColor: ((NSColor) -> Void)?

    private let checker = CheckerboardLayer()
    private let swatch = CALayer()
    private var popover: CaptureCatPopover?
    private var themeObservation: CCThemeObservation?

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 22, height: 22) }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(checker)
        layer?.addSublayer(swatch)
        layer?.borderWidth = 1
        layer?.masksToBounds = true
        // Border is chrome; the swatch color itself is user content and stays.
        themeObservation = CCThemeObservation { [weak self] in
            let ink: NSColor = CCTheme.isDark ? .white : .black
            self?.layer?.borderColor = ink.withAlphaComponent(0.25).cgColor
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = bounds.height / 2
        checker.frame = bounds
        checker.square = 4
        checker.setNeedsDisplay()
        swatch.frame = bounds
        CATransaction.commit()
    }

    func refresh() {
        swatch.backgroundColor = getColor().cgColor
    }

    override func mouseDown(with event: NSEvent) {
        if let popover, popover.isShown {
            popover.close()
            self.popover = nil
            return
        }
        let color = getColor().usingColorSpace(.sRGB) ?? .white
        let picker = ColorPickerPopoverView(color: color, supportsOpacity: supportsOpacity)
        picker.onChange = { [weak self] picked in
            self?.setColor?(picked)
            self?.refresh()
        }
        let controller = NSViewController()
        controller.view = picker
        controller.preferredContentSize = picker.intrinsicContentSize
        let popover = CaptureCatPopover()
        popover.contentViewController = controller
        popover.contentSize = picker.intrinsicContentSize
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        self.popover = popover
    }
}

/// Gray alpha checkerboard, drawn (not tiled images) — mirrors the SwiftUI
/// CheckerboardBackground.
final class CheckerboardLayer: CALayer {
    var square: CGFloat = 4

    override init() {
        super.init()
        backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        needsDisplayOnBoundsChange = true
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(in ctx: CGContext) {
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.25).cgColor)
        let cols = Int(ceil(bounds.width / square))
        let rows = Int(ceil(bounds.height / square))
        for row in 0..<rows {
            for col in 0..<cols where (row + col) % 2 == 0 {
                ctx.fill(CGRect(
                    x: CGFloat(col) * square, y: CGFloat(row) * square,
                    width: square, height: square
                ))
            }
        }
    }
}

// MARK: - Flat text field

/// NSTextField dressed like the flat kit — panelElevated fill, hairline
/// border, no focus ring, small label font.
/// Text-field cell that insets its text and editor by the chip's horizontal
/// padding — AppKit gives no built-in content inset, so both the drawn and
/// the editing rect must be adjusted or the caret sits flush to the border.
private final class InspectorFieldCell: NSTextFieldCell {
    static let hInset: CGFloat = InspectorFlatTextField.hPadding

    /// One rect used for drawing, editing AND selection — otherwise the caret
    /// and the drawn text land in different places.
    ///
    /// Measured with a fixed "Xg" probe in the cell's font (never the current
    /// string) so the geometry is identical whether the field is empty,
    /// showing a placeholder, or full of text — content-dependent measuring
    /// made focused and unfocused fields center differently.
    private func centeredRect(forBounds rect: NSRect) -> NSRect {
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

    // The SAME inset rect must be applied at every entry point. drawingRect
    // covers the static (unfocused) text and the placeholder, but AppKit does
    // NOT route edit(withFrame:)/select(withFrame:) through drawingRect — the
    // field editor is installed with the raw cell frame, so without these
    // overrides typed text draws flush to the pill's border while static text
    // keeps its padding. All four derive from one helper so the caret, the
    // selection, the editor and the drawn text share one x-origin exactly.
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        centeredRect(forBounds: super.drawingRect(forBounds: rect))
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        centeredRect(forBounds: super.titleRect(forBounds: rect))
    }

    override func edit(
        withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
        delegate: Any?, event: NSEvent?
    ) {
        super.edit(
            withFrame: centeredRect(forBounds: rect), in: controlView,
            editor: textObj, delegate: delegate, event: event
        )
    }

    override func select(
        withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
        delegate: Any?, start selStart: Int, length selLength: Int
    ) {
        super.select(
            withFrame: centeredRect(forBounds: rect), in: controlView,
            editor: textObj, delegate: delegate,
            start: selStart, length: selLength
        )
    }
}

final class InspectorFlatTextField: NSTextField {
    /// Matches InspectorChipsControl's pill: same padding, height and radius
    /// (rounded-full), so fields and chips read as one control family.
    static let hPadding: CGFloat = 14
    static let vPadding: CGFloat = 8

    private let placeholderText: String
    private var isFocusedAppearance = false
    private var themeObservation: CCThemeObservation?

    /// `width == nil` (the default) leaves the field flexible so a pane can
    /// pin it full-width like any other arranged row (InspectorSliderRow
    /// style). Pass an explicit width ONLY when the field is deliberately
    /// paired with a label in a compact row (e.g. "Clock", "Start"/"End").
    /// Never combine an explicit width with a full-width pin — the two
    /// constraints conflict and AppKit breaks one nondeterministically.
    init(placeholder: String, width: CGFloat? = nil) {
        placeholderText = placeholder
        super.init(frame: .zero)
        cell = InspectorFieldCell(textCell: "")
        isEditable = true
        isSelectable = true
        isBezeled = false
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        font = EditorThemeKit.chip()
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        if let width {
            widthAnchor.constraint(equalToConstant: width).isActive = true
        } else {
            setContentHuggingPriority(.defaultLow, for: .horizontal)
            setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        // Chip height: text line + 8pt above and below.
        let line = ceil((font ?? EditorThemeKit.chip()).boundingRectForFont.height)
        heightAnchor.constraint(equalToConstant: line + Self.vPadding * 2).isActive = true
        (cell as? NSTextFieldCell)?.usesSingleLineMode = true
        (cell as? NSTextFieldCell)?.lineBreakMode = .byTruncatingTail
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func applyTheme() {
        textColor = EditorThemeKit.textPrimary
        // Attributed placeholder so every field shares the kit's tertiary
        // text color instead of the stock AppKit gray.
        placeholderAttributedString = NSAttributedString(
            string: placeholderText,
            attributes: [
                .font: EditorThemeKit.chip(),
                .foregroundColor: EditorThemeKit.textTertiary,
            ]
        )
        applyFocusAppearance(isFocusedAppearance)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = CCRadius.full.resolved(for: bounds.height)
    }

    /// Focus reads like a selected chip: active fill + periwinkle outline,
    /// instead of the system focus ring (which we disable app-wide).
    private func applyFocusAppearance(_ focused: Bool) {
        isFocusedAppearance = focused
        layer?.backgroundColor = (focused ? EditorThemeKit.activeFill : EditorThemeKit.panelElevated).cgColor
        layer?.borderColor = (focused ? EditorThemeKit.selectionOutline : EditorThemeKit.hairline).cgColor
        layer?.borderWidth = 1
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { applyFocusAppearance(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { applyFocusAppearance(false) }
        return ok
    }

    // The field editor is what actually holds focus, so editing begin/end are
    // the reliable signals when the user clicks straight into the text.
    override func textDidBeginEditing(_ notification: Notification) {
        super.textDidBeginEditing(notification)
        applyFocusAppearance(true)
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        applyFocusAppearance(false)
        // Release focus on commit so Return/Tab doesn't leave the field
        // visually active (pre-existing behaviour, kept).
        window?.makeFirstResponder(nil)
    }
}
