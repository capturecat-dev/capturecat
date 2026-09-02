import ScreenCaptureKit
import AVFoundation
import AppKit

@Observable
final class AppState {
    static weak var current: AppState?
    private static let liveCameraPreviewPanelIdentifier = NSUserInterfaceItemIdentifier("so.capturecat.CaptureCat.liveCameraPreview")

    private enum DefaultsKey {
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let hasAcceptedTerms = "hasAcceptedTerms"
        static let recordingDurationLimit = "recordingDurationLimit"
        static let recordingCountdownSeconds = "recordingCountdownSeconds"
        static let autoZoomNewRecordings = "autoZoomNewRecordings"
        static let webCaptureDevice = "webCaptureDevice"
        static let webHeightMode = "webHeightMode"
        static let webDarkMode = "webDarkMode"
        static let webHideCookieBanners = "webHideCookieBanners"
        static let webHideChatWidgets = "webHideChatWidgets"
        static let webReduceMotion = "webReduceMotion"
        static let webCaptureDelay = "webCaptureDelay"
        static let autoSyncExports = "autoSyncExports"
        static let defaultScreenshotTool = "defaultScreenshotTool"
    }

    var recordingSession = RecordingSession()
    var currentProject: Project?
    /// Bumped when `currentProject` was replaced by a fresh instance reloaded
    /// from an external (MCP) disk edit — part of the editor child key in
    /// EditorWindowContentViewController, so the shell rebuilds even though
    /// the project id is unchanged.
    var editorReloadToken = 0
    var showEditor = false
    var showExport = false
    var showProjectBrowser = false
    var recordingError: String?
    var captureSystemAudio = true
    /// Maximum recorded duration for new takes, in seconds. 0 = no limit.
    /// Persisted; mirrored onto `recordingSession.durationLimit` so the
    /// session's 100ms tick enforces it against RECORDED time (its elapsed
    /// clock already excludes paused wall time).
    var recordingDurationLimit: TimeInterval = 0 {
        didSet {
            UserDefaults.standard.set(recordingDurationLimit, forKey: DefaultsKey.recordingDurationLimit)
            recordingSession.durationLimit = recordingDurationLimit > 0 ? recordingDurationLimit : nil
        }
    }
    /// Pre-recording countdown length in seconds (CapCut-style). 0 = off —
    /// recording starts immediately, no overlay. Persisted; the missing-key
    /// default is 3 (the classic 3-2-1), handled in `init`.
    var recordingCountdownSeconds: Int = 3 {
        didSet {
            UserDefaults.standard.set(recordingCountdownSeconds, forKey: DefaultsKey.recordingCountdownSeconds)
        }
    }
    /// "Auto-zoom. No editing required." — when a screen recording stops, the
    /// AutoZoomGenerator runs immediately so the project opens already
    /// zoomed. Default ON; a stored false is an explicit opt-out (missing-key
    /// default handled in `init`, same pattern as the countdown).
    var autoZoomNewRecordings: Bool = true {
        didSet {
            UserDefaults.standard.set(autoZoomNewRecordings, forKey: DefaultsKey.autoZoomNewRecordings)
        }
    }
    /// Automatically upload every export to the cloud library as a share
    /// (same background ShareJobCenter path as "Share after export").
    /// Default OFF — publishing to the cloud is an explicit opt-in. Only
    /// applies while signed in; when signed out, exports stay local.
    var autoSyncExports: Bool = false {
        didSet {
            UserDefaults.standard.set(autoSyncExports, forKey: DefaultsKey.autoSyncExports)
        }
    }
    /// "Default screenshot tool": ⇧⌘3/4/5 are intercepted app-wide and routed
    /// through CaptureCat (⇧⌘3 instant full-screen still, ⇧⌘4/5 open the
    /// capture panel); macOS's own screenshot UI never fires. Needs
    /// Accessibility trust — see ScreenshotHotkeys. Default off.
    var isDefaultScreenshotTool: Bool = false {
        didSet {
            UserDefaults.standard.set(isDefaultScreenshotTool, forKey: DefaultsKey.defaultScreenshotTool)
            guard !MCPServer.isMCP, !HeadlessRunner.isHeadless else { return }
            if isDefaultScreenshotTool, !ScreenshotHotkeys.hasPermission {
                ScreenshotHotkeys.requestPermission()
                // The system prompt appears only once per app, ever — open
                // the pane too so re-enables aren't a silent no-op.
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
            ScreenshotHotkeys.setEnabled(isDefaultScreenshotTool)
        }
    }
    /// Device layout for URL captures (Desktop default — a desktop-class site
    /// must come back in its desktop design). Persisted by raw value.
    var webCaptureDevice: WebDevicePreset = .desktop {
        didSet {
            UserDefaults.standard.set(webCaptureDevice.rawValue, forKey: DefaultsKey.webCaptureDevice)
        }
    }
    /// URL-capture options (height mode, dark mode, hide lists, delay,
    /// reduce motion). Defaults: viewport height, everything else off.
    var webCaptureOptions = WebCaptureOptions() {
        didSet {
            let defaults = UserDefaults.standard
            defaults.set(webCaptureOptions.heightMode.rawValue, forKey: DefaultsKey.webHeightMode)
            defaults.set(webCaptureOptions.darkMode, forKey: DefaultsKey.webDarkMode)
            defaults.set(webCaptureOptions.hideCookieBanners, forKey: DefaultsKey.webHideCookieBanners)
            defaults.set(webCaptureOptions.hideChatWidgets, forKey: DefaultsKey.webHideChatWidgets)
            defaults.set(webCaptureOptions.reduceMotion, forKey: DefaultsKey.webReduceMotion)
            defaults.set(webCaptureOptions.delaySeconds, forKey: DefaultsKey.webCaptureDelay)
        }
    }
    var selectedCameraDeviceID: String?
    var selectedMicrophoneDeviceID: String?
    var hasCompletedOnboarding: Bool
    var hasAcceptedTerms: Bool
    private(set) var authStateRevision = 0

    let recorder = ScreenRecorder()
    let deviceRecorder = DeviceRecorder()
    let cursorTracker = CursorTracker()
    let keystrokeTracker = KeystrokeTracker()
    /// ONE clock per take, handed to BOTH trackers. Timeline origin and pause
    /// bookkeeping live here and nowhere else, so cursor events and keystrokes
    /// are on the same timeline by construction — not by two call sites
    /// happening to pass matching numbers.
    let recordingClock = RecordingClock()
    /// True while the active take records an iPhone/iPad instead of the screen.
    private var isDeviceTake = false

    /// Finished segment files from mid-recording source switches, in order.
    struct RecordingSegment {
        let url: URL
        let kind: RecordingSourceKind
    }
    private var recordedSegments: [RecordingSegment] = []
    private var isSwitchingSource = false
    /// Human-readable name of what's being captured right now — shown in the
    /// recording toolbar so the user always knows the active source.
    private(set) var currentSourceLabel: String = ""
    /// Bundle id of the app whose window is being recorded (nil for
    /// display/area/device takes) — stamped onto the finished Project so the
    /// shortcut overlay can scope to the recorded app. Multi-segment stitched
    /// takes end up `.display` and ignore it.
    private var activeRecordingAppBundleID: String?

    private func sourceLabel(for source: CaptureSource) -> String {
        switch source {
        case .display(let display):
            let screen = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
            }
            return screen?.localizedName ?? "Display"
        case .window(let window):
            return window.owningApplication?.applicationName ?? window.title ?? "Window"
        case .area:
            return "Area"
        case .iosDevice(let device):
            return device.localizedName
        }
    }

    private var recordingsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CaptureCat/Recordings", isDirectory: true)
    }
    let panelController = FloatingPanelController()
    let cameraManager = CameraManager()
    let authService = AuthService()
    let shareService = ShareService()
    let projectStore = ProjectStore()
    /// Text captures ("notes") — parallel lightweight records beside the
    /// video projects, same folder-per-item persistence scheme.
    let noteStore = NoteStore()
    /// On-device OCR search index over captures — the browser's search and
    /// the MCP search_captures tool both read it. See CaptureTextIndex.
    let captureTextIndex = CaptureTextIndex()
    /// Folders / pins / shared marks — browser organization, separate from
    /// the per-project files.
    let library = ProjectLibrary()
    /// Background share uploads — detached from the export sheet; progress
    /// renders on project cards and mirrors to the web dashboard.
    let shareJobCenter = ShareJobCenter()

    private var recordingObserverTask: Task<Void, Never>?
    /// Injected by the AppKit shell (CaptureCatAppDelegate). Window opening used to
    /// also have a SwiftUI `OpenWindowAction` path for scene-hosted callers;
    /// that was removed with the SwiftUI shell, so this is the only opener.
    /// The scene ids ("editor", "onboarding") are unchanged.
    var appKitWindowOpener: ((String) -> Void)?
    /// Fires on the main actor once a finished recording has been saved as a
    /// project — the AutomationBridge publishes the project id through this so
    /// external tooling (MCP) learns what a stop produced.
    var onRecordingFinished: ((Project) -> Void)?
    /// One-shot seek consumed by the timeline when the editor opens — set by
    /// capturecat://open-project?id=…&t=… (e.g. a dashboard comment link).
    /// OUTPUT-time seconds, i.e. seconds into the exported/shared file.
    var pendingSeekOutputTime: TimeInterval?

    /// Present the editor window.
    func presentEditorWindow() {
        appKitWindowOpener?("editor")
    }
    private var shouldDiscardRecordingAfterStop = false
    private var pendingRestartRequest: (source: CaptureSource, captureAudio: Bool)?
    private static var didAutoOpenToolbarThisLaunch = false

    /// Set by headless harnesses (e.g. --browser-shot) BEFORE constructing
    /// AppState so the launch-time recording toolbar never pops on screen.
    static var suppressAutoToolbar = false

    init() {
        let defaults = UserDefaults.standard
        hasCompletedOnboarding = defaults.bool(forKey: DefaultsKey.hasCompletedOnboarding)
        hasAcceptedTerms = defaults.bool(forKey: DefaultsKey.hasAcceptedTerms)
        recordingDurationLimit = defaults.double(forKey: DefaultsKey.recordingDurationLimit)
        recordingSession.durationLimit = recordingDurationLimit > 0 ? recordingDurationLimit : nil
        // Missing key means "never chosen" → the 3s default; a stored 0 is an
        // explicit "Off" and must stay off.
        if defaults.object(forKey: DefaultsKey.recordingCountdownSeconds) != nil {
            recordingCountdownSeconds = defaults.integer(forKey: DefaultsKey.recordingCountdownSeconds)
        }
        if defaults.object(forKey: DefaultsKey.autoZoomNewRecordings) != nil {
            autoZoomNewRecordings = defaults.bool(forKey: DefaultsKey.autoZoomNewRecordings)
        }
        autoSyncExports = defaults.bool(forKey: DefaultsKey.autoSyncExports)
        isDefaultScreenshotTool = defaults.bool(forKey: DefaultsKey.defaultScreenshotTool)
        if let rawDevice = defaults.string(forKey: DefaultsKey.webCaptureDevice),
           let device = WebDevicePreset(rawValue: rawDevice) {
            webCaptureDevice = device
        }
        var webOptions = WebCaptureOptions()
        if let rawMode = defaults.string(forKey: DefaultsKey.webHeightMode),
           let mode = WebHeightMode(rawValue: rawMode) {
            webOptions.heightMode = mode
        }
        webOptions.darkMode = defaults.bool(forKey: DefaultsKey.webDarkMode)
        webOptions.hideCookieBanners = defaults.bool(forKey: DefaultsKey.webHideCookieBanners)
        webOptions.hideChatWidgets = defaults.bool(forKey: DefaultsKey.webHideChatWidgets)
        webOptions.reduceMotion = defaults.bool(forKey: DefaultsKey.webReduceMotion)
        webOptions.delaySeconds = defaults.integer(forKey: DefaultsKey.webCaptureDelay)
        webCaptureOptions = webOptions
        // Auto-stop takes the SAME path as the stop button — no forked
        // shutdown logic (CLAUDE.md §2 spirit: one source of truth).
        recordingSession.onDurationLimitReached = { [weak self] in
            self?.stopRecordingInProgress()
        }
        // One-time scrub: a removed AI feature left a plaintext API key in
        // defaults — extractable by anyone with disk access. AI now goes
        // through the API (server-held key); nothing client-side may remain.
        defaults.removeObject(forKey: "gemini_api_key")
        authService.onAuthStateChange = { [weak self] in
            Task { @MainActor [weak self] in
                self?.authStateRevision += 1
            }
        }
        authService.configureIfNeeded()

        Self.current = self
        // Successful background shares stamp the library's "shared" mark.
        shareJobCenter.attach(library: library)

        // Default-screenshot-tool hotkeys — never in --mcp/headless siblings
        // (same multi-process trap as the auto toolbar below).
        if !MCPServer.isMCP, !HeadlessRunner.isHeadless {
            ScreenshotHotkeys.onFullScreen = { [weak self] in self?.captureFullScreenScreenshot() }
            ScreenshotHotkeys.onPanel = { [weak self] in self?.beginNewRecording() }
            // The setting can be ON while Accessibility is still ungranted
            // (enabled before the grant, or the grant was revoked): prompt at
            // launch too, or the feature stays silently dead.
            if isDefaultScreenshotTool, !ScreenshotHotkeys.hasPermission {
                ScreenshotHotkeys.requestPermission()
            }
            ScreenshotHotkeys.setEnabled(isDefaultScreenshotTool)
            // The Accessibility grant lands in System Settings while we're
            // running — retry the tap whenever the user comes back.
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isDefaultScreenshotTool else { return }
                    ScreenshotHotkeys.setEnabled(true)
                }
            }
        }

        // Open toolbar once per app launch; never again from Dock re-activation.
        // Skip auto-open until onboarding is completed.
        // NEVER in --mcp / headless runs: those are background processes of
        // this same bundle (Claude/Codex spawn one per client), and each one
        // popping its own floating toolbar is how the user ends up with two
        // recording bars on screen (seen live 2026-08-17: four --mcp
        // processes, each showing a toolbar).
        guard !MCPServer.isMCP, !HeadlessRunner.isHeadless else { return }
        guard !Self.suppressAutoToolbar else { return }
        guard !Self.didAutoOpenToolbarThisLaunch else { return }
        guard !needsOnboarding else { return }
        Self.didAutoOpenToolbarThisLaunch = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.beginNewRecording()
        }
    }

    var needsOnboarding: Bool {
        !hasCompletedOnboarding
    }

    var currentAccountEmail: String? {
        _ = authStateRevision
        return authService.currentEmail
    }

    var isSignedIn: Bool {
        _ = authStateRevision
        return authService.currentUser != nil
    }

    func completeOnboarding(acceptedTerms: Bool) {
        hasAcceptedTerms = acceptedTerms
        hasCompletedOnboarding = true

        let defaults = UserDefaults.standard
        defaults.set(acceptedTerms, forKey: DefaultsKey.hasAcceptedTerms)
        defaults.set(true, forKey: DefaultsKey.hasCompletedOnboarding)
    }

    func resetOnboarding() {
        hasAcceptedTerms = false
        hasCompletedOnboarding = false

        let defaults = UserDefaults.standard
        defaults.set(false, forKey: DefaultsKey.hasAcceptedTerms)
        defaults.set(false, forKey: DefaultsKey.hasCompletedOnboarding)
    }

    var availableMicrophones: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    func preferredMicrophoneDeviceID() -> String? {
        guard !availableMicrophones.isEmpty else { return nil }
        let preferred = availableMicrophones.min { lhs, rhs in
            microphonePriority(lhs.localizedName) < microphonePriority(rhs.localizedName)
        }
        return preferred?.uniqueID
    }

    func beginNewRecording() {
        recordingError = nil
        shouldDiscardRecordingAfterStop = false
        pendingRestartRequest = nil
        // Opt in early so connected iPhones/iPads are discoverable by the time
        // the user opens the Device tab (they appear asynchronously).
        DeviceRecorder.enableDeviceDiscovery()

        if selectedCameraDeviceID == nil {
            selectedCameraDeviceID = cameraManager.availableDevices.first?.uniqueID
        }
        if selectedMicrophoneDeviceID == nil {
            selectedMicrophoneDeviceID = preferredMicrophoneDeviceID()
        }

        if recordingSession.isRecording || recordingSession.isPaused {
            panelController.panel?.orderFrontRegardless()
            return
        }

        recordingSession.reset()
        panelController.show(size: RecordingPanelMetrics.setupPanelSize())
    }

    func closeRecordingToolbar() {
        if recordingSession.isRecording || recordingSession.isPaused || isPreparing {
            return
        }
        shouldDiscardRecordingAfterStop = false
        pendingRestartRequest = nil
        panelController.close()
        recordingSession.reset()
    }

    func discardRecordingInProgress() {
        beginStoppingRecording(
            shouldDiscard: true,
            restartRequest: nil
        )
    }

    func restartRecordingInProgress(source: CaptureSource, captureAudio: Bool) {
        beginStoppingRecording(
            shouldDiscard: true,
            restartRequest: (source, captureAudio)
        )
    }

    func stopRecordingInProgress() {
        beginStoppingRecording(
            shouldDiscard: false,
            restartRequest: nil
        )
    }

    private var isPreparing: Bool {
        if case .preparing = recordingSession.phase { return true }
        if case .stopping = recordingSession.phase { return true }
        return false
    }

    private func beginStoppingRecording(
        shouldDiscard: Bool,
        restartRequest: (source: CaptureSource, captureAudio: Bool)?
    ) {
        guard recordingSession.isRecording || recordingSession.isPaused else { return }
        if case .stopping = recordingSession.phase { return }

        shouldDiscardRecordingAfterStop = shouldDiscard
        pendingRestartRequest = restartRequest

        // Stop immediately — no ScreenCaptureKit round-trips first. The app's
        // own windows are already excluded from capture via the application
        // filter, and awaiting SCK here could hang forever with panels already
        // closed, stranding a headless recording.
        Task { @MainActor in
            self.dismissLiveCameraPreviewPanel()
            self.panelController.close()
            guard self.recordingSession.isRecording || self.recordingSession.isPaused else { return }
            self.recordingSession.phase = .stopping
        }
    }

    @MainActor
    private func dismissLiveCameraPreviewPanel() {
        for panel in NSApp.windows.compactMap({ $0 as? NSPanel }) {
            guard panel.identifier == Self.liveCameraPreviewPanelIdentifier else { continue }
            panel.orderOut(nil)
            // Detach the hosting view (and its AVCaptureVideoPreviewLayer) NOW,
            // deterministically — a lazily-released preview layer can deadlock
            // against the capture session teardown that follows.
            panel.contentView = nil
            panel.close()
        }
    }

    func openEditor(with project: Project) {
        currentProject = project
        showProjectBrowser = false
        showEditor = true
        // Actually present the window — callers (project browser, deep links,
        // recording finish) all expect the editor to appear, not just the
        // state flag to flip.
        presentEditorWindow()
    }

    func closeEditor() {
        if let project = currentProject {
            projectStore.saveIfDirty(project)
        }
        currentProject = nil
        showProjectBrowser = false
        showEditor = false
    }

    func showBrowser() {
        if let project = currentProject {
            projectStore.saveIfDirty(project)
        }
        showProjectBrowser = true
    }

    func openProjectBrowser() {
        if let project = currentProject {
            projectStore.saveIfDirty(project)
        }
        currentProject = nil
        showProjectBrowser = true
        showEditor = true

        presentEditorWindow()
    }

    func signOut() throws {
        try authService.signOut()
        showExport = false
    }

    @MainActor
    func signIn() async throws {
        try await authService.signIn(presenting: authPresentationWindow())
    }

    @MainActor
    func authPresentationWindow() -> NSWindow? {
        let windows = NSApplication.shared.windows

        let preferredWindow = windows.first {
            $0.identifier?.rawValue == "editor" &&
            $0.isVisible &&
            !$0.isMiniaturized &&
            !($0 is NSPanel)
        }

        if let preferredWindow {
            return preferredWindow
        }

        let mainWindow = NSApplication.shared.mainWindow
        if let mainWindow, !(mainWindow is NSPanel), mainWindow.isVisible, !mainWindow.isMiniaturized {
            return mainWindow
        }

        let keyWindow = NSApplication.shared.keyWindow
        if let keyWindow, !(keyWindow is NSPanel), keyWindow.isVisible, !keyWindow.isMiniaturized {
            return keyWindow
        }

        return windows.first {
            $0.isVisible &&
            !$0.isMiniaturized &&
            !($0 is NSPanel)
        } ?? keyWindow
    }


    /// Returns true if recording started successfully
    func startRecording(source: CaptureSource, captureAudio: Bool) async -> Bool {
        // Guard against double-start (double-click, concurrent entry points) —
        // a second SCStream/writer would clobber the recorder's state.
        switch recordingSession.phase {
        case .idle, .finished, .failed:
            break
        case .preparing, .recording, .paused, .stopping:
            return false
        }
        recordingSession.phase = .preparing
        recordingError = nil
        shouldDiscardRecordingAfterStop = false
        pendingRestartRequest = nil
        recordedSegments = []
        currentSourceLabel = sourceLabel(for: source)
        if case .window(let window) = source {
            activeRecordingAppBundleID = window.owningApplication?.bundleIdentifier
        } else {
            activeRecordingAppBundleID = nil
        }

        do {
            if panelController.panel == nil {
                panelController.show(size: RecordingPanelMetrics.setupPanelSize())
            }

            // Wait for window to appear in system window list
            try? await Task.sleep(for: .milliseconds(300))

            // Collect our own windows to exclude from capture
            let excludeWindows = await excludedWindows()

            // Prewarm camera session if enabled. Give it a beat so the AVCapture
            // session is producing well-exposed frames *before* recording begins
            // — eliminates the black-sensor-warmup frames that used to land at
            // PTS=0 of the camera asset.
            if recordingSession.isCameraEnabled {
                try? cameraManager.start(deviceID: selectedCameraDeviceID)
                try? await Task.sleep(for: .milliseconds(150))
            }

            // Screen Studio-style countdown on the target screen, then capture
            // starts at exactly 0. Length is user-configurable (Off/3/5/10);
            // `run` no-ops for 0, so Off starts recording immediately.
            await CountdownOverlayController.run(
                on: countdownScreen(for: source),
                seconds: recordingCountdownSeconds
            )

            // Screen Studio approach: define ONE shared host-clock origin and
            // anchor every recorder (screen, camera, cursor) to it. Each asset's
            // PTS = sampleTime − origin, so they all sit on the same timeline
            // by construction. cameraTimeOffset becomes structurally 0.
            let sharedOrigin = CMClockGetTime(CMClockGetHostTimeClock())
            recorder.sharedOriginHostTime = sharedOrigin
            // Always reset the camera origin: a stale origin from a previous
            // take would anchor a mid-recording camera enable to the wrong time.
            cameraManager.sharedOriginHostTime = recordingSession.isCameraEnabled ? sharedOrigin : nil

            if case .iosDevice(let device) = source {
                // iPhone/iPad take — recorded via AVCapture, no SCK, no cursor.
                isDeviceTake = true
                if AVCaptureDevice.authorizationStatus(for: .video) != .authorized {
                    _ = await AVCaptureDevice.requestAccess(for: .video)
                }
                deviceRecorder.sharedOriginHostTime = sharedOrigin
                try deviceRecorder.startRecording(
                    device: device,
                    sharedOrigin: sharedOrigin,
                    microphoneDeviceID: selectedMicrophoneDeviceID,
                    captureMicrophone: recordingSession.isMicEnabled
                )
                if recordingSession.isCameraEnabled {
                    cameraManager.startRecording()
                }
                await deviceRecorder.waitForSessionStart()
            } else {
                isDeviceTake = false
                try await recorder.startRecording(
                    source: source,
                    excludingWindows: excludeWindows,
                    captureAudio: captureAudio,
                    captureMicrophone: recordingSession.isMicEnabled,
                    microphoneDeviceID: selectedMicrophoneDeviceID
                )

                if recordingSession.isCameraEnabled {
                    cameraManager.startRecording()
                }
                await recorder.waitForSessionStart(timeout: 1.0)

                // Refresh excluded windows to catch any late-appearing panels
                try? await Task.sleep(for: .milliseconds(200))
                await recorder.refreshExcludedWindows()

                // Anchor the input timeline to the shared origin directly — if the
                // first frame took >1s to arrive, `sessionStartHostTimeSeconds` is
                // still nil and the clock would fall back to "now", shifting every
                // cursor event and keystroke late. Resolved ONCE, into ONE clock:
                // both trackers then read the same origin object.
                recordingClock.restart(
                    originHostTimeSeconds: recorder.sessionStartHostTimeSeconds
                        ?? CMTimeGetSeconds(sharedOrigin)
                )
                // Pass the rect the recorder actually captured. For a window
                // that is the shadow-free content rect, which is smaller than
                // SCWindow.frame — mapping against the frame put every recorded
                // position up and to the left of the pixels it described.
                cursorTracker.start(
                    for: source,
                    clock: recordingClock,
                    capturedContentRect: recorder.capturedContentRect
                )
                // Keyboard timing capture (category-only unless the user
                // opted into the shortcut overlay; silently inert without
                // Input Monitoring permission).
                keystrokeTracker.start(
                    clock: recordingClock,
                    capturingShortcuts: recordingSession.isShortcutCaptureEnabled
                )
            }
            recordingSession.phase = .recording
            recordingSession.startTimer()

            observeRecordingState()
            return true
        } catch {
            recordingSession.phase = .failed(error.localizedDescription)
            recordingError = error.localizedDescription
            return false
        }
    }

    /// Find SCWindows that belong to our app so we can exclude them from capture
    private func excludedWindows() async -> [SCWindow] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
            return []
        }
        let myPID = ProcessInfo.processInfo.processIdentifier
        return content.windows.filter { $0.owningApplication?.processID == myPID }
    }

    private func observeRecordingState() {
        recordingObserverTask = Task {
            var wasPaused = false
            var wasMicEnabled = recordingSession.isMicEnabled
            var wasCameraEnabled = recordingSession.isCameraEnabled
            var wasMicrophoneDeviceID = selectedMicrophoneDeviceID
            while true {
                try? await Task.sleep(for: .milliseconds(100))
                if case .stopping = recordingSession.phase {
                    break
                }
                let isPaused = recordingSession.isPaused
                if isPaused && !wasPaused {
                    recorder.pause()
                    deviceRecorder.pause()
                    cursorTracker.pause()
                    keystrokeTracker.pause()
                    cameraManager.pause()
                } else if !isPaused && wasPaused {
                    recorder.resume()
                    deviceRecorder.resume()
                    cursorTracker.resume()
                    keystrokeTracker.resume()
                    cameraManager.resume()
                }
                wasPaused = isPaused

                let isMicEnabled = recordingSession.isMicEnabled
                if isMicEnabled != wasMicEnabled {
                    try? await recorder.setMicrophone(enabled: isMicEnabled, deviceID: selectedMicrophoneDeviceID)
                    wasMicEnabled = isMicEnabled
                }

                let microphoneDeviceID = selectedMicrophoneDeviceID
                if microphoneDeviceID != wasMicrophoneDeviceID {
                    try? await recorder.setMicrophone(enabled: recordingSession.isMicEnabled, deviceID: microphoneDeviceID)
                    wasMicrophoneDeviceID = microphoneDeviceID
                }

                // Camera toggle mid-recording
                let isCameraEnabled = recordingSession.isCameraEnabled
                if isCameraEnabled != wasCameraEnabled {
                    if isCameraEnabled {
                        // Mid-recording enable: anchor to the first camera sample
                        // (not a shared origin from recording start) so
                        // cameraTimeOffset reflects when the camera actually began.
                        cameraManager.sharedOriginHostTime = nil
                        // Refresh exclusions immediately to catch the preview panel
                        await recorder.refreshExcludedWindows()
                        try? cameraManager.start(deviceID: selectedCameraDeviceID)
                        cameraManager.startRecording()
                        // Refresh again after panel is fully registered
                        try? await Task.sleep(for: .milliseconds(100))
                        await recorder.refreshExcludedWindows()
                    } else {
                        cameraManager.stopRecording()
                        cameraManager.stop()
                        // The partial take won't be attached to the project —
                        // don't leave it orphaned on disk.
                        if let cameraURL = cameraManager.recordingURL {
                            try? FileManager.default.removeItem(at: cameraURL)
                        }
                        if let posterURL = cameraManager.posterURL {
                            try? FileManager.default.removeItem(at: posterURL)
                        }
                    }
                    wasCameraEnabled = isCameraEnabled
                }
            }

            // Stop recording
            recordingSession.stop()
            cursorTracker.stop()
            keystrokeTracker.stop()
            await MainActor.run {
                self.dismissLiveCameraPreviewPanel()
            }
            if cameraManager.isRecording {
                cameraManager.stopRecording()
            }
            if cameraManager.isRunning {
                cameraManager.stop()
            }
            // Finalize the active segment into the ordered list.
            if isDeviceTake {
                await deviceRecorder.stopRecording()
                if let url = deviceRecorder.outputURL {
                    recordedSegments.append(RecordingSegment(url: url, kind: .device))
                }
            } else {
                try? await recorder.stopRecording()
                if let url = recorder.outputURL {
                    recordedSegments.append(RecordingSegment(url: url, kind: recorder.recordingSourceKind))
                }
            }
            let segments = recordedSegments
            recordedSegments = []

            let shouldDiscard = shouldDiscardRecordingAfterStop
            let restartRequest = pendingRestartRequest
            shouldDiscardRecordingAfterStop = false
            pendingRestartRequest = nil
            if shouldDiscard {
                for segment in segments {
                    try? FileManager.default.removeItem(at: segment.url)
                }
                if let cameraURL = cameraManager.recordingURL {
                    try? FileManager.default.removeItem(at: cameraURL)
                }
                if let cameraPosterURL = cameraManager.posterURL {
                    try? FileManager.default.removeItem(at: cameraPosterURL)
                }
                if let restartRequest {
                    _ = await startRecording(
                        source: restartRequest.source,
                        captureAudio: restartRequest.captureAudio
                    )
                    return
                }
                await MainActor.run {
                    recordingSession.reset()
                    panelController.show(size: RecordingPanelMetrics.setupPanelSize())
                }
                return
            }

            // Resolve the final video: single segment as-is, multiple segments
            // stitched into one continuous movie (source switches mid-take).
            let videoURL: URL
            let sourceKind: RecordingSourceKind
            var stitchedSourceSegments: [ProjectSourceSegment] = []
            if segments.count > 1 {
                let stitchTarget = recordingsDirectory
                    .appendingPathComponent("capturecat_recording_\(UUID().uuidString).mov")
                let inputs = segments.map { RecordingStitcher.InputSegment(url: $0.url, kind: $0.kind) }
                if let result = try? await RecordingStitcher.stitch(inputs, outputURL: stitchTarget) {
                    videoURL = result.url
                    stitchedSourceSegments = result.segments
                    for segment in segments {
                        try? FileManager.default.removeItem(at: segment.url)
                    }
                } else {
                    // Stitch failed — salvage the first segment rather than lose the take.
                    videoURL = segments[0].url
                }
                // Mixed takes are never whole-project device takes — segment
                // metadata drives per-range device framing instead.
                sourceKind = .display
            } else if let only = segments.first {
                videoURL = only.url
                sourceKind = only.kind
            } else {
                return
            }

            // Save cursor data (screen takes only — no Mac cursor on a device)
            var cursorURL: URL?
            var keystrokeURL: URL?
            if sourceKind != .device {
                let url = videoURL.deletingPathExtension().appendingPathExtension("cursor.json")
                try? cursorTracker.save(to: url)
                cursorURL = url
                if !keystrokeTracker.events.isEmpty {
                    let keysURL = videoURL.deletingPathExtension().appendingPathExtension("keys.json")
                    try? keystrokeTracker.save(to: keysURL)
                    keystrokeURL = keysURL
                }
            }

            // Create project — include camera URL if camera was recorded
            let cameraURL = recordingSession.isCameraEnabled ? cameraManager.recordingURL : nil
            let cameraTimeOffset: TimeInterval = {
                guard recordingSession.isCameraEnabled,
                      let cameraStart = cameraManager.recordingStartHostTimeSeconds,
                      let screenStart = recorder.sessionStartHostTimeSeconds else {
                    return 0
                }
                // Positive = camera started later than screen timeline.
                // Negative = camera started slightly earlier and should be trimmed forward.
                return cameraStart - screenStart
            }()
            let recordedDuration: TimeInterval
            let asset = AVURLAsset(url: videoURL)
            if let duration = try? await asset.load(.duration) {
                let seconds = duration.seconds
                if seconds.isFinite, seconds > 0 {
                    recordedDuration = seconds
                } else {
                    recordedDuration = recordingSession.elapsedTime
                }
            } else {
                recordedDuration = recordingSession.elapsedTime
            }
            let project = Project(
                videoURL: videoURL,
                cursorDataURL: cursorURL,
                cameraVideoURL: cameraURL,
                cameraTimeOffset: cameraTimeOffset,
                duration: recordedDuration,
                recordingSourceKind: sourceKind
            )
            project.keystrokeDataURL = keystrokeURL
            if sourceKind == .window {
                project.recordedAppBundleID = activeRecordingAppBundleID
            }
            project.sourceSegments = stitchedSourceSegments
            project.settings.showCamera = cameraURL != nil
            // User-chosen default wallpaper for new projects (applied here,
            // not in Project.init, so harness fixtures stay deterministic).
            CustomWallpaperStore.applyDefaultBackground(to: project.settings)

            // Move media files into self-contained project folder
            projectStore.moveMediaIntoProjectFolder(project)

            // "Auto-zoom. No editing required." — generate the camera plan
            // from the recorded clicks/keystrokes before the first save, so
            // the editor opens on an already-zoomed timeline. Device takes
            // have no Mac cursor and are skipped by the nil cursorDataURL
            // guard inside the applier.
            if autoZoomNewRecordings {
                AutoZoomApplier.apply(to: project)
            }

            projectStore.save(project)
            projectStore.generateThumbnail(for: project)

            // UI operations must run on the main actor
            await MainActor.run {
                panelController.close()
                recordingSession.phase = .finished(videoURL)
                showProjectBrowser = false
                openEditor(with: project)
                onRecordingFinished?(project)
                captureTextIndex.scheduleIndex(projectID: project.id)
            }
        }
    }

    /// ⇧⌘3 as default screenshot tool: instant still of the main display,
    /// opened in the editor via the same still-to-movie path every other
    /// screenshot takes (no special cases downstream).
    @MainActor
    func captureFullScreenScreenshot() {
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: true)
                let mainID = CGMainDisplayID()
                guard let display = content.displays.first(where: { $0.displayID == mainID })
                        ?? content.displays.first else { return }
                guard let image = try await ScreenStillCapture.capture(.display(display)) else { return }
                let movie = FileManager.default.temporaryDirectory
                    .appendingPathComponent("capturecat-shot-\(UUID().uuidString).mp4")
                let size = try await StillMovieWriter.write(image: image, to: movie)
                openWebCapture(movieURL: movie, pixelSize: size, sourceURL: nil)
            } catch {
                recordingError = error.localizedDescription
            }
        }
    }

    /// Turns a captured web page into a project and opens the editor.
    ///
    /// Deliberately goes through the SAME path a recording does — move media
    /// into the project folder, save, thumbnail, open — so a screenshot is an
    /// ordinary project from here on and gets zooms, annotations, device frames
    /// and export with no special cases.
    @MainActor
    func openWebCapture(movieURL: URL, pixelSize: CGSize, sourceURL: URL?) {
        let project = Project(
            videoURL: movieURL,
            duration: StillMovieWriter.defaultDuration,
            recordingSourceKind: .display
        )
        if let host = sourceURL?.host {
            // Name it after the site rather than "Recording 12" — the whole
            // point of this flow is that you know what you captured.
            project.name = host.replacingOccurrences(of: "www.", with: "")
        }
        // Still capture — classified as "Image" in the browser.
        project.isStillCapture = true
        // A page screenshot has no cursor track and no camera, and a device
        // frame around a desktop-width page would be nonsense.
        project.settings.showCamera = false
        project.settings.showDeviceFrame = false
        CustomWallpaperStore.applyDefaultBackground(to: project.settings)

        projectStore.moveMediaIntoProjectFolder(project)
        projectStore.save(project)
        projectStore.generateThumbnail(for: project)

        panelController.close()
        showProjectBrowser = false
        openEditor(with: project)
        captureTextIndex.scheduleIndex(projectID: project.id)
    }

    /// Mid-recording source switch (desktop → iPhone → another display …):
    /// finalizes the active segment, rolls straight into a new recorder, and
    /// keeps the camera/timer clocks continuous via the pause bookkeeping.
    /// Segments are stitched into one movie when the recording stops.
    func switchRecordingSource(to newSource: CaptureSource) {
        guard recordingSession.isRecording, !isSwitchingSource else { return }
        Task { @MainActor in
            await performSourceSwitch(to: newSource)
        }
    }

    @MainActor
    private func performSourceSwitch(to newSource: CaptureSource) async {
        guard recordingSession.isRecording, !isSwitchingSource else { return }
        isSwitchingSource = true
        defer { isSwitchingSource = false }

        // Freeze all clocks during the swap so the stitched (gapless) video
        // stays aligned with the camera overlay and the visible timer.
        recordingSession.pause()
        cameraManager.pause()
        cursorTracker.pause()
        keystrokeTracker.pause()

        // Finalize the active segment.
        if isDeviceTake {
            await deviceRecorder.stopRecording()
            if let url = deviceRecorder.outputURL {
                recordedSegments.append(RecordingSegment(url: url, kind: .device))
            }
        } else {
            try? await recorder.stopRecording()
            if let url = recorder.outputURL {
                recordedSegments.append(RecordingSegment(url: url, kind: recorder.recordingSourceKind))
            }
        }

        // Cursor coordinate mapping is bound to the original source — stop
        // collecting after the first switch (only segment 1 gets cursor FX).
        // Keystrokes stop with it: mixing segment-1 cursor effects with
        // whole-take keystrokes would desync the keyboard sounds.
        cursorTracker.stop()
        keystrokeTracker.stop()

        // Roll into the next segment on a fresh clock origin.
        let origin = CMClockGetTime(CMClockGetHostTimeClock())
        do {
            if case .iosDevice(let device) = newSource {
                isDeviceTake = true
                if AVCaptureDevice.authorizationStatus(for: .video) != .authorized {
                    _ = await AVCaptureDevice.requestAccess(for: .video)
                }
                deviceRecorder.sharedOriginHostTime = origin
                try deviceRecorder.startRecording(
                    device: device,
                    sharedOrigin: origin,
                    microphoneDeviceID: selectedMicrophoneDeviceID,
                    captureMicrophone: recordingSession.isMicEnabled
                )
                await deviceRecorder.waitForSessionStart()
            } else {
                isDeviceTake = false
                recorder.sharedOriginHostTime = origin
                let excludeWindows = await excludedWindows()
                try await recorder.startRecording(
                    source: newSource,
                    excludingWindows: excludeWindows,
                    captureAudio: captureSystemAudio,
                    captureMicrophone: recordingSession.isMicEnabled,
                    microphoneDeviceID: selectedMicrophoneDeviceID
                )
                await recorder.waitForSessionStart(timeout: 1.0)
            }
        } catch {
            recordingError = "Couldn't switch source: \(error.localizedDescription)"
        }

        cameraManager.resume()
        recordingSession.resume()
        currentSourceLabel = sourceLabel(for: newSource)
    }

    private func countdownScreen(for source: CaptureSource) -> NSScreen? {
        switch source {
        case .display(let display), .area(let display, _):
            return NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
            } ?? NSScreen.main
        case .window, .iosDevice:
            return NSScreen.main
        }
    }

    private func microphonePriority(_ name: String) -> Int {
        let normalized = name.lowercased()
        if normalized.contains("macbook") || normalized.contains("built-in") || normalized.contains("internal") {
            return 0
        }
        if normalized.contains("iphone") {
            return 3
        }
        return 1
    }

}
