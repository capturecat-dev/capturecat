import Foundation
import os

private let shareLogger = Logger(subsystem: "so.capturecat.CaptureCat", category: "ShareService")

@MainActor
@Observable
final class ShareService {
    enum ShareState: Equatable {
        case idle
        /// Browser-card shares export first — only ShareJobCenter sets this.
        case exporting(progress: Double)
        case uploading(progress: Double)
        case completing
        case done(shareURL: String)
        case failed(String)
    }

    var state: ShareState = .idle

    var isActive: Bool {
        switch state {
        case .uploading, .completing: return true
        default: return false
        }
    }

    // MARK: - Upload Flow

    /// Full upload flow: get presigned URL → upload to R2 → confirm → return
    /// share URL. Network steps live in ShareUploadAPI, shared with the
    /// background ShareJobCenter — one implementation for both paths.
    ///
    /// `commentsEnabled` opts the share page into viewer comments;
    /// `annotationMarkers` are the project's annotations in OUTPUT-time
    /// seconds (see ExportSheetController — they ride the same SpeedTimeMap
    /// the exporter uses, so they line up with the uploaded file).
    func upload(
        fileURL: URL,
        fileName: String,
        durationSeconds: Double,
        commentsEnabled: Bool = false,
        annotationMarkers: [[String: Any]] = [],
        projectId: UUID? = nil
    ) async {
        state = .uploading(progress: 0)

        do {
            let token = try ShareUploadAPI.sessionToken()
            let fileSize = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int ?? 0

            shareLogger.info("Requesting presigned upload URL for \(fileName, privacy: .public)")
            let (videoId, uploadUrl) = try await ShareUploadAPI.requestUploadURL(
                token: token,
                fileName: fileName,
                fileSizeBytes: fileSize,
                durationSeconds: durationSeconds,
                commentsEnabled: commentsEnabled,
                annotationMarkers: annotationMarkers,
                projectId: projectId
            )

            shareLogger.info("Uploading \(fileName, privacy: .public) to R2")
            try await ShareUploadAPI.uploadFile(fileURL: fileURL, to: uploadUrl) { [weak self] progress in
                Task { @MainActor in
                    self?.state = .uploading(progress: progress)
                }
            }

            state = .completing
            shareLogger.info("Confirming upload for videoId=\(videoId, privacy: .public)")
            let shareURL = try await ShareUploadAPI.confirmUpload(token: token, videoId: videoId)

            state = .done(shareURL: shareURL)
            shareLogger.info("Share complete: \(shareURL, privacy: .public)")
        } catch {
            shareLogger.error("Share failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
        }
    }

    func reset() {
        state = .idle
    }
}

// MARK: - Errors

enum ShareError: LocalizedError {
    case notSignedIn
    case apiError(String)
    case invalidResponse
    case invalidURL
    case uploadFailed(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return String(localized: "You must be signed in to share videos.", comment: "Share error: sharing needs a signed-in account")
        case .apiError(let message):
            return String(localized: "API error: \(message)", comment: "Share error; the placeholder is the server's message")
        case .invalidResponse:
            return String(localized: "Received an invalid response from the server.", comment: "Share error: the server reply could not be read")
        case .invalidURL:
            return String(localized: "Invalid upload URL.", comment: "Share error: the server gave an unusable upload address")
        case .uploadFailed(let message):
            return String(localized: "Upload failed: \(message)", comment: "Share error; the placeholder is the upload error detail")
        }
    }
}
