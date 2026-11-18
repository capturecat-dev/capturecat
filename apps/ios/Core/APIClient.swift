import Foundation

nonisolated enum APIError: LocalizedError, Sendable {
    /// No session, or the API refused it (401). The session is cleared.
    case signedOut
    case http(status: Int, code: String?, message: String)
    case transport(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .signedOut: return "You're signed out. Sign in to CaptureCat to continue."
        case let .http(_, _, message): return message
        case let .transport(message): return message
        case .invalidResponse: return "CaptureCat sent an unexpected response. Try again."
        }
    }

    var status: Int? {
        if case let .http(status, _, _) = self { return status }
        return nil
    }

    var code: String? {
        if case let .http(_, code, _) = self { return code }
        return nil
    }
}

/// Thin async client for the CaptureCat API. Every call sends this app's own
/// Bearer session (cookie-less, so the API's CSRF gate never applies). A 401
/// clears the stored session and posts `.ccSessionDidChange`.
nonisolated final class APIClient: Sendable {
    static let shared = APIClient()

    private let session: URLSession
    private let baseURL: @Sendable () -> String
    private let token: @Sendable () -> String?

    /// The app uses the defaults; tests point a client at a local mock API
    /// with an explicit base URL and token (never at production by accident).
    init(
        session: URLSession = .shared,
        baseURL: @escaping @Sendable () -> String = { CaptureCatAPI.baseURL },
        token: @escaping @Sendable () -> String? = { SessionStore.load()?.token }
    ) {
        self.session = session
        self.baseURL = baseURL
        self.token = token
    }

    // MARK: Account

    func me() async throws -> AccountInfo {
        let (data, _) = try await send("GET", "/api/me")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw APIError.invalidResponse }
        let info = AccountInfo(json: json)
        SessionStore.refreshExpiry(info.sessionExpiresAt)
        return info
    }

    /// Exchange the loopback code for a session (`/api/desktop/token`).
    func redeem(code: String, verifier: String, redirectURI: String) async throws -> AuthSession {
        struct Body: Encodable { let code: String; let code_verifier: String; let redirect_uri: String }
        struct Reply: Decodable { let token: String; let expiresAt: Date?; let user: AccountUser }
        let (data, _) = try await send("POST", "/api/desktop/token", json: Body(code: code, code_verifier: verifier, redirect_uri: redirectURI), authenticated: false)
        let reply = try JSONDecoder.iso.decode(Reply.self, from: data)
        return AuthSession(token: reply.token, expiresAt: reply.expiresAt, user: reply.user, apiBaseURL: baseURL())
    }

    /// Sign this app's session out server-side (best effort).
    func revoke() async {
        _ = try? await send("POST", "/api/desktop/revoke", json: [String: String]())
    }

    /// `DELETE /api/me` — delete the account and everything it owns
    /// (apps/api: the server cancels an active subscription first and answers
    /// 502 `billing_unavailable`, deleting nothing, if it can't). 200 = deleted.
    /// 401 counts as deleted too: the session is gone, which after a DELETE
    /// whose response was lost means the first attempt landed — and either
    /// way this device can only sign out. Unlike `perform`, transport errors
    /// stay distinguishable (offline vs unreachable) so the confirmation can
    /// say whether anything happened.
    func deleteAccount() async throws -> AccountDeletionResult {
        var request = try makeRequest("DELETE", "/api/me")
        // Names the client in the server's deletion audit row.
        request.setValue("ios", forHTTPHeaderField: "X-CC-Client")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where [.notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff].contains(error.code) {
            throw AccountDeletionError.offline
        } catch {
            throw AccountDeletionError.unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw AccountDeletionError.unreachable }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        switch http.statusCode {
        case 200..<300:
            return AccountDeletionResult(
                alreadyGone: false,
                cancelledSubscriptions: json?["cancelledSubscriptions"] as? Int ?? 0,
                cleanupPending: (json?["cleanup"] as? String) == "pending"
            )
        case 401:
            return AccountDeletionResult(alreadyGone: true, cancelledSubscriptions: 0, cleanupPending: false)
        default:
            throw AccountDeletionError.http(status: http.statusCode, code: json?["code"] as? String, message: json?["error"] as? String)
        }
    }

    // MARK: Cloud projects

    func cloudProjects() async throws -> CloudProjectList {
        try await decode("GET", "/api/cloud-projects")
    }

    func cloudProject(_ id: String) async throws -> CloudProjectDetail {
        try await decode("GET", "/api/cloud-projects/\(id.uppercased())")
    }

    func deleteCloudProject(_ id: String) async throws {
        _ = try await send("DELETE", "/api/cloud-projects/\(id.uppercased())")
    }

    func stage(projectID: String, name: String, files: [ManifestFile]) async throws -> StageResult {
        struct Body: Encodable { let name: String; let files: [ManifestFile] }
        return try await decode("PUT", "/api/cloud-projects/\(projectID.uppercased())", json: Body(name: name, files: files))
    }

    /// true = committed; false = still verifying (call again).
    func finalize(projectID: String) async throws -> Bool {
        let (data, response) = try await send("POST", "/api/cloud-projects/\(projectID.uppercased())/finalize", json: [String: String]())
        if response.statusCode == 202 { return false }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["committed"] as? Bool ?? false
    }

    /// Save project.json with optimistic concurrency (`If-Match: "<revision>"`).
    func saveProject(_ id: String, document: Data, baseRevision: Int) async throws -> SaveOutcome {
        var request = try makeRequest("PUT", "/api/cloud-projects/\(id.uppercased())/project")
        request.setValue("\"\(baseRevision)\"", forHTTPHeaderField: "If-Match")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ios", forHTTPHeaderField: "X-CaptureCat-Client")
        request.httpBody = document
        let (data, response) = try await perform(request, allowing: [409])
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if response.statusCode == 409 {
            return .conflict(revision: json["revision"] as? Int ?? baseRevision, document: json["document"] as? String)
        }
        guard let revision = json["revision"] as? Int else { throw APIError.invalidResponse }
        return .saved(revision: revision)
    }

    // MARK: Shares

    func videos() async throws -> SharedVideoList {
        try await decode("GET", "/api/videos")
    }

    func comments(videoID: String) async throws -> [VideoComment] {
        let list: VideoCommentList = try await decode("GET", "/api/video/\(videoID)/comments")
        return list.comments
    }

    func postComment(videoID: String, body: String, videoTime: Double?, parentID: String? = nil) async throws -> VideoComment {
        struct Body: Encodable { let body: String; let videoTime: Double?; let parentId: String? }
        struct Reply: Decodable { let comment: VideoComment }
        let reply: Reply = try await decode("POST", "/api/video/\(videoID)/comments", json: Body(body: body, videoTime: videoTime, parentId: parentID))
        return reply.comment
    }

    /// Viewer comments on or off for one of the account's shares
    /// (`PATCH /api/video/:id/comments-enabled`, owner only). On needs a plan
    /// with comments: 403 `upgrade_required` with a sentence to show.
    /// → the value the API stored.
    func setCommentsEnabled(videoID: String, enabled: Bool) async throws -> Bool {
        struct Body: Encodable { let commentsEnabled: Bool }
        struct Reply: Decodable { let commentsEnabled: Bool }
        let reply: Reply = try await decode("PATCH", "/api/video/\(videoID)/comments-enabled", json: Body(commentsEnabled: enabled))
        return reply.commentsEnabled
    }

    /// The share's video bytes (`GET /api/video/:id`, Range-capable). Private
    /// shares need the Authorization header — see `authorizedHeaders`.
    func videoStreamURL(videoID: String) -> URL {
        URL(string: "\(baseURL())/api/video/\(videoID)")!
    }

    /// Headers for AVURLAsset (`AVURLAssetHTTPHeaderFieldsKey`).
    var authorizedHeaders: [String: String] {
        guard let token = token() else { return [:] }
        return ["Authorization": "Bearer \(token)"]
    }

    // MARK: Devices + wireless link

    func wirelessLink() async throws -> WirelessLinkResponse {
        try await decode("GET", "/api/wireless/link")
    }

    func rotateWirelessLink() async throws -> WirelessLinkResponse {
        try await decode("POST", "/api/wireless/link/rotate", json: [String: String]())
    }

    func registerDevice(_ registration: DeviceRegistration) async throws {
        _ = try await send("PUT", "/api/devices/\(registration.deviceID)", json: registration)
    }

    func unregisterDevice(_ deviceID: String) async {
        _ = try? await send("DELETE", "/api/devices/\(deviceID)")
    }

    func devices() async throws -> [AccountDevice] {
        let list: AccountDeviceList = try await decode("GET", "/api/devices")
        return list.devices
    }

    // MARK: Plumbing

    func decode<T: Decodable>(_ method: String, _ path: String) async throws -> T {
        let (data, _) = try await send(method, path)
        do { return try JSONDecoder.iso.decode(T.self, from: data) } catch { throw APIError.invalidResponse }
    }

    func decode<T: Decodable, B: Encodable>(_ method: String, _ path: String, json body: B) async throws -> T {
        let (data, _) = try await send(method, path, json: body)
        do { return try JSONDecoder.iso.decode(T.self, from: data) } catch { throw APIError.invalidResponse }
    }

    @discardableResult
    func send(_ method: String, _ path: String, authenticated: Bool = true) async throws -> (Data, HTTPURLResponse) {
        try await perform(makeRequest(method, path, authenticated: authenticated))
    }

    @discardableResult
    func send<B: Encodable>(_ method: String, _ path: String, json body: B, authenticated: Bool = true) async throws -> (Data, HTTPURLResponse) {
        var request = try makeRequest(method, path, authenticated: authenticated)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder.iso.encode(body)
        return try await perform(request)
    }

    func makeRequest(_ method: String, _ path: String, authenticated: Bool = true) throws -> URLRequest {
        guard let url = URL(string: baseURL() + path) else { throw APIError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if authenticated {
            guard let token = token() else { throw APIError.signedOut }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    func perform(_ request: URLRequest, allowing extra: Set<Int> = []) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.transport((error as? URLError)?.code == .notConnectedToInternet
                ? "You're offline. Check your connection and try again."
                : "Couldn't reach CaptureCat. Try again.")
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        if (200..<300).contains(http.statusCode) || extra.contains(http.statusCode) { return (data, http) }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if http.statusCode == 401, request.value(forHTTPHeaderField: "Authorization") != nil {
            SessionStore.clear()
            throw APIError.signedOut
        }
        let message = json?["error"] as? String ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode).capitalized
        throw APIError.http(status: http.statusCode, code: json?["code"] as? String, message: message)
    }
}

/// What `DELETE /api/me` reported.
nonisolated struct AccountDeletionResult: Equatable, Sendable {
    /// The session was already gone (401) — an earlier attempt landed.
    var alreadyGone: Bool
    var cancelledSubscriptions: Int
    /// Stored files are still being removed in the background.
    var cleanupPending: Bool
}

/// Why `DELETE /api/me` did not delete the account. The copy is what the
/// confirmation shows inline; every case means nothing was deleted (a 401 is
/// never an error here, see `deleteAccount`).
nonisolated enum AccountDeletionError: LocalizedError, Equatable, Sendable {
    case offline
    case unreachable
    case http(status: Int, code: String?, message: String?)

    var errorDescription: String? {
        switch self {
        case .offline:
            return "You're offline, so nothing was deleted. Connect to the internet and try again."
        case .unreachable:
            return "Couldn't reach CaptureCat, so your account wasn't deleted. Check your connection and try again."
        case let .http(status, code, message):
            switch (status, code) {
            case (409, _):
                return message ?? "Your account can't be deleted yet. Try again from the web app."
            case (502, _), (_, "billing_unavailable"):
                return message ?? "We couldn't cancel your subscription, so nothing was deleted. Try again in a moment."
            case (403, "agent_token_forbidden"):
                return "Only you can delete your account, while signed in to CaptureCat."
            case (403, _):
                return (message.map { $0 + ". " } ?? "") + "This account can't be deleted here. Email contact@capturecat.so and we'll help."
            case (429, _):
                return "Too many attempts. Wait a minute, then try again."
            default:
                return "Something went wrong, and nothing was deleted. Try again in a moment."
            }
        }
    }
}

/// `PUT /api/devices/:deviceId` body.
nonisolated struct DeviceRegistration: Encodable, Sendable {
    var deviceID: String
    var platform = "ios"
    var name: String
    var model: String
    var systemVersion: String
    var appVersion: String
    var apnsToken: String?
    var apnsEnvironment: String?

    enum CodingKeys: String, CodingKey {
        case platform, name, model, systemVersion, appVersion, apnsToken, apnsEnvironment
    }
}
