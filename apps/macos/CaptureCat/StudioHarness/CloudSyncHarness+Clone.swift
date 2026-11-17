import Foundation

// MARK: - Clone ("Continue on Mac")

extension CloudSyncHarness {
    /// A project recorded in the web app exists only in the cloud: its
    /// document names media the web's way (`file:///CaptureCat/Projects/<id>/…`)
    /// and has no cursor or keystroke data. `clone` must bring every file to
    /// a NEW project folder, re-point those references, write project.json
    /// last, and leave nothing behind on any failure.
    static func cloneChecks(_ checks: Checks, apiBase: String) async throws {
        let expect = checks.expect
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("capturecat-clone-test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        func folder(_ id: UUID) -> URL { root.appendingPathComponent("Projects/\(id.uuidString)", isDirectory: true) }
        /// What the web recorder uploads (apps/web/src/editor/record/publish.ts).
        func webRecordedProject(_ id: UUID, server: StubCloudServer, uploadRecording: Bool = true) throws -> (movie: Data, camera: Data) {
            let movie = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
            let camera = Data("web camera".utf8)
            var files: [(path: String, data: Data, contentType: String, source: String?)] = [
                ("camera.mov", camera, "video/quicktime", nil),
                ("camera_poster.png", Data("poster".utf8), "image/png", nil),
            ]
            if uploadRecording { files.insert(("recording.mov", movie, "video/quicktime", nil), at: 0) }
            server.webAddFiles(files)
            let project = Project(
                id: id,
                name: "Recorded in the browser",
                videoURL: URL(string: "file:///CaptureCat/Projects/\(id.uuidString)/recording.mov")!,
                cursorDataURL: nil,
                cameraVideoURL: URL(string: "file:///CaptureCat/Projects/\(id.uuidString)/camera.mov")!,
                duration: 14.25
            )
            server.webSave(try JSONEncoder().encode(project))
            return (movie, camera)
        }
        func cloneFailure(_ sync: CloudProjectSync, _ id: UUID, _ label: String) async -> CloudSyncError? {
            do {
                let outcome = try await sync.clone(projectID: id, into: folder(id))
                expect(false, "\(label) (clone returned \(outcome))")
            } catch let error as CloudSyncError {
                return error
            } catch {
                expect(false, "\(label) (threw \(error))")
            }
            return nil
        }

        print("clone: a web-recorded project comes to a Mac that never had it")
        let id = UUID()
        let server = StubCloudServer(ownerUID: "stub-owner")
        let sync = CloudProjectSync(transport: server, apiBaseURL: apiBase)
        let media = try webRecordedProject(id, server: server)
        let dir = folder(id)
        var phases: [CloudProjectSync.Progress.Phase] = []
        let outcome = try await sync.clone(projectID: id, into: dir) { phases.append($0.phase) }
        expect(outcome == .cloned(revision: 1), "clone → .cloned(revision: 1) (got \(outcome))")
        let cloned = try JSONDecoder().decode(Project.self, from: Data(contentsOf: dir.appendingPathComponent("project.json")))
        expect(cloned.id == id && cloned.name == "Recorded in the browser", "project.json is the web's document")
        expect(cloned.videoURL == dir.appendingPathComponent("recording.mov"),
               "the web's file:///CaptureCat/Projects/… recording is re-pointed at this Mac's copy")
        expect(cloned.cameraVideoURL == dir.appendingPathComponent("camera.mov"), "camera re-pointed too")
        expect(cloned.cursorDataURL == nil, "no cursor data is invented (the browser can't capture it)")
        expect((try? Data(contentsOf: dir.appendingPathComponent("recording.mov"))) == media.movie,
               "recording.mov downloaded byte-for-byte")
        expect((try? Data(contentsOf: dir.appendingPathComponent("camera.mov"))) == media.camera, "camera.mov downloaded")
        expect(fm.fileExists(atPath: dir.appendingPathComponent("camera_poster.png").path), "camera_poster.png downloaded")
        expect(CloudSyncState.load(from: dir, projectID: id, apiBaseURL: apiBase)?.revision == 1,
               "the sync sidecar agrees with revision 1")
        expect(((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).allSatisfy {
            !$0.hasPrefix(".cloudsync-") || $0 == CloudSyncState.fileName || $0 == CloudSyncState.baseFileName
        }, "no partial downloads left behind")
        expect(phases.first == .fetching && phases.last == .writing, "progress runs fetching → … → writing")
        let followUp = try await sync.pull(projectID: id, projectDirectory: dir)
        expect(followUp == .upToDate(revision: 1), "the next pull continues from the clone (got \(followUp))")

        print("clone: refusals leave nothing behind")
        let again = await cloneFailure(sync, id, "a second clone of the same project is refused")
        expect(again == .alreadyOnThisMac, "a project already on this Mac → .alreadyOnThisMac")
        expect((try? Data(contentsOf: dir.appendingPathComponent("recording.mov"))) == media.movie,
               "…and its files are untouched")

        let unknown = UUID()
        let none = try await CloudProjectSync(transport: StubCloudServer(ownerUID: "stub-owner"), apiBaseURL: apiBase)
            .clone(projectID: unknown, into: folder(unknown))
        expect(none == .noCloudCopy, "no cloud copy → .noCloudCopy")
        expect(!fm.fileExists(atPath: folder(unknown).path), "…and no folder is created")

        let other = UUID()
        let mismatch = await cloneFailure(sync, other, "a cloud document for another project is refused")
        expect(mismatch == .projectMismatch, "document id ≠ requested id → .projectMismatch")
        expect(!fm.fileExists(atPath: folder(other).path), "…before any folder exists")

        let broken = UUID()
        let failing = StubCloudServer(ownerUID: "stub-owner")
        _ = try webRecordedProject(broken, server: failing)
        failing.failDownloads = ["recording.mov"]
        let failed = await cloneFailure(CloudProjectSync(transport: failing, apiBaseURL: apiBase), broken,
                                        "a failed recording download fails the clone")
        if case .downloadFailed(let paths, _) = failed {
            expect(paths == ["recording.mov"], "downloadFailed names recording.mov")
        } else {
            expect(false, "a failed download throws .downloadFailed (got \(String(describing: failed)))")
        }
        expect(!fm.fileExists(atPath: folder(broken).path), "…and the half-downloaded folder is removed")

        let empty = UUID()
        let noRecording = StubCloudServer(ownerUID: "stub-owner")
        _ = try webRecordedProject(empty, server: noRecording, uploadRecording: false)
        let missing = await cloneFailure(CloudProjectSync(transport: noRecording, apiBaseURL: apiBase), empty,
                                         "a cloud copy without its recording is refused")
        if case .downloadFailed(let paths, _) = missing {
            expect(paths == ["recording.mov"], "missing recording → downloadFailed(recording.mov)")
        } else {
            expect(false, "missing recording throws .downloadFailed (got \(String(describing: missing)))")
        }
        expect(!fm.fileExists(atPath: folder(empty).appendingPathComponent("project.json").path)
               && !fm.fileExists(atPath: folder(empty).path),
               "…and no project.json (or folder) is left to show a broken project")
    }
}
