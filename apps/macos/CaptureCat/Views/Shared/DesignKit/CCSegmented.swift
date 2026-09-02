import AppKit

/// CCKit segmented control — shadcn's Tabs list: an elevated well holding
/// equal-width segments with a selection chip that springs between them, and
/// an optional hover wash that GLIDES under the pointer (Sonoma menu feel).
///
///     let seg = CCSegmented(segments: ["Fit", "Fill", "Stretch"]) { index in ... }
///     let bar = CCSegmented(segments: ["Image", "Video"], size: .sm)  // title bars
///     let tabs = CCSegmented(segments: [...], radius: .full, hoverWash: true)
@MainActor
final class CCSegmented: NSControl {
    /// Control scale: `.regular` for forms/panes, `.sm` for title bars and
    /// dense toolbars (a 30pt form control in a titlebar reads as bulk —
    /// user call 2026-08-17).
    enum Size {
        case sm
        case regular

        var height: CGFloat {
            switch self {
            case .sm: return 24
            case .regular: return 30
            }
        }

        var inset: CGFloat {
            switch self {
            case .sm: return 2
            case .regular: return 3
            }
        }

        var segmentPadding: CGFloat {
            switch self {
            case .sm: return 18
            case .regular: return 26
            }
        }

        @MainActor var font: NSFont {
            let base = CCTheme.font.button
            switch self {
            case .sm: return NSFont(descriptor: base.fontDescriptor, size: base.pointSize - 1) ?? base
            case .regular: return base
            }
        }
    }

    /// Chrome weight: `.elevated` is the form look (bordered well, card
    /// selection chip). `.plain` is the TITLE BAR look — no box at rest, the
    /// selection is a quiet ink wash — matching how Apple draws toolbar
    /// controls (bordered wells up there read as web forms; user call
    /// 2026-08-17).
    enum Chrome {
        case elevated
        case plain
    }

    var onChange: ((Int) -> Void)?
    let size: Size
    let chrome: Chrome

    /// Corner scale for the chrome; `.full` = pill. The default keeps the
    /// radius law's `.md` chrome / `.sm` chip pairing; any override keeps the
    /// chip CONCENTRIC (outer − inset), so a pill chrome holds a pill chip.
    var radius: CCRadius {
        didSet { needsLayout = true }
    }

    /// Glide hover (off by default): a quiet ink wash appears in place under
    /// the pointer's segment, SPRINGS between segments as the pointer moves,
    /// and fades out on exit. The selected segment is never washed — its chip
    /// already marks it. Same state rules as CCGlideHighlight: the wash
    /// appears in place only when its presentation is faded out, so a hop
    /// straight after an exit fade still glides instead of snapping.
    var hoverWash: Bool {
        didSet { if !hoverWash { routeHover(to: nil) } }
    }

    var selectedIndex: Int {
        didSet {
            guard selectedIndex != oldValue else { return }
            refreshSelection()
        }
    }

    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1 : CCTheme.current.disabledAlpha }
    }

    private var labels: [NSTextField] = []
    private let selection = CALayer()
    private let hover = CALayer()
    private var hoverIndex: Int?
    private var trackingArea: NSTrackingArea?
    private var themeObservation: CCThemeObservation?

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        let widest = labels.map { $0.intrinsicContentSize.width }.max() ?? 40
        let count = CGFloat(max(labels.count, 1))
        return NSSize(
            width: ceil((widest + size.segmentPadding) * count) + size.inset * 2,
            height: size.height
        )
    }

    init(
        segments: [String],
        selectedIndex: Int = 0,
        size: Size = .regular,
        chrome: Chrome = .elevated,
        radius: CCRadius = .md,
        hoverWash: Bool = false,
        onChange: ((Int) -> Void)? = nil
    ) {
        self.selectedIndex = selectedIndex
        self.size = size
        self.chrome = chrome
        self.radius = radius
        self.hoverWash = hoverWash
        self.onChange = onChange
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.masksToBounds = true

        hover.cornerCurve = .continuous
        hover.opacity = 0
        layer?.addSublayer(hover)
        selection.cornerCurve = .continuous
        layer?.addSublayer(selection)

        for text in segments {
            let label = NSTextField(labelWithString: text)
            label.font = size.font
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            labels.append(label)
        }
        heightAnchor.constraint(equalToConstant: size.height).isActive = true
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Update one segment's label in place — counts, live states. The text
    /// crossfades and any width change glides (never snaps or overdraws).
    func setTitle(_ title: String, at index: Int) {
        guard labels.indices.contains(index), labels[index].stringValue != title else { return }
        CCMotion.fadeContentSwap(labels[index])
        labels[index].stringValue = title
        invalidateIntrinsicContentSize()
        needsLayout = true
        CCMotion.expand(self)
    }

    private func segmentRect(_ index: Int) -> CGRect {
        let count = CGFloat(max(labels.count, 1))
        let width = (bounds.width - size.inset * 2) / count
        return CGRect(
            x: size.inset + width * CGFloat(index),
            y: size.inset,
            width: width,
            height: bounds.height - size.inset * 2
        )
    }

    override func layout() {
        super.layout()
        let outer = radius.resolved(for: bounds.height)
        layer?.cornerRadius = outer
        selection.cornerRadius = radius == .md
            ? CCTheme.radius(.sm)
            : max(outer - size.inset, 2)
        hover.cornerRadius = selection.cornerRadius
        CCMaterial.refit(layer!, radius: outer)
        CCMaterial.refit(selection, radius: selection.cornerRadius)
        for (index, label) in labels.enumerated() {
            let rect = segmentRect(index)
            let size = label.intrinsicContentSize
            label.frame = CGRect(
                x: rect.midX - size.width / 2,
                y: rect.midY - size.height / 2,
                width: size.width, height: size.height
            )
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selection.frame = segmentRect(selectedIndex)
        if let hoverIndex, hover.opacity > 0 { hover.frame = segmentRect(hoverIndex) }
        CATransaction.commit()
    }

    /// Hover routing (also the harness seam — probes drive it directly, the
    /// mouse handlers below feed it in production). `nil` = pointer left.
    func routeHover(to index: Int?) {
        guard hoverWash else { return }
        if let index, index != selectedIndex, labels.indices.contains(index) {
            let target = segmentRect(index)
            // Appear in place only when genuinely faded out — the PRESENTATION
            // opacity, not the model: a hop right after an exit fade must
            // glide from where the wash still visibly is (the no-glide root
            // cause of 2026-08-15).
            let appearing = (hover.presentation() ?? hover).opacity < 0.5
            hoverIndex = index
            if appearing {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                hover.frame = target
                CATransaction.commit()
            } else {
                CCMotion.spring(hover, keyPath: "position",
                                to: NSValue(point: CGPoint(x: target.midX, y: target.midY)), .snappy)
                CCMotion.spring(hover, keyPath: "bounds",
                                to: NSValue(rect: CGRect(origin: .zero, size: target.size)), .snappy)
            }
            CCMotion.fade(hover, keyPath: "opacity", to: 1, duration: 0.1)
        } else {
            CCMotion.fade(hover, keyPath: "opacity", to: 0, duration: 0.16)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { routeMouse(event) }
    override func mouseMoved(with event: NSEvent) { routeMouse(event) }
    override func mouseExited(with event: NSEvent) { routeHover(to: nil) }

    private func routeMouse(_ event: NSEvent) {
        guard isEnabled, hoverWash else { return }
        let point = convert(event.locationInWindow, from: nil)
        routeHover(to: labels.indices.first { segmentRect($0).contains(point) })
    }

    private func refreshSelection() {
        let target = segmentRect(selectedIndex)
        CCMotion.spring(selection, keyPath: "position",
                         to: NSValue(point: CGPoint(x: target.midX, y: target.midY)), .snappy)
        CCMotion.spring(selection, keyPath: "bounds",
                         to: NSValue(rect: CGRect(origin: .zero, size: target.size)), .snappy)
        applyTheme()
    }

    private func applyTheme() {
        guard let layer else { return }
        let colors = CCTheme.color
        switch chrome {
        case .elevated:
            layer.backgroundColor = colors.elevated.cgColor
            layer.borderColor = colors.border.cgColor
            // Skeuo: the well is recessed; the selected chip is raised glass
            // popping out of it.
            CCMaterial.dress(layer, as: .recessed(tint: colors.elevated),
                             radius: radius.resolved(for: bounds.height))
            selection.backgroundColor = colors.card.cgColor
            CCMaterial.dress(selection, as: .raised(tint: colors.card),
                             radius: selection.cornerRadius)
            selection.shadowColor = NSColor.black.cgColor
            selection.shadowOpacity = CCTheme.isDark ? 0.35 : 0.12
            selection.shadowRadius = 3
            selection.shadowOffset = CGSize(width: 0, height: CCTheme.isDark ? 0 : 1)
        case .plain:
            // Bare at rest; the selection is a quiet ink wash, no shadow.
            layer.backgroundColor = NSColor.clear.cgColor
            layer.borderColor = NSColor.clear.cgColor
            CCMaterial.strip(layer)
            selection.backgroundColor = colors.active.cgColor
            CCMaterial.dress(selection, as: .raised(tint: colors.active),
                             radius: selection.cornerRadius)
            selection.shadowOpacity = 0
        }
        for (index, label) in labels.enumerated() {
            label.textColor = index == selectedIndex ? colors.foreground : colors.mutedForeground
        }
        hover.backgroundColor = colors.hover.cgColor
    }

    // MARK: - Harness seams

    var probeHoverLayer: CALayer { hover }
    var probeSelectionLayer: CALayer { selection }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let point = convert(event.locationInWindow, from: nil)
        for index in labels.indices where segmentRect(index).contains(point) {
            guard index != selectedIndex else { return }
            selectedIndex = index
            onChange?(index)
            // The clicked segment is now selected — its chip marks it, so the
            // hover wash under it fades out (routeHover no-ops onto selection).
            routeHover(to: hoverIndex)
            return
        }
    }
}
