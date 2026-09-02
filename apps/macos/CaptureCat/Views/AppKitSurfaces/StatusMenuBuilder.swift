import AppKit

/// Actions the status-item menu fires. `CaptureCatAppDelegate` implements it; the
/// verification harness supplies a recording stub, so the menu can be built and
/// enumerated without booting the app shell.
@MainActor
@objc protocol StatusMenuActions: AnyObject {
    func newRecording(_ sender: Any?)
    func browseProjects(_ sender: Any?)
    func signOut(_ sender: Any?)
    func signIn(_ sender: Any?)
    func pauseOrResumeRecording(_ sender: Any?)
    func stopRecording(_ sender: Any?)
    func toggleAutoZoomNewRecordings(_ sender: Any?)
    func setAppearanceMode(_ sender: Any?)
    func openSettings(_ sender: Any?)
}

/// Native construction of the menu-bar surfaces that used to be SwiftUI
/// (`MenuBarView` inside `MenuBarExtra`, plus `CommandMenu("Account")`).
///
/// Row-for-row equivalent of `MenuBarView.body`:
///   New Recording… ⇧⌘N · Browse Captures… ⌘O · —— · account block ·
///   Check for Updates… · —— · [Pause/Resume · Stop ⇧⌘S · ——] · Quit ⌘Q
///
/// Enable state comes from AppKit's own validation (`autoenablesItems`), which
/// is what makes `Check for Updates…` grey out exactly when SwiftUI's
/// `.disabled(!canCheckForUpdates)` did — Sparkle's controller answers
/// `validateMenuItem(_:)` with `updater.canCheckForUpdates`.
@MainActor
enum StatusMenuBuilder {

    // MARK: - Account block

    /// Account rows shared by the main-menu Account menu and the status menu —
    /// mirrors the account section of `MenuBarView`.
    static func accountItems(appState: AppState, target: StatusMenuActions) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if let email = appState.currentAccountEmail {
            let emailItem = NSMenuItem(title: email, action: nil, keyEquivalent: "")
            emailItem.isEnabled = false
            items.append(emailItem)

            let signOutItem = NSMenuItem(title: "Sign Out", action: #selector(StatusMenuActions.signOut(_:)), keyEquivalent: "")
            signOutItem.target = target
            items.append(signOutItem)
        } else {
            let none = NSMenuItem(title: "Not signed in", action: nil, keyEquivalent: "")
            none.isEnabled = false
            items.append(none)

            // One item: the provider choice moved to the browser chooser that
            // `/api/desktop/authorize` serves, so it is no longer baked into
            // the app's menus.
            let signIn = NSMenuItem(title: "Sign In\u{2026}", action: #selector(StatusMenuActions.signIn(_:)), keyEquivalent: "")
            signIn.target = target
            items.append(signIn)
        }

        if let configError = appState.authService.configurationError {
            items.append(.separator())
            let errorItem = NSMenuItem(title: configError, action: nil, keyEquivalent: "")
            // `.foregroundStyle(.red)` in the SwiftUI row.
            errorItem.attributedTitle = NSAttributedString(
                string: configError,
                attributes: [
                    .foregroundColor: NSColor.systemRed,
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                ]
            )
            errorItem.isEnabled = false
            items.append(errorItem)
        }
        return items
    }

    // MARK: - Status item menu

    /// Rebuild the status-item menu in place (called from `menuNeedsUpdate`, so
    /// every open reflects live recording/auth state).
    static func populateStatusMenu(
        _ menu: NSMenu,
        appState: AppState,
        target: StatusMenuActions,
        updaterTarget: AnyObject?
    ) {
        menu.removeAllItems()

        let newRec = NSMenuItem(title: "New Recording...", action: #selector(StatusMenuActions.newRecording(_:)), keyEquivalent: "n")
        newRec.keyEquivalentModifierMask = [.command, .shift]
        newRec.target = target
        menu.addItem(newRec)

        let browse = NSMenuItem(title: "Browse Captures...", action: #selector(StatusMenuActions.browseProjects(_:)), keyEquivalent: "o")
        browse.target = target
        menu.addItem(browse)

        // Auto Zoom, Appearance, and the rest of the preference surface live
        // in the Settings window now (SettingsWindowController) — the menu
        // keeps one entry point instead of per-setting checkmark items.
        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(StatusMenuActions.openSettings(_:)),
            keyEquivalent: ","
        )
        settings.target = target
        menu.addItem(settings)

        let agents = NSMenuItem(
            title: "Connect AI Agents...",
            action: Selector(("connectAgents:")),
            keyEquivalent: ""
        )
        agents.target = target
        menu.addItem(agents)

        menu.addItem(.separator())
        for item in accountItems(appState: appState, target: target) {
            menu.addItem(item)
        }

        let updates = NSMenuItem(
            title: "Check for Updates...",
            action: Selector(("checkForUpdates:")),
            keyEquivalent: ""
        )
        updates.target = updaterTarget
        menu.addItem(updates)

        menu.addItem(.separator())

        if appState.recordingSession.isRecording || appState.recordingSession.isPaused {
            let pause = NSMenuItem(
                title: appState.recordingSession.isPaused ? "Resume Recording" : "Pause Recording",
                action: #selector(StatusMenuActions.pauseOrResumeRecording(_:)),
                keyEquivalent: ""
            )
            pause.target = target
            menu.addItem(pause)

            let stop = NSMenuItem(title: "Stop Recording", action: #selector(StatusMenuActions.stopRecording(_:)), keyEquivalent: "s")
            stop.keyEquivalentModifierMask = [.command, .shift]
            stop.target = target
            menu.addItem(stop)

            menu.addItem(.separator())
        }

        menu.addItem(withTitle: "Quit CaptureCat", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    // MARK: - Verification

    /// One line per row: `title | action | target | keyEquivalent`. Used by the
    /// conversion harness to diff the native menu against the SwiftUI original.
    static func describe(_ menu: NSMenu) -> [String] {
        menu.items.map { item in
            if item.isSeparatorItem { return "----" }
            let action = item.action.map { NSStringFromSelector($0) } ?? "—"
            let owner = item.target.map { String(describing: type(of: $0)) } ?? "responderChain"
            var key = ""
            if !item.keyEquivalent.isEmpty {
                let mods = item.keyEquivalentModifierMask
                key = (mods.contains(.command) ? "⌘" : "")
                    + (mods.contains(.shift) ? "⇧" : "")
                    + (mods.contains(.option) ? "⌥" : "")
                    + item.keyEquivalent.uppercased()
            }
            return "\(item.title) | \(action) | \(owner) | \(key)"
        }
    }
}
