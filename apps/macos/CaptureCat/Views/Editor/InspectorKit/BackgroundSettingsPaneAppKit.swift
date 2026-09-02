import AppKit
import UniformTypeIdentifiers

/// The Background tab as a native AppKit pane — twin of BackgroundSettingsView:
/// background type, colors/image/wallpaper source, frame (padding, placement +
/// pad, shape, corners, shadows), menu bar replacement.
@MainActor
final class BackgroundSettingsPaneAppKit: NSView {
    private let settings: ProjectSettings
    private let isDeviceRecording: Bool
    private let supportsMenuBar: Bool

    private let stack = NSStackView()

    private let typeChips = InspectorChipsControl()

    // Background source controls (shown per type)
    private let gradientStartWell = InspectorColorWellControl()
    private let gradientEndWell = InspectorColorWellControl()
    private let solidWell = InspectorColorWellControl()
    private var gradientStartRow: NSView!
    private var gradientEndRow: NSView!
    private var solidRow: NSView!
    private let chooseImageButton = CaptureCatButton(title: "Choose Image…", symbol: "photo", style: .secondary)
    private let imageGrid = WallpaperGridControl(mode: .customImages)
    private let wallpaperGrid = WallpaperGridControl(mode: .catalog)
    private let transparentCaption = InspectorKitViews.caption("No additional settings")
    private let angleSlider = InspectorSliderRow(label: "Angle", range: 0...360, step: 5)

    // Look (shared BackgroundLook — preview and export consume one bitmap)
    private let blurSlider = InspectorSliderRow(label: "Blur", range: 0...1, step: 0.02)
    private let pixelateSlider = InspectorSliderRow(label: "Pixelate", range: 0...1, step: 0.02)
    private let halftoneSlider = InspectorSliderRow(label: "Halftone", range: 0...1, step: 0.02)
    private let noiseSlider = InspectorSliderRow(label: "Grain", range: 0...1, step: 0.02)
    private let contrastSlider = InspectorSliderRow(label: "Contrast", range: 0.5...1.5, step: 0.02)
    private let hueSlider = InspectorSliderRow(label: "Hue", range: 0...360, step: 5)
    private let brightnessSlider = InspectorSliderRow(label: "Brightness", range: -1...1, step: 0.02)
    private let saturationSlider = InspectorSliderRow(label: "Saturation", range: 0...2, step: 0.05)
    private let tintWell = InspectorColorWellControl()
    private var tintRow: NSView!
    private let tintSlider = InspectorSliderRow(label: "Tint Amount", range: 0...1, step: 0.02)
    private let vignetteSlider = InspectorSliderRow(label: "Vignette", range: 0...1, step: 0.02)
    private let lookResetButton = InspectorButton("Reset Look")
    private var lookBox: InspectorSectionBox!

    // Frame
    private let deviceFrameToggle = InspectorToggleControl("iPhone / iPad Frame")
    private let paddingSlider = InspectorSliderRow(label: "Padding", range: 0...300, step: 4)
    private let placementMenu = InspectorMenuControl()
    private let placementPad = PlacementPadControl()
    /// Shown only while a freeform drag (videoCustomX/Y) overrides the enum.
    private let placementResetButton = InspectorButton("Reset to Center")
    private let shapeMenu = InspectorMenuControl()
    private let cornersSlider = InspectorSliderRow(label: "Rounded Corners", range: 0...20, step: 1)
    private let shadowSlider = InspectorSliderRow(label: "Shadow", range: 0...60, step: 2)
    private let shadowOpacitySlider = InspectorSliderRow(label: "Shadow Opacity", range: 0...1, step: 0.05)
    private let framePad = PropertyPreviewPadControl()

    // Menu bar
    private let menuBarChips = InspectorChipsControl()
    private let titleField = InspectorFlatTextField(placeholder: "App name", width: 140)
    private var titleRow: NSView!
    private let alignLabel = NSTextField(labelWithString: "Align")
    private let alignChips = InspectorChipsControl()
    private let clockField = InspectorFlatTextField(placeholder: "9:41", width: 70)
    private var clockRow: NSView!
    private let statusIconsToggle = InspectorToggleControl("Wi-Fi & Battery Icons")
    private let heightSlider = InspectorSliderRow(label: "Height", range: 2...6, step: 0.1)
    private let menuBarCaption = InspectorKitViews.caption("")

    override var isFlipped: Bool { true }

    init(settings: ProjectSettings, isDeviceRecording: Bool, supportsMenuBar: Bool) {
        self.settings = settings
        self.isDeviceRecording = isDeviceRecording
        self.supportsMenuBar = supportsMenuBar
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
        // Theme lives outside the settings observation loop on purpose — a
        // CCTheme.apply must not re-arm withObservationTracking.
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    private var themeObservation: CCThemeObservation?

    private func applyTheme() {
        alignLabel.textColor = EditorThemeKit.textPrimary
    }

    required init?(coder: NSCoder) { fatalError() }

    private func fullWidth(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func build() {
        // Background source section.
        let backgroundBox = InspectorSectionBox("Background")
        typeChips.items = ProjectSettings.BackgroundType.allCases.map(\.rawValue)
        backgroundBox.addRow(typeChips)
        gradientStartRow = InspectorKitViews.row("Start Color", control: gradientStartWell)
        gradientEndRow = InspectorKitViews.row("End Color", control: gradientEndWell)
        solidRow = InspectorKitViews.row("Color", control: solidWell)
        backgroundBox.addRow(gradientStartRow)
        backgroundBox.addRow(gradientEndRow)
        backgroundBox.addRow(solidRow)
        angleSlider.format = { "\(Int($0.rounded()))°" }
        backgroundBox.addRow(angleSlider)
        backgroundBox.addRow(chooseImageButton)
        backgroundBox.addRow(imageGrid, attached: true)
        backgroundBox.addRow(wallpaperGrid)
        backgroundBox.addRow(transparentCaption)
        fullWidth(backgroundBox)

        // Look section — adjustments layered on whatever fill is chosen.
        lookBox = InspectorSectionBox("Look")
        brightnessSlider.format = { v in
            v >= 0 ? "+\(Int((v * 100).rounded()))" : "\(Int((v * 100).rounded()))"
        }
        saturationSlider.format = { String(format: "%.2f×", $0) }
        contrastSlider.format = { String(format: "%.2f×", $0) }
        hueSlider.format = { "\(Int($0.rounded()))°" }
        lookBox.addRow(blurSlider)
        lookBox.addRow(pixelateSlider)
        lookBox.addRow(halftoneSlider)
        lookBox.addRow(noiseSlider)
        lookBox.addRow(brightnessSlider)
        lookBox.addRow(contrastSlider)
        lookBox.addRow(saturationSlider)
        lookBox.addRow(hueSlider)
        tintRow = InspectorKitViews.row("Tint", control: tintWell)
        lookBox.addRow(tintRow)
        lookBox.addRow(tintSlider, attached: true)
        lookBox.addRow(vignetteSlider)
        lookBox.addRow(lookResetButton, attached: true)
        fullWidth(lookBox)

        // Frame section — Placement first: it's the primary control here.
        let frameBox = InspectorSectionBox("Frame")
        if isDeviceRecording {
            frameBox.addRow(deviceFrameToggle)
        }
        placementMenu.items = ProjectSettings.VideoPlacement.allCases.map { .init(title: $0.rawValue) }
        frameBox.addRow(InspectorKitViews.row("Placement", control: placementMenu))
        frameBox.addRow(placementPad, attached: true)
        placementPad.heightAnchor.constraint(equalToConstant: 96).isActive = true
        frameBox.addRow(placementResetButton, attached: true)

        frameBox.addRow(paddingSlider)

        shapeMenu.items = ProjectSettings.FrameShape.allCases.map { .init(title: $0.rawValue) }
        frameBox.addRow(InspectorKitViews.row("Shape", control: shapeMenu))

        shadowOpacitySlider.format = { "\(Int($0 * 100))%" }
        frameBox.addRow(cornersSlider)
        frameBox.addRow(shadowSlider)
        frameBox.addRow(shadowOpacitySlider)
        frameBox.addRow(framePad, attached: true)
        framePad.heightAnchor.constraint(equalToConstant: 96).isActive = true
        fullWidth(frameBox)

        guard supportsMenuBar else { return }

        let menuBarBox = InspectorSectionBox("Menu Bar")

        // Display labels for MenuBarReplacement — the SwiftUI pane shortens
        // "Clean Dark/Light" to "Dark/Light" on the chips.
        menuBarChips.items = ProjectSettings.MenuBarReplacement.allCases.map {
            switch $0 {
            case .off: return "Original"
            case .hidden: return "Hidden"
            case .dark: return "Dark"
            case .light: return "Light"
            }
        }
        menuBarBox.addRow(menuBarChips)

        titleRow = InspectorKitViews.row("Title", control: titleField)
        menuBarBox.addRow(titleRow)

        alignLabel.font = EditorThemeKit.label()
        menuBarBox.addRow(alignLabel)
        alignChips.items = ProjectSettings.MenuBarTitleAlignment.allCases.map(\.rawValue)
        menuBarBox.addRow(alignChips, attached: true)

        clockRow = InspectorKitViews.row("Clock", control: clockField)
        menuBarBox.addRow(clockRow)
        menuBarBox.addRow(statusIconsToggle)

        heightSlider.format = { String(format: "%.1f%%", $0) }
        menuBarBox.addRow(heightSlider)
        menuBarBox.addRow(menuBarCaption, attached: true)
        fullWidth(menuBarBox)
    }

    private func wire() {
        typeChips.onSelect = { [weak self] index in
            self?.settings.backgroundType = ProjectSettings.BackgroundType.allCases[index]
        }

        func bindWell(_ well: InspectorColorWellControl,
                      get: @escaping () -> CodableColor,
                      set: @escaping (CodableColor) -> Void) {
            well.getColor = {
                let c = get()
                return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.opacity)
            }
            well.setColor = { color in
                guard let srgb = color.usingColorSpace(.sRGB) else { return }
                set(CodableColor(
                    red: srgb.redComponent, green: srgb.greenComponent,
                    blue: srgb.blueComponent, opacity: srgb.alphaComponent
                ))
            }
        }
        bindWell(gradientStartWell,
                 get: { [weak self] in self?.settings.gradientStartColor ?? CodableColor(red: 1, green: 1, blue: 1) },
                 set: { [weak self] in self?.settings.gradientStartColor = $0 })
        bindWell(gradientEndWell,
                 get: { [weak self] in self?.settings.gradientEndColor ?? CodableColor(red: 0, green: 0, blue: 0) },
                 set: { [weak self] in self?.settings.gradientEndColor = $0 })
        bindWell(solidWell,
                 get: { [weak self] in self?.settings.solidColor ?? CodableColor(red: 0, green: 0, blue: 0) },
                 set: { [weak self] in self?.settings.solidColor = $0 })
        bindWell(tintWell,
                 get: { [weak self] in self?.settings.backgroundTintColor ?? CodableColor(red: 0, green: 0, blue: 0) },
                 set: { [weak self] in
                     self?.settings.backgroundTintColor = $0
                     // Picking a tint with the amount at zero would look like
                     // nothing happened — give it a visible starting strength.
                     if (self?.settings.backgroundTintOpacity ?? 0) <= 0 {
                         self?.settings.backgroundTintOpacity = 0.3
                     }
                 })
        angleSlider.onChange = { [weak self] v in self?.settings.gradientAngle = v }
        blurSlider.onChange = { [weak self] v in self?.settings.backgroundBlur = v }
        pixelateSlider.onChange = { [weak self] v in self?.settings.backgroundPixelate = v }
        halftoneSlider.onChange = { [weak self] v in self?.settings.backgroundHalftone = v }
        noiseSlider.onChange = { [weak self] v in self?.settings.backgroundNoise = v }
        contrastSlider.onChange = { [weak self] v in self?.settings.backgroundContrast = v }
        hueSlider.onChange = { [weak self] v in self?.settings.backgroundHue = v }
        brightnessSlider.onChange = { [weak self] v in self?.settings.backgroundBrightness = v }
        saturationSlider.onChange = { [weak self] v in self?.settings.backgroundSaturation = v }
        tintSlider.onChange = { [weak self] v in self?.settings.backgroundTintOpacity = v }
        vignetteSlider.onChange = { [weak self] v in self?.settings.backgroundVignette = v }
        lookResetButton.onClick = { [weak self] in
            guard let s = self?.settings else { return }
            s.backgroundBlur = 0
            s.backgroundBrightness = 0
            s.backgroundSaturation = 1
            s.backgroundTintOpacity = 0
            s.backgroundVignette = 0
            s.backgroundPixelate = 0
            s.backgroundHalftone = 0
            s.backgroundNoise = 0
            s.backgroundContrast = 1
            s.backgroundHue = 0
        }

        chooseImageButton.onClick = { [weak self] in
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.image]
            if panel.runModal() == .OK, let url = panel.url {
                // The project keeps referencing the picked file (existing
                // behavior); a copy is remembered in the library so the image
                // reappears as a tile in the Image grid.
                self?.settings.backgroundImagePath = url.path
                CustomWallpaperStore.add(from: url)
                self?.imageGrid.reloadCustomItems()
            }
        }

        imageGrid.onSelect = { [weak self] path in
            self?.settings.backgroundImagePath = path
        }
        wallpaperGrid.onSelect = { [weak self] path in
            self?.settings.backgroundImagePath = path
        }

        deviceFrameToggle.onChange = { [weak self] on in self?.settings.showDeviceFrame = on }
        paddingSlider.onChange = { [weak self] v in self?.settings.backgroundPadding = v }
        placementMenu.onSelect = { [weak self] index in
            self?.settings.videoPlacement = ProjectSettings.VideoPlacement.allCases[index]
            // Picking an anchor is an explicit choice — drop any freeform
            // drag position, or the menu selection would appear to do nothing.
            self?.settings.videoCustomX = nil
            self?.settings.videoCustomY = nil
        }
        placementPad.onSelect = { [weak self] placement in
            self?.settings.videoPlacement = placement
            self?.settings.videoCustomX = nil
            self?.settings.videoCustomY = nil
        }
        placementResetButton.onClick = { [weak self] in
            self?.settings.videoCustomX = nil
            self?.settings.videoCustomY = nil
            self?.settings.videoPlacement = .center
        }
        shapeMenu.onSelect = { [weak self] index in
            self?.settings.frameShape = ProjectSettings.FrameShape.allCases[index]
        }
        cornersSlider.onChange = { [weak self] v in
            // Mirrors the SwiftUI pane: one slider writes both radii.
            self?.settings.windowCornerRadius = v
            self?.settings.cornerRadius = v
        }
        shadowSlider.onChange = { [weak self] v in self?.settings.shadowRadius = v }
        shadowOpacitySlider.onChange = { [weak self] v in self?.settings.shadowOpacity = v }

        guard supportsMenuBar else { return }
        menuBarChips.onSelect = { [weak self] index in
            self?.settings.menuBarReplacement = ProjectSettings.MenuBarReplacement.allCases[index]
        }
        titleField.delegate = fieldDelegate
        clockField.delegate = fieldDelegate
        statusIconsToggle.onChange = { [weak self] on in self?.settings.menuBarShowStatusIcons = on }
        alignChips.onSelect = { [weak self] index in
            self?.settings.menuBarTitleAlignment = ProjectSettings.MenuBarTitleAlignment.allCases[index]
        }
        heightSlider.onChange = { [weak self] v in self?.settings.menuBarHeight = v }
    }

    private lazy var fieldDelegate = FieldDelegate(owner: self)

    /// Live text-field mirroring (SwiftUI TextField binds on every keystroke).
    private final class FieldDelegate: NSObject, NSTextFieldDelegate {
        weak var owner: BackgroundSettingsPaneAppKit?
        init(owner: BackgroundSettingsPaneAppKit) { self.owner = owner }

        func controlTextDidChange(_ obj: Notification) {
            guard let owner, let field = obj.object as? NSTextField else { return }
            if field === owner.titleField {
                owner.settings.menuBarTitle = field.stringValue
            } else if field === owner.clockField {
                owner.settings.menuBarClock = field.stringValue
            }
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
        let type = settings.backgroundType
        typeChips.selectedIndex = ProjectSettings.BackgroundType.allCases.firstIndex(of: type) ?? 0

        let usesRamp = type == .gradient || type == .mesh
        gradientStartRow.isHidden = !usesRamp
        gradientEndRow.isHidden = !usesRamp
        solidRow.isHidden = type != .solid
        chooseImageButton.isHidden = type != .image
        imageGrid.isHidden = type != .image
        if type == .image {
            imageGrid.selectedPath = settings.backgroundImagePath
            imageGrid.loadIfNeeded()
        }
        wallpaperGrid.isHidden = type != .wallpaper
        if type == .wallpaper {
            wallpaperGrid.selectedPath = settings.backgroundImagePath
            wallpaperGrid.loadIfNeeded()
        }
        transparentCaption.isHidden = type != .transparent
        angleSlider.isHidden = type != .gradient
        // nil = legacy corner-to-corner diagonal; show it as the nearest
        // round number until the user takes over.
        angleSlider.setValue(settings.gradientAngle ?? 135)

        gradientStartWell.refresh()
        gradientEndWell.refresh()
        solidWell.refresh()

        lookBox.isHidden = type == .transparent
        blurSlider.setValue(settings.backgroundBlur)
        pixelateSlider.setValue(settings.backgroundPixelate)
        halftoneSlider.setValue(settings.backgroundHalftone)
        noiseSlider.setValue(settings.backgroundNoise)
        contrastSlider.setValue(settings.backgroundContrast)
        hueSlider.setValue(settings.backgroundHue)
        brightnessSlider.setValue(settings.backgroundBrightness)
        saturationSlider.setValue(settings.backgroundSaturation)
        tintWell.refresh()
        tintSlider.setValue(settings.backgroundTintOpacity)
        vignetteSlider.setValue(settings.backgroundVignette)
        lookResetButton.isHidden = BackgroundLook.Spec(settings).isPlainLook

        deviceFrameToggle.isOn = settings.showDeviceFrame
        paddingSlider.setValue(settings.backgroundPadding)
        // Placement honesty: while videoCustomX/Y override the enum, say
        // "Custom", offer the reset, and show the card where it actually is.
        let isCustomPlacement = PlacementMath.isCustom(settings)
        placementMenu.selectedIndex = ProjectSettings.VideoPlacement.allCases
            .firstIndex(of: settings.videoPlacement) ?? 0
        placementMenu.overrideTitle = isCustomPlacement ? "Custom" : nil
        placementResetButton.isHidden = !isCustomPlacement
        placementPad.placement = settings.videoPlacement
        placementPad.customFraction = isCustomPlacement
            ? CGPoint(x: settings.videoCustomX ?? 0.5, y: settings.videoCustomY ?? 0.5)
            : nil
        placementPad.padding = settings.backgroundPadding
        shapeMenu.selectedIndex = ProjectSettings.FrameShape.allCases
            .firstIndex(of: settings.frameShape) ?? 0
        cornersSlider.setValue(settings.windowCornerRadius)
        shadowSlider.setValue(settings.shadowRadius)
        shadowOpacitySlider.setValue(settings.shadowOpacity)
        framePad.mode = .frameStyle(
            cornerRadius: settings.windowCornerRadius,
            shadowRadius: settings.shadowRadius,
            shadowOpacity: settings.shadowOpacity)

        guard supportsMenuBar else { return }
        let replacement = settings.menuBarReplacement
        menuBarChips.selectedIndex = ProjectSettings.MenuBarReplacement.allCases
            .firstIndex(of: replacement) ?? 0
        let showsCustomBar = replacement == .dark || replacement == .light
        titleRow.isHidden = !showsCustomBar
        alignLabel.isHidden = !showsCustomBar
        alignChips.isHidden = !showsCustomBar
        clockRow.isHidden = !showsCustomBar
        statusIconsToggle.isHidden = !showsCustomBar
        heightSlider.isHidden = replacement == .off
        if titleField.currentEditor() == nil { titleField.stringValue = settings.menuBarTitle }
        if clockField.currentEditor() == nil { clockField.stringValue = settings.menuBarClock }
        alignChips.selectedIndex = ProjectSettings.MenuBarTitleAlignment.allCases
            .firstIndex(of: settings.menuBarTitleAlignment) ?? 0
        statusIconsToggle.isOn = settings.menuBarShowStatusIcons
        heightSlider.setValue(settings.menuBarHeight)
        menuBarCaption.stringValue = replacement == .hidden
            ? "Crops the menu bar strip off the recording entirely — adjust Height until the bar is exactly gone."
            : "Covers the recorded macOS menu bar with a clean bar — your own title, a fixed clock, no personal clutter. Adjust Height until it exactly hides the real bar."
    }
}

// MARK: - Placement pad

/// Mini canvas showing where the window card sits — native twin of
/// PlacementPadView. Click/drag snaps to the nine placements; the card inset
/// tracks the Padding slider.
@MainActor
final class PlacementPadControl: CCPreviewPad {
    var onSelect: ((ProjectSettings.VideoPlacement) -> Void)?
    var placement: ProjectSettings.VideoPlacement = .center { didSet { needsLayout = true } }
    /// Freeform override (videoCustomX/Y, card-CENTRE fractions, Y-down).
    /// While set, the mini card sits where the card actually is instead of
    /// pretending the enum anchor still applies.
    var customFraction: CGPoint? { didSet { needsLayout = true } }
    var padding: Double = 0 { didSet { needsLayout = true } }

    private static let fractions: [ProjectSettings.VideoPlacement: (x: CGFloat, y: CGFloat)] = [
        .topLeft: (0, 0), .top: (0.5, 0), .topRight: (1, 0),
        .left: (0, 0.5), .center: (0.5, 0.5), .right: (1, 0.5),
        .bottomLeft: (0, 1), .bottom: (0.5, 1), .bottomRight: (1, 1),
    ]

    private var dots: [CALayer] = []
    private let card = CALayer()
    private var themeObservation: CCThemeObservation?

    override var isFlipped: Bool { true }

    init() {
        // Own dot layout (it tracks the padding inset), so the base grid is off.
        super.init(showsGridDots: false)

        for _ in 0..<9 {
            let dot = CALayer()
            dot.cornerRadius = 1.5
            layer?.addSublayer(dot)
            dots.append(dot)
        }
        // The mini window card is demo content (it mimics the exported card)
        // and keeps its fixed colors; only the pad's grid dots re-ink.
        card.backgroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
        card.cornerRadius = 3
        card.cornerCurve = .continuous
        card.shadowColor = NSColor.black.withAlphaComponent(0.35).cgColor
        card.shadowOpacity = 1
        card.shadowRadius = 3
        card.shadowOffset = CGSize(width: 0, height: 1)
        layer?.addSublayer(card)

        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func applyTheme() {
        let ink: NSColor = CCTheme.isDark ? .white : .black
        for dot in dots {
            dot.backgroundColor = ink.withAlphaComponent(0.18).cgColor
        }
    }

    override func layout() {
        super.layout()
        let size = bounds.size
        guard size.width > 1 else { return }
        let inset = 6 + CGFloat(min(max(padding, 0), 300) / 300) * min(size.width, size.height) * 0.28
        let content = CGRect(
            x: inset, y: inset,
            width: max(1, size.width - 2 * inset),
            height: max(1, size.height - 2 * inset)
        )
        let cardW = content.width * 0.5
        let cardH = content.height * 0.58

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        for (i, dot) in dots.enumerated() {
            dot.frame = CGRect(
                x: content.minX + content.width * (CGFloat(i % 3) / 2) - 1.5,
                y: content.minY + content.height * (CGFloat(i / 3) / 2) - 1.5,
                width: 3, height: 3
            )
        }
        if let custom = customFraction {
            // Custom fractions are the card CENTRE (PlacementMath semantics);
            // clamp into the pad so an off-canvas card still reads at an edge.
            let fx = min(1, max(0, custom.x))
            let fy = min(1, max(0, custom.y))
            card.frame = CGRect(
                x: content.minX + content.width * fx - cardW / 2,
                y: content.minY + content.height * fy - cardH / 2,
                width: cardW, height: cardH
            )
        } else {
            let f = Self.fractions[placement] ?? (0.5, 0.5)
            card.frame = CGRect(
                x: content.minX + (content.width - cardW) * f.x,
                y: content.minY + (content.height - cardH) * f.y,
                width: cardW, height: cardH
            )
        }
        CATransaction.commit()
    }

    private func pick(at point: NSPoint) {
        func step(_ f: CGFloat) -> CGFloat { f < 1.0 / 3 ? 0 : (f > 2.0 / 3 ? 1 : 0.5) }
        let fx = step(point.x / max(1, bounds.width))
        let fy = step(point.y / max(1, bounds.height))
        if let match = Self.fractions.first(where: { $0.value == (fx, fy) })?.key {
            placement = match
            onSelect?(match)
        }
    }

    override func mouseDown(with event: NSEvent) { pick(at: convert(event.locationInWindow, from: nil)) }
    override func mouseDragged(with event: NSEvent) { pick(at: convert(event.locationInWindow, from: nil)) }
}

// MARK: - Wallpaper grid

/// 3×2 paginated macOS wallpaper picker — native twin of WallpaperPickerGrid,
/// including download badges, spinners, one auto-fetch-all sweep per run.
/// `.customImages` mode reuses the same cells to show ONLY the user's own
/// image library (the Image tab's grid); `.catalog` shows only the system
/// wallpapers, so user images never appear under Wallpaper.
@MainActor
final class WallpaperGridControl: NSView {
    enum Mode {
        case catalog
        case customImages
    }

    var onSelect: ((String) -> Void)?
    var selectedPath: String? { didSet { restyleCells() } }

    private let mode: Mode

    private var items: [WallpaperCatalog.Item] = []
    private var customItems: [WallpaperCatalog.Item] = []
    private var thumbnails: [String: NSImage] = [:]
    /// Custom-image thumbnails, keyed by file path (custom names may collide
    /// with catalog names).
    private var customThumbnails: [String: NSImage] = [:]
    private var downloading: Set<String> = []
    private var failed: Set<String> = []
    private var page = 0
    private var didLoad = false
    private static var didAutoFetchAll = false

    private let grid = NSStackView()
    private var rows: [NSStackView] = []
    private var cells: [WallpaperCell] = []
    private let customHeader = InspectorKitViews.caption("Your images")
    private let customGrid = NSStackView()
    private var customCells: [WallpaperCell] = []
    private let pagerBack = CaptureCatButton(title: "", symbol: "chevron.left", style: .quiet, height: 26, horizontalPadding: 4)
    private let pagerForward = CaptureCatButton(title: "", symbol: "chevron.right", style: .quiet, height: 26, horizontalPadding: 4)
    private let pagerLabel = NSTextField(labelWithString: "1 / 1")
    private let caption = InspectorKitViews.caption("Wallpapers with a download badge fetch in full quality on first use.")
    private let emptyCaption = InspectorKitViews.caption("No system wallpapers found")

    private let pageSize = 6

    override var isFlipped: Bool { true }

    init(mode: Mode = .catalog) {
        self.mode = mode
        super.init(frame: .zero)

        grid.orientation = .vertical
        grid.spacing = 8
        for _ in 0..<2 {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8
            row.distribution = .fillEqually
            for _ in 0..<3 {
                let cell = WallpaperCell()
                cells.append(cell)
                row.addArrangedSubview(cell)
                cell.heightAnchor.constraint(equalToConstant: 58).isActive = true
            }
            rows.append(row)
            grid.addArrangedSubview(row)
        }

        pagerBack.onClick = { [weak self] in self?.goBack() }
        pagerForward.onClick = { [weak self] in self?.goForward() }
        pagerLabel.font = EditorThemeKit.valuePill()
        pagerLabel.alignment = .center

        let pager = NSStackView(views: [pagerBack, NSView(), pagerLabel, NSView(), pagerForward])
        pager.orientation = .horizontal
        pager.distribution = .equalCentering

        customGrid.orientation = .vertical
        customGrid.spacing = 8
        customHeader.isHidden = true
        customGrid.isHidden = true

        let column = NSStackView(views: [customHeader, customGrid, emptyCaption, grid, pager, caption])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.setCustomSpacing(6, after: customHeader)
        column.setCustomSpacing(14, after: customGrid)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            customGrid.widthAnchor.constraint(equalTo: column.widthAnchor),
            grid.widthAnchor.constraint(equalTo: column.widthAnchor),
            pager.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])

        for (index, cell) in cells.enumerated() {
            cell.onClick = { [weak self] in self?.clickCell(index) }
            cell.onRightClick = { [weak self] event in self?.showMenu(catalogCell: index, event: event) }
        }

        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError() }

    private var themeObservation: CCThemeObservation?

    private func applyTheme() {
        pagerLabel.textColor = EditorThemeKit.textSecondary
    }

    // MARK: Loading

    func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        if mode == .customImages {
            // Only the user's own library — no catalog, pager, or captions.
            grid.isHidden = true
            caption.isHidden = true
            emptyCaption.isHidden = true
            pagerBack.isHidden = true
            pagerForward.isHidden = true
            pagerLabel.isHidden = true
            reloadCustomItems()
            return
        }
        items = WallpaperCatalog.listItems()
        emptyCaption.isHidden = !items.isEmpty
        grid.isHidden = items.isEmpty
        caption.isHidden = items.isEmpty
        refreshPage()
        loadThumbnails()
        autoFetchAll()
    }

    /// Rebuilds the user-image grid from the on-disk library
    /// (`.customImages` mode only).
    func reloadCustomItems() {
        guard mode == .customImages else { return }
        customItems = CustomWallpaperStore.listItems()
        customHeader.isHidden = true
        customGrid.isHidden = customItems.isEmpty

        // Rebuild rows of 3 — the library changes rarely and stays small.
        for row in customGrid.arrangedSubviews { row.removeFromSuperview() }
        customCells = []
        var rowStack: NSStackView?
        for (index, item) in customItems.enumerated() {
            if index % 3 == 0 {
                let row = NSStackView()
                row.orientation = .horizontal
                row.spacing = 8
                row.distribution = .fillEqually
                customGrid.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: customGrid.widthAnchor).isActive = true
                rowStack = row
            }
            let cell = WallpaperCell()
            cell.heightAnchor.constraint(equalToConstant: 58).isActive = true
            cell.onClick = { [weak self] in self?.clickCustomCell(index) }
            cell.onRightClick = { [weak self] event in self?.showMenu(customCell: index, event: event) }
            customCells.append(cell)
            rowStack?.addArrangedSubview(cell)
            if let path = item.localURL?.path, customThumbnails[path] == nil {
                loadCustomThumbnail(for: item)
            }
        }
        // Last row may be short — pad with spacers so cells keep equal width.
        if let rowStack, customItems.count % 3 != 0 {
            for _ in 0..<(3 - customItems.count % 3) {
                rowStack.addArrangedSubview(NSView())
            }
        }
        restyleCustomCells()
    }

    private func restyleCustomCells() {
        for (index, cell) in customCells.enumerated() {
            guard index < customItems.count else { continue }
            let item = customItems[index]
            let path = item.localURL?.path
            cell.configure(
                name: item.name,
                thumbnail: path.flatMap { customThumbnails[$0] },
                needsDownload: false,
                isDownloading: false,
                isFailed: false,
                isSelected: selectedPath != nil && selectedPath == path
            )
        }
    }

    private func loadCustomThumbnail(for item: WallpaperCatalog.Item) {
        guard let url = item.localURL else { return }
        Task.detached(priority: .utility) { [weak self] in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 320,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return }
            let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            await MainActor.run { [weak self] in
                self?.customThumbnails[url.path] = image
                self?.restyleCustomCells()
            }
        }
    }

    private func clickCustomCell(_ index: Int) {
        guard index < customItems.count, let url = customItems[index].localURL else { return }
        onSelect?(url.path)
    }

    // MARK: Context menu

    private func showMenu(catalogCell index: Int, event: NSEvent) {
        let visible = pageItems
        guard index < visible.count else { return }
        popUpMenu(path: visible[index].localURL?.path, isCustom: false, event: event, in: cells[index])
    }

    private func showMenu(customCell index: Int, event: NSEvent) {
        guard index < customItems.count else { return }
        popUpMenu(path: customItems[index].localURL?.path, isCustom: true, event: event, in: customCells[index])
    }

    private func popUpMenu(path: String?, isCustom: Bool, event: NSEvent, in cell: NSView) {
        let menu = NSMenu()
        let setDefault = NSMenuItem(title: "Set as Default", action: #selector(setAsDefaultAction(_:)), keyEquivalent: "")
        setDefault.target = self
        setDefault.representedObject = path
        // A catalog wallpaper that hasn't downloaded yet has no local file to
        // default to.
        setDefault.isEnabled = path != nil
        menu.addItem(setDefault)
        if isCustom {
            let remove = NSMenuItem(title: "Remove from Library", action: #selector(removeFromLibraryAction(_:)), keyEquivalent: "")
            remove.target = self
            remove.representedObject = path
            remove.isEnabled = path != nil
            menu.addItem(remove)
        }
        menu.autoenablesItems = false
        NSMenu.popUpContextMenu(menu, with: event, for: cell)
    }

    @objc private func setAsDefaultAction(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        CustomWallpaperStore.setDefaultBackground(path: path)
    }

    @objc private func removeFromLibraryAction(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        CustomWallpaperStore.remove(path: path)
        customThumbnails[path] = nil
        reloadCustomItems()
    }

    private func loadThumbnails() {
        let loaded = items
        // .userInitiated, not .utility: the main (user-interactive) thread
        // ends up waiting on results from this task, and a lower QoS there
        // is a priority inversion (Xcode's Hang Risk diagnostic).
        Task.detached(priority: .userInitiated) { [weak self] in
            for item in loaded {
                guard let source = CGImageSourceCreateWithURL(item.thumbnailURL as CFURL, nil) else { continue }
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 320,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ]
                guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { continue }
                let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                await MainActor.run { [weak self] in
                    self?.thumbnails[item.name] = image
                    self?.refreshPage()
                }
            }
        }
    }

    /// Concurrency for the background sweep.
    ///
    /// Sequential was the original shape and it is why a fresh install looks
    /// broken: full-res wallpapers are tens of megabytes each, so ~60 of them
    /// downloaded one after another leaves most of the grid badged for minutes.
    /// Four at a time saturates a normal connection without starving the
    /// thumbnail loads or the editor's own network use.
    private static let fetchConcurrency = 4

    private func autoFetchAll() {
        guard !Self.didAutoFetchAll else { return }
        Self.didAutoFetchAll = true
        Task { [weak self] in await self?.fetchMissing() }
    }

    /// Fetches every missing wallpaper, nearest-first and a few at a time.
    ///
    /// Ordering matters as much as concurrency here: the catalog order is
    /// alphabetical, so a strict sweep spends its first minutes on wallpapers
    /// the user cannot see. Whatever page is on screen is fetched first, and
    /// changing page re-prioritises because `missingNames()` is re-read each
    /// round rather than snapshotted once at the start.
    @MainActor
    private func fetchMissing() async {
        while true {
            let batch = missingNames().prefix(Self.fetchConcurrency)
            if batch.isEmpty { return }

            for name in batch {
                downloading.insert(name)
            }
            refreshPage()

            await withTaskGroup(of: (String, URL?).self) { group in
                for name in batch {
                    group.addTask {
                        do { return (name, try await WallpaperCatalog.download(name)) }
                        catch {
                            print("[Wallpaper] auto-fetch failed for \(name): \(error)")
                            return (name, nil)
                        }
                    }
                }
                for await (name, url) in group {
                    downloading.remove(name)
                    if let url, let index = items.firstIndex(where: { $0.name == name }) {
                        items[index].localURL = url
                    } else if url == nil {
                        // Recorded so the next round skips it — without this the
                        // loop would re-select the same failing wallpaper forever.
                        failed.insert(name)
                    }
                    refreshPage()
                }
            }
        }
    }

    /// Still-missing wallpapers, current page first.
    private func missingNames() -> [String] {
        let pending = items.filter {
            $0.localURL == nil && !downloading.contains($0.name) && !failed.contains($0.name)
        }
        let start = min(max(0, page * pageSize), items.count)
        let end = min(items.count, start + pageSize)
        let visible = Set(items[start..<end].map(\.name))
        // Visible first, catalog order within each group.
        return pending.sorted { a, b in
            let av = visible.contains(a.name), bv = visible.contains(b.name)
            if av != bv { return av }
            return false
        }.map(\.name)
    }

    // MARK: Paging / cells

    private var pageCount: Int { max(1, (items.count + pageSize - 1) / pageSize) }

    private var pageItems: [WallpaperCatalog.Item] {
        let start = page * pageSize
        guard start < items.count else { return [] }
        return Array(items[start..<min(start + pageSize, items.count)])
    }

    @objc private func goBack() {
        page = max(0, page - 1)
        refreshPage()
    }

    @objc private func goForward() {
        page = min(pageCount - 1, page + 1)
        refreshPage()
    }

    private func refreshPage() {
        let visible = pageItems
        for (index, cell) in cells.enumerated() {
            if index < visible.count {
                let item = visible[index]
                cell.isHidden = false
                cell.configure(
                    name: item.name,
                    thumbnail: thumbnails[item.name],
                    needsDownload: item.localURL == nil,
                    isDownloading: downloading.contains(item.name),
                    isFailed: failed.contains(item.name),
                    isSelected: selectedPath != nil && selectedPath == item.localURL?.path
                )
            } else {
                cell.isHidden = true
            }
        }
        pagerLabel.stringValue = "\(page + 1) / \(pageCount)"
        pagerBack.alphaValue = page == 0 ? 0.3 : 0.8
        pagerForward.alphaValue = page >= pageCount - 1 ? 0.3 : 0.8
    }

    private func restyleCells() {
        refreshPage()
        restyleCustomCells()
    }

    private func clickCell(_ index: Int) {
        let visible = pageItems
        guard index < visible.count else { return }
        let item = visible[index]
        if let url = item.localURL {
            onSelect?(url.path)
            return
        }
        guard !downloading.contains(item.name) else { return }
        downloading.insert(item.name)
        failed.remove(item.name)
        refreshPage()
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await WallpaperCatalog.download(item.name)
                if let idx = self.items.firstIndex(where: { $0.name == item.name }) {
                    self.items[idx].localURL = url
                }
                self.onSelect?(url.path)
            } catch {
                self.failed.insert(item.name)
                print("[Wallpaper] download failed for \(item.name): \(error)")
            }
            self.downloading.remove(item.name)
            self.refreshPage()
        }
    }

    /// One wallpaper thumbnail cell with selection ring + status badge.
    private final class WallpaperCell: NSView {
        var onClick: (() -> Void)?
        var onRightClick: ((NSEvent) -> Void)?

        /// A PLAIN sublayer, not a view-backed one: AppKit owns a view's
        /// backing-layer contents and clears anything set behind its back on
        /// the next display pass — which is exactly how the grid rendered 16
        /// pages of empty cells. NSImage contents on a raw CALayer are safe
        /// (and auto-oriented under this flipped view).
        private let thumbnailLayer = CALayer()
        private let badge = NSImageView()
        private let spinner = CCSpinner()
        private var isSelected = false
        private var themeObservation: CCThemeObservation?

        override var isFlipped: Bool { true }

        init() {
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = CCTheme.radius(.lg)
            layer?.cornerCurve = .continuous
            layer?.masksToBounds = true
            layer?.borderWidth = 1

            // Fill-crop like SwiftUI's .scaledToFill — NSImageView can only
            // aspect-fit, so the thumbnail rides on its own plain sublayer.
            thumbnailLayer.contentsGravity = .resizeAspectFill
            thumbnailLayer.masksToBounds = true
            layer?.addSublayer(thumbnailLayer)

            spinner.isDisplayedWhenStopped = false
            spinner.translatesAutoresizingMaskIntoConstraints = false
            addSubview(spinner)

            badge.translatesAutoresizingMaskIntoConstraints = false
            addSubview(badge)

            NSLayoutConstraint.activate([
                badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
                badge.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
                spinner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
                spinner.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            ])

            themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
        }

        required init?(coder: NSCoder) { fatalError() }

        private func applyTheme() {
            let ink: NSColor = CCTheme.isDark ? .white : .black
            layer?.backgroundColor = ink.withAlphaComponent(0.06).cgColor
            layer?.borderColor = isSelected
                ? NSColor.controlAccentColor.cgColor
                : ink.withAlphaComponent(0.10).cgColor
        }

        func configure(name: String, thumbnail: NSImage?, needsDownload: Bool,
                       isDownloading: Bool, isFailed: Bool, isSelected: Bool) {
            toolTip = name
            thumbnailLayer.contents = thumbnail
            self.isSelected = isSelected
            applyTheme()
            layer?.borderWidth = isSelected ? 2 : 1

            if isDownloading {
                spinner.startAnimation(nil)
                badge.isHidden = true
            } else {
                spinner.stopAnimation(nil)
                badge.isHidden = !(needsDownload || isFailed)
                if isFailed {
                    badge.image = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: nil)?
                        .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
                    badge.contentTintColor = .systemOrange
                } else if needsDownload {
                    badge.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)?
                        .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
                    badge.contentTintColor = NSColor.white.withAlphaComponent(0.85)
                }
            }
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            thumbnailLayer.frame = bounds
            CATransaction.commit()
        }

        override func mouseDown(with event: NSEvent) { onClick?() }
        override func rightMouseDown(with event: NSEvent) { onRightClick?(event) }
    }
}
