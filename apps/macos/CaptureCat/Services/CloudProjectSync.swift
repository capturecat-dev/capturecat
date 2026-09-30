import CryptoKit
import Foundation
import os

private let cloudLogger = Logger(subsystem: "so.capturecat.CaptureCat", category: "CloudProjectSync")

// MARK: - Web editor URL

extension CaptureCatAPI {
    /// Prefix of the web editor route; the project id is appended.
    ///
    /// Release: https://app.capturecat.so/editor (the web Worker maps the app
    /// host onto its /app routes). Debug follows the API: against the local
    /// `wrangler dev` API it opens the local web dev server (TanStack Start on
    /// :3200, where the same route lives at /app/editor); against a remote API
    /// it opens production. Override without rebuilding (Debug only, https or
    /// loopback — same rule as `apiBaseURL`):
    ///   defaults write so.capturecat.CaptureCat webEditorBaseURL http://localhost:3201/app/editor
    nonisolated static var webEditorBaseURL: String {
        #if DEBUG
        if let override = UserDefaults.standard.string(forKey: "webEditorBaseURL"),
           let url = URL(string: override), let host = url.host,
           url.scheme == "https" || host == "localhost" || host == "127.0.0.1" {
            return override.hasSuffix("/") ? String(override.dropLast()) : override
        }
        if let host = URL(string: baseURL)?.host, host == "localhost" || host == "127.0.0.1" {
            return "http://localhost:3200/app/editor"
        }
        #endif
        return "https://app.capturecat.so/editor"
    }

    nonisolated static func webEditorURL(projectID: UUID) -> URL {
        URL(string: "\(webEditorBaseURL)/\(projectID.uuidString)")!
    }
}

// MARK: - Logical paths (mirror of apps/api/src/lib/cloud-projects.ts)

/// The API's path + content-type rules, mirrored so the app never stages a
/// manifest the server will refuse. Source of truth: `CLOUD_FILE_TYPES` and
/// `checkLogicalPath` in apps/api/src/lib/cloud-projects.ts — keep in step.
nonisolated enum CloudPath {
    /// Extension → every content type the server accepts for it; the FIRST
    /// is the canonical one this Mac sends for its own files. The others
    /// arrive on files the web editor added (Firefox records voice-overs as
    /// `.wav`, some browsers label them `audio/x-wav`) and are passed back
    /// unchanged when a push keeps those files.
    static let acceptedTypes: [String: [String]] = [
        "mov": ["video/quicktime"], "mp4": ["video/mp4"], "m4v": ["video/mp4", "video/x-m4v"],
        "m4a": ["audio/mp4", "audio/x-m4a"], "aac": ["audio/aac"], "mp3": ["audio/mpeg"],
        "wav": ["audio/wav", "audio/x-wav"], "caf": ["audio/x-caf"],
        "png": ["image/png"], "jpg": ["image/jpeg"], "jpeg": ["image/jpeg"], "heic": ["image/heic"],
        "webp": ["image/webp"], "gif": ["image/gif"],
        "json": ["application/json"],
    ]

    /// Extension → the canonical content type the server accepts for it.
    static let contentTypes: [String: String] = acceptedTypes.compactMapValues(\.first)

    /// Files per manifest (`MAX_MANIFEST_FILES` on the server).
    static let maxManifestFiles = 200

    static func contentType(for path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        return contentTypes[ext]
    }

    /// Whether the server accepts `contentType` for `path`'s extension.
    static func accepts(_ contentType: String, for path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return acceptedTypes[ext]?.contains(contentType.lowercased()) == true
    }

    /// Per-kind ceiling (`KIND_MAX_BYTES` on the server), independent of the
    /// plan. A reference over it is skipped up front — one oversized
    /// wallpaper must not fail the whole sync with a 413.
    static func maxBytes(for path: String) -> Int64 {
        switch contentType(for: path)?.split(separator: "/").first {
        case "image": return 64 << 20
        case "audio": return 1 << 30
        case "application": return 512 << 20
        default: return 5 << 30
        }
    }

    /// Relative, ≤ 4 segments, every segment starts alphanumeric (no `.`/`..`,
    /// no hidden files) and uses only `A-Za-z0-9 ._()+@,-`, an allowed
    /// extension, and never project.json itself.
    static func isValid(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 255, path.lowercased() != "project.json" else { return false }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count <= 4 else { return false }
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 ._()+@,-")
        for segment in segments {
            guard let first = segment.first, segment.count <= 128,
                  first.isASCII, first.isLetter || first.isNumber,
                  segment.allSatisfy({ allowed.contains($0) }) else { return false }
        }
        return contentType(for: path) != nil
    }
}

// MARK: - Manifest

/// One file of a project bundle, hashed.
nonisolated struct CloudManifestFile: Equatable, Sendable {
    /// Logical path relative to the project folder (`recording.mov`, …), or
    /// `external/<sha12>.<ext>` for a file referenced from outside it.
    let path: String
    let sha256: String
    let bytes: Int64
    let contentType: String
    /// The reference exactly as project.json spells it, when that is not
    /// simply `path` (an absolute backgroundImagePath, a media URL that points
    /// outside the project folder). The web resolves references through it.
    let source: String?
    /// Where the bytes are on this Mac. Nil for a file only the cloud holds
    /// (one the web editor added), which a push keeps in the manifest
    /// without ever uploading it.
    let localURL: URL?
}

nonisolated struct CloudManifest: Sendable {
    var files: [CloudManifestFile]
    /// References that could not be included (missing on disk, unsupported
    /// type) — surfaced, never fatal: the web shows what it has.
    var skipped: [String]

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }

    func localURL(forSHA256 sha: String) -> URL? {
        files.first { $0.sha256 == sha && $0.localURL != nil }?.localURL
    }
}

/// What a project references on disk — collected from the model (main actor),
/// then hashed off-main.
nonisolated struct CloudFileReference: Equatable, Sendable {
    let localURL: URL
    /// Path relative to the project folder, nil when the file lives outside it.
    let relativePath: String?
    /// Set for references outside the folder: the exact project.json string.
    let source: String?
}

enum CloudProjectManifest {
    /// Every file the project references: the four media URLs, voice-over
    /// clips, the watermark and curtain logos, the background image, plus the
    /// camera poster and thumbnail when present. Order is stable; duplicates
    /// collapse. project.json itself is never a file (it has its own endpoint).
    static func references(for project: Project, projectDirectory: URL) -> [CloudFileReference] {
        let fm = FileManager.default
        var out: [CloudFileReference] = []
        var seen = Set<String>()

        func add(_ url: URL?, source: String? = nil) {
            guard let url, url.isFileURL else { return }
            let standardized = url.standardizedFileURL.resolvingSymlinksInPath()
            guard fm.fileExists(atPath: standardized.path), seen.insert(standardized.path).inserted else { return }
            let relative = relativePath(of: standardized, in: projectDirectory)
            out.append(CloudFileReference(
                localURL: standardized,
                relativePath: relative,
                source: relative == nil ? (source ?? url.absoluteString) : nil
            ))
        }

        add(project.videoURL)
        add(project.cursorDataURL)
        add(project.keystrokeDataURL)
        add(project.cameraVideoURL)
        for clip in project.voiceOverClips {
            add(clip.resolvedURL(in: projectDirectory))
        }
        add(project.watermarkImageURL)
        add(project.curtainLogoImageURL)
        if let path = project.settings.backgroundImagePath, !path.isEmpty {
            add(URL(fileURLWithPath: path), source: path)
        }
        add(projectDirectory.appendingPathComponent("camera_poster.png"))
        add(projectDirectory.appendingPathComponent("thumbnail.jpg"))
        return out
    }

    /// `file` relative to `directory`, or nil when it is not inside it.
    nonisolated static func relativePath(of file: URL, in directory: URL) -> String? {
        let dir = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let path = file.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = dir.hasSuffix("/") ? dir : dir + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let relative = String(path.dropFirst(prefix.count))
        return relative.isEmpty ? nil : relative
    }

    /// Streaming SHA-256 (4 MiB chunks — a multi-GB recording never sits in
    /// memory). Returns lowercase hex and the byte count actually read.
    nonisolated static func sha256(ofFileAt url: URL) throws -> (hex: String, bytes: Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        while true {
            let chunk: Data = try autoreleasepool { try handle.read(upToCount: 4 << 20) ?? Data() }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            total += Int64(chunk.count)
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), total)
    }

    nonisolated static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Hash every reference OFF the main actor and assign logical paths.
    /// `progress` gets (bytes hashed, total bytes) on the main actor.
    static func build(
        project: Project,
        projectDirectory: URL,
        progress: @escaping (Int64, Int64) -> Void = { _, _ in }
    ) async throws -> CloudManifest {
        let refs = references(for: project, projectDirectory: projectDirectory)
        return try await hash(refs, progress: progress)
    }

    static func hash(
        _ refs: [CloudFileReference],
        progress: @escaping (Int64, Int64) -> Void = { _, _ in }
    ) async throws -> CloudManifest {
        let sizes = refs.map { ref -> Int64 in
            let attrs = try? FileManager.default.attributesOfItem(atPath: ref.localURL.path)
            return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        }
        let total = sizes.reduce(0, +)
        var done: Int64 = 0
        var manifest = CloudManifest(files: [], skipped: [])
        var paths = Set<String>()
        for (index, ref) in refs.enumerated() {
            try Task.checkCancellation()
            var url = ref.localURL
            var fileSize = sizes[index]
            // Images no browser can decode (HEIC wallpapers, TIFF/BMP logos)
            // upload as a converted PNG/JPEG copy — decided owner-side
            // 2026-09-30. The original stays untouched; `source` maps the
            // project.json reference onto the converted file for the web.
            var converted = false
            if CloudImageTranscoder.needsTranscode(url) {
                do {
                    let original = url
                    let output = try await Task.detached(priority: .userInitiated) {
                        let digest = try CloudProjectManifest.sha256(ofFileAt: original)
                        return try CloudImageTranscoder.webCompatibleCopy(of: original, sourceSHA256: digest.hex)
                    }.value
                    url = output.url
                    fileSize = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?
                        .int64Value ?? fileSize
                    converted = true
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    manifest.skipped.append(ref.relativePath ?? url.path)
                    done += sizes[index]
                    progress(done, total)
                    continue
                }
            }
            // Type + size gates BEFORE hashing: a skipped file costs nothing.
            let probePath = converted
                ? "external/x.\(url.pathExtension.lowercased())"
                : (ref.relativePath ?? "external/x.\(url.pathExtension.lowercased())")
            guard CloudPath.contentType(for: probePath) != nil, fileSize <= CloudPath.maxBytes(for: probePath) else {
                manifest.skipped.append(ref.relativePath ?? url.path)
                done += sizes[index]
                progress(done, total)
                continue
            }
            let digest: (hex: String, bytes: Int64)
            do {
                digest = try await Task.detached(priority: .userInitiated) {
                    try CloudProjectManifest.sha256(ofFileAt: url)
                }.value
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Unreadable (sandbox, permissions, vanished mid-sync): the
                // web simply lacks this one reference — never fail the sync.
                manifest.skipped.append(ref.relativePath ?? url.path)
                done += sizes[index]
                progress(done, total)
                continue
            }
            done += sizes[index]
            progress(done, total)

            let path: String
            if let relative = ref.relativePath {
                // A converted in-folder image keeps its name + the new
                // extension (`bg.heic.png`), mapped back via `source`.
                path = converted ? "\(relative).\(url.pathExtension.lowercased())" : relative
            } else {
                // Outside the folder: named by content, so two different
                // external files can never collide on a path.
                let ext = url.pathExtension.lowercased()
                path = "external/\(digest.hex.prefix(12)).\(ext)"
            }
            guard CloudPath.isValid(path), let type = CloudPath.contentType(for: path) else {
                manifest.skipped.append(ref.relativePath ?? url.path)
                continue
            }
            guard paths.insert(path.lowercased()).inserted else { continue }
            manifest.files.append(CloudManifestFile(
                path: path,
                sha256: digest.hex,
                bytes: digest.bytes,
                contentType: type,
                // Converted: the web resolves the ORIGINAL reference
                // (in-folder: its relative path; external: as spelled).
                source: converted ? (ref.relativePath ?? ref.source) : ref.source,
                localURL: url
            ))
        }
        return manifest
    }
}

// MARK: - Sync state (sidecar)

/// What this Mac last agreed with the cloud: the revision it pushed or
/// pulled and the SHA-256 of project.json at that moment. Lives beside the
/// project as a hidden `.cloudsync.json` — never inside project.json, so the
/// document itself stays exactly the Codable the app and web share.
/// Keyed by project id AND API origin: a Debug build syncing to localhost
/// never mistakes that state for production's (and a duplicated project
/// folder, which copies the sidecar, gets a new id and starts fresh).
nonisolated struct CloudSyncState: Codable, Equatable, Sendable {
    var projectID: String
    var apiBaseURL: String
    var revision: Int
    var documentSHA256: String
    var syncedAt: Date

    static let fileName = ".cloudsync.json"

    static func load(from directory: URL, projectID: UUID, apiBaseURL: String) -> CloudSyncState? {
        let url = directory.appendingPathComponent(fileName)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601 // must match save()
        guard let data = try? Data(contentsOf: url),
              let state = try? decoder.decode(CloudSyncState.self, from: data),
              state.projectID == projectID.uuidString,
              state.apiBaseURL == apiBaseURL else { return nil }
        return state
    }

    func save(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
    }
}

// MARK: - Transport

nonisolated struct CloudUploadTarget: Equatable, Sendable {
    let sha256: String
    let bytes: Int64
    let contentType: String
    let paths: [String]
    let uploadURL: URL
}

nonisolated struct CloudStageResult: Equatable, Sendable {
    /// The cloud document's revision right now (0 = never saved).
    let revision: Int
    let documentSHA256: String?
    /// Objects the cloud lacks, each with its presigned PUT.
    let missing: [CloudUploadTarget]
}

nonisolated enum CloudFinalizeResult: Equatable, Sendable {
    case committed
    /// Server verified part of a very large upload — call again.
    case verifying
    /// Some staged objects never arrived (or were collected) — restage.
    case objectsMissing
}

/// One committed file of a cloud project, as GET /cloud-projects/:id (and
/// …/files) lists it — the manifest the last finalize committed, whoever
/// staged it (this Mac, another Mac, or the web editor adding a voice-over
/// or an image).
nonisolated struct CloudRemoteFile: Equatable, Sendable {
    let path: String
    let sha256: String
    let bytes: Int64
    let contentType: String
    let source: String?
    /// Presigned GET, valid ~15 minutes (refresh through `files`).
    let url: URL?
}

nonisolated struct CloudRemoteProject: Equatable, Sendable {
    let revision: Int
    let documentSHA256: String?
    /// project.json bytes exactly as stored; nil before the first save.
    let document: Data?
    /// The committed file manifest.
    var files: [CloudRemoteFile] = []
}

nonisolated enum CloudSaveResult: Equatable, Sendable {
    case saved(revision: Int, documentSHA256: String)
    case conflict(revision: Int, document: Data?)
}

nonisolated enum CloudSyncError: LocalizedError, Equatable {
    case notSignedIn
    case api(status: Int, code: String?, message: String)
    case invalidResponse
    case uploadURLExpired
    case uploadFailed(String)
    case missingProjectFile
    case invalidRemoteDocument(String)
    case projectMismatch
    case tooManyRetries
    case downloadURLExpired
    /// Media the pulled project.json references could not be brought to
    /// this Mac. Nothing was applied.
    case downloadFailed(paths: [String], detail: String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Sign in to CaptureCat to use the web editor."
        case .api(_, _, let message): return message
        case .invalidResponse: return "The CaptureCat server sent an unexpected response."
        case .uploadURLExpired: return "An upload link expired before the file was sent."
        case .uploadFailed(let detail): return "Upload failed: \(detail)"
        case .missingProjectFile: return "This project's project.json could not be read."
        case .invalidRemoteDocument(let detail):
            return "The web editor's version could not be opened on this Mac (\(detail)). Nothing was changed."
        case .projectMismatch: return "The cloud copy belongs to a different project. Nothing was changed."
        case .tooManyRetries: return "The upload could not be completed. Try again in a moment."
        case .downloadURLExpired: return "A download link expired before the file arrived."
        case .downloadFailed(let paths, let detail):
            let names = paths.prefix(3).joined(separator: ", ") + (paths.count > 3 ? " and \(paths.count - 3) more" : "")
            let what = paths.count == 1 ? "a file" : "\(paths.count) files"
            return "The web editor’s version uses \(what) that could not be downloaded (\(names): \(detail)). "
                + "This Mac’s copy of the project was not changed — try again in a moment."
        }
    }

    /// The API's machine-readable code, when the server sent one.
    var apiCode: String? {
        if case .api(_, let code, _) = self { return code }
        return nil
    }
}

/// The network steps of a cloud sync. `HTTPCloudProjectTransport` talks to
/// the API; the `--cloud-sync-test` harness swaps in an in-memory server.
protocol CloudProjectTransport: AnyObject {
    func stage(projectID: UUID, name: String, files: [CloudManifestFile]) async throws -> CloudStageResult
    func upload(fileAt url: URL, to target: CloudUploadTarget, progress: @escaping (Int64) -> Void) async throws
    func finalize(projectID: UUID) async throws -> CloudFinalizeResult
    /// Document + committed manifest (with presigned GETs); nil = no cloud copy.
    func fetch(projectID: UUID) async throws -> CloudRemoteProject?
    /// Fresh presigned GETs for the committed manifest.
    func files(projectID: UUID) async throws -> [CloudRemoteFile]
    /// Stream one committed file's bytes to `destination` (created or
    /// truncated). Throws `downloadURLExpired` when the presign lapsed.
    func download(_ file: CloudRemoteFile, to destination: URL, progress: @escaping (Int64) -> Void) async throws
    func save(projectID: UUID, document: Data, baseRevision: Int) async throws -> CloudSaveResult
}

// MARK: - Engine

/// Mirrors a Mac project to a cloud project and back.
///
/// PUSH ("Open in Web Editor"): hash the referenced files → add the files
/// only the cloud holds that a document still uses (the web editor adds
/// voice-overs, backgrounds and logos; a stage REPLACES the manifest, so
/// leaving them out would delete them) → stage the manifest → upload only
/// what the cloud lacks (presigned PUTs, streamed from disk) → finalize
/// (server verifies size + SHA-256) → save project.json with the revision
/// this Mac last agreed with the cloud.
///
/// PULL ("Pull Web Edits"): fetch the cloud document and manifest; if it
/// moved and this Mac has no unsynced edits (or the user said to replace
/// them), validate it with the app's own Codable, download every committed
/// file this Mac lacks or holds with a different SHA-256 (verified, atomic,
/// all BEFORE the document — a failure applies nothing), and write it
/// through `ProjectFileIO` — the atomic external-edit path the GUI already
/// reloads from. See CloudProjectMedia.swift.
///
/// The document is moved as BYTES in both directions: what the web saved is
/// what lands on disk (only references to files this Mac holds elsewhere —
/// foreign media URLs, the web's background path — are re-pointed), so keys
/// this build does not know survive.
final class CloudProjectSync {
    struct Progress: Equatable {
        enum Phase: Equatable { case hashing, uploading, verifying, saving, fetching, downloading, writing }
        let phase: Phase
        /// 0…1 within the phase.
        let fraction: Double
        let message: String
    }

    enum PushOutcome: Equatable {
        /// Saved a new cloud revision.
        case pushed(revision: Int)
        /// The cloud already has exactly this document.
        case unchanged(revision: Int)
        /// This Mac has no edits since its last sync and the web moved on —
        /// nothing to push (Pull Web Edits brings the web's version here).
        case cloudIsNewer(revision: Int)
        /// Both sides changed since the last sync. Nothing was saved.
        case conflict(remoteRevision: Int)
    }

    enum PullOutcome: Equatable {
        case pulled(revision: Int)
        case upToDate(revision: Int)
        /// project.json was already this revision, but files it references
        /// were missing here (an earlier build's pull wrote only the
        /// document): `files` were downloaded, and references still spelled
        /// the web's way were re-pointed at them.
        case mediaRestored(revision: Int, files: Int)
        case noCloudCopy
        /// The cloud moved AND this Mac has edits it never sent. Nothing
        /// was written; pull again with `force` to replace them.
        case localChangesWouldBeLost(remoteRevision: Int)
    }

    let transport: CloudProjectTransport
    let apiBaseURL: String

    init(transport: CloudProjectTransport, apiBaseURL: String = CaptureCatAPI.baseURL) {
        self.transport = transport
        self.apiBaseURL = apiBaseURL
    }

    // MARK: Push

    /// `overwriteRevision`: set after the user chose "Replace Web Version" on
    /// a conflict — the save is based on that cloud revision instead of this
    /// Mac's last-synced one.
    func push(
        project: Project,
        projectDirectory: URL,
        overwriteRevision: Int? = nil,
        progress: @escaping (Progress) -> Void = { _ in }
    ) async throws -> PushOutcome {
        let docURL = projectDirectory.appendingPathComponent("project.json")
        guard let document = try? Data(contentsOf: docURL) else { throw CloudSyncError.missingProjectFile }
        let documentSHA = CloudProjectManifest.sha256(of: document)
        let projectID = project.id
        let state = CloudSyncState.load(from: projectDirectory, projectID: projectID, apiBaseURL: apiBaseURL)

        progress(Progress(phase: .hashing, fraction: 0, message: "Preparing files…"))
        // What the cloud holds now: files the web editor added exist only
        // there, and a stage REPLACES the manifest — anything it leaves out,
        // finalize deletes.
        let remote = try await transport.fetch(projectID: projectID)
        var manifest = try await CloudProjectManifest.build(project: project, projectDirectory: projectDirectory) { done, total in
            progress(Progress(phase: .hashing, fraction: total > 0 ? Double(done) / Double(total) : 1, message: "Preparing files…"))
        }
        if !manifest.skipped.isEmpty {
            cloudLogger.info("cloud push skipped \(manifest.skipped.count) reference(s): \(manifest.skipped.joined(separator: ", "), privacy: .public)")
        }
        if let remote, !remote.files.isEmpty {
            let kept = Self.cloudOnlyFiles(remote.files, localManifest: manifest, referencedBy: [document, remote.document])
            if !kept.isEmpty {
                cloudLogger.info("cloud push keeps \(kept.count) cloud-only file(s): \(kept.map(\.path).joined(separator: ", "), privacy: .public)")
                manifest.files.append(contentsOf: kept)
            }
        }
        guard manifest.files.count <= CloudPath.maxManifestFiles else {
            throw CloudSyncError.api(
                status: 400, code: "too_many_files",
                message: "This project uses \(manifest.files.count) files; the web editor takes at most \(CloudPath.maxManifestFiles).")
        }

        var stage = try await transport.stage(projectID: projectID, name: project.name, files: manifest.files)
        // A kept file whose object the cloud no longer has (collected by a
        // concurrent restage) cannot be uploaded from here: leave it out.
        let lost = Set(stage.missing.map(\.sha256).filter { manifest.localURL(forSHA256: $0) == nil })
        if !lost.isEmpty {
            let dropped = manifest.files.filter { $0.localURL == nil && lost.contains($0.sha256) }.map(\.path)
            cloudLogger.info("cloud push drops \(dropped.count) file(s) the cloud lost: \(dropped.joined(separator: ", "), privacy: .public)")
            manifest.files.removeAll { $0.localURL == nil && lost.contains($0.sha256) }
            stage = try await transport.stage(projectID: projectID, name: project.name, files: manifest.files)
        }
        try await uploadMissing(stage.missing, manifest: manifest, projectID: projectID, name: project.name, progress: progress) {
            stage = $0
        }
        try await finalize(projectID: projectID, manifest: manifest, name: project.name, progress: progress)

        // The document. Compare against the CLOUD's copy first: identical
        // bytes need no save, whoever wrote them.
        progress(Progress(phase: .saving, fraction: 0, message: "Saving project…"))
        if stage.documentSHA256 == documentSHA, stage.revision > 0 {
            try saveState(revision: stage.revision, sha: documentSHA, in: projectDirectory, projectID: projectID)
            return .unchanged(revision: stage.revision)
        }
        if overwriteRevision == nil, let state, state.documentSHA256 == documentSHA, stage.revision > state.revision {
            return .cloudIsNewer(revision: stage.revision)
        }
        let base = overwriteRevision ?? state?.revision ?? 0
        switch try await transport.save(projectID: projectID, document: document, baseRevision: base) {
        case .saved(let revision, let sha):
            try saveState(revision: revision, sha: sha, in: projectDirectory, projectID: projectID)
            progress(Progress(phase: .saving, fraction: 1, message: "Saved"))
            return .pushed(revision: revision)
        case .conflict(let revision, _):
            return .conflict(remoteRevision: revision)
        }
    }

    private func uploadMissing(
        _ initial: [CloudUploadTarget],
        manifest: CloudManifest,
        projectID: UUID,
        name: String,
        progress: @escaping (Progress) -> Void,
        restaged: (CloudStageResult) -> Void
    ) async throws {
        var queue = initial
        let total = max(initial.reduce(Int64(0)) { $0 + $1.bytes }, 1)
        var sent: Int64 = 0
        var refreshedURLs = false
        progress(Progress(phase: .uploading, fraction: 0, message: uploadMessage(queue.count)))
        while let target = queue.first {
            try Task.checkCancellation()
            guard let local = manifest.localURL(forSHA256: target.sha256) else { throw CloudSyncError.invalidResponse }
            let before = sent
            let message = uploadMessage(queue.count)
            do {
                try await transport.upload(fileAt: local, to: target) { bytes in
                    let fraction = Double(before + min(bytes, target.bytes)) / Double(total)
                    progress(Progress(phase: .uploading, fraction: min(fraction, 1), message: message))
                }
            } catch CloudSyncError.uploadURLExpired where !refreshedURLs {
                // A long queue outlived the 15-minute presigns: restage for
                // fresh URLs (the server re-signs what is still missing) and
                // carry on with only what this Mac has not sent yet.
                refreshedURLs = true
                let fresh = try await transport.stage(projectID: projectID, name: name, files: manifest.files)
                restaged(fresh)
                let remaining = Set(queue.map(\.sha256))
                queue = fresh.missing.filter { remaining.contains($0.sha256) }
                continue
            }
            sent += target.bytes
            queue.removeFirst()
            progress(Progress(phase: .uploading, fraction: Double(sent) / Double(total), message: uploadMessage(queue.count)))
        }
    }

    private func uploadMessage(_ remaining: Int) -> String {
        remaining == 1 ? "Uploading 1 file…" : "Uploading \(remaining) files…"
    }

    private func finalize(
        projectID: UUID,
        manifest: CloudManifest,
        name: String,
        progress: @escaping (Progress) -> Void
    ) async throws {
        var reuploaded = false
        for attempt in 0..<40 {
            try Task.checkCancellation()
            progress(Progress(phase: .verifying, fraction: min(Double(attempt) / 10, 0.9), message: "Verifying upload…"))
            switch try await transport.finalize(projectID: projectID) {
            case .committed:
                progress(Progress(phase: .verifying, fraction: 1, message: "Verified"))
                return
            case .verifying:
                continue
            case .objectsMissing:
                // Objects collected or never landed (a crashed earlier run):
                // restage and send them once more.
                guard !reuploaded else { throw CloudSyncError.tooManyRetries }
                reuploaded = true
                let fresh = try await transport.stage(projectID: projectID, name: name, files: manifest.files)
                try await uploadMissing(fresh.missing, manifest: manifest, projectID: projectID, name: name, progress: progress) { _ in }
            }
        }
        throw CloudSyncError.tooManyRetries
    }

    private func saveState(revision: Int, sha: String, in directory: URL, projectID: UUID) throws {
        try CloudSyncState(
            projectID: projectID.uuidString,
            apiBaseURL: apiBaseURL,
            revision: revision,
            documentSHA256: sha,
            syncedAt: Date()
        ).save(to: directory)
    }

    // MARK: Pull

    func pull(
        projectID: UUID,
        projectDirectory: URL,
        force: Bool = false,
        progress: @escaping (Progress) -> Void = { _ in }
    ) async throws -> PullOutcome {
        progress(Progress(phase: .fetching, fraction: 0, message: "Checking the web editor…"))
        guard let remote = try await transport.fetch(projectID: projectID),
              let remoteDocument = remote.document else {
            return .noCloudCopy
        }
        let docURL = projectDirectory.appendingPathComponent("project.json")
        guard let local = try? Data(contentsOf: docURL) else { throw CloudSyncError.missingProjectFile }
        let localSHA = CloudProjectManifest.sha256(of: local)
        let remoteSHA = remote.documentSHA256 ?? CloudProjectManifest.sha256(of: remoteDocument)
        let state = CloudSyncState.load(from: projectDirectory, projectID: projectID, apiBaseURL: apiBaseURL)

        // This Mac already agrees with the cloud on the document when the
        // bytes match, or when it has not edited since the last sync and that
        // sync was at least this revision (the file on disk is the re-based
        // copy of it). Then only the media may be behind: an earlier build's
        // pull wrote project.json without the files it names.
        var agreedRevision: Int?
        if remoteSHA == localSHA {
            agreedRevision = remote.revision
        } else if !force {
            // Unsynced local edits = the file changed since the last agreed
            // state (or there never was one, so nothing proves otherwise).
            let localChanged = state.map { $0.documentSHA256 != localSHA } ?? true
            if localChanged { return .localChangesWouldBeLost(remoteRevision: remote.revision) }
            if let state, state.revision >= remote.revision { agreedRevision = state.revision }
        }
        if let revision = agreedRevision {
            let fetched = try await syncMedia(remote.files, referencedBy: local, projectID: projectID,
                                              projectDirectory: projectDirectory, progress: progress)
            // A document an earlier build pulled may still name a web file
            // by the web's path — point it at the copy now here.
            let repaired = (try? Self.validatedDocument(local, projectID: projectID, projectDirectory: projectDirectory,
                                                        files: remote.files)) ?? local
            if repaired != local {
                try ProjectFileIO.writeProjectData(repaired, to: docURL)
            }
            if repaired != local || remoteSHA == localSHA {
                try saveState(revision: revision, sha: CloudProjectManifest.sha256(of: repaired),
                              in: projectDirectory, projectID: projectID)
            }
            return fetched > 0 || repaired != local
                ? .mediaRestored(revision: revision, files: fetched)
                : .upToDate(revision: revision)
        }

        // Refuse a document this Mac cannot open BEFORE moving any bytes.
        _ = try Self.checkedProject(remoteDocument, projectID: projectID)
        // Every file the web's document names lands here first — the editor
        // must never see a project.json that points at a missing file. A
        // failure throws `downloadFailed` and leaves project.json untouched.
        _ = try await syncMedia(remote.files, referencedBy: remoteDocument, projectID: projectID,
                                projectDirectory: projectDirectory, progress: progress)

        progress(Progress(phase: .writing, fraction: 0.5, message: "Applying web edits…"))
        let data = try Self.validatedDocument(remoteDocument, projectID: projectID, projectDirectory: projectDirectory,
                                              files: remote.files)
        try ProjectFileIO.writeProjectData(data, to: docURL)
        try saveState(revision: remote.revision, sha: CloudProjectManifest.sha256(of: data), in: projectDirectory, projectID: projectID)
        progress(Progress(phase: .writing, fraction: 1, message: "Pulled revision \(remote.revision)"))
        cloudLogger.info("pulled cloud revision \(remote.revision) into \(projectID.uuidString, privacy: .public)")
        return .pulled(revision: remote.revision)
    }

    /// `data` decoded by THIS build's Project Codable and bound to this
    /// project — or the reason it cannot be opened here.
    @discardableResult
    static func checkedProject(_ data: Data, projectID: UUID) throws -> Project {
        let decoded: Project
        do {
            decoded = try JSONDecoder().decode(Project.self, from: data)
        } catch {
            throw CloudSyncError.invalidRemoteDocument(String(describing: error).prefix(160).description)
        }
        guard decoded.id == projectID else { throw CloudSyncError.projectMismatch }
        return decoded
    }

    /// The web's document, proven decodable by THIS build's Project Codable
    /// and bound to this project, before it may touch disk. Returned
    /// byte-for-byte unless a reference points at a file this Mac holds
    /// somewhere else — then only those keys are re-pointed, at the JSON
    /// level so every other key (known or not) is kept:
    ///  - a media URL outside this Mac's project folder (uploaded from
    ///    another Mac, or a web recording's `file:///CaptureCat/Projects/…`)
    ///    → the committed file it names (`files`, resolved the way the web
    ///    resolves it) when that is here, else the same file name in the
    ///    project folder;
    ///  - a `backgroundImagePath` that does not exist here (the web's
    ///    `/CaptureCat/Projects/<id>/<name>`, another Mac's wallpaper) → the
    ///    absolute path of the downloaded copy — how the Mac spells a
    ///    background image.
    /// Voice-over, watermark and curtain-logo names are relative to the
    /// project folder and download under the same name: nothing to change.
    static func validatedDocument(
        _ data: Data,
        projectID: UUID,
        projectDirectory: URL,
        files: [CloudRemoteFile] = []
    ) throws -> Data {
        try checkedProject(data, projectID: projectID)
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw CloudSyncError.invalidRemoteDocument("not a JSON object")
        }

        let fm = FileManager.default
        let index = CloudFileIndex(files)
        var changed = false
        for key in ["videoURL", "cursorDataURL", "keystrokeDataURL", "cameraVideoURL"] {
            guard let raw = object[key] as? String, let url = URL(string: raw), url.isFileURL,
                  CloudProjectManifest.relativePath(of: url, in: projectDirectory) == nil else { continue }
            var local: URL?
            if !fm.fileExists(atPath: url.path) {
                local = CloudProjectMedia.localCopy(of: raw, index: index, in: projectDirectory)
            }
            if local == nil {
                let sameName = projectDirectory.appendingPathComponent(url.lastPathComponent)
                if fm.fileExists(atPath: sameName.path) { local = sameName }
            }
            if let local, local.absoluteString != raw {
                object[key] = local.absoluteString
                changed = true
            }
        }
        if var settings = object["settings"] as? [String: Any],
           let path = settings["backgroundImagePath"] as? String, !path.isEmpty, !fm.fileExists(atPath: path),
           let local = CloudProjectMedia.localCopy(of: path, index: index, in: projectDirectory), local.path != path {
            settings["backgroundImagePath"] = local.path
            object["settings"] = settings
            changed = true
        }
        guard changed else { return data }

        let out = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes])
        try checkedProject(out, projectID: projectID)
        return out
    }
}

// MARK: - HTTP transport

/// The API client: bearer session from the Keychain, `CaptureCatAPI.baseURL`,
/// media streamed from disk straight to R2 through the presigned PUTs.
final class HTTPCloudProjectTransport: CloudProjectTransport {
    private let baseURL: String

    init(baseURL: String = CaptureCatAPI.baseURL) {
        self.baseURL = baseURL
    }

    private func request(_ method: String, _ path: String) throws -> URLRequest {
        guard let token = AuthKeychain.currentToken() else { throw CloudSyncError.notSignedIn }
        guard let url = URL(string: "\(baseURL)/api/cloud-projects\(path)") else { throw CloudSyncError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("capturecat-v1-9f3a7c2e", forHTTPHeaderField: "X-App-Token")
        request.timeoutInterval = 120
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudSyncError.invalidResponse }
        return (data, http)
    }

    private func apiError(_ data: Data, _ http: HTTPURLResponse) -> CloudSyncError {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let message = AuthService.errorMessage(from: data) ?? "HTTP \(http.statusCode)"
        return .api(status: http.statusCode, code: json?["code"] as? String, message: message)
    }

    private func json(_ data: Data) throws -> [String: Any] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw CloudSyncError.invalidResponse
        }
        return object
    }

    func stage(projectID: UUID, name: String, files: [CloudManifestFile]) async throws -> CloudStageResult {
        var request = try request("PUT", "/\(projectID.uuidString)")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "name": name,
            "files": files.map { file -> [String: Any] in
                var entry: [String: Any] = [
                    "path": file.path, "sha256": file.sha256, "bytes": file.bytes, "contentType": file.contentType,
                ]
                if let source = file.source { entry["source"] = source }
                return entry
            },
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, http) = try await send(request)
        guard http.statusCode == 200 else { throw apiError(data, http) }
        let object = try json(data)
        let missing = (object["missing"] as? [[String: Any]] ?? []).compactMap { entry -> CloudUploadTarget? in
            guard let sha = entry["sha256"] as? String,
                  let bytes = (entry["bytes"] as? NSNumber)?.int64Value,
                  let type = entry["contentType"] as? String,
                  let urlString = entry["uploadUrl"] as? String,
                  let url = URL(string: urlString) else { return nil }
            return CloudUploadTarget(sha256: sha, bytes: bytes, contentType: type,
                                     paths: entry["paths"] as? [String] ?? [], uploadURL: url)
        }
        return CloudStageResult(
            revision: (object["revision"] as? NSNumber)?.intValue ?? 0,
            documentSHA256: object["documentSha256"] as? String,
            missing: missing
        )
    }

    func upload(fileAt url: URL, to target: CloudUploadTarget, progress: @escaping (Int64) -> Void) async throws {
        var request = URLRequest(url: target.uploadURL)
        request.httpMethod = "PUT"
        // Both are signed into the URL: the PUT must carry exactly this type
        // and exactly this many bytes (URLSession sets Content-Length from
        // the file) or R2 refuses the signature.
        request.setValue(target.contentType, forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600
        let delegate = CloudUploadDelegate { sent in
            Task { @MainActor in progress(sent) }
        }
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.upload(for: request, fromFile: url)
        guard let http = response as? HTTPURLResponse else { throw CloudSyncError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            // R2 answers an expired presign with 403 AccessDenied / "Request has expired".
            if http.statusCode == 403 { throw CloudSyncError.uploadURLExpired }
            throw CloudSyncError.uploadFailed("HTTP \(http.statusCode) \(text.prefix(200))")
        }
    }

    func finalize(projectID: UUID) async throws -> CloudFinalizeResult {
        let request = try request("POST", "/\(projectID.uuidString)/finalize")
        let (data, http) = try await send(request)
        switch http.statusCode {
        case 200: return .committed
        case 202: return .verifying
        case 409:
            let code = (try? json(data))?["code"] as? String
            if code == "objects_missing" { return .objectsMissing }
            if code == "manifest_changed" { return .verifying }
            throw apiError(data, http)
        default: throw apiError(data, http)
        }
    }

    func fetch(projectID: UUID) async throws -> CloudRemoteProject? {
        let request = try request("GET", "/\(projectID.uuidString)")
        let (data, http) = try await send(request)
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else { throw apiError(data, http) }
        let object = try json(data)
        return CloudRemoteProject(
            revision: (object["revision"] as? NSNumber)?.intValue ?? 0,
            documentSHA256: object["documentSha256"] as? String,
            document: (object["document"] as? String).map { Data($0.utf8) },
            files: Self.remoteFiles(object["files"])
        )
    }

    func files(projectID: UUID) async throws -> [CloudRemoteFile] {
        let request = try request("GET", "/\(projectID.uuidString)/files")
        let (data, http) = try await send(request)
        guard http.statusCode == 200 else { throw apiError(data, http) }
        return Self.remoteFiles(try json(data)["files"])
    }

    /// The API's `files` array (presignFiles in routes/cloud-projects.ts).
    private static func remoteFiles(_ value: Any?) -> [CloudRemoteFile] {
        (value as? [[String: Any]] ?? []).compactMap { entry in
            guard let path = entry["path"] as? String,
                  let sha = (entry["sha256"] as? String)?.lowercased(),
                  let bytes = (entry["bytes"] as? NSNumber)?.int64Value,
                  let type = entry["contentType"] as? String else { return nil }
            let source = (entry["source"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return CloudRemoteFile(path: path, sha256: sha, bytes: bytes, contentType: type, source: source,
                                   url: (entry["url"] as? String).flatMap(URL.init(string:)))
        }
    }

    /// A plain GET of the presigned URL — no session headers: R2 checks the
    /// signature in the query, and the bearer token must never leave for a
    /// storage host. Bytes stream to `destination` as they arrive (a
    /// multi-GB recording never sits in memory); the caller verifies size +
    /// SHA-256 before the file is used.
    func download(_ file: CloudRemoteFile, to destination: URL, progress: @escaping (Int64) -> Void) async throws {
        guard let url = file.url else { throw CloudSyncError.downloadURLExpired }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var request = URLRequest(url: url)
        request.timeoutInterval = 600
        let delegate = CloudDownloadDelegate(handle: handle) { received in
            Task { @MainActor in progress(received) }
        }
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        let outcome = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CloudDownloadDelegate.Outcome, Error>) in
                delegate.start(task, continuation: continuation)
            }
        } onCancel: {
            task.cancel()
        }
        guard (200...299).contains(outcome.status) else {
            // R2 answers an expired presign with 403 AccessDenied / "Request has expired".
            if outcome.status == 403 { throw CloudSyncError.downloadURLExpired }
            throw CloudSyncError.api(status: outcome.status, code: nil, message: "HTTP \(outcome.status)")
        }
    }

    func save(projectID: UUID, document: Data, baseRevision: Int) async throws -> CloudSaveResult {
        var request = try request("PUT", "/\(projectID.uuidString)/project")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(baseRevision)\"", forHTTPHeaderField: "If-Match")
        request.httpBody = document
        let (data, http) = try await send(request)
        if http.statusCode == 409, let object = try? json(data), object["code"] as? String == "revision_conflict" {
            return .conflict(
                revision: (object["revision"] as? NSNumber)?.intValue ?? 0,
                document: (object["document"] as? String).map { Data($0.utf8) }
            )
        }
        guard http.statusCode == 200 else { throw apiError(data, http) }
        let object = try json(data)
        guard let revision = (object["revision"] as? NSNumber)?.intValue,
              let sha = object["documentSha256"] as? String else { throw CloudSyncError.invalidResponse }
        return .saved(revision: revision, documentSHA256: sha)
    }
}

/// Byte progress for a streamed upload. Called on URLSession's delegate
/// queue — the closure hops to the main actor itself.
nonisolated final class CloudUploadDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Int64) -> Void

    init(onProgress: @escaping @Sendable (Int64) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        onProgress(totalBytesSent)
    }
}

/// Streams one presigned GET into a file handle. Every callback arrives on
/// the session's serial delegate queue, so the state below is only ever
/// touched from one thread at a time.
nonisolated final class CloudDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Outcome: Sendable {
        let status: Int
        let bytes: Int64
    }

    private let handle: FileHandle
    private let onProgress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Outcome, Error>?
    private var status = 0
    private var received: Int64 = 0
    private var writeError: Error?

    init(handle: FileHandle, onProgress: @escaping @Sendable (Int64) -> Void) {
        self.handle = handle
        self.onProgress = onProgress
    }

    func start(_ task: URLSessionDataTask, continuation: CheckedContinuation<Outcome, Error>) {
        lock.withLock { self.continuation = continuation }
        task.resume()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // An error body (403 XML…) is not the file — never written.
        guard (200...299).contains(status), writeError == nil else { return }
        do {
            try handle.write(contentsOf: data)
            received += Int64(data.count)
            onProgress(received)
        } catch {
            writeError = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let pending = lock.withLock { () -> CheckedContinuation<Outcome, Error>? in
            defer { continuation = nil }
            return continuation
        }
        if let writeError {
            pending?.resume(throwing: writeError)
        } else if let error {
            pending?.resume(throwing: error)
        } else {
            pending?.resume(returning: Outcome(status: status, bytes: received))
        }
    }
}
