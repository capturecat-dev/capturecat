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
            makeItem("Open in Web Editor") {
                CloudSyncController.shared.openInWebEditor(project: project, appState: appState, window: window())
            },
            makeItem("Pull Web Edits") {
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
             title: "Opening in Web Editor", openWeb: true)
    }

    /// History ▸ "Sync now": the same push, without opening the browser.
    func syncNow(project: Project, appState: AppState, window: NSWindow?) {
        push(project: project, appState: appState, window: window, overwriteRevision: nil,
             title: "Syncing", openWeb: false)
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
                    dialog.finish(message: openWeb ? "Opening your browser…" : "Synced")
                    self.finish {
                        self.announce(projectID)
                        openBrowser()
                    }
                case .merged(_, let report):
                    dialog.finish(message: openWeb ? "Merged — opening your browser…" : "Merged")
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
                self?.fail(error, title: openWeb ? "Couldn’t open in the web editor" : "Couldn’t sync", window: window)
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
        let dialog = CloudSyncProgressDialog(title: "Merging", subtitle: project.name)
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
                    dialog.finish(message: "Merged")
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
                self?.fail(error, title: "Couldn’t merge", window: window)
            }
        }
    }

    /// "Merged 2 changes from Ana (Web)" — a CCToaster toast in `window`.
    func toast(_ report: CloudMergeReport, in window: NSWindow) {
        let settled = report.autoResolved.count
        var notes: [String] = []
        if settled > 0 { notes.append(settled == 1 ? "1 clash went to the latest edit" : "\(settled) clashes went to the latest edit") }
        if report.conflictsResolved > 0 {
            notes.append(report.conflictsResolved == 1 ? "1 conflict resolved" : "\(report.conflictsResolved) conflicts resolved")
        }
        notes.append("Both versions are kept in History.")
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
            title: "Edited in both places",
            message: "This project changed in the web editor and on this Mac since they last synced. "
                + "Pull Web Edits replaces this Mac’s unsynced changes with the web’s version; "
                + "Replace Web Version overwrites the web’s changes with this Mac’s."
        )
        // Reached only without a merge base (an older build's sidecar and a
        // revision the server no longer retains) — otherwise both sides
        // merge three-way and this two-way choice never appears.
        alert.addButton("Pull Web Edits", role: .primary)
        alert.addButton("Replace Web Version", role: .destructive)
        alert.addButton("Cancel")
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
        thenOpenWeb: Bool = false
    ) {
        guard task == nil, let window = window ?? appState.authPresentationWindow() else { return }
        guard ensureSignedIn(appState: appState, window: window, then: { [weak self] in
            self?.pullWebEdits(project: project, appState: appState, window: window, force: force, thenOpenWeb: thenOpenWeb)
        }) else { return }
        // Save first: the pull compares the file on disk with the last sync,
        // and the GUI only reloads a CLEAN project from an external write.
        flush(project, appState: appState)

        let dialog = CloudSyncProgressDialog(title: "Pulling Web Edits", subtitle: project.name)
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
                    dialog.finish(message: "Pulled revision \(revision)")
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
                    dialog.finish(message: files == 0 ? "Updated file references"
                                  : files == 1 ? "Downloaded 1 missing file" : "Downloaded \(files) missing files")
                    try? await Task.sleep(for: .milliseconds(450))
                    self.finish {
                        if thenOpenWeb { NSWorkspace.shared.open(CaptureCatAPI.webEditorURL(projectID: projectID)) }
                    }
                case .upToDate:
                    self.finish {
                        if thenOpenWeb {
                            NSWorkspace.shared.open(CaptureCatAPI.webEditorURL(projectID: projectID))
                        } else {
                            let alert = CCAlert(title: "Already up to date",
                                                message: "This Mac has the web editor’s latest version of “\(project.name)”.")
                            alert.beginSheet(for: window)
                        }
                    }
                case .noCloudCopy:
                    self.finish {
                        let alert = CCAlert(title: "Not in the web editor yet",
                                            message: "Open “\(project.name)” in the web editor first — its edits can then be pulled back here.")
                        alert.addButton("Open in Web Editor", role: .primary)
                        alert.addButton("Cancel")
                        alert.beginSheet(for: window) { [weak self] choice in
                            if choice == 0 { self?.openInWebEditor(project: project, appState: appState, window: window) }
                        }
                    }
                case .merged(_, let report):
                    // The web's edits merged INTO this Mac's unsynced ones
                    // (written atomically — the external-edit poll reloads
                    // the editor); this Mac's side goes up with the next push.
                    dialog.finish(message: "Merged web edits")
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
                            title: "Replace this Mac’s changes?",
                            message: "The web editor has a newer version (revision \(remoteRevision)), and this project "
                                + "has changes on this Mac that were never sent to the web. Pulling replaces them."
                        )
                        alert.addButton("Pull and Replace", role: .destructive)
                        alert.addButton("Cancel")
                        alert.beginSheet(for: window) { [weak self] choice in
                            if choice == 0 {
                                self?.pullWebEdits(project: project, appState: appState, window: window,
                                                   force: true, thenOpenWeb: thenOpenWeb)
                            }
                        }
                    }
                }
            } catch {
                self?.fail(error, title: "Couldn’t pull web edits", window: window)
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
    private func ensureSignedIn(appState: AppState, window: NSWindow, then: @escaping () -> Void) -> Bool {
        if AuthKeychain.currentToken() != nil { return true }
        let alert = CCAlert(
            title: "Sign in to use the web editor",
            message: "The web editor opens your project from your CaptureCat account’s cloud storage."
        )
        alert.addButton("Sign In", role: .primary)
        alert.addButton("Cancel")
        alert.beginSheet(for: window) { choice in
            guard choice == 0 else { return }
            Task { @MainActor in
                do {
                    try await appState.signIn()
                    then()
                } catch let error where AuthService.isUserCancellation(error) {
                    // Closed the browser tab — nothing to say.
                } catch {
                    let failure = CCAlert(title: "Sign-in failed", message: error.localizedDescription)
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
        if let dialog {
            dialog.dismiss(completion: then)
        } else {
            then()
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
            return "Your CaptureCat session has expired. Sign in again, then retry."
        }
        switch sync.apiCode {
        case "cloud_share_required", "no_storage_allowance":
            return "The web editor keeps your project in CaptureCat cloud storage, which your plan doesn’t include. "
                + "Upgrade to open projects on the web."
        case "storage_limit_reached":
            // Old versions pin the media they used, so a replaced recording
            // keeps counting until History lets go of it.
            return "Your cloud storage is full. Project History still keeps media you replaced — use Free up in "
                + "History, or delete shared videos or web-editor projects from your dashboard, then try again."
        case "not_owner":
            return "This project is in the web editor under another CaptureCat account. Sign in with that account to sync it."
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
    private let status = NSTextField(labelWithString: "Preparing…")
    private let bar = CCProgressBar()
    private let cancelButton = CCButton(title: "Cancel", style: .secondary, size: .regular)
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
        status.stringValue = "Cancelling…"
        cancelButton.isEnabled = false
        onCancel?()
    }
}
