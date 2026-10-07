import Foundation

// Bring-your-own-bucket storage for share-link videos (Settings › Storage).
//
// The server owns everything that matters: it test-writes, reads and deletes
// an object before saving, stores the credentials, and hands the existing
// upload presign (/api/upload/video) a URL in the user's bucket. The app only
// reads, saves and disconnects the bucket record here — uploads need no
// client change.
//
//   GET    /api/storage/bucket   → StorageBucketStatus
//   PUT    /api/storage/bucket   ← StorageBucketDraft → StorageBucketStatus
//   DELETE /api/storage/bucket   → StorageDisconnectResult
//
// Errors are `{ "error": "human message", "code": "…", "step"?: "…" }`; the
// `error` string is shown to the user verbatim.

/// S3-compatible providers the server accepts. Raw values are the wire
/// identity — never rename one.
nonisolated enum StorageProvider: String, CaseIterable, Sendable {
    case aws
    case r2
    case b2
    case wasabi
    case minio
    case other

    var title: String {
        switch self {
        case .aws: return "AWS S3"
        case .r2: return "Cloudflare R2"
        case .b2: return "Backblaze B2"
        case .wasabi: return "Wasabi"
        case .minio: return "MinIO"
        case .other: return "Other S3-compatible"
        }
    }

    /// Short name for summaries ("R2 · my-videos · auto").
    var shortTitle: String {
        switch self {
        case .aws: return "AWS S3"
        case .r2: return "R2"
        case .b2: return "B2"
        case .wasabi: return "Wasabi"
        case .minio: return "MinIO"
        case .other: return "S3-compatible"
        }
    }

    /// AWS resolves its endpoint from the region; everything else needs one.
    var needsEndpoint: Bool { self != .aws }

    /// Region a preset prefills ("" = the user must type one).
    var defaultRegion: String {
        switch self {
        case .aws: return "us-east-1"
        case .r2: return "auto"
        case .b2: return "us-west-004"
        case .wasabi: return "us-east-1"
        case .minio: return "us-east-1"
        case .other: return ""
        }
    }

    var regionPlaceholder: String {
        switch self {
        case .r2: return "auto"
        case .b2: return "us-west-004"
        case .other: return "us-east-1"
        default: return "us-east-1"
        }
    }

    /// MinIO (and most self-hosted servers) only speak path-style URLs.
    var defaultPathStyle: Bool { self == .minio }

    /// The endpoint a region implies, for providers whose endpoint is fully
    /// determined by it (B2, Wasabi). Used as the placeholder AND as the
    /// value saved when the endpoint field is left empty.
    func derivedEndpoint(region: String) -> String? {
        let region = region.trimmingCharacters(in: .whitespaces)
        guard !region.isEmpty else { return nil }
        switch self {
        case .b2: return "https://s3.\(region).backblazeb2.com"
        case .wasabi: return "https://s3.\(region).wasabisys.com"
        default: return nil
        }
    }

    func endpointPlaceholder(region: String) -> String {
        switch self {
        case .aws: return ""
        case .r2: return "https://<accountid>.r2.cloudflarestorage.com"
        case .b2: return derivedEndpoint(region: region) ?? "https://s3.<region>.backblazeb2.com"
        case .wasabi: return derivedEndpoint(region: region) ?? "https://s3.<region>.wasabisys.com"
        case .minio: return "https://minio.example.com:9000"
        case .other: return "https://s3.example.com"
        }
    }
}

/// The connected bucket, as the server describes it. The secret key is
/// never returned — only a masked hint of the access key ID.
nonisolated struct ConnectedStorageBucket: Equatable, Sendable {
    var id: String
    var provider: StorageProvider
    var endpoint: String?
    var region: String
    var bucket: String
    var pathPrefix: String
    var forcePathStyle: Bool
    var publicBaseUrl: String?
    var accessKeyIdHint: String
    var verifiedAt: Date?
    var videoCount: Int
}

/// GET/PUT response.
nonisolated struct StorageBucketStatus: Equatable, Sendable {
    /// The user's plan includes custom storage.
    var enabled: Bool
    /// The server is configured to store credentials.
    var available: Bool
    var bucket: ConnectedStorageBucket?
    /// Videos still playing from previously disconnected buckets.
    var retainedCount: Int
}

/// DELETE response.
nonisolated struct StorageDisconnectResult: Equatable, Sendable {
    var disconnected: Bool
    var retained: Bool
    var videoCount: Int
}

/// PUT body. Both keys are required on every save.
nonisolated struct StorageBucketDraft: Equatable, Sendable {
    var provider: StorageProvider
    var endpoint: String?
    var region: String
    var bucket: String
    var pathPrefix: String
    var forcePathStyle: Bool
    var publicBaseUrl: String?
    var accessKeyId: String
    var secretAccessKey: String

    /// Wire shape — optional strings go out as explicit `null`.
    var jsonObject: [String: Any] {
        [
            "provider": provider.rawValue,
            "endpoint": endpoint ?? NSNull(),
            "region": region,
            "bucket": bucket,
            "pathPrefix": pathPrefix,
            "forcePathStyle": forcePathStyle,
            "publicBaseUrl": publicBaseUrl ?? NSNull(),
            "accessKeyId": accessKeyId,
            "secretAccessKey": secretAccessKey,
        ]
    }
}

nonisolated enum StorageBucketAPIError: LocalizedError, Equatable {
    case notSignedIn
    /// Non-2xx from the API. `message` is the server's `error`, verbatim.
    case server(status: Int, message: String, code: String?, step: String?)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Sign in to manage custom storage."
        case .server(_, let message, _, _): return message
        case .invalidResponse: return "The server sent a response CaptureCat couldn't read."
        }
    }

    var code: String? {
        if case .server(_, _, let code, _) = self { return code }
        return nil
    }
}

/// The seam the Settings pane talks through: the live API in the app, a
/// canned fake in `--settings-shot` (the gate never touches the network).
nonisolated protocol StorageBucketClient: Sendable {
    /// A session token exists (signed in and unexpired).
    var hasSession: Bool { get }
    func fetchStatus() async throws -> StorageBucketStatus
    func save(_ draft: StorageBucketDraft) async throws -> StorageBucketStatus
    func disconnect() async throws -> StorageDisconnectResult
}

/// Live client — same request style as ShareUploadAPI / CloudProjectSync:
/// bearer session token from the Keychain + the X-App-Token version marker.
/// Every call hops off the main actor (`@concurrent`); callers await it from
/// the UI and apply results back on the main actor.
nonisolated struct StorageBucketAPI: StorageBucketClient {
    var baseURL: String { CaptureCatAPI.baseURL }

    var hasSession: Bool { AuthKeychain.currentToken() != nil }

    @concurrent
    func fetchStatus() async throws -> StorageBucketStatus {
        let data = try await send(method: "GET", body: nil)
        return try Self.decodeStatus(data)
    }

    @concurrent
    func save(_ draft: StorageBucketDraft) async throws -> StorageBucketStatus {
        let body = try JSONSerialization.data(withJSONObject: draft.jsonObject)
        let data = try await send(method: "PUT", body: body)
        return try Self.decodeStatus(data)
    }

    @concurrent
    func disconnect() async throws -> StorageDisconnectResult {
        let data = try await send(method: "DELETE", body: nil)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StorageBucketAPIError.invalidResponse
        }
        return StorageDisconnectResult(
            disconnected: json["disconnected"] as? Bool ?? true,
            retained: json["retained"] as? Bool ?? false,
            videoCount: Self.int(json["videoCount"]) ?? 0
        )
    }

    // MARK: - Transport

    private func send(method: String, body: Data?) async throws -> Data {
        guard let token = AuthKeychain.currentToken() else { throw StorageBucketAPIError.notSignedIn }
        guard let url = URL(string: "\(baseURL)/api/storage/bucket") else {
            throw StorageBucketAPIError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("capturecat-v1-9f3a7c2e", forHTTPHeaderField: "X-App-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // PUT runs a live write/read/delete against the user's bucket before
        // answering — give a slow provider room.
        request.timeoutInterval = method == "PUT" ? 60 : 20
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw StorageBucketAPIError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            throw Self.serverError(status: http.statusCode, data: data)
        }
        return data
    }

    // MARK: - Decoding (pure — the harness asserts these directly)

    static func serverError(status: Int, data: Data) -> StorageBucketAPIError {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let message = (json?["error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? HTTPURLResponse.localizedString(forStatusCode: status).capitalized
        return .server(status: status, message: message,
                       code: json?["code"] as? String, step: json?["step"] as? String)
    }

    static func decodeStatus(_ data: Data) throws -> StorageBucketStatus {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StorageBucketAPIError.invalidResponse
        }
        var bucket: ConnectedStorageBucket?
        if let raw = json["bucket"] as? [String: Any] {
            guard let providerRaw = raw["provider"] as? String,
                  let name = raw["bucket"] as? String else {
                throw StorageBucketAPIError.invalidResponse
            }
            bucket = ConnectedStorageBucket(
                id: raw["id"] as? String ?? "",
                // An unknown future provider still renders (as "other").
                provider: StorageProvider(rawValue: providerRaw) ?? .other,
                endpoint: nonEmpty(raw["endpoint"]),
                region: raw["region"] as? String ?? "",
                bucket: name,
                pathPrefix: raw["pathPrefix"] as? String ?? "",
                forcePathStyle: raw["forcePathStyle"] as? Bool ?? false,
                publicBaseUrl: nonEmpty(raw["publicBaseUrl"]),
                accessKeyIdHint: raw["accessKeyIdHint"] as? String ?? "",
                verifiedAt: (raw["verifiedAt"] as? String).flatMap(parseDate),
                videoCount: int(raw["videoCount"]) ?? 0
            )
        }
        return StorageBucketStatus(
            enabled: json["enabled"] as? Bool ?? false,
            available: json["available"] as? Bool ?? false,
            bucket: bucket,
            retainedCount: int(json["retainedCount"]) ?? 0
        )
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    private static func int(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    static func parseDate(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}
