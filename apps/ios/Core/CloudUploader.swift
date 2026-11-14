import CryptoKit
import Foundation

/// One file of a project being published from the phone.
nonisolated struct LocalProjectFile: Sendable {
    /// Path inside the project ("recording.mp4").
    var path: String
    var url: URL
    var contentType: String
}

nonisolated struct PublishProgress: Sendable {
    enum Phase: Sendable { case preparing, uploading, verifying, saving, done }
    var phase: Phase
    /// 0…1 within the phase.
    var fraction: Double
    var message: String
}

nonisolated enum PublishError: LocalizedError {
    case alreadyExists
    case uploadFailed(Int)
    case expired
    case notVerified

    var errorDescription: String? {
        switch self {
        case .alreadyExists: return "A project with this id is already in your library."
        case let .uploadFailed(status): return "The upload didn't finish (HTTP \(status)). Try again."
        case .expired: return "The upload took too long. Try again on a faster connection."
        case .notVerified: return "Some files didn't reach CaptureCat. Try again."
        }
    }
}

/// Publish a new cloud project — the same four steps the Mac's
/// `CloudProjectSync.push` and the web recorder's `publishTake` run:
/// hash → stage (presigned PUTs for what the cloud lacks) → upload straight
/// to storage → finalize (the server re-verifies size + SHA-256) → save
/// project.json with `If-Match` on the stage revision.
nonisolated enum CloudUploader {
    static func publish(
        projectID: String,
        name: String,
        files: [LocalProjectFile],
        document: Data,
        api: APIClient = .shared,
        progress report: @escaping @Sendable (PublishProgress) -> Void = { _ in }
    ) async throws -> Int {
        // URLSession can deliver a last upload-progress callback after the
        // upload call returned; the gate drops anything after publish ends so
        // a finished take never shows a stale "Uploading…" again.
        let gate = ProgressGate(report)
        defer { gate.close() }
        let progress: @Sendable (PublishProgress) -> Void = { gate.send($0) }

        // ── hash
        var manifest: [ManifestFile] = []
        let total = max(1, files.reduce(Int64(0)) { $0 + fileSize($1.url) })
        var hashed: Int64 = 0
        for file in files {
            let (sha, bytes) = try sha256(of: file.url) { done in
                progress(PublishProgress(phase: .preparing, fraction: Double(hashed + done) / Double(total), message: "Preparing…"))
            }
            hashed += bytes
            manifest.append(ManifestFile(path: file.path, sha256: sha, bytes: bytes, contentType: file.contentType))
        }
        let bySHA = Dictionary(manifest.enumerated().map { ($0.element.sha256, files[$0.offset]) }, uniquingKeysWith: { a, _ in a })

        // ── stage + upload (restage once if the 15-minute presigns expire)
        var stage = try await api.stage(projectID: projectID, name: name, files: manifest)
        if stage.revision > 0 {
            // This id already has a saved document: an earlier attempt got all
            // the way through (the app died before clearing the inbox). It is
            // published — and may have been edited on the Mac or web since, so
            // never save over it. (Stage reports the CURRENT revision; a save
            // "based on" it would silently win.)
            gate.finish(PublishProgress(phase: .done, fraction: 1, message: "Saved"))
            return stage.revision
        }
        var queue = stage.missing
        let uploadTotal = max(1, queue.reduce(Int64(0)) { $0 + $1.bytes })
        var sent: Int64 = 0
        var restaged = false
        while let target = queue.first {
            try Task.checkCancellation()
            guard let file = bySHA[target.sha256] else { throw PublishError.notVerified }
            let message = queue.count == 1 ? "Uploading…" : "Uploading \(queue.count) files…"
            let base = sent
            do {
                try await put(file.url, to: target) { bytes in
                    progress(PublishProgress(phase: .uploading, fraction: min(1, Double(base + bytes) / Double(uploadTotal)), message: message))
                }
            } catch PublishError.expired where !restaged {
                restaged = true
                stage = try await api.stage(projectID: projectID, name: name, files: manifest)
                let done = Set(manifest.map(\.sha256)).subtracting(queue.map(\.sha256))
                queue = stage.missing.filter { !done.contains($0.sha256) }
                continue
            }
            sent += target.bytes
            queue.removeFirst()
        }

        // ── finalize (bounded verification per request: call while "verifying")
        progress(PublishProgress(phase: .verifying, fraction: 0, message: "Checking upload…"))
        var committed = false
        for attempt in 0..<60 {
            try Task.checkCancellation()
            do {
                committed = try await api.finalize(projectID: projectID)
            } catch let error as APIError where error.code == "objects_missing" {
                throw PublishError.notVerified
            }
            if committed { break }
            progress(PublishProgress(phase: .verifying, fraction: min(0.95, Double(attempt + 1) / 10), message: "Checking upload…"))
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        guard committed else { throw PublishError.notVerified }

        // ── project.json (first save: based on the stage revision, 0 when new)
        progress(PublishProgress(phase: .saving, fraction: 0, message: "Saving…"))
        switch try await api.saveProject(projectID, document: document, baseRevision: stage.revision) {
        case let .saved(revision):
            gate.finish(PublishProgress(phase: .done, fraction: 1, message: "Saved"))
            return revision
        case .conflict:
            // Never overwrite a document someone else saved under this id.
            throw PublishError.alreadyExists
        }
    }

    // MARK: Helpers

    static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Streamed SHA-256 (lowercase hex) + byte count; never loads the file.
    static func sha256(of url: URL, onBytes: (Int64) -> Void = { _ in }) throws -> (String, Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var count: Int64 = 0
        while true {
            let chunk = try autoreleasepool { try handle.read(upToCount: 4 * 1024 * 1024) } ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            count += Int64(chunk.count)
            onBytes(count)
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), count)
    }

    /// One presigned PUT straight to storage, with byte progress.
    static func put(_ file: URL, to target: UploadTarget, onBytes: @escaping @Sendable (Int64) -> Void) async throws {
        var request = URLRequest(url: target.uploadUrl)
        request.httpMethod = target.method
        for (key, value) in target.headers { request.setValue(value, forHTTPHeaderField: key) }
        request.timeoutInterval = 600
        let delegate = UploadProgressDelegate(onBytes: onBytes)
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: file, delegate: delegate)
        guard let http = response as? HTTPURLResponse else { throw PublishError.uploadFailed(0) }
        if (200..<300).contains(http.statusCode) { return }
        // Storage answers an expired presign with 403 "Request has expired".
        if http.statusCode == 403, String(decoding: data, as: UTF8.self).range(of: "expired", options: .caseInsensitive) != nil {
            throw PublishError.expired
        }
        throw PublishError.uploadFailed(http.statusCode)
    }
}

/// Forwards progress until closed; `finish` sends one last value and closes.
private nonisolated final class ProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = true
    private let report: @Sendable (PublishProgress) -> Void

    init(_ report: @escaping @Sendable (PublishProgress) -> Void) {
        self.report = report
    }

    func send(_ p: PublishProgress) {
        lock.lock(); defer { lock.unlock() }
        if open { report(p) }
    }

    func finish(_ p: PublishProgress) {
        lock.lock(); defer { lock.unlock() }
        if open { report(p) }
        open = false
    }

    func close() {
        lock.lock(); open = false; lock.unlock()
    }
}

private nonisolated final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let onBytes: @Sendable (Int64) -> Void

    init(onBytes: @escaping @Sendable (Int64) -> Void) {
        self.onBytes = onBytes
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        onBytes(totalBytesSent)
    }
}
