import Foundation
import os

private let jobLogger = Logger(subsystem: "so.capturecat.CaptureCat", category: "ShareJobCenter")

/// Background share uploads. Starting a job returns immediately — the export
/// sheet can close, the app can be used, and progress shows on the project's
/// card in the browser. Each job is mirrored to the API's per-user ShareJobs
/// Durable Object, so the web dashboard renders the same progress the app
/// does.
@MainActor
@Observable
final class ShareJobCenter {
    struct Job: Identifiable {
        let id = UUID()
        let projectID: UUID
        let projectName: String
        var state: ShareService.ShareState
        var remoteJobID: String?

        var isActive: Bool {
            switch state {
            case .exporting, .uploading, .completing: return true
            default: return false
            }
        }
    }

    private(set) var jobs: [Job] = []
    private weak var library: ProjectLibrary?

    init(library: ProjectLibrary? = nil) {
        self.library = library
    }

    /// The most recent job for a project, if any.
    func job(for projectID: UUID) -> Job? {
        jobs.last { $0.projectID == projectID }
    }

    var hasActiveJobs: Bool { jobs.contains { $0.isActive } }

    /// Kick off a background upload. Fire and forget — all outcomes land in
    /// `jobs` (and in the library's shared marks on success).
    func start(
        projectID: UUID,
        projectName: String,
        fileURL: URL,
        durationSeconds: Double,
        commentsEnabled: Bool,
        annotationMarkers: [[String: Any]],
        transcript: [[String: Any]] = []
    ) {
        // One active job per project — a second share of the same project
        // replaces a finished record but never races an active upload.
        if let existing = job(for: projectID), existing.isActive {
            jobLogger.info("share already in flight for \(projectID.uuidString, privacy: .public)")
            return
        }
        jobs.removeAll { $0.projectID == projectID && !$0.isActive }

        let job = Job(projectID: projectID, projectName: projectName, state: .uploading(progress: 0))
        jobs.append(job)
        let localID = job.id

        Task {
            await self.runUpload(
                localID: localID, projectID: projectID, projectName: projectName,
                fileURL: fileURL, durationSeconds: durationSeconds,
                commentsEnabled: commentsEnabled, annotationMarkers: annotationMarkers,
                transcript: transcript,
                deleteFileWhenDone: false
            )
        }
    }

    /// Share straight from a project card: headless export to a temp file,
    /// then the normal background upload. The card shows both phases.
    func shareProject(
        projectID: UUID,
        projectName: String,
        durationSeconds: Double,
        annotationMarkers: [[String: Any]],
        transcript: [[String: Any]] = []
    ) {
        if let existing = job(for: projectID), existing.isActive {
            jobLogger.info("share already in flight for \(projectID.uuidString, privacy: .public)")
            return
        }
        jobs.removeAll { $0.projectID == projectID && !$0.isActive }

        let job = Job(projectID: projectID, projectName: projectName, state: .exporting(progress: 0))
        jobs.append(job)
        let localID = job.id

        let outputPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("capturecat-share-\(projectID.uuidString).mp4").path
        try? FileManager.default.removeItem(atPath: outputPath)

        Task {
            do {
                // Detached: VideoExporter blocks internally; the export sheet
                // runs it off-main for the same reason.
                let result = try await Task.detached(priority: .userInitiated) {
                    try await HeadlessRunner.performExport(
                        ref: projectID.uuidString,
                        outputPath: outputPath,
                        progress: { percent in
                            Task { @MainActor [weak self] in
                                self?.update(localID) {
                                    $0.state = .exporting(progress: Double(percent) / 100)
                                }
                            }
                        }
                    )
                }.value
                self.update(localID) { $0.state = .uploading(progress: 0) }
                await self.runUpload(
                    localID: localID, projectID: projectID, projectName: projectName,
                    fileURL: result.url, durationSeconds: durationSeconds,
                    commentsEnabled: false, annotationMarkers: annotationMarkers,
                    transcript: transcript,
                    deleteFileWhenDone: true
                )
            } catch {
                jobLogger.error("card share export failed: \(error.localizedDescription, privacy: .public)")
                self.update(localID) { $0.state = .failed(error.localizedDescription) }
            }
        }
    }

    private func runUpload(
        localID: UUID,
        projectID: UUID,
        projectName: String,
        fileURL: URL,
        durationSeconds: Double,
        commentsEnabled: Bool,
        annotationMarkers: [[String: Any]],
        transcript: [[String: Any]] = [],
        deleteFileWhenDone: Bool
    ) async {
        defer {
            if deleteFileWhenDone { try? FileManager.default.removeItem(at: fileURL) }
        }
        do {
                let token = try ShareUploadAPI.sessionToken()
                let fileSize = (try? FileManager.default
                    .attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0

                // On-device title/summary/chapters, when Apple Intelligence is
                // available — nothing leaves the Mac. The hub's Gemini button
                // covers machines without it.
                let localAI = await ShareIntelligence.localSummary(transcript: transcript)

                // A project that was shared before REPLACES its cloud video in
                // place: same videoId, same link, new version. Only if the
                // remote video is gone (deleted from the dashboard) does the
                // share fall back to minting a fresh link.
                var replaceUpload: (videoId: String, version: Int, uploadUrl: String)?
                if let existingVideoID = library?.sharedVideoID(for: projectID) {
                    do {
                        let (version, uploadUrl) = try await ShareUploadAPI.requestReplaceUploadURL(
                            token: token,
                            videoId: existingVideoID,
                            fileName: fileURL.lastPathComponent,
                            fileSizeBytes: fileSize,
                            durationSeconds: durationSeconds
                        )
                        replaceUpload = (existingVideoID, version, uploadUrl)
                    } catch {
                        jobLogger.info("replace unavailable for \(existingVideoID, privacy: .public), sharing fresh: \(error.localizedDescription, privacy: .public)")
                    }
                }

                let videoId: String
                let uploadUrl: String
                if let replaceUpload {
                    videoId = replaceUpload.videoId
                    uploadUrl = replaceUpload.uploadUrl
                } else {
                    (videoId, uploadUrl) = try await ShareUploadAPI.requestUploadURL(
                        token: token,
                        fileName: fileURL.lastPathComponent,
                        fileSizeBytes: fileSize,
                        durationSeconds: durationSeconds,
                        commentsEnabled: commentsEnabled,
                        annotationMarkers: annotationMarkers,
                        projectId: projectID,
                        transcript: transcript,
                        aiTitle: localAI?.title,
                        aiSummary: localAI?.summary,
                        aiChapters: localAI?.chapters ?? []
                    )
                }

                // Register the job server-side so the dashboard sees it too.
                // Non-fatal on failure — the upload itself must not depend on
                // the progress mirror.
                let remoteJobID = try? await ShareUploadAPI.registerJob(
                    token: token,
                    videoId: videoId,
                    projectId: projectID,
                    projectName: projectName,
                    fileName: fileURL.lastPathComponent,
                    fileSizeBytes: fileSize
                )
                self.update(localID) { $0.remoteJobID = remoteJobID }

                // Throttled remote mirror: at most one report per 2s or 5%.
                var lastReported = Date.distantPast
                var lastProgress = 0.0
                try await ShareUploadAPI.uploadFile(fileURL: fileURL, to: uploadUrl) { progress in
                    Task { @MainActor in
                        self.update(localID) { $0.state = .uploading(progress: progress) }
                        if let remoteJobID,
                           progress - lastProgress >= 0.05 || Date().timeIntervalSince(lastReported) >= 2 {
                            lastProgress = progress
                            lastReported = Date()
                            Task.detached {
                                try? await ShareUploadAPI.reportProgress(
                                    token: token, jobId: remoteJobID, progress: progress)
                            }
                        }
                    }
                }

                self.update(localID) { $0.state = .completing }
                if let remoteJobID {
                    try? await ShareUploadAPI.reportProgress(
                        token: token, jobId: remoteJobID, progress: 1, completing: true)
                }

                let shareURL: String
                if let replaceUpload {
                    // The new cut's markers/transcript/AI ride the completion —
                    // applying them earlier would describe a video that is not
                    // live yet.
                    shareURL = try await ShareUploadAPI.confirmReplace(
                        token: token,
                        videoId: videoId,
                        version: replaceUpload.version,
                        annotationMarkers: annotationMarkers,
                        transcript: transcript,
                        aiTitle: localAI?.title,
                        aiSummary: localAI?.summary,
                        aiChapters: localAI?.chapters ?? []
                    )
                } else {
                    shareURL = try await ShareUploadAPI.confirmUpload(token: token, videoId: videoId)
                }
                self.update(localID) { $0.state = .done(shareURL: shareURL) }
                self.library?.markShared(projectID, url: shareURL, videoID: videoId)
                if let remoteJobID {
                    try? await ShareUploadAPI.completeJob(
                        token: token, jobId: remoteJobID, shareUrl: shareURL)
                }
                jobLogger.info("background share complete: \(shareURL, privacy: .public)")
            } catch {
                jobLogger.error("background share failed: \(error.localizedDescription, privacy: .public)")
                self.update(localID) { $0.state = .failed(error.localizedDescription) }
                if let remoteJobID = self.jobs.first(where: { $0.id == localID })?.remoteJobID,
                   let token = try? ShareUploadAPI.sessionToken() {
                    try? await ShareUploadAPI.failJob(
                        token: token, jobId: remoteJobID, error: error.localizedDescription)
                }
            }
    }

    func dismiss(_ jobID: UUID) {
        jobs.removeAll { $0.id == jobID && !$0.isActive }
    }

    func attach(library: ProjectLibrary) {
        self.library = library
    }

    private func update(_ id: UUID, _ mutate: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        mutate(&jobs[index])
    }
}

// MARK: - Shared network steps

/// The share upload's network steps, shared by the legacy in-sheet
/// ShareService flow and ShareJobCenter — one implementation of presign,
/// PUT-to-R2, confirm, and the job-mirror endpoints.
enum ShareUploadAPI {
    static var apiBaseURL: String { CaptureCatAPI.baseURL }

    /// The Better Auth session token, read from the Keychain.
    static func sessionToken() throws -> String {
        guard let token = AuthKeychain.currentToken() else {
            throw ShareError.notSignedIn
        }
        return token
    }

    static func requestUploadURL(
        token: String,
        fileName: String,
        fileSizeBytes: Int,
        durationSeconds: Double,
        commentsEnabled: Bool,
        annotationMarkers: [[String: Any]],
        projectId: UUID?,
        transcript: [[String: Any]] = [],
        aiTitle: String? = nil,
        aiSummary: String? = nil,
        aiChapters: [[String: Any]] = []
    ) async throws -> (videoId: String, uploadUrl: String) {
        var request = URLRequest(url: URL(string: "\(apiBaseURL)/api/upload/video")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("capturecat-v1-9f3a7c2e", forHTTPHeaderField: "X-App-Token")

        var body: [String: Any] = [
            "fileName": fileName,
            "contentType": "video/mp4",
            "fileSizeBytes": fileSizeBytes,
            "durationSeconds": durationSeconds
        ]
        if commentsEnabled { body["commentsEnabled"] = true }
        if !annotationMarkers.isEmpty { body["annotations"] = annotationMarkers }
        // Lets the web dashboard deep-link back to this project
        // (capturecat://open-project?id=…).
        if let projectId { body["projectId"] = projectId.uuidString }
        if !transcript.isEmpty { body["transcript"] = transcript }
        if let aiTitle { body["aiTitle"] = aiTitle }
        if let aiSummary { body["aiSummary"] = aiSummary }
        if !aiChapters.isEmpty { body["aiChapters"] = aiChapters }
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData

        // App Attest: proves this request comes from the genuine app binary.
        // No-ops (empty headers) on unsupported hardware — never blocks.
        for (key, value) in await AppAttestService.shared.assertionHeaders(
            for: bodyData, apiBaseURL: apiBaseURL, bearerToken: token
        ) {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let text = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ShareError.apiError(text)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let videoId = json?["videoId"] as? String,
              let uploadUrl = json?["uploadUrl"] as? String else {
            throw ShareError.invalidResponse
        }

        return (videoId, uploadUrl)
    }

    static func uploadFile(
        fileURL: URL,
        to uploadUrlString: String,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        guard let uploadUrl = URL(string: uploadUrlString) else {
            throw ShareError.invalidURL
        }

        let fileData = try Data(contentsOf: fileURL)
        let totalBytes = Int64(fileData.count)

        var request = URLRequest(url: uploadUrl)
        request.httpMethod = "PUT"
        request.setValue("video/mp4", forHTTPHeaderField: "Content-Type")

        let delegate = UploadProgressDelegate { bytesSent in
            onProgress(min(Double(bytesSent) / Double(max(totalBytes, 1)), 1.0))
        }

        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let (data, response) = try await session.upload(for: request, from: fileData)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? "Upload failed"
            throw ShareError.uploadFailed(text)
        }
    }

    static func confirmUpload(token: String, videoId: String) async throws -> String {
        var request = URLRequest(url: URL(string: "\(apiBaseURL)/api/upload/video/\(videoId)/complete")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("capturecat-v1-9f3a7c2e", forHTTPHeaderField: "X-App-Token")

        // Empty body — the assertion still binds key id + counter to the call.
        for (key, value) in await AppAttestService.shared.assertionHeaders(
            for: Data(), apiBaseURL: apiBaseURL, bearerToken: token
        ) {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let text = String(data: data, encoding: .utf8) ?? "Confirm failed"
            throw ShareError.apiError(text)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let url = json?["url"] as? String else {
            throw ShareError.invalidResponse
        }

        return url
    }

    /// Presign an upload that REPLACES an existing shared video's file. The
    /// link stays the same; the old file becomes a history version.
    static func requestReplaceUploadURL(
        token: String,
        videoId: String,
        fileName: String,
        fileSizeBytes: Int,
        durationSeconds: Double
    ) async throws -> (version: Int, uploadUrl: String) {
        var request = URLRequest(
            url: URL(string: "\(apiBaseURL)/api/upload/video/\(videoId)/replace")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("capturecat-v1-9f3a7c2e", forHTTPHeaderField: "X-App-Token")

        let body: [String: Any] = [
            "fileName": fileName,
            "contentType": "video/mp4",
            "fileSizeBytes": fileSizeBytes,
            "durationSeconds": durationSeconds
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData

        for (key, value) in await AppAttestService.shared.assertionHeaders(
            for: bodyData, apiBaseURL: apiBaseURL, bearerToken: token
        ) {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let text = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ShareError.apiError(text)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let version = json?["version"] as? Int,
              let uploadUrl = json?["uploadUrl"] as? String else {
            throw ShareError.invalidResponse
        }
        return (version, uploadUrl)
    }

    /// Completes a replace upload: verifies the object server-side, flips the
    /// share link to the new version, and updates the metadata that describes
    /// the new cut.
    static func confirmReplace(
        token: String,
        videoId: String,
        version: Int,
        annotationMarkers: [[String: Any]],
        transcript: [[String: Any]],
        aiTitle: String? = nil,
        aiSummary: String? = nil,
        aiChapters: [[String: Any]] = []
    ) async throws -> String {
        var request = URLRequest(
            url: URL(string: "\(apiBaseURL)/api/upload/video/\(videoId)/replace/\(version)/complete")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("capturecat-v1-9f3a7c2e", forHTTPHeaderField: "X-App-Token")

        var body: [String: Any] = [:]
        if !annotationMarkers.isEmpty { body["annotations"] = annotationMarkers }
        if !transcript.isEmpty { body["transcript"] = transcript }
        if let aiTitle { body["aiTitle"] = aiTitle }
        if let aiSummary { body["aiSummary"] = aiSummary }
        if !aiChapters.isEmpty { body["aiChapters"] = aiChapters }
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData

        for (key, value) in await AppAttestService.shared.assertionHeaders(
            for: bodyData, apiBaseURL: apiBaseURL, bearerToken: token
        ) {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let text = String(data: data, encoding: .utf8) ?? "Confirm failed"
            throw ShareError.apiError(text)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let url = json?["url"] as? String else {
            throw ShareError.invalidResponse
        }
        return url
    }

    // MARK: Job mirror (ShareJobs Durable Object)

    private static func jobRequest(
        path: String, token: String, body: [String: Any]
    ) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "\(apiBaseURL)\(path)")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func registerJob(
        token: String,
        videoId: String,
        projectId: UUID,
        projectName: String,
        fileName: String,
        fileSizeBytes: Int
    ) async throws -> String {
        let request = try jobRequest(path: "/api/upload/jobs", token: token, body: [
            "videoId": videoId,
            "projectId": projectId.uuidString,
            "projectName": projectName,
            "fileName": fileName,
            "fileSizeBytes": fileSizeBytes,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let job = json["job"] as? [String: Any],
              let jobId = job["jobId"] as? String else {
            throw ShareError.invalidResponse
        }
        return jobId
    }

    static func reportProgress(
        token: String, jobId: String, progress: Double, completing: Bool = false
    ) async throws {
        var body: [String: Any] = ["progress": progress]
        if completing { body["completing"] = true }
        let request = try jobRequest(
            path: "/api/upload/jobs/\(jobId)/progress", token: token, body: body)
        _ = try await URLSession.shared.data(for: request)
    }

    static func completeJob(token: String, jobId: String, shareUrl: String) async throws {
        let request = try jobRequest(
            path: "/api/upload/jobs/\(jobId)/complete", token: token, body: ["shareUrl": shareUrl])
        _ = try await URLSession.shared.data(for: request)
    }

    static func failJob(token: String, jobId: String, error: String) async throws {
        let request = try jobRequest(
            path: "/api/upload/jobs/\(jobId)/fail", token: token, body: ["error": error])
        _ = try await URLSession.shared.data(for: request)
    }
}

// MARK: - Upload Progress Delegate

final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate {
    let onProgress: (Int64) -> Void

    init(onProgress: @escaping (Int64) -> Void) {
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
