import AppKit

/// CCKit tabs — shadcn's Tabs: a `CCSegmented` tab list (its raised
/// selection chip springs between tabs) over a stack of content panes. A
/// switch crossfades the panes with a small DIRECTIONAL slide — the incoming
/// pane arrives from the side you traveled toward, the outgoing one leaves
/// the other way — while the pane area's bottom edge glides to the new
/// pane's height (growth lands on the bounce).
///
///     let tabs = CCTabs([("Account", accountCard), ("Password", passwordCard)])
///     tabs.onChange = { index in ... }
///     tabs.selectedIndex = 1          // animated, same as a click
///
/// `listFillsWidth: true` stretches the list across the component (shadcn's
/// `grid w-full` list); by default it hugs its tabs.
@MainActor
final class CCTabs: NSView {
    var onChange: ((Int) -> Void)?

    var selectedIndex: Int {
        get { current }
        set { select(newValue, notify: false) }
    }

    /// Horizontal travel of the pane crossfade, in points.
    static let slideDistance: CGFloat = 14

    private let list: CCSegmented
    private let paneHost = CCTabsPaneHost()
    private var panes: [NSView] = []
    private var current: Int
    private var hostHeight: NSLayoutConstraint!
    private var hideWork: DispatchWorkItem?

    init(
        _ tabs: [(title: String, pane: NSView)],
        selectedIndex: Int = 0,
        listFillsWidth: Bool = false,
        size: CCSegmented.Size = .regular
    ) {
        current = max(0, min(selectedIndex, tabs.count - 1))
        list = CCSegmented(segments: tabs.map(\.title), selectedIndex: current, size: size)
        super.init(frame: .zero)
        wantsLayer = true

        paneHost.wantsLayer = true
        for view in [list, paneHost] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        hostHeight = paneHost.heightAnchor.constraint(equalToConstant: 0)
        var constraints: [NSLayoutConstraint] = [
            list.topAnchor.constraint(equalTo: topAnchor),
            list.leadingAnchor.constraint(equalTo: leadingAnchor),
            paneHost.topAnchor.constraint(equalTo: list.bottomAnchor, constant: CCSpace.sm),
            paneHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            paneHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            paneHost.bottomAnchor.constraint(equalTo: bottomAnchor),
            hostHeight,
        ]
        if listFillsWidth {
            constraints.append(list.trailingAnchor.constraint(equalTo: trailingAnchor))
        } else {
            constraints.append(list.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor))
        }
        NSLayoutConstraint.activate(constraints)

        for (index, tab) in tabs.enumerated() {
            let pane = tab.pane
            pane.translatesAutoresizingMaskIntoConstraints = false
            pane.wantsLayer = true
            paneHost.addSubview(pane)
            NSLayoutConstraint.activate([
                pane.topAnchor.constraint(equalTo: paneHost.topAnchor),
                pane.leadingAnchor.constraint(equalTo: paneHost.leadingAnchor),
                pane.trailingAnchor.constraint(equalTo: paneHost.trailingAnchor),
            ])
            pane.isHidden = index != current
            panes.append(pane)
        }
        list.onChange = { [weak self] index in self?.select(index, notify: true) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        // Settled: the pane area hugs the visible pane (tracks width-driven
        // reflow); an in-flight switch owns the height.
        guard panes.indices.contains(current), !CCMotion.isAnimating(hostHeight) else { return }
        let target = panes[current].frame.height
        if abs(hostHeight.constant - target) > 0.5 { hostHeight.constant = target }
    }

    private func select(_ index: Int, notify: Bool) {
        guard panes.indices.contains(index), index != current else { return }
        let previous = current
        current = index
        if list.selectedIndex != index { list.selectedIndex = index }

        let outgoing = panes[previous]
        let incoming = panes[index]
        let direction: CGFloat = index > previous ? 1 : -1
        hideWork?.cancel()
        // Anything still mid-exit from a rapid double switch hides now.
        for (i, pane) in panes.enumerated() where i != index && i != previous {
            pane.isHidden = true
            resetTransform(pane)
        }
        incoming.isHidden = false
        layoutSubtreeIfNeeded()

        if window != nil, let inLayer = incoming.layer, let outLayer = outgoing.layer {
            let slide = Self.slideDistance
            CCMotion.spring(outLayer, keyPath: "transform.translation.x", from: 0, to: -direction * slide, .smooth)
            CCMotion.fadeAlpha(outgoing, to: 0, duration: 0.16)
            CCMotion.spring(inLayer, keyPath: "transform.translation.x", from: direction * slide, to: 0, .smooth)
            CCMotion.fadeAlpha(incoming, to: 1, duration: 0.24, from: 0)
            let work = DispatchWorkItem { [weak self, weak outgoing] in
                guard let self, let outgoing, self.panes.firstIndex(of: outgoing) != self.current else { return }
                outgoing.isHidden = true
                self.resetTransform(outgoing)
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + CCMotion.paced(0.3), execute: work)

            // The pane area's bottom edge follows the new pane: growth
            // bounces, shrink glides — the top never moves.
            let target = incoming.frame.height
            let growing = target > hostHeight.constant
            CCMotion.animate(hostHeight, to: target, in: window?.contentView,
                             duration: growing ? 0.4 : 0.28,
                             curve: growing ? CCMotion.bouncePoints : CCMotion.glidePoints)
        } else {
            outgoing.isHidden = true
            outgoing.alphaValue = 1
            incoming.alphaValue = 1
            needsLayout = true
        }
        if notify { onChange?(index) }
    }

    private func resetTransform(_ pane: NSView) {
        pane.alphaValue = 1
        guard let layer = pane.layer else { return }
        layer.removeAnimation(forKey: "capmotion.transform.translation.x")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(0, forKeyPath: "transform.translation.x")
        CATransaction.commit()
    }

    // MARK: - Harness seams

    var probeList: CCSegmented { list }
    func probePane(_ index: Int) -> NSView { panes[index] }
    var probeHostHeight: NSLayoutConstraint { hostHeight }
}

/// Panes pin to its TOP via constraints, so the bottom edge is the one that
/// moves. Deliberately unflipped: panes are usually dressed cards, and
/// CCMaterial orients by the RELATIVE geometryFlipped (right only under an
/// unflipped parent).
private final class CCTabsPaneHost: NSView {}
