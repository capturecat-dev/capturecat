import AppKit

/// History ▸ Preview: an earlier cloud version shown READ-ONLY in the editor.
///
/// The version's document is decoded into a separate `Project` with
/// `isPreview` set — `ProjectStore` refuses to save it, so autosave, close
/// and quit can never write it over the real project.json. The editor swaps
/// to it the way an external edit swaps (`currentProject` + reload token),
/// and the stage carries a `CCCallout`: "Viewing Sep 28, 3:42 PM — Ana on
/// Web" with [Restore] [Back to Current]. Media resolve to this Mac's copies
/// (the same re-pointing a pull does); a file only that version had shows as
/// missing in the preview — restoring brings it back.
@MainActor
final class VersionPreviewController {
    static let shared = VersionPreviewController()

    struct Session {
        let projectID: UUID
        let version: CloudVersion
        let environment: EditorHistoryEnvironment
        weak var appState: AppState?
    }

    private(set) var session: Session?

    /// "Viewing Sep 28, 3:42 PM — Ana on Web" (shared: HistoryWords).
    static func title(for version: CloudVersion) -> String { HistoryWords.previewTitle(for: version) }

    func begin(preview: Project, version: CloudVersion, appState: AppState,
               environment: EditorHistoryEnvironment, window: NSWindow?) {
        guard preview.isPreview else { return }
        session = Session(projectID: preview.id, version: version, environment: environment, appState: appState)
        appState.currentProject = preview
        appState.editorReloadToken += 1
    }

    /// Back to the real project (the store's instance, freshly loaded).
    func backToCurrent() {
        guard let session, let appState = session.appState else {
            self.session = nil
            return
        }
        self.session = nil
        let id = session.projectID
        if let real = appState.projectStore.projects.first(where: { $0.id == id }) {
            appState.currentProject = real
        }
        appState.editorReloadToken += 1
    }

    /// The stage callout for a preview project (nil for a real one).
    func makeCallout(for project: Project, window: @escaping () -> NSWindow?) -> CCCallout? {
        guard project.isPreview, let session, session.projectID == project.id else { return nil }
        return Self.callout(
            version: session.version,
            onRestore: { [weak self] in self?.restore(project: project, window: window()) },
            onBack: { [weak self] in self?.backToCurrent() })
    }

    /// The callout itself — shared with `--history-panel-shot`.
    static func callout(version: CloudVersion, onRestore: @escaping () -> Void, onBack: @escaping () -> Void) -> CCCallout {
        let callout = CCCallout(title: title(for: version),
                                message: HistoryWords.previewMessage,
                                variant: .info)
        callout.setActions([
            CCButton(title: String(localized: "Restore", comment: "Button: restores the project to this history version (verb)"), symbol: "clock.arrow.circlepath", style: .primary, size: .sm, onClick: onRestore),
            CCButton(title: String(localized: "Back to Current", comment: "Version preview callout button: leaves the preview and returns to the current project"), style: .secondary, size: .sm, onClick: onBack),
        ])
        return callout
    }

    private func restore(project: Project, window: NSWindow?) {
        guard let session, let window, let appState = session.appState else { return }
        let version = session.version
        let alert = CCAlert(title: HistoryWords.restoreTitle(version), message: HistoryWords.restoreMessage)
        alert.addButton(String(localized: "Restore", comment: "Button: restores the project to this history version (verb)"), role: .primary)
        alert.addButton(String(localized: "Cancel", comment: "Dialog button: dismisses without doing anything"))
        alert.beginSheet(for: window) { [weak self] choice in
            guard choice == 0 else { return }
            guard let real = appState.projectStore.projects.first(where: { $0.id == project.id }) else { return }
            let dialog = CloudSyncProgressDialog(title: String(localized: "Restoring", comment: "Progress dialog title while restoring a history version"), subtitle: HistoryPaneAppKit.stamp(version.date))
            dialog.present(over: window)
            let client = session.environment.client
            let directory = session.environment.directory(real)
            Task { @MainActor [weak self] in
                do {
                    let outcome = try await client.restore(versionID: version.id, project: real,
                                                           projectDirectory: directory) { step in
                        dialog.update(step, weights: CloudSyncController.pushWeights)
                    }
                    dialog.finish(message: String(localized: "Restored", comment: "Progress dialog status: the history version was restored"))
                    dialog.dismiss {
                        // The pull rewrote project.json; the external-edit poll
                        // reloads the real project — leave the preview now.
                        self?.backToCurrent()
                        if case .restored = outcome {
                            CloudSyncController.shared.showToast(
                                title: HistoryWords.restoredToast(version),
                                message: HistoryWords.restoredToastMessage,
                                symbol: "clock.arrow.circlepath", in: window)
                        } else {
                            CCAlert(title: String(localized: "Sync first", comment: "Alert title: local changes must be synced before restoring a version"),
                                    message: String(localized: "This Mac has changes that conflict with the cloud. Sync them, then restore.", comment: "Alert message: local changes must be synced before restoring a version"))
                                .beginSheet(for: window)
                        }
                        NotificationCenter.default.post(name: CloudSyncController.didSyncNotification, object: real.id)
                    }
                } catch {
                    dialog.dismiss {
                        CCAlert(title: String(localized: "Couldn’t restore that version", comment: "Alert title when restoring a history version fails"),
                                message: CloudSyncController.message(for: error)).beginSheet(for: window)
                    }
                }
            }
        }
    }
}
