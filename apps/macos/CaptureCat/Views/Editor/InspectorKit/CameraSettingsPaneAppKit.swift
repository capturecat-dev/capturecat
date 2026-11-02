import AppKit
import UniformTypeIdentifiers

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
    /// Background removal for the WHOLE video (ProjectSettings.cameraLook):
    /// None / Cutout / Pop-out card. Not a timeline block — camera-layout
    /// blocks still override it for their span.
    private let backgroundLabel = InspectorKitViews.label("Background")
    private let backgroundChips = InspectorChipsControl()
    private static let backgroundLooks: [CameraBubbleLook?] = [nil] + CameraBubbleLook.allCases
    private let mirrorToggle = InspectorToggleControl("Mirror Camera")
    private let sizeSlider: InspectorSliderRow
    /// §12.5 — off keeps the bubble at its size while the screen zooms.
    private let shrinkToggle = InspectorToggleControl("Shrink During Zoom")
    /// §12.12 — vertical videos: camera row on top, screen below.
    private let stackToggle = InspectorToggleControl("Stack on Top in Vertical Video")
    private let stackHeightSlider = InspectorSliderRow(label: "Camera Height", range: 25...70, step: 1)
    /// §12.14 — the gap between the rows; None joins them into one card.
    private let stackGapSlider = InspectorSliderRow(label: "Gap", range: 0...8, step: 1)

    // Cutout & Pop-out (docs/camera-cutout.md §12) — whole-video styles for
    // the two looks; the section shows only while the project uses a look.
    private let looksBox = InspectorSectionBox("Cutout & Pop-out")
    private let edgeSoftnessSlider = InspectorSliderRow(label: "Edge Softness", range: 0...1, step: 0.05)
    private let edgeInsetSlider = InspectorSliderRow(label: "Edge Inset", range: 0...1, step: 0.05)
    private let popOutSlider = InspectorSliderRow(label: "Pop-out", range: 0...1, step: 0.05)
    private let cardLabel = InspectorKitViews.label("Card")
    private let cardChips = InspectorChipsControl()
    private let gradientStartWell = InspectorColorWellControl()
    private let gradientEndWell = InspectorColorWellControl()
    private var gradientRow: NSView!
    private let cardColorWell = InspectorColorWellControl()
    private var cardColorRow: NSView!
    private let backgroundBlurSlider = InspectorSliderRow(label: "Background Blur", range: 0...1, step: 0.05)
    private let cardChooseImageButton = CaptureCatButton(title: "Choose Image…", symbol: "photo", style: .secondary)
    private let cardImageGrid = WallpaperGridControl(mode: .customImages)
    private let cardWallpaperGrid = WallpaperGridControl(mode: .catalog)
    private let cardBorderLabel = InspectorKitViews.label("Border")
    private let cardBorderChips = InspectorChipsControl()
    private static let cardBorders: [CameraCardBorder?] = [nil] + CameraCardBorder.allCases
    private let cardBorderWidthSlider = InspectorSliderRow(label: "Thickness", range: 0...1, step: 0.05)
    private let cardBorderColorWell = InspectorColorWellControl()
    private var cardBorderColorRow: NSView!

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

    // Camera looks — background-removal status (docs/camera-cutout.md §9).
    private let project: Project?
    private let segmentation: CameraSegmentation?
    private let lookStatusRow = NSStackView()
    private let lookStatusLabel = InspectorKitViews.captionLine("")
    private let lookStatusBar = CCProgressBar()
    private var lookStatusShown = false
    private var lastLookStatus: CameraSegmentation.Status?

    private var detailViews: [NSView] = []
    private var cornerRadiusRow: NSView { cornerRadiusSlider }
    private var isObserving = false

    override var isFlipped: Bool { true }

    init(
        settings: ProjectSettings,
        hasRecordedCamera: Bool,
        project: Project? = nil,
        segmentation: CameraSegmentation? = nil
    ) {
        self.settings = settings
        self.hasRecordedCamera = hasRecordedCamera
        self.project = project
        self.segmentation = segmentation
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

        // Background first, right under the pad: below Shape it would
        // inherit the hidden orientation chips' 6pt gap on circle/square.
        cameraBox.addRow(backgroundLabel)
        cameraBox.addRow(backgroundChips, attached: true)
        // Background removal for the Cutout / Pop-out card looks: a caption
        // over the house progress bar (springs to each value; sweeps while
        // queued), right under the choice that starts it. Shown only while
        // the project uses a look.
        lookStatusRow.orientation = .vertical
        lookStatusRow.alignment = .leading
        lookStatusRow.spacing = 6
        lookStatusRow.addArrangedSubview(lookStatusLabel)
        lookStatusRow.addArrangedSubview(lookStatusBar)
        lookStatusBar.widthAnchor.constraint(equalTo: lookStatusRow.widthAnchor).isActive = true
        lookStatusLabel.widthAnchor.constraint(equalTo: lookStatusRow.widthAnchor).isActive = true
        lookStatusRow.wantsLayer = true
        lookStatusRow.isHidden = true
        // Not `attached`: while hidden it would pull Position up tight
        // against the chips.
        cameraBox.addRow(lookStatusRow)
        cameraBox.addRow(positionRow)
        cameraBox.addRow(shapeRow)
        cameraBox.addRow(orientationChips, attached: true)
        cameraBox.addRow(mirrorToggle)
        cameraBox.addRow(sizeSlider)
        cameraBox.addRow(shrinkToggle)
        cameraBox.addRow(stackToggle)
        cameraBox.addRow(stackHeightSlider, attached: true)
        cameraBox.addRow(stackGapSlider, attached: true)
        fullWidth(cameraBox)

        // Cutout & Pop-out: edges first (both looks), then the card.
        let gradientPair = NSStackView(views: [gradientStartWell, gradientEndWell])
        gradientPair.orientation = .horizontal
        gradientPair.spacing = 8
        gradientRow = InspectorKitViews.row("Card Colors", control: gradientPair)
        cardColorRow = InspectorKitViews.row("Card Color", control: cardColorWell)
        cardBorderColorRow = InspectorKitViews.row("Border Color", control: cardBorderColorWell)
        looksBox.addRow(edgeSoftnessSlider)
        looksBox.addRow(edgeInsetSlider)
        looksBox.addRow(popOutSlider)
        looksBox.addRow(cardLabel)
        looksBox.addRow(cardChips, attached: true)
        looksBox.addRow(gradientRow)
        looksBox.addRow(cardColorRow)
        looksBox.addRow(backgroundBlurSlider)
        looksBox.addRow(cardChooseImageButton)
        looksBox.addRow(cardImageGrid, attached: true)
        looksBox.addRow(cardWallpaperGrid)
        looksBox.addRow(cardBorderLabel)
        looksBox.addRow(cardBorderChips, attached: true)
        looksBox.addRow(cardBorderWidthSlider)
        looksBox.addRow(cardBorderColorRow)
        fullWidth(looksBox)

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
            backgroundLabel, backgroundChips, positionRow, shapeRow, orientationChips, mirrorToggle, sizeSlider,
            shrinkToggle, stackToggle, adjustBox, styleBox, tagBox,
        ]

        positionMenu.items = ProjectSettings.CameraPosition.allCases.map { .init(title: $0.rawValue) }
        shapeMenu.items = ProjectSettings.CameraShape.allCases.map { .init(title: $0.rawValue) }
        orientationChips.items = ProjectSettings.CameraOrientation.allCases.map(\.rawValue)
        backgroundChips.items = Self.backgroundLooks.map { $0?.displayName ?? "None" }
        backgroundChips.toolTip = "Remove the background behind you for the whole video"
        tagPositionMenu.items = ProjectSettings.CameraTagPosition.allCases.map { .init(title: $0.rawValue) }
        filterChips.items = ProjectSettings.CameraFilterStyle.allCases.map(\.rawValue)
        sizeSlider.format = { $0.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int($0))%" : String(format: "%.1f%%", $0) }
        hueSlider.format = { "\(Int($0))°" }
        ringLightSlider.format = { "\(Int($0 * 100))%" }
        opacitySlider.format = { "\(Int($0 * 100))%" }
        for slider in [edgeSoftnessSlider, edgeInsetSlider, popOutSlider, backgroundBlurSlider, cardBorderWidthSlider] {
            slider.format = { "\(Int(($0 * 100).rounded()))%" }
        }
        cardChips.items = CameraCardFill.allCases.map(\.displayName)
        cardChips.toolTip = "What fills the pop-out card behind you"
        cardBorderChips.items = Self.cardBorders.map { $0?.displayName ?? "None" }
        shrinkToggle.toolTip = "Shrink the camera while the screen is zoomed in"
        stackToggle.toolTip = "In 9:16 and 4:5 videos, put the camera across the top and the screen below"
        stackHeightSlider.format = { "\(Int($0.rounded()))%" }
        stackGapSlider.format = { $0 < 0.5 ? "None" : "\(Int($0.rounded()))%" }
        stackGapSlider.toolTip = "Space between the camera and the screen — None joins them into one card"
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
        backgroundChips.onSelect = { [weak self] index in
            guard let self else { return }
            settings.cameraLook = Self.backgroundLooks[index]
            // Start finding the person now rather than on the next preview
            // render (idempotent; a fresh mask is reused).
            if let project, project.usesCameraLook { segmentation?.ensureMask(for: project) }
        }

        shrinkToggle.onChange = { [weak self] on in
            // Default (on) is stored as nil so untouched projects stay byte-identical.
            self?.settings.cameraShrinkOnZoom = on ? nil : false
        }
        stackToggle.onChange = { [weak self] on in self?.settings.cameraPortraitStack = on }
        stackHeightSlider.onChange = { [weak self] percent in self?.settings.cameraStackRatio = percent / 100 }
        stackGapSlider.onChange = { [weak self] percent in self?.settings.cameraStackGap = percent.rounded() / 100 }

        // Cutout & Pop-out (§12)
        edgeSoftnessSlider.onChange = { [weak self] v in self?.settings.cameraEdgeSoftness = v }
        edgeInsetSlider.onChange = { [weak self] v in self?.settings.cameraEdgeInset = v }
        popOutSlider.onChange = { [weak self] v in self?.settings.cameraPopOutAmount = v }
        backgroundBlurSlider.onChange = { [weak self] v in self?.settings.cameraBackgroundBlur = v }
        cardChips.onSelect = { [weak self] index in
            self?.settings.cameraCardFill = CameraCardFill.allCases[index]
        }
        gradientStartWell.getColor = { [weak self] in
            guard let self else { return .white }
            return Self.nsColor(CameraCardStyle(self.settings).gradientTop)
        }
        gradientStartWell.setColor = { [weak self] c in self?.settings.cameraCardGradientStart = CodableColor(c) }
        gradientEndWell.getColor = { [weak self] in
            guard let self else { return .white }
            return Self.nsColor(CameraCardStyle(self.settings).gradientBottom)
        }
        gradientEndWell.setColor = { [weak self] c in self?.settings.cameraCardGradientEnd = CodableColor(c) }
        cardColorWell.getColor = { [weak self] in
            guard let self else { return .black }
            return Self.nsColor(CameraCardStyle(self.settings).color)
        }
        cardColorWell.setColor = { [weak self] c in self?.settings.cameraCardColor = CodableColor(c) }
        cardChooseImageButton.onClick = { [weak self] in
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.image]
            if panel.runModal() == .OK, let url = panel.url {
                // Same as the canvas background's picker: reference the file,
                // remember a copy so it reappears as a tile.
                self?.settings.cameraCardImagePath = url.path
                CustomWallpaperStore.add(from: url)
                self?.cardImageGrid.reloadCustomItems()
            }
        }
        cardImageGrid.onSelect = { [weak self] path in self?.settings.cameraCardImagePath = path }
        cardWallpaperGrid.onSelect = { [weak self] path in self?.settings.cameraCardImagePath = path }
        cardBorderChips.onSelect = { [weak self] index in
            self?.settings.cameraCardBorder = Self.cardBorders[index]
        }
        cardBorderWidthSlider.onChange = { [weak self] v in self?.settings.cameraCardBorderWidth = v }
        cardBorderColorWell.getColor = { [weak self] in
            guard let self else { return .white }
            return Self.nsColor(CameraCardStyle(self.settings).borderColor)
        }
        cardBorderColorWell.setColor = { [weak self] c in self?.settings.cameraCardBorderColor = CodableColor(c) }

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
        backgroundChips.selectedIndex = Self.backgroundLooks.firstIndex(of: settings.cameraLook) ?? 0
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
        shrinkToggle.isOn = settings.cameraShrinkOnZoom ?? true
        let stackOn = settings.cameraPortraitStack ?? false
        stackToggle.isOn = stackOn
        stackHeightSlider.setValue(CameraLayoutMath.stackRatio(settings.cameraStackRatio) * 100)
        if stackHeightSlider.isHidden != (!showDetails || !stackOn) {
            stackHeightSlider.isHidden = !showDetails || !stackOn
            if !stackHeightSlider.isHidden { CCMotion.expand(self) }
        }
        stackGapSlider.setValue(CameraLayoutMath.stackGap(settings.cameraStackGap) * 100)
        if stackGapSlider.isHidden != (!showDetails || !stackOn) {
            stackGapSlider.isHidden = !showDetails || !stackOn
            if !stackGapSlider.isHidden { CCMotion.expand(self) }
        }
        applyLooksSection(showDetails: showDetails)
        applyLookStatus(showDetails: showDetails)
    }

    private static func nsColor(_ c: CameraCardStyle.RGB) -> NSColor {
        NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
    }

    /// The Cutout & Pop-out section (§12.8): shown while the project uses a
    /// look; the card rows only while a pop-out card can draw, and each fill
    /// shows only its own controls.
    private func applyLooksSection(showDetails: Bool) {
        let regionLooks = project?.cameraLayoutRegions.compactMap(\.effectiveLook) ?? []
        let usesLook = settings.cameraLook != nil || !regionLooks.isEmpty
        let usesPopOut = settings.cameraLook == .popOut || regionLooks.contains(.popOut)
        let shown = showDetails && usesLook
        if shown != !looksBox.isHidden {
            looksBox.isHidden = !shown
            if shown {
                // Arrival lands on the house bounce, like the status row.
                CCMotion.expand(self)
                CCMotion.fadeAlpha(looksBox, to: 1, from: 0)
            }
        }
        guard shown else { return }
        let style = CameraCardStyle(settings)

        edgeSoftnessSlider.setValue(style.edgeSoftness)
        edgeInsetSlider.setValue(style.edgeInset)
        popOutSlider.setValue(style.popOutAmount ?? 0.5)
        backgroundBlurSlider.setValue(min(1, max(0, settings.cameraBackgroundBlur ?? 0)))
        cardChips.selectedIndex = CameraCardFill.allCases.firstIndex(of: style.fill) ?? 0
        cardBorderChips.selectedIndex = Self.cardBorders.firstIndex(of: style.border) ?? 0
        cardBorderWidthSlider.setValue(style.borderThickness)
        for well in [gradientStartWell, gradientEndWell, cardColorWell, cardBorderColorWell] { well.refresh() }

        let card: [NSView] = [popOutSlider, cardLabel, cardChips, cardBorderLabel, cardBorderChips]
        for view in card { view.isHidden = !usesPopOut }
        gradientRow.isHidden = !usesPopOut || style.fill != .gradient
        cardColorRow.isHidden = !usesPopOut || style.fill != .color
        backgroundBlurSlider.isHidden = !usesPopOut || style.fill != .camera
        let showsImage = usesPopOut && style.fill == .image
        cardChooseImageButton.isHidden = !showsImage
        cardImageGrid.isHidden = !showsImage
        cardWallpaperGrid.isHidden = !showsImage
        if showsImage {
            cardImageGrid.selectedPath = settings.cameraCardImagePath
            cardImageGrid.loadIfNeeded()
            cardWallpaperGrid.selectedPath = settings.cameraCardImagePath
            cardWallpaperGrid.loadIfNeeded()
        }
        cardBorderWidthSlider.isHidden = !usesPopOut || style.border == nil
        cardBorderColorRow.isHidden = !usesPopOut || style.border != .solid
    }

    /// "Removing background… 42%" while the mask job runs for this project.
    /// Reads the @Observable CameraSegmentation (and the project's regions)
    /// inside the observation loop, so progress ticks re-apply.
    private func applyLookStatus(showDetails: Bool) {
        let status: CameraSegmentation.Status = {
            guard let project, let segmentation else { return .notNeeded }
            _ = segmentation.revision
            return segmentation.status(for: project)
        }()
        let show = showDetails && status != .notNeeded
        if show != lookStatusShown {
            lookStatusShown = show
            lookStatusRow.isHidden = !show
            if show {
                // Arrival: the row lands on the house bounce, then fades in.
                CCMotion.expand(self)
                CCMotion.fadeAlpha(lookStatusRow, to: 1, from: 0)
            }
        }
        guard show, status != lastLookStatus else { return }
        let previous = lastLookStatus
        lastLookStatus = status
        let text: String
        switch status {
        case .notNeeded:
            return
        case .ready:
            text = "Background removed — Cutout and Pop-out card are live."
            lookStatusBar.isIndeterminate = false
            lookStatusBar.doubleValue = 1
        case .queued:
            text = "Removing background — waiting to start…"
            lookStatusBar.isIndeterminate = true
        case .running(let p):
            text = "Removing background… \(Int((p * 100).rounded()))%"
            lookStatusBar.isIndeterminate = false
            lookStatusBar.doubleValue = p
        case .paused(let p):
            text = "Paused while recording or exporting — \(Int((p * 100).rounded()))%"
            lookStatusBar.isIndeterminate = false
            lookStatusBar.doubleValue = p
        case .failed(let message):
            text = "Couldn't remove the background: \(message)"
            lookStatusBar.isIndeterminate = false
            lookStatusBar.doubleValue = 0
        }
        let barHidden: Bool = {
            if case .ready = status { return true }
            if case .failed = status { return true }
            return false
        }()
        lookStatusBar.isHidden = barHidden
        lookStatusLabel.toolTip = text
        // Phase changes crossfade; percent ticks just update in place.
        if let previous, Self.phase(previous) != Self.phase(status) {
            CCMotion.fadeContentSwap(lookStatusLabel)
        }
        lookStatusLabel.stringValue = text
    }

    private static func phase(_ status: CameraSegmentation.Status) -> Int {
        switch status {
        case .notNeeded: return 0
        case .ready: return 1
        case .queued: return 2
        case .running: return 3
        case .paused: return 4
        case .failed: return 5
        }
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
