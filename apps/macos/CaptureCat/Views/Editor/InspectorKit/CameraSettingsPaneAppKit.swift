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
    // Every control's title/range/step/readout, write and visibility: the
    // shared CameraPane spec (Studio/Editor/Inspector).
    private let showToggle = InspectorToggleControl(CameraPane.show)
    private let noCameraCaption = InspectorKitViews.caption(CameraPane.noCameraCaption)
    private let pad: CameraPreviewPadControl
    private let positionMenu = InspectorMenuControl(CameraPane.position)
    private let shapeMenu = InspectorMenuControl(CameraPane.shape)
    /// Bubble orientation (Auto / Vertical / Wide) — only meaningful for the
    /// aspect-following shapes; hidden for circle/square (always 1:1).
    private let orientationChips = InspectorChipsControl(CameraPane.orientation)
    /// Background removal for the WHOLE video (ProjectSettings.cameraLook):
    /// None / Cutout / Pop-out card. Not a timeline block — camera-layout
    /// blocks still override it for their span.
    private let backgroundLabel = InspectorKitViews.label(CameraPane.background.title)
    private let backgroundChips = InspectorChipsControl(CameraPane.background)
    private let mirrorToggle = InspectorToggleControl(CameraPane.mirror)
    private let sizeSlider = InspectorSliderRow(CameraPane.size)
    /// §12.5 — off keeps the bubble at its size while the screen zooms.
    private let shrinkToggle = InspectorToggleControl(CameraPane.shrink)
    /// §12.12 — vertical videos: camera row on top, screen below.
    private let stackToggle = InspectorToggleControl(CameraPane.stack)
    private let stackHeightSlider = InspectorSliderRow(CameraPane.stackHeight)
    /// §12.14 — the gap between the rows; None joins them into one card.
    private let stackGapSlider = InspectorSliderRow(CameraPane.stackGap)

    // Cutout & Pop-out (docs/camera-cutout.md §12) — whole-video styles for
    // the two looks; the section shows only while the project uses a look.
    private let looksBox = InspectorSectionBox("Cutout & Pop-out")
    private let edgeSoftnessSlider = InspectorSliderRow(CameraPane.edgeSoftness)
    private let edgeInsetSlider = InspectorSliderRow(CameraPane.edgeInset)
    private let popOutSlider = InspectorSliderRow(CameraPane.popOut)
    private let cardLabel = InspectorKitViews.label(CameraPane.cardFill.title)
    private let cardChips = InspectorChipsControl(CameraPane.cardFill)
    private let gradientStartWell = InspectorColorWellControl()
    private let gradientEndWell = InspectorColorWellControl()
    private var gradientRow: NSView!
    private let cardColorWell = InspectorColorWellControl()
    private var cardColorRow: NSView!
    private let backgroundBlurSlider = InspectorSliderRow(CameraPane.backgroundBlur)
    private let cardChooseImageButton = CaptureCatButton(title: "Choose Image…", symbol: "photo", style: .secondary)
    private let cardImageGrid = WallpaperGridControl(mode: .customImages)
    private let cardWallpaperGrid = WallpaperGridControl(mode: .catalog)
    private let cardBorderLabel = InspectorKitViews.label(CameraPane.cardBorder.title)
    private let cardBorderChips = InspectorChipsControl(CameraPane.cardBorder)
    private let cardBorderWidthSlider = InspectorSliderRow(CameraPane.cardBorderWidth)
    private let cardBorderColorWell = InspectorColorWellControl()
    private var cardBorderColorRow: NSView!

    // Adjust section — color sliders + look preset + ring light.
    private let brightnessSlider = InspectorSliderRow(CameraPane.brightness)
    private let contrastSlider = InspectorSliderRow(CameraPane.contrast)
    private let saturationSlider = InspectorSliderRow(CameraPane.saturation)
    private let hueSlider = InspectorSliderRow(CameraPane.hue)
    private let filterChips = InspectorChipsControl(CameraPane.filter)
    private let ringLightSlider = InspectorSliderRow(CameraPane.ringLight)

    // Style section — shape refinement, border, opacity.
    private let cornerRadiusSlider = InspectorSliderRow(CameraPane.cornerRadius)
    private let borderWidthSlider = InspectorSliderRow(CameraPane.borderWidth)
    private let borderColorWell = InspectorColorWellControl()
    private let borderColorReset = InspectorButton(CameraPane.borderColorReset)
    private var borderColorRow: NSView!
    private let opacitySlider = InspectorSliderRow(CameraPane.opacity)
    /// House 2D tilt pad (same control as the Motion pane), capped at ±25°.
    private let tiltPad = TiltPadControl()

    // Name-tag section.
    private let tagTextField = InspectorFlatTextField(CameraPane.tagText)
    private let tagSubtextField = InspectorFlatTextField(CameraPane.tagSubtext)
    private let tagPositionMenu = InspectorMenuControl(CameraPane.tagPosition)
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
        pad.inspectorSpecID = "camera.pad"
        cameraBox.addRow(pad)
        pad.heightAnchor.constraint(equalToConstant: 96).isActive = true

        let positionRow = InspectorKitViews.row(CameraPane.position.title, control: positionMenu)
        let shapeRow = InspectorKitViews.row(CameraPane.shape.title, control: shapeMenu)

        // Border color well + reset back to the default white 30% (nil).
        let borderPair = NSStackView(views: [borderColorWell, borderColorReset])
        borderPair.orientation = .horizontal
        borderPair.spacing = 8
        borderColorRow = InspectorKitViews.row(CameraPane.borderColor.title, control: borderPair)

        let tagPositionRow = InspectorKitViews.row(CameraPane.tagPosition.title, control: tagPositionMenu)
        let tagTextColorRow = InspectorKitViews.row(CameraPane.tagTextColor.title, control: tagTextColorWell)
        let tagBackgroundRow = InspectorKitViews.row(CameraPane.tagFill.title, control: tagBackgroundColorWell)

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
        gradientRow = InspectorKitViews.row(CameraPane.cardGradientStart.title, control: gradientPair)
        cardColorRow = InspectorKitViews.row(CameraPane.cardColor.title, control: cardColorWell)
        cardBorderColorRow = InspectorKitViews.row(CameraPane.cardBorderColor.title, control: cardBorderColorWell)
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

        backgroundChips.toolTip = "Remove the background behind you for the whole video"
        cardChips.toolTip = "What fills the pop-out card behind you"
        shrinkToggle.toolTip = "Shrink the camera while the screen is zoomed in"
        stackToggle.toolTip = "In 9:16 and 4:5 videos, put the camera across the top and the screen below"
        stackGapSlider.toolTip = "Space between the camera and the screen — None joins them into one card"
        tagTextField.delegate = self
        tagSubtextField.delegate = self
        tiltPad.maxAngle = CameraPane.tiltMaxAngle
        tiltPad.inspectorSpecID = "camera.tiltPad"
    }

    /// The pane's scope for the shared spec (built per use — cheap).
    private var scope: InspectorScope {
        var env = InspectorEnvironment()
        env.hasRecordedCamera = hasRecordedCamera
        return InspectorScope(settings: settings, project: project, env: env)
    }

    private func wire() {
        let scope: () -> InspectorScope? = { [weak self] in self?.scope }
        showToggle.bind(CameraPane.show, scope)
        mirrorToggle.bind(CameraPane.mirror, scope)
        sizeSlider.bind(CameraPane.size, scope)
        positionMenu.bind(CameraPane.position, scope)
        shapeMenu.bind(CameraPane.shape, scope)
        orientationChips.bind(CameraPane.orientation, scope)
        backgroundChips.onSelect = { [weak self] index in
            guard let self else { return }
            CameraPane.background.write(self.scope, index)
            // Start finding the person now rather than on the next preview
            // render (idempotent; a fresh mask is reused).
            if let project, project.usesCameraLook { segmentation?.ensureMask(for: project) }
        }

        shrinkToggle.bind(CameraPane.shrink, scope)
        stackToggle.bind(CameraPane.stack, scope)
        stackHeightSlider.bind(CameraPane.stackHeight, scope)
        stackGapSlider.bind(CameraPane.stackGap, scope)

        // Cutout & Pop-out (§12)
        edgeSoftnessSlider.bind(CameraPane.edgeSoftness, scope)
        edgeInsetSlider.bind(CameraPane.edgeInset, scope)
        popOutSlider.bind(CameraPane.popOut, scope)
        backgroundBlurSlider.bind(CameraPane.backgroundBlur, scope)
        cardChips.bind(CameraPane.cardFill, scope)
        gradientStartWell.bind(CameraPane.cardGradientStart, scope)
        gradientEndWell.bind(CameraPane.cardGradientEnd, scope)
        cardColorWell.bind(CameraPane.cardColor, scope, fallback: .black)
        cardChooseImageButton.onClick = { [weak self] in
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.image]
            if panel.runModal() == .OK, let url = panel.url, let self {
                // Same as the canvas background's picker: reference the file,
                // remember a copy so it reappears as a tile.
                CameraPane.adoptCardImage(self.scope, path: url.path)
                CustomWallpaperStore.add(from: url)
                self.cardImageGrid.reloadCustomItems()
            }
        }
        cardImageGrid.onSelect = { [weak self] path in
            guard let self else { return }
            CameraPane.adoptCardImage(self.scope, path: path)
        }
        cardWallpaperGrid.onSelect = { [weak self] path in
            guard let self else { return }
            CameraPane.adoptCardImage(self.scope, path: path)
        }
        cardBorderChips.bind(CameraPane.cardBorder, scope)
        cardBorderWidthSlider.bind(CameraPane.cardBorderWidth, scope)
        cardBorderColorWell.bind(CameraPane.cardBorderColor, scope)

        // Adjust
        brightnessSlider.bind(CameraPane.brightness, scope)
        contrastSlider.bind(CameraPane.contrast, scope)
        saturationSlider.bind(CameraPane.saturation, scope)
        hueSlider.bind(CameraPane.hue, scope)
        ringLightSlider.bind(CameraPane.ringLight, scope)
        filterChips.bind(CameraPane.filter, scope)

        // Style
        cornerRadiusSlider.bind(CameraPane.cornerRadius, scope)
        borderWidthSlider.bind(CameraPane.borderWidth, scope)
        opacitySlider.bind(CameraPane.opacity, scope)
        tiltPad.onChange = { [weak self] pitch, yaw in
            guard let self else { return }
            CameraPane.tilt(self.scope, pitch: pitch, yaw: yaw)
        }
        borderColorWell.bind(CameraPane.borderColor, scope)
        borderColorReset.onClick = { [weak self] in
            guard let self else { return }
            CameraPane.borderColorReset.run(self.scope)
            self.borderColorWell.refresh()
        }

        // Name tag
        tagPositionMenu.bind(CameraPane.tagPosition, scope)
        tagTextColorWell.bind(CameraPane.tagTextColor, scope)
        tagBackgroundColorWell.bind(CameraPane.tagFill, scope, fallback: NSColor(white: 0, alpha: 0.55))
    }

    /// Live text commit as the user types (same behaviour as the menu-bar
    /// title field in BackgroundSettingsPaneAppKit).
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === tagTextField {
            CameraPane.tagText.write(scope, field.stringValue)
        } else if field === tagSubtextField {
            CameraPane.tagSubtext.write(scope, field.stringValue)
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
        let scope = self.scope
        showToggle.isOn = CameraPane.show.read(scope)
        showToggle.isEnabled = CameraPane.show.enabled(scope)
        pad.alphaValue = CameraPane.showDetails(scope) ? 1 : 0.45

        let showDetails = CameraPane.showDetails(scope)
        for view in detailViews { view.isHidden = !showDetails }

        positionMenu.selectedIndex = CameraPane.position.read(scope) ?? 0
        shapeMenu.selectedIndex = CameraPane.shape.read(scope) ?? 0
        mirrorToggle.isOn = CameraPane.mirror.read(scope)
        backgroundChips.selectedIndex = CameraPane.background.read(scope) ?? 0
        sizeSlider.setValue(CameraPane.size.read(scope))

        brightnessSlider.setValue(CameraPane.brightness.read(scope))
        contrastSlider.setValue(CameraPane.contrast.read(scope))
        saturationSlider.setValue(CameraPane.saturation.read(scope))
        hueSlider.setValue(CameraPane.hue.read(scope))
        ringLightSlider.setValue(CameraPane.ringLight.read(scope))
        filterChips.selectedIndex = CameraPane.filter.read(scope) ?? 0

        // Corner radius only applies to the rounded-rect shape.
        // Orientation only applies to the aspect-following shapes — circle
        // and square are always 1:1.
        orientationChips.isHidden = !CameraPane.orientation.visible(scope)
        orientationChips.selectedIndex = CameraPane.orientation.read(scope) ?? 0
        cornerRadiusSlider.isHidden = !CameraPane.cornerRadius.visible(scope)
        cornerRadiusSlider.setValue(CameraPane.cornerRadius.read(scope))
        borderWidthSlider.setValue(CameraPane.borderWidth.read(scope))
        opacitySlider.setValue(CameraPane.opacity.read(scope))
        tiltPad.set(pitch: settings.cameraTiltPitch, yaw: settings.cameraTiltYaw, roll: 0)
        borderColorWell.refresh()

        tagPositionMenu.selectedIndex = CameraPane.tagPosition.read(scope) ?? 0
        if tagTextField.currentEditor() == nil { tagTextField.stringValue = CameraPane.tagText.read(scope) }
        if tagSubtextField.currentEditor() == nil { tagSubtextField.stringValue = CameraPane.tagSubtext.read(scope) }
        tagTextColorWell.refresh()
        tagBackgroundColorWell.refresh()
        pad.refresh()
        shrinkToggle.isOn = CameraPane.shrink.read(scope)
        stackToggle.isOn = CameraPane.stack.read(scope)
        stackHeightSlider.setValue(CameraPane.stackHeight.read(scope))
        let stackShown = CameraPane.stackShown(scope)
        if stackHeightSlider.isHidden != !stackShown {
            stackHeightSlider.isHidden = !stackShown
            if !stackHeightSlider.isHidden { CCMotion.expand(self) }
        }
        stackGapSlider.setValue(CameraPane.stackGap.read(scope))
        if stackGapSlider.isHidden != !stackShown {
            stackGapSlider.isHidden = !stackShown
            if !stackGapSlider.isHidden { CCMotion.expand(self) }
        }
        applyLooksSection(scope)
        applyLookStatus(showDetails: showDetails)
    }

    /// The Cutout & Pop-out section (§12.8): shown while the project uses a
    /// look; the card rows only while a pop-out card can draw, and each fill
    /// shows only its own controls.
    private func applyLooksSection(_ scope: InspectorScope) {
        let shown = CameraPane.looksShown(scope)
        if shown != !looksBox.isHidden {
            looksBox.isHidden = !shown
            if shown {
                // Arrival lands on the house bounce, like the status row.
                CCMotion.expand(self)
                CCMotion.fadeAlpha(looksBox, to: 1, from: 0)
            }
        }
        guard shown else { return }

        edgeSoftnessSlider.setValue(CameraPane.edgeSoftness.read(scope))
        edgeInsetSlider.setValue(CameraPane.edgeInset.read(scope))
        popOutSlider.setValue(CameraPane.popOut.read(scope))
        backgroundBlurSlider.setValue(CameraPane.backgroundBlur.read(scope))
        cardChips.selectedIndex = CameraPane.cardFill.read(scope) ?? 0
        cardBorderChips.selectedIndex = CameraPane.cardBorder.read(scope) ?? 0
        cardBorderWidthSlider.setValue(CameraPane.cardBorderWidth.read(scope))
        for well in [gradientStartWell, gradientEndWell, cardColorWell, cardBorderColorWell] { well.refresh() }

        let usesPopOut = CameraPane.usesPopOut(scope)
        let card: [NSView] = [popOutSlider, cardLabel, cardChips, cardBorderLabel, cardBorderChips]
        for view in card { view.isHidden = !usesPopOut }
        gradientRow.isHidden = !CameraPane.cardGradientStart.visible(scope)
        cardColorRow.isHidden = !CameraPane.cardColor.visible(scope)
        backgroundBlurSlider.isHidden = !CameraPane.backgroundBlur.visible(scope)
        let showsImage = CameraPane.cardImageVisible(scope)
        cardChooseImageButton.isHidden = !showsImage
        cardImageGrid.isHidden = !showsImage
        cardWallpaperGrid.isHidden = !showsImage
        if showsImage {
            cardImageGrid.selectedPath = settings.cameraCardImagePath
            cardImageGrid.loadIfNeeded()
            cardWallpaperGrid.selectedPath = settings.cameraCardImagePath
            cardWallpaperGrid.loadIfNeeded()
        }
        cardBorderWidthSlider.isHidden = !CameraPane.cardBorderWidth.visible(scope)
        cardBorderColorRow.isHidden = !CameraPane.cardBorderColor.visible(scope)
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
        InspectorPadMath.cameraBubbleDiameter(cameraSize: settings.effectiveCameraSize)
    }

    private var fraction: CGPoint { InspectorPadMath.cameraFraction(settings) }

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

    #if DEBUG
    /// Probe seam: the point a press must land on for bubble fraction (fx, fy).
    func probePoint(fx: CGFloat, fy: CGFloat) -> NSPoint {
        let bubble = bubbleSize
        let usableW = max(1, bounds.width - bubble - 2 * inset)
        let usableH = max(1, bounds.height - bubble - 2 * inset)
        return NSPoint(x: inset + bubble / 2 + fx * usableW, y: inset + bubble / 2 + fy * usableH)
    }
    #endif

    private func place(at point: NSPoint) {
        let bubble = bubbleSize
        let usableW = max(1, bounds.width - bubble - 2 * inset)
        let usableH = max(1, bounds.height - bubble - 2 * inset)
        let fx = (point.x - inset - bubble / 2) / usableW
        let fy = (point.y - inset - bubble / 2) / usableH
        InspectorPadMath.cameraDrag(settings, fx: fx, fy: fy)
        needsLayout = true
    }

    override func mouseDown(with event: NSEvent) {
        place(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        place(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        // A release near a corner collapses to the clean corner enum
        // (InspectorPadMath, shared with the iOS pad).
        let before = (settings.cameraCustomX, settings.cameraCustomY)
        InspectorPadMath.cameraRelease(settings)
        if before != (settings.cameraCustomX, settings.cameraCustomY) { needsLayout = true }
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
