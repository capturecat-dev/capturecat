import AppKit

/// CCKit tooltip — shadcn's Tooltip for ANY view:
///
///     CCTooltip.attach(to: exportButton, text: "Export", shortcut: "⌘E")
///     CCTooltip.attach(to: gear, text: "Settings", placement: .bottom)
///     CCTooltip.detach(from: exportButton)
///
/// Behavior:
///  • Appears after a ~0.5s hover; once one tooltip is up (or was up a
///    moment ago) moving onto another tooltipped view hands off INSTANTLY.
///  • Scale-in entrance pivoting on the edge that faces the target (it grows
///    out of what it describes) + fade.
///  • Smart placement: the preferred side flips when it would leave the
///    window's content area; the cross axis clamps inside it.
///  • Dismisses on pointer exit, any click, key press, or the target leaving
///    its window.
///
/// Implementation choice: the bubble floats in a borderless CHILD PANEL
/// (like the combobox popup) so it is never clipped by scroll views or
/// covered by sibling views/child windows. The panel ignores the mouse and
/// holds nothing hover-driven; the hover that matters — "is the pointer
/// still over the target?" — is POLLED (CCHoverPoller, 30 Hz) while a
/// tooltip is pending or shown, because tracking-area exits are exactly
/// what drop out around floating child panels. The target's tracking area
/// only STARTS the hover (in-window, where tracking areas are reliable).
@MainActor
final class CCTooltip: NSObject {
    enum Placement {
        case top
        case bottom
        case leading
        case trailing

        var opposite: Placement {
            switch self {
            case .top: return .bottom
            case .bottom: return .top
            case .leading: return .trailing
            case .trailing: return .leading
            }
        }
    }

    /// Hover delay before the first tooltip shows.
    static let delay: TimeInterval = 0.5
    /// A new target within this window after a tooltip hid shows instantly.
    static let handOffWindow: TimeInterval = 0.4
    /// Gap between the target and the bubble.
    static let gap: CGFloat = 6

    var text: String { didSet { bubble.setText(text, shortcut: shortcut) } }
    var shortcut: String? { didSet { bubble.setText(text, shortcut: shortcut) } }
    var placement: Placement

    private weak var target: NSView?
    private var trackingArea: NSTrackingArea?
    private let bubble = CCTooltipBubble()
    private let panel: NSPanel
    private var pending: DispatchWorkItem?
    private var poller: CCHoverPoller?
    private var clickMonitor: Any?
    private(set) var isShown = false
    private(set) var resolvedPlacement: Placement = .top

    /// The tooltip on screen right now (at most one app-wide).
    private static weak var visible: CCTooltip?
    private static var lastHiddenAt: CFTimeInterval = 0
    private static var associationKey: UInt8 = 0

    // MARK: - Attach / detach

    @discardableResult
    static func attach(to view: NSView, text: String, shortcut: String? = nil,
                       placement: Placement = .top) -> CCTooltip {
        detach(from: view)
        let tooltip = CCTooltip(target: view, text: text, shortcut: shortcut, placement: placement)
        // The view owns its tooltip (tracking areas don't retain owners).
        objc_setAssociatedObject(view, &associationKey, tooltip, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return tooltip
    }

    static func detach(from view: NSView) {
        guard let existing = tooltip(for: view) else { return }
        existing.hide(animated: false)
        if let area = existing.trackingArea { view.removeTrackingArea(area) }
        objc_setAssociatedObject(view, &associationKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    static func tooltip(for view: NSView) -> CCTooltip? {
        objc_getAssociatedObject(view, &associationKey) as? CCTooltip
    }

    private init(target: NSView, text: String, shortcut: String?, placement: Placement) {
        self.target = target
        self.text = text
        self.shortcut = shortcut
        self.placement = placement
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.hidesOnDeactivate = true
        let content = CCTooltipContent()
        content.wantsLayer = true
        panel.contentView = content
        bubble.translatesAutoresizingMaskIntoConstraints = true
        content.addSubview(bubble)
        bubble.setText(text, shortcut: shortcut)

        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        )
        target.addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - Hover entry points (tracking area → poller)

    @objc func mouseEntered(with event: NSEvent) { hoverBegan() }
    @objc func mouseExited(with event: NSEvent) { if !pointerOverTarget() { cancelOrHide() } }

    /// The pointer arrived on the target: show after the delay — or at once
    /// when another tooltip is up / just went down (hand-off).
    func hoverBegan() {
        guard !isShown, target?.window != nil else { return }
        let now = CACurrentMediaTime()
        let handOff = Self.visible != nil || now - Self.lastHiddenAt < Self.handOffWindow
        pending?.cancel()
        startPolling()
        if handOff {
            show(handOff: true)
        } else {
            let work = DispatchWorkItem { [weak self] in self?.show(handOff: false) }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
        }
    }

    private func cancelOrHide() {
        pending?.cancel()
        pending = nil
        if isShown { hide(animated: true) } else { stopPolling() }
    }

    private func pointerOverTarget() -> Bool {
        guard let target, let window = target.window, window.isVisible else { return false }
        let rect = window.convertToScreen(target.convert(target.visibleRect, to: nil))
        return rect.contains(NSEvent.mouseLocation)
    }

    private func startPolling() {
        guard poller == nil else { return }
        poller = CCHoverPoller { [weak self] in
            guard let self else { return }
            if !self.pointerOverTarget() { self.cancelOrHide() }
        }
    }

    private func stopPolling() {
        poller?.stop()
        poller = nil
    }

    // MARK: - Show / hide

    /// Present now. `handOff` skips nothing visually — the same entrance —
    /// but it is what makes the hop between adjacent targets instant.
    /// `tracking: false` (harness seam) presents without the pointer poller
    /// and dismiss monitors, so the user's real cursor can't end a probe.
    func show(handOff: Bool = false, tracking: Bool = true) {
        guard !isShown, let target, let window = target.window else { return }
        pending = nil
        if let other = Self.visible, other !== self { other.hide(animated: false) }
        isShown = true
        Self.visible = self

        let size = bubble.fittingSize
        let margin = CCTooltipContent.margin
        let (frameInWindow, side) = placementFrame(size: size, in: window)
        resolvedPlacement = side
        let screenRect = window.convertToScreen(frameInWindow)
        panel.setFrame(screenRect.insetBy(dx: -margin, dy: -margin), display: false)
        bubble.frame = NSRect(x: margin, y: margin, width: size.width, height: size.height)
        panel.level = window.level
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        bubble.layoutSubtreeIfNeeded()
        bubble.playEntrance(from: side)

        guard tracking else { return }
        startPolling()
        clickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]
        ) { [weak self] event in
            self?.hide(animated: true)
            return event
        }
    }

    func hide(animated: Bool) {
        pending?.cancel()
        pending = nil
        stopPolling()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        guard isShown else { return }
        isShown = false
        if Self.visible === self {
            Self.visible = nil
            Self.lastHiddenAt = CACurrentMediaTime()
        }
        let panel = self.panel
        let finish = { [weak self] in
            guard self?.isShown != true else { return }
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        if animated {
            bubble.playExit()
            DispatchQueue.main.asyncAfter(deadline: .now() + CCMotion.paced(0.12)) { finish() }
        } else {
            finish()
        }
    }

    /// Bubble frame in WINDOW coordinates: the preferred side, flipped to
    /// the opposite side when it would leave the content area, then clamped
    /// along the cross axis.
    private func placementFrame(size: NSSize, in window: NSWindow) -> (NSRect, Placement) {
        guard let target, let content = window.contentView else { return (.zero, placement) }
        let anchor = target.convert(target.bounds, to: nil)
        let area = content.convert(content.bounds, to: nil).insetBy(dx: 4, dy: 4)
        func frame(_ side: Placement) -> NSRect {
            switch side {
            case .top:
                return NSRect(x: anchor.midX - size.width / 2, y: anchor.maxY + Self.gap,
                              width: size.width, height: size.height)
            case .bottom:
                return NSRect(x: anchor.midX - size.width / 2, y: anchor.minY - Self.gap - size.height,
                              width: size.width, height: size.height)
            case .leading:
                return NSRect(x: anchor.minX - Self.gap - size.width, y: anchor.midY - size.height / 2,
                              width: size.width, height: size.height)
            case .trailing:
                return NSRect(x: anchor.maxX + Self.gap, y: anchor.midY - size.height / 2,
                              width: size.width, height: size.height)
            }
        }
        func fits(_ rect: NSRect, _ side: Placement) -> Bool {
            switch side {
            case .top: return rect.maxY <= area.maxY
            case .bottom: return rect.minY >= area.minY
            case .leading: return rect.minX >= area.minX
            case .trailing: return rect.maxX <= area.maxX
            }
        }
        var side = placement
        var rect = frame(side)
        if !fits(rect, side), fits(frame(side.opposite), side.opposite) {
            side = side.opposite
            rect = frame(side)
        }
        // Clamp the cross axis inside the content area.
        switch side {
        case .top, .bottom:
            rect.origin.x = min(max(rect.minX, area.minX), max(area.minX, area.maxX - rect.width))
        case .leading, .trailing:
            rect.origin.y = min(max(rect.minY, area.minY), max(area.minY, area.maxY - rect.height))
        }
        return (rect.integral, side)
    }

    // MARK: - Harness seams

    var probeBubbleLayer: CALayer? { bubble.layer }
    var probeSurfaceLayer: CALayer? { bubble.layer }
    var probePanel: NSPanel { panel }
    var probeBubbleView: NSView { bubble }
}

// MARK: - Panel content + bubble

/// Unflipped host with room around the bubble for its soft shadow.
private final class CCTooltipContent: NSView {
    static let margin: CGFloat = 10
}

@MainActor
private final class CCTooltipBubble: NSView {
    private let textField = NSTextField(labelWithString: "")
    private let shortcutField = NSTextField(labelWithString: "")
    private var themeObservation: CCThemeObservation?

    static let padding = NSSize(width: 9, height: 5)

    override var fittingSize: NSSize {
        let text = textField.intrinsicContentSize
        let shortcut = shortcutField.isHidden ? .zero : shortcutField.intrinsicContentSize
        let gap: CGFloat = shortcutField.isHidden ? 0 : CCSpace.sm
        return NSSize(
            width: ceil(text.width + gap + shortcut.width + Self.padding.width * 2) + 2,
            height: ceil(max(text.height, shortcut.height) + Self.padding.height * 2)
        )
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        for field in [textField, shortcutField] {
            field.translatesAutoresizingMaskIntoConstraints = true
            field.lineBreakMode = .byClipping
            addSubview(field)
        }
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setText(_ text: String, shortcut: String?) {
        textField.stringValue = text
        shortcutField.stringValue = shortcut ?? ""
        shortcutField.isHidden = (shortcut ?? "").isEmpty
        needsLayout = true
    }

    /// The bubble inverts the surface (ink fill, background-colored text) —
    /// shadcn's tooltip contrast. Composited to an OPAQUE color first: the
    /// ink token is translucent and translucent fills are never dressed.
    private var fill: NSColor {
        let colors = CCTheme.color
        let ink = colors.foreground
        return colors.background.blended(withFraction: ink.alphaComponent, of: ink.withAlphaComponent(1))
            ?? ink
    }

    private func applyTheme() {
        guard let layer else { return }
        let colors = CCTheme.color
        layer.backgroundColor = fill.cgColor
        CCMaterial.dress(layer, as: .raisedMatte(tint: fill), radius: CCTheme.radius(.md))
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = CCTheme.isDark ? 0.45 : 0.22
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: -2)
        textField.font = CCTheme.font.label
        textField.textColor = colors.background
        shortcutField.font = .monospacedSystemFont(ofSize: CCTheme.font.caption.pointSize, weight: .medium)
        shortcutField.textColor = colors.background.withAlphaComponent(0.6)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = CCTheme.radius(.md)
        if let layer { CCMaterial.refit(layer, radius: CCTheme.radius(.md)) }
        let text = textField.intrinsicContentSize
        let shortcut = shortcutField.intrinsicContentSize
        textField.frame = NSRect(x: Self.padding.width, y: (bounds.height - text.height) / 2,
                                 width: ceil(text.width) + 2, height: text.height)
        shortcutField.frame = NSRect(x: bounds.width - Self.padding.width - ceil(shortcut.width),
                                     y: (bounds.height - shortcut.height) / 2,
                                     width: ceil(shortcut.width), height: shortcut.height)
    }

    /// Scale 0.9 → 1 pivoting on the edge that FACES the target, + fade.
    func playEntrance(from side: CCTooltip.Placement) {
        guard let layer else { return }
        let b = layer.bounds
        // Unflipped view: y-up bounds. A tooltip ABOVE its target grows out
        // of its bottom edge, etc.
        let pivot: CGPoint
        switch side {
        case .top: pivot = CGPoint(x: b.midX, y: b.minY)
        case .bottom: pivot = CGPoint(x: b.midX, y: b.maxY)
        case .leading: pivot = CGPoint(x: b.maxX, y: b.midY)
        case .trailing: pivot = CGPoint(x: b.minX, y: b.midY)
        }
        CCMotion.spring(layer, keyPath: "transform",
                        from: NSValue(caTransform3D: CCMotion.scaleTransform(0.9, pivot: pivot, in: layer)),
                        to: NSValue(caTransform3D: CATransform3DIdentity), .snappy)
        CCMotion.fadeAlpha(self, to: 1, duration: 0.12, from: 0)
    }

    func playExit() {
        CCMotion.fadeAlpha(self, to: 0, duration: 0.1)
    }
}
