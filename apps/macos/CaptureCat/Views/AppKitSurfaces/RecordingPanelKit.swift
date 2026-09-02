import AppKit

// Native twins of the recording toolbar's SwiftUI chips.
//
// The SwiftUI panel draws every control as `.glassEffect(.regular, in: .capsule)`.
// AppKit exposes the SAME Liquid Glass primitive as `NSGlassEffectView`, so the
// native panel is glass-for-glass rather than a flat repaint — the InspectorKit
// idioms (hover wash, hand-built chip content, closure wiring, `isEnabled`
// alpha) are carried over on top of it.
//
// Geometry constants are the SwiftUI toolbar's, verbatim:
//   controlHeight 42 · controlSpacing 8 · tabWidth 84 · shell padding 8.

enum RecordingPanelMetrics {
    static let controlHeight: CGFloat = 46
    static let controlSpacing: CGFloat = 6
    static let tabWidth: CGFloat = 52
    static let shellPadding: CGFloat = 9

    /// The bar is a rounded rect now, not a capsule — CCKit `.xl`, the same
    /// token as dialog cards and the device monitor.
    @MainActor static var barRadius: CGFloat { CCTheme.radius(.xl) }
    /// Small-radius rounded rect for every interior surface that needs one —
    /// hover wash, selection square, the filled Record button. Nothing inside
    /// the bar is a capsule (user call: "no pill buttons inside"); controls
    /// are flat icon/label targets on the bar surface, Screen Studio style.
    /// The segment overlay MUST use the same radius (it glides over the tabs).
    /// CCKit `.lg` — shared with menus, popovers and preview cards.
    @MainActor static var tabRadius: CGFloat { CCTheme.radius(.lg) }

    // Flat-surface palette (EditorThemeKit + quiet washes).
    // Fully opaque: any see-through on this bar reads as "glass", which the
    // design explicitly rejects — the desktop must never bleed through.
    // Computed so every read resolves the CURRENT theme (EditorThemeKit is a
    // live façade over CCTheme; ink flips with CCTheme.isDark).
    @MainActor static var barFill: NSColor { EditorThemeKit.panel }
    @MainActor static var barStroke: NSColor { ink.withAlphaComponent(0.09) }
    /// On-state indicator dots keep the ACCENT hue — decoupled from the ring
    /// token when rings went ink-white (a white "on" dot loses the signal).
    @MainActor static var accentOn: NSColor { CCTheme.color.primary.withAlphaComponent(1) }
    @MainActor static var dotOff: NSColor { ink.withAlphaComponent(0.22) }
    @MainActor static var ink: NSColor { CCTheme.isDark ? .white : .black }

    /// Compact bar text font (Screen Studio scale).
    static func toolbarText() -> NSFont { .systemFont(ofSize: 12, weight: .medium) }
    /// Monospaced digits for the running timer: SwiftUI gets stability from
    /// `.contentTransition(.numericText())`, AppKit gets it from the font.
    static func timer() -> NSFont { .monospacedDigitSystemFont(ofSize: 12, weight: .medium) }
    /// Tiny label under the tab icon — Screen Studio's ~10pt caption.
    static func tabLabel() -> NSFont { .systemFont(ofSize: 10, weight: .medium) }
    static func sourceLabel() -> NSFont { .systemFont(ofSize: 11, weight: .medium) }

    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .medium) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight))
    }

    // MARK: - Panel geometry
    //
    // Previously static members of the SwiftUI `RecordingControlsView`; moved
    // here when that view was deleted. `AppState` needs them to size the panel
    // before any content exists.

    /// Wide setup toolbar: source tabs plus the inline pickers.
    /// Widest the setup row can be before its chips start overlapping.
    ///
    /// Measured, not guessed: the mode switch, five source tabs, the widest
    /// source chip, the device/audio chips and the transport buttons. The
    /// `--recording-panel-shot` gate asserts the real fitting width never
    /// exceeds the panel — when it did, AppKit broke the width constraint and
    /// the chips stacked on top of each other, which reads as a dead toolbar
    /// rather than a layout problem.
    // Sized for the WIDEST row (the Area tab: display picker + Select Area);
    // the shell hugs its content, so other tabs render narrower than this.
    // 1250 before the countdown chip joined the row; +60 covers the chip
    // ("3s" + stopwatch glyph) plus its stack spacing.
    static let setupContentWidth: CGFloat = 1310

    static func setupPanelSize() -> NSSize {
        let visibleWidth = NSScreen.main?.visibleFrame.width ?? 1440
        // Never wider than the screen, never narrower than the content needs.
        // On a display too small for the full row the panel takes what it can
        // and the wide chips truncate (they are 999-priority) rather than
        // overlapping.
        let width = min(setupContentWidth, max(760, visibleWidth - 80))
        return NSSize(width: width, height: 66)
    }

    /// Setup panel sized to a MEASURED content width (the Record↔Screenshot
    /// modes need different rows, so the bar breathes to fit each) — same
    /// screen clamps as the default size.
    static func setupPanelSize(fittingContentWidth contentWidth: CGFloat) -> NSSize {
        let visibleWidth = NSScreen.main?.visibleFrame.width ?? 1440
        let width = min(contentWidth, max(760, visibleWidth - 80))
        return NSSize(width: width, height: 66)
    }

    /// Narrow in-recording toolbar: timer plus transport controls.
    static func recordingPanelSize() -> NSSize {
        NSSize(width: 560, height: 66)
    }
}

// MARK: - Flat panel surface

/// Flat, near-opaque surface for the recording bar — the Liquid Glass /
/// vibrancy material is gone (user call: "no glass, too crammed"; the new
/// look follows Screen Studio's recorder bar). Kept the name and the API
/// (`contentView`, `cornerRadius`, `tintColor`) so the eleven chip subclasses
/// stayed untouched; visually it is now just a layer-backed rounded rect
/// painted with EditorThemeKit colors.
class GlassCompatView: NSView {
    private let tintOverlay = NSView()
    private var themeObservation: CCThemeObservation?

    var contentView: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            guard let contentView else { return }
            contentView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(contentView)
            NSLayoutConstraint.activate([
                contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
                contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
                contentView.topAnchor.constraint(equalTo: topAnchor),
                contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
    }

    var cornerRadius: CGFloat = 0 {
        didSet {
            layer?.cornerRadius = cornerRadius
            tintOverlay.layer?.cornerRadius = cornerRadius
            if let layer { CCMaterial.refit(layer, radius: cornerRadius) }
        }
    }

    /// Base fill of the surface. `nil` = transparent (quiet chips).
    /// Skeuo: SOLID fills get the raised key material (shadow suppressed —
    /// packed bar chips must not smear cast shadows over each other).
    /// Translucent washes stay flat: a gradient/under-edge over a see-through
    /// fill renders as dirty smudges, not depth (Mike, 2026-09-01).
    var fillColor: NSColor? {
        didSet {
            layer?.backgroundColor = fillColor?.cgColor
            guard let layer else { return }
            if let fillColor, fillColor.alphaComponent > 0.6 {
                CCMaterial.dress(layer, as: .raised(tint: fillColor), radius: cornerRadius)
                CCMaterial.suppressShadow(layer)
            } else {
                CCMaterial.strip(layer)
            }
        }
    }

    /// Hairline stroke around the surface. `nil` = no border.
    var strokeColor: NSColor? {
        didSet {
            layer?.borderColor = strokeColor?.cgColor
            layer?.borderWidth = strokeColor == nil ? 0 : 1
        }
    }

    /// Selected-state wash overlay (kept for API compatibility).
    var tintColor: NSColor? {
        didSet { tintOverlay.layer?.backgroundColor = tintColor?.cgColor }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        tintOverlay.translatesAutoresizingMaskIntoConstraints = false
        tintOverlay.wantsLayer = true
        addSubview(tintOverlay)
        NSLayoutConstraint.activate([
            tintOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            tintOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            tintOverlay.topAnchor.constraint(equalTo: topAnchor),
            tintOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Re-fires the color didSets on theme change so fills painted through the
    /// `fillColor`/`strokeColor`/`tintColor` pattern re-resolve live. Colors
    /// COMPUTED from the theme (ink washes, selection tints) don't re-derive by
    /// re-assignment — subclasses with those override this and restyle.
    func applyTheme() {
        // Self-assignment deliberately re-triggers each didSet, re-snapshotting
        // the (possibly dynamic) NSColor into the layer for the new appearance.
        let fill = fillColor, stroke = strokeColor, tint = tintColor
        fillColor = fill
        strokeColor = stroke
        tintColor = tint
    }
}

// MARK: - Base chip

/// Capsule glass chip. Subclasses fill `body` (the glass content view) and
/// opt into click or menu behaviour. Hit testing is collapsed onto the chip
/// itself so labels/icons inside never swallow the click — every chip in the
/// SwiftUI original is a single `.buttonStyle(.plain)` target.
class RecordingGlassChip: GlassCompatView {
    let body = NSView()

    /// Mirrors SwiftUI `.disabled(...)`: no action, dimmed. The dim is a
    /// quick fade, never a hard cut — enable/disable reads as state settling,
    /// not a glitch. (A fade IS the reduce-motion form, so no branch needed;
    /// off-window changes apply instantly.)
    var isEnabled: Bool = true {
        didSet {
            let target: CGFloat = isEnabled ? 1 : 0.4
            guard window != nil, alphaValue != target else {
                alphaValue = target
                return
            }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = RecordingMotion.reduceMotion
                    ? RecordingMotion.reducedDuration : RecordingMotion.fadeDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().alphaValue = target
            }
        }
    }

    /// Hover reporting for the segment-pill overlay. Only chips that opt in
    /// (by setting this) get a tracking area.
    var onHoverChange: ((Bool) -> Void)? {
        didSet { updateTrackingAreas() }
    }
    private var hoverTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking {
            removeTrackingArea(hoverTracking)
            self.hoverTracking = nil
        }
        guard onHoverChange != nil else { return }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled, !isHidden else { return }
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // No fill at rest — controls are flat, background-less targets on the
        // bar surface (Screen Studio interior). Only primaries (Record) and
        // transient washes paint anything.
        contentView = body
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        // Small rounded rect, never a capsule — only visible on chips that
        // actually paint a fill (Record) or a wash.
        cornerRadius = min(RecordingPanelMetrics.tabRadius + 2, bounds.height / 2)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Hit testing is collapsed onto the chip so the label and icon inside
        // never swallow a click. Overriding this DROPS what NSView does by
        // default, and one of those defaults is load-bearing: a hidden view
        // must not be hit at all.
        //
        // Without this guard the chips the current tab hides — windowChip and
        // areaDisplayChip — kept absorbing clicks from wherever they last laid
        // out, which was on top of the Window and Area tabs. Those two tabs
        // were dead while iPhone worked, because nothing hidden happened to
        // overlap iPhone. Nothing logged; the click simply went to an invisible
        // view that does nothing when hidden.
        guard !isHidden, alphaValue > 0.01 else { return nil }
        guard let local = superview?.convert(point, to: self) else { return nil }
        return bounds.contains(local) ? self : nil
    }

    /// The two overrides that make a chip clickable inside THIS panel.
    ///
    /// `mouseDownCanMoveWindow` defaults to TRUE for a non-opaque view, and the
    /// recording panel sets `isMovableByWindowBackground = true` so it can be
    /// dragged around the screen. Together that means AppKit treats a press on
    /// a chip as the start of a window drag: the drag consumes the event
    /// sequence, the matching mouse-up never reaches the view, and every
    /// control in the panel silently does nothing. Nothing logs, nothing
    /// throws — the panel just moves a pixel or two instead of switching tab.
    ///
    /// `acceptsFirstMouse` matters for the same panel for a different reason:
    /// it is a `.nonactivatingPanel` floating over other apps, so a click
    /// arriving while it is not key would otherwise be swallowed activating the
    /// window, and the user would have to click twice.
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Geometry probe for the alignment gate.
    var debugBodyFrameInWindow: NSRect { body.convert(body.bounds, to: nil) }

    /// Pin a content stack inside the glass with the chip's standard
    /// horizontal padding and a fixed control height.
    func install(_ content: NSView, horizontalPadding: CGFloat, height: CGFloat = RecordingPanelMetrics.controlHeight) {
        content.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: horizontalPadding),
            content.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -horizontalPadding),
            content.centerYAnchor.constraint(equalTo: body.centerYAnchor),
            body.heightAnchor.constraint(equalToConstant: height),
        ])
    }

    static func label(_ text: String = "", font: NSFont, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.cell?.truncatesLastVisibleLine = true
        return field
    }

    /// Small state dot in the chip's top-right corner: accent = on, dim = off
    /// (Screen Studio-style quiet toggles). Lazy — chips without state stay
    /// dot-free.
    func setIndicator(on: Bool) {
        let color = (on ? RecordingPanelMetrics.accentOn : RecordingPanelMetrics.dotOff).cgColor
        let dotLayer = indicatorDot().layer
        guard dotLayer?.backgroundColor != color else { return }
        // Quick tint fade, never a pop.
        CATransaction.begin()
        CATransaction.setAnimationDuration(RecordingMotion.fadeDuration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        dotLayer?.backgroundColor = color
        CATransaction.commit()
    }

    private var indicator: NSView?
    private func indicatorDot() -> NSView {
        if let indicator { return indicator }
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 2.5
        dot.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(dot)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 5),
            dot.heightAnchor.constraint(equalToConstant: 5),
            dot.topAnchor.constraint(equalTo: body.topAnchor, constant: 7),
            dot.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -9),
        ])
        indicator = dot
        return dot
    }

    static func icon(_ symbol: String?, size: CGFloat, weight: NSFont.Weight = .medium, color: NSColor = .labelColor) -> NSImageView {
        let view = NSImageView()
        if let symbol {
            view.image = RecordingPanelMetrics.symbol(symbol, size: size, weight: weight)
        }
        view.contentTintColor = color
        view.imageScaling = .scaleNone
        // Fixed, EVEN frame height per point size. SF Symbol images come back
        // with per-glyph heights ("display" shorter than "iphone"), and a
        // centred stack then parks each chip's icon centre — and the label
        // under it — at a different y. An even fixed height keeps every icon
        // centre, and every label baseline, on the same line across chips
        // (asserted by `--panel-live-capture`'s alignment table).
        let frameHeight = (size + 3).rounded(.up) + ((size + 3).rounded(.up).truncatingRemainder(dividingBy: 2) == 0 ? 0 : 1)
        view.heightAnchor.constraint(equalToConstant: frameHeight).isActive = true
        return view
    }
}

/// Chip that fires a closure on click (`Button { … } label: { chip }`).
class RecordingButtonChip: RecordingGlassChip {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        // Swallow — the action fires on mouse-up inside, like a plain button.
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }
}

/// Chip that pops a freshly built NSMenu on press (`Menu { … } label: { chip }`).
/// The menu is rebuilt on every press so it always reflects live device lists,
/// exactly like the SwiftUI `Menu` content closure.
class RecordingMenuChip: RecordingGlassChip {
    var menuProvider: (() -> NSMenu)?

    /// Flat option-list spec for the house combobox popup. Chips whose menu
    /// is a plain pick-one list set `optionsProvider` instead of
    /// `menuProvider` and get the CCKit popup (CCComboboxPopup) — same
    /// surface as CCCombobox/CCSelect. Sectioned or stateful menus keep
    /// `menuProvider`.
    struct OptionList {
        var options: [CCCombobox.Option]
        var selectedIndex: Int?
        var searchable = false
        var emptyText = "No options"
        var onSelect: (Int) -> Void
    }

    var optionsProvider: (() -> OptionList)?

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if let list = optionsProvider?() {
            CCComboboxPopup.present(
                options: list.options,
                selectedIndex: list.selectedIndex,
                from: self,
                searchable: list.searchable,
                emptyText: list.emptyText,
                onSelect: list.onSelect
            )
            return
        }
        guard let menu = menuProvider?() else { return }
        CaptureCatMenuPresenter.show(menu, from: self, edge: .below)
    }

    override func mouseUp(with event: NSEvent) {}
}

// MARK: - Source tab

/// `VStack { icon; title }` inside a capsule, 84×42. The SwiftUI original
/// marks selection with `.regular.interactive()` glass; AppKit has no
/// interactive variant, so selection reads as a tint + the InspectorKit
/// selection outline (same accent used by the inspector's chip rows).
final class RecordingTabChip: RecordingButtonChip {
    private let iconView: NSImageView
    private let titleField: NSTextField

    var isSelected: Bool = false {
        didSet { restyle() }
    }

    /// When a `SegmentPillOverlay` draws the selection for a whole strip, the
    /// chip must stop drawing its own — otherwise selection appears twice and
    /// the per-chip version snaps while the pill glides.
    var usesExternalSelection: Bool = false {
        didSet { restyle() }
    }

    init(title: String, symbol: String, width: CGFloat = RecordingPanelMetrics.tabWidth) {
        // Screen Studio proportions: ~16pt icon stacked over a ~10pt label in
        // a near-square chip.
        iconView = RecordingGlassChip.icon(symbol, size: 15, weight: .medium)
        titleField = RecordingGlassChip.label(title, font: RecordingPanelMetrics.tabLabel())
        super.init()
        titleField.alignment = .center

        let stack = NSStackView(views: [iconView, titleField])
        stack.orientation = .vertical
        stack.spacing = 2
        stack.alignment = .centerX
        install(stack, horizontalPadding: 2)
        widthAnchor.constraint(equalToConstant: width).isActive = true
        restyle()
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = min(RecordingPanelMetrics.tabRadius, bounds.height / 2)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Alignment probe (`--panel-live-capture`): icon centre and label baseline
    /// in WINDOW coordinates, so the gate can assert every tab chip carries its
    /// glyph and caption on the same two horizontal lines.
    var debugIconCenterYInWindow: CGFloat {
        iconView.convert(iconView.bounds, to: nil).midY
    }
    var debugLabelBaselineYInWindow: CGFloat {
        let frame = titleField.convert(titleField.bounds, to: nil)
        return frame.maxY - titleField.firstBaselineOffsetFromTop
    }

    private func restyle() {
        // Selection reads as icon/label color: white when active, secondary at
        // rest. The subtle darker square behind the active tab is drawn by the
        // SegmentPillOverlay (or by tintColor when no overlay is attached) —
        // no outlines, no capsules.
        let content: NSColor = isSelected ? .labelColor : .secondaryLabelColor
        iconView.contentTintColor = content
        titleField.textColor = content
        layer?.borderWidth = 0
        tintColor = (isSelected && !usesExternalSelection)
            ? RecordingPanelMetrics.ink.withAlphaComponent(0.12) : nil
    }

    /// The selection wash is DERIVED from the theme, so re-derive it rather
    /// than re-firing a stale color.
    override func applyTheme() {
        super.applyTheme()
        restyle()
    }
}

// MARK: - Menu field ("menuChip")

/// `icon · title · ⌄` in a capsule — the SwiftUI `menuChip(icon:title:)`.
final class RecordingMenuFieldChip: RecordingMenuChip {
    private let iconView: NSImageView
    private let titleField: NSTextField

    init(symbol: String, title: String, width: CGFloat) {
        iconView = RecordingGlassChip.icon(symbol, size: 13, color: .secondaryLabelColor)
        titleField = RecordingGlassChip.label(title, font: RecordingPanelMetrics.toolbarText())
        super.init()

        let chevron = RecordingGlassChip.icon("chevron.down", size: 9, weight: .semibold, color: .secondaryLabelColor)
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [iconView, titleField, spacer, chevron])
        stack.orientation = .horizontal
        stack.spacing = RecordingPanelMetrics.controlSpacing
        stack.alignment = .centerY
        // Title gets the slack; the chevron stays pinned right.
        titleField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 4).isActive = true
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        install(stack, horizontalPadding: 10)
        // Not required: on a panel too narrow for the full toolbar the wide
        // chips give up width (labels truncate) rather than pushing the record
        // and close buttons off the panel edge.
        let widthConstraint = widthAnchor.constraint(equalToConstant: width)
        widthConstraint.priority = .init(999)
        widthConstraint.isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var title: String {
        get { titleField.stringValue }
        set { titleField.stringValue = newValue }
    }

    var symbolName: String = "" {
        didSet { iconView.image = RecordingPanelMetrics.symbol(symbolName, size: 13) }
    }

    /// Alignment probe (`--panel-live-capture`).
    var debugIconCenterYInWindow: CGFloat {
        iconView.convert(iconView.bounds, to: nil).midY
    }
    var debugLabelBaselineYInWindow: CGFloat {
        let frame = titleField.convert(titleField.bounds, to: nil)
        return frame.maxY - titleField.firstBaselineOffsetFromTop
    }
}

// MARK: - Labelled button ("toolbarChipLabel")

/// `icon · title` in a capsule with a minimum width — `toolbarChipLabel`.
final class RecordingLabelChip: RecordingButtonChip {
    private let iconView: NSImageView
    private let titleField: NSTextField

    init(title: String, symbol: String, minWidth: CGFloat) {
        iconView = RecordingGlassChip.icon(symbol, size: 13)
        titleField = RecordingGlassChip.label(title, font: RecordingPanelMetrics.toolbarText())
        super.init()

        let stack = NSStackView(views: [iconView, titleField])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        install(stack, horizontalPadding: 10)
        let minimum = widthAnchor.constraint(greaterThanOrEqualToConstant: minWidth)
        minimum.priority = .init(999)
        minimum.isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(title: String, symbol: String) {
        titleField.stringValue = title
        iconView.image = RecordingPanelMetrics.symbol(symbol, size: 13)
    }

    /// Alignment probe (`--panel-live-capture`).
    var debugIconCenterYInWindow: CGFloat {
        iconView.convert(iconView.bounds, to: nil).midY
    }
    var debugLabelBaselineYInWindow: CGFloat {
        let frame = titleField.convert(titleField.bounds, to: nil)
        return frame.maxY - titleField.firstBaselineOffsetFromTop
    }
}

// MARK: - Icon button ("toolbarIconChip")

/// Square 42×42 capsule holding a single symbol — `toolbarIconChip`.
final class RecordingIconChip: RecordingButtonChip {
    private let iconView: NSImageView

    /// `fill` promotes the chip to a primary action (accent-filled, like the
    /// Record button); `width` lets primaries be wider than the 44pt square.
    init(symbol: String, color: NSColor = .labelColor, fill: NSColor? = nil,
         width: CGFloat = RecordingPanelMetrics.controlHeight) {
        iconView = RecordingGlassChip.icon(symbol, size: 14, color: color)
        super.init()
        if let fill { fillColor = fill }
        install(iconView, horizontalPadding: 0)
        widthAnchor.constraint(equalToConstant: width).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setSymbol(_ symbol: String) {
        iconView.image = RecordingPanelMetrics.symbol(symbol, size: 14)
    }

    /// Recording heartbeat: the icon breathes (opacity 1 ⇄ 0.45 on the glide
    /// curve) while a recording is live — Apple's menu-bar record indicator
    /// feel. No-op re-calls; honors reduce-motion by staying solid.
    func setPulsing(_ pulsing: Bool) {
        let key = "capturecat.pulse"
        guard let layer = iconView.layer else { return }
        if pulsing, !RecordingMotion.reduceMotion {
            guard layer.animation(forKey: key) == nil else { return }
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.45
            pulse.duration = 0.8
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CCMotion.glide
            layer.add(pulse, forKey: key)
        } else {
            layer.removeAnimation(forKey: key)
        }
    }

    /// Alignment probe (`--panel-live-capture`).
    var debugIconCenterYInWindow: CGFloat {
        iconView.convert(iconView.bounds, to: nil).midY
    }
}

/// Same square capsule, but it pops a menu instead of firing a closure —
/// the mid-recording "switch source" control.
final class RecordingIconMenuChip: RecordingMenuChip {
    private let iconView: NSImageView

    init(symbol: String) {
        iconView = RecordingGlassChip.icon(symbol, size: 14)
        super.init()
        install(iconView, horizontalPadding: 0)
        widthAnchor.constraint(equalToConstant: RecordingPanelMetrics.controlHeight).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Alignment probe (`--recording-panel-shot`).
    var debugIconCenterYInWindow: CGFloat {
        iconView.convert(iconView.bounds, to: nil).midY
    }
}

// MARK: - Status chips

/// Red dot + elapsed timecode. With a duration limit active the timecode
/// counts DOWN ("-0:42") and a quiet suffix names the limit ("of 2:00").
final class RecordingTimerChip: RecordingGlassChip {
    private let dot = NSView()
    private let timeField: NSTextField
    private let limitField: NSTextField

    override init() {
        timeField = RecordingGlassChip.label("0:00", font: RecordingPanelMetrics.timer())
        limitField = RecordingGlassChip.label("", font: RecordingPanelMetrics.timer(), color: .secondaryLabelColor)
        limitField.isHidden = true
        super.init()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
        ])

        let stack = NSStackView(views: [dot, timeField, limitField])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.setCustomSpacing(5, after: timeField)
        stack.alignment = .centerY
        install(stack, horizontalPadding: 12)
        applyTheme() // base observation fired before `dot` was styled
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func applyTheme() {
        super.applyTheme()
        // systemRed is dynamic — re-snapshot it for the new appearance.
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
    }

    func update(text: String, live: Bool, color: NSColor = .labelColor, limitText: String? = nil) {
        timeField.stringValue = text
        timeField.textColor = color
        limitField.stringValue = limitText.map { "of \($0)" } ?? ""
        limitField.isHidden = limitText == nil
        // Pause/resume dims the dot with a fade rather than a snap.
        let target: CGFloat = live ? 1 : 0.3
        guard dot.alphaValue != target else { return }
        guard window != nil else {
            dot.alphaValue = target
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = RecordingMotion.reduceMotion
                ? RecordingMotion.reducedDuration : RecordingMotion.fadeDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            dot.animator().alphaValue = target
        }
    }
}

/// "what is being captured right now" — icon + truncating source name.
final class RecordingSourceChip: RecordingGlassChip {
    private let iconView: NSImageView
    private let nameField: NSTextField

    override init() {
        iconView = RecordingGlassChip.icon("display", size: 11, weight: .semibold, color: .secondaryLabelColor)
        nameField = RecordingGlassChip.label("", font: RecordingPanelMetrics.sourceLabel())
        super.init()

        let stack = NSStackView(views: [iconView, nameField])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        install(stack, horizontalPadding: 10)
        nameField.widthAnchor.constraint(lessThanOrEqualToConstant: 150).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(label: String, isDevice: Bool) {
        nameField.stringValue = label
        iconView.image = RecordingPanelMetrics.symbol(isDevice ? "iphone" : "display", size: 11, weight: .semibold)
        toolTip = "Currently recording: \(label)"
    }
}

/// Maximum-duration picker for the setup row. A quiet timer glyph when no
/// limit is set; glyph + the active limit ("2 min") when one is. Pops the
/// preset menu on press (RecordingMenuChip), flat like every other control —
/// no fill, no capsule, just an icon/label target on the bar surface.
final class RecordingLimitChip: RecordingMenuChip {
    private let iconView: NSImageView
    private let valueField: NSTextField

    /// Recorded-time cap in seconds; 0 or nil = no limit.
    var limit: TimeInterval? {
        didSet { restyle() }
    }

    override init() {
        iconView = RecordingGlassChip.icon("timer", size: 13, color: .secondaryLabelColor)
        valueField = RecordingGlassChip.label("", font: RecordingPanelMetrics.toolbarText())
        super.init()

        let stack = NSStackView(views: [iconView, valueField])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        install(stack, horizontalPadding: 10)
        // Icon-only square when off; grows to fit the label when a limit is on.
        let minimum = widthAnchor.constraint(greaterThanOrEqualToConstant: 40)
        minimum.priority = .init(999)
        minimum.isActive = true
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Alignment probe (`--panel-live-capture`).
    var debugIconCenterYInWindow: CGFloat {
        iconView.convert(iconView.bounds, to: nil).midY
    }

    /// "15s" / "2 min" / "1:30" — short label for a limit in seconds.
    static func label(forLimit seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        if whole < 60 { return "\(whole)s" }
        if whole % 60 == 0 { return "\(whole / 60) min" }
        return TimeInterval(whole).formattedTimecode
    }

    private func restyle() {
        let active = (limit ?? 0) > 0
        valueField.stringValue = active ? Self.label(forLimit: limit!) : ""
        valueField.isHidden = !active
        iconView.contentTintColor = active ? .labelColor : .secondaryLabelColor
        setIndicator(on: active)
        toolTip = active
            ? "Recording stops automatically after \(Self.label(forLimit: limit!))."
            : "Set a maximum recording duration."
    }
}

/// Spinner shown while ScreenCaptureKit sources load.
final class RecordingSpinnerChip: RecordingGlassChip {
    private let spinner = CCSpinner()

    override init() {
        super.init()
        // Fixed 16pt disc centred in the capsule — pinning its edges would
        // stretch the indicator across the chip.
        spinner.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16),
            spinner.centerXAnchor.constraint(equalTo: body.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: body.centerYAnchor),
            body.widthAnchor.constraint(equalTo: spinner.widthAnchor, constant: 24),
            body.heightAnchor.constraint(equalToConstant: RecordingPanelMetrics.controlHeight),
        ])
        spinner.startAnimation(nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setSpinning(_ spinning: Bool) {
        spinning ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
    }
}

// MARK: - Separator

/// The toolbar's 1×24 hairline between source and device controls.
final class RecordingSeparator: NSView {
    private var themeObservation: CCThemeObservation?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        themeObservation = CCThemeObservation { [weak self] in
            self?.layer?.backgroundColor = RecordingPanelMetrics.ink.withAlphaComponent(0.10).cgColor
        }
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 1),
            heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}


// MARK: - URL field

/// Editable URL chip for the `URL` source tab.
///
/// A chip that must accept TYPING, which is a different animal from the rest of
/// the kit: `RecordingGlassChip.hitTest` deliberately collapses hit testing onto
/// the chip so labels and icons never swallow a click. That is exactly wrong
/// here — the text field has to receive the click to get focus — so this
/// subclass restores normal hit testing for its own field.
final class RecordingURLFieldChip: RecordingGlassChip, NSTextFieldDelegate {
    /// Fired on Return with a non-empty value.
    var onSubmit: ((String) -> Void)?

    private let field = NSTextField(string: "")
    private let iconView: NSImageView

    init(width: CGFloat) {
        iconView = RecordingGlassChip.icon("link", size: 13, color: .secondaryLabelColor)
        super.init()

        field.placeholderString = "example.com"
        field.font = RecordingPanelMetrics.toolbarText()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.delegate = self
        field.cell?.sendsActionOnEndEditing = false

        let go = RecordingGlassChip.icon("arrow.right.circle.fill", size: 14, color: .secondaryLabelColor)

        let stack = NSStackView(views: [iconView, field, go])
        stack.orientation = .horizontal
        stack.spacing = RecordingPanelMetrics.controlSpacing
        stack.alignment = .centerY
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        install(stack, horizontalPadding: 12)
        let w = widthAnchor.constraint(equalToConstant: width)
        w.priority = .init(999)
        w.isActive = true
    }

    /// Restores default hit testing so the text field can take focus. The base
    /// class returns `self` for every point, which would make the field
    /// unfocusable and the chip untypeable.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.01 else { return nil }
        return super.hitTest(point).flatMap { _ in
            guard let local = superview?.convert(point, to: self) else { return nil }
            return bounds.contains(local) ? (body.hitTest(convert(local, to: body)) ?? self) : nil
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var stringValue: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    /// Disabling must also stop TYPING, not just dim: the base dim leaves the
    /// field editable, and a mid-capture edit would race the in-flight URL.
    override var isEnabled: Bool {
        didSet {
            field.isEnabled = isEnabled
            if !isEnabled, field.currentEditor() != nil {
                window?.makeFirstResponder(nil)
            }
        }
    }

    /// Quiet inline failure, house style: a red hairline on the chip plus the
    /// message as a tooltip. No NSAlert — a bad URL is a small, local mistake.
    func setError(_ message: String?) {
        strokeColor = message == nil ? nil : NSColor.systemRed.withAlphaComponent(0.6)
        toolTip = message
    }

    func focus() {
        window?.makeFirstResponder(field)
    }

    /// Alignment probe (`--panel-live-capture`).
    var debugIconCenterYInWindow: CGFloat {
        iconView.convert(iconView.bounds, to: nil).midY
    }
    var debugLabelBaselineYInWindow: CGFloat {
        let frame = field.convert(field.bounds, to: nil)
        return frame.maxY - field.firstBaselineOffsetFromTop
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // Deliberately does NOT submit: losing focus is not a confirmation, and
        // firing here would capture a half-typed address the moment the user
        // clicked anywhere else in the panel.
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        let raw = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return true }
        onSubmit?(raw)
        return true
    }
}


// MARK: - Capture mode switch

/// What the panel is set up to produce.
///
/// Not folded into `RecordingSourceTab`: the source (display / window / area /
/// iPhone / URL) and the OUTPUT (a movie or a still) are independent choices,
/// and most sources support both. Combining them would mean a tab per pair.
enum CaptureMode: String, CaseIterable {
    case record = "Record"
    case screenshot = "Screenshot"

    var icon: String {
        switch self {
        case .record: return "record.circle"
        case .screenshot: return "camera"
        }
    }
}

/// Two-up mode switch that reads as one control.
///
/// Built from `RecordingTabChip`s rather than `NSSegmentedControl` because the
/// panel has a deliberate flat design language and stock AppKit chrome breaks
/// it (CLAUDE.md §1).
final class RecordingModeSwitch: NSView {
    /// A mode change is requested before this control commits its visual
    /// selection. The panel uses that boundary to snapshot the WHOLE old row;
    /// committing first captured a new “Screenshot” segment beside old record
    /// controls during the crossfade.
    var onChange: ((CaptureMode) -> Void)?

    private var chips: [CaptureMode: RecordingTabChip] = [:]
    private let pill = SegmentPillOverlay()
    private let stack = NSStackView()

    var mode: CaptureMode = .record {
        didSet {
            guard mode != oldValue else { return }
            restyle()
            syncPill(animated: true)
        }
    }

    init() {
        super.init(frame: .zero)
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false

        for m in CaptureMode.allCases {
            // "Screenshot" needs more room than the 52pt source tabs.
            let chip = RecordingTabChip(title: m.rawValue, symbol: m.icon, width: 66)
            chip.usesExternalSelection = true
            chip.onClick = { [weak self] in
                guard let self, self.mode != m else { return }
                self.onChange?(m)
            }
            chip.onHoverChange = { [weak self, weak chip] inside in
                guard let self, let chip else { return }
                self.pill.setHover(frame: inside ? self.convert(chip.bounds, from: chip) : nil)
            }
            chips[m] = chip
            stack.addArrangedSubview(chip)
        }

        addSubview(stack)
        addSubview(pill) // above the chips; never hit-tested
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            pill.leadingAnchor.constraint(equalTo: leadingAnchor),
            pill.trailingAnchor.constraint(equalTo: trailingAnchor),
            pill.topAnchor.constraint(equalTo: topAnchor),
            pill.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Exposed for the panel harness's click gate.
    var debugChips: [CaptureMode: RecordingTabChip] { chips }

    override func layout() {
        super.layout()
        // Keep the pill glued to the selected chip through re-layouts without
        // interrupting an in-flight glide. `layout()` runs before the stack
        // positions its chips, so force the children current first — syncing
        // against stale chip frames left the pill stranded at the edge.
        stack.layoutSubtreeIfNeeded()
        if let chip = chips[mode] {
            pill.syncIfNeeded(frame: convert(chip.bounds, from: chip))
        }
    }

    private func syncPill(animated: Bool) {
        guard let chip = chips[mode] else { return }
        pill.setSelection(frame: convert(chip.bounds, from: chip), animated: animated)
    }

    private func restyle() {
        for (m, chip) in chips { chip.isSelected = m == mode }
    }
}
