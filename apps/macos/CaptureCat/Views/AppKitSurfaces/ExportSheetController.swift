import AppKit
import UniformTypeIdentifiers

/// Native export sheet — faithful port of ExportView: format/resolution/fps/
/// quality settings on InspectorKit controls, the auth gate, the exporting
/// progress state, share-after-export, and the identical export pipeline
/// (save panel → detached VideoExporter → optional share upload → reveal).
@MainActor
final class ExportSheetController: NSViewController {
    private let appState: AppState
    private let project: Project
    /// Called when the sheet wants to close (Cancel or finished export).
    var onDismiss: (() -> Void)?

    private var exportSettings: ExportSettings
    private var exporter = VideoExporter()
    private var isExporting = false
    private var isCheckingAccess = false
    private var shouldStartExportAfterSignIn = false
    private var shareAfterExport = false
    private var allowComments = false

    /// What the sheet produces. `.image` exists only for still captures in
    /// Image treatment; everything else is pinned to `.video` and sees the
    /// sheet exactly as before.
    private enum OutputKind { case image, video }
    private var outputKind: OutputKind = .video
    /// The Image (PNG) | Video (MP4) chooser — built only for image-treatment
    /// stills.
    private var outputKindRow: NSView?
    private let outputKindChips = InspectorChipsControl()

    // Rows hidden while exporting a PNG (video-only controls).
    private var formatRow: NSView?
    private var fpsRow: NSView?

    private var progressTimer: Timer?
    private var shareObservation: SurfaceObservation?
    private var themeObservation: CCThemeObservation?

    // Form controls
    private let formatMenu = InspectorMenuControl()
    private let resolutionMenu = InspectorMenuControl()
    private let fpsMenu = InspectorMenuControl()
    private let customWidthField = InspectorFlatTextField(placeholder: "Width", width: 70)
    private let customHeightField = InspectorFlatTextField(placeholder: "Height", width: 70)
    private var customSizeRow: NSView!
    private let qualityRow = InspectorSliderRow(label: "Quality", range: ExportSettings.minimumQuality...ExportSettings.maximumQuality, step: 0.05)
    private let bitrateCaption = InspectorKitViews.caption("")
    private let fastExportToggle = InspectorToggleControl("Fast export (collapse still frames)")
    private let shareToggle = InspectorToggleControl("Share link after export")
    private let commentsToggle = InspectorToggleControl("Allow viewer comments on the share page")
    private let shareStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let shareProgress = CCProgressBar()
    private let shareCopyButton = InspectorButton("Copy")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let cancelButton = InspectorButton("Cancel")
    private let exportButton = InspectorButton("Export")

    // Exporting state
    private let formStack = NSStackView()
    private let exportingStack = NSStackView()
    private let exportProgressBar = CCProgressBar()
    private let exportPercentLabel = NSTextField(labelWithString: "0%")
    private let exportingTitle = NSTextField(labelWithString: "Exporting…")
    private let customSizeXLabel = NSTextField(labelWithString: "×")

    init(appState: AppState, project: Project) {
        self.appState = appState
        self.project = project
        self.exportSettings = project.settings.exportSettings
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The sheet is a CCDialog (header / scrollable content / footer) — no
    /// stock `presentAsSheet` chrome.
    private let dialog = CCDialog(title: "Export Video", width: 430)

    override func loadView() {
        view = dialog.card
        buildForm()
        buildExportingState()
        applySettingsToControls()
        observeShareState()
        // The sheet is short-lived, but an OPEN one must still follow a theme
        // flip — re-apply every label color read from EditorThemeKit at build.
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    private func applyTheme() {
        customSizeXLabel.textColor = EditorThemeKit.textSecondary
        shareStatusLabel.textColor = EditorThemeKit.textSecondary
        errorLabel.textColor = .systemRed
        exportingTitle.textColor = EditorThemeKit.textPrimary
        exportPercentLabel.textColor = EditorThemeKit.textSecondary
    }

    func present(over window: NSWindow) {
        loadViewIfNeeded()
        dialog.onEscape = { [weak self] in self?.dismissSheet() }
        dialog.setMaxContentHeight(440)
        dialog.present(over: window)
    }

    func dismissDialog() {
        dialog.dismiss()
    }

    deinit {
        progressTimer?.invalidate()
    }

    // MARK: - Form

    private func buildForm() {
        formStack.orientation = .vertical
        formStack.alignment = .leading
        formStack.spacing = 12
        formStack.translatesAutoresizingMaskIntoConstraints = false
        dialog.addContent(formStack)

        // Image (PNG) | Video (MP4) — still captures in Image treatment only.
        // With no timed effects the still IS an image, so PNG is the default;
        // any motion (zoom, curtain, …) defaults the sheet back to video.
        if project.isImageCapture, project.stillTreatment == .image {
            outputKind = project.hasTimedEffects ? .video : .image
            outputKindChips.items = ["Image (PNG)", "Video (MP4)"]
            outputKindChips.onSelect = { [weak self] index in
                self?.outputKind = index == 0 ? .image : .video
                self?.applyOutputKindVisibility()
            }
            let row = InspectorKitViews.row("Type", control: outputKindChips)
            outputKindRow = row
            formStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: formStack.widthAnchor).isActive = true
        }

        // Format
        formatMenu.items = ExportSettings.Format.allCases.map { .init(title: $0.rawValue) }
        formatMenu.onSelect = { [weak self] index in
            self?.exportSettings.format = ExportSettings.Format.allCases[index]
        }
        formatRow = addRow("Format", control: formatMenu)

        // Resolution
        resolutionMenu.items = ExportSettings.Resolution.allCases.map { .init(title: $0.rawValue) }
        resolutionMenu.onSelect = { [weak self] index in
            guard let self else { return }
            self.exportSettings.resolution = ExportSettings.Resolution.allCases[index]
            self.dialog.animateContentChange {
                self.customSizeRow.isHidden = self.exportSettings.resolution != .custom
            }
            self.refreshBitrateCaption()
        }
        addRow("Resolution", control: resolutionMenu)

        // Custom size row
        customSizeXLabel.font = EditorThemeKit.label()
        customSizeXLabel.textColor = EditorThemeKit.textSecondary
        let sizeStack = NSStackView(views: [customWidthField, customSizeXLabel, customHeightField])
        sizeStack.orientation = .horizontal
        sizeStack.spacing = 6
        customSizeRow = InspectorKitViews.row("Size", control: sizeStack)
        formStack.addArrangedSubview(customSizeRow)
        customSizeRow.widthAnchor.constraint(equalTo: formStack.widthAnchor).isActive = true
        customWidthField.delegate = self
        customHeightField.delegate = self

        // FPS
        fpsMenu.items = [.init(title: "30 fps"), .init(title: "60 fps")]
        fpsMenu.onSelect = { [weak self] index in
            self?.exportSettings.fps = index == 0 ? 30 : 60
        }
        fpsRow = addRow("Frame Rate", control: fpsMenu)

        // Quality
        qualityRow.format = { String(format: "%.0f%%", $0 * 100) }
        qualityRow.onChange = { [weak self] value in
            self?.exportSettings.quality = value
            self?.refreshBitrateCaption()
        }
        qualityRow.translatesAutoresizingMaskIntoConstraints = false
        formStack.addArrangedSubview(qualityRow)
        qualityRow.widthAnchor.constraint(equalTo: formStack.widthAnchor).isActive = true
        formStack.addArrangedSubview(bitrateCaption)

        // Fast export: static spans become one long-duration frame (VFR).
        // Identical pixels, dramatically faster on mostly-still recordings.
        // Off = classic constant-frame-rate for editors that dislike VFR.
        fastExportToggle.onChange = { [weak self] on in
            self?.exportSettings.collapseStaticSpans = on
        }
        fastExportToggle.translatesAutoresizingMaskIntoConstraints = false
        formStack.addArrangedSubview(fastExportToggle)
        fastExportToggle.widthAnchor.constraint(equalTo: formStack.widthAnchor).isActive = true

        // Share toggle + status
        shareToggle.onChange = { [weak self] on in
            guard let self else { return }
            self.shareAfterExport = on
            // The comments row glides open/closed and the dialog re-fits,
            // landing on the house bounce — never a snap or a stale height.
            self.dialog.animateContentChange {
                self.commentsToggle.isHidden = !on
            }
        }
        shareToggle.translatesAutoresizingMaskIntoConstraints = false
        formStack.addArrangedSubview(shareToggle)
        shareToggle.widthAnchor.constraint(equalTo: formStack.widthAnchor).isActive = true

        commentsToggle.onChange = { [weak self] on in
            self?.allowComments = on
        }
        commentsToggle.translatesAutoresizingMaskIntoConstraints = false
        formStack.addArrangedSubview(commentsToggle)
        commentsToggle.widthAnchor.constraint(equalTo: formStack.widthAnchor).isActive = true

        shareProgress.minValue = 0
        shareProgress.maxValue = 1
        shareProgress.translatesAutoresizingMaskIntoConstraints = false
        shareStatusLabel.font = EditorThemeKit.caption()
        shareStatusLabel.textColor = EditorThemeKit.textSecondary
        shareCopyButton.onClick = { [weak self] in
            guard let self, case .done(let url) = self.appState.shareService.state else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url, forType: .string)
        }
        let shareRow = NSStackView(views: [shareStatusLabel, shareCopyButton])
        shareRow.orientation = .horizontal
        shareRow.spacing = 8
        formStack.addArrangedSubview(shareRow)
        shareRow.widthAnchor.constraint(equalTo: formStack.widthAnchor).isActive = true
        formStack.addArrangedSubview(shareProgress)
        shareProgress.widthAnchor.constraint(equalTo: formStack.widthAnchor).isActive = true
        shareRow.isHidden = true
        shareProgress.isHidden = true

        // Error
        errorLabel.font = EditorThemeKit.caption()
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        formStack.addArrangedSubview(errorLabel)
        errorLabel.widthAnchor.constraint(equalTo: formStack.widthAnchor).isActive = true

        // Footer buttons — pinned in the dialog footer, trailing.
        cancelButton.onClick = { [weak self] in self?.dismissSheet() }
        exportButton.onClick = { [weak self] in self?.beginExportFlow() }
        dialog.addFooter(cancelButton)
        dialog.addFooter(exportButton)
    }

    @discardableResult
    private func addRow(_ label: String, control: NSView) -> NSView {
        let row = InspectorKitViews.row(label, control: control)
        formStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: formStack.widthAnchor).isActive = true
        return row
    }

    /// PNG output has no format/fps/quality/share — the resolution rows stay
    /// (they size the rendered frame exactly as they size the video).
    private func applyOutputKindVisibility() {
        let isImage = outputKind == .image
        outputKindChips.selectedIndex = isImage ? 0 : 1
        dialog.setTitle(isImage ? "Export Image" : "Export Video")
        // One animated re-fit for the whole row set (no-ops pre-presentation).
        dialog.animateContentChange {
            self.formatRow?.isHidden = isImage
            self.fpsRow?.isHidden = isImage
            self.qualityRow.isHidden = isImage
            self.bitrateCaption.isHidden = isImage
            self.shareToggle.isHidden = isImage
            self.commentsToggle.isHidden = isImage || !self.shareAfterExport
        }
    }

    private func applySettingsToControls() {
        formatMenu.selectedIndex = ExportSettings.Format.allCases.firstIndex(of: exportSettings.format) ?? 0
        resolutionMenu.selectedIndex = ExportSettings.Resolution.allCases.firstIndex(of: exportSettings.resolution) ?? 1
        fpsMenu.selectedIndex = exportSettings.fps == 30 ? 0 : 1
        customWidthField.stringValue = String(exportSettings.customWidth)
        customHeightField.stringValue = String(exportSettings.customHeight)
        customSizeRow.isHidden = exportSettings.resolution != .custom
        qualityRow.setValue(exportSettings.quality)
        shareToggle.isOn = shareAfterExport
        fastExportToggle.isOn = exportSettings.collapseStaticSpans
        commentsToggle.isOn = allowComments
        commentsToggle.isHidden = !shareAfterExport
        refreshBitrateCaption()
        applyOutputKindVisibility()
    }

    private func refreshBitrateCaption() {
        // The letterboxed preview canvas carries the resolved output aspect
        // (Auto = source aspect) — use it as the source-size stand-in so the
        // caption's WxH matches what the exporter will actually produce.
        bitrateCaption.stringValue = exportSettings.estimatedBitRateDescription(
            for: project.settings.aspectRatio,
            sourceSize: project.previewCanvasSize)
    }

    private func observeShareState() {
        shareObservation = SurfaceObservation { [weak self] in
            guard let self else { return }
            let state = self.appState.shareService.state
            self.renderShareState(state)
        }
    }

    private func renderShareState(_ state: ShareService.ShareState) {
        let shareRow = shareStatusLabel.superview as? NSStackView
        // Status rows appearing/disappearing re-fit the dialog on the house
        // growth motion, same as every other content change in this sheet.
        dialog.animateContentChange { self.applyShareState(state, to: shareRow) }
    }

    private func applyShareState(_ state: ShareService.ShareState, to shareRow: NSStackView?) {
        switch state {
        case .idle, .exporting:
            // .exporting is a ShareJobCenter-only phase; the sheet's own
            // ShareService never enters it.
            shareRow?.isHidden = true
            shareProgress.isHidden = true
        case .uploading(let progress):
            shareRow?.isHidden = false
            shareCopyButton.isHidden = true
            shareStatusLabel.stringValue = "Uploading to share..."
            shareProgress.isHidden = false
            shareProgress.doubleValue = progress
        case .completing:
            shareRow?.isHidden = false
            shareCopyButton.isHidden = true
            shareStatusLabel.stringValue = "Finalizing share link..."
            shareProgress.isHidden = true
        case .done(let url):
            shareRow?.isHidden = false
            shareCopyButton.isHidden = false
            shareStatusLabel.stringValue = url
            shareProgress.isHidden = true
            // The browser's "Shared" filter keys off this record.
            appState.library.markShared(project.id, url: url)
        case .failed(let message):
            shareRow?.isHidden = false
            shareCopyButton.isHidden = true
            shareStatusLabel.stringValue = "Share failed: \(message)"
            shareProgress.isHidden = true
        }
    }

    // MARK: - Exporting state

    private func buildExportingState() {
        exportingStack.orientation = .vertical
        exportingStack.alignment = .centerX
        exportingStack.spacing = 12
        exportingStack.translatesAutoresizingMaskIntoConstraints = false
        exportingStack.isHidden = true
        dialog.addContent(exportingStack)

        exportingTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        exportingTitle.textColor = EditorThemeKit.textPrimary
        exportingStack.addArrangedSubview(exportingTitle)

        exportProgressBar.minValue = 0
        exportProgressBar.maxValue = 1
        exportProgressBar.translatesAutoresizingMaskIntoConstraints = false
        exportProgressBar.widthAnchor.constraint(equalToConstant: 280).isActive = true
        exportingStack.addArrangedSubview(exportProgressBar)

        exportPercentLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        exportPercentLabel.textColor = EditorThemeKit.textSecondary
        exportingStack.addArrangedSubview(exportPercentLabel)
    }

    private func setExporting(_ exporting: Bool) {
        isExporting = exporting
        formStack.isHidden = exporting
        exportingStack.isHidden = !exporting
        exportButton.isEnabled = !exporting && !isCheckingAccess
        cancelButton.isEnabled = !exporting
        if exporting {
            progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let progress = self.exporter.progress
                    self.exportProgressBar.doubleValue = progress
                    self.exportPercentLabel.stringValue = "\(Int(progress * 100))%"
                }
            }
        } else {
            progressTimer?.invalidate()
            progressTimer = nil
        }
    }

    private func showError(_ message: String?) {
        errorLabel.stringValue = message ?? ""
        errorLabel.isHidden = message == nil
    }

    // MARK: - Export flow (mirrors ExportView)

    private func dismissSheet() {
        onDismiss?()
    }

    private func beginExportFlow() {
        commitCustomSizeFields()
        Task { await checkAccessAndMaybeExport() }
    }

    private func checkAccessAndMaybeExport() async {
        if let configError = appState.authService.configurationError {
            showError(configError)
            return
        }

        isCheckingAccess = true
        exportButton.isEnabled = false
        showError(nil)

        do {
            let access = try await appState.authService.evaluateExportAccess()
            isCheckingAccess = false
            exportButton.isEnabled = true

            switch access {
            case .allowed:
                startExport()
            case .needsSignIn:
                shouldStartExportAfterSignIn = true
                presentAuthGate()
            default:
                showError(appState.authService.exportAccessMessage(for: access))
            }
        } catch {
            isCheckingAccess = false
            exportButton.isEnabled = true
            showError(error.localizedDescription)
        }
    }

    private var authGate: AuthGateSheetController?

    private func presentAuthGate() {
        let gate = AuthGateSheetController(appState: appState) { [weak self] in
            guard let self else { return }
            if self.shouldStartExportAfterSignIn {
                self.shouldStartExportAfterSignIn = false
                self.beginExportFlow()
            }
        }
        authGate = gate
        gate.onClosed = { [weak self] in self?.authGate = nil }
        if let window = view.window { gate.present(over: window) }
    }

    private func startExport() {
        if outputKind == .image {
            startImageExport()
            return
        }
        let panel = NSSavePanel()
        let (contentType, ext): (UTType, String) = switch exportSettings.format {
        case .mp4: (.mpeg4Movie, "mp4")
        case .mov: (.quickTimeMovie, "mov")
        case .gif: (.gif, "gif")
        }
        panel.allowedContentTypes = [contentType]
        panel.nameFieldStringValue = "\(project.name).\(ext)"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        setExporting(true)
        showError(nil)
        project.settings.exportSettings = exportSettings

        // Same threading contract as the SwiftUI sheet: the export loop's
        // internal semaphore must never block the main thread.
        let capturedProject = project
        let capturedURL = url
        // Auto-sync: a signed-in user with the setting on uploads every
        // export, even without ticking Share. Signed out → local only (the
        // background job cannot auth-gate).
        let capturedShare = shareAfterExport || (appState.autoSyncExports && appState.isSignedIn)
        let capturedAllowComments = allowComments
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { [exporter] in
                    try await exporter.export(project: capturedProject, to: capturedURL)
                }.value

                setExporting(false)
                if capturedShare {
                    // Background job: the sheet closes immediately; progress
                    // lives on the project's card in the browser and on the
                    // web dashboard (mirrored through the ShareJobs DO).
                    appState.shareJobCenter.start(
                        projectID: capturedProject.id,
                        projectName: capturedProject.name,
                        fileURL: capturedURL,
                        durationSeconds: capturedProject.duration,
                        commentsEnabled: capturedAllowComments,
                        annotationMarkers: Self.annotationMarkers(for: capturedProject),
                        transcript: ShareIntelligence.transcriptPayload(for: capturedProject)
                    )
                }
                dismissSheet()
                NSWorkspace.shared.selectFile(capturedURL.path, inFileViewerRootedAtPath: "")
            } catch {
                setExporting(false)
                showError(error.localizedDescription)
            }
        }
    }

    /// PNG path — one composed frame through the real exporter (see
    /// StillImageExporter for why there is no separate still renderer).
    private func startImageExport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(project.name).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        setExporting(true)
        showError(nil)
        project.settings.exportSettings = exportSettings

        let capturedProject = project
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { [exporter] in
                    try await StillImageExporter.exportPNG(
                        project: capturedProject, to: url, exporter: exporter)
                }.value
                setExporting(false)
                dismissSheet()
                NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
            } catch {
                setExporting(false)
                showError(error.localizedDescription)
            }
        }
    }

    /// The project's annotations as share-page markers, in OUTPUT-time
    /// seconds. Built on the identical SpeedTimeMap the exporter uses
    /// (trim range + speed regions), so a marker points at the same frame in
    /// the uploaded file that the annotation covered in the editor.
    static func annotationMarkers(for project: Project) -> [[String: Any]] {
        let trimStart = project.effectiveTrimStart
        let trimEnd = max(trimStart, project.effectiveTrimEnd)
        guard trimEnd > trimStart else { return [] }
        let map = SpeedTimeMap(
            sourceStart: trimStart,
            sourceEnd: trimEnd,
            regions: project.speedRegions
        )
        return project.annotations
            .filter { $0.endTime > trimStart && $0.startTime < trimEnd }
            .sorted { $0.startTime < $1.startTime }
            .map { a in
                var marker: [String: Any] = [
                    "start": map.outputTime(forSource: max(a.startTime, trimStart)),
                    "end": map.outputTime(forSource: min(a.endTime, trimEnd)),
                ]
                let label = a.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !label.isEmpty, a.type == .text || a.type == .callout {
                    marker["label"] = String(label.prefix(120))
                }
                return marker
            }
    }

    private func commitCustomSizeFields() {
        if let width = Int(customWidthField.stringValue), width > 0 {
            exportSettings.customWidth = width
        }
        if let height = Int(customHeightField.stringValue), height > 0 {
            exportSettings.customHeight = height
        }
    }
}

extension ExportSheetController: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        commitCustomSizeFields()
    }
}

// MARK: - Auth gate sheet

/// Native port of AuthGateView — sign-in required panel with a single Sign In
/// button, working state, and error reporting.
@MainActor
final class AuthGateSheetController: NSViewController {
    private let appState: AppState
    private let onSignedIn: () -> Void
    var onClosed: (() -> Void)?

    /// CCDialog anatomy — header carries the title and explainer, footer the
    /// actions. No stock sheet chrome.
    private let dialog = CCDialog(
        title: "Sign In Required",
        subtitle: "Export is available to paid users and approved testers. Sign in to continue.",
        width: 380
    )

    // One button. Which providers exist is decided by the chooser page that
    // `/api/desktop/authorize` serves, not by this sheet.
    private let signInButton = InspectorButton("Sign In")
    private let workingLabel = NSTextField(labelWithString: "Signing in...")
    private let spinner = CCSpinner()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var themeObservation: CCThemeObservation?

    func present(over window: NSWindow) {
        loadViewIfNeeded()
        dialog.onEscape = { [weak self] in self?.closeGate() }
        dialog.present(over: window)
    }

    private func closeGate() {
        dialog.dismiss { [weak self] in self?.onClosed?() }
    }

    init(appState: AppState, onSignedIn: @escaping () -> Void) {
        self.appState = appState
        self.onSignedIn = onSignedIn
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        view = dialog.card

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        dialog.addContent(stack)

        if let configError = appState.authService.configurationError {
            let configLabel = NSTextField(wrappingLabelWithString: configError)
            configLabel.font = EditorThemeKit.caption()
            configLabel.textColor = .systemRed
            stack.addArrangedSubview(configLabel)
            configLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let disabled = appState.authService.configurationError != nil
        signInButton.isEnabled = !disabled
        signInButton.onClick = { [weak self] in
            Task { await self?.signIn { try await self?.appState.signIn() } }
        }
        signInButton.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(signInButton)
        signInButton.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        spinner.isDisplayedWhenStopped = false
        workingLabel.font = EditorThemeKit.caption()
        workingLabel.textColor = EditorThemeKit.textSecondary
        let workingRow = NSStackView(views: [spinner, workingLabel])
        workingRow.orientation = .horizontal
        workingRow.spacing = 8
        workingRow.isHidden = true
        stack.addArrangedSubview(workingRow)

        errorLabel.font = EditorThemeKit.caption()
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        stack.addArrangedSubview(errorLabel)
        errorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let cancel = InspectorButton("Cancel")
        cancel.onClick = { [weak self] in self?.closeGate() }
        dialog.addFooter(cancel)

        themeObservation = CCThemeObservation { [weak self] in
            self?.workingLabel.textColor = EditorThemeKit.textSecondary
        }
    }

    private func signIn(_ action: @escaping () async throws -> Void) async {
        setWorking(true)
        do {
            try await action()
            setWorking(false)
            closeGate()
            onSignedIn()
        } catch {
            setWorking(false)
            if AuthService.isUserCancellation(error) { return }
            errorLabel.stringValue = error.localizedDescription
            errorLabel.isHidden = false
        }
    }

    private func setWorking(_ working: Bool) {
        signInButton.isEnabled = !working
        (workingLabel.superview as? NSStackView)?.isHidden = !working
        if working { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }
}
