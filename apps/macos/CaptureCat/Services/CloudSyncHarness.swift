import AppKit
import CryptoKit
import Foundation
import ImageIO
import Network

/// `CaptureCat --cloud-sync-test` — headless acceptance gate for cloud
/// projects (web editor sync). No network and no real projects: it builds a
/// synthetic project in a throwaway temp folder and drives the REAL
/// `CloudProjectSync` engine (manifest, hashing, upload plan, finalize loop,
/// document save/pull, the sidecar, and the `ProjectFileIO` atomic write the
/// GUI reloads from) against `StubCloudServer`, an in-memory stand-in that
/// enforces the API's semantics: content-addressed objects, SHA-256 + size
/// verification at finalize, If-Match revisions with 409 conflicts, byte-
/// exact document storage, expiring presigns.
///
/// Media the web editor adds (voice-over takes, backgrounds, logos): the pull
/// must download them — verified, before project.json is applied, nothing
/// applied if one fails — and a later push must keep them in the manifest
/// (`webMediaChecks`, `secondMacChecks`). The REAL HTTP download path is
/// driven against a loopback server (`httpDownloadChecks`).
///
/// Then the UI: the real editor top bar (hosted like the editor window hosts
/// it) is measured at three widths with the Web Editor button clicked through
/// its real mouse path, and the real progress dialog is presented, driven
/// and cancelled — topology, not a bare pre-sized view (CLAUDE.md §3).
///
/// Every check prints; the process exits 0 only if all pass.
enum CloudSyncHarness {
    static func run() -> Never {
        setbuf(stdout, nil)
        // The UI section hosts real windows (parked off-screen), so run a real
        // app loop — accessory, never activated, like --editor-shell-shot.
        CCTheme.setMode(.dark, persist: false)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            CCTheme.setMode(.dark, persist: false)
            let ok = await execute()
            exit(ok ? 0 : 1)
        }
        app.run()
        exit(1)
    }

    final class Checks {
        var passed = 0
        var failures: [String] = []
        func expect(_ condition: Bool, _ label: String) {
            if condition {
                passed += 1
                print("  ✓ \(label)")
            } else {
                failures.append(label)
                print("  ✘ \(label)")
            }
        }
    }

    // MARK: - Fixture

    struct Fixture {
        let root: URL
        let dir: URL
        let external: URL
        let project: Project
        var json: URL { dir.appendingPathComponent("project.json") }
    }

    static func makeFixture() throws -> Fixture {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("capturecat-cloud-sync-test-\(UUID().uuidString)", isDirectory: true)
        let id = UUID()
        let dir = root.appendingPathComponent("Projects/\(id.uuidString)", isDirectory: true)
        let wallpapers = root.appendingPathComponent("Wallpapers", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try fm.createDirectory(at: wallpapers, withIntermediateDirectories: true)

        // 9 MiB of deterministic noise: more than two 4 MiB hash chunks.
        var rng = SplitMix64(seed: 0xCA7CA7)
        var movie = Data(count: 9 * 1024 * 1024 + 123)
        movie.withUnsafeMutableBytes { raw in
            for i in 0..<raw.count { raw[i] = UInt8(truncatingIfNeeded: rng.next()) }
        }
        try movie.write(to: dir.appendingPathComponent("recording.mov"))
        try Data("fake camera".utf8).write(to: dir.appendingPathComponent("camera.mov"))
        try Data(#"{"events":[{"t":0.1,"x":0.5,"y":0.5}]}"#.utf8).write(to: dir.appendingPathComponent("cursor.json"))
        try Data(#"{"keys":[]}"#.utf8).write(to: dir.appendingPathComponent("keys.json"))
        try Data("poster".utf8).write(to: dir.appendingPathComponent("camera_poster.png"))
        try Data("thumb".utf8).write(to: dir.appendingPathComponent("thumbnail.jpg"))
        let voiceName = "voiceover-\(UUID().uuidString).m4a"
        try Data("voice".utf8).write(to: dir.appendingPathComponent(voiceName))
        try Data("watermark".utf8).write(to: dir.appendingPathComponent("watermark-abcd1234.png"))
        try Data("curtain".utf8).write(to: dir.appendingPathComponent("curtain-logo-1a2b.png"))
        let external = wallpapers.appendingPathComponent("My Wall.jpg")
        try Data("wallpaper".utf8).write(to: external)
        // Things that must NEVER be uploaded.
        try Data("{}".utf8).write(to: dir.appendingPathComponent("project.json.bak"))
        try fm.createDirectory(at: dir.appendingPathComponent(".mcp-history"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dir.appendingPathComponent(".mcp-history/0001.json"))
        try Data("stray".utf8).write(to: dir.appendingPathComponent("unreferenced.png"))

        let project = Project(
            id: id,
            name: "Cloud Sync Fixture",
            videoURL: dir.appendingPathComponent("recording.mov"),
            cursorDataURL: dir.appendingPathComponent("cursor.json"),
            cameraVideoURL: dir.appendingPathComponent("camera.mov"),
            duration: 12.5
        )
        project.keystrokeDataURL = dir.appendingPathComponent("keys.json")
        project.voiceOverClips = [VoiceOverClip(fileName: voiceName, startTime: 1, duration: 2)]
        // A clip whose file is gone must be skipped, not fatal.
        project.voiceOverClips.append(VoiceOverClip(fileName: "voiceover-missing.m4a", startTime: 4, duration: 1))
        project.settings.watermarkFileName = "watermark-abcd1234.png"
        project.settings.curtainLogoFileName = "curtain-logo-1a2b.png"
        project.settings.backgroundImagePath = external.path

        let fixture = Fixture(root: root, dir: dir, external: external, project: project)
        try writeProject(project, to: fixture.json)
        return fixture
    }

    static func writeProject(_ project: Project, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        try encoder.encode(project).write(to: url, options: .atomic)
    }

    /// Edit project.json on disk the way the app would (decode → mutate →
    /// encode), returning the reloaded project.
    @discardableResult
    static func editLocal(_ fixture: Fixture, _ mutate: (Project) -> Void) throws -> Project {
        let project = try JSONDecoder().decode(Project.self, from: Data(contentsOf: fixture.json))
        mutate(project)
        try writeProject(project, to: fixture.json)
        return project
    }

    static func loadLocal(_ fixture: Fixture) throws -> Project {
        try JSONDecoder().decode(Project.self, from: Data(contentsOf: fixture.json))
    }

    // MARK: - Run

    private static func execute() async -> Bool {
        print("CLOUD SYNC TEST")
        let checks = Checks()
        let expect = checks.expect
        let fixture: Fixture
        do {
            fixture = try makeFixture()
        } catch {
            print("  ✘ fixture: \(error)")
            return false
        }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let id = fixture.project.id
        let apiBase = "https://api.stub.test"

        do {
            // ── 1. Path rules (mirror of the API's checkLogicalPath) ─────────
            print("paths")
            for good in ["recording.mov", "cursor.json", "voiceover-\(UUID().uuidString).m4a", "external/0123456789ab.jpg", "camera_poster.png"] {
                expect(CloudPath.isValid(good), "valid: \(good)")
            }
            for bad in ["../x.json", "/abs.mov", ".hidden.json", "a/.b.json", "project.json", "a/b/c/d/e.json", "x.svg", "noext", "a\\b.json", ""] {
                expect(!CloudPath.isValid(bad), "invalid: \(bad.isEmpty ? "<empty>" : bad)")
            }

            // ── 2. Manifest ─────────────────────────────────────────────────
            print("manifest")
            let manifest = try await CloudProjectManifest.build(project: fixture.project, projectDirectory: fixture.dir)
            let paths = Set(manifest.files.map(\.path))
            let externalSHA = CloudProjectManifest.sha256(of: try Data(contentsOf: fixture.external))
            let voice = fixture.project.voiceOverClips[0].fileName
            let expected: Set<String> = [
                "recording.mov", "cursor.json", "keys.json", "camera.mov", voice,
                "watermark-abcd1234.png", "curtain-logo-1a2b.png", "camera_poster.png", "thumbnail.jpg",
                "external/\(externalSHA.prefix(12)).jpg",
            ]
            expect(paths == expected, "manifest holds exactly the referenced files (\(paths.count))")
            expect(!paths.contains { $0.hasSuffix(".bak") || $0.hasPrefix(".") || $0 == "project.json" || $0 == "unreferenced.png" },
                   "project.json, .bak, hidden and unreferenced files are never uploaded")
            expect(manifest.files.allSatisfy { CloudPath.isValid($0.path) }, "every manifest path passes the server's rules")
            let movieData = try Data(contentsOf: fixture.dir.appendingPathComponent("recording.mov"))
            let recording = manifest.files.first { $0.path == "recording.mov" }
            expect(recording?.sha256 == CloudProjectManifest.sha256(of: movieData),
                   "streamed 4 MiB-chunk SHA-256 == one-shot SHA-256 (9 MiB file)")
            expect(recording?.bytes == Int64(movieData.count), "byte count matches the file")
            expect(recording?.contentType == "video/quicktime", ".mov → video/quicktime")
            expect(manifest.files.first { $0.path == "cursor.json" }?.contentType == "application/json", ".json → application/json")
            let ext = manifest.files.first { $0.path.hasPrefix("external/") }
            expect(ext?.source == fixture.external.path, "external file carries its exact project.json reference as source")
            expect(manifest.files.filter { $0.path != ext?.path }.allSatisfy { $0.source == nil },
                   "in-folder files need no source")
            // The raw-JSON reference scan (what push/pull use to decide which
            // cloud files a document needs) agrees with the model walk that
            // builds the manifest — one set of references, two readers.
            let scanned = CloudDocumentReferences.referencedPaths(by: try Data(contentsOf: fixture.json),
                                                                  in: CloudFileIndex(manifest))
            expect(scanned == paths, "project.json reference scan finds exactly the manifest's files (\(scanned?.count ?? -1))")
            // An image over the server's per-kind ceiling (64 MiB) is skipped
            // up front — sparse file, so the check costs no disk or hashing.
            let huge = fixture.root.appendingPathComponent("huge.png")
            FileManager.default.createFile(atPath: huge.path, contents: nil)
            let handle = try FileHandle(forWritingTo: huge)
            try handle.truncate(atOffset: UInt64(65 << 20))
            try handle.close()
            let oversize = try await CloudProjectManifest.hash([CloudFileReference(localURL: huge, relativePath: "huge.png", source: nil)])
            expect(oversize.files.isEmpty && oversize.skipped == ["huge.png"],
                   "an image over the 64 MiB kind ceiling is skipped, not sent to a certain 413")

            // Browser-undecodable images (HEIC wallpapers, TIFF logos) are
            // converted to PNG once, mapped back to their original reference
            // via `source`, and served from a content-keyed cache next time.
            func writeImage(_ url: URL, type: String) -> Bool {
                let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.displayP3)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
                guard let image = ctx.makeImage(),
                      let dest = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else { return false }
                CGImageDestinationAddImage(dest, image, nil)
                return CGImageDestinationFinalize(dest)
            }
            let heicIn = fixture.root.appendingPathComponent("logo.heic")
            let tiffOut = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-harness-wall-\(getpid()).tiff")
            defer { try? FileManager.default.removeItem(at: tiffOut) }
            let wroteImages = writeImage(heicIn, type: "public.heic") && writeImage(tiffOut, type: "public.tiff")
            expect(wroteImages, "wrote HEIC + TIFF fixtures")
            let images = try await CloudProjectManifest.hash([
                CloudFileReference(localURL: heicIn, relativePath: "logo.heic", source: nil),
                CloudFileReference(localURL: tiffOut, relativePath: nil, source: tiffOut.path),
            ])
            let heicFile = images.files.first { $0.source == "logo.heic" }
            let tiffFile = images.files.first { $0.source == tiffOut.path }
            expect(images.skipped.isEmpty && heicFile?.path == "logo.heic.png" && heicFile?.contentType == "image/png",
                   "in-folder HEIC uploads as logo.heic.png, source = its relative path (got \(heicFile?.path ?? "nil"))")
            expect(tiffFile.map { $0.path.hasPrefix("external/") && $0.path.hasSuffix(".png") } == true,
                   "external TIFF uploads as external/<sha12>.png, source = the exact reference")
            let decodes = heicFile?.localURL.flatMap { CGImageSourceCreateWithURL($0 as CFURL, nil) }
                .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
            expect(decodes?.width == 64 && decodes?.height == 48, "converted PNG decodes at the source size")
            expect(decodes?.colorSpace?.name == CGColorSpace.displayP3, "converted PNG keeps the Display P3 profile")
            let rehashed = try await CloudProjectManifest.hash([
                CloudFileReference(localURL: heicIn, relativePath: "logo.heic", source: nil),
            ])
            expect(rehashed.files.first?.localURL == heicFile?.localURL && rehashed.files.first?.sha256 == heicFile?.sha256,
                   "second sync reuses the cached conversion (same file, same hash)")
            try? FileManager.default.removeItem(at: heicIn)

            // ── 3. First push: everything uploads, verified, rev 1 ─────────
            print("push (fresh)")
            let server = StubCloudServer(ownerUID: "stub-owner")
            let sync = CloudProjectSync(transport: server, apiBaseURL: apiBase)
            var fractions: [Double] = []
            let first = try await sync.push(project: fixture.project, projectDirectory: fixture.dir) { p in
                if p.phase == .uploading { fractions.append(p.fraction) }
            }
            expect(first == .pushed(revision: 1), "fresh push → pushed revision 1 (got \(first))")
            expect(server.uploads.count == Set(manifest.files.map(\.sha256)).count, "one upload per distinct object (\(server.uploads.count))")
            expect(server.uploads.allSatisfy { $0.contentTypeMatched && $0.lengthMatched },
                   "every PUT carried the signed content type and exact length")
            expect(zip(fractions, fractions.dropFirst()).allSatisfy { $0 <= $1 } && (fractions.last ?? 0) >= 0.999,
                   "upload progress is monotonic and reaches 100% (\(fractions.count) updates)")
            expect(server.committedPaths == paths, "server committed exactly the manifest")
            let localBytes = try Data(contentsOf: fixture.json)
            expect(server.document == localBytes, "cloud document is byte-identical to project.json")
            let state1 = CloudSyncState.load(from: fixture.dir, projectID: id, apiBaseURL: apiBase)
            expect(state1?.revision == 1 && state1?.documentSHA256 == CloudProjectManifest.sha256(of: localBytes),
                   "sidecar records revision 1 + the document hash")
            expect(CloudSyncState.load(from: fixture.dir, projectID: id, apiBaseURL: "http://localhost:8787") == nil,
                   "sidecar is keyed by API origin (Debug localhost never reads prod state)")
            expect(CloudSyncState.load(from: fixture.dir, projectID: UUID(), apiBaseURL: apiBase) == nil,
                   "sidecar is keyed by project id (a duplicated folder starts fresh)")

            // ── 4. Idempotent re-push ──────────────────────────────────────
            print("push (no changes)")
            server.resetCounters()
            let again = try await sync.push(project: fixture.project, projectDirectory: fixture.dir)
            expect(again == .unchanged(revision: 1), "unchanged project → unchanged (got \(again))")
            expect(server.uploads.isEmpty && server.saveCalls == 0, "nothing uploaded, nothing saved")

            // ── 5. Only changed media re-uploads ───────────────────────────
            print("push (one media file changed)")
            server.resetCounters()
            try Data(#"{"events":[{"t":0.2,"x":0.1,"y":0.9}]}"#.utf8).write(to: fixture.dir.appendingPathComponent("cursor.json"))
            let mediaOnly = try await sync.push(project: fixture.project, projectDirectory: fixture.dir)
            expect(server.uploads.map(\.paths) == [["cursor.json"]], "only cursor.json re-uploaded (\(server.uploads.map(\.paths)))")
            expect(mediaOnly == .unchanged(revision: 1), "document untouched → no new revision")
            expect(server.garbageCollected == 1, "server dropped the superseded cursor.json object")

            // ── 6. Expired presign → restage once, resume ──────────────────
            print("push (expired upload URL)")
            server.resetCounters()
            server.expireNextUpload = true
            try Data(#"{"keys":[{"t":1}]}"#.utf8).write(to: fixture.dir.appendingPathComponent("keys.json"))
            _ = try await sync.push(project: fixture.project, projectDirectory: fixture.dir)
            expect(server.stageCalls == 2, "expired URL triggered exactly one restage (\(server.stageCalls))")
            expect(server.uploads.count == 1 && server.uploads[0].paths == ["keys.json"], "keys.json landed on the fresh URL")

            // ── 7. Local document edit → new revision ──────────────────────
            print("push (document edit)")
            server.resetCounters()
            let renamed = try editLocal(fixture) { $0.name = "Renamed on the Mac" }
            let edit = try await sync.push(project: renamed, projectDirectory: fixture.dir)
            expect(edit == .pushed(revision: 2), "edit → revision 2 (got \(edit))")
            expect(server.lastSaveBase == 1, "save was based on the last-synced revision (If-Match 1)")
            expect(server.uploads.isEmpty, "no media re-uploaded for a document edit")

            // ── 8. Web edit: push does not clobber; pull brings it here ────
            print("web edit → pull")
            let webDoc = try webEdited(server.document!, name: "Edited on the web", extraKey: "webOnlyKey")
            server.webSave(webDoc) // revision 3
            let noClobber = try await sync.push(project: try loadLocal(fixture), projectDirectory: fixture.dir)
            expect(noClobber == .cloudIsNewer(revision: 3), "unchanged Mac + newer web → cloudIsNewer, no save (got \(noClobber))")
            expect(server.document == webDoc, "web revision untouched by the push")

            let beforePull = try Data(contentsOf: fixture.json)
            let mtimeBefore = try modificationDate(fixture.json)
            try await Task.sleep(for: .milliseconds(20))
            let pulled = try await sync.pull(projectID: id, projectDirectory: fixture.dir)
            expect(pulled == .pulled(revision: 3), "pull → revision 3 (got \(pulled))")
            let afterPull = try Data(contentsOf: fixture.json)
            expect(afterPull == webDoc, "pulled project.json is byte-identical to the web's document")
            expect(String(decoding: afterPull, as: UTF8.self).contains("webOnlyKey"), "a key this build does not know survives the pull")
            expect(try loadLocal(fixture).name == "Edited on the web", "the app's own Codable decodes the pulled document")
            expect((try? Data(contentsOf: fixture.json.appendingPathExtension("bak"))) == beforePull,
                   "previous project.json kept as project.json.bak (MCP write contract)")
            expect(try modificationDate(fixture.json) > mtimeBefore, "mtime advanced — the GUI's external-edit poll will reload it")
            expect(!(try FileManager.default.contentsOfDirectory(atPath: fixture.dir.path)).contains { $0.hasPrefix(".project.json.tmp") },
                   "no temp file left behind (atomic replace)")
            expect(CloudSyncState.load(from: fixture.dir, projectID: id, apiBaseURL: apiBase)?.revision == 3, "sidecar advanced to revision 3")
            let upToDate = try await sync.pull(projectID: id, projectDirectory: fixture.dir)
            expect(upToDate == .upToDate(revision: 3), "second pull → up to date")

            // ── 9. Both sides changed → conflict, nothing lost ─────────────
            print("conflict")
            server.webSave(try webEdited(server.document!, name: "Web again", extraKey: "webKey2")) // rev 4
            let macEdit = try editLocal(fixture) { $0.name = "Mac again" }
            let macBytes = try Data(contentsOf: fixture.json)
            // This section is the NO-MERGE-BASE fallback (a sidecar written
            // by a build before merge bases, against a server that no longer
            // retains the agreed revision) — the two-way dialog's path. The
            // three-way merges are `mergeChecks` below.
            try? FileManager.default.removeItem(at: fixture.dir.appendingPathComponent(CloudSyncState.baseFileName))
            server.retainsRevisions = false
            let conflict = try await sync.push(project: macEdit, projectDirectory: fixture.dir)
            expect(conflict == .conflict(remoteRevision: 4), "both changed → conflict at revision 4 (got \(conflict))")
            expect(String(decoding: server.document!, as: UTF8.self).contains("Web again"), "conflict saved nothing over the web's revision")
            let refused = try await sync.pull(projectID: id, projectDirectory: fixture.dir)
            expect(refused == .localChangesWouldBeLost(remoteRevision: 4), "pull refuses to discard unsynced Mac edits (got \(refused))")
            expect(try Data(contentsOf: fixture.json) == macBytes, "local project.json untouched by the refused pull")
            server.retainsRevisions = true

            // "Replace Web Version": save based on the cloud's revision.
            let replaced = try await sync.push(project: macEdit, projectDirectory: fixture.dir, overwriteRevision: 4)
            expect(replaced == .pushed(revision: 5), "replace web version → revision 5 (got \(replaced))")
            expect(server.document == macBytes, "cloud now holds the Mac's bytes")

            // "Pull Web Edits" on a conflict: force.
            server.webSave(try webEdited(server.document!, name: "Web wins", extraKey: "webKey3")) // rev 6
            _ = try editLocal(fixture) { $0.name = "Mac loses" }
            let forced = try await sync.pull(projectID: id, projectDirectory: fixture.dir, force: true)
            expect(forced == .pulled(revision: 6), "forced pull → revision 6 (got \(forced))")
            expect(try loadLocal(fixture).name == "Web wins", "forced pull replaced the Mac edit")

            // ── 10. Media URLs from another Mac are re-based ───────────────
            print("rebase")
            let foreign = try webEditedURLs(server.document!, projectID: id)
            server.webSave(foreign) // rev 7
            let rebased = try await sync.pull(projectID: id, projectDirectory: fixture.dir)
            expect(rebased == .pulled(revision: 7), "pull of a foreign-path document (got \(rebased))")
            let local = try loadLocal(fixture)
            expect(local.videoURL?.resolvingSymlinksInPath() == fixture.dir.appendingPathComponent("recording.mov").resolvingSymlinksInPath(),
                   "videoURL re-based onto this Mac's project folder")
            expect(local.cursorDataURL?.lastPathComponent == "cursor.json"
                   && CloudProjectManifest.relativePath(of: local.cursorDataURL!, in: fixture.dir) == "cursor.json",
                   "cursorDataURL re-based too")
            expect(String(decoding: try Data(contentsOf: fixture.json), as: UTF8.self).contains("webKey3"),
                   "re-basing kept every other key (incl. unknown ones)")

            // ── 11. A document this Mac cannot open never touches disk ─────
            print("invalid remote documents")
            let safe = try Data(contentsOf: fixture.json)
            server.webSave(try replacingID(server.document!, with: UUID()))
            do {
                _ = try await sync.pull(projectID: id, projectDirectory: fixture.dir, force: true)
                expect(false, "another project's document is refused")
            } catch let error as CloudSyncError {
                expect(error == .projectMismatch, "another project's document is refused (projectMismatch)")
            }
            server.webSave(Data(#"{"id":"\#(id.uuidString)","name":"broken"}"#.utf8))
            do {
                _ = try await sync.pull(projectID: id, projectDirectory: fixture.dir, force: true)
                expect(false, "an undecodable document is refused")
            } catch let error as CloudSyncError {
                if case .invalidRemoteDocument = error { expect(true, "an undecodable document is refused (invalidRemoteDocument)") }
                else { expect(false, "an undecodable document is refused (got \(error))") }
            }
            expect(try Data(contentsOf: fixture.json) == safe, "local project.json unchanged after both refusals")

            // ── 12. No cloud copy ───────────────────────────────────────────
            print("no cloud copy")
            let empty = CloudProjectSync(transport: StubCloudServer(ownerUID: "other"), apiBaseURL: apiBase)
            let none = try await empty.pull(projectID: id, projectDirectory: fixture.dir)
            expect(none == .noCloudCopy, "pull with nothing in the cloud → noCloudCopy")

            // ── 13. Web editor URL ──────────────────────────────────────────
            print("web editor url")
            let url = CaptureCatAPI.webEditorURL(projectID: id).absoluteString
            expect(url.hasSuffix("/editor/\(id.uuidString)"), "web editor URL ends /editor/<projectId> (\(url))")

            // ── 14. Media the web editor added: pull brings it, push keeps it
            try await webMediaChecks(checks, apiBase: apiBase)
            try await secondMacChecks(checks, apiBase: apiBase)
            await httpDownloadChecks(checks)

            // ── 15b. Project history: merge base, three-way merges, Merge
            //         Review in a real window, attribution, history client
            try await mergeChecks(checks, apiBase: apiBase)

            // ── 15. UI: the real top bar + progress dialog, real windows ────
            await probeUI(checks, project: fixture.project)
        } catch {
            checks.failures.append("unexpected error: \(error)")
            print("  ✘ unexpected error: \(error)")
        }

        if checks.failures.isEmpty {
            print("CLOUD SYNC PASS (\(checks.passed) checks)")
            return true
        }
        print("CLOUD SYNC FAIL (\(checks.failures.count) of \(checks.passed + checks.failures.count)):")
        for failure in checks.failures { print("  ✘ \(failure)") }
        return false
    }

    // MARK: - Web-added media

    /// The web editor adds files to a cloud project — voice-over takes
    /// (`voiceover-<UUID>.m4a`, `.wav` from Firefox), a background image
    /// (`backgroundImagePath` = `/CaptureCat/Projects/<UUID>/<name>`),
    /// watermark and curtain logos — by restaging the whole manifest plus the
    /// new file, then saving a project.json that names it. The Mac must
    /// download those files BEFORE applying that document (or not apply it
    /// at all), and a later Mac push must not drop them from the manifest.
    private static func webMediaChecks(_ checks: Checks, apiBase: String) async throws {
        let expect = checks.expect
        let fm = FileManager.default
        let fixture = try makeFixture()
        defer { try? fm.removeItem(at: fixture.root) }
        let id = fixture.project.id
        let dir = fixture.dir
        let server = StubCloudServer(ownerUID: "stub-owner")
        let sync = CloudProjectSync(transport: server, apiBaseURL: apiBase)
        func bytes(_ name: String) -> Data? { try? Data(contentsOf: dir.appendingPathComponent(name)) }
        func exists(_ name: String) -> Bool { fm.fileExists(atPath: dir.appendingPathComponent(name).path) }
        func leftovers() -> [String] {
            // Partial downloads only — the sidecar and its merge base are
            // supposed to be there.
            ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter {
                $0.hasPrefix(".cloudsync-") && $0 != CloudSyncState.fileName && $0 != CloudSyncState.baseFileName
            }
        }
        func revision() -> Int? { CloudSyncState.load(from: dir, projectID: id, apiBaseURL: apiBase)?.revision }
        func clip(_ fileName: String, at start: Double) -> [String: Any] {
            ["id": UUID().uuidString, "fileName": fileName, "startTime": start, "sourceStartTime": 0,
             "duration": 1.5, "sourceDuration": 1.5, "gain": 1, "label": "Web take"]
        }
        func pullFailure(_ label: String) async -> CloudSyncError? {
            do {
                let outcome = try await sync.pull(projectID: id, projectDirectory: dir)
                expect(false, "\(label) (pull returned \(outcome))")
            } catch let error as CloudSyncError {
                return error
            } catch {
                expect(false, "\(label) (threw \(error))")
            }
            return nil
        }

        print("web media: path + type rules")
        for good in ["voiceover-\(UUID().uuidString).m4a", "voiceover-\(UUID().uuidString).wav",
                     "watermark-1A2B3C4D.png", "curtain-logo-9F8E7D6C.jpg", "bg-5e6f7a8b.webp"] {
            expect(CloudPath.isValid(good), "valid: \(good)")
        }
        expect(CloudPath.accepts("audio/wav", for: "a.wav") && CloudPath.accepts("audio/x-wav", for: "a.wav")
               && CloudPath.accepts("audio/x-m4a", for: "a.m4a") && !CloudPath.accepts("audio/mpeg", for: "a.wav"),
               "content types mirror the API's aliases (wav, x-wav, x-m4a)")

        _ = try await sync.push(project: fixture.project, projectDirectory: dir) // revision 1

        // ── The web adds five files, then saves a document naming them ──
        print("web media: pull downloads what the web added")
        let voiceM4A = "voiceover-\(UUID().uuidString).m4a"
        let voiceWAV = "voiceover-\(UUID().uuidString).wav"
        let bgName = "bg-\(UUID().uuidString.prefix(8).lowercased()).png"
        let wmName = "watermark-\(UUID().uuidString.prefix(8)).png"
        let clName = "curtain-logo-\(UUID().uuidString.prefix(8)).png"
        let bgRef = "/CaptureCat/Projects/\(id.uuidString)/\(bgName)"
        let added: [String: Data] = [
            voiceM4A: Data("web voice take, AAC in an MP4 box".utf8),
            voiceWAV: Data("web voice take, Firefox PCM WAVE".utf8),
            bgName: Data("web background PNG".utf8),
            wmName: Data("web watermark PNG".utf8),
            clName: Data("web curtain logo PNG".utf8),
        ]
        server.webAddFiles([
            (voiceM4A, added[voiceM4A]!, "audio/mp4", nil),
            (voiceWAV, added[voiceWAV]!, "audio/wav", nil),
            (bgName, added[bgName]!, "image/png", nil),
            (wmName, added[wmName]!, "image/png", nil),
            (clName, added[clName]!, "image/png", nil),
        ])
        server.webSave(try webEditedJSON(server.document!) { doc, settings in
            doc["name"] = "Web added media"
            doc["webMediaKey"] = ["kept": true]
            var clips = doc["voiceOverClips"] as? [[String: Any]] ?? []
            clips.append(clip(voiceM4A, at: 2))
            clips.append(clip(voiceWAV, at: 5))
            doc["voiceOverClips"] = clips
            settings["backgroundImagePath"] = bgRef
            settings["watermarkFileName"] = wmName
            settings["curtainLogoFileName"] = clName
        }) // revision 2

        let beforePull = try Data(contentsOf: fixture.json)
        var documentAtDownload: [Bool] = []
        server.onDownload = { _ in documentAtDownload.append((try? Data(contentsOf: fixture.json)) == beforePull) }
        var downloadFractions: [Double] = []
        let pulled = try await sync.pull(projectID: id, projectDirectory: dir) { step in
            if step.phase == .downloading { downloadFractions.append(step.fraction) }
        }
        server.onDownload = nil
        expect(pulled == .pulled(revision: 2), "pull of the web's media edit → revision 2 (got \(pulled))")
        expect(Set(server.downloads) == Set(added.keys),
               "downloaded exactly the 5 web-added files, nothing this Mac already had (got \(server.downloads.sorted()))")
        expect(!documentAtDownload.isEmpty && documentAtDownload.allSatisfy { $0 },
               "every download happened BEFORE project.json was replaced")
        for (name, data) in added.sorted(by: { $0.key < $1.key }) {
            expect(bytes(name) == data, "\(name) is in the project folder, byte-exact")
        }
        let local = try loadLocal(fixture)
        let webClips = local.voiceOverClips.filter { $0.fileName == voiceM4A || $0.fileName == voiceWAV }
        expect(webClips.count == 2 && webClips.allSatisfy { fm.fileExists(atPath: $0.resolvedURL(in: dir).path) },
               "both web voice-overs (.m4a + .wav) resolve to files — ProjectAudioMix no longer skips them")
        expect(local.settings.backgroundImagePath == dir.appendingPathComponent(bgName).path,
               "backgroundImagePath re-pointed at the downloaded file (\(local.settings.backgroundImagePath ?? "nil"))")
        expect(local.settings.backgroundImagePath.map { fm.fileExists(atPath: $0) } == true,
               "… which exists — no fall-back to the base fill")
        expect(local.watermarkImageURL.map { fm.fileExists(atPath: $0.path) } == true, "the web's watermark logo resolves")
        expect(local.curtainLogoImageURL.map { fm.fileExists(atPath: $0.path) } == true, "the web's curtain logo resolves")
        let written = String(decoding: try Data(contentsOf: fixture.json), as: UTF8.self)
        expect(written.contains("webMediaKey") && local.name == "Web added media",
               "the rest of the web's document (incl. unknown keys) applied as sent")
        expect(leftovers().isEmpty, "no partial downloads left behind (\(leftovers()))")
        expect(!downloadFractions.isEmpty && zip(downloadFractions, downloadFractions.dropFirst()).allSatisfy { $0 <= $1 }
               && (downloadFractions.last ?? 0) >= 0.999,
               "download progress is monotonic and reaches 100% (\(downloadFractions.count) updates)")
        expect(revision() == 2, "sidecar advanced to revision 2")
        server.resetCounters()
        let settled = try await sync.pull(projectID: id, projectDirectory: dir)
        expect(settled == .upToDate(revision: 2) && server.downloads.isEmpty,
               "second pull → up to date, nothing downloaded (got \(settled), \(server.downloads))")

        // ── A file whose SHA-256 differs is fetched again ─────────────────
        print("web media: changed files")
        server.resetCounters()
        var tampered = added[voiceM4A]!
        tampered[0] ^= 0x55 // same size: only the checksum can tell
        try tampered.write(to: dir.appendingPathComponent(voiceM4A))
        let keysV2 = Data(#"{"keys":[{"t":2.5,"k":"⌘S"}]}"#.utf8)
        server.webAddFiles([("keys.json", keysV2, "application/json", nil)]) // another client replaced it
        server.webSave(try webEdited(server.document!, name: "Web rev 3", extraKey: "rev3")) // revision 3
        let changed = try await sync.pull(projectID: id, projectDirectory: dir)
        expect(changed == .pulled(revision: 3), "pull → revision 3 (got \(changed))")
        expect(Set(server.downloads) == [voiceM4A, "keys.json"],
               "re-downloaded exactly the two files whose SHA-256 differs (got \(server.downloads.sorted()))")
        expect(bytes(voiceM4A) == added[voiceM4A], "same-size local file with the wrong hash replaced by the cloud's bytes")
        expect(bytes("keys.json") == keysV2, "a file the cloud replaced arrives in its new version")

        // ── An expired presigned GET is re-signed once ───────────────────
        print("web media: expired download link")
        server.resetCounters()
        let voice3 = "voiceover-\(UUID().uuidString).m4a"
        server.webAddFiles([(voice3, Data("take three".utf8), "audio/x-m4a", nil)])
        server.webSave(try webEditedJSON(server.document!) { doc, _ in
            doc["voiceOverClips"] = (doc["voiceOverClips"] as? [[String: Any]] ?? []) + [clip(voice3, at: 8)]
        }) // revision 4
        server.expireNextDownload = true
        let resigned = try await sync.pull(projectID: id, projectDirectory: dir)
        expect(resigned == .pulled(revision: 4) && server.fileListCalls == 1 && server.downloads == [voice3],
               "expired link → one GET …/files re-sign, download resumes (got \(resigned), lists \(server.fileListCalls))")

        // ── A failed download: nothing is applied, and the UI says so ─────
        print("web media: failed download")
        server.resetCounters()
        let voice4 = "voiceover-\(UUID().uuidString).m4a"
        let bg2 = "bg-\(UUID().uuidString.prefix(8).lowercased()).jpg"
        let cursorV2 = Data(#"{"events":[{"t":0.3,"x":0.2,"y":0.2}]}"#.utf8)
        server.webAddFiles([
            (voice4, Data("take four".utf8), "audio/mp4", nil),
            (bg2, Data("second background".utf8), "image/jpeg", nil),
            ("cursor.json", cursorV2, "application/json", nil),
        ])
        server.webSave(try webEditedJSON(server.document!) { doc, settings in
            doc["voiceOverClips"] = (doc["voiceOverClips"] as? [[String: Any]] ?? []) + [clip(voice4, at: 10)]
            settings["backgroundImagePath"] = "/CaptureCat/Projects/\(id.uuidString)/\(bg2)"
        }) // revision 5
        let safeDoc = try Data(contentsOf: fixture.json)
        let cursorBefore = bytes("cursor.json")
        server.failDownloads = [voice4]
        if let error = await pullFailure("a failed voice-over download fails the pull") {
            if case .downloadFailed(let paths, _) = error {
                expect(paths == [voice4], "the failure names the file that did not arrive (\(paths))")
            } else {
                expect(false, "a failed download → downloadFailed (got \(error))")
            }
            let message = CloudSyncController.message(for: error)
            expect(message.contains(voice4) && message.contains("not changed"),
                   "the alert names the file and says the project was not changed")
        }
        expect(try Data(contentsOf: fixture.json) == safeDoc, "project.json NOT applied — it would name a missing file")
        expect(revision() == 4, "sidecar still at revision 4")
        expect(bytes("cursor.json") == cursorBefore, "a file the failed pull would have REPLACED is untouched")
        expect(!exists(voice4), "the failed file is not in the folder")
        expect(leftovers().isEmpty, "no partial downloads left behind")

        server.failDownloads = []
        server.corruptDownloads = [voice4]
        if let error = await pullFailure("a corrupted transfer fails the pull") {
            if case .downloadFailed(let paths, let detail) = error {
                expect(paths == [voice4] && detail.lowercased().contains("checksum"),
                       "right length, wrong bytes → refused by the SHA-256 check (\(detail))")
            } else {
                expect(false, "a corrupted transfer → downloadFailed (got \(error))")
            }
        }
        expect(try Data(contentsOf: fixture.json) == safeDoc && !exists(voice4) && leftovers().isEmpty,
               "…and again nothing applied, nothing left behind")

        server.corruptDownloads = []
        server.resetCounters()
        let retried = try await sync.pull(projectID: id, projectDirectory: dir)
        expect(retried == .pulled(revision: 5), "retry once the fault clears → revision 5 (got \(retried))")
        expect(Set(server.downloads) == [voice4, "cursor.json"],
               "the retry fetches only the failed file + the held-back replacement (\(server.downloads.sorted()))")
        expect(bytes(voice4) == Data("take four".utf8) && bytes("cursor.json") == cursorV2, "both landed")
        expect(try loadLocal(fixture).settings.backgroundImagePath == dir.appendingPathComponent(bg2).path,
               "the second background is referenced by its local path")

        // ── Repair: an earlier build pulled only project.json ────────────
        print("web media: repair after a document-only pull")
        try? fm.removeItem(at: dir.appendingPathComponent(voiceWAV))
        server.resetCounters()
        let repaired = try await sync.pull(projectID: id, projectDirectory: dir)
        expect(repaired == .mediaRestored(revision: 5, files: 1) && exists(voiceWAV),
               "document already current, a referenced take missing → downloaded (got \(repaired))")

        // ── Push keeps what only the cloud holds ─────────────────────────
        print("web media: push keeps web-added files")
        // The web adds a take and saves; this Mac has not pulled. Its push
        // (unchanged document) must not drop the take the cloud document uses.
        server.resetCounters()
        let voice5 = "voiceover-\(UUID().uuidString).wav"
        let voice5Data = Data("take five".utf8)
        server.webAddFiles([(voice5, voice5Data, "audio/x-wav", nil)])
        server.webSave(try webEditedJSON(server.document!) { doc, _ in
            doc["voiceOverClips"] = (doc["voiceOverClips"] as? [[String: Any]] ?? []) + [clip(voice5, at: 12)]
        }) // revision 6
        let notPulled = try await sync.push(project: try loadLocal(fixture), projectDirectory: dir)
        expect(notPulled == .cloudIsNewer(revision: 6), "unchanged Mac → cloudIsNewer (got \(notPulled))")
        expect(server.committedPaths.contains(voice5) && server.ready[CloudProjectManifest.sha256(of: voice5Data)] != nil,
               "the web's take is still committed and stored (the web's document names it)")
        expect(server.committedFiles.first { $0.path == voice5 }?.contentType == "audio/x-wav",
               "…with the content type the web gave it")
        expect(server.uploads.isEmpty, "nothing re-uploaded")
        expect(Set(added.keys).subtracting([bgName]).isSubset(of: server.committedPaths),
               "every web file this Mac's document still names stays committed")

        // Both sides edited: the push conflicts, and still drops nothing.
        let voice6 = "voiceover-\(UUID().uuidString).m4a"
        server.webAddFiles([(voice6, Data("take six".utf8), "audio/mp4", nil)])
        server.webSave(try webEditedJSON(server.document!) { doc, _ in
            doc["voiceOverClips"] = (doc["voiceOverClips"] as? [[String: Any]] ?? []) + [clip(voice6, at: 14)]
        }) // revision 7
        let macEdit = try editLocal(fixture) { $0.name = "Mac edit during web edit" }
        // No merge base (older-build sidecar, revision not retained): the
        // two-way fallback, which must not drop the web's takes either.
        try? fm.removeItem(at: dir.appendingPathComponent(CloudSyncState.baseFileName))
        server.retainsRevisions = false
        let conflicted = try await sync.push(project: macEdit, projectDirectory: dir)
        server.retainsRevisions = true
        expect(conflicted == .conflict(remoteRevision: 7), "both changed → conflict (got \(conflicted))")
        expect(server.committedPaths.isSuperset(of: [voice5, voice6]), "a conflicting push drops none of the web's takes")

        // Pull them (force: the Mac edit loses), then a Mac edit pushes
        // with every file already in the cloud: no uploads at all.
        _ = try await sync.pull(projectID: id, projectDirectory: dir, force: true)
        expect(exists(voice5) && exists(voice6), "forced pull brought both takes")
        server.resetCounters()
        let edited = try editLocal(fixture) { $0.name = "Mac edit after pull" }
        let pushed = try await sync.push(project: edited, projectDirectory: dir)
        expect(pushed == .pushed(revision: 8), "Mac edit → revision 8 (got \(pushed))")
        expect(server.uploads.isEmpty, "no file re-uploaded — every SHA-256 was already in the cloud")
        expect(server.committedPaths.isSuperset(of: [voice4, voice5, voice6, voiceM4A, voiceWAV, bg2]),
               "the Mac's manifest carries every web-added file it references")

        // A document that names a file this Mac never downloaded (written by
        // an older build's pull): the push keeps the cloud's copy, uploads
        // nothing for it, and still saves.
        server.resetCounters()
        let voice7 = "voiceover-\(UUID().uuidString).m4a"
        server.webAddFiles([(voice7, Data("take seven".utf8), "audio/mp4", nil)])
        server.webSave(try webEditedJSON(server.document!) { doc, _ in
            doc["voiceOverClips"] = (doc["voiceOverClips"] as? [[String: Any]] ?? []) + [clip(voice7, at: 16)]
        }) // revision 9
        try ProjectFileIO.writeProjectData(server.document!, to: fixture.json) // the old pull: document only
        try CloudSyncState(projectID: id.uuidString, apiBaseURL: apiBase, revision: 9,
                           documentSHA256: CloudProjectManifest.sha256(of: server.document!), syncedAt: Date()).save(to: dir)
        let oldPull = try editLocal(fixture) { $0.name = "Edited after an old pull" }
        expect(!exists(voice7), "fixture: the take is only in the cloud")
        let keptPush = try await sync.push(project: oldPull, projectDirectory: dir)
        expect(keptPush == .pushed(revision: 10), "push → revision 10 (got \(keptPush))")
        expect(server.committedPaths.contains(voice7), "a take only the cloud holds, named by the pushed document, is kept")
        expect(!server.uploads.contains { $0.paths.contains(voice7) }, "…without being uploaded")

        // A cloud file NO document names any more is dropped (the Mac's push
        // is the only garbage collection a web-added file ever gets).
        server.resetCounters()
        let orphan = "voiceover-\(UUID().uuidString).m4a"
        server.webAddFiles([(orphan, Data("deleted take".utf8), "audio/mp4", nil)])
        _ = try await sync.push(project: try loadLocal(fixture), projectDirectory: dir)
        expect(!server.committedPaths.contains(orphan), "a cloud-only file no document references is dropped")
        expect(server.committedPaths.contains(voice7), "…while the referenced one stays")

        // The cloud lost a kept file's object (collected by a concurrent
        // restage): the push leaves that entry out instead of failing.
        server.resetCounters()
        server.loseObject(path: voice7)
        let lost = try await sync.push(project: try editLocal(fixture) { $0.name = "After a lost object" }, projectDirectory: dir)
        expect(lost == .pushed(revision: 11), "a kept file the cloud lost does not fail the push (got \(lost))")
        expect(!server.committedPaths.contains(voice7) && server.uploads.isEmpty,
               "…its entry is left out (nothing to upload it from)")

        // The progress dialog maps the new download phase onto its bar.
        let weights = CloudSyncController.pullWeights
        expect(weights[.downloading] != nil && weights[.hashing] != nil,
               "pull progress weights cover checking + downloading")
    }

    /// A second Mac opens the project: its folder holds only an older
    /// project.json, the wallpaper that lived OUTSIDE the first Mac's folder
    /// does not exist there, and the web re-saved the recording reference the
    /// way its recorder spells media (`file:///CaptureCat/Projects/<id>/…`).
    private static func secondMacChecks(_ checks: Checks, apiBase: String) async throws {
        let expect = checks.expect
        let fm = FileManager.default
        print("web media: pull onto another Mac")
        let fixture = try makeFixture()
        defer { try? fm.removeItem(at: fixture.root) }
        let id = fixture.project.id
        let server = StubCloudServer(ownerUID: "stub-owner")
        let sync = CloudProjectSync(transport: server, apiBaseURL: apiBase)
        _ = try await sync.push(project: fixture.project, projectDirectory: fixture.dir) // revision 1, Mac A
        let manifest = server.committedFiles
        let externalEntry = manifest.first { $0.path.hasPrefix("external/") }
        server.webSave(try webEditedJSON(server.document!) { doc, _ in
            doc["videoURL"] = "file:///CaptureCat/Projects/\(id.uuidString)/recording.mov"
            doc["name"] = "Opened on Mac B"
        }) // revision 2

        let dirB = fixture.root.appendingPathComponent("MacB/Projects/\(id.uuidString)", isDirectory: true)
        try fm.createDirectory(at: dirB, withIntermediateDirectories: true)
        try Data(contentsOf: fixture.json).write(to: dirB.appendingPathComponent("project.json"))
        try fm.removeItem(at: fixture.external)

        let asked = try await sync.pull(projectID: id, projectDirectory: dirB)
        expect(asked == .localChangesWouldBeLost(remoteRevision: 2),
               "no sync history on this Mac → asks before replacing (got \(asked))")
        let pulled = try await sync.pull(projectID: id, projectDirectory: dirB, force: true)
        expect(pulled == .pulled(revision: 2), "forced pull → revision 2 (got \(pulled))")
        let wrong = manifest.filter {
            (try? Data(contentsOf: dirB.appendingPathComponent($0.path))).map(CloudProjectManifest.sha256(of:)) != $0.sha256
        }
        expect(wrong.isEmpty && server.downloads.count == manifest.count,
               "all \(manifest.count) files (9 MiB recording, external/ subfolder) arrived verified (bad: \(wrong.map(\.path)))")
        let project = try loadLocal(Fixture(root: fixture.root, dir: dirB, external: fixture.external, project: fixture.project))
        expect(project.videoURL?.path == dirB.appendingPathComponent("recording.mov").path,
               "the web recorder's file:///CaptureCat/Projects/<id>/recording.mov → this Mac's copy")
        expect(externalEntry.map { project.settings.backgroundImagePath == dirB.appendingPathComponent($0.path).path } == true,
               "a wallpaper from outside the first Mac's folder → this Mac's \(externalEntry?.path ?? "external/…")")
        expect(project.watermarkImageURL.map { $0.deletingLastPathComponent().path == dirB.path && fm.fileExists(atPath: $0.path) } == true
               && project.curtainLogoImageURL.map { fm.fileExists(atPath: $0.path) } == true,
               "watermark + curtain logos resolve inside this Mac's folder")
        expect(project.voiceOverClips.filter { fm.fileExists(atPath: $0.resolvedURL(in: dirB).path) }.count == 1,
               "the recorded take resolves (the clip whose file never existed stays missing)")
    }

    /// The REAL `HTTPCloudProjectTransport.download` against a loopback
    /// server: a multi-MiB body streamed to disk, byte progress, no session
    /// token sent to the storage host, 403 → expired, 500 → error, and an
    /// error body never written as the file.
    private static func httpDownloadChecks(_ checks: Checks) async {
        let expect = checks.expect
        print("http download (real transport, loopback server)")
        final class Log: @unchecked Sendable {
            let lock = NSLock()
            var heads: [String] = []
            func record(_ head: String) { lock.withLock { heads.append(head) } }
            var all: [String] { lock.withLock { heads } }
        }
        var rng = SplitMix64(seed: 0xD00D)
        var body = Data(count: 3 * 1024 * 1024 + 77)
        body.withUnsafeMutableBytes { raw in
            for i in 0..<raw.count { raw[i] = UInt8(truncatingIfNeeded: rng.next()) }
        }
        let payload = body
        let log = Log()
        guard let listener = try? NWListener(using: .tcp, on: .any) else {
            expect(false, "loopback listener starts")
            return
        }
        listener.newConnectionHandler = { conn in
            conn.start(queue: .global())
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, _, _ in
                guard let data, let head = String(data: data, encoding: .utf8),
                      let line = head.split(separator: "\r\n").first else { conn.cancel(); return }
                log.record(head)
                let target = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                let status: String, type: String, reply: Data
                if target.hasPrefix("/ok") {
                    (status, type, reply) = ("200 OK", "audio/mp4", payload)
                } else if target.hasPrefix("/expired") {
                    (status, type, reply) = ("403 Forbidden", "application/xml",
                                             Data("<Error><Code>AccessDenied</Code><Message>Request has expired</Message></Error>".utf8))
                } else {
                    (status, type, reply) = ("500 Internal Server Error", "text/plain", Data("boom".utf8))
                }
                let header = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\n"
                    + "Content-Length: \(reply.count)\r\nConnection: close\r\n\r\n"
                conn.send(content: Data(header.utf8) + reply, completion: .contentProcessed { _ in conn.cancel() })
            }
        }
        listener.start(queue: .global())
        defer { listener.cancel() }
        var port: UInt16 = 0
        for _ in 0..<100 {
            if let value = listener.port?.rawValue, value != 0 { port = value; break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard port != 0 else {
            expect(false, "loopback listener has a port")
            return
        }

        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("cloud-http-download-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let transport = HTTPCloudProjectTransport(baseURL: "http://127.0.0.1:9")
        func file(_ route: String) -> CloudRemoteFile {
            CloudRemoteFile(path: "voiceover-x.m4a", sha256: CloudProjectManifest.sha256(of: payload),
                            bytes: Int64(payload.count), contentType: "audio/mp4", source: nil,
                            url: URL(string: "http://127.0.0.1:\(port)\(route)?X-Amz-Signature=0123abcd"))
        }

        let okFile = dir.appendingPathComponent("ok.part")
        var progress: [Int64] = []
        do {
            try await transport.download(file("/ok"), to: okFile) { progress.append($0) }
            try? await Task.sleep(for: .milliseconds(150)) // progress hops to the main actor
            let got = (try? Data(contentsOf: okFile)) ?? Data()
            expect(got == payload, "3 MiB body streamed to disk byte-exact (\(got.count) bytes)")
            expect(progress.max() == Int64(payload.count), "byte progress reaches the file size (\(progress.count) updates)")
        } catch {
            expect(false, "200 → downloaded (threw \(error))")
        }
        let head = log.all.first?.lowercased() ?? ""
        expect(!head.isEmpty && !head.contains("authorization:") && !head.contains("x-app-token:"),
               "the presigned GET carries no session token or app token")

        let expiredFile = dir.appendingPathComponent("expired.part")
        do {
            try await transport.download(file("/expired"), to: expiredFile) { _ in }
            expect(false, "403 → downloadURLExpired (no error)")
        } catch {
            expect((error as? CloudSyncError) == .downloadURLExpired, "403 → downloadURLExpired (got \(error))")
        }
        expect(((try? Data(contentsOf: expiredFile)) ?? Data([1])).isEmpty, "an error body is never written as the file")

        do {
            try await transport.download(file("/broken"), to: dir.appendingPathComponent("broken.part")) { _ in }
            expect(false, "500 → error (no error)")
        } catch {
            if case .api(let status, _, _)? = error as? CloudSyncError {
                expect(status == 500, "500 → api error with the status (\(status))")
            } else {
                expect(false, "500 → api error (got \(error))")
            }
        }
    }

    /// The web's JSON edit of a document: top level and `settings`.
    static func webEditedJSON(
        _ document: Data,
        _ mutate: (inout [String: Any], inout [String: Any]) -> Void
    ) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: document) as? [String: Any] else {
            throw CloudSyncError.invalidResponse
        }
        var settings = object["settings"] as? [String: Any] ?? [:]
        mutate(&object, &settings)
        object["settings"] = settings
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    // MARK: - UI probe

    private final class ProbeLog {
        var anchors: [NSView] = []
        var cancelled = false
    }

    /// Synthesized click through the view's REAL mouseDown/mouseUp path.
    static func click(_ view: NSView) {
        guard let window = view.window else { return }
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        if let down = event(.leftMouseDown), let up = event(.leftMouseUp) {
            view.mouseDown(with: down)
            view.mouseUp(with: up)
        }
    }

    /// The REAL `EditorToolbarController` bar, hosted the way the editor
    /// window hosts it (in-content, pinned top/leading/trailing at 52 pt under
    /// a transparent full-size titlebar — see EditorWindowContentController),
    /// measured at three widths; then the REAL progress dialog presented over
    /// that window. Windows are parked off-screen.
    private static func probeUI(_ checks: Checks, project: Project) async {
        let expect = checks.expect
        print("ui: editor top bar")
        let log = ProbeLog()
        let toolbar = EditorToolbarController(
            project: project,
            onShowBrowser: {},
            onExport: {},
            onToggleInspector: {},
            onWebEditor: { log.anchors.append($0) }
        )
        let root = NSView()
        root.wantsLayer = true
        let content = NSViewController()
        content.view = root
        let bar = toolbar.barView
        bar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 52),
        ])
        let window = NSWindow(contentViewController: content)
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.setContentSize(NSSize(width: 1400, height: 420))
        window.setFrameOrigin(NSPoint(x: -20_000, y: 200))
        window.orderFrontRegardless()
        toolbar.install(on: window)
        defer { window.close() }

        let buttons = bar.subviews.compactMap { $0 as? CCButton }
        guard let web = buttons.first(where: { $0.title == "Web Editor" }),
              let export = buttons.first(where: { $0.title == "Export…" }) else {
            expect(false, "top bar carries a Web Editor button beside Export")
            return
        }
        expect(true, "top bar carries a Web Editor button beside Export")
        let cluster = bar.subviews.first { $0 is NSStackView }

        for width in [1400.0, 1100.0, 900.0] {
            window.setContentSize(NSSize(width: width, height: 420))
            root.layoutSubtreeIfNeeded()
            let tag = "@\(Int(width))"
            let w = web.frame
            let e = export.frame
            expect(w.width > 40 && w.height > 10, "\(tag): Web Editor button rendered (\(Int(w.width))×\(Int(w.height)))")
            expect(abs((e.minX - w.maxX) - CCSpace.sm) < 0.5, "\(tag): sits \(Int(CCSpace.sm))pt left of Export")
            expect(bar.bounds.contains(w), "\(tag): inside the bar")
            expect(abs(w.midY - e.midY) < 1, "\(tag): on Export's centre line")
            if let cluster {
                expect(cluster.frame.maxX <= w.minX + 0.5, "\(tag): never overlaps the aspect cluster")
            }
            expect(!web.hasAmbiguousLayout && !export.hasAmbiguousLayout, "\(tag): unambiguous layout")
            if let superview = root.superview {
                let hit = root.hitTest(bar.convert(NSPoint(x: w.midX, y: w.midY), to: superview))
                expect(hit.map { $0 === web || $0.isDescendant(of: web) } == true, "\(tag): nothing covers it (hit test)")
            }
        }
        writeDrawnShot(of: bar, name: "cloud-topbar-900.png")
        click(web)
        expect(log.anchors.count == 1 && log.anchors.first === web,
               "a click hands the button itself to the Web Editor menu as its anchor")

        print("ui: progress dialog")
        let dialog = CloudSyncProgressDialog(title: "Opening in Web Editor", subtitle: project.name)
        dialog.onCancel = { log.cancelled = true }
        window.setContentSize(NSSize(width: 1100, height: 600))
        dialog.present(over: window)
        try? await Task.sleep(for: .milliseconds(500))
        let card = dialog.probeCard
        card.layoutSubtreeIfNeeded()
        let barFrame = dialog.probeBar.convert(dialog.probeBar.bounds, to: card)
        expect(card.window?.isVisible == true, "progress card is on screen over the editor window")
        expect(barFrame.width > 200 && card.bounds.contains(barFrame),
               "progress bar laid out inside the card (\(Int(barFrame.width))pt wide)")
        let weights: [CloudProjectSync.Progress.Phase: ClosedRange<Double>] = [.hashing: 0...0.12, .uploading: 0.12...0.86]
        dialog.update(CloudProjectSync.Progress(phase: .uploading, fraction: 0.5, message: "Uploading 3 files…"), weights: weights)
        expect(abs(dialog.probeBar.doubleValue - 0.49) < 1e-9, "upload at 50% → overall 49% (\(dialog.probeBar.doubleValue))")
        expect(dialog.probeStatus == "Uploading 3 files…", "status line follows the phase")
        dialog.update(CloudProjectSync.Progress(phase: .hashing, fraction: 1, message: "Preparing files…"), weights: weights)
        expect(dialog.probeBar.doubleValue >= 0.49, "the bar never runs backwards when a phase re-enters")
        // Pull Web Edits drives the same card through its download phase.
        dialog.update(CloudProjectSync.Progress(phase: .downloading, fraction: 0.5, message: "Downloading 3 files…"),
                      weights: CloudSyncController.pullWeights)
        expect(abs(dialog.probeBar.doubleValue - 0.56) < 1e-9 && dialog.probeStatus == "Downloading 3 files…",
               "pull: downloading at 50% → overall 56%, status follows (\(dialog.probeBar.doubleValue))")
        try? await Task.sleep(for: .milliseconds(400)) // let the fill glide land before the shot
        writeShot(of: card, name: "cloud-progress.png")
        click(dialog.probeCancelButton)
        expect(log.cancelled && dialog.probeStatus == "Cancelling…" && !dialog.probeCancelButton.isEnabled,
               "Cancel (real click) stops the sync and says so")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            dialog.dismiss { continuation.resume() }
        }
        expect(card.window?.isVisible != true, "dismiss takes the card down")
    }

    /// `--shot`: PNGs of what the UI checks measured, for eyeballing. Written
    /// to the (sandboxed) temp dir — ~/Library/Containers/so.capturecat.CaptureCat/
    /// Data/tmp/capturecat-cloud-sync/ — like the other probe shots.
    private static func writeShot(of view: NSView, name: String) {
        guard CommandLine.arguments.contains("--shot"),
              let layer = view.layer,
              let raw = CARendererSnapshot.render(layer: layer, size: view.bounds.size, scale: 2) else { return }
        // CARenderer hands back a bottom-up buffer; flip so the PNG reads upright.
        guard let ctx = CGContext(
            data: nil, width: raw.width, height: raw.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return }
        ctx.translateBy(x: 0, y: CGFloat(raw.height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(raw, in: CGRect(x: 0, y: 0, width: raw.width, height: raw.height))
        guard let image = ctx.makeImage() else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("capturecat-cloud-sync", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
        print("  · shot \(url.path)")
    }

    /// Draw-based capture (`cacheDisplay`) for chrome CARenderer sees as an
    /// empty tree off-screen — the same split `--editor-shell-shot` uses.
    private static func writeDrawnShot(of view: NSView, name: String) {
        guard CommandLine.arguments.contains("--shot"),
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("capturecat-cloud-sync", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("  · shot \(url.path)")
    }

    // MARK: - Helpers

    static func modificationDate(_ url: URL) throws -> Date {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
    }

    /// What a web save looks like: the same document, JSON-edited, compact
    /// formatting (not the Mac's pretty print), plus a key the Mac lacks.
    private static func webEdited(_ document: Data, name: String, extraKey: String) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: document) as? [String: Any] else {
            throw CloudSyncError.invalidResponse
        }
        object["name"] = name
        object[extraKey] = ["from": "web", "n": 1.5]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// The same document as uploaded from a different Mac: media URLs point
    /// into another user's Application Support.
    private static func webEditedURLs(_ document: Data, projectID: UUID) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: document) as? [String: Any] else {
            throw CloudSyncError.invalidResponse
        }
        let foreign = "file:///Users/someone-else/Library/Application%20Support/CaptureCat/Projects/\(projectID.uuidString)/"
        object["videoURL"] = foreign + "recording.mov"
        object["cursorDataURL"] = foreign + "cursor.json"
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func replacingID(_ document: Data, with id: UUID) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: document) as? [String: Any] else {
            throw CloudSyncError.invalidResponse
        }
        object["id"] = id.uuidString
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private struct SplitMix64 {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }
}

// MARK: - Stub server

/// In-memory stand-in for /api/cloud-projects with the API's semantics (see
/// apps/api/src/routes/cloud-projects.ts): objects content-addressed per
/// project, pending until finalize verifies size AND SHA-256, a committed
/// file set (path, sha, size, type, source — what GET …/:id lists with a
/// presigned GET each), unreferenced objects collected at finalize, the
/// document stored byte-exact with If-Match revisions (409 on a stale base).
/// `webAddFiles` is the web editor adding media: it restages the COMPLETE
/// committed manifest plus the new files, exactly like apps/web's
/// `addCloudProjectFile`.
final class StubCloudServer: CloudProjectTransport {
    struct Upload {
        let sha256: String
        let paths: [String]
        let contentTypeMatched: Bool
        let lengthMatched: Bool
    }

    let ownerUID: String
    private(set) var ready: [String: Data] = [:]
    private var landed: [String: Data] = [:]
    private var staged: [CloudManifestFile] = []
    private var stagedTypes: [String: String] = [:]
    /// The committed manifest, in staging order.
    private(set) var committedFiles: [CloudRemoteFile] = []
    private(set) var revision = 0
    private(set) var document: Data?
    private(set) var uploads: [Upload] = []
    private(set) var downloads: [String] = []
    private(set) var stageCalls = 0
    private(set) var saveCalls = 0
    private(set) var fileListCalls = 0
    private(set) var lastSaveBase: Int?
    private(set) var garbageCollected = 0
    var expireNextUpload = false
    /// Next GET answers 403 "Request has expired" (presign lapsed mid-queue).
    var expireNextDownload = false
    /// Paths whose GET fails (HTTP 500).
    var failDownloads: Set<String> = []
    /// Paths whose GET delivers the right LENGTH of the wrong bytes.
    var corruptDownloads: Set<String> = []
    /// Called as each GET starts — lets the harness look at the project
    /// folder at that moment.
    var onDownload: ((CloudRemoteFile) -> Void)?
    /// Presign generation: `files()` re-signs, and a URL from an older
    /// generation is refused like an expired presign.
    private var generation = 0

    var committed: [String: String] {
        Dictionary(committedFiles.map { ($0.path, $0.sha256) }, uniquingKeysWith: { first, _ in first })
    }
    var committedPaths: Set<String> { Set(committed.keys) }

    init(ownerUID: String) {
        self.ownerUID = ownerUID
    }

    func resetCounters() {
        uploads = []
        downloads = []
        stageCalls = 0
        saveCalls = 0
        fileListCalls = 0
        lastSaveBase = nil
        garbageCollected = 0
        revisionDocumentCalls = 0
        restoreCalls = 0
        lastSaveContext = nil
    }

    /// The web editor adding media (a voice-over take, a background or logo
    /// image): list → stage(everything committed + the new files) → PUT →
    /// finalize. A same-path file is replaced. The document is saved
    /// separately (`webSave`), once the upload settled — as the web does.
    func webAddFiles(_ added: [(path: String, data: Data, contentType: String, source: String?)]) {
        var files = committedFiles
        for file in added {
            precondition(CloudPath.isValid(file.path) && CloudPath.accepts(file.contentType, for: file.path),
                         "the API would refuse \(file.path) as \(file.contentType)")
            let sha = CloudProjectManifest.sha256(of: file.data)
            ready[sha] = file.data
            files.removeAll { $0.path.lowercased() == file.path.lowercased() }
            files.append(CloudRemoteFile(path: file.path, sha256: sha, bytes: Int64(file.data.count),
                                         contentType: file.contentType, source: file.source, url: nil))
        }
        committedFiles = files
        collect()
    }

    /// The object behind a committed path vanishes (a concurrent restage
    /// collected it) while the committed manifest still lists the path.
    func loseObject(path: String) {
        guard let sha = committed[path] else { return }
        ready[sha] = nil
    }

    private var documentSHA: String? { document.map { CloudProjectManifest.sha256(of: $0) } }

    private func presigned(_ file: CloudRemoteFile) -> CloudRemoteFile {
        CloudRemoteFile(path: file.path, sha256: file.sha256, bytes: file.bytes, contentType: file.contentType,
                        source: file.source,
                        url: URL(string: "https://r2.stub.test/get/\(file.sha256)?g=\(generation)"))
    }

    /// Finalize's garbage collection: objects no committed path points at
    /// (and, with `pinsVersionMedia`, no retained version's manifest).
    private func collect() {
        let live = Set(committedFiles.map(\.sha256)).union(pinnedSHAs)
        for sha in ready.keys where !live.contains(sha) {
            ready[sha] = nil
            garbageCollected += 1
        }
    }

    func stage(projectID: UUID, name: String, files: [CloudManifestFile]) async throws -> CloudStageResult {
        stageCalls += 1
        // The server's rules: checkLogicalPath, per-extension content types
        // (any accepted alias), unique paths case-insensitively, the
        // manifest length cap, one size per SHA-256.
        guard files.count <= CloudPath.maxManifestFiles else {
            throw CloudSyncError.api(status: 400, code: "too_many_files", message: "manifest too long")
        }
        var seenPaths = Set<String>()
        var sizes: [String: Int64] = [:]
        for file in files {
            guard CloudPath.isValid(file.path), CloudPath.accepts(file.contentType, for: file.path) else {
                throw CloudSyncError.api(status: 400, code: "invalid_path", message: "\(file.path) refused")
            }
            guard seenPaths.insert(file.path.lowercased()).inserted else {
                throw CloudSyncError.api(status: 400, code: "duplicate_path", message: "\(file.path) listed twice")
            }
            if let known = sizes[file.sha256], known != file.bytes {
                throw CloudSyncError.api(status: 400, code: "inconsistent_manifest", message: "\(file.path) two sizes")
            }
            sizes[file.sha256] = file.bytes
        }
        staged = files
        var missing: [CloudUploadTarget] = []
        var seen = Set<String>()
        for file in files where ready[file.sha256] == nil && seen.insert(file.sha256).inserted {
            stagedTypes[file.sha256] = file.contentType
            let key = "cloud-projects/\(ownerUID)/\(projectID.uuidString)/objects/\(file.sha256)"
            missing.append(CloudUploadTarget(
                sha256: file.sha256,
                bytes: file.bytes,
                contentType: file.contentType,
                paths: files.filter { $0.sha256 == file.sha256 }.map(\.path),
                uploadURL: URL(string: "https://r2.stub.test/\(key)?ct=\(file.contentType)&len=\(file.bytes)")!
            ))
        }
        return CloudStageResult(revision: revision, documentSHA256: documentSHA, missing: missing)
    }

    func upload(fileAt url: URL, to target: CloudUploadTarget, progress: @escaping (Int64) -> Void) async throws {
        if expireNextUpload {
            expireNextUpload = false
            throw CloudSyncError.uploadURLExpired
        }
        let data = try Data(contentsOf: url)
        // Simulated byte progress, like URLSession's didSendBodyData.
        for step in 1...4 { progress(Int64(data.count) * Int64(step) / 4) }
        let query = target.uploadURL.query ?? ""
        uploads.append(Upload(
            sha256: target.sha256,
            paths: target.paths,
            contentTypeMatched: query.contains("ct=\(target.contentType)") && stagedTypes[target.sha256] == target.contentType,
            lengthMatched: Int64(data.count) == target.bytes && query.contains("len=\(target.bytes)")
        ))
        landed[target.sha256] = data
    }

    func finalize(projectID: UUID) async throws -> CloudFinalizeResult {
        for file in staged where ready[file.sha256] == nil {
            guard let bytes = landed[file.sha256] else { return .objectsMissing }
            // The server's verification: size AND SHA-256 of what landed.
            guard Int64(bytes.count) == file.bytes, CloudProjectManifest.sha256(of: bytes) == file.sha256 else {
                landed[file.sha256] = nil
                throw CloudSyncError.api(status: 422, code: "hash_mismatch", message: "\(file.path) mismatch")
            }
            ready[file.sha256] = bytes
        }
        committedFiles = staged.map {
            CloudRemoteFile(path: $0.path, sha256: $0.sha256, bytes: $0.bytes,
                            contentType: $0.contentType, source: $0.source, url: nil)
        }
        collect()
        return .committed
    }

    func fetch(projectID: UUID) async throws -> CloudRemoteProject? {
        guard revision > 0 || !committedFiles.isEmpty else { return nil }
        return CloudRemoteProject(revision: revision, documentSHA256: documentSHA, document: document,
                                  files: committedFiles.map(presigned), updatedAt: updatedAt)
    }

    func files(projectID: UUID) async throws -> [CloudRemoteFile] {
        fileListCalls += 1
        generation += 1
        return committedFiles.map(presigned)
    }

    func download(_ file: CloudRemoteFile, to destination: URL, progress: @escaping (Int64) -> Void) async throws {
        onDownload?(file)
        if expireNextDownload {
            expireNextDownload = false
            generation += 1 // every URL handed out so far is now stale
        }
        guard file.url?.query == "g=\(generation)" else { throw CloudSyncError.downloadURLExpired }
        if failDownloads.contains(file.path) {
            throw CloudSyncError.api(status: 500, code: nil, message: "HTTP 500")
        }
        guard var data = ready[file.sha256] else {
            throw CloudSyncError.api(status: 404, code: nil, message: "HTTP 404")
        }
        if corruptDownloads.contains(file.path), !data.isEmpty {
            data[0] ^= 0xFF
        }
        downloads.append(file.path)
        try data.write(to: destination)
        for step in 1...4 { progress(Int64(data.count) * Int64(step) / 4) }
    }

    func save(projectID: UUID, document data: Data, baseRevision: Int, context: CloudSaveContext) async throws -> CloudSaveResult {
        saveCalls += 1
        lastSaveBase = baseRevision
        lastSaveContext = context
        guard baseRevision == revision else {
            return .conflict(CloudConflict(revision: revision, document: document,
                                           documentSHA256: documentSHA, updatedAt: updatedAt))
        }
        let previous = document
        revision += 1
        document = data
        updatedAt = stamp()
        let version = recordVersion(
            previous: previous, actorUID: ownerUID, clientKind: context.client, clientID: context.clientID,
            source: context.source.rawValue, change: context.change.flatMap(ProjectDiff.decodeHeader),
            checkpoint: context.checkpoint, mergedFrom: context.mergedFrom, restoredFrom: nil)
        return .saved(revision: revision, documentSHA256: CloudProjectManifest.sha256(of: data),
                      version: CloudSavedVersion(id: version.id, seq: version.seq, extended: version.extended))
    }

    // MARK: Project history (docs/project-history.md §2, §4, §6)

    /// One retained version, as `cloud_project_versions` stores it.
    struct StubVersion {
        let id: String
        let seq: Int
        let firstRevision: Int
        var revision: Int
        var document: Data
        var files: [CloudRemoteFile]
        let kind: String
        var label: String?
        let actorUID: String
        let clientKind: String
        let clientID: String?
        let source: String
        var change: ChangeSet?
        let openedAt: Date
        var updatedAt: Date
        let mergedFrom: Int?
        let restoredFrom: String?
        var extended = false
    }

    /// Oldest first.
    private(set) var versions: [StubVersion] = []
    private var nextSeq = 1
    /// When the current revision was saved (`updated_at`).
    private(set) var updatedAt: Date?
    private(set) var lastSaveContext: CloudSaveContext?
    private(set) var revisionDocumentCalls = 0
    private(set) var restoreCalls = 0
    private(set) var deletedVersions: [String] = []
    /// The server's clock for the next save (nil = wall clock) — pins the
    /// merge's last-writer rule in tests.
    var clock: Date?
    /// GET …/revisions/:rev/document answers only while a version holds
    /// that revision AND this is on (off = an expired or pre-history server).
    var retainsRevisions = true
    /// Version manifests pin their objects against collection (the API with
    /// history). Off by default: the pre-history checks expect a superseded
    /// object to be collected at once.
    var pinsVersionMedia = false
    /// Display names the versions list joins in.
    var displayNames: [String: String] = ["stub-owner": "Mike", "web-ana": "Ana"]
    /// Wait before answering a versions request (the pane's skeleton).
    var versionsDelay: Duration?

    private func stamp() -> Date {
        let now = clock ?? Date()
        clock = clock.map { $0.addingTimeInterval(1) }
        return now
    }

    /// The API's coalescing (§2): a save EXTENDS the head when it is the
    /// same actor + client id + source, the head is an unnamed `edit`, and
    /// no checkpoint was asked for. (The stub has no 10/3-minute windows.)
    @discardableResult
    private func recordVersion(
        previous: Data?, actorUID: String, clientKind: String, clientID: String?, source: String,
        change: ChangeSet?, checkpoint: CloudSaveContext.Checkpoint?, mergedFrom: Int?, restoredFrom: String?
    ) -> StubVersion {
        let now = updatedAt ?? Date()
        let derivedChange = change ?? previous.flatMap { prev -> ChangeSet? in
            guard let a = try? JSONValue.parse(data: prev), let b = try? JSONValue.parse(data: document ?? Data()) else { return nil }
            return ProjectDiff.diff(a, b)
        }
        if checkpoint == nil, var head = versions.last, head.kind == "edit", head.label == nil,
           head.actorUID == actorUID, head.clientID == clientID, head.source == source {
            head.revision = revision
            head.document = document ?? Data()
            head.files = committedFiles
            head.updatedAt = now
            head.change = head.change.map { prior in derivedChange.map { ProjectDiff.compose(prior, $0) } ?? prior } ?? derivedChange
            head.extended = true
            versions[versions.count - 1] = head
            return head
        }
        let kind: String
        switch checkpoint {
        case .merge: kind = "merge"
        case .restore: kind = "restore"
        case .upload: kind = "upload"
        default: kind = previous == nil ? "upload" : "edit"
        }
        let version = StubVersion(
            id: "ver-\(nextSeq)", seq: nextSeq, firstRevision: revision, revision: revision,
            document: document ?? Data(), files: committedFiles, kind: kind, label: nil,
            actorUID: actorUID, clientKind: clientKind, clientID: clientID, source: source,
            change: derivedChange, openedAt: now, updatedAt: now, mergedFrom: mergedFrom, restoredFrom: restoredFrom)
        nextSeq += 1
        versions.append(version)
        return version
    }

    /// A web save by `actor` (Ana on the web editor by default): a new
    /// revision and a version of kind `edit`, attributed to that actor.
    func webSave(_ data: Data, actor: String = "web-ana", client: String = "web", source: String = "human") {
        let previous = document
        revision += 1
        document = data
        updatedAt = stamp()
        recordVersion(previous: previous, actorUID: actor, clientKind: client, clientID: "browser-\(actor)",
                      source: source, change: nil, checkpoint: .push, mergedFrom: nil, restoredFrom: nil)
    }

    private var pinnedSHAs: Set<String> {
        pinsVersionMedia ? Set(versions.flatMap { $0.files.map(\.sha256) }) : []
    }

    func revisionDocument(projectID: UUID, revision rev: Int) async throws -> Data? {
        revisionDocumentCalls += 1
        guard retainsRevisions else { return nil }
        return versions.last { $0.revision == rev }?.document
    }

    func stubVersion(_ id: String) -> StubVersion? { versions.first { $0.id == id } }

    /// "Name this version" from another client (or the test itself).
    func name(_ id: String, _ label: String?) {
        guard let index = versions.firstIndex(where: { $0.id == id }) else { return }
        versions[index].label = label
    }

    private func cloudVersion(_ v: StubVersion) -> CloudVersion {
        CloudVersion(
            id: v.id, seq: v.seq, revision: v.revision, firstRevision: v.firstRevision, kind: v.kind,
            label: v.label, namedBy: v.label == nil ? nil : ownerUID, namedAt: nil, actorUID: v.actorUID,
            actorName: displayNames[v.actorUID], clientKind: v.clientKind, clientID: v.clientID, source: v.source,
            change: v.change, docBytes: Int64(v.document.count),
            manifestSHA: CloudProjectManifest.sha256(of: Data(v.files.map { "\($0.path)=\($0.sha256)" }.sorted().joined(separator: "\n").utf8)),
            restoredFrom: v.restoredFrom, mergedFromRevision: v.mergedFrom, openedAt: v.openedAt, updatedAt: v.updatedAt)
    }
}

extension StubCloudServer: CloudHistoryTransport {
    func head(projectID: UUID) async throws -> CloudHead? {
        guard revision > 0 else { return nil }
        return CloudHead(revision: revision, documentSHA256: document.map { CloudProjectManifest.sha256(of: $0) },
                         updatedAt: updatedAt, updatedBy: versions.last?.actorUID, headVersionID: versions.last?.id)
    }

    func versions(projectID: UUID, before: Int?, limit: Int) async throws -> CloudVersionPage? {
        if let versionsDelay { try await Task.sleep(for: versionsDelay) }
        guard revision > 0 else { return nil }
        let newestFirst = versions.reversed().filter { before == nil || $0.seq < before! }
        let slice = Array(newestFirst.prefix(limit))
        // "History keeps X of removed media": bytes only old versions pin.
        let current = Set(committedFiles.map(\.sha256))
        var pinned: [String: Int64] = [:]
        for version in versions {
            for file in version.files where !current.contains(file.sha256) { pinned[file.sha256] = file.bytes }
        }
        return CloudVersionPage(
            versions: slice.map(cloudVersion),
            nextBefore: newestFirst.count > slice.count ? slice.last?.seq : nil,
            retention: CloudRetention(historyDays: 30, maxNamed: 25, namedCount: versions.filter { $0.label != nil }.count),
            pinnedMediaBytes: pinned.values.reduce(0, +),
            headVersionID: versions.last?.id,
            isOwner: true)
    }

    func version(projectID: UUID, versionID: String) async throws -> CloudVersionDetail {
        guard let version = stubVersion(versionID) else {
            throw CloudSyncError.api(status: 404, code: "version_not_found", message: "No such version")
        }
        return CloudVersionDetail(version: cloudVersion(version), document: version.document,
                                  files: version.files.map { presigned($0) })
    }

    func renameVersion(projectID: UUID, versionID: String, label: String?) async throws -> CloudVersion? {
        guard let index = versions.firstIndex(where: { $0.id == versionID }) else {
            throw CloudSyncError.api(status: 404, code: "version_not_found", message: "No such version")
        }
        versions[index].label = (label?.isEmpty ?? true) ? nil : label
        return cloudVersion(versions[index])
    }

    /// Server-side restore (§4): the version's paths are re-committed,
    /// unioned with the current files (old-version paths win), then its
    /// document is saved as a NEW revision + version of kind `restore`.
    func restoreVersion(projectID: UUID, versionID: String, baseRevision: Int,
                        context: CloudSaveContext) async throws -> CloudRestoreResult {
        restoreCalls += 1
        guard let old = stubVersion(versionID) else {
            throw CloudSyncError.api(status: 404, code: "version_not_found", message: "No such version")
        }
        guard baseRevision == revision else {
            return .conflict(CloudConflict(revision: revision, document: document,
                                           documentSHA256: documentSHA, updatedAt: updatedAt))
        }
        var files = old.files
        let oldPaths = Set(files.map { $0.path.lowercased() })
        files += committedFiles.filter { !oldPaths.contains($0.path.lowercased()) }
        committedFiles = files
        let previous = document
        revision += 1
        document = old.document
        updatedAt = stamp()
        let version = recordVersion(
            previous: previous, actorUID: ownerUID, clientKind: context.client, clientID: context.clientID,
            source: context.source.rawValue, change: nil, checkpoint: .restore, mergedFrom: nil, restoredFrom: old.id)
        return .restored(revision: revision, documentSHA256: CloudProjectManifest.sha256(of: old.document),
                         version: CloudSavedVersion(id: version.id, seq: version.seq, extended: false))
    }

    func deleteVersion(projectID: UUID, versionID: String) async throws {
        guard versions.last?.id != versionID else {
            throw CloudSyncError.api(status: 409, code: "version_is_head", message: "The current version can't be deleted")
        }
        guard let index = versions.firstIndex(where: { $0.id == versionID }) else {
            throw CloudSyncError.api(status: 404, code: "version_not_found", message: "No such version")
        }
        versions.remove(at: index)
        deletedVersions.append(versionID)
        collect()
    }
}
