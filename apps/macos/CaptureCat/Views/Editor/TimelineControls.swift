import AppKit

// The timeline toolbar's icon button and its rich picker menus. The pickers
// render on the shared CCKit menu surface (DesignKit/CCMenu.swift) — the same
// one every context menu and combobox uses.

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
        imageView.image = CCIcon.image(icon, pointSize: pointSize, weight: .semibold)
        imageView.contentTintColor = tint ?? EditorThemeKit.textPrimary
    }

    /// 2026 look (replaces the 2026-09-01 raised keys): toolbar icons are
    /// GHOST buttons — no surface at rest, a flat soft wash on hover, and a
    /// floating chip when active. The press is CCMaterial.press (tint in
    /// place), never a re-dress.
    private func refreshFill() {
        guard let layer else { return }
        let ink: NSColor = CCTheme.isDark ? .white : .black
        if isActive {
            CCMaterial.dress(layer, as: .raised(tint: EditorThemeKit.activeFill), radius: EditorThemeKit.controlRadius)
        } else if isHovering && isEnabled {
            let wash = EditorThemeKit.panelElevated.blended(withFraction: 0.06, of: ink) ?? EditorThemeKit.panelElevated
            CCMaterial.dress(layer, as: .recessed(tint: wash), radius: EditorThemeKit.controlRadius)
        } else {
            CCMaterial.strip(layer)
            layer.backgroundColor = NSColor.clear.cgColor
        }
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

// MARK: - Picker popover

/// The timeline's rich pickers (annotation / effects / focus): the house menu
/// surface (CCMenuStage + CCMenuList, see DesignKit/CCMenu.swift) with RICH
/// rows — an icon tile, a title and a description that wraps (never
/// truncates) — grouped into sections. A section whose rows are ALL
/// unavailable says why in one caption under its header instead of showing
/// a stack of dead rows.
@MainActor
enum TimelinePickerPopover {
    struct Row {
        let icon: String
        let title: String
        let detail: String
        var isEnabled = true
        /// Replaces `detail` while the row is disabled — the reason it is.
        var disabledDetail: String? = nil
        let action: () -> Void
    }

    struct Section {
        /// Sentence-case header; nil for an unheaded group.
        var title: String?
        var rows: [Row]
        /// Shown under the header when EVERY row in the section is disabled.
        var disabledCaption: String? = nil
    }

    static func make(rows: [Row]) -> CaptureCatPopover {
        make(sections: [Section(title: nil, rows: rows)])
    }

    static func make(sections: [Section]) -> CaptureCatPopover {
        let popover = CaptureCatPopover()
        let list = CCMenuList()
        var actions: [ObjectIdentifier: () -> Void] = [:]
        for (index, section) in sections.enumerated() where !section.rows.isEmpty {
            if index > 0 { list.addSeparator() }
            let allDisabled = section.rows.allSatisfy { !$0.isEnabled }
            if let title = section.title {
                list.addHeader(title, caption: allDisabled ? section.disabledCaption : nil)
            }
            for row in section.rows {
                let detail = row.isEnabled ? row.detail : (row.disabledDetail ?? row.detail)
                let view = CCMenuRow(.init(style: .rich, icon: .named(row.icon), title: row.title,
                                           detail: detail, isEnabled: row.isEnabled))
                list.add(view)
                actions[ObjectIdentifier(view)] = row.action
            }
        }
        list.onActivate = { [weak popover] row in
            guard let action = actions[ObjectIdentifier(row)] else { return }
            popover?.commit(row, action: action)
        }

        let width = list.fittingWidth()
        list.layoutEntries(width: width)
        // Full height here; CaptureCatPopover caps it to the screen (and
        // turns the scroller on) at show time.
        let scroll = list.embedInScrollView(visibleHeight: list.frame.height)
        let controller = NSViewController()
        controller.view = scroll
        popover.contentViewController = controller
        popover.contentSize = list.frame.size
        return popover
    }
}
