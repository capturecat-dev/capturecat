import AppKit

// AppKit twins of the timeline's SwiftUI chrome. Both are ports of controls
// that had no equivalent in InspectorKit: `InspectorButton` is a text button
// with the wrong idle fill, and `NSMenu` cannot render the picker rows' two-line
// icon + title + description layout without custom item views anyway.

// MARK: - Toolbar icon button

/// 32×30 icon button — port of the SwiftUI `TimelineToolbarButton`: same size,
/// same `controlRadius` fill, same hover/active washes, same 0.35 disabled
/// alpha and the same 0.1s ease-out on both state changes.
final class TimelineToolbarButton: NSControl {
    // Every setter guards on equality: these are driven from the playback
    // observation loop, which fires per time-observer tick (~60Hz), and
    // rebuilding an NSImage symbol on every tick is pure waste.
    var icon: String {
        didSet { if icon != oldValue { refreshImage() } }
    }
    var pointSize: CGFloat {
        didSet { if pointSize != oldValue { refreshImage() } }
    }
    /// Non-nil overrides the symbol colour (red for destructive, cyan for the
    /// armed slice tool).
    var tint: NSColor? {
        didSet { if tint != oldValue { refreshImage() } }
    }
    var isActive = false {
        didSet { if isActive != oldValue { refreshFill() } }
    }
    override var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            alphaValue = isEnabled ? 1 : 0.35
            if !isEnabled { isHovering = false }
            refreshFill()
        }
    }

    private let imageView = NSImageView()
    private var isHovering = false { didSet { if isHovering != oldValue { refreshFill() } } }
    private var trackingArea: NSTrackingArea?
    private var themeObservation: CCThemeObservation?
    private let onClick: () -> Void
    /// When set, the hover wash is the container's gliding highlight instead
    /// of this button's own layer (active state stays local).
    var onHighlight: ((TimelineToolbarButton, Bool) -> Void)?

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 32, height: 30) }

    init(icon: String, pointSize: CGFloat = 14, tint: NSColor? = nil, action: @escaping () -> Void) {
        self.icon = icon
        self.pointSize = pointSize
        self.tint = tint
        self.onClick = action
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = EditorThemeKit.controlRadius
        layer?.cornerCurve = .continuous
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        // Fires once now (covering the initial refreshImage/refreshFill pass)
        // and again on every theme flip — a settled button never re-runs its
        // refreshes otherwise.
        themeObservation = CCThemeObservation { [weak self] in
            self?.refreshImage()
            self?.refreshFill()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func refreshImage() {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        let image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        imageView.image = image
        imageView.contentTintColor = tint ?? EditorThemeKit.textPrimary
    }

    /// Every toolbar icon is a raised CCMaterial key (kit-wide skeuomorphism,
    /// 2026-09-01) — rest on the elevated panel tint, hover lifts the tint
    /// toward the ink, active takes the selection fill. The press is
    /// CCMaterial.press (tint in place), never a re-dress.
    private func refreshFill() {
        guard let layer else { return }
        let ink: NSColor = CCTheme.isDark ? .white : .black
        let tint: NSColor
        if isActive {
            tint = EditorThemeKit.activeFill
        } else if isHovering && isEnabled {
            tint = EditorThemeKit.panelElevated.blended(withFraction: 0.08, of: ink) ?? EditorThemeKit.panelElevated
        } else {
            tint = EditorThemeKit.panelElevated
        }
        CCMaterial.dress(layer, as: .raised(tint: tint), radius: EditorThemeKit.controlRadius)
        // Packed bar: fifteen keys 4pt apart — cast shadows would smear
        // into one another, so the keys stand on their under-edge alone.
        CCMaterial.suppressShadow(layer)
    }

    override func layout() {
        super.layout()
        if let layer { CCMaterial.refit(layer, radius: EditorThemeKit.controlRadius) }
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
        if CCHoverPoller.debug {
            NSLog("Toolbar mouseEntered icon=%@ enabled=%d hasOnHighlight=%d",
                  icon, isEnabled ? 1 : 0, onHighlight != nil ? 1 : 0)
        }
        isHovering = isEnabled
    }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let layer else { return }
        CCMaterial.press(layer, down: true)
    }

    override func mouseUp(with event: NSEvent) {
        if let layer { CCMaterial.press(layer, down: false) }
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick()
    }
}

// MARK: - Picker popover row

/// Port of the SwiftUI `AnnotationPickerItem`: a 28×28 icon chip, a bold title
/// and a description line, with the icon chip and the whole row taking separate
/// hover washes.
final class TimelinePickerRow: NSControl {
    private let iconView = NSImageView()
    private let iconChip = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let onClick: () -> Void
    private var themeObservation: CCThemeObservation?
    /// Reports hover intent to the container's gliding wash.
    var onHighlight: ((TimelinePickerRow, Bool) -> Void)?

    private var isHovering = false {
        didSet { refresh() }
    }

    override var isFlipped: Bool { true }

    init(icon: String, title: String, detail: String, action: @escaping () -> Void) {
        self.onClick = action
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = EditorThemeKit.controlRadius
        layer?.cornerCurve = .continuous

        iconChip.wantsLayer = true
        iconChip.layer?.cornerRadius = EditorThemeKit.controlRadius
        iconChip.layer?.cornerCurve = .continuous
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        let image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        iconView.image = image
        iconView.imageScaling = .scaleProportionallyDown

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        detailLabel.stringValue = detail
        detailLabel.font = .systemFont(ofSize: 11)

        for v in [iconChip, iconView, titleLabel, detailLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            iconChip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconChip.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconChip.widthAnchor.constraint(equalToConstant: 28),
            iconChip.heightAnchor.constraint(equalToConstant: 28),
            iconView.centerXAnchor.constraint(equalTo: iconChip.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconChip.centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: iconChip.trailingAnchor, constant: 10),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            detailLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])
        // Covers the initial refresh() too — fires once immediately.
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isEnabled: Bool {
        didSet {
            alphaValue = isEnabled ? 1 : 0.4
            if !isEnabled { isHovering = false }
        }
    }

    private func applyTheme() {
        titleLabel.textColor = EditorThemeKit.textPrimary
        detailLabel.textColor = EditorThemeKit.textSecondary
        refresh()
    }

    private func refresh() {
        let on = isHovering && isEnabled
        // The row wash itself glides via the container's CCGlideHighlight.
        onHighlight?(self, on)
        iconChip.layer?.backgroundColor = (on ? EditorThemeKit.activeFill : .clear).cgColor
        iconView.contentTintColor = on ? EditorThemeKit.textPrimary : EditorThemeKit.textSecondary
    }

    /// Hover is DISPATCHED by the popover's PickerHoverContainer — rows own
    /// no tracking areas. (Their old .activeInKeyWindow areas never fired at
    /// all: CaptureCatPopover's panel is non-activating and never becomes key.)
    func setHovered(_ hovered: Bool) {
        isHovering = hovered && isEnabled
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick()
    }
}

/// Hover dispatcher for the picker popover — ONE .activeAlways tracking area
/// on the container, hit-testing rows per mouse move. Per-row areas proved
/// unreliable in borderless child panels (and .activeInKeyWindow never fires
/// in a non-activating panel at all); this mirrors CaptureCatMenuContentView.
@MainActor
private final class PickerHoverContainer: NSView, CaptureCatHoverRoutable {
    var rowsProvider: () -> [TimelinePickerRow] = { [] }

    private var hoverArea: NSTrackingArea?
    private weak var hoveredRow: TimelinePickerRow?
    private var themeObservation: CCThemeObservation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        themeObservation = CCThemeObservation { [weak self] in
            self?.layer?.backgroundColor = EditorThemeKit.panel.cgColor
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverArea = area
    }

    func routeHover(windowPoint: NSPoint) {
        let point = convert(windowPoint, from: nil)
        // Gap-tolerant: rows claim half the inter-row spacing so the wash
        // glides across gaps instead of clearing and re-appearing.
        let target = rowsProvider().first {
            !$0.frame.isEmpty && convert($0.bounds, from: $0).insetBy(dx: 0, dy: -1).contains(point)
        }
        guard target !== hoveredRow else { return }
        hoveredRow?.setHovered(false)
        hoveredRow = target
        target?.setHovered(true)
    }

    func clearHover() {
        hoveredRow?.setHovered(false)
        hoveredRow = nil
    }

    override func mouseEntered(with event: NSEvent) { routeHover(windowPoint: event.locationInWindow) }
    override func mouseMoved(with event: NSEvent) { routeHover(windowPoint: event.locationInWindow) }
    override func mouseExited(with event: NSEvent) {
        hoveredRow?.setHovered(false)
        hoveredRow = nil
    }
}

// MARK: - Picker popover

/// The three toolbar popovers (annotation / zoom / focus) share this container:
/// a fixed-width stack of `TimelinePickerRow`s on the panel colour, 6pt inset.
@MainActor
enum TimelinePickerPopover {
    struct Row {
        let icon: String
        let title: String
        let detail: String
        var isEnabled = true
        let action: () -> Void
    }

    static func make(width: CGFloat, rows: [Row]) -> CaptureCatPopover {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let popover = CaptureCatPopover()
        for row in rows {
            let control = TimelinePickerRow(
                icon: row.icon, title: row.title, detail: row.detail,
                action: { [weak popover] in
                    row.action()
                    popover?.close()
                }
            )
            control.isEnabled = row.isEnabled
            control.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(control)
            control.widthAnchor.constraint(equalToConstant: width - 12).isActive = true
        }

        let container = PickerHoverContainer()
        // Background is themed by the container's own CCThemeObservation.
        // Same gliding hover wash as the menus — one design language.
        let glide = CCGlideHighlight(host: container)
        for case let row as TimelinePickerRow in stack.arrangedSubviews {
            row.onHighlight = { row, active in glide.update(row: row, active: active) }
        }
        container.rowsProvider = { [weak stack] in
            (stack?.arrangedSubviews ?? []).compactMap { $0 as? TimelinePickerRow }
        }
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let controller = NSViewController()
        controller.view = container
        container.layoutSubtreeIfNeeded()
        let height = stack.fittingSize.height
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: width, height: height)
        return popover
    }
}
