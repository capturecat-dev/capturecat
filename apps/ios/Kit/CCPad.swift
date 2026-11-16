import UIKit

/// CCKit 2D pad — the inspector's drag pads (placement, camera bubble, tilt,
/// zoom focus, subtitle and watermark position) at touch scale: a recessed
/// well with a floating knob. The pad reports raw touches in its own
/// coordinates (`onTouch`); the host maps them to values (the studio's
/// InspectorPadMath) and pushes the knob back with `setKnob(_:animated:)`,
/// which springs (`.snappy`) when the value arrives from elsewhere and tracks
/// the finger 1:1 during a drag.
///
/// Touch-first: the whole well is the target (≥ 44 pt tall), a press
/// presses the knob in place, release lands it on the house bounce. One
/// VoiceOver element: label = title, value = `accessibilityValueProvider()`,
/// adjustable left/right and custom up/down actions nudging by `nudge`.
class CCPadView: UIControl {
    enum Phase { case began, moved, ended }

    /// Raw touches, pad coordinates (Y-down).
    var onTouch: ((Phase, CGPoint) -> Void)?
    /// VoiceOver nudges (dx, dy as fractions of the pad).
    var onNudge: ((CGFloat, CGFloat) -> Void)?
    var title: String { didSet { accessibilityLabel = title } }
    var accessibilityValueProvider: () -> String = { "" } { didSet { refreshAccessibility() } }
    var nudge: CGFloat = 0.05

    /// Where the knob sits, as a fraction of `knobArea`.
    private(set) var knobFraction = CGPoint(x: 0.5, y: 0.5)
    /// The rectangle the knob travels in (defaults to the inset bounds).
    var knobAreaInset: CGFloat = 14 { didSet { setNeedsLayout() } }
    var knobDiameter: CGFloat = 18 { didSet { setNeedsLayout() } }
    var showsKnob = true { didSet { knob.isHidden = !showsKnob } }

    /// Host drawing (mini cards, crosshairs) sits under the knob.
    let contentLayer = CALayer()
    let knob = CALayer()
    private(set) var isDragging = false

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerCurve = .continuous
        contentLayer.masksToBounds = true
        layer.addSublayer(contentLayer)
        layer.addSublayer(knob)
        heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityTraits = .adjustable
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Move up") { [weak self] _ in self?.onNudge?(0, -(self?.nudge ?? 0)); return true },
            UIAccessibilityCustomAction(name: "Move down") { [weak self] _ in self?.onNudge?(0, self?.nudge ?? 0); return true },
        ]
        ccOnThemeChange { [weak self] in self?.applyTheme() }
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The knob's travel rectangle.
    var knobArea: CGRect { bounds.insetBy(dx: knobAreaInset, dy: knobAreaInset) }

    func point(forFraction f: CGPoint) -> CGPoint {
        let area = knobArea
        return CGPoint(x: area.minX + f.x * area.width, y: area.minY + f.y * area.height)
    }

    /// Push the knob (no callbacks). Springs unless tracking or `animated` is false.
    func setKnob(_ fraction: CGPoint, animated: Bool) {
        knobFraction = fraction
        let target = point(forFraction: fraction)
        if animated, window != nil, !isDragging, bounds.width > 0 {
            CCMotion.spring(knob, keyPath: "position", to: NSValue(cgPoint: target), .snappy)
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            knob.position = target
            CATransaction.commit()
        }
        refreshAccessibility()
    }

    func refreshAccessibility() {
        accessibilityValue = accessibilityValueProvider()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let r = CCTheme.radius(.lg)
        layer.cornerRadius = r
        CCMaterial.refit(layer, radius: r)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.frame = bounds
        contentLayer.cornerRadius = r
        knob.bounds = CGRect(x: 0, y: 0, width: knobDiameter, height: knobDiameter)
        knob.cornerRadius = knobDiameter / 2
        CCMaterial.refit(knob, radius: knobDiameter / 2)
        knob.position = point(forFraction: knobFraction)
        CATransaction.commit()
    }

    func applyTheme() {
        CCMaterial.dress(layer, as: .recessed(tint: CCTheme.color.elevated), radius: CCTheme.radius(.lg), traits: traitCollection)
        layer.borderWidth = 1
        layer.borderColor = cc(CCTheme.color.border)
        CCMaterial.dress(knob, as: .raised(tint: .white), radius: knobDiameter / 2, traits: traitCollection)
    }

    // MARK: Touch

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        isDragging = true
        CCMotion.spring(knob, keyPath: "transform.scale", to: 1.18, .snappy)
        onTouch?(.began, touch.location(in: self))
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        onTouch?(.moved, touch.location(in: self))
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        isDragging = false
        CCMotion.spring(knob, keyPath: "transform.scale", to: 1.0, .bouncy)
        onTouch?(.ended, touch?.location(in: self) ?? point(forFraction: knobFraction))
    }

    override func cancelTracking(with event: UIEvent?) {
        endTracking(nil, with: event)
    }

    // MARK: VoiceOver

    override func accessibilityIncrement() { onNudge?(nudge, 0) }
    override func accessibilityDecrement() { onNudge?(-nudge, 0) }

    // MARK: Probe

    /// Drive the real touch path: press and release at `point` (pad coordinates).
    func probePress(at point: CGPoint) {
        isDragging = true
        onTouch?(.began, point)
        isDragging = false
        onTouch?(.ended, point)
    }
}
