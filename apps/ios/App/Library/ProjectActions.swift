import UIKit

/// The project/share actions every screen offers (detail screens, the
/// library card's long-press sheet) — one implementation, house dialogs.
enum ProjectActions {
    enum RenameError: LocalizedError {
        case notSynced
        case busy

        var errorDescription: String? {
            switch self {
            case .notSynced: return "This project hasn't finished syncing yet. Try again in a moment."
            case .busy: return "Someone else is editing this project right now. Try again in a moment."
            }
        }
    }

    /// Rename = a LOSSLESS edit of project.json (only `name` changes), saved
    /// with If-Match on the revision we loaded. On a conflict, the rename is
    /// re-applied onto the document the server returned and saved once more.
    static func rename(projectID: String, to name: String) async throws {
        let api = AppEnvironment.shared.api
        let detail = try await LibraryStore.shared.detail(for: projectID, fresh: true)
        guard let text = detail.document, let data = text.data(using: .utf8) else { throw RenameError.notSynced }
        let renamed = try ProjectDocument.renamed(data, to: name)
        var newRevision: Int
        switch try await api.saveProject(projectID, document: renamed, baseRevision: detail.revision) {
        case .saved(let revision):
            newRevision = revision
        case .conflict(let revision, let theirs):
            guard let theirs, let theirData = theirs.data(using: .utf8) else { throw RenameError.notSynced }
            let rebased = try ProjectDocument.renamed(theirData, to: name)
            switch try await api.saveProject(projectID, document: rebased, baseRevision: revision) {
            case .saved(let revision): newRevision = revision
            case .conflict: throw RenameError.busy
            }
        }
        LibraryStore.shared.didRename(projectID, to: name, revision: newRevision)
        NotificationCenter.default.post(name: .ccLibraryShouldRefresh, object: nil)
    }

    static func promptRename(projectID: String, currentName: String, from presenter: UIViewController, done: ((String) -> Void)? = nil) {
        CCAlert.prompt(
            title: "Rename",
            message: "The new name shows everywhere — on your Mac, the web and here.",
            placeholder: "Project name",
            initialValue: currentName,
            confirmTitle: "Rename",
            from: presenter,
            action: { name in
                guard name != currentName else { return }
                try await rename(projectID: projectID, to: name)
            },
            completion: { name in
                guard let name, name != currentName else { return }
                CCHaptics.success()
                AppToaster.shared.show(title: "Renamed", message: name, variant: .success)
                done?(name)
            }
        )
    }

    static func confirmDelete(projectID: String, name: String, from presenter: UIViewController, done: (() -> Void)? = nil) {
        CCAlert.confirm(
            title: "Delete “\(name)”?",
            message: "It's removed from your library on every device — Mac, web and here. Shared links made from it keep working.",
            confirmTitle: "Delete",
            destructive: true,
            from: presenter,
            action: {
                try await AppEnvironment.shared.api.deleteCloudProject(projectID)
            },
            completion: { confirmed in
                guard confirmed else { return }
                LibraryStore.shared.didDelete(projectID)
                NotificationCenter.default.post(name: .ccLibraryShouldRefresh, object: nil)
                AppToaster.shared.show(title: "Project deleted", message: name, variant: .default, symbol: "trash")
                done?()
            }
        )
    }

    static func confirmDiscard(_ take: PendingTake, from presenter: UIViewController) {
        CCAlert.confirm(
            title: "Discard this take?",
            message: "“\(take.name)” hasn't uploaded yet. Discarding deletes it from this iPhone.",
            confirmTitle: "Discard",
            destructive: true,
            from: presenter
        ) { confirmed in
            guard confirmed else { return }
            AppEnvironment.shared.inbox.discard(take.id)
        }
    }

    static func openInWebEditor(projectID: String) {
        let url = CaptureCatAPI.webEditorURL(projectID: projectID)
        #if DEBUG
        if AppEnvironment.shared.isFixture {
            AppToaster.shared.show(title: "Opens the web editor", message: url.absoluteString, symbol: "globe")
            return
        }
        #endif
        UIApplication.shared.open(url)
    }

    static func copyLink(_ share: SharedVideo) {
        UIPasteboard.general.url = share.url
        CCHaptics.success()
        AppToaster.shared.show(title: "Link copied", message: share.url.absoluteString, variant: .success, symbol: "link")
    }

    /// The system share sheet (allowed system UI) for a share link.
    static func shareSheet(_ share: SharedVideo, from presenter: UIViewController, source: UIView) {
        let controller = UIActivityViewController(activityItems: [share.url], applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = source
        controller.popoverPresentationController?.sourceRect = source.bounds
        presenter.present(controller, animated: true)
    }
}
