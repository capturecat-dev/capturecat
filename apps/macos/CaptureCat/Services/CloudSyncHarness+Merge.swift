import AppKit
import Foundation

/// `--cloud-sync-test`, project-history part (docs/project-history.md
/// Phase 3B + 4): the merge base sidecar, three-way merges on push (409) and
/// pull, the last-writer clock, the server fallback for a lost base, the
/// two-way fallback with no base anywhere, `.mcp-history` attribution, a
/// structural conflict resolved through the REAL Merge Review dialog in a
/// real window, and the history client (versions, name, restore with pinned
/// media, Free up) — all against `StubCloudServer`'s history routes.
extension CloudSyncHarness {
    static func mergeChecks(_ checks: Checks, apiBase: String) async throws {
        let expect = checks.expect
        let fm = FileManager.default
        let fixture = try makeFixture()
        defer { try? fm.removeItem(at: fixture.root) }
        let id = fixture.project.id
        let dir = fixture.dir
        let baseURL = dir.appendingPathComponent(CloudSyncState.baseFileName)
        let server = StubCloudServer(ownerUID: "stub-owner")
        let sync = CloudProjectSync(transport: server, apiBaseURL: apiBase, clientID: "test-install-0001")
        func disk() throws -> Data { try Data(contentsOf: fixture.json) }
        func state() -> CloudSyncState? { CloudSyncState.load(from: dir, projectID: id, apiBaseURL: apiBase) }
        func json(_ data: Data?) -> JSONValue? { data.flatMap { try? JSONValue.parse(data: $0) } }
        func setModified(_ date: Date) throws {
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: fixture.json.path)
        }
        /// A web save by Ana at `at` (the server's updated_at).
        func webSave(at: Date, _ mutate: (inout [String: Any], inout [String: Any]) -> Void) throws {
            server.clock = at
            server.webSave(try webEditedJSON(server.document!, mutate))
        }

        // ── Base sidecar + headers on a first upload ─────────────────────
        print("merge: base sidecar + history headers")
        let first = try await sync.push(project: fixture.project, projectDirectory: dir)
        expect(first == .pushed(revision: 1), "first push → revision 1 (got \(first))")
        expect(try state()?.baseFile == CloudSyncState.baseFileName && state()?.loadBase(from: dir) == (try disk()),
               "a push writes .cloudsync-base.json: the exact bytes the sidecar's hash names")
        let headers = server.lastSaveContext?.headers ?? [:]
        expect(headers["X-CC-Client"] == "mac" && headers["X-CC-Client-Id"] == "test-install-0001"
               && headers["X-CC-Checkpoint"] == "upload" && headers["X-CC-Source"] == "human",
               "first upload sends X-CC-Client mac, the install id, X-CC-Source human, X-CC-Checkpoint upload (\(headers))")
        let install = CloudClientIdentity.installID
        expect(UUID(uuidString: install) != nil && CloudClientIdentity.isValid(install)
               && install == CloudClientIdentity.installID
               && !install.localizedCaseInsensitiveContains(ProcessInfo.processInfo.hostName),
               "the default client id is a stable random UUID from defaults, never the machine name")
        expect(!CloudClientIdentity.isValid("Mike's MacBook Pro") && !CloudClientIdentity.isValid(String(repeating: "a", count: 65)),
               "client ids outside [A-Za-z0-9_-]{1,64} are never sent")

        // ── Offline Mac edit + web edit: clean merge on the push's 409 ───
        print("merge: offline Mac edit + web edit (clean)")
        try webSave(at: Date().addingTimeInterval(-600)) { doc, settings in
            settings["backgroundPadding"] = 0.137
            doc["webOnlyFeature"] = ["kept": true, "n": 2]
        } // revision 2 (Ana, web)
        let theirs2 = server.document!
        let macEdited = try editLocal(fixture) {
            $0.name = "Mac offline edit"
            $0.zoomRegions.append(ZoomRegion(startTime: 3, endTime: 4))
        }
        let zoomsBefore = fixture.project.zoomRegions.count
        // "Offline": the base must come from the sidecar alone.
        server.retainsRevisions = false
        server.resetCounters()
        let mtimeBefore = try modificationDate(fixture.json)
        let outcome = try await sync.push(project: macEdited, projectDirectory: dir)
        server.retainsRevisions = true
        guard case .merged(let mergedRevision, let report) = outcome else {
            expect(false, "Mac + web edits → clean merge (got \(outcome))")
            return
        }
        expect(mergedRevision == 3, "the merge is saved as revision 3 (got \(mergedRevision))")
        expect(server.revisionDocumentCalls == 0, "the base came from the sidecar — no server round trip (offline-capable)")
        expect(try disk() == server.document, "disk and cloud end byte-identical")
        let merged = try loadLocal(fixture)
        expect(merged.name == "Mac offline edit" && merged.zoomRegions.count == zoomsBefore + 1,
               "the Mac's rename and new zoom survive")
        expect(abs(merged.settings.backgroundPadding - 0.137) < 1e-9, "the web's background change survives")
        expect(String(decoding: try disk(), as: UTF8.self).contains("webOnlyFeature"),
               "a web-only key survives (merged as raw JSON, never round-tripped through Project)")
        expect((try? CloudProjectSync.checkedProject(try disk(), projectID: id)) != nil,
               "the merged document decodes with this build's Project")
        expect(server.lastSaveBase == 2 && server.lastSaveContext?.checkpoint == .merge && server.lastSaveContext?.mergedFrom == 2,
               "saved with If-Match: theirs (2), X-CC-Checkpoint merge, X-CC-Merged-From 2")
        if let header = server.lastSaveContext?.change.flatMap(ProjectDiff.decodeHeader),
           let t = json(theirs2), let m = json(try disk()) {
            expect(header == ProjectDiff.diff(t, m), "X-CC-Change is the theirs → merged change-set")
        } else {
            expect(false, "X-CC-Change is the theirs → merged change-set (header missing)")
        }
        expect(server.versions.last?.kind == "merge" && server.versions.last?.mergedFrom == 2,
               "the server opens a version of kind merge")
        expect(try state()?.revision == 3 && state()?.loadBase(from: dir) == (try disk()),
               "sidecar + base advance to the merged bytes at revision 3")
        expect(report.toastTitle == "Merged 2 changes from Ana (Web)", "toast reads “\(report.toastTitle)”")
        expect(try fm.fileExists(atPath: fixture.json.appendingPathExtension("bak").path) && (try modificationDate(fixture.json)) > mtimeBefore,
               "written through ProjectFileIO (.bak kept, mtime advanced → the GUI's reload poll)")

        // ── Pull over unsynced Mac edits: merge locally, push later ──────
        print("merge: pull over unsynced Mac edits")
        try webSave(at: Date().addingTimeInterval(-300)) { _, settings in settings["cornerRadius"] = 7.5 } // rev 4
        var note = Annotation(type: .text, startTime: 2, endTime: 3)
        note.text = "Mac-only note"
        _ = try editLocal(fixture) { $0.annotations.append(note) }
        server.resetCounters()
        let pulled = try await sync.pull(projectID: id, projectDirectory: dir)
        guard case .merged(let pulledRevision, _) = pulled else {
            expect(false, "pull over unsynced edits → merge (got \(pulled))")
            return
        }
        let afterPull = try loadLocal(fixture)
        expect(pulledRevision == 4 && afterPull.settings.cornerRadius == 7.5
               && afterPull.annotations.contains { $0.id == note.id },
               "pull merged the web's corner radius with the Mac's unsynced annotation")
        expect(try state()?.revision == 4 && state()?.documentSHA256 != CloudProjectManifest.sha256(of: try disk()),
               "the sidecar agrees with revision 4; the Mac's annotation is still an unsynced edit")
        expect(server.saveCalls == 0, "a pull never saves")
        let pushedAfterPull = try await sync.push(project: try loadLocal(fixture), projectDirectory: dir)
        expect(try pushedAfterPull == .pushed(revision: 5) && (try disk()) == server.document,
               "the next push sends it (revision 5), disk and cloud byte-identical (got \(pushedAfterPull))")

        // ── The last writer wins a same-field clash (and ties → theirs) ──
        print("merge: last writer (mtime vs updated_at)")
        try webSave(at: Date().addingTimeInterval(-120)) { doc, _ in doc["name"] = "Web title A" } // rev 6
        _ = try editLocal(fixture) { $0.name = "Mac title A" } // mtime: now (later)
        let mineLater = try await sync.push(project: try loadLocal(fixture), projectDirectory: dir)
        if case .merged(_, let r) = mineLater {
            expect(try loadLocal(fixture).name == "Mac title A" && r.autoResolved.contains { $0.path == "name" && $0.winner == .mine },
                   "Mac edited later → the Mac's title wins, logged as auto-resolved")
        } else { expect(false, "same-field clash merges (got \(mineLater))") }
        let theirsAt = Date().addingTimeInterval(-60)
        try webSave(at: theirsAt) { doc, _ in doc["name"] = "Web title B" }
        _ = try editLocal(fixture) { $0.name = "Mac title B" }
        try setModified(theirsAt.addingTimeInterval(-500))
        _ = try await sync.push(project: try loadLocal(fixture), projectDirectory: dir)
        expect(try loadLocal(fixture).name == "Web title B", "the web edited later → the web's title wins")
        let tieAt = Date().addingTimeInterval(-30)
        try webSave(at: tieAt) { doc, _ in doc["name"] = "Web title C" }
        _ = try editLocal(fixture) { $0.name = "Mac title C" }
        try setModified(tieAt)
        _ = try await sync.push(project: try loadLocal(fixture), projectDirectory: dir)
        expect(try loadLocal(fixture).name == "Web title C", "a tie (same millisecond) goes to theirs")
        let now = Date()
        expect(!CloudProjectSync.mineWins(localModified: now.addingTimeInterval(86_400), theirsUpdatedAt: now.addingTimeInterval(60), now: now)
               && CloudProjectSync.mineWins(localModified: now, theirsUpdatedAt: now.addingTimeInterval(-1), now: now)
               && !CloudProjectSync.mineWins(localModified: now, theirsUpdatedAt: nil, now: now),
               "a future mtime is clamped to now; an unknown server clock goes to theirs")
        expect(try disk() == server.document, "after every merge, disk and cloud byte-identical")

        // ── Lost base → the server's copy of the agreed revision ─────────
        print("merge: server fallback for a missing base")
        try fm.removeItem(at: baseURL)
        try webSave(at: Date().addingTimeInterval(-200)) { _, settings in settings["shadowOpacity"] = 0.42 }
        _ = try editLocal(fixture) { $0.zoomRegions.append(ZoomRegion(startTime: 5, endTime: 6)) }
        server.resetCounters()
        let fallback = try await sync.push(project: try loadLocal(fixture), projectDirectory: dir)
        expect({ if case .merged = fallback { return true }; return false }() && server.revisionDocumentCalls == 1,
               "missing .cloudsync-base.json → GET /revisions/:rev/document, then a clean merge (got \(fallback))")
        expect(try disk() == server.document && state()?.loadBase(from: dir) == (try disk()),
               "…disk and cloud byte-identical, and the base is back")
        try Data(#"{"not":"the base"}"#.utf8).write(to: baseURL)
        try webSave(at: Date().addingTimeInterval(-200)) { _, settings in settings["shadowOpacity"] = 0.24 }
        _ = try editLocal(fixture) { $0.name = "After a torn base" }
        server.resetCounters()
        let mismatch = try await sync.push(project: try loadLocal(fixture), projectDirectory: dir)
        expect(try { if case .merged = mismatch { return true }; return false }() && server.revisionDocumentCalls == 1
               && (try loadLocal(fixture)).name == "After a torn base",
               "a base whose bytes don't match the sidecar's hash is ignored → server fallback (got \(mismatch))")
        try fm.removeItem(at: baseURL)
        server.retainsRevisions = false
        try webSave(at: Date().addingTimeInterval(-200)) { doc, _ in doc["name"] = "Web, no base" }
        _ = try editLocal(fixture) { $0.name = "Mac, no base" }
        let twoWay = try await sync.push(project: try loadLocal(fixture), projectDirectory: dir)
        let twoWayPull = try await sync.pull(projectID: id, projectDirectory: dir)
        expect(twoWay == .conflict(remoteRevision: server.revision) && twoWayPull == .localChangesWouldBeLost(remoteRevision: server.revision),
               "no base anywhere → the two-way fallback on push and pull (got \(twoWay), \(twoWayPull))")
        server.retainsRevisions = true
        _ = try await sync.pull(projectID: id, projectDirectory: dir, force: true)

        // ── Attribution: the .mcp-history chain (Phase 4) ────────────────
        print("attribution (.mcp-history chain)")
        let agent1 = try loadLocal(fixture)
        agent1.name = "Agent renamed"
        _ = try MCPServer.commitEdit(agent1, to: fixture.json, tool: "set_project", summary: "rename")
        let agent2 = try loadLocal(fixture)
        agent2.settings.cornerRadius = 3
        _ = try MCPServer.commitEdit(agent2, to: fixture.json, tool: "set_style", summary: "corner radius")
        server.resetCounters()
        _ = try await sync.push(project: try loadLocal(fixture), projectDirectory: dir)
        expect(server.lastSaveContext?.source == .agent, "two chained MCP writes cover base → current → X-CC-Source agent")
        let agent3 = try loadLocal(fixture)
        agent3.settings.cornerRadius = 9
        _ = try MCPServer.commitEdit(agent3, to: fixture.json, tool: "set_style", summary: "corner radius")
        _ = try editLocal(fixture) { $0.name = "A human touch after the agent" }
        server.resetCounters()
        _ = try await sync.push(project: try loadLocal(fixture), projectDirectory: dir)
        expect(server.lastSaveContext?.source == .mixed, "an MCP write plus a GUI save → mixed")
        _ = try editLocal(fixture) { $0.name = "Only a human" }
        server.resetCounters()
        _ = try await sync.push(project: try loadLocal(fixture), projectDirectory: dir)
        expect(server.lastSaveContext?.source == .human, "no MCP write since the base → human")
        let legacy = [
            CloudAttribution.Entry(name: "1", pre: "a", post: "b", at: nil),
            CloudAttribution.Entry(name: "2", pre: "b", post: "c", at: nil),
        ]
        expect(CloudAttribution.source(entries: legacy, baseSHA: "a", currentSHA: "c", since: nil) == .agent
               && CloudAttribution.source(entries: legacy, baseSHA: "a", currentSHA: "d", since: nil) == .mixed
               && CloudAttribution.source(entries: [legacy[1]], baseSHA: "a", currentSHA: "c", since: nil) == .mixed,
               "the chain must start AT the base and end AT the current file")
        let metaNames = (try? fm.contentsOfDirectory(atPath: dir.appendingPathComponent(".mcp-history").path))?
            .filter { $0.hasSuffix(".meta.json") } ?? []
        let metaHasPre = metaNames.contains { name in
            ((try? Data(contentsOf: dir.appendingPathComponent(".mcp-history/\(name)")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["preSHA256"] is String
        }
        expect(metaHasPre, "MCPServer's history meta now records preSHA256 (the chain's other end)")

        try await reviewChecks(checks, server: server, sync: sync, fixture: fixture, apiBase: apiBase)
        try await historyClientChecks(checks, server: server, sync: sync, fixture: fixture, apiBase: apiBase)
    }

    // MARK: - Merge Review (structural conflict, real dialog)

    private static func reviewChecks(
        _ checks: Checks, server: StubCloudServer, sync: CloudProjectSync, fixture: Fixture, apiBase: String
    ) async throws {
        let expect = checks.expect
        let dir = fixture.dir
        let id = fixture.project.id
        print("merge review: delete vs modify, resolved in the real dialog")
        var shared = Annotation(type: .text, startTime: 1, endTime: 2)
        shared.text = "Shared note"
        _ = try editLocal(fixture) { $0.annotations = [shared] }
        _ = try await sync.push(project: try loadLocal(fixture), projectDirectory: dir)
        // The web edits the note; this Mac deletes it, EARLIER.
        server.clock = Date().addingTimeInterval(-60)
        server.webSave(try webEditedJSON(server.document!) { doc, _ in
            var notes = doc["annotations"] as? [[String: Any]] ?? []
            if !notes.isEmpty { notes[0]["text"] = "Edited on the web" }
            doc["annotations"] = notes
        })
        _ = try editLocal(fixture) { $0.annotations.removeAll() }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-600)],
                                              ofItemAtPath: fixture.json.path)
        let diskBefore = try Data(contentsOf: fixture.json)
        let cloudBefore = server.document
        let outcome = try await sync.push(project: try loadLocal(fixture), projectDirectory: dir)
        guard case .needsReview(let review) = outcome else {
            expect(false, "delete vs modify → Merge Review (got \(outcome))")
            return
        }
        let conflict = review.conflicts.first
        expect(review.conflicts.count == 1 && conflict?.kind == "deleteVsModify" && conflict?.deletedBy == .mine,
               "one deleteVsModify conflict, deleted by mine (\(review.conflicts.map(\.id)))")
        expect(conflict?.defaultResolution == .theirs, "its default is the last writer (the web edited later)")
        expect(try Data(contentsOf: fixture.json) == diskBefore && server.document == cloudBefore,
               "nothing is written or saved until the conflict is reviewed")
        expect(review.author?.name == "Ana" && review.author?.clientLabel == "Web", "Merge Review knows who edited (Ana on the web)")

        // The REAL dialog over a real window (the editor's transparent-titlebar style).
        let content = NSViewController()
        content.view = NSView()
        content.view.wantsLayer = true
        let window = NSWindow(contentViewController: content)
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.setContentSize(NSSize(width: 1100, height: 700))
        window.setFrameOrigin(NSPoint(x: -20_000, y: 200))
        window.orderFrontRegardless()
        defer { window.close() }

        let dialog = MergeReviewDialog(review: review, projectName: "Cloud Sync Fixture")
        final class Box { var choices: [String: MergeSide]? }
        let box = Box()
        dialog.onApply = { box.choices = $0 }
        dialog.present(over: window)
        try? await Task.sleep(for: .milliseconds(600))
        let card = dialog.probeCard
        card.layoutSubtreeIfNeeded()
        guard let segment = dialog.probeSegments.first else {
            expect(false, "the dialog shows a Mine/Theirs control per conflict")
            return
        }
        let segFrame = segment.convert(segment.bounds, to: card)
        expect(card.window?.isVisible == true && dialog.probeSegments.count == 1 && segFrame.width >= 150
               && card.bounds.contains(segFrame),
               "dialog up over the window, one Mine/Theirs control laid out inside the card (\(Int(segFrame.width))pt)")
        expect(segment.selectedIndex == 1 && dialog.probeTitles.first == "Annotation",
               "the control starts on Theirs (the default) under an “Annotation” row")
        // A real click on the LEFT segment (“Mine”), through mouseDown/mouseUp.
        let mineX = segment.bounds.minX + segment.bounds.width * 0.25
        clickAt(segment, NSPoint(x: mineX, y: segment.bounds.midY))
        let model = segment.probeSelectionLayer.position
        try? await Task.sleep(for: .milliseconds(45))
        let shown = (segment.probeSelectionLayer.presentation() ?? segment.probeSelectionLayer).position
        expect(segment.selectedIndex == 0, "a real click on Mine selects it")
        expect(abs(shown.x - model.x) > 0.5, "the selection chip is mid-spring 45 ms later (\(Int(shown.x)) → \(Int(model.x)))")
        click(dialog.probeApplyButton)
        for _ in 0..<40 where box.choices == nil { try? await Task.sleep(for: .milliseconds(50)) }
        expect(box.choices == [conflict?.id ?? "": .mine], "Apply hands back the user's choice (\(String(describing: box.choices)))")
        expect(card.window?.isVisible != true, "the dialog is gone after Apply")

        guard let choices = box.choices else { return }
        let resolved = try await sync.resolve(review, choices: choices, projectDirectory: dir)
        guard case .merged(_, let report) = resolved else {
            expect(false, "resolve → merged (got \(resolved))")
            return
        }
        expect(try loadLocal(fixture).annotations.isEmpty, "Mine (this Mac's delete) won the conflict")
        expect(try Data(contentsOf: fixture.json) == server.document, "disk and cloud end byte-identical after review")
        expect(server.lastSaveContext?.checkpoint == .merge && report.conflictsResolved == 1,
               "saved as a merge checkpoint; the report counts the resolved conflict")
        expect(MergeReviewDialog.detail(for: conflict!, theirs: "Ana").contains("Deleted on this Mac"),
               "the row explains which side deleted what")
        _ = id
    }

    // MARK: - History client (versions, name, restore with pinned media, Free up)

    private static func historyClientChecks(
        _ checks: Checks, server: StubCloudServer, sync: CloudProjectSync, fixture: Fixture, apiBase: String
    ) async throws {
        let expect = checks.expect
        let fm = FileManager.default
        let dir = fixture.dir
        let id = fixture.project.id
        print("history client: versions, name, restore, free up")
        server.pinsVersionMedia = true
        let client = CloudHistoryClient(transport: server, sync: sync)
        guard let page = try await client.page(projectID: id) else {
            expect(false, "the versions list answers for an uploaded project")
            return
        }
        expect(page.versions.count == server.versions.count && page.versions.first?.id == server.versions.last?.id,
               "versions come newest first, one per retained version (\(page.versions.count))")
        expect(page.versions.contains { $0.kind == "merge" } && page.versions.contains { $0.kind == "upload" }
               && page.versions.contains { $0.clientLabel == "Agent via Mac" } && page.versions.contains { $0.actorName == "Ana" && $0.clientLabel == "Web" },
               "kinds, actors and client badges come through (merge, upload, Agent via Mac, Ana on Web)")
        let upload = server.versions.first!
        _ = try await client.rename(projectID: id, versionID: upload.id, label: "First upload")
        expect(server.stubVersion(upload.id)?.label == "First upload", "Name this version → PATCH label")

        // Change a media file and push: the first version now pins the OLD bytes.
        let watermark = dir.appendingPathComponent("watermark-abcd1234.png")
        let oldWatermark = try Data(contentsOf: watermark)
        try Data("watermark v2".utf8).write(to: watermark)
        _ = try await sync.push(project: try loadLocal(fixture), projectDirectory: dir)
        _ = try editLocal(fixture) { $0.name = "Unsynced before restore" } // pushed first by restore
        let versionsBefore = server.versions.count
        server.resetCounters()
        server.raceNextRestore = true // the first POST answers 409 files_changed
        let restored = try await client.restore(versionID: upload.id, project: try loadLocal(fixture), projectDirectory: dir)
        expect(restored == .restored(revision: server.revision), "restore → a NEW head revision (got \(restored))")
        expect(server.restoreCalls == 2, "409 files_changed (a media commit raced) → retried once (\(server.restoreCalls) POSTs)")
        expect(server.versions.count == versionsBefore + 2 && server.versions.last?.kind == "restore"
               && server.versions.last?.restoredFrom == upload.id,
               "unsynced Mac edits were pushed first (kept in History), then a restore version")
        expect(try server.document == upload.document && (try Data(contentsOf: fixture.json)) == server.document,
               "disk and cloud hold the restored version's bytes")
        expect((try? Data(contentsOf: watermark)) == oldWatermark, "the media that version pinned came back too")

        guard let afterRestore = try await client.page(projectID: id) else { return }
        expect(afterRestore.pinnedMediaBytes > 0 && afterRestore.freeableBytes > 0
               && afterRestore.freeableBytes <= afterRestore.pinnedMediaBytes && afterRestore.isOwner == true,
               "History keeps \(afterRestore.pinnedMediaBytes) B of removed media, \(afterRestore.freeableBytes) B freeable (access owner)")
        let freed = try await client.freeUp(projectID: id)
        guard let afterFree = try await client.page(projectID: id) else { return }
        expect(!freed.deletedVersions.isEmpty && freed.releasedBytes > 0 && afterFree.freeableBytes == 0
               && afterFree.pinnedMediaBytes == freed.pinnedMediaBytes && server.stubVersion(upload.id) != nil
               && !freed.deletedVersions.contains(upload.id),
               "POST /history/free-up deleted \(freed.deletedVersions.count) unnamed version(s), released \(freed.releasedBytes) B; the named one stays")
        do {
            try await client.delete(projectID: id, versionID: server.versions.last!.id)
            expect(false, "the head version can't be deleted")
        } catch {
            expect((error as? CloudSyncError)?.apiCode == "head_version"
                   && CloudHistoryClient.message(for: error) == "The current version can't be deleted.",
                   "the head version can't be deleted (409 head_version, in words)")
        }
        server.access = "member"
        let memberPage = try await client.page(projectID: id)
        do {
            try await client.delete(projectID: id, versionID: server.versions.first!.id)
            expect(false, "a member cannot delete versions")
        } catch {
            expect(memberPage?.isOwner == false && (error as? CloudSyncError)?.apiCode == "not_owner",
                   "access member → not the owner; DELETE answers 403 not_owner")
        }
        server.access = "owner"
        server.namedLimit = server.versions.filter { $0.label != nil }.count
        do {
            _ = try await client.rename(projectID: id, versionID: server.versions.dropLast().last!.id, label: "One too many")
            expect(false, "the named-version cap is enforced")
        } catch {
            expect((error as? CloudSyncError)?.apiCode == "named_version_limit",
                   "naming past the plan's cap → 402 named_version_limit")
        }
        server.namedLimit = 25

        // The parser against the contract's own example payloads (§6.1).
        let sample = Data("""
        {"projectId":"p","revision":15,"headVersionId":"a1b2","access":"member","versions":[
          {"id":"a1b2","seq":7,"kind":"edit","label":null,"namedBy":null,"namedAt":null,
           "actor":{"uid":"u-ana","name":"Ana"},"client":"web","source":"agent","firstRevision":12,"revision":15,
           "documentBytes":48213,"documentSha256":"ff","change":{"v":1,"items":{},"settings":{"background":["backgroundPadding"]},"fields":[]},
           "restoredFrom":null,"mergedFromRevision":14,"openedAt":"2026-09-28T15:40:01.000Z",
           "updatedAt":"2026-09-28T15:42:09.123Z","isHead":true}],
         "nextBefore":null,"retention":{"maxHistoryDays":30,"maxNamedVersions":25,"namedCount":3},
         "pinnedMediaBytes":1048576,"freeableBytes":524288}
        """.utf8)
        let parsed = CloudHistoryParse.page(sample)
        let v = parsed?.versions.first
        expect(v?.actorName == "Ana" && v?.clientLabel == "Agent via Web" && v?.isHead == true && v?.firstRevision == 12
               && v?.mergedFromRevision == 14 && v?.summary == "Background changed" && v?.documentBytes == 48213
               && parsed?.isOwner == false && parsed?.retention?.maxNamed == 25 && parsed?.retention?.namedCount == 3
               && parsed?.freeableBytes == 524_288 && parsed?.nextBefore == nil,
               "CloudHistoryParse reads the contract's version list exactly (actor, client, source, change, retention, bytes)")
        let conflictBody: [String: Any] = ["code": "revision_conflict", "revision": 9, "documentSha256": "aa",
                                           "updatedAt": "2026-09-28T15:42:09.123Z", "document": "{}", "headVersionId": "h9"]
        let parsedConflict = HTTPCloudProjectTransport.conflict(conflictBody)
        expect(parsedConflict.revision == 9 && parsedConflict.headVersionID == "h9" && parsedConflict.updatedAt != nil,
               "a 409 revision_conflict body parses with its headVersionId and updatedAt")
        let preview = try await client.previewProject(projectID: id, versionID: upload.id, projectDirectory: dir)
        expect(preview.isPreview && preview.id == id, "a version opens as a read-only preview project")
        expect(try !ProjectStore.persists(preview) && ProjectStore.persists(try loadLocal(fixture)),
               "ProjectStore's save gate refuses a preview project (and only a preview)")
        _ = fm
    }

    /// Synthesized click at `point` (view coordinates) through the view's
    /// REAL mouseDown/mouseUp path.
    static func clickAt(_ view: NSView, _ point: NSPoint) {
        guard let window = view.window else { return }
        let location = view.convert(point, to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        if let down = event(.leftMouseDown), let up = event(.leftMouseUp) {
            view.mouseDown(with: down)
            view.mouseUp(with: up)
        }
    }
}
