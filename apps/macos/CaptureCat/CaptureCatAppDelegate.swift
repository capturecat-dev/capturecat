import AppKit
import Sparkle

/// AppKit application shell (Phase 1 of the AppKit conversion). Owns the app
/// lifecycle, main menu, status item, and windows; all window CONTENT is the
/// existing SwiftUI hosted unchanged. Boot order: flag guard → AppState →
/// Sparkle (gated off for headless/MCP) → headless/MCP start. Auth needs no
/// boot step of its own any more — AppState's AuthService restores the session
/// from the Keychain on construction.
@MainActor
final class CaptureCatAppDelegate: NSObject, NSApplicationDelegate {
    let appState: AppState
    let updaterController: SPUStandardUpdaterController

    private var deepLinkHandler: DeepLinkHandler?
    /// Services-menu provider ("Capture Text in CaptureCat") + clipboard-note
    /// fallback. Retained here; NSApp.servicesProvider is unowned.
    private var textCaptureService: TextCaptureService?
    private var automationBridge: AutomationBridge?
    private var statusItem: NSStatusItem?
    private var editorWindowController: NSWindowController?
    private var onboardingWindowController: NSWindowController?
    private var settingsWindowController: SettingsWindowController?
    /// The main-menu Account menu, matched by identity in menuNeedsUpdate
    /// (its title is localized, so it can't be compared).
    private weak var accountMenu: NSMenu?
    private let isUtilityRun = HeadlessRunner.isHeadless || MCPServer.isMCP
    /// Held for the updater's lifetime — Sparkle keeps only a weak reference.
    private static let updateFeedDelegate = UpdateFeedDelegate()

    override init() {
        // A stray/unknown --flag means someone is on the CLI expecting help —
        // print usage and exit instead of launching the GUI at them.
        HeadlessRunner.handleUnknownFlags()
        appState = AppState()
        updaterController = SPUStandardUpdaterController(
            // Headless/MCP runs must not kick off Sparkle update checks.
            startingUpdater: !HeadlessRunner.isHeadless && !MCPServer.isMCP,
            // Selects the appcast matching this build's architecture. Without
            // it every Intel Mac auto-updates to the arm64 DMG.
            updaterDelegate: CaptureCatAppDelegate.updateFeedDelegate,
            userDriverDelegate: nil
        )
        super.init()
        if HeadlessRunner.isHeadless {
            HeadlessRunner.start()
        } else if MCPServer.isMCP {
            MCPServer.start()
        }
        appState.appKitWindowOpener = { [weak self] id in
            self?.openWindow(id: id)
        }
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isUtilityRun else { return }
        // Restore the persisted appearance (default: follow the system).
        CCTheme.bootFromDefaults()
        // "Continue on Mac" from the iPhone app over the Wi-Fi link.
        NotificationCenter.default.addObserver(forName: .ccContinueProjectOnMac, object: nil, queue: .main) { [weak self] note in
            guard let id = note.userInfo?["id"] as? String else { return }
            MainActor.assumeIsolated { self?.continueProjectFromPhone(id) }
        }
        NSApp.mainMenu = buildMainMenu()
        installStatusItem()
        // MCP → GUI command channel (start/stop recording). GUI instance only.
        automationBridge = AutomationBridge(appState: appState)
        automationBridge?.start()
        // `CaptureCat --mcp` is a separate headless process editing
        // project.json files directly. Reload projects it changes so the
        // browser (and a clean open editor) pick the edit up instead of
        // autosaving a stale in-memory copy back over it. GUI instance only.
        appState.projectStore.onExternalProjectChange = { [weak self] fresh in
            guard let appState = self?.appState else { return }
            if appState.currentProject?.id == fresh.id {
                appState.currentProject = fresh
                appState.editorReloadToken += 1
            }
        }
        appState.projectStore.startWatchingForExternalChanges()
        // Services-menu text capture: pairs with the NSServices entry in
        // Info.plist. NSUpdateDynamicServices nudges pbs to pick the entry up
        // on first launch (otherwise it can take a re-login to appear).
        let textCapture = TextCaptureService(appState: appState)
        textCaptureService = textCapture
        NSApp.servicesProvider = textCapture
        NSUpdateDynamicServices()
        // Reminders: become the notification delegate (clicks route back to
        // the capture) and re-derive pending notifications from the persisted
        // reminder dates.
        ReminderCenter.shared.activate()
        ReminderCenter.shared.resync(
            projects: appState.projectStore.projects,
            notes: appState.noteStore.notes,
            projectStore: appState.projectStore,
            noteStore: appState.noteStore
        )
        // Text search index: load persisted records now; OCR of new/changed
        // captures starts after a launch-settle delay, one project at a time
        // at utility QoS (and never while recording/exporting).
        appState.captureTextIndex.start(appState: appState)
        // Camera-look masks: segmentation runs on demand (a look applied in
        // the editor, or a recording into a project that uses one).
        appState.cameraSegmentation.start(appState: appState)
        if appState.needsOnboarding || OnboardingViewController.isForcedPreview {
            openWindow(id: "onboarding")
        }
        // The recording flow starts from applicationDidBecomeActive — no
        // visible windows means beginNewRecording, same as the SwiftUI shell.
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        handleActivation(hasVisibleWindows: flag)
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        handleActivation(hasVisibleWindows: NSApplication.shared.windows.contains { $0.isVisible && !$0.isMiniaturized })
    }

    // MARK: - Handoff from the iPhone app

    /// The iPhone app's project screen advertises this activity (Apple
    /// Handoff); clicking CaptureCat in the Dock continues it here.
    static let continueProjectActivity = "so.capturecat.openProject"

    func application(_ application: NSApplication, willContinueUserActivityWithType userActivityType: String) -> Bool {
        !isUtilityRun && userActivityType == Self.continueProjectActivity
    }

    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard !isUtilityRun, userActivity.activityType == Self.continueProjectActivity,
              let id = userActivity.userInfo?["projectId"] as? String else { return false }
        continueProjectFromPhone(id)
        return true
    }

    /// Both iPhone paths (Wi-Fi link, Handoff) land here and take the deep
    /// link's road: clone if not on disk, else open + pull, then come forward.
    private func continueProjectFromPhone(_ id: String) {
        guard !isUtilityRun, UUID(uuidString: id) != nil,
              let url = URL(string: "capturecat://open-project?id=\(id.uppercased())&from=ios") else { return }
        handleIncomingURL(url)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // A headless/MCP instance of this same bundle can receive URL events
        // from LaunchServices — it must never act on them (it has no UI and
        // must not start invisible recordings).
        guard !isUtilityRun else { return }
        for url in urls {
            handleIncomingURL(url)
        }
    }

    private func handleIncomingURL(_ url: URL) {
        // Sign-in never comes back through a URL scheme: the OAuth callback is
        // delivered to a loopback socket this process owns (see
        // LoopbackAuthServer). `capturecat://` is purely the app's deep-link handler.
        if deepLinkHandler == nil {
            deepLinkHandler = DeepLinkHandler(appState: appState)
        }
        deepLinkHandler?.handle(url)
    }

    /// Right-click Dock menu — reliable entry even when the status-bar icon
    /// is hidden under the notch on a crowded menu bar.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let browse = NSMenuItem(title: String(localized: "Browse Captures…", comment: "Dock menu item: opens the capture library"), action: #selector(browseProjects(_:)), keyEquivalent: "")
        browse.target = self
        menu.addItem(browse)
        let record = NSMenuItem(title: String(localized: "New Recording…", comment: "Dock menu item: starts setting up a new screen recording"), action: #selector(newRecording(_:)), keyEquivalent: "")
        record.target = self
        menu.addItem(record)
        return menu
    }

    private func handleActivation(hasVisibleWindows: Bool) {
        guard !isUtilityRun else { return }

        if appState.needsOnboarding {
            if let onboardingWindow = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue == "onboarding" }) {
                onboardingWindow.makeKeyAndOrderFront(nil)
            }
            return
        }

        guard !appState.recordingSession.isRecording, !appState.recordingSession.isPaused else { return }
        guard appState.panelController.panel?.isVisible != true else { return }
        guard !hasVisibleWindows else { return }

        appState.beginNewRecording()
    }

    // MARK: - Windows

    func openWindow(id: String) {
        switch id {
        case "editor": showEditorWindow()
        case "onboarding": showOnboardingWindow()
        case "agents": showAgentSetupWindow()
        default: break
        }
    }

    private var agentSetupWindowController: NSWindowController?

    @objc func connectAgents(_ sender: Any?) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        showAgentSetupWindow()
    }

    private func showAgentSetupWindow() {
        if agentSetupWindowController == nil {
            let window = NSWindow(contentViewController: AgentSetupViewController())
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.identifier = NSUserInterfaceItemIdentifier("agents")
            window.title = String(localized: "Connect AI Agents", comment: "Window title: setup window for connecting AI agents (Claude, Cursor…) to CaptureCat")
            window.isReleasedWhenClosed = false
            window.center()
            agentSetupWindowController = NSWindowController(window: window)
        }
        agentSetupWindowController?.showWindow(nil)
        agentSetupWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    private func showEditorWindow() {
        if editorWindowController == nil {
            editorWindowController = EditorWindowController(appState: appState)
        }
        editorWindowController?.showWindow(nil)
        editorWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    private func showOnboardingWindow() {
        if onboardingWindowController == nil {
            // Phase 3b: native onboarding controller.
            let content: NSViewController = OnboardingViewController(appState: appState)
            let window = NSWindow(contentViewController: content)
            // windowResizability(.contentSize) equivalent: fixed to content.
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.identifier = NSUserInterfaceItemIdentifier("onboarding")
            window.title = String(localized: "CaptureCat Onboarding", comment: "Window title: first-run onboarding window")
            window.setContentSize(NSSize(width: 960, height: 600))
            window.isReleasedWhenClosed = false
            window.center()
            onboardingWindowController = NSWindowController(window: window)
        }
        onboardingWindowController?.showWindow(nil)
        onboardingWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Status item (replaces MenuBarExtra)

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // The cat mark as a TEMPLATE image (body silhouette from the traced
        // vector, see MenuBarCat.imageset): the system inks it white on dark
        // menu bars, black on light ones, and dims it correctly when inactive —
        // which is what a "white" menu-bar icon actually is on macOS.
        if let cat = NSImage(named: "MenuBarCat") {
            cat.isTemplate = true
            // Menu-bar height budget is 22pt; the mark is taller than wide
            // (viewBox 728x834), so 18pt tall → ~15.7pt wide.
            cat.size = NSSize(width: 18 * (728.0 / 834.0), height: 18)
            item.button?.image = cat
        } else {
            item.button?.image = CCIcon.image("record.circle", pointSize: 13, weight: .regular,
                                              accessibilityDescription: "CaptureCat")
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    // MARK: - Actions

    @objc func newRecording(_ sender: Any?) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if appState.needsOnboarding {
            openWindow(id: "onboarding")
        } else {
            appState.beginNewRecording()
        }
    }

    @objc func newNoteFromClipboard(_ sender: Any?) {
        textCaptureService?.newNoteFromClipboard()
    }

    @objc func browseProjects(_ sender: Any?) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        appState.openProjectBrowser()
    }

    @objc func setAppearanceMode(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String,
              let mode = CCThemeMode(rawValue: raw) else { return }
        CCTheme.setMode(mode)
    }

    @objc func openSettings(_ sender: Any?) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                appState: appState,
                onCheckForUpdates: { [weak self] in
                    self?.updaterController.checkForUpdates(nil)
                },
                onConnectAgents: { [weak self] in
                    self?.connectAgents(nil)
                }
            )
        }
        settingsWindowController?.present()
    }

    @objc func toggleAutoZoomNewRecordings(_ sender: Any?) {
        appState.autoZoomNewRecordings.toggle()
        // The status menu rebuilds on open, but the sender that fired is the
        // live item — flip its checkmark now so the change reads instantly.
        (sender as? NSMenuItem)?.state = appState.autoZoomNewRecordings ? .on : .off
    }

    @objc func signOut(_ sender: Any?) {
        do {
            try appState.signOut()
        } catch {
            NSApplication.shared.presentError(error)
        }
    }

    @objc func signIn(_ sender: Any?) {
        Task { @MainActor in
            do {
                try await appState.signIn()
            } catch {
                if AuthService.isUserCancellation(error) { return }
                NSApplication.shared.presentError(error)
            }
        }
    }

    @objc func showPlans(_ sender: Any?) {
        NSWorkspace.shared.open(PlanGate.pricingURL)
    }

    @objc func pauseOrResumeRecording(_ sender: Any?) {
        if appState.recordingSession.isPaused {
            appState.recordingSession.resume()
        } else {
            appState.recordingSession.pause()
        }
    }

    @objc func stopRecording(_ sender: Any?) {
        appState.stopRecordingInProgress()
    }

    // MARK: - Main menu

    private func buildMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        // App menu
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: String(localized: "About CaptureCat", comment: "Menu bar ▸ CaptureCat: opens the About panel"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: String(localized: "Settings…", comment: "Menu bar ▸ CaptureCat: opens Settings"), action: #selector(openSettings(_:)), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        let updates = NSMenuItem(title: String(localized: "Check for Updates...", comment: "Menu bar ▸ CaptureCat: checks for a newer app version"), action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        updates.target = updaterController
        appMenu.addItem(updates)
        appMenu.addItem(.separator())
        let servicesItem = appMenu.addItem(withTitle: String(localized: "Services", comment: "Menu bar ▸ CaptureCat: the macOS Services submenu"), action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu()
        servicesItem.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Hide CaptureCat", comment: "Menu bar ▸ CaptureCat: hides the app"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: String(localized: "Hide Others", comment: "Menu bar ▸ CaptureCat: hides all other apps"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: String(localized: "Show All", comment: "Menu bar ▸ CaptureCat: shows all hidden apps"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Quit CaptureCat", comment: "Menu bar ▸ CaptureCat: quits the app"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // File menu — mirrors the old CommandGroup(after: .newItem).
        let fileMenu = NSMenu(title: String(localized: "File", comment: "Menu bar: File menu title"))
        let newRec = NSMenuItem(title: String(localized: "New Recording...", comment: "Menu bar ▸ File: starts setting up a new screen recording"), action: #selector(newRecording(_:)), keyEquivalent: "n")
        newRec.keyEquivalentModifierMask = [.command, .shift]
        newRec.target = self
        fileMenu.addItem(newRec)
        let browse = NSMenuItem(title: String(localized: "Browse Captures...", comment: "Menu bar ▸ File: opens the capture library"), action: #selector(browseProjects(_:)), keyEquivalent: "o")
        browse.target = self
        fileMenu.addItem(browse)
        // Clipboard fallback for the Services-menu text capture.
        let clipNote = NSMenuItem(title: String(localized: "New Note from Clipboard", comment: "Menu bar ▸ File: creates a text note from the clipboard contents"), action: #selector(newNoteFromClipboard(_:)), keyEquivalent: "n")
        clipNote.keyEquivalentModifierMask = [.command, .option]
        clipNote.target = self
        fileMenu.addItem(clipNote)
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: String(localized: "Close", comment: "Menu bar ▸ File: closes the front window (verb)"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let fileItem = NSMenuItem()
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        // Edit menu — required for text fields and the editor's undo stack
        // (SwiftUI's environment undoManager resolves to the window's).
        let editMenu = NSMenu(title: String(localized: "Edit", comment: "Menu bar: Edit menu title"))
        editMenu.addItem(withTitle: String(localized: "Undo", comment: "Menu bar ▸ Edit: undo the last change (verb)"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: String(localized: "Redo", comment: "Menu bar ▸ Edit: redo the last undone change (verb)"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: String(localized: "Cut", comment: "Menu bar ▸ Edit: cut the selection (verb)"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: String(localized: "Copy", comment: "Menu bar ▸ Edit: copy the selection (verb)"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: String(localized: "Paste", comment: "Menu bar ▸ Edit: paste (verb)"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: String(localized: "Delete", comment: "Menu bar ▸ Edit: delete the selection (verb)"), action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: String(localized: "Select All", comment: "Menu bar ▸ Edit: select everything"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        // Account menu — dynamic, rebuilt each open via NSMenuDelegate.
        let accountMenu = NSMenu(title: String(localized: "Account", comment: "Menu bar: Account menu title (sign in, plan, sign out)"))
        accountMenu.delegate = self
        self.accountMenu = accountMenu
        let accountItem = NSMenuItem()
        accountItem.submenu = accountMenu
        mainMenu.addItem(accountItem)

        // View menu
        let viewMenu = NSMenu(title: String(localized: "View", comment: "Menu bar: View menu title"))
        // Browser type filter — nil-targeted, resolved through the responder
        // chain to ProjectBrowserViewController when the browser is showing.
        let typeFilters: [(String, Selector, String)] = [
            (String(localized: "All Captures", comment: "Menu bar ▸ View: show every capture type in the library"), #selector(ProjectBrowserViewController.filterAllCaptures(_:)), "1"),
            (String(localized: "Videos", comment: "Menu bar ▸ View: filter the library to video captures"), #selector(ProjectBrowserViewController.filterVideoCaptures(_:)), "2"),
            (String(localized: "Images", comment: "Menu bar ▸ View: filter the library to image captures"), #selector(ProjectBrowserViewController.filterImageCaptures(_:)), "3"),
            (String(localized: "Notes", comment: "Menu bar ▸ View: filter the library to text notes"), #selector(ProjectBrowserViewController.filterNoteCaptures(_:)), "4"),
        ]
        for (title, action, key) in typeFilters {
            viewMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        viewMenu.addItem(.separator())
        viewMenu.addItem(
            withTitle: String(localized: "Search Captures", comment: "Menu bar ▸ View: focuses the library search field"),
            action: #selector(ProjectBrowserViewController.focusSearchField(_:)),
            keyEquivalent: "k"
        )
        viewMenu.addItem(.separator())
        // Editor inspector (column + icon rail) — nil-targeted, resolved
        // through the responder chain to the editor shell when it is key.
        let inspectorToggle = viewMenu.addItem(
            withTitle: String(localized: "Toggle Inspector", comment: "Menu bar ▸ View: shows or hides the editor inspector panel"),
            action: #selector(EditorShellViewController.toggleInspectorFromMenu(_:)),
            keyEquivalent: "i"
        )
        inspectorToggle.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(.separator())
        let fullScreen = viewMenu.addItem(withTitle: String(localized: "Enter Full Screen", comment: "Menu bar ▸ View: makes the window full screen"), action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        let viewItem = NSMenuItem()
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        // Window menu
        let windowMenu = NSMenu(title: String(localized: "Window", comment: "Menu bar: Window menu title"))
        windowMenu.addItem(withTitle: String(localized: "Minimize", comment: "Menu bar ▸ Window: minimizes the window to the Dock (verb)"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: String(localized: "Zoom", comment: "Menu bar ▸ Window: zooms (resizes) the window, standard macOS command"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: String(localized: "Bring All to Front", comment: "Menu bar ▸ Window: brings all app windows forward"), action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu
        let windowItem = NSMenuItem()
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        // Help menu
        let helpMenu = NSMenu(title: String(localized: "Help", comment: "Menu bar: Help menu title"))
        NSApp.helpMenu = helpMenu
        let helpItem = NSMenuItem()
        helpItem.submenu = helpMenu
        mainMenu.addItem(helpItem)

        return mainMenu
    }

    // MARK: - Dynamic menu content

    /// Account section rows shared by the main-menu Account menu and the
    /// status-item menu — mirrors the old SwiftUI CommandMenu("Account").
    /// Construction lives in StatusMenuBuilder so the harness can enumerate the
    /// identical rows without booting the shell.
    private func accountMenuItems() -> [NSMenuItem] {
        StatusMenuBuilder.accountItems(appState: appState, target: self)
    }

    /// Status-item menu rows — mirrors the old SwiftUI MenuBarExtra content.
    private func rebuildStatusMenu(_ menu: NSMenu) {
        StatusMenuBuilder.populateStatusMenu(
            menu,
            appState: appState,
            target: self,
            updaterTarget: updaterController
        )
    }
}

extension CaptureCatAppDelegate: StatusMenuActions {}

extension CaptureCatAppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === statusItem?.menu {
            rebuildStatusMenu(menu)
        } else if let accountMenu, menu === accountMenu {
            menu.removeAllItems()
            for item in accountMenuItems() {
                menu.addItem(item)
            }
        }
    }
}
