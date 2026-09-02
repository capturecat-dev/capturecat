import AppKit

// CCKit small primitives — Badge, Divider, Card. Each is a few dozen lines;
// they live together so the kit stays browsable.

/// shadcn Badge: a small pill label for statuses and counts.
///
///     CCBadge("Beta")                    // subtle wash
///     CCBadge("Live", variant: .primary) // accent fill
@MainActor
final class CCBadge: NSView {
    enum Variant {
        case subtle
        case primary
        case destructive
        case outline
    }

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue; invalidateIntrinsicContentSize() }
    }

    var variant: Variant {
        didSet { applyTheme() }
    }

    private let label = NSTextField(labelWithString: "")
    private var themeObservation: CCThemeObservation?

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(label.intrinsicContentSize.width) + 16, height: 20)
    }

    init(_ text: String, variant: Variant = .subtle) {
        self.variant = variant
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        label.stringValue = text
        label.font = CCTheme.font.caption
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 20),
        ])
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        layer?.cornerRadius = CCRadius.full.resolved(for: bounds.height)
        if let layer { CCMaterial.refit(layer, radius: CCRadius.full.resolved(for: bounds.height)) }
    }

    private func applyTheme() {
        guard let layer else { return }
        let colors = CCTheme.color
        let radius = CCRadius.full.resolved(for: 20)
        switch variant {
        case .subtle:
            layer.backgroundColor = colors.active.cgColor
            layer.borderWidth = 0
            label.textColor = colors.foreground
            CCMaterial.dress(layer, as: .raised(tint: colors.active), radius: radius)
        case .primary:
            layer.backgroundColor = colors.primary.cgColor
            layer.borderWidth = 0
            label.textColor = colors.primaryForeground
            CCMaterial.dress(layer, as: .raised(tint: colors.primary), radius: radius)
        case .destructive:
            layer.backgroundColor = colors.destructive.cgColor
            layer.borderWidth = 0
            label.textColor = .white
            CCMaterial.dress(layer, as: .raised(tint: colors.destructive), radius: radius)
        case .outline:
            layer.backgroundColor = NSColor.clear.cgColor
            layer.borderWidth = 1
            layer.borderColor = colors.border.cgColor
            label.textColor = colors.mutedForeground
            CCMaterial.strip(layer)
        }
    }
}

/// shadcn Separator: a 1pt hairline in the border token. Horizontal by
/// default; `CCDivider(vertical: true)` pins WIDTH to 1 instead — pinning a
/// horizontal divider's top+bottom collapses its host to 1pt (the required
/// height constraint wins over the window size; learned in the Settings
/// window, 2026-08-17).
@MainActor
final class CCDivider: NSView {
    private let vertical: Bool
    private var themeObservation: CCThemeObservation?

    override var intrinsicContentSize: NSSize {
        vertical
            ? NSSize(width: 1, height: NSView.noIntrinsicMetric)
            : NSSize(width: NSView.noIntrinsicMetric, height: 1)
    }

    init(vertical: Bool = false) {
        self.vertical = vertical
        super.init(frame: .zero)
        wantsLayer = true
        if vertical {
            widthAnchor.constraint(equalToConstant: 1).isActive = true
        } else {
            heightAnchor.constraint(equalToConstant: 1).isActive = true
        }
        themeObservation = CCThemeObservation { [weak self] in
            self?.layer?.backgroundColor = CCTheme.color.border.cgColor
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// shadcn Card: the house surface container — card fill, border, .lg radius,
/// vertical content stack with `CCSpace.md` padding. Add rows with
/// `addContent(_:)`; optional header via `init(title:)`.
@MainActor
final class CCCard: NSView {
    private let stack = NSStackView()
    private var titleField: NSTextField?
    private var themeObservation: CCThemeObservation?

    init(title: String? = nil) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = CCSpace.sm
        stack.edgeInsets = NSEdgeInsets(
            top: CCSpace.md, left: CCSpace.md,
            bottom: CCSpace.md, right: CCSpace.md
        )
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        if let title {
            let field = NSTextField(labelWithString: title)
            field.font = CCTheme.font.header
            stack.addArrangedSubview(field)
            stack.setCustomSpacing(CCSpace.md, after: field)
            titleField = field
        }
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        layer?.cornerRadius = CCTheme.radius(.lg)
        if let layer { CCMaterial.refit(layer, radius: CCTheme.radius(.lg)) }
    }

    func addContent(_ view: NSView, fullWidth: Bool = true) {
        stack.addArrangedSubview(view)
        if fullWidth {
            view.widthAnchor.constraint(
                equalTo: stack.widthAnchor, constant: -CCSpace.md * 2
            ).isActive = true
        }
    }

    private func applyTheme() {
        let colors = CCTheme.color
        layer?.backgroundColor = colors.card.cgColor
        layer?.borderColor = colors.border.cgColor
        // Skeuo: cards are raised material — gradient + bevel, no gloss.
        if let layer {
            CCMaterial.dress(layer, as: .raisedMatte(tint: colors.card),
                             radius: CCTheme.radius(.lg))
        }
        titleField?.textColor = colors.foreground
    }
}
