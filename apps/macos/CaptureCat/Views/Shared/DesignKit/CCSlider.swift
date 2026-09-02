import AppKit

/// The house slider — a full-radius pill that carries its own label and value,
/// with faint tick marks and a vertical white bar as the thumb:
///
///     ┌────────────────────────────────────────────┐
///     │ Clouds   ·   ·   ·  ▍  ·   ·   ·      65%  │
///     └────────────────────────────────────────────┘
///
/// Click anywhere to jump, then keep dragging. The bar tracks tight under the
/// pointer and settles on the house curve when the value arrives from the
/// model; on hover the pill brightens and the bar grows slightly.
@MainActor
final class CCSlider: NSControl {
    var range: ClosedRange<Double> = 0...1
    var step: Double?
    var onChange: ((Double) -> Void)?
    /// Custom value display. Leave nil for the house default: the value as a
    /// normalized 0–100% of the range. Units like px/pt are banned from the
    /// UI — nobody thinks in pixels; only human units (%, ×, °, s) may appear.
    var format: ((Double) -> String)? {
        didSet { refreshValueText() }
    }

    var title: String {
        get { titleField.stringValue }
        set { titleField.stringValue = newValue; needsLayout = true }
    }

    /// Optional SF Symbol shown after the title (e.g. a speaker icon).
    var symbol: String? {
        didSet {
            symbolView.image = symbol.flatMap {
                NSImage(systemSymbolName: $0, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
            }
            symbolView.isHidden = symbol == nil
            needsLayout = true
        }
    }

    override var doubleValue: Double {
        didSet {
            refreshValueText()
            needsLayout = true
        }
    }

    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1 : CCTheme.current.disabledAlpha }
    }

    private static let pillHeight: CGFloat = 36
    private static let hPadding: CGFloat = 14
    /// Upper bound; layout thins ticks out as the travel span shrinks.
    private static let maxTickCount = 9

    private let thumb = CALayer()
    private var ticks: [CALayer] = []
    private let titleField = NSTextField(labelWithString: "")
    private let symbolView = NSImageView()
    private let valueField = NSTextField(labelWithString: "")
    private var isHovering = false
    private var isDragging = false
    private var trackingArea: NSTrackingArea?
    private var themeObservation: CCThemeObservation?

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.pillHeight)
    }

    init(title: String = "") {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        for _ in 0..<Self.maxTickCount {
            let tick = CALayer()
            tick.cornerRadius = 0.5
            layer?.addSublayer(tick)
            ticks.append(tick)
        }

        thumb.cornerRadius = 2
        thumb.cornerCurve = .continuous
        thumb.shadowColor = NSColor.black.cgColor
        thumb.shadowOpacity = 0.35
        thumb.shadowRadius = 3
        thumb.shadowOffset = .zero
        layer?.addSublayer(thumb)

        titleField.stringValue = title
        titleField.font = CCTheme.font.button
        titleField.lineBreakMode = .byTruncatingTail
        valueField.font = CCTheme.font.mono
        valueField.alignment = .right
        symbolView.isHidden = true
        for view in [titleField, symbolView, valueField] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.pillHeight),
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.hPadding),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbolView.leadingAnchor.constraint(equalTo: titleField.trailingAnchor, constant: CCSpace.xs + 2),
            symbolView.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.hPadding),
            valueField.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueField.leadingAnchor.constraint(greaterThanOrEqualTo: titleField.trailingAnchor, constant: CCSpace.sm),
        ])
        refreshValueText()
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func applyTheme() {
        let colors = CCTheme.color
        layer?.borderColor = colors.border.cgColor
        for tick in ticks {
            tick.backgroundColor = colors.faintForeground.withAlphaComponent(0.22).cgColor
        }
        // The thumb bar is a hard-contrast marker: white on dark, ink on light.
        thumb.backgroundColor = (CCTheme.isDark ? NSColor.white : NSColor.black.withAlphaComponent(0.85)).cgColor
        titleField.textColor = colors.foreground
        valueField.textColor = colors.mutedForeground
        symbolView.contentTintColor = colors.mutedForeground
        restyle()
    }

    private var fraction: CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        let clamped = min(max(doubleValue, range.lowerBound), range.upperBound)
        return CGFloat((clamped - range.lowerBound) / span)
    }

    /// Widest value the current format can produce — reserving it keeps the
    /// travel span stable while the value text changes under the thumb.
    private var reservedValueWidth: CGFloat {
        let font = CCTheme.font.mono
        return [range.lowerBound, range.upperBound]
            .map { NSAttributedString(string: displayText(for: $0), attributes: [.font: font]).size().width }
            .max() ?? valueField.intrinsicContentSize.width
    }

    /// The bar travels between the label and the value — like the reference
    /// design, ticks and thumb never run under the text.
    private var travel: (origin: CGFloat, width: CGFloat) {
        let symbolWidth: CGFloat = symbol == nil ? 0 : 16 + CCSpace.xs
        let origin = Self.hPadding + titleField.intrinsicContentSize.width + symbolWidth + CCSpace.lg
        let end = bounds.width - Self.hPadding - max(reservedValueWidth, valueField.intrinsicContentSize.width) - CCSpace.md
        return (origin, max(1, end - origin))
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = CCRadius.full.resolved(for: bounds.height)
        if let layer { CCMaterial.refit(layer, radius: CCRadius.full.resolved(for: bounds.height)) }

        let (origin, width) = travel
        let midY = bounds.midY
        let barHeight: CGFloat = isDragging ? 22 : 18
        let barWidth: CGFloat = 4

        CATransaction.begin()
        if isDragging {
            CATransaction.setDisableActions(true)
        } else {
            CATransaction.setAnimationDuration(0.28)
            CATransaction.setAnimationTimingFunction(CCMotion.settle)
        }
        // Thin the ticks to the room available (~18pt apart, none when the
        // span is too tight for them to read as a scale).
        let visibleTicks = width < 54 ? 0 : min(Self.maxTickCount, Int(width / 18))
        for (index, tick) in ticks.enumerated() {
            tick.isHidden = index >= visibleTicks
            guard index < visibleTicks else { continue }
            let t = CGFloat(index + 1) / CGFloat(visibleTicks + 1)
            tick.frame = CGRect(x: origin + width * t, y: midY - 4, width: 1, height: 8)
        }
        thumb.frame = CGRect(
            x: origin + (width - barWidth) * fraction,
            y: midY - barHeight / 2,
            width: barWidth, height: barHeight
        )
        CATransaction.commit()
    }

    private func refreshValueText() {
        valueField.stringValue = displayText(for: doubleValue)
    }

    private func displayText(for value: Double) -> String {
        if let format { return format(value) }
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return "0%" }
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        return "\(Int(((clamped - range.lowerBound) / span * 100).rounded()))%"
    }

    private func restyle() {
        guard let layer else { return }
        let washTint: NSColor = CCTheme.isDark ? .white : .black
        let fill = isHovering || isDragging
            ? CCTheme.color.elevated.blended(withFraction: 0.06, of: washTint) ?? CCTheme.color.elevated
            : CCTheme.color.elevated
        CCMotion.fade(layer, keyPath: "backgroundColor", to: fill.cgColor)
        // Skeuo: the pill is a well; the thumb bar is a raised sliver.
        CCMaterial.dress(layer, as: .recessed(tint: fill),
                         radius: CCRadius.full.resolved(for: Self.pillHeight))
        CCMaterial.dress(thumb, as: .raised(tint: CCTheme.isDark ? .white : .lightGray), radius: 2)
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
        restyle()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        restyle()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isDragging = true
        CCMotion.spring(thumb, keyPath: "bounds.size.height", to: 22.0, .snappy)
        commit(atX: convert(event.locationInWindow, from: nil).x)
        restyle()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, isDragging else { return }
        commit(atX: convert(event.locationInWindow, from: nil).x)
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        commit(atX: convert(event.locationInWindow, from: nil).x)
        isDragging = false
        CCMotion.spring(thumb, keyPath: "bounds.size.height", to: 18.0, .bouncy)
        needsLayout = true
        restyle()
    }

    private func commit(atX x: CGFloat) {
        let (origin, width) = travel
        let fraction = min(max((x - origin) / width, 0), 1)
        var next = range.lowerBound + Double(fraction) * (range.upperBound - range.lowerBound)
        if let step, step > 0 {
            next = ((next - range.lowerBound) / step).rounded() * step + range.lowerBound
        }
        let clamped = min(max(next, range.lowerBound), range.upperBound)
        if clamped != doubleValue {
            doubleValue = clamped
            onChange?(clamped)
        }
        needsLayout = true
    }
}
