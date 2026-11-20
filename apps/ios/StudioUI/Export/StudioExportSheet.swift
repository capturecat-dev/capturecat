import AVFoundation
import ImageIO
import UIKit

/// Export from the iOS editor (Studio 3d).
///
///     StudioExport.present(from: editor, project: project)
///
/// The house sheet over the editor — the Mac's export dialog at touch scale:
/// Type (still captures in Image treatment), Format (MP4 / MOV / GIF),
/// Resolution (720p / 1080p / 4K / Custom), Frame Rate (30 / 60 fps),
/// Quality, the bit-rate caption and Fast export — every choice and caption
/// from the SHARED `ExportSheetSpec` over the shared `ExportSettings`. An
/// iPhone opens at 1080p30 (`ExportSheetSpec.phoneDefaults`). Export runs
/// `StudioExportJob` (the Mac's `VideoExporter` / `StillImageExporter`) with
/// a live progress bar that springs to each value, Cancel (partial files
/// removed) and the background note (`StudioExportBackground`); then the
/// file goes out through `ExportDelivery`: Save to Photos, Save to Files,
/// Share. Errors arrive as house `CCAlert`s.
///
/// Chrome: a scrim and a floating `CCCard` — docked to the bottom on compact
/// width (rising from it), a centred card on regular width. Every change of
/// content re-fits the card on the house growth bounce, moving only the
/// pushed edge (the top of a docked sheet, the bottom of a centred card).
@available(iOS 26, *)
@MainActor
enum StudioExport {
    @discardableResult
    static func present(from presenter: UIViewController, project: Project) -> StudioExportSheetController {
        let controller = StudioExportSheetController(project: project)
        CCAlert.topmost(from: presenter).present(controller, animated: false)
        return controller
    }

    /// The alert title for a failed export.
    static func errorTitle(for error: Error?) -> String {
        if case VideoExporter.ExportError.insufficientMemory? = error { return String(localized: "Not enough memory to export") }
        return String(localized: "Couldn't export")
    }
}

@available(iOS 26, *)
@MainActor
final class StudioExportSheetController: UIViewController {
    enum Phase: String { case form, exporting, done }

    let project: Project
    private(set) var settings: ExportSettings
    private(set) var outputKind: ExportSheetSpec.OutputKind
    private(set) var phase: Phase = .form
    private(set) var job: StudioExportJob?
    /// Called when the sheet has closed.
    var onClose: (() -> Void)?

    // Chrome.
    private let scrim = UIView()
    let card = CCCard(floating: true, tint: CCTheme.color.popover, radius: .xl)
    private let scroll = UIScrollView()
    private let content = UIStackView()
    private let titleLabel = ccLabel("", font: CCFont.title, color: CCTheme.color.foreground, lines: 0)
    private var hasEntered = false
    private var isClosing = false
    private(set) lazy var isDocked = traitCollection.horizontalSizeClass != .regular

    // Form.
    private let formStack = UIStackView()
    let typeControl = CCSegmented(segments: ExportSheetSpec.typeTitles, size: .sm)
    let formatControl = CCSegmented(segments: ExportSheetSpec.formats.map(\.rawValue), size: .sm)
    let resolutionControl = CCSegmented(segments: ExportSheetSpec.resolutions.map(\.displayName), size: .sm)
    let frameRateControl = CCSegmented(segments: ExportSheetSpec.frameRates.map(ExportSheetSpec.frameRateTitle), size: .sm)
    let widthField = CCField(placeholder: String(localized: "Width", comment: "Export sheet: custom width in pixels (field placeholder)"))
    let heightField = CCField(placeholder: String(localized: "Height", comment: "Export sheet: custom height in pixels (field placeholder)"))
    let qualitySlider = CCSlider(title: String(localized: "Quality", comment: "Export sheet: video quality slider"), value: 0.85,
                                 range: ExportSettings.minimumQuality...ExportSettings.maximumQuality, step: 0.05)
    let caption = ccLabel("", font: CCFont.caption, color: CCTheme.color.mutedForeground, lines: 0)
    let fastExportRow = CCToggleRow(title: String(localized: "Fast export", comment: "Export sheet toggle"), detail: String(localized: "Collapse still frames (identical pixels, variable frame rate)", comment: "Export sheet: explains the Fast export toggle"))
    private var typeRow: UIView!
    private var formatRow: UIView!
    private var frameRateRow: UIView!
    private var customSizeRow: UIView!

    // Exporting.
    let progressRow = StudioFeatureProgressRow()
    let backgroundNote = ccLabel("", font: CCFont.caption, color: CCTheme.color.mutedForeground, lines: 0)
    private let exportingStack = UIStackView()

    // Done.
    let summary = ccLabel("", font: CCFont.label, color: CCTheme.color.mutedForeground, lines: 0)
    private let doneStack = UIStackView()

    // Footer.
    private let footer = UIStackView()
    let cancelButton = CCButton(title: String(localized: "Cancel", comment: "Export sheet: close without exporting"), style: .secondary, size: .lg, radius: .lg)
    let exportButton = CCButton(title: String(localized: "Export", comment: "Export sheet: start the export"), symbol: "share", style: .primary, size: .lg, radius: .lg)
    let cancelExportButton = CCButton(title: String(localized: "Cancel Export", comment: "Export sheet: stop the running export"), style: .secondary, size: .lg, radius: .lg)
    let photosButton = CCButton(title: String(localized: "Save to Photos", comment: "Export sheet: save the exported file to the Photos library"), symbol: "photo-add", style: .primary, size: .lg, radius: .lg)
    let filesButton = CCButton(title: String(localized: "Save to Files", comment: "Export sheet: save the exported file with the Files app"), symbol: "folder", style: .secondary, size: .lg, radius: .lg)
    let shareButton = CCButton(title: String(localized: "Share", comment: "Export sheet: open the share sheet for the exported file"), symbol: "share", style: .secondary, size: .lg, radius: .lg)
    let doneButton = CCButton(title: String(localized: "Done", comment: "Export sheet: close after exporting"), style: .ghost, size: .lg, radius: .lg)

    private var observation: SurfaceObservation?
    private var heightPin: NSLayoutConstraint?
    private var topPin: NSLayoutConstraint?
    private var scrollHeight: NSLayoutConstraint!

    #if DEBUG
    /// Probe seams — INJECTED DEFECT for `--export-sheet --inject wrong-resolution`:
    /// the resolution row writes the NEXT resolution, not the one tapped.
    static var probeWrongResolution = false
    /// Probe seam: the phone default applies (nil = this device's idiom).
    static var probeIsPhone: Bool?
    /// Probe seam: every alert the sheet presented.
    private(set) var probeAlerts: [CCAlert] = []
    /// Probe seam: the delivery controllers it presented, in order.
    private(set) var probePresented: [UIViewController] = []
    #endif

    var isPhone: Bool {
        #if DEBUG
        if let p = Self.probeIsPhone { return p }
        #endif
        return UIDevice.current.userInterfaceIdiom == .phone
    }

    init(project: Project) {
        self.project = project
        settings = project.settings.exportSettings
        outputKind = ExportSheetSpec.defaultOutputKind(for: project)
        super.init(nibName: nil, bundle: nil)
        if isPhone { settings = ExportSheetSpec.phoneDefaults(settings) }
        modalPresentationStyle = .overFullScreen
        modalPresentationCapturesStatusBarAppearance = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Build

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        scrim.backgroundColor = CCTheme.color.overlay
        scrim.alpha = 0
        scrim.translatesAutoresizingMaskIntoConstraints = false
        scrim.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(scrimTapped)))
        view.addSubview(scrim)
        card.alpha = 0
        card.accessibilityViewIsModal = true
        card.accessibilityIdentifier = "studio.export.card"
        view.addSubview(card)

        let tile = CCIconTile(symbol: "film", side: 44, kind: .recessed, tint: CCTheme.color.primary.withAlphaComponent(0.14),
                              iconSize: 19, iconTint: CCTheme.color.primary, radius: .md)
        let tileHolder = UIView()
        tileHolder.addSubview(tile)
        NSLayoutConstraint.activate([
            tile.leadingAnchor.constraint(equalTo: tileHolder.leadingAnchor),
            tile.topAnchor.constraint(equalTo: tileHolder.topAnchor),
            tile.bottomAnchor.constraint(equalTo: tileHolder.bottomAnchor),
        ])
        titleLabel.accessibilityTraits = .header

        content.axis = .vertical
        content.spacing = CCSpace.md
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addArrangedSubview(tileHolder)
        content.addArrangedSubview(titleLabel)
        content.setCustomSpacing(CCSpace.sm, after: tileHolder)
        buildForm()
        buildExporting()
        buildDone()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = false
        scroll.showsVerticalScrollIndicator = false
        scroll.addSubview(content)
        card.addSubview(scroll)
        buildFooter()
        card.addSubview(footer)

        scrollHeight = scroll.heightAnchor.constraint(equalTo: content.heightAnchor)
        scrollHeight.priority = .required - 2
        // Rows with only a minimum height (the toggle row's ≥ 44) would
        // otherwise stretch to whatever the free-height card resolves to: the
        // content always takes its smallest valid height.
        let hug = content.heightAnchor.constraint(equalToConstant: 0)
        hug.priority = .fittingSizeLevel
        hug.isActive = true
        NSLayoutConstraint.activate([
            scrim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrim.topAnchor.constraint(equalTo: view.topAnchor),
            scrim.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.topAnchor.constraint(equalTo: card.topAnchor, constant: CCSpace.xl),
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: CCSpace.xl),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -CCSpace.xl),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor),
            scrollHeight,
            footer.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: CCSpace.xl),
            footer.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: CCSpace.xl),
            footer.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -CCSpace.xl),
            footer.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -CCSpace.xl),
            card.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: CCSpace.lg),
            card.bottomAnchor.constraint(lessThanOrEqualTo: view.keyboardLayoutGuide.topAnchor, constant: -CCSpace.sm),
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
        if isDocked {
            let fill = card.widthAnchor.constraint(equalTo: view.safeAreaLayoutGuide.widthAnchor, constant: -CCSpace.sm * 2)
            fill.priority = .required - 1
            let bottom = card.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -CCSpace.sm)
            bottom.priority = .defaultHigh
            NSLayoutConstraint.activate([card.widthAnchor.constraint(lessThanOrEqualToConstant: 500), fill, bottom])
            view.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(pan(_:))))
        } else {
            let width = card.widthAnchor.constraint(equalToConstant: 440)
            width.priority = .required - 1
            let centerY = card.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -12)
            centerY.priority = .defaultLow
            NSLayoutConstraint.activate([
                width, centerY,
                card.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: CCSpace.xl),
            ])
        }
        applySettingsToControls()
        applyPhase()
    }

    private func row(_ title: String, _ control: UIView) -> UIView {
        let label = ccLabel(title, font: CCFont.labelMedium, color: CCTheme.color.foreground)
        let stack = UIStackView(arrangedSubviews: [label, control])
        stack.axis = .vertical
        stack.spacing = CCSpace.xs + 2
        control.accessibilityLabel = title
        return stack
    }

    private func buildForm() {
        formStack.axis = .vertical
        formStack.spacing = CCSpace.md
        typeRow = row(String(localized: "Type", comment: "Export sheet row: image or video"), typeControl)
        formatRow = row(String(localized: "Format", comment: "Export sheet row: file format (MP4, GIF…)"), formatControl)
        let resolutionRow = row(String(localized: "Resolution", comment: "Export sheet row: output resolution"), resolutionControl)
        for field in [widthField, heightField] {
            field.keyboardType = .numberPad
            field.textAlignment = .center
            field.addAction(UIAction { [weak self] _ in self?.commitCustomSize() }, for: .editingDidEnd)
        }
        let times = ccLabel("×", font: CCFont.label, color: CCTheme.color.mutedForeground)
        let sizeStack = UIStackView(arrangedSubviews: [widthField, times, heightField])
        sizeStack.spacing = CCSpace.sm
        sizeStack.alignment = .center
        widthField.widthAnchor.constraint(equalTo: heightField.widthAnchor).isActive = true
        customSizeRow = row(String(localized: "Size", comment: "Export sheet row: custom width × height"), sizeStack)
        frameRateRow = row(String(localized: "Frame Rate", comment: "Export sheet row: frames per second"), frameRateControl)
        for v in [typeRow!, formatRow!, resolutionRow, customSizeRow!, frameRateRow!, qualitySlider, caption, fastExportRow] {
            formStack.addArrangedSubview(v)
        }
        formStack.setCustomSpacing(CCSpace.xs, after: qualitySlider)
        content.addArrangedSubview(formStack)

        typeControl.onChange = { [weak self] index in
            guard let self else { return }
            self.outputKind = index == 0 ? .image : .video
            self.animateContentChange { self.applyVisibility() }
        }
        formatControl.onChange = { [weak self] index in
            guard let self else { return }
            self.settings.format = ExportSheetSpec.formats[index]
            self.refreshCaption()
        }
        resolutionControl.onChange = { [weak self] index in
            guard let self else { return }
            var chosen = index
            #if DEBUG
            if Self.probeWrongResolution { chosen = min(index + 1, ExportSheetSpec.resolutions.count - 1) }
            #endif
            self.settings.resolution = ExportSheetSpec.resolutions[chosen]
            self.refreshCaption()
            self.animateContentChange { self.applyVisibility() }
        }
        frameRateControl.onChange = { [weak self] index in
            guard let self else { return }
            self.settings.fps = ExportSheetSpec.frameRates[index]
            self.refreshCaption()
        }
        qualitySlider.format = { String(format: "%.0f%%", $0 * 100) }
        qualitySlider.onChange = { [weak self] value in
            self?.settings.quality = value
            self?.refreshCaption()
        }
        fastExportRow.onChange = { [weak self] on in self?.settings.collapseStaticSpans = on }
    }

    private func buildExporting() {
        exportingStack.axis = .vertical
        exportingStack.spacing = CCSpace.md
        progressRow.accessibilityIdentifier = "studio.export.progress"
        exportingStack.addArrangedSubview(progressRow)
        exportingStack.addArrangedSubview(backgroundNote)
        content.addArrangedSubview(exportingStack)
    }

    private func buildDone() {
        doneStack.axis = .vertical
        doneStack.spacing = CCSpace.sm
        doneStack.addArrangedSubview(summary)
        content.addArrangedSubview(doneStack)
    }

    private func buildFooter() {
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.axis = .vertical
        footer.spacing = CCSpace.sm
        for b in [exportButton, photosButton, filesButton, shareButton, cancelExportButton, cancelButton, doneButton] {
            footer.addArrangedSubview(b)
        }
        cancelButton.onTap = { [weak self] in self?.close() }
        exportButton.onTap = { [weak self] in self?.startExport() }
        cancelExportButton.onTap = { [weak self] in self?.job?.cancel() }
        doneButton.onTap = { [weak self] in self?.close() }
        photosButton.onTap = { [weak self] in self?.saveToPhotos() }
        filesButton.onTap = { [weak self] in self?.saveToFiles() }
        shareButton.onTap = { [weak self] in self?.share() }
    }

    private func applySettingsToControls() {
        typeControl.setSelectedIndex(outputKind == .image ? 0 : 1, animated: false)
        formatControl.setSelectedIndex(ExportSheetSpec.formats.firstIndex(of: settings.format) ?? 0, animated: false)
        resolutionControl.setSelectedIndex(ExportSheetSpec.resolutions.firstIndex(of: settings.resolution) ?? 1, animated: false)
        frameRateControl.setSelectedIndex(ExportSheetSpec.frameRateIndex(settings.fps), animated: false)
        widthField.text = String(settings.customWidth)
        heightField.text = String(settings.customHeight)
        qualitySlider.setValue(settings.quality, animated: false)
        fastExportRow.setOn(settings.collapseStaticSpans, animated: false)
        refreshCaption()
    }

    private func refreshCaption() {
        caption.text = ExportSheetSpec.caption(settings: settings, project: project)
    }

    /// Rows by output kind and resolution (the Mac sheet's rules).
    private func applyVisibility() {
        let isImage = outputKind == .image
        typeRow.isHidden = !ExportSheetSpec.offersImage(project)
        formatRow.isHidden = isImage
        frameRateRow.isHidden = isImage
        qualitySlider.isHidden = isImage
        caption.isHidden = isImage
        fastExportRow.isHidden = isImage
        customSizeRow.isHidden = settings.resolution != .custom
        titleLabel.text = phase == .done ? (isImage ? String(localized: "Image exported", comment: "Export sheet title when an image export finished") : String(localized: "Exported", comment: "Export sheet title / status when a video export finished"))
            : ExportSheetSpec.title(for: outputKind)
    }

    private func applyPhase() {
        formStack.isHidden = phase != .form
        exportingStack.isHidden = phase != .exporting
        doneStack.isHidden = phase != .done
        exportButton.isHidden = phase != .form
        cancelButton.isHidden = phase != .form
        cancelExportButton.isHidden = phase != .exporting
        for b in [photosButton, filesButton, shareButton, doneButton] { b.isHidden = phase != .done }
        applyVisibility()
    }

    private func setPhase(_ next: Phase) {
        guard next != phase else { return }
        phase = next
        animateContentChange { self.applyPhase() }
        UIAccessibility.post(notification: .layoutChanged, argument: titleLabel)
    }

    // MARK: - Wrapping labels

    /// Multi-line labels inside the scroll view measure their height at their
    /// laid-out width (the scroll view gives them no width to wrap against on
    /// the first pass, which left tall labels with their text centred in gaps).
    @discardableResult
    private func refreshLabelWidths() -> Bool {
        var changed = false
        func walk(_ v: UIView) {
            if let label = v as? UILabel, label.numberOfLines == 0, !label.isHidden {
                let width = label.bounds.width > 0 ? label.bounds.width : scroll.bounds.width
                if width > 0, abs(label.preferredMaxLayoutWidth - width) > 0.5 {
                    label.preferredMaxLayoutWidth = width
                    changed = true
                }
            }
            v.subviews.forEach(walk)
        }
        walk(content)
        return changed
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if refreshLabelWidths() { view.setNeedsLayout() }
    }

    // MARK: - Motion

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasEntered else { return }
        hasEntered = true
        CCMotion.fadeAlpha(scrim, to: 1, duration: 0.22, from: 0)
        CCMotion.fadeAlpha(card, to: 1, duration: 0.18, from: 0)
        if isDocked {
            if !CCMotion.reduceMotion {
                let travel = view.bounds.height - card.frame.minY
                CCMotion.spring(card.layer, keyPath: "transform.translation.y", from: travel, to: 0, .arrive)
            }
        } else {
            CCMotion.enter(card.layer, .scaleIn)
        }
        UIAccessibility.post(notification: .screenChanged, argument: card)
    }

    /// The card's height the content needs, capped by the room on screen.
    private func fittedHeight() -> CGFloat {
        let needed = card.systemLayoutSizeFitting(
            CGSize(width: card.bounds.width, height: 0),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
        let room = view.keyboardLayoutGuide.layoutFrame.minY - view.safeAreaInsets.top - CCSpace.lg - CCSpace.sm
        return min(needed, max(room, 200))
    }

    /// Re-fits the card to a content change on the house growth bounce;
    /// only the pushed edge moves (the docked sheet's top, the centred card's bottom).
    func animateContentChange(_ changes: @escaping () -> Void) {
        guard isViewLoaded, view.window != nil, card.bounds.height > 0 else {
            changes()
            return
        }
        view.layoutIfNeeded()
        if !isDocked, topPin == nil {
            let pin = card.topAnchor.constraint(equalTo: view.topAnchor, constant: card.frame.minY)
            pin.priority = UILayoutPriority(700)
            pin.isActive = true
            topPin = pin
        }
        let start = card.bounds.height
        heightPin?.isActive = false
        changes()
        view.layoutIfNeeded()
        if refreshLabelWidths() { view.layoutIfNeeded() }
        let target = fittedHeight()
        let height = card.heightAnchor.constraint(equalToConstant: start)
        height.priority = .required - 1
        height.isActive = true
        heightPin = height
        view.layoutIfNeeded()
        CCMotion.animate(height, to: target, in: view, duration: 0.42, curve: .bounce) { [weak self, weak height] in
            guard let self, let height, self.heightPin === height else { return }
            height.isActive = false
            self.heightPin = nil
        }
    }

    // MARK: - Export

    private func commitCustomSize() {
        if let w = Int(widthField.text ?? ""), w > 0 { settings.customWidth = w }
        if let h = Int(heightField.text ?? ""), h > 0 { settings.customHeight = h }
        refreshCaption()
    }

    /// Export — the sheet's chosen settings through the shared exporter.
    func startExport() {
        guard phase == .form else { return }
        view.endEditing(true)
        commitCustomSize()
        let job = StudioExportJob(project: project, kind: outputKind, settings: settings)
        self.job = job
        progressRow.update(text: String(localized: "Exporting… \(0 as Int)%", comment: "Export progress line, e.g. Exporting… 42%"), value: 0)
        job.start()
        backgroundNote.text = job.background.note
        setPhase(.exporting)
        observation = SurfaceObservation { [weak self, weak job] in
            guard let self, let job else { return }
            let state = job.state
            let progress = job.progress
            switch state {
            case .running:
                self.progressRow.update(text: String(localized: "Exporting… \(Int((progress * 100).rounded(.down)))%", comment: "Export progress line, e.g. Exporting… 42%"), value: progress)
            case .finished(let url):
                self.progressRow.update(text: String(localized: "Exported", comment: "Export sheet title / status when a video export finished"), value: 1)
                self.finished(url)
            case .failed(let message):
                self.failed(message, error: job.error)
            case .cancelled:
                self.observation?.cancel()
                self.job = nil
                self.setPhase(.form)
            }
        }
    }

    private func finished(_ url: URL) {
        observation?.cancel()
        summary.text = url.lastPathComponent
        setPhase(.done)
        CCHaptics.success()
        Task { @MainActor [weak self] in
            let line = await Self.describe(url)
            guard let self, self.phase == .done else { return }
            self.animateContentChange { self.summary.text = line }
        }
    }

    private func failed(_ message: String, error: Error?) {
        observation?.cancel()
        job = nil
        setPhase(.form)
        presentAlert(title: StudioExport.errorTitle(for: error), message: message)
    }

    private func presentAlert(title: String, message: String) {
        let alert = CCAlert(title: title, message: message)
        alert.symbol = "warning-fill"
        alert.tone = .destructive
        alert.addButton(String(localized: "OK", comment: "Alert button"), role: .primary)
        #if DEBUG
        probeAlerts.append(alert)
        #endif
        alert.present(from: self)
    }

    /// "name.mp4 · 1280×720 · 4.0 s · 2.1 MB" (read back from the file).
    static func describe(_ url: URL) async -> String {
        var parts = [url.lastPathComponent]
        switch ExportDelivery.kind(for: url) {
        case .gif, .png:
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
                parts.append("\(w)×\(h)")
                let frames = CGImageSourceGetCount(source)
                if frames > 1 { parts.append(String(localized: "\(frames) frames", comment: "Exported file summary: frame count of an animated GIF")) }
            }
        case .movie:
            let asset = AVURLAsset(url: url)
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize) {
                parts.append("\(Int(size.width))×\(Int(size.height))")
            }
            if let duration = try? await asset.load(.duration) {
                let seconds = String(format: "%.1f", duration.seconds)
                parts.append(String(localized: "\(seconds) s", comment: "Exported file summary: duration in seconds, e.g. 4.0 s"))
            }
        }
        if let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 {
            parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Delivery

    private var exportedURL: URL? {
        if case .finished(let url)? = job?.state { return url }
        return nil
    }

    private func saveToPhotos() {
        guard let url = exportedURL, !photosButton.isBusy else { return }
        photosButton.isBusy = true
        Task { @MainActor [weak self] in
            do {
                _ = try await ExportDelivery.saveToPhotos(url)
                guard let self else { return }
                self.photosButton.isBusy = false
                self.photosButton.title = String(localized: "Saved to Photos", comment: "Export sheet button after saving to Photos succeeded")
                self.photosButton.symbol = "check"
                self.photosButton.isEnabled = false
                CCHaptics.success()
            } catch {
                guard let self else { return }
                self.photosButton.isBusy = false
                self.presentAlert(title: String(localized: "Couldn't save to Photos"), message: error.localizedDescription)
            }
        }
    }

    private func saveToFiles() {
        guard let url = exportedURL else { return }
        presentDelivery(ExportDelivery.filesPicker(for: url))
    }

    private func share() {
        guard let url = exportedURL else { return }
        presentDelivery(ExportDelivery.shareSheet(for: url, from: shareButton))
    }

    private func presentDelivery(_ controller: UIViewController) {
        #if DEBUG
        probePresented.append(controller)
        #endif
        present(controller, animated: true)
    }

    // MARK: - Closing

    @objc private func scrimTapped() {
        guard phase != .exporting else { return }
        close()
    }

    @objc private func pan(_ gesture: UIPanGestureRecognizer) {
        guard !isClosing, phase != .exporting else { return }
        let dy = max(0, gesture.translation(in: view).y)
        switch gesture.state {
        case .changed:
            card.transform = CGAffineTransform(translationX: 0, y: dy)
            scrim.alpha = max(0, 1 - dy / 300)
        case .ended, .cancelled:
            if dy > 90 || gesture.velocity(in: view).y > 800 {
                close()
            } else {
                CCMotion.springViews(.snappy) {
                    self.card.transform = .identity
                    self.scrim.alpha = 1
                }
            }
        default:
            break
        }
    }

    override func accessibilityPerformEscape() -> Bool {
        guard phase != .exporting else { return false }
        close()
        return true
    }

    /// Closes the sheet; a finished export's file is discarded (Photos, Files
    /// and Share made their own copies).
    func close() {
        guard !isClosing, phase != .exporting else { return }
        isClosing = true
        view.endEditing(true)
        observation?.cancel()
        job?.discard()
        if isDocked {
            let travel = view.bounds.height - card.frame.minY
            CCMotion.run(duration: 0.22, curve: .glide) {
                self.card.transform = CGAffineTransform(translationX: 0, y: travel)
            }
        } else {
            CCMotion.exit(card.layer, .scaleIn)
            CCMotion.fadeAlpha(card, to: 0, duration: 0.16)
        }
        CCMotion.fadeAlpha(scrim, to: 0, duration: 0.18)
        DispatchQueue.main.asyncAfter(deadline: .now() + CCMotion.paced(0.2)) { [weak self] in
            guard let self else { return }
            let onClose = self.onClose
            self.dismiss(animated: false) { onClose?() }
        }
    }
}
