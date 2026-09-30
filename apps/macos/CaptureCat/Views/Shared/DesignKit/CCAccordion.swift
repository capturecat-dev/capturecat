import AppKit

/// CCKit accordion — shadcn's Accordion: stacked header rows whose chevron
/// springs a half turn while the body reveals below on the growth bounce
/// (bottom edge only — see `CCCollapsible`). `.single` keeps at most one item
/// open; `.multiple` lets any number open. Headers take keyboard focus
/// (Tab), toggle with space/return and hop with ↑/↓.
///
///     let faq = CCAccordion(mode: .single)
///     faq.addItem(title: "Is it accessible?", text: "Yes — it adheres to …")
///     faq.addItem(title: "Custom body", content: someView)
///     faq.onChange = { index, expanded in ... }
///
/// `chrome: .card` (default) sits the group on a raised matte card;
/// `.plain` drops the surface for use inside an existing card.
@MainActor
final class CCAccordion: NSView {
    enum Mode {
        case single
        case multiple
    }

    enum Chrome {
        case card
        case plain
    }

    let mode: Mode
    let chrome: Chrome
    var onChange: ((Int, Bool) -> Void)?

    private let stack = NSStackView()
    private var headers: [CCAccordionHeader] = []
    private var bodies: [CCCollapsible] = []
    private var dividers: [CCDivider] = []
    private var themeObservation: CCThemeObservation?

    init(mode: Mode = .single, chrome: Chrome = .card) {
        self.mode = mode
        self.chrome = chrome
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous

        stack.orientation = .vertical
        // Centered: rows are full-width, so only the (narrower) hairlines
        // actually center — inset into the text column on both sides.
        stack.alignment = .centerX
        stack.spacing = 0
        let inset = chrome == .card ? CCSpace.xs : 0
        stack.edgeInsets = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Items

    /// Add an item whose body is a muted paragraph.
    @discardableResult
    func addItem(title: String, text: String) -> CCCollapsible {
        let paragraph = CCAccordionParagraph(text)
        return addItem(title: title, content: paragraph)
    }

    /// Add an item with any body view (inset to the header's text column).
    @discardableResult
    func addItem(title: String, content: NSView) -> CCCollapsible {
        let index = headers.count
        let inset = stack.edgeInsets.left + stack.edgeInsets.right
        if index > 0 {
            let divider = CCDivider()
            stack.addArrangedSubview(divider)
            divider.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                           constant: -inset - CCSpace.md * 2).isActive = true
            dividers.append(divider)
        }

        let header = CCAccordionHeader(title: title)
        header.onActivate = { [weak self] in self?.toggle(index) }
        header.onMoveFocus = { [weak self] delta in self?.moveFocus(from: index, by: delta) }
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -inset).isActive = true
        headers.append(header)

        // The body column lines up with the header title; bottom padding
        // rides inside the collapsible so it is revealed with the content.
        let wrapper = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(content)
        let pad = CCAccordionHeader.textInset
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: wrapper.topAnchor),
            content.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: pad),
            content.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -pad),
            content.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -CCSpace.md),
        ])
        let body = CCCollapsible(content: wrapper)
        stack.addArrangedSubview(body)
        body.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -inset).isActive = true
        bodies.append(body)
        return body
    }

    var itemCount: Int { headers.count }

    func isExpanded(at index: Int) -> Bool {
        bodies.indices.contains(index) && bodies[index].isExpanded
    }

    /// Open/close one item. In `.single` mode opening an item closes the
    /// others (they glide shut while the new body bounces open).
    func setExpanded(_ expanded: Bool, at index: Int, animated: Bool = true) {
        guard bodies.indices.contains(index), bodies[index].isExpanded != expanded else { return }
        if expanded, mode == .single {
            for (other, body) in bodies.enumerated() where other != index && body.isExpanded {
                body.setExpanded(false, animated: animated)
                headers[other].setOpen(false, animated: animated)
                onChange?(other, false)
            }
        }
        bodies[index].setExpanded(expanded, animated: animated)
        headers[index].setOpen(expanded, animated: animated)
        onChange?(index, expanded)
    }

    func toggle(_ index: Int) {
        setExpanded(!isExpanded(at: index), at: index)
    }

    private func moveFocus(from index: Int, by delta: Int) {
        guard !headers.isEmpty else { return }
        let next = (index + delta + headers.count) % headers.count
        window?.makeFirstResponder(headers[next])
    }

    // MARK: - Chrome

    override func layout() {
        super.layout()
        guard chrome == .card, let layer else { return }
        layer.cornerRadius = CCTheme.radius(.lg)
        CCMaterial.refit(layer, radius: CCTheme.radius(.lg))
    }

    private func applyTheme() {
        guard chrome == .card, let layer else { return }
        let colors = CCTheme.color
        layer.backgroundColor = colors.card.cgColor
        layer.borderWidth = 1
        layer.borderColor = colors.border.cgColor
        CCMaterial.dress(layer, as: .raisedMatte(tint: colors.card), radius: CCTheme.radius(.lg))
    }

    // MARK: - Harness seams

    func probeBody(_ index: Int) -> CCCollapsible { bodies[index] }
    func probeChevronLayer(_ index: Int) -> CALayer { headers[index].probeChevron }
    func probeHeader(_ index: Int) -> NSView { headers[index] }
    var probeSurfaceLayer: CALayer? { layer }
}

// MARK: - Header row

@MainActor
private final class CCAccordionHeader: NSView {
    /// Leading/trailing inset of the title (and the body column under it).
    static let textInset: CGFloat = 12
    static let rowHeight: CGFloat = 40

    var onActivate: (() -> Void)?
    var onMoveFocus: ((Int) -> Void)?

    private let titleField = NSTextField(labelWithString: "")
    /// Leaf host for the chevron — animated sublayers never ride a view
    /// that has subviews (AppKit rebuilds those sublayer arrays).
    private let chevronHost = NSView()
    private let chevron = CAShapeLayer()
    private var isOpen = false
    private var isHovering = false
    private var isPressed = false
    private var isKeyboardFocused = false
    private var trackingArea: NSTrackingArea?
    private var themeObservation: CCThemeObservation?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    init(title: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous

        titleField.stringValue = title
        titleField.lineBreakMode = .byTruncatingTail
        chevronHost.wantsLayer = true
        let side: CGFloat = 12
        chevron.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        chevron.fillColor = nil
        chevron.lineWidth = 1.6
        chevron.lineCap = .round
        chevron.lineJoin = .round
        // Down-pointing chevron in the host's Y-up space; opening springs a
        // half turn so it points up (shadcn's rotate-180).
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 2.5, y: 7.6))
        path.addLine(to: CGPoint(x: 6, y: 4.1))
        path.addLine(to: CGPoint(x: 9.5, y: 7.6))
        chevron.path = path
        chevronHost.layer?.addSublayer(chevron)

        for view in [titleField, chevronHost] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.rowHeight),
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.textInset),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevronHost.leadingAnchor.constraint(greaterThanOrEqualTo: titleField.trailingAnchor, constant: CCSpace.sm),
            chevronHost.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.textInset),
            chevronHost.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevronHost.widthAnchor.constraint(equalToConstant: side),
            chevronHost.heightAnchor.constraint(equalToConstant: side),
        ])
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        layer?.cornerRadius = CCTheme.radius(.md)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chevron.position = CGPoint(x: chevronHost.bounds.midX, y: chevronHost.bounds.midY)
        CATransaction.commit()
    }

    func setOpen(_ open: Bool, animated: Bool) {
        guard open != isOpen else { return }
        isOpen = open
        let angle: CGFloat = open ? .pi : 0
        if animated, window != nil {
            CCMotion.spring(chevron, keyPath: "transform.rotation.z", to: angle, .bouncy)
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            chevron.setValue(angle, forKeyPath: "transform.rotation.z")
            CATransaction.commit()
        }
    }

    private func applyTheme(animated: Bool = false) {
        let colors = CCTheme.color
        titleField.font = NSFont.systemFont(ofSize: CCTheme.font.chip.pointSize, weight: .medium)
        titleField.textColor = colors.foreground
        chevron.strokeColor = colors.mutedForeground.cgColor
        // Hover / keyboard focus = the quiet ink wash; press = the deeper
        // `active` wash, tinted IN PLACE (no movement, no ring).
        let wash: NSColor = isPressed ? colors.active
            : (isHovering || isKeyboardFocused ? colors.hover : .clear)
        if animated, let layer {
            CCMotion.fade(layer, keyPath: "backgroundColor", to: wash.cgColor)
        } else {
            layer?.backgroundColor = wash.cgColor
        }
    }

    // MARK: Mouse

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
        isHovering = true
        applyTheme(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        applyTheme(animated: true)
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        applyTheme(animated: true)
    }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        applyTheme(animated: true)
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onActivate?() }
    }

    // MARK: Keyboard

    override func becomeFirstResponder() -> Bool {
        // Show the focus wash only for KEYBOARD focus (Tab/arrows) — a click
        // that focuses the header must not leave a highlight behind.
        let viaMouse = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            .contains(NSApp.currentEvent?.type ?? .keyDown)
        isKeyboardFocused = !viaMouse
        applyTheme(animated: true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        isKeyboardFocused = false
        applyTheme(animated: true)
        return true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49, 36, 76: // space, return, enter
            onActivate?()
        case 125: // ↓
            onMoveFocus?(1)
        case 126: // ↑
            onMoveFocus?(-1)
        default:
            super.keyDown(with: event)
        }
    }

    var probeChevron: CALayer { chevron }
}

/// Muted body paragraph for text items.
@MainActor
private final class CCAccordionParagraph: NSView {
    private let label: CCWrappingLabel
    private var themeObservation: CCThemeObservation?

    init(_ text: String) {
        label = CCWrappingLabel(text)
        super.init(frame: .zero)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        themeObservation = CCThemeObservation { [weak self] in
            self?.label.font = CCTheme.font.label
            self?.label.textColor = CCTheme.color.mutedForeground
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
