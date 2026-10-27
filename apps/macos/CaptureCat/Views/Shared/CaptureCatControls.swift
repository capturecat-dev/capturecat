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
            imageView.image = CCIcon.image(symbol, pointSize: 12, weight: .semibold)
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
        // 2026 look: a flat well track and a floating white thumb (matches CCToggle).
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

/// The kit menu body receives the presenters' polled hover.
extension CCMenuList: CaptureCatHoverRoutable {}

/// Borderless replacement for `NSPopover`. The caller supplies custom content;
/// this class supplies the house floating surface (CCMenuStage: `popover`
/// token, .lg radius, hairline, soft wide shadow), its open/close motion and
/// transient dismissal — the same surface every menu uses. Content that is a
/// CCMenuList (TimelinePickerPopover) also gets ↑/↓/↩/type-select, the row
/// stagger and the pick blink.
@MainActor
final class CaptureCatPopover: NSObject {
    static let didCloseNotification = Notification.Name("CaptureCatPopoverDidClose")

    var contentViewController: NSViewController?
    var contentSize: NSSize = .zero
    var isShown: Bool { panel.isVisible && !(stage?.isClosing ?? true) }

    private weak var hoverTarget: CaptureCatHoverRoutable?
    private var hoverPoller: CaptureCatHoverPoller?

    private let panel = NSPanel(
        contentRect: .zero,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    private var stage: CCMenuStage?
    private weak var menuList: CCMenuList?
    private weak var parentWindow: NSWindow?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var isCommitting = false

    override init() {
        super.init()
        CCMenuStage.configure(panel)
    }

    func show(relativeTo positioningRect: NSRect, of positioningView: NSView, preferredEdge: NSRectEdge) {
        guard let window = positioningView.window, let controller = contentViewController,
              let anchor = CaptureCatPopupGeometry.screenRect(of: positioningRect, in: positioningView)
        else { return }
        close()
        isCommitting = false
        parentWindow = window

        let content = controller.view
        content.layoutSubtreeIfNeeded()
        var size = contentSize
        if size.width <= 0 || size.height <= 0 { size = controller.preferredContentSize }
        if size.width <= 0 || size.height <= 0 { size = content.fittingSize }
        let list = Self.findMenuList(in: content)
        menuList = list
        // Menus own their padding; custom content keeps a 1 pt inset so the
        // hairline edge stays visible around its own background.
        let inset: CGFloat = list == nil ? 1 : 0
        var surface = NSSize(width: max(1, size.width) + inset * 2, height: max(1, size.height) + inset * 2)
        if let list {
            // Height grows to fit; a menu scrolls only past the screen.
            surface.height = min(surface.height, CCMenuStage.maxSurfaceHeight(for: anchor))
            if let scroll = list.enclosingScrollView {
                let scrolls = list.frame.height > surface.height + 0.5
                scroll.hasVerticalScroller = scrolls
                scroll.verticalScrollElasticity = scrolls ? .allowed : .none
            }
        }

        let stage = CCMenuStage()
        stage.setContent(content, inset: inset)
        stage.resize(surfaceSize: surface)
        self.stage = stage
        panel.contentView = stage

        let origin = CaptureCatPopupGeometry.origin(
            anchor: anchor,
            popupSize: stage.surfaceSize,
            prefersAbove: preferredEdge == .maxY,
            horizontalAlignment: .center
        )
        panel.setFrame(stage.panelFrame(surfaceOrigin: origin), display: false)

        window.addChildWindow(panel, ordered: .above)
        stage.prepareForOpen()
        panel.orderFront(nil)
        // Pivot on the edge that faces the trigger.
        let edge: CCMenuStage.Edge = origin.y >= anchor.maxY - 0.5 ? .bottom : .top
        stage.playOpen(from: edge, anchor: NSPoint(x: anchor.midX, y: anchor.midY), list: list)

        // Polled hover, same rationale as CaptureCatMenuSession: tracking areas
        // AND moved-event routing drop out over panel overhang; polling the
        // window-server cursor position cannot.
        hoverTarget = Self.findHoverRoutable(in: content)
        hoverPoller = CaptureCatHoverPoller { [weak self] in
            self?.routeHover(screenPoint: NSEvent.mouseLocation)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown { return self.handleKey(event) ? nil : event }
            if event.window !== self.panel
                || !(self.stage?.surfaceContains(windowPoint: event.locationInWindow) ?? false) {
                self.close()
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard !CCMenu.probeIsolated else { return }
            self?.close()
        }
    }

    /// ⎋ closes any popover; menu-list content also takes ↑/↓/↩ and
    /// type-select (the panel never becomes key, so keys arrive here).
    private func handleKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 {
            close()
            return true
        }
        guard let list = menuList else { return false }
        if isCommitting { return true }
        switch event.keyCode {
        case 125: list.moveHighlight(1); return true
        case 126: list.moveHighlight(-1); return true
        case 36, 76: return list.activateHighlighted()
        default:
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  let chars = event.charactersIgnoringModifiers, chars.count == 1,
                  chars.rangeOfCharacter(from: .alphanumerics) != nil else { return false }
            return list.typeSelect(chars)
        }
    }

    /// A pick in a menu-list popover: the row's wash blinks once, then the
    /// popover closes and `action` runs (macOS order).
    func commit(_ row: CCMenuRow, action: @escaping () -> Void) {
        guard !isCommitting, let list = menuList else { return }
        isCommitting = true
        stopTracking()
        list.pulse(row) { [weak self] in
            self?.close()
            action()
        }
    }

    private func routeHover(screenPoint: NSPoint) {
        guard let hoverTarget, !isCommitting else { return }
        if panel.isVisible, let surface = stage?.surfaceScreenRect, surface.contains(screenPoint) {
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

    private static func findMenuList(in root: NSView) -> CCMenuList? {
        if let match = root as? CCMenuList { return match }
        if let scroll = root as? NSScrollView, let list = scroll.documentView as? CCMenuList { return list }
        for sub in root.subviews {
            if let found = findMenuList(in: sub) { return found }
        }
        return nil
    }

    private func stopTracking() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        hoverPoller?.stop()
        hoverPoller = nil
    }

    func close() {
        let wasShown = isShown
        stopTracking()
        guard let closing = stage, panel.isVisible, !closing.isClosing else { return }
        let panel = self.panel
        let parent = parentWindow
        closing.playClose { [weak self] in
            // Re-shown during the fade: the panel now carries a new stage.
            if let self, self.stage !== closing { return }
            parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        if wasShown { NotificationCenter.default.post(name: Self.didCloseNotification, object: self) }
    }

    // MARK: - Harness seams

    var probePanel: NSWindow { panel }
    var probeStage: CCMenuStage? { stage }
    var probeList: CCMenuList? { menuList }
}

// MARK: - Captures-style menu surface

/// Presents an `NSMenu` model on the house menu surface (CCMenuStage +
/// CCMenuList). Existing menu construction code stays intact; only its
/// rendering is replaced, which keeps actions and validation DRY.
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
        session.onDismiss = { if active === session { active = nil } }
        session.show(relativeTo: sourceOnScreen, edge: edge, selectedItem: selectedItem)
    }

    static func showContextMenu(_ menu: NSMenu, with event: NSEvent, for view: NSView) {
        guard let window = view.window,
              let pointOnScreen = CaptureCatPopupGeometry.screenPoint(for: event, in: view)
        else { return }
        dismiss()
        let session = CaptureCatMenuSession(menu: menu, parentWindow: window)
        active = session
        session.onDismiss = { if active === session { active = nil } }
        session.show(at: pointOnScreen)
    }

    static func dismiss() {
        active?.dismiss()
        active = nil
    }

    // MARK: Harness seams

    struct ProbeSurface {
        let panel: NSWindow
        let stage: CCMenuStage
        let list: CCMenuList
    }

    /// The open root menu (nil when none).
    static var probeRoot: ProbeSurface? {
        active.map { ProbeSurface(panel: $0.panel, stage: $0.stage, list: $0.list) }
    }

    /// The root menu's open flyout (nil when none).
    static var probeFlyout: ProbeSurface? {
        active?.childSession.map { ProbeSurface(panel: $0.panel, stage: $0.stage, list: $0.list) }
    }
}

@MainActor
private final class CaptureCatMenuSession: NSObject {
    var onDismiss: (() -> Void)?

    fileprivate let panel: NSPanel
    fileprivate let stage = CCMenuStage()
    fileprivate private(set) var list = CCMenuList()
    private weak var parentWindow: NSWindow?
    private let menu: NSMenu
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var hoverPoller: CaptureCatHoverPoller?
    private var isDismissed = false
    /// A row was picked: the menu is inert while its wash blinks.
    private var isCommitting = false

    // Flyout chain: submenus open as sibling sessions to the side, macOS-style.
    private weak var parentSession: CaptureCatMenuSession?
    fileprivate private(set) var childSession: CaptureCatMenuSession?
    /// The row whose submenu is currently flown out (kept highlighted).
    private weak var flyoutRow: CCMenuRow?
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
        CCMenuStage.configure(panel)
    }

    func show(relativeTo rect: NSRect, edge: CaptureCatMenuPresenter.Edge, selectedItem: NSMenuItem?) {
        rebuild(selectedItem: selectedItem, anchor: rect)
        let origin = CaptureCatPopupGeometry.origin(
            anchor: rect,
            popupSize: stage.surfaceSize,
            prefersAbove: edge == .above,
            horizontalAlignment: .leading,
            gap: 5
        )
        place(origin)
        installAndOrder(edge: origin.y >= rect.maxY - 0.5 ? .bottom : .top,
                        anchor: NSPoint(x: rect.midX, y: rect.midY), scales: true)
    }

    func show(at point: NSPoint) {
        let anchor = NSRect(origin: point, size: .zero)
        rebuild(selectedItem: nil, anchor: anchor)
        let origin = CaptureCatPopupGeometry.origin(
            anchor: anchor,
            popupSize: stage.surfaceSize,
            prefersAbove: false,
            horizontalAlignment: .leading,
            gap: 2
        )
        place(origin)
        installAndOrder(edge: origin.y >= point.y - 0.5 ? .bottom : .top, anchor: point, scales: true)
    }

    func dismiss() {
        guard !isDismissed else { return }
        isDismissed = true
        hoverTimer?.invalidate()
        hoverTimer = nil
        closeChild()
        stopTracking()
        // Sessions are one-shot, so the fade-out can safely outlive `self`.
        let panel = self.panel
        let parent = parentWindow
        stage.playClose {
            parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        onDismiss?()
        onDismiss = nil
    }

    private func stopTracking() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        hoverPoller?.stop()
        hoverPoller = nil
    }

    private func place(_ surfaceOrigin: NSPoint) {
        panel.setFrame(stage.panelFrame(surfaceOrigin: surfaceOrigin), display: false)
    }

    // MARK: - Flyout chain plumbing

    private func rootSession() -> CaptureCatMenuSession { parentSession?.rootSession() ?? self }
    private func deepestSession() -> CaptureCatMenuSession { childSession?.deepestSession() ?? self }
    private func chainSessions() -> [CaptureCatMenuSession] { [self] + (childSession?.chainSessions() ?? []) }

    private func closeChild() {
        // The flyout row keeps the highlight for keyboard continuity (← / ⎋
        // step back onto it); hover moves it on as usual.
        list.pinnedRow = nil
        flyoutRow = nil
        childSession?.dismiss()
        childSession = nil
    }

    /// Fly the row's submenu out beside it (or focus the existing flyout).
    private func openSubmenu(for row: CCMenuRow) {
        guard let submenu = (row.representedObject as? NSMenuItem)?.submenu, let parentWindow else { return }
        if flyoutRow === row { return }
        closeChild()
        let child = CaptureCatMenuSession(menu: submenu, parentWindow: parentWindow)
        child.parentSession = self
        childSession = child
        flyoutRow = row
        list.pinnedRow = row
        list.setHighlighted(row)
        let rowOnScreen = CaptureCatPopupGeometry.screenRect(of: row.bounds, in: row) ?? .zero
        child.show(flyoutFrom: rowOnScreen, selectedItem: submenu.items.first(where: { $0.state == .on }))
    }

    /// Hover intent from the list: submenu rows pop their flyout after a short
    /// dwell (140 ms); plain rows retire an open flyout after a slightly longer
    /// one (300 ms grace — a diagonal move into the flyout doesn't slam it shut).
    fileprivate func rowHovered(_ row: CCMenuRow?) {
        hoverTimer?.invalidate()
        hoverTimer = nil
        guard let row, !rootSession().isCommitting else { return }
        if (row.representedObject as? NSMenuItem)?.submenu != nil, row.isEnabled {
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

    /// Present as a flyout: anchored beside the parent row (its first row
    /// level with it), flipping to the left edge when the screen runs out.
    private func show(flyoutFrom rowRect: NSRect, selectedItem: NSMenuItem?) {
        rebuild(selectedItem: selectedItem, anchor: rowRect)
        let size = stage.surfaceSize
        let visible = CCMenuStage.visibleFrame(for: rowRect).insetBy(dx: 8, dy: 8)
        // The parent surface's edge sits one padding beyond the row.
        var x = rowRect.maxX + CCMenu.padding + 2
        var flyEdge: CCMenuStage.Edge = .left
        if x + size.width > visible.maxX {
            x = rowRect.minX - CCMenu.padding - 2 - size.width
            flyEdge = .right
        }
        // Top-align the flyout's first row with its row (menu coordinates are Y-up).
        var y = rowRect.maxY + CCMenu.padding - size.height
        y = min(max(y, visible.minY), visible.maxY - size.height)
        place(NSPoint(x: max(visible.minX, x), y: y))
        installAndOrder(edge: flyEdge, anchor: NSPoint(x: rowRect.midX, y: rowRect.midY), scales: false)
    }

    private func installAndOrder(edge: CCMenuStage.Edge, anchor: NSPoint, scales: Bool) {
        parentWindow?.addChildWindow(panel, ordered: .above)
        stage.prepareForOpen()
        panel.orderFront(nil)
        // Flyouts slide + fade only; root menus also scale and stagger rows.
        stage.playOpen(from: edge, anchor: anchor, list: parentSession == nil ? list : nil, scales: scales)

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
            if event.type == .keyDown {
                if self.isCommitting { return nil }
                return self.deepestSession().handleKey(event) ? nil : event
            }
            if let window = event.window,
               let session = self.chainSessions().first(where: { $0.panel === window }),
               session.stage.surfaceContains(windowPoint: event.locationInWindow) {
                return event
            }
            self.dismiss()
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard !CCMenu.probeIsolated else { return }
            self?.dismiss()
        }
    }

    /// Root-session hover routing: find the chain panel under the pointer and
    /// hand its list the hover; every other session in the chain clears (the
    /// flyout row's own highlight persists via the list's `pinnedRow`).
    private func routeHoverAcrossChain(screenPoint: NSPoint) {
        guard !isCommitting else { return }
        for session in chainSessions() {
            let inside = session.panel.isVisible
                && (session.stage.surfaceScreenRect?.contains(screenPoint) ?? false)
            if inside {
                session.list.routeHover(windowPoint: session.panel.convertPoint(fromScreen: screenPoint))
            } else {
                session.list.clearHover()
            }
        }
    }

    private func rebuild(selectedItem: NSMenuItem?, anchor: NSRect) {
        let list = CCMenuList()
        for item in menu.items where !item.isHidden {
            if item.isSeparatorItem {
                list.addSeparator()
                continue
            }
            if item.isSectionHeader {
                list.addHeader(item.title)
                continue
            }
            let row = CCMenuRow(Self.model(for: item))
            row.representedObject = item
            list.add(row)
        }
        list.onActivate = { [weak self] row in self?.activate(row) }
        list.onHover = { [weak self] row in self?.rowHovered(row) }
        self.list = list

        let width = list.fittingWidth()
        list.layoutEntries(width: width)
        let height = min(list.frame.height, CCMenuStage.maxSurfaceHeight(for: anchor))
        let scroll = list.embedInScrollView(visibleHeight: height)
        stage.setContent(scroll, inset: 0)
        stage.resize(surfaceSize: NSSize(width: width, height: height))
        panel.contentView = stage

        if let selectedItem, let row = list.rows.first(where: { $0.representedObject === selectedItem }) {
            list.setHighlighted(row, animated: false)
            row.scrollToVisible(row.bounds)
        }
    }

    private static func model(for item: NSMenuItem) -> CCMenuRow.Model {
        var color: NSColor?
        if let attributed = item.attributedTitle, attributed.length > 0 {
            color = attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        }
        let accessory: CCMenuRow.Accessory = item.submenu != nil ? .submenu
            : item.state == .on ? .check
            : item.state == .mixed ? .mixed
            : .none
        let shortcut = shortcut(for: item)
        return CCMenuRow.Model(
            style: .simple,
            icon: item.image.map { .image($0) },
            title: item.title,
            titleColor: color,
            shortcut: shortcut.isEmpty ? nil : shortcut,
            accessory: accessory,
            isEnabled: item.isEnabled
        )
    }

    private func activate(_ row: CCMenuRow) {
        guard let item = row.representedObject as? NSMenuItem, item.isEnabled else { return }
        let root = rootSession()
        guard !root.isCommitting else { return }
        if item.submenu != nil {
            openSubmenu(for: row)
            childSession?.selectFirst()
            return
        }
        // The pick: the menu goes inert, the row's wash blinks once, then the
        // whole chain closes and the action runs — macOS order.
        root.isCommitting = true
        root.stopTracking()
        for session in root.chainSessions() { session.hoverTimer?.invalidate() }
        list.pulse(row) {
            root.dismiss()
            guard let action = item.action else { return }
            NSApp.sendAction(action, to: item.target, from: item)
        }
    }

    private func selectFirst() {
        list.highlightFirst()
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: // escape — retire the deepest flyout first, then the menu
            if let parentSession { parentSession.closeChild() } else { dismiss() }
            return true
        case 125: list.moveHighlight(1); return true
        case 126: list.moveHighlight(-1); return true
        case 36, 76:
            list.activateHighlighted()
            return true
        case 123: // left arrow — step back out of a flyout
            guard let parentSession else { return false }
            parentSession.closeChild()
            return true
        case 124: // right arrow — fly the highlighted submenu out
            if let row = list.highlightedRow, (row.representedObject as? NSMenuItem)?.submenu != nil {
                activate(row)
                return true
            }
            return false
        default:
            // Type-select, macOS-menu style.
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  let chars = event.charactersIgnoringModifiers, chars.count == 1,
                  chars.rangeOfCharacter(from: .alphanumerics) != nil else { return false }
            return list.typeSelect(chars)
        }
    }

    /// The shortcut as macOS writes it: ⌃⌥⇧⌘ then the key glyph.
    private static func shortcut(for item: NSMenuItem) -> String {
        let key = item.keyEquivalent
        guard !key.isEmpty else { return "" }
        var value = ""
        var modifiers = item.keyEquivalentModifierMask
        // An uppercase key equivalent implies Shift.
        if key.count == 1, key.uppercased() == key, key.lowercased() != key { modifiers.insert(.shift) }
        if modifiers.contains(.control) { value += "⌃" }
        if modifiers.contains(.option) { value += "⌥" }
        if modifiers.contains(.shift) { value += "⇧" }
        if modifiers.contains(.command) { value += "⌘" }
        let glyphs: [String: String] = [
            "\u{8}": "⌫", "\u{7f}": "⌫", "\r": "↩", "\u{3}": "⌤", "\u{1b}": "⎋", "\t": "⇥", " ": "Space",
            String(UnicodeScalar(NSDeleteFunctionKey)!): "⌦",
            String(UnicodeScalar(NSUpArrowFunctionKey)!): "↑",
            String(UnicodeScalar(NSDownArrowFunctionKey)!): "↓",
            String(UnicodeScalar(NSLeftArrowFunctionKey)!): "←",
            String(UnicodeScalar(NSRightArrowFunctionKey)!): "→",
        ]
        return value + (glyphs[key] ?? key.uppercased())
    }
}
