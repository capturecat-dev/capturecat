import AppKit

/// A 30Hz tracking loop for floating panels — the mechanism of last resort
/// that actually works. NSTrackingArea delivery AND app mouse-moved event
/// routing both drop out over the parts of a borderless non-activating child
/// panel that overhang the parent window; polling `NSEvent.mouseLocation`
/// (pure window-server state, no event delivery involved) cannot. Native
/// menus run their own tracking loop for the same reason. Owners start it on
/// present and MUST stop it on dismiss.
@MainActor
final class CCHoverPoller {
    private var timer: Timer?
    private var ticks = 0

    /// Hover-routing diagnostics, retired 2026-08-17 (user call: the log
    /// flood drowned real output). Flip to `true` in code when debugging
    /// hover delivery — the old capHoverDebug defaults key is ignored so a
    /// stale default can never re-enable the flood on a user's machine.
    static let debug = false

    init(_ tick: @escaping @MainActor () -> Void) {
        if Self.debug { NSLog("CCHoverPoller START") }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { _ in
            MainActor.assumeIsolated {
                tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        if Self.debug {
            let heartbeat = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    NSLog("CCHoverPoller alive mouse=%@", NSStringFromPoint(NSEvent.mouseLocation))
                    _ = self
                }
            }
            RunLoop.main.add(heartbeat, forMode: .common)
            heartbeatTimer = heartbeat
        }
    }

    private var heartbeatTimer: Timer?

    func stop() {
        if Self.debug { NSLog("CCHoverPoller STOP") }
        timer?.invalidate()
        timer = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }
}

/// CCKit combobox — shadcn's Combobox: a trigger pill that opens a floating
/// panel with a search field and a filtered option list. `CCSelect` is the
/// same control without the search row (shadcn's Select) — one popup, one
/// keyboard model, one glide highlight for both.
///
///     let combo = CCCombobox(placeholder: "Select a font…")
///     combo.options = fonts.map { .init(title: $0) }
///     combo.selectedIndex = 2
///     combo.onSelect = { index in ... }
///
/// Behaviors that are deliberate, learned the hard way elsewhere in the app:
///  • Hover in the popup is driven by a polled tracking loop (CCHoverPoller),
///    never by NSTrackingArea — real enter/moved delivery to borderless child
///    panels drops events over regions overhanging the parent window.
///  • The panel CAN become key (unlike menus) — the search field needs typing,
///    and the searchless select needs ↑/↓/↩/⎋ routed via the panel itself.
///  • All colors re-apply live on theme change (CCThemeObservation).
///  • ↑/↓ move the active row, ↩ commits it, ⎋ closes; the wash glides
///    between hover and keyboard positions on the house spring.
@MainActor
class CCCombobox: NSControl {
    struct Option: Equatable {
        var title: String
        var subtitle: String? = nil
    }

    /// Trigger scale: `.regular` for forms, `.sm` for title bars and dense
    /// toolbars — same rationale as CCSegmented.Size.
    enum Size {
        case sm
        case regular

        var height: CGFloat {
            switch self {
            case .sm: return 24
            case .regular: return 30
            }
        }

        var hPadding: CGFloat {
            switch self {
            case .sm: return 9
            case .regular: return 11
            }
        }

        var chevronPointSize: CGFloat {
            switch self {
            case .sm: return 8
            case .regular: return 9
            }
        }

        @MainActor var font: NSFont {
            let base = CCTheme.font.chip
            switch self {
            case .sm: return NSFont(descriptor: base.fontDescriptor, size: base.pointSize - 1.5) ?? base
            case .regular: return base
            }
        }
    }

    /// Chrome weight — see CCSegmented.Chrome: `.plain` is the title-bar
    /// look (bare at rest, hover wash, no border box).
    enum Chrome {
        case elevated
        case plain
    }

    let size: Size
    let chrome: Chrome
    var options: [Option] = []
    var placeholder: String {
        didSet { refreshTrigger() }
    }
    var searchPlaceholder = "Search…"
    /// Shown when the filter matches nothing.
    var emptyText = "No results"
    var onSelect: ((Int) -> Void)?
    /// Corner scale for the trigger; `.full` = capsule.
    var radius: CCRadius = .md {
        didSet { needsLayout = true }
    }
    /// False = shadcn Select: no search row, panel-routed keyboard.
    let searchable: Bool

    var selectedIndex: Int? {
        didSet { refreshTrigger() }
    }

    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1 : CCTheme.current.disabledAlpha }
    }

    private let label = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private var isHovering = false
    private var trackingArea: NSTrackingArea?
    private var themeObservation: CCThemeObservation?
    private var popup: CCComboboxPopup?

    /// Minimum trigger width — compact placements (toolbars) lower it so a
    /// short value like "16:9" doesn't carry form-width chrome.
    var minTriggerWidth: CGFloat = 180 {
        didSet { invalidateIntrinsicContentSize() }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: max(minTriggerWidth, label.intrinsicContentSize.width + 58),
            height: size.height
        )
    }

    init(
        placeholder: String = "Select…",
        searchable: Bool = true,
        size: Size = .regular,
        chrome: Chrome = .elevated
    ) {
        self.placeholder = placeholder
        self.searchable = searchable
        self.size = size
        self.chrome = chrome
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        label.font = size.font
        label.lineBreakMode = .byTruncatingTail
        chevron.image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size.chevronPointSize, weight: .semibold))
        for view in [label, chevron] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: size.height),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: size.hPadding),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: CCSpace.sm),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -size.hPadding + 1),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        refreshTrigger()
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        layer?.cornerRadius = radius.resolved(for: bounds.height)
        if let layer { CCMaterial.refit(layer, radius: radius.resolved(for: bounds.height)) }
    }

    private func refreshTrigger() {
        let text: String
        if let selectedIndex, options.indices.contains(selectedIndex) {
            text = options[selectedIndex].title
        } else {
            text = placeholder
        }
        if text != label.stringValue {
            // Picking an option swaps the trigger text: crossfade it and
            // glide any width change instead of snapping.
            CCMotion.fadeContentSwap(label)
            label.stringValue = text
        }
        applyTheme()
        invalidateIntrinsicContentSize()
        CCMotion.animateLayout(self)
    }

    private func applyTheme() {
        guard let layer else { return }
        let colors = CCTheme.color
        let hasValue = selectedIndex.map { options.indices.contains($0) } ?? false
        switch chrome {
        case .elevated:
            let washTint: NSColor = CCTheme.isDark ? .white : .black
            let fill = isHovering
                ? colors.elevated.blended(withFraction: 0.06, of: washTint) ?? colors.elevated
                : colors.elevated
            layer.backgroundColor = fill.cgColor
            // Open state carries via the popup itself — no ring (removed).
            layer.borderColor = colors.border.cgColor
            // Skeuo: the trigger is a well the value sits inside.
            CCMaterial.dress(layer, as: .recessed(tint: fill),
                             radius: radius.resolved(for: bounds.height))
        case .plain:
            // Bare at rest; hover shows the quiet wash, open holds it.
            let wash: NSColor = popup != nil
                ? colors.active
                : (isHovering ? colors.hover : .clear)
            layer.backgroundColor = wash.cgColor
            layer.borderColor = NSColor.clear.cgColor
            if wash.alphaComponent < 0.01 {
                CCMaterial.strip(layer)
            } else {
                CCMaterial.dress(layer, as: .raised(tint: wash),
                                 radius: radius.resolved(for: bounds.height))
            }
        }
        label.textColor = hasValue ? colors.foreground : colors.mutedForeground
        chevron.contentTintColor = colors.mutedForeground
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
        applyTheme()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        applyTheme()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        popup == nil ? open() : dismissPopup()
    }

    // MARK: - Popup lifecycle

    func open() {
        guard popup == nil, window != nil else { return }
        let popup = CCComboboxPopup(
            options: options,
            selectedIndex: selectedIndex,
            searchPlaceholder: searchPlaceholder,
            emptyText: emptyText,
            minWidth: max(bounds.width, searchable ? 220 : bounds.width),
            searchable: searchable
        )
        popup.onCommit = { [weak self] index in
            guard let self else { return }
            self.dismissPopup()
            if index != self.selectedIndex {
                self.selectedIndex = index
                self.onSelect?(index)
            }
        }
        popup.onDismiss = { [weak self] in
            self?.popup = nil
            self?.applyTheme()
        }
        self.popup = popup
        popup.present(below: self)
        applyTheme()
    }

    func dismissPopup() {
        popup?.dismiss()
    }

    // MARK: - Harness seams (drive the REAL popup, no parallel logic)

    var probePopup: CCComboboxPopup? { popup }
}

/// CCKit select — shadcn's Select: the combobox trigger + option panel with
/// the search row omitted. ↑/↓/↩/⎋ work immediately via the panel; the
/// glide highlight and row pooling are the combobox's, not a copy.
///
///     let quality = CCSelect(placeholder: "Quality…")
///     quality.options = ["Low", "Medium", "High"].map { .init(title: $0) }
///     quality.onSelect = { index in ... }
@MainActor
final class CCSelect: CCCombobox {
    init(placeholder: String = "Select…", size: Size = .regular, chrome: Chrome = .elevated) {
        super.init(placeholder: placeholder, searchable: false, size: size, chrome: chrome)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

// MARK: - Popup

/// The floating search-and-list surface. Internal (not private) so the kit
/// gallery harness can drive the real filtering/keyboard machinery.
@MainActor
final class CCComboboxPopup: NSObject, NSTextFieldDelegate {
    var onCommit: ((Int) -> Void)?
    var onDismiss: (() -> Void)?

    private let options: [CCCombobox.Option]
    private let searchable: Bool
    private let searchField: CCField
    private let emptyLabel: NSTextField
    private let listStack = NSStackView()
    private let chrome = NSView()
    private let scroll = NSScrollView()
    private let panel: CCComboboxKeyPanel
    private weak var parentWindow: NSWindow?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var hoverPoller: CCHoverPoller?
    private var themeObservation: CCThemeObservation?

    private var glide: CCGlideHighlight?
    /// Reusable row pool — rows are REBOUND on filter changes, never
    /// recreated: with big option sets (the font list is every installed
    /// family, 300+) per-keystroke row rebuilding froze the main thread,
    /// which also starved the hover poller. The pool is capped; matches
    /// beyond it are reachable by narrowing the search.
    private var rowPool: [CCComboboxRow] = []
    private var rows: [CCComboboxRow] = []
    private let moreLabel = NSTextField(labelWithString: "")
    private static let maxVisibleRows = 80
    /// Indices into `options` for the rows currently shown.
    private(set) var visibleIndices: [Int] = []
    private var activeRow: Int? // index into `rows`
    private weak var hoveredRow: CCComboboxRow?
    private let selectedIndex: Int?
    private let minWidth: CGFloat

    private static let rowHeight: CGFloat = 30
    private static let maxListHeight: CGFloat = 9.5 * rowHeight

    init(
        options: [CCCombobox.Option],
        selectedIndex: Int?,
        searchPlaceholder: String,
        emptyText: String,
        minWidth: CGFloat,
        searchable: Bool = true
    ) {
        self.options = options
        self.selectedIndex = selectedIndex
        self.minWidth = minWidth
        self.searchable = searchable
        searchField = CCField(placeholder: searchPlaceholder)
        emptyLabel = NSTextField(labelWithString: emptyText)
        panel = CCComboboxKeyPanel(
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
        // Searchless select: no field editor to route keys through, so the
        // panel itself drives the active row.
        panel.onKeyCommand = { [weak self] selector in
            self?.handleKeyCommand(selector) ?? false
        }
        buildChrome()
    }

    private func buildChrome() {
        chrome.wantsLayer = true
        chrome.layer?.cornerCurve = .continuous
        chrome.layer?.borderWidth = 1
        chrome.layer?.shadowColor = NSColor.black.cgColor
        chrome.layer?.shadowRadius = 18
        chrome.layer?.shadowOffset = CGSize(width: 0, height: -6)

        searchField.delegate = self
        searchField.onTextChange = { [weak self] text in self?.applyFilter(text) }

        let divider = CCDivider()

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 2
        listStack.edgeInsets = NSEdgeInsets(top: 5, left: 5, bottom: 5, right: 5)

        let clipDoc = CCComboboxFlippedView()
        listStack.translatesAutoresizingMaskIntoConstraints = false
        clipDoc.addSubview(listStack)
        scroll.documentView = clipDoc
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        clipDoc.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = CCTheme.font.label
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        moreLabel.font = CCTheme.font.caption
        moreLabel.alignment = .center

        let header: [NSView] = searchable ? [searchField, divider] : []
        for view in header + [scroll, emptyLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            chrome.addSubview(view)
        }
        let listTop: NSLayoutYAxisAnchor
        if searchable {
            NSLayoutConstraint.activate([
                searchField.topAnchor.constraint(equalTo: chrome.topAnchor, constant: 6),
                searchField.leadingAnchor.constraint(equalTo: chrome.leadingAnchor, constant: 6),
                searchField.trailingAnchor.constraint(equalTo: chrome.trailingAnchor, constant: -6),

                divider.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
                divider.leadingAnchor.constraint(equalTo: chrome.leadingAnchor),
                divider.trailingAnchor.constraint(equalTo: chrome.trailingAnchor),
            ])
            listTop = divider.bottomAnchor
        } else {
            listTop = chrome.topAnchor
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: listTop, constant: searchable ? 0 : 1),
            scroll.leadingAnchor.constraint(equalTo: chrome.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: chrome.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: chrome.bottomAnchor, constant: -1),

            emptyLabel.centerXAnchor.constraint(equalTo: chrome.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: listTop, constant: 14),

            clipDoc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            clipDoc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            clipDoc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            listStack.leadingAnchor.constraint(equalTo: clipDoc.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: clipDoc.trailingAnchor),
            listStack.topAnchor.constraint(equalTo: clipDoc.topAnchor),
            listStack.bottomAnchor.constraint(equalTo: clipDoc.bottomAnchor),
        ])

        glide = CCGlideHighlight(host: chrome)
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
        applyFilter("")
    }

    private func applyTheme() {
        chrome.layer?.backgroundColor = CCTheme.color.popover.cgColor
        chrome.layer?.borderColor = CCTheme.color.border.cgColor
        chrome.layer?.shadowOpacity = CCTheme.isDark ? 0.48 : 0.2
        chrome.layer?.cornerRadius = CCTheme.radius(.lg)
        emptyLabel.textColor = CCTheme.color.mutedForeground
        moreLabel.textColor = CCTheme.color.faintForeground
    }

    // MARK: - Filtering

    private func poolRow(at index: Int) -> CCComboboxRow {
        while rowPool.count <= index {
            let row = CCComboboxRow()
            row.onPick = { [weak self, weak row] in
                guard let self, let row, let position = self.rows.firstIndex(of: row) else { return }
                self.onCommit?(self.visibleIndices[position])
            }
            row.onHighlight = { [weak self] row, active in
                self?.glide?.update(row: row, active: active)
            }
            listStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: listStack.widthAnchor, constant: -10).isActive = true
            rowPool.append(row)
        }
        return rowPool[index]
    }

    func applyFilter(_ text: String) {
        hoveredRow?.setHovered(false)
        hoveredRow = nil
        let query = text.trimmingCharacters(in: .whitespaces)
        visibleIndices = options.indices.filter { index in
            query.isEmpty || options[index].title.localizedCaseInsensitiveContains(query)
                || (options[index].subtitle?.localizedCaseInsensitiveContains(query) ?? false)
        }
        emptyLabel.isHidden = !visibleIndices.isEmpty

        let shown = min(visibleIndices.count, Self.maxVisibleRows)
        rows = (0..<shown).map { position in
            let optionIndex = visibleIndices[position]
            let row = poolRow(at: position)
            row.bind(option: options[optionIndex], isSelected: optionIndex == selectedIndex)
            row.isHidden = false
            return row
        }
        // Hide (never destroy) the rest of the pool.
        for index in shown..<rowPool.count { rowPool[index].isHidden = true }
        // Overflow hint sits at the end of the list.
        moreLabel.removeFromSuperview()
        if visibleIndices.count > shown {
            moreLabel.stringValue = "\(visibleIndices.count - shown) more — keep typing to narrow"
            listStack.addArrangedSubview(moreLabel)
        }

        // Filtering restarts keyboard focus at the top match.
        setActiveRow(rows.isEmpty ? nil : 0)
        layoutPanel()
    }

    private func setActiveRow(_ index: Int?) {
        if let activeRow, rows.indices.contains(activeRow) {
            rows[activeRow].setKeyboardActive(false)
        }
        activeRow = index
        if let index, rows.indices.contains(index) {
            rows[index].setKeyboardActive(true)
            chrome.layoutSubtreeIfNeeded()
            rows[index].scrollToVisible(rows[index].bounds)
        }
    }

    // MARK: - Keyboard
    // One command handler for both entry points: the search field's delegate
    // (searchable) and the panel's keyDown (searchless select).

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        handleKeyCommand(selector)
    }

    private func handleKeyCommand(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            moveActive(1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveActive(-1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            commitActive()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
            return true
        default:
            return false
        }
    }

    private func moveActive(_ delta: Int) {
        guard !rows.isEmpty else { return }
        let next = ((activeRow ?? -delta) + delta + rows.count) % rows.count
        setActiveRow(next)
    }

    func commitActive() {
        guard let activeRow, visibleIndices.indices.contains(activeRow) else { return }
        onCommit?(visibleIndices[activeRow])
    }

    // MARK: - Presentation

    func present(below trigger: NSView) {
        guard let window = trigger.window else { return }
        parentWindow = window
        panel.contentView = chrome
        layoutPanel()

        let anchorOnScreen = window.convertToScreen(trigger.convert(trigger.bounds, to: nil))
        var origin = NSPoint(x: anchorOnScreen.minX, y: anchorOnScreen.minY - panel.frame.height - 5)
        if let visible = window.screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - panel.frame.width - 8)
            if origin.y < visible.minY + 8 {
                origin.y = anchorOnScreen.maxY + 5
            }
        }
        panel.setFrameOrigin(origin)
        window.addChildWindow(panel, ordered: .above)
        panel.alphaValue = 0
        panel.orderFront(nil)
        panel.makeKey()
        if searchable { panel.makeFirstResponder(searchField) }
        if let layer = chrome.layer {
            let frame = layer.frame
            layer.anchorPoint = CGPoint(x: 0.5, y: 1)
            layer.frame = frame
            layer.transform = CATransform3DMakeScale(0.96, 0.96, 1)
            CCMotion.spring(layer, keyPath: "transform.scale", to: 1.0, .smooth)
        }
        CCMotion.run(duration: 0.18, curve: CCMotion.glide) {
            self.panel.animator().alphaValue = 1
        }

        // Polled hover — floating panels drop tracking-area AND moved-event
        // delivery over regions overhanging the parent window; polling the
        // window-server cursor position cannot (see CCHoverPoller).
        hoverPoller = CCHoverPoller { [weak self] in
            self?.routeHover(screenPoint: NSEvent.mouseLocation)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.window !== self.panel { self.dismiss() }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismiss()
        }
    }

    private func layoutPanel() {
        chrome.layoutSubtreeIfNeeded()
        let listHeight = min(Self.maxListHeight, listStack.fittingSize.height)
        let emptyHeight: CGFloat = visibleIndices.isEmpty ? 44 : 0
        let headerHeight: CGFloat = searchable
            ? 6 + searchField.intrinsicContentSize.height + 6 + 1
            : 1
        let height = headerHeight + max(listHeight, emptyHeight) + 1
        panel.setContentSize(NSSize(width: minWidth, height: height))
    }

    private func routeHover(screenPoint: NSPoint) {
        var target: CCComboboxRow? = nil
        if panel.isVisible, panel.frame.contains(screenPoint) {
            let windowPoint = panel.convertPoint(fromScreen: screenPoint)
            let point = chrome.convert(windowPoint, from: nil)
            // Gap-tolerant hit test — see CCGlideHighlight's appearing note.
            target = rows.first {
                !$0.frame.isEmpty && chrome.convert($0.bounds, from: $0).insetBy(dx: 0, dy: -1).contains(point)
            }
        }
        guard target !== hoveredRow else { return }
        if CCHoverPoller.debug {
            NSLog("CCCombobox hover -> row=%d", target.flatMap { rows.firstIndex(of: $0) } ?? -1)
        }
        hoveredRow?.setHovered(false)
        hoveredRow = target
        target?.setHovered(true)
    }

    func dismiss() {
        guard localMonitor != nil || panel.isVisible else { return }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        hoverPoller?.stop()
        hoverPoller = nil
        let panel = self.panel
        let parent = parentWindow
        CCMotion.run(duration: 0.12, curve: CCMotion.glide, {
            panel.animator().alphaValue = 0
        }, completion: {
            parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        })
        parent?.makeKey()
        onDismiss?()
        onDismiss = nil
    }

    // MARK: - Harness seams

    var probeSearchField: CCField { searchField }
    var probeSearchVisible: Bool { searchField.superview != nil }
    var probeRowTitles: [String] { visibleIndices.map { options[$0].title } }
    var probeActiveRow: Int? { activeRow }
    var probePanel: NSWindow { panel }
    /// Harness seam for the searchless keyboard path — same routing the real
    /// panel keyDown uses.
    func probeSendKey(_ selector: Selector) -> Bool { handleKeyCommand(selector) }
}

// MARK: - One-shot presentation

extension CCComboboxPopup {
    /// The popup currently presented via `present(options:from:)` — one at a
    /// time, retained here until it dismisses (the caller holds nothing).
    private static var oneShot: CCComboboxPopup?

    /// Presents the house option popup from ANY anchor view — the reusable
    /// path for triggers that aren't a CCCombobox/CCSelect control
    /// (recording-panel chips, toolbar buttons). Same panel, rows, keyboard
    /// model, and glide highlight as the combobox; the popup retains itself
    /// until committed or dismissed.
    @discardableResult
    static func present(
        options: [CCCombobox.Option],
        selectedIndex: Int? = nil,
        from anchor: NSView,
        searchable: Bool = false,
        searchPlaceholder: String = "Search…",
        emptyText: String = "No options",
        minWidth: CGFloat = 220,
        onSelect: @escaping (Int) -> Void
    ) -> CCComboboxPopup {
        oneShot?.dismiss()
        let popup = CCComboboxPopup(
            options: options,
            selectedIndex: selectedIndex,
            searchPlaceholder: searchPlaceholder,
            emptyText: emptyText,
            minWidth: max(minWidth, anchor.bounds.width),
            searchable: searchable
        )
        // Weak: onCommit lives on the popup itself, so a strong capture would
        // be a retain cycle that outlives the dismissal. `oneShot` keeps the
        // popup alive while it is on screen.
        popup.onCommit = { [weak popup] index in
            popup?.dismiss()
            onSelect(index)
        }
        popup.onDismiss = {
            if oneShot === popup { oneShot = nil }
        }
        oneShot = popup
        popup.present(below: anchor)
        return popup
    }
}

// MARK: - Row

@MainActor
private final class CCComboboxRow: NSControl {
    var onPick: (() -> Void)?
    var onHighlight: ((CCComboboxRow, Bool) -> Void)?

    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private let check = NSImageView()
    private var isHovering = false
    private var isKeyboardActive = false
    private var themeObservation: CCThemeObservation?

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: 120 + titleField.intrinsicContentSize.width, height: 30)
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous

        titleField.font = CCTheme.font.chip
        titleField.lineBreakMode = .byTruncatingTail
        subtitleField.font = CCTheme.font.caption
        for view in [titleField, subtitleField, check] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            subtitleField.leadingAnchor.constraint(equalTo: titleField.trailingAnchor, constant: CCSpace.sm),
            subtitleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            check.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Pool rebinding — filter changes update contents in place instead of
    /// recreating rows (see CCComboboxPopup.rowPool).
    func bind(option: CCCombobox.Option, isSelected: Bool) {
        titleField.stringValue = option.title
        subtitleField.stringValue = option.subtitle ?? ""
        subtitleField.isHidden = option.subtitle == nil
        // Selection check trails, far right — house rule.
        check.image = isSelected
            ? NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .bold))
            : nil
        setHovered(false)
        setKeyboardActive(false)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = CCTheme.radius(.md)
    }

    private func applyTheme() {
        titleField.textColor = CCTheme.color.foreground
        subtitleField.textColor = CCTheme.color.faintForeground
        check.contentTintColor = CCTheme.color.primary
    }

    /// Hover is dispatched by the popup's event monitor — no tracking areas.
    func setHovered(_ hovered: Bool) {
        guard hovered != isHovering else { return }
        isHovering = hovered
        refresh()
    }

    func setKeyboardActive(_ active: Bool) {
        guard active != isKeyboardActive else { return }
        isKeyboardActive = active
        refresh()
    }

    private func refresh() {
        onHighlight?(self, isHovering || isKeyboardActive)
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPick?()
    }
}

/// Borderless panels refuse key status by default; the search field needs it.
/// For the searchless select the panel is also the keyboard target: keyDown
/// maps arrows/return/escape onto the popup's command handler.
private final class CCComboboxKeyPanel: NSPanel {
    var onKeyCommand: ((Selector) -> Bool)?

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        let selector: Selector?
        switch event.keyCode {
        case 125: selector = #selector(NSResponder.moveDown(_:))
        case 126: selector = #selector(NSResponder.moveUp(_:))
        case 36, 76: selector = #selector(NSResponder.insertNewline(_:))
        case 53: selector = #selector(NSResponder.cancelOperation(_:))
        default: selector = nil
        }
        if let selector, onKeyCommand?(selector) == true { return }
        super.keyDown(with: event)
    }
}

private final class CCComboboxFlippedView: NSView {
    override var isFlipped: Bool { true }
}
