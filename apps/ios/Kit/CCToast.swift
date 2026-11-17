import UIKit

/// CCKit toasts — Sonner in UIKit. A `CCToaster` owns a touch-transparent
/// overlay on a host view; toasts spring up from its bottom edge, older ones
/// compress into a stack BEHIND the front toast (smaller, peeking above it),
/// each auto-dismisses behind a countdown hairline, may carry one action, and
/// leaves with a short drop + fade (or a swipe down).
///
///     let toaster = CCToaster(host: view)
///     toaster.bottomInset = 96                 // clear a floating tab bar
///     toaster.show(title: "Link copied", variant: .success)
final class CCToaster {
    private let overlay = CCToastOverlay()
    private var toasts: [CCToast] = []
    var maxVisible = 3
    var bottomInset: CGFloat = CCSpace.lg { didSet { restack(animated: true) } }

    init(host: UIView) {
        overlay.frame = host.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(overlay)
        overlay.onLayout = { [weak self] in self?.restack(animated: false) }
    }

    /// Keep the overlay above views added later.
    func bringToFront() { overlay.superview?.bringSubviewToFront(overlay) }

    @discardableResult
    func show(title: String, message: String? = nil, variant: CCToast.Variant = .default, symbol: String? = nil,
              action: CCToast.Action? = nil, duration: TimeInterval = 3.5) -> CCToast {
        bringToFront()
        let toast = CCToast(title: title, message: message, variant: variant, symbol: symbol, action: action, duration: duration)
        toast.onDismiss = { [weak self, weak toast] in
            guard let self, let toast else { return }
            self.remove(toast)
        }
        overlay.addSubview(toast)
        toasts.append(toast)
        restack(animated: false, entering: toast)
        CCMotion.fadeAlpha(toast, to: 1, duration: 0.2, from: 0)
        CCMotion.enter(toast.layer, .slideUp(distance: 28))
        restack(animated: true)
        toast.startCountdown()
        CCAccessibility.announce([title, message].compactMap { $0 }.joined(separator: ". "))
        while toasts.count > maxVisible + 1 { toasts.first?.dismiss() ; break }
        return toast
    }

    func dismissAll() { toasts.forEach { $0.dismiss() } }

    private func remove(_ toast: CCToast) {
        toasts.removeAll { $0 === toast }
        restack(animated: true)
    }

    private func frame(for toast: CCToast) -> CGRect {
        let bounds = overlay.bounds
        let safe = overlay.safeAreaInsets
        let width = min(bounds.width - CCSpace.lg * 2 - safe.left - safe.right, 440)
        let height = toast.height(forWidth: width)
        let x = (bounds.width - width) / 2
        let y = bounds.height - max(bottomInset, safe.bottom + CCSpace.sm) - height
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func restack(animated: Bool, entering: CCToast? = nil) {
        guard overlay.bounds.width > 0 else { return }
        let ordered = Array(toasts.reversed())   // front first
        guard let front = ordered.first else { return }
        let frontFrame = frame(for: front)
        for (depth, toast) in ordered.enumerated() {
            var target = frame(for: toast)
            target.origin.y = frontFrame.maxY - target.height
            let scale = 1 - 0.05 * CGFloat(depth)
            let lift = -10 * CGFloat(depth)
            let alpha: CGFloat = depth >= maxVisible ? 0 : 1 - 0.18 * CGFloat(depth)
            toast.layer.zPosition = CGFloat(-depth)
            toast.isUserInteractionEnabled = depth == 0
            if toast === entering || !animated {
                toast.bounds.size = target.size
                toast.center = CGPoint(x: target.midX, y: target.midY)
                toast.stackTransform = CGAffineTransform(translationX: 0, y: lift).scaledBy(x: scale, y: scale)
                if toast !== entering { toast.alpha = alpha }
            } else {
                CCMotion.springViews(.smooth, crossFading: toast) {
                    toast.bounds.size = target.size
                    toast.center = CGPoint(x: target.midX, y: target.midY)
                    toast.stackTransform = CGAffineTransform(translationX: 0, y: lift).scaledBy(x: scale, y: scale)
                    toast.alpha = alpha
                }
            }
        }
    }
}

private final class CCToastOverlay: UIView {
    var onLayout: (() -> Void)?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

final class CCToast: UIView {
    enum Variant {
        case `default`
        case success
        case warning
        case destructive

        var symbol: String? {
            switch self {
            case .default: return nil
            case .success: return "check-circle-fill"
            case .warning: return "warning-fill"
            case .destructive: return "error-fill"
            }
        }

        var tone: UIColor {
            switch self {
            case .default: return CCTheme.color.foreground
            case .success: return CCTheme.color.success
            case .warning: return CCTheme.color.warning
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

    var onDismiss: (() -> Void)?
    let duration: TimeInterval
    /// Stack compression rides the CARD (the container keeps FLIP springs).
    var stackTransform: CGAffineTransform = .identity {
        didSet { card.transform = stackTransform }
    }

    private let card = CCCard(floating: true, tint: CCTheme.color.popover, radius: .lg)
    private let icon: CCIconView?
    private let titleLabel: UILabel
    private let messageLabel: UILabel
    private var actionButton: CCButton?
    private let barTrack = UIView()
    private let bar = CALayer()
    private var dismissWork: DispatchWorkItem?
    private var isLeaving = false

    init(title: String, message: String?, variant: Variant, symbol: String?, action: Action?, duration: TimeInterval) {
        self.duration = duration
        icon = (symbol ?? variant.symbol).map { CCIconView($0, pointSize: 15, weight: .semibold, tint: variant.tone) }
        titleLabel = ccLabel(title, font: CCFont.labelSemibold, color: CCTheme.color.foreground, lines: 2)
        messageLabel = ccLabel(message ?? "", font: CCFont.caption, color: CCTheme.color.mutedForeground, lines: 3)
        super.init(frame: .zero)
        ccFloatsOverContent = true
        alpha = 0
        card.translatesAutoresizingMaskIntoConstraints = true
        card.frame = bounds
        card.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(card)
        messageLabel.isHidden = message == nil

        let text = UIStackView(arrangedSubviews: [titleLabel, messageLabel])
        text.axis = .vertical
        text.spacing = 2
        let row = UIStackView(arrangedSubviews: [icon, text].compactMap { $0 })
        row.spacing = CCSpace.sm + 2
        row.alignment = .center
        if let action {
            let button = CCButton(title: action.title, style: .primary, size: .sm)
            button.onTap = { [weak self] in
                action.handler()
                self?.dismiss()
            }
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            row.addArrangedSubview(button)
            actionButton = button
        }
        row.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            row.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])
        barTrack.isUserInteractionEnabled = false
        barTrack.clipsToBounds = true
        barTrack.layer.cornerCurve = .continuous
        barTrack.isHidden = !duration.isFinite
        card.addSubview(barTrack)
        bar.anchorPoint = CGPoint(x: 0, y: 0.5)
        barTrack.layer.addSublayer(bar)

        isAccessibilityElement = action == nil
        accessibilityLabel = [title, message].compactMap { $0 }.joined(separator: ". ")
        let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
        addGestureRecognizer(pan)
        ccOnThemeChange { [weak self] in self?.applyTheme() }
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func applyTheme() {
        bar.backgroundColor = CCTheme.color.foreground.resolvedColor(with: traitCollection).withAlphaComponent(0.18).cgColor
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        let reserved: CGFloat = 28 + (icon != nil ? CCIcon.side(for: 15) + 10 : 0) + (actionButton.map { $0.intrinsicContentSize.width + 10 } ?? 0)
        let textWidth = max(60, width - reserved)
        let titleH = titleLabel.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
        let messageH = messageLabel.isHidden ? 0 : messageLabel.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height + 2
        return max(56, ceil(titleH + messageH + 28))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        barTrack.frame = CGRect(x: 14, y: card.bounds.height - 4, width: card.bounds.width - 28, height: 1.5)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bar.bounds.size.height = 1.5
        bar.position = CGPoint(x: 0, y: 0.75)
        if bar.animation(forKey: "countdown") == nil, bar.bounds.width == 0, !didStart { bar.bounds.size.width = barTrack.bounds.width }
        CATransaction.commit()
    }

    private var didStart = false

    func startCountdown() {
        guard duration.isFinite else { return }
        didStart = true
        layoutIfNeeded()
        let width = barTrack.bounds.width
        let shrink = CABasicAnimation(keyPath: "bounds.size.width")
        shrink.fromValue = width
        shrink.toValue = 0
        shrink.duration = duration
        bar.bounds.size.width = 0
        bar.add(shrink, forKey: "countdown")
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func dismiss() {
        guard !isLeaving else { return }
        isLeaving = true
        dismissWork?.cancel()
        CCMotion.run(duration: 0.22, curve: .glide, {
            self.transform = CGAffineTransform(translationX: 0, y: 18)
            self.alpha = 0
        }, completion: { [weak self] in
            self?.removeFromSuperview()
        })
        onDismiss?()
    }

    @objc private func pan(_ gesture: UIPanGestureRecognizer) {
        let dy = gesture.translation(in: self).y
        switch gesture.state {
        case .changed:
            transform = CGAffineTransform(translationX: 0, y: max(dy, dy / 4))
        case .ended, .cancelled:
            if dy > 40 || gesture.velocity(in: self).y > 500 {
                dismiss()
            } else {
                CCMotion.springViews(.snappy, crossFading: self) { self.transform = .identity }
            }
        default:
            break
        }
    }
}
