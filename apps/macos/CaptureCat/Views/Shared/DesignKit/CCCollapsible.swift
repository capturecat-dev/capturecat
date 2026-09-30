import AppKit

/// CCKit collapsible — shadcn's Collapsible content: a clipping container
/// that reveals (or covers) its content by moving ONE edge — the bottom.
/// The content is pinned to the container's top at its natural height, so it
/// never shifts, squashes or fades while the edge travels; growth lands on the
/// house bounce (`CCMotion.animate`, curve-true and re-laid-out every tick so
/// any dressed surface around it refits in lockstep).
///
///     let more = CCCollapsible(content: detailsStack)
///     disclosure.onClick = { more.toggle() }
///     more.onToggle = { expanded in ... }
///
/// The trigger is up to the caller (any control) — `CCAccordion` pairs it
/// with a chevron header row.
@MainActor
final class CCCollapsible: NSView {
    let content: NSView
    var onToggle: ((Bool) -> Void)?

    private(set) var isExpanded: Bool
    private var heightConstraint: NSLayoutConstraint!

    init(content: NSView, expanded: Bool = false) {
        self.content = content
        self.isExpanded = expanded
        super.init(frame: .zero)
        wantsLayer = true
        // Clips the not-yet-revealed part of the content; the moving bottom
        // edge IS the reveal.
        layer?.masksToBounds = true

        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightConstraint,
        ])
        // Expanded-at-init resolves its height on the first layout pass.
        needsLayout = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The content's natural height at the current width. The content is
    /// pinned top/leading/trailing only, so its laid-out frame IS its
    /// natural height whether or not the container currently reveals it.
    private var contentHeight: CGFloat { content.frame.height }

    override func layout() {
        super.layout()
        // Track content changes (wrapping at a new width, rows added) while
        // settled; never clobber an in-flight reveal.
        guard !CCMotion.isAnimating(heightConstraint) else { return }
        let target = isExpanded ? contentHeight : 0
        if abs(heightConstraint.constant - target) > 0.5 {
            heightConstraint.constant = target
        }
    }

    func toggle() { setExpanded(!isExpanded) }

    /// Reveal/cover. Growth lands on the bounce, the collapse glides shut;
    /// either way only the bottom edge travels.
    func setExpanded(_ expanded: Bool, animated: Bool = true) {
        guard expanded != isExpanded else { return }
        // Settle pending layout BEFORE flipping state — layout() would
        // otherwise snap the height straight to the new target.
        layoutSubtreeIfNeeded()
        isExpanded = expanded
        let target = expanded ? contentHeight : 0
        let root = window?.contentView
        if animated, root != nil {
            CCMotion.animate(
                heightConstraint, to: target, in: root,
                duration: expanded ? 0.4 : 0.26,
                curve: expanded ? CCMotion.bouncePoints : CCMotion.glidePoints
            )
        } else {
            heightConstraint.constant = target
            needsLayout = true
        }
        onToggle?(expanded)
    }

    // MARK: - Harness seams

    var probeHeightConstraint: NSLayoutConstraint { heightConstraint }
    var probeTargetHeight: CGFloat { isExpanded ? contentHeight : 0 }
    var probeIsAnimating: Bool { CCMotion.isAnimating(heightConstraint) }
}
