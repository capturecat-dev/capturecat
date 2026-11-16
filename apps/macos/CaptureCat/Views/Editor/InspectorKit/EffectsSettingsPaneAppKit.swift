import AppKit
import UniformTypeIdentifiers

/// The Effects tab — every project-wide effect in ONE list, each with an
/// enable switch, always visible (no need to add something first to discover
/// it). A switch turns the effect on with sensible defaults; its detail
/// controls appear underneath while it is on. Zoom and Tilt (timeline
/// blocks) live in MotionSettingsPaneAppKit's flat list, which embeds this
/// pane for the project-wide effects — ONE Effects concept either way.
@MainActor
final class EffectsSettingsPaneAppKit: NSView {
    private let project: Project
    private let settings: ProjectSettings

    private let stack = NSStackView()

    /// Consulted when Slide flips ON: returns true if the slide was joined to
    /// a selected block (span snapped); false → plain global slide.
    var onSlideEnabled: (() -> Bool)?

    // Every control's title/range/step/readout, write and visibility: the
    // shared EffectsPane spec (Studio/Editor/Inspector).
    private let slideToggle = InspectorToggleControl(EffectsPane.slide)
    private let slideChips = InspectorChipsControl(EffectsPane.slideStyle)
    private let slidePad = EffectPreviewPadControl()
    // Slide length is set ONLY by dragging the block's edge on the EFFECTS
    // lane — a slider here would bypass the timeline's no-overlap clamp.
    private let slideBounceSlider = InspectorSliderRow(EffectsPane.slideBounce)
    /// Pace within the block: 1x spans the whole block, higher lands early
    /// and holds. Length itself stays timeline-only.
    private let slideSpeedSlider = InspectorSliderRow(EffectsPane.slideSpeed)
    private let slideDepthToggle = InspectorToggleControl(EffectsPane.slideDepth)
    private let slideCaption = InspectorKitViews.captionLine(EffectsPane.slideCaption)

    private let curtainToggle = InspectorToggleControl(EffectsPane.curtain)
    private let curtainChips = InspectorChipsControl(EffectsPane.curtainCorner)
    private let curtainDurationSlider = InspectorSliderRow(EffectsPane.curtainLength)
    private let curtainColorWell = InspectorColorWellControl()
    private var curtainColorRow: NSView!
    private let curtainColorResetButton = InspectorButton(EffectsPane.curtainColorReset)
    private let curtainLogoChooseButton = InspectorButton("Choose Logo…")
    private let curtainLogoRemoveButton = InspectorButton(EffectsPane.curtainLogoRemove)
    private let curtainLogoButtons = NSStackView()
    private let curtainLogoOpacitySlider = InspectorSliderRow(EffectsPane.curtainLogoOpacity)
    private let curtainLogoSizeSlider = InspectorSliderRow(EffectsPane.curtainLogoSize)
    private let curtainLogoTintToggle = InspectorToggleControl(EffectsPane.curtainLogoTint)
    private let curtainLogoTintWell = InspectorColorWellControl()
    private var curtainLogoTintRow: NSView!
    private let curtainCaption = InspectorKitViews.captionLine(EffectsPane.curtainCaption)

    private let parallaxToggle = InspectorToggleControl(EffectsPane.parallax)
    private let parallaxSlider = InspectorSliderRow(EffectsPane.parallaxStrength)
    private let parallaxPad = PropertyPreviewPadControl()
    private let parallaxCaption = InspectorKitViews.captionLine(EffectsPane.parallaxCaption)

    private let blurToggle = InspectorToggleControl(EffectsPane.motionBlur)
    private let blurStrengthSlider = InspectorSliderRow(EffectsPane.motionBlurStrength)
    private let blurPad = PropertyPreviewPadControl()
    private let blurCaption = InspectorKitViews.captionLine(EffectsPane.motionBlurCaption)

    override var isFlipped: Bool { true }

    init(project: Project) {
        self.project = project
        self.settings = project.settings
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

        func fullWidth(_ view: NSView) {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        // One grouped box per effect — switch first, details while it's on,
        // a single-line caption (full story in the tooltip) at the bottom.
        let slideBox = InspectorSectionBox("Slide")
        slideBox.addRow(slideToggle)
        slideBox.addRow(slideChips)
        slideBox.addRow(slidePad, attached: true)
        slidePad.heightAnchor.constraint(equalToConstant: 96).isActive = true
        slideBox.addRow(slideBounceSlider)
        slideBox.addRow(slideSpeedSlider)
        slideBox.addRow(slideDepthToggle)
        slideBox.addRow(slideCaption, attached: true)
        fullWidth(slideBox)

        let curtainBox = InspectorSectionBox("Curtain Unveil")
        curtainBox.addRow(curtainToggle)
        curtainBox.addRow(curtainChips)
        curtainBox.addRow(curtainDurationSlider)
        curtainColorRow = InspectorKitViews.row(EffectsPane.curtainColor.title, control: curtainColorWell)
        curtainBox.addRow(curtainColorRow)
        curtainBox.addRow(curtainColorResetButton, attached: true)
        curtainLogoButtons.orientation = .horizontal
        curtainLogoButtons.spacing = 8
        curtainLogoButtons.addArrangedSubview(curtainLogoChooseButton)
        curtainLogoButtons.addArrangedSubview(curtainLogoRemoveButton)
        curtainBox.addRow(curtainLogoButtons)
        curtainBox.addRow(curtainLogoOpacitySlider)
        curtainBox.addRow(curtainLogoSizeSlider)
        curtainBox.addRow(curtainLogoTintToggle)
        curtainLogoTintRow = InspectorKitViews.row(EffectsPane.curtainLogoTintColor.title, control: curtainLogoTintWell)
        curtainBox.addRow(curtainLogoTintRow)
        curtainBox.addRow(curtainCaption, attached: true)
        fullWidth(curtainBox)

        let parallaxBox = InspectorSectionBox("Parallax")
        parallaxBox.addRow(parallaxToggle)
        parallaxBox.addRow(parallaxSlider)
        parallaxBox.addRow(parallaxPad, attached: true)
        parallaxPad.heightAnchor.constraint(equalToConstant: 96).isActive = true
        parallaxBox.addRow(parallaxCaption, attached: true)
        fullWidth(parallaxBox)

        let blurBox = InspectorSectionBox("Motion Blur")
        blurBox.addRow(blurToggle)
        blurBox.addRow(blurStrengthSlider)
        blurBox.addRow(blurPad, attached: true)
        blurPad.heightAnchor.constraint(equalToConstant: 96).isActive = true
        blurBox.addRow(blurCaption, attached: true)
        fullWidth(blurBox)

        let scope: () -> InspectorScope? = { [weak self] in self?.scope }
        slideToggle.bind(EffectsPane.slide, scope)
        slideChips.bind(EffectsPane.slideStyle, scope)
        slideBounceSlider.bind(EffectsPane.slideBounce, scope)
        slideSpeedSlider.bind(EffectsPane.slideSpeed, scope)
        slideDepthToggle.bind(EffectsPane.slideDepth, scope)
        curtainToggle.bind(EffectsPane.curtain, scope)
        curtainChips.bind(EffectsPane.curtainCorner, scope)
        curtainDurationSlider.bind(EffectsPane.curtainLength, scope)
        curtainColorWell.bind(EffectsPane.curtainColor, scope, fallback: Self.defaultCurtainNSColor)
        curtainColorResetButton.bind(EffectsPane.curtainColorReset, scope)
        curtainLogoChooseButton.inspectorSpecID = "effects.curtainLogoChoose"
        curtainLogoChooseButton.onClick = { [weak self] in self?.pickCurtainLogo() }
        curtainLogoRemoveButton.bind(EffectsPane.curtainLogoRemove, scope)
        curtainLogoOpacitySlider.bind(EffectsPane.curtainLogoOpacity, scope)
        curtainLogoSizeSlider.bind(EffectsPane.curtainLogoSize, scope)
        curtainLogoTintToggle.bind(EffectsPane.curtainLogoTint, scope)
        curtainLogoTintWell.bind(EffectsPane.curtainLogoTintColor, scope)
        parallaxToggle.bind(EffectsPane.parallax, scope)
        parallaxSlider.bind(EffectsPane.parallaxStrength, scope)
        blurToggle.bind(EffectsPane.motionBlur, scope)
        blurStrengthSlider.bind(EffectsPane.motionBlurStrength, scope)

        observe()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The math's shared charcoal top stop as NSColor — shown in the well
    /// when no custom curtain color is set.
    private static var defaultCurtainNSColor: NSColor {
        let c = CurtainUnveilMath.coverColorTop
        return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
    }


    /// The pane's scope for the shared spec — the selection only matters to
    /// Slide (joining the selected block).
    private var scope: InspectorScope {
        InspectorScope(settings: settings, project: project,
                       motion: .joinOnly { [weak self] in self?.onSlideEnabled?() ?? false })
    }

    // Same pick/copy semantics as the Brand pane's watermark: copy into the
    // project folder under a fresh name (cache-busting), remove the old file
    // (EffectsPane.adoptCurtainLogo, shared with iOS).
    private func pickCurtainLogo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .pdf]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a logo image (PNG with transparency works best)"
        guard panel.runModal() == .OK, let source = panel.url else { return }
        do {
            try EffectsPane.adoptCurtainLogo(scope, from: source)
        } catch InspectorMediaError.noProjectFolder {
            return
        } catch {
            NSSound.beep()
        }
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

    private func applySettings() {
        let scope = self.scope
        let slideOn = EffectsPane.slide.read(scope)
        slideToggle.isOn = slideOn
        slideChips.isHidden = !EffectsPane.slideStyle.visible(scope)
        slidePad.isHidden = !slideOn
        slideBounceSlider.isHidden = !EffectsPane.slideBounce.visible(scope)
        slideSpeedSlider.isHidden = !EffectsPane.slideSpeed.visible(scope)
        slideDepthToggle.isHidden = !EffectsPane.slideDepth.visible(scope)
        if slideOn {
            slideChips.selectedIndex = EffectsPane.slideStyle.read(scope) ?? 0
            slidePad.mode = .slide(
                style: settings.introSlideStyle,
                duration: settings.introSlideDuration,
                bounce: settings.introSlideBounce,
                depth: settings.introSlideDepth)
        }
        slideDepthToggle.isOn = EffectsPane.slideDepth.read(scope)
        slideBounceSlider.setValue(EffectsPane.slideBounce.read(scope))
        slideSpeedSlider.setValue(EffectsPane.slideSpeed.read(scope))

        let curtainOn = EffectsPane.curtain.read(scope)
        let hasLogo = settings.curtainLogoFileName != nil
        curtainToggle.isOn = curtainOn
        curtainChips.isHidden = !EffectsPane.curtainCorner.visible(scope)
        curtainDurationSlider.isHidden = !EffectsPane.curtainLength.visible(scope)
        curtainColorRow.isHidden = !EffectsPane.curtainColor.visible(scope)
        curtainColorResetButton.isHidden = !EffectsPane.curtainColorReset.visible(scope)
        curtainLogoButtons.isHidden = !EffectsPane.curtainLogoChooseVisible(scope)
        curtainLogoRemoveButton.isHidden = !hasLogo
        curtainLogoOpacitySlider.isHidden = !EffectsPane.curtainLogoOpacity.visible(scope)
        curtainLogoSizeSlider.isHidden = !EffectsPane.curtainLogoSize.visible(scope)
        curtainLogoTintToggle.isHidden = !EffectsPane.curtainLogoTint.visible(scope)
        curtainLogoTintRow.isHidden = !EffectsPane.curtainLogoTintColor.visible(scope)
        if curtainOn {
            curtainChips.selectedIndex = EffectsPane.curtainCorner.read(scope) ?? 0
            curtainDurationSlider.setValue(EffectsPane.curtainLength.read(scope))
            curtainColorWell.refresh()
            curtainLogoChooseButton.title = EffectsPane.curtainLogoChooseTitle(scope)
            curtainLogoOpacitySlider.setValue(EffectsPane.curtainLogoOpacity.read(scope))
            curtainLogoSizeSlider.setValue(EffectsPane.curtainLogoSize.read(scope))
            curtainLogoTintToggle.isOn = EffectsPane.curtainLogoTint.read(scope)
            curtainLogoTintWell.refresh()
        }

        let parallaxOn = EffectsPane.parallax.read(scope)
        parallaxToggle.isOn = parallaxOn
        parallaxSlider.isHidden = !EffectsPane.parallaxStrength.visible(scope)
        parallaxPad.isHidden = !parallaxOn
        if parallaxOn {
            parallaxSlider.setValue(EffectsPane.parallaxStrength.read(scope))
            parallaxPad.mode = .parallax(strength: settings.parallaxStrength)
        }

        blurToggle.isOn = EffectsPane.motionBlur.read(scope)
        blurStrengthSlider.isHidden = !EffectsPane.motionBlurStrength.visible(scope)
        if settings.motionBlur {
            blurStrengthSlider.setValue(EffectsPane.motionBlurStrength.read(scope))
        }
        blurPad.isHidden = !settings.motionBlur
        blurPad.mode = .motionBlur(on: settings.motionBlur, strength: settings.motionBlurStrength)
    }
}
