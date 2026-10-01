import AppKit

/// CCKit callout — shadcn's inline Alert: a raised matte panel with a
/// leading variant icon, a title and a description. It drops in on arrival
/// (fade + a short fall from above) and, when dismissible, COLLAPSES on
/// dismiss: the bottom edge rises over the content (top pinned, nothing
/// inside moves) while the panel fades, and the stack below closes up
/// without a final snap.
///
///     let note = CCCallout(title: "Heads up!", message: "You can add components …")
///     let err = CCCallout(title: "Export failed", message: "Disk is full.",
///                         variant: .destructive, dismissible: true)
///     err.onDismiss = { ... }
@MainActor
final class CCCallout: NSView {
    enum Variant {
        case info
        case success
        case warning
        case destructive

        var symbol: String {
            switch self {
            case .info: return "info.circle.fill"
            case .success: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .destructive: return "exclamationmark.octagon.fill"
            }
        }

        @MainActor var color: NSColor {
            switch self {
            case .info: return CCTheme.color.primary
            case .success: return .systemGreen
            case .warning: return .systemOrange
            case .destructive: return CCTheme.color.destructive
            }
        }
    }

    let variant: Variant
    var onDismiss: (() -> Void)?
    /// Remove from the superview once the collapse lands (default).
    var removesOnDismiss = true
    /// Play the drop-in when first mounted in a window.
    var playsEntrance = true

    private let surface = NSView()
    private let icon = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let messageField = CCWrappingLabel()
    private var closeButton: CCButton?
    private var surfaceBottom: NSLayoutConstraint!
    /// The text's bottom pin — released when an action row sits below it.
    private var contentBottom: NSLayoutConstraint!
    private var actionRow: NSStackView?
    private(set) var actions: [CCButton] = []
    private var collapseHeight: NSLayoutConstraint?
    private var hasEntered = false
    private(set) var isDismissing = false
    private var themeObservation: CCThemeObservation?

    /// The material's extruded under-edge peeks 2pt below the surface; the
    /// clip leaves room for it.
    private static let extrude: CGFloat = 2

    init(title: String, message: String? = nil, variant: Variant = .info, dismissible: Bool = false) {
        self.variant = variant
        super.init(frame: .zero)
        wantsLayer = true
        // Clips the panel while the bottom edge rises on dismiss.
        layer?.masksToBounds = true

        surface.wantsLayer = true
        surface.layer?.cornerCurve = .continuous
        surface.layer?.borderWidth = 1
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)

        icon.image = NSImage(systemSymbolName: variant.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        titleField.stringValue = title
        titleField.lineBreakMode = .byTruncatingTail
        messageField.stringValue = message ?? ""
        messageField.isHidden = message == nil
        for view in [icon, titleField, messageField] {
            view.translatesAutoresizingMaskIntoConstraints = false
            surface.addSubview(view)
        }
        let pad = CCSpace.md
        let textLeading = pad + 16 + CCSpace.sm + 2
        surfaceBottom = surface.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.extrude)
        var constraints: [NSLayoutConstraint] = [
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surfaceBottom,
            icon.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: pad),
            icon.centerYAnchor.constraint(equalTo: titleField.centerYAnchor),
            titleField.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: textLeading),
            titleField.topAnchor.constraint(equalTo: surface.topAnchor, constant: pad),
            messageField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            messageField.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -pad),
        ]
        let trailingInset: CGFloat
        if dismissible {
            let close = CCButton(symbol: "xmark", style: .ghost, size: .sm) { [weak self] in self?.dismiss() }
            close.translatesAutoresizingMaskIntoConstraints = false
            surface.addSubview(close)
            constraints += [
                close.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -CCSpace.sm),
                close.centerYAnchor.constraint(equalTo: titleField.centerYAnchor),
            ]
            closeButton = close
            trailingInset = CCSpace.sm + 24 + CCSpace.xs
        } else {
            trailingInset = pad
        }
        constraints.append(titleField.trailingAnchor.constraint(lessThanOrEqualTo: surface.trailingAnchor,
                                                                constant: -trailingInset))
        if message != nil {
            contentBottom = messageField.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -pad)
            constraints += [
                messageField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: CCSpace.xxs + 1),
                contentBottom,
            ]
        } else {
            contentBottom = titleField.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -pad)
            constraints.append(contentBottom)
        }
        NSLayoutConstraint.activate(constraints)
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Action buttons in a row under the text, aligned with it (shadcn's
    /// Alert with actions — "[Restore] [Back to Current]"). An empty list
    /// removes the row.
    func setActions(_ buttons: [CCButton]) {
        actionRow?.removeFromSuperview()
        actionRow = nil
        actions = buttons
        guard !buttons.isEmpty else {
            contentBottom.isActive = true
            return
        }
        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.spacing = CCSpace.sm
        row.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(row)
        contentBottom.isActive = false
        let above: NSView = messageField.isHidden ? titleField : messageField
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: surface.trailingAnchor, constant: -CCSpace.md),
            row.topAnchor.constraint(equalTo: above.bottomAnchor, constant: CCSpace.sm),
            row.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -CCSpace.md),
        ])
        actionRow = row
    }

    override func layout() {
        super.layout()
        surface.layer?.cornerRadius = CCTheme.radius(.lg)
        if let layer = surface.layer { CCMaterial.refit(layer, radius: CCTheme.radius(.lg)) }
    }

    private func applyTheme() {
        let colors = CCTheme.color
        let tint = variant.color
        // A whisper of the variant hue in an OPAQUE fill (translucent fills
        // must never be dressed): the neutral info callout stays plain card.
        let amount: CGFloat = variant == .info ? 0 : (CCTheme.isDark ? 0.075 : 0.05)
        let fill = colors.card.blended(withFraction: amount, of: tint) ?? colors.card
        if let layer = surface.layer {
            layer.backgroundColor = fill.cgColor
            layer.borderColor = (variant == .info ? colors.border
                : tint.withAlphaComponent(CCTheme.isDark ? 0.26 : 0.24)).cgColor
            CCMaterial.dress(layer, as: .raisedMatte(tint: fill), radius: CCTheme.radius(.lg))
        }
        icon.contentTintColor = tint
        titleField.font = NSFont.systemFont(ofSize: CCTheme.font.chip.pointSize, weight: .semibold)
        titleField.textColor = variant == .destructive ? tint : colors.foreground
        messageField.font = CCTheme.font.label
        messageField.textColor = colors.mutedForeground
    }

    // MARK: - Entrance

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, playsEntrance, !hasEntered else { return }
        hasEntered = true
        playEntrance()
    }

    /// Fade in while falling a few points into place (translation-only, so
    /// AppKit's anchor stays put). Also callable to re-announce a callout.
    func playEntrance() {
        guard let layer, window != nil else { return }
        let above: CGFloat = (superview?.isFlipped ?? false) ? -6 : 6
        CCMotion.spring(layer, keyPath: "transform.translation.y", from: above, to: 0, .smooth)
        CCMotion.fadeAlpha(self, to: 1, duration: 0.22, from: 0)
    }

    // MARK: - Dismiss

    /// Collapse away: bottom edge rises (glide), content fades, then the
    /// view hides (and is removed when `removesOnDismiss`).
    func dismiss() {
        guard !isDismissing else { return }
        isDismissing = true
        layoutSubtreeIfNeeded()
        // Fold the stack's spacing AFTER us into our own height for the
        // collapse, so the stack closes up continuously — otherwise the gap
        // would snap shut when we finally hide.
        var extra: CGFloat = 0
        if let stack = superview as? NSStackView,
           let index = stack.arrangedSubviews.firstIndex(of: self),
           index < stack.arrangedSubviews.count - 1 {
            let custom = stack.customSpacing(after: self)
            extra = custom == NSStackView.useDefaultSpacing ? stack.spacing : custom
            stack.setCustomSpacing(0, after: self)
        }
        surfaceBottom.isActive = false
        let clamp = heightAnchor.constraint(equalToConstant: bounds.height + extra)
        clamp.isActive = true
        collapseHeight = clamp
        guard window != nil else { finishDismiss(); return }
        CCMotion.fadeAlpha(surface, to: 0, duration: 0.2)
        CCMotion.animate(clamp, to: 0, in: window?.contentView, duration: 0.3,
                         curve: CCMotion.glidePoints) { [weak self] in
            self?.finishDismiss()
        }
    }

    private func finishDismiss() {
        isHidden = true
        onDismiss?()
        if removesOnDismiss { removeFromSuperview() }
    }

    // MARK: - Harness seams

    var probeSurfaceLayer: CALayer? { surface.layer }
    var probeCollapseHeight: NSLayoutConstraint? { collapseHeight }
    /// The description's wrapped text fits its frame (nothing clipped).
    var probeMessageFits: Bool {
        guard !messageField.isHidden, let cell = messageField.cell else { return true }
        let width = messageField.bounds.width
        let needed = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 10_000)).height
        return width > 0 && needed <= messageField.bounds.height + 1
    }
}
