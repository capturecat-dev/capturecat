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

    /// Every row, in order.
    var rows: [InspectorRowView] { sections.flatMap { $0.view.rows } }

    func refresh(_ scope: InspectorScope) {
        var revealed: [UIView] = []
        var grown: (UIView, CGFloat)?
        for (spec, view) in sections {
            let showSection = spec.visible(scope)
            for row in view.rows {
                let show = showSection && row.isRowVisible(scope)
                if row.isHidden == show {
                    row.isHidden = !show
                    if show { revealed.append(row) }
                    if grown == nil { grown = (view, view.bounds.height) }
                }
                if show { row.refresh(scope) }
            }
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

/// A section card: optional title above a raised-matte surface holding rows.
@MainActor
final class InspectorSectionView: UIView {
    let rows: [InspectorRowView]
    private let card = CCSurface(.raisedMatte, tint: CCTheme.color.card, radius: .lg)
    private let stack = UIStackView()

    init(title: String?, rows: [InspectorRowView]) {
        self.rows = rows
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let column = UIStackView()
        column.axis = .vertical
        column.spacing = CCSpace.sm
        if let title {
            let label = ccLabel(title.uppercased(), font: CCFont.micro, color: CCTheme.color.mutedForeground)
            label.adjustsFontForContentSizeCategory = true
            label.accessibilityTraits = .header
            label.accessibilityLabel = title
            column.addArrangedSubview(label)
        }
        stack.axis = .vertical
        stack.spacing = CCSpace.md
        stack.alignment = .fill
        rows.forEach { stack.addArrangedSubview($0) }
        card.addSubview(stack)
        pinEdges(stack, to: card, inset: CCSpace.md)
        column.addArrangedSubview(card)
        addSubview(column)
        pinEdges(column, to: self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The card hides with its last visible row.
    func refreshSeparators() {
        card.isHidden = !rows.contains { !$0.isHidden }
    }
}
