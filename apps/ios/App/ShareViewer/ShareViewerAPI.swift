import AVFoundation
import Foundation

// The public share endpoints the web share page reads (apps/web/src/routes/
// share.$videoId.tsx + components/share/*), with the API's rules
// (apps/api/src/routes/{video,hub,analytics,video-report}.ts):
//
//   GET  /api/video/:id/meta[?token]      200 open meta | 200 {gate} | 410 removed | 404 (missing, private, not ready)
//   POST /api/video/:id/unlock {password} 200 {token} | 403 wrong | 429
//   GET  /api/video/:id[?token&v]         the bytes (Range); 403 private unless the OWNER's bearer
//   GET  /api/video/:id/comments[?token]  {comments, viewer} — 404 when comments are off
//   POST /api/video/:id/comments[?token]  {body, authorName?, videoTime?, parentId?, annotation?} — anyone;
//                                         a bearer only ATTACHES who is posting
//   GET  /api/video/:id/reactions?session {reactions, mine}
//   POST /api/video/:id/reactions         {emoji, videoTime, sessionId} → {ok, mine} (same emoji toggles off)
//   GET  /api/video/:id/transcript        {segments}
//   POST /api/video/:id/analytics[?token] {sessionId, events} — the view + watch ticks
//   POST /api/video/:id/report            {reason, details?}
//
// Nothing here needs an account. When this device is signed in, its bearer
// rides along so a comment is posted AS the user (name, owner badge) and the
// owner can play their own private share — exactly what the web's cookie does.

/// `GET /api/video/:id/meta` when the share is open.
struct ShareMeta: Decodable, Equatable {
    var videoId: String
    var fileName: String
    var durationSeconds: Double?
    var createdAt: String?
    var commentsEnabled: Bool?
    var allowDownload: Bool?
    var aiTitle: String?
    var aiSummary: String?
    var aiChapters: [Chapter]?
    var hasTranscript: Bool?
    var currentVersion: Int?
    var ctaLabel: String?
    var ctaUrl: String?
    /// The owner's annotation markers (output seconds) — ranges on the
    /// scrubber, pills and Summary rows, the web's `meta.annotations`.
    var annotations: [ShareAnnotationMarker]?
    /// The owner's accent "#RRGGBB" (the markers' and the drawing's default ink).
    var brandAccent: String?

    struct Chapter: Decodable, Equatable {
        var start: Double
        var label: String
    }

    var createdDate: Date? { createdAt.flatMap(ISO8601.parse) }

    /// The web's viewer-facing title: the AI title, else the file name with
    /// its extension stripped; the apps' own `capturecat-share-<UUID>` name
    /// reads "Untitled recording".
    var displayTitle: String {
        if let ai = aiTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !ai.isEmpty { return ai }
        return Self.prettyFileName(fileName)
    }

    static func prettyFileName(_ fileName: String) -> String {
        let base = fileName.replacingOccurrences(of: "\\.[A-Za-z0-9]{2,5}$", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if base.isEmpty || base.range(of: "^capturecat-share-[0-9a-fA-F-]{8,}$", options: .regularExpression) != nil {
            return String(localized: "Untitled recording", comment: "Title shown for a shared video that has no name")
        }
        return base
    }

    /// The share page's accent: the owner's brand colour, else amber.
    var accent: String {
        if let accent = brandAccent, ShareAnnotationMath.isColor(accent) { return accent.lowercased() }
        return ShareAnnotationMath.defaultAccent
    }

    /// Markers sorted by time (the API keeps the owner's order).
    var markers: [ShareAnnotationMarker] { annotations ?? [] }

    /// The markers the web lists as pills / Summary rows.
    var pillMarkers: [ShareAnnotationMarker] { markers.filter(\.hasPill) }

    /// Chapters worth a Summary tab: the web hides a lone chapter at 0:00.
    var meaningfulChapters: [Chapter] {
        let chapters = (aiChapters ?? []).sorted { $0.start < $1.start }
        if chapters.count == 1, chapters[0].start < 1 { return [] }
        return chapters
    }
}

/// Which wall a gated share hit (the web's `gate`).
enum ShareGateState: String {
    case locked, expired, viewLimit = "view_limit", paused
}

/// What opening a share found.
enum ShareLookup: Equatable {
    case open(ShareMeta)
    case gated(ShareGateState, fileName: String)
    case removed(String)
    /// Private: 404 at /meta, 403 "This video is private" at the stream.
    case privateVideo
    /// The OWNER's own private share: /meta refuses it (public page), but the
    /// stream plays with their bearer — the app shows it without the social bits.
    case ownerPrivate
    case notFound
}

struct ShareReaction: Decodable, Equatable {
    var emoji: String
    var videoTime: Double
}

struct ShareTranscriptSegment: Decodable, Equatable {
    var start: Double
    var end: Double
    var text: String
}

/// The signed-in caller, as GET /comments describes them.
struct ShareCommentViewer: Decodable, Equatable {
    var name: String
    var image: String?
    var isOwner: Bool?
}

enum ShareViewerError: LocalizedError {
    case wrongPassword
    case tooManyAttempts
    case message(String)

    var errorDescription: String? {
        switch self {
        case .wrongPassword: return String(localized: "Wrong password.")
        case .tooManyAttempts: return String(localized: "Too many attempts — try later.")
        case let .message(text): return text
        }
    }
}

/// The reasons the API accepts (apps/api/src/lib/moderation.ts REPORT_REASONS,
/// labels from apps/web/src/lib/report-reasons.ts).
enum ShareReportReason: String, CaseIterable {
    case spam, sexual, violence, hate, harassment, illegal, copyright, other

    var label: String {
        switch self {
        case .spam: return String(localized: "Spam or misleading", comment: "Report reason for a shared video")
        case .sexual: return String(localized: "Sexual content", comment: "Report reason for a shared video")
        case .violence: return String(localized: "Violence or gore", comment: "Report reason for a shared video")
        case .hate: return String(localized: "Hate or harassment of a group", comment: "Report reason for a shared video")
        case .harassment: return String(localized: "Bullying or harassment", comment: "Report reason for a shared video")
        case .illegal: return String(localized: "Illegal activity", comment: "Report reason for a shared video")
        case .copyright: return String(localized: "Copyright infringement", comment: "Report reason for a shared video")
        case .other: return String(localized: "Something else", comment: "Report reason for a shared video")
        }
    }
}

/// The reactions the API accepts, in the web's order (apps/api lib/db.ts REACTION_EMOJI).
enum ShareReactions {
    static let all = ["👍", "❤️", "🔥", "😂", "😮", "🎉"]
    static let spoken = ["👍": String(localized: "Thumbs up", comment: "VoiceOver name of the 👍 reaction"), "❤️": String(localized: "Heart", comment: "VoiceOver name of the ❤️ reaction"), "🔥": String(localized: "Fire", comment: "VoiceOver name of the 🔥 reaction"), "😂": String(localized: "Laughing", comment: "VoiceOver name of the 😂 reaction"), "😮": String(localized: "Surprised", comment: "VoiceOver name of the 😮 reaction"), "🎉": String(localized: "Celebrate", comment: "VoiceOver name of the 🎉 reaction")]
}

final class ShareViewerAPI {
    private let session: URLSession
    private let baseURL: () -> String
    private let token: () -> String?

    init(session: URLSession = .shared,
         baseURL: @escaping () -> String = { CaptureCatAPI.baseURL },
         token: @escaping () -> String? = { SessionStore.load()?.token }) {
        self.session = session
        self.baseURL = baseURL
        self.token = token
    }

    // MARK: Requests

    private func url(_ path: String, _ query: [String: String?] = [:]) -> URL {
        var components = URLComponents(string: baseURL() + path)!
        let items = query.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }.sorted { $0.name < $1.name }
        if !items.isEmpty { components.queryItems = items }
        return components.url!
    }

    private func request(_ method: String, _ url: URL, json: Any? = nil, bearer: Bool = true) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if bearer, let token = token() { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: json)
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            throw ShareViewerError.message((error as? URLError)?.code == .notConnectedToInternet
                ? String(localized: "You're offline. Check your connection and try again.")
                : String(localized: "Couldn't reach CaptureCat. Try again."))
        }
    }

    private func object(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func failure(_ data: Data, _ status: Int, fallback: String) -> ShareViewerError {
        let json = object(data)
        if status == 429 { return .message(json["error"] as? String ?? String(localized: "Slow down — try again in a few minutes.")) }
        return .message(json["error"] as? String ?? fallback)
    }

    // MARK: Meta

    func lookup(_ videoID: String, token shareToken: String? = nil) async throws -> ShareLookup {
        // No bearer: /meta is the public page's view (the owner's cookie
        // never changes it on the web either).
        let (data, status) = try await send(request("GET", url("/api/video/\(videoID)/meta", ["token": shareToken]), bearer: false))
        switch status {
        case 200:
            let json = object(data)
            if let gate = json["gate"] as? String, gate != "open" {
                return .gated(ShareGateState(rawValue: gate) ?? .locked, fileName: json["fileName"] as? String ?? "")
            }
            guard let meta = try? JSONDecoder.iso.decode(ShareMeta.self, from: data) else {
                throw ShareViewerError.message(String(localized: "CaptureCat sent an unexpected response. Try again."))
            }
            return .open(meta)
        case 410:
            let json = object(data)
            return .removed(json["message"] as? String ?? String(localized: "This video was removed for violating CaptureCat's terms."))
        case 404:
            return try await probePrivate(videoID)
        default:
            throw failure(data, status, fallback: String(localized: "Couldn't load this video. Try again."))
        }
    }

    /// /meta answers 404 for a private share and a missing one alike; the
    /// stream tells them apart (403 "This video is private"), and plays for
    /// the owner's bearer.
    private func probePrivate(_ videoID: String) async throws -> ShareLookup {
        var probe = request("GET", url("/api/video/\(videoID)"))
        probe.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (_, status) = try await send(probe)
        switch status {
        case 200, 206: return .ownerPrivate
        case 403: return .privateVideo
        case 410: return .removed(String(localized: "This video was removed for violating CaptureCat's terms."))
        default: return .notFound
        }
    }

    func unlock(_ videoID: String, password: String) async throws -> String {
        let (data, status) = try await send(request("POST", url("/api/video/\(videoID)/unlock"), json: ["password": password], bearer: false))
        switch status {
        case 200:
            guard let token = object(data)["token"] as? String else { throw ShareViewerError.message(String(localized: "Could not load the video.")) }
            return token
        case 429: throw ShareViewerError.tooManyAttempts
        case 403: throw ShareViewerError.wrongPassword
        default: throw failure(data, status, fallback: String(localized: "Could not load the video."))
        }
    }

    // MARK: Playback

    /// Pinning `?v=` keeps the byte URL cacheable and changes it when a
    /// replace upload flips the live version (the web does the same).
    func streamAsset(_ videoID: String, token shareToken: String?, version: Int?) -> AVURLAsset {
        let streamURL = url("/api/video/\(videoID)", ["token": shareToken, "v": version.map(String.init)])
        var headers: [String: String] = [:]
        if let token = token() { headers["Authorization"] = "Bearer \(token)" }
        return AVURLAsset(url: streamURL, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
    }

    func downloadURL(_ videoID: String, token shareToken: String?) -> URL {
        url("/api/video/\(videoID)/download", ["token": shareToken])
    }

    // MARK: Comments

    func comments(_ videoID: String, token shareToken: String?) async throws -> (comments: [VideoComment], viewer: ShareCommentViewer?) {
        let (data, status) = try await send(request("GET", url("/api/video/\(videoID)/comments", ["token": shareToken])))
        guard status == 200 else { throw failure(data, status, fallback: String(localized: "Couldn't load comments.")) }
        struct Reply: Decodable {
            var comments: [Tolerant]
            var viewer: ShareCommentViewer?
        }
        guard let reply = try? JSONDecoder.iso.decode(Reply.self, from: data) else {
            throw ShareViewerError.message(String(localized: "Couldn't load comments."))
        }
        return (reply.comments.compactMap(\.comment), reply.viewer)
    }

    func postComment(_ videoID: String, token shareToken: String?, body: String, authorName: String?,
                     videoTime: Double?, parentID: String?, annotation: String? = nil) async throws -> VideoComment {
        var json: [String: Any] = ["body": body]
        if let authorName, !authorName.isEmpty { json["authorName"] = authorName }
        if let videoTime, parentID == nil { json["videoTime"] = videoTime }
        if let parentID { json["parentId"] = parentID }
        var post = request("POST", url("/api/video/\(videoID)/comments", ["token": shareToken]), json: json)
        // The drawing rides as the serializer's EXACT bytes (the web's
        // JSON.stringify output), spliced in rather than re-encoded.
        if let annotation, parentID == nil, let rest = post.httpBody.flatMap({ String(data: $0, encoding: .utf8) }), rest.hasPrefix("{") {
            post.httpBody = Data(("{\"annotation\":" + annotation + (rest == "{}" ? "}" : "," + rest.dropFirst())).utf8)
        }
        let (data, status) = try await send(post)
        guard status == 200 || status == 201 else {
            throw failure(data, status, fallback: parentID == nil ? String(localized: "Could not post comment", comment: "Error when posting a comment on a shared video fails") : String(localized: "Could not post reply", comment: "Error when posting a reply to a comment fails"))
        }
        struct Reply: Decodable { var comment: Tolerant }
        guard let comment = (try? JSONDecoder.iso.decode(Reply.self, from: data))?.comment.comment else {
            throw ShareViewerError.message(String(localized: "Could not post comment", comment: "Error when posting a comment on a shared video fails"))
        }
        return comment
    }

    /// The web's tolerant reader (lib/share/comments.ts readComment): a
    /// missing field never drops the thread.
    private struct Tolerant: Decodable {
        var comment: VideoComment?
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            guard let id = try? c.decode(String.self, forKey: .commentId), let body = try? c.decode(String.self, forKey: .body) else {
                comment = nil
                return
            }
            let name = ((try? c.decodeIfPresent(String.self, forKey: .authorName)) ?? nil)?.trimmingCharacters(in: .whitespaces)
            let created = ((try? c.decodeIfPresent(String.self, forKey: .createdAt)) ?? nil).flatMap(ISO8601.parse) ?? Date()
            let time = (try? c.decodeIfPresent(Double.self, forKey: .videoTime)) ?? nil
            comment = VideoComment(
                commentId: id,
                parentId: (try? c.decodeIfPresent(String.self, forKey: .parentId)) ?? nil,
                authorName: (name?.isEmpty == false ? name : nil) ?? String(localized: "Anonymous", comment: "Author name for a comment posted without a name"),
                authorImage: (try? c.decodeIfPresent(String.self, forKey: .authorImage)) ?? nil,
                isOwner: ((try? c.decodeIfPresent(Bool.self, forKey: .isOwner)) ?? nil) ?? false,
                body: body,
                videoTime: time.map { max(0, $0) } ?? 0,
                createdAt: created,
                annotation: ((try? c.decodeIfPresent(ShareAnnotation.self, forKey: .annotation)) ?? nil).flatMap { $0.shapes.isEmpty ? nil : $0 })
        }
        enum Keys: String, CodingKey { case commentId, parentId, authorName, authorImage, isOwner, body, videoTime, createdAt, annotation }
    }

    // MARK: Reactions

    func reactions(_ videoID: String, session sessionID: String) async throws -> (all: [ShareReaction], mine: String?) {
        let (data, status) = try await send(request("GET", url("/api/video/\(videoID)/reactions", ["session": sessionID]), bearer: false))
        guard status == 200 else { throw failure(data, status, fallback: String(localized: "Couldn't load reactions.")) }
        struct Reply: Decodable {
            struct Mine: Decodable { var emoji: String }
            var reactions: [ShareReaction]?
            var mine: Mine?
        }
        let reply = try? JSONDecoder.iso.decode(Reply.self, from: data)
        return (reply?.reactions ?? [], reply?.mine?.emoji)
    }

    /// → this viewer's reaction afterwards (nil = toggled off).
    func react(_ videoID: String, emoji: String, at time: Double, session sessionID: String) async throws -> String? {
        let (data, status) = try await send(request("POST", url("/api/video/\(videoID)/reactions"),
                                                    json: ["emoji": emoji, "videoTime": time, "sessionId": sessionID], bearer: false))
        guard (200..<300).contains(status) else { throw failure(data, status, fallback: String(localized: "Couldn't react. Try again.")) }
        return (object(data)["mine"] as? [String: Any])?["emoji"] as? String
    }

    // MARK: Transcript, analytics, report

    func transcript(_ videoID: String) async throws -> [ShareTranscriptSegment] {
        let (data, status) = try await send(request("GET", url("/api/video/\(videoID)/transcript"), bearer: false))
        guard status == 200 else { throw failure(data, status, fallback: String(localized: "Couldn't load the transcript.")) }
        struct Reply: Decodable { var segments: [ShareTranscriptSegment]? }
        return (try? JSONDecoder.iso.decode(Reply.self, from: data))?.segments ?? []
    }

    /// Fire-and-forget, like the web's beacon.
    func analytics(_ videoID: String, token shareToken: String?, sessionID: String, events: [[String: Any]]) async {
        let body: [String: Any] = ["sessionId": sessionID, "events": events, "referrer": "ios-app"]
        _ = try? await send(request("POST", url("/api/video/\(videoID)/analytics", ["token": shareToken]), json: body, bearer: false))
    }

    func report(_ videoID: String, reason: ShareReportReason) async throws {
        let (data, status) = try await send(request("POST", url("/api/video/\(videoID)/report"), json: ["reason": reason.rawValue]))
        guard (200..<300).contains(status) else {
            if status == 429 { throw ShareViewerError.message(String(localized: "You've sent a lot of reports. Try again in a while.")) }
            throw failure(data, status, fallback: String(localized: "Couldn't send the report. Try again."))
        }
    }
}
