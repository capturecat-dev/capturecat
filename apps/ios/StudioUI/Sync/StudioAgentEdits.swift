import Foundation
import UIKit

/// "Edited by Claude" — background edits made by the user's own AI agent
/// through the cloud MCP server (`apps/api/src/mcp/`) arriving in an open
/// editor.
///
/// The edit itself comes in through the sync's ordinary pull (the head poll,
/// foreground, a push that lost the race, or the "AI finished editing"
/// notification): unsent work here merges three-way exactly as it does for
/// any other concurrent change, and conflicts take the usual Merge Review /
/// two-way path. This type only looks at WHO made the revisions that just
/// came in: the cloud's History marks an agent's save (`source: agent`,
/// `X-CC-Source: agent`) and names the agent (`agent.name` — the OAuth
/// client's own name, e.g. "Claude"). When one did, the editor shows a small
/// notice with Undo, and the head poll runs faster for a while (agents save
/// in bursts).
///
/// **Undo never deletes.** It puts back what this device held before the
/// agent's edit, as a NEW revision:
/// - clean case (the agent's version is still the head, nothing unsent here,
///   and the version this device last agreed with is in History): the
///   server's own restore of that version (History shows "Restored"), then a
///   pull — the same path History's Restore takes;
/// - otherwise (edits were made since, here or elsewhere): only the agent's
///   change is reverted, three-way — base = the agent's document, mine = this
///   editor now, theirs = the document before the agent — and pushed like any
///   edit. Edits made after the agent's stay.
/// Either way it is ONE undo step on the editor ("Undo AI Edit").
@available(iOS 26, *)
@MainActor
final class StudioAgentEdits {
    struct Edit: Equatable {
        /// The newest agent version that came in.
        let versionID: String
        let revision: Int
        /// The revision this device agreed with before it came in.
        let agreedRevision: Int
        /// History's version holding `agreedRevision` (nil when coalesced away).
        let undoVersionID: String?
        /// The agent's version is a fresh one (not a continuation of a
        /// version this device had already seen).
        let isFreshVersion: Bool
        let agentName: String?
        /// "Zoom added · Text added" (History's change summary).
        let summary: String
        /// What the editor held just before the pull, and what it adopted.
        let before: Data
        let after: Data

        var title: String {
            if let agentName { return String(localized: "Edited by \(agentName)", comment: "Notice in the editor when the user's AI agent changed the open project; the argument is the agent's name, e.g. Claude") }
            return String(localized: "Edited by your AI agent", comment: "Notice in the editor when an unnamed AI agent changed the open project")
        }
    }

    enum UndoError: LocalizedError {
        case nothingToUndo
        var errorDescription: String? {
            String(localized: "There's nothing to undo — the AI's edit isn't in this project any more.", comment: "Error when undoing an AI agent's edit that is gone")
        }
    }

    enum UndoPath: String { case serverRestore = "server-restore", revert = "revert" }

    private weak var sync: StudioCloudSync?
    /// The last agent edit that came in (the gate reads it).
    private(set) var last: Edit?
    private var hotUntil: Date?
    /// How long the head poll stays fast after an agent edit.
    var hotWindow: TimeInterval = 120
    /// The fast poll interval while hot.
    var hotPollInterval: TimeInterval = 5
    /// Seconds the notice stays up.
    var noticeDuration: TimeInterval = 10
    /// Harness: every agent edit noticed.
    var onEdit: ((Edit) -> Void)?
    #if DEBUG
    /// Gate self-test (`-agentEditInject`): a defect in the shipping path —
    /// "skip-notice" never notices, "undo-noop" undoes nothing. The gate must FAIL.
    static var probeInject: String?
    /// Probe seams: the notice on screen, the path the last Undo took.
    private(set) weak var probeNotice: CCToast?
    private(set) var probeLastUndoPath: UndoPath?
    #endif

    init(sync: StudioCloudSync) {
        self.sync = sync
    }

    var isHot: Bool { hotUntil.map { $0 > Date() } ?? false }

    /// The head poll's interval right now.
    func pollInterval(default value: TimeInterval) -> TimeInterval {
        isHot ? min(value, hotPollInterval) : value
    }

    // MARK: - Noticing

    /// The cloud's changes just landed in the editor (`before` → `after`):
    /// look up who made the revisions past `agreed`.
    func cloudChanged(since agreed: Int?, before: Data?, after: Data?) {
        guard let agreed, let before, let after else { return }
        Task { @MainActor [weak self] in await self?.detect(since: agreed, before: before, after: after) }
    }

    @discardableResult
    func detect(since agreed: Int, before: Data, after: Data) async -> Edit? {
        guard let sync, let page = try? await sync.history.page(projectID: sync.projectID) else { return nil }
        let versions = page.versions.sorted { $0.seq > $1.seq }
        guard let agent = versions.first(where: { $0.revision > agreed && ($0.source == "agent" || $0.source == "mixed") })
        else { return nil }
        #if DEBUG
        if Self.probeInject == "skip-notice" { return nil }
        #endif
        let target = versions.first(where: { $0.revision <= agreed })
        let edit = Edit(
            versionID: agent.id, revision: agent.revision, agreedRevision: agreed,
            undoVersionID: target?.revision == agreed ? target?.id : nil,
            isFreshVersion: (agent.firstRevision ?? agent.revision) > agreed,
            agentName: agent.agentName, summary: agent.summary, before: before, after: after)
        last = edit
        hotUntil = Date().addingTimeInterval(hotWindow)
        StudioCloudSync.trace?("agent edit by \(edit.agentName ?? "an agent") at revision \(edit.revision) (agreed \(agreed)): \(edit.summary)")
        onEdit?(edit)
        present(edit)
        return edit
    }

    private func present(_ edit: Edit) {
        guard let editor = sync?.editor, editor.viewIfLoaded?.window != nil else { return }
        let toast = Self.notice(in: editor, title: edit.title, summary: edit.summary, duration: noticeDuration) { [weak self, weak editor] in
            guard let self, let editor else { return }
            Task { @MainActor in await self.runUndo(edit, in: editor) }
        }
        #if DEBUG
        probeNotice = toast
        #else
        _ = toast
        #endif
    }

    /// The "Edited by …" notice with its Undo (one look for the app and the l10n audit).
    @discardableResult
    static func notice(in editor: EditorViewController, title: String, summary: String, duration: TimeInterval,
                       undo: @escaping () -> Void) -> CCToast {
        let action = CCToast.Action(title: String(localized: "Undo", comment: "Button on the AI-edit notice that puts the project back"), handler: undo)
        return StudioHistory.toast(in: editor, title: title, message: summary, variant: .default,
                                   symbol: "sparkles", action: action, duration: duration)
    }

    #if DEBUG
    /// The l10n audit (StudioLab `--l10n`): the notice as an agent edit by
    /// "Claude" that changed the background and effects raises it, plus the unnamed-agent title.
    @discardableResult
    static func probeShowNotice(in editor: EditorViewController, named: Bool) -> CCToast {
        let summary = [String(localized: "Background changed", comment: "History row caption phrase (phrases are joined with \" · \")"),
                       String(localized: "Effects changed", comment: "History row caption phrase (phrases are joined with \" · \")")]
            .joined(separator: ChangeSummary.separator)
        let edit = Edit(versionID: "probe", revision: 2, agreedRevision: 1, undoVersionID: nil, isFreshVersion: true,
                        agentName: named ? "Claude" : nil, summary: summary, before: Data(), after: Data())
        return notice(in: editor, title: edit.title, summary: edit.summary, duration: 30) {}
    }
    #endif

    private func runUndo(_ edit: Edit, in editor: EditorViewController) async {
        do {
            try await undo(edit)
            StudioHistory.toast(in: editor, title: String(localized: "AI edit undone", comment: "Toast after undoing an AI agent's edit"),
                                message: String(localized: "The version before it is back, as a new version in History.", comment: "Toast detail after undoing an AI agent's edit"),
                                variant: .success)
        } catch {
            StudioHistory.toast(in: editor, title: String(localized: "Couldn't undo the AI edit", comment: "Toast when undoing an AI agent's edit failed"),
                                message: CloudHistoryClient.historyMessage(for: error) ?? error.localizedDescription,
                                variant: .destructive)
        }
    }

    // MARK: - Undo

    /// Puts back what this device held before `edit`, as a new revision
    /// (see the type comment). One undo step on the editor.
    @discardableResult
    func undo(_ edit: Edit) async throws -> UndoPath {
        guard let sync, let editor = sync.editor else { throw UndoError.nothingToUndo }
        #if DEBUG
        if Self.probeInject == "undo-noop" { return .revert }
        #endif
        editor.saveNow()
        let current = editor.historyModelDocument()
        let headID = (try? await sync.history.page(projectID: sync.projectID))?.headVersionID
        let unchangedHere = Self.sameJSON(current, edit.after)

        if let target = edit.undoVersionID, headID == edit.versionID, edit.isFreshVersion, unchangedHere, !sync.hasUnsentEdits {
            let restored = try await sync.historyService.restore(versionID: target)
            try editor.historySwap(to: restored, from: current, actionName: Self.actionName)
            StudioHistory.history(of: editor).recordSave(restored)
            editor.header.title = editor.project.name
            sync.refreshStatus()
            StudioCloudSync.trace?("undid the agent edit: server restore of \(target)")
            note(.serverRestore)
            return .serverRestore
        }

        let target: Data
        if unchangedHere {
            target = edit.before
        } else {
            guard let base = try? JSONValue.parse(data: edit.after), let mine = try? JSONValue.parse(data: current),
                  let theirs = try? JSONValue.parse(data: edit.before) else { throw UndoError.nothingToUndo }
            target = Data(ProjectMerge.merge(base: base, mine: mine, theirs: theirs, mineWins: true, choices: [:]).merged.canonical.utf8)
        }
        guard !Self.sameJSON(target, current) else { throw UndoError.nothingToUndo }
        try editor.historySwap(to: target, from: current, actionName: Self.actionName)
        StudioHistory.history(of: editor).recordSave(target)
        editor.header.title = editor.project.name
        sync.refreshStatus()
        sync.requestPush()
        StudioCloudSync.trace?("undid the agent edit: reverted its change here (pushing)")
        note(.revert)
        return .revert
    }

    static let actionName = String(localized: "Undo AI Edit", comment: "Undo menu name for undoing an AI agent's edit")

    private func note(_ path: UndoPath) {
        #if DEBUG
        probeLastUndoPath = path
        #endif
    }

    static func sameJSON(_ a: Data, _ b: Data) -> Bool {
        guard let x = try? JSONValue.parse(data: a), let y = try? JSONValue.parse(data: b) else { return a == b }
        return x == y
    }
}
