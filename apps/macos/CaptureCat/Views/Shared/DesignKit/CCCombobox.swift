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
                // Probes drive hover through the real dispatchers themselves;
                // the user's actual pointer must never leak into them.
                guard !CCMenu.probeIsolated else { return }
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
        chevron.image = CCIcon.image("chevron.up.chevron.down", pointSize: size.chevronPointSize, weight: .semibold)
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

/// The floating search-and-list surface — the house menu (CCMenuStage +
/// CCMenuList, see CCMenu.swift) with an optional search row on top.
/// Internal (not private) so the kit gallery harness can drive the real
/// filtering/keyboard machinery.
@MainActor
final class CCComboboxPopup: NSObject, NSTextFieldDelegate {
    var onCommit: ((Int) -> Void)?
    var onDismiss: (() -> Void)?

    private let options: [CCCombobox.Option]
    private let searchable: Bool
    private let searchField: CCField
    private let emptyLabel: NSTextField
    private let divider = CCDivider()
    private let list = CCMenuList()
    private let body = CCComboboxFlippedView()
    private var scroll: NSScrollView?
    private let stage = CCMenuStage()
    private let panel: CCComboboxKeyPanel
    private weak var parentWindow: NSWindow?
    private var anchorOnScreen = NSRect.zero
    private var opensUpward = false
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var hoverPoller: CCHoverPoller?
    private var themeObservation: CCThemeObservation?

    /// Reusable row pool — rows are REBOUND on filter changes, never
    /// recreated: with big option sets (the font list is every installed
    /// family, 300+) per-keystroke row rebuilding froze the main thread,
    /// which also starved the hover poller. The pool is capped; matches
    /// beyond it are reachable by narrowing the search.
    private var rowPool: [CCMenuRow] = []
    private var rows: [CCMenuRow] = []
    private let moreLabel = NSTextField(labelWithString: "")
    private static let maxVisibleRows = 80
    /// Indices into `options` for the rows currently shown.
    private(set) var visibleIndices: [Int] = []
    private let selectedIndex: Int?
    private let minWidth: CGFloat
    private var width: CGFloat = 0
    /// Searchable lists stop growing at ~10 rows (typing narrows them);
    /// a plain select grows until the screen runs out.
    private static let searchableListCap: CGFloat = 10.5 * (CCMenu.simpleRowHeight + 1) + CCMenu.padding * 2
    private var pulsingRow: CCMenuRow?
    private var isDismissed = false

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
        CCMenuStage.configure(panel)
        // Searchless select: no field editor to route keys through, so the
        // panel itself drives the highlighted row.
        panel.onKeyCommand = { [weak self] selector in
            self?.handleKeyCommand(selector) ?? false
        }
        buildBody()
    }

    private func buildBody() {
        searchField.delegate = self
        searchField.onTextChange = { [weak self] text in self?.applyFilter(text) }
        emptyLabel.font = CCTheme.font.label
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        moreLabel.font = CCTheme.font.caption
        moreLabel.alignment = .center
        moreLabel.isHidden = true
        if searchable {
            body.addSubview(searchField)
            body.addSubview(divider)
        }
        body.addSubview(emptyLabel)
        body.addSubview(moreLabel)
        list.onActivate = { [weak self] row in
            guard let self, let position = self.rows.firstIndex(where: { $0 === row }) else { return }
            self.commit(position)
        }
        stage.setContent(body, inset: 0)
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
        applyFilter("")
    }

    private func applyTheme() {
        emptyLabel.textColor = CCTheme.color.mutedForeground
        moreLabel.textColor = CCTheme.color.faintForeground
    }

    // MARK: - Filtering

    private func poolRow(at index: Int) -> CCMenuRow {
        while rowPool.count <= index {
            let row = CCMenuRow(.init(title: ""))
            list.add(row)
            rowPool.append(row)
        }
        return rowPool[index]
    }

    func applyFilter(_ text: String) {
        list.clearHover()
        let query = text.trimmingCharacters(in: .whitespaces)
        visibleIndices = options.indices.filter { index in
            query.isEmpty || options[index].title.localizedCaseInsensitiveContains(query)
                || (options[index].subtitle?.localizedCaseInsensitiveContains(query) ?? false)
        }
        emptyLabel.isHidden = !visibleIndices.isEmpty

        let shown = min(visibleIndices.count, Self.maxVisibleRows)
        rows = (0..<shown).map { position in
            let optionIndex = visibleIndices[position]
            let option = options[optionIndex]
            let row = poolRow(at: position)
            // Selection check trails, far right — house rule.
            row.update(.init(title: option.title, subtitle: option.subtitle,
                             accessory: optionIndex == selectedIndex ? .check : .none))
            row.isHidden = false
            return row
        }
        // Hide (never destroy) the rest of the pool.
        for index in shown..<rowPool.count { rowPool[index].isHidden = true }
        moreLabel.isHidden = visibleIndices.count <= shown
        if !moreLabel.isHidden {
            moreLabel.stringValue = "\(visibleIndices.count - shown) more — keep typing to narrow"
        }
        layoutPanel()
        // Unfiltered, the highlight starts on the current value (macOS
        // popup behavior); filtering restarts it at the top match.
        let current = query.isEmpty ? selectedIndex.flatMap { visibleIndices.firstIndex(of: $0) } : nil
        let start = current.flatMap { rows.indices.contains($0) ? rows[$0] : nil } ?? rows.first
        list.setHighlighted(start, animated: false)
        if let start, panel.isVisible { start.scrollToVisible(start.bounds) }
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
            list.moveHighlight(1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            list.moveHighlight(-1)
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

    func commitActive() {
        guard let row = list.highlightedRow, let position = rows.firstIndex(where: { $0 === row }) else { return }
        commit(position)
    }

    /// The pick: the model hears it NOW (synchronously — callers and the
    /// kit gate rely on that); the row's wash blinks once while the
    /// surface closes behind it.
    private func commit(_ position: Int) {
        guard !isDismissed, visibleIndices.indices.contains(position) else { return }
        pulsingRow = rows[position]
        onCommit?(visibleIndices[position])
    }

    // MARK: - Presentation

    func present(below trigger: NSView) {
        guard let window = trigger.window else { return }
        parentWindow = window
        anchorOnScreen = window.convertToScreen(trigger.convert(trigger.bounds, to: nil))
        panel.contentView = stage
        layoutPanel()
        window.addChildWindow(panel, ordered: .above)
        stage.prepareForOpen()
        panel.orderFront(nil)
        panel.makeKey()
        if searchable { panel.makeFirstResponder(searchField) }
        if let current = list.highlightedRow { current.scrollToVisible(current.bounds) }
        stage.playOpen(from: opensUpward ? .bottom : .top,
                       anchor: NSPoint(x: anchorOnScreen.midX, y: anchorOnScreen.midY), list: list)

        // Polled hover — floating panels drop tracking-area AND moved-event
        // delivery over regions overhanging the parent window; polling the
        // window-server cursor position cannot (see CCHoverPoller).
        hoverPoller = CCHoverPoller { [weak self] in
            self?.routeHover(screenPoint: NSEvent.mouseLocation)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.window !== self.panel || !self.stage.surfaceContains(windowPoint: event.locationInWindow) {
                self.dismiss()
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard !CCMenu.probeIsolated else { return }
            self?.dismiss()
        }
    }

    /// Sizes the surface to the list (width fixed once measured, so typing
    /// never jitters it) and keeps the edge facing the trigger pinned.
    private func layoutPanel() {
        let fieldHeight = searchField.intrinsicContentSize.height
        let header: CGFloat = searchable ? 6 + fieldHeight + 6 + 1 : 0
        let measured = list.fittingWidth(minWidth: max(minWidth, CCMenu.minWidth))
        width = max(width, measured)
        let listHeight = rows.isEmpty ? 0 : list.height(forWidth: width)
        list.layoutEntries(width: width)
        let anchor = anchorOnScreen
        let screenCap = CCMenuStage.maxSurfaceHeight(for: anchor) - header
        let cap = searchable ? min(Self.searchableListCap, screenCap) : screenCap
        let visibleList = min(listHeight, cap)
        let emptyHeight: CGFloat = visibleIndices.isEmpty ? 44 : 0
        let moreHeight: CGFloat = moreLabel.isHidden ? 0 : 22
        let height = header + max(visibleList, emptyHeight) + moreHeight

        if scroll == nil {
            let made = list.embedInScrollView(visibleHeight: visibleList)
            body.addSubview(made)
            scroll = made
        }
        if let scroll {
            scroll.frame = NSRect(x: 0, y: header, width: width, height: visibleList)
            let scrolls = listHeight > visibleList + 0.5
            scroll.hasVerticalScroller = scrolls
            scroll.verticalScrollElasticity = scrolls ? .allowed : .none
            scroll.isHidden = rows.isEmpty
        }
        if searchable {
            searchField.frame = NSRect(x: 6, y: 6, width: width - 12, height: fieldHeight)
            divider.frame = NSRect(x: 0, y: 6 + fieldHeight + 6, width: width, height: 1)
        }
        emptyLabel.frame = NSRect(x: 0, y: header + 14, width: width, height: 18)
        moreLabel.frame = NSRect(x: 0, y: height - moreHeight + 3, width: width, height: 16)
        stage.resize(surfaceSize: NSSize(width: width, height: height))

        // Placement: below the trigger, flipping above when the screen runs
        // out; later resizes keep the trigger-facing edge pinned.
        let visible = CCMenuStage.visibleFrame(for: anchor).insetBy(dx: 8, dy: 8)
        guard anchor != .zero else { return }
        if !panel.isVisible {
            opensUpward = anchor.minY - 5 - height < visible.minY && anchor.maxY + 5 + height <= visible.maxY
        }
        let x = min(max(anchor.minX, visible.minX), visible.maxX - width)
        // Neither side fits: stay on screen (overlapping the trigger beats
        // running off the display).
        let y = min(max(opensUpward ? anchor.maxY + 5 : anchor.minY - 5 - height, visible.minY),
                    visible.maxY - height)
        panel.setFrame(stage.panelFrame(surfaceOrigin: NSPoint(x: x, y: y)), display: panel.isVisible)
    }

    private func routeHover(screenPoint: NSPoint) {
        guard panel.isVisible, !isDismissed else { return }
        if let surface = stage.surfaceScreenRect, surface.contains(screenPoint) {
            list.routeHover(windowPoint: panel.convertPoint(fromScreen: screenPoint))
        } else {
            list.clearHover()
        }
    }

    func dismiss() {
        guard !isDismissed else { return }
        isDismissed = true
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        hoverPoller?.stop()
        hoverPoller = nil
        let panel = self.panel
        let parent = parentWindow
        let stage = self.stage
        let close = {
            stage.playClose {
                parent?.removeChildWindow(panel)
                panel.orderOut(nil)
            }
        }
        if let pulsingRow {
            // Picked: blink the chosen row, then close.
            list.pulse(pulsingRow, then: close)
        } else {
            close()
        }
        parent?.makeKey()
        onDismiss?()
        onDismiss = nil
    }

    // MARK: - Harness seams

    var probeSearchField: CCField { searchField }
    var probeSearchVisible: Bool { searchField.superview != nil }
    var probeRowTitles: [String] { visibleIndices.map { options[$0].title } }
    var probeActiveRow: Int? { list.highlightedRow.flatMap { row in rows.firstIndex(where: { $0 === row }) } }
    var probePanel: NSWindow { panel }
    var probeStage: CCMenuStage { stage }
    var probeList: CCMenuList { list }
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
