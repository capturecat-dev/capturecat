import UIKit

// CCKit color picking (the Mac's InspectorColorWellControl +
// ColorPickerPopoverView, at touch scale):
//
//   CCColorWell        the inspector's round swatch; tap → the picker
//   CCColorPickerView  the picker body: house swatches, then CUSTOM — a
//                      saturation/brightness field, a hue bar, an opacity bar
//                      (when the property has opacity) and a hex entry
//   CCColorPicker      presents the body: a bottom sheet on compact width, a
//                      floating card anchored to the well on regular width
//
//     let well = CCColorWell(title: "Ripple color", color: .white, supportsOpacity: false)
//     well.onChange = { color in … }     // live, every knob move / swatch / hex
//     well.onCommit = { color in … }     // once, when the picker closes
//
// COLOR SPACE: everything is sRGB (the Mac picker's rule). HSB ↔ sRGB is done
// by hand so the hex readout always describes the swatch it sits next to.
// The spectra, swatches and the composed color are CONTENT and never retheme;
// only chrome (rims, wells, knob shadow) follows light/dark.

// MARK: - sRGB HSB

struct CCHSBA: Equatable {
    var hue: Double
    var saturation: Double
    var brightness: Double
    var alpha: Double
}

extension UIColor {
    /// HSB → sRGB by hand (UIColor(hue:…) lands in extended sRGB, which is
    /// the same for in-gamut values — but this keeps the math explicit and
    /// identical to the Mac's `NSColor.srgb(hue:…)`).
    static func ccSRGB(hue: Double, saturation: Double, brightness: Double, alpha: Double = 1) -> UIColor {
        let h = (hue.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
        let s = min(max(saturation, 0), 1)
        let v = min(max(brightness, 0), 1)
        let sector = floor(h)
        let f = h - sector
        let p = v * (1 - s)
        let q = v * (1 - s * f)
        let t = v * (1 - s * (1 - f))
        let rgb: (Double, Double, Double)
        switch Int(sector) % 6 {
        case 0: rgb = (v, t, p)
        case 1: rgb = (q, v, p)
        case 2: rgb = (p, v, t)
        case 3: rgb = (p, q, v)
        case 4: rgb = (t, p, v)
        default: rgb = (v, p, q)
        }
        return UIColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: min(max(alpha, 0), 1))
    }

    /// sRGB components, clamped to 0…1 (out-of-gamut colors clip).
    var ccSRGBA: (r: Double, g: Double, b: Double, a: Double) {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let converted = cgColor.converted(to: srgb, intent: .defaultIntent, options: nil) ?? cgColor
        let c = converted.components ?? [1, 1, 1, 1]
        func clamp(_ v: CGFloat) -> Double { Double(min(max(v, 0), 1)) }
        if c.count >= 4 { return (clamp(c[0]), clamp(c[1]), clamp(c[2]), clamp(c[3])) }
        if c.count == 2 { return (clamp(c[0]), clamp(c[0]), clamp(c[0]), clamp(c[1])) }
        return (1, 1, 1, 1)
    }

    /// sRGB → HSB (hue 0…1).
    var ccHSBA: CCHSBA {
        let (r, g, b, a) = ccSRGBA
        let maxC = max(r, g, b), minC = min(r, g, b), delta = maxC - minC
        var hue = 0.0
        if delta > 0 {
            if maxC == r { hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
            else if maxC == g { hue = (b - r) / delta + 2 }
            else { hue = (r - g) / delta + 4 }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        return CCHSBA(hue: hue, saturation: maxC == 0 ? 0 : delta / maxC, brightness: maxC, alpha: a)
    }

    /// "RRGGBB" (sRGB, alpha ignored).
    var ccHex: String {
        let (r, g, b, _) = ccSRGBA
        return String(format: "%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    /// Parse "RRGGBB" / "#RRGGBB" / "RGB".
    static func ccHex(_ text: String, alpha: Double = 1) -> UIColor? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return UIColor(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
                       blue: Double(v & 0xFF) / 255, alpha: alpha)
    }

    /// Same 8-bit sRGB color (alpha ignored).
    func ccSameRGB(_ other: UIColor) -> Bool { ccHex == other.ccHex }
}

/// A named house swatch (names are for VoiceOver).
struct CCColorPreset {
    var name: String
    var color: UIColor

    /// The Mac picker's twelve presets, in its order.
    static let house: [CCColorPreset] = [
        .init(name: "White", color: .white),
        .init(name: "Light grey", color: UIColor(red: 0.75, green: 0.75, blue: 0.75, alpha: 1)),
        .init(name: "Grey", color: UIColor(red: 0.45, green: 0.45, blue: 0.45, alpha: 1)),
        .init(name: "Black", color: .black),
        .init(name: "Yellow", color: UIColor(red: 1.00, green: 0.84, blue: 0.20, alpha: 1)),
        .init(name: "Coral", color: UIColor(red: 1.00, green: 0.42, blue: 0.30, alpha: 1)),
        .init(name: "Pink", color: UIColor(red: 0.98, green: 0.31, blue: 0.55, alpha: 1)),
        .init(name: "Violet", color: UIColor(red: 0.65, green: 0.45, blue: 0.98, alpha: 1)),
        .init(name: "Periwinkle", color: UIColor(red: 0.62, green: 0.66, blue: 0.92, alpha: 1)),
        .init(name: "Blue", color: UIColor(red: 0.25, green: 0.62, blue: 1.00, alpha: 1)),
        .init(name: "Green", color: UIColor(red: 0.25, green: 0.85, blue: 0.62, alpha: 1)),
        .init(name: "Orange", color: UIColor(red: 1.00, green: 0.62, blue: 0.25, alpha: 1)),
    ]

    static func name(for color: UIColor, in presets: [CCColorPreset] = house) -> String? {
        presets.first { $0.color.ccSameRGB(color) }?.name
    }
}

/// VoiceOver text for a color: "Blue, 40A0FF, 80% opacity".
func ccColorDescription(_ color: UIColor, presets: [CCColorPreset] = CCColorPreset.house, opacity: Bool = true) -> String {
    let rgba = color.ccSRGBA
    var parts = [CCColorPreset.name(for: color, in: presets), "#" + color.ccHex].compactMap { $0 }
    if opacity, rgba.a < 0.995 { parts.append("\(Int((rgba.a * 100).rounded()))% opacity") }
    return parts.joined(separator: ", ")
}

// MARK: - Checkerboard

/// The transparency checker under translucent colors (content, not chrome).
final class CCCheckerboardLayer: CALayer {
    var square: CGFloat = 5 { didSet { setNeedsDisplay() } }

    override init() {
        super.init()
        needsDisplayOnBoundsChange = true
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(in ctx: CGContext) {
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(bounds)
        ctx.setFillColor(UIColor(white: 0.80, alpha: 1).cgColor)
        let cols = Int(ceil(bounds.width / square)), rows = Int(ceil(bounds.height / square))
        for row in 0..<max(rows, 0) {
            for col in 0..<max(cols, 0) where (row + col) % 2 == 1 {
                ctx.fill(CGRect(x: CGFloat(col) * square, y: CGFloat(row) * square, width: square, height: square))
            }
        }
    }
}

// MARK: - Knob

/// The drag knob for the spectra: the current color in a white ring with a
/// soft dark shadow (legible on any hue). Grows while held (scale spring).
private final class CCColorKnob: CALayer {
    override init() {
        super.init()
        borderColor = UIColor.white.cgColor
        shadowColor = UIColor.black.cgColor
        shadowOpacity = 0.35
        shadowRadius = 2
        shadowOffset = CGSize(width: 0, height: 0.5)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func size(_ diameter: CGFloat, ring: CGFloat = 3) {
        bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        cornerRadius = diameter / 2
        borderWidth = ring
    }

    func held(_ down: Bool) {
        CCMotion.spring(self, keyPath: "transform.scale", to: down ? 1.18 : 1.0, down ? .snappy : .bouncy)
    }
}

/// An accessibility element whose value and adjustments are closures.
final class CCAdjustableElement: UIAccessibilityElement {
    var valueText: () -> String = { "" }
    var onIncrement: () -> Void = {}
    var onDecrement: () -> Void = {}

    override var accessibilityValue: String? {
        get { valueText() }
        set {}
    }

    override func accessibilityIncrement() { onIncrement() }
    override func accessibilityDecrement() { onDecrement() }
}

// MARK: - Saturation / brightness field

/// White→hue horizontally, clear→black vertically. Touch anywhere to jump
/// there, then keep dragging (the Mac's square). VoiceOver: two adjustable
/// elements, saturation and brightness.
final class CCColorField: UIControl {
    var hue: Double = 0 { didSet { refreshGradient() } }
    var saturation: Double = 0 { didSet { setNeedsLayout() } }
    var brightness: Double = 1 { didSet { setNeedsLayout() } }
    /// Fires continuously through the drag with (saturation, brightness).
    var onChange: ((Double, Double) -> Void)?
    var onRelease: (() -> Void)?

    private let clip = CALayer()
    private let hueGradient = CAGradientLayer()
    private let shadeGradient = CAGradientLayer()
    private let knob = CCColorKnob()
    private let satElement: CCAdjustableElement
    private let briElement: CCAdjustableElement

    override init(frame: CGRect) {
        satElement = CCAdjustableElement(accessibilityContainer: NSObject())
        briElement = CCAdjustableElement(accessibilityContainer: NSObject())
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        clip.masksToBounds = true
        clip.cornerCurve = .continuous
        clip.borderWidth = 1
        hueGradient.startPoint = CGPoint(x: 0, y: 0.5)
        hueGradient.endPoint = CGPoint(x: 1, y: 0.5)
        shadeGradient.startPoint = CGPoint(x: 0.5, y: 0)
        shadeGradient.endPoint = CGPoint(x: 0.5, y: 1)
        shadeGradient.colors = [UIColor.black.withAlphaComponent(0).cgColor, UIColor.black.cgColor]
        clip.addSublayer(hueGradient)
        clip.addSublayer(shadeGradient)
        layer.addSublayer(clip)
        knob.size(26)
        layer.addSublayer(knob)
        refreshGradient()
        satElement.accessibilityContainer = self
        briElement.accessibilityContainer = self
        satElement.accessibilityLabel = "Saturation"
        briElement.accessibilityLabel = "Brightness"
        satElement.accessibilityTraits = .adjustable
        briElement.accessibilityTraits = .adjustable
        satElement.valueText = { [weak self] in "\(Int(((self?.saturation ?? 0) * 100).rounded()))%" }
        briElement.valueText = { [weak self] in "\(Int(((self?.brightness ?? 0) * 100).rounded()))%" }
        satElement.onIncrement = { [weak self] in self?.adjust(ds: 0.05, db: 0) }
        satElement.onDecrement = { [weak self] in self?.adjust(ds: -0.05, db: 0) }
        briElement.onIncrement = { [weak self] in self?.adjust(ds: 0, db: 0.05) }
        briElement.onDecrement = { [weak self] in self?.adjust(ds: 0, db: -0.05) }
        accessibilityElements = [satElement, briElement]
        ccOnThemeChange { [weak self] in self?.applyTheme() }
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func applyTheme() {
        let ink: UIColor = CCTheme.isDark(traitCollection) ? .white : .black
        clip.borderColor = ink.withAlphaComponent(0.08).cgColor
    }

    private func refreshGradient() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Linear sRGB white→hue, then clear→black on top, IS the HSB plane:
        // v·((1−s)·white + s·hue) — exact, no Oklab needed.
        hueGradient.colors = [UIColor.white.cgColor, UIColor.ccSRGB(hue: hue, saturation: 1, brightness: 1).cgColor]
        knob.backgroundColor = UIColor.ccSRGB(hue: hue, saturation: saturation, brightness: brightness).cgColor
        CATransaction.commit()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clip.frame = bounds
        clip.cornerRadius = CCTheme.radius(.md)
        hueGradient.frame = clip.bounds
        shadeGradient.frame = clip.bounds
        knob.position = CGPoint(x: saturation * bounds.width, y: (1 - brightness) * bounds.height)
        knob.backgroundColor = UIColor.ccSRGB(hue: hue, saturation: saturation, brightness: brightness).cgColor
        CATransaction.commit()
        satElement.accessibilityFrameInContainerSpace = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height / 2)
        briElement.accessibilityFrameInContainerSpace = CGRect(x: 0, y: bounds.height / 2, width: bounds.width, height: bounds.height / 2)
    }

    private func adjust(ds: Double, db: Double) {
        saturation = min(max(saturation + ds, 0), 1)
        brightness = min(max(brightness + db, 0), 1)
        onChange?(saturation, brightness)
        onRelease?()
    }

    private func commit(_ point: CGPoint) {
        let s = min(1, max(0, Double(point.x / max(1, bounds.width))))
        let b = min(1, max(0, 1 - Double(point.y / max(1, bounds.height))))
        guard s != saturation || b != brightness else { return }
        saturation = s
        brightness = b
        onChange?(s, b)
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        knob.held(true)
        commit(touch.location(in: self))
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        commit(touch.location(in: self))
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        if let touch { commit(touch.location(in: self)) }
        knob.held(false)
        onRelease?()
    }

    override func cancelTracking(with event: UIEvent?) { endTracking(nil, with: event) }

    /// Probe seam: drive the real touch path at a point (field coordinates).
    func probeTouch(_ point: CGPoint, phase: Int) {
        switch phase {
        case 0: knob.held(true); commit(point)
        case 1: commit(point)
        default: commit(point); knob.held(false); onRelease?()
        }
    }

    var probeKnob: CALayer { knob }
}

// MARK: - Hue / opacity bars

/// A capsule bar with a knob (hue spectrum, or opacity over the checker).
/// Touch anywhere to jump, then drag. One adjustable VoiceOver element.
final class CCColorBar: UIControl {
    enum Kind {
        case hue
        case opacity
    }

    let kind: Kind
    var fraction: Double = 0 { didSet { setNeedsLayout(); refreshAccessibility() } }
    /// Opacity bars: the opaque end of the ramp (the current color at alpha 1).
    var baseColor: UIColor = .white { didSet { refreshGradient() } }
    var onChange: ((Double) -> Void)?
    var onRelease: (() -> Void)?

    static let height: CGFloat = 28
    private let clip = CALayer()
    private let checker = CCCheckerboardLayer()
    private let gradient = CAGradientLayer()
    private let knob = CCColorKnob()

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        clip.masksToBounds = true
        clip.borderWidth = 1
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        if kind == .opacity {
            checker.square = 6
            clip.addSublayer(checker)
        }
        clip.addSublayer(gradient)
        layer.addSublayer(clip)
        knob.size(Self.height)
        layer.addSublayer(knob)
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        isAccessibilityElement = true
        accessibilityLabel = kind == .hue ? "Hue" : "Opacity"
        accessibilityTraits = .adjustable
        refreshGradient()
        refreshAccessibility()
        ccOnThemeChange { [weak self] in self?.applyTheme() }
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// 44 pt tall touch target around the 28 pt bar.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let dy = max(0, (44 - bounds.height) / 2)
        return bounds.insetBy(dx: 0, dy: -dy).contains(point)
    }

    private func applyTheme() {
        let ink: UIColor = CCTheme.isDark(traitCollection) ? .white : .black
        clip.borderColor = ink.withAlphaComponent(0.08).cgColor
        checker.contentsScale = max(traitCollection.displayScale, 1)
        checker.setNeedsDisplay()
    }

    private func refreshGradient() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch kind {
        case .hue:
            // Seven stops: linear sRGB between neighbouring pure hues IS the
            // HSB hue ramp at s = b = 1.
            gradient.colors = (0...6).map { UIColor.ccSRGB(hue: Double($0) / 6, saturation: 1, brightness: 1).cgColor }
            gradient.locations = (0...6).map { NSNumber(value: Double($0) / 6) }
        case .opacity:
            let (r, g, b, _) = baseColor.ccSRGBA
            gradient.colors = [UIColor(red: r, green: g, blue: b, alpha: 0).cgColor, UIColor(red: r, green: g, blue: b, alpha: 1).cgColor]
            gradient.locations = nil
        }
        CATransaction.commit()
        setNeedsLayout()
    }

    private var knobColor: UIColor {
        switch kind {
        case .hue: return .ccSRGB(hue: fraction, saturation: 1, brightness: 1)
        case .opacity:
            let (r, g, b, _) = baseColor.ccSRGBA
            return UIColor(red: r, green: g, blue: b, alpha: 1).ccBlended(1 - fraction, of: .white, traits: traitCollection)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clip.frame = bounds
        clip.cornerRadius = bounds.height / 2
        checker.frame = clip.bounds
        gradient.frame = clip.bounds
        let r = bounds.height / 2
        knob.position = CGPoint(x: r + CGFloat(fraction) * max(0, bounds.width - 2 * r), y: bounds.midY)
        knob.backgroundColor = knobColor.cgColor
        CATransaction.commit()
    }

    private func refreshAccessibility() {
        accessibilityValue = kind == .hue ? "\(Int((fraction * 360).rounded()))°" : "\(Int((fraction * 100).rounded()))%"
    }

    private func commit(_ x: CGFloat) {
        let r = bounds.height / 2
        let f = min(1, max(0, Double((x - r) / max(1, bounds.width - 2 * r))))
        guard f != fraction else { return }
        fraction = f
        onChange?(f)
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        knob.held(true)
        commit(touch.location(in: self).x)
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        commit(touch.location(in: self).x)
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        if let touch { commit(touch.location(in: self).x) }
        knob.held(false)
        onRelease?()
    }

    override func cancelTracking(with event: UIEvent?) { endTracking(nil, with: event) }

    override func accessibilityIncrement() { step(kind == .hue ? 5.0 / 360 : 0.05) }
    override func accessibilityDecrement() { step(kind == .hue ? -5.0 / 360 : -0.05) }

    private func step(_ delta: Double) {
        fraction = min(max(fraction + delta, 0), 1)
        onChange?(fraction)
        onRelease?()
    }

    /// Probe seam: the real commit path at `x` (bar coordinates).
    func probeCommit(x: CGFloat) { commit(x); onRelease?() }
    var probeKnob: CALayer { knob }
}

// MARK: - Swatch

/// A round preset swatch: the color over the checker, a quiet rim, and — when
/// selected — an ink ring that springs in around it. 32 pt, a 44 pt target.
final class CCColorSwatch: UIControl {
    let preset: CCColorPreset
    var onPick: ((CCColorPreset) -> Void)?
    static let diameter: CGFloat = 32

    private let checker = CCCheckerboardLayer()
    private let fill = CALayer()
    private let shade = CALayer()
    private let ring = CAShapeLayer()

    override var isSelected: Bool {
        didSet {
            guard isSelected != oldValue else { return }
            refreshRing(animated: true)
            accessibilityTraits = isSelected ? [.button, .selected] : .button
        }
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            // Press tints in place.
            CCMotion.fade(shade, keyPath: "opacity", to: Float(isHighlighted ? 0.16 : 0), duration: isHighlighted ? 0.06 : 0.18)
        }
    }

    init(preset: CCColorPreset) {
        self.preset = preset
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        checker.square = 4
        checker.masksToBounds = true
        shade.opacity = 0
        shade.backgroundColor = UIColor.black.cgColor
        ring.fillColor = nil
        ring.lineWidth = 2
        ring.opacity = 0
        for l in [checker, fill, shade] as [CALayer] { layer.addSublayer(l) }
        layer.addSublayer(ring)
        fill.backgroundColor = preset.color.cgColor   // content: never rethemes
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 44),
            heightAnchor.constraint(equalToConstant: 44),
        ])
        isAccessibilityElement = true
        accessibilityLabel = preset.name
        accessibilityTraits = .button
        addAction(UIAction { [weak self] _ in
            guard let self else { return }
            CCHaptics.selection()
            self.onPick?(self.preset)
        }, for: .touchUpInside)
        ccOnThemeChange { [weak self] in self?.applyTheme() }
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func applyTheme() {
        let ink: UIColor = CCTheme.isDark(traitCollection) ? .white : .black
        fill.borderColor = ink.withAlphaComponent(0.18).cgColor
        fill.borderWidth = 1
        ring.strokeColor = cc(CCTheme.color.foreground)
        checker.contentsScale = max(traitCollection.displayScale, 1)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let d = Self.diameter
        let rect = CGRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [checker, fill, shade] as [CALayer] {
            l.frame = rect
            l.cornerRadius = d / 2
        }
        ring.frame = bounds
        ring.path = UIBezierPath(ovalIn: rect.insetBy(dx: -4.5, dy: -4.5)).cgPath
        CATransaction.commit()
        refreshRing(animated: false)
    }

    private func refreshRing(animated: Bool) {
        let target: Float = isSelected ? 1 : 0
        guard animated, window != nil else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            ring.opacity = target
            CATransaction.commit()
            return
        }
        CCMotion.fade(ring, keyPath: "opacity", to: target, duration: 0.16)
        if isSelected, !CCMotion.reduceMotion {
            CCMotion.spring(ring, keyPath: "transform.scale", from: 0.86, to: 1.0, .bouncy)
        }
    }

    var probeRingLayer: CALayer { ring }
}

// MARK: - Swatch grid

/// The swatches as a justified grid of 44 pt cells — as many per row as fit,
/// balanced (twelve fall into 6 + 6, never 8 + 4). Lays out in its OWN pass
/// (a parent's layoutSubviews runs before the stack sizes this view) and
/// sizes its own height.
private final class CCSwatchGrid: UIView {
    let swatches: [CCColorSwatch]
    private var heightConstraint: NSLayoutConstraint!
    static let cell: CGFloat = 44
    static let rowGap: CGFloat = 4

    init(swatches: [CCColorSwatch]) {
        self.swatches = swatches
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        swatches.forEach { $0.translatesAutoresizingMaskIntoConstraints = true; addSubview($0) }
        heightConstraint = heightAnchor.constraint(equalToConstant: Self.cell)
        heightConstraint.isActive = true
        accessibilityContainerType = .semanticGroup
        accessibilityLabel = "Swatches"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        guard width > 0, !swatches.isEmpty else { return }
        let cell = Self.cell, minGap: CGFloat = 6
        let fit = max(1, min(swatches.count, Int((width + minGap) / (cell + minGap))))
        let rows = Int(ceil(Double(swatches.count) / Double(fit)))
        let columns = Int(ceil(Double(swatches.count) / Double(rows)))
        let gap = columns > 1 ? (width - cell * CGFloat(columns)) / CGFloat(columns - 1) : 0
        for (i, swatch) in swatches.enumerated() {
            let row = i / columns, col = i % columns
            swatch.frame = CGRect(x: CGFloat(col) * (cell + gap), y: CGFloat(row) * (cell + Self.rowGap), width: cell, height: cell)
        }
        let height = CGFloat(rows) * cell + CGFloat(max(0, rows - 1)) * Self.rowGap
        if heightConstraint.constant != height { heightConstraint.constant = height }
    }
}

/// The current-color chip beside the hex field (checker under translucency).
private final class CCColorChip: CCSurface {
    let checker = CCCheckerboardLayer()
    let fill = CALayer()

    init() {
        super.init(.recessed, tint: CCTheme.color.elevated, radius: .md)
        layer.masksToBounds = true
        layer.borderWidth = 1
        checker.square = 5
        layer.addSublayer(checker)
        layer.addSublayer(fill)
        isAccessibilityElement = false
        ccOnThemeChange { [weak self] in
            guard let self else { return }
            self.layer.borderColor = self.cc(CCTheme.color.border)
            self.checker.contentsScale = max(self.traitCollection.displayScale, 1)
        }
        layer.borderColor = cc(CCTheme.color.border)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        checker.frame = bounds
        fill.frame = bounds
        CATransaction.commit()
    }
}

// MARK: - Picker body

/// The picker body (the Mac's ColorPickerPopoverView, touch scale): the house
/// swatches, then the custom controls. Every change fires `onChange`;
/// `adopt(_:)` pulls an external color in without echoing.
final class CCColorPickerView: UIView, UITextFieldDelegate {
    var onChange: ((UIColor) -> Void)?
    /// A gesture finished (finger lifted, swatch picked, hex committed).
    var onSettle: (() -> Void)?

    let supportsOpacity: Bool
    let presets: [CCColorPreset]

    private(set) var hue: Double = 0
    private(set) var saturation: Double = 0
    private(set) var brightness: Double = 1
    private(set) var opacity: Double = 1

    var color: UIColor { .ccSRGB(hue: hue, saturation: saturation, brightness: brightness, alpha: opacity) }

    private let swatches: [CCColorSwatch]
    private let swatchGrid: CCSwatchGrid
    private let customLabel = ccLabel("Custom", font: CCFont.captionMedium, color: CCTheme.color.mutedForeground)
    private let field = CCColorField()
    private let hueBar = CCColorBar(kind: .hue)
    private let opacityBar = CCColorBar(kind: .opacity)
    private let hexWell = CCSurface(.recessed, tint: CCTheme.color.elevated, radius: .md)
    private let hashLabel = ccLabel("#", font: CCFont.mono, color: CCTheme.color.faintForeground)
    private let hexField = UITextField()
    private let opacityLabel = ccLabel("100%", font: CCFont.mono, color: CCTheme.color.mutedForeground, alignment: .right)
    private let preview = CCColorChip()

    init(color: UIColor, supportsOpacity: Bool = true, presets: [CCColorPreset] = CCColorPreset.house) {
        self.supportsOpacity = supportsOpacity
        self.presets = presets
        swatches = presets.map { CCColorSwatch(preset: $0) }
        swatchGrid = CCSwatchGrid(swatches: swatches)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        for swatch in swatches {
            swatch.onPick = { [weak self] picked in
                guard let self else { return }
                self.adopt(picked.color.withAlphaComponent(self.supportsOpacity ? CGFloat(self.opacity) : 1), keepHue: true)
                self.pushColor()
                self.onSettle?()
            }
        }

        field.onChange = { [weak self] s, b in
            self?.saturation = s
            self?.brightness = b
            self?.pushColor()
        }
        field.onRelease = { [weak self] in self?.onSettle?() }
        hueBar.onChange = { [weak self] value in
            self?.hue = value
            self?.pushColor()
        }
        hueBar.onRelease = { [weak self] in self?.onSettle?() }
        opacityBar.onChange = { [weak self] value in
            self?.opacity = value
            self?.pushColor()
        }
        opacityBar.onRelease = { [weak self] in self?.onSettle?() }
        opacityBar.isHidden = !supportsOpacity
        opacityLabel.isHidden = !supportsOpacity
        opacityLabel.isAccessibilityElement = false

        hexField.font = CCFont.mono
        hexField.adjustsFontForContentSizeCategory = true
        hexField.textColor = CCTheme.color.foreground
        hexField.tintColor = CCTheme.color.foreground
        hexField.keyboardType = .asciiCapable
        hexField.autocapitalizationType = .allCharacters
        hexField.autocorrectionType = .no
        hexField.spellCheckingType = .no
        hexField.returnKeyType = .done
        hexField.delegate = self
        hexField.accessibilityLabel = "Hex color"
        hexField.translatesAutoresizingMaskIntoConstraints = false
        hashLabel.isAccessibilityElement = false
        // The "#" hugs; the field takes the well's width (equal 250 hugging
        // let the label stretch and shoved the text to the far right).
        hashLabel.setContentHuggingPriority(.required, for: .horizontal)
        hexField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        opacityLabel.setContentHuggingPriority(.required, for: .horizontal)
        opacityLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        hexWell.setContentHuggingPriority(.defaultLow, for: .horizontal)
        hexWell.addSubview(hashLabel)
        hexWell.addSubview(hexField)
        hexWell.layer.borderWidth = 1

        let hexRow = UIStackView(arrangedSubviews: [preview, hexWell, opacityLabel])
        hexRow.spacing = CCSpace.sm
        hexRow.alignment = .center
        hexRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [swatchGrid, customLabel, field, hueBar, opacityBar, hexRow])
        stack.axis = .vertical
        stack.spacing = CCSpace.md
        stack.setCustomSpacing(CCSpace.lg, after: swatchGrid)
        stack.setCustomSpacing(CCSpace.sm, after: customLabel)
        stack.setCustomSpacing(CCSpace.lg, after: field)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let fieldHeight = field.heightAnchor.constraint(equalTo: field.widthAnchor, multiplier: 0.5)
        fieldHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            fieldHeight,
            field.heightAnchor.constraint(lessThanOrEqualToConstant: 200),
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            preview.widthAnchor.constraint(equalToConstant: 44),
            preview.heightAnchor.constraint(equalToConstant: 44),
            hexWell.heightAnchor.constraint(equalToConstant: 44),
            opacityLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 48),
            hashLabel.leadingAnchor.constraint(equalTo: hexWell.leadingAnchor, constant: 14),
            hashLabel.centerYAnchor.constraint(equalTo: hexWell.centerYAnchor),
            hexField.leadingAnchor.constraint(equalTo: hashLabel.trailingAnchor, constant: 4),
            hexField.trailingAnchor.constraint(equalTo: hexWell.trailingAnchor, constant: -12),
            hexField.topAnchor.constraint(equalTo: hexWell.topAnchor),
            hexField.bottomAnchor.constraint(equalTo: hexWell.bottomAnchor),
        ])
        adopt(color, keepHue: false)
        ccOnThemeChange { [weak self] in self?.applyTheme() }
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func applyTheme() {
        hexWell.layer.borderColor = cc(CCTheme.color.border)
    }

    // MARK: Color plumbing

    private func pushColor() {
        syncSubviews()
        onChange?(color)
    }

    /// Pull an external color into the knobs (no echo). Greys and black keep
    /// the hue you were on, so the hue bar never jumps back to red.
    func adopt(_ newColor: UIColor, keepHue: Bool = true) {
        let hsba = newColor.ccHSBA
        if !(keepHue && (hsba.saturation < 0.0001 || hsba.brightness < 0.0001)) { hue = hsba.hue }
        saturation = hsba.saturation
        brightness = hsba.brightness
        opacity = supportsOpacity ? hsba.alpha : 1
        syncSubviews()
    }

    private func syncSubviews() {
        field.hue = hue
        field.saturation = saturation
        field.brightness = brightness
        hueBar.fraction = hue
        opacityBar.fraction = opacity
        opacityBar.baseColor = .ccSRGB(hue: hue, saturation: saturation, brightness: brightness)
        opacityLabel.text = "\(Int((opacity * 100).rounded()))%"
        if !hexField.isFirstResponder { hexField.text = color.ccHex }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview.fill.backgroundColor = color.cgColor
        CATransaction.commit()
        let current = color
        for swatch in swatches { swatch.isSelected = swatch.preset.color.ccSameRGB(current) }
    }

    // MARK: Hex entry

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "0123456789ABCDEFabcdef#")
        guard string.unicodeScalars.allSatisfy(allowed.contains) else { return false }
        let next = ((textField.text ?? "") as NSString).replacingCharacters(in: range, with: string)
        return next.replacingOccurrences(of: "#", with: "").count <= 6
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    func textFieldDidEndEditing(_ textField: UITextField) { commitHex(textField.text ?? "") }

    /// Apply typed hex; invalid text reverts to the current color.
    @discardableResult
    func commitHex(_ text: String) -> Bool {
        guard let picked = UIColor.ccHex(text, alpha: opacity) else {
            hexField.text = color.ccHex
            return false
        }
        adopt(picked, keepHue: true)
        hexField.text = color.ccHex
        pushColor()
        onSettle?()
        return true
    }

    // MARK: Probe seams

    var probeSwatches: [CCColorSwatch] { swatches }
    var probeField: CCColorField { field }
    var probeHueBar: CCColorBar { hueBar }
    var probeOpacityBar: CCColorBar { opacityBar }
    var probeHexText: String { hexField.text ?? "" }
    var probeOpacityText: String { opacityLabel.text ?? "" }
}

// MARK: - Well

/// The inspector's color well: a round swatch (checker under translucent
/// colors, an ink rim). Tap opens the picker — a bottom sheet on compact
/// width, a card anchored to the well on regular width. 32 pt, 44 pt target.
final class CCColorWell: UIControl {
    var onChange: ((UIColor) -> Void)?
    var onCommit: ((UIColor) -> Void)?
    var supportsOpacity: Bool { didSet { refresh() } }
    var presets: [CCColorPreset] = CCColorPreset.house
    /// The picker's title and the well's VoiceOver label.
    var title: String { didSet { accessibilityLabel = title } }

    /// Push a model color (no echo).
    var color: UIColor { didSet { refresh() } }

    static let diameter: CGFloat = 32
    private let checker = CCCheckerboardLayer()
    private let fill = CALayer()
    private let shade = CALayer()

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            CCMotion.fade(shade, keyPath: "opacity", to: Float(isHighlighted ? 0.16 : 0), duration: isHighlighted ? 0.06 : 0.18)
        }
    }

    override var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            CCMotion.fadeAlpha(self, to: isEnabled ? 1 : CCTheme.disabledAlpha, duration: 0.16)
            accessibilityTraits = isEnabled ? .button : [.button, .notEnabled]
        }
    }

    init(title: String, color: UIColor, supportsOpacity: Bool = true) {
        self.title = title
        self.color = color
        self.supportsOpacity = supportsOpacity
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        checker.square = 4
        shade.opacity = 0
        shade.backgroundColor = UIColor.black.cgColor
        for l in [checker, fill, shade] as [CALayer] {
            l.masksToBounds = true
            layer.addSublayer(l)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 44),
            heightAnchor.constraint(equalToConstant: 44),
        ])
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityTraits = .button
        accessibilityHint = "Opens the color picker"
        addAction(UIAction { [weak self] _ in self?.presentPicker() }, for: .touchUpInside)
        ccOnThemeChange { [weak self] in self?.applyTheme() }
        applyTheme()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func applyTheme() {
        let ink: UIColor = CCTheme.isDark(traitCollection) ? .white : .black
        fill.borderColor = ink.withAlphaComponent(0.25).cgColor
        fill.borderWidth = 1
        checker.contentsScale = max(traitCollection.displayScale, 1)
        checker.setNeedsDisplay()
    }

    private func refresh() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let shown = supportsOpacity ? color : color.withAlphaComponent(1)
        fill.backgroundColor = shown.cgColor
        CATransaction.commit()
        accessibilityValue = ccColorDescription(shown, presets: presets, opacity: supportsOpacity)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let d = Self.diameter
        let rect = CGRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [checker, fill, shade] as [CALayer] {
            l.frame = rect
            l.cornerRadius = d / 2
        }
        CATransaction.commit()
    }

    /// Open the picker from the nearest view controller.
    func presentPicker() {
        guard isEnabled, let presenter = ccNearestViewController() else { return }
        CCColorPicker.present(from: presenter, source: self, title: title, color: color,
                              supportsOpacity: supportsOpacity, presets: presets,
                              onChange: { [weak self] picked in
                                  self?.color = picked
                                  self?.onChange?(picked)
                              },
                              onCommit: { [weak self] picked in self?.onCommit?(picked) })
    }
}

extension UIView {
    /// The view controller that owns this view (responder chain; extension-safe).
    func ccNearestViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let r = responder {
            if let vc = r as? UIViewController { return vc }
            responder = r.next
        }
        return nil
    }
}

// MARK: - Presentation

/// Presents a CCColorPickerView: compact width → a bottom sheet that rises
/// from the bottom edge (swipe down or tap the scrim to close); regular width
/// → a floating card anchored to `source`, scaling in from it.
enum CCColorPicker {
    @discardableResult
    static func present(
        from presenter: UIViewController,
        source: UIView?,
        title: String,
        color: UIColor,
        supportsOpacity: Bool = true,
        presets: [CCColorPreset] = CCColorPreset.house,
        onChange: ((UIColor) -> Void)? = nil,
        onCommit: ((UIColor) -> Void)? = nil
    ) -> CCColorPickerController {
        let controller = CCColorPickerController(title: title, color: color, supportsOpacity: supportsOpacity,
                                                 presets: presets, source: source)
        controller.onChange = onChange
        controller.onCommit = onCommit
        CCAlert.topmost(from: presenter).present(controller, animated: false)
        return controller
    }
}

final class CCColorPickerController: UIViewController, UIGestureRecognizerDelegate {
    var onChange: ((UIColor) -> Void)?
    var onCommit: ((UIColor) -> Void)?
    let picker: CCColorPickerView
    let card = CCCard(floating: true, tint: CCTheme.color.popover, radius: .xl)
    private let pickerTitle: String
    private weak var source: UIView?
    private let scrim = UIView()
    private let initial: UIColor
    private var isFinishing = false
    private var hasEntered = false
    private var anchored: Bool { traitCollection.horizontalSizeClass == .regular && source != nil }

    init(title: String, color: UIColor, supportsOpacity: Bool, presets: [CCColorPreset], source: UIView?) {
        pickerTitle = title
        initial = color
        self.source = source
        picker = CCColorPickerView(color: color, supportsOpacity: supportsOpacity, presets: presets)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        scrim.backgroundColor = CCTheme.color.overlay
        scrim.alpha = 0
        scrim.frame = view.bounds
        scrim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrim.isAccessibilityElement = false
        view.addSubview(scrim)
        scrim.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(close)))

        let titleLabel = ccLabel(pickerTitle, font: CCFont.header, color: CCTheme.color.foreground)
        titleLabel.accessibilityTraits = .header
        let done = CCButton(title: "Done", style: .secondary, size: .sm, radius: .full)
        done.onTap = { [weak self] in self?.close() }
        let header = UIStackView(arrangedSubviews: [titleLabel, done])
        header.alignment = .center
        header.spacing = CCSpace.md
        header.translatesAutoresizingMaskIntoConstraints = false
        picker.onChange = { [weak self] color in self?.onChange?(color) }

        card.accessibilityViewIsModal = true
        card.alpha = 0
        card.addSubview(header)
        card.addSubview(picker)
        view.addSubview(card)
        let pad = CCSpace.lg + 4
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: pad),
            header.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -pad + 4),
            header.topAnchor.constraint(equalTo: card.topAnchor, constant: CCSpace.md + 2),
            picker.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: pad),
            picker.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -pad),
            picker.topAnchor.constraint(equalTo: header.bottomAnchor, constant: CCSpace.md),
            picker.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -pad),
            card.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: CCSpace.sm),
            card.bottomAnchor.constraint(lessThanOrEqualTo: view.keyboardLayoutGuide.topAnchor, constant: -CCSpace.sm),
        ])
        if anchored { layoutAnchored() } else { layoutSheet() }
    }

    private func layoutSheet() {
        let fill = card.widthAnchor.constraint(equalTo: view.safeAreaLayoutGuide.widthAnchor, constant: -CCSpace.sm * 2)
        fill.priority = .required - 1
        let bottom = card.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -CCSpace.sm)
        bottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
            fill, bottom,
        ])
        let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)
    }

    /// Only a drag that starts on the card's header strip (or the scrim)
    /// dismisses — the spectra below own their own drags.
    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        let y = gesture.location(in: card).y
        return y < 64 || !card.bounds.contains(gesture.location(in: card))
    }

    private func layoutAnchored() {
        guard let source else { return }
        view.layoutIfNeeded()
        let frame = source.convert(source.bounds, to: view)
        let width: CGFloat = 340
        let x = min(max(frame.midX - width / 2, CCSpace.lg), view.bounds.width - width - CCSpace.lg)
        let below = frame.maxY + 8
        let estimated = picker.systemLayoutSizeFitting(CGSize(width: width - 40, height: 0),
                                                       withHorizontalFittingPriority: .required,
                                                       verticalFittingPriority: .fittingSizeLevel).height + 90
        var constraints = [
            card.widthAnchor.constraint(equalToConstant: width),
            card.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: x),
        ]
        if view.bounds.height - below - view.safeAreaInsets.bottom > estimated {
            constraints.append(card.topAnchor.constraint(equalTo: view.topAnchor, constant: below))
        } else {
            let above = card.bottomAnchor.constraint(equalTo: view.topAnchor, constant: frame.minY - 8)
            above.priority = .defaultHigh
            constraints.append(above)
        }
        NSLayoutConstraint.activate(constraints)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasEntered else { return }
        hasEntered = true
        CCMotion.fadeAlpha(scrim, to: anchored ? 0.5 : 1, duration: 0.2, from: 0)
        CCMotion.fadeAlpha(card, to: 1, duration: 0.16, from: 0)
        if anchored {
            CCMotion.enter(card.layer, .scaleIn)
        } else if !CCMotion.reduceMotion {
            let travel = view.bounds.height - card.frame.minY
            CCMotion.spring(card.layer, keyPath: "transform.translation.y", from: travel, to: 0, .arrive)
        }
        UIAccessibility.post(notification: .screenChanged, argument: card)
    }

    override func accessibilityPerformEscape() -> Bool { close(); return true }

    @objc private func pan(_ gesture: UIPanGestureRecognizer) {
        let dy = max(0, gesture.translation(in: view).y)
        switch gesture.state {
        case .changed:
            card.transform = CGAffineTransform(translationX: 0, y: dy)
            scrim.alpha = max(0, 1 - dy / 300)
        case .ended, .cancelled:
            if dy > 90 || gesture.velocity(in: view).y > 800 {
                close()
            } else {
                CCMotion.springViews(.snappy) {
                    self.card.transform = .identity
                    self.scrim.alpha = 1
                }
            }
        default:
            break
        }
    }

    @objc func close() {
        guard !isFinishing else { return }
        isFinishing = true
        view.endEditing(true)
        let final = picker.color
        CCMotion.fadeAlpha(scrim, to: 0, duration: 0.18)
        if anchored {
            CCMotion.exit(card.layer, .scaleIn)
            CCMotion.fadeAlpha(card, to: 0, duration: 0.14)
        } else {
            let travel = view.bounds.height - card.frame.minY
            CCMotion.run(duration: 0.22, curve: .glide) {
                self.card.transform = CGAffineTransform(translationX: 0, y: travel)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + CCMotion.paced(0.2)) { [weak self] in
            guard let self else { return }
            let changed = !final.ccSameRGB(self.initial) || abs(final.ccSRGBA.a - self.initial.ccSRGBA.a) > 0.001
            let commit = self.onCommit
            self.dismiss(animated: false) { if changed { commit?(final) } }
        }
    }
}
