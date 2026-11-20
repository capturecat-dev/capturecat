import UIKit

/// "Delete Account" (App Store Guideline 5.1.1(v)): the whole flow lives in
/// the app — no web redirect, no email.
///
///  1. A destructive confirmation SHEET (house `CCAlert`, rising on the house
///     motion) says what goes: shares and their links, cloud projects and
///     their history, comments, devices, agent connections; an active
///     subscription is cancelled at once; a connected storage bucket's keys
///     are forgotten but its files are never touched; projects on this device
///     go too. "Delete Account" stays disabled until DELETE is typed.
///  2. `DELETE /api/me` with the button busy. Anything but success keeps the
///     sheet open with the reason inline (the server's own words for a team
///     the user still owns, or a subscription that couldn't be cancelled;
///     offline / unreachable say nothing was deleted). A 401 counts as done —
///     an earlier attempt whose answer was lost.
///  3. On success, before the sheet closes, this device's account data is
///     wiped (`wipeLocalData`) — so even a crash right after still leaves
///     nothing behind; the session's 401 signs the app out on next launch.
///  4. The sheet closes, credentials are dropped, the root swaps to the
///     sign-in screen and a toast confirms.
@MainActor
enum AccountDeletion {
    static let title = String(localized: "Delete Account", comment: "Title of the delete-account confirmation sheet")
    static let confirmTitle = String(localized: "Delete Account", comment: "Button in the delete-account sheet: permanently delete the account")
    static let confirmWord = "DELETE"
    static let message = String(localized: "This permanently deletes your CaptureCat account and everything in it: shared videos and their links, cloud projects and their history, comments you've written, connected devices and agent connections. An active subscription is cancelled immediately, with no further charges. If you connected your own storage bucket, we forget its keys but never delete the files in your bucket. Projects on this \(ThisDevice.noun) are removed too. This can't be undone.", comment: "Argument is iPhone or iPad")

    /// True when `text` is the confirmation word (any case, spaces ignored).
    static func isConfirmed(_ text: String?) -> Bool {
        (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == confirmWord
    }

    #if DEBUG
    /// Gate seam (`-accountDeleteInject skip-wipe|skip-signout`): an INJECTED
    /// DEFECT in the shipping path; the account-delete gate must FAIL with it.
    static var probeInject: String? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-accountDeleteInject"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }()
    /// The confirmation on screen (gate seam).
    static weak var probeField: CCField?
    static var probeAlert: CCAlert?
    #endif

    /// Present the confirmation from `presenter` (the Account screen).
    @discardableResult
    static func presentConfirmation(from presenter: UIViewController) -> CCAlert {
        let alert = CCAlert(title: String(localized: "Delete your account?"), message: message)
        alert.symbol = "trash"
        alert.tone = .destructive
        alert.presentation = .sheet

        let hint = ccLabel(String(localized: "To confirm, type \(confirmWord) below.", comment: "Argument is the word DELETE, which stays in English (the user must type it exactly)"), font: CCFont.labelSemibold, color: CCTheme.color.foreground, lines: 0)
        let field = CCField(placeholder: confirmWord)
        field.autocapitalizationType = .allCharacters
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.returnKeyType = .done
        field.accessibilityLabel = String(localized: "Type \(confirmWord) to confirm", comment: "Accessibility label; argument is the word DELETE, which stays in English")
        field.onReturn = { [weak field] _ in field?.resignFirstResponder() }
        let accessory = UIStackView(arrangedSubviews: [hint, field])
        accessory.axis = .vertical
        accessory.spacing = CCSpace.sm
        alert.accessoryView = accessory

        var result: AccountDeletionResult?
        alert.addButton(confirmTitle, role: .destructive) { [weak field] in
            field?.unmarkText()
            guard isConfirmed(field?.text) else { throw ConfirmError.notTyped }
            let outcome = try await AppEnvironment.shared.api.deleteAccount()
            // The account is gone: nothing of it may stay on this device,
            // whatever happens next.
            wipeLocalData()
            result = outcome
        }
        alert.addButton(String(localized: "Cancel", comment: "Alert button"), role: .cancel)
        alert.setButtonEnabled(0, false)
        field.onTextChange = { [weak alert] text in alert?.setButtonEnabled(0, isConfirmed(text)) }
        #if DEBUG
        probeField = field
        probeAlert = alert
        #endif
        alert.present(from: presenter) { index in
            #if DEBUG
            probeAlert = nil
            #endif
            guard index == 0, let result else { return }
            Task { await finish(result) }
        }
        return alert
    }

    enum ConfirmError: LocalizedError {
        case notTyped
        var errorDescription: String? { String(localized: "Type \(AccountDeletion.confirmWord) to confirm.", comment: "Error; argument is the word DELETE, which stays in English") }
    }

    /// After the sheet closed: drop the credentials (the root swaps to the
    /// sign-in screen on `.ccSessionDidChange`) and say it's done.
    static func finish(_ result: AccountDeletionResult) async {
        #if DEBUG
        if probeInject == "skip-signout" { return }
        #endif
        await AppEnvironment.shared.session.endAfterAccountDeletion()
        CCHaptics.success()
        AppToaster.shared.show(
            title: String(localized: "Your account was deleted"),
            message: result.cancelledSubscriptions > 0
                ? String(localized: "Your subscription was cancelled. Thanks for using CaptureCat.")
                : String(localized: "Thanks for using CaptureCat."),
            variant: .success, symbol: "trash"
        )
    }

    // MARK: - This device

    /// Every account-derived thing this device keeps, in the app sandbox and
    /// the App Group: studio projects (and their sync state + history), the
    /// upload inbox, the library's caches, exports in progress, URL caches,
    /// the per-account App Group keys and this device's id (a new one is
    /// minted on the next sign-in). Credentials go in `finish`. Downloaded
    /// tools that hold no account data (the transcription model) stay.
    static func wipeLocalData() {
        #if DEBUG
        if probeInject == "skip-wipe" { return }
        #endif
        if #available(iOS 26, *) {
            StudioCloudSync.resetSessions()
            StudioCloudSync.environment = nil
            try? FileManager.default.removeItem(at: StudioExportJob.exportsDirectory)
        }
        let fm = FileManager.default
        try? fm.removeItem(at: StudioEditorEntry.projectsRoot)
        for take in TakeInbox.all() { TakeInbox.remove(take.id) }
        // Folders a half-written take left without a take.json.
        if let leftovers = try? fm.contentsOfDirectory(at: TakeInbox.root, includingPropertiesForKeys: nil) {
            leftovers.forEach { try? fm.removeItem(at: $0) }
        }
        UploadCenter.shared.reload()
        LibraryStore.shared.reset()
        URLCache.shared.removeAllCachedResponses()
        let group = AppGroup.defaults
        for key in [AppGroup.Keys.preferredMacID, AppGroup.Keys.lastLinkKeyID, AppGroup.Keys.broadcastMode, AppGroup.Keys.deviceID] {
            group.removeObject(forKey: key)
        }
    }

    /// What `wipeLocalData` must leave empty (gate seam; also a cheap
    /// self-check). Each entry: a description of what is still there.
    static func leftovers() -> [String] {
        let fm = FileManager.default
        var found: [String] = []
        func contents(_ url: URL) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).filter { !$0.hasPrefix(".") }
        }
        let studio = contents(StudioEditorEntry.projectsRoot)
        if !studio.isEmpty { found.append("studio projects: \(studio.joined(separator: ", "))") }
        let inbox = contents(TakeInbox.root)
        if !inbox.isEmpty { found.append("inbox takes: \(inbox.joined(separator: ", "))") }
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("CaptureCatLibrary", isDirectory: true)
        for sub in ["facts", "thumbs"] {
            let files = contents(caches.appendingPathComponent(sub))
            if !files.isEmpty { found.append("library \(sub): \(files.count) file(s)") }
        }
        if #available(iOS 26, *) {
            let exports = contents(StudioExportJob.exportsDirectory)
            if !exports.isEmpty { found.append("exports: \(exports.joined(separator: ", "))") }
        }
        if AppGroup.defaults.string(forKey: AppGroup.Keys.preferredMacID) != nil { found.append("preferred Mac") }
        return found
    }
}
