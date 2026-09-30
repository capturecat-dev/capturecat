import AppKit

/// shadcn Kbd — a keycap for shortcuts. The kit's raised matte key with the
/// glyph centred, so "⇧⌘4" in a tooltip, a menu or a settings row reads as
/// real keys instead of a string.
///
///     CCKbd("⌘")                          // one key
///     CCKbd("Space", size: .sm)
///     CCKbd.group(["⇧", "⌘", "4"])        // a shortcut, keys 4pt apart
///     key.tap()                            // demo press: tints in place
///
/// Press follows the kit law — the cap TINTS in place (never travels or
/// scales); `tap()` is the scripted demo press used by walkthroughs.
@MainActor
final class CCKbd: NSView {
    enum Size {
        case sm
        case regular
        case lg

        var height: CGFloat {
            switch self {
            case .sm: return 18
            case .regular: return 22
            case .lg: return 34
            }
        }

        var hPadding: CGFloat {
            switch self {
            case .sm: return 5
            case .regular: return 6
            case .lg: return 10
            }
        }

        var radius: CCRadius {
            switch self {
            case .sm: return .sm
            case .regular, .lg: return .md
            }
        }

        @MainActor var font: NSFont {
            let base = CCTheme.font.button
            switch self {
            case .sm: return .systemFont(ofSize: base.pointSize - 1.5, weight: .medium)
            case .regular: return .systemFont(ofSize: base.pointSize, weight: .medium)
            case .lg: return .systemFont(ofSize: base.pointSize + 5, weight: .medium)
            }
        }
    }

    var text: String {
        get { label.stringValue }
        set {
            guard newValue != label.stringValue else { return }
            CCMotion.fadeContentSwap(label)
            label.stringValue = newValue
            invalidateIntrinsicContentSize()
            CCMotion.expand(self)
        }
    }

    let size: Size

    /// Held-down look for scripted demos (walkthroughs, tooltips that echo a
    /// pressed shortcut). Tints in place like every kit press.
    var isPressed = false {
        didSet {
            guard isPressed != oldValue, let layer else { return }
            CCMaterial.press(layer, down: isPressed)
        }
    }

    private let label = NSTextField(labelWithString: "")
    private var themeObservation: CCThemeObservation?

    override var intrinsicContentSize: NSSize {
        let textWidth = ceil(label.intrinsicContentSize.width)
        return NSSize(width: max(size.height, textWidth + size.hPadding * 2), height: size.height)
    }

    init(_ text: String, size: Size = .regular) {
        self.size = size
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        label.stringValue = text
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            // Glyphs sit optically a hair high on a raised face — the
            // under-edge makes the visible face shorter than the bounds.
            label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -0.5),
            heightAnchor.constraint(equalToConstant: size.height),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// A scripted keystroke: tint down, hold, release — the demo press.
    func tap(hold: TimeInterval = 0.16) {
        isPressed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + CCMotion.paced(hold)) { [weak self] in
            self?.isPressed = false
        }
    }

    override func layout() {
        super.layout()
        let radius = size.radius.resolved(for: bounds.height)
        layer?.cornerRadius = radius
        if let layer { CCMaterial.refit(layer, radius: radius) }
    }

    private func applyTheme() {
        guard let layer else { return }
        let colors = CCTheme.color
        label.font = size.font
        label.textColor = colors.foreground
        layer.backgroundColor = colors.elevated.cgColor
        // Inline caps sit in dense text rows — a cast shadow would smear
        // across neighbours; only the large demo caps throw one.
        if size != .lg { CCMaterial.suppressShadow(layer) }
        CCMaterial.dress(layer, as: .raised(tint: colors.elevated),
                         radius: size.radius.resolved(for: size.height))
    }

    /// A shortcut as a row of caps, 4pt apart (the macOS menu rhythm).
    static func group(_ keys: [String], size: Size = .regular) -> NSStackView {
        let stack = NSStackView(views: keys.map { CCKbd($0, size: size) })
        stack.orientation = .horizontal
        stack.spacing = size == .lg ? CCSpace.sm : CCSpace.xs
        return stack
    }

    // MARK: - Harness seams

    var probeLabel: NSTextField { label }
}
