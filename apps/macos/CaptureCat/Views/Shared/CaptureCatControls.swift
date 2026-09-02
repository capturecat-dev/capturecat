import AppKit

// MARK: - Popup geometry

/// The only coordinate bridge used by menus and floating panels. AppKit event
/// locations are already in window coordinates, while view bounds are local;
/// keeping those two paths explicit prevents container offsets from being
/// applied twice. Placement is resolved against the screen containing the
/// anchor, not `window.screen`, which is important for windows spanning two
/// displays and non-activating recording panels.
@MainActor
enum CaptureCatPopupGeometry {
    enum HorizontalAlignment { case leading, center }

    static func screenRect(of rect: NSRect, in view: NSView) -> NSRect? {
        guard let window = view.window else { return nil }
        return window.convertToScreen(view.convert(rect, to: nil))
    }

    static func screenPoint(for event: NSEvent, in view: NSView) -> NSPoint? {
        guard let window = view.window else { return nil }
        // `locationInWindow` is ALREADY in the window base coordinate space.
        // Converting it through `view` first applies the view's origin a second
        // time and is the source of the old sidebar/timeline menu offsets.
        return window.convertToScreen(
            NSRect(origin: event.locationInWindow, size: .zero)
        ).origin
    }

    static func origin(
        anchor: NSRect,
        popupSize: NSSize,
        prefersAbove: Bool,
        horizontalAlignment: HorizontalAlignment,
        gap: CGFloat = 5
    ) -> NSPoint {
        let screen = screen(containing: anchor)
        let visible = (screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? anchor)
            .insetBy(dx: 8, dy: 8)

        let idealX: CGFloat = switch horizontalAlignment {
        case .leading: anchor.minX
        case .center: anchor.midX - popupSize.width / 2
        }
        let x = clamp(idealX, lower: visible.minX, upper: visible.maxX - popupSize.width)

        let aboveY = anchor.maxY + gap
        let belowY = anchor.minY - popupSize.height - gap
        let preferredY = prefersAbove ? aboveY : belowY
        let alternateY = prefersAbove ? belowY : aboveY
        let y: CGFloat
        if fitsVertically(preferredY, height: popupSize.height, in: visible) {
            y = preferredY
        } else if fitsVertically(alternateY, height: popupSize.height, in: visible) {
            y = alternateY
        } else {
            y = clamp(preferredY, lower: visible.minY, upper: visible.maxY - popupSize.height)
        }
        return NSPoint(x: x, y: y)
    }

    private static func screen(containing anchor: NSRect) -> NSScreen? {
        let point = NSPoint(x: anchor.midX, y: anchor.midY)
        if let direct = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) {
            return direct
        }
        // A zero-sized context-menu anchor can sit exactly on a display edge;
        // choose the display with the largest intersection in that case.
        return NSScreen.screens.max {
            $0.frame.intersection(anchor).width * $0.frame.intersection(anchor).height
                < $1.frame.intersection(anchor).width * $1.frame.intersection(anchor).height
        }
    }

    private static func fitsVertically(_ y: CGFloat, height: CGFloat, in frame: NSRect) -> Bool {
        y >= frame.minY && y + height <= frame.maxY
    }

    private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        guard upper >= lower else { return lower }
        return min(max(value, lower), upper)
    }
}

// MARK: - Hover routing

/// A floating-panel container whose row hover is DRIVEN BY EVENT MONITORS
/// (CaptureCatMenuSession / CaptureCatPopover), not by NSTrackingArea: real enter/moved
/// delivery to borderless non-activating child panels drops events partway
/// down long row lists. Conformers hit-test their rows from a window point.
@MainActor
protocol CaptureCatHoverRoutable: AnyObject {
    func routeHover(windowPoint: NSPoint)
    func clearHover()
}

/// App-side alias — the poller lives in the kit (DesignKit/CCCombobox.swift
/// hosts CCHoverPoller) so kit components can use it without depending on
/// app code.
typealias CaptureCatHoverPoller = CCHoverPoller

// MARK: - Shared buttons

/// The app-wide button primitive. It deliberately owns every pixel of its
/// chrome so an `NSButtonCell` can never reintroduce Aqua bevels, focus rings,
/// or platform-dependent padding.
@MainActor
final class CaptureCatButton: NSControl {
    enum Style {
        case primary
        case secondary
        case quiet
        case warning
        case destructive
    }

    var onClick: (() -> Void)?
    var style: Style { didSet { refresh() } }
    /// Shadcn-style radius token (`.sm`/`.md`/`.lg`/`.full`…), default `.md`.
    var radius: CCRadius = .md { didSet { needsLayout = true } }
    var isSelected = false { didSet { refresh() } }
    var keyEquivalent = ""
    var keyEquivalentModifierMask: NSEvent.ModifierFlags = []

    var title: String {
        get { titleField.stringValue }
        set {
            titleField.stringValue = newValue
            titleAfterIcon?.constant = newValue.isEmpty ? 0 : 6
            invalidateIntrinsicContentSize()
        }
    }

    var symbol: String? {
        didSet { refreshSymbol() }
    }

    override var isEnabled: Bool {
        didSet {
            if !isEnabled { isHovering = false; isPressed = false }
            refresh()
        }
    }

    private let titleField = NSTextField(labelWithString: "")
    private let imageView = NSImageView()
    private let height: CGFloat
    private let horizontalPadding: CGFloat
    private var trackingArea: NSTrackingArea?
    private var isHovering = false { didSet { refresh() } }
    private var isPressed = false { didSet { refresh() } }
    private var themeObservation: CCThemeObservation?

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        let iconWidth: CGFloat = symbol == nil ? 0 : 18
        let gap: CGFloat = symbol == nil || title.isEmpty ? 0 : 6
        return NSSize(
            width: horizontalPadding * 2 + iconWidth + gap + titleField.intrinsicContentSize.width,
            height: height
        )
    }

    /// `icon:` takes an SF Symbol name — shadcn's `icon={}` slot.
    convenience init(
        _ title: String = "",
        icon: String?,
        style: Style = .secondary,
        action: (() -> Void)? = nil
    ) {
        self.init(title: title, symbol: icon, style: style, action: action)
    }

    init(
        title: String = "",
        symbol: String? = nil,
        style: Style = .secondary,
        height: CGFloat = 30,
        horizontalPadding: CGFloat = 11,
        action: (() -> Void)? = nil
    ) {
        self.style = style
        self.symbol = symbol
        self.height = height
        self.horizontalPadding = horizontalPadding
        self.onClick = action
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = radius.resolved(for: height)
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        titleField.stringValue = title
        titleField.font = EditorThemeKit.button()
        titleField.lineBreakMode = .byTruncatingTail
        titleField.translatesAutoresizingMaskIntoConstraints = false
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyDown
        addSubview(imageView)
        addSubview(titleField)

        let iconLeading = imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalPadding)
        let titleAfterIcon = titleField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6)
        let titleWithoutIcon = titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalPadding)
        iconLeading.isActive = true
        titleAfterIcon.isActive = symbol != nil
        titleWithoutIcon.isActive = symbol == nil
        self.titleAfterIcon = titleAfterIcon
        self.titleWithoutIcon = titleWithoutIcon

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: height),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 18),
            imageView.heightAnchor.constraint(equalToConstant: 18),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontalPadding),
        ])
        refreshSymbol()
        themeObservation = CCThemeObservation { [weak self] in self?.refresh() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        layer?.cornerRadius = radius.resolved(for: bounds.height)
    }

    private var titleAfterIcon: NSLayoutConstraint?
    private var titleWithoutIcon: NSLayoutConstraint?

    private func refreshSymbol() {
        imageView.isHidden = symbol == nil
        if let symbol {
            imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        } else {
            imageView.image = nil
        }
        titleAfterIcon?.isActive = symbol != nil
        titleWithoutIcon?.isActive = symbol == nil
        // Icon-only buttons drop the icon→title gap — with the 6pt gap a
        // 26pt square chip is unsatisfiable (4+18+6+0+4 = 32) and AutoLayout
        // breaks the icon width instead.
        titleAfterIcon?.constant = title.isEmpty ? 0 : 6
        invalidateIntrinsicContentSize()
        refresh()
    }

    private func refresh() {
        let base: NSColor
        let border: NSColor
        let content: NSColor
        switch style {
        case .primary:
            base = NSColor.controlAccentColor
            border = .clear
            content = .white
        case .secondary:
            base = EditorThemeKit.panelElevated
            border = EditorThemeKit.hairline
            content = EditorThemeKit.textPrimary
        case .quiet:
            base = isSelected ? EditorThemeKit.activeFill : .clear
            border = .clear
            content = isSelected ? EditorThemeKit.textPrimary : EditorThemeKit.textSecondary
        case .warning:
            base = EditorThemeKit.panelElevated
            border = NSColor.systemOrange.withAlphaComponent(0.22)
            content = NSColor.systemOrange.withAlphaComponent(0.95)
        case .destructive:
            base = EditorThemeKit.panelElevated
            border = NSColor.systemRed.withAlphaComponent(0.18)
            content = NSColor.systemRed.withAlphaComponent(0.95)
        }

        let fill: NSColor
        if isPressed {
            fill = base.blended(withFraction: 0.16, of: .black) ?? base
        } else if isHovering {
            fill = base.blended(withFraction: style == .quiet ? 0.07 : 0.09,
                                of: CCTheme.isDark ? .white : .black)
                ?? EditorThemeKit.hoverFill
        } else {
            fill = base
        }
        if let layer, window != nil {
            CCMotion.fade(layer, keyPath: "backgroundColor", to: fill.cgColor)
            CCMotion.fade(layer, keyPath: "borderColor", to: border.cgColor)
        } else {
            layer?.backgroundColor = fill.cgColor
            layer?.borderColor = border.cgColor
        }
        titleField.textColor = content
        imageView.contentTintColor = content
        alphaValue = isEnabled ? 1 : CCTheme.current.disabledAlpha
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

    override func mouseEntered(with event: NSEvent) { isHovering = isEnabled }
    override func mouseExited(with event: NSEvent) { isHovering = false }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        CCMotion.pressScale(self, down: true)
    }
    override func mouseDragged(with event: NSEvent) {
        guard isEnabled else { return }
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if inside != isPressed {
            isPressed = inside
            CCMotion.pressScale(self, down: inside)
        }
    }
    override func mouseUp(with event: NSEvent) {
        let shouldFire = isEnabled && bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        CCMotion.pressScale(self, down: false)
        if shouldFire { onClick?() }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isEnabled, !keyEquivalent.isEmpty,
              event.charactersIgnoringModifiers?.lowercased() == keyEquivalent.lowercased(),
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == keyEquivalentModifierMask
        else { return super.performKeyEquivalent(with: event) }
        onClick?()
        return true
    }
}

// MARK: - Shared toggle

/// Compact, fully custom toggle used wherever the app previously exposed an
/// `NSSwitch`. The geometry and colour come from the same control tokens as
/// buttons and menu rows.
@MainActor
final class CaptureCatToggle: NSControl {
    var onChange: ((Bool) -> Void)?
    var isOn = false { didSet { if isOn != oldValue { refresh(animated: window != nil) } } }

    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1 : 0.38 }
    }

    private let thumb = NSView()
    private var thumbLeading: NSLayoutConstraint!
    private var themeObservation: CCThemeObservation?

    override var intrinsicContentSize: NSSize { NSSize(width: 30, height: 18) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = CCRadius.full.resolved(for: 18)
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = CCRadius.full.resolved(for: 12)
        thumb.layer?.cornerCurve = .continuous
        thumb.layer?.backgroundColor = NSColor.white.cgColor
        thumb.layer?.shadowColor = NSColor.black.cgColor
        thumb.layer?.shadowOpacity = 0.24
        thumb.layer?.shadowRadius = 2
        thumb.layer?.shadowOffset = CGSize(width: 0, height: -1)
        thumb.translatesAutoresizingMaskIntoConstraints = false
        addSubview(thumb)
        thumbLeading = thumb.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 30),
            heightAnchor.constraint(equalToConstant: 18),
            thumb.widthAnchor.constraint(equalToConstant: 12),
            thumb.heightAnchor.constraint(equalToConstant: 12),
            thumb.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbLeading,
        ])
        // Thumb stays white in both themes, matching DesignKit's CCToggle.
        themeObservation = CCThemeObservation { [weak self] in self?.refresh(animated: false) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func refresh(animated: Bool) {
        thumbLeading.constant = isOn ? 15 : 3
        let fillColor = isOn
            ? NSColor.controlAccentColor.withAlphaComponent(0.88)
            : EditorThemeKit.panelElevated
        let fill = fillColor.cgColor
        let border = (isOn ? NSColor.clear : EditorThemeKit.hairline).cgColor
        // Skeuo: recessed track, glossy raised thumb (matches CCToggle).
        if let layer {
            CCMaterial.dress(layer, as: .recessed(tint: fillColor),
                             radius: CCRadius.full.resolved(for: 18))
        }
        if let thumbLayer = thumb.layer {
            CCMaterial.dress(thumbLayer, as: .raised(tint: .white), radius: 6)
        }
        guard animated else {
            layer?.backgroundColor = fill
            layer?.borderColor = border
            layoutSubtreeIfNeeded()
            return
        }
        if let layer {
            CCMotion.fade(layer, keyPath: "backgroundColor", to: fill, duration: 0.2)
            CCMotion.fade(layer, keyPath: "borderColor", to: border, duration: 0.2)
        }
        // The thumb travels on a REAL bouncy spring. (The old version sprang
        // transform.scale to 1.0 — already 1.0, a no-op — while the travel
        // rode a flat constraint ease; the "bouncy" comment was a lie.)
        // Commit the constraint endpoint without animation, then spring the
        // layer from where it visibly was to the resolved position.
        let fromX = (thumb.layer?.presentation() ?? thumb.layer)?.position.x
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutSubtreeIfNeeded()
        CATransaction.commit()
        if let thumbLayer = thumb.layer, let fromX {
            let travel = CCMotion.springAnimation(keyPath: "position.x", .bouncy)
            travel.fromValue = fromX
            travel.toValue = thumbLayer.position.x
            thumbLayer.add(travel, forKey: "capmotion.position.x")
        }
    }

    // MARK: - Harness seam

    var probeThumbLayer: CALayer? { thumb.layer }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        isOn.toggle()
        onChange?(isOn)
    }
}

// MARK: - Shared floating panel

/// Borderless replacement for `NSPopover`. The caller supplies custom content;
/// this class supplies the same Captures-style elevated surface and transient
/// dismissal used by dropdowns, without an Aqua arrow or material bezel.
@MainActor
final class CaptureCatPopover: NSObject {
    static let didCloseNotification = Notification.Name("CaptureCatPopoverDidClose")

    var contentViewController: NSViewController?
    var contentSize: NSSize = .zero
    var isShown: Bool { panel.isVisible }

    private weak var hoverTarget: CaptureCatHoverRoutable?
    private var hoverPoller: CaptureCatHoverPoller?

    private let panel = NSPanel(
        contentRect: .zero,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    private weak var parentWindow: NSWindow?
    private var localMonitor: Any?
    private var globalMonitor: Any?

    override init() {
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.acceptsMouseMovedEvents = true
    }

    func show(relativeTo positioningRect: NSRect, of positioningView: NSView, preferredEdge: NSRectEdge) {
        guard let window = positioningView.window, let controller = contentViewController else { return }
        close()
        parentWindow = window

        let content = controller.view
        content.layoutSubtreeIfNeeded()
        var size = contentSize
        if size.width <= 0 || size.height <= 0 { size = controller.preferredContentSize }
        if size.width <= 0 || size.height <= 0 { size = content.fittingSize }
        size.width = max(1, size.width)
        size.height = max(1, size.height)

        let chrome = CaptureCatPopoverChromeView()
        content.translatesAutoresizingMaskIntoConstraints = false
        chrome.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: chrome.leadingAnchor, constant: 1),
            content.trailingAnchor.constraint(equalTo: chrome.trailingAnchor, constant: -1),
            content.topAnchor.constraint(equalTo: chrome.topAnchor, constant: 1),
            content.bottomAnchor.constraint(equalTo: chrome.bottomAnchor, constant: -1),
        ])
        panel.contentView = chrome
        panel.setContentSize(NSSize(width: size.width + 2, height: size.height + 2))

        guard let anchor = CaptureCatPopupGeometry.screenRect(of: positioningRect, in: positioningView) else { return }
        let origin = CaptureCatPopupGeometry.origin(
            anchor: anchor,
            popupSize: panel.frame.size,
            prefersAbove: preferredEdge == .maxY,
            horizontalAlignment: .center
        )
        panel.setFrameOrigin(origin)

        window.addChildWindow(panel, ordered: .above)
        panel.alphaValue = 0
        panel.orderFront(nil)
        CaptureCatPopupAnimator.present(panel, content: chrome, fromAbove: preferredEdge != .maxY)
        // Polled hover, same rationale as CaptureCatMenuSession: tracking areas
        // AND moved-event routing drop out over panel overhang; polling the
        // window-server cursor position cannot.
        hoverTarget = Self.findHoverRoutable(in: content)
        hoverPoller = CaptureCatHoverPoller { [weak self] in
            self?.routeHover(screenPoint: NSEvent.mouseLocation)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                self.close()
                return nil
            }
            if event.type != .keyDown, event.window !== self.panel { self.close() }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
    }

    private func routeHover(screenPoint: NSPoint) {
        guard let hoverTarget else { return }
        if panel.isVisible, panel.frame.contains(screenPoint) {
            hoverTarget.routeHover(windowPoint: panel.convertPoint(fromScreen: screenPoint))
        } else {
            hoverTarget.clearHover()
        }
    }

    private static func findHoverRoutable(in root: NSView) -> CaptureCatHoverRoutable? {
        if let match = root as? CaptureCatHoverRoutable { return match }
        for sub in root.subviews {
            if let found = findHoverRoutable(in: sub) { return found }
        }
        return nil
    }

    func close() {
        let wasVisible = panel.isVisible
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        hoverPoller?.stop()
        hoverPoller = nil
        hoverTarget?.clearHover()
        parentWindow?.removeChildWindow(panel)
        panel.orderOut(nil)
        if wasVisible { NotificationCenter.default.post(name: Self.didCloseNotification, object: self) }
    }
}

@MainActor
private final class CaptureCatPopoverChromeView: NSView {
    private var themeObservation: CCThemeObservation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = CCTheme.radius(.lg)
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.shadowOpacity = 0.46
        layer?.shadowRadius = 18
        layer?.shadowOffset = CGSize(width: 0, height: -6)
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func applyTheme() {
        layer?.backgroundColor = EditorThemeKit.panel.cgColor
        layer?.borderColor = EditorThemeKit.hairline.cgColor
        layer?.shadowColor = NSColor.black.cgColor
    }
}

// MARK: - Popup presentation animation

/// One entrance/exit animation for every floating surface (menus, popovers,
/// dropdowns): fade plus a small Keynote-style scale settle from the anchored
/// edge. Exit is a quick fade so dismissal never feels laggy.
@MainActor
enum CaptureCatPopupAnimator {
    static func present(_ panel: NSWindow, content: NSView, fromAbove: Bool) {
        content.wantsLayer = true
        if let layer = content.layer {
            let frame = layer.frame
            layer.anchorPoint = CGPoint(x: 0.5, y: fromAbove ? 1 : 0)
            layer.position = CGPoint(
                x: frame.midX,
                y: fromAbove ? frame.maxY : frame.minY
            )
            layer.transform = CATransform3DMakeScale(0.96, 0.96, 1)
            CCMotion.spring(layer, keyPath: "transform.scale", to: 1.0, .smooth)
        }
        CCMotion.run(duration: 0.18, curve: CCMotion.glide) {
            panel.animator().alphaValue = 1
        }
    }

    static func dismiss(_ panel: NSWindow, completion: @escaping () -> Void) {
        CCMotion.run(duration: 0.12, curve: CCMotion.glide, {
            panel.animator().alphaValue = 0
        }, completion: completion)
    }
}

// MARK: - Captures-style menu surface

/// Presents an `NSMenu` model using the same flat floating surface as the
/// Captures command-K results. Existing menu construction code stays intact;
/// only its rendering is replaced, which keeps actions and validation DRY.
@MainActor
enum CaptureCatMenuPresenter {
    enum Edge { case above, below }

    private static var active: CaptureCatMenuSession?

    static func show(
        _ menu: NSMenu,
        from sourceView: NSView,
        edge: Edge = .below,
        selectedItem: NSMenuItem? = nil
    ) {
        guard let window = sourceView.window,
              let sourceOnScreen = CaptureCatPopupGeometry.screenRect(of: sourceView.bounds, in: sourceView)
        else { return }
        dismiss()
        let session = CaptureCatMenuSession(menu: menu, parentWindow: window)
        active = session
        session.onDismiss = { active = nil }
        session.show(relativeTo: sourceOnScreen, edge: edge, selectedItem: selectedItem)
    }

    static func showContextMenu(_ menu: NSMenu, with event: NSEvent, for view: NSView) {
        guard let window = view.window,
              let pointOnScreen = CaptureCatPopupGeometry.screenPoint(for: event, in: view)
        else { return }
        dismiss()
        let session = CaptureCatMenuSession(menu: menu, parentWindow: window)
        active = session
        session.onDismiss = { active = nil }
        session.show(at: pointOnScreen)
    }

    static func dismiss() {
        active?.dismiss()
        active = nil
    }
}

@MainActor
private final class CaptureCatMenuSession: NSObject {
    var onDismiss: (() -> Void)?

    private let panel: NSPanel
    private weak var parentWindow: NSWindow?
    private let menu: NSMenu
    private var selectedRow = -1
    private var rows: [CaptureCatMenuRow] = []
    private weak var menuContent: CaptureCatMenuContentView?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var hoverPoller: CaptureCatHoverPoller?
    private var anchorRect = NSRect.zero
    private var edge: CaptureCatMenuPresenter.Edge = .below
    private var fixedPoint: NSPoint?

    // Flyout chain: submenus open as sibling sessions to the side, macOS-style.
    private weak var parentSession: CaptureCatMenuSession?
    private var childSession: CaptureCatMenuSession?
    /// The row whose submenu is currently flown out (kept highlighted).
    private weak var flyoutRow: CaptureCatMenuRow?
    private var hoverTimer: Timer?

    init(menu: NSMenu, parentWindow: NSWindow) {
        self.parentWindow = parentWindow
        self.menu = menu
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
    }

    func show(relativeTo rect: NSRect, edge: CaptureCatMenuPresenter.Edge, selectedItem: NSMenuItem?) {
        anchorRect = rect
        self.edge = edge
        rebuild(selectedItem: selectedItem)
        installAndOrder()
    }

    func show(at point: NSPoint) {
        fixedPoint = point
        rebuild(selectedItem: nil)
        installAndOrder()
    }

    func dismiss() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        closeChild()
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        hoverPoller?.stop()
        hoverPoller = nil
        // Sessions are one-shot, so the fade-out can safely outlive `self`.
        let panel = self.panel
        let parent = parentWindow
        CaptureCatPopupAnimator.dismiss(panel) {
            parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        onDismiss?()
        onDismiss = nil
    }

    // MARK: - Flyout chain plumbing

    private func rootSession() -> CaptureCatMenuSession { parentSession?.rootSession() ?? self }
    private func deepestSession() -> CaptureCatMenuSession { childSession?.deepestSession() ?? self }
    private func chainPanels() -> [NSPanel] { [panel] + (childSession?.chainPanels() ?? []) }

    private func closeChild() {
        flyoutRow?.isFlyoutOpen = false
        flyoutRow = nil
        childSession?.dismiss()
        childSession = nil
    }

    /// Fly the row's submenu out beside it (or focus the existing flyout).
    private func openSubmenu(for row: CaptureCatMenuRow) {
        guard let submenu = row.item.submenu, let parentWindow else { return }
        if flyoutRow === row { return }
        closeChild()
        let child = CaptureCatMenuSession(menu: submenu, parentWindow: parentWindow)
        child.parentSession = self
        childSession = child
        flyoutRow = row
        row.isFlyoutOpen = true
        let rowOnScreen = CaptureCatPopupGeometry.screenRect(of: row.bounds, in: row) ?? .zero
        child.show(flyoutFrom: rowOnScreen, selectedItem: submenu.items.first(where: { $0.state == .on }))
    }

    /// Hover intent from a row: submenu rows pop their flyout after a short
    /// dwell; plain rows retire an open flyout after a slightly longer one
    /// (so a diagonal move into the flyout doesn't slam it shut).
    fileprivate func rowHovered(_ row: CaptureCatMenuRow) {
        hoverTimer?.invalidate()
        if row.item.submenu != nil, row.item.isEnabled {
            hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.14, repeats: false) { [weak self, weak row] _ in
                MainActor.assumeIsolated {
                    guard let self, let row else { return }
                    self.openSubmenu(for: row)
                }
            }
        } else if childSession != nil {
            hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.closeChild() }
            }
        }
    }

    /// Present as a flyout: anchored beside the parent row, flipping to the
    /// left edge when the screen runs out.
    private func show(flyoutFrom rowRect: NSRect, selectedItem: NSMenuItem?) {
        rebuild(selectedItem: selectedItem)
        let size = panel.frame.size
        let visible = (NSScreen.screens.first(where: { NSMouseInRect(NSPoint(x: rowRect.midX, y: rowRect.midY), $0.frame, false) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? rowRect).insetBy(dx: 8, dy: 8)
        var x = rowRect.maxX + 4
        if x + size.width > visible.maxX { x = rowRect.minX - size.width - 4 }
        // Top-align the flyout with its row (menu coordinates are Y-up).
        var y = rowRect.maxY + 6 - size.height
        y = min(max(y, visible.minY), visible.maxY - size.height)
        panel.setFrameOrigin(NSPoint(x: max(visible.minX, x), y: y))
        installAndOrder()
    }

    private func installAndOrder() {
        parentWindow?.addChildWindow(panel, ordered: .above)
        panel.alphaValue = 0
        panel.orderFront(nil)
        if let content = panel.contentView {
            CaptureCatPopupAnimator.present(panel, content: content, fromAbove: edge == .below)
        }

        // Only the root session watches events; children live and die with it.
        guard parentSession == nil else { return }
        // Hover comes from a POLLING tracking loop, not tracking areas and not
        // mouse-moved events — both drop out over panel regions that overhang
        // the parent window (the "glide dies partway down the menu" bug, twice).
        hoverPoller = CaptureCatHoverPoller { [weak self] in
            self?.routeHoverAcrossChain(screenPoint: NSEvent.mouseLocation)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown { return self.deepestSession().handleKey(event) ? nil : event }
            if let window = event.window, self.chainPanels().contains(where: { $0 === window }) {
                return event
            }
            self.dismiss()
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismiss()
        }
    }

    /// Root-session hover routing: find the chain panel under the pointer and
    /// hand its content the hover; every other session in the chain clears
    /// (the flyout row's own highlight persists via `isFlyoutOpen`, not hover).
    private func chainSessions() -> [CaptureCatMenuSession] { [self] + (childSession?.chainSessions() ?? []) }

    private var debugTickCount = 0

    private func routeHoverAcrossChain(screenPoint: NSPoint) {
        debugTickCount += 1
        for session in chainSessions() {
            let inside = session.panel.isVisible && session.panel.frame.contains(screenPoint)
            if CCHoverPoller.debug, debugTickCount % 30 == 0 {
                NSLog("CCMenu chain tick mouse=%@ panel=%@ inside=%d content=%d",
                      NSStringFromPoint(screenPoint), NSStringFromRect(session.panel.frame),
                      inside ? 1 : 0, session.menuContent != nil ? 1 : 0)
            }
            if inside {
                let windowPoint = session.panel.convertPoint(fromScreen: screenPoint)
                session.menuContent?.routeHover(windowPoint: windowPoint)
            } else {
                session.menuContent?.clearHover()
            }
        }
    }

    private func rebuild(selectedItem: NSMenuItem?) {
        let content = CaptureCatMenuContentView()
        menuContent = content
        rows = []

        for item in menu.items where !item.isHidden {
            if item.isSeparatorItem {
                content.addSeparator()
                continue
            }
            let row = CaptureCatMenuRow(item: item) { [weak self] row in
                self?.activate(row)
            }
            row.onHover = { [weak self] row in
                self?.rowHovered(row)
            }
            rows.append(row)
            content.add(row)
        }

        let width = content.preferredWidth
        let height = min(content.preferredHeight, 430)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = content.preferredHeight > height
        scroll.autohidesScrollers = true
        scroll.documentView = content
        content.frame = NSRect(x: 0, y: 0, width: width, height: content.preferredHeight)

        let chrome = CaptureCatMenuChromeView(frame: scroll.frame)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        chrome.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: chrome.leadingAnchor, constant: 1),
            scroll.trailingAnchor.constraint(equalTo: chrome.trailingAnchor, constant: -1),
            scroll.topAnchor.constraint(equalTo: chrome.topAnchor, constant: 1),
            scroll.bottomAnchor.constraint(equalTo: chrome.bottomAnchor, constant: -1),
        ])
        panel.contentView = chrome
        panel.setContentSize(NSSize(width: width + 2, height: height + 2))
        reposition()

        if let selectedItem, let index = rows.firstIndex(where: { $0.item === selectedItem }) {
            select(index)
        } else {
            selectedRow = -1
        }
    }

    private func reposition() {
        let anchor = fixedPoint.map { NSRect(origin: $0, size: .zero) } ?? anchorRect
        let origin = CaptureCatPopupGeometry.origin(
            anchor: anchor,
            popupSize: panel.frame.size,
            prefersAbove: fixedPoint == nil && edge == .above,
            horizontalAlignment: .leading,
            gap: fixedPoint == nil ? 5 : 2
        )
        panel.setFrameOrigin(origin)
    }

    private func activate(_ row: CaptureCatMenuRow) {
        let item = row.item
        guard item.isEnabled else { return }
        if item.submenu != nil {
            openSubmenu(for: row)
            childSession?.selectFirst()
            return
        }
        rootSession().dismiss()
        guard let action = item.action else { return }
        NSApp.sendAction(action, to: item.target, from: item)
    }

    private func selectFirst() {
        if let first = selectableRows().first { select(first) }
    }

    private func selectableRows() -> [Int] {
        rows.indices.filter { rows[$0].item.isEnabled }
    }

    private func select(_ index: Int) {
        selectedRow = index
        for (rowIndex, row) in rows.enumerated() { row.isKeyboardSelected = rowIndex == index }
    }

    private func move(_ delta: Int) {
        let candidates = selectableRows()
        guard !candidates.isEmpty else { return }
        guard let current = candidates.firstIndex(of: selectedRow) else {
            select(delta > 0 ? candidates[0] : candidates[candidates.count - 1])
            return
        }
        select(candidates[(current + delta + candidates.count) % candidates.count])
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: // escape — retire the deepest flyout first, then the menu
            if let parentSession { parentSession.closeChild() } else { dismiss() }
            return true
        case 125: move(1); return true
        case 126: move(-1); return true
        case 36, 76:
            if rows.indices.contains(selectedRow) { activate(rows[selectedRow]) }
            return true
        case 123: // left arrow — step back out of a flyout
            guard let parentSession else { return false }
            parentSession.closeChild()
            return true
        case 124: // right arrow — fly the selected submenu out
            if rows.indices.contains(selectedRow), rows[selectedRow].item.submenu != nil {
                activate(rows[selectedRow])
                return true
            }
            return false
        default: return false
        }
    }
}

@MainActor
private final class CaptureCatMenuChromeView: NSView {
    private var themeObservation: CCThemeObservation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = CCTheme.radius(.lg)
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.shadowOpacity = 0.48
        layer?.shadowRadius = 18
        layer?.shadowOffset = CGSize(width: 0, height: -6)
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func applyTheme() {
        layer?.backgroundColor = EditorThemeKit.panelElevated.cgColor
        layer?.borderColor = EditorThemeKit.hairline.cgColor
        layer?.shadowColor = NSColor.black.cgColor
    }
}

@MainActor
private final class CaptureCatMenuContentView: NSView, CaptureCatHoverRoutable {
    private let stack = NSStackView()
    /// One shared hover/selection wash that GLIDES between rows on a spring —
    /// the macOS Sonoma menu feel — instead of each row flashing its own.
    private let highlight = CALayer()
    private weak var highlightedRow: CaptureCatMenuRow?
    private var separatorLines: [NSView] = []
    private var themeObservation: CCThemeObservation?
    private(set) var preferredWidth: CGFloat = 190
    // fittingSize already includes the stack's edge insets — adding more here
    // is what made the menu's bottom gutter visibly deeper than the top.
    var preferredHeight: CGFloat { stack.fittingSize.height }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        highlight.cornerRadius = CCTheme.radius(.md)
        highlight.cornerCurve = .continuous
        highlight.opacity = 0
        layer?.insertSublayer(highlight, at: 0)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 5, bottom: 5, right: 5)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
        ])
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func applyTheme() {
        highlight.backgroundColor = EditorThemeKit.activeFill.cgColor
        for line in separatorLines {
            line.layer?.backgroundColor = EditorThemeKit.hairline.cgColor
        }
    }

    func add(_ row: CaptureCatMenuRow) {
        stack.addArrangedSubview(row)
        preferredWidth = max(preferredWidth, min(360, row.fittingSize.width + 10))
        row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -10).isActive = true
        row.onHighlight = { [weak self] row, active in
            self?.setHighlight(row: row, active: active)
        }
    }

    // MARK: - Hover dispatch (one tracking area, not one per row)
    //
    // Rows used to each install their own NSTrackingArea. Inside this menu's
    // stack-in-scroll-in-borderless-child-panel topology, per-row enter/exit
    // delivery proved unreliable with a real mouse (hover died after the
    // first rows) while synthesized probe events sailed through — the classic
    // "wrong topology" gate blind spot. Native menus track the same way this
    // now does: ONE area on the container, hit-testing rows per mouse move.

    private var hoverArea: NSTrackingArea?
    private weak var hoveredRow: CaptureCatMenuRow?

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

    private func row(at point: NSPoint) -> CaptureCatMenuRow? {
        for case let row as CaptureCatMenuRow in stack.arrangedSubviews {
            if row.frame.isEmpty { continue }
            // Gap-tolerant: rows claim half the 4pt inter-row spacing, so the
            // wash never clears (and re-appears) while crossing between rows.
            if convert(row.frame, from: stack).insetBy(dx: 0, dy: -2).contains(point) { return row }
        }
        return nil
    }

    func routeHover(windowPoint: NSPoint) {
        let target = row(at: convert(windowPoint, from: nil))
        guard target !== hoveredRow else { return }
        if CCHoverPoller.debug {
            NSLog("CCMenu hover -> %@", target?.item.title ?? "(none)")
        }
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

    private func setHighlight(row: CaptureCatMenuRow, active: Bool) {
        if active {
            layoutSubtreeIfNeeded()
            let target = row.convert(row.bounds, to: self)
            // Keep a prior row's geometry as the next glide origin even after
            // its exit fade has fully completed. Opacity is not a state
            // boundary: using it here made slow row-to-row moves snap in
            // place whenever the pointer spent more than 0.16s in a gap.
            let appearing = highlightedRow == nil
            highlightedRow = row
            if appearing {
                // First landing: appear in place, no cross-menu flight.
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                highlight.frame = target
                CATransaction.commit()
            } else {
                CCMotion.spring(highlight, keyPath: "position",
                                 to: NSValue(point: CGPoint(x: target.midX, y: target.midY)), .snappy)
                CCMotion.spring(highlight, keyPath: "bounds",
                                 to: NSValue(rect: CGRect(origin: .zero, size: target.size)), .snappy)
            }
            CCMotion.fade(highlight, keyPath: "opacity", to: 1, duration: 0.1)
        } else if highlightedRow === row {
            // Fade but keep the reference — the next activation glides from
            // here rather than reading as a fresh landing.
            CCMotion.fade(highlight, keyPath: "opacity", to: 0, duration: 0.16)
        }
    }

    func addSeparator() {
        let holder = NSView()
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = EditorThemeKit.hairline.cgColor
        separatorLines.append(line)
        line.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(line)
        NSLayoutConstraint.activate([
            holder.heightAnchor.constraint(equalToConstant: 9),
            line.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 8),
            line.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -8),
            line.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
        ])
        stack.addArrangedSubview(holder)
        holder.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -10).isActive = true
    }
}

@MainActor
private final class CaptureCatMenuRow: NSControl {
    let item: NSMenuItem
    var isKeyboardSelected = false { didSet { refresh() } }
    /// Row stays highlighted while its submenu is flown out beside it.
    var isFlyoutOpen = false { didSet { refresh() } }
    var onHover: ((CaptureCatMenuRow) -> Void)?
    /// Reports highlight intent to the content view's gliding wash.
    var onHighlight: ((CaptureCatMenuRow, Bool) -> Void)?

    private let icon = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let shortcutField = NSTextField(labelWithString: "")
    private let trailingIcon = NSImageView()
    private let onPick: (CaptureCatMenuRow) -> Void
    private var isHovering = false { didSet { refresh() } }
    private let isHeader: Bool
    private var themeObservation: CCThemeObservation?

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        let width = 50 + titleField.intrinsicContentSize.width + shortcutField.intrinsicContentSize.width
        return NSSize(width: width, height: item.isEnabled ? 30 : 24)
    }

    init(item: NSMenuItem, onPick: @escaping (CaptureCatMenuRow) -> Void) {
        self.item = item
        self.onPick = onPick
        self.isHeader = !item.isEnabled && item.action == nil && item.submenu == nil
        super.init(frame: .zero)
        wantsLayer = true
        // Concentric with the .lg menu chrome across its 5pt gutter.
        layer?.cornerRadius = CCTheme.radius(.md)
        layer?.cornerCurve = .continuous

        titleField.stringValue = item.title
        titleField.font = isHeader
            ? .systemFont(ofSize: 10, weight: .semibold)
            : .systemFont(ofSize: 12, weight: .medium)
        titleField.lineBreakMode = .byTruncatingTail

        icon.imageScaling = .scaleProportionallyDown
        if let image = item.image {
            icon.image = image
        }

        shortcutField.stringValue = Self.shortcut(for: item)
        shortcutField.font = .systemFont(ofSize: 10.5, weight: .medium)
        shortcutField.alignment = .right

        // Selection state and submenu indicators live at the FAR RIGHT edge —
        // never leading (house rule: check/selection marks trail).
        if item.submenu != nil {
            trailingIcon.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        } else if item.state == .on {
            trailingIcon.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .bold))
        }

        for view in [icon, titleField, shortcutField, trailingIcon] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: item.isEnabled ? 30 : 24),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 15),
            icon.heightAnchor.constraint(equalToConstant: 15),
            titleField.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcutField.leadingAnchor.constraint(greaterThanOrEqualTo: titleField.trailingAnchor, constant: 14),
            shortcutField.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingIcon.leadingAnchor.constraint(equalTo: shortcutField.trailingAnchor, constant: 7),
            trailingIcon.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            trailingIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingIcon.widthAnchor.constraint(equalToConstant: 12),
        ])
        refresh()
        // Rows are short-lived, but a menu can be open across a theme flip.
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func applyTheme() {
        titleField.textColor = titleColor(isHeader: isHeader)
        if icon.image != nil {
            icon.contentTintColor = item.isEnabled ? EditorThemeKit.textSecondary : EditorThemeKit.textTertiary
        }
        shortcutField.textColor = EditorThemeKit.textTertiary
        if item.submenu != nil {
            trailingIcon.contentTintColor = EditorThemeKit.textTertiary
        } else if item.state == .on {
            trailingIcon.contentTintColor = NSColor.controlAccentColor
        }
    }

    private func titleColor(isHeader: Bool) -> NSColor {
        if isHeader { return EditorThemeKit.textTertiary }
        guard item.isEnabled else { return EditorThemeKit.textTertiary }
        if let attributedTitle = item.attributedTitle,
           attributedTitle.length > 0,
           let color = attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor {
            return color
        }
        return EditorThemeKit.textPrimary
    }

    private static func shortcut(for item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        var value = ""
        let modifiers = item.keyEquivalentModifierMask
        if modifiers.contains(.control) { value += "⌃" }
        if modifiers.contains(.option) { value += "⌥" }
        if modifiers.contains(.shift) { value += "⇧" }
        if modifiers.contains(.command) { value += "⌘" }
        return value + item.keyEquivalent.uppercased()
    }

    private func refresh() {
        onHighlight?(self, (isHovering || isKeyboardSelected || isFlyoutOpen) && item.isEnabled)
    }

    /// Hover is DISPATCHED by CaptureCatMenuContentView's single tracking area
    /// (see its hover-dispatch note) — rows own no tracking areas.
    func setHovered(_ hovered: Bool) {
        if hovered {
            isHovering = item.isEnabled
            onHover?(self)
        } else {
            isHovering = false
        }
    }
    override func mouseUp(with event: NSEvent) {
        guard item.isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPick(self)
    }
}
