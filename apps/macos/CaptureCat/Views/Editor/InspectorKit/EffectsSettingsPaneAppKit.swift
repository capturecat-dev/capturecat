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

    private let slideToggle = InspectorToggleControl("Slide")
    private let slideChips = InspectorChipsControl()
    private let slidePad = EffectPreviewPadControl()
    // Slide length is set ONLY by dragging the block's edge on the EFFECTS
    // lane — a slider here would bypass the timeline's no-overlap clamp.
    private let slideBounceSlider = InspectorSliderRow(label: "Bounce", range: 0...1, step: 0.05)
    /// Pace within the block: 1x spans the whole block, higher lands early
    /// and holds. Length itself stays timeline-only.
    private let slideSpeedSlider = InspectorSliderRow(label: "Speed", range: 1...4, step: 0.25)
    private let slideDepthToggle = InspectorToggleControl("Pull Toward Viewer")
    private let slideCaption = InspectorKitViews.captionLine(
        "Slides in from an edge — drag the Slide block on the EFFECTS lane to place it.",
        full: "The screen slides from an edge with a punchy settle. Pull Toward Viewer adds a 3D depth pull — the card starts small and deep, then dollies to the front as it lands. Drag the yellow Slide block on the EFFECTS lane to place it anywhere — at 0:00 it plays as the intro."
    )

    private let curtainToggle = InspectorToggleControl("Curtain Unveil")
    private let curtainChips = InspectorChipsControl()
    private let curtainDurationSlider = InspectorSliderRow(label: "Length", range: 0.4...3.0, step: 0.1)
    private let curtainColorWell = InspectorColorWellControl()
    private var curtainColorRow: NSView!
    private let curtainColorResetButton = InspectorButton("Reset Color")
    private let curtainLogoChooseButton = InspectorButton("Choose Logo…")
    private let curtainLogoRemoveButton = InspectorButton("Remove Logo", destructive: true)
    private let curtainLogoButtons = NSStackView()
    private let curtainLogoOpacitySlider = InspectorSliderRow(label: "Logo Opacity", range: 0...1, step: 0.05)
    private let curtainLogoSizeSlider = InspectorSliderRow(label: "Logo Size", range: 0.05...0.8, step: 0.05)
    private let curtainLogoTintToggle = InspectorToggleControl("Tint Logo")
    private let curtainLogoTintWell = InspectorColorWellControl()
    private var curtainLogoTintRow: NSView!
    private let curtainCaption = InspectorKitViews.captionLine(
        "A curtain peels away from the chosen corner to reveal the video.",
        full: "A curtain covers the screen and peels away from the chosen corner like a page turn, revealing the video underneath. Add a logo and it rides the curtain, peeling away with it. Drag the Curtain block on the EFFECTS lane to place it."
    )

    private let parallaxToggle = InspectorToggleControl("Parallax")
    private let parallaxSlider = InspectorSliderRow(label: "Strength", range: 0.05...1, step: 0.05)
    private let parallaxPad = PropertyPreviewPadControl()
    private let parallaxCaption = InspectorKitViews.captionLine(
        "The background drifts gently with zooms for a sense of depth."
    )

    private let blurToggle = InspectorToggleControl("Motion Blur")
    private let blurStrengthSlider = InspectorSliderRow(label: "Strength", range: 0...1, step: 0.05)
    private let blurPad = PropertyPreviewPadControl()
    private let blurCaption = InspectorKitViews.captionLine(
        "Subtle blur during fast camera movement, for a more natural look.",
        full: "Adds subtle blur during fast camera movements for a more natural look."
    )

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
        slideChips.items = IntroSlideStyle.allCases.dropFirst().map(\.rawValue)
        slideBox.addRow(slideChips)
        slideBox.addRow(slidePad, attached: true)
        slidePad.heightAnchor.constraint(equalToConstant: 96).isActive = true
        slideBounceSlider.format = { $0 < 0.026 ? "None" : "\(Int(($0 * 100).rounded()))%" }
        slideBox.addRow(slideBounceSlider)
        slideSpeedSlider.format = { $0 <= 1.01 ? "1x" : String(format: "%.2gx", $0) }
        slideBox.addRow(slideSpeedSlider)
        slideBox.addRow(slideDepthToggle)
        slideBox.addRow(slideCaption, attached: true)
        fullWidth(slideBox)

        let curtainBox = InspectorSectionBox("Curtain Unveil")
        curtainBox.addRow(curtainToggle)
        curtainChips.items = CurtainUnveilCorner.allCases.dropFirst().map(\.rawValue)
        curtainBox.addRow(curtainChips)
        curtainDurationSlider.format = { String(format: "%.1fs", $0) }
        curtainBox.addRow(curtainDurationSlider)
        curtainColorRow = InspectorKitViews.row("Curtain", control: curtainColorWell)
        curtainBox.addRow(curtainColorRow)
        curtainBox.addRow(curtainColorResetButton, attached: true)
        curtainLogoButtons.orientation = .horizontal
        curtainLogoButtons.spacing = 8
        curtainLogoButtons.addArrangedSubview(curtainLogoChooseButton)
        curtainLogoButtons.addArrangedSubview(curtainLogoRemoveButton)
        curtainBox.addRow(curtainLogoButtons)
        curtainLogoOpacitySlider.format = { "\(Int(($0 * 100).rounded()))%" }
        curtainBox.addRow(curtainLogoOpacitySlider)
        curtainLogoSizeSlider.format = { "\(Int(($0 * 100).rounded()))%" }
        curtainBox.addRow(curtainLogoSizeSlider)
        curtainBox.addRow(curtainLogoTintToggle)
        curtainLogoTintRow = InspectorKitViews.row("Tint", control: curtainLogoTintWell)
        curtainBox.addRow(curtainLogoTintRow)
        curtainBox.addRow(curtainCaption, attached: true)
        fullWidth(curtainBox)

        let parallaxBox = InspectorSectionBox("Parallax")
        parallaxBox.addRow(parallaxToggle)
        parallaxSlider.format = { "\(Int(($0 * 100).rounded()))%" }
        parallaxBox.addRow(parallaxSlider)
        parallaxBox.addRow(parallaxPad, attached: true)
        parallaxPad.heightAnchor.constraint(equalToConstant: 96).isActive = true
        parallaxBox.addRow(parallaxCaption, attached: true)
        fullWidth(parallaxBox)

        let blurBox = InspectorSectionBox("Motion Blur")
        blurBox.addRow(blurToggle)
        blurStrengthSlider.format = { "\(Int(($0 * 100).rounded()))%" }
        blurBox.addRow(blurStrengthSlider)
        blurBox.addRow(blurPad, attached: true)
        blurPad.heightAnchor.constraint(equalToConstant: 96).isActive = true
        blurBox.addRow(blurCaption, attached: true)
        fullWidth(blurBox)

        slideToggle.onChange = { [weak self] on in
            guard let self else { return }
            if on {
                if self.onSlideEnabled?() != true, self.settings.introSlideStyle == .off {
                    self.settings.introSlideStyle = .bottom
                }
            } else {
                self.settings.introSlideStyle = .off
            }
        }
        slideChips.onSelect = { [weak self] index in
            let styles = Array(IntroSlideStyle.allCases.dropFirst())
            self?.settings.introSlideStyle = styles[max(0, min(styles.count - 1, index))]
        }
        slideBounceSlider.onChange = { [weak self] v in self?.settings.introSlideBounce = v }
        slideSpeedSlider.onChange = { [weak self] v in self?.settings.introSlideSpeed = v }
        slideDepthToggle.onChange = { [weak self] on in self?.settings.introSlideDepth = on }
        curtainToggle.onChange = { [weak self] on in
            self?.settings.curtainUnveilCorner = on ? .topLeft : .off
        }
        curtainChips.onSelect = { [weak self] index in
            let corners = Array(CurtainUnveilCorner.allCases.dropFirst())
            self?.settings.curtainUnveilCorner = corners[max(0, min(corners.count - 1, index))]
        }
        curtainDurationSlider.onChange = { [weak self] v in self?.settings.curtainUnveilDuration = v }
        curtainColorWell.getColor = { [weak self] in
            self?.settings.curtainColor?.nsColor ?? Self.defaultCurtainNSColor
        }
        curtainColorWell.setColor = { [weak self] c in
            self?.settings.curtainColor = CodableColor(c)
        }
        curtainColorResetButton.onClick = { [weak self] in self?.settings.curtainColor = nil }
        curtainLogoChooseButton.onClick = { [weak self] in self?.pickCurtainLogo() }
        curtainLogoRemoveButton.onClick = { [weak self] in self?.removeCurtainLogo() }
        curtainLogoOpacitySlider.onChange = { [weak self] v in self?.settings.curtainLogoOpacity = v }
        curtainLogoSizeSlider.onChange = { [weak self] v in self?.settings.curtainLogoScale = v }
        curtainLogoTintToggle.onChange = { [weak self] on in
            self?.settings.curtainLogoTint = on ? CodableColor(.white) : nil
        }
        curtainLogoTintWell.getColor = { [weak self] in
            self?.settings.curtainLogoTint?.nsColor ?? .white
        }
        curtainLogoTintWell.setColor = { [weak self] c in
            self?.settings.curtainLogoTint = CodableColor(c)
        }
        parallaxToggle.onChange = { [weak self] on in
            self?.settings.parallaxStrength = on ? 0.4 : 0
        }
        parallaxSlider.onChange = { [weak self] v in self?.settings.parallaxStrength = v }
        blurToggle.onChange = { [weak self] on in self?.settings.motionBlur = on }
        blurStrengthSlider.onChange = { [weak self] v in self?.settings.motionBlurStrength = v }

        observe()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The math's shared charcoal top stop as NSColor — shown in the well
    /// when no custom curtain color is set.
    private static var defaultCurtainNSColor: NSColor {
        let c = CurtainUnveilMath.coverColorTop
        return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
    }


    // Same pick/copy semantics as the Brand pane's watermark: copy into the
    // project folder under a fresh name (cache-busting), remove the old file.
    private func pickCurtainLogo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .pdf]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a logo image (PNG with transparency works best)"
        guard panel.runModal() == .OK, let source = panel.url else { return }
        guard let folder = project.videoURL?.deletingLastPathComponent() else { return }
        let destName = "curtain-logo-\(UUID().uuidString.prefix(8)).\(source.pathExtension.lowercased())"
        let dest = folder.appendingPathComponent(destName)
        do {
            let previous = project.curtainLogoImageURL
            try FileManager.default.copyItem(at: source, to: dest)
            settings.curtainLogoFileName = destName
            if let previous { try? FileManager.default.removeItem(at: previous) }
        } catch {
            NSSound.beep()
        }
    }

    private func removeCurtainLogo() {
        if let url = project.curtainLogoImageURL {
            try? FileManager.default.removeItem(at: url)
        }
        settings.curtainLogoFileName = nil
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
        let slideOn = settings.introSlideStyle != .off
        slideToggle.isOn = slideOn
        slideChips.isHidden = !slideOn
        slidePad.isHidden = !slideOn
        slideBounceSlider.isHidden = !slideOn
        slideSpeedSlider.isHidden = !slideOn
        slideDepthToggle.isHidden = !slideOn
        if slideOn {
            let styles = Array(IntroSlideStyle.allCases.dropFirst())
            slideChips.selectedIndex = styles.firstIndex(of: settings.introSlideStyle) ?? 0
            slidePad.mode = .slide(
                style: settings.introSlideStyle,
                duration: settings.introSlideDuration,
                bounce: settings.introSlideBounce,
                depth: settings.introSlideDepth)
        }
        slideDepthToggle.isOn = settings.introSlideDepth
        slideBounceSlider.setValue(settings.introSlideBounce)
        slideSpeedSlider.setValue(settings.introSlideSpeed)

        let curtainOn = settings.curtainUnveilCorner != .off
        let hasLogo = settings.curtainLogoFileName != nil
        curtainToggle.isOn = curtainOn
        curtainChips.isHidden = !curtainOn
        curtainDurationSlider.isHidden = !curtainOn
        curtainColorRow.isHidden = !curtainOn
        curtainColorResetButton.isHidden = !curtainOn || settings.curtainColor == nil
        curtainLogoButtons.isHidden = !curtainOn
        curtainLogoRemoveButton.isHidden = !hasLogo
        curtainLogoOpacitySlider.isHidden = !curtainOn || !hasLogo
        curtainLogoSizeSlider.isHidden = !curtainOn || !hasLogo
        curtainLogoTintToggle.isHidden = !curtainOn || !hasLogo
        curtainLogoTintRow.isHidden = !curtainOn || !hasLogo || settings.curtainLogoTint == nil
        if curtainOn {
            let corners = Array(CurtainUnveilCorner.allCases.dropFirst())
            curtainChips.selectedIndex = corners.firstIndex(of: settings.curtainUnveilCorner) ?? 0
            curtainDurationSlider.setValue(settings.curtainUnveilDuration)
            curtainColorWell.refresh()
            curtainLogoChooseButton.title = hasLogo ? "Replace Logo…" : "Choose Logo…"
            curtainLogoOpacitySlider.setValue(settings.curtainLogoOpacity)
            curtainLogoSizeSlider.setValue(settings.curtainLogoScale)
            curtainLogoTintToggle.isOn = settings.curtainLogoTint != nil
            curtainLogoTintWell.refresh()
        }

        let parallaxOn = settings.parallaxStrength > 0.001
        parallaxToggle.isOn = parallaxOn
        parallaxSlider.isHidden = !parallaxOn
        parallaxPad.isHidden = !parallaxOn
        if parallaxOn {
            parallaxSlider.setValue(settings.parallaxStrength)
            parallaxPad.mode = .parallax(strength: settings.parallaxStrength)
        }

        blurToggle.isOn = settings.motionBlur
        blurStrengthSlider.isHidden = !settings.motionBlur
        if settings.motionBlur {
            blurStrengthSlider.setValue(settings.motionBlurStrength)
        }
        blurPad.isHidden = !settings.motionBlur
        blurPad.mode = .motionBlur(on: settings.motionBlur, strength: settings.motionBlurStrength)
    }
}
