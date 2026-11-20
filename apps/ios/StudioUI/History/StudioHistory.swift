import UIKit

/// The iOS studio's project History (docs/ios-studio-plan.md Phase 4f) —
/// the UIKit twin of the Mac's History pane, preview, restore, compare and
/// Merge Review, over the on-device `LocalProjectHistory`.
///
///     StudioHistory.attach(editor)                       // the editor does this on load
///     StudioHistory.present(from: vc, project: editor.project, undoManager: editor.undoManager)
///
/// `present` shows History as a SHEET on compact width (iPhone) and a SIDE
/// PANEL over the inspector column on regular width (iPad). The inspector's
/// `onShowHistory` (Studio 4d) wires to it at merge time.
///
/// Engine: Studio/ProjectHistory — the same version rules, change-sets,
/// summaries, Compare groups and three-way merge as the Mac. Cloud history
/// and sync are Phase 5: they plug in behind `ProjectHistoryService` (the
/// pane talks only to that) and hand Merge Review a `ProjectMergeSession`.
@available(iOS 26, *)
@MainActor
enum StudioHistory {
    /// One store per project folder, shared by every editor of it.
    private static var stores: [String: LocalProjectHistory] = [:]
    private static var editors: [UUID: WeakEditor] = [:]

    private final class WeakEditor {
        weak var editor: EditorViewController?
        init(_ editor: EditorViewController) { self.editor = editor }
    }

    // MARK: - Identity

    static let clientIDKey = "studioHistoryClientID"

    /// This install's history identity: a random per-install client id
    /// (never a device or user name), saves attributed to "You".
    static var identity: ProjectHistoryIdentity {
        let defaults = UserDefaults.standard
        var id = defaults.string(forKey: clientIDKey) ?? ""
        if id.isEmpty {
            id = UUID().uuidString.lowercased()
            defaults.set(id, forKey: clientIDKey)
        }
        return ProjectHistoryIdentity(actorUID: "device", actorName: "You", clientKind: "ios", clientID: id)
    }

    /// "iPad" / "iPhone" — Merge Review's "this iPad".
    static var deviceNoun: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }

    // MARK: - Stores

    static func store(for directory: URL) -> LocalProjectHistory {
        let key = directory.standardizedFileURL.path
        if let existing = stores[key] { return existing }
        let store = LocalProjectHistory(projectDirectory: directory, identity: identity)
        stores[key] = store
        return store
    }

    /// Harness seam: a prepared store (StudioLab's replay of the Mac's history).
    static func install(_ store: LocalProjectHistory) {
        stores[store.projectDirectory.standardizedFileURL.path] = store
    }

    static func history(of editor: EditorViewController) -> LocalProjectHistory {
        store(for: editor.folder.directory)
    }

    // MARK: - Attach (the editor's hook)

    /// Keeps the editor's saves in its project's History: the document it
    /// opened (a new version when it differs from the last one kept — the
    /// file changed outside this editor), then every save the folder writes.
    static func attach(_ editor: EditorViewController) {
        let store = history(of: editor)
        editors[editor.project.id] = WeakEditor(editor)
        if let data = try? Data(contentsOf: editor.folder.documentURL) {
            if store.head == nil {
                store.record(data, at: store.clock())
            } else {
                store.recordSave(data, checkpoint: .push)
            }
        }
        // Phase 5: the cloud sync may have hooked the folder first — chain.
        let previous = editor.folder.onDidSave
        editor.folder.onDidSave = { [weak store] data in
            store?.recordSave(data)
            previous?(data)
        }
    }

    // MARK: - Present

    /// The plain entry point: History for `project` in the editor that
    /// shows it (`presenter`, one of its ancestors, or the editor registered
    /// for the project). `undoManager` is the editor's (restore and merge are
    /// one step on it).
    @discardableResult
    static func present(from presenter: UIViewController, project: Project, undoManager: UndoManager?) -> HistoryPanelController? {
        var candidate: UIViewController? = presenter
        while let vc = candidate {
            if let editor = vc as? EditorViewController, editor.project === project { return present(in: editor) }
            candidate = vc.parent ?? vc.presentingViewController
        }
        guard let editor = editors[project.id]?.editor else { return nil }
        _ = undoManager
        return present(in: editor)
    }

    /// Phase 5: the project's CLOUD history while its sync is live
    /// (`StudioCloudSync.attach` registers it); it lists the on-device
    /// history itself when offline.
    static var cloudHistory: [UUID: () -> ProjectHistoryService?] = [:]

    /// What History lists for `editor`: the cloud's versions when the
    /// project syncs, else this device's.
    static func service(of editor: EditorViewController) -> ProjectHistoryService {
        cloudHistory[editor.project.id]?() ?? history(of: editor)
    }

    @discardableResult
    static func present(in editor: EditorViewController) -> HistoryPanelController {
        if let open = HistoryPresentation.current(in: editor) { return open.panel }
        let panel = HistoryPanelController(service: service(of: editor), host: editor, device: deviceNoun)
        HistoryPresentation.present(panel, in: editor)
        return panel
    }

    // MARK: - Toasts

    private final class EditorToaster {
        weak var host: UIView?
        let toaster: CCToaster
        init(host: UIView) {
            self.host = host
            toaster = CCToaster(host: host)
        }
    }

    private static var toasters: [ObjectIdentifier: EditorToaster] = [:]

    /// History's toasts over the editor (one toaster per editor view).
    @discardableResult
    static func toast(in editor: EditorViewController, title: String, message: String? = nil,
                      variant: CCToast.Variant = .default, symbol: String? = nil,
                      action: CCToast.Action? = nil, duration: TimeInterval = 3.5) -> CCToast {
        let key = ObjectIdentifier(editor)
        toasters = toasters.filter { $0.value.host != nil }
        let entry = toasters[key].flatMap { $0.host === editor.view ? $0 : nil } ?? EditorToaster(host: editor.view)
        toasters[key] = entry
        return entry.toaster.show(title: title, message: message, variant: variant, symbol: symbol, action: action,
                                  duration: duration)
    }

    // MARK: - Merge Review

    /// Merge Review over `session` (the conflicts' Mine / Theirs choices);
    /// `onApply` gets the session re-merged with them. Sheet on iPhone,
    /// side panel on iPad.
    @discardableResult
    static func reviewMerge(from editor: EditorViewController, session: ProjectMergeSession,
                            projectName: String? = nil,
                            onApply: @escaping (ProjectMergeSession) -> Void,
                            onCancel: (() -> Void)? = nil) -> StudioMergeReviewController {
        let review = StudioMergeReviewController(session: session, projectName: projectName ?? editor.project.name,
                                                 device: deviceNoun)
        review.onApply = { choices in
            var resolved = session
            resolved.choose(choices)
            onApply(resolved)
        }
        review.onCancel = onCancel
        HistoryPresentation.presentReview(review, in: editor)
        return review
    }
}

// MARK: - The editor as History's host

@available(iOS 26, *)
extension EditorViewController {
    /// Makes `document` the project — written to project.json, adopted by
    /// the live model — as ONE undo step named `actionName` (undo puts the
    /// previous document back the same way).
    func historyApply(document: Data, actionName: String) throws {
        saveNow()
        let previous = (try? Data(contentsOf: folder.documentURL)) ?? Data()
        try historySwap(to: document, from: previous, actionName: actionName)
    }

    /// The swap itself (no save first): `document` is written and adopted,
    /// undo puts `previous` back. Phase 5's sync calls it with what it wrote.
    func historySwap(to document: Data, from previous: Data, actionName: String) throws {
        let videoBefore = project.videoURL
        let resolved = try folder.adoptDocument(document)
        project.adoptState(of: resolved)
        if let undo = undoManager {
            let opened = undo.groupingLevel == 0
            if opened { undo.beginUndoGrouping() }
            undo.registerUndo(withTarget: self) { editor in
                try? editor.historySwap(to: previous, from: document, actionName: actionName)
            }
            undo.setActionName(actionName)
            if opened { undo.endUndoGrouping() }
        }
        playback.syncToTrimRange(for: project)
        if project.videoURL != videoBefore {
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.playback.setup(for: self.project, initialTime: self.playback.currentTime)
                self.renderStage()
            }
        }
        renderStage()
    }

    /// The document as this editor would save it now (model onto document).
    func historyCurrentDocument() -> Data {
        saveNow()
        return (try? Data(contentsOf: folder.documentURL)) ?? Data()
    }
}

extension LocalProjectHistory {
    /// An editor save: kept unless it is the same JSON as the last version
    /// (a re-save after a restore re-spells the bytes, not the project).
    @discardableResult
    func recordSave(_ document: Data, at date: Date? = nil, checkpoint: ProjectVersionLog.Checkpoint? = nil) -> ProjectVersionLog.Entry? {
        if let head {
            if head.document == document { return nil }
            if let a = try? JSONValue.parse(data: head.document), let b = try? JSONValue.parse(data: document), a == b {
                return nil
            }
        }
        return record(document, at: date ?? clock(), checkpoint: checkpoint)
    }
}
