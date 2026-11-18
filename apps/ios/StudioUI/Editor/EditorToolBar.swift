import UIKit

/// The editor's tool bar — a DRILL-DOWN bar in the Mac inspector rail's
/// dress (icon over a small label, the open key on a gliding raised chip):
/// a row along the bottom of a portrait phone, a rail down the trailing edge
/// of a landscape phone, a row under the timeline on iPad.
///
///   Root:     Background · Cursor · … · Annotate | Add · Split · Speed | History
///   A pane:   ‹ · its sub-options (Background: Gradient · Mesh · Solid · … · Look · Frame)
///   Context:  ‹ · Adjust · Split · Duplicate · Delete · Speed · Options
///   Slicing:  ‹ · Split
///
/// Tapping a pane tool REPLACES the bar's keys with that pane's sub-options
/// (`setOptions`, built from the shared inspector specs); a sub-option opens
/// a SHORT panel above the bar (the editor decides). The back key (‹, far
/// leading) goes up a level. A selection swaps in its CONTEXT keys — the
/// timeline's own commands, never a fork of them. Level changes slide in
/// place from the side they lead to (a cross-fade under Reduce Motion), and
/// VoiceOver lands on the new level's first key.
///
/// Keys are the kit's rail keys (`CCIconRailKey`: ≥ 64 × 56 pt, VoiceOver
/// buttons labelled by their titles, keyboard-focusable). The bar scrolls
/// along its axis.
///
/// The keys ride a FLOATING Liquid Glass capsule (`CCGlassView`, iOS 26):
/// inset from the screen's edges (a phone's bottom bar drops toward the
/// home indicator, as system bars float), as long as its level's keys and
/// no longer than the room — so the capsule MORPHS when a level change
/// brings more or fewer keys (its far edge, the pushed one, on the house
/// bounce; a cross-fade under Reduce Motion). Reduce Transparency puts the
/// kit's opaque raised material in the glass's place. Where an inspector column is always on screen (iPad, the
/// iPhone Duo's crease layouts) the pane tools are left out.
@MainActor
final class EditorToolBar: UIView {
    enum Axis { case horizontal, vertical }

    enum Tool: Equatable {
        case add, split, speed, pane(InspectorTab), history
        /// ‹ — up a level (out of a pane, clear a selection, disarm slicing).
        case back
        /// A pane level's sub-option (`InspectorPanelOption.id`).
        case option(String)
        case adjust, duplicate, delete, options
    }

    enum Mode: Equatable {
        /// The root tools.
        case tools
        /// A pane's sub-options.
        case pane(InspectorTab)
        /// Something is selected: which context keys apply.
        case context(Context)
        /// The slice tool is armed (tap the VIDEO lane to cut).
        case slicing
    }

    struct Context: Equatable {
        var adjust: Bool
        var duplicate: Bool
        var delete: Bool
        var speed: Bool
        var options: Bool
    }

    /// A key was tapped (the key itself anchors any sheet it opens).
    var onTool: ((Tool, UIView) -> Void)?

    var axis: Axis = .horizontal { didSet { if axis != oldValue { relayout(); restyleChrome(); rebuild(animated: false, direction: 0) } } }
    var showsPaneTools = true { didSet { if showsPaneTools != oldValue { rebuild(animated: false, direction: 0) } } }
    /// Docked to the screen's edge (a hairline on the inner edge, keys kept
    /// inside the safe area) or a row on the region (iPad).
    var docked = true { didSet { if docked != oldValue { applyDocking(); relayout() } } }
    private(set) var mode: Mode = .tools
    /// The pane level's options (as last set).
    private(set) var options: [InspectorPanelOption] = []

    private let scroll = CCScrollView()
    /// The floating glass capsule the keys ride.
    private let glass = CCGlassView(shape: .capsule, interactive: true)
    /// The capsule's length along the axis (hugs the level's keys).
    private var lengthConstraint: NSLayoutConstraint?
    /// A level change is laying out: it fits (and animates) the capsule itself.
    private var holdsCapsule = false
    private var stack = UIStackView()
    private let hairline = UIView()
    private var keys: [(tool: Tool, key: CCIconRailKey)] = []
    private var axisConstraints: [NSLayoutConstraint] = []
    private var stackConstraints: [NSLayoutConstraint] = []
    /// The key whose panel is open (an option, Adjust, a pane tool).
    private(set) var openTool: Tool?
    /// The open key sits on a raised chip that GLIDES between keys (the kit
    /// rail's selected state) — fades in on open, out on close.
    private let chip = CALayer()
    /// The outgoing level while a level change animates (probes sample it).
    #if DEBUG
    private(set) var probeOutgoing: UIView?
    #endif
    #if DEBUG
    /// Harness seam: the row's scroll view (the slide check).
    var probeScroll: UIScrollView { scroll }
    #endif

    /// The bar's thickness across its axis (keys + padding), without the
    /// safe-area band a docked bar adds.
    static let thickness: CGFloat = capsuleThickness + 2 * glassMargin
    static let railWidth: CGFloat = CCIconRail.keyWidth + 8 + 2 * glassMargin
    /// The glass capsule's thickness (keys + their padding).
    static let capsuleThickness: CGFloat = CCIconRail.keyHeight + 8
    /// The capsule's inset from the bar's edges (it floats).
    static let glassMargin: CGFloat = 6

    #if DEBUG
    /// Probe seam — INJECTED DEFECT (`bar-snap`): level changes snap.
    static var probeSnapLevels = false
    /// Probe seam — INJECTED DEFECT (`no-back`): a pane level has no back key.
    static var probeNoBack = false
    #endif

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        accessibilityIdentifier = "studio.toolBar"
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.delaysContentTouches = false
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.accessibilityIdentifier = "studio.toolBar.glass"
        addSubview(glass)
        glass.contentView.addSubview(scroll)
        hairline.translatesAutoresizingMaskIntoConstraints = false
        hairline.isUserInteractionEnabled = false
        addSubview(hairline)
        chip.cornerCurve = .continuous
        chip.opacity = 0
        scroll.layer.insertSublayer(chip, at: 0)
        ccOnThemeChange { [weak self] in self?.restyleChrome() }
        restyleChrome()
        relayout()
        rebuild(animated: false, direction: 0)
        applyDocking()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Keys

    private func item(for tool: Tool) -> CCIconRail.Item {
        switch tool {
        case .add: return .init(title: "Add", symbol: "plus")
        case .split: return .init(title: "Split", symbol: "scissors")
        case .speed: return .init(title: "Speed", symbol: "gauge.with.needle")
        case .pane(let tab): return .init(title: tab.rawValue, symbol: tab.icon)
        case .history: return .init(title: InspectorFeature.showHistory.title, symbol: InspectorFeature.showHistory.symbol)
        case .back: return .init(title: "Back", symbol: "chevron-left")
        case .option(let id):
            let o = options.first { $0.id == id }
            return .init(title: o?.title ?? id, symbol: o?.symbol ?? "sliders")
        case .adjust: return .init(title: "Adjust", symbol: "slider.horizontal.3")
        case .duplicate: return .init(title: "Duplicate", symbol: "square.fill.on.square")
        case .delete: return .init(title: "Delete", symbol: "trash")
        case .options: return .init(title: "Options", symbol: "gearshape")
        }
    }

    private func hint(for tool: Tool) -> String? {
        switch tool {
        case .add: return "Adds an effect, a focus region, an annotation or a voice over, or arms the slice tool."
        case .split: return "Splits the recording at the playhead."
        case .speed: return "Sets the speed of the part under the playhead."
        case .pane: return "Shows its settings on the tool bar."
        case .history: return "Shows this project's earlier versions."
        case .back:
            switch mode {
            case .context: return "Clears the selection."
            case .slicing: return "Puts the slice tool away."
            default: return "Back to the tools."
            }
        case .option: return "Opens its controls above the tool bar."
        case .adjust: return "Opens the selection's settings."
        case .duplicate: return "Duplicates the selection."
        case .delete: return "Deletes the selection."
        case .options: return "Shows the selection's options."
        }
    }

    private func makeKey(_ tool: Tool) -> CCIconRailKey {
        let key = CCIconRailKey(item: item(for: tool))
        key.accessibilityHint = hint(for: tool)
        switch tool {
        case .pane(let tab): key.accessibilityIdentifier = "studio.tool.\(tab.rawValue.lowercased())"
        case .back: key.accessibilityIdentifier = "studio.tool.back"
        case .option(let id):
            key.accessibilityIdentifier = "studio.option.\(id)"
            key.growsToFit = axis == .horizontal
        default: break
        }
        key.addAction(UIAction { [weak self, weak key] _ in
            guard let self, let key else { return }
            CCHaptics.selection()
            self.onTool?(tool, key)
        }, for: .touchUpInside)
        return key
    }

    private func separator() -> UIView {
        let line = CCDivider(vertical: axis == .horizontal)
        line.translatesAutoresizingMaskIntoConstraints = false
        line.isAccessibilityElement = false
        let length: CGFloat = 28
        (axis == .horizontal ? line.heightAnchor : line.widthAnchor).constraint(equalToConstant: length).isActive = true
        return line
    }

    /// The level's tools, with separators (nil) between groups.
    private func tools(for mode: Mode) -> [Tool?] {
        switch mode {
        case .tools:
            var t: [Tool?] = []
            if showsPaneTools { t += InspectorTab.allCases.map { .pane($0) } + [nil] }
            t += [.add, .split, .speed]
            if showsPaneTools { t += [nil, .history] }
            return t
        case .pane:
            var t: [Tool?] = [.back, nil]
            #if DEBUG
            if Self.probeNoBack { t = [] }
            #endif
            return t + options.map { .option($0.id) }
        case .slicing:
            return [.back, nil, .split]
        case .context(let c):
            var t: [Tool?] = [.back, nil]
            if c.adjust { t.append(.adjust) }
            t.append(.split)
            if c.duplicate { t.append(.duplicate) }
            if c.delete { t.append(.delete) }
            if c.speed { t.append(.speed) }
            if c.options { t.append(.options) }
            return t
        }
    }

    /// Builds the level's keys in a fresh stack; animated, the old level
    /// slides out toward `direction` (−1 back, +1 deeper) as the new slides in.
    private func rebuild(animated: Bool, direction: CGFloat) {
        let old = stack
        let new = UIStackView()
        new.translatesAutoresizingMaskIntoConstraints = false
        new.spacing = 4
        new.alignment = .center
        new.axis = axis == .horizontal ? .horizontal : .vertical
        keys = []
        for tool in tools(for: mode) {
            guard let tool else { new.addArrangedSubview(separator()); continue }
            let key = makeKey(tool)
            keys.append((tool, key))
            new.addArrangedSubview(key)
        }
        var animate = animated && window != nil && old.superview != nil
        #if DEBUG
        if Self.probeSnapLevels { animate = false }
        #endif
        // The outgoing level leaves as a snapshot over the bar (the scroll
        // content follows only the new level).
        var ghost: UIView?
        if animate, let snap = old.snapshotView(afterScreenUpdates: false) {
            snap.frame = old.convert(old.bounds, to: self)
            snap.isUserInteractionEnabled = false
            snap.isAccessibilityElement = false
            addSubview(snap)
            ghost = snap
        }
        holdsCapsule = true
        defer { holdsCapsule = false }
        old.removeFromSuperview()
        stack = new
        scroll.addSubview(new)
        activateStackConstraints()
        layoutIfNeeded()
        fitCapsule(animated: animate)
        scroll.setContentOffset(.zero, animated: false)
        placeChip(animated: false)
        accessibilityElements = nil
        guard animate else { return }
        let horizontal = axis == .horizontal
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let travel: CGFloat = 44 * direction * (horizontal && rtl ? -1 : 1)
        let keyPath = horizontal ? "transform.translation.x" : "transform.translation.y"
        if direction != 0 {
            CCMotion.spring(new.layer, keyPath: keyPath, from: travel, to: 0, .smooth)
        } else {
            CCMotion.enter(new.layer, horizontal ? .slideUp(distance: 10) : .fade)
        }
        CCMotion.fadeAlpha(new, to: 1, duration: 0.22, from: 0)
        if let ghost {
            #if DEBUG
            probeOutgoing = ghost
            #endif
            CCMotion.fadeAlpha(ghost, to: 0, duration: 0.18)
            if direction != 0 { CCMotion.spring(ghost.layer, keyPath: keyPath, to: -travel / 2, .snappy) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self, weak ghost] in
                ghost?.removeFromSuperview()
                #if DEBUG
                if self?.probeOutgoing === ghost { self?.probeOutgoing = nil }
                #endif
            }
        }
    }

    // MARK: Layout

    private func relayout() {
        NSLayoutConstraint.deactivate(axisConstraints)
        let guide = safeAreaLayoutGuide
        let m = Self.glassMargin
        var c: [NSLayoutConstraint] = [
            scroll.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
        ]
        let length: NSLayoutConstraint
        if axis == .horizontal {
            length = glass.widthAnchor.constraint(equalToConstant: 200)
            c += [
                glass.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: m),
                glass.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -m),
                glass.heightAnchor.constraint(equalToConstant: Self.capsuleThickness),
                // Docked: hangs from the bar's top (the editor drops the bar
                // toward the home indicator); a row: centred in it.
                docked ? glass.topAnchor.constraint(equalTo: topAnchor, constant: m)
                       : glass.centerYAnchor.constraint(equalTo: centerYAnchor),
                hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
                hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
                hairline.topAnchor.constraint(equalTo: topAnchor),
                hairline.heightAnchor.constraint(equalToConstant: 1),
            ]
        } else {
            length = glass.heightAnchor.constraint(equalToConstant: 200)
            c += [
                glass.topAnchor.constraint(equalTo: topAnchor, constant: m),
                glass.bottomAnchor.constraint(lessThanOrEqualTo: guide.bottomAnchor, constant: -m),
                glass.leadingAnchor.constraint(equalTo: leadingAnchor, constant: m),
                glass.widthAnchor.constraint(equalToConstant: Self.railWidth - 2 * m),
                hairline.topAnchor.constraint(equalTo: topAnchor),
                hairline.bottomAnchor.constraint(equalTo: bottomAnchor),
                hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
                hairline.widthAnchor.constraint(equalToConstant: 1),
            ]
        }
        // Hugs the keys; the room caps it (the keys then scroll inside).
        length.priority = .init(999)
        lengthConstraint = length
        c.append(length)
        axisConstraints = c
        NSLayoutConstraint.activate(c)
        setNeedsLayout()
    }

    /// The level's keys end to end (+ the stack's padding), along the axis.
    private var contentLength: CGFloat {
        let fit = stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        return ceil((axis == .horizontal ? fit.width : fit.height) + 8)
    }

    /// The capsule grows or shrinks to the level's keys: on the house
    /// bounce at its far (pushed) edge when animated.
    private func fitCapsule(animated: Bool) {
        guard let lengthConstraint else { return }
        let target = contentLength
        guard abs(lengthConstraint.constant - target) > 0.5 else { return }
        var animate = animated && window != nil
        #if DEBUG
        if Self.probeSnapLevels { animate = false }
        #endif
        if animate {
            CCMotion.animate(lengthConstraint, to: target, in: self, duration: 0.42, curve: .bounce)
        } else {
            lengthConstraint.constant = target
        }
    }

    /// The glass capsule (probes: its frame, its effect).
    var probeGlass: CCGlassView { glass }

    private func activateStackConstraints() {
        NSLayoutConstraint.deactivate(stackConstraints)
        let pad: CGFloat = 4
        var c = [
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: pad),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: pad),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -pad),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -pad),
        ]
        if axis == .horizontal {
            c.append(stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -2 * pad))
        } else {
            c.append(stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -2 * pad))
        }
        stackConstraints = c
        NSLayoutConstraint.activate(c)
    }

    private func restyleChrome() {
        // The ground under the floating glass: the timeline region's surface
        // under a row (it reads as one region), the editor's ground beside a rail.
        backgroundColor = axis == .horizontal ? CCTheme.color.card : CCTheme.color.background
        hairline.backgroundColor = CCTheme.color.border
        CCMaterial.dress(chip, as: .raised(tint: CCTheme.color.elevated), radius: CCTheme.radius(.md), traits: traitCollection)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Keys that changed size (text size, a long sub-option) refit the
        // capsule; a level change animates it itself.
        if !holdsCapsule, let lengthConstraint, !CCMotion.isAnimating(lengthConstraint),
           abs(lengthConstraint.constant - contentLength) > 0.5 {
            lengthConstraint.constant = contentLength
            setNeedsLayout()
        }
        placeChip(animated: false)
    }

    private var chipKey: CCIconRailKey? {
        guard let openTool else { return nil }
        return keys.first { $0.tool == openTool }?.key
    }

    private func placeChip(animated: Bool) {
        let animate = animated && window != nil
        guard let key = chipKey, key.bounds.width > 1 else {
            guard chip.opacity > 0 else { return }
            if animate { CCMotion.fade(chip, keyPath: "opacity", to: Float(0), duration: 0.18) } else { chip.opacity = 0 }
            return
        }
        let target = key.convert(key.bounds, to: scroll).insetBy(dx: 1, dy: 2)
        let r = CCTheme.radius(.md)
        let shown = chip.opacity > 0.5
        if animate, shown {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            chip.bounds = CGRect(origin: .zero, size: target.size)
            CATransaction.commit()
            CCMotion.spring(chip, keyPath: "position", to: NSValue(cgPoint: CGPoint(x: target.midX, y: target.midY)), .smooth)
        } else if chip.frame != target || !shown {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            chip.frame = target
            CATransaction.commit()
        }
        if !shown {
            if animate {
                CCMotion.fade(chip, keyPath: "opacity", to: Float(1), duration: 0.2, from: Float(0))
                CCMotion.enter(chip, .scaleIn)
            } else {
                chip.opacity = 1
            }
        }
        chip.cornerRadius = r
        CCMaterial.refit(chip, radius: r)
        if animate {
            scroll.scrollRectToVisible(target.insetBy(dx: axis == .horizontal ? -24 : 0, dy: axis == .vertical ? -24 : 0),
                                       animated: true)
        }
    }

    private func applyDocking() {
        // The glass floats: no docked hairline (the capsule is the edge).
        hairline.isHidden = true
    }

    // MARK: State

    /// Marks the key whose panel is open (nil = none): it takes the
    /// selected state and the chip glides to it.
    func setOpen(_ tool: Tool?, animated: Bool = true) {
        openTool = tool
        refreshSelection()
        placeChip(animated: animated)
    }

    private func refreshSelection() {
        for (tool, key) in keys {
            var selected = tool == openTool
            if case .option(let id) = tool, options.first(where: { $0.id == id })?.isCurrent == true { selected = true }
            key.isSelected = selected
        }
    }

    /// The open pane (compat: the pane tool, or Adjust among the context keys).
    var openPane: InspectorTab? {
        if case .pane(let tab)? = openTool { return tab }
        return nil
    }

    /// Changes level: the keys slide in place (deeper from the trailing
    /// side, back from the leading side; a context swap rises).
    func setMode(_ newMode: Mode, animated: Bool) {
        guard newMode != mode else { return }
        let direction: CGFloat
        switch (mode, newMode) {
        case (.tools, .pane), (.tools, .context), (.tools, .slicing), (.pane, .context): direction = 1
        case (.pane, .tools), (.context, .tools), (.slicing, .tools), (.context, .pane): direction = -1
        default: direction = 0
        }
        mode = newMode
        openTool = nil
        rebuild(animated: animated, direction: direction)
        // VoiceOver lands on the new level's first key (‹ on a sub-level).
        let first = keys.first?.key
        #if DEBUG
        probeLastAnnounced = first
        #endif
        if window != nil { UIAccessibility.post(notification: .layoutChanged, argument: first) }
    }

    #if DEBUG
    /// The last key a level change moved VoiceOver to (the a11y gate reads it).
    private(set) var probeLastAnnounced: UIView?
    #endif

    /// The pane level's options: rebuilt in place when they change (a value
    /// that reveals more rows), the level kept.
    func setOptions(_ newOptions: [InspectorPanelOption]) {
        guard newOptions != options else { return }
        let sameKeys = newOptions.map(\.id) == options.map(\.id) && newOptions.map(\.title) == options.map(\.title)
        options = newOptions
        guard case .pane = mode else { return }
        if sameKeys { refreshSelection(); return }
        if case .option(let id)? = openTool, !newOptions.contains(where: { $0.id == id }) { openTool = nil }
        rebuild(animated: false, direction: 0)
    }

    // MARK: Probe

    /// The visible key titled `title` (the gates press keys by their labels).
    func probeKey(_ title: String) -> CCIconRailKey? {
        keys.first { $0.key.accessibilityLabel == title }?.key
    }

    /// The key for a tool on the CURRENT level.
    func key(for tool: Tool) -> CCIconRailKey? {
        keys.first { $0.tool == tool }?.key
    }

    /// Visible key titles, in order.
    var probeTitles: [String] { keys.compactMap { $0.key.accessibilityLabel } }

    /// The open key's gliding chip (motion probes sample it).
    var probeChipLayer: CALayer { chip }

    /// The level showing now (motion probes sample its layer).
    var probeVisibleStack: UIView { stack }
}
