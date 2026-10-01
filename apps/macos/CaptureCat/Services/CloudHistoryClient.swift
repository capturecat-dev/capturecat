import Foundation
import os

private let historyLogger = Logger(subsystem: "so.capturecat.CaptureCat", category: "CloudHistory")

// MARK: - Models (docs/project-history.md §6.1 — the implemented wire contract)

/// One retained checkpoint of a cloud project — the API's version object `V`:
/// `{ id, seq, kind, label, namedBy: {uid,name}|null, namedAt,
///    actor: {uid,name}|null, client, source, firstRevision, revision,
///    documentBytes, documentSha256, change|null, restoredFrom,
///    mergedFromRevision, openedAt, updatedAt, isHead }`.
nonisolated struct CloudVersion: Equatable, Sendable, Identifiable {
    let id: String
    let seq: Int
    /// The head revision this version holds.
    let revision: Int
    /// The first revision it covered (a coalesced version spans several).
    let firstRevision: Int?
    /// `upload` | `edit` | `merge` | `restore`.
    let kind: String
    var label: String?
    /// Display name (else uid) of who named it.
    let namedBy: String?
    let namedAt: Date?
    let actorUID: String?
    /// The actor's display name (`actor.name`).
    let actorName: String?
    /// `mac` | `web` | `unknown` (`client`).
    let clientKind: String
    /// `human` | `agent` | `mixed`.
    let source: String
    /// The change-set from the previous version; nil = unknown (a client
    /// that sent no `X-CC-Change`) — shown as a generic "Edited".
    let change: ChangeSet?
    let documentBytes: Int64?
    let documentSHA256: String?
    let restoredFrom: String?
    let mergedFromRevision: Int?
    let openedAt: Date?
    let updatedAt: Date?
    /// The server marks the current version.
    let isHead: Bool

    var isNamed: Bool { !(label ?? "").isEmpty }
    var date: Date? { updatedAt ?? openedAt }

    /// The client badge: "Mac" / "Web" / "Agent via Mac" / "Agent via Web".
    var clientLabel: String {
        let client: String
        switch clientKind {
        case "mac": client = "Mac"
        case "web": client = "Web"
        default: client = "Other"
        }
        switch source {
        case "agent": return "Agent via \(client)"
        case "mixed": return "\(client) + Agent"
        default: return client
        }
    }

    /// "Zoom added · Background changed · 3 captions edited" (≤ 3 phrases).
    var summary: String {
        if let change { return ChangeSummary.format(change, maxParts: 3) }
        switch kind {
        case "upload": return "Uploaded"
        case "restore": return "Restored an earlier version"
        case "merge": return "Merged edits"
        default: return "Edited"
        }
    }
}

nonisolated struct CloudRetention: Equatable, Sendable {
    /// `maxHistoryDays` — Pro 30, Business 365, Free 0 (head only).
    let historyDays: Int?
    /// `maxNamedVersions` — Pro 25, Business 500.
    let maxNamed: Int?
    let namedCount: Int?
}

nonisolated struct CloudVersionPage: Equatable, Sendable {
    var versions: [CloudVersion]
    /// `before=` cursor for the next page (nil = no more).
    var nextBefore: Int?
    var retention: CloudRetention?
    /// Media the committed set dropped that history still keeps (counts
    /// toward storage) — "History keeps X of removed media".
    var pinnedMediaBytes: Int64
    /// The part of it Free up would release (pinned only by unnamed,
    /// non-head versions).
    var freeableBytes: Int64
    var headVersionID: String?
    /// `access == "owner"` (only the owner deletes versions or frees media).
    var isOwner: Bool?
}

nonisolated struct CloudHead: Equatable, Sendable {
    let revision: Int
    let documentSHA256: String?
    let updatedAt: Date?
    let updatedBy: String?
    let headVersionID: String?
}

nonisolated struct CloudVersionDetail: Equatable, Sendable {
    let version: CloudVersion?
    /// The version's project.json, byte-exact.
    let document: Data
    /// That version's manifest, each with a presigned GET.
    let files: [CloudRemoteFile]
    /// Paths of that manifest whose objects are gone.
    let missingPaths: [String]
}

nonisolated enum CloudRestoreResult: Equatable, Sendable {
    case restored(revision: Int, documentSHA256: String?, version: CloudSavedVersion?)
    /// 409 `revision_conflict` — the head moved (If-Match lost).
    case conflict(CloudConflict)
    /// 409 `files_changed` — a media commit raced the restore; retry.
    case filesChanged
}

nonisolated struct CloudFreeUpResult: Equatable, Sendable {
    let deletedVersions: [String]
    let releasedBytes: Int64
    let pinnedMediaBytes: Int64
    let freeableBytes: Int64
}

// MARK: - Transport

/// The history routes (§6.1). `HTTPCloudProjectTransport` talks to the API;
/// `--cloud-sync-test` / `--history-panel-shot` use `StubCloudServer`.
protocol CloudHistoryTransport: AnyObject {
    /// GET …/:id/head — nil = no cloud copy.
    func head(projectID: UUID) async throws -> CloudHead?
    /// GET …/:id/versions?before=&limit= — nil = no cloud copy.
    func versions(projectID: UUID, before: Int?, limit: Int) async throws -> CloudVersionPage?
    /// GET …/:id/versions/:vid
    func version(projectID: UUID, versionID: String) async throws -> CloudVersionDetail
    /// PATCH …/versions/:vid {label} (nil/empty label = unname).
    func renameVersion(projectID: UUID, versionID: String, label: String?) async throws -> CloudVersion?
    /// POST …/versions/:vid/restore + If-Match (+ X-CC-Client/-Id/-Source).
    func restoreVersion(projectID: UUID, versionID: String, baseRevision: Int,
                        context: CloudSaveContext) async throws -> CloudRestoreResult
    /// DELETE …/versions/:vid (owner only; 409 `head_version` for the head).
    func deleteVersion(projectID: UUID, versionID: String) async throws
    /// POST …/:id/history/free-up (owner only).
    func freeUp(projectID: UUID) async throws -> CloudFreeUpResult
}

// MARK: - Parsing

nonisolated enum CloudHistoryParse {
    private static func value(_ object: [String: Any], _ keys: String...) -> Any? {
        for key in keys {
            if let value = object[key], !(value is NSNull) { return value }
        }
        return nil
    }

    /// `{uid, name}` → name, else uid; a bare string passes through.
    private static func person(_ raw: Any?) -> (uid: String?, name: String?) {
        if let object = raw as? [String: Any] {
            return (CloudJSON.string(object["uid"]), CloudJSON.string(object["name"]))
        }
        return (CloudJSON.string(raw), nil)
    }

    static func version(_ raw: Any?) -> CloudVersion? {
        guard let object = raw as? [String: Any], let id = CloudJSON.string(value(object, "id")) else { return nil }
        var change: ChangeSet?
        if let json = value(object, "change") {
            if let text = json as? String {
                change = (try? JSONValue.parse(text)).flatMap(ProjectDiff.changeSet(from:))
            } else if let data = try? JSONSerialization.data(withJSONObject: json),
                      let parsed = try? JSONValue.parse(data: data) {
                change = ProjectDiff.changeSet(from: parsed)
            }
        }
        let actor = person(value(object, "actor"))
        let namer = person(value(object, "namedBy"))
        return CloudVersion(
            id: id,
            seq: CloudJSON.int(value(object, "seq")) ?? 0,
            revision: CloudJSON.int(value(object, "revision")) ?? 0,
            firstRevision: CloudJSON.int(value(object, "firstRevision")),
            kind: CloudJSON.string(value(object, "kind")) ?? "edit",
            label: CloudJSON.string(value(object, "label")),
            namedBy: namer.name ?? namer.uid,
            namedAt: CloudAPIDate.parse(value(object, "namedAt")),
            actorUID: actor.uid,
            actorName: actor.name,
            clientKind: CloudJSON.string(value(object, "client")) ?? "unknown",
            source: CloudJSON.string(value(object, "source")) ?? "human",
            change: change,
            documentBytes: CloudJSON.int64(value(object, "documentBytes")),
            documentSHA256: CloudJSON.string(value(object, "documentSha256")),
            restoredFrom: CloudJSON.string(value(object, "restoredFrom")),
            mergedFromRevision: CloudJSON.int(value(object, "mergedFromRevision")),
            openedAt: CloudAPIDate.parse(value(object, "openedAt")),
            updatedAt: CloudAPIDate.parse(value(object, "updatedAt")),
            isHead: value(object, "isHead") as? Bool ?? false
        )
    }

    static func page(_ data: Data) -> CloudVersionPage? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = value(object, "versions") as? [Any] else { return nil }
        var retention: CloudRetention?
        if let r = value(object, "retention") as? [String: Any] {
            retention = CloudRetention(
                historyDays: CloudJSON.int(value(r, "maxHistoryDays")),
                maxNamed: CloudJSON.int(value(r, "maxNamedVersions")),
                namedCount: CloudJSON.int(value(r, "namedCount")))
        }
        return CloudVersionPage(
            versions: list.compactMap(version),
            nextBefore: CloudJSON.int(value(object, "nextBefore")),
            retention: retention,
            pinnedMediaBytes: CloudJSON.int64(value(object, "pinnedMediaBytes")) ?? 0,
            freeableBytes: CloudJSON.int64(value(object, "freeableBytes")) ?? 0,
            headVersionID: CloudJSON.string(value(object, "headVersionId")),
            isOwner: CloudJSON.string(value(object, "access")).map { $0 == "owner" })
    }

    static func head(_ data: Data) -> CloudHead? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let revision = CloudJSON.int(value(object, "revision")) else { return nil }
        return CloudHead(
            revision: revision,
            documentSHA256: CloudJSON.string(value(object, "documentSha256")),
            updatedAt: CloudAPIDate.parse(value(object, "updatedAt")),
            updatedBy: CloudJSON.string(value(object, "updatedBy")),
            headVersionID: CloudJSON.string(value(object, "headVersionId")))
    }

    static func detail(_ data: Data) -> CloudVersionDetail? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let text = value(object, "document") as? String else { return nil }
        return CloudVersionDetail(
            version: version(value(object, "version")),
            document: Data(text.utf8),
            files: HTTPCloudProjectTransport.remoteFiles(value(object, "files")),
            missingPaths: value(object, "missingPaths") as? [String] ?? [])
    }

    /// `{ projectId, revision, versionId, documentSha256, document }`.
    static func revisionDocument(_ data: Data) -> Data? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let text = object["document"] as? String else { return nil }
        return Data(text.utf8)
    }

    static func freeUp(_ data: Data) -> CloudFreeUpResult? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return CloudFreeUpResult(
            deletedVersions: value(object, "deletedVersions") as? [String] ?? [],
            releasedBytes: CloudJSON.int64(value(object, "releasedBytes")) ?? 0,
            pinnedMediaBytes: CloudJSON.int64(value(object, "pinnedMediaBytes")) ?? 0,
            freeableBytes: CloudJSON.int64(value(object, "freeableBytes")) ?? 0)
    }
}

extension HTTPCloudProjectTransport: CloudHistoryTransport {
    func head(projectID: UUID) async throws -> CloudHead? {
        let (data, http) = try await send(try request("GET", "/\(projectID.uuidString)/head"))
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else { throw apiError(data, http) }
        guard let head = CloudHistoryParse.head(data) else { throw CloudSyncError.invalidResponse }
        return head
    }

    func versions(projectID: UUID, before: Int?, limit: Int) async throws -> CloudVersionPage? {
        var path = "/\(projectID.uuidString)/versions?limit=\(max(1, min(limit, 200)))"
        if let before { path += "&before=\(before)" }
        let (data, http) = try await send(try request("GET", path))
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else { throw apiError(data, http) }
        guard let page = CloudHistoryParse.page(data) else { throw CloudSyncError.invalidResponse }
        return page
    }

    func version(projectID: UUID, versionID: String) async throws -> CloudVersionDetail {
        let (data, http) = try await send(try request("GET", "/\(projectID.uuidString)/versions/\(Self.escape(versionID))"))
        guard http.statusCode == 200 else { throw apiError(data, http) }
        guard let detail = CloudHistoryParse.detail(data) else { throw CloudSyncError.invalidResponse }
        return detail
    }

    func renameVersion(projectID: UUID, versionID: String, label: String?) async throws -> CloudVersion? {
        var request = try request("PATCH", "/\(projectID.uuidString)/versions/\(Self.escape(versionID))")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["label": (label?.isEmpty == false ? label! : NSNull()) as Any]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, http) = try await send(request)
        guard http.statusCode == 200 else { throw apiError(data, http) }
        return CloudHistoryParse.version(((try? json(data)) ?? [:])["version"])
    }

    func restoreVersion(projectID: UUID, versionID: String, baseRevision: Int,
                        context: CloudSaveContext) async throws -> CloudRestoreResult {
        var request = try request("POST", "/\(projectID.uuidString)/versions/\(Self.escape(versionID))/restore")
        request.setValue("\"\(baseRevision)\"", forHTTPHeaderField: "If-Match")
        // Restore takes the client headers only (it is always its own version).
        for name in ["X-CC-Client", "X-CC-Client-Id", "X-CC-Source"] {
            if let value = context.headers[name] { request.setValue(value, forHTTPHeaderField: name) }
        }
        let (data, http) = try await send(request)
        if http.statusCode == 409, let object = try? json(data) {
            switch object["code"] as? String {
            case "revision_conflict": return .conflict(Self.conflict(object))
            case "files_changed": return .filesChanged
            default: throw apiError(data, http) // version_media_missing
            }
        }
        guard http.statusCode == 200 else { throw apiError(data, http) }
        let object = try json(data)
        guard let revision = CloudJSON.int(object["revision"]) else { throw CloudSyncError.invalidResponse }
        return .restored(revision: revision, documentSHA256: object["documentSha256"] as? String,
                         version: Self.savedVersion(object["version"]))
    }

    func deleteVersion(projectID: UUID, versionID: String) async throws {
        let (data, http) = try await send(try request("DELETE", "/\(projectID.uuidString)/versions/\(Self.escape(versionID))"))
        guard (200...299).contains(http.statusCode) else { throw apiError(data, http) }
    }

    func freeUp(projectID: UUID) async throws -> CloudFreeUpResult {
        let (data, http) = try await send(try request("POST", "/\(projectID.uuidString)/history/free-up"))
        guard http.statusCode == 200 else { throw apiError(data, http) }
        guard let result = CloudHistoryParse.freeUp(data) else { throw CloudSyncError.invalidResponse }
        return result
    }

    private static func escape(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? id
    }
}

// MARK: - Local sync status

/// The "On this Mac — not synced" pseudo-row: project.json vs the merge base.
nonisolated struct CloudLocalStatus: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// No sidecar for this API: the project was never uploaded from here.
        case neverUploaded
        case synced
        case unsynced
    }

    let kind: Kind
    let revision: Int?
    /// base → local (nil when the base is unknown).
    let changes: ChangeSet?

    var summary: String {
        guard let changes else { return "Edited on this Mac" }
        return ChangeSummary.format(changes, maxParts: 3)
    }

    static func read(projectID: UUID, projectDirectory: URL, apiBaseURL: String) -> CloudLocalStatus {
        guard let state = CloudSyncState.load(from: projectDirectory, projectID: projectID, apiBaseURL: apiBaseURL) else {
            return CloudLocalStatus(kind: .neverUploaded, revision: nil, changes: nil)
        }
        guard let local = try? Data(contentsOf: projectDirectory.appendingPathComponent("project.json")) else {
            return CloudLocalStatus(kind: .synced, revision: state.revision, changes: nil)
        }
        if CloudProjectManifest.sha256(of: local) == state.documentSHA256 {
            return CloudLocalStatus(kind: .synced, revision: state.revision, changes: nil)
        }
        var changes: ChangeSet?
        if let base = state.loadBase(from: projectDirectory),
           let a = try? JSONValue.parse(data: base), let b = try? JSONValue.parse(data: local) {
            changes = ProjectDiff.diff(a, b)
        }
        return CloudLocalStatus(kind: .unsynced, revision: state.revision, changes: changes)
    }
}

// MARK: - Client (what the History pane calls)

/// The History pane's service: list, name, compare, preview, restore,
/// delete and Free up — over a `CloudHistoryTransport`, with the sync engine
/// for the parts that move documents (restore = push unsynced edits, POST
/// restore, pull the restored revision).
@MainActor
final class CloudHistoryClient {
    typealias Transport = CloudHistoryTransport & CloudProjectTransport

    let transport: Transport
    let sync: CloudProjectSync

    init(transport: Transport, sync: CloudProjectSync) {
        self.transport = transport
        self.sync = sync
    }

    static func live() -> CloudHistoryClient {
        let transport = HTTPCloudProjectTransport()
        return CloudHistoryClient(transport: transport, sync: CloudProjectSync(transport: transport))
    }

    func page(projectID: UUID, before: Int? = nil) async throws -> CloudVersionPage? {
        try await transport.versions(projectID: projectID, before: before, limit: 50)
    }

    func localStatus(projectID: UUID, projectDirectory: URL) -> CloudLocalStatus {
        CloudLocalStatus.read(projectID: projectID, projectDirectory: projectDirectory, apiBaseURL: sync.apiBaseURL)
    }

    func detail(projectID: UUID, versionID: String) async throws -> CloudVersionDetail {
        try await transport.version(projectID: projectID, versionID: versionID)
    }

    func rename(projectID: UUID, versionID: String, label: String?) async throws -> CloudVersion? {
        try await transport.renameVersion(projectID: projectID, versionID: versionID, label: label)
    }

    func delete(projectID: UUID, versionID: String) async throws {
        try await transport.deleteVersion(projectID: projectID, versionID: versionID)
    }

    /// "Free up": the server deletes every unnamed, non-head version pinning
    /// media the project no longer uses (owner only).
    func freeUp(projectID: UUID) async throws -> CloudFreeUpResult {
        try await transport.freeUp(projectID: projectID)
    }

    enum RestoreOutcome: Equatable {
        case restored(revision: Int)
        /// This Mac's unsynced edits could not be saved to History first
        /// (they conflict), or the head kept moving — sync, then restore.
        case needsSync
    }

    /// Restore `versionID` as a NEW head (History keeps the current one):
    /// unsynced Mac edits are pushed first so they are in History too, then
    /// POST restore at the revision this Mac agrees with, then the restored
    /// revision (and the media its manifest pins) is pulled here.
    func restore(
        versionID: String,
        project: Project,
        projectDirectory dir: URL,
        progress: @escaping (CloudProjectSync.Progress) -> Void = { _ in }
    ) async throws -> RestoreOutcome {
        let projectID = project.id
        var state = CloudSyncState.load(from: dir, projectID: projectID, apiBaseURL: sync.apiBaseURL)
        let local = try? Data(contentsOf: dir.appendingPathComponent("project.json"))
        if state == nil || local.map(CloudProjectManifest.sha256(of:)) != state?.documentSHA256 {
            switch try await sync.push(project: project, projectDirectory: dir, progress: progress) {
            case .pushed, .unchanged, .cloudIsNewer, .merged: break
            case .conflict, .needsReview: return .needsSync
            }
            state = CloudSyncState.load(from: dir, projectID: projectID, apiBaseURL: sync.apiBaseURL)
        }
        guard var agreed = state else { throw CloudSyncError.invalidResponse }
        let context = CloudSaveContext(clientID: sync.clientID, source: .human, checkpoint: .restore)
        for attempt in 0..<3 {
            switch try await transport.restoreVersion(projectID: projectID, versionID: versionID,
                                                      baseRevision: agreed.revision, context: context) {
            case .restored(let revision, _, _):
                let pulled = try await sync.pull(projectID: projectID, projectDirectory: dir, progress: progress)
                historyLogger.info("restored version \(versionID, privacy: .public) as revision \(revision) (\(String(describing: pulled), privacy: .public))")
                return .restored(revision: revision)
            case .filesChanged:
                // A media commit raced the restore: the API says retry.
                continue
            case .conflict:
                // Someone saved meanwhile: agree with the new head (a pull —
                // this Mac has no unsynced edits now), then retry.
                guard attempt < 2 else { return .needsSync }
                _ = try await sync.pull(projectID: projectID, projectDirectory: dir, progress: progress)
                guard let fresh = CloudSyncState.load(from: dir, projectID: projectID, apiBaseURL: sync.apiBaseURL) else {
                    return .needsSync
                }
                agreed = fresh
            }
        }
        return .needsSync
    }

    /// A version as a read-only project for Preview: its document decoded by
    /// this build (media re-pointed at this Mac's copies, like a pull), with
    /// `isPreview` set so ProjectStore never saves it.
    func previewProject(projectID: UUID, versionID: String, projectDirectory: URL) async throws -> Project {
        let detail = try await detail(projectID: projectID, versionID: versionID)
        let data = try CloudProjectSync.validatedDocument(detail.document, projectID: projectID,
                                                          projectDirectory: projectDirectory, files: detail.files)
        let project = try CloudProjectSync.checkedProject(data, projectID: projectID)
        project.isPreview = true
        return project
    }

    /// History refusals in the user's words; everything else as the sync says.
    static func message(for error: Error) -> String {
        switch (error as? CloudSyncError)?.apiCode {
        case "named_version_limit":
            return "Your plan's named-version limit is reached. Unname an older version first."
        case "invalid_label":
            return "Version names are up to 100 characters, without control characters."
        case "head_version":
            return "The current version can't be deleted."
        case "not_owner":
            return "Only the project's owner can delete versions or free up History."
        case "version_media_missing":
            return "Some of this version's media is no longer stored, so it can't be restored."
        case "version_document_missing":
            return "This version's document is no longer stored."
        case "version_not_found":
            return "That version no longer exists — History may have been pruned."
        default:
            return CloudSyncController.message(for: error)
        }
    }
}
