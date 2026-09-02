import AVFoundation
import AppKit
import Observation

// MARK: - Shared shell state

/// Selection + chrome state the shell owns — the values the toolbar, the stage,
/// the inspector column and the timeline all read.
@MainActor
@Observable
final class EditorShellSelection {
    var inspectorTab: InspectorTab = .background
    var showInspector = true
    var selectedHighlightID: UUID?
    var selectedTiltID: UUID?
    var selectedZoomID: UUID?
    var selectedAnnotationID: UUID?
    /// The Slide chip on the EFFECTS lane is selected (it is settings, not a
    /// region, so it has no UUID) — drives its focus ring.
    var selectedDepthFocusID: UUID?
    /// Selected blur region (FOCUS lane / canvas) — drives the Blur inspector
    /// section, like highlight/depth-focus.
    var selectedBlurID: UUID?
    var introSelected = false
    /// The Curtain Unveil chip on the EFFECTS lane is selected (settings, not
    /// a region, so it has no UUID) — drives its focus ring.
    var curtainSelected = false
    var previewZoom: CGFloat = 1.0
}

// MARK: - Window content switcher

/// Picks onboarding / project browser / editor shell and swaps the child
/// controller as `AppState` changes.
@MainActor
final class EditorWindowContentViewController: NSViewController {
    private let appState: AppState
    private var observation: SurfaceObservation?
    private var current: NSViewController?
    private var currentKey: String = ""
    private var themeObservation: CCThemeObservation?
    /// The editor's in-content top bar while the editor is the current child.
    private var editorTopBar: NSView?

    init(appState: AppState) {
        self.appState = appState
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        view = root
        themeObservation = CCThemeObservation { [weak self] in
            self?.view.layer?.backgroundColor = EditorThemeKit.windowBackground.cgColor
        }

        observation = SurfaceObservation { [weak self] in
            guard let self else { return }
            let onboarding = self.appState.needsOnboarding
            let browser = self.appState.showProjectBrowser
            let project = self.appState.currentProject
            let reloadToken = self.appState.editorReloadToken
            self.apply(onboarding: onboarding, browser: browser, project: project, reloadToken: reloadToken)
        }
    }

    private func apply(onboarding: Bool, browser: Bool, project: Project?, reloadToken: Int) {
        let key: String
        if onboarding {
            key = "onboarding"
        } else if browser || project == nil {
            key = "browser"
        } else {
            // reloadToken: an external (MCP) edit replaces currentProject with
            // a fresh instance under the same id — the token bump forces the
            // shell to rebuild on the reloaded project.
            key = "editor:\(project!.id.uuidString):\(reloadToken)"
        }
        guard key != currentKey else { return }
        currentKey = key

        let next: NSViewController
        switch key {
        case "onboarding": next = OnboardingViewController(appState: appState)
        case "browser": next = ProjectBrowserViewController(appState: appState)
        default: next = EditorShellViewController(appState: appState, project: project!)
        }

        if let current {
            current.view.removeFromSuperview()
            current.removeFromParent()
        }
        editorTopBar?.removeFromSuperview()
        editorTopBar = nil
        addChild(next)
        next.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(next.view)
        // The editor gets the house top bar pinned above its shell — an
        // in-content HeaderChromeView, never an NSToolbar (no system Liquid
        // Glass, house rule). Browser and onboarding stay full-bleed; they
        // draw their own headers.
        if let shell = next as? EditorShellViewController {
            let bar = shell.topBarView
            bar.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(bar)
            editorTopBar = bar
            NSLayoutConstraint.activate([
                bar.topAnchor.constraint(equalTo: view.topAnchor),
                bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                bar.heightAnchor.constraint(equalToConstant: 52),
                next.view.topAnchor.constraint(equalTo: bar.bottomAnchor),
            ])
        } else {
            next.view.topAnchor.constraint(equalTo: view.topAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            next.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            next.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            next.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        current = next

        // Only the editor puts a toolbar on the window; the browser and
        // onboarding draw their own in-content headers.
        if let window = view.window {
            (next as? EditorShellViewController)?.installToolbar(on: window)
            if !(next is EditorShellViewController) { window.toolbar = nil }
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if let window = view.window {
            if let shell = current as? EditorShellViewController {
                shell.installToolbar(on: window)
            } else {
                window.toolbar = nil
            }
        }
    }

    /// The view the window should focus. The editor's keyboard surface
    /// (space-to-play, timeline hotkeys) is SwiftUI `.focusable()` state inside
    /// the hosted timeline — focusing the plain container view would starve it,
    /// which is exactly the failure AppKit P1 hit with the whole editor.
    var focusTarget: NSView? {
        (current as? EditorShellViewController)?.focusTarget ?? current?.view
    }
}

// MARK: - Editor shell

/// The editor window shell: toolbar + [ stage over timeline | inspector ].
///
/// Layout metrics are lifted verbatim from `EditorShellView.stageContent`:
/// stage padding 14/10/4 (h/top/bottom), timeline padding 14/8/12, inspector
/// column 340…480 (ideal 380), stage card radius `panelRadius` with a 1 px
/// hairline border and a bottom-trailing zoom pill inset 10.
@MainActor
final class EditorShellViewController: NSSplitViewController {
    /// Optional so the `--editor-shell-shot` probe can build the real shell
    /// without spinning up a full `AppState` (which starts a recording).
    private let appState: AppState?
    private let project: Project
    // Internal, not private: the `--editor-shell-shot` harness drives these to
    // assert the behaviours a screenshot cannot show (inspector collapse,
    // focus target, close/reopen player lifecycle).
    let playback: EditorPlaybackController
    let selection = EditorShellSelection()

    private var stageController: EditorStageViewController!
    private(set) var inspectorItem: NSSplitViewItem!
    private var toolbarController: EditorToolbarController!
    // Internal, not private: `--editor-shell-shot` asserts the reveal tab
    // appears when the inspector (column + icon rail) is fully hidden.
    private(set) var revealTab: InspectorRevealTab!

    /// Session persistence for the hidden inspector — UserDefaults, no model
    /// change (enum raw values / Codable untouched).
    static let inspectorVisibleDefaultsKey = "EditorInspectorVisible"

    private var selectionObservation: SurfaceObservation?
    private var playbackObservation: SurfaceObservation?
    private var pendingSeekObservation: SurfaceObservation?
    private var autoSaveObservation: EditorAutoSaveObserver?
    private var themeObservation: CCThemeObservation?

    // Change-detection mirrors for the observation loops (the AppKit twin of
    // `.onChange(of:)`).
    private var lastShowInspector = true
    private var lastHighlightID: UUID?
    private var lastDepthFocusID: UUID?
    private var lastBlurRegionID: UUID?
    private var lastTiltID: UUID?
    private var lastZoomID: UUID?
    private var lastAnnotationID: UUID?
    private var lastShowCamera: Bool
    private var lastMuted: Bool
    private var lastTrimStart: TimeInterval
    private var lastTrimEnd: TimeInterval
    private var lastAudioSignature: String
    private var lastVideoClipSignature: String
    private var lastVoiceOverSignature: String
    private var lastCurrentTime: Double = -1
    private var lastIsPlaying = false

    init(appState: AppState?, project: Project) {
        self.appState = appState
        self.project = project
        self.playback = EditorPlaybackController(appState: appState)
        self.lastShowCamera = project.settings.showCamera
        self.lastMuted = project.settings.muteRecordedAudio
        self.lastTrimStart = project.trimStart
        self.lastTrimEnd = project.trimEnd
        self.lastAudioSignature = ""
        self.lastVideoClipSignature = ""
        self.lastVoiceOverSignature = ""
        super.init(nibName: nil, bundle: nil)
        self.lastAudioSignature = audioSignature
        self.lastVideoClipSignature = playback.videoClipSignature(for: project)
        self.lastVoiceOverSignature = playback.voiceOverSignature(for: project)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var audioSignature: String {
        "\(project.settings.systemAudioVolume)|\(project.settings.microphoneVolume)|\(project.settings.voiceOverVolume)"
    }

    override func loadView() {
        // NSSplitViewController builds its own view; give it the flat slab so
        // no system material shows through at the divider.
        super.loadView()
        view.wantsLayer = true
        themeObservation = CCThemeObservation { [weak self] in
            self?.view.layer?.backgroundColor = EditorThemeKit.windowBackground.cgColor
        }
        splitView.dividerStyle = .thin
        splitView.isVertical = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        stageController = EditorStageViewController(
            project: project,
            playback: playback,
            selection: selection,
            onToggleVoiceOverRecording: { [weak self] in
                guard let self else { return }
                Task { @MainActor in await self.playback.toggleVoiceOverRecording(for: self.project) }
            }
        )
        let contentItem = NSSplitViewItem(viewController: stageController)
        contentItem.minimumThickness = 420
        contentItem.canCollapse = false
        contentItem.holdingPriority = .init(rawValue: 249)
        addSplitViewItem(contentItem)

        let inspectorController = EditorInspectorViewController(
            project: project,
            playback: playback,
            selection: selection
        )
        // A PLAIN split item, not `inspectorWithViewController:` — the system
        // inspector item wraps the view in its own chrome, and on macOS 26
        // that chrome draws a Liquid-Glass hairline around the column while
        // the window is key (the user-visible "ghost border" that vanished on
        // deactivate). Like NSToolbar's glass, it has no opt-out; a plain
        // trailing item keeps the collapse animation (`animator().isCollapsed`)
        // and drag-to-resize with zero system chrome.
        inspectorItem = NSSplitViewItem(viewController: inspectorController)
        // `.inspectorColumnWidth(min: 340, ideal: 380, max: 480)`.
        //
        // The item rests at the hosted column's 353 pt fitting width, which is
        // EXACTLY the width the SwiftUI inspector column renders at too — in
        // the SwiftUI shell that 353 sits inside a 380 pt region with a 13.5 pt
        // band of system inspector material on each side (verified by pixel
        // scan in `--editor-shell-shot`). The native item has no bands, so the
        // panel is flush and the stage is 27 pt wider. Attempts to force the
        // region to 380 (setPosition / preferredContentSize / a seeded width
        // constraint) are all overridden or fatal under NSSplitViewController —
        // and the bands are the very "system inspector material" InspectorView
        // was written to hide, so flush is the truer result.
        inspectorItem.minimumThickness = 340
        inspectorItem.maximumThickness = 480
        inspectorItem.canCollapse = true
        // Full-height layout, the inspector-item default. With it FALSE,
        // NSSplitViewController physically insets the item's view below the
        // window's (transparent, fullSizeContentView) titlebar — measured 32pt
        // in the shot probe — even though the whole split view already sits
        // below the 52pt in-content top bar, so the inspector card started a
        // titlebar-height lower than the preview card in the real window. The
        // old harness hosted the shell at the window top, where BOTH columns
        // happened to shift, so the misalignment never reproduced there.
        inspectorItem.allowsFullHeightLayout = true
        inspectorItem.holdingPriority = .init(rawValue: 260)
        addSplitViewItem(inspectorItem)

        toolbarController = EditorToolbarController(
            project: project,
            onShowBrowser: { [weak self] in self?.appState?.showBrowser() },
            onExport: { [weak self] in self?.appState?.showExport = true },
            onToggleInspector: { [weak self] in
                guard let self else { return }
                self.selection.showInspector.toggle()
            }
        )

        // Reveal tab — the discoverable "bring the sidebar back" affordance.
        // With the inspector (column + icon rail) fully hidden, a slim
        // house-styled grabber hugs the window's right edge; clicking it
        // re-shows the sidebar. The toolbar toggle and ⌥⌘I still work — this
        // strip just means re-opening never depends on remembering either.
        revealTab = InspectorRevealTab { [weak self] in
            self?.setInspectorVisible(true)
        }
        revealTab.translatesAutoresizingMaskIntoConstraints = false
        revealTab.isHidden = true
        view.addSubview(revealTab)
        NSLayoutConstraint.activate([
            revealTab.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            revealTab.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        startObserving()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if let window = view.window {
            installToolbar(on: window)
            // Window state restoration can bring the editor back with the
            // inspector collapsed — restore the user's last explicit choice
            // (per-session UserDefaults; defaults to visible).
            let stored = UserDefaults.standard
                .object(forKey: Self.inspectorVisibleDefaultsKey) as? Bool
            selection.showInspector = stored ?? true
        }
        // `.task(id: project.id)` semantics: set up on appear, tear down on
        // disappear. The editor window is order-out-on-close and reused, so
        // setting the player up once in viewDidLoad would leave it dead after
        // the first close/reopen.
        startPlaybackIfNeeded()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        playback.teardown(saving: project)
        isStartingPlayback = false
    }

    func installToolbar(on window: NSWindow) {
        toolbarController.install(on: window)
    }

    /// Single entry point for every inspector show/hide path (toolbar button,
    /// ⌥⌘I, reveal tab) — the observation loop below animates the split
    /// collapse and persists the choice.
    func setInspectorVisible(_ visible: Bool) {
        selection.showInspector = visible
    }

    /// View ▸ Toggle Inspector (⌥⌘I) — nil-targeted, resolved through the
    /// responder chain to whichever editor shell owns the key window.
    @objc func toggleInspectorFromMenu(_ sender: Any?) {
        setInspectorVisible(!selection.showInspector)
    }

    /// The in-content top bar (see EditorToolbarController) — the window
    /// content controller pins it above this shell.
    var topBarView: NSView { toolbarController.barView }

    var focusTarget: NSView? { stageController?.timelineFocusView }

    // MARK: - Playback wiring (the AppKit twin of EditorView's onChange chain)

    private var isStartingPlayback = false

    private func startPlaybackIfNeeded() {
        guard playback.player == nil, !isStartingPlayback else { return }
        isStartingPlayback = true
        // Consume the one-shot pending seek HERE, as the player's
        // initialTime, not via a scrub racing the load. The old consumer
        // (timeline viewDidAppear → scrub) ran while the player was still
        // nil/loading: the scrub wrote currentTime, then setupPlayer reset
        // it to trimStart and the first-frame warm-up re-anchored there —
        // the search/deep-link seek silently vanished. As initialTime the
        // target IS the start position, so the ready-wait and warm-up
        // preserve it by construction. Covers cold-open and browser→editor
        // (both build a fresh shell).
        var initialTime: TimeInterval?
        if let appState, let pending = appState.pendingSeekOutputTime {
            appState.pendingSeekOutputTime = nil
            initialTime = sourceTime(forPendingOutput: pending)
            print("[Seek] consuming pendingSeekOutputTime=\(pending) → source=\(initialTime!) at player load")
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.playback.setupPlayer(for: self.project, initialTime: initialTime)
            self.isStartingPlayback = false
        }
    }

    /// Output-time → source-time for this project — the same trim+speed map
    /// the timeline/share paths use (see TimelineViewController.fullTimeMap).
    private func sourceTime(forPendingOutput output: TimeInterval) -> TimeInterval {
        let map = SpeedTimeMap(
            sourceStart: project.effectiveTrimStart,
            sourceEnd: max(project.effectiveTrimStart, project.effectiveTrimEnd),
            regions: project.speedRegions
        )
        let clamped = min(max(0, output), map.outputDuration)
        return map.sourceTime(forOutput: clamped)
    }

    /// A pending seek that arrives while THIS editor is already open (deep
    /// link to the currently open project): wait for readiness, let the
    /// first-frame warm-up's re-anchor settle, then scrub exactly.
    private func consumeLatePendingSeek(_ pending: TimeInterval) {
        let source = sourceTime(forPendingOutput: pending)
        print("[Seek] consuming late pendingSeekOutputTime=\(pending) → source=\(source)")
        Task { @MainActor [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(5)
            while self.playback.player?.currentItem?.status != .readyToPlay, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            try? await Task.sleep(for: .milliseconds(250))
            self.playback.scrub(to: source, for: self.project, exact: true)
        }
    }

    private func startObserving() {
        if let projectStore = appState?.projectStore {
            autoSaveObservation = EditorAutoSaveObserver(project: project, projectStore: projectStore)
        }

        // Seeks set while this editor is ALREADY open (deep link to the
        // currently open project) — the load path consumes via
        // setupPlayer(initialTime:) in startPlaybackIfNeeded instead.
        pendingSeekObservation = SurfaceObservation { [weak self] in
            guard let self, let appState = self.appState else { return }
            guard let pending = appState.pendingSeekOutputTime else { return }
            guard self.playback.player != nil else { return }
            appState.pendingSeekOutputTime = nil
            self.consumeLatePendingSeek(pending)
        }

        selectionObservation = SurfaceObservation { [weak self] in
            guard let self else { return }
            let show = self.selection.showInspector
            let highlight = self.selection.selectedHighlightID
            let depthFocus = self.selection.selectedDepthFocusID
            let blurRegion = self.selection.selectedBlurID
            let tilt = self.selection.selectedTiltID
            let zoom = self.selection.selectedZoomID
            let annotation = self.selection.selectedAnnotationID

            if show != self.lastShowInspector {
                self.lastShowInspector = show
                self.inspectorItem.animator().isCollapsed = !show
                UserDefaults.standard.set(show, forKey: Self.inspectorVisibleDefaultsKey)
            }
            // The reveal tab exists exactly when the sidebar does not.
            self.revealTab?.isHidden = show
            if highlight != self.lastHighlightID {
                self.lastHighlightID = highlight
                if highlight != nil { self.selection.inspectorTab = .effects; self.selection.showInspector = true }
            }
            if depthFocus != self.lastDepthFocusID {
                self.lastDepthFocusID = depthFocus
                if depthFocus != nil { self.selection.inspectorTab = .effects; self.selection.showInspector = true }
            }
            if blurRegion != self.lastBlurRegionID {
                self.lastBlurRegionID = blurRegion
                if blurRegion != nil { self.selection.inspectorTab = .effects; self.selection.showInspector = true }
            }
            if tilt != self.lastTiltID {
                self.lastTiltID = tilt
                if tilt != nil { self.selection.inspectorTab = .effects; self.selection.showInspector = true }
            }
            if zoom != self.lastZoomID {
                self.lastZoomID = zoom
                if zoom != nil { self.selection.inspectorTab = .effects; self.selection.showInspector = true }
            }
            if annotation != self.lastAnnotationID {
                self.lastAnnotationID = annotation
                if annotation != nil { self.selection.inspectorTab = .annotations; self.selection.showInspector = true }
            }
        }

        playbackObservation = SurfaceObservation { [weak self] in
            guard let self else { return }
            let project = self.project
            // Reads that register the observation — mirrors of every
            // `.onChange(of:)` EditorView installs.
            let muted = project.settings.muteRecordedAudio
            let audio = self.audioSignature
            let trimStart = project.trimStart
            let trimEnd = project.trimEnd
            let clipSignature = self.playback.videoClipSignature(for: project)
            let voiceSignature = self.playback.voiceOverSignature(for: project)
            let showCamera = project.settings.showCamera
            let time = self.playback.currentTime
            let playing = self.playback.isPlaying

            if muted != self.lastMuted {
                self.lastMuted = muted
                self.playback.player?.isMuted = muted
                Task { @MainActor in await self.playback.applyAudioMix(for: project) }
            }
            if audio != self.lastAudioSignature {
                self.lastAudioSignature = audio
                Task { @MainActor in await self.playback.applyAudioMix(for: project) }
            }
            if trimStart != self.lastTrimStart || trimEnd != self.lastTrimEnd {
                self.lastTrimStart = trimStart
                self.lastTrimEnd = trimEnd
                self.playback.syncPlaybackToTrimRange(for: project)
            }
            if clipSignature != self.lastVideoClipSignature {
                self.lastVideoClipSignature = clipSignature
                Task { @MainActor in
                    await self.playback.rebuildPlayback(
                        for: project,
                        preserveTime: self.playback.currentTime,
                        resumePlayback: self.playback.isPlaying
                    )
                }
            }
            if voiceSignature != self.lastVoiceOverSignature {
                self.lastVoiceOverSignature = voiceSignature
                self.playback.scheduleVoiceOverRefresh(for: project)
            }
            if showCamera != self.lastShowCamera {
                self.lastShowCamera = showCamera
                self.playback.setCameraEnabled(showCamera, for: project)
            }
            if time != self.lastCurrentTime {
                self.lastCurrentTime = time
                self.playback.syncCameraPlaybackIfNeeded(for: project)
            }
            if playing != self.lastIsPlaying {
                self.lastIsPlaying = playing
                if !playing, self.playback.isRecordingVoiceOver {
                    Task { @MainActor in
                        await self.playback.stopVoiceOverRecording(for: project, discard: false, resumePlayback: false)
                    }
                }
                self.playback.updatePlaybackState(for: project, playing: playing)
            }
        }
    }
}

// MARK: - Inspector reveal tab

/// Slim grabber hugging the window's right edge while the inspector is
/// hidden — panel surface, hairline, chevron, hover wash (house flat design;
/// no stock chrome). Clicking re-shows the sidebar.
@MainActor
final class InspectorRevealTab: NSView {
    private let onClick: () -> Void
    private let chevron = NSImageView()
    private var hovered = false { didSet { refresh() } }
    private var themeObservation: CCThemeObservation?

    init(onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        // Flush against the trailing edge — round only the exposed left pair.
        layer?.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        layer?.borderWidth = 1
        toolTip = "Show Inspector (⌥⌘I)"

        chevron.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Show Inspector")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        chevron.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevron)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 18),
            heightAnchor.constraint(equalToConstant: 64),
            chevron.centerXAnchor.constraint(equalTo: centerXAnchor),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        themeObservation = CCThemeObservation { [weak self] in self?.refresh() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func refresh() {
        layer?.backgroundColor = (hovered ? EditorThemeKit.hoverFill : EditorThemeKit.panel).cgColor
        layer?.borderColor = EditorThemeKit.hairline.cgColor
        chevron.contentTintColor = hovered ? EditorThemeKit.textPrimary : EditorThemeKit.textSecondary
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { onClick() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

// MARK: - Top bar

/// The editor's top bar — an in-content HeaderChromeView, NOT an NSToolbar.
/// It was an NSToolbar until 2026-08-17; on macOS 26 NSToolbar wraps custom
/// items in Liquid Glass capsules with no opt-out, and the house rule is
/// absolute: no system glass, flat CCKit chrome only (same pattern as the
/// browser's header). The bar draws in the window's transparent-titlebar
/// region, insets past the traffic lights, and drags/zooms the window like
/// every Mac title bar.
@MainActor
final class EditorToolbarController: NSObject {
    /// The bar itself; the window content controller pins it to the top.
    let barView = HeaderChromeView()

    private let project: Project
    private let onShowBrowser: () -> Void
    private let onExport: () -> Void
    private let onToggleInspector: () -> Void
    // Kit controls in the title bar (user call 2026-08-17: the hand-rolled
    // capsule pills read as foreign chrome — every switcher is CCKit now).
    // macOS 26 wraps adjacent toolbar items in ONE Liquid Glass capsule with
    // no opt-out, so both controls live in a single cluster item: plain-
    // chrome kit controls separated by a hairline, letting the system
    // capsule be the only box — the Safari-style grouped pill.
    private let aspectSelect = CCSelect(placeholder: "Aspect", size: .sm, chrome: .plain)
    private let treatmentSwitch: CCSegmented
    private let controlsCluster = NSStackView()
    private let clusterDivider = CCDivider(vertical: true)
    private var aspectObservation: SurfaceObservation?
    private var treatmentObservation: SurfaceObservation?

    init(
        project: Project,
        onShowBrowser: @escaping () -> Void,
        onExport: @escaping () -> Void,
        onToggleInspector: @escaping () -> Void
    ) {
        self.project = project
        self.onShowBrowser = onShowBrowser
        self.onExport = onExport
        self.onToggleInspector = onToggleInspector
        treatmentSwitch = CCSegmented(
            segments: ["Image", "Video"],
            selectedIndex: project.stillTreatment == .image ? 0 : 1,
            size: .sm,
            chrome: .plain
        )
        super.init()

        treatmentSwitch.onChange = { [weak project] index in
            project?.stillTreatment = index == 0 ? .image : .video
        }
        treatmentObservation = SurfaceObservation { [weak self, weak project] in
            guard let self, let project else { return }
            self.treatmentSwitch.selectedIndex = project.stillTreatment == .image ? 0 : 1
        }

        let ratios = AspectRatio.allCases
        aspectSelect.minTriggerWidth = 84
        aspectSelect.options = ratios.map { .init(title: $0.rawValue, subtitle: $0.platformHint) }
        aspectSelect.onSelect = { [weak project] index in
            project?.settings.aspectRatio = ratios[index]
        }
        aspectObservation = SurfaceObservation { [weak self, weak project] in
            guard let self, let project else { return }
            self.aspectSelect.selectedIndex = ratios.firstIndex(of: project.settings.aspectRatio)
        }

        controlsCluster.orientation = .horizontal
        controlsCluster.alignment = .centerY
        controlsCluster.spacing = CCSpace.sm
        controlsCluster.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)
        // Recordings keep only the aspect select; the treatment switch and
        // its divider exist for still captures.
        if project.isImageCapture {
            controlsCluster.addArrangedSubview(treatmentSwitch)
            clusterDivider.heightAnchor.constraint(equalToConstant: 14).isActive = true
            controlsCluster.addArrangedSubview(clusterDivider)
        }
        controlsCluster.addArrangedSubview(aspectSelect)
        buildBar()
    }

    private let titleLabel = NSTextField(labelWithString: "")
    private var titleObservation: SurfaceObservation?
    private var themeObservation: CCThemeObservation?

    /// Bar layout: [⌗ captures] [title] …[Image|Video │ 16:9]… [Export] [◧].
    /// Centering the cluster is a preference (450); the required gaps to its
    /// neighbours win as the window narrows.
    private func buildBar() {
        // Labeled, not icon-only: getting back to the captures browser is the
        // editor's one navigation exit, and a bare glyph made it easy to miss
        // (user call 2026-08-26 — same discoverability pass as the inspector
        // reveal tab).
        let captures = CCButton(title: "Captures", symbol: "square.grid.2x2", style: .ghost, size: .regular) { [weak self] in
            self?.onShowBrowser()
        }
        captures.toolTip = "Browse Captures (⌘O)"

        titleLabel.lineBreakMode = .byTruncatingTail

        let exportButton = CCButton(title: "Export…", style: .primary, size: .sm) { [weak self] in
            self?.onExport()
        }
        let inspector = CCButton(symbol: "sidebar.right", style: .ghost, size: .regular) { [weak self] in
            self?.onToggleInspector()
        }
        inspector.toolTip = "Toggle Inspector"

        for view in [captures, titleLabel, controlsCluster, exportButton, inspector] {
            view.translatesAutoresizingMaskIntoConstraints = false
            barView.addSubview(view)
        }
        let clusterCenter = controlsCluster.centerXAnchor.constraint(equalTo: barView.centerXAnchor)
        clusterCenter.priority = NSLayoutConstraint.Priority(450)
        NSLayoutConstraint.activate([
            // Past the traffic lights the transparent titlebar leaves in place.
            captures.leadingAnchor.constraint(equalTo: barView.leadingAnchor, constant: 84),
            captures.centerYAnchor.constraint(equalTo: barView.centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: captures.trailingAnchor, constant: CCSpace.sm),
            titleLabel.centerYAnchor.constraint(equalTo: barView.centerYAnchor),

            clusterCenter,
            controlsCluster.leadingAnchor.constraint(
                greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: CCSpace.lg),
            controlsCluster.trailingAnchor.constraint(
                lessThanOrEqualTo: exportButton.leadingAnchor, constant: -CCSpace.lg),
            controlsCluster.centerYAnchor.constraint(equalTo: barView.centerYAnchor),

            inspector.trailingAnchor.constraint(equalTo: barView.trailingAnchor, constant: -CCSpace.md),
            inspector.centerYAnchor.constraint(equalTo: barView.centerYAnchor),
            exportButton.trailingAnchor.constraint(equalTo: inspector.leadingAnchor, constant: -CCSpace.sm),
            exportButton.centerYAnchor.constraint(equalTo: barView.centerYAnchor),
        ])
        themeObservation = CCThemeObservation { [weak self] in
            self?.titleLabel.font = CCTheme.font.header
            self?.titleLabel.textColor = CCTheme.color.foreground
        }
    }

    /// No NSToolbar — ever (house rule). The window keeps its transparent
    /// titlebar; the bar lives in content. Window title still tracks renames
    /// for Mission Control / the Window menu.
    func install(on window: NSWindow) {
        window.toolbar = nil
        titleObservation = SurfaceObservation { [weak self, weak window] in
            guard let self, let window else { return }
            window.title = self.project.name
            self.titleLabel.stringValue = self.project.name
        }
    }
}

// MARK: - Stage + timeline

/// `EditorShellView.stageContent` as AppKit: the preview card (with the zoom
/// pill) above the timeline container.
@MainActor
final class EditorStageViewController: NSViewController {
    private let project: Project
    private let playback: EditorPlaybackController
    private let selection: EditorShellSelection
    private let onToggleVoiceOverRecording: () -> Void

    private let card = NSView()
    private let scroll = ZoomScrollView()
    private var previewSurface: NSView!
    private var compositor: PreviewCompositorView?
    private let zoomPill = PreviewZoomPill()
    private let annotationPill = AnnotationToolbarPill()
    // Default docking (bottom center) vs contextual (floated above the
    // selected annotation, iOS-edit-menu style). Exactly one pair is active.
    private var pillCenterDefault: NSLayoutConstraint!
    private var pillBottomDefault: NSLayoutConstraint!
    private var pillCenterContextual: NSLayoutConstraint!
    private var pillBottomContextual: NSLayoutConstraint!
    private var timelineController: TimelineViewController!

    /// Focus lands on the timeline's root view — the single first responder
    /// that owns the panel's keyboard handling.
    var timelineFocusView: NSView? { timelineController?.view }

    private var previewObservation: SurfaceObservation?
    private var zoomObservation: SurfaceObservation?
    private var aspectObservation: SurfaceObservation?
    private var themeObservation: CCThemeObservation?

    init(
        project: Project,
        playback: EditorPlaybackController,
        selection: EditorShellSelection,
        onToggleVoiceOverRecording: @escaping () -> Void
    ) {
        self.project = project
        self.playback = playback
        self.selection = selection
        self.onToggleVoiceOverRecording = onToggleVoiceOverRecording
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        view = root

        // ── Preview card ──────────────────────────────────────────────────
        card.wantsLayer = true
        card.layer?.cornerRadius = EditorThemeKit.panelRadius
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true
        // No hairline: with the card painting the panel surface, an outline
        // reads as a ghost border around the content (user feedback).
        card.layer?.borderWidth = 0
        card.translatesAutoresizingMaskIntoConstraints = false
        // Chrome only — the compositor's canvas inside the card is CONTENT
        // and never re-themes. The card gets the PANEL surface, not the
        // window background: the letterboxed canvas leaves bars inside the
        // card, and window-colored bars read as a second frame (a dark moat
        // between the hairline and the render). Panel-colored bars are
        // visually part of the panel — one level of framing.
        themeObservation = CCThemeObservation { [weak self] in
            guard let self else { return }
            self.view.layer?.backgroundColor = EditorThemeKit.windowBackground.cgColor
            self.card.layer?.backgroundColor = EditorThemeKit.panel.cgColor
        }
        root.addSubview(card)

        let compositorView = PreviewCompositorView(frame: .zero)
        compositorView.onSelectHighlight = { [weak self] in self?.selection.selectedHighlightID = $0 }
        compositorView.onSelectDepthFocus = { [weak self] in self?.selection.selectedDepthFocusID = $0 }
        compositorView.onSelectBlurRegion = { [weak self] in self?.selection.selectedBlurID = $0 }
        compositorView.onSelectAnnotation = { [weak self] in self?.selection.selectedAnnotationID = $0 }
        compositorView.onSetZoomFocal = { [weak self] point in
            guard let self,
                  let id = self.selection.selectedZoomID,
                  let index = self.project.zoomRegions.firstIndex(where: { $0.id == id })
            else { return }
            self.project.zoomRegions[index].focalPoint = point
            // Aiming the shot by hand means the aim must hold: fixed focus.
            self.project.zoomRegions[index].followsCursor = false
        }
        compositorView.onCanvasDragEnded = { [weak self] in
            self?.repositionAnnotationPill()
        }
        compositorView.onCreateBlurRegion = { [weak self] rect, style in
            self?.timelineController?.createBlurRegion(rect: rect, style: style)
        }
        compositor = compositorView
        previewSurface = compositorView

        // NSScrollView magnification scales the rendered content while the
        // document view keeps its unscaled bounds, so `project.previewCanvasSize`
        // stays the card size exactly.
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.25
        scroll.maxMagnification = 4.0
        // The titlebar inset must not shrink the clip view — the preview canvas
        // is the card, exactly.
        scroll.automaticallyAdjustsContentInsets = false
        // Letterboxed canvas: the compositor keeps the PROJECT's aspect
        // (Auto = the source video's), centered in the card — the canvas the
        // user edits on is exactly the frame the exporter ships.
        let centeringClip = CenteringClipView()
        centeringClip.drawsBackground = false
        scroll.contentView = centeringClip
        scroll.documentView = previewSurface
        scroll.canvasAspectProvider = { [weak self] in
            guard let self else { return nil }
            let settings = self.project.settings
            let output = settings.exportSettings.resolvedOutputSize(
                for: settings.aspectRatio, sourceSize: self.playback.videoSize)
            guard output.width > 0, output.height > 0 else { return nil }
            return output.width / output.height
        }
        // Re-letterbox when the aspect setting, export resolution or the
        // source size changes.
        aspectObservation = SurfaceObservation { [weak self] in
            guard let self else { return }
            _ = self.project.settings.aspectRatio
            _ = self.project.settings.exportSettings.resolution
            _ = self.project.settings.exportSettings.customWidth
            _ = self.project.settings.exportSettings.customHeight
            _ = self.playback.videoSize
            self.scroll.needsLayout = true
        }
        card.addSubview(scroll)

        // Zoom pill — bottom trailing, inset 10 (sibling of the card so the
        // card's corner mask can never clip it).
        zoomPill.translatesAutoresizingMaskIntoConstraints = false
        zoomPill.onZoomOut = { [weak self] in self?.stepZoom(-1) }
        zoomPill.onZoomIn = { [weak self] in self?.stepZoom(1) }
        zoomPill.onReset = { [weak self] in self?.selection.previewZoom = 1.0 }
        root.addSubview(zoomPill)

        // Annotation pill — bottom center, same sibling-of-the-card treatment
        // as the zoom pill so the card's corner mask can never clip it.
        annotationPill.translatesAutoresizingMaskIntoConstraints = false
        annotationPill.onColorChange = { [weak self] color in
            self?.timelineController?.applyToolbarColor(color)
        }
        annotationPill.colorProvider = { [weak self] in
            self?.timelineController?.toolbarCurrentColor() ?? .white
        }
        annotationPill.backgroundColorProvider = { [weak self] in
            self?.timelineController?.toolbarCurrentBackgroundColor() ?? .black
        }
        annotationPill.onBackgroundColorChange = { [weak self] color in
            self?.timelineController?.applyToolbarBackgroundColor(color)
        }
        annotationPill.onFontChange = { [weak self] name in
            self?.timelineController?.applyToolbarFont(name)
        }
        annotationPill.onWeightChange = { [weak self] weight in
            self?.timelineController?.applyToolbarWeight(weight)
        }
        annotationPill.onBackgroundToggle = { [weak self] in
            self?.timelineController?.toggleToolbarBackground()
        }
        annotationPill.onSizeChange = { [weak self] value in
            self?.timelineController?.applyToolbarSize(value)
        }
        root.addSubview(annotationPill)
        pillCenterDefault = annotationPill.centerXAnchor.constraint(equalTo: card.centerXAnchor)
        pillBottomDefault = annotationPill.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10)
        pillCenterContextual = annotationPill.centerXAnchor.constraint(equalTo: card.leadingAnchor)
        pillBottomContextual = annotationPill.bottomAnchor.constraint(equalTo: card.topAnchor)
        NSLayoutConstraint.activate([pillCenterDefault, pillBottomDefault])

        // ── Timeline ──────────────────────────────────────────────────────
        timelineController = TimelineViewController(
            project: project,
            playback: playback,
            selection: selection,
            onToggleVoiceOverRecording: onToggleVoiceOverRecording
        )
        // Fresh text/callout lands straight in the in-place editor.
        timelineController.onArmBlurDraw = { [weak self] style in
            self?.compositor?.armBlurDraw(style: style)
        }
        timelineController.onBeginInlineEdit = { [weak self] id in
            self?.compositor?.beginInlineTextEdit(annotationID: id)
        }
        addChild(timelineController)
        let timelinePanel = timelineController.view
        timelinePanel.translatesAutoresizingMaskIntoConstraints = false
        // `sizingOptions = [.intrinsicContentSize]` has no NSView equivalent —
        // `TimelineRootView.intrinsicContentSize` plays that role, and the card
        // above still derives its height from this panel's.
        timelinePanel.setContentHuggingPriority(.required, for: .vertical)
        timelinePanel.setContentCompressionResistancePriority(.required, for: .vertical)
        root.addSubview(timelinePanel)

        NSLayoutConstraint.activate([
            // .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
            card.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            card.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            // topAnchor, NOT safeAreaLayoutGuide: the shell always sits below
            // the 52pt in-content top bar (EditorWindowContentViewController),
            // so no titlebar ever overlaps it. Safe-area anchors here caused
            // the real-window misalignment — NSSplitViewController gives the
            // inspector item (allowsFullHeightLayout=false) a titlebar
            // safe-area inset computed from the WINDOW's transparent titlebar
            // while the stage item's actual overlap is 0, so the two cards'
            // tops disagreed by the titlebar height in the real app only.
            card.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),

            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: card.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: card.bottomAnchor),

            zoomPill.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            zoomPill.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),

            // (annotation pill constraints are managed below — two docking
            // modes, see repositionAnnotationPill.)

            // VStack(spacing: 0): stage bottom 4 + timeline top 8 = 12 pt gap
            timelinePanel.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 12),
            // Side padding stays 14 as before; only the BOTTOM bleeds into
            // the window edge with square bottom corners.
            timelinePanel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            timelinePanel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            timelinePanel.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        startObserving()
    }

    private static let zoomSteps: [CGFloat] = [0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 4.0]

    private func stepZoom(_ direction: Int) {
        let zoom = selection.previewZoom
        if direction > 0 {
            if let next = Self.zoomSteps.first(where: { $0 > zoom }) { selection.previewZoom = next }
        } else {
            if let prev = Self.zoomSteps.last(where: { $0 < zoom }) { selection.previewZoom = prev }
        }
    }

    private func startObserving() {
        zoomObservation = SurfaceObservation { [weak self] in
            guard let self else { return }
            let zoom = self.selection.previewZoom
            self.scroll.magnification = zoom
            self.scroll.hasHorizontalScroller = zoom > 1
            self.scroll.hasVerticalScroller = zoom > 1
            self.scroll.scrollingEnabled = zoom > 1
            self.zoomPill.update(
                zoom: zoom,
                canZoomOut: zoom > (Self.zoomSteps.first ?? 0.25),
                canZoomIn: zoom < (Self.zoomSteps.last ?? 4.0)
            )
        }

        guard let compositor else { return }
        previewObservation = SurfaceObservation { [weak self] in
            guard let self else { return }
            // Re-derive the cursor path if the smoothing settings moved. Reading
            // them here also registers them with the observation, so toggling
            // "Smooth cursor" repaints immediately instead of on next open.
            self.playback.applyCursorSmoothing(
                settings: self.project.settings,
                trimEnd: self.project.effectiveTrimEnd)
            let showCameraOverlay = self.playback.showCameraOverlay(for: self.project)
            // Blur chrome renders from the compositor's preview-local ID;
            // reading the SHARED ID here (which also registers it with this
            // observation) keeps regions selected from outside the canvas —
            // drag-drawn, timeline lane, inspector — showing chrome too.
            compositor.syncBlurSelection(self.selection.selectedBlurID)
            compositor.schedule(PreviewCompositorView.FrameInput(
                project: self.project,
                currentTime: self.playback.currentTime,
                isPlaying: self.playback.isPlaying,
                isScrubbing: self.playback.isScrubbing,
                cursorEvents: self.playback.cursorEvents,
                scrollTimes: self.playback.keystrokeEvents.lazy
                    .filter { $0.category == .scroll }.map(\.timestamp).sorted(),
                keystrokeEvents: self.playback.keystrokeEvents,
                cursorCoordinateSize: self.playback.cursorCoordinateSize,
                videoSize: self.playback.videoSize,
                player: self.playback.player,
                cameraPlayer: showCameraOverlay ? self.playback.cameraPlayer : nil,
                cameraPosterImage: self.project.settings.showCamera ? self.playback.cameraPosterImage : nil,
                cameraVideoAspect: self.playback.cameraVideoAspect,
                videoPosterImage: self.playback.videoPosterImage,
                selectedAnnotationID: self.selection.selectedAnnotationID,
                selectedHighlightID: self.selection.selectedHighlightID,
                selectedBlurID: compositor.localSelectedBlurID,
                selectedDepthFocusID: self.selection.selectedDepthFocusID,
                selectedZoomID: self.selection.selectedZoomID
            ))
            // Reading selectedAnnotationID above also registered it with this
            // observation, so selection changes re-run us and the pill follows.
            self.repositionAnnotationPill()
        }
    }

    /// iOS-edit-menu placement: with an annotation selected the pill floats
    /// just above it (below it when it hugs the top edge); with nothing
    /// selected it docks bottom-center as the add toolbar.
    private func repositionAnnotationPill() {
        guard let compositor else { return }
        // The pill is EDITING chrome: hidden during playback AND while a drag
        // is in flight (Keynote behaviour — and per-mouse-move toolbar layout
        // is exactly the work dragging must never pay).
        if playback.isPlaying || compositor.isDraggingOnCanvas {
            annotationPill.isHidden = true
            return
        }

        // Contextual ONLY: no selection, no pill. Adding annotations lives in
        // the timeline toolbar's popover — a permanently docked toolbar over
        // the preview was chrome the video paid for full-time.
        guard let rect = compositor.selectedAnnotationViewRect(),
              let annotation = timelineController?.toolbarSelectedAnnotation() else {
            annotationPill.isHidden = true
            pillCenterContextual.isActive = false
            pillBottomContextual.isActive = false
            pillCenterDefault.isActive = true
            pillBottomDefault.isActive = true
            return
        }
        annotationPill.isHidden = false
        // Per-type properties; no-op when nothing displayed has changed.
        annotationPill.configure(with: annotation)

        // Compositor coords → card coords, then top-down offsets (autolayout
        // anchor constants are top-down regardless of either view's isFlipped).
        let rc = card.convert(rect, from: compositor)
        let topDownTop = card.isFlipped ? rc.minY : card.bounds.height - rc.maxY
        let topDownBottom = card.isFlipped ? rc.maxY : card.bounds.height - rc.minY

        let pillSize = annotationPill.fittingSize
        let gap: CGFloat = 10
        // Above the annotation; below it when there is no headroom.
        let bottomConstant: CGFloat
        if topDownTop - gap - pillSize.height >= 8 {
            bottomConstant = topDownTop - gap
        } else {
            bottomConstant = min(card.bounds.height - 8, topDownBottom + gap + pillSize.height)
        }
        // Clamp horizontally so the pill never leaves the card.
        let half = pillSize.width / 2
        let cx = min(max(rc.midX, half + 8), max(half + 8, card.bounds.width - half - 8))

        pillCenterDefault.isActive = false
        pillBottomDefault.isActive = false
        pillCenterContextual.constant = cx
        pillBottomContextual.constant = bottomConstant
        pillCenterContextual.isActive = true
        pillBottomContextual.isActive = true
    }
}

/// NSScrollView that ignores scroll/magnify gestures at 1× — the AppKit twin
/// of `.scrollDisabled(previewZoom <= 1)` — and keeps its document view exactly
/// the size of the card.
///
/// The size must come from `layout()`, not the owning controller's
/// `viewDidLayout`: the card's height is derived from the timeline's intrinsic
/// height, which settles in a later pass, and a stale document size leaks
/// straight into `project.previewCanvasSize` (a shared preview↔export
/// contract). SwiftUI sized the preview to `geo.size` and let `scaleEffect`
/// do the zoom — magnification here does the same, so the document size is
/// deliberately independent of the magnification level.
final class ZoomScrollView: NSScrollView {
    var scrollingEnabled = false

    /// The width/height aspect the preview canvas must keep — the project's
    /// aspect-ratio setting resolved against the source video (see
    /// `AspectRatio.canvasAspect`). The document view (the compositor, whose
    /// bounds ARE `project.previewCanvasSize`) is letterboxed to this aspect
    /// inside the card so the editor shows exactly the exported framing.
    /// nil = fill the card (pre-aspect behavior, used only when unset).
    var canvasAspectProvider: (() -> CGFloat?)?

    override func scrollWheel(with event: NSEvent) {
        guard scrollingEnabled else { return }
        super.scrollWheel(with: event)
    }

    override func layout() {
        super.layout()
        guard let document = documentView, bounds.width > 0, bounds.height > 0 else { return }
        let size: CGSize
        if let aspect = canvasAspectProvider?() {
            size = AspectRatio.letterboxRect(
                in: CGRect(origin: .zero, size: bounds.size), aspect: aspect).size
        } else {
            size = bounds.size
        }
        if document.frame.size != size {
            document.setFrameSize(size)
        }
    }
}

/// Clip view that centers a document smaller than itself — the letterboxed
/// preview canvas must sit in the middle of the card, but a stock NSClipView
/// pins an undersized document to a corner.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var constrained = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return constrained }
        let doc = document.frame
        if doc.width < constrained.width {
            constrained.origin.x = doc.minX - (constrained.width - doc.width) / 2
        }
        if doc.height < constrained.height {
            constrained.origin.y = doc.minY - (constrained.height - doc.height) / 2
        }
        return constrained
    }
}

/// The zoom controls pill: `[-] 100% [+]` in a capsule, 6/4 padding, spacing 2.
@MainActor
final class PreviewZoomPill: NSView {
    var onZoomOut: (() -> Void)?
    var onZoomIn: (() -> Void)?
    var onReset: (() -> Void)?

    private let minus = CaptureCatButton(title: "", symbol: "minus.magnifyingglass", style: .quiet, height: 20, horizontalPadding: 1)
    private let plus = CaptureCatButton(title: "", symbol: "plus.magnifyingglass", style: .quiet, height: 20, horizontalPadding: 1)
    private let percent = CaptureCatButton(title: "100%", style: .quiet, height: 20, horizontalPadding: 5)

    private var themeObservation: CCThemeObservation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Borderless like the stage card — surface color IS the framing.
        layer?.borderWidth = 0
        themeObservation = CCThemeObservation { [weak self] in
            self?.layer?.backgroundColor = EditorThemeKit.panelElevated.cgColor
        }

        let out = minus
        out.onClick = { [weak self] in self?.zoomOut() }
        out.keyEquivalent = "-"
        out.keyEquivalentModifierMask = .command
        let into = plus
        into.onClick = { [weak self] in self?.zoomIn() }
        into.keyEquivalent = "="
        into.keyEquivalentModifierMask = .command

        percent.onClick = { [weak self] in self?.reset() }
        percent.toolTip = "Reset zoom to 100%"
        percent.translatesAutoresizingMaskIntoConstraints = false
        percent.widthAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true

        let stack = NSStackView(views: [out, percent, into])
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        minusButton = out
        plusButton = into
        update(zoom: 1, canZoomOut: true, canZoomIn: true)
    }

    private var minusButton: CaptureCatButton!
    private var plusButton: CaptureCatButton!

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    func update(zoom: CGFloat, canZoomOut: Bool, canZoomIn: Bool) {
        percent.title = "\(Int(zoom * 100))%"
        minusButton?.isEnabled = canZoomOut
        plusButton?.isEnabled = canZoomIn
    }

    @objc private func zoomOut() { onZoomOut?() }
    @objc private func zoomIn() { onZoomIn?() }
    @objc private func reset() { onReset?() }
}

// MARK: - Inspector column

/// Hosts `InspectorColumnAppKit` directly — rail, scroll, and all eight panes
/// are native.
///
/// This used to go through `NSHostingView` → `InspectorView` →
/// `InspectorColumnBridge` to reach the same column. The SwiftUI layer existed
/// only to turn `@State` into `Binding`s; `InspectorPaneContexts` builds the
/// same accessors natively, and a `withObservationTracking` re-arm pushes
/// updates where `updateNSView` used to.
@MainActor
final class EditorInspectorViewController: NSViewController {
    private let project: Project
    private let playback: EditorPlaybackController
    private let selection: EditorShellSelection

    private var column: InspectorColumnAppKit!
    private let panel = NSView()
    private var contextObservation: SurfaceObservation?
    private var themeObservation: CCThemeObservation?

    init(project: Project, playback: EditorPlaybackController, selection: EditorShellSelection) {
        self.project = project
        self.playback = playback
        self.selection = selection
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        view = root
        // The inspector is a CARD, matching the stage's preview card: same
        // top inset (safeArea + 10), same panelRadius/hairline family, and —
        // like the timeline panel — a square bottom that meets the window
        // edge. Without it the column rendered as a full-bleed slab whose
        // top and bottom never lined up with the left side (the user-visible
        // "cut off" inspector).
        panel.wantsLayer = true
        panel.layer?.cornerRadius = EditorThemeKit.panelRadius
        panel.layer?.cornerCurve = .continuous
        // Root is not flipped, so MaxY corners are the TOP pair — round the
        // top like the preview card, keep the bottom square like the timeline.
        panel.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        panel.layer?.masksToBounds = true
        // Borderless, matching the stage card: the panel surface against the
        // window background IS the framing — a hairline here read as a ghost
        // border (user feedback, twice).
        panel.layer?.borderWidth = 0
        panel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(panel)
        themeObservation = CCThemeObservation { [weak self] in
            guard let self else { return }
            self.view.layer?.backgroundColor = EditorThemeKit.windowBackground.cgColor
            self.panel.layer?.backgroundColor = EditorThemeKit.panel.cgColor
        }

        column = InspectorColumnAppKit(
            project: project,
            motionContext: motionContext(),
            annotateContext: annotateContext(),
            onSelectTab: { [weak self] in self?.selection.inspectorTab = $0 }
        )
        column.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(column)
        NSLayoutConstraint.activate([
            // Stage card: top+10, trailing 14 off the window edge; timeline:
            // bottom flush. The stage's own 14 pt trailing padding plus the
            // split divider is the gap on our leading side. topAnchor, not
            // safeAreaLayoutGuide — see the stage card's constraint: the
            // shell always sits below the in-content top bar, and safe-area
            // anchors made the inspector card start a titlebar-height lower
            // than the preview card in the real (fullSizeContentView) window.
            panel.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            panel.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            panel.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            column.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            column.topAnchor.constraint(equalTo: panel.topAnchor),
            column.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            // The column's own fitting width is 353, and NSSplitViewController
            // sizes the item to that — without this floor the inspector region
            // would be 353 and the stage 27 pt wider than intended.
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 380),
        ])

        // Re-arms on every change to the tab and the selected region/annotation
        // IDs — the reads below are what register those dependencies, exactly
        // as the bridge's `updateNSView` did.
        contextObservation = SurfaceObservation { [weak self] in
            guard let self else { return }
            let tab = self.selection.inspectorTab
            _ = self.selection.selectedHighlightID
            _ = self.selection.selectedDepthFocusID
            _ = self.selection.selectedBlurID
            _ = self.selection.selectedTiltID
            _ = self.selection.selectedZoomID
            _ = self.selection.selectedAnnotationID
            self.column.update(
                selectedTab: tab,
                motionContext: self.motionContext(),
                annotateContext: self.annotateContext(),
                onSelectTab: { [weak self] in self?.selection.inspectorTab = $0 }
            )
        }
    }

    private func motionContext() -> MotionPaneContext {
        InspectorPaneContexts.motion(
            project: project,
            selection: selection,
            undoManager: view.window?.undoManager,
            currentTime: { [weak playback] in playback?.currentTime ?? 0 }
        )
    }

    private func annotateContext() -> AnnotatePaneContext {
        InspectorPaneContexts.annotate(
            selection: selection,
            currentTime: playback.currentTime,
            undoManager: view.window?.undoManager
        )
    }
}

// MARK: - Autosave

/// The AppKit twin of `AutoSaveModifier` — the same fields and the same
/// signature strings, scheduled through the same `ProjectStore`. The first
/// observation pass is priming only (SwiftUI's `.onChange` does not fire on
/// appear either).
@MainActor
final class EditorAutoSaveObserver {
    private let project: Project
    private let onDirty: () -> Void
    private var observation: SurfaceObservation?
    private var primed = false
    private var last: String = ""

    convenience init(project: Project, projectStore: ProjectStore) {
        self.init(project: project) { [weak project] in
            guard let project else { return }
            projectStore.scheduleAutoSave(for: project)
        }
    }

    /// `onDirty` is injected so `--editor-shell-shot` can assert the priming
    /// and change behaviour without writing to the user's project store.
    init(project: Project, onDirty: @escaping () -> Void) {
        self.project = project
        self.onDirty = onDirty
        observation = SurfaceObservation { [weak self] in
            guard let self else { return }
            let snapshot = self.snapshot()
            defer { self.last = snapshot }
            guard self.primed else { self.primed = true; return }
            guard snapshot != self.last else { return }
            self.onDirty()
        }
    }

    /// Full persisted-state signature: encoding the project reads every
    /// Codable field, so the observation re-arms on ALL of them and any
    /// mutation that would change project.json marks it dirty. This must stay
    /// exhaustive — close/quit saves are dirty-gated now (saveIfDirty), so a
    /// field the signature misses would never persist.
    private func snapshot() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        if let data = try? encoder.encode(project) {
            return String(decoding: data, as: UTF8.self)
        }
        return legacySnapshot()
    }

    private func legacySnapshot() -> String {
        let s = project.settings
        var parts: [String] = [
            // AutoSaveVisualModifier
            "\(s.backgroundType)", "\(s.backgroundImagePath ?? "")", "\(s.backgroundPadding)",
            "\(s.cornerRadius)", "\(s.windowCornerRadius)", "\(s.showCursor)", "\(s.cursorScale)",
            "\(s.showCamera)", "\(s.cameraPosition)", "\(s.cameraMirrored)",
            // AutoSaveDataModifier
            "\(s.cameraSize)", "\(s.aspectRatio)", "\(s.systemAudioVolume)", "\(s.microphoneVolume)",
            "\(s.voiceOverVolume)", "\(s.animationSpeed)", "\(s.autoZoomLevel)", "\(s.showSubtitles)",
            // AutoSaveEditsModifier
            "\(project.trimStart)", "\(project.trimEnd)", "\(project.subtitles.count)",
            // Image | Video treatment tab (still captures) — the choice must
            // survive a relaunch, so flipping it dirties the project.
            "\(project.stillTreatment)",
        ]
        parts.append(project.zoomRegions.map {
            "\($0.id.uuidString):\($0.startTime):\($0.endTime):\($0.zoomLevel):\($0.focalPoint.x):\($0.focalPoint.y)"
        }.joined(separator: "|"))
        parts.append(project.tiltRegions.map {
            "\($0.id.uuidString):\($0.startTime):\($0.endTime):\($0.pitch):\($0.yaw):\($0.roll)"
        }.joined(separator: "|"))
        parts.append(project.blurRegions.map {
            "\($0.id.uuidString):\($0.startTime):\($0.endTime):\($0.rect.origin.x):\($0.rect.origin.y):\($0.rect.width):\($0.rect.height):\($0.intensity)"
        }.joined(separator: "|"))
        parts.append(project.highlightRegions.map {
            "\($0.id.uuidString):\($0.startTime):\($0.endTime):\($0.rect.origin.x):\($0.rect.origin.y):\($0.rect.width):\($0.rect.height):\($0.opacity)"
        }.joined(separator: "|"))
        parts.append(project.voiceOverClips.map {
            "\($0.id.uuidString):\($0.fileName):\($0.startTime):\($0.sourceStartTime):\($0.duration):\($0.sourceDuration):\($0.gain)"
        }.joined(separator: "|"))
        parts.append(project.speedRegions.map {
            "\($0.id.uuidString):\($0.startTime):\($0.endTime):\($0.speed)"
        }.joined(separator: "|"))
        parts.append(project.videoClipSegments.map {
            "\($0.id.uuidString):\($0.startTime):\($0.endTime)"
        }.joined(separator: "|") + "#" + project.splitPoints.map { String($0) }.joined(separator: ","))
        parts.append(project.annotations.map {
            "\($0.id.uuidString):\($0.startTime):\($0.endTime):\($0.x):\($0.y):\($0.text)"
        }.joined(separator: "|"))
        parts.append(project.subtitles.map {
            "\($0.id.uuidString):\($0.startTime):\($0.endTime):\($0.text)"
        }.joined(separator: "|"))
        return parts.joined(separator: "§")
    }
}
