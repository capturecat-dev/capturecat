import AppKit

/// The entire Camera tab as a native AppKit view.
/// Reads the @Observable ProjectSettings through a withObservationTracking
/// re-register loop; writes happen directly from the controls.
@MainActor
final class CameraSettingsPaneAppKit: NSView, NSTextFieldDelegate {
    private let settings: ProjectSettings
    private let hasRecordedCamera: Bool

    private let stack = NSStackView()
    private let showToggle = InspectorToggleControl("Show Camera")
    private let noCameraCaption = InspectorKitViews.caption("No recorded camera video is available for this project.")
    private let pad: CameraPreviewPadControl
    private let positionMenu = InspectorMenuControl()
    private let shapeMenu = InspectorMenuControl()
    /// Bubble orientation (Auto / Vertical / Wide) — only meaningful for the
    /// aspect-following shapes; hidden for circle/square (always 1:1).
    private let orientationChips = InspectorChipsControl()
    private let mirrorToggle = InspectorToggleControl("Mirror Camera")
    private let sizeSlider: InspectorSliderRow

    // Adjust section — color sliders + look preset + ring light.
    private let brightnessSlider = InspectorSliderRow(label: "Brightness", range: -1...1, step: 0.05)
    private let contrastSlider = InspectorSliderRow(label: "Contrast", range: 0.5...1.5, step: 0.05)
    private let saturationSlider = InspectorSliderRow(label: "Saturation", range: 0...2, step: 0.05)
    private let hueSlider = InspectorSliderRow(label: "Hue", range: -180...180, step: 5)
    private let filterChips = InspectorChipsControl()
    private let ringLightSlider = InspectorSliderRow(label: "Ring Light", range: 0...1, step: 0.05)

    // Style section — shape refinement, border, opacity.
    private let cornerRadiusSlider = InspectorSliderRow(label: "Corner Radius", range: 0...60, step: 1)
    private let borderWidthSlider = InspectorSliderRow(label: "Border", range: 0...8, step: 0.5)
    private let borderColorWell = InspectorColorWellControl()
    private let borderColorReset = InspectorButton("Reset")
    private var borderColorRow: NSView!
    private let opacitySlider = InspectorSliderRow(label: "Opacity", range: 0.2...1, step: 0.05)
    /// House 2D tilt pad (same control as the Motion pane), capped at ±25°.
    private let tiltPad = TiltPadControl()

    // Name-tag section.
    private let tagTextField = InspectorFlatTextField(placeholder: "Name")
    private let tagSubtextField = InspectorFlatTextField(placeholder: "Role / company")
    private let tagPositionMenu = InspectorMenuControl()
    private let tagTextColorWell = InspectorColorWellControl()
    private let tagBackgroundColorWell = InspectorColorWellControl()

    private var detailViews: [NSView] = []
    private var cornerRadiusRow: NSView { cornerRadiusSlider }
    private var isObserving = false

    override var isFlipped: Bool { true }

    init(settings: ProjectSettings, hasRecordedCamera: Bool) {
        self.settings = settings
        self.hasRecordedCamera = hasRecordedCamera
        self.pad = CameraPreviewPadControl(settings: settings)
        // Shown as % of canvas width — the stored value stays nominal-canvas
        // points (persistence identity; 1456pt nominal width = 100%). 8% floor:
        // below that the bubble reads as a dot and the name tag has nowhere to
        // live. 22% ceiling gives presenter-style prominence.
        self.sizeSlider = InspectorSliderRow(label: "Size", range: 8...22, step: 0.5)
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

        let cameraBox = InspectorSectionBox("Camera Overlay")
        cameraBox.addRow(showToggle)
        if !hasRecordedCamera {
            cameraBox.addRow(noCameraCaption, attached: true)
        }
        cameraBox.addRow(pad)
        pad.heightAnchor.constraint(equalToConstant: 96).isActive = true

        let positionRow = InspectorKitViews.row("Position", control: positionMenu)
        let shapeRow = InspectorKitViews.row("Shape", control: shapeMenu)

        // Border color well + reset back to the default white 30% (nil).
        let borderPair = NSStackView(views: [borderColorWell, borderColorReset])
        borderPair.orientation = .horizontal
        borderPair.spacing = 8
        borderColorRow = InspectorKitViews.row("Border Color", control: borderPair)

        let tagPositionRow = InspectorKitViews.row("Tag Position", control: tagPositionMenu)
        let tagTextColorRow = InspectorKitViews.row("Text Color", control: tagTextColorWell)
        let tagBackgroundRow = InspectorKitViews.row("Tag Fill", control: tagBackgroundColorWell)

        cameraBox.addRow(positionRow)
        cameraBox.addRow(shapeRow)
        cameraBox.addRow(orientationChips, attached: true)
        cameraBox.addRow(mirrorToggle)
        cameraBox.addRow(sizeSlider)
        fullWidth(cameraBox)

        let adjustBox = InspectorSectionBox("Adjust")
        for row in [brightnessSlider, contrastSlider, saturationSlider, hueSlider] {
            adjustBox.addRow(row)
        }
        adjustBox.addRow(filterChips)
        adjustBox.addRow(ringLightSlider)
        fullWidth(adjustBox)

        let styleBox = InspectorSectionBox("Style")
        styleBox.addRow(cornerRadiusSlider)
        styleBox.addRow(borderWidthSlider)
        styleBox.addRow(borderColorRow)
        styleBox.addRow(opacitySlider)
        styleBox.addRow(tiltPad)
        fullWidth(styleBox)

        let tagBox = InspectorSectionBox("Name Tag")
        tagBox.addRow(tagTextField)
        tagBox.addRow(tagSubtextField)
        tagBox.addRow(tagPositionRow)
        tagBox.addRow(tagTextColorRow)
        tagBox.addRow(tagBackgroundRow)
        fullWidth(tagBox)

        detailViews = [
            positionRow, shapeRow, orientationChips, mirrorToggle, sizeSlider,
            adjustBox, styleBox, tagBox,
        ]

        positionMenu.items = ProjectSettings.CameraPosition.allCases.map { .init(title: $0.rawValue) }
        shapeMenu.items = ProjectSettings.CameraShape.allCases.map { .init(title: $0.rawValue) }
        orientationChips.items = ProjectSettings.CameraOrientation.allCases.map(\.rawValue)
        tagPositionMenu.items = ProjectSettings.CameraTagPosition.allCases.map { .init(title: $0.rawValue) }
        filterChips.items = ProjectSettings.CameraFilterStyle.allCases.map(\.rawValue)
        sizeSlider.format = { $0.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int($0))%" : String(format: "%.1f%%", $0) }
        hueSlider.format = { "\(Int($0))°" }
        ringLightSlider.format = { "\(Int($0 * 100))%" }
        opacitySlider.format = { "\(Int($0 * 100))%" }
        tagTextField.delegate = self
        tagSubtextField.delegate = self
        tiltPad.maxAngle = 25
    }

    private func wire() {
        showToggle.onChange = { [weak self] on in self?.settings.showCamera = on }
        mirrorToggle.onChange = { [weak self] on in self?.settings.cameraMirrored = on }
        sizeSlider.onChange = { [weak self] percent in
            self?.settings.cameraSize = percent / 100 * 1456
        }
        positionMenu.onSelect = { [weak self] index in
            guard let self else { return }
            // Picking a corner from the menu clears free placement.
            settings.cameraPosition = ProjectSettings.CameraPosition.allCases[index]
            settings.cameraCustomX = nil
            settings.cameraCustomY = nil
        }
        shapeMenu.onSelect = { [weak self] index in
            self?.settings.cameraShape = ProjectSettings.CameraShape.allCases[index]
        }
        orientationChips.onSelect = { [weak self] index in
            self?.settings.cameraOrientation = ProjectSettings.CameraOrientation.allCases[index]
        }

        // Adjust
        brightnessSlider.onChange = { [weak self] v in self?.settings.cameraBrightness = v }
        contrastSlider.onChange = { [weak self] v in self?.settings.cameraContrast = v }
        saturationSlider.onChange = { [weak self] v in self?.settings.cameraSaturation = v }
        hueSlider.onChange = { [weak self] v in self?.settings.cameraHue = v }
        ringLightSlider.onChange = { [weak self] v in self?.settings.cameraRingLight = v }
        filterChips.onSelect = { [weak self] index in
            self?.settings.cameraFilter = ProjectSettings.CameraFilterStyle.allCases[index]
        }

        // Style
        cornerRadiusSlider.onChange = { [weak self] v in self?.settings.cameraCornerRadius = v }
        borderWidthSlider.onChange = { [weak self] v in self?.settings.cameraBorderWidth = v }
        opacitySlider.onChange = { [weak self] v in self?.settings.cameraOpacity = v }
        tiltPad.onChange = { [weak self] pitch, yaw in
            self?.settings.cameraTiltPitch = pitch
            self?.settings.cameraTiltYaw = yaw
        }
        borderColorWell.getColor = { [weak self] in
            guard let self else { return .white }
            return CameraStyleMath.borderNSColor(self.settings)
        }
        borderColorWell.setColor = { [weak self] c in
            self?.settings.cameraBorderColor = CodableColor(c)
        }
        borderColorReset.onClick = { [weak self] in
            self?.settings.cameraBorderColor = nil
            self?.borderColorWell.refresh()
        }

        // Name tag
        tagPositionMenu.onSelect = { [weak self] index in
            self?.settings.cameraTagPosition = ProjectSettings.CameraTagPosition.allCases[index]
        }
        tagTextColorWell.getColor = { [weak self] in
            self?.settings.cameraTagTextColor.nsColor ?? .white
        }
        tagTextColorWell.setColor = { [weak self] c in
            self?.settings.cameraTagTextColor = CodableColor(c)
        }
        tagBackgroundColorWell.getColor = { [weak self] in
            self?.settings.cameraTagBackgroundColor.nsColor ?? NSColor(white: 0, alpha: 0.55)
        }
        tagBackgroundColorWell.setColor = { [weak self] c in
            self?.settings.cameraTagBackgroundColor = CodableColor(c)
        }
    }

    /// Live text commit as the user types (same behaviour as the menu-bar
    /// title field in BackgroundSettingsPaneAppKit).
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === tagTextField {
            settings.cameraTagText = field.stringValue
        } else if field === tagSubtextField {
            settings.cameraTagSubtext = field.stringValue
        }
    }

    /// Classic @Observable → AppKit bridge: read everything we render inside
    /// withObservationTracking so any change re-registers and re-applies.
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
        showToggle.isOn = settings.showCamera
        showToggle.isEnabled = hasRecordedCamera
        pad.alphaValue = hasRecordedCamera && settings.showCamera ? 1 : 0.45

        let showDetails = hasRecordedCamera && settings.showCamera
        for view in detailViews { view.isHidden = !showDetails }

        positionMenu.selectedIndex = ProjectSettings.CameraPosition.allCases
            .firstIndex(of: settings.cameraPosition) ?? 0
        shapeMenu.selectedIndex = ProjectSettings.CameraShape.allCases
            .firstIndex(of: settings.cameraShape) ?? 0
        mirrorToggle.isOn = settings.cameraMirrored
        sizeSlider.setValue(settings.effectiveCameraSize / 1456 * 100)

        brightnessSlider.setValue(settings.cameraBrightness)
        contrastSlider.setValue(settings.cameraContrast)
        saturationSlider.setValue(settings.cameraSaturation)
        hueSlider.setValue(settings.cameraHue)
        ringLightSlider.setValue(settings.cameraRingLight)
        filterChips.selectedIndex = ProjectSettings.CameraFilterStyle.allCases
            .firstIndex(of: settings.cameraFilter) ?? 0

        // Corner radius only applies to the rounded-rect shape.
        // Orientation only applies to the aspect-following shapes — circle
        // and square are always 1:1.
        let aspectShape = settings.cameraShape == .roundedRect || settings.cameraShape == .squircle
        orientationChips.isHidden = !showDetails || !aspectShape
        orientationChips.selectedIndex = ProjectSettings.CameraOrientation.allCases
            .firstIndex(of: settings.cameraOrientation) ?? 0

        cornerRadiusSlider.isHidden = !showDetails || settings.cameraShape != .roundedRect
        cornerRadiusSlider.setValue(settings.cameraCornerRadius)
        borderWidthSlider.setValue(settings.cameraBorderWidth)
        opacitySlider.setValue(settings.cameraOpacity)
        tiltPad.set(pitch: settings.cameraTiltPitch, yaw: settings.cameraTiltYaw, roll: 0)
        borderColorWell.refresh()

        tagPositionMenu.selectedIndex = ProjectSettings.CameraTagPosition.allCases
            .firstIndex(of: settings.cameraTagPosition) ?? 0
        if tagTextField.currentEditor() == nil { tagTextField.stringValue = settings.cameraTagText }
        if tagSubtextField.currentEditor() == nil { tagSubtextField.stringValue = settings.cameraTagSubtext }
        tagTextColorWell.refresh()
        tagBackgroundColorWell.refresh()
        pad.refresh()
    }
}

/// Mini canvas showing the camera bubble's placement, shape, and relative
/// size, with the animated person silhouette. Drag to place freely (writes
/// cameraCustomX/Y); a release near a corner snaps back to the corner enum.
/// Native twin of the SwiftUI CameraPreviewPad.
@MainActor
final class CameraPreviewPadControl: NSView {
    private let settings: ProjectSettings

    private let inset: CGFloat = 8
    private let bubbleContainer = CALayer()
    private let bubbleGradient = CAGradientLayer()
    private let silhouette = CameraSilhouetteLayer()
    private let fauxLine1 = CALayer()
    private let fauxLine2 = CALayer()
    private var timer: Timer?

    override var isFlipped: Bool { true }

    init(settings: ProjectSettings) {
        self.settings = settings
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.cornerRadius = CCTheme.radius(.lg)
        layer?.cornerCurve = .continuous

        fauxLine1.cornerRadius = 1.5
        fauxLine2.cornerRadius = 1.5
        layer?.addSublayer(fauxLine1)
        layer?.addSublayer(fauxLine2)

        bubbleGradient.colors = [
            NSColor.white.withAlphaComponent(0.22).cgColor,
            NSColor.white.withAlphaComponent(0.08).cgColor,
        ]
        bubbleContainer.addSublayer(bubbleGradient)
        bubbleContainer.addSublayer(silhouette)
        bubbleContainer.masksToBounds = true
        bubbleContainer.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        bubbleContainer.borderWidth = 1
        bubbleContainer.shadowColor = NSColor.black.withAlphaComponent(0.35).cgColor
        bubbleContainer.shadowOpacity = 1
        bubbleContainer.shadowRadius = 3
        bubbleContainer.shadowOffset = CGSize(width: 0, height: 1)
        layer?.addSublayer(bubbleContainer)

        // Idle-motion clock — same layered sinusoids as the SwiftUI pad.
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let window = self.window,
                      window.occlusionState.contains(.visible),
                      !self.isHiddenOrHasHiddenAncestor else { return }
                self.silhouette.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError() }

    private var themeObservation: CCThemeObservation?

    /// Pad chrome only — the demo bubble (gradient, silhouette, border,
    /// shadow) mimics the exported camera overlay and keeps its fixed colors.
    private func applyTheme() {
        let ink: NSColor = CCTheme.isDark ? .white : .black
        layer?.backgroundColor = ink.withAlphaComponent(0.06).cgColor
        layer?.borderColor = ink.withAlphaComponent(0.12).cgColor
        fauxLine1.backgroundColor = ink.withAlphaComponent(0.10).cgColor
        fauxLine2.backgroundColor = ink.withAlphaComponent(0.07).cgColor
    }

    deinit {
        timer?.invalidate()
    }

    private var bubbleSize: CGFloat {
        20 + CGFloat((settings.effectiveCameraSize - 120) / 200) * 26
    }

    private var fraction: CGPoint {
        if let x = settings.cameraCustomX, let y = settings.cameraCustomY {
            return CGPoint(x: x, y: y)
        }
        return ReactiveCameraLayout.fraction(for: settings.cameraPosition)
    }

    func refresh() {
        needsLayout = true
        silhouette.mirrored = settings.cameraMirrored
        applyShape()
    }

    private func applyShape() {
        let bubble = bubbleSize
        switch settings.cameraShape {
        case .circle: bubbleContainer.cornerRadius = bubble / 2
        case .squircle: bubbleContainer.cornerRadius = bubble / 2 * 0.6
        case .roundedRect: bubbleContainer.cornerRadius = bubble / 2 * 0.35
        case .square: bubbleContainer.cornerRadius = 0
        }
        bubbleContainer.cornerCurve = .continuous
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        fauxLine1.frame = CGRect(x: 10, y: 10, width: bounds.width * 0.34, height: 4)
        fauxLine2.frame = CGRect(x: 10, y: 18, width: bounds.width * 0.5, height: 4)

        let bubble = bubbleSize
        let f = fraction
        let cx = inset + bubble / 2 + (bounds.width - bubble - 2 * inset) * f.x
        let cy = inset + bubble / 2 + (bounds.height - bubble - 2 * inset) * f.y
        bubbleContainer.frame = CGRect(x: cx - bubble / 2, y: cy - bubble / 2, width: bubble, height: bubble)
        bubbleGradient.frame = bubbleContainer.bounds
        silhouette.frame = bubbleContainer.bounds
        silhouette.bubble = bubble
        applyShape()

        CATransaction.commit()
    }

    // MARK: - Drag to place

    private func place(at point: NSPoint) {
        let bubble = bubbleSize
        let usableW = max(1, bounds.width - bubble - 2 * inset)
        let usableH = max(1, bounds.height - bubble - 2 * inset)
        let fx = (point.x - inset - bubble / 2) / usableW
        let fy = (point.y - inset - bubble / 2) / usableH
        settings.cameraCustomX = Double(min(1, max(0, fx)))
        settings.cameraCustomY = Double(min(1, max(0, fy)))
        needsLayout = true
    }

    override func mouseDown(with event: NSEvent) {
        place(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        place(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        // A release near a corner collapses to the clean corner enum.
        guard let x = settings.cameraCustomX, let y = settings.cameraCustomY else { return }
        for corner in ProjectSettings.CameraPosition.allCases {
            let f = ReactiveCameraLayout.fraction(for: corner)
            if abs(f.x - x) < 0.08 && abs(f.y - y) < 0.08 {
                settings.cameraPosition = corner
                settings.cameraCustomX = nil
                settings.cameraCustomY = nil
                needsLayout = true
                return
            }
        }
    }
}

/// Drawn head-and-shoulders silhouette with layered idle motion — breathing
/// shoulders, an irregular nod, slow glances. Same math as CameraSilhouette
/// in CameraSettingsView.swift so the two pads read identically.
final class CameraSilhouetteLayer: CALayer {
    var bubble: CGFloat = 30
    var mirrored = false

    private let shoulders = CALayer()
    private let head = CALayer()

    override init() {
        super.init()
        shoulders.backgroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
        head.backgroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
        addSublayer(shoulders)
        addSublayer(head)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    func tick() {
        let t = CACurrentMediaTime()
        let breathe = 1 + 0.028 * sin(t * 1.15)
        let nod = 2.6 * sin(t * 0.85) + 1.4 * sin(t * 2.05 + 0.7)
        let glance = bubble * 0.028 * CGFloat(sin(t * 0.45 + 2.1))
        let sway = bubble * 0.015 * CGFloat(sin(t * 0.7 + 1.0))
        let size = bubble

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let mirror = CATransform3DMakeScale(mirrored ? -1 : 1, 1, 1)
        transform = mirror

        // Shoulders — bottom half clips out of the bubble (webcam framing).
        let shoulderW = size * 0.92
        let shoulderH = size * 0.55
        shoulders.bounds = CGRect(x: 0, y: 0, width: shoulderW, height: shoulderH)
        shoulders.cornerRadius = shoulderH / 2
        shoulders.position = CGPoint(x: bounds.midX + sway, y: bounds.midY + size * 0.45 + shoulderH * 0)
        shoulders.anchorPoint = CGPoint(x: 0.5, y: 1.0)
        shoulders.position.y = bounds.midY + size * 0.45 + shoulderH / 2
        shoulders.transform = CATransform3DMakeScale(1, CGFloat(breathe), 1)

        // Head — nods about the neck, glances side to side.
        let headSize = size * 0.38
        head.bounds = CGRect(x: 0, y: 0, width: headSize, height: headSize)
        head.cornerRadius = headSize / 2
        head.anchorPoint = CGPoint(x: 0.5, y: 1.0)
        head.position = CGPoint(
            x: bounds.midX + sway + glance,
            y: bounds.midY + size * 0.04 + headSize / 2
        )
        head.transform = CATransform3DMakeRotation(CGFloat(nod) * .pi / 180, 0, 0, 1)

        CATransaction.commit()
    }
}
