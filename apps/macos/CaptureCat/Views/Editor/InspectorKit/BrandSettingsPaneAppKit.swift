import AppKit
import UniformTypeIdentifiers

/// The Brand tab as a native AppKit pane — faithful port of BrandSettingsView:
/// watermark toggle, logo picker (copied into the project folder), free-drag
/// position pad whose mark tracks the Size slider and the logo's aspect,
/// and Size / Opacity sliders.
@MainActor
final class BrandSettingsPaneAppKit: NSView {
    private let project: Project

    private let stack = NSStackView()
    // Every control's title/range/step/readout, write and visibility: the
    // shared BrandPane spec (Studio/Editor/Inspector).
    private let showToggle = InspectorToggleControl(BrandPane.show)

    private let logoRow = NSStackView()
    private let thumbBox = NSView()
    private let thumbImage = NSImageView()
    private let thumbPlaceholder = NSImageView()
    private let chooseButton = InspectorButton("Choose Logo…")
    private let removeButton = InspectorButton(BrandPane.remove)
    private let errorLabel = InspectorKitViews.caption("")

    private let pad: WatermarkPositionPadControl
    private let sizeSlider = InspectorSliderRow(BrandPane.size)
    private let opacitySlider = InspectorSliderRow(BrandPane.opacity)
    private var detailViews: [NSView] = []

    private var thumbnail: NSImage?
    private var loadedName: String??

    override var isFlipped: Bool { true }

    init(project: Project) {
        self.project = project
        self.pad = WatermarkPositionPadControl(settings: project.settings)
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
        // Separate from the settings observation loop — a CCTheme.apply must
        // not re-arm withObservationTracking.
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError() }

    private var themeObservation: CCThemeObservation?

    private func applyTheme() {
        thumbBox.layer?.backgroundColor = EditorThemeKit.panelElevated.cgColor
        thumbBox.layer?.borderColor = EditorThemeKit.hairline.cgColor
        thumbPlaceholder.contentTintColor = EditorThemeKit.textTertiary
    }

    private func fullWidth(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func build() {
        let brandBox = InspectorSectionBox("Brand")
        brandBox.addRow(showToggle)

        // Logo row: 44pt thumbnail card + Choose/Remove buttons
        thumbBox.wantsLayer = true
        thumbBox.layer?.cornerRadius = 6
        thumbBox.layer?.cornerCurve = .continuous
        thumbBox.layer?.borderWidth = 1
        thumbImage.imageScaling = .scaleProportionallyDown
        thumbPlaceholder.image = CCIcon.image("photo.badge.plus", pointSize: 14, weight: .regular)
        for v in [thumbImage, thumbPlaceholder] {
            v.translatesAutoresizingMaskIntoConstraints = false
            thumbBox.addSubview(v)
        }
        NSLayoutConstraint.activate([
            thumbBox.widthAnchor.constraint(equalToConstant: 44),
            thumbBox.heightAnchor.constraint(equalToConstant: 44),
            thumbImage.leadingAnchor.constraint(equalTo: thumbBox.leadingAnchor, constant: 4),
            thumbImage.trailingAnchor.constraint(equalTo: thumbBox.trailingAnchor, constant: -4),
            thumbImage.topAnchor.constraint(equalTo: thumbBox.topAnchor, constant: 4),
            thumbImage.bottomAnchor.constraint(equalTo: thumbBox.bottomAnchor, constant: -4),
            thumbPlaceholder.centerXAnchor.constraint(equalTo: thumbBox.centerXAnchor),
            thumbPlaceholder.centerYAnchor.constraint(equalTo: thumbBox.centerYAnchor),
        ])

        let buttons = NSStackView()
        buttons.orientation = .vertical
        buttons.alignment = .leading
        buttons.spacing = 6
        buttons.addArrangedSubview(chooseButton)
        buttons.addArrangedSubview(removeButton)

        logoRow.orientation = .horizontal
        logoRow.alignment = .top
        logoRow.spacing = 10
        logoRow.addArrangedSubview(thumbBox)
        logoRow.addArrangedSubview(buttons)
        brandBox.addRow(logoRow)

        errorLabel.textColor = .systemRed
        brandBox.addRow(errorLabel, attached: true)
        fullWidth(brandBox)

        let positionBox = InspectorSectionBox("Position")
        pad.inspectorSpecID = "brand.pad"
        positionBox.addRow(pad)
        pad.heightAnchor.constraint(equalToConstant: 96).isActive = true
        positionBox.addRow(sizeSlider)
        positionBox.addRow(opacitySlider)
        fullWidth(positionBox)
        detailViews = [positionBox]
    }

    /// The pane's scope for the shared spec.
    private var scope: InspectorScope { InspectorScope(settings: project.settings, project: project) }

    private func wire() {
        let scope: () -> InspectorScope? = { [weak self] in self?.scope }
        showToggle.bind(BrandPane.show, scope)
        chooseButton.inspectorSpecID = "brand.choose"
        chooseButton.onClick = { [weak self] in self?.pickLogo() }
        removeButton.onClick = { [weak self] in self?.removeLogo() }
        sizeSlider.onChange = { [weak self] v in
            guard let self else { return }
            BrandPane.size.write(self.scope, v)
            self.pad.refresh()
        }
        opacitySlider.onChange = { [weak self] v in
            guard let self else { return }
            BrandPane.opacity.write(self.scope, v)
            self.pad.refresh()
        }
    }

    // Same pick/copy semantics as the SwiftUI pane: copy into the project
    // folder under a fresh name (cache-busting), remove the previous file
    // (BrandPane.adoptLogo, shared with iOS).
    private func pickLogo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a logo image (PNG with transparency works best)"
        guard panel.runModal() == .OK, let source = panel.url else { return }
        do {
            try BrandPane.adoptLogo(scope, from: source)
            errorLabel.stringValue = ""
        } catch InspectorMediaError.noProjectFolder {
            errorLabel.stringValue = "Project folder not available."
            errorLabel.isHidden = false
        } catch {
            errorLabel.stringValue = "Couldn't copy logo: \(error.localizedDescription)"
        }
    }

    private func removeLogo() {
        BrandPane.removeLogo(scope)
        thumbnail = nil
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
        let s = project.settings
        let scope = self.scope
        showToggle.isOn = BrandPane.show.read(scope)

        if loadedName != s.watermarkFileName {
            loadedName = s.watermarkFileName
            thumbnail = project.watermarkImageURL.flatMap { NSImage(contentsOf: $0) }
            pad.logo = thumbnail
        }
        thumbImage.image = thumbnail
        thumbPlaceholder.isHidden = thumbnail != nil
        chooseButton.title = BrandPane.chooseTitle(scope)
        removeButton.isHidden = !BrandPane.remove.visible(scope)
        errorLabel.isHidden = errorLabel.stringValue.isEmpty

        let showDetails = BrandPane.detailsVisible(scope)
        for view in detailViews { view.isHidden = !showDetails }
        sizeSlider.setValue(BrandPane.size.read(scope))
        opacitySlider.setValue(BrandPane.opacity.read(scope))
        pad.refresh()
    }
}

// MARK: - Watermark pad (native twin of WatermarkPositionPad)

@MainActor
final class WatermarkPositionPadControl: NSView {
    private let settings: ProjectSettings
    private let inset: CGFloat = 8
    private let markLayer = CALayer()
    private let fallbackLayer = CALayer()

    var logo: NSImage? {
        didSet { refresh() }
    }

    override var isFlipped: Bool { true }

    init(settings: ProjectSettings) {
        self.settings = settings
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = CCTheme.radius(.lg)
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        markLayer.contentsGravity = .resizeAspect
        markLayer.contentsScale = 2
        layer?.addSublayer(markLayer)

        // seal.fill placeholder when no logo yet
        let symbol = CCIcon.image("seal.fill", pointSize: 12, weight: .regular)
        fallbackLayer.contents = symbol
        fallbackLayer.contentsGravity = .resizeAspect
        fallbackLayer.opacity = 0.7
        layer?.addSublayer(fallbackLayer)

        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError() }

    private var themeObservation: CCThemeObservation?

    /// Pad chrome only — the logo mark is the user's own asset.
    private func applyTheme() {
        let ink: NSColor = CCTheme.isDark ? .white : .black
        layer?.backgroundColor = ink.withAlphaComponent(0.06).cgColor
        layer?.borderColor = ink.withAlphaComponent(0.12).cgColor
    }

    /// Mini logo mirrors the Size slider (40…400 px → 12…56 pt wide) and the
    /// real logo's aspect — same mapping as the SwiftUI pad.
    private var markSize: CGSize {
        let w = InspectorPadMath.watermarkMarkWidth(size: settings.watermarkSize)
        let aspect: CGFloat = {
            guard let logo, logo.size.height > 0 else { return 1.5 }
            return logo.size.width / logo.size.height
        }()
        return CGSize(width: w, height: w / max(0.35, min(4, aspect)))
    }

    override func layout() {
        super.layout()
        refresh()
    }

    func refresh() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let mark = markSize
        let usableW = max(1, bounds.width - 2 * inset - mark.width)
        let usableH = max(1, bounds.height - 2 * inset - mark.height)
        let fx = CGFloat(min(1, max(0, settings.watermarkX)))
        let fy = CGFloat(min(1, max(0, settings.watermarkY)))
        let frame = CGRect(
            x: inset + usableW * fx, y: inset + usableH * fy,
            width: mark.width, height: mark.height
        )
        let alpha = Float(max(0.35, settings.watermarkOpacity))
        if let logo {
            markLayer.isHidden = false
            fallbackLayer.isHidden = true
            markLayer.contents = logo
            markLayer.frame = frame
            markLayer.opacity = alpha
        } else {
            markLayer.isHidden = true
            fallbackLayer.isHidden = false
            fallbackLayer.frame = frame
            fallbackLayer.opacity = alpha
        }
        CATransaction.commit()
    }

    #if DEBUG
    /// Probe seam: the point a press must land on for mark fraction (fx, fy).
    func probePoint(fx: CGFloat, fy: CGFloat) -> NSPoint {
        let mark = markSize
        let usableW = max(1, bounds.width - 2 * inset - mark.width)
        let usableH = max(1, bounds.height - 2 * inset - mark.height)
        return NSPoint(x: inset + mark.width / 2 + fx * usableW, y: inset + mark.height / 2 + fy * usableH)
    }
    #endif

    private func setFraction(from point: CGPoint) {
        let mark = markSize
        let usableW = max(1, bounds.width - 2 * inset - mark.width)
        let usableH = max(1, bounds.height - 2 * inset - mark.height)
        let fx = (point.x - inset - mark.width / 2) / usableW
        let fy = (point.y - inset - mark.height / 2) / usableH
        InspectorPadMath.watermarkDrag(settings, fx: fx, fy: fy)
        refresh()
    }

    override func mouseDown(with event: NSEvent) {
        setFraction(from: convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        setFraction(from: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        // Per-axis edge/corner magnetism — InspectorPadMath, shared with iOS.
        InspectorPadMath.watermarkRelease(settings)
        refresh()
    }
}
