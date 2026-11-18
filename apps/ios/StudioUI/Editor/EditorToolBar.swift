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
/// along its axis. When a level's keys don't fit, the capsule fills the
/// room and the gaps widen evenly so its edge lands BETWEEN two keys (a key
/// is never cut mid-glyph at rest); a soft edge fade inside the capsule
/// marks the side(s) with more, and a slide comes to rest with its leading
/// edge between two keys.
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
final class EditorToolBar: UIView, UIScrollViewDelegate {
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

    /// The edge fade inside the capsule on a side with more keys.
    static let edgeFade: CGFloat = 44
    /// Air between the capsule's ends and the first / last key.
    static let endPadding: CGFloat = 8
    /// A bottom panel's glass sheet runs on under the bar: the bar's own
    /// ground clears so the capsule floats over the sheet.
    private(set) var isOverSheet = false

    #if DEBUG
    /// Probe seam — INJECTED DEFECT (`bar-cuts-key`): the capsule runs to
    /// the room's edge, cutting the key there mid-glyph.
    static var probeCutsKey = false
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
        scroll.edgeFade = Self.edgeFade
        scroll.delegate = self
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
        line.accessibilityIdentifier = "studio.toolBar.separator"
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
        new.spacing = Self.keySpacing
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

    /// The level's keys end to end (+ the end padding), along the axis.
    private var contentLength: CGFloat {
        let fit = stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        // The laid-out level can come out wider than its fitting size (a
        // key that grows to its title): the capsule hugs whichever is longer.
        let laid = axis == .horizontal ? stack.bounds.width : stack.bounds.height
        return ceil(max(axis == .horizontal ? fit.width : fit.height, laid) + 2 * Self.endPadding)
    }

    /// The most the capsule may be along the axis (the bar's room).
    private var room: CGFloat {
        let guide = safeAreaLayoutGuide.layoutFrame
        let m = Self.glassMargin
        return axis == .horizontal ? guide.width - 2 * m : guide.maxY - 2 * m
    }

    /// The keys' natural spacing.
    static let keySpacing: CGFloat = 4
    /// The most a gap may widen so an overflowing level's edge lands
    /// between two keys with the capsule still filling the room.
    static let maxSpread: CGFloat = 22

    /// The capsule's resting length. The keys end to end when they fit.
    /// When they don't, the capsule fills the room and the gaps up to the
    /// last whole key that fits widen evenly so the edge lands in the gap
    /// after it — a key is never cut mid-glyph at rest,
    /// and the edge fade over that last key says there is more. (A gap that
    /// would have to widen past `maxSpread` leaves the capsule a little
    /// short of the room instead.) Sets the level's spacing.
    private func fitLevel() -> CGFloat {
        let base = Self.keySpacing
        let views = stack.arrangedSubviews.filter { !$0.isHidden }
        let sizes = views.map { axis == .horizontal ? $0.bounds.width : $0.bounds.height }
        let room = self.room
        func setSpacing(_ value: CGFloat) {
            if abs(stack.spacing - value) > 0.01 { stack.spacing = value }
        }
        // (Laid out: every key has its size; a separator is a hairline.)
        let laidOut = zip(views, sizes).allSatisfy { !($0.0 is CCIconRailKey) || $0.1 > 0.5 }
        guard room > 1, !sizes.isEmpty, laidOut else {
            setSpacing(base)
            return contentLength
        }
        // Each view's far end at the natural spacing (content coordinates).
        var ends: [CGFloat] = []
        var end = Self.endPadding
        for (i, size) in sizes.enumerated() {
            if i > 0 { end += base }
            end += size
            ends.append(end)
        }
        let full = ceil(end + Self.endPadding)
        guard full > room + 0.5 else {
            setSpacing(base)
            return full
        }
        #if DEBUG
        if Self.probeCutsKey {
            setSpacing(base)
            return floor(room)
        }
        #endif
        // The last whole key ends the end padding short of the capsule's
        // (round) end, as the first starts after it; the next key starts
        // past that end (its gap is at least the end padding wide).
        let edge = room - Self.endPadding
        let minExtra = Self.endPadding - base
        for k in ends.indices.reversed() where k < ends.count - 1 && ends[k] <= edge {
            let gaps = CGFloat(k)
            let extra = k == 0 ? minExtra : min(Self.maxSpread, (edge - ends[k]) / gaps)
            guard extra >= minExtra else { continue }
            setSpacing(base + extra)
            return floor(min(room, ends[k] + extra * gaps + Self.endPadding))
        }
        setSpacing(base)
        return floor(room)
    }

    /// The middles of the gaps between the level's keys (and separators),
    /// in the scroll's content coordinates along the axis.
    private var keyGaps: [CGFloat] {
        stack.layoutIfNeeded()
        let spans: [(CGFloat, CGFloat)] = stack.arrangedSubviews.filter { !$0.isHidden }.map {
            let f = $0.convert($0.bounds, to: scroll)
            // (The scroll's bounds are its content coordinates.)
            return axis == .horizontal ? (f.minX, f.maxX) : (f.minY, f.maxY)
        }.sorted { $0.0 < $1.0 }
        return zip(spans, spans.dropFirst()).map { ($0.1 + $1.0) / 2 }
    }

    /// The capsule grows or shrinks to the level's keys: on the house
    /// bounce at its far (pushed) edge when animated.
    private func fitCapsule(animated: Bool) {
        guard let lengthConstraint else { return }
        let target = fitLevel()
        stack.layoutIfNeeded()
        guard abs(lengthConstraint.constant - target) > 0.5 else { return }
        var animate = animated && window != nil
        #if DEBUG
        if Self.probeSnapLevels { animate = false }
        #endif
        if animate {
            // Keys that settle their size meanwhile (a growing title) refit after.
            CCMotion.animate(lengthConstraint, to: target, in: self, duration: 0.42, curve: .bounce) { [weak self] in
                DispatchQueue.main.async { self?.setNeedsLayout() }
            }
        } else {
            lengthConstraint.constant = target
        }
    }

    /// The glass capsule (probes: its frame, its effect).
    var probeGlass: CCGlassView { glass }

    private func activateStackConstraints() {
        NSLayoutConstraint.deactivate(stackConstraints)
        let pad: CGFloat = 4
        // A little more air at the ends than across the bar.
        let along = Self.endPadding
        let h = axis == .horizontal
        var c = [
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: h ? along : pad),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: h ? pad : along),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -(h ? along : pad)),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -(h ? pad : along)),
        ]
        if axis == .horizontal {
            c.append(stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -2 * pad))
        } else {
            c.append(stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -2 * pad))
        }
        stackConstraints = c
        NSLayoutConstraint.activate(c)
    }

    private var groundColor: UIColor {
        // The ground under the floating glass: the timeline region's surface
        // under a row (it reads as one region), the editor's ground beside a
        // rail — clear over a bottom panel's sheet (the capsule floats on it).
        if isOverSheet { return .clear }
        return axis == .horizontal ? CCTheme.color.card : CCTheme.color.background
    }

    /// A bottom panel's glass sheet runs on under the bar (`true`): the
    /// bar's ground fades out so the capsule floats over the ONE sheet; it
    /// fades back as the panel closes.
    func setOverSheet(_ over: Bool, animated: Bool) {
        guard over != isOverSheet else { return }
        isOverSheet = over
        if animated, window != nil {
            UIView.animate(withDuration: over ? 0.22 : 0.26, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.backgroundColor = self.groundColor
            }
        } else {
            backgroundColor = groundColor
        }
    }

    private func restyleChrome() {
        backgroundColor = groundColor
        hairline.backgroundColor = CCTheme.color.border
        CCMaterial.dress(chip, as: .raised(tint: CCTheme.color.elevated), radius: CCTheme.radius(.md), traits: traitCollection)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Keys that changed size (text size, a long sub-option) refit the
        // capsule; a level change animates it itself.
        if !holdsCapsule, let lengthConstraint, !CCMotion.isAnimating(lengthConstraint) {
            let target = fitLevel()
            if abs(lengthConstraint.constant - target) > 0.5 {
                lengthConstraint.constant = target
                setNeedsLayout()
            }
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
        if animate { revealKey(target) }
    }

    private func applyDocking() {
        // The glass floats: no docked hairline (the capsule is the edge).
        hairline.isHidden = true
    }

    // MARK: Sliding

    /// Slides the open key into view (clear of the edge fades) and comes to
    /// rest with an edge between two keys — never through one at both ends.
    private func revealKey(_ rect: CGRect) {
        let h = axis == .horizontal
        let length = h ? scroll.bounds.width : scroll.bounds.height
        let maxOffset = (h ? scroll.contentSize.width : scroll.contentSize.height) - length
        guard maxOffset > 0.5 else { return }
        let current = h ? scroll.contentOffset.x : scroll.contentOffset.y
        let lo = (h ? rect.maxX : rect.maxY) + Self.edgeFade - length   // the least offset that shows it
        let hi = (h ? rect.minX : rect.minY) - Self.edgeFade            // the most
        guard current < lo - 0.5 || current > hi + 0.5 else { return }
        let gaps = keyGaps
        // An edge in a gap: the leading edge at one, or the trailing edge.
        let stops = ([0, maxOffset] + gaps + gaps.map { $0 - length }).filter { $0 >= 0 && $0 <= maxOffset }
        let fits = stops.filter { $0 >= lo - 0.5 && $0 <= hi + 0.5 }
        let target = fits.min(by: { abs($0 - current) < abs($1 - current) }) ?? min(max(current, lo), max(lo, hi))
        let clamped = min(max(target, 0), maxOffset)
        scroll.setContentOffset(h ? CGPoint(x: clamped, y: 0) : CGPoint(x: 0, y: clamped), animated: true)
    }

    /// A slide comes to rest with its leading edge in the gap between two
    /// keys (or at either end), never through a key.
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        let h = axis == .horizontal
        let maxOffset = h ? scrollView.contentSize.width - scrollView.bounds.width
                          : scrollView.contentSize.height - scrollView.bounds.height
        guard maxOffset > 1 else { return }
        let target = h ? targetContentOffset.pointee.x : targetContentOffset.pointee.y
        let stops = [0] + keyGaps.filter { $0 > 0 && $0 < maxOffset } + [maxOffset]
        guard let best = stops.min(by: { abs($0 - target) < abs($1 - target) }) else { return }
        if h { targetContentOffset.pointee.x = best } else { targetContentOffset.pointee.y = best }
    }

    #if DEBUG
    /// The resting viewport (scroll coordinates) and every key's glyph
    /// frames in it — the bar-edge gate checks none straddles the edge.
    var probeGlyphs: (viewport: CGRect, glyphs: [(key: String, frame: CGRect)]) {
        layoutIfNeeded()
        var out: [(String, CGRect)] = []
        for (_, key) in keys {
            func walk(_ v: UIView) {
                if v is UILabel || v is CCIconView {
                    if !v.isHidden { out.append((key.accessibilityLabel ?? "?", v.convert(v.bounds, to: scroll))) }
                    return
                }
                v.subviews.forEach(walk)
            }
            walk(key)
        }
        return (scroll.bounds, out)
    }
    /// The edge fade's mask (nil = no fade).
    var probeFadeMask: CAGradientLayer? { scroll.probeFadeMask }
    #endif

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
