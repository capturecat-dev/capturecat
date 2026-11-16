import AppKit

/// The Cursor tab as a native AppKit pane — twin of CursorSettingsView.
@MainActor
final class CursorSettingsPaneAppKit: NSView {
    private let settings: ProjectSettings
    /// Whether the CURRENT project has captured keystroke timings.
    var hasKeystrokeData: Bool = true { didSet { apply() } }

    private let stack = NSStackView()
    private let previewBox: CursorPreviewBoxControl
    // Every control's title/range/step/readout, write and visibility: the
    // shared CursorPane spec (Studio/Editor/Inspector).
    private let showToggle = InspectorToggleControl(CursorPane.show)
    private let styleMenu = InspectorMenuControl(CursorPane.style)
    private let sizeSlider = InspectorSliderRow(CursorPane.size)
    // Fluid movement (CursorSpringMath) — demoed live in the preview box.
    // (The tilt/stretch/drag/weight pose sliders were cut: fluid movement is
    // the one motion treatment the product needs, and it's on by default. The
    // pose math survives in CursorPhysicsMath, inert at its zero defaults.)
    private let fluidToggle = InspectorToggleControl(CursorPane.fluidToggle)
    private let tensionSlider = InspectorSliderRow(CursorPane.tension)
    private let tensionCaption = InspectorKitViews.caption(CursorPane.tensionCaption)
    private let frictionSlider = InspectorSliderRow(CursorPane.friction)
    private let frictionCaption = InspectorKitViews.caption(CursorPane.frictionCaption)
    private let massSlider = InspectorSliderRow(CursorPane.mass)
    private let massCaption = InspectorKitViews.caption(CursorPane.massCaption)
    private let autoHideToggle = InspectorToggleControl(CursorPane.autoHide)
    private let loopToggle = InspectorToggleControl(CursorPane.loop)
    private let stopEndToggle = InspectorToggleControl(CursorPane.stopAtEnd)
    private let endCaption = InspectorKitViews.caption(CursorPane.endCaption)
    private let hideAfterSlider = InspectorSliderRow(CursorPane.hideAfter)
    private let smoothToggle = InspectorToggleControl(CursorPane.smooth)
    private let smoothingSlider = InspectorSliderRow(CursorPane.smoothing)
    private let rippleToggle = InspectorToggleControl(CursorPane.rippleToggle)
    private let rippleSizeSlider = InspectorSliderRow(CursorPane.rippleSize)
    private let rippleColorWell = InspectorColorWellControl()
    private var rippleColorRow: NSView!
    private let clickSoundToggle = InspectorToggleControl(CursorPane.clickSoundToggle)
    private let clickStyleMenu = InspectorMenuControl(CursorPane.clickStyle)
    private let clickTestButton = InspectorButton(CursorPane.clickTest)
    private var clickStyleRow: NSView!
    private let clickVolumeSlider = InspectorSliderRow(CursorPane.clickVolume)
    private var clickSoundCaption: NSView!
    private var keyNoDataCaption: NSView!
    private let keySoundToggle = InspectorToggleControl(CursorPane.keySoundToggle)
    private let keyStyleMenu = InspectorMenuControl(CursorPane.keyStyle)
    private let keyTestButton = InspectorButton(CursorPane.keyTest)
    private var keyStyleRow: NSView!
    private let keyVolumeSlider = InspectorSliderRow(CursorPane.keyVolume)
    private var keyCaption: NSView!
    private var keyPermissionCaption: NSView!
    private let keyPermissionButton = InspectorButton("Request Permission")
    /// Whether the CURRENT project recorded shortcut identity (opt-in).
    var hasShortcutData: Bool = false { didSet { apply() } }
    /// Whether the CURRENT project is a single-window recording — the only
    /// case where scoping the overlay to the recorded app means anything.
    var isWindowRecording: Bool = false { didSet { apply() } }
    private let keystrokeOverlayToggle = InspectorToggleControl(CursorPane.keystrokeOverlay)
    private let keystrokePositionMenu = InspectorMenuControl(CursorPane.keystrokePosition)
    private var keystrokePositionRow: NSView!
    private let keystrokeAnimationMenu = InspectorMenuControl(CursorPane.keystrokeAnimation)
    private var keystrokeAnimationRow: NSView!
    private let keystrokeSizeSlider = InspectorSliderRow(CursorPane.keystrokeSize)
    private let keystrokeScopeToggle = InspectorToggleControl(CursorPane.keystrokeScope)
    private var keystrokeScopeCaption: NSView!
    private var keystrokeNoDataCaption: NSView!
    private var keystrokeCaption: NSView!

    override var isFlipped: Bool { true }

    init(settings: ProjectSettings) {
        self.settings = settings
        self.previewBox = CursorPreviewBoxControl(settings: settings)
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
        observe()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        func fullWidth(_ view: NSView) {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let cursorBox = InspectorSectionBox("Cursor")
        cursorBox.addRow(previewBox)
        previewBox.heightAnchor.constraint(equalToConstant: 110).isActive = true
        cursorBox.addRow(showToggle)
        // The Mac menu shows each style's cursor image beside its name.
        styleMenu.items = ProjectSettings.CursorStyle.allCases.map {
            .init(title: $0.rawValue, icon: CursorStyleProvider.asset(for: $0).image)
        }
        cursorBox.addRow(InspectorKitViews.row(CursorPane.style.title, control: styleMenu))
        cursorBox.addRow(sizeSlider)
        fullWidth(cursorBox)

        let motionBox = InspectorSectionBox("Motion")
        motionBox.addRow(fluidToggle)
        motionBox.addRow(tensionSlider)
        motionBox.addRow(tensionCaption, attached: true)
        motionBox.addRow(frictionSlider)
        motionBox.addRow(frictionCaption, attached: true)
        motionBox.addRow(massSlider)
        motionBox.addRow(massCaption, attached: true)
        motionBox.addRow(smoothToggle)
        motionBox.addRow(smoothingSlider)
        fullWidth(motionBox)

        let behaviorBox = InspectorSectionBox("Behavior")
        behaviorBox.addRow(autoHideToggle)
        behaviorBox.addRow(hideAfterSlider)
        behaviorBox.addRow(loopToggle)
        behaviorBox.addRow(stopEndToggle)
        behaviorBox.addRow(endCaption, attached: true)
        fullWidth(behaviorBox)

        let clickBox = InspectorSectionBox("Click Effect")
        clickBox.addRow(rippleToggle)
        clickBox.addRow(rippleSizeSlider)
        rippleColorRow = InspectorKitViews.row(CursorPane.rippleColor.title, control: rippleColorWell)
        clickBox.addRow(rippleColorRow)

        clickBox.addRow(clickSoundToggle)
        let styleControls = NSStackView(views: [clickStyleMenu, clickTestButton])
        styleControls.orientation = .horizontal
        styleControls.spacing = 8
        clickStyleRow = InspectorKitViews.row(CursorPane.clickStyle.title, control: styleControls)
        clickBox.addRow(clickStyleRow)
        clickBox.addRow(clickVolumeSlider)
        clickSoundCaption = InspectorKitViews.captionLine(CursorPane.clickCaption)
        clickBox.addRow(clickSoundCaption, attached: true)
        fullWidth(clickBox)

        let keyBox = InspectorSectionBox("Keyboard Sounds")
        keyBox.addRow(keySoundToggle)
        let keyControls = NSStackView(views: [keyStyleMenu, keyTestButton])
        keyControls.orientation = .horizontal
        keyControls.spacing = 8
        keyStyleRow = InspectorKitViews.row(CursorPane.keyStyle.title, control: keyControls)
        keyBox.addRow(keyStyleRow)
        keyBox.addRow(keyVolumeSlider)
        keyNoDataCaption = InspectorKitViews.caption(CursorPane.keyNoDataCaption)
        keyBox.addRow(keyNoDataCaption, attached: true)
        keyCaption = InspectorKitViews.captionLine(CursorPane.keyCaption)
        keyBox.addRow(keyCaption, attached: true)
        keyPermissionCaption = InspectorKitViews.caption(CursorPane.keyPermissionCaption)
        keyBox.addRow(keyPermissionCaption)
        keyBox.addRow(keyPermissionButton, attached: true)
        fullWidth(keyBox)

        let overlayBox = InspectorSectionBox("Shortcut Overlay")
        overlayBox.addRow(keystrokeOverlayToggle)
        keystrokePositionRow = InspectorKitViews.row(CursorPane.keystrokePosition.title, control: keystrokePositionMenu)
        overlayBox.addRow(keystrokePositionRow)
        keystrokeAnimationRow = InspectorKitViews.row(CursorPane.keystrokeAnimation.title, control: keystrokeAnimationMenu)
        overlayBox.addRow(keystrokeAnimationRow)
        overlayBox.addRow(keystrokeSizeSlider)
        overlayBox.addRow(keystrokeScopeToggle)
        keystrokeScopeCaption = InspectorKitViews.captionLine(CursorPane.keystrokeScopeCaption)
        overlayBox.addRow(keystrokeScopeCaption, attached: true)
        keystrokeNoDataCaption = InspectorKitViews.caption(CursorPane.keystrokeNoDataCaption)
        overlayBox.addRow(keystrokeNoDataCaption, attached: true)
        keystrokeCaption = InspectorKitViews.captionLine(CursorPane.keystrokeCaption)
        overlayBox.addRow(keystrokeCaption, attached: true)
        fullWidth(overlayBox)
    }

    #if DEBUG
    static var probeKeystrokePermission: Bool?
    #endif

    /// The pane's scope for the shared spec (built per use — cheap).
    private var scope: InspectorScope {
        var env = InspectorEnvironment()
        env.hasKeystrokeData = hasKeystrokeData
        env.hasShortcutData = hasShortcutData
        env.isWindowRecording = isWindowRecording
        env.hasKeystrokePermission = KeystrokeTracker.hasPermission
        #if DEBUG
        // Probe seam: the values test pins the permission (it varies per Mac).
        if let pinned = Self.probeKeystrokePermission { env.hasKeystrokePermission = pinned }
        #endif
        return InspectorScope(settings: settings, env: env)
    }

    private func wire() {
        let scope: () -> InspectorScope? = { [weak self] in self?.scope }
        showToggle.bind(CursorPane.show, scope)
        styleMenu.bind(CursorPane.style, scope)
        sizeSlider.bind(CursorPane.size, scope)
        fluidToggle.bind(CursorPane.fluidToggle, scope)
        tensionSlider.bind(CursorPane.tension, scope)
        frictionSlider.bind(CursorPane.friction, scope)
        massSlider.bind(CursorPane.mass, scope)
        autoHideToggle.bind(CursorPane.autoHide, scope)
        loopToggle.bind(CursorPane.loop, scope)
        stopEndToggle.bind(CursorPane.stopAtEnd, scope)
        hideAfterSlider.bind(CursorPane.hideAfter, scope)
        smoothToggle.bind(CursorPane.smooth, scope)
        smoothingSlider.bind(CursorPane.smoothing, scope)
        rippleToggle.bind(CursorPane.rippleToggle, scope)
        rippleSizeSlider.bind(CursorPane.rippleSize, scope)
        rippleColorWell.bind(CursorPane.rippleColor, scope, requireSRGB: true)
        clickSoundToggle.bind(CursorPane.clickSoundToggle, scope)
        clickStyleMenu.bind(CursorPane.clickStyle, scope)
        clickTestButton.bind(CursorPane.clickTest, scope)
        clickVolumeSlider.bind(CursorPane.clickVolume, scope)
        keySoundToggle.bind(CursorPane.keySoundToggle, scope)
        keyStyleMenu.bind(CursorPane.keyStyle, scope)
        keyTestButton.bind(CursorPane.keyTest, scope)
        keyVolumeSlider.bind(CursorPane.keyVolume, scope)
        keyPermissionButton.onClick = {
            KeystrokeTracker.requestPermission()
        }
        keystrokeOverlayToggle.bind(CursorPane.keystrokeOverlay, scope)
        keystrokePositionMenu.bind(CursorPane.keystrokePosition, scope)
        keystrokeAnimationMenu.bind(CursorPane.keystrokeAnimation, scope)
        keystrokeSizeSlider.bind(CursorPane.keystrokeSize, scope)
        keystrokeScopeToggle.bind(CursorPane.keystrokeScope, scope)
    }

    private func observe() {
        withObservationTracking { [weak self] in
            self?.apply()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observe()
            }
        }
    }

    private func apply() {
        let scope = self.scope
        showToggle.isOn = CursorPane.show.read(scope)
        styleMenu.selectedIndex = CursorPane.style.read(scope) ?? 0
        sizeSlider.setValue(CursorPane.size.read(scope))
        fluidToggle.isOn = CursorPane.fluidToggle.read(scope)
        tensionSlider.isHidden = !CursorPane.tension.visible(scope)
        frictionSlider.isHidden = !CursorPane.friction.visible(scope)
        massSlider.isHidden = !CursorPane.mass.visible(scope)
        tensionCaption.isHidden = !CursorPane.tensionCaption.visible(scope)
        frictionCaption.isHidden = !CursorPane.frictionCaption.visible(scope)
        massCaption.isHidden = !CursorPane.massCaption.visible(scope)
        tensionSlider.setValue(CursorPane.tension.read(scope))
        frictionSlider.setValue(CursorPane.friction.read(scope))
        massSlider.setValue(CursorPane.mass.read(scope))
        autoHideToggle.isOn = CursorPane.autoHide.read(scope)
        loopToggle.isOn = CursorPane.loop.read(scope)
        stopEndToggle.isOn = CursorPane.stopAtEnd.read(scope)
        hideAfterSlider.isHidden = !CursorPane.hideAfter.visible(scope)
        hideAfterSlider.setValue(CursorPane.hideAfter.read(scope))
        smoothToggle.isOn = CursorPane.smooth.read(scope)
        smoothingSlider.isHidden = !CursorPane.smoothing.visible(scope)
        smoothingSlider.setValue(CursorPane.smoothing.read(scope))
        rippleToggle.isOn = CursorPane.rippleToggle.read(scope)
        rippleSizeSlider.isHidden = !CursorPane.rippleSize.visible(scope)
        rippleSizeSlider.setValue(CursorPane.rippleSize.read(scope))
        rippleColorRow.isHidden = !CursorPane.rippleColor.visible(scope)
        rippleColorWell.refresh()
        clickSoundToggle.isOn = CursorPane.clickSoundToggle.read(scope)
        clickStyleRow.isHidden = !CursorPane.clickStyle.visible(scope)
        clickStyleMenu.selectedIndex = CursorPane.clickStyle.read(scope) ?? 0
        clickVolumeSlider.isHidden = !CursorPane.clickVolume.visible(scope)
        clickVolumeSlider.setValue(CursorPane.clickVolume.read(scope))
        clickSoundCaption.isHidden = !CursorPane.clickCaption.visible(scope)
        keySoundToggle.isOn = CursorPane.keySoundToggle.read(scope)
        keyStyleRow.isHidden = !CursorPane.keyStyle.visible(scope)
        keyStyleMenu.selectedIndex = CursorPane.keyStyle.read(scope) ?? 0
        keyVolumeSlider.isHidden = !CursorPane.keyVolume.visible(scope)
        keyVolumeSlider.setValue(CursorPane.keyVolume.read(scope))
        keyNoDataCaption.isHidden = !CursorPane.keyNoDataCaption.visible(scope)
        keyCaption.isHidden = !CursorPane.keyCaption.visible(scope)
        keyPermissionCaption.isHidden = !CursorPane.keyPermissionCaption.visible(scope)
        keyPermissionButton.isHidden = !CursorPane.keyPermissionVisible(scope)
        keystrokeOverlayToggle.isOn = CursorPane.keystrokeOverlay.read(scope)
        keystrokePositionRow.isHidden = !CursorPane.keystrokePosition.visible(scope)
        keystrokePositionMenu.selectedIndex = CursorPane.keystrokePosition.read(scope) ?? 0
        keystrokeAnimationRow.isHidden = !CursorPane.keystrokeAnimation.visible(scope)
        keystrokeAnimationMenu.selectedIndex = CursorPane.keystrokeAnimation.read(scope) ?? 0
        keystrokeSizeSlider.isHidden = !CursorPane.keystrokeSize.visible(scope)
        keystrokeSizeSlider.setValue(CursorPane.keystrokeSize.read(scope))
        keystrokeScopeToggle.isHidden = !CursorPane.keystrokeScope.visible(scope)
        keystrokeScopeToggle.isOn = CursorPane.keystrokeScope.read(scope)
        keystrokeScopeCaption.isHidden = !CursorPane.keystrokeScopeCaption.visible(scope)
        keystrokeNoDataCaption.isHidden = !CursorPane.keystrokeNoDataCaption.visible(scope)
        keystrokeCaption.isHidden = !CursorPane.keystrokeCaption.visible(scope)
        previewBox.refreshFromSettings()
    }
}

/// Looping live preview of the cursor treatment — native twin of
/// CursorPreviewBox: glide (pace ∝ smoothing), click ripple with the same
/// ring recipe, auto-hide fade. Driven by a 30fps timer off CACurrentMediaTime.
@MainActor
final class CursorPreviewBoxControl: NSView {
    private let settings: ProjectSettings

    private let loopDuration: Double = 3.0
    private let rippleDuration: Double = 0.45

    // NSImageView (not raw layer contents) so multi-rep cursor images pick
    // the same representation AppKit uses everywhere else.
    private let cursorView = NSImageView()
    private let outerRing = CAShapeLayer()
    private let innerRing = CAShapeLayer()
    private let dot = CALayer()
    private let glow = CAGradientLayer()
    private let rippleHost = NSView()
    private var chrome: [CALayer] = []
    private var timer: Timer?
    /// Spring-driven demo path, rebuilt when the fluid parameters (or the box
    /// size) change — the REAL CursorSpringMath, so the pad shows exactly what
    /// the recording will do.
    private var demoSpring: (signature: String, path: [CursorEvent])?

    override var isFlipped: Bool { true }

    init(settings: ProjectSettings) {
        self.settings = settings
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.cornerRadius = CCTheme.radius(.lg)
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        // Mock window chrome: traffic lights + three text lines.
        for i in 0..<3 {
            let dot = CALayer()
            dot.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
            dot.frame = CGRect(x: 10 + CGFloat(i) * 9, y: 10, width: 5, height: 5)
            dot.cornerRadius = 2.5
            layer?.addSublayer(dot)
            chrome.append(dot)
        }
        for (i, alpha) in [0.12, 0.08, 0.08].enumerated() {
            let line = CALayer()
            line.backgroundColor = NSColor.white.withAlphaComponent(alpha).cgColor
            line.cornerRadius = 2
            line.frame = CGRect(x: 10, y: 24 + CGFloat(i) * 10, width: 0, height: 5)
            layer?.addSublayer(line)
            chrome.append(line)
        }

        glow.type = .radial
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        // Ripple rides in its own transparent host ABOVE the cursor view —
        // the export (and the SwiftUI box) draw the ripple over the cursor.
        addSubview(cursorView)
        rippleHost.wantsLayer = true
        addSubview(rippleHost)
        for l in [glow, outerRing, innerRing, dot] {
            rippleHost.layer?.addSublayer(l)
        }
        outerRing.fillColor = NSColor.clear.cgColor
        outerRing.lineWidth = 2
        innerRing.fillColor = NSColor.clear.cgColor
        innerRing.lineWidth = 1.5
        dot.cornerRadius = 3
        cursorView.imageScaling = .scaleProportionallyUpOrDown
        cursorView.wantsLayer = true
        cursorView.layer?.shadowColor = NSColor.black.withAlphaComponent(0.4).cgColor
        cursorView.layer?.shadowOpacity = 1
        cursorView.layer?.shadowRadius = 1.5
        cursorView.layer?.shadowOffset = CGSize(width: 0.5, height: 1)

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

        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { timer?.invalidate() }

    private var themeObservation: CCThemeObservation?

    /// Box chrome only — the demo content (mock window, cursor, ripple)
    /// mimics a recording and keeps its fixed colors in both themes.
    private func applyTheme() {
        let ink: NSColor = CCTheme.isDark ? .white : .black
        layer?.backgroundColor = ink.withAlphaComponent(0.06).cgColor
        layer?.borderColor = ink.withAlphaComponent(0.12).cgColor
    }

    func refreshFromSettings() {
        cursorView.image = CursorStyleProvider.asset(for: settings.cursorStyle).image
        tick()
    }

    override func layout() {
        super.layout()
        rippleHost.frame = bounds
        // Resize the two mock text lines to the box width.
        guard chrome.count == 6 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chrome[3].frame.size.width = bounds.width * 0.4
        chrome[4].frame.size.width = bounds.width * 0.62
        chrome[5].frame.size.width = bounds.width * 0.5
        CATransaction.commit()
    }

    private func tick() {
        let size = bounds.size
        guard size.width > 1 else { return }

        let showCursor = settings.showCursor
        let showRipple = settings.showClickRipple
        let smoothing = settings.smoothCursor ? settings.smoothingFactor : 0
        let scale = settings.cursorScale
        let rippleSize = settings.clickRippleSize
        let ripple = settings.clickRippleColor
        let rippleColor = NSColor(srgbRed: ripple.red, green: ripple.green, blue: ripple.blue, alpha: ripple.opacity)

        let t = CACurrentMediaTime().truncatingRemainder(dividingBy: loopDuration)
        let glideDuration = 0.7 + smoothing * 2.2
        let p = min(1, t / glideDuration)
        let eased = p * p * (3 - 2 * p)
        let start = CGPoint(x: size.width * 0.22, y: size.height * 0.62)
        let end = CGPoint(x: size.width * 0.68, y: size.height * 0.44)
        let cursorPos: CGPoint
        if settings.cursorFluidEnabled {
            // The raw demo path is a hold → LINEAR hop → hold; every bit of
            // easing, overshoot and wiggle the pad shows comes from the spring.
            let sig = "\(settings.cursorTension):\(settings.cursorFriction):\(settings.cursorMass):\(Int(size.width))x\(Int(size.height))"
            if demoSpring?.signature != sig {
                let raw: [CursorEvent] = [
                    CursorEvent(timestamp: 0, x: start.x, y: start.y, isClick: false),
                    CursorEvent(timestamp: 0.45, x: start.x, y: start.y, isClick: false),
                    CursorEvent(timestamp: 0.80, x: end.x, y: end.y, isClick: false),
                    CursorEvent(timestamp: loopDuration, x: end.x, y: end.y, isClick: false),
                ]
                demoSpring = (sig, CursorSpringMath.simulate(
                    events: raw,
                    tension: settings.cursorTension,
                    friction: settings.cursorFriction,
                    mass: settings.cursorMass
                ))
            }
            cursorPos = CursorSmoother().interpolate(events: demoSpring!.path, at: t)
        } else {
            cursorPos = CGPoint(
                x: start.x + (end.x - start.x) * eased,
                y: start.y + (end.y - start.y) * eased
            )
        }
        let clickTime = glideDuration + 0.25
        let rippleProgress = (t - clickTime) / rippleDuration
        let cursorOpacity: Double = {
            guard settings.autoHideCursor else { return 1 }
            let fadeStart = loopDuration - 0.5
            return t > fadeStart ? max(0, 1 - (t - fadeStart) / 0.4) : 1
        }()
        // Loop-to-start / stop-at-end — same window CursorEndBehaviorMath
        // uses (0.8s glide-back, 0.5s freeze), applied to this demo path.
        var endPos = cursorPos
        if settings.cursorLoopToStart {
            let window = 0.8
            let rampStart = loopDuration - window
            if t > rampStart {
                let p = min(1, max(0, (t - rampStart) / window))
                let eased = p * p * (3 - 2 * p)
                endPos.x += (start.x - endPos.x) * CGFloat(eased)
                endPos.y += (start.y - endPos.y) * CGFloat(eased)
            }
        } else if settings.cursorStopAtEnd {
            // By the freeze window the glide has long settled at `end` in
            // either the linear or spring path — freeze there.
            let freezeStart = loopDuration - 0.5
            if t > freezeStart { endPos = end }
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        cursorView.isHidden = !showCursor
        if showCursor {
            let asset = CursorStyleProvider.asset(for: settings.cursorStyle)
            let w = asset.image.size.width * scale
            let h = asset.image.size.height * scale
            cursorView.frame = CGRect(
                x: endPos.x - asset.hotSpot.x * scale,
                y: endPos.y - asset.hotSpot.y * scale,
                width: w, height: h
            )
            cursorView.alphaValue = cursorOpacity
        }

        let rippleActive = showRipple && rippleProgress >= 0 && rippleProgress <= 1
        for l in [glow, outerRing, innerRing, dot] { l.isHidden = !rippleActive }
        if rippleActive {
            let rp = rippleProgress
            let outerScale = 0.2 + rp * 0.8
            let outerOpacity = 1.0 - rp
            let outerD = rippleSize * outerScale
            outerRing.frame = CGRect(x: end.x - outerD / 2, y: end.y - outerD / 2, width: outerD, height: outerD)
            outerRing.path = CGPath(ellipseIn: outerRing.bounds, transform: nil)
            outerRing.strokeColor = rippleColor.withAlphaComponent(outerOpacity * 0.7).cgColor

            let innerProgress = max(0, rp - 0.1) / 0.9
            let innerScale = 0.15 + innerProgress * 0.5
            let innerOpacity = max(0, 1.0 - innerProgress * 1.5)
            let innerD = rippleSize * 0.6 * innerScale
            innerRing.frame = CGRect(x: end.x - innerD / 2, y: end.y - innerD / 2, width: innerD, height: innerD)
            innerRing.path = CGPath(ellipseIn: innerRing.bounds, transform: nil)
            innerRing.strokeColor = rippleColor.withAlphaComponent(innerOpacity * 0.5).cgColor

            dot.frame = CGRect(x: end.x - 3, y: end.y - 3, width: 6, height: 6)
            dot.backgroundColor = rippleColor.withAlphaComponent(max(0, 1.0 - rp * 3) * 0.6).cgColor

            glow.frame = outerRing.frame
            glow.cornerRadius = outerD / 2
            glow.colors = [
                rippleColor.withAlphaComponent(outerOpacity * 0.12).cgColor,
                rippleColor.withAlphaComponent(0).cgColor,
            ]
        }

        CATransaction.commit()
    }
}
