import AppKit

// CCKit menus — ONE surface, row set and motion for every custom menu in the
// app: NSMenu-backed context/dropdown menus (CaptureCatMenuPresenter), the
// timeline's rich pickers (TimelinePickerPopover) and the combobox/select
// popup (CCComboboxPopup). Presenters keep their own panel, keyboard and
// dismissal logic; everything you can SEE comes from here.
//
//  • CCMenuStage — the panel's content view. A floating `popover` surface
//    (radius .lg, CCMaterial hairline, soft wide shadow) inside a transparent
//    margin the shadow can fall into, plus the open/close motion.
//  • CCMenuList — rows, section headers (+ an optional "why it's disabled"
//    caption) and hairline separators; measures a width where no title ever
//    truncates (min 220, max 380; descriptions wrap to ≤ 2 lines), owns the
//    gliding hover wash, keyboard highlight, the pick pulse and the row
//    stagger.
//  • CCMenuRow — `.simple` (30 pt: icon · title · shortcut cap · check/chevron
//    at the FAR right) or `.rich` (icon tile · title · wrapping description).
//
// Motion (CCMotion; Reduce Motion → fades only): open = 120 ms fade + 0.96→1
// scale on the `.arrive` spring (slight overshoot) pivoting on the edge
// nearest the trigger + a 6 pt slide from that edge; rows stagger in 18 ms
// apart (first 8, the rest with the 8th); hover = the glide wash; pick = the
// wash blinks once (~120 ms) before the menu closes; close = 100 ms fade +
// scale to 0.98; flyouts = 6 pt slide + fade.

// MARK: - Metrics, fonts, switches

@MainActor
enum CCMenu {
    /// Inner padding between the surface edge and the rows.
    static let padding: CGFloat = 6
    static let minWidth: CGFloat = 220
    static let maxWidth: CGFloat = 380
    static let simpleRowHeight: CGFloat = 30
    static let richRowMinHeight: CGFloat = 46
    static let maxDetailLines = 2

    // Motion vocabulary (standard pace; CCMotion.paced scales every value).
    static let openFade: TimeInterval = 0.12
    static let openScale: CGFloat = 0.96
    static let slide: CGFloat = 6
    static let staggerStep: TimeInterval = 0.018
    static let staggerCount = 8
    static let rowFade: TimeInterval = 0.14
    static let closeFade: TimeInterval = 0.1
    static let closeScale: CGFloat = 0.98
    static let pulseDuration: TimeInterval = 0.12

    static var titleFont: NSFont { .systemFont(ofSize: 13) }
    static var richTitleFont: NSFont { .systemFont(ofSize: 13, weight: .semibold) }
    static var detailFont: NSFont { .systemFont(ofSize: 11.5) }
    static var subtitleFont: NSFont { .systemFont(ofSize: 11.5) }
    static var headerFont: NSFont { .systemFont(ofSize: 11, weight: .semibold) }
    static var captionFont: NSFont { .systemFont(ofSize: 11) }

    /// Accessibility: Reduce Motion collapses every menu animation to fades.
    static var reduceMotion: Bool {
        probeReduceMotion ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // MARK: Probe seams (gates only — never set in a normal launch)

    static var probeReduceMotion: Bool?
    /// Keeps the user's REAL pointer and clicks out of a probe's menus: the
    /// hover pollers stop routing and global outside-click monitors ignore
    /// events (the probe drives hover through the real dispatchers itself).
    static var probeIsolated = false
    /// Gate self-tests: deliberately re-introduce a defect so the gate can
    /// prove it bites. "narrow" clamps the width back (descriptions/titles
    /// truncate); "snap" skips the open motion and the row stagger.
    static var probeInjectedDefects: Set<String> = []

    // MARK: Text measurement (shared by layout AND the gate's checks)

    static func label(_ font: NSFont) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = font
        field.isSelectable = false
        // Frames are sized from measurement; a too-small frame must read as
        // a visible ellipsis (and fail the gate), never a silent clip.
        field.lineBreakMode = .byTruncatingTail
        field.allowsDefaultTighteningForTruncation = false
        return field
    }

    static func wrappingLabel(_ font: NSFont) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: "")
        field.font = font
        field.isSelectable = false
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = maxDetailLines
        field.cell?.truncatesLastVisibleLine = true
        return field
    }

    /// Single-line size a label needs (its cell's own measurement).
    static func singleLineSize(_ field: NSTextField) -> NSSize {
        guard let cell = field.cell else { return field.intrinsicContentSize }
        let size = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: 10_000, height: 10_000))
        return NSSize(width: ceil(size.width), height: ceil(size.height))
    }

    private static let scratch: NSTextField = {
        let field = NSTextField(wrappingLabelWithString: "")
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        return field
    }()

    /// Height and line count `text` needs at `width` with UNLIMITED lines —
    /// the true requirement, independent of any line cap on the field.
    static func wrappedRequirement(_ text: String, font: NSFont, width: CGFloat) -> (height: CGFloat, lines: Int) {
        guard !text.isEmpty, width > 0 else { return (0, 0) }
        scratch.font = font
        scratch.stringValue = text
        let bounds = NSRect(x: 0, y: 0, width: width, height: 10_000)
        let height = ceil(scratch.cell?.cellSize(forBounds: bounds).height ?? 0)
        scratch.stringValue = "Ag"
        let line = max(1, ceil(scratch.cell?.cellSize(forBounds: bounds).height ?? 1))
        // Line fragments stack at `line` pitch past the first; round up so a
        // hair of leading never undercounts.
        let lines = max(1, Int(((height - line) / line).rounded(.up)) + 1)
        return (height, height <= line + 0.5 ? 1 : lines)
    }
}

// MARK: - Row

/// One menu row. Hover/keyboard highlight is DISPATCHED by the owning
/// `CCMenuList` (rows own no tracking areas — they drop events inside
/// borderless child panels); clicks are the row's own.
@MainActor
final class CCMenuRow: NSView {
    enum Style { case simple, rich }
    enum Accessory { case none, check, mixed, submenu }
    enum Icon {
        /// A CCIcon/SF name, drawn by the kit at the row's size.
        case named(String)
        /// A ready image (menu items' own images); templates take the ink.
        case image(NSImage)
    }

    struct Model {
        var style: Style = .simple
        var icon: Icon?
        var title: String
        /// Overrides the title ink (destructive items, attributed titles).
        var titleColor: NSColor?
        /// `.simple`: faint text trailing the title ("16:9  YouTube · X").
        var subtitle: String?
        /// `.rich`: the description under the title (wraps ≤ 2 lines).
        var detail: String?
        var shortcut: String?
        var accessory: Accessory = .none
        var isEnabled = true

        init(style: Style = .simple, icon: Icon? = nil, title: String, titleColor: NSColor? = nil,
             subtitle: String? = nil, detail: String? = nil, shortcut: String? = nil,
             accessory: Accessory = .none, isEnabled: Bool = true) {
            self.style = style
            self.icon = icon
            self.title = title
            self.titleColor = titleColor
            self.subtitle = subtitle
            self.detail = detail
            self.shortcut = shortcut
            self.accessory = accessory
            self.isEnabled = isEnabled
        }
    }

    // Geometry (points).
    static let leadPad: CGFloat = 8
    static let simpleTrailPad: CGFloat = 8
    static let richTrailPad: CGFloat = 10
    static let iconSlot: CGFloat = 16
    static let iconGap: CGFloat = 8
    static let tileSide: CGFloat = 30
    static let tileGap: CGFloat = 10
    static let accessorySlot: CGFloat = 12
    static let accessoryGap: CGFloat = 8
    static let shortcutGap: CGFloat = 16
    static let subtitleGap: CGFloat = 6
    static let titleDetailGap: CGFloat = 1
    static let richVPad: CGFloat = 8

    private(set) var model: Model
    /// The source object (e.g. the NSMenuItem this row renders).
    var representedObject: AnyObject?
    /// Set by the list; fires on a genuine click (mouseUp inside).
    var onClick: ((CCMenuRow) -> Void)?
    var isEnabled: Bool { model.isEnabled }

    /// Column reservations, set by the list so every row in a menu aligns.
    var reservesIconColumn = false { didSet { if reservesIconColumn != oldValue { needsLayout = true } } }
    var reservesAccessoryColumn = false { didSet { if reservesAccessoryColumn != oldValue { needsLayout = true } } }

    let titleField: NSTextField
    let subtitleField: NSTextField
    let detailField: NSTextField
    private let iconView = NSImageView()
    private let tile = NSView()
    private let tileHot = NSView()
    private let tileIcon = NSImageView()
    private let tileIconHot = NSImageView()
    private var shortcutCap: CCKbd?
    private let accessoryView = NSImageView()
    private(set) var isHot = false
    private var themeObservation: CCThemeObservation?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(_ model: Model) {
        self.model = model
        titleField = CCMenu.label(model.style == .rich ? CCMenu.richTitleFont : CCMenu.titleFont)
        subtitleField = CCMenu.label(CCMenu.subtitleFont)
        detailField = CCMenu.wrappingLabel(CCMenu.detailFont)
        super.init(frame: .zero)
        wantsLayer = true

        iconView.imageScaling = .scaleProportionallyDown
        tileIcon.imageScaling = .scaleNone
        tileIconHot.imageScaling = .scaleNone
        tile.wantsLayer = true
        tile.layer?.cornerCurve = .continuous
        tileHot.wantsLayer = true
        tileHot.layer?.cornerCurve = .continuous
        tileHot.alphaValue = 0
        tileIconHot.alphaValue = 0
        tile.addSubview(tileHot)
        tile.addSubview(tileIcon)
        tile.addSubview(tileIconHot)
        accessoryView.imageScaling = .scaleNone
        for view in [iconView, tile, titleField, subtitleField, detailField, accessoryView] as [NSView] {
            addSubview(view)
        }
        bind(model)
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Rebind in place (row pools rebind on filter changes, never recreate).
    func update(_ model: Model) {
        let styleChanged = model.style != self.model.style
        self.model = model
        if styleChanged {
            titleField.font = model.style == .rich ? CCMenu.richTitleFont : CCMenu.titleFont
        }
        invalidateMeasurements()
        bind(model)
        applyTheme()
        needsLayout = true
    }

    private func bind(_ model: Model) {
        invalidateMeasurements()
        titleField.stringValue = model.title
        subtitleField.stringValue = model.subtitle ?? ""
        subtitleField.isHidden = model.style == .rich || (model.subtitle ?? "").isEmpty
        detailField.stringValue = model.detail ?? ""
        detailField.isHidden = model.style != .rich || (model.detail ?? "").isEmpty
        let rich = model.style == .rich
        tile.isHidden = !rich
        iconView.isHidden = rich || model.icon == nil

        shortcutCap?.removeFromSuperview()
        shortcutCap = nil
        if let shortcut = model.shortcut, !shortcut.isEmpty {
            let cap = CCKbd(shortcut, size: .sm, tone: .quiet)
            addSubview(cap)
            shortcutCap = cap
        }

        // Check / mixed / chevron sit at the FAR right — house rule.
        switch model.accessory {
        case .none: accessoryView.image = nil
        case .check: accessoryView.image = CCIcon.image("checkmark", pointSize: 10, weight: .bold)
        case .mixed: accessoryView.image = CCIcon.image("minus", pointSize: 10, weight: .bold)
        case .submenu: accessoryView.image = CCIcon.image("chevron.right", pointSize: 9, weight: .semibold)
        }
        isHot = false
        tileHot.alphaValue = 0
        tileIconHot.alphaValue = 0
        tileIcon.alphaValue = 1
    }

    private func iconImage(pointSize: CGFloat, color: NSColor? = nil) -> NSImage? {
        switch model.icon {
        case .named(let name)?:
            return color.map { CCIcon.image(name, pointSize: pointSize, weight: .semibold, color: $0) }
                ?? CCIcon.image(name, pointSize: pointSize, weight: .semibold)
        case .image(let image)?:
            return image
        case nil:
            return nil
        }
    }

    private func applyTheme() {
        let colors = CCTheme.color
        titleField.textColor = model.titleColor ?? colors.foreground
        subtitleField.textColor = colors.faintForeground
        detailField.textColor = colors.mutedForeground
        accessoryView.contentTintColor = model.accessory == .submenu ? colors.mutedForeground : colors.primary
        if model.style == .rich {
            tileIcon.image = iconImage(pointSize: 15)
            tileIcon.contentTintColor = colors.mutedForeground
            tileIconHot.image = iconImage(pointSize: 15)
            tileIconHot.contentTintColor = .white
            if let layer = tile.layer {
                let radius = CCTheme.radius(.md)
                layer.cornerRadius = radius
                // The well tint; on dark the elevated token sits too close to
                // the popover surface to read as a tile, so lift it a touch.
                let well = CCTheme.isDark
                    ? colors.elevated.blended(withFraction: 0.04, of: .white) ?? colors.elevated
                    : colors.elevated
                CCMaterial.dress(layer, as: .recessed(tint: well), radius: radius)
            }
            tileHot.layer?.backgroundColor = colors.primary.cgColor
            tileHot.layer?.cornerRadius = CCTheme.radius(.md)
        } else {
            iconView.image = iconImage(pointSize: 12)
            iconView.contentTintColor = colors.mutedForeground
        }
    }

    // MARK: Highlight

    /// The row's own share of the highlight (the wash itself is the list's):
    /// a rich row's tile springs to the accent with a white icon.
    func setHot(_ hot: Bool, animated: Bool = true) {
        guard hot != isHot else { return }
        isHot = hot
        guard model.style == .rich else { return }
        let reduce = CCMenu.reduceMotion || !animated
        for (view, target) in [(tileHot, hot ? 1.0 : 0.0), (tileIconHot, hot ? 1.0 : 0.0), (tileIcon, hot ? 0.0 : 1.0)] as [(NSView, CGFloat)] {
            if reduce || view.window == nil {
                view.alphaValue = target
            } else {
                Self.springAlpha(view, to: target)
            }
        }
    }

    /// alphaValue-safe SPRING cross-fade (fadeAlpha's spring twin).
    private static func springAlpha(_ view: NSView, to alpha: CGFloat) {
        guard let layer = view.layer else { view.alphaValue = alpha; return }
        let from = (layer.presentation() ?? layer).opacity
        view.alphaValue = alpha
        let animation = CCMotion.springAnimation(keyPath: "opacity", .snappy)
        animation.fromValue = from
        animation.toValue = Float(alpha)
        layer.add(animation, forKey: "ccmenu.hot")
    }

    // MARK: Measurement

    // Measurement cache — a menu measures every row several times while
    // choosing its width; text only changes on bind.
    private var cachedTitleSize: NSSize?
    private var cachedSubtitleSize: NSSize?
    private var cachedDetailLine: CGFloat?
    private var cachedWraps: [CGFloat: (height: CGFloat, lines: Int)] = [:]

    private func invalidateMeasurements() {
        cachedTitleSize = nil
        cachedSubtitleSize = nil
        cachedDetailLine = nil
        cachedWraps = [:]
    }

    private var titleSize: NSSize {
        if let cachedTitleSize { return cachedTitleSize }
        let size = CCMenu.singleLineSize(titleField)
        cachedTitleSize = size
        return size
    }

    private var subtitleSize: NSSize {
        if let cachedSubtitleSize { return cachedSubtitleSize }
        let size = CCMenu.singleLineSize(subtitleField)
        cachedSubtitleSize = size
        return size
    }

    private var subtitleWidth: CGFloat {
        subtitleField.isHidden ? 0 : Self.subtitleGap + subtitleSize.width
    }

    private func detailRequirement(width: CGFloat) -> (height: CGFloat, lines: Int) {
        let key = (width * 2).rounded() / 2
        if let hit = cachedWraps[key] { return hit }
        let need = CCMenu.wrappedRequirement(detailField.stringValue, font: CCMenu.detailFont, width: key)
        cachedWraps[key] = need
        return need
    }
    private var shortcutWidth: CGFloat {
        guard let cap = shortcutCap else { return 0 }
        return Self.shortcutGap + ceil(cap.intrinsicContentSize.width)
    }
    private var accessoryWidth: CGFloat {
        reservesAccessoryColumn ? Self.accessoryGap + Self.accessorySlot : 0
    }

    /// Width where NOTHING truncates (a rich description may still wrap).
    var minimumWidth: CGFloat {
        switch model.style {
        case .simple:
            let icon = reservesIconColumn ? Self.iconSlot + Self.iconGap : 0
            return Self.leadPad + icon + titleSize.width + subtitleWidth + shortcutWidth
                + accessoryWidth + Self.simpleTrailPad
        case .rich:
            return richTextX + titleSize.width + accessoryWidth + Self.richTrailPad
        }
    }

    /// Width with the description on ONE line (the "fits content" width).
    var naturalWidth: CGFloat {
        guard model.style == .rich, !detailField.isHidden else { return minimumWidth }
        if cachedDetailLine == nil { cachedDetailLine = CCMenu.singleLineSize(detailField).width }
        let detail = cachedDetailLine ?? 0
        return max(minimumWidth, richTextX + detail + accessoryWidth + Self.richTrailPad)
    }

    private var richTextX: CGFloat { Self.leadPad + Self.tileSide + Self.tileGap }

    func detailTextWidth(forRowWidth width: CGFloat) -> CGFloat {
        width - richTextX - accessoryWidth - Self.richTrailPad
    }

    /// Lines the description needs at this row width (unlimited-line truth).
    func detailLines(forRowWidth width: CGFloat) -> Int {
        guard model.style == .rich, !detailField.isHidden else { return 0 }
        return detailRequirement(width: detailTextWidth(forRowWidth: width)).lines
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        switch model.style {
        case .simple:
            return CCMenu.simpleRowHeight
        case .rich:
            var block = titleSize.height
            if !detailField.isHidden {
                let need = detailRequirement(width: detailTextWidth(forRowWidth: width))
                let line = need.lines > 0 ? need.height / CGFloat(need.lines) : 0
                block += Self.titleDetailGap + ceil(line * CGFloat(min(need.lines, CCMenu.maxDetailLines)))
            }
            return max(CCMenu.richRowMinHeight, ceil(block + Self.richVPad * 2))
        }
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let midY = h / 2
        var right = w - (model.style == .rich ? Self.richTrailPad : Self.simpleTrailPad)
        if reservesAccessoryColumn {
            accessoryView.frame = NSRect(x: right - Self.accessorySlot, y: midY - Self.accessorySlot / 2,
                                         width: Self.accessorySlot, height: Self.accessorySlot)
            right -= Self.accessorySlot + Self.accessoryGap
        } else {
            accessoryView.frame = .zero
        }
        let title = titleSize

        switch model.style {
        case .simple:
            var x = Self.leadPad
            if reservesIconColumn {
                iconView.frame = NSRect(x: x, y: midY - Self.iconSlot / 2, width: Self.iconSlot, height: Self.iconSlot)
                x += Self.iconSlot + Self.iconGap
            }
            if let cap = shortcutCap {
                let size = cap.intrinsicContentSize
                cap.frame = NSRect(x: right - ceil(size.width), y: (midY - size.height / 2).rounded(),
                                   width: ceil(size.width), height: size.height)
                right -= ceil(size.width) + Self.shortcutGap
            }
            let titleWidth = min(title.width, max(0, right - x))
            titleField.frame = NSRect(x: x, y: (midY - title.height / 2).rounded(), width: titleWidth, height: title.height)
            if !subtitleField.isHidden {
                let sub = subtitleSize
                let subX = x + titleWidth + Self.subtitleGap
                subtitleField.frame = NSRect(x: subX, y: (midY - sub.height / 2).rounded(),
                                             width: min(sub.width, max(0, right - subX)), height: sub.height)
            }
        case .rich:
            let tileY = (midY - Self.tileSide / 2).rounded()
            tile.frame = NSRect(x: Self.leadPad, y: tileY, width: Self.tileSide, height: Self.tileSide)
            tileHot.frame = tile.bounds
            if let layer = tile.layer { CCMaterial.refit(layer, radius: CCTheme.radius(.md)) }
            let glyph = tileIcon.image?.size ?? .zero
            let glyphRect = NSRect(x: ((Self.tileSide - glyph.width) / 2).rounded(),
                                   y: ((Self.tileSide - glyph.height) / 2).rounded(),
                                   width: glyph.width, height: glyph.height)
            tileIcon.frame = glyphRect
            tileIconHot.frame = glyphRect

            let textX = richTextX
            let textW = max(0, right - textX)
            var block = title.height
            var detailHeight: CGFloat = 0
            if !detailField.isHidden {
                let need = detailRequirement(width: textW)
                let line = need.lines > 0 ? need.height / CGFloat(need.lines) : 0
                detailHeight = ceil(line * CGFloat(min(need.lines, CCMenu.maxDetailLines)))
                block += Self.titleDetailGap + detailHeight
            }
            let top = ((h - block) / 2).rounded()
            titleField.frame = NSRect(x: textX, y: top, width: min(title.width, textW), height: title.height)
            if !detailField.isHidden {
                detailField.frame = NSRect(x: textX, y: top + title.height + Self.titleDetailGap,
                                           width: textW, height: detailHeight)
            }
        }
    }

    // MARK: Clicks

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Labels and icons never swallow the click: the whole row is the target.
        isHidden || !frame.contains(point) ? nil : self
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?(self)
    }

    // MARK: Probe seams

    var probeShortcutCap: CCKbd? { shortcutCap }
    var probeAccessory: NSImageView { accessoryView }
    var probeTileHotAlpha: CGFloat { tileHot.alphaValue }
    /// Presentation opacity of the accent tile (spring cross-fade probes).
    var probeTileHotPresented: Float { (tileHot.layer?.presentation() ?? tileHot.layer)?.opacity ?? 0 }
    var probeIsRich: Bool { model.style == .rich }
}

// MARK: - Section header

/// Sentence-case section header, with an optional caption under it that says
/// WHY the section's rows are unavailable ("Needs a camera recording").
@MainActor
final class CCMenuHeader: NSView {
    let titleField = CCMenu.label(CCMenu.headerFont)
    let captionField = CCMenu.label(CCMenu.captionFont)
    var isFirst = false
    private var themeObservation: CCThemeObservation?

    static let topPad: CGFloat = 7
    static let firstTopPad: CGFloat = 4
    static let bottomPad: CGFloat = 3
    static let captionGap: CGFloat = 1

    override var isFlipped: Bool { true }

    init(title: String, caption: String?) {
        super.init(frame: .zero)
        wantsLayer = true
        titleField.stringValue = title
        captionField.stringValue = caption ?? ""
        captionField.isHidden = (caption ?? "").isEmpty
        addSubview(titleField)
        addSubview(captionField)
        themeObservation = CCThemeObservation { [weak self] in
            self?.titleField.textColor = CCTheme.color.mutedForeground
            self?.captionField.textColor = CCTheme.color.mutedForeground
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var hasCaption: Bool { !captionField.isHidden }

    var minimumWidth: CGFloat {
        var width = CCMenu.singleLineSize(titleField).width
        if hasCaption { width = max(width, CCMenu.singleLineSize(captionField).width) }
        return CCMenuRow.leadPad * 2 + width
    }

    var height: CGFloat {
        var h = (isFirst ? Self.firstTopPad : Self.topPad) + CCMenu.singleLineSize(titleField).height
        if hasCaption { h += Self.captionGap + CCMenu.singleLineSize(captionField).height }
        return h + Self.bottomPad
    }

    override func layout() {
        super.layout()
        let title = CCMenu.singleLineSize(titleField)
        let x = CCMenuRow.leadPad
        let available = max(0, bounds.width - x * 2)
        var y = isFirst ? Self.firstTopPad : Self.topPad
        titleField.frame = NSRect(x: x, y: y, width: min(title.width, available), height: title.height)
        y += title.height
        if hasCaption {
            let caption = CCMenu.singleLineSize(captionField)
            captionField.frame = NSRect(x: x, y: y + Self.captionGap, width: min(caption.width, available),
                                        height: caption.height)
        }
    }
}

// MARK: - Separator

@MainActor
final class CCMenuSeparator: NSView {
    private let line = NSView()
    private var themeObservation: CCThemeObservation?
    static let height: CGFloat = 9

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        line.wantsLayer = true
        addSubview(line)
        themeObservation = CCThemeObservation { [weak self] in
            self?.line.layer?.backgroundColor = CCTheme.color.border.cgColor
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2
        let thickness = 1 / scale
        line.frame = NSRect(x: CCMenuRow.leadPad, y: (bounds.height / 2).rounded(),
                            width: max(0, bounds.width - CCMenuRow.leadPad * 2), height: thickness)
    }
}

// MARK: - List

/// The menu body: rows, headers and separators stacked by hand (deterministic
/// measurement — the width is chosen from content, not from a stack view's
/// opinion), plus the shared hover wash, keyboard highlight, pick pulse and
/// entrance stagger. Hover arrives through `routeHover(windowPoint:)` from the
/// presenter's CCHoverPoller.
@MainActor
final class CCMenuList: NSView {
    private(set) var entries: [NSView] = []
    var rows: [CCMenuRow] { entries.compactMap { $0 as? CCMenuRow } }
    var visibleRows: [CCMenuRow] { rows.filter { !$0.isHidden } }
    var headers: [CCMenuHeader] { entries.compactMap { $0 as? CCMenuHeader } }

    /// A picked (clicked / ↩) enabled row.
    var onActivate: ((CCMenuRow) -> Void)?
    /// Hover intent — the row under the pointer (nil = none). Presenters use
    /// it for submenu dwell timers.
    var onHover: ((CCMenuRow?) -> Void)?
    /// A row that keeps the highlight while the pointer is elsewhere (the row
    /// whose submenu is flown out).
    var pinnedRow: CCMenuRow?

    private(set) weak var highlightedRow: CCMenuRow?
    private weak var hoverRow: CCMenuRow?
    private(set) var wash: CCGlideHighlight!
    private(set) var laidOutWidth: CGFloat = 0

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        wash = CCGlideHighlight(host: self, radius: .md)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Building

    func add(_ row: CCMenuRow) {
        row.onClick = { [weak self] row in self?.activate(row) }
        append(row)
    }

    func addHeader(_ title: String, caption: String? = nil) {
        append(CCMenuHeader(title: title, caption: caption))
    }

    func addSeparator() {
        // Never lead with, or double up, separators.
        guard let last = entries.last, !(last is CCMenuSeparator) else { return }
        append(CCMenuSeparator())
    }

    private func append(_ view: NSView) {
        entries.append(view)
        addSubview(view)
    }

    /// Entries in layout order (probes: stagger sampling).
    var probeLaidOutEntries: [NSView] { laidOutEntries }

    private var hasRichRows: Bool { rows.contains { $0.model.style == .rich } }
    var rowSpacing: CGFloat { hasRichRows ? 2 : 1 }

    /// Entries that take part in layout: visible, minus a dangling separator.
    private var laidOutEntries: [NSView] {
        var list = entries.filter { !$0.isHidden }
        while let last = list.last, last is CCMenuSeparator { list.removeLast() }
        while let first = list.first, first is CCMenuSeparator { list.removeFirst() }
        return list
    }

    private func syncColumns() {
        let simple = rows.filter { $0.model.style == .simple && !$0.isHidden }
        let icons = simple.contains { $0.model.icon != nil }
        let accessories = rows.contains { !$0.isHidden && $0.model.accessory != .none }
        for row in rows {
            row.reservesIconColumn = icons
            row.reservesAccessoryColumn = accessories
            row.alphaValue = row.isEnabled ? 1 : CCTheme.current.disabledAlpha
        }
        let first = laidOutEntries.first
        for header in headers { header.isFirst = first === header }
    }

    // MARK: Measurement

    /// The menu width: wide enough that no title, subtitle or shortcut ever
    /// truncates, at least `minWidth`, at most `maxWidth` UNLESS a title
    /// needs more (the menu widens instead of truncating), and wide enough
    /// that every description fits in ≤ 2 lines.
    func fittingWidth(minWidth: CGFloat = CCMenu.minWidth, maxWidth: CGFloat = CCMenu.maxWidth) -> CGFloat {
        syncColumns()
        let pad = CCMenu.padding * 2
        let live = laidOutEntries
        let rowViews = live.compactMap { $0 as? CCMenuRow }
        let mustFit = max(
            rowViews.map(\.minimumWidth).max() ?? 0,
            live.compactMap { ($0 as? CCMenuHeader)?.minimumWidth }.max() ?? 0
        ) + pad
        let natural = (rowViews.map(\.naturalWidth).max() ?? 0) + pad
        var width = max(minWidth, mustFit, min(natural, maxWidth)).rounded(.up)
        // Descriptions wrap to at most two lines; past that the menu widens.
        while rowViews.contains(where: { $0.detailLines(forRowWidth: width - pad) > CCMenu.maxDetailLines }),
              width < natural {
            width += 8
        }
        if CCMenu.probeInjectedDefects.contains("narrow") { width = 200 }
        return width
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        syncColumns()
        let rowWidth = width - CCMenu.padding * 2
        var y = CCMenu.padding
        var previousWasRow = false
        for view in laidOutEntries {
            if let row = view as? CCMenuRow {
                if previousWasRow { y += rowSpacing }
                y += row.height(forWidth: rowWidth)
                previousWasRow = true
            } else if let header = view as? CCMenuHeader {
                y += header.height
                previousWasRow = false
            } else {
                y += CCMenuSeparator.height
                previousWasRow = false
            }
        }
        return ceil(y + CCMenu.padding)
    }

    /// Frames every entry for `width` and sizes the list itself.
    func layoutEntries(width: CGFloat) {
        syncColumns()
        laidOutWidth = width
        let rowWidth = width - CCMenu.padding * 2
        let live = laidOutEntries
        for view in entries where !live.contains(where: { $0 === view }) { view.frame = .zero }
        var y = CCMenu.padding
        var previousWasRow = false
        for view in live {
            let height: CGFloat
            if let row = view as? CCMenuRow {
                if previousWasRow { y += rowSpacing }
                height = row.height(forWidth: rowWidth)
                previousWasRow = true
            } else if let header = view as? CCMenuHeader {
                height = header.height
                previousWasRow = false
            } else {
                height = CCMenuSeparator.height
                previousWasRow = false
            }
            view.frame = NSRect(x: CCMenu.padding, y: y, width: rowWidth, height: height)
            view.needsLayout = true
            y += height
        }
        setFrameSize(NSSize(width: width, height: ceil(y + CCMenu.padding)))
        layoutSubtreeIfNeeded()
    }

    /// A scroll view hosting the list at `visibleHeight` — it only scrolls
    /// when the menu is taller than the screen allows.
    func embedInScrollView(visibleHeight: CGFloat) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: frame.width, height: visibleHeight))
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.hasVerticalScroller = frame.height > visibleHeight + 0.5
        scroll.verticalScrollElasticity = frame.height > visibleHeight + 0.5 ? .allowed : .none
        scroll.horizontalScrollElasticity = .none
        scroll.documentView = self
        scroll.contentView.scroll(to: .zero)
        return scroll
    }

    // MARK: Hover (dispatched — rows own no tracking areas)

    private func row(at point: NSPoint) -> CCMenuRow? {
        let slack = rowSpacing / 2 + 0.5
        return visibleRows.first {
            $0.isEnabled && !$0.frame.isEmpty && $0.frame.insetBy(dx: 0, dy: -slack).contains(point)
        }
    }

    func routeHover(windowPoint: NSPoint) {
        let target = row(at: convert(windowPoint, from: nil))
        guard target !== hoverRow else { return }
        hoverRow = target
        setHighlighted(target ?? pinnedRow)
        onHover?(target)
    }

    func clearHover() {
        guard hoverRow != nil else { return }
        hoverRow = nil
        setHighlighted(pinnedRow)
        onHover?(nil)
    }

    // MARK: Highlight / keyboard

    /// Moves the one wash to `row` (glides between rows; appears in place on
    /// the first landing; fades on nil). Disabled rows never highlight.
    func setHighlighted(_ row: CCMenuRow?, animated: Bool = true) {
        let target = (row?.isEnabled ?? false) ? row : nil
        guard target !== highlightedRow else { return }
        let previous = highlightedRow
        highlightedRow = target
        previous?.setHot(false, animated: animated)
        wash.crossfadesInsteadOfGliding = CCMenu.reduceMotion || !animated
        if let target {
            target.setHot(true, animated: animated)
            wash.update(row: target, active: true)
            if !animated {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                wash.layer.removeAllAnimations()
                wash.layer.opacity = 1
                CATransaction.commit()
            }
        } else if let previous {
            wash.update(row: previous, active: false)
        }
    }

    func moveHighlight(_ delta: Int) {
        let candidates = visibleRows.filter(\.isEnabled)
        guard !candidates.isEmpty else { return }
        let next: CCMenuRow
        if let current = highlightedRow, let index = candidates.firstIndex(where: { $0 === current }) {
            next = candidates[(index + delta + candidates.count) % candidates.count]
        } else {
            next = delta > 0 ? candidates[0] : candidates[candidates.count - 1]
        }
        setHighlighted(next)
        next.scrollToVisible(next.bounds)
    }

    func highlightFirst() {
        if let first = visibleRows.first(where: \.isEnabled) { setHighlighted(first) }
    }

    /// Type-select: jump to the next enabled row whose title starts with
    /// `characters` (wrapping), macOS-menu style.
    @discardableResult
    func typeSelect(_ characters: String) -> Bool {
        let key = characters.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return false }
        let candidates = visibleRows.filter(\.isEnabled)
        guard !candidates.isEmpty else { return false }
        let start = highlightedRow.flatMap { row in candidates.firstIndex(where: { $0 === row }) } ?? -1
        for offset in 1...candidates.count {
            let row = candidates[(start + offset) % candidates.count]
            if row.model.title.lowercased().hasPrefix(key) {
                setHighlighted(row)
                row.scrollToVisible(row.bounds)
                return true
            }
        }
        return false
    }

    @discardableResult
    func activateHighlighted() -> Bool {
        guard let row = highlightedRow else { return false }
        activate(row)
        return true
    }

    func activate(_ row: CCMenuRow) {
        guard row.isEnabled else { return }
        onActivate?(row)
    }

    // MARK: Motion

    /// The pick acknowledgement: the wash lands on `row` and blinks once
    /// (~120 ms), THEN `completion` runs (close + perform), like macOS.
    func pulse(_ row: CCMenuRow, then completion: @escaping () -> Void) {
        if highlightedRow !== row { setHighlighted(row) }
        wash.pulse(duration: CCMenu.pulseDuration)
        DispatchQueue.main.asyncAfter(deadline: .now() + CCMotion.paced(CCMenu.pulseDuration)) {
            completion()
        }
    }

    /// Rows (and headers/separators) arrive in sequence: each fades in and
    /// RISES 6 pt, 18 ms after the previous; the first 8 stagger, the rest
    /// land with the 8th. Reduce Motion: nothing (the surface fade carries it).
    func playEntrance() {
        guard !CCMenu.reduceMotion, !CCMenu.probeInjectedDefects.contains("snap") else { return }
        for (index, view) in laidOutEntries.enumerated() {
            guard let layer = view.layer, view.window != nil else { continue }
            let delay = CCMenu.staggerStep * Double(min(index, CCMenu.staggerCount - 1))
            let resting: CGFloat = (view as? CCMenuRow).map { $0.isEnabled ? 1 : CCTheme.current.disabledAlpha } ?? 1
            // "Below" in the space the transform acts in (the list's layer).
            let down = layer.superlayer?.contentsAreFlipped() ?? isFlipped
            CCMotion.spring(layer, keyPath: "transform.translation.y",
                            from: down ? CCMenu.slide : -CCMenu.slide, to: 0, .snappy, delay: delay)
            CCMotion.fadeAlpha(view, to: resting, duration: CCMenu.rowFade, delay: delay, from: 0)
        }
    }
}

// MARK: - Stage (the floating surface + its motion)

/// A menu panel's content view: a transparent margin (room for the soft wide
/// shadow — a layer shadow outside the WINDOW is clipped) around the floating
/// surface. Presenters size the panel with `panelFrame(surfaceOrigin:)` and
/// test hits/hover against `surfaceScreenRect`.
@MainActor
final class CCMenuStage: NSView {
    /// Shadow room around the surface: ≥ 3.3σ of the blur on every side
    /// (plus the 10 pt drop at the bottom) — a layer shadow that reaches the
    /// WINDOW edge is cut off there as a visible box (measured: at 34 pt a
    /// σ-24 shadow still darkened the backdrop 3 levels).
    static let shadowInsets = NSEdgeInsets(top: 30, left: 40, bottom: 52, right: 40)

    enum Edge { case top, bottom, left, right }

    let surface = CCMenuSurface()
    private let clip = CCMenuClip()
    private(set) var content: NSView?
    private(set) var surfaceSize: NSSize = .zero
    private(set) var openEdge: Edge = .top
    private var pivot: CGPoint = .zero
    private(set) var isClosing = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        surface.addSubview(clip)
        addSubview(surface)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Install the menu body. `inset` keeps the hairline visible around
    /// content that paints its own background (generic popovers).
    func setContent(_ view: NSView, inset: CGFloat) {
        content?.removeFromSuperview()
        content = view
        view.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: clip.leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(equalTo: clip.trailingAnchor, constant: -inset),
            view.topAnchor.constraint(equalTo: clip.topAnchor, constant: inset),
            view.bottomAnchor.constraint(equalTo: clip.bottomAnchor, constant: -inset),
        ])
    }

    func resize(surfaceSize size: NSSize) {
        surfaceSize = NSSize(width: ceil(size.width), height: ceil(size.height))
        let i = Self.shadowInsets
        setFrameSize(NSSize(width: surfaceSize.width + i.left + i.right,
                            height: surfaceSize.height + i.top + i.bottom))
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        let i = Self.shadowInsets
        // Unflipped stage: the bottom inset is at y = 0.
        surface.frame = NSRect(x: i.left, y: i.bottom, width: surfaceSize.width, height: surfaceSize.height)
        clip.frame = surface.bounds
    }

    /// The panel frame that puts the SURFACE at `origin` (screen space).
    func panelFrame(surfaceOrigin origin: NSPoint) -> NSRect {
        let i = Self.shadowInsets
        return NSRect(x: origin.x - i.left, y: origin.y - i.bottom,
                      width: surfaceSize.width + i.left + i.right,
                      height: surfaceSize.height + i.top + i.bottom)
    }

    var surfaceScreenRect: NSRect? {
        guard let window else { return nil }
        return window.convertToScreen(surface.convert(surface.bounds, to: nil))
    }

    func surfaceContains(windowPoint: NSPoint) -> Bool {
        surface.convert(surface.bounds, to: nil).contains(windowPoint)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Clicks in the shadow margin are not the menu's.
        let local = convert(point, from: superview)
        guard surface.frame.contains(local) else { return nil }
        return super.hitTest(point)
    }

    // MARK: Motion

    /// Call before ordering the panel in, so it never flashes at rest.
    func prepareForOpen() {
        surface.alphaValue = 0
    }

    /// OPEN: fade 0→1 (120 ms) + a 0.96→1 scale on the `.arrive` spring
    /// pivoting on `edge` (at `anchor`, a screen point along it), plus a 6 pt
    /// slide from that edge; then the list's row stagger. Flyouts pass
    /// `scales: false` (slide + fade only).
    func playOpen(from edge: Edge, anchor: NSPoint?, list: CCMenuList?, scales: Bool = true) {
        openEdge = edge
        layoutSubtreeIfNeeded()
        guard let layer = surface.layer else { surface.alphaValue = 1; return }
        pivot = pivotPoint(edge: edge, anchor: anchor, in: layer)
        if CCMenu.probeInjectedDefects.contains("snap") {
            surface.alphaValue = 1
            return
        }
        CCMotion.fadeAlpha(surface, to: 1, duration: CCMenu.openFade, from: 0)
        guard !CCMenu.reduceMotion else { return }
        var start = scales
            ? CCMotion.scaleTransform(CCMenu.openScale, pivot: pivot, in: layer)
            : CATransform3DIdentity
        let slide = slideVector(edge: edge, in: layer)
        start = CATransform3DConcat(start, CATransform3DMakeTranslation(slide.x, slide.y, 0))
        CCMotion.spring(layer, keyPath: "transform",
                        from: NSValue(caTransform3D: start),
                        to: NSValue(caTransform3D: CATransform3DIdentity), .arrive)
        list?.playEntrance()
    }

    /// CLOSE: 100 ms fade + scale to 0.98 about the open pivot, then
    /// `completion` (the presenter orders the panel out).
    func playClose(completion: @escaping () -> Void) {
        guard !isClosing else { return }
        isClosing = true
        if let layer = surface.layer, !CCMenu.reduceMotion {
            CCMotion.fade(layer, keyPath: "transform",
                          to: NSValue(caTransform3D: CCMotion.scaleTransform(CCMenu.closeScale, pivot: pivot, in: layer)),
                          duration: CCMenu.closeFade)
        }
        CCMotion.fadeAlpha(surface, to: 0, duration: CCMenu.closeFade)
        DispatchQueue.main.asyncAfter(deadline: .now() + CCMotion.paced(CCMenu.closeFade) + 0.03) {
            completion()
        }
    }

    /// Is the space the surface's transform acts in y-down?
    private func transformSpaceIsDown(_ layer: CALayer) -> Bool {
        layer.superlayer?.contentsAreFlipped() ?? false
    }

    private func pivotPoint(edge: Edge, anchor: NSPoint?, in layer: CALayer) -> CGPoint {
        let b = layer.bounds
        let down = transformSpaceIsDown(layer)
        // The anchor projected onto the surface, clamped to it.
        var along = CGPoint(x: b.midX, y: b.midY)
        if let anchor, let screen = surfaceScreenRect {
            along.x = min(max(anchor.x - screen.minX, 0), b.width)
            let fromBottom = min(max(anchor.y - screen.minY, 0), b.height)
            along.y = down ? b.height - fromBottom : fromBottom
        }
        let top: CGFloat = down ? 0 : b.height
        let bottom: CGFloat = down ? b.height : 0
        switch edge {
        case .top: return CGPoint(x: along.x, y: top)
        case .bottom: return CGPoint(x: along.x, y: bottom)
        case .left: return CGPoint(x: 0, y: along.y)
        case .right: return CGPoint(x: b.width, y: along.y)
        }
    }

    /// Start offset: displaced TOWARD the trigger edge, sliding away from it.
    private func slideVector(edge: Edge, in layer: CALayer) -> CGPoint {
        let up: CGFloat = transformSpaceIsDown(layer) ? -1 : 1
        let d = CCMenu.slide
        switch edge {
        case .top: return CGPoint(x: 0, y: d * up)
        case .bottom: return CGPoint(x: 0, y: -d * up)
        case .left: return CGPoint(x: -d, y: 0)
        case .right: return CGPoint(x: d, y: 0)
        }
    }

    // MARK: Probe seams

    var probeSurfaceLayer: CALayer? { surface.layer }
    /// Presentation opacity / scale of the surface (mid-flight probes).
    var probePresentedOpacity: Float { (surface.layer?.presentation() ?? surface.layer)?.opacity ?? 0 }
    var probePresentedScale: CGFloat {
        guard let layer = surface.layer else { return 1 }
        return (layer.presentation() ?? layer).transform.m11
    }
    var probePresentedTranslation: CGPoint {
        guard let layer = surface.layer else { return .zero }
        let t = (layer.presentation() ?? layer).transform
        return CGPoint(x: t.m41, y: t.m42)
    }
}

/// The floating surface: `popover` tint dressed by CCMaterial (hairline edge,
/// whisper of top light) plus the menu's soft, wide cast shadow.
@MainActor
final class CCMenuSurface: NSView {
    private var themeObservation: CCThemeObservation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func applyTheme() {
        guard let layer else { return }
        let radius = CCTheme.radius(.lg)
        layer.cornerRadius = radius
        CCMaterial.dress(layer, as: .raisedMatte(tint: CCTheme.color.popover), radius: radius)
        applyShadow()
    }

    override func layout() {
        super.layout()
        guard let layer else { return }
        CCMaterial.refit(layer, radius: CCTheme.radius(.lg))
        // Re-asserted every layout: AppKit drops init-time shadows on view
        // backing layers when it reconfigures them (the kit's shadow heal).
        applyShadow()
    }

    private func applyShadow() {
        guard let layer else { return }
        let radius = CCTheme.radius(.lg)
        layer.masksToBounds = false
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = CCTheme.isDark ? 0.45 : 0.16
        // "Radius 24" in CSS/SwiftUI terms. CALayer's shadowRadius is a
        // Gaussian SIGMA (measured: 24 → σ≈23.6), i.e. twice as soft as the
        // web's `0 10px 24px` — so the CA value is 12 (same convention as
        // CIGaussianBlur, see CLAUDE.md §2).
        layer.shadowRadius = 12
        let down = layer.contentsAreFlipped()
        layer.shadowOffset = CGSize(width: 0, height: down ? 10 : -10)
        layer.shadowPath = CGPath(roundedRect: layer.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    var probeShadow: (opacity: Float, radius: CGFloat) {
        (layer?.shadowOpacity ?? 0, layer?.shadowRadius ?? 0)
    }
}

/// Rounds the content to the surface's corners.
@MainActor
private final class CCMenuClip: NSView {
    private var themeObservation: CCThemeObservation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
        themeObservation = CCThemeObservation { [weak self] in
            self?.layer?.cornerRadius = CCTheme.radius(.lg)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

// MARK: - Panel

extension CCMenuStage {
    /// The house configuration for a menu panel: borderless, non-activating,
    /// transparent (the stage draws everything), above popUpMenu level.
    static func configure(_ panel: NSPanel) {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
    }

    /// Visible frame of the screen an anchor sits on (menus clamp to it).
    static func visibleFrame(for anchor: NSRect) -> NSRect {
        let point = NSPoint(x: anchor.midX, y: anchor.midY)
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
            ?? NSScreen.screens.max {
                $0.frame.intersection(anchor).width * $0.frame.intersection(anchor).height
                    < $1.frame.intersection(anchor).width * $1.frame.intersection(anchor).height
            }
            ?? NSScreen.main
        return screen?.visibleFrame ?? anchor
    }

    /// Tallest surface the screen allows (menus only scroll past this).
    static func maxSurfaceHeight(for anchor: NSRect) -> CGFloat {
        max(120, visibleFrame(for: anchor).height - 16)
    }
}
