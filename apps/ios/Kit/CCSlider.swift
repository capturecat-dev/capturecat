import UIKit

/// The house slider (port of the Mac's CCSlider / InspectorSliderRow) — a
/// full-radius recessed pill that carries its own label and value readout,
/// faint tick marks, and a slim floating bar as the thumb:
///
///     ┌────────────────────────────────────────────┐
///     │ Padding   ·   ·   ·  ▍  ·   ·   ·     65%  │
///     └────────────────────────────────────────────┘
///
///     let padding = CCSlider(title: "Padding", value: 0.4)                 // 0–1, continuous
///     let blur = CCSlider(title: "Blur", value: 4, range: 0...10, step: 1) // discrete: ticks ARE the steps
///     let speed = CCSlider(title: "Speed", value: 1, range: 0.5...4)
///     speed.detents = [1]                                                // soft stop at 1×
///     speed.format = { String(format: "%.2g×", $0) }                     // human units only — never px/pt
///     speed.onChange = { value in … }    // live, every change
///     speed.onCommit = { value in … }    // once, when the finger lifts (undo grouping)
///
/// Touch: grab ANYWHERE on the pill and drag — the value moves by the
/// finger's travel (relative, so touching never jumps it); a TAP without
/// movement jumps to that spot and the bar springs there. Discrete sliders
/// tick a selection haptic on every step; continuous sliders stick briefly at
/// each `detent` with a firmer detent haptic, and both bump at the ends of the
/// range. The pill brightens and the bar grows while held (Mac 18 → 22 pt,
/// here 22 → 28 pt). VoiceOver: one adjustable element, value = the readout.
final class CCSlider: UIControl {
    // Keyboard (iPad, Studio 6a): focusable; the arrows adjust it exactly as
    // VoiceOver's swipe up / down does.
    override var canBecomeFocused: Bool { isEnabled && !isHidden && isUserInteractionEnabled }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if let step = ccArrowStep(presses), isEnabled {
            if step > 0 { accessibilityIncrement() } else { accessibilityDecrement() }
            return
        }
        super.pressesBegan(presses, with: event)
    }

    var onChange: ((Double) -> Void)?
    /// Fires once per gesture, when the finger lifts (or VoiceOver adjusts).
    var onCommit: ((Double) -> Void)?

    var range: ClosedRange<Double> {
        didSet { storedValue = resolve(storedValue); refreshValueText(); setNeedsLayout() }
    }

    /// nil = continuous. A step snaps the value to `lowerBound + k·step`; when
    /// the range holds ≤ 10 steps the ticks mark exactly those stops.
    var step: Double? {
        didSet { storedValue = resolve(storedValue); refreshValueText(); setNeedsLayout() }
    }

    /// Soft stops on a CONTINUOUS slider (a neutral 1×, a centred 0): the
    /// value sticks within ~8 pt of finger travel and a detent haptic fires as
    /// it lands. Each shows as a slightly stronger tick.
    var detents: [Double] = [] { didSet { setNeedsLayout() } }

    /// Custom readout. nil = the house default: the value as a normalized
    /// 0–100% of the range. Only human units (%, ×, °, s) — never px/pt.
    var format: ((Double) -> String)? {
        didSet { refreshValueText(); setNeedsLayout() }
    }

    var title: String {
        get { titleLabel.text ?? "" }
        set { titleLabel.text = newValue; accessibilityLabel = newValue; setNeedsLayout() }
    }

    /// Optional kit icon after the title.
    var symbol: String? {
        didSet {
            if let symbol {
                if let symbolView { symbolView.iconName = symbol } else {
                    let view = CCIconView(symbol, pointSize: 13, weight: .medium, tint: CCTheme.color.mutedForeground)
                    view.translatesAutoresizingMaskIntoConstraints = true
                    view.isUserInteractionEnabled = false
                    addSubview(view)
                    symbolView = view
                }
            } else {
                symbolView?.removeFromSuperview()
                symbolView = nil
            }
            setNeedsLayout()
        }
    }

    /// Step / detent / end-of-range haptics (on by default).
    var haptics = true

    var value: Double {
        get { storedValue }
        set { setValue(newValue, animated: false) }
    }

    override var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            CCMotion.fadeAlpha(self, to: isEnabled ? 1 : CCTheme.disabledAlpha, duration: 0.16)
            accessibilityTraits = isEnabled ? .adjustable : [.adjustable, .notEnabled]
        }
    }

    static let minHeight: CGFloat = 44
    private static let hPadding: CGFloat = 16
    private static let maxTicks = 9
    private static let barWidth: CGFloat = 5
    private static let barIdle: CGFloat = 22
    private static let barActive: CGFloat = 28
    /// Finger travel (pt) inside which a continuous value sticks to a detent.
    private static let detentRadius: CGFloat = 8

    private var storedValue: Double
    private let titleLabel: UILabel
    private var symbolView: CCIconView?
    private let valueLabel = UILabel()
    private var ticks: [CALayer] = []
    private var detentTicks: [CALayer] = []
    private let thumb = CALayer()
    private var dragging = false
    private var dragStartX: CGFloat = 0
    private var dragStartValue: Double = 0
    private var dragMoved = false

    init(title: String, value: Double = 0.5, range: ClosedRange<Double> = 0...1, step: Double? = nil,
         format: ((Double) -> String)? = nil) {
        self.range = range
        self.step = step
        self.format = format
        storedValue = value
        titleLabel = ccLabel(title, font: CCFont.scaled(15, .medium, .subheadline, max: 20), color: CCTheme.color.foreground)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerCurve = .continuous
        for _ in 0..<Self.maxTicks {
            let tick = CALayer()
            tick.cornerRadius = 0.5
            layer.addSublayer(tick)
            ticks.append(tick)
        }
        for _ in 0..<4 {
            let tick = CALayer()
            tick.cornerRadius = 0.75
            tick.isHidden = true
            layer.addSublayer(tick)
            detentTicks.append(tick)
        }
        // A plain layer, not a material sublayer: the bar's height SPRINGS,
        // and a child base layer would park at the final size mid-flight.
        thumb.cornerRadius = 2.5
        thumb.cornerCurve = .continuous
        thumb.borderWidth = 0.5
        thumb.shadowColor = UIColor.black.cgColor
        thumb.shadowOffset = .zero
        layer.addSublayer(thumb)
        titleLabel.translatesAutoresizingMaskIntoConstraints = true
        valueLabel.font = CCFont.mono
        valueLabel.adjustsFontForContentSizeCategory = true
        ccRelayoutOnTextSizeChange()
        // Big Dynamic Type: title and readout shrink to fit the pill (≥ 55%).
        for label in [titleLabel, valueLabel] {
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.55
        }
        valueLabel.textAlignment = .right
        for view in [titleLabel, valueLabel] as [UIView] {
            view.isUserInteractionEnabled = false
            addSubview(view)
        }
        setContentHuggingPriority(.required, for: .vertical)
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityTraits = .adjustable
        storedValue = resolve(value)
        refreshValueText()
        ccOnThemeChange { [weak self] in self?.applyTheme() }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: CCSlider, _: UITraitCollection) in
            self.invalidateIntrinsicContentSize()
            self.setNeedsLayout()
        }
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: max(Self.minHeight, ceil(titleLabel.font.lineHeight) + 20))
    }

    // MARK: - Value

    private var span: Double { range.upperBound - range.lowerBound }

    /// Clamp + step-snap (keeps 0.1 + 0.2 from drifting).
    private func resolve(_ raw: Double) -> Double {
        var v = min(max(raw, range.lowerBound), range.upperBound)
        if let step, step > 0 {
            v = ((v - range.lowerBound) / step).rounded() * step + range.lowerBound
            v = min(max(v, range.lowerBound), range.upperBound)
        }
        return v
    }

    /// Continuous only: stick to the nearest detent within the radius.
    private func stickToDetent(_ v: Double) -> Double {
        guard step == nil, !detents.isEmpty, travel.width > 0 else { return v }
        let radius = Double(Self.detentRadius / travel.width) * span
        guard let nearest = detents.min(by: { abs($0 - v) < abs($1 - v) }), abs(nearest - v) <= radius else { return v }
        return min(max(nearest, range.lowerBound), range.upperBound)
    }

    /// Keep a pushed model value as it is (clamped, NOT step-snapped), the
    /// way the Mac slider holds it: a model value between stops then still
    /// changes when the user lands on the nearest stop (the inspector, whose
    /// writes must match the Mac's). Off (default): pushes snap to a stop.
    var keepsOffStepValues = false

    /// Push a model value (no onChange echo). `animated` springs the bar there.
    func setValue(_ newValue: Double, animated: Bool) {
        let next = keepsOffStepValues ? min(max(newValue, range.lowerBound), range.upperBound) : resolve(newValue)
        guard next != storedValue else { return }
        storedValue = next
        refreshValueText()
        if animated, window != nil, bounds.width > 0 {
            CCMotion.spring(thumb, keyPath: "position", to: NSValue(cgPoint: thumbCenter(for: next)), .smooth)
        }
        setNeedsLayout()
    }

    /// A user-driven change: haptics, readout, callbacks.
    private func userSet(_ newValue: Double, animated: Bool = false) {
        let old = storedValue
        guard newValue != old else { return }
        if animated {
            setValue(newValue, animated: true)
        } else {
            storedValue = newValue
            refreshValueText()
            setNeedsLayout()
            layoutIfNeeded()
        }
        if haptics {
            if newValue == range.lowerBound || newValue == range.upperBound {
                CCHaptics.detent()
            } else if step != nil {
                CCHaptics.selection()
            } else if detents.contains(newValue) {
                CCHaptics.detent()
            }
        }
        onChange?(storedValue)
        sendActions(for: .valueChanged)
    }

    private func display(_ v: Double) -> String {
        if let format { return format(v) }
        guard span > 0 else { return "0%" }
        return "\(Int(((min(max(v, range.lowerBound), range.upperBound) - range.lowerBound) / span * 100).rounded()))%"
    }

    private func refreshValueText() {
        valueLabel.text = display(storedValue)
        accessibilityValue = valueLabel.text
    }

    // MARK: - Geometry

    /// Widest readout the range can produce — reserving it keeps the travel
    /// stable while the text changes under the bar.
    private var reservedValueWidth: CGFloat {
        let font = valueLabel.font ?? CCFont.mono
        let samples = [range.lowerBound, range.upperBound, storedValue] + (step == nil ? [] : [range.lowerBound + (step ?? 0)])
        let widest = samples.map { ceil((display($0) as NSString).size(withAttributes: [.font: font]).width) }.max() ?? 30
        return max(widest, 30)
    }

    private var titleWidth: CGFloat {
        min(ceil(titleLabel.intrinsicContentSize.width), max(0, bounds.width * 0.45))
    }

    /// The bar travels between the label and the readout — ticks and thumb
    /// never run under text.
    private var travel: (origin: CGFloat, width: CGFloat) {
        let symbolWidth: CGFloat = symbol == nil ? 0 : CCIcon.side(for: 13) + CCSpace.xs + 2
        let origin = Self.hPadding + titleWidth + symbolWidth + CCSpace.lg
        let end = bounds.width - Self.hPadding - reservedValueWidth - CCSpace.md
        return (origin, max(1, end - origin))
    }

    private func fraction(of v: Double) -> CGFloat {
        guard span > 0 else { return 0 }
        return CGFloat((min(max(v, range.lowerBound), range.upperBound) - range.lowerBound) / span)
    }

    private func thumbCenter(for v: Double) -> CGPoint {
        let (origin, width) = travel
        return CGPoint(x: origin + (width - Self.barWidth) * fraction(of: v) + Self.barWidth / 2, y: bounds.midY)
    }

    /// Discrete ranges with ≤ 10 steps tick every stop; otherwise ticks thin
    /// to the room (~22 pt apart, none when the travel is too tight to read).
    private var tickFractions: [CGFloat] {
        let width = travel.width
        if let step, step > 0, span > 0 {
            let count = Int((span / step).rounded())
            if count >= 2, count <= Self.maxTicks + 1, width / CGFloat(count) >= 12 {
                return (1..<count).map { CGFloat($0) / CGFloat(count) }
            }
        }
        let visible = width < 64 ? 0 : min(Self.maxTicks, Int(width / 22))
        return (0..<visible).map { CGFloat($0 + 1) / CGFloat(visible + 1) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let r = CCRadius.full.resolved(for: bounds.height)
        layer.cornerRadius = r
        CCMaterial.refit(layer, radius: r)

        let midY = bounds.midY
        let titleHeight = ceil(titleLabel.font.lineHeight)
        titleLabel.frame = CGRect(x: Self.hPadding, y: midY - titleHeight / 2, width: titleWidth, height: titleHeight)
        if let symbolView {
            let side = CCIcon.side(for: 13)
            symbolView.frame = CGRect(x: titleLabel.frame.maxX + CCSpace.xs + 2, y: midY - side / 2, width: side, height: side)
        }
        let valueHeight = ceil((valueLabel.font ?? CCFont.mono).lineHeight)
        let valueWidth = reservedValueWidth
        valueLabel.frame = CGRect(x: bounds.width - Self.hPadding - valueWidth, y: midY - valueHeight / 2, width: valueWidth, height: valueHeight)

        let (origin, width) = travel
        // A tick sits exactly where the bar's centre lands for that value, so
        // a discrete slider's bar parks ON its ticks.
        func tickX(_ f: CGFloat) -> CGFloat { origin + Self.barWidth / 2 + (width - Self.barWidth) * f }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let fractions = tickFractions
        for (index, tick) in ticks.enumerated() {
            tick.isHidden = index >= fractions.count
            guard index < fractions.count else { continue }
            tick.frame = CGRect(x: tickX(fractions[index]) - 0.5, y: midY - 5, width: 1, height: 10)
        }
        let marks = step == nil ? Array(detents.prefix(detentTicks.count)) : []
        for (index, tick) in detentTicks.enumerated() {
            tick.isHidden = index >= marks.count
            guard index < marks.count else { continue }
            tick.frame = CGRect(x: tickX(fraction(of: marks[index])) - 0.75, y: midY - 7, width: 1.5, height: 14)
        }
        let barHeight = dragging ? Self.barActive : Self.barIdle
        if thumb.animation(forKey: "ccmotion.bounds.size.height") == nil {
            thumb.bounds = CGRect(x: 0, y: 0, width: Self.barWidth, height: barHeight)
        }
        if thumb.animation(forKey: "ccmotion.position") == nil || dragging {
            thumb.removeAnimation(forKey: "ccmotion.position")
            thumb.position = thumbCenter(for: storedValue)
        }
        CATransaction.commit()
    }

    private func applyTheme() {
        let colors = CCTheme.color
        let traits = traitCollection
        let dark = CCTheme.isDark(traits)
        let fill = dragging ? colors.elevated.ccBlended(0.06, of: dark ? .white : .black, traits: traits) : colors.elevated
        CCMaterial.dress(layer, as: .recessed(tint: fill), radius: CCRadius.full.resolved(for: max(bounds.height, Self.minHeight)), traits: traits)
        layer.borderWidth = 1
        layer.borderColor = cc(colors.border)
        let tickInk = colors.faintForeground.resolvedColor(with: traits)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for tick in ticks { tick.backgroundColor = tickInk.withAlphaComponent(0.22).cgColor }
        for tick in detentTicks { tick.backgroundColor = tickInk.withAlphaComponent(0.5).cgColor }
        // The Mac thumb: a white floating bar on dark, light grey on light.
        thumb.backgroundColor = (dark ? UIColor.white : UIColor.lightGray).cgColor
        thumb.borderColor = CCMaterial.hairline(dark: dark, onWell: false).cgColor
        thumb.shadowOpacity = dark ? 0.35 : 0.22
        thumb.shadowRadius = 2.5
        CATransaction.commit()
        valueLabel.textColor = colors.mutedForeground
        titleLabel.textColor = colors.foreground
        symbolView?.tintColor = colors.mutedForeground
    }

    // MARK: - Touch (shared by UIControl tracking and the probe seams)

    private func trackBegan(at x: CGFloat) -> Bool {
        guard isEnabled else { return false }
        dragging = true
        dragMoved = false
        dragStartX = x
        dragStartValue = storedValue
        if haptics { CCHaptics.prepare() }
        applyTheme()
        CCMotion.spring(thumb, keyPath: "bounds.size.height", to: Self.barActive, .snappy)
        return true
    }

    private func trackMoved(to x: CGFloat) {
        guard dragging else { return }
        let dx = x - dragStartX
        if !dragMoved {
            guard abs(dx) >= 3 else { return }
            dragMoved = true
        }
        guard span > 0 else { return }
        let raw = dragStartValue + Double(dx / travel.width) * span
        // Past an end the value pins there and the drag re-bases, so coming
        // back moves it at once (no dead zone to unwind).
        if raw < range.lowerBound || raw > range.upperBound {
            let pinned = raw < range.lowerBound ? range.lowerBound : range.upperBound
            dragStartValue = pinned
            dragStartX = x
            userSet(pinned)
            return
        }
        userSet(stickToDetent(resolve(raw)))
    }

    private func trackEnded(at x: CGFloat?) {
        guard dragging else { return }
        dragging = false
        if let x, !dragMoved {
            // A tap: jump there; the bar springs across.
            let (origin, width) = travel
            let raw = range.lowerBound + Double(min(max((x - origin) / width, 0), 1)) * span
            let target = stickToDetent(resolve(raw))
            if target != storedValue {
                userSet(target, animated: true)
                if haptics, step == nil, !detents.contains(target), target != range.lowerBound, target != range.upperBound {
                    CCHaptics.selection()
                }
            }
        }
        applyTheme()
        CCMotion.spring(thumb, keyPath: "bounds.size.height", to: Self.barIdle, .bouncy)
        setNeedsLayout()
        onCommit?(storedValue)
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        trackBegan(at: touch.location(in: self).x)
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        trackMoved(to: touch.location(in: self).x)
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        trackEnded(at: touch?.location(in: self).x)
    }

    override func cancelTracking(with event: UIEvent?) {
        dragMoved = true   // a cancelled touch never counts as a tap
        trackEnded(at: nil)
    }

    // MARK: - Accessibility

    private var accessibilityStep: Double { step ?? span / 20 }

    override func accessibilityIncrement() { accessibilityAdjust(+1) }
    override func accessibilityDecrement() { accessibilityAdjust(-1) }

    private func accessibilityAdjust(_ direction: Double) {
        guard isEnabled else { return }
        var next = resolve(storedValue + direction * accessibilityStep)
        // Never step OVER a detent: land on it first.
        if step == nil, let crossed = detents.filter({ direction > 0 ? ($0 > storedValue && $0 < next) : ($0 < storedValue && $0 > next) })
            .min(by: { abs($0 - storedValue) < abs($1 - storedValue) }) {
            next = crossed
        }
        userSet(next, animated: true)
        onCommit?(storedValue)
    }

    // MARK: - Probe seams

    enum ProbePhase { case began, moved, ended, cancelled }

    /// Drive the real touch path with a finger at `x` (slider coordinates).
    func probeTrack(_ phase: ProbePhase, x: CGFloat) {
        switch phase {
        case .began: _ = trackBegan(at: x)
        case .moved: trackMoved(to: x)
        case .ended: trackEnded(at: x)
        case .cancelled: cancelTracking(with: nil)
        }
    }

    /// Where the bar's centre sits for `value`.
    func probeX(for value: Double) -> CGFloat { thumbCenter(for: value).x }
    var probeTravel: (origin: CGFloat, width: CGFloat) { travel }
    var probeThumbLayer: CALayer { thumb }
    var probeTickFrames: [CGRect] { ticks.filter { !$0.isHidden }.map(\.frame) }
    var probeDetentFrames: [CGRect] { detentTicks.filter { !$0.isHidden }.map(\.frame) }
    var probeValueText: String { valueLabel.text ?? "" }
    var probeIsDragging: Bool { dragging }
    var probeTitleFont: UIFont { titleLabel.font }
}
