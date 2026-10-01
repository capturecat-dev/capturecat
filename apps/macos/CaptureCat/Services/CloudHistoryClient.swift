import Foundation
import os

private let historyLogger = Logger(subsystem: "so.capturecat.CaptureCat", category: "CloudHistory")

// MARK: - Models (docs/project-history.md §2 + §4)

/// One retained checkpoint of a cloud project (`cloud_project_versions`).
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
    let namedBy: String?
    let namedAt: Date?
    let actorUID: String?
    /// Display name the API joins in (`versions` list).
    let actorName: String?
    /// `mac` | `web` | `unknown`.
    let clientKind: String
    let clientID: String?
    /// `human` | `agent` | `mixed`.
    let source: String
    /// The version's change-set (base → this version), composed by the API.
    let change: ChangeSet?
    let docBytes: Int64?
    let manifestSHA: String?
    let restoredFrom: String?
    let mergedFromRevision: Int?
    let openedAt: Date?
    let updatedAt: Date?

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
    /// History window in days (Pro 30, Business 365, Free 0).
    let historyDays: Int?
    /// Named-version cap (Pro 25, Business 500).
    let maxNamed: Int?
    let namedCount: Int?
}

nonisolated struct CloudVersionPage: Equatable, Sendable {
    var versions: [CloudVersion]
    /// `before=` cursor for the next page (nil = no more).
    var nextBefore: Int?
    var retention: CloudRetention?
    /// "History keeps X of removed media".
    var pinnedMediaBytes: Int64
    var headVersionID: String?
    /// The caller owns the project (only the owner may delete versions).
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
}

nonisolated enum CloudRestoreResult: Equatable, Sendable {
    case restored(revision: Int, documentSHA256: String?, version: CloudSavedVersion?)
    /// The head moved (If-Match lost) — the 409 carries it.
    case conflict(CloudConflict)
}

// MARK: - Transport

/// The history routes (design §4). `HTTPCloudProjectTransport` talks to the
/// API; `--cloud-sync-test` / `--history-panel-shot` use `StubCloudServer`.
protocol CloudHistoryTransport: AnyObject {
    /// GET …/:id/head — nil = no cloud copy.
    func head(projectID: UUID) async throws -> CloudHead?
    /// GET …/:id/versions?before=&limit= — nil = no cloud copy.
    func versions(projectID: UUID, before: Int?, limit: Int) async throws -> CloudVersionPage?
    /// GET …/:id/versions/:vid
    func version(projectID: UUID, versionID: String) async throws -> CloudVersionDetail
    /// PATCH …/versions/:vid {label} (nil/empty label = unname).
    func renameVersion(projectID: UUID, versionID: String, label: String?) async throws -> CloudVersion?
    /// POST …/versions/:vid/restore + If-Match.
    func restoreVersion(projectID: UUID, versionID: String, baseRevision: Int,
                        context: CloudSaveContext) async throws -> CloudRestoreResult
    /// DELETE …/versions/:vid (owner only; never the head).
    func deleteVersion(projectID: UUID, versionID: String) async throws
}

// MARK: - Parsing (tolerant: camelCase, snake_case and nested actor shapes)

nonisolated enum CloudHistoryParse {
    private static func value(_ object: [String: Any], _ keys: String...) -> Any? {
        for key in keys {
            if let value = object[key], !(value is NSNull) { return value }
        }
        return nil
    }

    static func version(_ raw: Any?) -> CloudVersion? {
        guard let object = raw as? [String: Any],
              let id = CloudJSON.string(value(object, "id", "versionId", "version_id")) else { return nil }
        let actor = value(object, "actor") as? [String: Any] ?? [:]
        var change: ChangeSet?
        if let json = value(object, "change", "changeJson", "change_json") {
            if let text = json as? String {
                change = (try? JSONValue.parse(text)).flatMap(ProjectDiff.changeSet(from:))
            } else if let data = try? JSONSerialization.data(withJSONObject: json),
                      let parsed = try? JSONValue.parse(data: data) {
                change = ProjectDiff.changeSet(from: parsed)
            }
        }
        return CloudVersion(
            id: id,
            seq: CloudJSON.int(value(object, "seq")) ?? 0,
            revision: CloudJSON.int(value(object, "revision")) ?? 0,
            firstRevision: CloudJSON.int(value(object, "firstRevision", "first_revision")),
            kind: CloudJSON.string(value(object, "kind")) ?? "edit",
            label: CloudJSON.string(value(object, "label")),
            namedBy: CloudJSON.string(value(object, "namedBy", "named_by")),
            namedAt: CloudAPIDate.parse(value(object, "namedAt", "named_at")),
            actorUID: CloudJSON.string(value(object, "actorUid", "actor_uid")) ?? CloudJSON.string(actor["uid"]),
            actorName: CloudJSON.string(value(object, "actorName", "actor_name", "actorDisplayName"))
                ?? CloudJSON.string(actor["name"]) ?? CloudJSON.string(actor["displayName"]),
            clientKind: CloudJSON.string(value(object, "clientKind", "client_kind", "client")) ?? "unknown",
            clientID: CloudJSON.string(value(object, "clientId", "client_id")),
            source: CloudJSON.string(value(object, "source")) ?? "human",
            change: change,
            docBytes: CloudJSON.int64(value(object, "docBytes", "doc_bytes")),
            manifestSHA: CloudJSON.string(value(object, "manifestSha", "manifest_sha", "manifestSha256")),
            restoredFrom: CloudJSON.string(value(object, "restoredFrom", "restored_from")),
            mergedFromRevision: CloudJSON.int(value(object, "mergedFromRevision", "merged_from_revision")),
            openedAt: CloudAPIDate.parse(value(object, "openedAt", "opened_at")),
            updatedAt: CloudAPIDate.parse(value(object, "updatedAt", "updated_at"))
        )
    }

    static func page(_ data: Data) -> CloudVersionPage? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let versions = (value(object, "versions", "items") as? [Any] ?? []).compactMap(version)
        var retention: CloudRetention?
        if let r = value(object, "retention") as? [String: Any] {
            retention = CloudRetention(
                historyDays: CloudJSON.int(value(r, "historyDays", "maxHistoryDays", "days")),
                maxNamed: CloudJSON.int(value(r, "maxNamedVersions", "maxNamed", "named")),
                namedCount: CloudJSON.int(value(r, "namedCount", "named_count")))
        }
        var isOwner = value(object, "isOwner", "is_owner") as? Bool
        if isOwner == nil, let access = CloudJSON.string(value(object, "access")) { isOwner = access == "owner" }
        return CloudVersionPage(
            versions: versions,
            nextBefore: CloudJSON.int(value(object, "nextBefore", "next_before", "nextCursor")),
            retention: retention,
            pinnedMediaBytes: CloudJSON.int64(value(object, "pinnedMediaBytes", "pinned_media_bytes")) ?? 0,
            headVersionID: CloudJSON.string(value(object, "headVersionId", "head_version_id")),
            isOwner: isOwner)
    }

    static func head(_ data: Data) -> CloudHead? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let revision = CloudJSON.int(value(object, "revision")) else { return nil }
        return CloudHead(
            revision: revision,
            documentSHA256: CloudJSON.string(value(object, "documentSha256", "docSha", "docSha256")),
            updatedAt: CloudAPIDate.parse(value(object, "updatedAt", "updated_at")),
            updatedBy: CloudJSON.string(value(object, "updatedBy", "updated_by")),
            headVersionID: CloudJSON.string(value(object, "headVersionId", "head_version_id")))
    }

    static func detail(_ data: Data) -> CloudVersionDetail? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let text = value(object, "document") as? String else { return nil }
        return CloudVersionDetail(
            version: version(value(object, "version")),
            document: Data(text.utf8),
            files: HTTPCloudProjectTransport.remoteFiles(value(object, "files")))
    }

    /// `{document: "<text>"}`, or the document itself as the body.
    static func revisionDocument(_ data: Data) -> Data? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let text = object["document"] as? String { return Data(text.utf8) }
        if object["id"] != nil, object["settings"] != nil { return data }
        return nil
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
        var path = "/\(projectID.uuidString)/versions?limit=\(max(1, min(limit, 50)))"
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
        let object = (try? json(data)) ?? [:]
        return CloudHistoryParse.version(object["version"] ?? object)
    }

    func restoreVersion(projectID: UUID, versionID: String, baseRevision: Int,
                        context: CloudSaveContext) async throws -> CloudRestoreResult {
        var request = try request("POST", "/\(projectID.uuidString)/versions/\(Self.escape(versionID))/restore")
        request.setValue("\"\(baseRevision)\"", forHTTPHeaderField: "If-Match")
        for (name, value) in context.headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, http) = try await send(request)
        if http.statusCode == 409, let object = try? json(data) {
            return .conflict(Self.conflict(object))
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
/// delete and "Free up" — over a `CloudHistoryTransport`, with the sync
/// engine for the parts that move documents (restore = push unsynced edits,
/// POST restore, pull the restored revision).
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

    /// "Free up": delete the unnamed versions pinning removed media — every
    /// unnamed, non-head version whose manifest is not the head's (only those
    /// can hold a file the current project no longer uses). Named versions
    /// are kept (the user asked for them). Returns how many were deleted.
    func freeUp(projectID: UUID, page: CloudVersionPage) async throws -> Int {
        let head = page.versions.first { $0.id == page.headVersionID } ?? page.versions.first
        let doomed = Self.freeUpCandidates(page)
        var deleted = 0
        for version in doomed where version.id != head?.id {
            try await transport.deleteVersion(projectID: projectID, versionID: version.id)
            deleted += 1
        }
        return deleted
    }

    nonisolated static func freeUpCandidates(_ page: CloudVersionPage) -> [CloudVersion] {
        let head = page.versions.first { $0.id == page.headVersionID } ?? page.versions.first
        return page.versions.filter { version in
            version.id != head?.id && !version.isNamed
                && version.manifestSHA != nil && version.manifestSHA != head?.manifestSHA
        }
    }

    enum RestoreOutcome: Equatable {
        case restored(revision: Int)
        /// This Mac's unsynced edits could not be saved to History first
        /// (they conflict) — sync, then restore.
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
        for attempt in 0..<2 {
            switch try await transport.restoreVersion(projectID: projectID, versionID: versionID,
                                                      baseRevision: agreed.revision, context: context) {
            case .restored(let revision, _, _):
                let pulled = try await sync.pull(projectID: projectID, projectDirectory: dir, progress: progress)
                historyLogger.info("restored version \(versionID, privacy: .public) as revision \(revision) (\(String(describing: pulled), privacy: .public))")
                return .restored(revision: revision)
            case .conflict:
                // Someone saved meanwhile: agree with the new head (a pull —
                // this Mac has no unsynced edits now), then retry once.
                guard attempt == 0 else { return .needsSync }
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
}
