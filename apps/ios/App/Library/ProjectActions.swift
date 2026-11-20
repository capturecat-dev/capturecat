import UIKit

/// The project/share actions every screen offers (detail screens, the
/// library card's long-press sheet) — one implementation, house dialogs.
enum ProjectActions {
    enum RenameError: LocalizedError {
        case notSynced
        case busy

        var errorDescription: String? {
            switch self {
            case .notSynced: return String(localized: "This project hasn't finished syncing yet. Try again in a moment.")
            case .busy: return String(localized: "Someone else is editing this project right now. Try again in a moment.")
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
            title: String(localized: "Rename", comment: "Rename dialog title"),
            message: String(localized: "The new name shows everywhere — on your Mac, the web and here."),
            placeholder: String(localized: "Project name", comment: "Rename dialog: text field placeholder"),
            initialValue: currentName,
            confirmTitle: String(localized: "Rename", comment: "Rename dialog: confirm button"),
            from: presenter,
            action: { name in
                guard name != currentName else { return }
                try await rename(projectID: projectID, to: name)
            },
            completion: { name in
                guard let name, name != currentName else { return }
                CCHaptics.success()
                AppToaster.shared.show(title: String(localized: "Renamed", comment: "Toast after a project was renamed"), message: name, variant: .success)
                done?(name)
            }
        )
    }

    enum HandoffError: LocalizedError {
        case noMac
        var errorDescription: String? { String(localized: "Still can't find your Mac. Is CaptureCat open on it?") }
    }

    /// "Continue on Mac": the connected Mac opens this project in its editor
    /// (cloning it if needed). With no Mac on the local network, explain the
    /// two other ways — Handoff from the Dock, or the web editor.
    static func continueOnMac(projectID: String, name: String, from presenter: UIViewController) {
        let progress = AppToaster.shared.show(title: String(localized: "Opening on your Mac…"), message: name, symbol: "desktop")
        Task { @MainActor in
            let result = await AppEnvironment.shared.capture.continueOnMac(projectID: projectID, name: name)
            progress?.dismiss()
            switch result {
            case let .opened(macName):
                CCHaptics.success()
                AppToaster.shared.show(title: String(localized: "Opened on \(macName)", comment: "Toast; argument is the Mac's name"), message: name, variant: .success, symbol: "desktop")
            case .refused:
                AppToaster.shared.show(title: String(localized: "Your Mac couldn't open it"), message: String(localized: "Try again, or open it in the web editor."), variant: .warning)
            case .noMac, .signedOut:
                presentNoMac(projectID: projectID, name: name, from: presenter)
            }
        }
    }

    private static func presentNoMac(projectID: String, name: String, from presenter: UIViewController) {
        let alert = CCAlert(
            title: String(localized: "Couldn't reach your Mac"),
            message: String(localized: "Open CaptureCat on your Mac — same Wi-Fi, same account — and try again. Or use Handoff: while this project is open here, CaptureCat shows up in your Mac's Dock.")
        )
        alert.addButton(String(localized: "Try again", comment: "Alert button: retry opening the project on the Mac"), role: .primary) {
            let result = await AppEnvironment.shared.capture.continueOnMac(projectID: projectID, name: name)
            guard case let .opened(macName) = result else { throw HandoffError.noMac }
            CCHaptics.success()
            AppToaster.shared.show(title: String(localized: "Opened on \(macName)", comment: "Toast; argument is the Mac's name"), message: name, variant: .success, symbol: "desktop")
        }
        alert.addButton(String(localized: "Open in web editor", comment: "Alert button")) { openInWebEditor(projectID: projectID) }
        alert.addButton(String(localized: "Cancel", comment: "Alert button"), role: .cancel)
        alert.present(from: presenter)
    }

    static func confirmDelete(projectID: String, name: String, from presenter: UIViewController, done: (() -> Void)? = nil) {
        CCAlert.confirm(
            title: String(localized: "Delete “\(name)”?", comment: "Delete confirmation title; argument is the project name"),
            message: String(localized: "It's removed from your library on every device — Mac, web and here. Shared links made from it keep working."),
            confirmTitle: String(localized: "Delete", comment: "Delete confirmation: confirm button"),
            destructive: true,
            from: presenter,
            action: {
                try await AppEnvironment.shared.api.deleteCloudProject(projectID)
            },
            completion: { confirmed in
                guard confirmed else { return }
                LibraryStore.shared.didDelete(projectID)
                NotificationCenter.default.post(name: .ccLibraryShouldRefresh, object: nil)
                AppToaster.shared.show(title: String(localized: "Project deleted", comment: "Toast"), message: name, variant: .default, symbol: "trash")
                done?()
            }
        )
    }

    static func confirmDiscard(_ take: PendingTake, from presenter: UIViewController) {
        CCAlert.confirm(
            title: String(localized: "Discard this take?", comment: "Confirmation title: delete a recording that hasn't uploaded"),
            message: String(localized: "“\(take.name)” hasn't uploaded yet. Discarding deletes it from this \(ThisDevice.noun).", comment: "First argument is the recording name, second is iPhone or iPad"),
            confirmTitle: String(localized: "Discard", comment: "Confirm button: delete the un-uploaded recording"),
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
        AppToaster.shared.show(title: String(localized: "Link copied", comment: "Toast after copying a share link"), message: share.url.absoluteString, variant: .success, symbol: "link")
    }

    /// The system share sheet (allowed system UI) for a share link.
    static func shareSheet(_ share: SharedVideo, from presenter: UIViewController, source: UIView) {
        let controller = UIActivityViewController(activityItems: [share.url], applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = source
        controller.popoverPresentationController?.sourceRect = source.bounds
        presenter.present(controller, animated: true)
    }
}
