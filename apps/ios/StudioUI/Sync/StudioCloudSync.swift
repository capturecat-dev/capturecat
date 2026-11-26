import Foundation
import Network
import UIKit

/// The iOS studio's cloud sync (docs/ios-studio-plan.md Phase 5) — the
/// Mac's own engine (`CloudProjectSync`, `CloudHistoryClient`, the three-way
/// merge; Studio/Sync) driven the way an editor needs it:
///
/// - **Open**: a project not on this device is CLONED (every file it names
///   downloaded and verified before project.json lands); one that is here is
///   PULLED — the cloud's newer revision comes in, and edits made here that
///   were never sent merge with it three-way (the merge base is the
///   `.cloudsync-base.json` the Mac keeps too).
/// - **Edit**: every editor save (`StudioProjectFolder.onDidSave`) schedules
///   a push `pushDelay` later (debounced: a burst of edits is one push) —
///   media uploads, finalize, then project.json saved with `If-Match` the
///   revision this device last agreed with the cloud.
/// - **Concurrent change**: a push that loses the race (409) or a pull over
///   unsent edits merges three-way; a clean merge lands in the editor as ONE
///   undo step, structural conflicts open Merge Review (Studio 4f), and with
///   no merge base anywhere the user picks a side (the Mac's two-way
///   fallback). The editor polls the cloud's head while it is open.
/// - **Offline**: a push that cannot reach the API leaves the edits where
///   they are — unsent edits ARE the queue (project.json differs from the
///   merge base) — and retries with backoff, when the network comes back,
///   and on the next foreground (`resumePending`).
///
/// One session per project, owned here (it outlives the editor: a push
/// scheduled by the last save still runs after the editor closes).
@available(iOS 26, *)
@MainActor
final class StudioCloudSync {
    // MARK: - Environment (the transport / auth seam)

    /// What the sync talks to: the app's `HTTPCloudProjectTransport` (its
    /// session token), or StudioLab's in-process stub.
    struct Environment {
        let transport: CloudHistoryClient.Transport
        /// Keys the sync sidecar (`CloudSyncState.apiBaseURL`).
        let apiBaseURL: String
        /// `X-CC-Client-Id` — this install's random id.
        let clientID: String
        /// `X-CC-Client`.
        var clientKind = "ios"
    }

    /// Set by the app while signed in (nil = this device edits locally only).
    static var environment: Environment? {
        didSet {
            if let old = oldValue, environment.map({ $0.transport !== old.transport }) ?? true { sessions = [:] }
        }
    }

    enum Status: Equatable {
        /// No cloud for this project here (signed out).
        case localOnly
        /// project.json is what the cloud holds.
        case synced
        /// Edits on this device the cloud does not have yet.
        case pending
        case syncing
        /// The last attempt could not reach the API; the edits wait here.
        case offline
        /// Waiting on the user (Merge Review, or keep-mine / use-theirs).
        case review
        case failed(String)

        var words: String {
            switch self {
            case .localOnly:
                let device = StudioHistory.deviceNoun
                return String(localized: "Saved on this \(device) only", comment: "Sync status; the argument is iPhone or iPad")
            case .synced: return String(localized: "All changes synced", comment: "Sync status")
            case .pending: return String(localized: "Changes waiting to sync", comment: "Sync status")
            case .syncing: return String(localized: "Syncing…", comment: "Sync status: a sync is in progress")
            case .offline:
                let device = StudioHistory.deviceNoun
                return String(localized: "Offline — your changes are saved on this \(device) and sync when you're back online", comment: "Sync status; the argument is iPhone or iPad")
            case .review: return String(localized: "Waiting for you to choose how to merge", comment: "Sync status: a merge conflict needs the user")
            case .failed(let message): return String(localized: "Couldn't sync: \(message)", comment: "Sync status; the argument is the error message")
            }
        }
    }

    // MARK: - Sessions

    private static var sessions: [UUID: StudioCloudSync] = [:]

    /// The project's session (created on first use); nil without an environment.
    static func session(projectID: UUID, directory: URL) -> StudioCloudSync? {
        guard let environment else { return nil }
        if let existing = sessions[projectID], existing.directory.standardizedFileURL == directory.standardizedFileURL {
            return existing
        }
        let session = StudioCloudSync(projectID: projectID, directory: directory, environment: environment)
        sessions[projectID] = session
        return session
    }

    static func existing(projectID: UUID) -> StudioCloudSync? { sessions[projectID] }
    /// The session an open editor is attached to (its cloud project).
    static func session(for editor: EditorViewController) -> StudioCloudSync? {
        sessions.values.first { $0.editor === editor }
    }

    /// Harness seam: forget every session (their timers stop).
    static func resetSessions() {
        for session in sessions.values { session.stop() }
        sessions = [:]
    }

    /// Harness transcript: every engine outcome and status change.
    static var trace: ((String) -> Void)?

    // MARK: - State

    let projectID: UUID
    let directory: URL
    let engine: CloudProjectSync
    let history: CloudHistoryClient
    let transport: CloudHistoryClient.Transport

    private(set) var status: Status = .synced {
        didSet {
            guard status != oldValue else { return }
            Self.trace?("status \(status)")
            onStatus?(status)
            badge?.show(status, animated: true)
        }
    }
    var onStatus: ((Status) -> Void)?
    /// After a save landed in the cloud (5c: an inbox take leaves the inbox).
    var onPushed: ((Int) -> Void)?

    /// Seconds after the last save before the push (a burst of edits = one push).
    var pushDelay: TimeInterval = 3
    /// Seconds between head polls while an editor is attached (0 = off).
    var pollInterval: TimeInterval = 20
    /// Retry backoff after a failed or offline attempt.
    var retryDelays: [TimeInterval] = [2, 5, 15, 30, 60]

    private(set) weak var editor: EditorViewController?
    private weak var badge: StudioSyncBadge?
    private var chain: Task<Void, Never>?
    private var pushTimer: Task<Void, Never>?
    private var retryTimer: Task<Void, Never>?
    private var pollTimer: Task<Void, Never>?
    private var retryIndex = 0
    private var pushQueued = false
    private var pendingReview: CloudMergeReview?
    private var pendingTwoWay: Int?
    private var pendingToast: String?
    private var observers: [NSObjectProtocol] = []
    private(set) lazy var historyService = StudioCloudHistory(sync: self)
    /// "Edited by Claude": agent revisions among what a pull brought in.
    private(set) lazy var agentEdits = StudioAgentEdits(sync: self)
    /// An agent check the open's pull left for when the editor is on screen.
    private var pendingAgentCheck: (agreed: Int, before: Data, after: Data)?
    #if DEBUG
    /// Probe seams: the Merge Review / two-way choice this session put up.
    private(set) weak var probeReview: StudioMergeReviewController?
    private(set) weak var probeTwoWay: CCAlert?
    /// The last merge put up for review (the round trip records its triple).
    private(set) var probeLastReview: CloudMergeReview?
    #endif
    var probeBadge: StudioSyncBadge? { badge }

    var documentURL: URL { directory.appendingPathComponent(StudioProjectFolder.documentName) }

    private init(projectID: UUID, directory: URL, environment: Environment) {
        self.projectID = projectID
        self.directory = directory
        transport = environment.transport
        engine = CloudProjectSync(transport: environment.transport, apiBaseURL: environment.apiBaseURL,
                                  clientID: environment.clientID)
        engine.clientKind = environment.clientKind
        // Autosave pushes coalesce into the head version (the web editor's
        // rule); the first upload, merges and restores still open their own.
        engine.pushCheckpoint = nil
        history = CloudHistoryClient(transport: environment.transport, sync: engine)
        status = Self.localStatus(projectID: projectID, directory: directory, apiBaseURL: environment.apiBaseURL)
    }

    /// Synced when project.json is the agreed base; pending otherwise.
    private static func localStatus(projectID: UUID, directory: URL, apiBaseURL: String) -> Status {
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(StudioProjectFolder.documentName).path)
        else { return .synced }
        switch CloudLocalStatus.read(projectID: projectID, projectDirectory: directory, apiBaseURL: apiBaseURL).kind {
        case .synced: return .synced
        case .unsynced, .neverUploaded: return .pending
        }
    }

    private var localStatus: Status {
        Self.localStatus(projectID: projectID, directory: directory, apiBaseURL: engine.apiBaseURL)
    }

    /// Whether project.json holds edits the cloud does not have.
    var hasUnsentEdits: Bool { localStatus == .pending }

    /// Re-reads the status from disk (after History's restore moved it).
    func refreshStatus() {
        status = localStatus
    }

    // MARK: - Serial work

    /// Every engine call runs one after another (a push never overlaps a
    /// pull, a resolve or a restore).
    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = chain
        chain = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    /// Runs `work` in the serial chain and returns its result.
    func exclusive<T>(_ work: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = chain
        let task = Task { @MainActor () async throws -> T in
            await previous?.value
            return try await work()
        }
        chain = Task { @MainActor in _ = try? await task.value }
        return try await task.value
    }

    /// Waits until the chain is idle (harness).
    func settle() async {
        while let current = chain {
            await current.value
            if chain == current { break }
        }
    }

    // MARK: - Open

    /// The editor's way in: the project's folder brought up to date (clone or
    /// pull) and opened, with its session (nil without an environment — then
    /// only a folder already here opens). Attach the session to the editor
    /// once it is on screen.
    static func open(projectID: UUID, directory: URL) async throws -> (folder: StudioProjectFolder, sync: StudioCloudSync?) {
        let session = session(projectID: projectID, directory: directory)
        if let session { _ = try await session.prepare() }
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(StudioProjectFolder.documentName).path)
        else { throw StudioProjectFolder.OpenError.missingDocument }
        return (try StudioProjectFolder.open(directory), session)
    }

    /// The fast way in: the local copy already holds the revision the
    /// library just listed, so it opens with no network wait — the head check
    /// (`checkRemote`) runs once the editor is attached, and pulls through the
    /// usual merge path if the cloud moved meanwhile. Nil whenever the slow,
    /// careful `open` is needed (no copy, an unsynced first open, the listed
    /// revision differs, or the folder doesn't open — e.g. media missing).
    static func openCurrentLocal(projectID: UUID, directory: URL, listedRevision: Int?) -> (folder: StudioProjectFolder, sync: StudioCloudSync)? {
        guard let listedRevision, let session = session(projectID: projectID, directory: directory),
              FileManager.default.fileExists(atPath: directory.appendingPathComponent(StudioProjectFolder.documentName).path),
              let state = CloudSyncState.load(from: directory, projectID: projectID, apiBaseURL: session.engine.apiBaseURL),
              state.revision == listedRevision,
              let folder = try? StudioProjectFolder.open(directory) else { return nil }
        session.refreshStatus()
        return (folder, session)
    }

    enum Prepared: Equatable {
        case cloned(revision: Int)
        case ready
        case merged
        case needsReview
        case twoWay(remoteRevision: Int)
        case offline
        /// Not in the cloud yet: the first push uploads it.
        case notUploaded
    }

    enum OpenError: LocalizedError {
        case noCloudCopy
        var errorDescription: String? {
            String(localized: "This project isn't in your CaptureCat cloud any more.", comment: "Error opening a cloud project that was deleted from the cloud")
        }
    }

    /// Brings the folder up to date before the editor opens: clone when
    /// project.json is not here, else pull (merging edits made here).
    /// Throws only when there is nothing to open (no local copy and the
    /// clone failed).
    func prepare() async throws -> Prepared {
        try await exclusive { [self] in
            migrateDownloadMarker()
            let fm = FileManager.default
            if !fm.fileExists(atPath: documentURL.path) {
                switch try await engine.clone(projectID: projectID, into: directory) {
                case .cloned(let revision):
                    Self.trace?("clone → cloned(revision: \(revision))")
                    status = .synced
                    return .cloned(revision: revision)
                case .noCloudCopy:
                    Self.trace?("clone → noCloudCopy")
                    throw OpenError.noCloudCopy
                }
            }
            do {
                let agreed = agreedRevision
                let before = try? Data(contentsOf: documentURL)
                let outcome = try await engine.pull(projectID: projectID, projectDirectory: directory)
                Self.trace?("open pull → \(outcome)")
                switch outcome {
                case .pulled, .mediaRestored:
                    rememberAgentCheck(agreed: agreed, before: before)
                    status = localStatus
                    return .ready
                case .upToDate:
                    status = localStatus
                    return .ready
                case .merged(_, let report):
                    rememberAgentCheck(agreed: agreed, before: before)
                    pendingToast = report.toastTitle
                    status = .pending
                    return .merged
                case .needsReview(let review):
                    pendingReview = review
                    status = .review
                    return .needsReview
                case .localChangesWouldBeLost(let revision):
                    pendingTwoWay = revision
                    status = .review
                    return .twoWay(remoteRevision: revision)
                case .noCloudCopy:
                    status = .pending
                    return .notUploaded
                }
            } catch {
                handle(error)
                return .offline
            }
        }
    }

    /// The download-only flow before Phase 5 (StudioEditorEntry) kept a
    /// `.studio-download.json` marker {revision, documentSHA256} instead of
    /// the sync sidecar: it becomes one (no base bytes — the merge asks the
    /// API for that revision's document when it needs it, or heals the base
    /// from project.json while nothing was edited).
    private func migrateDownloadMarker() {
        let marker = directory.appendingPathComponent(".studio-download.json")
        guard let data = try? Data(contentsOf: marker),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let revision = (object["revision"] as? NSNumber)?.intValue,
              let sha = object["documentSHA256"] as? String else { return }
        if CloudSyncState.load(from: directory, projectID: projectID, apiBaseURL: engine.apiBaseURL) == nil {
            try? CloudSyncState(projectID: projectID.uuidString, apiBaseURL: engine.apiBaseURL, revision: revision,
                                documentSHA256: sha, syncedAt: Date(), baseFile: nil, mcpMark: nil).save(to: directory)
        }
        try? FileManager.default.removeItem(at: marker)
        Self.trace?("migrated the download marker (revision \(revision))")
    }

    /// The revision this device last agreed with the cloud on.
    var agreedRevision: Int? {
        CloudSyncState.load(from: directory, projectID: projectID, apiBaseURL: engine.apiBaseURL)?.revision
    }

    private func rememberAgentCheck(agreed: Int?, before: Data?) {
        guard let agreed, let before, let after = try? Data(contentsOf: documentURL) else { return }
        pendingAgentCheck = (agreed, before, after)
    }

    // MARK: - Editor

    /// Ties the session to an editor showing this project (after it is on
    /// screen): its saves push, the cloud's changes land in it, History
    /// lists the cloud's versions, the header shows the status dot.
    func attach(_ editor: EditorViewController) {
        self.editor = editor
        let previous = editor.folder.onDidSave
        editor.folder.onDidSave = { [weak self] data in
            previous?(data)
            self?.editorDidSave()
        }
        StudioHistory.cloudHistory[projectID] = { [weak self] in self?.historyService }
        let badge = StudioSyncBadge()
        badge.onTap = { [weak self, weak editor] in
            guard let self, let editor else { return }
            StudioHistory.toast(in: editor, title: self.status.words)
        }
        editor.header.setLeadingAccessory(badge)
        badge.show(status, animated: false)
        self.badge = badge
        observeApp()
        startPolling()

        if let review = pendingReview {
            pendingReview = nil
            presentReview(review)
        } else if let revision = pendingTwoWay {
            pendingTwoWay = nil
            presentTwoWay(remoteRevision: revision)
        }
        if let toast = pendingToast {
            pendingToast = nil
            StudioHistory.toast(in: editor, title: toast, variant: .success)
        }
        if let check = pendingAgentCheck {
            pendingAgentCheck = nil
            agentEdits.cloudChanged(since: check.agreed, before: check.before, after: check.after)
        }
        if status == .pending || status == .offline { schedulePush(after: pushDelay) }
    }

    /// Stops timers and observers (the harness's reset; the app keeps
    /// sessions for its lifetime).
    func stop() {
        pushTimer?.cancel()
        retryTimer?.cancel()
        pollTimer?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        NetworkWatch.shared.remove(self)
    }

    private func editorDidSave() {
        if status != .syncing && status != .review { status = .pending }
        schedulePush(after: pushDelay)
    }

    // MARK: - Push

    /// A push `delay` seconds from now (replacing one already scheduled).
    func schedulePush(after delay: TimeInterval) {
        pushTimer?.cancel()
        pushTimer = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self else { return }
            self.requestPush()
        }
    }

    /// Queues one push (coalesced: a push already waiting covers this one).
    func requestPush() {
        pushTimer?.cancel()
        guard !pushQueued else { return }
        pushQueued = true
        enqueue { [weak self] in
            guard let self else { return }
            self.pushQueued = false
            await self.runPush()
        }
    }

    /// Pushes now and waits for it (harness; Sync now).
    @discardableResult
    func pushNow() async -> CloudProjectSync.PushOutcome? {
        pushTimer?.cancel()
        return try? await exclusive { [self] in await runPush() }
    }

    @discardableResult
    private func runPush(overwriteRevision: Int? = nil) async -> CloudProjectSync.PushOutcome? {
        editor?.saveNow()
        guard FileManager.default.fileExists(atPath: documentURL.path) else { return nil }
        let project: Project
        if let editor { project = editor.project } else {
            guard let folder = try? StudioProjectFolder.open(directory) else { return nil }
            project = folder.project
        }
        let before = try? Data(contentsOf: documentURL)
        let agreed = agreedRevision
        status = .syncing
        do {
            let outcome = try await engine.push(project: project, projectDirectory: directory,
                                                overwriteRevision: overwriteRevision)
            Self.trace?("push → \(outcome)")
            retryIndex = 0
            switch outcome {
            case .pushed(let revision):
                status = localStatus
                onPushed?(revision)
            case .unchanged(let revision):
                status = localStatus
                onPushed?(revision)
            case .cloudIsNewer:
                await runPull()
            case .merged(let revision, let report):
                adoptDisk(since: before, actionName: String(localized: "Merge Changes", comment: "Undo action name: merging synced changes"))
                toast(report.toastTitle)
                agentEdits.cloudChanged(since: agreed, before: before, after: try? Data(contentsOf: documentURL))
                status = localStatus
                onPushed?(revision)
                if status == .pending { schedulePush(after: 0.2) }
            case .needsReview(let review):
                presentReview(review)
            case .conflict(let revision):
                presentTwoWay(remoteRevision: revision)
            }
            return outcome
        } catch {
            handle(error)
            return nil
        }
    }

    // MARK: - Pull

    /// Pulls now and waits for it (the head poll, foreground, harness).
    @discardableResult
    func pullNow() async -> CloudProjectSync.PullOutcome? {
        try? await exclusive { [self] in await runPull() }
    }

    /// The cloud's head moved past what this device agreed with → pull.
    func checkRemote() async {
        guard let head = try? await transport.head(projectID: projectID) else { return }
        let agreed = CloudSyncState.load(from: directory, projectID: projectID, apiBaseURL: engine.apiBaseURL)?.revision ?? 0
        guard head.revision != agreed else { return }
        Self.trace?("head \(head.revision) ≠ agreed \(agreed) → pull")
        await pullNow()
    }

    @discardableResult
    private func runPull(force: Bool = false) async -> CloudProjectSync.PullOutcome? {
        editor?.saveNow()
        let before = try? Data(contentsOf: documentURL)
        let agreed = agreedRevision
        status = .syncing
        do {
            let outcome = try await engine.pull(projectID: projectID, projectDirectory: directory, force: force)
            Self.trace?("pull → \(outcome)")
            retryIndex = 0
            switch outcome {
            case .pulled, .mediaRestored:
                adoptDisk(since: before, actionName: String(localized: "Changes from the Cloud", comment: "Undo action name: adopting changes pulled from the cloud"))
                agentEdits.cloudChanged(since: agreed, before: before, after: try? Data(contentsOf: documentURL))
                status = localStatus
                if status == .pending { schedulePush(after: pushDelay) }
            case .upToDate:
                status = localStatus
                if status == .pending { schedulePush(after: pushDelay) }
            case .merged(_, let report):
                // The cloud's edits are in; this device's are still unsent.
                adoptDisk(since: before, actionName: String(localized: "Merge Changes", comment: "Undo action name: merging synced changes"))
                toast(report.toastTitle)
                agentEdits.cloudChanged(since: agreed, before: before, after: try? Data(contentsOf: documentURL))
                status = .pending
                schedulePush(after: 0.2)
            case .needsReview(let review):
                presentReview(review)
            case .localChangesWouldBeLost(let revision):
                presentTwoWay(remoteRevision: revision)
            case .noCloudCopy:
                status = .pending
                schedulePush(after: 0.2)
            }
            return outcome
        } catch {
            handle(error)
            return nil
        }
    }

    // MARK: - Merge Review / two-way

    /// Structural conflicts: the 4f Merge Review over the engine's merge,
    /// then `resolve` with the user's choices (re-merged against what the
    /// cloud and the disk hold by then).
    private func presentReview(_ review: CloudMergeReview) {
        status = .review
        #if DEBUG
        probeLastReview = review
        #endif
        guard let editor, editor.viewIfLoaded?.window != nil else {
            pendingReview = review
            return
        }
        let session = ProjectMergeSession(
            base: review.base, mine: review.mine, theirs: review.theirs, mineWins: review.mineWins,
            choices: review.choices, theirsAuthor: review.author, theirsFallback: String(localized: "The cloud version", comment: "Merge review: name for the cloud side of a conflict"))
        Self.trace?("merge review: \(review.unresolved.count) conflict(s) to review")
        let shown = StudioHistory.reviewMerge(from: editor, session: session, onApply: { [weak self] resolved in
            guard let self else { return }
            self.enqueue { [weak self] in await self?.runResolve(review, choices: resolved.choices) }
        }, onCancel: { [weak self] in
            // Nothing was written: the edits stay here, unsent, until the
            // next push asks again.
            guard let self else { return }
            Self.trace?("merge review cancelled")
            self.status = .pending
        })
        #if DEBUG
        probeReview = shown
        #else
        _ = shown
        #endif
    }

    private func runResolve(_ review: CloudMergeReview, choices: [String: MergeSide]) async {
        editor?.saveNow()
        let before = try? Data(contentsOf: documentURL)
        status = .syncing
        do {
            let outcome = try await engine.resolve(review, choices: choices, projectDirectory: directory)
            Self.trace?("resolve → \(outcome)")
            switch outcome {
            case .merged(let revision, let report):
                adoptDisk(since: before, actionName: String(localized: "Merge Changes", comment: "Undo action name: merging synced changes"))
                toast(report.toastTitle)
                status = localStatus
                if review.origin == .push { onPushed?(revision) }
                if status == .pending { schedulePush(after: 0.2) }
            case .needsReview(let next):
                presentReview(next)
            case .conflict(let revision):
                presentTwoWay(remoteRevision: revision)
            }
        } catch {
            handle(error)
        }
    }

    /// Both sides changed and no merge base exists anywhere (the Mac's
    /// two-way fallback): keep this device's version, or take the cloud's.
    private func presentTwoWay(remoteRevision: Int) {
        status = .review
        guard let editor, editor.viewIfLoaded?.window != nil else {
            pendingTwoWay = remoteRevision
            return
        }
        Self.trace?("two-way choice at revision \(remoteRevision)")
        let device = StudioHistory.deviceNoun
        let alert = CCAlert(
            title: String(localized: "This project changed in two places", comment: "Alert title: sync conflict that cannot be merged automatically"),
            message: String(localized: "It was edited elsewhere while this \(device) had changes that never synced, and the two can't be merged automatically.", comment: "Sync conflict alert; the argument is iPhone or iPad"))
        alert.presentation = .sheet
        alert.addButton(String(localized: "Keep this \(device)'s version", comment: "Sync conflict alert button: keep the local version; the argument is iPhone or iPad"), role: .primary) { [weak self] in
            guard let self else { return }
            _ = try await self.exclusive { [self] in await self.runPush(overwriteRevision: remoteRevision) }
        }
        alert.addButton(String(localized: "Use the cloud version", comment: "Sync conflict alert button: replace local changes with the cloud version"), role: .destructive) { [weak self] in
            guard let self else { return }
            _ = try await self.exclusive { [self] in await self.runPull(force: true) }
        }
        alert.addButton(String(localized: "Not now", comment: "Sync conflict alert button: decide later"), role: .cancel)
        #if DEBUG
        probeTwoWay = alert
        #endif
        alert.present(from: editor) { [weak self] index in
            if index == 2 { self?.status = .pending }
        }
    }

    // MARK: - The editor adopts what the sync wrote

    /// project.json changed under the editor (a pull, a merge): the editor
    /// takes it as ONE undo step. Edits made while the sync ran (the model
    /// moved on from `before`) are merged over it, so nothing typed during
    /// a sync is lost.
    private func adoptDisk(since before: Data?, actionName: String) {
        guard let editor, let disk = try? Data(contentsOf: documentURL) else { return }
        let model = editor.historyModelDocument()
        var target = disk
        if let before, let base = try? JSONValue.parse(data: before), let mine = try? JSONValue.parse(data: model),
           base != mine, let theirs = try? JSONValue.parse(data: disk) {
            let merged = ProjectMerge.merge(base: base, mine: mine, theirs: theirs, mineWins: true, choices: [:]).merged
            if merged != theirs {
                target = Data(merged.canonical.utf8)
                Self.trace?("kept \(ChangeSummary.format(ProjectDiff.diff(base, mine), maxParts: 3)) made during the sync")
            }
        }
        if let a = try? JSONValue.parse(data: target), let b = try? JSONValue.parse(data: model), a == b {
            StudioHistory.history(of: editor).recordSave(target)
            return
        }
        do {
            try editor.historySwap(to: target, from: model, actionName: actionName)
            editor.header.title = editor.project.name
            StudioHistory.history(of: editor).recordSave(target)
            Self.trace?("editor adopted the synced document (\(actionName))")
        } catch {
            Self.trace?("editor could not adopt: \(error.localizedDescription)")
        }
    }

    private func toast(_ title: String) {
        guard let editor else { return }
        StudioHistory.toast(in: editor, title: title, variant: .success)
    }

    // MARK: - Errors, offline, retries

    static func isOffline(_ error: Error) -> Bool {
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost,
                 .cannotFindHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff,
                 .callIsActive, .secureConnectionFailed:
                return true
            default:
                return false
            }
        }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorNotConnectedToInternet
    }

    private func handle(_ error: Error) {
        Self.trace?("error: \(Self.isOffline(error) ? "offline" : String(describing: error))")
        if error is CancellationError { status = localStatus; return }
        if let sync = error as? CloudSyncError, sync == .notSignedIn {
            status = .localOnly
            return
        }
        if Self.isOffline(error) {
            status = .offline
            NetworkWatch.shared.add(self)
        } else {
            status = .failed(CloudHistoryClient.historyMessage(for: error) ?? error.localizedDescription)
        }
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard !retryDelays.isEmpty else { return }
        let delay = retryDelays[min(retryIndex, retryDelays.count - 1)]
        retryIndex += 1
        retryTimer?.cancel()
        retryTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.retry()
        }
    }

    /// The network is back, the app came forward, or a backoff ran out.
    func retry() {
        retryTimer?.cancel()
        switch status {
        case .offline, .failed, .pending:
            requestPush()
        default:
            break
        }
    }

    private func observeApp() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Send what the editor holds before the app is suspended.
                self.editor?.saveNow()
                guard self.hasUnsentEdits else { return }
                let token = UIApplication.shared.beginBackgroundTask(withName: "CaptureCat sync")
                Task { @MainActor in
                    await self.pushNow()
                    UIApplication.shared.endBackgroundTask(token)
                }
            }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshNow()
            }
        })
    }

    private func startPolling() {
        pollTimer?.cancel()
        guard pollInterval > 0 else { return }
        pollTimer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let interval = self.map { $0.agentEdits.pollInterval(default: $0.pollInterval) } ?? 20
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self, self.editor != nil else { return }
                if self.status == .synced { await self.checkRemote() }
            }
        }
    }

    /// Brings the project up to date now (the "AI finished editing"
    /// notification, an app that came forward): unsent edits push first —
    /// a lost race merges the cloud's change in — otherwise the head check.
    func refreshNow() {
        if hasUnsentEdits { requestPush() } else { Task { await checkRemote() } }
    }

    // MARK: - The offline queue across launches

    /// Pushes every studio project under `root` holding edits the cloud does
    /// not have (made offline, or while the app was closed). Called when the
    /// app comes forward.
    static func resumePending(in root: URL) {
        guard let environment else { return }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return }
        for name in names {
            guard let id = UUID(uuidString: name) else { continue }
            let dir = root.appendingPathComponent(name, isDirectory: true)
            guard fm.fileExists(atPath: dir.appendingPathComponent(StudioProjectFolder.documentName).path),
                  localStatus(projectID: id, directory: dir, apiBaseURL: environment.apiBaseURL) == .pending
            else { continue }
            session(projectID: id, directory: dir)?.requestPush()
        }
    }
}

// MARK: - Network reachability

/// Wakes waiting sessions when a network path comes back.
@available(iOS 26, *)
@MainActor
final class NetworkWatch {
    static let shared = NetworkWatch()
    private let monitor = NWPathMonitor()
    private var waiting: [ObjectIdentifier: StudioCloudSync] = [:]
    private var started = false

    func add(_ session: StudioCloudSync) {
        waiting[ObjectIdentifier(session)] = session
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in NetworkWatch.shared.wake() }
        }
        monitor.start(queue: DispatchQueue(label: "so.capturecat.studio.network"))
    }

    func remove(_ session: StudioCloudSync) {
        waiting[ObjectIdentifier(session)] = nil
    }

    private func wake() {
        let sessions = Array(waiting.values)
        waiting = [:]
        for session in sessions { session.retry() }
    }
}
