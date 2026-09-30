import AppKit

/// CCKit empty state — shadcn's Empty: a recessed well holding a centered
/// icon on a RAISED key tile, a title, a short description and up to two
/// actions. On arrival the pieces rise in one after another (staggered
/// fade + lift, `CCMotion.stagger`).
///
///     let empty = CCEmptyState(
///         symbol: "film.stack", title: "No recordings yet",
///         message: "Hit ⌘⇧R to capture your first clip.",
///         primary: CCButton(title: "New Recording", style: .primary) { … },
///         secondary: CCButton(title: "Import…", style: .outline) { … })
@MainActor
final class CCEmptyState: NSView {
    /// Play the staggered arrival when first mounted in a window.
    var playsEntrance = true

    private let tile = NSView()
    private let icon = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let messageField = NSTextField(wrappingLabelWithString: "")
    private let buttonRow = NSStackView()
    private let stack = NSStackView()
    private var hasEntered = false
    private var themeObservation: CCThemeObservation?

    static let tileSide: CGFloat = 48

    init(symbol: String, title: String, message: String? = nil,
         primary: CCButton? = nil, secondary: CCButton? = nil) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        tile.wantsLayer = true
        tile.layer?.cornerCurve = .continuous
        tile.layer?.borderWidth = 1
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 20, weight: .regular))
        icon.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(icon)
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: Self.tileSide),
            tile.heightAnchor.constraint(equalToConstant: Self.tileSide),
            icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
        ])

        titleField.stringValue = title
        titleField.alignment = .center
        titleField.lineBreakMode = .byTruncatingTail
        messageField.stringValue = message ?? ""
        messageField.alignment = .center
        messageField.isHidden = message == nil
        messageField.isSelectable = false
        // Both yield width (below the window's resize priority) — the title
        // truncates and the description re-wraps as the area narrows.
        titleField.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        messageField.setContentCompressionResistancePriority(.init(250), for: .horizontal)

        buttonRow.orientation = .horizontal
        buttonRow.spacing = CCSpace.sm
        for button in [secondary, primary].compactMap({ $0 }) { buttonRow.addArrangedSubview(button) }
        buttonRow.isHidden = buttonRow.arrangedSubviews.isEmpty

        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = CCSpace.xs + 2
        for view in [tile, titleField, messageField, buttonRow] { stack.addArrangedSubview(view) }
        stack.setCustomSpacing(CCSpace.md + 2, after: tile)
        stack.setCustomSpacing(CCSpace.lg, after: messageField)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: CCSpace.xl + 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -(CCSpace.xl + 4)),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: CCSpace.lg),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -CCSpace.lg),
            // Readable measure for the description.
            messageField.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
        ])
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The pieces, in arrival order.
    private var pieces: [NSView] {
        [tile, titleField, messageField, buttonRow].filter { !$0.isHidden }
    }

    override func layout() {
        super.layout()
        let available = max(0, bounds.width - CCSpace.lg * 2)
        let measure = min(320, available)
        if abs(messageField.preferredMaxLayoutWidth - measure) > 0.5 {
            messageField.preferredMaxLayoutWidth = measure
            messageField.invalidateIntrinsicContentSize()
        }
        layer?.cornerRadius = CCTheme.radius(.lg)
        if let layer { CCMaterial.refit(layer, radius: CCTheme.radius(.lg)) }
        tile.layer?.cornerRadius = CCTheme.radius(.lg)
        if let layer = tile.layer { CCMaterial.refit(layer, radius: CCTheme.radius(.lg)) }
    }

    private func applyTheme() {
        let colors = CCTheme.color
        if let layer {
            // The empty area is a well; the icon tile is a key raised in it.
            layer.backgroundColor = colors.card.cgColor
            layer.borderColor = colors.border.cgColor
            CCMaterial.dress(layer, as: .recessed(tint: colors.card), radius: CCTheme.radius(.lg))
        }
        if let layer = tile.layer {
            layer.backgroundColor = colors.elevated.cgColor
            layer.borderColor = colors.border.cgColor
            CCMaterial.dress(layer, as: .raised(tint: colors.elevated), radius: CCTheme.radius(.lg))
        }
        icon.contentTintColor = colors.mutedForeground
        titleField.font = CCTheme.font.header
        titleField.textColor = colors.foreground
        messageField.font = CCTheme.font.label
        messageField.textColor = colors.mutedForeground
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, playsEntrance, !hasEntered else { return }
        hasEntered = true
        playEntrance()
    }

    /// Staggered arrival — tile, title, description, actions.
    func playEntrance() {
        CCMotion.stagger(pieces, distance: 8, interval: 0.06)
    }

    // MARK: - Harness seams

    var probePieces: [NSView] { pieces }
    var probeTileLayer: CALayer? { tile.layer }
    var probeWellLayer: CALayer? { layer }
}
