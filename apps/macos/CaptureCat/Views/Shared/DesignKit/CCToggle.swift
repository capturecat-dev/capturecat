import AppKit

/// CCKit switch — shadcn's Switch: a pill track with a round thumb that
/// springs across on the house bouncy curve. Track fills with `primary` when
/// on, `active` wash when off. All colors re-applied live on theme change.
///
///     let toggle = CCToggle(isOn: true) { on in ... }
@MainActor
final class CCToggle: NSControl {
    var onChange: ((Bool) -> Void)?

    var isOn: Bool {
        didSet {
            guard isOn != oldValue else { return }
            applyTheme()
            moveThumb(animated: true)
        }
    }

    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1 : CCTheme.current.disabledAlpha }
    }

    private static let trackSize = NSSize(width: 36, height: 21)
    private static let thumbInset: CGFloat = 2

    private let thumb = CALayer()
    private var themeObservation: CCThemeObservation?

    override var intrinsicContentSize: NSSize { Self.trackSize }

    init(isOn: Bool = false, onChange: ((Bool) -> Void)? = nil) {
        self.isOn = isOn
        self.onChange = onChange
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        let thumbSide = Self.trackSize.height - Self.thumbInset * 2
        thumb.bounds = CGRect(x: 0, y: 0, width: thumbSide, height: thumbSide)
        thumb.cornerRadius = thumbSide / 2
        thumb.shadowColor = NSColor.black.cgColor
        thumb.shadowOpacity = 0.3
        thumb.shadowRadius = 2
        thumb.shadowOffset = CGSize(width: 0, height: -0.5)
        layer?.addSublayer(thumb)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.trackSize.width),
            heightAnchor.constraint(equalToConstant: Self.trackSize.height),
        ])
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        layer?.cornerRadius = CCRadius.full.resolved(for: bounds.height)
        if let layer { CCMaterial.refit(layer, radius: CCRadius.full.resolved(for: bounds.height)) }
        // Never clobber an in-flight flip: a layout pass during the spring
        // (focus changes, sibling relayouts) would snap the thumb to its
        // endpoint. The spring's model value already IS the layout target.
        if thumb.animation(forKey: "capmotion.position") == nil {
            moveThumb(animated: false)
        }
    }

    private var thumbCenter: CGPoint {
        let side = thumb.bounds.height
        let x = isOn
            ? bounds.width - Self.thumbInset - side / 2
            : Self.thumbInset + side / 2
        return CGPoint(x: x, y: bounds.midY)
    }

    private func moveThumb(animated: Bool) {
        if animated {
            CCMotion.spring(thumb, keyPath: "position", to: NSValue(point: thumbCenter), .bouncy)
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            thumb.position = thumbCenter
            CATransaction.commit()
        }
    }

    private func applyTheme() {
        guard let layer else { return }
        let colors = CCTheme.color
        layer.backgroundColor = (isOn ? colors.primary : colors.active).cgColor
        layer.borderColor = (isOn ? NSColor.clear : colors.border).cgColor
        thumb.backgroundColor = NSColor.white.cgColor
        // Skeuo: the track is a lit well, the thumb a glossy ball.
        CCMaterial.dress(layer, as: .recessed(tint: isOn ? colors.primary : colors.active),
                         radius: CCRadius.full.resolved(for: Self.trackSize.height))
        CCMaterial.dress(thumb, as: .raised(tint: .white), radius: thumb.bounds.height / 2)
    }

    override func mouseDown(with event: NSEvent) {
        // Toggle on press-down: switches should feel instant.
        guard isEnabled else { return }
        isOn.toggle()
        onChange?(isOn)
    }

    // MARK: - Harness seams

    /// The material engine inserts sublayers below content, so probes must
    /// never fish with `sublayers.first` — it would read a static material
    /// layer that happens to sit mid-range and pass vacuously.
    var probeThumbLayer: CALayer { thumb }
}
