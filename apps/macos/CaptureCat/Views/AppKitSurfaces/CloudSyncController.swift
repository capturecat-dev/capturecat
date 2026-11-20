import AppKit

/// "Open in Web Editor" and "Pull Web Edits" — the GUI around
/// `CloudProjectSync`. Reached from the editor's top bar (Web Editor menu)
/// and from a project card's context menu, right beside Share.
///
/// All chrome is CCKit: a `CCDialog` carrying a `CCProgressBar` while the
/// sync runs (Cancel / Escape stop it), `CCAlert` for sign-in, conflicts and
/// errors. One sync at a time, app-wide.
@MainActor
final class CloudSyncController {
    static let shared = CloudSyncController()

    private var task: Task<Void, Never>?
    private var progress: CloudSyncProgressDialog?
    private var reviewDialog: MergeReviewDialog?
    /// The project `openFromCloud` is bringing to this Mac — mirrored into
    /// `CloudLibrary.cloning` so the browser's Cloud section hides it while
    /// it downloads (and shows it again if the clone fails).
    private var cloningProjectID: UUID?
    /// One toaster per window (merge results land in the window that asked).
    private var toasters: [ObjectIdentifier: (window: () -> NSWindow?, toaster: CCToaster)] = [:]

    var isBusy: Bool { task != nil }

    /// Posted after any sync, merge or restore touched a project (object:
    /// the project id) — the History pane refreshes on it.
    static let didSyncNotification = Notification.Name("CloudSyncControllerDidSync")

    /// The two actions as menu rows (built by whoever owns the menu, so the
    /// browser's closure-target helper and the editor's presenter both fit).
    static func menuItems(
        for project: Project,
        appState: AppState,
        window: @escaping () -> NSWindow?,
        makeItem: (String, @escaping () -> Void) -> NSMenuItem
    ) -> [NSMenuItem] {
        [
            makeItem(String(localized: "Open in Web Editor", comment: "Menu item / button: syncs the project and opens it in the CaptureCat web editor")) {
                CloudSyncController.shared.openInWebEditor(project: project, appState: appState, window: window())
            },
            makeItem(String(localized: "Pull Web Edits", comment: "Menu item: downloads edits made in the web editor into this Mac's copy")) {
                CloudSyncController.shared.pullWebEdits(project: project, appState: appState, window: window())
            },
        ]
    }

    // MARK: - Open in Web Editor

    func openInWebEditor(
        project: Project,
        appState: AppState,
        window: NSWindow?,
        overwriteRevision: Int? = nil
    ) {
        push(project: project, appState: appState, window: window, overwriteRevision: overwriteRevision,
             title: String(localized: "Opening in Web Editor", comment: "Progress dialog title while the project syncs before opening in the web editor"), openWeb: true)
    }

    /// History ▸ "Sync now": the same push, without opening the browser.
    func syncNow(project: Project, appState: AppState, window: NSWindow?) {
        push(project: project, appState: appState, window: window, overwriteRevision: nil,
             title: String(localized: "Syncing", comment: "Progress dialog title while the project syncs to the cloud"), openWeb: false)
    }

    private func push(
        project: Project,
        appState: AppState,
        window: NSWindow?,
        overwriteRevision: Int?,
        title: String,
        openWeb: Bool
    ) {
        guard task == nil, let window = window ?? appState.authPresentationWindow() else { return }
        guard ensureSignedIn(appState: appState, window: window, then: { [weak self] in
            self?.push(project: project, appState: appState, window: window, overwriteRevision: overwriteRevision,
                       title: title, openWeb: openWeb)
        }) else { return }
        flush(project, appState: appState)

        let dialog = CloudSyncProgressDialog(title: title, subtitle: project.name)
        dialog.onCancel = { [weak self] in self?.task?.cancel() }
        dialog.present(over: window)
        progress = dialog

        let sync = CloudProjectSync(transport: HTTPCloudProjectTransport())
        let projectID = project.id
        let openBrowser = { if openWeb { NSWorkspace.shared.open(CaptureCatAPI.webEditorURL(projectID: projectID)) } }
        task = Task { [weak self] in
            do {
                let outcome = try await sync.push(
                    project: project,
                    projectDirectory: project.projectDirectory,
                    overwriteRevision: overwriteRevision
                ) { step in
                    dialog.update(step, weights: Self.pushWeights)
                }
                guard let self else { return }
                switch outcome {
                case .pushed, .unchanged, .cloudIsNewer:
                    dialog.finish(message: openWeb ? String(localized: "Opening your browser…", comment: "Sync progress dialog status after syncing, while the web browser opens") : String(localized: "Synced", comment: "Sync progress dialog status: the sync finished"))
                    self.finish {
                        self.announce(projectID)
                        openBrowser()
                    }
                case .merged(_, let report):
                    dialog.finish(message: openWeb ? String(localized: "Merged — opening your browser…", comment: "Sync progress dialog status after merging web and Mac edits, while the browser opens") : String(localized: "Merged", comment: "Sync progress dialog status: web and Mac edits were merged"))
                    self.finish {
                        self.announce(projectID)
                        self.toast(report, in: window)
                        openBrowser()
                    }
                case .needsReview(let review):
                    self.finish {
                        self.presentMergeReview(review, project: project, appState: appState, window: window,
                                                openWeb: openWeb)
                    }
                case .conflict(let remoteRevision):
                    self.finish {
                        self.presentConflict(
                            project: project, appState: appState, window: window, remoteRevision: remoteRevision)
                    }
                }
            } catch {
                self?.fail(error, title: openWeb ? String(localized: "Couldn’t open in the web editor", comment: "Alert title when syncing before opening the web editor fails") : String(localized: "Couldn’t sync", comment: "Alert title when syncing the project to the cloud fails"), window: window)
            }
        }
    }

    // MARK: - Merge

    /// Structural conflicts: the Merge Review dialog, then `resolve`.
    func presentMergeReview(
        _ review: CloudMergeReview,
        project: Project,
        appState: AppState?,
        window: NSWindow,
        openWeb: Bool
    ) {
        let dialog = MergeReviewDialog(review: review, projectName: project.name)
        dialog.onApply = { [weak self] choices in
            self?.reviewDialog = nil
            self?.resolveMerge(review, choices: choices, project: project, appState: appState, window: window,
                               openWeb: openWeb)
        }
        dialog.onCancel = { [weak self] in self?.reviewDialog = nil }
        reviewDialog = dialog
        dialog.present(over: window)
    }

    private func resolveMerge(
        _ review: CloudMergeReview,
        choices: [String: MergeSide],
        project: Project,
        appState: AppState?,
        window: NSWindow,
        openWeb: Bool
    ) {
        guard task == nil else { return }
        let dialog = CloudSyncProgressDialog(title: String(localized: "Merging", comment: "Progress dialog title while applying a reviewed merge"), subtitle: project.name)
        dialog.onCancel = { [weak self] in self?.task?.cancel() }
        dialog.present(over: window)
        progress = dialog
        let sync = CloudProjectSync(transport: HTTPCloudProjectTransport())
        let projectID = project.id
        task = Task { [weak self] in
            do {
                let outcome = try await sync.resolve(review, choices: choices,
                                                     projectDirectory: project.projectDirectory) { step in
                    dialog.update(step, weights: Self.pushWeights)
                }
                guard let self else { return }
                switch outcome {
                case .merged(_, let report):
                    dialog.finish(message: String(localized: "Merged", comment: "Sync progress dialog status: web and Mac edits were merged"))
                    self.finish {
                        self.announce(projectID)
                        self.toast(report, in: window)
                        if openWeb { NSWorkspace.shared.open(CaptureCatAPI.webEditorURL(projectID: projectID)) }
                    }
                case .needsReview(let next):
                    self.finish {
                        self.presentMergeReview(next, project: project, appState: appState, window: window, openWeb: openWeb)
                    }
                case .conflict(let remoteRevision):
                    self.finish {
                        guard let appState else { return }
                        self.presentConflict(project: project, appState: appState, window: window,
                                             remoteRevision: remoteRevision)
                    }
                }
            } catch {
                self?.fail(error, title: String(localized: "Couldn’t merge", comment: "Alert title when applying a merge fails"), window: window)
            }
        }
    }

    /// "Merged 2 changes from Ana (Web)" — a CCToaster toast in `window`.
    func toast(_ report: CloudMergeReport, in window: NSWindow) {
        let settled = report.autoResolved.count
        var notes: [String] = []
        if settled > 0 { notes.append(settled == 1 ? String(localized: "1 clash went to the latest edit", comment: "Merge toast note: one clashing change was settled in favour of the most recent edit") : String(localized: "\(settled) clashes went to the latest edit", comment: "Merge toast note: clashing changes were settled in favour of the most recent edit; the number is the count")) }
        if report.conflictsResolved > 0 {
            notes.append(report.conflictsResolved == 1 ? String(localized: "1 conflict resolved", comment: "Merge toast note: one conflict was resolved by the user") : String(localized: "\(report.conflictsResolved) conflicts resolved", comment: "Merge toast note: conflicts were resolved by the user; the number is the count"))
        }
        notes.append(String(localized: "Both versions are kept in History.", comment: "Merge toast note; History is the project version history panel"))
        showToast(title: report.toastTitle, message: notes.joined(separator: " · "),
                  symbol: "arrow.triangle.merge", in: window)
    }

    /// A house toast in `window` (one CCToaster per window, reused).
    @discardableResult
    func showToast(title: String, message: String?, variant: CCToast.Variant = .success,
                   symbol: String? = nil, in window: NSWindow) -> CCToast? {
        guard let host = window.contentView else { return nil }
        let key = ObjectIdentifier(window)
        let toaster: CCToaster
        if let existing = toasters[key], existing.window() === window {
            toaster = existing.toaster
        } else {
            toaster = CCToaster(in: host)
            toasters[key] = ({ [weak window] in window }, toaster)
        }
        return toaster.show(title: title, message: message, variant: variant, symbol: symbol, duration: 5)
    }

    private func announce(_ projectID: UUID) {
        NotificationCenter.default.post(name: Self.didSyncNotification, object: projectID)
    }

    private func presentConflict(project: Project, appState: AppState, window: NSWindow, remoteRevision: Int) {
        let alert = CCAlert(
            title: String(localized: "Edited in both places", comment: "Alert title: the project was edited both in the web editor and on this Mac"),
            message: String(localized: "This project changed in the web editor and on this Mac since they last synced. Pull Web Edits replaces this Mac’s unsynced changes with the web’s version; Replace Web Version overwrites the web’s changes with this Mac’s.", comment: "Alert message for a sync conflict; Pull Web Edits and Replace Web Version are the button names")
        )
        // Reached only without a merge base (an older build's sidecar and a
        // revision the server no longer retains) — otherwise both sides
        // merge three-way and this two-way choice never appears.
        alert.addButton(String(localized: "Pull Web Edits", comment: "Sync conflict alert button: replaces this Mac's unsynced changes with the web version"), role: .primary)
        alert.addButton(String(localized: "Replace Web Version", comment: "Sync conflict alert button: overwrites the web version with this Mac's changes"), role: .destructive)
        alert.addButton(String(localized: "Cancel", comment: "Dialog button: dismisses without doing anything"))
        alert.beginSheet(for: window) { [weak self] choice in
            switch choice {
            case 0:
                self?.pullWebEdits(project: project, appState: appState, window: window, force: true, thenOpenWeb: true)
            case 1:
                self?.openInWebEditor(project: project, appState: appState, window: window, overwriteRevision: remoteRevision)
            default:
                break
            }
        }
    }

    // MARK: - Pull Web Edits

    func pullWebEdits(
        project: Project,
        appState: AppState,
        window: NSWindow?,
        force: Bool = false,
        thenOpenWeb: Bool = false,
        quiet: Bool = false
    ) {
        guard task == nil, let window = window ?? appState.authPresentationWindow() else { return }
        guard ensureSignedIn(appState: appState, window: window, then: { [weak self] in
            self?.pullWebEdits(project: project, appState: appState, window: window, force: force,
                               thenOpenWeb: thenOpenWeb, quiet: quiet)
        }) else { return }
        // Save first: the pull compares the file on disk with the last sync,
        // and the GUI only reloads a CLEAN project from an external write.
        flush(project, appState: appState)

        let dialog = CloudSyncProgressDialog(title: String(localized: "Pulling Web Edits", comment: "Progress dialog title while downloading edits from the web editor"), subtitle: project.name)
        dialog.onCancel = { [weak self] in self?.task?.cancel() }
        dialog.present(over: window)
        progress = dialog

        let sync = CloudProjectSync(transport: HTTPCloudProjectTransport())
        let projectID = project.id
        task = Task { [weak self] in
            do {
                let outcome = try await sync.pull(
                    projectID: projectID,
                    projectDirectory: project.projectDirectory,
                    force: force
                ) { step in
                    dialog.update(step, weights: Self.pullWeights)
                }
                guard let self else { return }
                switch outcome {
                case .pulled(let revision):
                    // project.json was replaced atomically; ProjectStore's
                    // external-edit poll reloads it (and an open editor) within
                    // a second — the same path MCP edits take.
                    dialog.finish(message: String(localized: "Pulled revision \(revision)", comment: "Sync progress status after pulling web edits; the number is the cloud revision"))
                    try? await Task.sleep(for: .milliseconds(450))
                    self.finish {
                        self.announce(projectID)
                        if thenOpenWeb { NSWorkspace.shared.open(CaptureCatAPI.webEditorURL(projectID: projectID)) }
                    }
                case .mediaRestored(_, let files):
                    // Same document, but files it names were missing here
                    // (an earlier pull fetched only project.json). If the
                    // document's references were re-pointed at them, the
                    // external-edit poll reloads it like any pull.
                    dialog.finish(message: files == 0 ? String(localized: "Updated file references", comment: "Sync progress status: the project now points at media files already on this Mac")
                                  : files == 1 ? String(localized: "Downloaded 1 missing file", comment: "Sync progress status: one missing media file was downloaded") : String(localized: "Downloaded \(files) missing files", comment: "Sync progress status: missing media files were downloaded; the number is the count"))
                    try? await Task.sleep(for: .milliseconds(450))
                    self.finish {
                        if thenOpenWeb { NSWorkspace.shared.open(CaptureCatAPI.webEditorURL(projectID: projectID)) }
                    }
                case .upToDate:
                    self.finish {
                        if thenOpenWeb {
                            NSWorkspace.shared.open(CaptureCatAPI.webEditorURL(projectID: projectID))
                        } else if !quiet {
                            let alert = CCAlert(title: String(localized: "Already up to date", comment: "Alert title: there are no web edits to pull"),
                                                message: String(localized: "This Mac has the web editor’s latest version of “\(project.name)”.", comment: "Alert message: no web edits to pull; the placeholder is the project name"))
                            alert.beginSheet(for: window)
                        }
                    }
                case .noCloudCopy where quiet:
                    // Continue on Mac for a project the web never had: the
                    // copy here is the only one, and it is already open.
                    self.finish {}
                case .noCloudCopy:
                    self.finish {
                        let alert = CCAlert(title: String(localized: "Not in the web editor yet", comment: "Alert title: the project has never been opened in the web editor"),
                                            message: String(localized: "Open “\(project.name)” in the web editor first — its edits can then be pulled back here.", comment: "Alert message; the placeholder is the project name"))
                        alert.addButton(String(localized: "Open in Web Editor", comment: "Menu item / button: syncs the project and opens it in the CaptureCat web editor"), role: .primary)
                        alert.addButton(String(localized: "Cancel", comment: "Dialog button: dismisses without doing anything"))
                        alert.beginSheet(for: window) { [weak self] choice in
                            if choice == 0 { self?.openInWebEditor(project: project, appState: appState, window: window) }
                        }
                    }
                case .merged(_, let report):
                    // The web's edits merged INTO this Mac's unsynced ones
                    // (written atomically — the external-edit poll reloads
                    // the editor); this Mac's side goes up with the next push.
                    dialog.finish(message: String(localized: "Merged web edits", comment: "Sync progress status: web edits were merged into this Mac's unsynced changes"))
                    try? await Task.sleep(for: .milliseconds(300))
                    self.finish {
                        self.announce(projectID)
                        self.toast(report, in: window)
                        if thenOpenWeb { NSWorkspace.shared.open(CaptureCatAPI.webEditorURL(projectID: projectID)) }
                    }
                case .needsReview(let review):
                    self.finish {
                        self.presentMergeReview(review, project: project, appState: appState, window: window,
                                                openWeb: thenOpenWeb)
                    }
                case .localChangesWouldBeLost(let remoteRevision):
                    self.finish {
                        let alert = CCAlert(
                            title: String(localized: "Replace this Mac’s changes?", comment: "Alert title before pulling web edits would discard unsynced local changes"),
                            message: String(localized: "The web editor has a newer version (revision \(remoteRevision)), and this project has changes on this Mac that were never sent to the web. Pulling replaces them.", comment: "Alert message; the number is the cloud revision")
                        )
                        alert.addButton(String(localized: "Pull and Replace", comment: "Alert button: pulls web edits and discards this Mac's unsynced changes"), role: .destructive)
                        alert.addButton(String(localized: "Cancel", comment: "Dialog button: dismisses without doing anything"))
                        alert.beginSheet(for: window) { [weak self] choice in
                            if choice == 0 {
                                self?.pullWebEdits(project: project, appState: appState, window: window,
                                                   force: true, thenOpenWeb: thenOpenWeb, quiet: quiet)
                            }
                        }
                    }
                }
            } catch {
                self?.fail(error, title: String(localized: "Couldn’t pull web edits", comment: "Alert title when pulling web edits fails"), window: window)
            }
        }
    }

    // MARK: - Continue on Mac

    /// The web app's "Continue on Mac" (`capturecat://open-project?id=…&from=web`)
    /// for a project this Mac already has: open it, then bring in whatever
    /// the web changed since (the same pull as Pull Web Edits, merge and
    /// conflict handling included). Quiet when there is nothing new.
    func continueFromWeb(project: Project, appState: AppState, seek: Double? = nil) {
        if let seek { appState.pendingSeekOutputTime = seek }
        appState.openEditor(with: project)
        appState.bringToFront()
        guard task == nil else { return }
        pullWebEdits(project: project, appState: appState, window: nil, quiet: true)
    }

    /// `capturecat://open-project?id=…` for a project this Mac does not have —
    /// one recorded or built in the web app. Signs in if needed, downloads
    /// it with everything the cloud holds into a new project folder
    /// (`CloudProjectSync.clone`), lists it, and opens the editor.
    ///
    /// `title`: the progress card's heading — the browser's Cloud section
    /// opens projects made on the iPhone too, not only on the web.
    func openFromCloud(projectID: UUID, appState: AppState, seek: Double? = nil,
                       title: String = String(localized: "Opening from the Web", comment: "Progress dialog title while downloading a cloud project made on the web")) {
        guard task == nil else {
            // Already bringing it in (a second click): just show where.
            appState.bringToFront()
            return
        }
        // A deep link can arrive with no window open (menu bar app): the
        // project browser hosts the sign-in prompt and the progress dialog.
        if appState.authPresentationWindow() == nil { appState.openProjectBrowser() }
        appState.bringToFront()
        guard let window = appState.authPresentationWindow() else { return }
        guard ensureSignedIn(
            appState: appState, window: window,
            title: String(localized: "Sign in to open this project", comment: "Alert title: sign-in is needed to download a cloud project"),
            message: String(localized: "It was made in the CaptureCat web app. Sign in with the same account to bring it to this Mac.", comment: "Alert message asking the user to sign in to download a cloud project"),
            then: { [weak self] in self?.openFromCloud(projectID: projectID, appState: appState, seek: seek, title: title) }
        ) else { return }

        let dialog = CloudSyncProgressDialog(title: title, subtitle: String(localized: "Bringing your project to this Mac", comment: "Progress dialog subtitle while downloading a cloud project"))
        dialog.onCancel = { [weak self] in self?.task?.cancel() }
        dialog.present(over: window)
        progress = dialog

        let sync = CloudProjectSync(transport: HTTPCloudProjectTransport())
        let directory = Project.directory(for: projectID)
        cloningProjectID = projectID
        CloudLibrary.shared.setCloning(projectID, true)
        task = Task { [weak self] in
            do {
                let outcome = try await sync.clone(projectID: projectID, into: directory) { step in
                    dialog.update(step, weights: Self.pullWeights)
                }
                guard let self else { return }
                switch outcome {
                case .cloned:
                    dialog.finish(message: String(localized: "Ready", comment: "Progress dialog status: the cloud project finished downloading"))
                    try? await Task.sleep(for: .milliseconds(350))
                    self.finish {
                        guard let project = appState.projectStore.adopt(projectAt: directory) else {
                            let alert = CCAlert(title: String(localized: "Couldn’t open the project", comment: "Alert title when a downloaded cloud project can't be opened"),
                                                message: String(localized: "It downloaded, but this version of CaptureCat could not read it.", comment: "Alert message: the downloaded project is in a format this app version can't read"))
                            alert.beginSheet(for: window)
                            return
                        }
                        if let seek { appState.pendingSeekOutputTime = seek }
                        appState.openEditor(with: project)
                        // Minutes may have passed (sign-in in the browser, the
                        // download): bring the editor up over the browser.
                        appState.bringToFront()
                        self.announce(projectID)
                    }
                case .noCloudCopy:
                    self.finish {
                        let alert = CCAlert(
                            title: String(localized: "Project not found", comment: "Alert title: the cloud project isn't in the signed-in account"),
                            message: String(localized: "This Mac is signed in to a CaptureCat account that doesn’t have this project. If you made it in the web app, sign in here with that same account and open it again.", comment: "Alert message when the cloud project isn't in the signed-in account")
                        )
                        alert.beginSheet(for: window)
                    }
                }
            } catch CloudSyncError.alreadyOnThisMac {
                // Raced a local copy into existence (a second click): open that.
                self?.finish {
                    if let project = appState.projectStore.adopt(projectAt: directory) {
                        appState.openEditor(with: project)
                        appState.bringToFront()
                    }
                }
            } catch {
                self?.fail(error, title: String(localized: "Couldn’t open the project", comment: "Alert title when downloading a cloud project fails"), window: window)
            }
        }
    }

    // MARK: - Shared

    /// Overall-bar share of each phase (they arrive in this order).
    static let pushWeights: [CloudProjectSync.Progress.Phase: ClosedRange<Double>] = [
        .hashing: 0...0.12, .uploading: 0.12...0.86, .verifying: 0.86...0.94, .saving: 0.94...1,
    ]
    /// Pull: fetch the document, check which referenced files this Mac
    /// lacks (hashing), download them, then apply project.json.
    static let pullWeights: [CloudProjectSync.Progress.Phase: ClosedRange<Double>] = [
        .fetching: 0...0.08, .hashing: 0.08...0.2, .downloading: 0.2...0.92, .writing: 0.92...1,
    ]

    /// Signed in → true. Otherwise offers sign-in and re-runs `then` on success.
    private func ensureSignedIn(
        appState: AppState,
        window: NSWindow,
        title: String = String(localized: "Sign in to use the web editor", comment: "Alert title: sign-in is needed before using the web editor"),
        message: String = String(localized: "The web editor opens your project from your CaptureCat account’s cloud storage.", comment: "Alert message explaining why sign-in is needed for the web editor"),
        then: @escaping () -> Void
    ) -> Bool {
        if AuthKeychain.currentToken() != nil { return true }
        let alert = CCAlert(title: title, message: message)
        alert.addButton(String(localized: "Sign In", comment: "Alert button: starts signing in (verb)"), role: .primary)
        alert.addButton(String(localized: "Cancel", comment: "Dialog button: dismisses without doing anything"))
        alert.beginSheet(for: window) { choice in
            guard choice == 0 else { return }
            Task { @MainActor in
                do {
                    try await appState.signIn()
                    then()
                } catch let error where AuthService.isUserCancellation(error) {
                    // Closed the browser tab — nothing to say.
                } catch {
                    let failure = CCAlert(title: String(localized: "Sign-in failed", comment: "Alert title when signing in fails"), message: error.localizedDescription)
                    failure.beginSheet(for: window)
                }
            }
        }
        return false
    }

    /// Write pending in-app edits so the sync reads what the user sees.
    private func flush(_ project: Project, appState: AppState) {
        appState.projectStore.saveIfDirty(project)
        if let open = appState.currentProject, open.id == project.id, open !== project {
            appState.projectStore.saveIfDirty(open)
        }
    }

    private func finish(_ then: @escaping () -> Void) {
        task = nil
        let dialog = progress
        progress = nil
        // The clone is over either way: release its Cloud-section slot AFTER
        // `then` ran, so a success has already adopted the project (it is
        // local now) and the card never flickers back for a frame.
        let cloned = cloningProjectID
        cloningProjectID = nil
        let done = {
            then()
            if let cloned { CloudLibrary.shared.setCloning(cloned, false) }
        }
        if let dialog {
            dialog.dismiss(completion: done)
        } else {
            done()
        }
    }

    private func fail(_ error: Error, title: String, window: NSWindow) {
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            finish {}
            return
        }
        finish {
            let alert = CCAlert(title: title, message: Self.message(for: error))
            alert.beginSheet(for: window)
        }
    }

    /// The server's words where they are already user-facing; plan/storage
    /// refusals rephrased for this feature (the shared upload policy words
    /// them for video shares).
    static func message(for error: Error) -> String {
        guard let sync = error as? CloudSyncError else { return error.localizedDescription }
        if case .api(let status, _, _) = sync, status == 401 {
            return String(localized: "Your CaptureCat session has expired. Sign in again, then retry.", comment: "Error message when the sign-in session expired")
        }
        switch sync.apiCode {
        case "cloud_share_required", "no_storage_allowance":
            return String(localized: "The web editor keeps your project in CaptureCat cloud storage, which your plan doesn’t include. Upgrade to open projects on the web.", comment: "Error message when the user's plan has no cloud storage")
        case "storage_limit_reached":
            // Old versions pin the media they used, so a replaced recording
            // keeps counting until History lets go of it.
            return String(localized: "Your cloud storage is full. Project History still keeps media you replaced — use Free up in History, or delete shared videos or web-editor projects from your dashboard, then try again.", comment: "Error message when cloud storage is full; Free up is a button name in the History panel")
        case "not_owner":
            return String(localized: "This project is in the web editor under another CaptureCat account. Sign in with that account to sync it.", comment: "Error message when the cloud project belongs to a different account")
        default:
            return sync.localizedDescription
        }
    }
}

/// Closure-backed menu row target (the item retains it via representedObject).
final class CloudMenuTarget: NSObject {
    private let handler: () -> Void
    init(handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { handler() }

    static func item(_ title: String, handler: @escaping () -> Void) -> NSMenuItem {
        let target = CloudMenuTarget(handler: handler)
        let item = NSMenuItem(title: title, action: #selector(CloudMenuTarget.fire), keyEquivalent: "")
        item.target = target
        item.representedObject = target
        return item
    }
}

// MARK: - Progress dialog

/// The sync's progress card: status line + CCProgressBar + Cancel, on the
/// house CCDialog (scrim, spring-in, Escape).
@MainActor
final class CloudSyncProgressDialog {
    var onCancel: (() -> Void)?

    private let dialog: CCDialog
    private let status = NSTextField(labelWithString: String(localized: "Preparing…", comment: "Sync progress dialog initial status"))
    private let bar = CCProgressBar()
    private let cancelButton = CCButton(title: String(localized: "Cancel", comment: "Dialog button: dismisses without doing anything"), style: .secondary, size: .regular)
    private var themeObservation: CCThemeObservation?

    init(title: String, subtitle: String) {
        dialog = CCDialog(title: title, subtitle: subtitle, width: 400)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = CCSpace.sm
        stack.translatesAutoresizingMaskIntoConstraints = false

        status.lineBreakMode = .byTruncatingTail
        bar.minValue = 0
        bar.maxValue = 1
        bar.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(status)
        stack.addArrangedSubview(bar)
        bar.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        dialog.addContent(stack)

        cancelButton.onClick = { [weak self] in self?.cancel() }
        dialog.addFooter(cancelButton)
        dialog.onEscape = { [weak self] in self?.cancel() }

        themeObservation = CCThemeObservation { [weak self] in
            self?.status.font = CCTheme.font.label
            self?.status.textColor = CCTheme.color.mutedForeground
        }
    }

    // Probe seams (`--cloud-sync-test`): assert on the real parts, never on
    // `sublayers.first`-style guesses.
    var probeCard: NSView { dialog.card }
    var probeBar: CCProgressBar { bar }
    var probeStatus: String { status.stringValue }
    var probeCancelButton: CCButton { cancelButton }

    func present(over window: NSWindow) {
        dialog.present(over: window)
    }

    func dismiss(completion: (() -> Void)? = nil) {
        dialog.dismiss(completion: completion)
    }

    /// Map a phase-local fraction onto the overall bar. The bar only moves
    /// forward (phases can re-enter, e.g. a restage mid-upload).
    func update(_ step: CloudProjectSync.Progress, weights: [CloudProjectSync.Progress.Phase: ClosedRange<Double>]) {
        if status.stringValue != step.message { status.stringValue = step.message }
        guard let range = weights[step.phase] else { return }
        let overall = range.lowerBound + (range.upperBound - range.lowerBound) * min(max(step.fraction, 0), 1)
        if overall > bar.doubleValue { bar.doubleValue = overall }
    }

    func finish(message: String) {
        status.stringValue = message
        bar.doubleValue = 1
        cancelButton.isEnabled = false
    }

    private func cancel() {
        status.stringValue = String(localized: "Cancelling…", comment: "Sync progress dialog status after the user pressed Cancel")
        cancelButton.isEnabled = false
        onCancel?()
    }
}
