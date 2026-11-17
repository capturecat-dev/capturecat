import Foundation

// MARK: - HTTP transport

/// The API's error text from a failed response body: the JSON `error` /
/// `message` / `error_description`, else a short plain-text body (never an
/// HTML or XML page). The Mac's `AuthService.errorMessage(from:)` is this.
nonisolated enum CloudAPIErrorText {
    static func message(from data: Data) -> String? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["error", "message", "error_description"] {
                if let value = json[key] as? String, !value.isEmpty {
                    return String(value.prefix(300))
                }
            }
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<") else { return nil }
        return String(trimmed.prefix(300))
    }
}

/// The API client: the app's bearer session, its API base URL, media
/// streamed from disk straight to R2 through the presigned PUTs.
///
/// Shared by the Mac and the iOS studio; each app supplies its own session
/// (the auth seam): the Mac's Keychain session and `CaptureCatAPI.baseURL`
/// through `init(baseURL:)` (Services/HTTPCloudProjectTransport+Mac.swift),
/// the iOS app's SessionStore through `init(baseURL:token:)`.
final class HTTPCloudProjectTransport: CloudProjectTransport {
    private let baseURL: String
    /// The session bearer token, read at every request (nil = signed out).
    private let token: () -> String?

    init(baseURL: String, token: @escaping () -> String?) {
        self.baseURL = baseURL
        self.token = token
    }

    func request(_ method: String, _ path: String) throws -> URLRequest {
        guard let token = token() else { throw CloudSyncError.notSignedIn }
        guard let url = URL(string: "\(baseURL)/api/cloud-projects\(path)") else { throw CloudSyncError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("capturecat-v1-9f3a7c2e", forHTTPHeaderField: "X-App-Token")
        request.timeoutInterval = 120
        return request
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudSyncError.invalidResponse }
        return (data, http)
    }

    func apiError(_ data: Data, _ http: HTTPURLResponse) -> CloudSyncError {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let message = CloudAPIErrorText.message(from: data) ?? "HTTP \(http.statusCode)"
        return .api(status: http.statusCode, code: json?["code"] as? String, message: message)
    }

    func json(_ data: Data) throws -> [String: Any] {
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
            files: Self.remoteFiles(object["files"]),
            updatedAt: CloudAPIDate.parse(object["updatedAt"])
        )
    }

    func files(projectID: UUID) async throws -> [CloudRemoteFile] {
        let request = try request("GET", "/\(projectID.uuidString)/files")
        let (data, http) = try await send(request)
        guard http.statusCode == 200 else { throw apiError(data, http) }
        return Self.remoteFiles(try json(data)["files"])
    }

    /// The API's `files` array (presignFiles in routes/cloud-projects.ts).
    static func remoteFiles(_ value: Any?) -> [CloudRemoteFile] {
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

    func save(projectID: UUID, document: Data, baseRevision: Int, context: CloudSaveContext) async throws -> CloudSaveResult {
        var request = try request("PUT", "/\(projectID.uuidString)/project")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(baseRevision)\"", forHTTPHeaderField: "If-Match")
        // History headers (docs/project-history.md §6); servers without
        // project history ignore them.
        for (name, value) in context.headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = document
        let (data, http) = try await send(request)
        if http.statusCode == 409, let object = try? json(data), object["code"] as? String == "revision_conflict" {
            return .conflict(Self.conflict(object))
        }
        guard http.statusCode == 200 else { throw apiError(data, http) }
        let object = try json(data)
        guard let revision = (object["revision"] as? NSNumber)?.intValue,
              let sha = object["documentSha256"] as? String else { throw CloudSyncError.invalidResponse }
        return .saved(revision: revision, documentSHA256: sha, version: Self.savedVersion(object["version"]))
    }

    /// The 409 body: `{code: "revision_conflict", revision, documentSha256, updatedAt, document}`.
    static func conflict(_ object: [String: Any]) -> CloudConflict {
        CloudConflict(
            revision: (object["revision"] as? NSNumber)?.intValue ?? 0,
            document: (object["document"] as? String).map { Data($0.utf8) },
            documentSHA256: object["documentSha256"] as? String,
            updatedAt: CloudAPIDate.parse(object["updatedAt"]),
            headVersionID: CloudJSON.string(object["headVersionId"])
        )
    }

    /// `version: {id, seq, extended}` (absent before project history).
    static func savedVersion(_ value: Any?) -> CloudSavedVersion? {
        guard let object = value as? [String: Any], let id = CloudJSON.string(object["id"]) else { return nil }
        return CloudSavedVersion(id: id, seq: CloudJSON.int(object["seq"]) ?? 0,
                                 extended: object["extended"] as? Bool ?? false)
    }

    func revisionDocument(projectID: UUID, revision: Int) async throws -> Data? {
        let request = try request("GET", "/\(projectID.uuidString)/revisions/\(revision)/document")
        let (data, http) = try await send(request)
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else { throw apiError(data, http) }
        return CloudHistoryParse.revisionDocument(data)
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
