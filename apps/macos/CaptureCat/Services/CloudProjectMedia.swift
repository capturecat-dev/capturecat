import Foundation
import os

private let mediaLogger = Logger(subsystem: "so.capturecat.CaptureCat", category: "CloudProjectSync")

// MARK: - Which file a reference names

/// A cloud project's files, indexed the way the web editor resolves a
/// project.json reference — `resolveMediaRef` in
/// apps/web/src/editor/state/cloud.ts, step for step, so the Mac and the web
/// agree on which file a reference names:
///
///   exact `source` → the logical path itself → the decoded path of a
///   `file://` URL (as a source) → the project-relative tail of a
///   `…/CaptureCat/Projects/<id>/<rest>` path (source, then path) → the last
///   path component (source, then path).
nonisolated struct CloudFileIndex {
    private var byPath: [String: CloudRemoteFile] = [:]
    private var bySource: [String: String] = [:]

    init(_ files: [CloudRemoteFile]) {
        for file in files {
            byPath[file.path] = file
            if let source = file.source { bySource[source] = file.path }
        }
    }

    /// This Mac's own manifest, indexed the same way.
    init(_ manifest: CloudManifest) {
        self.init(manifest.files.map {
            CloudRemoteFile(path: $0.path, sha256: $0.sha256, bytes: $0.bytes, contentType: $0.contentType,
                            source: $0.source, url: nil)
        })
    }

    private func lookup(_ key: String) -> CloudRemoteFile? {
        if let path = bySource[key] { return byPath[path] }
        return byPath[key]
    }

    func resolve(_ reference: String?) -> CloudRemoteFile? {
        guard let reference, !reference.isEmpty else { return nil }
        if let hit = lookup(reference) { return hit }
        var path = reference
        if reference.hasPrefix("file://") {
            guard let url = URL(string: reference) else { return nil }
            path = url.path
        }
        if let hit = bySource[path].flatMap({ byPath[$0] }) { return hit }
        if let marker = path.range(of: "/CaptureCat/Projects/") {
            // …/Projects/<UUID>/<relative path>
            let rest = path[marker.upperBound...].components(separatedBy: "/").dropFirst().joined(separator: "/")
            if !rest.isEmpty, let hit = lookup(rest) { return hit }
        }
        guard let last = path.components(separatedBy: "/").last, !last.isEmpty else { return nil }
        return lookup(last)
    }
}

// MARK: - What a document references

nonisolated enum CloudDocumentReferences {
    /// Every file reference in a project.json, spelled exactly as the
    /// document spells it: the four media URLs, voice-over clip files, the
    /// watermark and curtain logos, the background image, and the two files
    /// the Mac keeps beside every project. The SAME set
    /// `CloudProjectManifest.references(for:)` collects from the model — the
    /// `--cloud-sync-test` harness proves the two agree on its fixture.
    /// Read from the raw JSON (not the Codable) so a web document with keys
    /// this build does not know is still understood. Nil when the document is
    /// not a JSON object.
    static func strings(in document: Data) -> [String]? {
        guard let object = (try? JSONSerialization.jsonObject(with: document)) as? [String: Any] else { return nil }
        var out: [String] = []
        for key in ["videoURL", "cursorDataURL", "keystrokeDataURL", "cameraVideoURL"] {
            if let value = object[key] as? String, !value.isEmpty { out.append(value) }
        }
        for clip in object["voiceOverClips"] as? [[String: Any]] ?? [] {
            if let name = clip["fileName"] as? String, !name.isEmpty { out.append(name) }
        }
        if let settings = object["settings"] as? [String: Any] {
            for key in ["watermarkFileName", "curtainLogoFileName", "backgroundImagePath"] {
                if let value = settings[key] as? String, !value.isEmpty { out.append(value) }
            }
        }
        out.append(contentsOf: CloudProjectMedia.derivedFiles)
        return out
    }

    /// Logical paths of the files `document` references, resolved against
    /// `index`. Nil when the document cannot be read — callers then treat
    /// every file as referenced (never drop what cannot be ruled out).
    static func referencedPaths(by document: Data, in index: CloudFileIndex) -> Set<String>? {
        strings(in: document).map { Set($0.compactMap { index.resolve($0)?.path }) }
    }
}

// MARK: - Bringing cloud files to this Mac

nonisolated enum CloudProjectMedia {
    /// Files the Mac regenerates for itself (library thumbnail, camera
    /// poster). Fetched when missing, never replaced: this Mac's copy is at
    /// least as current as the cloud's.
    static let derivedFiles = ["camera_poster.png", "thumbnail.jpg"]

    /// Prefix of in-flight downloads in the project folder: hidden, so never
    /// part of a manifest, and on the project's volume, so the final rename
    /// is atomic.
    static let partialPrefix = ".cloudsync-"

    struct Download: Sendable {
        var file: CloudRemoteFile
        let destination: URL
        /// An existing file with different bytes — only swapped in once every
        /// file the document needs has arrived.
        let replaces: Bool
    }

    /// Where a manifest `source` points on this Mac: an absolute path, a
    /// file URL, or a path relative to the project folder (a converted
    /// HEIC's original). Nil when it cannot be a local file.
    static func localURL(forSource source: String, in directory: URL) -> URL? {
        if source.hasPrefix("file://") { return URL(string: source).flatMap { $0.isFileURL ? $0 : nil } }
        if source.hasPrefix("/") { return URL(fileURLWithPath: source) }
        guard !source.split(separator: "/").contains("..") else { return nil }
        return directory.appendingPathComponent(source)
    }

    static func isInside(_ url: URL, _ directory: URL) -> Bool {
        let dir = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path == dir || path.hasPrefix(dir.hasSuffix("/") ? dir : dir + "/")
    }

    /// Where this Mac holds the file `reference` names (per `index`), inside
    /// or beside the project: the Mac's own original when the entry was a
    /// converted/external upload and that original is here, else the
    /// downloaded copy at its logical path. Nil when neither exists.
    static func localCopy(of reference: String, index: CloudFileIndex, in directory: URL) -> URL? {
        guard let file = index.resolve(reference) else { return nil }
        let fm = FileManager.default
        if let source = file.source, let original = localURL(forSource: source, in: directory),
           fm.fileExists(atPath: original.path) {
            return original
        }
        guard CloudPath.isValid(file.path) else { return nil }
        let copy = directory.appendingPathComponent(file.path)
        return fm.fileExists(atPath: copy.path) ? copy : nil
    }

    /// Which committed files to download: every one missing from the project
    /// folder, or present with a different size or SHA-256. Skipped: an
    /// entry whose `source` original is on this Mac (a HEIC this Mac uploaded
    /// converted, a wallpaper outside the folder — this Mac's own file wins),
    /// a derived file already here, and anything the API's path rules refuse
    /// (so nothing can be written outside the folder). Hashes off the main
    /// actor; `progress` gets (bytes checked, bytes to check).
    @MainActor
    static func plan(
        _ files: [CloudRemoteFile],
        projectDirectory: URL,
        progress: @escaping (Int64, Int64) -> Void = { _, _ in }
    ) async throws -> [Download] {
        let fm = FileManager.default
        var out: [Download] = []
        var toHash: [(file: CloudRemoteFile, url: URL)] = []
        var seen = Set<String>()
        for file in files where seen.insert(file.path.lowercased()).inserted {
            guard CloudPath.isValid(file.path) else {
                mediaLogger.info("cloud pull ignored invalid path \(file.path, privacy: .public)")
                continue
            }
            let destination = projectDirectory.appendingPathComponent(file.path)
            if let source = file.source, let original = localURL(forSource: source, in: projectDirectory),
               original.standardizedFileURL != destination.standardizedFileURL,
               fm.fileExists(atPath: original.path) { continue }
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: destination.path, isDirectory: &isDirectory) else {
                out.append(Download(file: file, destination: destination, replaces: false))
                continue
            }
            if derivedFiles.contains(file.path) { continue }
            let size = ((try? fm.attributesOfItem(atPath: destination.path))?[.size] as? NSNumber)?.int64Value ?? -1
            if isDirectory.boolValue || size != file.bytes {
                out.append(Download(file: file, destination: destination, replaces: true))
            } else {
                toHash.append((file, destination))
            }
        }
        let total = toHash.reduce(Int64(0)) { $0 + $1.file.bytes }
        var done: Int64 = 0
        for (file, url) in toHash {
            try Task.checkCancellation()
            let digest = try? await Task.detached(priority: .userInitiated) {
                try CloudProjectManifest.sha256(ofFileAt: url)
            }.value
            try Task.checkCancellation()
            if digest?.hex != file.sha256 {
                out.append(Download(file: file, destination: url, replaces: true))
            }
            done += file.bytes
            progress(done, total)
        }
        return out
    }

    /// Partial downloads a crashed or killed pull left behind (a running
    /// pull removes its own). Only ones an hour old: never another sync's.
    static func removeStalePartials(in directory: URL) {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(partialPrefix) && name.hasSuffix(".part") {
            let url = directory.appendingPathComponent(name)
            let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date ?? .distantPast
            if modified < Date(timeIntervalSinceNow: -3600) { try? fm.removeItem(at: url) }
        }
    }

    /// Move a verified download into place — created, or atomically swapped
    /// over the old file.
    static func commit(_ temp: URL, to destination: URL, in directory: URL) throws {
        let fm = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        guard isInside(parent, directory) else { throw CocoaError(.fileWriteNoPermission) }
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: temp)
        } else {
            try fm.moveItem(at: temp, to: destination)
        }
    }

    /// Short, user-facing reason for one failed file.
    static func describe(_ error: Error) -> String {
        switch error {
        case let sync as CloudSyncError:
            if case .api(_, _, let message) = sync { return message }
            return sync.localizedDescription
        case let integrity as IntegrityError:
            return integrity.localizedDescription
        default:
            return error.localizedDescription
        }
    }

    struct IntegrityError: LocalizedError {
        var errorDescription: String? { "the downloaded bytes did not match their checksum" }
    }
}

extension CloudProjectSync {
    /// Bring the committed cloud files this Mac lacks into the project
    /// folder, BEFORE any document that names them is applied.
    ///
    /// Each file streams to a hidden temp file in the project folder and is
    /// verified (size + SHA-256 against the manifest) before it is used. A
    /// NEW file is moved into place at once (harmless on its own, and a retry
    /// then skips it); a REPLACEMENT is held until every download is in, so a
    /// failed pull never changes a file the current document uses. If a file
    /// `document` references failed, the held replacements are discarded and
    /// `downloadFailed` is thrown — the caller must not apply the document.
    /// A failure of a file no longer referenced is logged and ignored.
    /// Returns how many files were downloaded.
    func syncMedia(
        _ files: [CloudRemoteFile],
        referencedBy document: Data,
        projectID: UUID,
        projectDirectory: URL,
        progress: @escaping (Progress) -> Void
    ) async throws -> Int {
        guard !files.isEmpty else { return 0 }
        CloudProjectMedia.removeStalePartials(in: projectDirectory)
        progress(Progress(phase: .hashing, fraction: 0, message: "Checking files…"))
        var queue = try await CloudProjectMedia.plan(files, projectDirectory: projectDirectory) { done, total in
            progress(Progress(phase: .hashing, fraction: total > 0 ? Double(done) / Double(total) : 1,
                              message: "Checking files…"))
        }
        progress(Progress(phase: .hashing, fraction: 1, message: "Checking files…"))
        guard !queue.isEmpty else { return 0 }

        let fm = FileManager.default
        let total = max(queue.reduce(Int64(0)) { $0 + $1.file.bytes }, 1)
        var received: Int64 = 0
        var downloaded = 0
        var failures: [(path: String, error: Error)] = []
        var held: [(temp: URL, destination: URL)] = []
        var partials = Set<URL>()
        defer { for url in partials { try? fm.removeItem(at: url) } }
        var refreshedAt: Int?

        func message(_ remaining: Int) -> String {
            remaining == 1 ? "Downloading 1 file…" : "Downloading \(remaining) files…"
        }
        progress(Progress(phase: .downloading, fraction: 0, message: message(queue.count)))

        var index = 0
        while index < queue.count {
            try Task.checkCancellation()
            let item = queue[index]
            let temp = projectDirectory.appendingPathComponent(
                "\(CloudProjectMedia.partialPrefix)\(UUID().uuidString).part")
            partials.insert(temp)
            let before = received
            let status = message(queue.count - index)
            do {
                try await transport.download(item.file, to: temp) { bytes in
                    let fraction = Double(before + min(max(bytes, 0), item.file.bytes)) / Double(total)
                    progress(Progress(phase: .downloading, fraction: min(fraction, 1), message: status))
                }
                let digest = try await Task.detached(priority: .userInitiated) {
                    try CloudProjectManifest.sha256(ofFileAt: temp)
                }.value
                guard digest.bytes == item.file.bytes, digest.hex == item.file.sha256 else {
                    throw CloudProjectMedia.IntegrityError()
                }
                if item.replaces {
                    held.append((temp, item.destination))
                } else {
                    try CloudProjectMedia.commit(temp, to: item.destination, in: projectDirectory)
                    partials.remove(temp)
                }
                downloaded += 1
            } catch CloudSyncError.downloadURLExpired where refreshedAt != index {
                // A long queue outlived the 15-minute presigns: re-sign
                // (GET …/files) and retry this file, once per file.
                try? fm.removeItem(at: temp)
                partials.remove(temp)
                refreshedAt = index
                let fresh = Dictionary(try await transport.files(projectID: projectID).map { ($0.path, $0) },
                                       uniquingKeysWith: { first, _ in first })
                for i in index..<queue.count {
                    if let file = fresh[queue[i].file.path], file.sha256 == queue[i].file.sha256 { queue[i].file = file }
                }
                continue
            } catch {
                try? fm.removeItem(at: temp)
                partials.remove(temp)
                if Task.isCancelled { throw CancellationError() }
                failures.append((item.file.path, error))
            }
            received += item.file.bytes
            index += 1
            progress(Progress(phase: .downloading, fraction: min(Double(received) / Double(total), 1),
                              message: message(queue.count - index)))
        }

        if !failures.isEmpty {
            let referenced = CloudDocumentReferences.referencedPaths(by: document, in: CloudFileIndex(files))
            let fatal = failures.filter { referenced?.contains($0.path) ?? true }
            for failure in failures where !fatal.contains(where: { $0.path == failure.path }) {
                mediaLogger.info("cloud pull skipped unreferenced \(failure.path, privacy: .public): \(String(describing: failure.error), privacy: .public)")
            }
            if let first = fatal.first {
                // `partials` (deferred) removes the held replacements too.
                throw CloudSyncError.downloadFailed(paths: fatal.map(\.path),
                                                   detail: CloudProjectMedia.describe(first.error))
            }
        }
        for (temp, destination) in held {
            try CloudProjectMedia.commit(temp, to: destination, in: projectDirectory)
            partials.remove(temp)
        }
        mediaLogger.info("cloud pull downloaded \(downloaded) file(s) into \(projectID.uuidString, privacy: .public)")
        return downloaded
    }

    /// Files only the cloud holds that this push must keep: the web editor
    /// added them (a voice-over take, a background or logo image) and a
    /// document still uses them — the one being pushed, or the one the cloud
    /// serves now (which this push may not replace: cloudIsNewer, conflict).
    /// A reference this Mac's own manifest already satisfies never keeps the
    /// cloud's copy (this Mac's file supersedes it). Kept entries are never
    /// uploaded: the server already holds their objects. Everything else the
    /// cloud holds and no document names is dropped — finalize collects it.
    static func cloudOnlyFiles(
        _ remote: [CloudRemoteFile],
        localManifest manifest: CloudManifest,
        referencedBy documents: [Data?]
    ) -> [CloudManifestFile] {
        let cloud = CloudFileIndex(remote)
        let local = CloudFileIndex(manifest)
        var keep = Set<String>()
        var keepEverything = false
        for document in documents.compactMap({ $0 }) {
            guard let refs = CloudDocumentReferences.strings(in: document) else {
                keepEverything = true // unreadable: rule nothing out
                continue
            }
            for ref in refs where local.resolve(ref) == nil {
                if let file = cloud.resolve(ref) { keep.insert(file.path) }
            }
        }
        let localPaths = Set(manifest.files.map { $0.path.lowercased() })
        let localSources = Set(manifest.files.compactMap(\.source))
        var sizes = Dictionary(manifest.files.map { ($0.sha256, $0.bytes) }, uniquingKeysWith: { first, _ in first })
        var out: [CloudManifestFile] = []
        var seen = Set<String>()
        for file in remote {
            guard keepEverything || keep.contains(file.path),
                  !localPaths.contains(file.path.lowercased()), seen.insert(file.path.lowercased()).inserted,
                  file.source.map({ !localSources.contains($0) }) ?? true,
                  CloudPath.isValid(file.path), CloudPath.accepts(file.contentType, for: file.path),
                  file.bytes <= CloudPath.maxBytes(for: file.path) else { continue }
            if let known = sizes[file.sha256], known != file.bytes { continue }
            sizes[file.sha256] = file.bytes
            out.append(CloudManifestFile(path: file.path, sha256: file.sha256, bytes: file.bytes,
                                         contentType: file.contentType, source: file.source, localURL: nil))
        }
        return out
    }
}
