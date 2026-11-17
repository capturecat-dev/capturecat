import Foundation

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
            return .conflict(CloudConflict(revision: revision, document: document, documentSHA256: documentSHA,
                                           updatedAt: updatedAt, headVersionID: versions.last?.id))
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

    /// One retained version, as `cloud_project_versions` stores it: the
    /// shared log's entry (Studio/ProjectHistory/ProjectVersionLog — the
    /// iOS studio's on-device history records through the same rules) plus
    /// the media manifest it pins.
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

        init(_ entry: ProjectVersionLog.Entry, files: [CloudRemoteFile]) {
            id = entry.id; seq = entry.seq; firstRevision = entry.firstRevision; revision = entry.revision
            document = entry.document; self.files = files; kind = entry.kind; label = entry.label
            actorUID = entry.actorUID; clientKind = entry.clientKind; clientID = entry.clientID; source = entry.source
            change = entry.change; openedAt = entry.openedAt; updatedAt = entry.updatedAt
            mergedFrom = entry.mergedFrom; restoredFrom = entry.restoredFrom; extended = entry.extended
        }
    }

    /// The versions (no coalescing windows — the gates pin a clock that
    /// jumps between saves) and each one's pinned manifest.
    private var log = ProjectVersionLog()
    private var versionFiles: [String: [CloudRemoteFile]] = [:]

    /// Oldest first.
    var versions: [StubVersion] { log.entries.map { StubVersion($0, files: versionFiles[$0.id] ?? []) } }
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
        let entry = log.record(
            previous: previous, document: document ?? Data(), revision: revision, at: updatedAt ?? Date(),
            actorUID: actorUID, clientKind: clientKind, clientID: clientID, source: source, change: change,
            checkpoint: checkpoint.flatMap { ProjectVersionLog.Checkpoint(rawValue: $0.rawValue) },
            mergedFrom: mergedFrom, restoredFrom: restoredFrom)
        versionFiles[entry.id] = committedFiles
        return StubVersion(entry, files: committedFiles)
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

    /// `{projectId, revision, versionId, documentSha256, document}` when some
    /// version holds `rev`; 404 `revision_not_retained` (nil) otherwise.
    func revisionDocument(projectID: UUID, revision rev: Int) async throws -> Data? {
        revisionDocumentCalls += 1
        guard retainsRevisions, let holder = versions.last(where: { $0.revision == rev }) else { return nil }
        let body: [String: Any] = [
            "projectId": projectID.uuidString, "revision": rev, "versionId": holder.id,
            "documentSha256": CloudProjectManifest.sha256(of: holder.document),
            "document": String(decoding: holder.document, as: UTF8.self),
        ]
        return CloudHistoryParse.revisionDocument((try? JSONSerialization.data(withJSONObject: body)) ?? Data())
    }

    /// `access` of the versions list ("owner" | "member").
    var access = "owner"
    /// The owner's plan's `maxNamedVersions` (Pro 25).
    var namedLimit = 25

    func stubVersion(_ id: String) -> StubVersion? { versions.first { $0.id == id } }

    /// "Name this version" from another client (or the test itself).
    func name(_ id: String, _ label: String?) {
        log.name(id, label)
    }

    /// The API's version object `V` (docs/project-history.md §6.1), built as
    /// JSON and read back through `CloudHistoryParse` — so every history
    /// check also exercises the client's parser on the real wire shape.
    private func versionJSON(_ v: StubVersion) -> [String: Any] {
        func orNull(_ value: Any?) -> Any { value ?? NSNull() }
        let change: Any = v.change
            .flatMap { try? JSONSerialization.jsonObject(with: Data($0.json.canonical.utf8)) } ?? NSNull()
        return [
            "id": v.id, "seq": v.seq, "kind": v.kind, "label": orNull(v.label),
            "namedBy": v.label == nil ? NSNull() : ["uid": ownerUID, "name": orNull(displayNames[ownerUID])] as [String: Any],
            "namedAt": v.label == nil ? NSNull() : CloudAPIDate.string(v.updatedAt),
            "actor": ["uid": v.actorUID, "name": orNull(displayNames[v.actorUID])] as [String: Any],
            "client": v.clientKind, "source": v.source,
            "firstRevision": v.firstRevision, "revision": v.revision,
            "documentBytes": v.document.count, "documentSha256": CloudProjectManifest.sha256(of: v.document),
            "change": change, "restoredFrom": orNull(v.restoredFrom), "mergedFromRevision": orNull(v.mergedFrom),
            "openedAt": CloudAPIDate.string(v.openedAt), "updatedAt": CloudAPIDate.string(v.updatedAt),
            "isHead": v.id == versions.last?.id,
        ]
    }

    private func wire(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    /// Media the committed set dropped that versions still pin, and the part
    /// pinned ONLY by unnamed non-head versions (what Free up releases).
    func mediaStats() -> (pinned: Int64, freeable: Int64) {
        let current = Set(committedFiles.map(\.sha256))
        let headID = versions.last?.id
        var pinned: [String: Int64] = [:]
        var keptByProtected = Set<String>()
        for version in versions {
            for file in version.files where !current.contains(file.sha256) {
                pinned[file.sha256] = file.bytes
                if version.label != nil || version.id == headID { keptByProtected.insert(file.sha256) }
            }
        }
        let freeable = pinned.filter { !keptByProtected.contains($0.key) }.values.reduce(0, +)
        return (pinned.values.reduce(0, +), freeable)
    }

    /// Next restore answers 409 `files_changed` (a media commit raced it).
    var raceNextRestore = false
}

extension StubCloudServer: CloudHistoryTransport {
    func head(projectID: UUID) async throws -> CloudHead? {
        guard revision > 0 else { return nil }
        let body: [String: Any] = [
            "projectId": projectID.uuidString, "revision": revision,
            "documentSha256": document.map { CloudProjectManifest.sha256(of: $0) } ?? NSNull(),
            "updatedAt": updatedAt.map(CloudAPIDate.string) ?? NSNull(),
            "updatedBy": versions.last?.actorUID ?? NSNull(), "headVersionId": versions.last?.id ?? NSNull(),
        ]
        return CloudHistoryParse.head(wire(body))
    }

    func versions(projectID: UUID, before: Int?, limit: Int) async throws -> CloudVersionPage? {
        if let versionsDelay { try await Task.sleep(for: versionsDelay) }
        guard revision > 0 else { return nil }
        let pageSize = max(1, min(limit, 200))
        let newestFirst = versions.reversed().filter { before == nil || $0.seq < before! }
        let slice = Array(newestFirst.prefix(pageSize))
        let stats = mediaStats()
        let body: [String: Any] = [
            "projectId": projectID.uuidString, "revision": revision,
            "headVersionId": versions.last?.id ?? NSNull(), "access": access,
            "versions": slice.map(versionJSON),
            "nextBefore": slice.count == pageSize ? (slice.last?.seq as Any) : NSNull(),
            "retention": ["maxHistoryDays": 30, "maxNamedVersions": namedLimit,
                          "namedCount": versions.filter { $0.label != nil }.count],
            "pinnedMediaBytes": stats.pinned, "freeableBytes": stats.freeable,
        ]
        guard let page = CloudHistoryParse.page(wire(body)) else { throw CloudSyncError.invalidResponse }
        return page
    }

    func version(projectID: UUID, versionID: String) async throws -> CloudVersionDetail {
        guard let version = stubVersion(versionID) else {
            throw CloudSyncError.api(status: 404, code: "version_not_found", message: "Version not found")
        }
        let files = version.files.map { file -> [String: Any] in
            let signed = presigned(file)
            return ["path": file.path, "sha256": file.sha256, "bytes": file.bytes, "contentType": file.contentType,
                    "source": file.source ?? NSNull(), "url": signed.url?.absoluteString ?? NSNull()]
        }
        let body: [String: Any] = [
            "projectId": projectID.uuidString, "version": versionJSON(version),
            "document": String(decoding: version.document, as: UTF8.self), "files": files,
            "missingPaths": version.files.filter { ready[$0.sha256] == nil }.map(\.path),
            "urlsExpireAt": CloudAPIDate.string(Date().addingTimeInterval(900)),
        ]
        guard let detail = CloudHistoryParse.detail(wire(body)) else { throw CloudSyncError.invalidResponse }
        return detail
    }

    func renameVersion(projectID: UUID, versionID: String, label: String?) async throws -> CloudVersion? {
        guard let index = versions.firstIndex(where: { $0.id == versionID }) else {
            throw CloudSyncError.api(status: 404, code: "version_not_found", message: "Version not found")
        }
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmed.count <= 100, !trimmed.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw CloudSyncError.api(status: 400, code: "invalid_label", message: "Invalid label")
        }
        if !trimmed.isEmpty, versions[index].label == nil, versions.filter({ $0.label != nil }).count >= namedLimit {
            throw CloudSyncError.api(status: 402, code: "named_version_limit", message: "Named version limit reached")
        }
        log.name(versionID, trimmed.isEmpty ? nil : trimmed)
        let body = wire(["projectId": projectID.uuidString, "version": versionJSON(versions[index])])
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        return CloudHistoryParse.version(object?["version"])
    }

    /// Server-side restore (§6.1): the version's media paths are re-committed
    /// into the current set (version paths win, current ones stay), then its
    /// document is saved as a NEW revision + `restore` version.
    func restoreVersion(projectID: UUID, versionID: String, baseRevision: Int,
                        context: CloudSaveContext) async throws -> CloudRestoreResult {
        restoreCalls += 1
        guard let old = stubVersion(versionID) else {
            throw CloudSyncError.api(status: 404, code: "version_not_found", message: "Version not found")
        }
        guard baseRevision == revision else {
            return .conflict(CloudConflict(revision: revision, document: document, documentSHA256: documentSHA,
                                           updatedAt: updatedAt, headVersionID: versions.last?.id))
        }
        if raceNextRestore {
            raceNextRestore = false
            return .filesChanged
        }
        let missing = old.files.filter { ready[$0.sha256] == nil }.map(\.path)
        guard missing.isEmpty else {
            throw CloudSyncError.api(status: 409, code: "version_media_missing",
                                     message: "Some of this version's media is no longer stored")
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
        guard access == "owner" else {
            throw CloudSyncError.api(status: 403, code: "not_owner", message: "Only the owner can delete versions")
        }
        guard versions.last?.id != versionID else {
            throw CloudSyncError.api(status: 409, code: "head_version", message: "The current version cannot be deleted")
        }
        guard versions.contains(where: { $0.id == versionID }) else {
            throw CloudSyncError.api(status: 404, code: "version_not_found", message: "Version not found")
        }
        log.remove([versionID])
        versionFiles[versionID] = nil
        deletedVersions.append(versionID)
        collect()
    }

    /// POST …/history/free-up: every UNNAMED, non-head version that pins
    /// media the committed set dropped is deleted.
    func freeUp(projectID: UUID) async throws -> CloudFreeUpResult {
        guard access == "owner" else {
            throw CloudSyncError.api(status: 403, code: "not_owner", message: "Only the owner can free up History")
        }
        let before = mediaStats()
        let current = Set(committedFiles.map(\.sha256))
        let headID = versions.last?.id
        let doomed = versions.filter { v in
            v.id != headID && v.label == nil && v.files.contains { !current.contains($0.sha256) }
        }.map(\.id)
        log.remove(Set(doomed))
        for id in doomed { versionFiles[id] = nil }
        deletedVersions += doomed
        collect()
        let after = mediaStats()
        let body: [String: Any] = [
            "projectId": projectID.uuidString, "deletedVersions": doomed,
            "releasedBytes": before.pinned - after.pinned,
            "pinnedMediaBytes": after.pinned, "freeableBytes": after.freeable,
        ]
        guard let result = CloudHistoryParse.freeUp(wire(body)) else { throw CloudSyncError.invalidResponse }
        return result
    }
}
