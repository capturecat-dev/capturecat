import AppKit

/// The Cursor tab as a native AppKit pane — twin of CursorSettingsView.
@MainActor
final class CursorSettingsPaneAppKit: NSView {
    private let settings: ProjectSettings
    /// Whether the CURRENT project has captured keystroke timings.
    var hasKeystrokeData: Bool = true { didSet { apply() } }

    private let stack = NSStackView()
    private let previewBox: CursorPreviewBoxControl
    private let showToggle = InspectorToggleControl("Show Cursor")
    private let styleMenu = InspectorMenuControl()
    private let sizeSlider = InspectorSliderRow(label: "Size", range: 0.5...3.0, step: 0.25)
    // Fluid movement (CursorSpringMath) — demoed live in the preview box.
    // (The tilt/stretch/drag/weight pose sliders were cut: fluid movement is
    // the one motion treatment the product needs, and it's on by default. The
    // pose math survives in CursorPhysicsMath, inert at its zero defaults.)
    private let fluidToggle = InspectorToggleControl("Fluid Movement")
    private let tensionSlider = InspectorSliderRow(label: "Tension", range: 20...600, step: 10)
    private let tensionCaption = InspectorKitViews.caption("How quickly the cursor accelerates toward where you moved.")
    private let frictionSlider = InspectorSliderRow(label: "Friction", range: 2...80, step: 1)
    private let frictionCaption = InspectorKitViews.caption("Resistance while moving fast — higher settles sooner.")
    private let massSlider = InspectorSliderRow(label: "Mass", range: 0.2...6, step: 0.1)
    private let massCaption = InspectorKitViews.caption("Heavier keeps momentum — more overshoot and wiggle. Clicks always stay exactly where you clicked.")
    private let autoHideToggle = InspectorToggleControl("Auto-Hide Cursor")
    private let loopToggle = InspectorToggleControl("Loop to Start")
    private let stopEndToggle = InspectorToggleControl("Stop at End")
    private let endCaption = InspectorKitViews.caption("Loop glides the cursor back to its first position near the end — seamless for looping social clips. Stop freezes it for the final half second.")
    private let hideAfterSlider = InspectorSliderRow(label: "Hide After", range: 1...10, step: 0.5)
    private let smoothToggle = InspectorToggleControl("Smooth Cursor Motion")
    private let smoothingSlider = InspectorSliderRow(label: "Smoothing", range: 0.05...0.5, step: 0.05)
    private let rippleToggle = InspectorToggleControl("Show Click Ripple")
    private let rippleSizeSlider = InspectorSliderRow(label: "Size", range: 20...100, step: 5)
    private let rippleColorWell = InspectorColorWellControl()
    private var rippleColorRow: NSView!
    private let clickSoundToggle = InspectorToggleControl("Click Sound")
    private let clickStyleMenu = InspectorMenuControl()
    private let clickTestButton = InspectorButton("Test")
    private var clickStyleRow: NSView!
    private let clickVolumeSlider = InspectorSliderRow(label: "Volume", range: 0.1...1.0, step: 0.05)
    private var clickSoundCaption: NSView!
    private var keyNoDataCaption: NSView!
    private let keySoundToggle = InspectorToggleControl("Keyboard Sounds")
    private let keyStyleMenu = InspectorMenuControl()
    private let keyTestButton = InspectorButton("Test")
    private var keyStyleRow: NSView!
    private let keyVolumeSlider = InspectorSliderRow(label: "Volume", range: 0.1...1.0, step: 0.05)
    private var keyCaption: NSView!
    private var keyPermissionCaption: NSView!
    private let keyPermissionButton = InspectorButton("Request Permission")
    /// Whether the CURRENT project recorded shortcut identity (opt-in).
    var hasShortcutData: Bool = false { didSet { apply() } }
    /// Whether the CURRENT project is a single-window recording — the only
    /// case where scoping the overlay to the recorded app means anything.
    var isWindowRecording: Bool = false { didSet { apply() } }
    private let keystrokeOverlayToggle = InspectorToggleControl("Show Shortcut Overlay")
    private let keystrokePositionMenu = InspectorMenuControl()
    private var keystrokePositionRow: NSView!
    private let keystrokeAnimationMenu = InspectorMenuControl()
    private var keystrokeAnimationRow: NSView!
    private let keystrokeSizeSlider = InspectorSliderRow(label: "Size", range: 0.6...1.8, step: 0.1)
    private let keystrokeScopeToggle = InspectorToggleControl("Only Recorded App")
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
        styleMenu.items = ProjectSettings.CursorStyle.allCases.map {
            .init(title: $0.rawValue, icon: CursorStyleProvider.asset(for: $0).image)
        }
        cursorBox.addRow(InspectorKitViews.row("Style", control: styleMenu))
        sizeSlider.format = { String(format: "%.2fx", $0) }
        cursorBox.addRow(sizeSlider)
        fullWidth(cursorBox)

        let motionBox = InspectorSectionBox("Motion")
        motionBox.addRow(fluidToggle)
        motionBox.addRow(tensionSlider)
        motionBox.addRow(tensionCaption, attached: true)
        motionBox.addRow(frictionSlider)
        motionBox.addRow(frictionCaption, attached: true)
        massSlider.format = { String(format: "%.1fx", $0) }
        motionBox.addRow(massSlider)
        motionBox.addRow(massCaption, attached: true)
        motionBox.addRow(smoothToggle)
        motionBox.addRow(smoothingSlider)
        fullWidth(motionBox)

        let behaviorBox = InspectorSectionBox("Behavior")
        behaviorBox.addRow(autoHideToggle)
        hideAfterSlider.format = { String(format: "%.1fs", $0) }
        behaviorBox.addRow(hideAfterSlider)
        behaviorBox.addRow(loopToggle)
        behaviorBox.addRow(stopEndToggle)
        behaviorBox.addRow(endCaption, attached: true)
        fullWidth(behaviorBox)

        let clickBox = InspectorSectionBox("Click Effect")
        clickBox.addRow(rippleToggle)
        clickBox.addRow(rippleSizeSlider)
        rippleColorWell.supportsOpacity = false
        rippleColorRow = InspectorKitViews.row("Color", control: rippleColorWell)
        clickBox.addRow(rippleColorRow)

        clickBox.addRow(clickSoundToggle)
        clickStyleMenu.items = ClickSoundStyle.allCases.map { .init(title: $0.rawValue, icon: nil) }
        let styleControls = NSStackView(views: [clickStyleMenu, clickTestButton])
        styleControls.orientation = .horizontal
        styleControls.spacing = 8
        clickStyleRow = InspectorKitViews.row("Sound", control: styleControls)
        clickBox.addRow(clickStyleRow)
        clickVolumeSlider.format = { "\(Int(($0 * 100).rounded()))%" }
        clickBox.addRow(clickVolumeSlider)
        clickSoundCaption = InspectorKitViews.captionLine(
            "A synthesized tick plays at every recorded click.",
            full: "A synthesized tick plays at every recorded click — in the preview and in the exported file."
        )
        clickBox.addRow(clickSoundCaption, attached: true)
        fullWidth(clickBox)

        let keyBox = InspectorSectionBox("Keyboard Sounds")
        keyBox.addRow(keySoundToggle)
        keyStyleMenu.items = KeySoundStyle.allCases.map { .init(title: $0.rawValue, icon: nil) }
        let keyControls = NSStackView(views: [keyStyleMenu, keyTestButton])
        keyControls.orientation = .horizontal
        keyControls.spacing = 8
        keyStyleRow = InspectorKitViews.row("Sound", control: keyControls)
        keyBox.addRow(keyStyleRow)
        keyVolumeSlider.format = { "\(Int(($0 * 100).rounded()))%" }
        keyBox.addRow(keyVolumeSlider)
        keyNoDataCaption = InspectorKitViews.caption(
            "This recording has no keystroke data — typing sounds apply to recordings made from now on (with Input Monitoring granted). Record a new take to hear them."
        )
        keyBox.addRow(keyNoDataCaption, attached: true)
        keyCaption = InspectorKitViews.captionLine(
            "Keystroke timings (never what you typed) play as typing sounds.",
            full: "Keystroke timings (never what you typed) are captured in new recordings and play as typing sounds."
        )
        keyBox.addRow(keyCaption, attached: true)
        keyPermissionCaption = InspectorKitViews.caption(
            "Grant Input Monitoring in System Settings → Privacy & Security so future recordings can capture keystroke timing. Nothing you type is ever stored — only when keys were pressed."
        )
        keyBox.addRow(keyPermissionCaption)
        keyBox.addRow(keyPermissionButton, attached: true)
        fullWidth(keyBox)

        let overlayBox = InspectorSectionBox("Shortcut Overlay")
        overlayBox.addRow(keystrokeOverlayToggle)
        keystrokePositionMenu.items = KeystrokeOverlayPosition.allCases
            .map { .init(title: $0.label, icon: nil) }
        keystrokePositionRow = InspectorKitViews.row("Position", control: keystrokePositionMenu)
        overlayBox.addRow(keystrokePositionRow)
        keystrokeAnimationMenu.items = KeystrokeOverlayAnimation.allCases
            .map { .init(title: $0.label, icon: nil) }
        keystrokeAnimationRow = InspectorKitViews.row("Animation", control: keystrokeAnimationMenu)
        overlayBox.addRow(keystrokeAnimationRow)
        keystrokeSizeSlider.format = { "\(Int(($0 * 100).rounded()))%" }
        overlayBox.addRow(keystrokeSizeSlider)
        overlayBox.addRow(keystrokeScopeToggle)
        keystrokeScopeCaption = InspectorKitViews.captionLine(
            "Hide shortcuts pressed in other apps during the recording.",
            full: "Hide shortcuts pressed in other apps while this window was being recorded."
        )
        overlayBox.addRow(keystrokeScopeCaption, attached: true)
        keystrokeNoDataCaption = InspectorKitViews.caption(
            "This recording has no shortcut data. Enable \"Capture Shortcuts\" in the recording panel before recording — only combos with ⌘, ⌃ or ⌥ are stored, never plain typing."
        )
        overlayBox.addRow(keystrokeNoDataCaption, attached: true)
        keystrokeCaption = InspectorKitViews.captionLine(
            "Recorded shortcuts (⌘⇧S…) appear as a pill in preview and export.",
            full: "Recorded shortcuts (⌘⇧S…) appear as a pill, in the preview and in the exported file."
        )
        overlayBox.addRow(keystrokeCaption, attached: true)
        fullWidth(overlayBox)
    }

    private func wire() {
        showToggle.onChange = { [weak self] on in self?.settings.showCursor = on }
        styleMenu.onSelect = { [weak self] index in
            self?.settings.cursorStyle = ProjectSettings.CursorStyle.allCases[index]
        }
        sizeSlider.onChange = { [weak self] v in self?.settings.cursorScale = v }
        fluidToggle.onChange = { [weak self] on in self?.settings.cursorFluidEnabled = on }
        tensionSlider.onChange = { [weak self] v in self?.settings.cursorTension = v }
        frictionSlider.onChange = { [weak self] v in self?.settings.cursorFriction = v }
        massSlider.onChange = { [weak self] v in self?.settings.cursorMass = v }
        autoHideToggle.onChange = { [weak self] on in self?.settings.autoHideCursor = on }
        loopToggle.onChange = { [weak self] on in
            self?.settings.cursorLoopToStart = on
            if on { self?.settings.cursorStopAtEnd = false }
        }
        stopEndToggle.onChange = { [weak self] on in
            self?.settings.cursorStopAtEnd = on
            if on { self?.settings.cursorLoopToStart = false }
        }
        hideAfterSlider.onChange = { [weak self] v in self?.settings.autoHideDelay = v }
        smoothToggle.onChange = { [weak self] on in self?.settings.smoothCursor = on }
        smoothingSlider.onChange = { [weak self] v in self?.settings.smoothingFactor = v }
        rippleToggle.onChange = { [weak self] on in self?.settings.showClickRipple = on }
        rippleSizeSlider.onChange = { [weak self] v in self?.settings.clickRippleSize = v }
        rippleColorWell.getColor = { [weak self] in
            guard let c = self?.settings.clickRippleColor else { return .white }
            return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.opacity)
        }
        rippleColorWell.setColor = { [weak self] color in
            guard let srgb = color.usingColorSpace(.sRGB) else { return }
            self?.settings.clickRippleColor = CodableColor(
                red: srgb.redComponent, green: srgb.greenComponent,
                blue: srgb.blueComponent, opacity: srgb.alphaComponent
            )
        }
        clickSoundToggle.onChange = { [weak self] on in
            self?.settings.clickSoundEnabled = on
            if on, let s = self?.settings {
                ClickSoundPlayer.shared.playPreview(volume: s.clickSoundVolume, style: s.clickSoundStyle)
            }
        }
        clickStyleMenu.onSelect = { [weak self] index in
            guard let self else { return }
            let style = ClickSoundStyle.allCases[index]
            settings.clickSoundStyle = style
            ClickSoundPlayer.shared.play(volume: settings.clickSoundVolume, style: style)
        }
        clickTestButton.onClick = { [weak self] in
            guard let s = self?.settings else { return }
            ClickSoundPlayer.shared.play(volume: s.clickSoundVolume, style: s.clickSoundStyle)
        }
        clickVolumeSlider.onChange = { [weak self] v in
            guard let self else { return }
            settings.clickSoundVolume = v
            ClickSoundPlayer.shared.playPreview(volume: v, style: settings.clickSoundStyle)
        }
        keySoundToggle.onChange = { [weak self] on in
            guard let self else { return }
            settings.keySoundEnabled = on
            if on {
                KeySoundPlayer.shared.playTestBurst(volume: settings.keySoundVolume, style: settings.keySoundStyle)
            }
        }
        keyStyleMenu.onSelect = { [weak self] index in
            guard let self else { return }
            let style = KeySoundStyle.allCases[index]
            settings.keySoundStyle = style
            KeySoundPlayer.shared.playTestBurst(volume: settings.keySoundVolume, style: style)
        }
        keyTestButton.onClick = { [weak self] in
            guard let s = self?.settings else { return }
            KeySoundPlayer.shared.playTestBurst(volume: s.keySoundVolume, style: s.keySoundStyle)
        }
        keyVolumeSlider.onChange = { [weak self] v in
            self?.settings.keySoundVolume = v
        }
        keyPermissionButton.onClick = {
            KeystrokeTracker.requestPermission()
        }
        keystrokeOverlayToggle.onChange = { [weak self] on in
            self?.settings.showKeystrokes = on
        }
        keystrokePositionMenu.onSelect = { [weak self] index in
            self?.settings.keystrokeOverlayPosition = KeystrokeOverlayPosition.allCases[index]
        }
        keystrokeAnimationMenu.onSelect = { [weak self] index in
            self?.settings.keystrokeOverlayAnimation = KeystrokeOverlayAnimation.allCases[index]
        }
        keystrokeSizeSlider.onChange = { [weak self] v in
            self?.settings.keystrokeOverlaySize = v
        }
        keystrokeScopeToggle.onChange = { [weak self] on in
            self?.settings.keystrokeOverlayScopeToRecordedApp = on
        }
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
        showToggle.isOn = settings.showCursor
        styleMenu.selectedIndex = ProjectSettings.CursorStyle.allCases
            .firstIndex(of: settings.cursorStyle) ?? 0
        sizeSlider.setValue(settings.cursorScale)
        fluidToggle.isOn = settings.cursorFluidEnabled
        for control in [tensionSlider, frictionSlider, massSlider] {
            control.isHidden = !settings.cursorFluidEnabled
        }
        tensionCaption.isHidden = !settings.cursorFluidEnabled
        frictionCaption.isHidden = !settings.cursorFluidEnabled
        massCaption.isHidden = !settings.cursorFluidEnabled
        tensionSlider.setValue(settings.cursorTension)
        frictionSlider.setValue(settings.cursorFriction)
        massSlider.setValue(settings.cursorMass)
        autoHideToggle.isOn = settings.autoHideCursor
        loopToggle.isOn = settings.cursorLoopToStart
        stopEndToggle.isOn = settings.cursorStopAtEnd
        hideAfterSlider.isHidden = !settings.autoHideCursor
        hideAfterSlider.setValue(settings.autoHideDelay)
        smoothToggle.isOn = settings.smoothCursor
        smoothingSlider.isHidden = !settings.smoothCursor
        smoothingSlider.setValue(settings.smoothingFactor)
        rippleToggle.isOn = settings.showClickRipple
        rippleSizeSlider.isHidden = !settings.showClickRipple
        rippleSizeSlider.setValue(settings.clickRippleSize)
        rippleColorRow.isHidden = !settings.showClickRipple
        rippleColorWell.refresh()
        clickSoundToggle.isOn = settings.clickSoundEnabled
        clickStyleRow.isHidden = !settings.clickSoundEnabled
        clickStyleMenu.selectedIndex = ClickSoundStyle.allCases
            .firstIndex(of: settings.clickSoundStyle) ?? 0
        clickVolumeSlider.isHidden = !settings.clickSoundEnabled
        clickVolumeSlider.setValue(settings.clickSoundVolume)
        clickSoundCaption.isHidden = !settings.clickSoundEnabled
        keySoundToggle.isOn = settings.keySoundEnabled
        keyStyleRow.isHidden = !settings.keySoundEnabled
        keyStyleMenu.selectedIndex = KeySoundStyle.allCases
            .firstIndex(of: settings.keySoundStyle) ?? 0
        keyVolumeSlider.isHidden = !settings.keySoundEnabled
        keyVolumeSlider.setValue(settings.keySoundVolume)
        let hasKeyPermission = KeystrokeTracker.hasPermission
        keyNoDataCaption.isHidden = !settings.keySoundEnabled || hasKeystrokeData
        keyCaption.isHidden = !settings.keySoundEnabled || !hasKeyPermission || !hasKeystrokeData
        keyPermissionCaption.isHidden = !settings.keySoundEnabled || hasKeyPermission
        keyPermissionButton.isHidden = !settings.keySoundEnabled || hasKeyPermission
        keystrokeOverlayToggle.isOn = settings.showKeystrokes
        let overlayActive = settings.showKeystrokes && hasShortcutData
        keystrokePositionRow.isHidden = !overlayActive
        keystrokePositionMenu.selectedIndex = KeystrokeOverlayPosition.allCases
            .firstIndex(of: settings.keystrokeOverlayPosition) ?? 0
        keystrokeAnimationRow.isHidden = !overlayActive
        keystrokeAnimationMenu.selectedIndex = KeystrokeOverlayAnimation.allCases
            .firstIndex(of: settings.keystrokeOverlayAnimation) ?? 0
        keystrokeSizeSlider.isHidden = !overlayActive
        keystrokeSizeSlider.setValue(settings.keystrokeOverlaySize)
        keystrokeScopeToggle.isHidden = !overlayActive || !isWindowRecording
        keystrokeScopeToggle.isOn = settings.keystrokeOverlayScopeToRecordedApp
        keystrokeScopeCaption.isHidden = keystrokeScopeToggle.isHidden
        keystrokeNoDataCaption.isHidden = !settings.showKeystrokes || hasShortcutData
        keystrokeCaption.isHidden = !overlayActive
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
