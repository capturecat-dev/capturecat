import UIKit

/// `--ios-cloud-sync <outDir> [--template <ProjectTemplate.json>] [--inject drop-if-match|merge-wrong-side|lose-unknown-key]`
/// and `--ios-cloud-sync-roundtrip <dir> --step 2|4` (Studio Phase 5) — the
/// iOS studio's cloud sync, against the Mac's.
///
/// **Engine (part A).** The Mac's `--cloud-sync-test` engine sections
/// (StudioHarness/CloudSyncHarness: paths, manifest, push, pull, conflicts,
/// rebase, refusals, web-added media, clone, a second device, the HTTP
/// download path, three-way merges, attribution, the history client) run
/// here, on iOS, against the same `StubCloudServer`; the script compares the
/// lines with the Mac's (the AppKit-only sections print only on the Mac).
///
/// **The iOS studio (part B).** `StudioCloudSync` with the shipping
/// `EditorViewController` in this real window, against an in-process cloud
/// (one `StubCloudServer` per project): open = clone; editor edits autosave
/// and push debounced with If-Match; media uploads; a concurrent change
/// pulls and merges into the open editor as one undo step; a lost race (409)
/// merges; the same field edited on both goes to the later writer; a
/// structural conflict opens Merge Review in the editor; History lists the
/// CLOUD's versions and restores through the server; offline edits queue and
/// push when the network is back (and after a relaunch); a moved container
/// re-points media; an inbox take becomes a studio project and uploads; the
/// header's status dot moves mid-flight.
///
/// **Gate power.** `--inject` breaks the iOS client's outbound path in the
/// in-process cloud (a save without If-Match, a merge clock that picks the
/// wrong side, a save that drops unknown keys); the gate must FAIL.
@available(iOS 26, *)
@MainActor
enum CloudSyncLab {
    static func start(_ arguments: [String], lab: LabViewController) -> Bool {
        func value(_ name: String) -> String? {
            arguments.firstIndex(of: name).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        if let dir = value("--ios-cloud-sync-roundtrip") {
            guard let step = value("--step").flatMap(Int.init) else {
                print("usage: --ios-cloud-sync-roundtrip <dir> --step 2|4")
                exit(64)
            }
            lab.stage.isHidden = true
            Task { @MainActor in
                let checks = CloudSyncHarness.Checks()
                let trip = CloudSyncRoundTripIOS(host: lab, dir: URL(fileURLWithPath: dir, isDirectory: true), checks: checks)
                do { try await trip.run(step: step) } catch { checks.expect(false, "step \(step) threw \(error)") }
                let ok = checks.failures.isEmpty
                print("ROUNDTRIP STEP \(step) \(ok ? "PASS" : "FAIL") (\(checks.passed) checks)")
                exit(ok ? 0 : 1)
            }
            return true
        }
        guard let out = value("--ios-cloud-sync") else { return false }
        lab.stage.isHidden = true
        let inject = value("--inject")
        let template = value("--template").map { URL(fileURLWithPath: $0) }
        Task { @MainActor in
            setbuf(stdout, nil)
            var engineOK = true
            if inject == nil, !arguments.contains("--skip-engine") {
                print("== part A: the Mac's engine sections, on iOS")
                engineOK = await CloudSyncHarness.runShared()
            }
            print("== part B: the iOS studio's sync")
            let rig = CloudSyncRig(host: lab, out: URL(fileURLWithPath: out, isDirectory: true),
                                   inject: inject, template: template)
            let iosOK = await rig.run()
            print(engineOK && iosOK ? "IOS-CLOUD-SYNC-GATE PASS" : "IOS-CLOUD-SYNC-GATE FAIL")
            exit(engineOK && iosOK ? 0 : 1)
        }
        return true
    }
}

// MARK: - The in-process cloud

/// One `StubCloudServer` per project (the stub serves one project), behind
/// the transport the iOS sync talks to — with the switch that takes it
/// offline and the defects `--inject` plants in the client's outbound path.
@available(iOS 26, *)
@MainActor
final class LabCloud: CloudProjectTransport, CloudHistoryTransport {
    private(set) var servers: [UUID: StubCloudServer] = [:]
    var offline = false
    var inject: String?

    func server(_ id: UUID) -> StubCloudServer {
        if let existing = servers[id] { return existing }
        let server = StubCloudServer(ownerUID: "stub-owner")
        server.pinsVersionMedia = true
        servers[id] = server
        return server
    }

    func adopt(_ server: StubCloudServer, for id: UUID) { servers[id] = server }

    private func gate() throws {
        if offline { throw URLError(.notConnectedToInternet) }
    }

    /// The defect `merge-wrong-side`: the cloud's clock claims a later edit,
    /// so a same-field clash goes to the wrong (earlier) writer.
    private func skewed(_ date: Date?) -> Date? {
        inject == "merge-wrong-side" ? Date.distantFuture : date
    }

    func stage(projectID: UUID, name: String, files: [CloudManifestFile]) async throws -> CloudStageResult {
        try gate(); return try await server(projectID).stage(projectID: projectID, name: name, files: files)
    }
    func upload(fileAt url: URL, to target: CloudUploadTarget, progress: @escaping (Int64) -> Void) async throws {
        try gate()
        // The presigned key names the project: cloud-projects/<owner>/<id>/objects/<sha>.
        let parts = target.uploadURL.path.split(separator: "/")
        guard let i = parts.firstIndex(of: "objects"), i > 0, let id = UUID(uuidString: String(parts[i - 1])) else {
            throw CloudSyncError.uploadFailed("unroutable \(target.uploadURL)")
        }
        try await server(id).upload(fileAt: url, to: target, progress: progress)
    }
    func finalize(projectID: UUID) async throws -> CloudFinalizeResult {
        try gate(); return try await server(projectID).finalize(projectID: projectID)
    }
    func fetch(projectID: UUID) async throws -> CloudRemoteProject? {
        try gate()
        guard var remote = try await server(projectID).fetch(projectID: projectID) else { return nil }
        remote.updatedAt = skewed(remote.updatedAt)
        return remote
    }
    func files(projectID: UUID) async throws -> [CloudRemoteFile] {
        try gate(); return try await server(projectID).files(projectID: projectID)
    }
    func download(_ file: CloudRemoteFile, to destination: URL, progress: @escaping (Int64) -> Void) async throws {
        try gate()
        // Presigned GETs name no project: the server holding the object whose
        // presign generation matches answers (the others refuse it).
        var last: Error = CloudSyncError.api(status: 404, code: nil, message: "HTTP 404")
        for server in servers.values where server.ready[file.sha256] != nil {
            do { return try await server.download(file, to: destination, progress: progress) } catch { last = error }
        }
        throw last
    }
    func save(projectID: UUID, document: Data, baseRevision: Int, context: CloudSaveContext) async throws -> CloudSaveResult {
        try gate()
        let server = server(projectID)
        var base = baseRevision
        var data = document
        // `drop-if-match`: the save ignores the revision this device agreed with.
        if inject == "drop-if-match" { base = server.revision }
        // `lose-unknown-key`: the document goes through this build's Codable
        // (what the released Mac app does), dropping keys it does not know.
        if inject == "lose-unknown-key", let project = try? JSONDecoder().decode(Project.self, from: document),
           let encoded = try? JSONEncoder().encode(project) {
            data = encoded
        }
        let result = try await server.save(projectID: projectID, document: data, baseRevision: base, context: context)
        if case .conflict(var conflict) = result {
            conflict.updatedAt = skewed(conflict.updatedAt)
            return .conflict(conflict)
        }
        return result
    }
    func revisionDocument(projectID: UUID, revision: Int) async throws -> Data? {
        try gate(); return try await server(projectID).revisionDocument(projectID: projectID, revision: revision)
    }
    func head(projectID: UUID) async throws -> CloudHead? {
        try gate(); return try await server(projectID).head(projectID: projectID)
    }
    func versions(projectID: UUID, before: Int?, limit: Int) async throws -> CloudVersionPage? {
        try gate(); return try await server(projectID).versions(projectID: projectID, before: before, limit: limit)
    }
    func version(projectID: UUID, versionID: String) async throws -> CloudVersionDetail {
        try gate(); return try await server(projectID).version(projectID: projectID, versionID: versionID)
    }
    func renameVersion(projectID: UUID, versionID: String, label: String?) async throws -> CloudVersion? {
        try gate(); return try await server(projectID).renameVersion(projectID: projectID, versionID: versionID, label: label)
    }
    func restoreVersion(projectID: UUID, versionID: String, baseRevision: Int,
                        context: CloudSaveContext) async throws -> CloudRestoreResult {
        try gate()
        return try await server(projectID).restoreVersion(projectID: projectID, versionID: versionID,
                                                          baseRevision: baseRevision, context: context)
    }
    func deleteVersion(projectID: UUID, versionID: String) async throws {
        try gate(); try await server(projectID).deleteVersion(projectID: projectID, versionID: versionID)
    }
    func freeUp(projectID: UUID) async throws -> CloudFreeUpResult {
        try gate(); return try await server(projectID).freeUp(projectID: projectID)
    }
}

// MARK: - Part B

@available(iOS 26, *)
@MainActor
final class CloudSyncRig {
    let host: LabViewController
    let out: URL
    let inject: String?
    let template: URL?
    let checks = CloudSyncHarness.Checks()
    let cloud = LabCloud()
    static let apiBase = "https://api.stub.test"
    private var trace: [String] = []
    private var motion: [String] = []

    init(host: LabViewController, out: URL, inject: String?, template: URL?) {
        self.host = host
        self.out = out
        self.inject = inject
        self.template = template
        cloud.inject = inject
    }

    private func expect(_ condition: Bool, _ label: String) { checks.expect(condition, label) }

    private func wait(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > end { return false }
            await LabTime.settle(0.02)
        }
        return true
    }

    private func f(_ v: Double) -> String { String(format: "%.3f", v) }

    func run() async -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        let root = fm.temporaryDirectory.appendingPathComponent("ios-cloud-sync-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        StudioCloudSync.trace = { [weak self] line in
            self?.trace.append(line)
            print("    · \(line)")
        }
        StudioCloudSync.resetSessions()
        StudioCloudSync.environment = StudioCloudSync.Environment(
            transport: cloud, apiBaseURL: Self.apiBase, clientID: "ios-install-0001")
        do {
            try await scenarios(root: root)
        } catch {
            expect(false, "unexpected error: \(error)")
        }
        StudioCloudSync.resetSessions()
        StudioCloudSync.environment = nil
        try? trace.joined(separator: "\n").write(to: out.appendingPathComponent("sync-trace.txt"), atomically: true, encoding: .utf8)
        try? motion.joined(separator: "\n").write(to: out.appendingPathComponent("motion.txt"), atomically: true, encoding: .utf8)
        if checks.failures.isEmpty {
            print("IOS CLOUD SYNC PASS (\(checks.passed) checks)")
            return true
        }
        print("IOS CLOUD SYNC FAIL (\(checks.failures.count) of \(checks.passed + checks.failures.count)):")
        for failure in checks.failures { print("  ✘ \(failure)") }
        return false
    }

    // MARK: Fixture (a project made on "the Mac", pushed by the Mac's engine)

    struct Fixture {
        let id: UUID
        let macDir: URL
        let mac: CloudProjectSync
        var server: StubCloudServer
    }

    private func makeMacProject(root: URL) async throws -> Fixture {
        let id = UUID()
        let macDir = root.appendingPathComponent("Mac/Projects/\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: macDir, withIntermediateDirectories: true)
        try await CloudSyncRoundTrip.writeMovie(to: macDir.appendingPathComponent("recording.mp4"))
        try Data(#"{"events":[{"t":0.4,"x":0.5,"y":0.5}]}"#.utf8).write(to: macDir.appendingPathComponent("cursor.json"))
        let project = Project(id: id, name: "Synced on iOS", videoURL: macDir.appendingPathComponent("recording.mp4"),
                              cursorDataURL: macDir.appendingPathComponent("cursor.json"), duration: 2)
        var note = Annotation(type: .text, startTime: 0.2, endTime: 1.6)
        note.text = "Shared note"
        project.annotations = [note]
        var object = (try JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any]) ?? [:]
        object["webOnlyKey"] = ["kept": true]
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            .write(to: macDir.appendingPathComponent("project.json"))
        let server = cloud.server(id)
        let mac = CloudProjectSync(transport: server, apiBaseURL: Self.apiBase, clientID: "mac-install-0001")
        _ = try await mac.push(project: project, projectDirectory: macDir)
        return Fixture(id: id, macDir: macDir, mac: mac, server: server)
    }

    /// The Mac edits its copy (through its Codable, like its editor saves)
    /// and pushes. `at` pins the server's clock (the merge's "theirs" time).
    @discardableResult
    private func macEdit(_ fx: Fixture, at: Date? = nil, _ mutate: (Project) -> Void) async throws -> CloudProjectSync.PushOutcome {
        _ = try await fx.mac.pull(projectID: fx.id, projectDirectory: fx.macDir)
        let url = fx.macDir.appendingPathComponent("project.json")
        let project = try JSONDecoder().decode(Project.self, from: Data(contentsOf: url))
        mutate(project)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        try encoder.encode(project).write(to: url, options: .atomic)
        fx.server.clock = at
        defer { fx.server.clock = nil }
        return try await fx.mac.push(project: project, projectDirectory: fx.macDir)
    }

    private func cloudProject(_ fx: Fixture) -> Project? {
        fx.server.document.flatMap { try? JSONDecoder().decode(Project.self, from: $0) }
    }

    private func object(_ data: Data?) -> [String: Any]? {
        data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    // MARK: Editor

    private func present(_ folder: StudioProjectFolder, sync: StudioCloudSync?) async -> EditorViewController {
        let editor = EditorViewController(folder: folder)
        editor.onClose = {}
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            host.present(editor, animated: false) { c.resume() }
        }
        sync?.attach(editor)
        _ = await wait(15) { editor.playback.isReady }
        await LabTime.settle(0.3)
        return editor
    }

    private func dismiss(_ editor: EditorViewController) async {
        editor.saveNow()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            editor.dismiss(animated: false) { c.resume() }
        }
        await LabTime.settle(0.1)
    }

    /// Lets the editor's observation fire its autosave, then saves now.
    private func commit(_ editor: EditorViewController) async {
        await LabTime.settle(0.15)
        editor.saveNow()
    }

    // MARK: Scenarios

    private func scenarios(root: URL) async throws {
        let fm = FileManager.default
        var fx = try await makeMacProject(root: root)
        let iosRoot = root.appendingPathComponent("iOS/Application Support/Studio/Projects", isDirectory: true)
        let iosDir = iosRoot.appendingPathComponent(fx.id.uuidString, isDirectory: true)

        // ── open = clone ─────────────────────────────────────────────────
        print("open: a project only the cloud has is cloned")
        let (folder, maybeSync) = try await StudioCloudSync.open(projectID: fx.id, directory: iosDir)
        guard let sync = maybeSync else { expect(false, "a sync session exists while signed in"); return }
        sync.pushDelay = 0.5
        sync.pollInterval = 0
        sync.retryDelays = []
        let disk = { (try? Data(contentsOf: iosDir.appendingPathComponent("project.json"))) ?? Data() }
        let state = { CloudSyncState.load(from: iosDir, projectID: fx.id, apiBaseURL: Self.apiBase) }
        let wrong = fx.server.committedFiles.filter {
            (try? Data(contentsOf: iosDir.appendingPathComponent($0.path))).map(CloudProjectManifest.sha256(of:)) != $0.sha256
        }
        expect(wrong.isEmpty && fx.server.committedFiles.count == 2,
               "every committed file arrived verified (\(fx.server.committedFiles.map(\.path).sorted()))")
        expect(object(disk())?["webOnlyKey"] != nil, "a key this build does not know survives the clone")
        expect(folder.project.videoURL?.path == iosDir.appendingPathComponent("recording.mp4").path,
               "the recording reference points into this device's folder")
        expect(state()?.revision == 1 && state()?.loadBase(from: iosDir) != nil,
               "the sidecar agrees with revision 1 and keeps the merge base")
        expect(sync.status == .synced, "status: synced (\(sync.status))")

        let editor = await present(folder, sync: sync)
        expect(editor.stage.core.displayedVideoFrame != nil, "the cloned project plays in the shipping editor")
        await badgeChecks(editor: editor, sync: sync)

        // ── edits → one debounced push, If-Match ─────────────────────────
        print("edit: autosave pushes, debounced, If-Match")
        fx.server.resetCounters()
        editor.project.settings.backgroundPadding = 61
        await LabTime.settle(0.25)
        editor.project.settings.cornerRadius = 7
        _ = await wait(8) { fx.server.saveCalls >= 1 && sync.status == .synced }
        await sync.settle()
        expect(fx.server.saveCalls == 1, "a burst of two edits is ONE save (\(fx.server.saveCalls))")
        expect(fx.server.lastSaveBase == 1, "the save is If-Match 1 — the revision this device agreed with")
        let context = fx.server.lastSaveContext
        expect(context?.client == "ios" && context?.clientID == "ios-install-0001" && context?.checkpoint == nil,
               "X-CC-Client ios, this install's id, no checkpoint (an autosave coalesces into the head version)")
        expect(cloudProject(fx)?.settings.backgroundPadding == 61 && cloudProject(fx)?.settings.cornerRadius == 7,
               "the cloud holds both edits")
        expect(object(fx.server.document)?["webOnlyKey"] != nil, "the unknown key survives the editor's save and push")
        expect(disk() == fx.server.document && sync.status == .synced, "disk == cloud, status synced")

        // ── media: only the new file uploads ─────────────────────────────
        print("edit: a new media file uploads, nothing else")
        fx.server.resetCounters()
        let voiceName = "voiceover-ios-take.m4a"
        try Data("a voice take".utf8).write(to: iosDir.appendingPathComponent(voiceName))
        editor.project.voiceOverClips.append(VoiceOverClip(fileName: voiceName, startTime: 0.5, duration: 1))
        _ = await wait(8) { fx.server.saveCalls >= 1 && sync.status == .synced }
        await sync.settle()
        expect(fx.server.uploads.map(\.paths) == [[voiceName]], "only the voice take uploaded (\(fx.server.uploads.map(\.paths)))")
        expect(fx.server.committedPaths.contains(voiceName), "the cloud's manifest holds it")

        // ── the Mac pulls the iPad's edit ────────────────────────────────
        print("round trip (in process): the Mac's engine pulls it")
        let macPull = try await fx.mac.pull(projectID: fx.id, projectDirectory: fx.macDir)
        let macProject = try? JSONDecoder().decode(Project.self, from: Data(contentsOf: fx.macDir.appendingPathComponent("project.json")))
        expect(macPull == .pulled(revision: fx.server.revision), "the Mac pulls the iOS revision (\(macPull))")
        expect(macProject?.settings.backgroundPadding == 61 && macProject?.voiceOverClips.contains { $0.fileName == voiceName } == true
               && fm.fileExists(atPath: fx.macDir.appendingPathComponent(voiceName).path),
               "the Mac reads padding 61 and the voice take, whose file arrived")

        // ── a concurrent change merges into the open editor ──────────────
        print("concurrent: the Mac renames while this device edits")
        sync.pushDelay = 30
        editor.project.settings.backgroundPadding = 70
        await commit(editor)
        try await macEdit(fx) { $0.name = "Renamed on the Mac" }
        let undoBefore = editor.undoManager?.undoActionName
        await sync.checkRemote()
        await LabTime.settle(0.2)
        expect(editor.project.name == "Renamed on the Mac" && editor.project.settings.backgroundPadding == 70,
               "pull merged three-way: the Mac's rename AND this device's padding 70 are in the editor")
        expect(editor.undoManager?.undoActionName == "Merge Changes" && undoBefore != "Merge Changes",
               "the merge landed as ONE undo step (“Merge Changes”)")
        expect(editor.header.title == "Renamed on the Mac", "the header shows the new name")
        _ = await wait(8) { sync.status == .synced }
        await sync.settle()
        expect(cloudProject(fx)?.name == "Renamed on the Mac" && cloudProject(fx)?.settings.backgroundPadding == 70 && disk() == fx.server.document,
               "the merged document pushed: the cloud has both, byte-identical to disk")

        // ── a lost race (409) merges on push ─────────────────────────────
        print("conflict: a push that lost the race merges (409)")
        editor.project.settings.cornerRadius = 12
        await commit(editor)
        try await macEdit(fx) { $0.settings.shadowRadius = 33 }
        fx.server.resetCounters()
        let raced = await sync.pushNow()
        var mergedOnPush = false
        if case .merged = raced { mergedOnPush = true }
        expect(mergedOnPush, "push → 409 → three-way merge (\(String(describing: raced)))")
        expect(fx.server.lastSaveContext?.checkpoint == .merge && fx.server.lastSaveContext?.mergedFrom != nil,
               "saved as a merge checkpoint, X-CC-Merged-From the head it lost to")
        expect(editor.project.settings.cornerRadius == 12 && editor.project.settings.shadowRadius == 33,
               "the editor holds both sides (this device's radius 12, the Mac's shadow 33)")
        expect(cloudProject(fx)?.settings.shadowRadius == 33, "the Mac's change survives in the cloud")

        // ── the same field on both: the later writer wins ────────────────
        print("conflict: the same field edited on both — the later edit wins")
        try await macEdit(fx, at: Date().addingTimeInterval(-120)) { $0.settings.backgroundPadding = 80 }
        await LabTime.settle(0.05)
        editor.project.settings.backgroundPadding = 90
        await commit(editor)
        await sync.pushNow()
        await sync.settle()
        expect(cloudProject(fx)?.settings.backgroundPadding == 90 && editor.project.settings.backgroundPadding == 90,
               "this device edited later → its 90 beats the Mac's earlier 80 (cloud \(String(describing: cloudProject(fx)?.settings.backgroundPadding)))")

        // ── a structural conflict opens Merge Review ─────────────────────
        print("conflict: delete vs modify → Merge Review in the editor")
        try await macEdit(fx, at: Date().addingTimeInterval(-60)) { project in
            if !project.annotations.isEmpty { project.annotations[0].text = "Edited on the Mac" }
        }
        editor.project.annotations.removeAll()
        await commit(editor)
        let revisionBefore = fx.server.revision
        sync.requestPush()
        _ = await wait(6) { sync.probeReview?.view.window != nil }
        guard let review = sync.probeReview else {
            expect(false, "Merge Review opened")
            return
        }
        await LabTime.settle(0.5)
        expect(review.rows.count == 1 && review.rows.first?.conflict.kind == "deleteVsModify",
               "Merge Review shows one delete-vs-modify conflict (\(review.rows.map(\.conflict.kind)))")
        expect(sync.status == .review && fx.server.revision == revisionBefore,
               "nothing saved while it waits; status review")
        // Pick Mine (keep this device's delete) through the control's own path.
        if let row = review.rows.first, row.control.selectedIndex != 0 {
            (row.control.accessibilityElements?[0] as? UIAccessibilityElement).map { _ = $0.accessibilityActivate() }
        }
        await LabTime.settle(0.05)
        review.applyButton.sendActions(for: .touchUpInside)
        _ = await wait(6) { sync.status == .synced && fx.server.revision > revisionBefore }
        await sync.settle()
        expect(editor.project.annotations.isEmpty && cloudProject(fx)?.annotations.isEmpty == true,
               "Mine applied: the annotation is gone here and in the cloud")
        expect(disk() == fx.server.document, "disk and cloud byte-identical after the review")

        // ── History lists the cloud's versions ───────────────────────────
        print("history: the cloud's versions, restore through the server")
        let panel = StudioHistory.present(in: editor)
        _ = await wait(3) { panel.view.window != nil }
        let page = try await panel.service.page()
        await LabTime.settle(0.4)
        let cloudIDs = fx.server.versions.reversed().map(\.id)
        expect(!panel.service.isLocal && page?.versions.map(\.id) == cloudIDs,
               "History lists the cloud's \(cloudIDs.count) versions, newest first (not the on-device log)")
        if let upload = page?.versions.last {
            let uploadDoc = fx.server.stubVersion(upload.id)?.document
            fx.server.resetCounters()
            try await HistoryPanelController.restore(upload, service: panel.service, host: editor)
            await sync.settle()
            expect(fx.server.restoreCalls == 1 && fx.server.versions.last?.kind == "restore",
                   "Restore ran on the server (a new head of kind restore)")
            expect(editor.project.settings.backgroundPadding == (uploadDoc.flatMap { try? JSONDecoder().decode(Project.self, from: $0) }?.settings.backgroundPadding ?? -1)
                   && editor.undoManager?.undoActionName == "Restore Version",
                   "the editor holds the restored version, as one undo step")
        } else {
            expect(false, "History has an upload version")
        }
        panel.close()
        await LabTime.settle(0.4)

        // ── offline: edits wait, then push ───────────────────────────────
        print("offline: edits queue on this device and push when back")
        sync.pushDelay = 0.3
        let agreedBefore = state()?.revision
        cloud.offline = true
        fx.server.resetCounters()
        editor.project.settings.backgroundPadding = 33
        _ = await wait(6) { sync.status == .offline }
        editor.project.settings.cornerRadius = 3
        await LabTime.settle(1.6)
        expect(sync.status == .offline && fx.server.saveCalls == 0, "offline: nothing reached the cloud; status offline")
        expect(sync.probeBadge?.probeRing.opacity == 1, "the status dot turns into a hollow ring")
        let onDisk = try? JSONDecoder().decode(Project.self, from: disk())
        expect(onDisk?.settings.backgroundPadding == 33 && onDisk?.settings.cornerRadius == 3 && sync.hasUnsentEdits,
               "both edits are saved on this device (the queue)")
        let offlinePage = try await sync.historyService.page()
        expect(sync.historyService.isLocal && offlinePage?.versions.first?.id.hasPrefix("local-") == true,
               "History lists the on-device versions while offline")
        cloud.offline = false
        sync.retry() // what NetworkWatch does when the path comes back
        _ = await wait(6) { sync.status == .synced }
        await sync.settle()
        expect(fx.server.saveCalls == 1 && fx.server.lastSaveBase == agreedBefore,
               "back online: ONE save carries the queued edits, If-Match the last agreed revision (\(String(describing: agreedBefore)))")
        expect(cloudProject(fx)?.settings.backgroundPadding == 33 && cloudProject(fx)?.settings.cornerRadius == 3,
               "the cloud has both offline edits")

        // ── across a relaunch: resumePending ─────────────────────────────
        print("offline: an edit made before the app quit pushes on the next launch")
        await dismiss(editor)
        StudioCloudSync.resetSessions()
        if var object = object(disk()), var settings = object["settings"] as? [String: Any] {
            settings["backgroundPadding"] = 44
            object["settings"] = settings
            try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
                .write(to: iosDir.appendingPathComponent("project.json"), options: .atomic)
        }
        fx.server.resetCounters()
        StudioCloudSync.resumePending(in: iosRoot)
        let resumed = StudioCloudSync.existing(projectID: fx.id)
        _ = await wait(6) { fx.server.saveCalls == 1 && resumed?.status == .synced }
        await resumed?.settle()
        expect(fx.server.saveCalls == 1 && cloudProject(fx)?.settings.backgroundPadding == 44,
               "resumePending found the unsent edit and pushed it (no editor open)")

        // ── a moved container: media re-point on open ────────────────────
        print("reinstall: the container moved — media re-point on open")
        StudioCloudSync.resetSessions()
        let movedRoot = root.appendingPathComponent("iOS-moved/Application Support/Studio/Projects", isDirectory: true)
        try fm.createDirectory(at: movedRoot, withIntermediateDirectories: true)
        let movedDir = movedRoot.appendingPathComponent(fx.id.uuidString, isDirectory: true)
        try fm.moveItem(at: iosDir, to: movedDir)
        try? fm.removeItem(at: root.appendingPathComponent("iOS", isDirectory: true))
        let stale = object(try? Data(contentsOf: movedDir.appendingPathComponent("project.json")))?["videoURL"] as? String
        // (The last pull spelled the recording as the device that saved it
        // did — a path that is not this container's.)
        let staleURL = stale.flatMap(URL.init(string:))
        expect(staleURL.map { !$0.path.hasPrefix(movedRoot.path) } == true,
               "project.json names the recording outside the new container (\(staleURL?.deletingLastPathComponent().lastPathComponent ?? "nil")/…)")
        try await macEdit(fx) { $0.settings.backgroundBlur = 0.25 }
        fx.server.resetCounters()
        let (movedFolder, movedSync) = try await StudioCloudSync.open(projectID: fx.id, directory: movedDir)
        movedSync?.pushDelay = 0.3
        movedSync?.pollInterval = 0
        movedSync?.retryDelays = []
        expect(movedFolder.project.videoURL?.path == movedDir.appendingPathComponent("recording.mp4").path
               && fm.fileExists(atPath: movedFolder.project.videoURL?.path ?? ""),
               "the recording resolves inside the new container")
        expect(fx.server.downloads.isEmpty, "nothing re-downloaded (the files were all here)")
        let moved = await present(movedFolder, sync: movedSync)
        expect(moved.stage.core.displayedVideoFrame != nil && moved.project.settings.backgroundBlur == 0.25,
               "it plays, with the Mac's newer edit pulled in")
        moved.project.settings.backgroundPadding = 55
        _ = await wait(6) { fx.server.saveCalls >= 1 && movedSync?.status == .synced }
        await movedSync?.settle()
        expect(fx.server.uploads.isEmpty && cloudProject(fx)?.settings.backgroundPadding == 55,
               "an edit from the new container pushes without re-uploading any media")
        await dismiss(moved)

        // ── 5c: an inbox take becomes a studio project ───────────────────
        await inboxChecks(root: root, iosRoot: movedRoot)
        _ = fx
        fx.server = cloud.server(fx.id)
    }

    // MARK: Status dot

    private func badgeChecks(editor: EditorViewController, sync: StudioCloudSync) async {
        print("status: the header's sync dot")
        guard let badge = sync.probeBadge else { expect(false, "the editor's header shows the sync dot"); return }
        var inHeader = false
        var view: UIView? = badge
        while let v = view { if v === editor.header { inHeader = true }; view = v.superview }
        let title = editor.header.probeTitleView
        let badgeFrame = badge.convert(badge.bounds, to: editor.header)
        let titleFrame = title.convert(title.bounds, to: editor.header)
        expect(inHeader && !badge.isHidden && badgeFrame.maxX <= titleFrame.minX + 0.5,
               "the dot sits in the header beside the back key, clear of the title (\(Int(badgeFrame.maxX)) ≤ \(Int(titleFrame.minX)))")
        expect(badge.accessibilityValue == StudioCloudSync.Status.synced.words, "VoiceOver reads its state in words")
        // Growth bounce + colour cross-fade, sampled as a sequence.
        badge.show(.pending, animated: true)
        var samples: [(Double, Double)] = []
        let begin = Date()
        while Date().timeIntervalSince(begin) < 0.3 {
            let p = badge.probeDot.presentation() ?? badge.probeDot
            samples.append((Date().timeIntervalSince(begin), (p.value(forKeyPath: "transform.scale") as? Double) ?? 1))
            await LabTime.settle(0.012)
        }
        motion.append("dot scale " + samples.map { "\(f($0.0)):\(f($0.1))" }.joined(separator: " "))
        let early = samples.first { $0.0 >= 0.03 }?.1 ?? 1
        expect(early > 0.56 && abs(early - 1) > 0.01,
               "the dot's growth is mid-flight 30 ms in (scale \(f(early)), 0.55 → 1)")
        await LabTime.settle(0.6)
        badge.show(sync.status, animated: false)
    }

    // MARK: 5c — inbox take → studio project

    private func inboxChecks(root: URL, iosRoot: URL) async {
        print("inbox: a capture from this device opens as a studio project")
        guard let template, let templateData = try? Data(contentsOf: template),
              var doc = object(templateData) else {
            expect(false, "the project template is readable (--template)")
            return
        }
        let fm = FileManager.default
        let id = UUID()
        let take = root.appendingPathComponent("Inbox/\(id.uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: take, withIntermediateDirectories: true)
            try await CloudSyncRoundTrip.writeMovie(to: take.appendingPathComponent("recording.mp4"))
            // ProjectDocument.make's substitutions (core-selftest locks them).
            doc["id"] = id.uuidString
            doc["name"] = "Recorded on iPhone"
            doc["videoURL"] = "file:///CaptureCat/Projects/\(id.uuidString)/recording.mp4"
            doc["duration"] = 2
            doc["recordingSourceKind"] = "device"
            let document = try JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys])
            let dir = iosRoot.appendingPathComponent(id.uuidString, isDirectory: true)
            try StudioInboxImport.makeProject(in: dir, document: document,
                                              media: [(take.appendingPathComponent("recording.mp4"), "recording.mp4")])
            expect(fm.fileExists(atPath: dir.appendingPathComponent("recording.mp4").path)
                   && (try? Data(contentsOf: dir.appendingPathComponent("project.json"))) == document,
                   "the take's media and project.json are in a studio folder")
            let server = cloud.server(id)
            let (folder, sync) = try await StudioCloudSync.open(projectID: id, directory: dir)
            sync?.pushDelay = 0.3
            sync?.pollInterval = 0
            sync?.retryDelays = []
            var pushedRevision: Int?
            sync?.onPushed = { pushedRevision = $0 }
            expect(folder.project.videoURL?.path == dir.appendingPathComponent("recording.mp4").path,
                   "the recorder's file:///CaptureCat/Projects/<id>/ reference resolves into the folder")
            let editor = await present(folder, sync: sync)
            _ = await wait(8) { pushedRevision != nil }
            await sync?.settle()
            expect(pushedRevision == 1 && server.lastSaveBase == 0 && server.lastSaveContext?.checkpoint == .upload,
                   "its first push uploads it as the cloud project: If-Match 0, checkpoint upload, revision 1")
            expect(server.committedPaths == ["recording.mp4"] && server.document.map { (try? JSONValue.parse(data: $0)) == (try? JSONValue.parse(data: document)) } == true,
                   "the recording and the take's document are in the cloud")
            expect(editor.stage.core.displayedVideoFrame != nil, "it plays in the editor")
            await dismiss(editor)
        } catch {
            expect(false, "inbox import threw \(error)")
        }
    }
}

// MARK: - The round trip's iOS steps

@available(iOS 26, *)
@MainActor
final class CloudSyncRoundTripIOS {
    let host: LabViewController
    let dir: URL
    let checks: CloudSyncHarness.Checks

    init(host: LabViewController, dir: URL, checks: CloudSyncHarness.Checks) {
        self.host = host
        self.dir = dir
        self.checks = checks
    }

    private func wait(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > end { return false }
            await LabTime.settle(0.02)
        }
        return true
    }

    func run(step: Int) async throws {
        let expect = checks.expect
        guard let id = CloudSyncRoundTrip.projectID(dir) else { expect(false, "round trip state exists"); return }
        let server = try StubCloudServer.load(from: CloudSyncRoundTrip.cloudDir(dir))
        StudioCloudSync.trace = { print("    · \($0)") }
        StudioCloudSync.environment = StudioCloudSync.Environment(
            transport: server, apiBaseURL: CloudSyncRoundTrip.apiBase, clientID: "ios-roundtrip")
        let iosDir = dir.appendingPathComponent("ios/Studio/Projects/\(id.uuidString)", isDirectory: true)
        let docURL = iosDir.appendingPathComponent("project.json")
        func object(_ data: Data?) -> [String: Any]? {
            data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
        switch step {
        case 2:
            print("round trip 2 (iOS): open the Mac's project, edit, push")
            let (folder, sync) = try await StudioCloudSync.open(projectID: id, directory: iosDir)
            sync?.pushDelay = 0.3
            sync?.pollInterval = 0
            expect((try? Data(contentsOf: docURL)).flatMap { object($0) }?["futureKey"] != nil,
                   "the Mac's document arrived with the key neither app knows")
            let editor = EditorViewController(folder: folder)
            editor.onClose = {}
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in host.present(editor, animated: false) { c.resume() } }
            sync?.attach(editor)
            _ = await wait(15) { editor.playback.isReady }
            _ = await wait(5) { editor.stage.core.displayedVideoFrame != nil }
            expect(editor.stage.core.displayedVideoFrame != nil, "the Mac's recording plays in the iOS editor")
            editor.project.settings.backgroundPadding = 64
            var note = Annotation(type: .text, startTime: 0.2, endTime: 1.5)
            note.text = "From iOS"
            editor.project.annotations.append(note)
            _ = await wait(8) { server.revision == 2 && sync?.status == .synced }
            await sync?.settle()
            expect(server.revision == 2 && server.lastSaveBase == 1, "the iOS edit pushed as revision 2 (If-Match 1)")
            expect(object(server.document)?["futureKey"] != nil, "the unknown key went back up with it")
            editor.saveNow()
        case 4:
            print("round trip 4 (iOS): edits made offline meet the Mac's — merge on open")
            // Offline edits on disk (the editor saved them; the app quit before
            // they synced): padding 72, corner radius 5, the annotation deleted.
            guard var doc = object(try? Data(contentsOf: docURL)), var settings = doc["settings"] as? [String: Any] else {
                expect(false, "the iOS copy from step 2 is here")
                return
            }
            settings["backgroundPadding"] = 72
            settings["cornerRadius"] = 5
            doc["settings"] = settings
            doc["annotations"] = [] as [Any]
            try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys]).write(to: docURL, options: .atomic)
            let (folder, sync) = try await StudioCloudSync.open(projectID: id, directory: iosDir)
            sync?.pushDelay = 0.3
            sync?.pollInterval = 0
            expect(sync?.status == .review, "opening pulls the Mac's revision 3 over unsent edits → a merge to review (\(String(describing: sync?.status)))")
            let editor = EditorViewController(folder: folder)
            editor.onClose = {}
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in host.present(editor, animated: false) { c.resume() } }
            sync?.attach(editor)
            _ = await wait(6) { sync?.probeReview?.view.window != nil }
            guard let review = sync?.probeReview, let pending = sync?.probeLastReview else {
                expect(false, "Merge Review opened over the editor")
                return
            }
            await LabTime.settle(0.5)
            expect(review.rows.map(\.conflict.kind) == ["deleteVsModify"],
                   "one conflict: deleted here, re-worded on the Mac (\(review.rows.map(\.conflict.kind)))")
            if let row = review.rows.first, row.control.selectedIndex != 0 {
                (row.control.accessibilityElements?[0] as? UIAccessibilityElement).map { _ = $0.accessibilityActivate() }
            }
            await LabTime.settle(0.05)
            review.applyButton.sendActions(for: .touchUpInside)
            _ = await wait(8) { server.revision == 4 && sync?.status == .synced }
            await sync?.settle()
            expect(server.revision == 4, "the merge pushed as revision 4 (\(server.revision))")
            expect(editor.project.name == "Renamed on the Mac" && editor.project.settings.backgroundPadding == 72
                   && editor.project.settings.cornerRadius == 5 && editor.project.annotations.isEmpty,
                   "the editor holds the merge: the Mac's rename, padding 72, radius 5 (later writer), annotation deleted (Mine)")
            // The triple and the choices, for the Mac binary to re-merge.
            let choices = Dictionary(uniqueKeysWithValues: pending.conflicts.map { ($0.id, "mine") })
            let session = ProjectMergeSession(base: pending.base, mine: pending.mine, theirs: pending.theirs,
                                              mineWins: pending.mineWins,
                                              choices: choices.mapValues { _ in MergeSide.mine })
            let record: [String: Any] = [
                "base": pending.base.canonical, "mine": pending.mine.canonical, "theirs": pending.theirs.canonical,
                "mineWins": pending.mineWins, "choices": choices, "merged": session.merged.canonical,
            ]
            try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                .write(to: dir.appendingPathComponent("merge-ios.json"))
            expect(pending.mineWins, "this device's edits are the later ones (mine wins same-field clashes)")
        default:
            expect(false, "unknown iOS step \(step)")
        }
        try server.save(to: CloudSyncRoundTrip.cloudDir(dir))
        StudioCloudSync.resetSessions()
        StudioCloudSync.environment = nil
    }
}
