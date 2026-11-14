import Observation
import UIKit

// CCKit small primitives — Badge, Divider, Card, Callout, Avatar and the
// observation loop. Each is short; they live together so the kit stays
// browsable.

/// shadcn Badge: a small floating pill for statuses ("iPhone", "Shared").
final class CCBadge: UIView {
    enum Variant {
        case subtle
        case primary
        case destructive
        case outline
        case success
        case warning
    }

    var text: String {
        get { label.text ?? "" }
        set {
            guard newValue != label.text else { return }
            label.text = newValue
            accessibilityLabel = newValue
            invalidateIntrinsicContentSize()
            CCMotion.pop(self, from: 0.88)
        }
    }

    var variant: Variant { didSet { applyTheme() } }

    /// Swap the leading glyph (badges created with a symbol).
    func setSymbol(_ name: String) {
        guard let icon, icon.iconName != name else { return }
        icon.iconName = name
    }

    private let label = UILabel()
    private let icon: CCIconView?

    init(_ text: String, symbol: String? = nil, variant: Variant = .subtle) {
        self.variant = variant
        icon = symbol.map { CCIconView($0, pointSize: 10, weight: .semibold) }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerCurve = .continuous
        label.text = text
        label.font = CCFont.scaled(12, .medium, .caption1, max: 16)
        label.adjustsFontForContentSizeCategory = true
        label.translatesAutoresizingMaskIntoConstraints = false
        let stack = UIStackView(arrangedSubviews: [icon, label].compactMap { $0 })
        stack.spacing = 3
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.isUserInteractionEnabled = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 20),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        isAccessibilityElement = true
        accessibilityLabel = text
        ccOnThemeChange { [weak self] in self?.applyTheme() }
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let r = CCRadius.full.resolved(for: bounds.height)
        layer.cornerRadius = r
        CCMaterial.refit(layer, radius: r)
    }

    private func applyTheme() {
        let colors = CCTheme.color
        let r = CCRadius.full.resolved(for: max(bounds.height, 20))
        let fill: UIColor?
        let ink: UIColor
        switch variant {
        case .subtle: fill = colors.active; ink = colors.foreground
        case .primary: fill = colors.primary; ink = colors.primaryForeground
        case .destructive: fill = colors.destructive; ink = .white
        case .success: fill = colors.success.withAlphaComponent(0.16); ink = CCTheme.dyn(light: UIColor(red: 0.12, green: 0.5, blue: 0.22, alpha: 1), dark: UIColor(red: 0.45, green: 0.88, blue: 0.55, alpha: 1))
        case .warning: fill = colors.warning.withAlphaComponent(0.16); ink = CCTheme.dyn(light: UIColor(red: 0.62, green: 0.34, blue: 0.0, alpha: 1), dark: UIColor(red: 1.0, green: 0.72, blue: 0.36, alpha: 1))
        case .outline: fill = nil; ink = colors.mutedForeground
        }
        label.textColor = ink
        icon?.tintColor = ink
        if let fill {
            layer.borderWidth = 0
            CCMaterial.dress(layer, as: .raisedMatte(tint: fill), radius: r, traits: traitCollection)
        } else {
            CCMaterial.strip(layer)
            layer.borderWidth = 1
            layer.borderColor = cc(colors.border)
        }
    }
}

/// shadcn Separator: a hairline in the border token. The thin axis is
/// PINNED by a constraint (like the Mac's) — an intrinsic size alone lets
/// Auto Layout stretch a divider to fill slack.
final class CCDivider: UIView {
    private let vertical: Bool
    private var thickness: NSLayoutConstraint!

    init(vertical: Bool = false) {
        self.vertical = vertical
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = CCTheme.color.border
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        thickness = vertical ? widthAnchor.constraint(equalToConstant: 0.5) : heightAnchor.constraint(equalToConstant: 0.5)
        thickness.isActive = true
        registerForTraitChanges([UITraitDisplayScale.self]) { (self: CCDivider, _: UITraitCollection) in
            self.thickness.constant = self.ccHairline
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        thickness.constant = ccHairline
    }
}

/// shadcn Card: the house surface container — card fill, hairline, `.lg`
/// radius. `floating: true` adds the cast shadow (a card on the page);
/// otherwise it is matte (a card inside a surface that has depth already).
class CCCard: UIView {
    var floating: Bool { didSet { applyTheme() } }
    var tint: UIColor { didSet { applyTheme() } }
    var radius: CCRadius { didSet { setNeedsLayout(); applyTheme() } }

    init(floating: Bool = false, tint: UIColor = CCTheme.color.card, radius: CCRadius = .lg) {
        self.floating = floating
        self.tint = tint
        self.radius = radius
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerCurve = .continuous
        ccOnThemeChange { [weak self] in self?.applyTheme() }
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let r = radius.resolved(for: bounds.height)
        layer.cornerRadius = r
        CCMaterial.refit(layer, radius: r)
    }

    func applyTheme() {
        let style: CCMaterial.Style = floating ? .raised(tint: tint) : .raisedMatte(tint: tint)
        CCMaterial.dress(layer, as: style, radius: radius.resolved(for: bounds.height), traits: traitCollection)
        // The Mac card's 1 pt edge in the border token (matte cards only —
        // floating surfaces read by their shadow).
        layer.borderWidth = floating ? 0 : 1
        layer.borderColor = cc(CCTheme.color.border)
    }
}

/// Inline alert (shadcn Alert): a quiet tinted well with a leading kit icon,
/// title and message. Slides its height open on the growth bounce.
final class CCCallout: UIView {
    enum Variant {
        case info
        case success
        case warning
        case destructive

        var symbol: String {
            switch self {
            case .info: return "info-fill"
            case .success: return "check-circle-fill"
            case .warning: return "warning-fill"
            case .destructive: return "error-fill"
            }
        }

        var tone: UIColor {
            switch self {
            case .info: return CCTheme.color.primary
            case .success: return CCTheme.color.success
            case .warning: return CCTheme.color.warning
            case .destructive: return CCTheme.color.destructive
            }
        }
    }

    var variant: Variant { didSet { applyTheme() } }
    private let icon: CCIconView
    private let titleLabel: UILabel
    private let messageLabel: UILabel
    var onDismiss: (() -> Void)?
    private var dismissButton: CCButton?

    init(title: String? = nil, message: String, variant: Variant = .info, dismissible: Bool = false) {
        self.variant = variant
        icon = CCIconView(variant.symbol, pointSize: 15, weight: .semibold, tint: variant.tone)
        titleLabel = ccLabel(title ?? "", font: CCFont.labelSemibold, color: CCTheme.color.foreground, lines: 0)
        messageLabel = ccLabel(message, font: CCFont.caption, color: CCTheme.color.mutedForeground, lines: 0)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerCurve = .continuous
        titleLabel.isHidden = title == nil
        let text = UIStackView(arrangedSubviews: [titleLabel, messageLabel])
        text.axis = .vertical
        text.spacing = 2
        let row = UIStackView(arrangedSubviews: [icon, text])
        row.spacing = CCSpace.sm + 2
        row.alignment = .top
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        if dismissible {
            let close = CCButton(symbol: "close", style: .ghost, size: .sm)
            close.accessibilityLabelOverride = "Dismiss"
            close.onTap = { [weak self] in self?.onDismiss?() }
            row.addArrangedSubview(close)
            dismissButton = close
        }
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CCSpace.md),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CCSpace.md),
            row.topAnchor.constraint(equalTo: topAnchor, constant: CCSpace.md),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -CCSpace.md),
        ])
        isAccessibilityElement = !dismissible
        accessibilityLabel = [title, message].compactMap { $0 }.joined(separator: ". ")
        ccOnThemeChange { [weak self] in self?.applyTheme() }
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var message: String {
        get { messageLabel.text ?? "" }
        set { messageLabel.text = newValue; accessibilityLabel = [titleLabel.text, newValue].compactMap { $0 }.joined(separator: ". ") }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = CCTheme.radius(.lg)
        CCMaterial.refit(layer, radius: CCTheme.radius(.lg))
    }

    private func applyTheme() {
        icon.iconName = variant.symbol
        icon.tintColor = variant.tone
        let wash = CCTheme.color.card.ccBlended(CCTheme.isDark(traitCollection) ? 0.14 : 0.08, of: variant.tone, traits: traitCollection)
        CCMaterial.dress(layer, as: .recessed(tint: wash), radius: CCTheme.radius(.lg), traits: traitCollection)
    }
}

/// Avatar: the user's photo, or deterministic-hue initials.
final class CCAvatar: UIView {
    private let initials = UILabel()
    private let imageView = UIImageView()
    let side: CGFloat

    var name: String { didSet { refresh() } }
    var image: UIImage? { didSet { refresh() } }

    init(name: String, image: UIImage? = nil, side: CGFloat = 40) {
        self.name = name
        self.image = image
        self.side = side
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        clipsToBounds = true
        layer.cornerCurve = .continuous
        initials.textAlignment = .center
        initials.font = .systemFont(ofSize: side * 0.4, weight: .semibold)
        initials.textColor = .white
        imageView.contentMode = .scaleAspectFill
        for view in [initials, imageView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor), view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor), view.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: side), heightAnchor.constraint(equalToConstant: side)])
        isAccessibilityElement = false
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = CCRadius.full.resolved(for: bounds.height)
    }

    private func refresh() {
        imageView.image = image
        imageView.isHidden = image == nil
        let parts = name.split(whereSeparator: { $0 == " " || $0 == "@" || $0 == "." }).prefix(2)
        initials.text = parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
        // Deterministic hue from the name — content, not chrome.
        var hash: UInt32 = 5381
        for byte in name.utf8 { hash = (hash &<< 5) &+ hash &+ UInt32(byte) }
        backgroundColor = UIColor(hue: CGFloat(hash % 360) / 360, saturation: 0.45, brightness: 0.72, alpha: 1)
    }
}

/// `withObservationTracking` re-arming loop — how state flows into views
/// (the Mac's SurfaceObservation). `apply` reads the observable state it
/// needs; any change to what it read re-runs it on the next main-actor turn.
final class SurfaceObservation {
    private var cancelled = false

    init(_ apply: @escaping () -> Void) {
        observe(apply)
    }

    private func observe(_ apply: @escaping () -> Void) {
        guard !cancelled else { return }
        withObservationTracking {
            apply()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observe(apply)
            }
        }
    }

    func cancel() { cancelled = true }

    deinit { cancelled = true }
}

/// A dressed surface that refits ITS OWN material in its own layout pass.
/// Use this (never a parent's layoutSubviews) for any nested well/tile: a
/// parent lays out before Auto Layout sizes its grandchildren, so refitting
/// from there parks the material at a stale (often zero) size.
class CCSurface: UIView {
    enum Kind {
        case raised
        case raisedMatte
        case recessed
    }

    var kind: Kind { didSet { applyTheme() } }
    var tint: UIColor { didSet { applyTheme() } }
    var radius: CCRadius { didSet { setNeedsLayout(); applyTheme() } }

    init(_ kind: Kind = .recessed, tint: UIColor = CCTheme.color.elevated, radius: CCRadius = .md) {
        self.kind = kind
        self.tint = tint
        self.radius = radius
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerCurve = .continuous
        ccOnThemeChange { [weak self] in self?.applyTheme() }
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let r = radius.resolved(for: bounds.height)
        layer.cornerRadius = r
        CCMaterial.refit(layer, radius: r)
    }

    func applyTheme() {
        let style: CCMaterial.Style
        switch kind {
        case .raised: style = .raised(tint: tint)
        case .raisedMatte: style = .raisedMatte(tint: tint)
        case .recessed: style = .recessed(tint: tint)
        }
        CCMaterial.dress(layer, as: style, radius: radius.resolved(for: bounds.height), traits: traitCollection)
    }
}

/// A square tile holding a kit icon (a recessed well by default).
final class CCIconTile: CCSurface {
    let icon: CCIconView

    init(symbol: String, side: CGFloat = 44, kind: Kind = .recessed, tint: UIColor = CCTheme.color.elevated,
         iconSize: CGFloat = 18, iconTint: UIColor = CCTheme.color.foreground, radius: CCRadius = .md) {
        icon = CCIconView(symbol, pointSize: iconSize, weight: .medium, tint: iconTint)
        super.init(kind, tint: tint, radius: radius)
        addSubview(icon)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: side),
            heightAnchor.constraint(equalToConstant: side),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
