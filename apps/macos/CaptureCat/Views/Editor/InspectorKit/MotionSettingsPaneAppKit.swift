import AppKit

/// The Motion tab as a native AppKit pane — twin of MotionSettingsView,
/// context-sensitive: global motion settings when no EFFECTS block is
/// selected, the selected block's Zoom/Tilt editors when one is.
@MainActor
final class MotionSettingsPaneAppKit: NSView {
    private let settings: ProjectSettings
    private var context: MotionPaneContext

    private let stack = NSStackView()

    // Global mode: the full Effects list (slide/parallax/blur toggles +
    // add-at-playhead) — ONE Effects concept, whether or not a block is
    // selected.
    let effectsPane: EffectsSettingsPaneAppKit
    private var globalViews: [NSView] = []

    // Block sections (always visible; details follow the selected block)
    // Below 1.0 the "zoom" is a SCALE-DOWN: the card shrinks toward the focal
    // point — scale is an effect, timed on the EFFECTS lane like any zoom.
    // Every control's title/range/step/readout, write and visibility: the
    // shared EffectBlocksPane spec (Studio/Editor/Inspector).
    private let blockZoomSlider = InspectorSliderRow(EffectBlocksPane.zoomLevel)
    private let zoomPreviewPad = EffectPreviewPadControl()
    private let followCursorToggle = InspectorToggleControl(EffectBlocksPane.followCursor)
    /// Per-block animation style — the "Screen Animation Style" control:
    /// Default follows the project speed; Snappy pops, Slow Glide and
    /// Cinematic ease in without any bounce.
    private let blockStyleMenu = InspectorMenuControl(EffectBlocksPane.zoomSpeed)
    private var blockStyleRow: NSView!
    /// Aim the zoom: where the push-in points, 0…1 in video space. THIS is
    /// how an "offset at an angle" opening is composed — the card's rest
    /// placement stays put and the excursion lives in the block, so the end
    /// of the effect always lands back home.
    private let focusPad = ZoomFocusPadControl()
    /// Card position excursion during the block — slides the whole card away
    /// from its home and back on the block's spring.
    private let offsetPad = ZoomFocusPadControl(title: "Offset")
    private let blockZoomCaption = InspectorKitViews.captionLine(EffectBlocksPane.zoomCaption)
    /// Section toggles — every effect on a block switches on and off here.
    private let zoomToggle = InspectorToggleControl(EffectBlocksPane.zoomToggle)
    private let tiltToggle = InspectorToggleControl(EffectBlocksPane.tiltToggle)
    private var zoomViews: [NSView] = []

    private let tiltPad = TiltPadControl()
    /// One-click skew presets — the fastest route to a good-looking tilt.
    private let tiltPresetChips = InspectorChipsControl(EffectBlocksPane.tiltPreset)
    private let tiltStyleMenu = InspectorMenuControl(EffectBlocksPane.tiltSpeed)
    private var tiltStyleRow: NSView!
    private let rotationSlider = InspectorSliderRow(EffectBlocksPane.rotation)
    private let tiltCaption = InspectorKitViews.captionLine(EffectBlocksPane.tiltCaption)
    /// One-click "reference look": deep push-in with a gentle pitch-back and a
    /// whisper of rotation. The depth comes from PITCH — big roll values are
    /// what make zoom+tilt look broken.
    private let cinematicButton = InspectorButton(EffectBlocksPane.cinematic)
    private let tiltButtonRow = NSStackView()
    private var tiltViews: [NSView] = []

    // Highlight section
    private let highlightOpacitySlider = InspectorSliderRow(EffectBlocksPane.highlightOpacity)
    private let highlightPad = PropertyPreviewPadControl()
    private let highlightCaption = InspectorKitViews.captionLine(EffectBlocksPane.highlightCaption)
    private let removeHighlightButton = InspectorButton(EffectBlocksPane.removeHighlight)
    private var highlightViews: [NSView] = []

    // Depth Focus section
    private let depthFocusStyleChips = InspectorChipsControl(EffectBlocksPane.depthStyleChoice)
    private let depthFocusStrengthSlider = InspectorSliderRow(EffectBlocksPane.depthStrength)
    private let depthFocusFalloffSlider = InspectorSliderRow(EffectBlocksPane.depthFalloff)
    private let depthFocusCornerSlider = InspectorSliderRow(EffectBlocksPane.depthCorner)
    private let depthFocusAngleSlider = InspectorSliderRow(EffectBlocksPane.depthAngle)
    private let depthFocusCaption = InspectorKitViews.captionLine(EffectBlocksPane.depthCaption)
    private let removeDepthFocusButton = InspectorButton(EffectBlocksPane.removeDepth)
    private var depthFocusViews: [NSView] = []

    // Blur section
    private let blurStyleChips = InspectorChipsControl(EffectBlocksPane.blurStyleChoice)
    private let blurStrengthSlider = InspectorSliderRow(EffectBlocksPane.blurStrength)
    private let blurAnimatedToggle = InspectorToggleControl(EffectBlocksPane.blurAnimated)
    private let blurCaption = InspectorKitViews.captionLine(EffectBlocksPane.blurCaption)
    private let removeBlurButton = InspectorButton(EffectBlocksPane.removeBlur)
    private var blurViews: [NSView] = []

    override var isFlipped: Bool { true }

    init(project: Project, context: MotionPaneContext) {
        self.settings = project.settings
        self.context = context
        self.effectsPane = EffectsSettingsPaneAppKit(project: project)
        super.init(frame: .zero)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])

        build()
        wire()
        effectsPane.onSlideEnabled = { [weak self] in
            self?.context.onJoinSlideToSelectedBlock() ?? false
        }
        observe()
        update(context: context)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        func fullWidth(_ view: NSView) {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        fullWidth(effectsPane)
        globalViews = [effectsPane]

        let zoomBox = InspectorSectionBox("Zoom")
        zoomBox.addRow(zoomToggle)
        zoomBox.addRow(blockZoomSlider)
        blockStyleRow = InspectorKitViews.row(EffectBlocksPane.zoomSpeed.title, control: blockStyleMenu)
        zoomBox.addRow(blockStyleRow)
        zoomBox.addRow(zoomPreviewPad, attached: true)
        zoomPreviewPad.heightAnchor.constraint(equalToConstant: 96).isActive = true
        zoomBox.addRow(followCursorToggle)
        focusPad.inspectorSpecID = "blocks.focusPad"
        offsetPad.inspectorSpecID = "blocks.offsetPad"
        tiltPad.inspectorSpecID = "blocks.tiltPad"
        zoomBox.addRow(focusPad)
        focusPad.heightAnchor.constraint(equalToConstant: 132).isActive = true
        zoomBox.addRow(offsetPad)
        offsetPad.heightAnchor.constraint(equalToConstant: 132).isActive = true
        zoomBox.addRow(blockZoomCaption, attached: true)
        fullWidth(zoomBox)
        zoomViews = [blockZoomSlider, blockStyleRow, zoomPreviewPad, followCursorToggle, focusPad, offsetPad, blockZoomCaption]

        let tiltBox = InspectorSectionBox("Tilt")
        tiltBox.addRow(tiltToggle)
        tiltBox.addRow(tiltPad)
        tiltBox.addRow(tiltPresetChips, attached: true)
        tiltBox.addRow(rotationSlider)
        tiltStyleRow = InspectorKitViews.row(EffectBlocksPane.tiltSpeed.title, control: tiltStyleMenu)
        tiltBox.addRow(tiltStyleRow)
        tiltButtonRow.orientation = .horizontal
        tiltButtonRow.spacing = 8
        tiltButtonRow.addArrangedSubview(cinematicButton)
        tiltBox.addRow(tiltButtonRow)
        tiltBox.addRow(tiltCaption, attached: true)
        fullWidth(tiltBox)
        tiltViews = [tiltPad, tiltPresetChips, rotationSlider, tiltStyleRow, tiltCaption, tiltButtonRow]

        let highlightBox = InspectorSectionBox("Highlight Mask")
        highlightBox.addRow(highlightOpacitySlider)
        highlightBox.addRow(highlightPad, attached: true)
        highlightPad.heightAnchor.constraint(equalToConstant: 96).isActive = true
        highlightBox.addRow(highlightCaption, attached: true)
        highlightBox.addRow(removeHighlightButton)
        fullWidth(highlightBox)
        highlightViews = [highlightBox]

        let depthFocusBox = InspectorSectionBox("Depth Focus")
        depthFocusBox.addRow(depthFocusStyleChips)
        depthFocusBox.addRow(depthFocusStrengthSlider)
        depthFocusBox.addRow(depthFocusFalloffSlider)
        depthFocusBox.addRow(depthFocusCornerSlider)
        depthFocusBox.addRow(depthFocusAngleSlider)
        depthFocusBox.addRow(depthFocusCaption, attached: true)
        depthFocusBox.addRow(removeDepthFocusButton)
        fullWidth(depthFocusBox)
        depthFocusViews = [depthFocusBox]

        let blurBox = InspectorSectionBox("Blur")
        blurBox.addRow(blurStyleChips)
        blurBox.addRow(blurStrengthSlider)
        blurBox.addRow(blurAnimatedToggle)
        blurBox.addRow(blurCaption, attached: true)
        blurBox.addRow(removeBlurButton)
        fullWidth(blurBox)
        blurViews = [blurBox]
    }

    /// The pane's scope for the shared spec: the selected block through the
    /// current context (rebuilt per use, so it always sees the latest one).
    private var scope: InspectorScope {
        InspectorScope(settings: settings, motion: context)
    }

    private func wire() {
        let scope: () -> InspectorScope? = { [weak self] in self?.scope }
        blockZoomSlider.bind(EffectBlocksPane.zoomLevel, scope)
        followCursorToggle.bind(EffectBlocksPane.followCursor, scope)
        blockStyleMenu.bind(EffectBlocksPane.zoomSpeed, scope)
        focusPad.onChange = { [weak self] focal in
            guard let self else { return }
            EffectBlocksPane.focus(self.scope, fx: focal.x, fy: focal.y)
        }
        offsetPad.onChange = { [weak self] point in
            guard let self else { return }
            // Pad 0…1 maps to the full excursion range; dead-centre means none.
            EffectBlocksPane.offset(self.scope, point: point)
        }
        zoomToggle.bind(EffectBlocksPane.zoomToggle, scope)
        tiltToggle.bind(EffectBlocksPane.tiltToggle, scope)

        tiltPad.onChange = { [weak self] pitch, yaw in
            guard let self else { return }
            EffectBlocksPane.tilt(self.scope, pitch: pitch, yaw: yaw)
            self.refreshBlockUI()
        }
        rotationSlider.onChange = { [weak self] v in
            guard let self else { return }
            EffectBlocksPane.rotation.write(self.scope, v)
            self.tiltPad.roll = v
        }
        tiltPresetChips.bind(EffectBlocksPane.tiltPreset, scope)
        tiltStyleMenu.bind(EffectBlocksPane.tiltSpeed, scope)
        cinematicButton.bind(EffectBlocksPane.cinematic, scope)

        highlightOpacitySlider.bind(EffectBlocksPane.highlightOpacity, scope)
        removeHighlightButton.bind(EffectBlocksPane.removeHighlight, scope)

        depthFocusStyleChips.onSelect = { [weak self] i in
            guard let self else { return }
            EffectBlocksPane.depthStyleChoice.write(self.scope, i)
            self.refreshBlockUI()
        }
        depthFocusStrengthSlider.bind(EffectBlocksPane.depthStrength, scope)
        depthFocusFalloffSlider.bind(EffectBlocksPane.depthFalloff, scope)
        depthFocusCornerSlider.bind(EffectBlocksPane.depthCorner, scope)
        depthFocusAngleSlider.bind(EffectBlocksPane.depthAngle, scope)
        removeDepthFocusButton.bind(EffectBlocksPane.removeDepth, scope)

        blurStyleChips.onSelect = { [weak self] i in
            guard let self else { return }
            EffectBlocksPane.blurStyleChoice.write(self.scope, i)
            self.refreshBlockUI()
        }
        blurStrengthSlider.bind(EffectBlocksPane.blurStrength, scope)
        blurAnimatedToggle.bind(EffectBlocksPane.blurAnimated, scope)
        removeBlurButton.bind(EffectBlocksPane.removeBlur, scope)
    }

    /// Called from the bridge on every SwiftUI update — fresh bindings and
    /// (possibly) different selection.
    func update(context: MotionPaneContext) {
        self.context = context
        refreshBlockUI()
    }

    private func observe() {
        withObservationTracking { [weak self] in
            self?.applySettings()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observe()
            }
        }
    }

    private func applySettings() {}

    private func refreshBlockUI() {
        let zoom = context.zoomRegion.wrappedValue
        let tilt = context.tiltRegion.wrappedValue
        let highlight = context.highlightRegion.wrappedValue
        let depthFocus = context.focusRegion.wrappedValue
        let blur = context.blurRegion.wrappedValue

        // ONE flat Effects list, always. Zoom/Tilt toggles are always there:
        // on a selected block they stack that effect onto it; with nothing
        // selected they drop a block at the playhead. Their detail controls
        // follow the selected block.
        for v in zoomViews { v.isHidden = zoom == nil }
        for v in tiltViews { v.isHidden = tilt == nil }
        for v in highlightViews { v.isHidden = highlight == nil }
        for v in depthFocusViews { v.isHidden = depthFocus == nil }
        for v in blurViews { v.isHidden = blur == nil }
        let scope = self.scope
        if blur != nil {
            blurStyleChips.selectedIndex = EffectBlocksPane.blurStyleChoice.read(scope) ?? 0
            blurStrengthSlider.setValue(EffectBlocksPane.blurStrength.read(scope))
            blurAnimatedToggle.isOn = EffectBlocksPane.blurAnimated.read(scope)
            // Animation only means something for the mosaic.
            blurAnimatedToggle.isHidden = !EffectBlocksPane.blurAnimated.visible(scope)
        }
        if depthFocus != nil {
            depthFocusStyleChips.selectedIndex = EffectBlocksPane.depthStyleChoice.read(scope) ?? 0
            depthFocusStrengthSlider.setValue(EffectBlocksPane.depthStrength.read(scope))
            depthFocusFalloffSlider.setValue(EffectBlocksPane.depthFalloff.read(scope))
            depthFocusCornerSlider.setValue(EffectBlocksPane.depthCorner.read(scope))
            depthFocusAngleSlider.setValue(EffectBlocksPane.depthAngle.read(scope))
            // Angle is tilt-shift-only; corner radius is Area-only.
            depthFocusAngleSlider.isHidden = !EffectBlocksPane.depthAngle.visible(scope)
            depthFocusCornerSlider.isHidden = !EffectBlocksPane.depthCorner.visible(scope)
        }
        zoomToggle.isOn = zoom != nil
        tiltToggle.isOn = tilt != nil

        if let zoom {
            blockZoomSlider.setValue(zoom.zoomLevel)
            let style = zoom.animationStyle
            zoomPreviewPad.mode = .zoom(
                level: zoom.zoomLevel,
                omegaMultiplier: style?.omegaMultiplier ?? 1,
                damping: style?.damping ?? 0.88)
            followCursorToggle.isOn = EffectBlocksPane.followCursor.read(scope)
            blockStyleMenu.selectedIndex = EffectBlocksPane.zoomSpeed.read(scope) ?? 0
            focusPad.focal = zoom.focalPoint
            offsetPad.focal = EffectBlocksPane.offsetPoint(scope)
        }
        if let tilt {
            tiltPad.set(pitch: tilt.pitch, yaw: tilt.yaw, roll: tilt.roll)
            rotationSlider.setValue(tilt.roll)
            tiltStyleMenu.selectedIndex = EffectBlocksPane.tiltSpeed.read(scope) ?? 0
        }
        if let highlight {
            highlightOpacitySlider.setValue(highlight.opacity)
            highlightPad.mode = .highlightMask(opacity: highlight.opacity)
        }
    }
}

// MARK: - Motion speed demo pad

/// Loops a zoom-in / release on the EXACT spring the preview and exporter use
/// (ω = 2.5/duration, ζ = 0.88). Native twin of MotionSpeedPreviewPad.
@MainActor
final class MotionSpeedPadControl: NSView {
    var duration: Double = 0.8

    private let card = CALayer()
    private var cardContent: [CALayer] = []
    /// Wash alpha per cardContent layer (3 dots, then 3 lines) — reused by
    /// applyTheme so a theme flip re-tints them at the same strengths.
    private static let cardContentAlphas: [CGFloat] = [0.28, 0.28, 0.28, 0.28, 0.16, 0.16]
    private var timer: Timer?
    private var themeObservation: CCThemeObservation?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        card.cornerRadius = 5
        card.cornerCurve = .continuous
        layer?.addSublayer(card)

        // Traffic lights + text lines inside the mini window.
        for i in 0..<3 {
            let dot = CALayer()
            dot.frame = CGRect(x: 8 + CGFloat(i) * 7, y: 8, width: 4, height: 4)
            dot.cornerRadius = 2
            card.addSublayer(dot)
            cardContent.append(dot)
        }
        let widths: [CGFloat] = [30, 46, 38]
        for i in 0..<3 {
            let line = CALayer()
            line.cornerRadius = 1.5
            line.frame = CGRect(x: 8, y: 18 + CGFloat(i) * 7.5, width: widths[i], height: 3.5)
            card.addSublayer(line)
            cardContent.append(line)
        }

        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }

        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let window = self.window,
                      window.occlusionState.contains(.visible),
                      !self.isHiddenOrHasHiddenAncestor else { return }
                self.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    required init?(coder: NSCoder) { fatalError() }

    private func applyTheme() {
        let ink: NSColor = CCTheme.isDark ? .white : .black
        layer?.backgroundColor = ink.withAlphaComponent(0.06).cgColor
        layer?.borderColor = ink.withAlphaComponent(0.12).cgColor
        layer?.cornerRadius = CCTheme.radius(.lg)
        card.backgroundColor = ink.withAlphaComponent(0.10).cgColor
        for (layer, alpha) in zip(cardContent, Self.cardContentAlphas) {
            layer.backgroundColor = ink.withAlphaComponent(alpha).cgColor
        }
    }

    deinit { timer?.invalidate() }

    /// Analytic response of the real zoom spring (ω = 2.5/animDur, ζ = 0.88).
    private static func springResponse(_ u: Double, animDur: Double) -> Double {
        guard u > 0 else { return 0 }
        let omega = 2.5 / animDur
        let zeta = 0.88
        let damped = omega * (1 - zeta * zeta).squareRoot()
        return 1 - exp(-zeta * omega * u)
            * (cos(damped * u) + (zeta * omega / damped) * sin(damped * u))
    }

    private static func demoZoom(at t: Double, cycle: Double, animDur: Double) -> Double {
        let half = cycle / 2
        return t < half
            ? 1 + 0.5 * springResponse(t - 0.2, animDur: animDur)
            : 1 + 0.5 * (1 - springResponse(t - half - 0.2, animDur: animDur))
    }

    private func tick() {
        let size = bounds.size
        guard size.width > 1 else { return }
        let animDur = max(0.2, duration)
        let cycle = max(2.4, animDur * 2 + 1.2)
        let t = CACurrentMediaTime().truncatingRemainder(dividingBy: cycle)
        let zoom = Self.demoZoom(at: t, cycle: cycle, animDur: animDur)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let w = size.width * 0.44
        let h = size.height * 0.62
        card.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        card.position = CGPoint(x: size.width / 2, y: size.height / 2)
        // scaleEffect(zoom, anchor: (0.38, 0.42)) — replicate via anchorPoint.
        card.anchorPoint = CGPoint(x: 0.38, y: 0.42)
        card.position = CGPoint(
            x: size.width / 2 - w / 2 + w * 0.38,
            y: size.height / 2 - h / 2 + h * 0.42
        )
        card.transform = CATransform3DMakeScale(zoom, zoom, 1)
        CATransaction.commit()
    }
}

// MARK: - Tilt pad

/// 2D skew pad (an XY pad for the 3D tilt) — native twin of TiltPadView. Drag sets
/// yaw (x) + pitch (y); the mini card warps with the REAL TiltMath homography;
/// double-click resets.
@MainActor
final class TiltPadControl: NSView {
    var onChange: ((Double, Double) -> Void)?
    var roll: Double = 0 { didSet { applyCardTransform() } }

    private(set) var pitch: Double = 0
    private(set) var yaw: Double = 0

    /// 60° lets the card flatten almost edge-on; past that the homography's
    /// perspective divide gets degenerate at the card corners. Panes with a
    /// subtler effect (e.g. the camera bubble tilt, ±25) may lower this.
    var maxAngle: Double = 60
    private let padHeight: CGFloat = 120

    private let titleLabel = NSTextField(labelWithString: "Skew")
    private let valuePill = NSTextField(labelWithString: "0° / 0°")
    private let pillBackground = NSView()
    private let padArea = PadArea()
    private var themeObservation: CCThemeObservation?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)

        titleLabel.font = EditorThemeKit.label()
        valuePill.font = EditorThemeKit.valuePill()
        pillBackground.wantsLayer = true
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }

        padArea.owner = self

        for v in [titleLabel, pillBackground, valuePill, padArea] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: topAnchor),

            valuePill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            valuePill.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            pillBackground.leadingAnchor.constraint(equalTo: valuePill.leadingAnchor, constant: -7),
            pillBackground.trailingAnchor.constraint(equalTo: valuePill.trailingAnchor, constant: 7),
            pillBackground.topAnchor.constraint(equalTo: valuePill.topAnchor, constant: -2.5),
            pillBackground.bottomAnchor.constraint(equalTo: valuePill.bottomAnchor, constant: 2.5),

            padArea.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            padArea.leadingAnchor.constraint(equalTo: leadingAnchor),
            padArea.trailingAnchor.constraint(equalTo: trailingAnchor),
            padArea.heightAnchor.constraint(equalToConstant: padHeight),
            padArea.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func applyTheme() {
        titleLabel.textColor = EditorThemeKit.textPrimary
        valuePill.textColor = EditorThemeKit.textSecondary
        let ink: NSColor = CCTheme.isDark ? .white : .black
        pillBackground.layer?.backgroundColor = ink.withAlphaComponent(0.07).cgColor
        padArea.applyTheme()
    }

    override func layout() {
        super.layout()
        pillBackground.layer?.cornerRadius = pillBackground.bounds.height / 2
    }

    func set(pitch: Double, yaw: Double, roll: Double) {
        self.pitch = pitch
        self.yaw = yaw
        self.roll = roll
        refresh()
    }

    #if DEBUG
    /// Probe seam: press the pad at (fx, fy) of its half-extents
    /// (x right, y up, −1…1) through the pad area's real mouse handlers.
    func probePress(fx: Double, fy: Double) {
        let size = padArea.bounds.size
        let point = NSPoint(x: size.width / 2 + CGFloat(fx) * max(1, size.width / 2 - 10),
                            y: size.height / 2 - CGFloat(fy) * max(1, size.height / 2 - 10))
        guard let window = padArea.window else { return }
        let location = padArea.convert(point, to: nil)
        // The pad commits on press (and drag); a release does nothing.
        if let event = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 0,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                          clickCount: 1, pressure: 1) {
            padArea.mouseDown(with: event)
        }
    }
    #endif

    fileprivate func drag(to point: NSPoint) {
        let size = padArea.bounds.size
        let fx = (point.x - size.width / 2) / max(1, size.width / 2 - 10)
        let fy = (size.height / 2 - point.y) / max(1, size.height / 2 - 10)
        // Clamp + whole-degree rounding: InspectorPadMath, shared with iOS.
        (pitch, yaw) = InspectorPadMath.tiltAngles(fx: Double(fx), fy: Double(fy), maxAngle: maxAngle)
        refresh()
        onChange?(pitch, yaw)
    }

    fileprivate func reset() {
        pitch = 0
        yaw = 0
        refresh()
        onChange?(0, 0)
    }

    private func refresh() {
        valuePill.stringValue = String(format: "%.0f° / %.0f°", pitch, yaw)
        padArea.knobFraction = InspectorPadMath.tiltKnobFraction(pitch: pitch, yaw: yaw, maxAngle: maxAngle)
        applyCardTransform()
        padArea.needsLayout = true
    }

    private func applyCardTransform() {
        padArea.setCardTilt(pitch: pitch, yaw: yaw, roll: roll)
    }

    /// The interactive square: crosshair, warped mini card, drag knob.
    fileprivate final class PadArea: NSView {
        weak var owner: TiltPadControl?
        var knobFraction = CGPoint(x: 0.5, y: 0.5)

        private let crosshairV = CALayer()
        private let crosshairH = CALayer()
        private let cardHost = CALayer()   // static frame; sublayerTransform warps
        private let card = MiniTiltCardLayer()
        private let knob = CALayer()

        override var isFlipped: Bool { true }

        init() {
            super.init(frame: .zero)
            wantsLayer = true
            layer?.borderWidth = 1
            layer?.cornerCurve = .continuous

            for line in [crosshairV, crosshairH] {
                layer?.addSublayer(line)
            }
            cardHost.addSublayer(card)
            layer?.addSublayer(cardHost)
            knob.shadowColor = NSColor.black.withAlphaComponent(0.4).cgColor
            knob.shadowOpacity = 1
            knob.shadowRadius = 2
            layer?.addSublayer(knob)
            applyTheme()
        }

        required init?(coder: NSCoder) { fatalError() }

        /// Re-tinted by the owner's theme observation (one token per control).
        func applyTheme() {
            let ink: NSColor = CCTheme.isDark ? .white : .black
            layer?.backgroundColor = ink.withAlphaComponent(0.06).cgColor
            layer?.borderColor = ink.withAlphaComponent(0.12).cgColor
            layer?.cornerRadius = CCTheme.radius(.lg)
            for line in [crosshairV, crosshairH] {
                line.backgroundColor = ink.withAlphaComponent(0.15).cgColor
            }
            knob.backgroundColor = CCTheme.color.foreground.cgColor
        }

        func setCardTilt(pitch: Double, yaw: Double, roll: Double) {
            // The SAME homography the preview/export use, centered on the
            // card (center: .zero + CA's center anchor = TiltMath's own
            // conjugation about the card midpoint).
            let projection = TiltMath.projectionTransform(
                pitchDegrees: pitch, yawDegrees: yaw, rollDegrees: roll,
                center: .zero,
                distance: TiltMath.perspectiveDistance(for: MiniTiltCardLayer.cardSize)
            )
            card.transform = CATransform3D(projection)
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            crosshairV.frame = CGRect(x: bounds.midX - 0.5, y: 6, width: 1, height: bounds.height - 12)
            crosshairH.frame = CGRect(x: 6, y: bounds.midY - 0.5, width: bounds.width - 12, height: 1)
            cardHost.frame = bounds
            card.bounds = CGRect(origin: .zero, size: MiniTiltCardLayer.cardSize)
            card.position = CGPoint(x: bounds.midX, y: bounds.midY)
            let knobX = bounds.width * knobFraction.x
            let knobY = bounds.height * knobFraction.y
            // Match SwiftUI: knob travels within 10pt margins.
            let usableHalfW = bounds.width / 2 - 10
            let usableHalfH = bounds.height / 2 - 10
            let cx = bounds.midX + (knobFraction.x - 0.5) * 2 * usableHalfW
            let cy = bounds.midY + (knobFraction.y - 0.5) * 2 * usableHalfH
            _ = (knobX, knobY)
            knob.frame = CGRect(x: cx - 6, y: cy - 6, width: 12, height: 12)
            knob.cornerRadius = 6
            CATransaction.commit()
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                owner?.reset()
                return
            }
            owner?.drag(to: convert(event.locationInWindow, from: nil))
        }

        override func mouseDragged(with event: NSEvent) {
            owner?.drag(to: convert(event.locationInWindow, from: nil))
        }
    }
}

/// Miniature "screen card" — native twin of MiniTiltCard: white gradient card
/// with faux content lines, warped by the real homography via CATransform3D.
final class MiniTiltCardLayer: CALayer {
    static let cardSize = CGSize(width: 64, height: 40)

    private let gradient = CAGradientLayer()

    override init() {
        super.init()
        shadowColor = NSColor.black.withAlphaComponent(0.35).cgColor
        shadowOpacity = 1
        shadowRadius = 3
        shadowOffset = CGSize(width: 0, height: 2)

        gradient.colors = [
            NSColor.white.withAlphaComponent(0.9).cgColor,
            NSColor.white.withAlphaComponent(0.55).cgColor,
        ]
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        gradient.cornerRadius = 4
        gradient.cornerCurve = .continuous
        gradient.frame = CGRect(origin: .zero, size: Self.cardSize)
        addSublayer(gradient)

        let widths: [CGFloat] = [26, 40, 34]
        let alphas: [CGFloat] = [0.25, 0.15, 0.15]
        for i in 0..<3 {
            let line = CALayer()
            line.backgroundColor = NSColor.black.withAlphaComponent(alphas[i]).cgColor
            line.cornerRadius = 1
            line.frame = CGRect(x: 6, y: 6 + CGFloat(i) * 6, width: widths[i], height: 3)
            gradient.addSublayer(line)
        }
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }
}

// CATransform3D(ProjectionTransform) moved to TiltMath.swift (shared with
// the P4 preview compositor).


/// 2D focal-aim pad for a zoom block — a dot on a 16:9 miniature of the
/// video; drag to point the push-in. 0…1 in video space, Y-down (top-left of
/// the pad is the video's top-left).
@MainActor
final class ZoomFocusPadControl: NSView {
    var onChange: ((CGPoint) -> Void)?
    var focal = CGPoint(x: 0.5, y: 0.5) { didSet { needsDisplay = true; refreshPill() } }

    private let titleLabel: NSTextField
    private let valuePill = NSTextField(labelWithString: "50% / 50%")
    private let pillBackground = NSView()
    private var themeObservation: CCThemeObservation?

    override var isFlipped: Bool { true }

    init(title: String = "Focus") {
        titleLabel = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        titleLabel.font = EditorThemeKit.label()
        valuePill.font = EditorThemeKit.valuePill()
        pillBackground.wantsLayer = true
        pillBackground.layer?.cornerRadius = 5
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
        for v in [titleLabel, pillBackground, valuePill] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: topAnchor),
            valuePill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            valuePill.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            pillBackground.leadingAnchor.constraint(equalTo: valuePill.leadingAnchor, constant: -7),
            pillBackground.trailingAnchor.constraint(equalTo: valuePill.trailingAnchor, constant: 7),
            pillBackground.topAnchor.constraint(equalTo: valuePill.topAnchor, constant: -2.5),
            pillBackground.bottomAnchor.constraint(equalTo: valuePill.bottomAnchor, constant: 2.5),
        ])
        refreshPill()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func applyTheme() {
        titleLabel.textColor = EditorThemeKit.textPrimary
        valuePill.textColor = EditorThemeKit.textSecondary
        let ink: NSColor = CCTheme.isDark ? .white : .black
        pillBackground.layer?.backgroundColor = ink.withAlphaComponent(0.07).cgColor
        needsDisplay = true
    }

    private func refreshPill() {
        valuePill.stringValue = "\(Int((focal.x * 100).rounded()))% / \(Int((focal.y * 100).rounded()))%"
    }

    private var padRect: CGRect {
        let top: CGFloat = 26
        return CGRect(x: 0, y: top, width: bounds.width, height: max(1, bounds.height - top))
    }

    override func draw(_ dirtyRect: NSRect) {
        // Pad chrome sits on the panel background → theme ink (live at
        // draw time; theme changes invalidate every window).
        let ink: NSColor = CCTheme.isDark ? .white : .black
        let pad = padRect
        let bg = NSBezierPath(roundedRect: pad, xRadius: 8, yRadius: 8)
        ink.withAlphaComponent(0.06).setFill()
        bg.fill()
        ink.withAlphaComponent(0.12).setStroke()
        bg.lineWidth = 1
        bg.stroke()

        // Crosshair thirds — framing guides.
        ink.withAlphaComponent(0.08).setStroke()
        for fx in [1.0 / 3.0, 2.0 / 3.0] {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: pad.minX + pad.width * fx, y: pad.minY + 4))
            line.line(to: NSPoint(x: pad.minX + pad.width * fx, y: pad.maxY - 4))
            line.stroke()
            let hline = NSBezierPath()
            hline.move(to: NSPoint(x: pad.minX + 4, y: pad.minY + pad.height * fx))
            hline.line(to: NSPoint(x: pad.maxX - 4, y: pad.minY + pad.height * fx))
            hline.stroke()
        }

        let dot = NSPoint(
            x: pad.minX + pad.width * focal.x,
            y: pad.minY + pad.height * focal.y
        )
        let ring = NSBezierPath(ovalIn: NSRect(x: dot.x - 8, y: dot.y - 8, width: 16, height: 16))
        ink.withAlphaComponent(0.25).setFill()
        ring.fill()
        let center = NSBezierPath(ovalIn: NSRect(x: dot.x - 4.5, y: dot.y - 4.5, width: 9, height: 9))
        CCTheme.color.foreground.setFill()
        center.fill()
    }

    #if DEBUG
    /// Probe seam: the point a press must land on for pad fraction (fx, fy).
    func probePoint(fx: CGFloat, fy: CGFloat) -> NSPoint {
        let pad = padRect
        return NSPoint(x: pad.minX + fx * pad.width, y: pad.minY + fy * pad.height)
    }
    #endif

    private func apply(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let pad = padRect
        guard pad.width > 1, pad.height > 1 else { return }
        focal = InspectorPadMath.focal(fx: (p.x - pad.minX) / pad.width, fy: (p.y - pad.minY) / pad.height)
        onChange?(focal)
    }

    override func mouseDown(with event: NSEvent) { apply(event) }
    override func mouseDragged(with event: NSEvent) { apply(event) }
}
