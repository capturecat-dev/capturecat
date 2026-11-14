import Foundation

// Shapes of the API responses the iOS app reads. Field names match the API
// byte for byte (apps/api/src/routes/*.ts); anything the app does not use is
// simply not decoded, so additive API changes never break an installed app.

/// `GET /api/me`.
nonisolated struct AccountInfo: Sendable, Equatable {
    var uid: String
    var email: String?
    var tier: String
    var planName: String
    var planDisplayName: String
    var features: [String: Bool]
    var storageLimitBytes: Int64?
    var sessionExpiresAt: Date?

    init(json: [String: Any]) {
        uid = json["uid"] as? String ?? ""
        email = json["email"] as? String
        tier = json["tier"] as? String ?? "free"
        let plan = json["plan"] as? [String: Any]
        planName = plan?["name"] as? String ?? tier
        planDisplayName = plan?["displayName"] as? String ?? tier.capitalized
        features = (json["features"] as? [String: Any] ?? [:]).compactMapValues { $0 as? Bool }
        storageLimitBytes = ((json["limits"] as? [String: Any])?["maxTotalStorageBytes"] as? NSNumber)?.int64Value
        sessionExpiresAt = (json["sessionExpiresAt"] as? String).flatMap(ISO8601.parse)
    }
}

/// One row of `GET /api/cloud-projects`.
nonisolated struct CloudProjectSummary: Decodable, Sendable, Equatable, Hashable {
    var projectId: String
    var name: String
    var revision: Int
    var hasDocument: Bool
    var documentSha256: String?
    var totalBytes: Int64
    var orgId: String?
    var isOwner: Bool
    var createdAt: Date
    var updatedAt: Date
}

nonisolated struct StorageUsage: Decodable, Sendable, Equatable {
    var usedBytes: Int64
    var limitBytes: Int64
}

nonisolated struct CloudProjectList: Decodable, Sendable {
    var projects: [CloudProjectSummary]
    var storage: StorageUsage?
}

/// A committed file with a short-lived presigned GET.
nonisolated struct CloudRemoteFile: Decodable, Sendable, Equatable {
    var path: String
    var sha256: String
    var bytes: Int64
    var contentType: String
    var source: String?
    var url: URL
}

/// `GET /api/cloud-projects/:id`.
nonisolated struct CloudProjectDetail: Decodable, Sendable {
    var projectId: String
    var name: String
    var revision: Int
    var access: String
    /// The raw project.json text exactly as last saved (nil before the first save).
    var document: String?
    var files: [CloudRemoteFile]
    var urlsExpireAt: Date
    var updatedAt: Date
}

/// One file of a stage manifest (`PUT /api/cloud-projects/:id`).
nonisolated struct ManifestFile: Codable, Sendable, Equatable {
    var path: String
    var sha256: String
    var bytes: Int64
    var contentType: String
}

nonisolated struct UploadTarget: Decodable, Sendable {
    var sha256: String
    var bytes: Int64
    var contentType: String
    var paths: [String]
    var method: String
    var uploadUrl: URL
    var headers: [String: String]
}

nonisolated struct StageResult: Decodable, Sendable {
    var projectId: String
    var revision: Int
    var missing: [UploadTarget]
    var presentCount: Int
}

nonisolated enum SaveOutcome: Sendable {
    case saved(revision: Int)
    /// Someone saved first; here is what they saved (rebase onto it).
    case conflict(revision: Int, document: String?)
}

/// One row of `GET /api/videos` — a share (exported video with a link).
nonisolated struct SharedVideo: Decodable, Sendable, Equatable, Hashable {
    var videoId: String
    var fileName: String
    var contentType: String?
    var fileSizeBytes: Int64?
    var durationSeconds: Double?
    var isPrivate: Bool
    var createdAt: Date
    var url: URL
    /// The cloud project this share was exported from, when known.
    var projectId: String?
    var commentsEnabled: Bool?
    var thumbnailUrl: URL?
    var removed: Removed?

    nonisolated struct Removed: Decodable, Sendable, Equatable, Hashable {
        var at: String
        var reason: String?
    }
}

nonisolated struct SharedVideoList: Decodable, Sendable {
    var videos: [SharedVideo]
    var storageUsedBytes: Int64?
    var storageLimitBytes: Int64?
}

/// `GET /api/video/:id/comments` rows.
nonisolated struct VideoComment: Decodable, Sendable, Equatable, Hashable {
    var commentId: String
    var parentId: String?
    var authorName: String
    var authorImage: String?
    var isOwner: Bool
    var body: String
    var videoTime: Double?
    var createdAt: Date
}

nonisolated struct VideoCommentList: Decodable, Sendable {
    var comments: [VideoComment]
}

/// `GET /api/devices` rows (never carries push tokens).
nonisolated struct AccountDevice: Decodable, Sendable, Equatable {
    var deviceId: String
    var platform: String
    var name: String
    var model: String?
    var canPush: Bool?
    var lastSeenAt: Date?
}

nonisolated struct AccountDeviceList: Decodable, Sendable {
    var devices: [AccountDevice]
}

/// `GET /api/wireless/link`.
nonisolated struct WirelessLinkResponse: Decodable, Sendable {
    var key: String
    var keyId: String
}
