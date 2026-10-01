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

    static func title(for version: CloudVersion) -> String {
        // "Ana on Web"; an agent's or mixed save names the badge instead
        // ("Ana (Agent via Web)").
        let who: String
        switch (version.actorName, version.source) {
        case (let name?, "human"): who = "\(name) on \(version.clientLabel)"
        case (let name?, _): who = "\(name) (\(version.clientLabel))"
        default: who = version.clientLabel
        }
        return "Viewing \(HistoryPaneAppKit.stamp(version.date)) — \(who)"
    }

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
                                message: "Read-only preview — edits here are not saved.",
                                variant: .info)
        callout.setActions([
            CCButton(title: "Restore", symbol: "clock.arrow.circlepath", style: .primary, size: .sm, onClick: onRestore),
            CCButton(title: "Back to Current", style: .secondary, size: .sm, onClick: onBack),
        ])
        return callout
    }

    private func restore(project: Project, window: NSWindow?) {
        guard let session, let window, let appState = session.appState else { return }
        let version = session.version
        let alert = CCAlert(
            title: "Restore the version from \(HistoryPaneAppKit.stamp(version.date))?",
            message: "Your current version stays in History — restoring adds this one as the newest version.")
        alert.addButton("Restore", role: .primary)
        alert.addButton("Cancel")
        alert.beginSheet(for: window) { [weak self] choice in
            guard choice == 0 else { return }
            guard let real = appState.projectStore.projects.first(where: { $0.id == project.id }) else { return }
            let dialog = CloudSyncProgressDialog(title: "Restoring", subtitle: HistoryPaneAppKit.stamp(version.date))
            dialog.present(over: window)
            let client = session.environment.client
            let directory = session.environment.directory(real)
            Task { @MainActor [weak self] in
                do {
                    let outcome = try await client.restore(versionID: version.id, project: real,
                                                           projectDirectory: directory) { step in
                        dialog.update(step, weights: CloudSyncController.pushWeights)
                    }
                    dialog.finish(message: "Restored")
                    dialog.dismiss {
                        // The pull rewrote project.json; the external-edit poll
                        // reloads the real project — leave the preview now.
                        self?.backToCurrent()
                        if case .restored = outcome {
                            CloudSyncController.shared.showToast(
                                title: "Restored the version from \(HistoryPaneAppKit.stamp(version.date))",
                                message: "The version before it is still in History.",
                                symbol: "clock.arrow.circlepath", in: window)
                        } else {
                            CCAlert(title: "Sync first",
                                    message: "This Mac has changes that conflict with the cloud. Sync them, then restore.")
                                .beginSheet(for: window)
                        }
                        NotificationCenter.default.post(name: CloudSyncController.didSyncNotification, object: real.id)
                    }
                } catch {
                    dialog.dismiss {
                        CCAlert(title: "Couldn’t restore that version",
                                message: CloudSyncController.message(for: error)).beginSheet(for: window)
                    }
                }
            }
        }
    }
}
