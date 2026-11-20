import AppKit
import AVFoundation
import CoreGraphics
import ScreenCaptureKit
import os

/// Phase-6 of the AppKit conversion: the floating recording panel's content is
/// native AppKit instead of a hosted SwiftUI view. Flip to false to fall back
/// to `RecordingControlsView` — both implementations remain in the tree and
/// drive the identical `AppState` calls.
let useAppKitRecordingSurfaces = true

private let panelLogger = Logger(subsystem: "so.capturecat.CaptureCat", category: "RecordingPanelAppKit")

/// Native recording toolbar. A 1:1 port of `RecordingControlsView`: the same
/// source tabs, the same inline pickers, the same device/microphone menus, the
/// same mid-recording source switching, and the same camera-bubble / device
/// monitor side panels. Every action calls the same `AppState` method the
/// SwiftUI view called; nothing about pause/resume bookkeeping moved.
@MainActor
final class RecordingPanelViewController: NSViewController {
    typealias SourceTab = RecordingSourceTab

    private let appState: AppState

    // MARK: - Mirrored @State

    private var sourceTab: SourceTab = .display
    private var availableDisplays: [SCDisplay] = []
    private var availableWindows: [SCWindow] = []
    private var selectedDisplayID: CGDirectDisplayID?
    private var selectedWindowID: CGWindowID?
    private var areaDisplayID: CGDirectDisplayID?
    private var selectedAreaRect: CGRect?
    private var availableCaptureDevices: [AVCaptureDevice] = []
    private var selectedCaptureDeviceUID: String?
    private var isLoadingSources = false
    private var isSelectingArea = false
    private var errorMessage: String?

    // MARK: - Side panels

    private let cameraFloatPreview = CameraFloatPreviewController()
    private var deviceMonitorPanel: NSPanel?
    /// What the open monitor shows ("cable" / "wifi:<id>") — a mid-take
    /// switch between the two rebuilds it.
    private var deviceMonitorSource: String?
    /// Last Wi-Fi phone list seen by the observation pass.
    private var lastWirelessEntries: [WirelessDeviceListing.Entry] = []
    private var notificationObservers: [NSObjectProtocol] = []

    // MARK: - Change tracking (stands in for SwiftUI `.onChange`)

    private var lastPhase: RecordingPhase = .idle
    private var lastCameraEnabled = false
    private var lastCameraDeviceID: String?
    private var observation: SurfaceObservation?
    private var themeObservation: CCThemeObservation?
    /// Floating non-activating panels can drop ordinary tracking-area events.
    /// Poll the window-server cursor location while this controller is visible,
    /// as the menu and combobox surfaces do, so the shared hover wash remains
    /// reliable across the whole recording bar.
    private var toolbarHoverPoller: CCHoverPoller?
    private var toolbarGlide: CCGlideHighlight?
    private var glideChips: [RecordingGlassChip] = []
    private weak var hoveredGlideChip: RecordingGlassChip?
    private var isStarted = false

    // MARK: - Views

    // Glass on 26+, vibrancy capsule on 14–15 — see GlassCompatView.
    private let shell = GlassCompatView()
    private let shellBody = NSView()
    private let stack = NSStackView()

    private var tabChips: [SourceTab: RecordingTabChip] = [:]
    private let tabsStack = NSStackView()
    /// One persistent selection pill + hover backdrop that glide between the
    /// source tabs instead of per-chip tint flips.
    private let tabsPill = SegmentPillOverlay()
    private let modeSwitch = RecordingModeSwitch()
    private let modeSeparator = RecordingSeparator()
    // Primary actions: raised keys, smaller than the row (no oversize squares).
    private let shotChip = RecordingIconChip(
        symbol: "camera.fill", color: .white, fill: CCTheme.color.primary,
        keySize: RecordingPanelMetrics.keySize, glyphSize: 16
    )
    private let urlChip = RecordingURLFieldChip(width: 320)
    /// Desktop / Tablet / Mobile layout for URL captures — visible only on the
    /// URL tab, next to the address field it modifies.
    private let webDeviceChip = RecordingMenuFieldChip(symbol: "desktopcomputer", title: String(localized: "Desktop", comment: "Recording panel URL tab: initial label of the web layout picker (desktop-width page)"), width: 128)
    /// Options popover trigger for URL captures (height/dark/hide/delay).
    private let webOptionsChip = RecordingIconChip(symbol: "gearshape")
    private var webOptionsPopover: CaptureCatPopover?
    private var isCapturingURL = false
    /// Failure of the LAST URL capture, shown inline on the field (red
    /// hairline + tooltip) — deliberately not routed through `errorMessage`,
    /// whose warning triangle means "source loading broke, click to retry".
    private var urlErrorMessage: String?
    private let displayChip = RecordingMenuFieldChip(symbol: "display", title: String(localized: "Choose Display", comment: "Recording panel: placeholder on the display picker before one is chosen"), width: 200)
    private let windowChip = RecordingMenuFieldChip(symbol: "macwindow", title: String(localized: "Choose Window", comment: "Recording panel: placeholder on the window picker before one is chosen"), width: 200)
    private let areaDisplayChip = RecordingMenuFieldChip(symbol: "display", title: String(localized: "Choose Display", comment: "Recording panel: placeholder on the display picker before one is chosen"), width: 168)
    private let areaPickChip = RecordingLabelChip(title: String(localized: "Select Area", comment: "Recording panel Area tab: button (verb) to drag out a screen region"), symbol: "rectangle.dashed", minWidth: 116)
    private let areaStack = NSStackView()
    private let deviceChip = RecordingMenuFieldChip(symbol: "iphone", title: String(localized: "Choose Device", comment: "Recording panel iPhone tab: placeholder on the device picker before one is chosen"), width: 200)
    private let separator = RecordingSeparator()
    private let devicesChip = RecordingMenuFieldChip(symbol: "slider.horizontal.3", title: String(localized: "Mic · No Cam", comment: "Recording panel: initial summary on the mic/camera chip (microphone on, no camera)"), width: 164)
    private let audioChip = RecordingLabelChip(title: String(localized: "Audio On", comment: "Recording panel: toggle chip, system audio is being captured"), symbol: "speaker.wave.2.fill", minWidth: 108)
    // One gear menu holds the recording-behaviour options (countdown,
    // duration limit, shortcut capture) — one gear instead of a chip per option.
    private let settingsChip = RecordingIconMenuChip(symbol: "gearshape")
    private var limitPopover: CaptureCatPopover?
    private let spinnerChip = RecordingSpinnerChip()
    private let warningChip = RecordingIconChip(symbol: "exclamationmark.triangle.fill", color: .systemYellow)
    private let recordChip = RecordingIconChip(
        symbol: "record.circle", color: .white, fill: NSColor.systemRed,
        keySize: RecordingPanelMetrics.keySize, glyphSize: 18
    )
    private let closeChip = RecordingIconChip(symbol: "xmark", color: .secondaryLabelColor)

    private let timerChip = RecordingTimerChip()
    private let sourceChip = RecordingSourceChip()
    private let pauseChip = RecordingIconChip(symbol: "pause.fill")
    private let switchChip = RecordingIconMenuChip(symbol: "arrow.triangle.2.circlepath")
    private let restartChip = RecordingIconChip(symbol: "arrow.counterclockwise")
    private let stopChip = RecordingIconChip(
        symbol: "stop.fill", color: .white, fill: NSColor.systemRed,
        keySize: RecordingPanelMetrics.stopKeySize, glyphSize: 13
    )
    private let deleteChip = RecordingIconChip(symbol: "trash.fill", color: .systemRed)

    // Quiet close sits far left INSIDE the bar.
    private var setupViews: [NSView] { [closeChip, modeSwitch, modeSeparator, tabsStack, urlChip, webDeviceChip, webOptionsChip, displayChip, windowChip, areaStack, deviceChip, separator, devicesChip, audioChip, settingsChip, spinnerChip, warningChip, recordChip, shotChip] }
    private var recordingViews: [NSView] { [timerChip, sourceChip, pauseChip, switchChip, restartChip, stopChip, deleteChip] }

    // MARK: - Init

    init(appState: AppState) {
        self.appState = appState
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Build

    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: RecordingPanelMetrics.setupPanelSize()))
        root.autoresizingMask = [.width, .height]
        view = root
        buildShell()
        wireActions()
    }

    private func buildShell() {
        shell.translatesAutoresizingMaskIntoConstraints = false
        // The 2026 floating card — the menus' and popovers' surface: popover
        // tint with a whisper of top light and the material's 0.5pt hairline.
        // Opaque fills are dressed raised by GlassCompatView with the cast
        // shadow suppressed; the panel window's own shadow supplies the depth.
        //
        // Re-read from RecordingPanelMetrics on every theme flip. GlassCompatView's
        // own applyTheme only re-assigns the color it was ALREADY holding, and the
        // kit's palette is concrete sRGB (not dynamic NSColor), so that
        // self-assignment re-writes the same frozen ink — the bar kept its dark
        // fill in light mode while its chips re-inked around it. Fires once now,
        // so this is also the initial paint.
        themeObservation = CCThemeObservation { [weak self] in
            guard let self else { return }
            self.shell.fillColor = RecordingPanelMetrics.barFill
            self.shell.strokeColor = nil
        }
        shell.contentView = shellBody
        view.addSubview(shell)
        // `.fixedSize(horizontal: true, vertical: false).padding(8).glassEffect(…)`
        // — the HStack's height is its tallest child (42), so the capsule is
        // 42 + 2×8 tall and sits centred in the panel, not stretched to it.
        NSLayoutConstraint.activate([
            shell.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            shell.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            // Never let the toolbar spill past the panel: the wide chips are
            // 999-priority, so they shrink first and the record/close buttons
            // stay reachable.
            shell.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor),
        ])

        tabsStack.orientation = .horizontal
        tabsStack.spacing = RecordingPanelMetrics.controlSpacing
        tabsStack.alignment = .centerY
        for tab in SourceTab.allCases {
            let chip = RecordingTabChip(title: tab.displayName, symbol: tab.icon)
            chip.usesExternalSelection = true
            chip.onClick = { [weak self] in self?.select(tab: tab) }
            chip.onHoverChange = { [weak self, weak chip] inside in
                guard let self, let chip else { return }
                let frame = inside ? self.tabsStack.convert(chip.bounds, from: chip) : nil
                if CCHoverPoller.debug {
                    NSLog("REC-HOVER tab=%@ inside=%d frame=%@",
                          tab.rawValue, inside ? 1 : 0,
                          frame.map(NSStringFromRect) ?? "nil")
                }
                self.tabsPill.setHover(frame: frame)
            }
            tabChips[tab] = chip
            tabsStack.addArrangedSubview(chip)
        }
        // Non-arranged and BELOW the chips: the selection is an opaque
        // floating chip that the tab glyphs sit on.
        tabsStack.addSubview(tabsPill, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            tabsPill.leadingAnchor.constraint(equalTo: tabsStack.leadingAnchor),
            tabsPill.trailingAnchor.constraint(equalTo: tabsStack.trailingAnchor),
            tabsPill.topAnchor.constraint(equalTo: tabsStack.topAnchor),
            tabsPill.bottomAnchor.constraint(equalTo: tabsStack.bottomAnchor),
        ])

        urlChip.onSubmit = { [weak self] raw in self?.captureWebPage(raw) }

        modeSwitch.onChange = { [weak self] mode in self?.applyModeChange(to: mode) }
        shotChip.onClick = { [weak self] in self?.captureStill() }

        areaStack.orientation = .horizontal
        areaStack.spacing = RecordingPanelMetrics.controlSpacing
        areaStack.alignment = .centerY
        areaStack.addArrangedSubview(areaDisplayChip)
        areaStack.addArrangedSubview(areaPickChip)

        stack.orientation = .horizontal
        stack.spacing = RecordingPanelMetrics.controlSpacing
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.wantsLayer = true // section-morph slide animates the layer
        for chip in setupViews + recordingViews {
            stack.addArrangedSubview(chip)
        }
        // Gliding hover wash for the non-tab chips — the tab groups already
        // glide via their segment pill; this gives the rest of the bar the
        // same feel as the editor toolbar and menus.
        toolbarGlide = CCGlideHighlight(host: stack, radius: .lg)
        // Some controls live inside a nested row (the Area picker), so this
        // deliberately walks the whole toolbar rather than only its direct
        // arranged subviews. Source/mode tabs retain their own segmented
        // hover treatment; every other chip shares this one bar-wide wash.
        glideChips = recordingGlassChips(in: stack).filter { !($0 is RecordingTabChip) }

        shellBody.addSubview(stack)
        let padding = RecordingPanelMetrics.shellPadding
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: shellBody.leadingAnchor, constant: padding),
            stack.trailingAnchor.constraint(equalTo: shellBody.trailingAnchor, constant: -padding),
            stack.topAnchor.constraint(equalTo: shellBody.topAnchor, constant: padding),
            stack.bottomAnchor.constraint(equalTo: shellBody.bottomAnchor, constant: -padding),
        ])
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        shell.cornerRadius = min(RecordingPanelMetrics.barRadius, shell.bounds.height / 2)
        // Layout-time resync only — user-driven moves animate in select(tab:).
        // Force the tab strip current first: viewDidLayout can run before the
        // stack has positioned its chips.
        tabsStack.layoutSubtreeIfNeeded()
        if let chip = tabChips[sourceTab] {
            tabsPill.syncIfNeeded(frame: tabsStack.convert(chip.bounds, from: chip))
        }
    }

    // MARK: - Action wiring
    //
    // Every closure below is the SwiftUI button body, verbatim.

    private func wireActions() {
        displayChip.optionsProvider = { [weak self] in self?.displayOptions() ?? .init(options: [], onSelect: { _ in }) }
        windowChip.optionsProvider = { [weak self] in self?.windowOptions() ?? .init(options: [], onSelect: { _ in }) }
        areaDisplayChip.optionsProvider = { [weak self] in self?.areaDisplayOptions() ?? .init(options: [], onSelect: { _ in }) }
        deviceChip.optionsProvider = { [weak self] in self?.deviceCaptureOptions() ?? .init(options: [], onSelect: { _ in }) }
        devicesChip.menuProvider = { [weak self] in self?.devicesMenu() ?? NSMenu() }
        switchChip.menuProvider = { [weak self] in self?.switchSourceMenu() ?? NSMenu() }
        settingsChip.menuProvider = { [weak self] in self?.recordingSettingsMenu() ?? NSMenu() }
        settingsChip.toolTip = String(localized: "Recording options: countdown, duration limit, shortcut capture.", comment: "Recording panel: tooltip on the gear button")
        webDeviceChip.menuProvider = { [weak self] in self?.webDeviceMenu() ?? NSMenu() }
        webOptionsChip.onClick = { [weak self] in self?.presentWebOptionsPopover() }
        webOptionsChip.toolTip = String(localized: "Web capture options: height, dark mode, hidden widgets, delay.", comment: "Recording panel URL tab: tooltip on the gear button")

        areaPickChip.onClick = { [weak self] in self?.pickArea() }
        audioChip.onClick = { [weak self] in
            guard let self else { return }
            self.appState.captureSystemAudio.toggle()
            self.refresh()
        }
        warningChip.onClick = { [weak self] in
            guard let self else { return }
            Task { await self.loadSources(forceProbe: true) }
        }
        warningChip.toolTip = String(localized: "Retry source loading.", comment: "Recording panel: tooltip on the warning button shown when displays/windows failed to load")
        recordChip.onClick = { [weak self] in self?.startRecording() }
        closeChip.onClick = { [weak self] in self?.appState.closeRecordingToolbar() }

        pauseChip.onClick = { [weak self] in
            guard let self else { return }
            if self.appState.recordingSession.isPaused {
                self.appState.recordingSession.resume()
            } else {
                self.appState.recordingSession.pause()
            }
        }
        switchChip.toolTip = String(localized: "Switch source — keeps recording, segments are joined on stop", comment: "Recording panel while recording: tooltip on the switch-source button")
        restartChip.onClick = { [weak self] in self?.confirmRestartRecording() }
        stopChip.onClick = { [weak self] in
            guard let self else { return }
            self.hideCameraPreview()
            self.appState.stopRecordingInProgress()
        }
        deleteChip.onClick = { [weak self] in self?.confirmDeleteRecording() }
    }

    // MARK: - Lifecycle (SwiftUI `.onAppear` / `.onDisappear`)

    /// `.onAppear` — primes devices, loads sources, sizes the panel and brings
    /// the camera bubble up, then starts observing AppState.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        loadViewIfNeeded()

        lastPhase = appState.recordingSession.phase
        lastCameraEnabled = appState.recordingSession.isCameraEnabled
        lastCameraDeviceID = appState.selectedCameraDeviceID

        installNotificationObservers()

        primeDefaultDevices()
        if availableDisplays.isEmpty {
            Task { await loadSources() }
        }
        syncPanelSize()
        handleCameraPreviewState()
        refresh()

        // `NSTrackingArea` enter/exit events are not dependable across all
        // regions of a borderless `.nonactivatingPanel`; a 30 Hz cursor poll
        // is the same reliable mechanism used by the app's popup menus.
        toolbarHoverPoller = CCHoverPoller { [weak self] in
            self?.routeToolbarHover(screenPoint: NSEvent.mouseLocation)
        }

        observation = SurfaceObservation { [weak self] in
            self?.observeAppState()
        }
        // iPhone over Wi-Fi: relist the account's phones while the bar is up.
        WirelessDeviceHub.shared.panelDidOpen()
    }

    /// `.onDisappear` — tears the side panels down and releases the camera
    /// when no take is in flight. Called by FloatingPanelController whenever
    /// the panel content is replaced or the panel closes.
    func teardown() {
        toolbarHoverPoller?.stop()
        toolbarHoverPoller = nil
        if let hoveredGlideChip {
            toolbarGlide?.update(row: hoveredGlideChip, active: false)
        }
        hoveredGlideChip = nil
        observation?.cancel()
        observation = nil
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers = []
        hideCameraPreview()
        hideDeviceMonitor()
        if !appState.recordingSession.isRecording && !appState.recordingSession.isPaused {
            appState.cameraManager.stop()
            // Nobody is left to see a "Tap Start Broadcast" prompt.
            WirelessDeviceHub.shared.cancelPending(message: nil)
        }
        WirelessDeviceHub.shared.panelDidClose()
    }

    /// Routes a single hover target for the flat, non-tab controls. A single
    /// target also preserves the highlight's previous frame while crossing a
    /// stack gap, allowing `CCGlideHighlight` to animate the move instead of
    /// treating each control as a fresh appearance.
    private func routeToolbarHover(screenPoint: NSPoint) {
        guard let window = view.window, window.isVisible else {
            clearToolbarHover()
            return
        }

        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let stackPoint = stack.convert(windowPoint, from: nil)
        let target = glideChips.first { chip in
            guard !chip.isHiddenOrHasHiddenAncestor,
                  chip.isEnabled,
                  chip.alphaValue > 0.01 else { return false }
            // Claim half the inter-chip gap. This avoids a fade/reappear when
            // the pointer moves directly from one control to its neighbour.
            return stack.convert(chip.bounds, from: chip)
                .insetBy(dx: 0, dy: -RecordingPanelMetrics.controlSpacing / 2)
                .contains(stackPoint)
        }

        guard target !== hoveredGlideChip else { return }
        if CCHoverPoller.debug {
            let oldName = hoveredGlideChip.map { String(describing: type(of: $0)) } ?? "none"
            let newName = target.map { String(describing: type(of: $0)) } ?? "none"
            let frame = target.map { stack.convert($0.bounds, from: $0) }
            NSLog("REC-HOVER controls old=%@ new=%@ cursor=(%.1f,%.1f) stack=(%.1f,%.1f) frame=%@ candidates=%d",
                  oldName, newName, screenPoint.x, screenPoint.y, stackPoint.x, stackPoint.y,
                  frame.map(NSStringFromRect) ?? "nil", glideChips.count)
        }
        if let hoveredGlideChip {
            toolbarGlide?.update(row: hoveredGlideChip, active: false)
        }
        hoveredGlideChip = target
        if let target {
            toolbarGlide?.update(row: target, active: true)
        }
    }

    private func clearToolbarHover() {
        guard let hoveredGlideChip else { return }
        toolbarGlide?.update(row: hoveredGlideChip, active: false)
        self.hoveredGlideChip = nil
    }

    private func recordingGlassChips(in root: NSView) -> [RecordingGlassChip] {
        var chips: [RecordingGlassChip] = []
        func visit(_ view: NSView) {
            if let chip = view as? RecordingGlassChip { chips.append(chip) }
            for child in view.subviews { visit(child) }
        }
        visit(root)
        return chips
    }

    private func installNotificationObservers() {
        let center = NotificationCenter.default
        notificationObservers.append(center.addObserver(
            forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.sourceTab == .device else { return }
                self.refreshCaptureDevices()
            }
        })
        notificationObservers.append(center.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.sourceTab == .device else { return }
                self.refreshCaptureDevices()
            }
        })
        notificationObservers.append(center.addObserver(
            forName: .cameraBubbleSizeChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.cameraFloatPreview.isVisible else { return }
                self.hideCameraPreview()
                self.showCameraPreview()
            }
        })
    }

    /// The `.onChange` block: phase, camera enable, and camera device changes
    /// drive exactly the same side effects the SwiftUI view drove.
    private func observeAppState() {
        // Read every tracked property up front so the observation re-arms on
        // all of them regardless of which branch runs.
        let phase = appState.recordingSession.phase
        let cameraEnabled = appState.recordingSession.isCameraEnabled
        let cameraDeviceID = appState.selectedCameraDeviceID
        _ = appState.recordingSession.elapsedTime
        _ = appState.recordingSession.isMicEnabled
        _ = appState.captureSystemAudio
        _ = appState.currentSourceLabel
        _ = appState.deviceRecorder.isRecording
        let wirelessRecording = appState.wirelessRecorder.isRecording
        let wireless = WirelessDeviceHub.shared
        let wirelessEntries = wireless.entries
        _ = wireless.pending
        _ = wireless.notice
        _ = appState.isSignedIn
        _ = wireless.signedInOverride
        _ = appState.recordingDurationLimit
        _ = appState.licence
        _ = appState.recordingCountdownSeconds
        _ = appState.webCaptureDevice
        _ = appState.webCaptureOptions

        if phase != lastPhase {
            lastPhase = phase
            performPhaseTransition()
            handleCameraPreviewState()
            handleDeviceMonitorState()
        }
        if cameraEnabled != lastCameraEnabled {
            lastCameraEnabled = cameraEnabled
            handleCameraPreviewState()
        }
        // A mid-take switch between a cabled and a Wi-Fi phone (or between
        // phones) changes what the monitor shows without a phase change.
        if (wirelessRecording || appState.deviceRecorder.isRecording) != (deviceMonitorPanel != nil)
            || (deviceMonitorPanel != nil && deviceMonitorSource != currentMonitorSource) {
            handleDeviceMonitorState()
        }
        if wirelessEntries != lastWirelessEntries {
            lastWirelessEntries = wirelessEntries
            reconcileDeviceSelection()
        }
        if cameraDeviceID != lastCameraDeviceID {
            lastCameraDeviceID = cameraDeviceID
            // Recreate the bubble — a device switch can change its shape
            // (circle for webcams, device-aspect rect for phone screens).
            hideCameraPreview()
            handleCameraPreviewState()
        }
        refresh()
    }

    // MARK: - Render

    private func refresh() {
        guard isViewLoaded else { return }
        let recordingActive = isRecordingActive

        for view in setupViews { view.isHidden = recordingActive }
        for view in recordingViews { view.isHidden = !recordingActive }
        // The stop button breathes while footage is actually being written —
        // solid while paused, gone when idle.
        stopChip.setPulsing(appState.recordingSession.isRecording)

        if recordingActive {
            renderRecordingToolbar()
        } else {
            renderSetupToolbar()
        }
        view.needsLayout = true
    }

    private func renderSetupToolbar() {
        for (tab, chip) in tabChips {
            chip.isSelected = tab == sourceTab
            chip.isEnabled = true
        }

        displayChip.isHidden = sourceTab != .display
        windowChip.isHidden = sourceTab != .window
        areaStack.isHidden = sourceTab != .area
        deviceChip.isHidden = sourceTab != .device
        urlChip.isHidden = sourceTab != .url
        webDeviceChip.isHidden = sourceTab != .url
        webDeviceChip.title = appState.webCaptureDevice.title
        webDeviceChip.symbolName = appState.webCaptureDevice.symbol
        webDeviceChip.toolTip = String(localized: "Capture the page in its \(appState.webCaptureDevice.title.lowercased()) layout.", comment: "Recording panel URL tab: tooltip on the layout picker; the value is the lowercased layout name (desktop, tablet, mobile)")
        webOptionsChip.isHidden = sourceTab != .url
        // The gear quietly signals when any option departs from the defaults.
        webOptionsChip.setIndicator(on: appState.webCaptureOptions != WebCaptureOptions())
        // URL capture has no Start button — Return in the field runs it — and
        // the device/audio chips are meaningless for a web page, so the row
        // collapses to just the tabs and the address field. That collapse is
        // what produces the slide: the stack animates its arranged subviews out
        // and the tabs glide left into the freed space.
        let urlMode = sourceTab == .url
        let shooting = modeSwitch.mode == .screenshot
        separator.isHidden = urlMode
        // A still has no sound and no camera overlay, so those chips would be
        // controls with nothing to control.
        devicesChip.isHidden = urlMode || shooting
        audioChip.isHidden = urlMode || shooting
        // The gear's options (countdown, duration limit, shortcut capture)
        // only mean something for a recording, so like the record button it
        // disappears for stills and URL captures.
        settingsChip.isHidden = urlMode || shooting
        // Quiet indicator when any option departs from the defaults.
        settingsChip.setIndicator(
            on: appState.recordingDurationLimit > 0
                || appState.recordingCountdownSeconds != 3
                || appState.recordingSession.isShortcutCaptureEnabled
        )
        // URL capture runs from Return in the field; screenshot swaps the red
        // record button for a shutter.
        recordChip.isHidden = urlMode || shooting
        shotChip.isHidden = urlMode || !shooting
        shotChip.isEnabled = canStart
        modeSwitch.isHidden = false
        modeSeparator.isHidden = false

        displayChip.title = selectedDisplay.map(displayTitle) ?? String(localized: "Choose Display", comment: "Recording panel: placeholder on the display picker before one is chosen")
        windowChip.title = selectedWindow.map(windowTitle) ?? String(localized: "Choose Window", comment: "Recording panel: placeholder on the window picker before one is chosen")
        areaDisplayChip.title = areaDisplay.map(displayTitle) ?? String(localized: "Choose Display", comment: "Recording panel: placeholder on the display picker before one is chosen")
        areaPickChip.update(title: areaSelectionLabel, symbol: "rectangle.dashed")
        areaPickChip.isEnabled = areaDisplay != nil && !isSelectingArea
        deviceChip.setTitle(deviceChipTitle, animated: true)
        // Quiet inline failure ("Open CaptureCat on your iPhone to stream").
        deviceChip.setError(sourceTab == .device ? WirelessDeviceHub.shared.notice : nil,
                            fallbackToolTip: WirelessDeviceHub.shared.pending?.prompt)

        devicesChip.title = deviceSummaryTitle
        devicesChip.setIndicator(
            on: appState.recordingSession.isMicEnabled || appState.recordingSession.isCameraEnabled
        )
        audioChip.setIndicator(on: appState.captureSystemAudio)
        audioChip.update(
            title: appState.captureSystemAudio ? String(localized: "Audio On", comment: "Recording panel: toggle chip, system audio is being captured") : String(localized: "Audio Off", comment: "Recording panel: toggle chip, system audio is not captured"),
            symbol: appState.captureSystemAudio ? "speaker.wave.2.fill" : "speaker.slash.fill"
        )

        // The spinner does double duty: source loading, and a URL capture in
        // flight. While a page is being captured the whole URL row locks —
        // field, device, gear — so the in-flight state cannot be mutated
        // under the capture, and the spinner is the feedback that Return did
        // something at all.
        let urlBusy = isCapturingURL && sourceTab == .url
        urlChip.isEnabled = !urlBusy
        webDeviceChip.isEnabled = !urlBusy
        webOptionsChip.isEnabled = !urlBusy
        urlChip.setError(urlBusy ? nil : urlErrorMessage)
        // …and a third duty: waiting for an iPhone to start broadcasting.
        let wirelessWaiting = sourceTab == .device && WirelessDeviceHub.shared.pending != nil
        spinnerChip.isHidden = !(isLoadingSources || urlBusy || wirelessWaiting)
        spinnerChip.setSpinning(isLoadingSources || urlBusy || wirelessWaiting)
        warningChip.isHidden = isLoadingSources || errorMessage == nil
        warningChip.toolTip = String(localized: "Retry source loading. \(errorMessage ?? "")", comment: "Recording panel: tooltip on the warning button; the value is the error message")
        recordChip.isHidden = !canStart
    }

    private func renderRecordingToolbar() {
        let blocked = isPreparingPhase || isStoppingPhase
        // The limit the take actually runs to: the user's own, or Free's
        // 5-minute cap (PlanGate) — the session enforces this same value.
        let limit = appState.recordingSession.durationLimit ?? 0
        if limit > 0, !isPreparingPhase {
            // Count DOWN against the recorded-time cap. `elapsedTime` freezes
            // while paused, so the remaining figure freezes with it — the
            // limit spends recorded time, not wall time.
            let remaining = max(0, limit - appState.recordingSession.elapsedTime)
            timerChip.update(
                text: "-" + remaining.formattedTimecode,
                live: appState.recordingSession.isRecording,
                color: remaining <= 10 ? .systemRed : .labelColor,
                limitText: RecordingLimitLabel.label(forLimit: limit)
            )
        } else {
            timerChip.update(text: timerText, live: appState.recordingSession.isRecording)
        }
        let recordingDevice = appState.deviceRecorder.isRecording || appState.wirelessRecorder.isRecording
        if let pending = WirelessDeviceHub.shared.pending {
            // Still recording the current source while the phone is asked.
            sourceChip.update(label: pending.prompt, isDevice: true,
                              toolTip: String(localized: "\(pending.prompt) — recording \(appState.currentSourceLabel) until it starts", comment: "Recording panel tooltip while waiting for an iPhone; first value is the waiting prompt, second the source still being recorded"))
        } else if let notice = WirelessDeviceHub.shared.notice {
            sourceChip.update(label: notice, isDevice: recordingDevice, toolTip: notice)
        } else {
            sourceChip.update(label: appState.currentSourceLabel, isDevice: recordingDevice)
        }

        let paused = appState.recordingSession.isPaused
        pauseChip.setSymbol(paused ? "play.fill" : "pause.fill")
        pauseChip.toolTip = paused ? String(localized: "Resume Recording", comment: "Recording panel: tooltip on the pause/resume button") : String(localized: "Pause Recording", comment: "Recording panel: tooltip on the pause/resume button")
        for chip in [pauseChip, restartChip, stopChip, deleteChip] {
            chip.isEnabled = !blocked
        }
        switchChip.isEnabled = !blocked
    }

    // MARK: - Menus

    private func actionItem(_ title: String, state: NSControl.StateValue = .off, handler: @escaping () -> Void) -> NSMenuItem {
        let item = RecordingMenuAction(title: title, handler: handler)
        item.state = state
        return item
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func newMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        return menu
    }

    private func displayOptions() -> RecordingMenuChip.OptionList {
        let displays = availableDisplays
        return .init(
            options: displays.map { .init(title: displayTitle($0)) },
            selectedIndex: displays.firstIndex { $0.displayID == selectedDisplayID },
            emptyText: String(localized: "No displays found", comment: "Recording panel: display picker empty state"),
            onSelect: { [weak self] index in
                guard let self, displays.indices.contains(index) else { return }
                let display = displays[index]
                self.selectedDisplayID = display.displayID
                self.flashDisplay(display)
                self.refresh()
            }
        )
    }

    private func areaDisplayOptions() -> RecordingMenuChip.OptionList {
        let displays = availableDisplays
        return .init(
            options: displays.map { .init(title: displayTitle($0)) },
            selectedIndex: displays.firstIndex { $0.displayID == areaDisplayID },
            emptyText: String(localized: "No displays found", comment: "Recording panel: display picker empty state"),
            onSelect: { [weak self] index in
                guard let self, displays.indices.contains(index) else { return }
                let display = displays[index]
                self.areaDisplayID = display.displayID
                self.flashDisplay(display)
                self.refresh()
            }
        )
    }

    private func windowOptions() -> RecordingMenuChip.OptionList {
        // The list was loaded when the panel opened — apps launched since
        // would be missing. Refresh in the background so the NEXT open is
        // current even if this one is a beat stale.
        Task { await loadSources() }
        let windows = availableWindows
        return .init(
            options: windows.map { window in
                .init(
                    title: window.title?.isEmpty == false ? window.title! : String(localized: "Untitled", comment: "Recording panel: name for a window that has no title"),
                    subtitle: window.owningApplication?.applicationName
                )
            },
            selectedIndex: windows.firstIndex { $0.windowID == selectedWindowID },
            searchable: true,
            emptyText: String(localized: "No windows available", comment: "Recording panel: window picker empty state"),
            onSelect: { [weak self] index in
                guard let self, windows.indices.contains(index) else { return }
                let window = windows[index]
                self.selectedWindowID = window.windowID
                self.activateOwningApplication(for: window)
                self.flashDisplayForWindow(window)
                self.refresh()
            }
        )
    }

    private func deviceCaptureOptions() -> RecordingMenuChip.OptionList {
        // The old menu carried a "Refresh" row; the popup refreshes on every
        // open instead, so the list is current by the time it appears.
        refreshCaptureDevices()
        let devices = availableCaptureDevices
        // iPhones over Wi-Fi follow the cabled devices: streaming, then
        // "start on iPhone" (app open), then "not open" (push).
        let signedIn = wirelessRowsVisible
        let wireless = signedIn ? WirelessDeviceHub.shared.entries : []
        var options: [CCCombobox.Option] = devices.map { .init(title: $0.localizedName) }
        options += wireless.map { .init(title: $0.title, subtitle: $0.subtitle) }
        let selectedIndex = devices.firstIndex { $0.uniqueID == selectedCaptureDeviceUID }
            ?? wireless.firstIndex { Self.wirelessSelectionKey($0.key) == selectedCaptureDeviceUID }.map { $0 + devices.count }
        var actions: [RecordingMenuChip.OptionList.Action] = []
        if !signedIn {
            actions.append(.init(
                option: .init(title: String(localized: "Sign in to use your iPhone over Wi-Fi", comment: "Recording panel device picker: action row title"), subtitle: String(localized: "or connect it with a cable", comment: "Recording panel device picker: subtitle under ‘Sign in to use your iPhone over Wi-Fi’")),
                run: { NSApp.sendAction(#selector(StatusMenuActions.signIn(_:)), to: nil, from: nil) }
            ))
        } else if !wireless.isEmpty || WirelessDeviceHub.shared.cloudDevices.contains(where: { $0.platform == "ios" }) {
            // Only for an account that has an iPhone to forget.
            actions.append(.init(
                option: .init(title: String(localized: "Forget my devices…", comment: "Recording panel device picker: action row that unlinks all Wi-Fi devices")),
                run: { [weak self] in self?.confirmForgetDevices() }
            ))
        }
        return .init(
            options: options,
            selectedIndex: selectedIndex,
            emptyText: String(localized: "Connect an iPhone or iPad via USB, unlock it, and tap “Trust”.", comment: "Recording panel device picker empty state; “Trust” is the button on the iPhone’s trust prompt"),
            onSelect: { [weak self] index in
                guard let self else { return }
                if devices.indices.contains(index) {
                    WirelessDeviceHub.shared.cancelPending(message: nil)
                    self.selectedCaptureDeviceUID = devices[index].uniqueID
                    self.refresh()
                } else if wireless.indices.contains(index - devices.count) {
                    self.selectWireless(wireless[index - devices.count])
                }
            },
            actions: actions
        )
    }

    // MARK: - iPhone over Wi-Fi

    private static let wirelessPrefix = "wifi:"

    /// Signed in (or the harness says so): Wi-Fi rows instead of "Sign in…".
    private var wirelessRowsVisible: Bool {
        WirelessDeviceHub.shared.showsWirelessRows(appSignedIn: appState.isSignedIn)
    }

    static func wirelessSelectionKey(_ key: String) -> String { wirelessPrefix + WirelessIdentity.key(key) }

    /// The selected Wi-Fi phone's id, when the device pick is one.
    private var selectedWirelessKey: String? {
        guard let uid = selectedCaptureDeviceUID, uid.hasPrefix(Self.wirelessPrefix) else { return nil }
        return String(uid.dropFirst(Self.wirelessPrefix.count))
    }

    private var selectedWirelessEntry: WirelessDeviceListing.Entry? {
        guard let key = selectedWirelessKey else { return nil }
        return WirelessDeviceHub.shared.entries.first { $0.key == key }
    }

    private var deviceChipTitle: String {
        if let key = selectedWirelessKey {
            if let pending = WirelessDeviceHub.shared.pending, pending.key == key { return pending.prompt }
            return selectedWirelessEntry?.title ?? String(localized: "iPhone · Wi-Fi", comment: "Recording panel: device picker label for an iPhone connected over Wi-Fi")
        }
        return selectedCaptureDevice?.localizedName ?? String(localized: "Choose Device", comment: "Recording panel iPhone tab: placeholder on the device picker before one is chosen")
    }

    /// Pick a Wi-Fi phone. Streaming: ready to record. Otherwise ask it to
    /// broadcast (LAN control when its app is open, a notification when it
    /// isn't) and wait; on failure or timeout the previous pick comes back
    /// and the chip shows a quiet notice.
    private func selectWireless(_ entry: WirelessDeviceListing.Entry) {
        let previous = selectedCaptureDeviceUID
        let key = Self.wirelessSelectionKey(entry.key)
        selectedCaptureDeviceUID = key
        WirelessDeviceHub.shared.clearNotice()
        refresh()
        guard entry.availability != .streaming else { return }
        Task { [weak self] in
            let streaming = await WirelessDeviceHub.shared.requestBroadcast(entry.key)
            guard let self else { return }
            if !streaming, self.selectedCaptureDeviceUID == key, previous != key {
                self.selectedCaptureDeviceUID = previous
            }
            self.refresh()
        }
    }

    /// Keep the device pick valid as phones come and go: a vanished Wi-Fi
    /// phone falls back to the first cabled device or streaming phone.
    private func reconcileDeviceSelection() {
        let wireless = wirelessRowsVisible ? WirelessDeviceHub.shared.entries : []
        if let key = selectedWirelessKey {
            if wireless.contains(where: { $0.key == key }) { return }
            if WirelessDeviceHub.shared.pending?.key == key { return }
            selectedCaptureDeviceUID = nil
        }
        if selectedCaptureDeviceUID == nil || (selectedWirelessKey == nil && selectedCaptureDevice == nil) {
            selectedCaptureDeviceUID = availableCaptureDevices.first?.uniqueID
                ?? wireless.first { $0.availability == .streaming }.map { Self.wirelessSelectionKey($0.key) }
        }
    }

    /// "Forget my devices…": rotate the account's link key after a CCAlert
    /// confirmation. Every phone and Mac must refetch it to connect again.
    private func confirmForgetDevices() {
        guard let window = view.window else { return }
        let alert = CCAlert(
            title: String(localized: "Forget your devices?", comment: "Alert title: confirm unlinking all Wi-Fi devices"),
            message: String(localized: "Every iPhone and Mac on your account stops connecting over Wi-Fi until it fetches the new link. Ones still signed in do that on their own; sign a lost device out of your account to keep it out.", comment: "Alert message for ‘Forget your devices?’")
        )
        alert.addButton(String(localized: "Forget Devices", comment: "Alert button (destructive): unlink all Wi-Fi devices"), role: .destructive)
        alert.addButton(String(localized: "Cancel", comment: "Alert button: dismiss without doing anything"))
        alert.beginSheet(for: window) { index in
            guard index == 0 else { return }
            Task { @MainActor in
                do {
                    try await WirelessDeviceHub.shared.forgetDevices()
                } catch {
                    WirelessDeviceHub.shared.showNotice(String(localized: "Couldn't forget devices: \(error.localizedDescription)", comment: "Recording panel notice when unlinking devices fails; the value is the error"))
                }
            }
        }
    }

    private func devicesMenu() -> NSMenu {
        let menu = newMenu()

        menu.addItem(.sectionHeader(title: String(localized: "Microphone", comment: "Recording panel mic/camera menu: section header")))
        menu.addItem(actionItem(
            String(localized: "No Microphone", comment: "Recording panel mic/camera menu: item that turns the microphone off"),
            state: appState.recordingSession.isMicEnabled ? .off : .on
        ) { [weak self] in
            self?.appState.recordingSession.isMicEnabled = false
        })

        let microphones = appState.availableMicrophones
        if microphones.isEmpty {
            menu.addItem(disabledItem(String(localized: "No microphones found", comment: "Recording panel mic/camera menu: empty state")))
        } else {
            for microphone in microphones {
                let isSelected = appState.recordingSession.isMicEnabled
                    && microphone.uniqueID == appState.selectedMicrophoneDeviceID
                menu.addItem(actionItem(microphone.localizedName, state: isSelected ? .on : .off) { [weak self] in
                    guard let self else { return }
                    self.appState.selectedMicrophoneDeviceID = microphone.uniqueID
                    self.appState.recordingSession.isMicEnabled = true
                })
            }
        }

        menu.addItem(.separator())
        // Opens the system mic-mode picker — enabling "Voice Isolation" there
        // gives OS-level noise suppression for CaptureCat's mic capture.
        menu.addItem(actionItem(String(localized: "Voice Isolation & Mic Modes…", comment: "Recording panel mic/camera menu: opens the macOS microphone mode picker")) {
            AVCaptureDevice.showSystemUserInterface(.microphoneModes)
        })

        menu.addItem(.sectionHeader(title: String(localized: "Camera / iPhone Overlay", comment: "Recording panel mic/camera menu: section header for the camera bubble source")))
        menu.addItem(actionItem(
            String(localized: "No Overlay", comment: "Recording panel mic/camera menu: item that turns the camera overlay off"),
            state: appState.recordingSession.isCameraEnabled ? .off : .on
        ) { [weak self] in
            self?.appState.recordingSession.isCameraEnabled = false
        })

        let cameras = appState.cameraManager.availableDevices
        if cameras.isEmpty {
            menu.addItem(disabledItem(String(localized: "No cameras found", comment: "Recording panel mic/camera menu: empty state")))
        } else {
            for camera in cameras {
                let isSelected = appState.recordingSession.isCameraEnabled
                    && camera.uniqueID == appState.selectedCameraDeviceID
                menu.addItem(actionItem(camera.localizedName, state: isSelected ? .on : .off) { [weak self] in
                    guard let self else { return }
                    self.appState.selectedCameraDeviceID = camera.uniqueID
                    self.appState.recordingSession.isCameraEnabled = true
                })
            }
        }

        return menu
    }

    /// Gear menu: every recording-behaviour option in one
    /// place — toggles up top, stateful pickers as submenus, Settings… last.
    private func recordingSettingsMenu() -> NSMenu {
        let menu = newMenu()

        menu.addItem(actionItem(
            String(localized: "Capture Shortcuts (⌘⇧S overlay)", comment: "Recording panel gear menu: toggle that records keyboard shortcuts as an on-screen overlay"),
            state: appState.recordingSession.isShortcutCaptureEnabled ? .on : .off
        ) { [weak self] in
            guard let self else { return }
            let enabling = !self.appState.recordingSession.isShortcutCaptureEnabled
            self.appState.recordingSession.isShortcutCaptureEnabled = enabling
            if enabling, !KeystrokeTracker.hasPermission {
                KeystrokeTracker.requestPermission()
            }
            self.refresh()
        })

        menu.addItem(.separator())

        // Submenu titles carry the current value so the collapsed menu still
        // reads at a glance ("Recording Countdown — 3s").
        let countdownSeconds = appState.recordingCountdownSeconds
        let countdownItem = NSMenuItem(
            title: countdownSeconds > 0
                ? String(localized: "Recording Countdown — \(countdownSeconds)s", comment: "Recording panel gear menu: submenu title with current countdown, e.g. \"Recording Countdown — 3s\"; s = seconds")
                : String(localized: "Recording Countdown — Off", comment: "Recording panel gear menu: submenu title when no countdown is set"),
            action: nil, keyEquivalent: ""
        )
        countdownItem.submenu = countdownMenu()
        menu.addItem(countdownItem)

        let limit = PlanGate.effectiveLimit(userLimit: appState.recordingDurationLimit, licence: appState.licence) ?? 0
        let limitItem = NSMenuItem(
            title: limit > 0
                ? String(localized: "Duration Limit — \(RecordingLimitLabel.label(forLimit: limit))", comment: "Recording panel gear menu: submenu title with current limit, e.g. \"Duration Limit — 5 min\"")
                : String(localized: "Duration Limit — Off", comment: "Recording panel gear menu: submenu title when no duration limit is set"),
            action: nil, keyEquivalent: ""
        )
        limitItem.submenu = limitMenu()
        menu.addItem(limitItem)

        menu.addItem(.separator())
        menu.addItem(actionItem(String(localized: "Settings…", comment: "Recording panel gear menu: opens the app Settings window")) {
            NSApp.sendAction(#selector(StatusMenuActions.openSettings(_:)), to: nil, from: nil)
        })
        return menu
    }

    /// Mid-recording source switch — desktop → iPhone → another display …
    private func switchSourceMenu() -> NSMenu {
        let menu = newMenu()
        menu.addItem(.sectionHeader(title: String(localized: "Displays", comment: "Recording panel switch-source menu: section header")))
        for display in availableDisplays {
            menu.addItem(actionItem(displayTitle(display)) { [weak self] in
                self?.appState.switchRecordingSource(to: .display(display))
            })
        }
        menu.addItem(.sectionHeader(title: String(localized: "iPhone / iPad", comment: "Recording panel switch-source menu: section header")))
        let devices = DeviceRecorder.availableDevices
        let wireless = wirelessRowsVisible ? WirelessDeviceHub.shared.entries : []
        if devices.isEmpty && wireless.isEmpty {
            menu.addItem(disabledItem(String(localized: "No devices connected", comment: "Recording panel switch-source menu: empty state")))
        }
        for device in devices {
            menu.addItem(actionItem(device.localizedName) { [weak self] in
                self?.appState.switchRecordingSource(to: .iosDevice(device))
            })
        }
        // Wi-Fi phones: a streaming one switches now; an open or known one is
        // asked to broadcast first while the current source keeps recording.
        for entry in wireless {
            let title = entry.subtitle.map { "\(entry.title) — \($0)" } ?? entry.title
            menu.addItem(actionItem(title) { [weak self] in
                self?.appState.switchRecordingSource(to: .wirelessDevice(entry.key))
            })
        }
        return menu
    }

    // MARK: - Duration limit

    private static let limitPresets: [(title: String, seconds: TimeInterval)] = [
        (String(localized: "No Limit", comment: "Recording duration limit menu: no limit"), 0),
        (String(localized: "15s", comment: "Recording duration limit menu: 15 seconds"), 15),
        (String(localized: "30s", comment: "Recording duration limit menu: 30 seconds"), 30),
        (String(localized: "1 min", comment: "Recording duration limit menu: 1 minute"), 60),
        (String(localized: "2 min", comment: "Recording duration limit menu: 2 minutes"), 120),
        (String(localized: "5 min", comment: "Recording duration limit menu: 5 minutes"), 300),
        (String(localized: "10 min", comment: "Recording duration limit menu: 10 minutes"), 600),
    ]

    private func limitMenu() -> NSMenu {
        let menu = newMenu()
        let licence = appState.licence
        // What a take runs to — on Free, "No Limit" still stops at 5 min,
        // so that is what's ticked.
        let current = PlanGate.effectiveLimit(userLimit: appState.recordingDurationLimit, licence: licence) ?? 0
        for preset in Self.limitPresets {
            if PlanGate.isProOnlyLimit(preset.seconds, licence: licence) {
                menu.addItem(disabledItem(String(localized: "\(preset.title) — Pro", comment: "Recording duration limit menu: a disabled preset that needs the Pro plan; the value is the preset, e.g. \"No Limit\"")))
                continue
            }
            menu.addItem(actionItem(preset.title, state: current == preset.seconds ? .on : .off) { [weak self] in
                self?.setDurationLimit(preset.seconds)
            })
        }
        menu.addItem(.separator())
        let isCustom = current > 0 && !Self.limitPresets.contains { $0.seconds == current }
        let customTitle = isCustom
            ? String(localized: "Custom… (\(RecordingLimitLabel.label(forLimit: current)))", comment: "Recording duration limit menu: custom limit item showing the current custom value") : String(localized: "Custom…", comment: "Recording duration limit menu: opens a popover to type a custom limit")
        menu.addItem(actionItem(customTitle, state: isCustom ? .on : .off) { [weak self] in
            self?.presentCustomLimitPopover()
        })
        if !licence.allowsCommercialUse {
            menu.addItem(.separator())
            menu.addItem(disabledItem(String(localized: "Free records up to 5 min, for personal use", comment: "Recording duration limit menu: note explaining the Free plan limit")))
            menu.addItem(actionItem(String(localized: "See Plans…", comment: "Recording duration limit menu: opens the pricing page")) { NSWorkspace.shared.open(PlanGate.pricingURL) })
        }
        return menu
    }

    private func setDurationLimit(_ seconds: TimeInterval) {
        appState.setRecordingDurationLimit(seconds)
        refresh()
    }

    /// Small flat popover for a custom limit: value field + s/min selector.
    /// House style — EditorThemeKit surfaces, small rounded rects, no stock
    /// chrome, no capsules.
    private func presentCustomLimitPopover() {
        limitPopover?.close()
        let editor = CustomLimitEditorViewController(
            initialSeconds: appState.recordingDurationLimit
        ) { [weak self] seconds in
            self?.limitPopover?.close()
            self?.limitPopover = nil
            if let seconds { self?.setDurationLimit(seconds) }
        }
        let popover = CaptureCatPopover()
        popover.contentViewController = editor
        popover.show(relativeTo: settingsChip.bounds, of: settingsChip, preferredEdge: .maxY)
        limitPopover = popover
    }

    // MARK: - Web capture device

    private func webDeviceMenu() -> NSMenu {
        let menu = newMenu()
        let current = appState.webCaptureDevice
        for preset in WebDevicePreset.allCases {
            let title = String(localized: "\(preset.title) (\(Int(preset.viewportWidth))pt)", comment: "Recording panel web layout menu item: layout name and viewport width in points, e.g. \"Desktop (1440pt)\"; pt = points")
            menu.addItem(actionItem(title, state: current == preset ? .on : .off) { [weak self] in
                guard let self else { return }
                self.appState.webCaptureDevice = preset
                self.refresh()
            })
        }
        return menu
    }

    /// Flat options popover (WebOptionsEditor) under the gear chip. Changes
    /// apply immediately; the popover closes on outside click (.transient).
    private func presentWebOptionsPopover() {
        webOptionsPopover?.close()
        let editor = WebOptionsEditorViewController(options: appState.webCaptureOptions) { [weak self] options in
            guard let self else { return }
            self.appState.webCaptureOptions = options
            self.refresh()
        }
        let popover = CaptureCatPopover()
        popover.contentViewController = editor
        popover.show(relativeTo: webOptionsChip.bounds, of: webOptionsChip, preferredEdge: .maxY)
        webOptionsPopover = popover
    }

    // MARK: - Pre-recording countdown

    private static let countdownPresets: [(title: String, seconds: Int)] = [
        (String(localized: "Off", comment: "Recording countdown menu: no countdown"), 0),
        (String(localized: "3s", comment: "Recording countdown menu: 3 seconds"), 3),
        (String(localized: "5s", comment: "Recording countdown menu: 5 seconds"), 5),
        (String(localized: "10s", comment: "Recording countdown menu: 10 seconds"), 10),
    ]

    private func countdownMenu() -> NSMenu {
        let menu = newMenu()
        let current = appState.recordingCountdownSeconds
        for preset in Self.countdownPresets {
            menu.addItem(actionItem(preset.title, state: current == preset.seconds ? .on : .off) { [weak self] in
                guard let self else { return }
                self.appState.recordingCountdownSeconds = preset.seconds
                self.refresh()
            })
        }
        return menu
    }

    // MARK: - Tab switching

    // MARK: - Harness hooks

    /// Width the setup toolbar actually needs, vs the width it is given.
    /// `--recording-panel-shot` asserts the first never exceeds the second:
    /// when it does, AppKit breaks the width constraint and the chips OVERLAP,
    /// so clicks land on whichever view happens to be on top.
    var debugToolbarFitting: (needed: CGFloat, available: CGFloat) {
        (shell.fittingSize.width, view.bounds.width)
    }

    /// Every setup-toolbar view with its frame in WINDOW coordinates, so the
    /// gate can spot overlaps rather than infer them.
    var debugSetupFrames: [(name: String, frame: NSRect, hidden: Bool)] {
        let named: [(String, NSView)] = [
            ("tabsStack", tabsStack), ("displayChip", displayChip),
            ("windowChip", windowChip), ("areaStack", areaStack),
            ("deviceChip", deviceChip), ("devicesChip", devicesChip),
            ("audioChip", audioChip), ("recordChip", recordChip), ("closeChip", closeChip),
        ]
        return named.map { (n, v) in
            (n, v.convert(v.bounds, to: nil), v.isHidden)
        }
    }

    /// The Record/Screenshot chips, for the click gate.
    var debugModeChips: [CaptureMode: RecordingTabChip] { modeSwitch.debugChips }

    /// The source tab chips, for `--recording-panel-shot`'s click gate.
    var debugTabChips: [RecordingSourceTab: RecordingTabChip] { tabChips }
    /// The currently selected source tab.
    var debugSelectedTab: RecordingSourceTab { sourceTab }
    var debugTimerChip: RecordingTimerChip { timerChip }

    /// Drives the two independent recording-bar hover systems through an
    /// actual transition and reports whether their presentation layers were
    /// between the two controls mid-flight. Harness only.
    func debugProbeHoverGlide(completion: @escaping (_ tabsGlide: Bool, _ controlsGlide: Bool) -> Void) {
        tabsStack.layoutSubtreeIfNeeded()
        stack.layoutSubtreeIfNeeded()
        guard let display = tabChips[.display], let window = tabChips[.window],
              let toolbarGlide else {
            completion(false, false)
            return
        }

        let displayFrame = tabsStack.convert(display.bounds, from: display)
        let windowFrame = tabsStack.convert(window.bounds, from: window)
        let micFrame = stack.convert(devicesChip.bounds, from: devicesChip)
        let audioFrame = stack.convert(audioChip.bounds, from: audioChip)

        // Let each first placement settle. Then deliberately include the
        // mouse-exit transition the live poller emits before entering its
        // neighbour; this is the sequence that used to erase the glide.
        tabsPill.setHover(frame: displayFrame)
        toolbarGlide.update(row: devicesChip, active: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { [weak self] in
            guard let self else { completion(false, false); return }
            self.tabsPill.setHover(frame: nil)
            self.tabsPill.setHover(frame: windowFrame)
            toolbarGlide.update(row: self.devicesChip, active: false)
            toolbarGlide.update(row: self.audioChip, active: true)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                guard let self else { completion(false, false); return }
                let tabMidX = self.tabsPill.debugHoverPresentationFrame.midX
                let controlsMidX = toolbarGlide.debugPresentationFrame.midX
                let isBetween: (CGFloat, CGFloat, CGFloat) -> Bool = { value, a, b in
                    value > min(a, b) + 0.5 && value < max(a, b) - 0.5
                }
                completion(
                    isBetween(tabMidX, displayFrame.midX, windowFrame.midX),
                    isBetween(controlsMidX, micFrame.midX, audioFrame.midX)
                )
            }
        }
    }

    /// Frozen-row snapshots currently on screen — the rapid-switch gate:
    /// mid-crossfade at most ONE may exist; settled, exactly zero. Stacked
    /// snapshots are the "duplicate logos" bug.
    var debugCrossfadeSnapshotCount: Int {
        shellBody.subviews.filter { $0 is HitTransparentImageView }.count
    }
    /// True while the live row is mid-fade (settled rows must be alpha 1).
    var debugRowIsSettled: Bool {
        stack.alphaValue == 1 && stack.layer?.animation(forKey: "opacity") == nil
            && fadedControlViews.isEmpty
    }

    // MARK: - Live-capture hooks (--panel-live-capture)

    /// PRESENTATION-tree opacities of the two crossfading rows — what is on
    /// glass right now, not the model values `cacheDisplay` renders. When a
    /// tab switch keeps the strip live (region freeze), the "incoming" row is
    /// the faded CONTROLS, not the whole stack — the stack stays opaque by
    /// design and would read as a permanent 1.0 overlap.
    var debugCrossfadePresentation: (outgoing: Float?, incoming: Float?) {
        let incoming: Float?
        if let control = fadedControlViews.first {
            incoming = control.layer?.presentation().map(\.opacity) ?? Float(control.alphaValue)
        } else {
            incoming = stack.layer?.presentation().map(\.opacity) ?? Float(stack.alphaValue)
        }
        return (activeCrossfadeSnapshot?.layer?.presentation()?.opacity, incoming)
    }
    /// Tab-strip frame in window coordinates (band for the pixel gate).
    var debugTabsStripFrameInWindow: NSRect { tabsStack.convert(tabsStack.bounds, to: nil) }
    /// Shell frame in window coordinates.
    var debugShellFrameInWindow: NSRect { shell.convert(shell.bounds, to: nil) }

    /// Alignment table for every visible icon-over-label chip plus the URL-row
    /// chips: (name, icon centerY, label baselineY | nan) in window coords.
    var debugAlignmentRows: [(name: String, iconCenterY: CGFloat, labelBaseline: CGFloat)] {
        var rows: [(String, CGFloat, CGFloat)] = []
        for (tab, chip) in tabChips.sorted(by: { $0.key.rawValue < $1.key.rawValue }) where !chip.isHiddenOrHasHiddenAncestor {
            rows.append(("tab-\(tab.rawValue)", chip.debugIconCenterYInWindow, chip.debugLabelBaselineYInWindow))
        }
        for (mode, chip) in modeSwitch.debugChips.sorted(by: { $0.key.rawValue < $1.key.rawValue }) where !chip.isHiddenOrHasHiddenAncestor {
            rows.append(("mode-\(mode.rawValue)", chip.debugIconCenterYInWindow, chip.debugLabelBaselineYInWindow))
        }
        if !urlChip.isHiddenOrHasHiddenAncestor {
            rows.append(("url-field", urlChip.debugIconCenterYInWindow, urlChip.debugLabelBaselineYInWindow))
        }
        if !webDeviceChip.isHiddenOrHasHiddenAncestor {
            rows.append(("web-device", webDeviceChip.debugIconCenterYInWindow, webDeviceChip.debugLabelBaselineYInWindow))
        }
        if !webOptionsChip.isHiddenOrHasHiddenAncestor {
            rows.append(("web-gear", webOptionsChip.debugIconCenterYInWindow, .nan))
        }
        if !settingsChip.isHiddenOrHasHiddenAncestor {
            rows.append(("settings-gear", settingsChip.debugIconCenterYInWindow, .nan))
        }
        return rows
    }

    /// Geometry dump for the alignment gate's stragglers.
    var debugChipGeometry: [(name: String, chip: NSRect, body: NSRect)] {
        [("settings-gear", settingsChip), ("web-gear", webOptionsChip)].map { name, chip in
            (name, chip.convert(chip.bounds, to: nil), chip.debugBodyFrameInWindow)
        }
    }

    /// Runs the REAL animated tab switch — same code path as a click.
    func debugAnimatedSelect(_ tab: SourceTab) { select(tab: tab) }

    /// Selection-chip probe: the chip's on-glass frame and `target`'s frame
    /// (both in the strip's coordinates), whether the chip sits UNDER the tab
    /// glyphs, and whether it carries the floating material's shadow.
    func debugTabsPillProbe(target: SourceTab) -> (presentation: CGRect, target: CGRect, below: Bool, floating: Bool) {
        let chipFrame = tabChips[target].map { tabsStack.convert($0.bounds, from: $0) } ?? .zero
        return (tabsPill.debugSelectionPresentationFrame, chipFrame,
                tabsStack.subviews.first === tabsPill, tabsPill.debugSelectionHasShadow)
    }

    private func select(tab: SourceTab) {
        guard !isRecordingActive else { return } // `.disabled(isRecordingActive)`
        guard !isCapturingURL else { return }
        sourceTab = tab
        errorMessage = nil
        if tab == .device {
            refreshCaptureDevices()
        }
        // Window tab goes straight into the macOS-screenshot-style picker:
        // hover highlights the window under the cursor, click selects it,
        // Escape falls back to the chip's list.
        if tab == .window {
            pickWindow()
        }

        // The selection pill springs to the clicked tab while the row settles.
        if let chip = tabChips[tab] {
            tabsPill.setSelection(
                frame: tabsStack.convert(chip.bounds, from: chip),
                animated: true
            )
        }

        // Same recipe as the phase morph — snapshot freeze, first-half fade
        // out, mid-point beat, second-half fade in — but on the crisp tab
        // clock, and only when the row visibly changes. `resizeToFitContent`
        // makes the bar BREATHE to each tab's natural width on the springy
        // settle curve — tabs whose rows differ in width (Area, iPhone, URL)
        // used to crossfade inside a fixed shell with no resize at all,
        // which read as dead (user call 2026-08-17: "Area to iPhone and
        // back isn't springy").
        crossfadeRows(
            clock: RecordingMotion.morphDuration,
            layoutCurve: RecordingMotion.settleCurve,
            onlyIfLayoutChanges: true,
            resizeToFitContent: true,
            keepTabsLive: true
        ) { [weak self] in
            // Focus after the crossfade, not during: taking first responder
            // mid-animation puts the caret where the field used to be.
            if tab == .url { self?.urlChip.focus() }
        }
    }

    // MARK: - Capture mode

    /// Animates the row into its new shape when Record/Screenshot flips. The
    /// new selection is committed only AFTER the old bar has been frozen, so
    /// no frame can contain an incoming mode label with outgoing controls.
    private func applyModeChange(to mode: CaptureMode) {
        guard mode != modeSwitch.mode else { return }
        // iPhone is a live-video source; there is nothing to "screenshot" from
        // it here, so fall back to Display rather than leaving a tab selected
        // that the mode cannot service.
        if mode == .screenshot, sourceTab == .device {
            sourceTab = .display
        }
        // Record↔Screenshot changes the row's composition (record button vs
        // shutter, device/audio chips come and go). Use the calm two-phase
        // phase clock rather than a short crossfade: old bar out, a clean
        // surface beat, then new bar in while the shell settles.
        crossfadeRows(
            clock: RecordingMotion.phaseCrossfadeDuration,
            layoutCurve: RecordingMotion.phaseResizeCurve,
            resizeToFitContent: true,
            beforeRefresh: { [weak self] in self?.modeSwitch.mode = mode }
        )
    }

    /// Grabs a still of the selected source and opens it in the editor.
    ///
    /// Goes through the same still-to-movie encode the URL flow uses, so a
    /// screenshot is an ordinary project with zooms, annotations, device frames
    /// and export — rather than a second, thinner editor.
    private func captureStill() {
        guard let source = selectedSource else { return }
        Task { @MainActor in
            do {
                guard let image = try await ScreenStillCapture.capture(source) else {
                    errorMessage = String(localized: "Nothing was captured.", comment: "Recording panel: error when a screenshot capture returned no image")
                    refresh()
                    return
                }
                let movie = FileManager.default.temporaryDirectory
                    .appendingPathComponent("capturecat-shot-\(UUID().uuidString).mp4")
                let size = try await StillMovieWriter.write(image: image, to: movie)
                appState.openWebCapture(movieURL: movie, pixelSize: size, sourceURL: nil)
            } catch {
                errorMessage = error.localizedDescription
                panelLogger.error("still capture failed: \(error.localizedDescription, privacy: .public)")
                refresh()
            }
        }
    }

    // MARK: - URL capture

    /// Renders the address via the CaptureCat API's Chromium engine
    /// (`RemoteScreenshotClient`), encodes the returned PNG as a short movie
    /// and opens it in the editor as an ordinary project.
    ///
    /// 100% Chromium by product decision: there is NO local-WebKit fallback —
    /// signed-out, offline and API errors all land inline on the URL field.
    /// (`WebPageCapture.normalize` is only borrowed as the pure URL
    /// normalizer; nothing here renders in WKWebView.)
    private func captureWebPage(_ raw: String) {
        guard !isCapturingURL else { return }
        guard let pageURL = WebPageCapture.normalize(raw) else {
            urlErrorMessage = String(localized: "\"\(raw)\" is not a valid web address.", comment: "Recording panel URL tab: inline error; the value is what the person typed")
            refresh()
            return
        }
        isCapturingURL = true
        urlErrorMessage = nil
        refresh()

        Task { @MainActor in
            defer { isCapturingURL = false; refresh() }
            do {
                let image = try await RemoteScreenshotClient().capture(
                    url: pageURL, preset: appState.webCaptureDevice, options: appState.webCaptureOptions
                )
                guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    throw RemoteScreenshotClient.ClientError.badResponse
                }

                let movie = FileManager.default.temporaryDirectory
                    .appendingPathComponent("capturecat-web-\(UUID().uuidString).mp4")
                let size = try await StillMovieWriter.write(image: cg, to: movie)

                appState.openWebCapture(
                    movieURL: movie,
                    pixelSize: size,
                    sourceURL: pageURL
                )
            } catch {
                urlErrorMessage = error.localizedDescription
                panelLogger.error("web capture failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Derived state (ported verbatim)

    private var selectedCaptureDevice: AVCaptureDevice? {
        availableCaptureDevices.first { $0.uniqueID == selectedCaptureDeviceUID }
    }

    private var areaSelectionLabel: String {
        guard let rect = selectedAreaRect else { return String(localized: "Select Area", comment: "Recording panel Area tab: button (verb) to drag out a screen region") }
        return String(localized: "Area \(Int(rect.width))x\(Int(rect.height))", comment: "Recording panel Area tab: chosen region size in pixels, e.g. \"Area 1280x720\"")
    }

    private var canStart: Bool {
        guard !isLoadingSources, !isSelectingArea else { return false }
        switch sourceTab {
        case .display: return selectedDisplay != nil
        case .window: return selectedWindow != nil
        case .area: return areaDisplay != nil && selectedAreaRect != nil
        case .device:
            if selectedCaptureDevice != nil { return true }
            guard let key = selectedWirelessKey else { return false }
            let hub = WirelessDeviceHub.shared
            return hub.isStreaming(key) && hub.pending == nil
        // URL capture is not a recording: it has no Start button and is driven
        // by Return in the URL field, so nothing here can "start".
        case .url: return false
        }
    }

    private var isSetupMode: Bool {
        if case .idle = appState.recordingSession.phase { return true }
        if case .failed = appState.recordingSession.phase { return true }
        return false
    }

    private var selectedDisplay: SCDisplay? {
        availableDisplays.first { $0.displayID == selectedDisplayID }
    }

    private var areaDisplay: SCDisplay? {
        availableDisplays.first { $0.displayID == areaDisplayID }
    }

    private var selectedWindow: SCWindow? {
        availableWindows.first { $0.windowID == selectedWindowID }
    }

    private var deviceSummaryTitle: String {
        let mic = appState.recordingSession.isMicEnabled ? String(localized: "Mic", comment: "Recording panel: mic/camera chip, microphone on (short)") : String(localized: "No Mic", comment: "Recording panel: mic/camera chip, microphone off (short)")
        let camera = appState.recordingSession.isCameraEnabled ? String(localized: "Cam", comment: "Recording panel: mic/camera chip, camera on (short for camera)") : String(localized: "No Cam", comment: "Recording panel: mic/camera chip, camera off (short for camera)")
        return "\(mic) · \(camera)"
    }

    private var timerText: String {
        if case .preparing = appState.recordingSession.phase { return String(localized: "Starting...", comment: "Recording panel: timer text while the recording is starting") }
        return appState.recordingSession.elapsedTime.formattedTimecode
    }

    private var isPreparingPhase: Bool {
        if case .preparing = appState.recordingSession.phase { return true }
        return false
    }

    private var isStoppingPhase: Bool {
        if case .stopping = appState.recordingSession.phase { return true }
        return false
    }

    private var isRecordingOrPaused: Bool {
        appState.recordingSession.isRecording || appState.recordingSession.isPaused
    }

    private var isRecordingActive: Bool {
        isPreparingPhase || isRecordingOrPaused || isStoppingPhase
    }

    private var shouldShowLiveCameraPreview: Bool {
        isPreparingPhase || isRecordingOrPaused
    }

    private func displayTitle(_ display: SCDisplay) -> String {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
        }
        let name = screen?.localizedName ?? String(localized: "Display", comment: "Recording panel: fallback name for a monitor whose name is unknown")
        return "\(name) (\(display.width)×\(display.height))"
    }

    private func windowTitle(_ window: SCWindow) -> String {
        let name = window.title?.isEmpty == false ? window.title! : String(localized: "Untitled", comment: "Recording panel: name for a window that has no title")
        if let app = window.owningApplication?.applicationName, !app.isEmpty {
            return "\(name) - \(app)"
        }
        return name
    }

    private func activateOwningApplication(for window: SCWindow) {
        guard let pid = window.owningApplication?.processID else { return }
        NSRunningApplication(processIdentifier: pid)?
            .activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }

    private func flashDisplayForWindow(_ window: SCWindow) {
        let windowFrame = window.frame
        let targetScreen = NSScreen.screens.max { lhs, rhs in
            let lhsArea = lhs.frame.intersection(windowFrame)
            let rhsArea = rhs.frame.intersection(windowFrame)
            return lhsArea.width * lhsArea.height < rhsArea.width * rhsArea.height
        }
        guard let screen = targetScreen else { return }
        flashScreenBorder(screen)
    }

    private func flashDisplay(_ display: SCDisplay) {
        guard let screen = NSScreen.screens.first(where: {
            guard let screenNumber = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return false
            }
            return screenNumber == display.displayID
        }) else { return }
        flashScreenBorder(screen)
    }

    private func flashScreenBorder(_ screen: NSScreen) {
        let frame = screen.frame
        let borderWindow = NSWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        borderWindow.level = .screenSaver
        borderWindow.sharingType = .none
        borderWindow.backgroundColor = .clear
        borderWindow.isOpaque = false
        borderWindow.ignoresMouseEvents = true
        borderWindow.hasShadow = false

        let borderView = NSView(frame: NSRect(origin: .zero, size: frame.size))
        borderView.wantsLayer = true
        borderView.layer?.borderColor = NSColor.systemBlue.cgColor
        borderView.layer?.borderWidth = 6
        borderView.layer?.cornerRadius = CCTheme.radius(.lg)
        borderWindow.contentView = borderView
        borderWindow.orderFrontRegardless()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                borderWindow.animator().alphaValue = 0
            }, completionHandler: {
                borderWindow.orderOut(nil)
            })
        }
    }

    // MARK: - Sources

    private func syncPanelSize() {
        let targetSize = isRecordingActive
            ? RecordingPanelMetrics.recordingPanelSize()
            : RecordingPanelMetrics.setupPanelSize()
        appState.panelController.resize(to: targetSize)
    }

    // MARK: - Phase morph (setup ↔ recording toolbar)

    /// The transition is exactly two things — Apple's own record-transition
    /// recipe (Control Center screen recording, QuickTime):
    ///   1. the window resizes on one gentle curve, and
    ///   2. the row content plain-crossfades: outgoing over the FIRST half,
    ///      incoming over the SECOND half, with a brief mid-point where the
    ///      bar is just the solid surface. That empty beat is what makes the
    ///      crossfade read calm instead of busy.
    /// No hero, no slide, no scale, no stagger. Reduce-motion runs the same
    /// recipe on the short clock. Tab switches use the identical recipe via
    /// `crossfadeRows` (the selection pill's glide is separate and stays).
    private func performPhaseTransition() {
        let targetSize = isRecordingActive
            ? RecordingPanelMetrics.recordingPanelSize()
            : RecordingPanelMetrics.setupPanelSize()
        crossfadeRows(resizeTo: targetSize)
    }

    /// Set by `--panel-motion-capture`: the harness drives the crossfade
    /// frame-by-frame itself, so the live animation must not also run.
    var debugSuppressAnimatedTransition = false

    /// The shared crossfade: freeze the outgoing row, flip to the incoming
    /// one, fade out then in around a clean mid-point while the window (if
    /// `resizeTo` is given) and the shell resolve on the same clock.
    ///
    /// `clock`/`layoutCurve` pick the family member: the setup↔recording
    /// phase morph runs the slow record clock, tab switches the crisp
    /// `morphDuration`/`settleCurve` pair. `onlyIfLayoutChanges` is the tab
    /// rule: when the incoming row needs the same width as the outgoing one,
    /// nothing translates, so there is nothing for a snapshot to hide — the
    /// row swaps in place and only the selection pill moves. (Width is the
    /// right test, not chip identity: labels only ever slide when the row's
    /// metrics change. Display↔Window swap equal-width picker chips — zero
    /// motion — while any switch to/from URL, Area, or a screenshot-mode row
    /// changes widths and gets the full snapshot treatment.)
    /// The one snapshot allowed on screen. Rapid switching used to start a
    /// second crossfade while the first was mid-fade: its snapshot stayed up
    /// (duplicate logos) and the NEW snapshot was taken of a half-faded,
    /// mid-resize row (misaligned ghosts). Every crossfade now settles the
    /// previous one to its end state FIRST — remove the old snapshot, kill
    /// the in-flight fades, restore the live row to full alpha — so a
    /// snapshot always captures a clean, settled row and at most one exists.
    private var activeCrossfadeSnapshot: NSImageView?
    /// Tab switches fade ONLY these (the controls right of the tab strip);
    /// the strip itself stays live so its labels never crossfade over
    /// themselves. Emptied when the crossfade settles.
    private var fadedControlViews: [NSView] = []

    private func settleInFlightCrossfade() {
        guard activeCrossfadeSnapshot != nil
            || stack.layer?.animation(forKey: "opacity") != nil
            || stack.alphaValue != 1
            || !fadedControlViews.isEmpty else { return }
        unfreezeOutgoingRow(activeCrossfadeSnapshot)
        activeCrossfadeSnapshot = nil
        // The animator's in-flight opacity animation would keep presenting the
        // OLD fade over the new crossfade's model values — remove it.
        stack.layer?.removeAnimation(forKey: "opacity")
        stack.alphaValue = 1
        for view in fadedControlViews {
            view.layer?.removeAnimation(forKey: "opacity")
            view.alphaValue = 1
        }
        fadedControlViews = []
        // Deliberately synchronous: the next crossfade snapshots and measures
        // the row immediately after this settle, so layout MUST be resolved
        // here (a needsLayout deferral leaves a stale snapshot behind — the
        // TABSTORM/PANEL-LIVE gates fail). When settle is reached from inside
        // a layout pass AppKit logs a one-time "not legal to call
        // -layoutSubtreeIfNeeded" warning; accepted trade, benign today.
        view.layoutSubtreeIfNeeded()
    }

    /// What the row visibly says: every text and symbol in the currently
    /// unhidden chips, in order. The crossfade-skip test compares this before
    /// and after `refresh()` — width alone can't see an equal-width label
    /// swap (see the tab rule below).
    private func rowContentSignature() -> String {
        func collect(_ view: NSView, into parts: inout [String]) {
            guard !view.isHidden else { return }
            if let field = view as? NSTextField {
                parts.append(field.stringValue)
            }
            if let imageView = view as? NSImageView, let name = imageView.image?.name() {
                parts.append(name)
            }
            for subview in view.subviews { collect(subview, into: &parts) }
        }
        var parts: [String] = []
        collect(stack, into: &parts)
        return parts.joined(separator: "|")
    }

    private func crossfadeRows(
        resizeTo targetSize: NSSize? = nil,
        clock clockDuration: TimeInterval = RecordingMotion.phaseCrossfadeDuration,
        // Optional sentinel: the CAMediaTimingFunction default is resolved in
        // the body so the main-actor static is never touched by a
        // nonisolated default-argument expression.
        layoutCurve layoutCurveOverride: CAMediaTimingFunction? = nil,
        onlyIfLayoutChanges: Bool = false,
        resizeToFitContent: Bool = false,
        keepTabsLive: Bool = false,
        beforeRefresh: (() -> Void)? = nil,
        completion: (() -> Void)? = nil
    ) {
        guard isViewLoaded, view.window != nil, !debugSuppressAnimatedTransition else {
            syncPanelSize()
            refresh()
            completion?()
            return
        }
        settleInFlightCrossfade()
        let layoutCurve = layoutCurveOverride ?? RecordingMotion.phaseResizeCurve
        let reduce = RecordingMotion.reduceMotion
        let clock = reduce ? RecordingMotion.reducedDuration : clockDuration
        let half = clock / 2

        // Freeze the outgoing row before refresh() flips visibility (both
        // sections live in one stack, so they cannot be on screen at once).
        let widthBefore = stack.fittingSize.width
        let signatureBefore = rowContentSignature()
        // Chrome padding between the bar edge and the row content — measured,
        // not a metric constant, so fit-resizing tracks the real shell.
        let chromePad = max(0, (view.window?.frame.width ?? view.bounds.width) - widthBefore)
        let outgoing = freezeOutgoingRow(after: keepTabsLive ? tabsStack : nil)
        activeCrossfadeSnapshot = outgoing

        // Mode changes use this to commit the segment selection only after
        // the outgoing snapshot exists. Other transitions leave it empty.
        beforeRefresh?()
        refresh() // flip hidden states to the incoming section

        // Tab rule: skip the crossfade only when the row TRULY didn't change
        // on screen — same width AND same visible text/symbols. Width alone
        // was the old test, and it let equal-width switches (Display↔Window)
        // swap different labels in place: an instant text pop, the "crossover"
        // the user called ugly (2026-08-17). Rows that changed content at the
        // same width now get the same calm crossfade, just with no resize.
        if onlyIfLayoutChanges,
           abs(stack.fittingSize.width - widthBefore) < 0.5,
           rowContentSignature() == signatureBefore {
            unfreezeOutgoingRow(outgoing)
            activeCrossfadeSnapshot = nil
            completion?()
            return
        }
        // Mode switches: the bar BREATHES to fit the incoming row on the same
        // clock as the crossfade (Apple's recipe) — a fixed-width bar left the
        // narrower screenshot row rattling inside the record-width shell and
        // the two different-width rows colliding mid-fade.
        let effectiveTarget = resizeToFitContent
            ? RecordingPanelMetrics.setupPanelSize(
                fittingContentWidth: stack.fittingSize.width + chromePad)
            : targetSize
        // Tab switches hide only the incoming CONTROLS; the tab strip (and
        // everything left of it) stays live and simply glides with the
        // resize — fading identical tab labels out and back at shifted
        // positions is the "text crossover" the user hated (2026-08-17).
        if keepTabsLive, let boundary = stack.arrangedSubviews.firstIndex(of: tabsStack) {
            fadedControlViews = Array(stack.arrangedSubviews[(boundary + 1)...])
                .filter { !$0.isHidden }
            for view in fadedControlViews { view.alphaValue = 0 }
        } else {
            stack.alphaValue = 0
        }

        // Window frame + Auto Layout resolve inside ONE animation group (in
        // FloatingPanelController.resize) on the crossfade clock. No-op in the
        // harness, which has no floating panel.
        if let effectiveTarget {
            appState.panelController.resize(
                to: effectiveTarget, animated: true,
                duration: clock, curve: layoutCurve
            )
        }

        // The two fade halves run through AppKit's animator, chained by the
        // first half's completion. They must NOT be raw CABasicAnimations on
        // the backing layers: AppKit owns `opacity` on layer-backed views and
        // reasserts it from `alphaValue` during the animated layout pass, which
        // silently killed the snapshot's fade-out — the frozen row then sat
        // fully opaque for the whole clock while the incoming row faded in
        // around it (icons rendered TWICE, worst to/from URL, `--panel-live-
        // capture` frames 06–10), and the switch ended on a hard pop instead
        // of a fade. Curves/halves stay the same math the motion-capture
        // harness samples via RecordingMotion.crossfadeAlphas.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = half
            ctx.timingFunction = RecordingMotion.crossfadeHalfCurve
            outgoing?.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, self.activeCrossfadeSnapshot === outgoing else {
                // Superseded mid-fade — a newer crossfade already settled and
                // removed this snapshot; its own chain owns the row now.
                return
            }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = half
                ctx.timingFunction = RecordingMotion.crossfadeHalfCurve
                if self.fadedControlViews.isEmpty {
                    self.stack.animator().alphaValue = 1
                } else {
                    for view in self.fadedControlViews { view.animator().alphaValue = 1 }
                }
            } completionHandler: { [weak self] in
                guard let self, self.activeCrossfadeSnapshot === outgoing else { return }
                self.unfreezeOutgoingRow(outgoing)
                self.activeCrossfadeSnapshot = nil
                self.stack.alphaValue = 1
                for view in self.fadedControlViews { view.alphaValue = 1 }
                self.fadedControlViews = []
                completion?()
            }
        }

        // Shell/layout settle on the same clock and curve as the window.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = clock
            ctx.timingFunction = layoutCurve
            ctx.allowsImplicitAnimation = true
            view.layoutSubtreeIfNeeded()
        }
    }

    /// Bitmap of the current row, hosted INSIDE the bar (centred in the
    /// shell) with the shell clipping while it fades: as the bar narrows, the
    /// frozen content is swallowed by the bar's own edges rather than
    /// floating over the desktop outside it — the defect the first motion
    /// captures showed.
    /// `after:` freezes ONLY the region right of that arranged subview (tab
    /// switches pass the tab strip) and pins the shot to the boundary's LIVE
    /// trailing edge — the frozen old controls track the persistent strip
    /// through the breathe-resize instead of floating at a stale center.
    private func freezeOutgoingRow(after boundary: NSView? = nil) -> NSImageView? {
        if let boundary, boundary.superview === stack {
            let regionMinX = boundary.frame.maxX + stack.spacing / 2
            let region = NSRect(
                x: regionMinX, y: 0,
                width: stack.bounds.width - regionMinX,
                height: stack.bounds.height
            )
            guard region.width > 1,
                  let rep = stack.bitmapImageRepForCachingDisplay(in: region) else { return nil }
            stack.cacheDisplay(in: region, to: rep)
            let image = NSImage(size: region.size)
            image.addRepresentation(rep)
            let shot = HitTransparentImageView(frame: .zero)
            shot.image = image
            shot.imageScaling = .scaleAxesIndependently
            shot.translatesAutoresizingMaskIntoConstraints = false
            shell.layer?.masksToBounds = true
            shellBody.addSubview(shot)
            NSLayoutConstraint.activate([
                shot.leadingAnchor.constraint(
                    equalTo: boundary.trailingAnchor,
                    constant: regionMinX - boundary.frame.maxX
                ),
                shot.centerYAnchor.constraint(equalTo: shellBody.centerYAnchor),
                shot.widthAnchor.constraint(equalToConstant: region.width),
                shot.heightAnchor.constraint(equalToConstant: region.height),
            ])
            return shot
        }
        guard let shot = Self.snapshot(of: stack, in: view) else { return nil }
        let size = shot.frame.size
        shot.translatesAutoresizingMaskIntoConstraints = false
        shell.layer?.masksToBounds = true
        shellBody.addSubview(shot)
        NSLayoutConstraint.activate([
            shot.centerXAnchor.constraint(equalTo: shellBody.centerXAnchor),
            shot.centerYAnchor.constraint(equalTo: shellBody.centerYAnchor),
            shot.widthAnchor.constraint(equalToConstant: size.width),
            shot.heightAnchor.constraint(equalToConstant: size.height),
        ])
        return shot
    }

    private func unfreezeOutgoingRow(_ shot: NSImageView?) {
        shot?.removeFromSuperview()
        shell.layer?.masksToBounds = false
    }

    // MARK: - Motion-capture hooks (--panel-motion-capture)

    /// Freezes the outgoing row, applies `mutate` (select a tab, set a phase)
    /// and returns a stepper the harness drives at fixed intervals: `apply(t)`
    /// sets the crossfade's model values for progress t (0…1) with implicit
    /// animation disabled, so `cacheDisplay` renders honest frames of the
    /// exact alphas the live animation would show — both read
    /// `RecordingMotion.crossfadeAlphas`, one source of truth.
    func debugPhaseCrossfadeStepper(mutate: () -> Void) -> (apply: (Double) -> Void, finish: () -> Void) {
        // Live path equivalents: freezeOutgoingRow + the shell's animated
        // layout. The shell width is driven explicitly here because manual
        // stepping has no animation group to interpolate layout — same
        // start/end, same resize curve.
        let shellW0 = shell.bounds.width
        let outgoing = freezeOutgoingRow()
        mutate()
        refresh()
        view.layoutSubtreeIfNeeded()
        let shellW1 = shell.bounds.width
        stack.alphaValue = 0
        let shellWidth = shell.widthAnchor.constraint(equalToConstant: shellW0)
        shellWidth.priority = .init(999)
        shellWidth.isActive = true
        return (
            apply: { [weak self] t in
                guard let self else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                shellWidth.constant = shellW0 + (shellW1 - shellW0) * RecordingMotion.resizeProgress(at: t)
                let alphas = RecordingMotion.crossfadeAlphas(at: t)
                outgoing?.alphaValue = alphas.outgoing
                self.stack.alphaValue = alphas.incoming
                self.view.layoutSubtreeIfNeeded()
                CATransaction.commit()
            },
            finish: { [weak self] in
                shellWidth.isActive = false
                self?.unfreezeOutgoingRow(outgoing)
                self?.stack.alphaValue = 1
            }
        )
    }


    /// Bitmap of `source` positioned over its current spot in `host` — the
    /// outgoing half of the section cross-fade.
    ///
    /// MUST be hit-transparent: the snapshot overlays the live row for the
    /// whole crossfade (0.45s), and a plain NSImageView swallows any click
    /// arriving in that window — which made a second tab click within half a
    /// second of the first silently dead (the TABCLICK "lands one tab left"
    /// regression: the click did nothing, so the PREVIOUS selection stuck).
    private static func snapshot(of source: NSView, in host: NSView) -> NSImageView? {
        guard source.bounds.width > 1, source.bounds.height > 1,
              let rep = source.bitmapImageRepForCachingDisplay(in: source.bounds) else { return nil }
        source.cacheDisplay(in: source.bounds, to: rep)
        let image = NSImage(size: source.bounds.size)
        image.addRepresentation(rep)
        let imageView = HitTransparentImageView(frame: host.convert(source.bounds, from: source))
        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently
        return imageView
    }

    private func primeDefaultDevices() {
        if appState.selectedCameraDeviceID == nil {
            appState.selectedCameraDeviceID = appState.cameraManager.availableDevices.first?.uniqueID
        }
        if appState.selectedMicrophoneDeviceID == nil {
            appState.selectedMicrophoneDeviceID = appState.preferredMicrophoneDeviceID()
        }
    }

    private func refreshCaptureDevices() {
        DeviceRecorder.enableDeviceDiscovery()
        let apply = { [weak self] in
            guard let self else { return }
            self.availableCaptureDevices = DeviceRecorder.availableDevices
            self.reconcileDeviceSelection()
            self.refresh()
        }
        apply()
        // Devices surface asynchronously after the CoreMediaIO opt-in — check
        // again shortly so a just-plugged iPhone appears without manual refresh.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MainActor.assumeIsolated(apply)
        }
    }

    /// Set by the panel gates (`--recording-panel-shot`): never ask
    /// ScreenCaptureKit for sources. A gate build is signed differently from
    /// the release but shares its bundle id, so macOS shows its Screen
    /// Recording prompt — on the developer's Mac, with the real CaptureCat
    /// already allowed — and answering it hands the permission to the gate
    /// build. The panel then simply lists no displays or windows.
    static var harnessSkipsSourceProbe = false

    private func loadSources(forceProbe: Bool = false) async {
        if Self.harnessSkipsSourceProbe {
            isLoadingSources = false
            refresh()
            return
        }
        isLoadingSources = true
        errorMessage = nil
        refresh()

        let preflight = CGPreflightScreenCaptureAccess()
        if preflight {
            ScreenRecorder.clearAutomaticProbeSuppression()
        }
        if ScreenRecorder.shouldSuppressAutomaticScreenCaptureProbe && !forceProbe {
            panelLogger.info("loadSources skipped: suppressAutoProbe=true forceProbe=false preflight=\(preflight)")
            errorMessage = String(localized: "Screen recording access was recently denied. Enable CaptureCat in System Settings, then click the warning icon to retry.", comment: "Recording panel: error tooltip when Screen Recording permission was denied")
            isLoadingSources = false
            refresh()
            return
        }

        do {
            let content = try await appState.recorder.availableContent()
            availableDisplays = content.displays
            if selectedDisplayID == nil {
                selectedDisplayID = availableDisplays.first?.displayID
            }
            if areaDisplayID == nil {
                areaDisplayID = availableDisplays.first?.displayID
            }

            let myPID = ProcessInfo.processInfo.processIdentifier
            availableWindows = content.windows.filter { window in
                guard let title = window.title, !title.isEmpty else { return false }
                guard window.owningApplication?.processID != myPID else { return false }
                // Real app windows live on layer 0 — this drops menu bar items,
                // Control Centre chrome, the Dock, wallpaper, and other overlays.
                guard window.windowLayer == 0 else { return false }
                // No isOnScreen guard: windows on other Spaces and fullscreen
                // apps report false, and they're precisely the ones users go
                // looking for in this list. SCK captures them regardless.
                // Skip tiny utility slivers (status popovers, tooltips).
                guard window.frame.width >= 120 && window.frame.height >= 90 else { return false }
                return true
            }

            if selectedWindowID == nil {
                selectedWindowID = availableWindows.first?.windowID
            }
        } catch {
            let nsError = error as NSError
            let postFailurePreflight = CGPreflightScreenCaptureAccess()
            let windowListProbe = ScreenRecorder.hasScreenRecordingViaWindowList()
            panelLogger.error("loadSources failed: domain=\(nsError.domain, privacy: .public) code=\(nsError.code) desc=\(nsError.localizedDescription, privacy: .public) preflight=\(postFailurePreflight) windowList=\(windowListProbe) forceProbe=\(forceProbe)")
            if postFailurePreflight {
                errorMessage = String(localized: "CaptureCat appears enabled in Screen Recording, but macOS is still denying this app session. Quit CaptureCat completely and reopen it.", comment: "Recording panel: error tooltip when permission is on but macOS still refuses")
            } else {
                errorMessage = String(localized: "Screen recording permission is required. Enable CaptureCat in System Settings > Privacy & Security > Screen Recording.", comment: "Recording panel: error tooltip; the path names macOS System Settings panes")
            }
        }

        isLoadingSources = false
        refresh()
    }

    private func pickArea() {
        guard let display = areaDisplay else { return }
        isSelectingArea = true
        refresh()
        AreaSelectionOverlay.showOverlay(for: display) { [weak self] rect in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isSelectingArea = false
                if let rect {
                    self.selectedAreaRect = rect
                }
                self.refresh()
            }
        }
    }

    /// Hover-to-pick a window on screen (WindowSelectionOverlay). The picked
    /// CGWindowID is matched against the loaded SCWindow list; when the list
    /// is stale (window opened after load) it reloads once and retries.
    private func pickWindow() {
        guard !WindowSelectionOverlay.isActive else { return }
        // Harness runs drive real tab switches (debugAnimatedSelect) — a
        // live full-screen picker overlay would sit inside every screenshot.
        guard !CommandLine.arguments.contains(where: {
            $0.hasSuffix("-shot") || $0.hasSuffix("-probe") || $0.hasSuffix("-test")
        }) else { return }
        WindowSelectionOverlay.show { [weak self] windowID in
            MainActor.assumeIsolated {
                guard let self, let windowID else { return }
                // Same post-selection behavior as picking from the list:
                // the chosen window comes forward, ready to capture.
                if let window = self.availableWindows.first(where: { $0.windowID == windowID }) {
                    self.selectedWindowID = windowID
                    self.activateOwningApplication(for: window)
                    self.refresh()
                } else {
                    Task { @MainActor in
                        await self.loadSources()
                        if let window = self.availableWindows.first(where: { $0.windowID == windowID }) {
                            self.selectedWindowID = windowID
                            self.activateOwningApplication(for: window)
                        }
                        self.refresh()
                    }
                }
            }
        }
    }

    private var selectedSource: CaptureSource? {
        guard canStart else { return nil }
        switch sourceTab {
        case .display:
            guard let display = selectedDisplay else { return nil }
            return .display(display)
        case .window:
            guard let window = selectedWindow else { return nil }
            return .window(window)
        case .url:
            // Not a capture source — handled by `captureWebPage(_:)`.
            return nil
        case .area:
            guard let display = areaDisplay, let rect = selectedAreaRect else { return nil }
            return .area(display, rect)
        case .device:
            if let key = selectedWirelessKey { return .wirelessDevice(key) }
            guard let device = selectedCaptureDevice else { return nil }
            return .iosDevice(device)
        }
    }

    private func startRecording() {
        guard let source = selectedSource else { return }
        errorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            let success = await self.appState.startRecording(
                source: source,
                captureAudio: self.appState.captureSystemAudio
            )
            if !success {
                self.errorMessage = self.appState.recordingError ?? String(localized: "Failed to start recording", comment: "Recording panel: generic error when a recording could not start")
            }
            self.refresh()
        }
    }

    private func confirmRestartRecording() {
        guard let source = selectedSource else { return }
        let alert = CCAlert(
            title: String(localized: "Restart recording from beginning?", comment: "Alert title: confirm restarting the current recording"),
            message: String(localized: "Current take will be deleted and recording will immediately restart from 0:00.", comment: "Alert message for ‘Restart recording from beginning?’")
        )
        alert.addButton(String(localized: "Restart", comment: "Alert button (destructive, verb): restart the recording"), role: .destructive)
        alert.addButton(String(localized: "Keep Recording", comment: "Alert button: cancel restart and continue recording"))

        // Parent to the bar's own window: while recording the bar is a
        // non-activating .screenSaver-level panel that is never keyWindow,
        // so runModal() would orphan the dialog at a level BELOW the bar —
        // visible confirm buttons the user can never reach.
        guard let window = view.window else { return }
        alert.beginSheet(for: window) { [weak self] index in
            guard let self, index == 0 else { return }
            self.hideCameraPreview()
            self.appState.restartRecordingInProgress(
                source: source, captureAudio: self.appState.captureSystemAudio
            )
        }
    }

    private func confirmDeleteRecording() {
        let alert = CCAlert(
            title: String(localized: "Delete this recording?", comment: "Alert title: confirm deleting the recording in progress"),
            message: String(localized: "This stops and permanently deletes the current recording.", comment: "Alert message for ‘Delete this recording?’")
        )
        alert.addButton(String(localized: "Delete", comment: "Alert button (destructive, verb): delete the recording"), role: .destructive)
        alert.addButton(String(localized: "Cancel", comment: "Alert button: dismiss without doing anything"))

        guard let window = view.window else { return } // see confirmRestartRecording
        alert.beginSheet(for: window) { [weak self] index in
            guard let self, index == 0 else { return }
            self.hideCameraPreview()
            self.appState.discardRecordingInProgress()
        }
    }

    // MARK: - Camera bubble

    /// Free-floating squircle preview: draggable
    /// anywhere, position persisted, shares the recorder's capture session so
    /// the live feed continues seamlessly into the recording.
    private func showCameraPreview() {
        guard !cameraFloatPreview.isVisible else { return }

        let device = appState.cameraManager.availableDevices.first {
            $0.uniqueID == appState.selectedCameraDeviceID
        }
        let isScreenDevice = device?.hasMediaType(.muxed) ?? false
        cameraFloatPreview.show(
            session: appState.cameraManager.captureSession,
            device: device,
            isScreenDevice: isScreenDevice
        )
    }

    private func hideCameraPreview() {
        cameraFloatPreview.hide()
    }

    private func handleCameraPreviewState() {
        if isSetupMode {
            if appState.recordingSession.isCameraEnabled {
                try? appState.cameraManager.start(deviceID: appState.selectedCameraDeviceID)
                showCameraPreview()
            } else {
                hideCameraPreview()
                if !appState.cameraManager.isRecording {
                    appState.cameraManager.stop()
                }
            }
            return
        }

        if shouldShowLiveCameraPreview && appState.recordingSession.isCameraEnabled {
            showCameraPreview()
            return
        }

        hideCameraPreview()
        if !appState.cameraManager.isRecording {
            appState.cameraManager.stop()
        }
    }

    // MARK: - Live device monitor

    /// "cable" / "wifi:<id>" for the segment being recorded, nil for screen.
    private var currentMonitorSource: String? {
        if appState.wirelessRecorder.isRecording, let key = appState.wirelessRecorder.phoneKey {
            return Self.wirelessSelectionKey(key)
        }
        return appState.deviceRecorder.isRecording ? "cable" : nil
    }

    private func handleDeviceMonitorState() {
        let source = isRecordingOrPaused ? currentMonitorSource : nil
        if deviceMonitorPanel != nil, deviceMonitorSource != source {
            hideDeviceMonitor()
        }
        if source != nil {
            showDeviceMonitor()
        } else {
            hideDeviceMonitor()
        }
    }

    private func showDeviceMonitor() {
        guard deviceMonitorPanel == nil else { return }
        let content: NSView
        if appState.wirelessRecorder.isRecording, let key = appState.wirelessRecorder.phoneKey,
           let server = WirelessDeviceHub.shared.server {
            // The Wi-Fi phone's decoded frames on a sample-buffer layer.
            content = WirelessMonitorContentView(server: server, phone: key)
        } else if let session = appState.deviceRecorder.captureSession {
            let preview = CameraPreviewNSView()
            preview.mirrored = false
            preview.gravity = .resizeAspect
            preview.attach(session: session)
            content = preview
        } else {
            return
        }
        deviceMonitorSource = currentMonitorSource

        let size = NSSize(width: 250, height: 520)
        let monitor = DeviceMonitorNSView(content: content)
        monitor.frame = NSRect(origin: .zero, size: size)
        monitor.autoresizingMask = [.width, .height]

        let panel = NSPanel(
            contentRect: monitor.frame,
            styleMask: [.nonactivatingPanel, .borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.contentView = monitor
        // Resizable from the edges; keeps the phone's proportions.
        panel.contentAspectRatio = size
        panel.minSize = NSSize(width: 150, height: 312)
        panel.maxSize = NSSize(width: 520, height: 1082)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.sharingType = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true

        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.minX + 16, y: visible.midY - size.height / 2))
        }
        // Arrives with the house glide (fade) instead of popping in.
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        CCMotion.run(duration: 0.22, curve: CCMotion.glide) {
            panel.animator().alphaValue = 1
        }
        deviceMonitorPanel = panel
    }

    private func hideDeviceMonitor() {
        deviceMonitorSource = nil
        deviceMonitorPanel?.orderOut(nil)
        deviceMonitorPanel?.contentView = nil
        deviceMonitorPanel?.close()
        deviceMonitorPanel = nil
    }

    // MARK: - Harness hooks

    /// The bar shell's ACTUAL painted fill (harness only) — the theme-flip
    /// gate scores this colour directly rather than trusting a pixel mean.
    func debugShellLayerFill() -> CGColor? {
        shell.layer?.backgroundColor
    }

    /// Force a specific setup-mode tab (screenshot harness only).
    func debugSelectTab(_ tab: SourceTab) {
        sourceTab = tab
        refresh()
    }

    /// Drive the URL row exactly as Return in the field does (harness only) —
    /// same code path, so the probe tests the real wiring, not a twin.
    func debugSubmitURL(_ raw: String) {
        captureWebPage(raw)
    }

    /// Snapshot of the URL row's busy/error state for the spinner probe.
    var debugURLRowState: (spinnerVisible: Bool, spinnerBusy: Bool, fieldEnabled: Bool,
                           deviceEnabled: Bool, gearEnabled: Bool, error: String?) {
        (!spinnerChip.isHiddenOrHasHiddenAncestor, isCapturingURL, urlChip.isEnabled,
         webDeviceChip.isEnabled, webOptionsChip.isEnabled, urlErrorMessage)
    }

    /// Seed source lists without touching ScreenCaptureKit (screenshot
    /// harness only).
    func debugSeedSources(displays: [SCDisplay], windows: [SCWindow]) {
        availableDisplays = displays
        availableWindows = windows
        selectedDisplayID = displays.first?.displayID
        areaDisplayID = displays.first?.displayID
        selectedWindowID = windows.first?.windowID
        refresh()
    }

    /// Every drop-down the panel can open, built exactly as a real press
    /// builds it — lets the harness enumerate menu content and wiring without
    /// running a modal tracking loop.
    func debugMenus() -> [(String, NSMenu)] {
        [
            ("mic-camera", devicesMenu()),
            ("recording-settings", recordingSettingsMenu()),
            ("duration-limit", limitMenu()),
            ("countdown", countdownMenu()),
            ("web-device", webDeviceMenu()),
            ("switch-source", switchSourceMenu()),
        ]
    }

    // MARK: Wi-Fi harness seams (`--wireless-device-test`)

    /// The device picker exactly as a press builds it (options + actions).
    func debugDeviceOptionList() -> RecordingMenuChip.OptionList { deviceCaptureOptions() }

    /// The device row's visible state.
    var debugDeviceChipState: (title: String, error: String?, spinnerVisible: Bool, canStart: Bool, titleSwapInFlight: Bool) {
        (deviceChip.title, deviceChip.debugErrorMessage, !spinnerChip.isHiddenOrHasHiddenAncestor,
         canStart, deviceChip.debugTitleSwapInFlight)
    }

    var debugSelectedDeviceUID: String? { selectedCaptureDeviceUID }
    var debugDeviceTitleLayerInfo: String { deviceChip.debugTitleLayerInfo }
    var debugSourceChipLabel: String { sourceChip.debugLabel }
    var debugDeviceMonitorPanel: NSPanel? { deviceMonitorPanel }

    /// The four source pickers, now house combobox popups rather than menus —
    /// built exactly as a real press builds them, for harness enumeration.
    func debugOptionLists() -> [(String, RecordingMenuChip.OptionList)] {
        [
            ("display", displayOptions()),
            ("window", windowOptions()),
            ("area-display", areaDisplayOptions()),
            ("device-capture", deviceCaptureOptions()),
        ]
    }
}

/// Frozen-row overlay for the phase/tab crossfade: pure scenery, never a
/// click target — clicks pass through to the live chips underneath.
private final class HitTransparentImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// NSMenuItem that fires a closure — the AppKit shape of a SwiftUI
/// `Button` inside a `Menu`.
final class RecordingMenuAction: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire(_:)), keyEquivalent: "")
        target = self
        isEnabled = true
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire(_ sender: Any?) { handler() }
}
