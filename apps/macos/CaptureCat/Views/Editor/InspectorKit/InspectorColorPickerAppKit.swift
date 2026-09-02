import AppKit

// Native AppKit twin of the SwiftUI ColorPickerPopover. Same 208pt bubble, same
// 11pt padding, same stack: saturation/brightness square, hue bar, optional
// opacity bar, preset row, hex field.
//
// COLOR SPACE: everything here is sRGB. The SwiftUI original composed its result
// with `Color(hue:saturation:brightness:)` (sRGB) but formatted the hex readout
// through `NSColor(hue:...)`, which is CALIBRATED RGB — so the printed hex drifted
// from the swatch it described. Both paths go through `NSColor.srgb(hue:...)` here,
// which makes the readout agree with the color for the first time. The composed
// color itself is unchanged, so stored projects are unaffected.

// MARK: - sRGB HSB

extension NSColor {
    /// HSB → sRGB, done by hand because every AppKit HSB initialiser lands in
    /// calibrated RGB instead.
    static func srgb(hue: Double, saturation: Double, brightness: Double, alpha: Double) -> NSColor {
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
        return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: alpha)
    }

    /// sRGB → HSB. Returns zeroed components rather than trapping if the color
    /// cannot be converted (pattern colors, mainly).
    var srgbHSBA: (hue: Double, saturation: Double, brightness: Double, alpha: Double) {
        guard let c = usingColorSpace(.sRGB) else { return (0, 0, 1, 1) }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return (Double(h), Double(s), Double(b), Double(a))
    }
}

// MARK: - Saturation / brightness square

/// White→hue horizontally, clear→black vertically, with a draggable knob.
/// Click anywhere to jump there, then keep dragging — same as the SwiftUI
/// `DragGesture(minimumDistance: 0)`.
private final class SaturationBrightnessSquare: NSView {
    var hue: Double = 0 { didSet { refreshGradients() } }
    var saturation: Double = 0 { didSet { needsLayout = true } }
    var brightness: Double = 1 { didSet { needsLayout = true } }
    /// Fires continuously through the drag with the new (saturation, brightness).
    var onChange: ((Double, Double) -> Void)?

    private let hueGradient = OklabGradientLayer()
    /// Both ends are black, so alpha-only ramps interpolate the same in sRGB as
    /// in Oklab — a plain CAGradientLayer is exact here.
    private let shadeGradient = CAGradientLayer()
    private let knob = CALayer()
    private var themeObservation: CCThemeObservation?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = CCTheme.radius(.md)
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1

        // The SV spectrum itself is content and never rethemes; only the
        // chrome (border, knob ring) follows the theme.
        shadeGradient.startPoint = CGPoint(x: 0.5, y: 0)
        shadeGradient.endPoint = CGPoint(x: 0.5, y: 1)
        shadeGradient.colors = [
            NSColor.black.withAlphaComponent(0).cgColor,
            NSColor.black.cgColor,
        ]

        knob.borderWidth = 2
        knob.shadowColor = NSColor.black.withAlphaComponent(0.5).cgColor
        knob.shadowOpacity = 1
        knob.shadowRadius = 1
        knob.shadowOffset = .zero

        layer?.addSublayer(hueGradient)
        layer?.addSublayer(shadeGradient)
        layer?.addSublayer(knob)
        refreshGradients()
        themeObservation = CCThemeObservation { [weak self] in
            let ink: NSColor = CCTheme.isDark ? .white : .black
            self?.layer?.borderColor = ink.withAlphaComponent(0.08).cgColor
            self?.knob.borderColor = ink.cgColor
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func refreshGradients() {
        hueGradient.set(
            from: NSColor.white.srgba,
            to: NSColor.srgb(hue: hue, saturation: 1, brightness: 1, alpha: 1).srgba
        )
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hueGradient.frame = bounds
        shadeGradient.frame = bounds
        let size: CGFloat = 14
        knob.frame = CGRect(
            x: saturation * bounds.width - size / 2,
            y: (1 - brightness) * bounds.height - size / 2,
            width: size, height: size
        )
        knob.cornerRadius = size / 2
        knob.backgroundColor = NSColor
            .srgb(hue: hue, saturation: saturation, brightness: brightness, alpha: 1).cgColor
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) { commit(event) }
    override func mouseDragged(with event: NSEvent) { commit(event) }
    override func mouseUp(with event: NSEvent) { commit(event) }

    private func commit(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let s = min(1, max(0, Double(p.x / max(1, bounds.width))))
        let b = min(1, max(0, 1 - Double(p.y / max(1, bounds.height))))
        saturation = s
        brightness = b
        onChange?(s, b)
    }
}

// MARK: - Hue / opacity bars

/// Capsule bar with a stroke-only knob. Subclassed for hue and opacity so both
/// share the geometry, the hit-testing and the knob.
private class ColorBarView: NSView {
    var fraction: Double = 0 { didSet { needsLayout = true } }
    var onChange: ((Double) -> Void)?

    let knob = CALayer()
    private static let knobSize: CGFloat = 12
    private var themeObservation: CCThemeObservation?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        knob.borderWidth = 2
        knob.shadowColor = NSColor.black.withAlphaComponent(0.5).cgColor
        knob.shadowOpacity = 1
        knob.shadowRadius = 1
        knob.shadowOffset = .zero
        // Knob ring is chrome; the bar's spectrum underneath is content.
        themeObservation = CCThemeObservation { [weak self] in
            self?.knob.borderColor = (CCTheme.isDark ? NSColor.white : .black).cgColor
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = bounds.height / 2
        let size = Self.knobSize
        knob.frame = CGRect(
            x: fraction * max(0, bounds.width - size),
            y: bounds.midY - size / 2,
            width: size, height: size
        )
        knob.cornerRadius = size / 2
        layoutBar()
        CATransaction.commit()
    }

    /// Subclass hook — lay out the gradient/checker layers under the knob.
    func layoutBar() {}

    override func mouseDown(with event: NSEvent) { commit(event) }
    override func mouseDragged(with event: NSEvent) { commit(event) }
    override func mouseUp(with event: NSEvent) { commit(event) }

    private func commit(_ event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        // The SwiftUI bar mapped raw x/width, knob width included — keep that so
        // the reachable range is identical.
        let f = min(1, max(0, Double(x / max(1, bounds.width))))
        fraction = f
        onChange?(f)
    }
}

private final class HueBarView: ColorBarView {
    private let gradient = OklabGradientLayer()

    override init() {
        super.init()
        // Seven evenly-spaced stops, each PAIR interpolated in Oklab — the same
        // ramp `LinearGradient(colors:)` produces from the same seven colors.
        gradient.stops = (0...6).map { i in
            (
                location: CGFloat(i) / 6,
                color: NSColor.srgb(hue: Double(i) / 6, saturation: 1, brightness: 1, alpha: 1).srgba
            )
        }
        layer?.addSublayer(gradient)
        layer?.addSublayer(knob)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutBar() { gradient.frame = bounds }
}

private final class OpacityBarView: ColorBarView {
    /// The opaque end of the ramp — the currently composed color at alpha 1.
    var baseColor: NSColor = .white { didSet { refreshGradient() } }

    private let checker = CheckerboardLayer()
    private let gradient = OklabGradientLayer()

    override init() {
        super.init()
        checker.square = 5
        layer?.addSublayer(checker)
        layer?.addSublayer(gradient)
        layer?.addSublayer(knob)
        refreshGradient()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func refreshGradient() {
        // `OklabGradient.mix` weights the Lab coordinates by alpha, which is how
        // SwiftUI ramps a color to transparent — a straight sRGB fade is ~11/255
        // off through the middle of the ramp.
        gradient.set(
            from: baseColor.withAlphaComponent(0).srgba,
            to: baseColor.withAlphaComponent(1).srgba
        )
    }

    override func layoutBar() {
        checker.frame = bounds
        checker.setNeedsDisplay()
        gradient.frame = bounds
    }
}

// MARK: - Preset swatch

private final class PresetSwatchControl: NSControl {
    var onPick: ((NSColor) -> Void)?
    private let color: NSColor
    private var themeObservation: CCThemeObservation?

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 14, height: 14) }

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        // The preset color itself is content; only the border rim rethemes.
        layer?.backgroundColor = color.cgColor
        layer?.borderWidth = 1
        themeObservation = CCThemeObservation { [weak self] in
            let ink: NSColor = CCTheme.isDark ? .white : .black
            self?.layer?.borderColor = ink.withAlphaComponent(0.18).cgColor
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPick?(color)
    }
}

// MARK: - Popover body

/// The picker body, sized to a fixed 208pt width like the SwiftUI original.
/// Hosted by `InspectorColorWellControl` inside the shared transient panel.
@MainActor
final class ColorPickerPopoverView: NSView, NSTextFieldDelegate {
    /// Fires on every knob move, preset tap and committed hex.
    var onChange: ((NSColor) -> Void)?

    static let width: CGFloat = 208
    private static let padding: CGFloat = 11
    private static let spacing: CGFloat = 9
    private static let squareHeight: CGFloat = 108
    private static let barHeight: CGFloat = 10
    private static let presetSize: CGFloat = 14

    private static let presets: [NSColor] = [
        .white,
        NSColor(srgbRed: 0.75, green: 0.75, blue: 0.75, alpha: 1),
        NSColor(srgbRed: 0.45, green: 0.45, blue: 0.45, alpha: 1),
        .black,
        NSColor(srgbRed: 1.00, green: 0.84, blue: 0.20, alpha: 1), // yellow
        NSColor(srgbRed: 1.00, green: 0.42, blue: 0.30, alpha: 1), // coral
        NSColor(srgbRed: 0.98, green: 0.31, blue: 0.55, alpha: 1), // pink
        NSColor(srgbRed: 0.65, green: 0.45, blue: 0.98, alpha: 1), // violet
        NSColor(srgbRed: 0.62, green: 0.66, blue: 0.92, alpha: 1), // periwinkle (accent)
        NSColor(srgbRed: 0.25, green: 0.62, blue: 1.00, alpha: 1), // blue
        NSColor(srgbRed: 0.25, green: 0.85, blue: 0.62, alpha: 1), // green
        NSColor(srgbRed: 1.00, green: 0.62, blue: 0.25, alpha: 1), // orange
    ]

    private let supportsOpacity: Bool
    private let square = SaturationBrightnessSquare()
    private let hueBar = HueBarView()
    private let opacityBar = OpacityBarView()
    private let presetRow = NSView()
    private let hexContainer = NSView()
    private let hexField = NSTextField()

    private var hue: Double = 0
    private var saturation: Double = 0
    private var brightness: Double = 1
    private var alpha: Double = 1

    private let hashLabel = NSTextField(labelWithString: "#")
    private var themeObservation: CCThemeObservation?

    override var isFlipped: Bool { true }

    init(color: NSColor, supportsOpacity: Bool) {
        self.supportsOpacity = supportsOpacity
        super.init(frame: .zero)
        wantsLayer = true

        square.onChange = { [weak self] s, b in
            self?.saturation = s
            self?.brightness = b
            self?.pushColor()
        }
        hueBar.onChange = { [weak self] value in
            self?.hue = value
            self?.square.hue = value
            self?.pushColor()
        }
        opacityBar.onChange = { [weak self] value in
            self?.alpha = value
            self?.pushColor()
        }

        addSubview(square)
        addSubview(hueBar)
        if supportsOpacity { addSubview(opacityBar) }

        for preset in Self.presets {
            let swatch = PresetSwatchControl(color: preset)
            swatch.onPick = { [weak self] picked in
                self?.adopt(picked)
                self?.pushColor()
            }
            presetRow.addSubview(swatch)
        }
        addSubview(presetRow)

        hexContainer.wantsLayer = true
        hexContainer.layer?.cornerRadius = CCTheme.radius(.md)
        hexContainer.layer?.cornerCurve = .continuous
        hexContainer.layer?.borderWidth = 1

        let hash = hashLabel
        hash.font = .systemFont(ofSize: 11, weight: .medium)
        hash.translatesAutoresizingMaskIntoConstraints = false

        hexField.isBezeled = false
        hexField.isBordered = false
        hexField.drawsBackground = false
        hexField.focusRingType = .none
        hexField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        hexField.placeholderString = "FFFFFF"
        hexField.delegate = self
        hexField.target = self
        hexField.action = #selector(hexSubmitted)
        hexField.translatesAutoresizingMaskIntoConstraints = false

        hexContainer.addSubview(hash)
        hexContainer.addSubview(hexField)
        addSubview(hexContainer)
        NSLayoutConstraint.activate([
            hash.leadingAnchor.constraint(equalTo: hexContainer.leadingAnchor, constant: 7),
            hash.centerYAnchor.constraint(equalTo: hexContainer.centerYAnchor),
            hexField.leadingAnchor.constraint(equalTo: hash.trailingAnchor, constant: 5),
            hexField.trailingAnchor.constraint(equalTo: hexContainer.trailingAnchor, constant: -7),
            hexField.centerYAnchor.constraint(equalTo: hexContainer.centerYAnchor),
        ])

        adopt(color)
        frame = NSRect(origin: .zero, size: intrinsicContentSize)
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Popover shell chrome only — the spectra, swatches and composed color
    /// are content and never retheme.
    private func applyTheme() {
        let ink: NSColor = CCTheme.isDark ? .white : .black
        layer?.backgroundColor = EditorThemeKit.panelElevated.cgColor
        hexContainer.layer?.backgroundColor = ink.withAlphaComponent(0.06).cgColor
        hexContainer.layer?.borderColor = ink.withAlphaComponent(0.07).cgColor
        hashLabel.textColor = ink.withAlphaComponent(0.4)
        hexField.textColor = ink.withAlphaComponent(0.9)
    }

    // MARK: Layout

    /// Hex row height: one 11pt line plus the row's 4pt vertical padding.
    ///
    /// The line metric is `NSAttributedString.size().height` — the same measure
    /// `RasterGoldenHarness.baselineProbe` pinned SwiftUI's text box to (size 11
    /// → 14.0). `boundingRectForFont` runs 3pt tall and both
    /// `ascender - descender` and `NSLayoutManager.defaultLineHeight` run 1pt
    /// short; because this is the LAST row in the stack, either error shifts the
    /// whole popover rather than showing up locally.
    private var hexRowHeight: CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let line = NSAttributedString(string: "H", attributes: [.font: font]).size().height
        return ceil(line) + 8
    }

    override var intrinsicContentSize: NSSize {
        let p = Self.padding
        let s = Self.spacing
        var h = p + Self.squareHeight + s + Self.barHeight
        if supportsOpacity { h += s + Self.barHeight }
        // `.padding(.top, 1)` on the preset row.
        h += s + 1 + Self.presetSize
        h += s + hexRowHeight + p
        return NSSize(width: Self.width, height: h)
    }

    override func layout() {
        super.layout()
        let p = Self.padding
        let s = Self.spacing
        let contentWidth = bounds.width - p * 2
        var y = p

        square.frame = NSRect(x: p, y: y, width: contentWidth, height: Self.squareHeight)
        y += Self.squareHeight + s

        hueBar.frame = NSRect(x: p, y: y, width: contentWidth, height: Self.barHeight)
        y += Self.barHeight + s

        if supportsOpacity {
            opacityBar.frame = NSRect(x: p, y: y, width: contentWidth, height: Self.barHeight)
            y += Self.barHeight + s
        }

        y += 1
        presetRow.frame = NSRect(x: p, y: y, width: contentWidth, height: Self.presetSize)
        layoutPresets(in: contentWidth)
        y += Self.presetSize + s

        hexContainer.frame = NSRect(x: p, y: y, width: contentWidth, height: hexRowHeight)
    }

    /// `HStack(spacing: 0)` with a `Spacer(minLength: 0)` between every pair:
    /// first swatch flush left, last flush right, equal gaps between.
    private func layoutPresets(in width: CGFloat) {
        let swatches = presetRow.subviews
        guard swatches.count > 1 else {
            swatches.first?.frame = NSRect(x: 0, y: 0, width: Self.presetSize, height: Self.presetSize)
            return
        }
        let size = Self.presetSize
        let gap = (width - size * CGFloat(swatches.count)) / CGFloat(swatches.count - 1)
        for (i, swatch) in swatches.enumerated() {
            swatch.frame = NSRect(x: CGFloat(i) * (size + gap), y: 0, width: size, height: size)
        }
    }

    // MARK: Color plumbing

    private var composedColor: NSColor {
        .srgb(hue: hue, saturation: saturation, brightness: brightness, alpha: alpha)
    }

    private func pushColor() {
        syncSubviews()
        onChange?(composedColor)
    }

    /// Pull an external color into the knobs. Never echoes `onChange` — the
    /// SwiftUI original guarded the same feedback loop with `isInternalChange`.
    func adopt(_ color: NSColor) {
        let hsba = color.srgbHSBA
        hue = hsba.hue
        saturation = hsba.saturation
        brightness = hsba.brightness
        alpha = supportsOpacity ? hsba.alpha : 1
        syncSubviews()
    }

    private func syncSubviews() {
        square.hue = hue
        square.saturation = saturation
        square.brightness = brightness
        hueBar.fraction = hue
        opacityBar.fraction = alpha
        opacityBar.baseColor = .srgb(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
        // Never overwrite what the user is mid-way through typing.
        if window?.firstResponder !== hexField.currentEditor() {
            hexField.stringValue = currentHex
        }
    }

    private var currentHex: String {
        let c = NSColor.srgb(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
        return String(
            format: "%02X%02X%02X",
            Int((c.redComponent * 255).rounded()),
            Int((c.greenComponent * 255).rounded()),
            Int((c.blueComponent * 255).rounded())
        )
    }

    // MARK: Backing scale

    // Layers added by hand do NOT inherit the view's contentsScale the way a
    // view's own backing layer does, so anything that implements `draw(in:)`
    // (the Oklab ramps, the alpha checkerboards) rasterises at 1x until it is
    // told otherwise — visible as soft gradients on a Retina display.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyBackingScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyBackingScale()
    }

    private func applyBackingScale() {
        let scale = window?.backingScaleFactor ?? 2
        func walk(_ layer: CALayer) {
            if layer.delegate == nil, layer.contentsScale != scale {
                layer.contentsScale = scale
                layer.setNeedsDisplay()
            }
            layer.sublayers?.forEach(walk)
        }
        if let root = layer { walk(root) }
    }

    // MARK: Harness hooks

    /// Row frames top-to-bottom, for `--raster-golden`'s structural assertion.
    func debugRowFrames() -> [CGRect] {
        var rows = [square.frame, hueBar.frame]
        if supportsOpacity { rows.append(opacityBar.frame) }
        rows.append(presetRow.frame)
        rows.append(hexContainer.frame)
        return rows.sorted { $0.minY < $1.minY }
    }

    func debugPresetFrames() -> [CGRect] {
        presetRow.subviews.map(\.frame).sorted { $0.minX < $1.minX }
    }

    func debugHexText() -> String { currentHex }

    /// The SwiftUI original left its hex field empty until `.onAppear`; blanking
    /// this one lets the raster gate compare chrome against chrome.
    func debugClearHexText() { hexField.stringValue = "" }

    @objc private func hexSubmitted() {
        var text = hexField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else {
            hexField.stringValue = currentHex
            return
        }
        let picked = NSColor(
            srgbRed: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            alpha: alpha
        )
        adopt(picked)
        pushColor()
    }
}
