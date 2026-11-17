import UIKit

/// The editor's tool bar (the editor redesign): one row of icon + label
/// tools along the bottom of a portrait phone, a rail down the trailing edge
/// of a landscape phone, a row under the timeline on iPad.
///
///   Tools:    Add · Split · Speed | Background · Cursor · … · Annotate | History
///   Context:  Done · Adjust · Split · Duplicate · Delete · Speed · Options
///   Slicing:  Done · Split
///
/// The pane tools (`showsPaneTools`) open the inspector's panes as a panel
/// (the editor decides how); where an inspector column is always on screen
/// (iPad, the iPhone Duo's crease layouts) they are left out. When something
/// is selected on the timeline or the stage, the CONTEXT keys take the tools'
/// place — the timeline's own commands (`StudioTimelineViewController`'s
/// split / duplicate / delete / speed / item menu), never a fork of them.
///
/// Keys are the kit's rail keys (`CCIconRailKey`: ≥ 64 × 56 pt, VoiceOver
/// buttons labelled by their titles, keyboard-focusable). The bar scrolls
/// along its axis. Swapping tools ⇄ context cross-fades with a short rise
/// (a cross-fade alone under Reduce Motion).
@MainActor
final class EditorToolBar: CCSurface {
    enum Axis { case horizontal, vertical }

    enum Tool: Equatable {
        case add, split, speed, pane(InspectorTab), history
        case done, adjust, duplicate, delete, options
    }

    enum Mode: Equatable {
        case tools
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

    var axis: Axis = .horizontal { didSet { if axis != oldValue { relayout() } } }
    var showsPaneTools = true { didSet { if showsPaneTools != oldValue { rebuildTools() } } }
    /// Docked to the screen's edge (no corners, a hairline on the inner
    /// edge, keys kept inside the safe area) or a floating card (iPad).
    var docked = true { didSet { if docked != oldValue { applyDocking() } } }
    private(set) var mode: Mode = .tools

    private let scroll = UIScrollView()
    private let toolsStack = UIStackView()
    private let contextStack = UIStackView()
    private let hairline = UIView()
    private var keys: [(tool: Tool, key: CCIconRailKey)] = []
    private var contextKeys: [(tool: Tool, key: CCIconRailKey)] = []
    private var axisConstraints: [NSLayoutConstraint] = []
    private(set) var openPane: InspectorTab?
    /// The open panel's tool sits on a raised chip that GLIDES between keys
    /// (the kit rail's selected state) — fades in on open, out on close.
    private let chip = CALayer()

    /// The bar's thickness across its axis (keys + padding), without the
    /// safe-area band a docked bar adds.
    static let thickness: CGFloat = CCIconRail.keyHeight + 8
    static let railWidth: CGFloat = CCIconRail.keyWidth + 8

    init() {
        super.init(.raisedMatte, tint: CCTheme.color.card, radius: .none)
        accessibilityIdentifier = "studio.toolBar"
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.delaysContentTouches = false
        addSubview(scroll)
        hairline.translatesAutoresizingMaskIntoConstraints = false
        hairline.isUserInteractionEnabled = false
        addSubview(hairline)
        for stack in [toolsStack, contextStack] {
            stack.translatesAutoresizingMaskIntoConstraints = false
            stack.spacing = 4
            stack.alignment = .center
            scroll.addSubview(stack)
        }
        contextStack.isHidden = true
        chip.cornerCurve = .continuous
        chip.opacity = 0
        scroll.layer.insertSublayer(chip, at: 0)
        ccOnThemeChange { [weak self] in self?.restyleChrome() }
        restyleChrome()
        rebuildTools()
        relayout()
        applyDocking()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Keys

    private static func item(for tool: Tool) -> CCIconRail.Item {
        switch tool {
        case .add: return .init(title: "Add", symbol: "plus")
        case .split: return .init(title: "Split", symbol: "scissors")
        case .speed: return .init(title: "Speed", symbol: "gauge.with.needle")
        case .pane(let tab): return .init(title: tab.rawValue, symbol: tab.icon)
        case .history: return .init(title: InspectorFeature.showHistory.title, symbol: InspectorFeature.showHistory.symbol)
        case .done: return .init(title: "Done", symbol: "checkmark")
        case .adjust: return .init(title: "Adjust", symbol: "slider.horizontal.3")
        case .duplicate: return .init(title: "Duplicate", symbol: "square.fill.on.square")
        case .delete: return .init(title: "Delete", symbol: "trash")
        case .options: return .init(title: "Options", symbol: "gearshape")
        }
    }

    private static func hint(for tool: Tool) -> String? {
        switch tool {
        case .add: return "Adds an effect, a focus region, an annotation or a voice over, or arms the slice tool."
        case .split: return "Splits the recording at the playhead."
        case .speed: return "Sets the speed of the part under the playhead."
        case .pane: return "Opens its settings in a panel above the tool bar; again closes it."
        case .history: return "Shows this project's earlier versions."
        case .done: return "Clears the selection."
        case .adjust: return "Opens the selection's settings."
        case .duplicate: return "Duplicates the selection."
        case .delete: return "Deletes the selection."
        case .options: return "Shows the selection's options."
        }
    }

    private func makeKey(_ tool: Tool) -> CCIconRailKey {
        let key = CCIconRailKey(item: Self.item(for: tool))
        key.accessibilityHint = Self.hint(for: tool)
        if case .pane(let tab) = tool { key.accessibilityIdentifier = "studio.tool.\(tab.rawValue.lowercased())" }
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

    private func rebuildTools() {
        for v in toolsStack.arrangedSubviews { v.removeFromSuperview() }
        keys = []
        var tools: [Tool] = [.add, .split, .speed]
        if showsPaneTools { tools += InspectorTab.allCases.map { .pane($0) } + [.history] }
        for (i, tool) in tools.enumerated() {
            if showsPaneTools, i == 3 || tool == .history { toolsStack.addArrangedSubview(separator()) }
            let key = makeKey(tool)
            keys.append((tool, key))
            toolsStack.addArrangedSubview(key)
        }
        setOpenPane(openPane)
    }

    private func rebuildContext(_ tools: [Tool]) {
        for v in contextStack.arrangedSubviews { v.removeFromSuperview() }
        contextKeys = []
        for tool in tools {
            let key = makeKey(tool)
            contextKeys.append((tool, key))
            contextStack.addArrangedSubview(key)
        }
    }

    // MARK: Layout

    private func relayout() {
        NSLayoutConstraint.deactivate(axisConstraints + stackConstraints.values.flatMap { $0 })
        let horizontal = axis == .horizontal
        for stack in [toolsStack, contextStack] {
            stack.axis = horizontal ? .horizontal : .vertical
        }
        // Separators follow the axis.
        rebuildTools()
        let guide = safeAreaLayoutGuide
        let pad: CGFloat = 4
        var c: [NSLayoutConstraint] = []
        if horizontal {
            c += [
                scroll.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
                scroll.topAnchor.constraint(equalTo: topAnchor),
                scroll.heightAnchor.constraint(equalToConstant: Self.thickness),
                hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
                hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
                hairline.topAnchor.constraint(equalTo: topAnchor),
                hairline.heightAnchor.constraint(equalToConstant: 1),
            ]
        } else {
            c += [
                scroll.topAnchor.constraint(equalTo: topAnchor),
                scroll.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
                scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
                scroll.widthAnchor.constraint(equalToConstant: Self.railWidth),
                hairline.topAnchor.constraint(equalTo: topAnchor),
                hairline.bottomAnchor.constraint(equalTo: bottomAnchor),
                hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
                hairline.widthAnchor.constraint(equalToConstant: 1),
            ]
        }
        stackConstraints = [:]
        for stack in [toolsStack, contextStack] {
            // Only the stack on show sizes the scroll content (two stacks of
            // different lengths would fight over it).
            var own = [
                stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: pad),
                stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: pad),
            ]
            let sizing = [
                stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -pad),
                stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -pad),
            ]
            if horizontal {
                own.append(stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -2 * pad))
            } else {
                own.append(stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -2 * pad))
            }
            c += own
            stackConstraints[ObjectIdentifier(stack)] = sizing
        }
        axisConstraints = c
        NSLayoutConstraint.activate(c)
        activateSizing()
        setNeedsLayout()
    }

    private var stackConstraints: [ObjectIdentifier: [NSLayoutConstraint]] = [:]

    private func activateSizing() {
        let shown = mode == .tools ? toolsStack : contextStack
        let hidden = mode == .tools ? contextStack : toolsStack
        NSLayoutConstraint.deactivate(stackConstraints[ObjectIdentifier(hidden)] ?? [])
        NSLayoutConstraint.activate(stackConstraints[ObjectIdentifier(shown)] ?? [])
    }

    private func restyleChrome() {
        hairline.backgroundColor = CCTheme.color.border
        CCMaterial.dress(chip, as: .raised(tint: CCTheme.color.elevated), radius: CCTheme.radius(.md), traits: traitCollection)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        placeChip(animated: false)
    }

    /// The key the chip marks: the open pane's tool, or Adjust among the
    /// context keys while its panel is open.
    private var chipKey: CCIconRailKey? {
        guard let openPane else { return nil }
        switch mode {
        case .tools: return keys.first { $0.tool == .pane(openPane) }?.key
        case .context: return contextKeys.first { $0.tool == .adjust }?.key
        case .slicing: return nil
        }
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
        radius = docked ? .none : .lg
        hairline.isHidden = !docked
    }

    // MARK: State

    /// Marks the pane tool whose panel is open (nil = none): the key takes
    /// the selected state and the chip glides to it (Adjust among the
    /// context keys).
    func setOpenPane(_ tab: InspectorTab?, animated: Bool = true) {
        openPane = tab
        for (tool, key) in keys {
            if case .pane(let t) = tool { key.isSelected = t == tab } else { key.isSelected = false }
        }
        for (tool, key) in contextKeys { key.isSelected = tool == .adjust && tab != nil }
        placeChip(animated: animated)
    }

    /// Tools, the context keys for a selection, or the slice tool's bar.
    func setMode(_ newMode: Mode, animated: Bool) {
        guard newMode != mode else { return }
        let wasTools = mode == .tools
        mode = newMode
        switch newMode {
        case .tools:
            break
        case .slicing:
            rebuildContext([.done, .split])
        case .context(let c):
            var tools: [Tool] = [.done]
            if c.adjust { tools.append(.adjust) }
            tools.append(.split)
            if c.duplicate { tools.append(.duplicate) }
            if c.delete { tools.append(.delete) }
            if c.speed { tools.append(.speed) }
            if c.options { tools.append(.options) }
            rebuildContext(tools)
        }
        let showContext = newMode != .tools
        let incoming = showContext ? contextStack : toolsStack
        let outgoing = showContext ? toolsStack : contextStack
        // Context → context (another selection): the keys change in place.
        let swap = showContext == wasTools
        incoming.isHidden = false
        outgoing.isHidden = true
        activateSizing()
        layoutIfNeeded()
        setOpenPane(openPane, animated: false)
        scroll.setContentOffset(.zero, animated: false)
        accessibilityElements = nil
        guard swap, animated, window != nil else { return }
        CCMotion.fadeAlpha(incoming, to: 1, duration: 0.2, from: 0)
        CCMotion.enter(incoming.layer, axis == .horizontal ? .slideUp(distance: 10) : .fade)
        UIAccessibility.post(notification: .layoutChanged, argument: incoming.arrangedSubviews.first)
    }

    // MARK: Probe

    /// The visible key titled `title` (the gates press keys by their labels).
    func probeKey(_ title: String) -> CCIconRailKey? {
        let pool = mode == .tools ? keys : contextKeys
        return pool.first { $0.key.accessibilityLabel == title }?.key
    }

    /// The key for a tool in the CURRENT mode.
    func key(for tool: Tool) -> CCIconRailKey? {
        (mode == .tools ? keys : contextKeys).first { $0.tool == tool }?.key
    }

    /// Visible key titles, in order.
    var probeTitles: [String] {
        (mode == .tools ? keys : contextKeys).compactMap { $0.key.accessibilityLabel }
    }

    /// The open tool's gliding chip (motion probes sample it).
    var probeChipLayer: CALayer { chip }

    /// The stack showing now (motion probes sample its layer).
    var probeVisibleStack: UIView { mode == .tools ? toolsStack : contextStack }
}
