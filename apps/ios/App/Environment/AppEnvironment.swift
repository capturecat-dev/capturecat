import AVFoundation
import Observation
import UIKit

// The one seam between the screens and the outside world. Screens never call
// APIClient / SessionStore / UploadCenter / CaptureHubModel directly; they go
// through `AppEnvironment.shared`, which is the LIVE stack in every build —
// and, in Debug builds launched with `-uiFixtures`, a deterministic synthetic
// world that never touches the network or the keychain (FixtureWorld.swift).

/// Everything the screens need from the CaptureCat API.
protocol CloudAPI: AnyObject {
    func me() async throws -> AccountInfo
    func cloudProjects() async throws -> CloudProjectList
    func cloudProject(_ id: String) async throws -> CloudProjectDetail
    func deleteCloudProject(_ id: String) async throws
    func saveProject(_ id: String, document: Data, baseRevision: Int) async throws -> SaveOutcome
    /// `GET /api/videos`, plus the fields Core's `SharedVideo` doesn't decode.
    func shares() async throws -> ShareListing
    func comments(videoID: String) async throws -> [VideoComment]
    func postComment(videoID: String, body: String, videoTime: Double?, parentID: String?) async throws -> VideoComment
    /// The share's video (private shares need the bearer header).
    func streamAsset(videoID: String) -> AVURLAsset
    /// A share's custom thumbnail (`thumbnailUrl`), when it has one.
    func shareThumbnail(_ video: SharedVideo) async -> UIImage?
    /// "Forget my devices" — rotate the account's Wi-Fi link key.
    func forgetDevices() async throws
}

/// Extra share fields from `GET /api/videos` (gap: Core's SharedVideo has
/// no profileVisible / hasPassword).
struct ShareExtras: Equatable, Sendable {
    var profileVisible: Bool
    var hasPassword: Bool
}

struct ShareListing {
    var videos: [SharedVideo]
    var extras: [String: ShareExtras]
}

/// Sign-in state and the two flows.
protocol SessionGateway: AnyObject {
    var user: AccountUser? { get }
    func signIn(from window: UIWindow?) async throws
    func signOut() async
}

/// The upload inbox (UploadCenter in the live app).
protocol InboxFeed: AnyObject, Observable {
    var takes: [PendingTake] { get }
    var progress: [String: PublishProgress] { get }
    func retry(_ id: String)
    func discard(_ id: String)
    func processPending()
    func reload()
}

/// What the Capture tab renders (CaptureHubModel + MacPresence + UploadCenter
/// in the live app; fake presence states in fixtures).
protocol CaptureFeed: AnyObject {
    var presenceStatus: MacPresence.Status { get }
    var nearbyMacs: [(id: String, name: String)] { get }
    var connectedMacID: String? { get }
    var lastRequest: CaptureHubModel.Request? { get }
    var importError: String? { get }
    var isImporting: Bool { get }
    func prefer(macID: String?)
    func streamToMac(from view: UIView)
    func recordOnPhone(from view: UIView)
    func pickScreenshots(from presenter: UIViewController)
    func pickVideos(from presenter: UIViewController)
    func dismissRequest()
    /// "Continue on Mac" for a cloud project.
    func continueOnMac(projectID: String, name: String) async -> MacPresence.HandoffResult
}

final class AppEnvironment {
    static let shared = AppEnvironment()

    let api: CloudAPI
    let session: SessionGateway
    let inbox: InboxFeed
    let capture: CaptureFeed
    let isFixture: Bool

    private init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uiFixtures") || ProcessInfo.processInfo.arguments.contains("-kitGallery") {
            let world = FixtureWorld.shared
            api = world
            session = world.session
            inbox = world.inbox
            capture = world.capture
            isFixture = true
            return
        }
        #endif
        api = LiveCloudAPI()
        session = LiveSession()
        inbox = UploadCenter.shared
        capture = LiveCaptureFeed()
        isFixture = false
    }
}

extension Notification.Name {
    /// The scene became active (SceneDelegate) — screens refresh.
    static let ccAppDidBecomeActive = Notification.Name("so.capturecat.ios.appDidBecomeActive")
}

// MARK: - Live

final class LiveCloudAPI: CloudAPI {
    private let client = APIClient.shared

    func me() async throws -> AccountInfo { try await client.me() }
    func cloudProjects() async throws -> CloudProjectList { try await client.cloudProjects() }
    func cloudProject(_ id: String) async throws -> CloudProjectDetail { try await client.cloudProject(id) }
    func deleteCloudProject(_ id: String) async throws { try await client.deleteCloudProject(id) }

    func saveProject(_ id: String, document: Data, baseRevision: Int) async throws -> SaveOutcome {
        try await client.saveProject(id, document: document, baseRevision: baseRevision)
    }

    func shares() async throws -> ShareListing {
        // One request, decoded twice: Core's SharedVideoList, and the extra
        // fields this screen shows (privacy: profileVisible / hasPassword).
        let (data, _) = try await client.send("GET", "/api/videos")
        let list: SharedVideoList
        do { list = try JSONDecoder.iso.decode(SharedVideoList.self, from: data) } catch { throw APIError.invalidResponse }
        struct ExtrasList: Decodable {
            struct Row: Decodable { var videoId: String; var profileVisible: Bool?; var hasPassword: Bool? }
            var videos: [Row]
        }
        let extras = (try? JSONDecoder().decode(ExtrasList.self, from: data))?.videos ?? []
        var map: [String: ShareExtras] = [:]
        for row in extras {
            map[row.videoId] = ShareExtras(profileVisible: row.profileVisible ?? false, hasPassword: row.hasPassword ?? false)
        }
        return ShareListing(videos: list.videos, extras: map)
    }

    func comments(videoID: String) async throws -> [VideoComment] { try await client.comments(videoID: videoID) }

    func postComment(videoID: String, body: String, videoTime: Double?, parentID: String?) async throws -> VideoComment {
        try await client.postComment(videoID: videoID, body: body, videoTime: videoTime, parentID: parentID)
    }

    func streamAsset(videoID: String) -> AVURLAsset {
        AVURLAsset(url: client.videoStreamURL(videoID: videoID), options: ["AVURLAssetHTTPHeaderFieldsKey": client.authorizedHeaders])
    }

    func shareThumbnail(_ video: SharedVideo) async -> UIImage? {
        guard let url = video.thumbnailUrl else { return nil }
        var request = URLRequest(url: url)
        for (key, value) in client.authorizedHeaders { request.setValue(value, forHTTPHeaderField: key) }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return UIImage(data: data)
    }

    func forgetDevices() async throws {
        try await WirelessLinkStore.rotate()
    }
}

final class LiveSession: SessionGateway {
    var user: AccountUser? { SessionStore.load()?.user }

    func signIn(from window: UIWindow?) async throws {
        _ = try await AuthService.shared.signIn(from: window)
    }

    func signOut() async {
        await AuthService.shared.signOut()
    }
}

extension UploadCenter: InboxFeed {}

final class LiveCaptureFeed: CaptureFeed {
    private var model: CaptureHubModel { .shared }
    private var presence: MacPresence { .shared }

    var presenceStatus: MacPresence.Status { presence.status }
    var nearbyMacs: [(id: String, name: String)] { presence.nearbyMacs.map { ($0.id, $0.name) } }
    var connectedMacID: String? { presence.connectedMacID }
    var lastRequest: CaptureHubModel.Request? { model.lastRequest }
    var importError: String? { model.importError }
    var isImporting: Bool { model.isImporting }

    func prefer(macID: String?) { presence.prefer(macID: macID) }
    func streamToMac(from view: UIView) { model.streamToMac(from: view) }
    func recordOnPhone(from view: UIView) { model.recordOnPhone(from: view) }
    func pickScreenshots(from presenter: UIViewController) { model.pickScreenshots(from: presenter) }
    func pickVideos(from presenter: UIViewController) { model.pickVideos(from: presenter) }
    func dismissRequest() { model.dismissRequest() }
    func continueOnMac(projectID: String, name: String) async -> MacPresence.HandoffResult {
        await presence.openOnMac(projectID: projectID, name: name)
    }
}
