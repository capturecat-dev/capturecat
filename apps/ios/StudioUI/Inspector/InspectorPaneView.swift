import UIKit

/// One inspector pane on iOS, built from the shared spec's sections
/// (`InspectorTab.sections`): a titled card per section, a row per control.
/// `refresh(_:)` re-reads every value and applies every show/hide rule; a
/// change in what shows GROWS on the house bounce — revealed rows fade in
/// while the rows below are pushed, only the pushed edge moves.
@MainActor
final class InspectorPaneView: UIView {
    let tab: InspectorTab
    private(set) var sections: [(spec: InspectorSection, view: InspectorSectionView)] = []
    private var hasRefreshed = false

    #if DEBUG
    /// Probe seam — INJECTED DEFECT: show/hide snaps (no growth animation).
    static var probeSnapGrowth = false
    #endif
    #if DEBUG
    /// Probe seam — INJECTED DEFECT (`drop-control`): this row never shows.
    static var probeDropRowID: String?
    #endif
    /// The last growth: the section that grew and its height before/after.
    private(set) var lastGrowth: (section: UIView, from: CGFloat, to: CGFloat)?

    init(tab: InspectorTab, host: InspectorHost) {
        self.tab = tab
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        accessibilityIdentifier = "inspector.pane.\(tab)"
        let column = UIStackView()
        column.axis = .vertical
        column.spacing = CCSpace.lg
        column.alignment = .fill
        // Keyboard (iPad): the pane is one focus group and each row its own,
        // so Tab steps row to row and the arrows move within a row.
        focusGroupIdentifier = "studio.inspector.\(tab.rawValue)"
        for spec in tab.sections {
            let rows = spec.rows.map { Self.makeRow($0, host: host) }
            for row in rows { row.focusGroupIdentifier = "studio.inspector.\(tab.rawValue).\(row.rowID)" }
            let view = InspectorSectionView(title: spec.title, rows: rows)
            view.accessibilityIdentifier = spec.id
            column.addArrangedSubview(view)
            sections.append((spec, view))
        }
        addSubview(column)
        pinEdges(column, to: self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    static func makeRow(_ row: InspectorRow, host: InspectorHost) -> InspectorRowView {
        switch row {
        case .slider(let spec):
            let volume = AudioPane.volumes.first { $0.slider.id == spec.id }
            return InspectorSliderRowView(spec, host: host, symbol: volume.map { v in { v.symbol(for: $0) } })
        case .toggle(let spec): return InspectorToggleRowView(spec, host: host)
        case .choice(let spec): return InspectorChoiceRowView(spec, host: host)
        case .color(let spec): return InspectorColorRowView(title: spec.title, [spec], host: host)
        case .colorPair(let title, let a, let b): return InspectorColorRowView(title: title, [a, b], host: host)
        case .text(let spec):
            return InspectorTextRowView(spec, host: host, showsTitle: spec.id.hasPrefix("background."))
        case .action(let spec): return InspectorActionRowView([spec], host: host)
        case .actions(let specs): return InspectorActionRowView(specs, host: host)
        case .caption(let spec): return InspectorCaptionRowView(spec)
        case .feature(let feature, let visible): return InspectorFeatureRowView(feature, visible: visible, host: host)
        case .custom(let id, let visible): return InspectorCustomRows.make(id: id, visible: visible, host: host)
        }
    }

    /// The bar's sub-options for this pane (the drill-down level): each
    /// opens a SHORT panel of one small group of rows. A section led by a
    /// chip choice (Background: Gradient, Mesh, ...) offers one option per
    /// choice; a section of a few rows is one option; a longer one splits
    /// into one option per titled row (its captions and previews ride along).
    func panelOptions(_ scope: InspectorScope) -> [InspectorPanelOption] {
        var out: [InspectorPanelOption] = []
        var index = 0
        let all = rows
        for (spec, view) in sections {
            let base = index
            index += view.rows.count
            guard spec.visible(scope) else { continue }
            let visible = view.rows.indices.filter { view.rows[$0].isRowVisible(scope) }.map { base + $0 }
            guard !visible.isEmpty else { continue }
            if case .choice(let choice)? = spec.rows.first, choice.style == .chips, choice.items.count <= 8,
               visible.first == base {
                let current = choice.read(scope)
                for (i, item) in choice.items.enumerated() {
                    out.append(InspectorPanelOption(
                        id: "\(spec.id)#\(i)", title: item, symbol: InspectorPanelOption.symbol(for: item, fallback: tab.icon),
                        rows: [], choice: .init(row: base, index: i), section: spec.id, isCurrent: current == i))
                }
                continue
            }
            let title = spec.title ?? tab.rawValue
            if visible.count <= 3 || spec.title == nil {
                out.append(InspectorPanelOption(
                    id: spec.id, title: title, symbol: InspectorPanelOption.symbol(for: title, fallback: tab.icon),
                    rows: visible, choice: nil, section: spec.id, isCurrent: false))
                continue
            }
            // Chunk: a titled row starts an option; untitled rows (captions,
            // previews) join the option around them.
            var chunks: [(title: String, rows: [Int], kind: InspectorRow)] = []
            var leading: [Int] = []
            for i in visible {
                let row = spec.rows[i - base]
                if var rowTitle = InspectorPanelOption.title(of: row, scope: scope) {
                    // Chips the Mac titles by their section ("Slide" under
                    // Slide) take a key name for what they pick.
                    if case .choice(let c) = row, c.title == spec.title,
                       let name = InspectorPanelOption.choiceKeyNames[c.id] { rowTitle = name }
                    chunks.append((rowTitle, leading + [i], row))
                    leading = []
                } else if chunks.isEmpty {
                    leading.append(i)
                } else {
                    chunks[chunks.count - 1].rows.append(i)
                }
            }
            if !leading.isEmpty { chunks.append((title, leading, spec.rows[leading[0] - base])) }
            for chunk in chunks {
                out.append(InspectorPanelOption(
                    id: "\(spec.id)/\(all[chunk.rows.first!].rowID)", title: chunk.title,
                    symbol: InspectorPanelOption.symbol(for: chunk.title,
                                                        fallback: InspectorPanelOption.symbol(of: chunk.kind, tab: tab)),
                    rows: chunk.rows, choice: nil, section: spec.id, isCurrent: false))
            }
        }
        // A phone's short panel has a height budget: an option whose rows
        // would overflow it splits into further keys (never clipped, never
        // scrolled).
        if let budget = panelBudget, budget > 0 { out = split(out, budget: budget, scope: scope) }
        if out.isEmpty {
            out.append(InspectorPanelOption(id: "\(tab.rawValue).all", title: tab.rawValue, symbol: tab.icon,
                                            rows: Array(all.indices), choice: nil, section: nil, isCurrent: false))
        }
        // One name per key: a repeated title (Cursor's three "Size" rows)
        // takes its group's first word after the first ("Click Size").
        var seen = Set<String>()
        for (i, o) in out.enumerated() {
            defer { seen.insert(out[i].title) }
            guard seen.contains(o.title),
                  let group = sections.first(where: { $0.spec.id == o.section })?.spec.title?.split(separator: " ").first
            else { continue }
            out[i] = InspectorPanelOption(id: o.id, title: "\(group) \(o.title)", symbol: o.symbol, rows: o.rows,
                                          choice: o.choice, section: o.section, isCurrent: o.isCurrent)
        }
        return out
    }

    /// The room a phone's short panel has for one option's rows (nil = no
    /// limit: the iPad column, a side panel). Set by the inspector.
    var panelBudget: CGFloat?

    /// The air above and below a short panel's rows (the pane's inset in it).
    static let panelVerticalPadding: CGFloat = 2 * CCSpace.md

    /// Splits every option whose rows overflow `budget` into keys that each
    /// fit: a titled row and the untitled rows riding with it (its preview,
    /// its caption) stay together. A choice group's overflow becomes keys
    /// after the group's choices (shared by every choice).
    private func split(_ options: [InspectorPanelOption], budget: CGFloat, scope: InspectorScope) -> [InspectorPanelOption] {
        var out: [InspectorPanelOption] = []
        var pending: [InspectorPanelOption] = []
        var splitSections = Set<String>()
        for (n, o) in options.enumerated() {
            let isChoice = o.choice != nil
            let indices = isChoice ? o.section.map { rowsAfterChoice(section: $0, scope: scope) } ?? [] : o.rows
            let chunks = chunk(indices, budget: budget, scope: scope)
            if chunks.count > 1 {
                out.append(InspectorPanelOption(id: o.id, title: o.title, symbol: o.symbol, rows: chunks[0],
                                                choice: o.choice, section: o.section, isCurrent: o.isCurrent))
                let section = o.section ?? o.id
                if !isChoice || !splitSections.contains(section) {
                    splitSections.insert(section)
                    let extra = chunks.dropFirst().enumerated().map { k, rows in
                        overflowOption(of: o, rows: rows, number: k + 2, scope: scope)
                    }
                    if isChoice { pending += extra } else { out += extra }
                }
            } else {
                out.append(o)
            }
            // A choice group's extra keys follow its last choice.
            let next = options.indices.contains(n + 1) ? options[n + 1] : nil
            if !pending.isEmpty, !(next?.choice != nil && next?.section == o.section) {
                out += pending
                pending = []
            }
        }
        return out + pending
    }

    private func overflowOption(of o: InspectorPanelOption, rows: [Int], number: Int,
                                scope: InspectorScope) -> InspectorPanelOption {
        let specs = specRows
        let titled = rows.lazy.compactMap { InspectorPanelOption.title(of: specs[$0], scope: scope) }.first
        let title = titled ?? Self.name(ofRowID: self.rows[rows[0]].rowID) ?? "\(o.title) \(number)"
        let kind = specs[rows.first { InspectorPanelOption.title(of: specs[$0], scope: scope) != nil } ?? rows[0]]
        return InspectorPanelOption(
            id: "\(o.section ?? o.id)+\(rows[0])", title: title,
            symbol: InspectorPanelOption.symbol(for: title, fallback: InspectorPanelOption.symbol(of: kind, tab: tab)),
            rows: rows, choice: nil, section: o.section, isCurrent: false)
    }

    /// Row `i`'s height at the pane's width (hidden rows too): its last
    /// laid-out height when it has one, else a fitting pass.
    func estimatedHeight(_ i: Int) -> CGFloat {
        let row = rows[i]
        if !row.isHidden, row.bounds.height > 0.5 { measured[row.rowID] = row.bounds.height }
        if let h = measured[row.rowID] { return h }
        let fit = fittingHeight(i)
        guard fit < 1 else { return fit }
        // A control drawn from its frame (the slider) has no fitting height:
        // its last laid-out height, else the house control height.
        return row.bounds.height > 1 ? row.bounds.height : 44
    }

    /// Row `i`'s height from a fitting pass at the pane's width.
    func fittingHeight(_ i: Int) -> CGFloat {
        let row = rows[i]
        let width = bounds.width > 1 ? bounds.width : max(1, (superview?.bounds.width ?? 320) - 2 * CCSpace.lg)
        // Multi-line copy wraps at the row's width in the fitting pass too.
        func wrap(_ v: UIView) {
            if let l = v as? UILabel, l.numberOfLines != 1 { l.preferredMaxLayoutWidth = width - 40 }
            v.subviews.forEach(wrap)
        }
        wrap(row)
        let h = row.systemLayoutSizeFitting(CGSize(width: width, height: 0), withHorizontalFittingPriority: .required,
                                            verticalFittingPriority: .fittingSizeLevel).height
        func unwrap(_ v: UIView) {
            if let l = v as? UILabel, l.numberOfLines != 1 { l.preferredMaxLayoutWidth = 0 }
            v.subviews.forEach(unwrap)
        }
        unwrap(row)
        return h
    }
    /// Rows' heights as last laid out (by id; a size-class change clears it).
    private var measured: [String: CGFloat] = [:]

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if previous?.horizontalSizeClass != traitCollection.horizontalSizeClass
            || previous?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory { measured = [:] }
    }

    /// A key name for an untitled control row from its id
    /// ("blocks.offsetPad" → "Offset").
    static func name(ofRowID id: String) -> String? {
        guard var last = id.split(separator: ".").last.map(String.init) else { return nil }
        for suffix in ["Pad", "Preview", "Row"] where last.hasSuffix(suffix) && last.count > suffix.count {
            last.removeLast(suffix.count)
        }
        var words: [String] = []
        for ch in last {
            if ch.isUppercase || words.isEmpty { words.append(String(ch)) } else { words[words.count - 1].append(ch) }
        }
        let name = words.joined(separator: " ").lowercased()
        return name.isEmpty ? nil : name.prefix(1).uppercased() + name.dropFirst()
    }

    /// A display-only preview well (no control of its own).
    static func isPreview(_ row: InspectorRowView) -> Bool {
        row is InspectorPreviewRow || row is InspectorLivePreviewRow
    }

    /// Every row's spec, in `rows` order.
    private var specRows: [InspectorRow] { sections.flatMap { $0.spec.rows } }

    /// `indices` in groups that each fit `budget` (a group too tall on its
    /// own stays one: the gate reports it).
    private func chunk(_ indices: [Int], budget: CGFloat, scope: InspectorScope) -> [[Int]] {
        guard indices.count > 1 else { return [indices] }
        let specs = specRows
        let height = estimatedHeight
        // Units: a control with the captions under it; a lone preview
        // well leading a control (Show Cursor's) stays with it.
        let all = rows
        var units: [[Int]] = []
        for i in indices {
            var caption = all[i].rowID.hasSuffix("Caption")
            if case .caption = specs[i] { caption = true }
            let titled = InspectorPanelOption.title(of: specs[i], scope: scope) != nil
            let afterPreview = units.last.map { $0.count == 1 && Self.isPreview(all[$0[0]]) } ?? false
            if let last = units.indices.last, caption || (titled && afterPreview) {
                units[last].append(i)
            } else {
                units.append([i])
            }
        }
        let gap = InspectorSectionView.panelRowGap
        let room = budget - Self.panelVerticalPadding
        func unitHeight(_ u: [Int]) -> CGFloat { u.map(height).reduce(0, +) + gap * CGFloat(u.count - 1) }
        var chunks: [[Int]] = []
        var used: CGFloat = 0
        for u in units {
            let h = unitHeight(u)
            if let last = chunks.indices.last, used + gap + h <= room {
                chunks[last] += u
                used += gap + h
            } else {
                chunks.append(u)
                used = h
            }
        }
        return chunks
    }

    /// The visible rows of `section` after its leading choice (what a
    /// choice option's panel shows once the choice is applied).
    func rowsAfterChoice(section id: String, scope: InspectorScope) -> [Int] {
        var index = 0
        for (spec, view) in sections {
            defer { index += view.rows.count }
            guard spec.id == id else { continue }
            let base = index
            return view.rows.indices.dropFirst().filter { view.rows[$0].isRowVisible(scope) }.map { base + $0 }
        }
        return []
    }

    /// Every row, in order.
    var rows: [InspectorRowView] { sections.flatMap { $0.view.rows } }

    /// Any row showing (a panel whose switch rides its strip may have none).
    var hasVisibleRows: Bool { sections.contains { !$0.view.isHidden && $0.view.rows.contains { !$0.isHidden } } }

    /// A panel showing ONE option: only these rows (indices into `rows`);
    /// nil = the whole pane (the iPad column).
    private(set) var focus: Set<Int>?

    /// Shows only `rows` (nil = all), without the growth animation.
    func setFocus(_ rows: Set<Int>?, scope: InspectorScope) {
        focus = rows
        for (_, view) in sections { view.showsHeader = rows == nil }
        let had = hasRefreshed
        hasRefreshed = false
        refresh(scope)
        hasRefreshed = had
    }

    func refresh(_ scope: InspectorScope) {
        var revealed: [UIView] = []
        var grown: (UIView, CGFloat)?
        var index = 0
        for (spec, view) in sections {
            let specShows = spec.visible(scope)
            var anyRow = false
            for row in view.rows {
                defer { index += 1 }
                var show = specShows && row.isRowVisible(scope) && (focus?.contains(index) ?? true)
                #if DEBUG
                if row.rowID == Self.probeDropRowID { show = false }
                #endif
                if show { anyRow = true }
                if row.isHidden == show {
                    row.isHidden = !show
                    if show { revealed.append(row) }
                    if grown == nil { grown = (view, view.bounds.height) }
                }
                if show { row.refresh(scope) }
            }
            let showSection = specShows && (focus == nil || anyRow)
            if view.isHidden == showSection {
                view.isHidden = !showSection
                if showSection { revealed.append(view) }
                if grown == nil { grown = (view, 0) }
            }
            view.refreshSeparators()
        }
        defer { hasRefreshed = true }
        guard hasRefreshed, window != nil, grown != nil else {
            layoutIfNeeded()
            return
        }
        #if DEBUG
        if Self.probeSnapGrowth {
            layoutIfNeeded()
            return
        }
        #endif
        let root = ccLayoutRoot
        let before = grown!
        if CCMotion.reduceMotion {
            // Reduce Motion: the rows land under a cross-fade — no growth.
            CCMotion.crossFade(root) { root.layoutIfNeeded() }
            lastGrowth = (before.0, before.1, before.0.bounds.height)
            return
        }
        // Growth lands on the bounce; revealed rows fade in as they open.
        for view in revealed { view.alpha = 0 }
        CCMotion.run(duration: 0.38, curve: .bounce, {
            root.layoutIfNeeded()
        })
        for view in revealed {
            CCMotion.fadeAlpha(view, to: 1, duration: 0.24, delay: 0.06, from: 0)
        }
        lastGrowth = (before.0, before.1, before.0.bounds.height)
    }
}

/// A section: a small-caps header over FLAT rows (no card — the panel or
/// column is the only surface), a hairline between visible rows.
@MainActor
final class InspectorSectionView: UIView {
    let rows: [InspectorRowView]
    /// The section's title (the Mac box's header), nil for an untitled one.
    let title: String?
    private let stack = UIStackView()
    private var dividers: [UIView] = []
    private let header: UILabel?
    /// Hidden while a panel shows one option (its title is the strip's).
    /// A panel's few rows also drop the hairlines between them and sit on
    /// the Mac inspector's row rhythm instead (no separators, even air).
    var showsHeader = true {
        didSet {
            header?.isHidden = !showsHeader || !hasVisibleRow
            stack.spacing = showsHeader ? CCSpace.sm : Self.panelRowGap
        }
    }
    /// The air between a short panel's rows (the Mac's 16 pt rhythm, a
    /// touch tighter for the phone's short panel).
    static let panelRowGap: CGFloat = 14
    private var hasVisibleRow = true

    #if DEBUG
    /// Probe seam — INJECTED DEFECT (`card-in-card`): each section is boxed in
    /// a rounded card inside the panel again.
    static var probeBoxedSections = false
    #endif

    init(title: String?, rows: [InspectorRowView]) {
        self.rows = rows
        self.title = title
        if let title {
            let label = ccLabel(title.uppercased(), font: CCFont.scaled(10, .semibold, .caption2, max: 14),
                                color: CCTheme.color.faintForeground)
            label.adjustsFontForContentSizeCategory = true
            label.attributedText = NSAttributedString(string: title.uppercased(), attributes: [.kern: 0.6])
            label.accessibilityTraits = .header
            label.accessibilityLabel = title
            header = label
        } else {
            header = nil
        }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let column = UIStackView()
        column.axis = .vertical
        column.spacing = CCSpace.sm
        if let header { column.addArrangedSubview(header) }
        stack.axis = .vertical
        stack.spacing = CCSpace.sm
        stack.alignment = .fill
        for (i, row) in rows.enumerated() {
            stack.addArrangedSubview(row)
            if i < rows.count - 1 {
                let line = CCDivider()
                dividers.append(line)
                stack.addArrangedSubview(line)
            }
        }
        column.addArrangedSubview(stack)
        addSubview(column)
        pinEdges(column, to: self)
        #if DEBUG
        if Self.probeBoxedSections {
            let box = CCSurface(.raisedMatte, tint: CCTheme.color.elevated, radius: .lg)
            box.isUserInteractionEnabled = false
            box.accessibilityIdentifier = "probe.boxedSection"
            insertSubview(box, at: 0)
            pinEdges(box, to: self)
        }
        #endif
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Dividers only BETWEEN visible rows; the header hides with the last row.
    func refreshSeparators() {
        for (i, line) in dividers.enumerated() {
            let before = !rows[i].isHidden
            let after = rows[(i + 1)...].contains { !$0.isHidden }
            let show = before && after && showsHeader
            if line.isHidden == show { line.isHidden = !show }
        }
        hasVisibleRow = rows.contains { !$0.isHidden }
        header?.isHidden = !showsHeader || !hasVisibleRow
    }
}

/// One sub-option on the tool bar's pane level.
struct InspectorPanelOption: Equatable {
    struct Choice: Equatable { let row: Int; let index: Int }
    let id: String
    let title: String
    let symbol: String
    /// Rows its panel shows (indices into the pane's rows); empty for a
    /// choice, whose panel shows the section's rows once it is applied.
    let rows: [Int]
    let choice: Choice?
    let section: String?
    /// A choice that is the current value.
    let isCurrent: Bool

    /// Key names for chip rows titled by their section on the Mac (which
    /// shows them under the section's header, with no label of their own).
    static let choiceKeyNames: [String: String] = [
        "effects.slideStyle": "Direction", "effects.curtainCorner": "Corner", "blocks.tiltPreset": "Presets",
    ]

    @MainActor
    static func title(of row: InspectorRow, scope: InspectorScope) -> String? {
        switch row {
        case .slider(let s): return s.title
        case .toggle(let t): return t.title
        case .choice(let c): return c.title
        case .color(let c): return c.title
        case .colorPair(let title, _, _): return title
        case .text(let t): return t.title
        case .action(let a): return a.title(scope)
        case .actions(let a): return a.first.map { $0.title(scope) }
        case .feature(let f, _): return f.title
        case .caption, .custom: return nil
        }
    }

    @MainActor
    static func symbol(of row: InspectorRow, tab: InspectorTab) -> String {
        switch row {
        case .slider: return "sliders"
        case .toggle: return "circle-half"
        case .choice: return "grid"
        case .color, .colorPair: return "palette"
        case .text: return "text"
        case .action, .actions: return "wand"
        case .feature: return "sparkles"
        case .caption, .custom: return CCIcon.has(tab.icon) ? tab.icon : "sliders"
        }
    }

    /// A kit icon for a title (keywords), else `fallback`.
    static func symbol(for title: String, fallback: String) -> String {
        let t = title.lowercased()
        let table: [(String, String)] = [
            ("gradient", "circle-half"), ("mesh", "grid"), ("solid", "circle-fill"), ("wallpaper", "desktop"),
            ("transparent", "circle-dashed"), ("image", "photo"), ("look", "sliders"), ("frame", "rectangle"),
            ("menu bar", "window"), ("cursor", "cursor"), ("click", "tap"), ("sound", "speaker"), ("volume", "speaker"),
            ("audio", "speaker"), ("voice", "mic"), ("mic", "mic"), ("blur", "aperture"), ("pixel", "pixelate"),
            ("speed", "gauge"), ("motion", "cursor-motion"), ("zoom", "zoom-in"), ("tilt", "tilt"), ("size", "zoom-in"),
            ("color", "palette"), ("shadow", "circle-half"), ("corner", "rectangle"), ("style", "brush-fill"),
            ("text", "text"), ("subtitle", "captions"), ("preset", "grid"), ("position", "pin"), ("camera", "camera"),
            ("shape", "ellipse"), ("tag", "text-bubble"), ("highlight", "highlighter"), ("depth", "aperture"),
            ("curtain", "curtain"), ("slide", "arrow-right-line"), ("parallax", "showcase"), ("timing", "timer"),
            ("stroke", "scribble"), ("tap", "tap"), ("brand", "seal-check"), ("logo", "seal-check"),
            ("overlay", "picture-in-picture"), ("keyboard", "note"), ("shortcut", "note"), ("behavior", "eye"),
            ("hide", "eye-off"), ("show", "eye"), ("background", "palette"), ("adjust", "sliders"), ("effects", "sparkles"),
            ("pop", "person-popout"), ("cutout", "person-cutout"), ("padding", "shrink"), ("angle", "rotate-cw"),
        ]
        for (key, icon) in table where t.contains(key) { return icon }
        return CCIcon.has(fallback) ? fallback : "sliders"
    }
}
