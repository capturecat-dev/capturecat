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
    private let showToggle = InspectorToggleControl("Show Watermark")

    private let logoRow = NSStackView()
    private let thumbBox = NSView()
    private let thumbImage = NSImageView()
    private let thumbPlaceholder = NSImageView()
    private let chooseButton = InspectorButton("Choose Logo…")
    private let removeButton = InspectorButton("Remove", destructive: true)
    private let errorLabel = InspectorKitViews.caption("")

    private let pad: WatermarkPositionPadControl
    private let sizeSlider = InspectorSliderRow(label: "Size", range: 40...400, step: 10)
    private let opacitySlider = InspectorSliderRow(label: "Opacity", range: 0.1...1.0, step: 0.05)
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
        thumbPlaceholder.image = NSImage(
            systemSymbolName: "photo.badge.plus", accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
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
        positionBox.addRow(pad)
        pad.heightAnchor.constraint(equalToConstant: 96).isActive = true
        positionBox.addRow(sizeSlider)
        opacitySlider.format = { "\(Int(($0 * 100).rounded()))%" }
        positionBox.addRow(opacitySlider)
        fullWidth(positionBox)
        detailViews = [positionBox]
    }

    private func wire() {
        showToggle.onChange = { [weak self] on in self?.project.settings.showWatermark = on }
        chooseButton.onClick = { [weak self] in self?.pickLogo() }
        removeButton.onClick = { [weak self] in self?.removeLogo() }
        sizeSlider.onChange = { [weak self] v in
            self?.project.settings.watermarkSize = v
            self?.pad.refresh()
        }
        opacitySlider.onChange = { [weak self] v in
            self?.project.settings.watermarkOpacity = v
            self?.pad.refresh()
        }
    }

    // Same pick/copy semantics as the SwiftUI pane: copy into the project
    // folder under a fresh name (cache-busting), remove the previous file.
    private func pickLogo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a logo image (PNG with transparency works best)"
        guard panel.runModal() == .OK, let source = panel.url else { return }
        guard let folder = project.videoURL?.deletingLastPathComponent() else {
            errorLabel.stringValue = "Project folder not available."
            errorLabel.isHidden = false
            return
        }
        let destName = "watermark-\(UUID().uuidString.prefix(8)).\(source.pathExtension.lowercased())"
        let dest = folder.appendingPathComponent(destName)
        do {
            let previous = project.watermarkImageURL
            try FileManager.default.copyItem(at: source, to: dest)
            project.settings.watermarkFileName = destName
            project.settings.showWatermark = true
            errorLabel.stringValue = ""
            if let previous { try? FileManager.default.removeItem(at: previous) }
        } catch {
            errorLabel.stringValue = "Couldn't copy logo: \(error.localizedDescription)"
        }
    }

    private func removeLogo() {
        if let url = project.watermarkImageURL {
            try? FileManager.default.removeItem(at: url)
        }
        project.settings.watermarkFileName = nil
        project.settings.showWatermark = false
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
        showToggle.isOn = s.showWatermark

        if loadedName != s.watermarkFileName {
            loadedName = s.watermarkFileName
            thumbnail = project.watermarkImageURL.flatMap { NSImage(contentsOf: $0) }
            pad.logo = thumbnail
        }
        thumbImage.image = thumbnail
        thumbPlaceholder.isHidden = thumbnail != nil
        chooseButton.title = s.watermarkFileName == nil ? "Choose Logo…" : "Replace Logo…"
        removeButton.isHidden = s.watermarkFileName == nil
        errorLabel.isHidden = errorLabel.stringValue.isEmpty

        let showDetails = s.showWatermark && s.watermarkFileName != nil
        for view in detailViews { view.isHidden = !showDetails }
        sizeSlider.setValue(s.watermarkSize)
        opacitySlider.setValue(s.watermarkOpacity)
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
        let symbol = NSImage(systemSymbolName: "seal.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
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
        let t = (min(400, max(40, settings.watermarkSize)) - 40) / 360
        let w = 12 + CGFloat(t) * 44
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

    private func setFraction(from point: CGPoint) {
        let mark = markSize
        let usableW = max(1, bounds.width - 2 * inset - mark.width)
        let usableH = max(1, bounds.height - 2 * inset - mark.height)
        let fx = (point.x - inset - mark.width / 2) / usableW
        let fy = (point.y - inset - mark.height / 2) / usableH
        settings.watermarkX = Double(min(1, max(0, fx)))
        settings.watermarkY = Double(min(1, max(0, fy)))
        refresh()
    }

    override func mouseDown(with event: NSEvent) {
        setFraction(from: convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        setFraction(from: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        // Per-axis edge/corner magnetism — same thresholds as SwiftUI.
        if abs(settings.watermarkX) < 0.06 { settings.watermarkX = 0 }
        if abs(settings.watermarkX - 1) < 0.06 { settings.watermarkX = 1 }
        if abs(settings.watermarkY) < 0.06 { settings.watermarkY = 0 }
        if abs(settings.watermarkY - 1) < 0.06 { settings.watermarkY = 1 }
        refresh()
    }
}
