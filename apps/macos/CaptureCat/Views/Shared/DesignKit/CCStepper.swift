import AppKit

/// CCKit stepper — a numeric value in a recessed well between two raised
/// −/+ keys. Value changes ROLL the digits vertically in the direction of
/// change (`CCRollingLabel`). A click steps once on mouseUp; press-and-HOLD
/// auto-repeats after a beat and accelerates the longer you hold. ↑/↓ step
/// when focused. Keys dim at the bounds.
///
///     let fps = CCStepper(value: 30, min: 1, max: 120, step: 1)
///     fps.format = { "\(Int($0)) fps" }     // human units only — never px/pt
///     fps.onChange = { value in ... }
@MainActor
final class CCStepper: NSView {
    var onChange: ((Double) -> Void)?

    var minValue: Double { didSet { clampAndRefresh() } }
    var maxValue: Double { didSet { clampAndRefresh() } }
    var step: Double

    /// Human-unit display (%, ×, s, fps…). nil = the number itself, with
    /// decimals only when the step needs them.
    var format: ((Double) -> String)? {
        didSet {
            wellWidth?.constant = reservedWellWidth
            refreshText(direction: .none)
            invalidateIntrinsicContentSize()
        }
    }

    var value: Double {
        get { storedValue }
        set { setValue(newValue, notify: false) }
    }

    var isEnabled = true {
        didSet {
            alphaValue = isEnabled ? 1 : CCTheme.current.disabledAlpha
            refreshKeys()
        }
    }

    static let height: CGFloat = 30

    private var storedValue: Double
    private let minus = CCStepperKey(symbol: "minus")
    private let plus = CCStepperKey(symbol: "plus")
    private let well = NSView()
    private let label = CCRollingLabel()
    private var wellWidth: NSLayoutConstraint!
    private var themeObservation: CCThemeObservation?

    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { isEnabled }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.height * 2 + CCSpace.xs * 2 + reservedWellWidth, height: Self.height)
    }

    init(value: Double = 0, min: Double = 0, max: Double = 100, step: Double = 1) {
        storedValue = Swift.min(Swift.max(value, min), max)
        minValue = min
        maxValue = max
        self.step = step
        super.init(frame: .zero)

        well.wantsLayer = true
        well.layer?.cornerCurve = .continuous
        well.layer?.borderWidth = 1
        for view in [minus, well, plus] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        label.translatesAutoresizingMaskIntoConstraints = false
        well.addSubview(label)
        wellWidth = well.widthAnchor.constraint(equalToConstant: reservedWellWidth)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            minus.leadingAnchor.constraint(equalTo: leadingAnchor),
            minus.topAnchor.constraint(equalTo: topAnchor),
            minus.widthAnchor.constraint(equalToConstant: Self.height),
            minus.heightAnchor.constraint(equalToConstant: Self.height),
            well.leadingAnchor.constraint(equalTo: minus.trailingAnchor, constant: CCSpace.xs),
            well.topAnchor.constraint(equalTo: topAnchor),
            well.heightAnchor.constraint(equalToConstant: Self.height),
            wellWidth,
            plus.leadingAnchor.constraint(equalTo: well.trailingAnchor, constant: CCSpace.xs),
            plus.topAnchor.constraint(equalTo: topAnchor),
            plus.widthAnchor.constraint(equalToConstant: Self.height),
            plus.heightAnchor.constraint(equalToConstant: Self.height),
            plus.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.leadingAnchor.constraint(equalTo: well.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: well.trailingAnchor, constant: -4),
            label.topAnchor.constraint(equalTo: well.topAnchor),
            label.bottomAnchor.constraint(equalTo: well.bottomAnchor),
        ])
        minus.onStep = { [weak self] in self?.nudge(-1) }
        plus.onStep = { [weak self] in self?.nudge(1) }
        refreshText(direction: .none)
        refreshKeys()
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Value

    private func display(_ value: Double) -> String {
        if let format { return format(value) }
        let decimals = step.truncatingRemainder(dividingBy: 1) == 0 ? 0
            : Swift.min(3, Int(ceil(-log10(step.truncatingRemainder(dividingBy: 1)))))
        return String(format: "%.\(decimals)f", value)
    }

    /// Widest text the range can produce, so the well never jitters.
    private var reservedWellWidth: CGFloat {
        let font = label.font
        let widest = [minValue, maxValue, storedValue].map {
            NSAttributedString(string: display($0), attributes: [.font: font]).size().width
        }.max() ?? 20
        return Swift.max(48, ceil(widest) + CCSpace.md * 2)
    }

    private func nudge(_ direction: Int) {
        guard isEnabled else { return }
        setValue(storedValue + Double(direction) * step, notify: true)
    }

    private func setValue(_ newValue: Double, notify: Bool) {
        var next = Swift.min(Swift.max(newValue, minValue), maxValue)
        // Snap to the step grid (keeps 0.1 + 0.2 from drifting).
        if step > 0 { next = ((next - minValue) / step).rounded() * step + minValue }
        next = Swift.min(Swift.max(next, minValue), maxValue)
        guard next != storedValue else { return }
        let direction: CCRollingLabel.Direction = next > storedValue ? .up : .down
        storedValue = next
        refreshText(direction: direction)
        refreshKeys()
        if notify { onChange?(next) }
    }

    private func clampAndRefresh() {
        storedValue = Swift.min(Swift.max(storedValue, minValue), maxValue)
        wellWidth?.constant = reservedWellWidth
        refreshText(direction: .none)
        refreshKeys()
    }

    private func refreshText(direction: CCRollingLabel.Direction) {
        label.setText(display(storedValue), direction: direction)
    }

    private func refreshKeys() {
        minus.isEnabled = isEnabled && storedValue > minValue
        plus.isEnabled = isEnabled && storedValue < maxValue
    }

    // MARK: - Chrome

    override func layout() {
        super.layout()
        well.layer?.cornerRadius = CCTheme.radius(.md)
        if let layer = well.layer { CCMaterial.refit(layer, radius: CCTheme.radius(.md)) }
    }

    private func applyTheme() {
        let colors = CCTheme.color
        label.font = .monospacedDigitSystemFont(ofSize: CCTheme.font.chip.pointSize, weight: .medium)
        label.textColor = colors.foreground
        if let layer = well.layer {
            layer.backgroundColor = colors.elevated.cgColor
            layer.borderColor = colors.border.cgColor
            // Skeuo: the value sits in a recessed well between raised keys.
            CCMaterial.dress(layer, as: .recessed(tint: colors.elevated), radius: CCTheme.radius(.md))
        }
        wellWidth?.constant = reservedWellWidth
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126, 124: nudge(1)   // ↑ →
        case 125, 123: nudge(-1)  // ↓ ←
        default: super.keyDown(with: event)
        }
    }

    // MARK: - Harness seams

    var probeLabel: CCRollingLabel { label }
    var probeWellLayer: CALayer? { well.layer }
    var probeKeyLayers: [CALayer] { [minus.layer, plus.layer].compactMap { $0 } }
    /// Drive the real press-and-hold machinery (the mouse handlers feed it).
    func probeHold(plus isPlus: Bool, down: Bool) {
        (isPlus ? plus : minus).setHeld(down)
    }
}

// MARK: - Key

/// A raised −/+ key. Tints in place on press; a click steps on mouseUp
/// (inside), a hold auto-repeats with acceleration and suppresses the
/// release step.
@MainActor
private final class CCStepperKey: NSView {
    var onStep: (() -> Void)?

    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            CCMotion.fadeAlpha(self, to: isEnabled ? 1 : CCTheme.current.disabledAlpha, duration: 0.16)
            if !isEnabled { setHeld(false) }
        }
    }

    /// Hold timing: first repeat after `holdDelay`, then every interval,
    /// shrinking by `acceleration` down to `fastest`.
    static let holdDelay: TimeInterval = 0.4
    static let firstInterval: TimeInterval = 0.12
    static let acceleration: TimeInterval = 0.84
    static let fastest: TimeInterval = 0.03

    private let icon = NSImageView()
    private var isHovering = false
    private var isPressed = false
    private var repeated = false
    private var holdTimer: Timer?
    private var interval = CCStepperKey.firstInterval
    private var trackingArea: NSTrackingArea?
    private var themeObservation: CCThemeObservation?

    init(symbol: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        layer?.cornerRadius = CCTheme.radius(.md)
        if let layer { CCMaterial.refit(layer, radius: CCTheme.radius(.md)) }
    }

    private func applyTheme(animated: Bool = false) {
        guard let layer else { return }
        let colors = CCTheme.color
        let base = colors.elevated
        let ink: NSColor = CCTheme.isDark ? .white : .black
        // Same wash recipe as CCButton: hover lightens/darkens a touch,
        // press more — the key tints IN PLACE, it never travels.
        let amount: CGFloat = isPressed ? 0.14 : (isHovering ? 0.08 : 0)
        let fill = amount > 0 ? (base.blended(withFraction: amount, of: ink) ?? base) : base
        if animated {
            CCMotion.fade(layer, keyPath: "backgroundColor", to: fill.cgColor)
        } else {
            layer.backgroundColor = fill.cgColor
        }
        layer.borderColor = colors.border.cgColor
        CCMaterial.dress(layer, as: .raised(tint: fill), radius: CCTheme.radius(.md))
        icon.contentTintColor = colors.foreground
    }

    /// Press state + the hold-to-repeat clock.
    func setHeld(_ held: Bool) {
        holdTimer?.invalidate()
        holdTimer = nil
        guard held, isEnabled else { return }
        repeated = false
        interval = Self.firstInterval
        scheduleRepeat(after: Self.holdDelay)
    }

    private func scheduleRepeat(after delay: TimeInterval) {
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isEnabled else { return }
                self.repeated = true
                self.onStep?()
                self.interval = max(Self.fastest, self.interval * Self.acceleration)
                self.scheduleRepeat(after: self.interval)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled else { return }
        isHovering = true
        applyTheme(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        applyTheme(animated: true)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        applyTheme(animated: true)
        setHeld(true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled else { return }
        // Dragging off the key pauses the repeat (and the press tint);
        // coming back resumes both.
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        guard inside != isPressed else { return }
        isPressed = inside
        applyTheme(animated: true)
        if inside {
            scheduleRepeat(after: interval)
        } else {
            holdTimer?.invalidate()
            holdTimer = nil
        }
    }

    override func mouseUp(with event: NSEvent) {
        let wasRepeating = repeated
        setHeld(false)
        isPressed = false
        applyTheme(animated: true)
        guard isEnabled, !wasRepeating,
              bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onStep?()
    }
}
