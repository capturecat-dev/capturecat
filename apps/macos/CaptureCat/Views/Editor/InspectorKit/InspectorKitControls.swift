import AppKit

// Native AppKit twins of the SwiftUI inspector kit (InspectorControls.swift).
// Every control is hand-drawn against EditorThemeKit — no stock control
// chrome. Shared primitives live in CaptureCatControls.swift.
//
// All controls are flipped, layer-backed and communicate with closures; the
// pane that owns them re-applies model state through an observation loop.

// MARK: - Slider

/// The bare custom slider track — a 3pt rail with a white fill and a round
/// knob. Click anywhere to jump there, then keep dragging.
final class InspectorSliderControl: NSControl {
    var range: ClosedRange<Double> = 0...1
    var step: Double?
    var onChange: ((Double) -> Void)?

    override var doubleValue: Double {
        didSet { needsLayout = true }
    }

    private let railHeight: CGFloat = 3
    private let knobIdle: CGFloat = 12
    private let knobActive: CGFloat = 14

    private let rail = CALayer()
    private let fill = CALayer()
    private let knob = CALayer()
    private var isHovering = false
    private var isDraggingKnob = false
    private var trackingArea: NSTrackingArea?
    private var themeObservation: CCThemeObservation?

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: knobActive + 2)
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        for l in [rail, fill, knob] { layer?.addSublayer(l) }
        knob.shadowOpacity = 1
        knob.shadowRadius = 2
        knob.shadowOffset = CGSize(width: 0, height: 1)
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    private func applyTheme() {
        // High-contrast ink against the current panel — white on dark, black on light.
        let ink: NSColor = CCTheme.isDark ? .white : .black
        rail.backgroundColor = ink.withAlphaComponent(0.12).cgColor
        fill.backgroundColor = ink.withAlphaComponent(0.85).cgColor
        knob.backgroundColor = ink.cgColor
        knob.shadowColor = NSColor.black.withAlphaComponent(0.3).cgColor
        // Skeuo: the knob is a small glossy ball (the 3px rail stays clean —
        // material on a hairline is noise).
        CCMaterial.dress(knob, as: .raised(tint: ink), radius: knobIdle / 2)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var fraction: CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        let clamped = min(max(doubleValue, range.lowerBound), range.upperBound)
        return CGFloat((clamped - range.lowerBound) / span)
    }

    override func layout() {
        super.layout()
        let knobSize = isDraggingKnob || isHovering ? knobActive : knobIdle
        let usable = max(1, bounds.width - knobSize)
        let knobX = usable * fraction
        let midY = bounds.midY

        CATransaction.begin()
        // Tight tracking while dragging; a soft Keynote settle when the value
        // arrives from the model or the knob grows on hover.
        CATransaction.setAnimationDuration(isDraggingKnob ? 0.08 : 0.28)
        CATransaction.setAnimationTimingFunction(CCMotion.settle)
        rail.frame = CGRect(x: 0, y: midY - railHeight / 2, width: bounds.width, height: railHeight)
        rail.cornerRadius = railHeight / 2
        fill.frame = CGRect(x: 0, y: midY - railHeight / 2, width: knobX + knobSize / 2, height: railHeight)
        fill.cornerRadius = railHeight / 2
        knob.frame = CGRect(x: knobX, y: midY - knobSize / 2, width: knobSize, height: knobSize)
        knob.cornerRadius = knobSize / 2
        CCMaterial.refit(knob, radius: knobSize / 2)
        CATransaction.commit()
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

    override func mouseEntered(with event: NSEvent) { isHovering = true; needsLayout = true }
    override func mouseExited(with event: NSEvent) { isHovering = false; needsLayout = true }

    override func mouseDown(with event: NSEvent) {
        isDraggingKnob = true
        commit(atX: convert(event.locationInWindow, from: nil).x)
    }

    override func mouseDragged(with event: NSEvent) {
        commit(atX: convert(event.locationInWindow, from: nil).x)
    }

    override func mouseUp(with event: NSEvent) {
        commit(atX: convert(event.locationInWindow, from: nil).x)
        isDraggingKnob = false
        needsLayout = true
    }

    private func commit(atX x: CGFloat) {
        let knobSize = knobActive
        let usable = max(1, bounds.width - knobSize)
        let fraction = min(max((x - knobSize / 2) / usable, 0), 1)
        var next = range.lowerBound + Double(fraction) * (range.upperBound - range.lowerBound)
        if let step, step > 0 {
            next = ((next - range.lowerBound) / step).rounded() * step + range.lowerBound
        }
        let clamped = min(max(next, range.lowerBound), range.upperBound)
        if clamped != doubleValue {
            doubleValue = clamped
            onChange?(clamped)
        }
        needsLayout = true
    }
}

/// Standard slider row — now one CCSlider pill carrying its own label,
/// ticks and value (the Weather-style control). The old label-above/rail-below
/// layout is gone; the API is unchanged so panes didn't move.
final class InspectorSliderRow: NSView {
    let slider = CCSlider()
    /// nil (default) shows the house 0–100% readout; set only for human units
    /// (%, ×, °, s) — px/pt never appear in the UI.
    var format: ((Double) -> String)? {
        get { slider.format }
        set { slider.format = newValue }
    }

    override var isFlipped: Bool { true }

    init(label text: String, range: ClosedRange<Double>, step: Double? = nil) {
        super.init(frame: .zero)
        slider.title = text
        slider.range = range
        slider.step = step
        slider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(slider)
        NSLayoutConstraint.activate([
            slider.leadingAnchor.constraint(equalTo: leadingAnchor),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor),
            slider.topAnchor.constraint(equalTo: topAnchor),
            slider.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Push a model value into the row (no onChange echo).
    func setValue(_ value: Double) {
        slider.doubleValue = value
    }

    var onChange: ((Double) -> Void)? {
        didSet { slider.onChange = { [weak self] value in self?.onChange?(value) } }
    }
}

// MARK: - Menu picker

/// Flat drop-down field replacing `.pickerStyle(.menu)`.
final class InspectorMenuControl: NSControl {
    struct Item {
        let title: String
        var icon: NSImage?
    }

    var items: [Item] = [] { didSet { refresh() } }
    var selectedIndex: Int = 0 { didSet { refresh() } }
    /// When set, the collapsed field shows this instead of the selected item —
    /// e.g. "Custom" while a freeform override supersedes the enum.
    var overrideTitle: String? { didSet { refresh() } }
    var onSelect: ((Int) -> Void)?

    private let title = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private let iconChip = NSImageView()
    private let hoverWash = NSView()
    private var trackingArea: NSTrackingArea?
    private var themeObservation: CCThemeObservation?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        // The shipped SwiftUI menu renders flat on the panel — chevron leading
        // the title, no visible field fill; only a hover wash appears.
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerRadius = EditorThemeKit.controlRadius
        layer?.cornerCurve = .continuous

        hoverWash.wantsLayer = true
        hoverWash.layer?.backgroundColor = NSColor.clear.cgColor
        hoverWash.layer?.cornerRadius = EditorThemeKit.controlRadius
        hoverWash.layer?.cornerCurve = .continuous

        title.font = EditorThemeKit.label()
        title.lineBreakMode = .byTruncatingTail

        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        chevron.image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)

        iconChip.wantsLayer = true
        iconChip.layer?.cornerRadius = 3
        iconChip.layer?.cornerCurve = .continuous
        iconChip.imageScaling = .scaleProportionallyUpOrDown
        iconChip.isHidden = true

        for v in [hoverWash, chevron, iconChip, title] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            hoverWash.leadingAnchor.constraint(equalTo: leadingAnchor),
            hoverWash.trailingAnchor.constraint(equalTo: trailingAnchor),
            hoverWash.topAnchor.constraint(equalTo: topAnchor),
            hoverWash.bottomAnchor.constraint(equalTo: bottomAnchor),

            chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),

            iconChip.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 6),
            iconChip.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconChip.widthAnchor.constraint(equalToConstant: 18),
            iconChip.heightAnchor.constraint(equalToConstant: 18),

            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            heightAnchor.constraint(equalToConstant: 16),
        ])
        titleLeading = title.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 6)
        titleLeading?.isActive = true
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    private var titleLeading: NSLayoutConstraint?

    required init?(coder: NSCoder) { fatalError() }

    private func applyTheme() {
        title.textColor = EditorThemeKit.textPrimary
        chevron.contentTintColor = EditorThemeKit.textSecondary
        let ink: NSColor = CCTheme.isDark ? .white : .black
        iconChip.layer?.backgroundColor = ink.withAlphaComponent(0.9).cgColor
    }

    private func refresh() {
        guard items.indices.contains(selectedIndex) else { return }
        // The collapsed field shows chevron + title only (matches the shipped
        // app); per-item icons appear in the dropdown, not the field.
        title.stringValue = overrideTitle ?? items[selectedIndex].title
        iconChip.isHidden = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hoverWash.layer?.backgroundColor = EditorThemeKit.hoverFill.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        hoverWash.layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        let menu = NSMenu()
        for (index, item) in items.enumerated() {
            let mi = NSMenuItem(title: item.title, action: #selector(pick(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = index
            if let icon = item.icon {
                mi.image = icon
            } else if index == selectedIndex {
                mi.state = .on
            }
            menu.addItem(mi)
        }
        CaptureCatMenuPresenter.show(
            menu,
            from: self,
            edge: .below,
            selectedItem: menu.items[safe: selectedIndex]
        )
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard sender.tag != selectedIndex else { return }
        selectedIndex = sender.tag
        onSelect?(sender.tag)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Chip row

/// A single row of roomy pill chips — one option per chip, sized to its
/// label. The row NEVER wraps: when it would overflow the pane width it
/// scrolls horizontally behind an overlay scroller, so labels stay whole
/// at the roomy padding and the pane keeps one tidy line.
final class InspectorChipsControl: NSView {
    var items: [String] = [] { didSet { rebuild() } }
    var selectedIndex: Int = 0 { didSet { restyle() } }
    var onSelect: ((Int) -> Void)?

    private var chips: [ChipButton] = []
    private let hGap: CGFloat = 8
    private let scroll = NSScrollView()
    private let doc = FlippedDocView()
    private var heightConstraint: NSLayoutConstraint!

    override var isFlipped: Bool { true }

    private final class FlippedDocView: NSView {
        override var isFlipped: Bool { true }
    }

    init() {
        super.init(frame: .zero)
        heightConstraint = heightAnchor.constraint(equalToConstant: 30)
        heightConstraint.isActive = true

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScrollElasticity = .none
        scroll.documentView = doc
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func rebuild() {
        chips.forEach { $0.removeFromSuperview() }
        chips = items.enumerated().map { index, text in
            let chip = ChipButton(text: text)
            chip.onClick = { [weak self] in
                guard let self, self.selectedIndex != index else { return }
                self.selectedIndex = index
                self.onSelect?(index)
            }
            return chip
        }
        chips.forEach(doc.addSubview)
        restyle()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard !chips.isEmpty else { return }

        // The compression ChipButton always PROMISED but nothing ever wired:
        // shrink every chip's padding (down to minPadding) so the whole set
        // fits the pane before falling back to horizontal scrolling — a chip
        // cut mid-label reads as broken, not scrollable.
        let labelTotal = chips.reduce(0) { $0 + $1.labelWidth }
        let gaps = hGap * CGFloat(max(0, chips.count - 1))
        let spare = bounds.width - gaps - labelTotal
        let perSide = floor(spare / CGFloat(chips.count * 2))
        let pad = min(ChipButton.defaultPadding, max(ChipButton.minPadding, perSide))
        for chip in chips { chip.horizontalPadding = pad }

        // Flow layout: when even compressed padding can't fit one line, WRAP
        // to the next — a chip cut mid-label at the pane edge reads as
        // broken, never as scrollable.
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for chip in chips {
            let size = chip.fittingSize
            if x > 0, x + size.width > bounds.width {
                x = 0
                y += lineHeight + 6
            }
            chip.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
            x += size.width + hGap
            lineHeight = max(lineHeight, size.height)
        }
        // Slack below the chips: the material's under edge (+2pt) and soft
        // shadow need room, or the clip guillotines them into hard artifacts.
        let slack: CGFloat = 6
        let total = y + lineHeight + slack
        doc.frame = CGRect(x: 0, y: 0, width: bounds.width, height: total)
        if heightConstraint.constant != total {
            heightConstraint.constant = total
        }
    }

    private func restyle() {
        for (index, chip) in chips.enumerated() {
            chip.setSelected(index == selectedIndex)
        }
    }

    private final class ChipButton: NSView {
        static let defaultPadding: CGFloat = 14
        static let minPadding: CGFloat = 8

        var onClick: (() -> Void)?
        private let label = NSTextField(labelWithString: "")
        private var isSelected = false
        private var themeObservation: CCThemeObservation?
        private var leadingPad: NSLayoutConstraint!
        private var trailingPad: NSLayoutConstraint!

        /// The label's own width — what the chip needs beyond its padding.
        var labelWidth: CGFloat { label.intrinsicContentSize.width }

        /// Per-side horizontal padding; the owning row compresses this at
        /// narrow widths so every label stays whole.
        var horizontalPadding: CGFloat = ChipButton.defaultPadding {
            didSet {
                guard horizontalPadding != oldValue else { return }
                leadingPad.constant = horizontalPadding
                trailingPad.constant = -horizontalPadding
            }
        }

        init(text: String) {
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerCurve = .continuous
            layer?.borderWidth = 0
            label.stringValue = text
            label.font = EditorThemeKit.chip()
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            leadingPad = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.defaultPadding)
            trailingPad = label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.defaultPadding)
            let bottomPad = label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
            // The chip is FRAME-placed by the flow layout, so until the first
            // layout pass its autoresizing constraints pin it at zero size.
            // The closing-edge constraints must yield (999) during that
            // instant or AppKit logs a conflict for every chip on every pane
            // open; `fittingSize` still honors 999s, so the resolved layout
            // is identical.
            trailingPad.priority = .init(999)
            bottomPad.priority = .init(999)
            NSLayoutConstraint.activate([
                leadingPad!,
                trailingPad!,
                label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                bottomPad,
            ])
            themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            layer?.cornerRadius = CCRadius.full.resolved(for: bounds.height)
            if let layer {
                CCMaterial.refit(layer, radius: CCRadius.full.resolved(for: bounds.height))
            }
        }

        func setSelected(_ selected: Bool) {
            isSelected = selected
            applyTheme()
        }

        private func applyTheme() {
            label.textColor = EditorThemeKit.textPrimary
            // No selection ring (removed 2026-09-01) — the brighter fill and
            // raised material carry the selected state on their own.
            let fill = isSelected ? EditorThemeKit.activeFill : EditorThemeKit.panelElevated
            layer?.backgroundColor = fill.cgColor
            layer?.borderWidth = 0
            // Skeuo: raised glass chip with a real downward shadow — the
            // switcher chips read as buttons sitting ON the panel.
            if let layer {
                CCMaterial.dress(layer, as: .raised(tint: fill),
                                 radius: CCRadius.full.resolved(for: max(bounds.height, 30)))
                layer.shadowColor = NSColor.black.cgColor
                layer.shadowOpacity = CCTheme.isDark ? 0.35 : 0.15
                layer.shadowRadius = 2
                layer.shadowOffset = CGSize(width: 0, height: -1)
            }
        }

        // Real key travel on click — firing on bare mouseDown with zero
        // feedback was part of "the clicking is very ugly".
        override func mouseDown(with event: NSEvent) {
            if let layer { CCMaterial.press(layer, down: true) }
        }

        override func mouseUp(with event: NSEvent) {
            if let layer { CCMaterial.press(layer, down: false) }
            if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
        }
    }
}

// MARK: - Toggle

/// Label left, house toggle right.
final class InspectorToggleControl: NSView {
    var onChange: ((Bool) -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let toggle = CaptureCatToggle()
    private var themeObservation: CCThemeObservation?

    override var isFlipped: Bool { true }

    var isOn: Bool {
        get { toggle.isOn }
        set { toggle.isOn = newValue }
    }

    var isEnabled: Bool {
        get { toggle.isEnabled }
        set {
            toggle.isEnabled = newValue
            label.alphaValue = newValue ? 1 : 0.4
        }
    }

    init(_ text: String) {
        super.init(frame: .zero)
        label.stringValue = text
        label.font = EditorThemeKit.label()
        toggle.onChange = { [weak self] value in self?.onChange?(value) }
        for v in [label, toggle] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalTo: toggle.heightAnchor),
        ])
        themeObservation = CCThemeObservation { [weak self] in
            self?.label.textColor = EditorThemeKit.textPrimary
        }
    }

    required init?(coder: NSCoder) { fatalError() }

}

// MARK: - Button

/// Flat inspector button — a panelElevated chip that washes on hover.
/// Destructive actions get red text; the fill stays neutral.
final class InspectorButton: NSControl {
    var onClick: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let destructive: Bool
    private var trackingArea: NSTrackingArea?
    private var isHovering = false
    private var isPressed = false
    private var themeObservation: CCThemeObservation?

    override var isFlipped: Bool { true }

    init(_ text: String, destructive: Bool = false) {
        self.destructive = destructive
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = EditorThemeKit.controlRadius
        layer?.cornerCurve = .continuous
        label.stringValue = text
        label.font = EditorThemeKit.button()
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    private func applyTheme() {
        label.textColor = destructive
            ? CCTheme.color.destructive.withAlphaComponent(0.9)
            : EditorThemeKit.textPrimary
        restyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1 : 0.4 }
    }

    /// Mutable label (e.g. "Choose Logo…" ↔ "Replace Logo…").
    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    private func restyle() {
        let wash: NSColor
        if isPressed { wash = EditorThemeKit.activeFill }
        else if isHovering { wash = EditorThemeKit.hoverFill }
        else { wash = .clear }
        // Hover/press wash blends toward the theme's ink, not always white.
        let ink: NSColor = CCTheme.isDark ? .white : .black
        let fill = EditorThemeKit.panelElevated.blended(withFraction: wash.alphaComponent, of: ink)
            ?? EditorThemeKit.panelElevated
        layer?.backgroundColor = fill.cgColor
        // Always raised — press feedback is key travel (CCMaterial.press),
        // not a recessed re-dress.
        if let layer {
            CCMaterial.dress(layer, as: .raised(tint: fill),
                             radius: EditorThemeKit.controlRadius)
        }
    }

    override func layout() {
        super.layout()
        if let layer { CCMaterial.refit(layer, radius: EditorThemeKit.controlRadius) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = isEnabled; restyle() }
    override func mouseExited(with event: NSEvent) { isHovering = false; restyle() }
    // Press = the darker restyle wash alone; buttons never move on click.
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true; restyle()
    }
    override func mouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = false; restyle()
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

// MARK: - Layout helpers

@MainActor
enum InspectorKitViews {
    /// Retains a CCThemeObservation on the view itself so factory-made labels
    /// and dividers re-resolve their colors on theme flips without needing a
    /// dedicated subclass.
    private static var themeObservationKey: UInt8 = 0
    private static func bindTheme(_ view: NSView, _ apply: @escaping @MainActor () -> Void) {
        objc_setAssociatedObject(
            view, &themeObservationKey,
            CCThemeObservation(apply),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    /// Section header — sentence case, sized like a real heading.
    static func header(_ title: String) -> NSTextField {
        let field = NSTextField(labelWithString: title)
        field.font = EditorThemeKit.header()
        bindTheme(field) { [weak field] in field?.textColor = EditorThemeKit.textPrimary }
        return field
    }

    /// Muted explainer line under a control group.
    static func caption(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = EditorThemeKit.caption()
        field.isSelectable = false
        bindTheme(field) { [weak field] in field?.textColor = EditorThemeKit.textTertiary }
        return field
    }

    /// Label left, any control right-aligned.
    static func row(_ label: String, control: NSView) -> NSView {
        let container = NSView()
        let field = NSTextField(labelWithString: label)
        field.font = EditorThemeKit.label()
        bindTheme(field) { [weak field] in field?.textColor = EditorThemeKit.textPrimary }
        for v in [field, control] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            field.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            control.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            control.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            container.heightAnchor.constraint(equalTo: control.heightAnchor),
        ])
        return container
    }

    /// Section separator with breathing room.
    static func divider() -> NSView {
        let container = NSView()
        let line = NSView()
        line.wantsLayer = true
        bindTheme(line) { [weak line] in
            line?.layer?.backgroundColor = EditorThemeKit.hairline.cgColor
        }
        line.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
            line.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            container.heightAnchor.constraint(equalToConstant: 9),
        ])
        return container
    }
}
