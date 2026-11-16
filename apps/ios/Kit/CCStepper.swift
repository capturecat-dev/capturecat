import UIKit

/// CCKit stepper (port of the Mac's CCStepper) — a numeric value in a
/// recessed well between two raised −/+ keys. Value changes ROLL the digits
/// vertically in the direction of change (`CCRollingLabel`). A tap steps once
/// on release; press-and-HOLD auto-repeats after a beat and accelerates the
/// longer you hold. Keys dim at the bounds. Mac 30 pt → 40 pt here, each key a
/// 44 pt touch target.
///
///     let fps = CCStepper(value: 30, min: 1, max: 120, step: 1)
///     fps.format = { "\(Int($0)) fps" }     // human units only — never px/pt
///     fps.accessibilityLabel = "Frame rate"
///     fps.onChange = { value in … }         // every step (holds included)
///     fps.onCommit = { value in … }         // once, when the finger lifts
///
/// Haptics: a selection tick per step, a firmer detent when a bound is hit.
/// VoiceOver: ONE adjustable element (swipe up/down steps), value = the text.
final class CCStepper: UIControl {
    var onChange: ((Double) -> Void)?
    var onCommit: ((Double) -> Void)?

    var minValue: Double { didSet { clampAndRefresh() } }
    var maxValue: Double { didSet { clampAndRefresh() } }
    var step: Double

    /// Human-unit display (%, ×, s, fps…). nil = the number itself, with
    /// decimals only when the step needs them.
    var format: ((Double) -> String)? {
        didSet { refreshText(direction: .none); refreshWellWidth() }
    }

    var value: Double {
        get { storedValue }
        set { setValue(newValue, notify: false) }
    }

    override var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            CCMotion.fadeAlpha(well, to: isEnabled ? 1 : CCTheme.disabledAlpha, duration: 0.16)
            refreshKeys()
            accessibilityTraits = isEnabled ? .adjustable : [.adjustable, .notEnabled]
        }
    }

    static let height: CGFloat = 40
    static let keyWidth: CGFloat = 44

    private var storedValue: Double
    private let minus = CCStepperKey(symbol: "minus")
    private let plus = CCStepperKey(symbol: "plus")
    private let well = CCSurface(.recessed, tint: CCTheme.color.elevated, radius: .md)
    private let label = CCRollingLabel()
    private var wellWidth: NSLayoutConstraint!
    private var heightConstraint: NSLayoutConstraint!

    init(value: Double = 0, min: Double = 0, max: Double = 100, step: Double = 1) {
        storedValue = Swift.min(Swift.max(value, min), max)
        minValue = min
        maxValue = max
        self.step = step
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        well.isUserInteractionEnabled = false
        well.layer.borderWidth = 1
        for view in [minus, well, plus] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        well.addSubview(label)
        wellWidth = well.widthAnchor.constraint(equalToConstant: 56)
        heightConstraint = heightAnchor.constraint(equalToConstant: Self.height)
        NSLayoutConstraint.activate([
            heightConstraint,
            minus.leadingAnchor.constraint(equalTo: leadingAnchor),
            minus.topAnchor.constraint(equalTo: topAnchor),
            minus.bottomAnchor.constraint(equalTo: bottomAnchor),
            minus.widthAnchor.constraint(equalToConstant: Self.keyWidth),
            well.leadingAnchor.constraint(equalTo: minus.trailingAnchor, constant: CCSpace.xs),
            well.topAnchor.constraint(equalTo: topAnchor),
            well.bottomAnchor.constraint(equalTo: bottomAnchor),
            wellWidth,
            plus.leadingAnchor.constraint(equalTo: well.trailingAnchor, constant: CCSpace.xs),
            plus.topAnchor.constraint(equalTo: topAnchor),
            plus.bottomAnchor.constraint(equalTo: bottomAnchor),
            plus.widthAnchor.constraint(equalToConstant: Self.keyWidth),
            plus.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.leadingAnchor.constraint(equalTo: well.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: well.trailingAnchor, constant: -4),
            label.topAnchor.constraint(equalTo: well.topAnchor),
            label.bottomAnchor.constraint(equalTo: well.bottomAnchor),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        minus.onStep = { [weak self] in self?.nudge(-1) }
        plus.onStep = { [weak self] in self?.nudge(1) }
        minus.onRelease = { [weak self] in self?.commit() }
        plus.onRelease = { [weak self] in self?.commit() }
        isAccessibilityElement = true
        accessibilityTraits = .adjustable
        refreshText(direction: .none)
        refreshKeys()
        ccOnThemeChange { [weak self] in self?.applyTheme() }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: CCStepper, _: UITraitCollection) in
            self.refreshWellWidth()
        }
        applyTheme()
        refreshWellWidth()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: Self.keyWidth * 2 + CCSpace.xs * 2 + wellWidth.constant, height: heightConstraint.constant)
    }

    // MARK: - Value

    private func display(_ value: Double) -> String {
        if let format { return format(value) }
        let fractional = step.truncatingRemainder(dividingBy: 1)
        let decimals = fractional == 0 ? 0 : Swift.min(3, Int(ceil(-log10(fractional))))
        return String(format: "%.\(decimals)f", value)
    }

    /// Widest text the range can produce, so the well never jitters; the
    /// height follows Dynamic Type.
    private func refreshWellWidth() {
        let font = CCFont.monoValue(traitCollection)
        let widest = [minValue, maxValue, storedValue].map {
            (display($0) as NSString).size(withAttributes: [.font: font]).width
        }.max() ?? 20
        wellWidth?.constant = Swift.max(56, ceil(widest) + CCSpace.md * 2)
        heightConstraint?.constant = Swift.max(Self.height, ceil(font.lineHeight) + 16)
        invalidateIntrinsicContentSize()
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
        guard notify else { return }
        if next == minValue || next == maxValue { CCHaptics.detent() } else { CCHaptics.selection() }
        onChange?(next)
        sendActions(for: .valueChanged)
    }

    private func commit() { onCommit?(storedValue) }

    private func clampAndRefresh() {
        storedValue = Swift.min(Swift.max(storedValue, minValue), maxValue)
        refreshWellWidth()
        refreshText(direction: .none)
        refreshKeys()
    }

    private func refreshText(direction: CCRollingLabel.Direction) {
        label.setText(display(storedValue), direction: direction)
        accessibilityValue = display(storedValue)
    }

    private func refreshKeys() {
        minus.isEnabled = isEnabled && storedValue > minValue
        plus.isEnabled = isEnabled && storedValue < maxValue
    }

    private func applyTheme() {
        let colors = CCTheme.color
        label.textColor = colors.foreground
        well.tint = colors.elevated
        well.layer.borderColor = cc(colors.border)
    }

    // MARK: - Accessibility

    override func accessibilityIncrement() { nudge(1); commit() }
    override func accessibilityDecrement() { nudge(-1); commit() }

    // MARK: - Probe seams

    var probeLabel: CCRollingLabel { label }
    var probeWellLayer: CALayer { well.layer }
    var probeKeys: (minus: UIControl, plus: UIControl) { (minus, plus) }
    /// Drive the real press-and-hold machinery (the touch handlers feed it).
    func probeHold(plus isPlus: Bool, down: Bool) {
        (isPlus ? plus : minus).probePress(down)
    }
}

// MARK: - Key

/// A raised −/+ key. Tints in place on press; a tap steps on release
/// (inside), a hold auto-repeats with acceleration and suppresses the
/// release step. Dragging off pauses the repeat; coming back resumes it.
private final class CCStepperKey: UIControl {
    var onStep: (() -> Void)?
    var onRelease: (() -> Void)?

    /// Hold timing (the Mac's): first repeat after `holdDelay`, then every
    /// interval, shrinking by `acceleration` down to `fastest`.
    static let holdDelay: TimeInterval = 0.4
    static let firstInterval: TimeInterval = 0.12
    static let acceleration: TimeInterval = 0.84
    static let fastest: TimeInterval = 0.03

    private let icon: CCIconView
    private var pressed = false
    private var repeated = false
    private var holdTimer: Timer?
    private var interval = CCStepperKey.firstInterval

    init(symbol: String) {
        icon = CCIconView(symbol, pointSize: 15, weight: .semibold, tint: CCTheme.color.foreground)
        super.init(frame: .zero)
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        icon.isUserInteractionEnabled = false
        addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        isAccessibilityElement = false
        ccOnThemeChange { [weak self] in self?.applyTheme() }
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            CCMotion.fadeAlpha(self, to: isEnabled ? 1 : CCTheme.disabledAlpha, duration: 0.16)
            if !isEnabled { stopHold(); setPressed(false) }
        }
    }

    /// 44 pt tall touch target.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let dy = max(0, (44 - bounds.height) / 2)
        return bounds.insetBy(dx: 0, dy: -dy).contains(point)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let r = CCTheme.radius(.md)
        layer.cornerRadius = r
        CCMaterial.refit(layer, radius: r)
    }

    private func applyTheme() {
        let colors = CCTheme.color
        CCMaterial.dress(layer, as: .raised(tint: colors.elevated), radius: CCTheme.radius(.md), traits: traitCollection)
        layer.borderColor = cc(colors.border)
        icon.tintColor = colors.foreground
    }

    private func setPressed(_ down: Bool) {
        guard down != pressed else { return }
        pressed = down
        // Press TINTS in place — the key never travels.
        CCMaterial.press(layer, down: down, traits: traitCollection)
    }

    private func startHold() {
        stopHold()
        repeated = false
        interval = Self.firstInterval
        scheduleRepeat(after: Self.holdDelay)
    }

    private func stopHold() {
        holdTimer?.invalidate()
        holdTimer = nil
    }

    private func scheduleRepeat(after delay: TimeInterval) {
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isEnabled, self.pressed else { return }
                self.repeated = true
                self.onStep?()
                self.interval = max(Self.fastest, self.interval * Self.acceleration)
                self.scheduleRepeat(after: self.interval)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard isEnabled else { return false }
        setPressed(true)
        startHold()
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let inside = self.point(inside: touch.location(in: self), with: event)
        guard inside != pressed else { return true }
        setPressed(inside)
        if inside { scheduleRepeat(after: interval) } else { stopHold() }
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        let inside = touch.map { self.point(inside: $0.location(in: self), with: event) } ?? false
        release(stepIfTap: inside)
    }

    override func cancelTracking(with event: UIEvent?) { release(stepIfTap: false) }

    private func release(stepIfTap: Bool) {
        let wasRepeating = repeated
        stopHold()
        setPressed(false)
        if isEnabled, stepIfTap, !wasRepeating { onStep?() }
        onRelease?()
    }

    func probePress(_ down: Bool) {
        if down {
            guard isEnabled else { return }
            setPressed(true)
            startHold()
        } else {
            release(stepIfTap: true)
        }
    }
}
