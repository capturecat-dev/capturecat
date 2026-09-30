import AppKit
import CryptoKit
import Foundation
import ImageIO

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

    private final class Checks {
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

    private struct Fixture {
        let root: URL
        let dir: URL
        let external: URL
        let project: Project
        var json: URL { dir.appendingPathComponent("project.json") }
    }

    private static func makeFixture() throws -> Fixture {
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

    private static func writeProject(_ project: Project, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        try encoder.encode(project).write(to: url, options: .atomic)
    }

    /// Edit project.json on disk the way the app would (decode → mutate →
    /// encode), returning the reloaded project.
    @discardableResult
    private static func editLocal(_ fixture: Fixture, _ mutate: (Project) -> Void) throws -> Project {
        let project = try JSONDecoder().decode(Project.self, from: Data(contentsOf: fixture.json))
        mutate(project)
        try writeProject(project, to: fixture.json)
        return project
    }

    private static func loadLocal(_ fixture: Fixture) throws -> Project {
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
            let decodes = heicFile.flatMap { CGImageSourceCreateWithURL($0.localURL as CFURL, nil) }
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
            let conflict = try await sync.push(project: macEdit, projectDirectory: fixture.dir)
            expect(conflict == .conflict(remoteRevision: 4), "both changed → conflict at revision 4 (got \(conflict))")
            expect(String(decoding: server.document!, as: UTF8.self).contains("Web again"), "conflict saved nothing over the web's revision")
            let refused = try await sync.pull(projectID: id, projectDirectory: fixture.dir)
            expect(refused == .localChangesWouldBeLost(remoteRevision: 4), "pull refuses to discard unsynced Mac edits (got \(refused))")
            expect(try Data(contentsOf: fixture.json) == macBytes, "local project.json untouched by the refused pull")

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

            // ── 14. UI: the real top bar + progress dialog, real windows ────
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

    // MARK: - UI probe

    private final class ProbeLog {
        var anchors: [NSView] = []
        var cancelled = false
    }

    /// Synthesized click through the view's REAL mouseDown/mouseUp path.
    private static func click(_ view: NSView) {
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

    private static func modificationDate(_ url: URL) throws -> Date {
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
/// file set, unreferenced objects collected, the document stored byte-exact
/// with If-Match revisions (409 on a stale base).
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
    private(set) var committed: [String: String] = [:] // path → sha
    private(set) var revision = 0
    private(set) var document: Data?
    private(set) var uploads: [Upload] = []
    private(set) var stageCalls = 0
    private(set) var saveCalls = 0
    private(set) var lastSaveBase: Int?
    private(set) var garbageCollected = 0
    var expireNextUpload = false

    var committedPaths: Set<String> { Set(committed.keys) }

    init(ownerUID: String) {
        self.ownerUID = ownerUID
    }

    func resetCounters() {
        uploads = []
        stageCalls = 0
        saveCalls = 0
        lastSaveBase = nil
        garbageCollected = 0
    }

    /// A save made by the web editor (always based on the current revision).
    func webSave(_ data: Data) {
        revision += 1
        document = data
    }

    private var documentSHA: String? { document.map { CloudProjectManifest.sha256(of: $0) } }

    func stage(projectID: UUID, name: String, files: [CloudManifestFile]) async throws -> CloudStageResult {
        stageCalls += 1
        for file in files where !CloudPath.isValid(file.path) || CloudPath.contentType(for: file.path) != file.contentType {
            throw CloudSyncError.api(status: 400, code: "invalid_path", message: "\(file.path) refused")
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
        committed = Dictionary(staged.map { ($0.path, $0.sha256) }, uniquingKeysWith: { first, _ in first })
        let live = Set(committed.values)
        for sha in ready.keys where !live.contains(sha) {
            ready[sha] = nil
            garbageCollected += 1
        }
        return .committed
    }

    func fetch(projectID: UUID) async throws -> CloudRemoteProject? {
        guard revision > 0 || !committed.isEmpty else { return nil }
        return CloudRemoteProject(revision: revision, documentSHA256: documentSHA, document: document)
    }

    func save(projectID: UUID, document data: Data, baseRevision: Int) async throws -> CloudSaveResult {
        saveCalls += 1
        lastSaveBase = baseRevision
        guard baseRevision == revision else { return .conflict(revision: revision, document: document) }
        revision += 1
        document = data
        return .saved(revision: revision, documentSHA256: CloudProjectManifest.sha256(of: data))
    }
}
