import AppKit

/// CCKit button — shadcn's Button variants in AppKit, flat house chrome.
///
///     let save = CCButton(title: "Save", style: .primary) { ... }
///     let tiny = CCButton(title: "Copy", style: .outline, size: .sm)
///     let gear = CCButton(symbol: "gearshape", style: .ghost)   // icon-only square
///
/// Styles: `.primary` (accent fill), `.secondary` (elevated surface),
/// `.outline` (border only), `.ghost` (bare, wash on hover), `.link`
/// (accent text, underline on hover), `.destructive` (red fill).
/// Sizes: `.sm` / `.regular` / `.lg`; a button with a symbol and no title
/// renders as a square icon button. `radius` overrides the corner scale per
/// button (`.full` gives a capsule). All colors are theme tokens re-applied
/// live on `CCTheme.apply`; hover/press washes cross-fade on the house glide.
@MainActor
final class CCButton: NSControl {
    enum Style {
        case primary
        case secondary
        case outline
        case ghost
        case link
        case destructive
    }

    /// shadcn's `size="sm|default|lg"`.
    enum Size {
        case sm
        case regular
        case lg

        var height: CGFloat {
            switch self {
            case .sm: return 24
            case .regular: return 30
            case .lg: return 36
            }
        }

        var hPadding: CGFloat {
            switch self {
            case .sm: return 10
            case .regular: return 14
            case .lg: return 18
            }
        }

        var symbolPointSize: CGFloat {
            switch self {
            case .sm: return 10
            case .regular: return 11
            case .lg: return 13
            }
        }

        @MainActor var font: NSFont {
            // Regular reads the theme token; the others scale around it so a
            // themed font family/weight carries across the size scale.
            let base = CCTheme.font.button
            switch self {
            case .sm: return NSFont(descriptor: base.fontDescriptor, size: base.pointSize - 1) ?? base
            case .regular: return base
            case .lg: return NSFont(descriptor: base.fontDescriptor, size: base.pointSize + 1.5) ?? base
            }
        }
    }

    enum SymbolPlacement {
        case leading
        case trailing
    }

    var onClick: (() -> Void)?

    var style: Style {
        didSet { applyTheme() }
    }

    var size: Size {
        didSet {
            label.font = size.font
            refreshSymbolImage()
            heightConstraint.constant = size.height
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    /// Corner scale for this button; `.full` = capsule.
    var radius: CCRadius {
        didSet { needsLayout = true }
    }

    var title: String {
        get { label.stringValue }
        set {
            guard newValue != label.stringValue else { return }
            // Crossfade the text and glide the width — a title swap must
            // never snap the frame or overdraw old/new glyphs.
            CCMotion.fadeContentSwap(label)
            label.stringValue = newValue
            if style == .link { applyTheme() }
            invalidateIntrinsicContentSize()
            needsLayout = true
            CCMotion.expand(self)
        }
    }

    /// Optional SF Symbol beside the title — or alone: a symbol with an empty
    /// title renders a square icon button.
    var symbol: String? {
        didSet {
            refreshSymbolImage()
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    var symbolPlacement: SymbolPlacement {
        didSet { needsLayout = true }
    }

    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1 : CCTheme.current.disabledAlpha }
    }

    private var isIconOnly: Bool { label.stringValue.isEmpty && symbol != nil }

    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private var heightConstraint: NSLayoutConstraint!
    private var isHovering = false
    private var isPressed = false
    private var trackingArea: NSTrackingArea?
    private var themeObservation: CCThemeObservation?

    /// The width the label's CELL wants — not the raw attributed-string
    /// width (misses the cell's own horizontal slop and truncates the last
    /// characters) and not `intrinsicContentSize` on a truncating field
    /// (reports collapsed widths once the label has been manually framed).
    private var titleWidth: CGFloat {
        guard !label.stringValue.isEmpty, let cell = label.cell else { return 0 }
        let unbounded = NSRect(x: 0, y: 0, width: 10_000, height: 100)
        return ceil(cell.cellSize(forBounds: unbounded).width)
    }

    override var intrinsicContentSize: NSSize {
        if isIconOnly {
            return NSSize(width: size.height, height: size.height)
        }
        var width = titleWidth + size.hPadding * 2
        if symbol != nil { width += ceil(icon.intrinsicContentSize.width) + CCSpace.xs }
        return NSSize(width: width, height: size.height)
    }

    init(
        title: String = "",
        symbol: String? = nil,
        style: Style = .secondary,
        size: Size = .regular,
        radius: CCRadius = .md,
        symbolPlacement: SymbolPlacement = .leading,
        onClick: (() -> Void)? = nil
    ) {
        self.style = style
        self.size = size
        self.radius = radius
        self.symbol = symbol
        self.symbolPlacement = symbolPlacement
        self.onClick = onClick
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        label.stringValue = title
        label.font = size.font
        label.lineBreakMode = .byTruncatingTail
        refreshSymbolImage()
        // Manual frames (see layout()) — placement/icon-only variants change
        // geometry too often for a constraint web.
        for view in [icon, label] { addSubview(view) }
        heightConstraint = heightAnchor.constraint(equalToConstant: size.height)
        heightConstraint.isActive = true
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func refreshSymbolImage() {
        icon.image = symbol.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: size.symbolPointSize, weight: .medium))
        }
        icon.isHidden = symbol == nil
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = radius.resolved(for: bounds.height)
        if let layer { CCMaterial.refit(layer, radius: radius.resolved(for: bounds.height)) }

        let iconSize = symbol != nil ? icon.intrinsicContentSize : .zero
        if isIconOnly {
            icon.frame = NSRect(
                x: (bounds.width - iconSize.width) / 2,
                y: (bounds.height - iconSize.height) / 2,
                width: iconSize.width, height: iconSize.height
            )
            label.frame = .zero
            return
        }

        let labelSize = NSSize(width: titleWidth, height: label.intrinsicContentSize.height)
        let gap: CGFloat = symbol != nil ? CCSpace.xs : 0
        let content = labelSize.width + iconSize.width + gap
        let maxLabelWidth = bounds.width - size.hPadding * 2 - iconSize.width - gap
        let labelWidth = min(labelSize.width, max(maxLabelWidth, 0))
        var x = max((bounds.width - content) / 2, size.hPadding)

        func place(_ view: NSView, _ viewSize: NSSize, width: CGFloat? = nil) {
            view.frame = NSRect(
                x: x, y: (bounds.height - viewSize.height) / 2,
                width: width ?? viewSize.width, height: viewSize.height
            )
            x += (width ?? viewSize.width) + gap
        }
        if symbol != nil, symbolPlacement == .leading {
            place(icon, iconSize)
            place(label, labelSize, width: labelWidth)
        } else {
            place(label, labelSize, width: labelWidth)
            if symbol != nil { place(icon, iconSize) }
        }
    }

    /// `animated` cross-fades fill/border on the glide curve — hover and
    /// press feel liquid instead of snapping. Theme swaps stay instant.
    private func applyTheme(animated: Bool = false) {
        guard let layer else { return }
        let colors = CCTheme.color
        let fill: NSColor
        let text: NSColor
        var borderColor = colors.border
        switch style {
        case .primary:
            fill = colors.primary
            text = colors.primaryForeground
            borderColor = .clear
        case .secondary:
            fill = colors.elevated
            text = colors.foreground
        case .outline:
            fill = .clear
            text = colors.foreground
        case .ghost:
            fill = .clear
            text = colors.foreground
            borderColor = .clear
        case .link:
            fill = .clear
            text = colors.primary
            borderColor = .clear
        case .destructive:
            fill = colors.destructive
            text = .white
            borderColor = .clear
        }
        let washed: NSColor = {
            guard isHovering || isPressed else { return fill }
            switch style {
            case .ghost, .outline:
                return isPressed ? colors.active : colors.hover
            case .link:
                return .clear
            default:
                let washTint: NSColor = CCTheme.isDark ? .white : .black
                let amount: CGFloat = isPressed ? 0.14 : 0.08
                return fill.blended(withFraction: amount, of: washTint) ?? fill
            }
        }()

        label.textColor = text
        icon.contentTintColor = text
        // Link: underline on hover, like an inline anchor.
        if style == .link {
            label.attributedStringValue = NSAttributedString(
                string: label.stringValue,
                attributes: [
                    .font: size.font,
                    .foregroundColor: text,
                    .underlineStyle: isHovering ? NSUnderlineStyle.single.rawValue : 0,
                ]
            )
        }

        let ring = CCTheme.current.ring
        let ringWidth = isPressed ? ring.pressWidth : (isHovering ? ring.hoverWidth : 0)
        let resolvedBorder = ringWidth > 0 ? CCTheme.current.ringColor : borderColor
        layer.borderWidth = max(ringWidth, 1)
        if animated {
            CCMotion.fade(layer, keyPath: "backgroundColor", to: washed.cgColor)
            CCMotion.fade(layer, keyPath: "borderColor", to: resolvedBorder.cgColor)
        } else {
            layer.backgroundColor = washed.cgColor
            layer.borderColor = resolvedBorder.cgColor
        }
        // Skeuomorphic dressing: filled surfaces are raised glass; pressed
        // flips them recessed (the button visibly depresses). Ghost/link at
        // rest have no surface to dress.
        if washed.alphaComponent < 0.01 {
            CCMaterial.strip(layer)
        } else {
            // Always raised — the press is KEY TRAVEL (CCMaterial.press in
            // the mouse handlers), never a recessed re-dress: flipping the
            // material snapped a dark inner band into the face on click.
            CCMaterial.dress(layer, as: .raised(tint: washed), radius: radius.resolved(for: bounds.height))
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled else { return }
        isHovering = true
        applyTheme(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        applyTheme(animated: true)
    }

    // Press feedback is the darker wash alone (applyTheme's isPressed blend)
    // — Apple buttons tint in place; they never move or restyle on click.
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        applyTheme(animated: true)
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = false
        applyTheme(animated: true)
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) { onClick?() }
    }
}
