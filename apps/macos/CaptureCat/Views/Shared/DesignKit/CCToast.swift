import AppKit

/// CCKit toasts — Sonner in AppKit. A `CCToaster` is an in-window overlay
/// host; toasts spring up from its bottom edge, older ones compress into a
/// stack BEHIND the front toast (smaller, peeking above it, fading back), and
/// hovering the stack fans it out into a list. Each toast auto-dismisses
/// behind a subtle countdown hairline (paused while the stack is hovered),
/// can carry one action button, and leaves with a short drop + fade while
/// the rest re-stack.
///
///     let toaster = CCToaster(in: window.contentView!)          // once per window
///     toaster.show(title: "Recording saved", message: "Launch demo.mov",
///                  variant: .success,
///                  action: .init(title: "Undo") { undoSave() })
///     toaster.show(title: "Export failed", variant: .destructive, duration: 8)
///
/// Variants: `.default` (no icon unless `symbol:`), `.success`, `.warning`,
/// `.destructive` — each with a leading SF Symbol in its tone.
@MainActor
final class CCToast: NSView {
    enum Variant {
        case `default`
        case success
        case warning
        case destructive

        var symbol: String? {
            switch self {
            case .default: return nil
            case .success: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .destructive: return "xmark.octagon.fill"
            }
        }

        @MainActor var tone: NSColor? {
            switch self {
            case .default: return nil
            case .success: return .systemGreen
            case .warning: return .systemOrange
            case .destructive: return CCTheme.color.destructive
            }
        }
    }

    struct Action {
        var title: String
        var handler: () -> Void
        init(title: String, handler: @escaping () -> Void) {
            self.title = title
            self.handler = handler
        }
    }

    let variant: Variant
    /// Seconds on screen; `.infinity` = until dismissed.
    let duration: TimeInterval
    var onDismiss: (() -> Void)?

    weak var toaster: CCToaster?

    /// The dressed surface — stack SCALE rides this layer; the container
    /// (self) carries the FLIP position springs (see CCMotion.glide).
    fileprivate let card = CCToastCard()
    private let icon = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let messageField = NSTextField(wrappingLabelWithString: "")
    private var actionButton: CCButton?
    private let closeButton: CCButton
    private let barHost = CCToastBarHost()
    private let bar = CALayer()
    private var dismissWork: DispatchWorkItem?
    /// Countdown remaining, 0…1 of `duration`.
    private var remaining: CGFloat = 1
    private var isPaused = true
    private var themeObservation: CCThemeObservation?

    static let padding: CGFloat = 14
    static let iconSide: CGFloat = 16
    static let minHeight: CGFloat = 52

    init(title: String, message: String? = nil, variant: Variant = .default,
         symbol: String? = nil, action: Action? = nil, duration: TimeInterval = 4) {
        self.variant = variant
        self.duration = duration
        closeButton = CCButton(symbol: "xmark", style: .ghost, size: .sm)
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = true

        card.wantsLayer = true
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 1
        card.frame = bounds
        card.autoresizingMask = [.width, .height]
        addSubview(card)

        barHost.wantsLayer = true
        barHost.layer?.masksToBounds = true
        barHost.layer?.cornerCurve = .continuous
        barHost.frame = card.bounds
        barHost.autoresizingMask = [.width, .height]
        bar.anchorPoint = CGPoint(x: 0, y: 0.5)
        barHost.layer?.addSublayer(bar)
        barHost.isHidden = !duration.isFinite
        card.addSubview(barHost)

        let symbolName = symbol ?? variant.symbol
        icon.image = symbolName.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        }
        icon.isHidden = icon.image == nil
        icon.imageScaling = .scaleProportionallyUpOrDown
        titleField.stringValue = title
        titleField.lineBreakMode = .byTruncatingTail
        messageField.stringValue = message ?? ""
        messageField.isHidden = message == nil
        messageField.isSelectable = false
        for view in [icon, titleField, messageField] { card.addSubview(view) }

        if let action {
            let button = CCButton(title: action.title, style: .primary, size: .sm) { [weak self] in
                action.handler()
                self?.dismiss()
            }
            card.addSubview(button)
            actionButton = button
        }
        closeButton.onClick = { [weak self] in self?.dismiss() }
        closeButton.alphaValue = 0
        card.addSubview(closeButton)
        card.closeButton = closeButton
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Geometry

    private var textX: CGFloat {
        icon.isHidden ? Self.padding : Self.padding + Self.iconSide + CCSpace.sm + 2
    }

    static let closeSide: CGFloat = 20

    private func trailingReserve(width: CGFloat) -> CGFloat {
        var reserve = CCSpace.sm + Self.closeSide + CCSpace.xs + 2
        if let actionButton { reserve += actionButton.intrinsicContentSize.width + CCSpace.sm }
        return reserve
    }

    private func textWidth(for width: CGFloat) -> CGFloat {
        max(40, width - textX - trailingReserve(width: width))
    }

    private func messageHeight(for width: CGFloat) -> CGFloat {
        guard !messageField.isHidden, let cell = messageField.cell else { return 0 }
        return ceil(cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth(for: width), height: 10_000)).height)
    }

    private var titleHeight: CGFloat { ceil(titleField.intrinsicContentSize.height) }

    /// Natural height at `width` (the toaster sizes toasts with it).
    func height(forWidth width: CGFloat) -> CGFloat {
        let message = messageHeight(for: width)
        let text = titleHeight + (message > 0 ? 2 + message : 0)
        return max(Self.minHeight, ceil(text + Self.padding * 2))
    }

    override func layout() {
        super.layout()
        let b = card.bounds
        let radius = CCTheme.radius(.lg)
        card.layer?.cornerRadius = radius
        if let layer = card.layer {
            CCMaterial.refit(layer, radius: radius)
            // Re-assert the float shadow every layout — AppKit reconfigures
            // backing layers on window attach and drops init-time shadows.
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = CCTheme.isDark ? 0.42 : 0.14
            layer.shadowRadius = 14
            layer.shadowOffset = CGSize(width: 0, height: -5)
        }
        barHost.layer?.cornerRadius = radius
        // Unflipped card: y-up, so the text block is laid out from the top.
        let message = messageHeight(for: b.width)
        let textBlock = titleHeight + (message > 0 ? 2 + message : 0)
        let top = b.height - (b.height - textBlock) / 2
        let width = textWidth(for: b.width)
        titleField.frame = NSRect(x: textX, y: top - titleHeight, width: width, height: titleHeight)
        messageField.frame = NSRect(x: textX, y: top - titleHeight - 2 - message, width: width, height: message)
        messageField.preferredMaxLayoutWidth = width
        // A fixed square slot (the text column already assumes it); the
        // symbol scales into it — an intrinsic-size frame read before the
        // image view settled rendered the glyph at half size.
        icon.frame = NSRect(x: Self.padding, y: titleField.frame.midY - Self.iconSide / 2,
                            width: Self.iconSide, height: Self.iconSide)
        let closeX = b.width - CCSpace.sm - Self.closeSide
        closeButton.frame = NSRect(x: closeX, y: (b.height - Self.closeSide) / 2,
                                   width: Self.closeSide, height: Self.closeSide)
        if let actionButton {
            let size = actionButton.intrinsicContentSize
            actionButton.frame = NSRect(x: closeX - CCSpace.xs - 2 - size.width, y: (b.height - size.height) / 2,
                                        width: size.width, height: size.height)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bar.bounds = CGRect(x: 0, y: 0, width: b.width, height: 2)
        bar.position = CGPoint(x: 0, y: 1)
        CATransaction.commit()
    }

    private func applyTheme() {
        let colors = CCTheme.color
        if let layer = card.layer {
            layer.backgroundColor = colors.popover.cgColor
            layer.borderColor = colors.border.cgColor
            CCMaterial.dress(layer, as: .raisedMatte(tint: colors.popover), radius: CCTheme.radius(.lg))
        }
        let tone = variant.tone ?? colors.foreground
        icon.contentTintColor = tone
        titleField.font = NSFont.systemFont(ofSize: CCTheme.font.chip.pointSize, weight: .semibold)
        titleField.textColor = colors.foreground
        messageField.font = CCTheme.font.label
        messageField.textColor = colors.mutedForeground
        bar.backgroundColor = (variant.tone?.withAlphaComponent(0.55)
            ?? colors.foreground.withAlphaComponent(0.22)).cgColor
    }

    // MARK: - Countdown

    /// Start (or resume) the auto-dismiss clock + the hairline.
    func resumeCountdown() {
        guard duration.isFinite, isPaused, remaining > 0 else { return }
        isPaused = false
        let seconds = Double(remaining) * duration
        let shrink = CABasicAnimation(keyPath: "transform.scale.x")
        shrink.fromValue = remaining
        shrink.toValue = 0
        shrink.duration = seconds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bar.setValue(0, forKeyPath: "transform.scale.x")
        CATransaction.commit()
        bar.add(shrink, forKey: "cctoast.countdown")
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Freeze the clock where it is (stack hovered).
    func pauseCountdown() {
        guard duration.isFinite, !isPaused else { return }
        isPaused = true
        dismissWork?.cancel()
        dismissWork = nil
        let shown = (bar.presentation() ?? bar).value(forKeyPath: "transform.scale.x") as? CGFloat ?? remaining
        remaining = max(0, min(1, shown))
        bar.removeAnimation(forKey: "cctoast.countdown")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bar.setValue(remaining, forKeyPath: "transform.scale.x")
        CATransaction.commit()
    }

    /// Collapsed stacks show only the FRONT toast's content; the ones
    /// behind are bare surfaces peeking out (no half-covered text).
    fileprivate func setContentVisible(_ visible: Bool, animated: Bool) {
        let views: [NSView] = [icon, titleField, messageField, barHost] + (actionButton.map { [$0] } ?? [])
        for view in views {
            if animated {
                CCMotion.fadeAlpha(view, to: visible ? 1 : 0, duration: visible ? 0.2 : 0.12)
            } else {
                view.alphaValue = visible ? 1 : 0
            }
        }
    }

    fileprivate func setCloseVisible(_ visible: Bool) {
        CCMotion.fadeAlpha(closeButton, to: visible ? 1 : 0, duration: 0.14)
    }

    func dismiss() {
        dismissWork?.cancel()
        dismissWork = nil
        toaster?.remove(self)
    }

    // MARK: - Harness seams

    var probeCardLayer: CALayer? { card.layer }
    var probeCountdownLayer: CALayer { bar }
    var probeRemaining: CGFloat {
        (bar.presentation() ?? bar).value(forKeyPath: "transform.scale.x") as? CGFloat ?? -1
    }
}

/// The toast's dressed surface. The close button only takes clicks while
/// it is shown (it fades, it never hides — a hidden view can't fade out).
private final class CCToastCard: NSView {
    weak var closeButton: NSView?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if let closeButton, let hit, hit === closeButton || hit.isDescendant(of: closeButton),
           closeButton.alphaValue < 0.5 {
            return self
        }
        return hit
    }
}

/// The countdown's clip — never takes clicks.
private final class CCToastBarHost: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Toaster

@MainActor
final class CCToaster {
    enum Position {
        case bottomTrailing
        case bottomCenter
    }

    let position: Position
    /// Toasts shown at once; older ones wait (invisible) behind the stack.
    var maxVisible = 3 {
        didSet { restack(animated: true) }
    }

    /// Stack geometry (Sonner's numbers, in points).
    static let width: CGFloat = 356
    static let inset: CGFloat = 16
    static let expandedGap: CGFloat = 10
    static let peek: CGFloat = 10
    static let scaleStep: CGFloat = 0.05

    /// Hover-driven fan-out. Harnesses turn it off so the user's real
    /// pointer position can never leak into a probe.
    var followsPointer = true

    private let overlay: CCToasterView
    /// Newest first — index 0 is the front toast.
    private(set) var toasts: [CCToast] = []
    private(set) var isExpanded = false

    init(in host: NSView, position: Position = .bottomTrailing) {
        self.position = position
        overlay = CCToasterView(frame: host.bounds)
        overlay.autoresizingMask = [.width, .height]
        host.addSubview(overlay, positioned: .above, relativeTo: nil)
        overlay.toaster = self
    }

    // MARK: Show / remove

    @discardableResult
    func show(title: String, message: String? = nil, variant: CCToast.Variant = .default,
              symbol: String? = nil, action: CCToast.Action? = nil,
              duration: TimeInterval = 4) -> CCToast {
        let toast = CCToast(title: title, message: message, variant: variant,
                            symbol: symbol, action: action, duration: duration)
        show(toast)
        return toast
    }

    func show(_ toast: CCToast) {
        toast.toaster = self
        // Keep the overlay the top-most subview (hosts add views later).
        if let host = overlay.superview, host.subviews.last !== overlay {
            host.addSubview(overlay, positioned: .above, relativeTo: nil)
        }
        overlay.addSubview(toast)   // newest on top
        toasts.insert(toast, at: 0)
        let targets = layoutTargets()
        guard let entry = targets.first else { return }
        // Arrive from just below the overlay's bottom edge.
        let offstage = NSRect(x: entry.frame.minX, y: -entry.frame.height - 8,
                              width: entry.frame.width, height: entry.frame.height)
        toast.frame = offstage
        toast.layoutSubtreeIfNeeded()
        applyScale(toast, entry.scale, animated: false)
        CCMotion.fadeAlpha(toast, to: 1, duration: 0.22, from: 0)
        restack(animated: true, entering: toast)
        if isExpanded { toast.pauseCountdown() } else { toast.resumeCountdown() }
        overlay.refreshHover()
    }

    fileprivate func remove(_ toast: CCToast) {
        guard let index = toasts.firstIndex(of: toast) else { return }
        toasts.remove(at: index)
        toast.pauseCountdown()
        // Leave: a short drop + fade, then gone.
        if let layer = toast.layer, toast.window != nil {
            CCMotion.spring(layer, keyPath: "transform.translation.y", to: -14.0, .snappy)
            CCMotion.fadeAlpha(toast, to: 0, duration: 0.18)
            DispatchQueue.main.asyncAfter(deadline: .now() + CCMotion.paced(0.24)) { toast.removeFromSuperview() }
        } else {
            toast.removeFromSuperview()
        }
        toast.onDismiss?()
        if toasts.isEmpty { setExpanded(false) }
        restack(animated: true)
        overlay.refreshHover()
    }

    func dismissAll() {
        for toast in toasts { toast.dismiss() }
    }

    // MARK: Stack

    /// Fan out (hover) or compress. Pauses/resumes every countdown. Also
    /// the harness seam — the overlay's hover routing feeds it.
    func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        for toast in toasts {
            expanded ? toast.pauseCountdown() : toast.resumeCountdown()
            toast.setCloseVisible(expanded)
        }
        restack(animated: true)
    }

    struct Target {
        var frame: NSRect
        var scale: CGFloat
        var opacity: CGFloat
    }

    private func layoutTargets() -> [Target] {
        let bounds = overlay.bounds
        let width = max(160, min(Self.width, bounds.width - Self.inset * 2))
        let x = position == .bottomTrailing ? bounds.width - Self.inset - width : (bounds.width - width) / 2
        var targets: [Target] = []
        let heights = toasts.map { $0.height(forWidth: width) }
        let frontHeight = heights.first ?? 0
        var y = Self.inset
        for (index, height) in heights.enumerated() {
            let visible = index < maxVisible
            if isExpanded {
                targets.append(Target(frame: NSRect(x: x, y: y, width: width, height: height),
                                      scale: 1, opacity: visible ? 1 : 0))
                y += height + Self.expandedGap
            } else {
                // Collapsed: each older toast shrinks and peeks `peek` pt
                // above the one in front (center-pivot scale).
                let scale = 1 - Self.scaleStep * CGFloat(min(index, maxVisible))
                let visualTop = Self.inset + frontHeight + Self.peek * CGFloat(min(index, maxVisible - 1))
                let minY = max(Self.inset, visualTop - height * (1 + scale) / 2)
                let opacity: CGFloat = visible ? 1 - 0.14 * CGFloat(index) : 0
                targets.append(Target(frame: NSRect(x: x, y: minY, width: width, height: height),
                                      scale: scale, opacity: opacity))
            }
        }
        return targets
    }

    fileprivate func restack(animated: Bool, entering: CCToast? = nil) {
        let targets = layoutTargets()
        for (index, (toast, target)) in zip(toasts, targets).enumerated() {
            toast.setContentVisible(index == 0 || isExpanded, animated: animated && toast !== entering)
            if animated {
                CCMotion.glide(toast, to: target.frame, toast === entering ? .bouncy : .smooth)
                toast.layoutSubtreeIfNeeded()
                applyScale(toast, target.scale, animated: toast !== entering)
                if toast !== entering, abs(toast.alphaValue - target.opacity) > 0.01 {
                    CCMotion.fadeAlpha(toast, to: target.opacity, duration: 0.2)
                }
            } else {
                toast.frame = target.frame
                applyScale(toast, target.scale, animated: false)
                toast.alphaValue = target.opacity
            }
        }
    }

    private func applyScale(_ toast: CCToast, _ scale: CGFloat, animated: Bool) {
        guard let layer = toast.card.layer else { return }
        let center = CGPoint(x: layer.bounds.midX, y: layer.bounds.midY)
        let transform = NSValue(caTransform3D: CCMotion.scaleTransform(scale, pivot: center, in: layer))
        if animated, toast.window != nil {
            CCMotion.spring(layer, keyPath: "transform", to: transform, .smooth)
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.setValue(transform, forKeyPath: "transform")
            CATransaction.commit()
        }
    }

    /// Region the pointer must be inside for the stack to fan out.
    fileprivate var hoverRegion: NSRect {
        toasts.prefix(maxVisible).reduce(NSRect.null) { $0.union($1.frame) }
            .insetBy(dx: -4, dy: -6)
    }

    fileprivate func overlayDidResize() {
        restack(animated: false)
    }

    // MARK: - Harness seams

    var probeOverlay: NSView { overlay }
    var probeTargets: [Target] { layoutTargets() }
}

/// Transparent overlay: passes every click through except on toasts, and
/// routes hover over the stack (in-window, so a tracking area is reliable).
private final class CCToasterView: NSView {
    weak var toaster: CCToaster?
    private var trackingArea: NSTrackingArea?
    private var lastSize: NSSize = .zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard subviews.contains(where: { $0.alphaValue > 0.05 && $0.frame.contains(local) }) else { return nil }
        return super.hitTest(point)
    }

    override func layout() {
        super.layout()
        // Re-stack (instantly) only when the host actually resized — a
        // resize is not a motion moment, and in-flight springs keep riding.
        if bounds.size != lastSize {
            lastSize = bounds.size
            toaster?.overlayDidResize()
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

    override func mouseMoved(with event: NSEvent) { route(convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { route(convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { toaster?.setExpanded(false) }

    func refreshHover() {
        guard let window else { return }
        route(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    private func route(_ point: NSPoint) {
        guard let toaster, toaster.followsPointer, !toaster.toasts.isEmpty else { return }
        toaster.setExpanded(toaster.hoverRegion.contains(point))
    }
}
