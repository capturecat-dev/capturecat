#if DEBUG
import AVFoundation
import Observation
import UIKit

/// `-uiFixtures`: a deterministic synthetic CaptureCat — recordings (one from
/// an iPhone), screenshots, shares with comments, an uploading and a failed
/// inbox take, Mac presence — served through the same seams as the live
/// stack. Never touches the network or the keychain (no APIClient, no
/// SessionStore calls). Frames are drawn locally (FixtureArt) and written to
/// small local movies once (Caches/CaptureCatFixtures), so the player and the
/// thumbnail generator run their REAL code paths on them.
///
/// Extra launch flags: `-uiFixtureSignedOut`, `-uiFixtureSignInFails`,
/// `-uiFixtureEmpty`, `-uiFixturePresence searching|connected|multi|unavailable|signedOut`,
/// `-uiFixtureRequest`, `-uiFixtureImportError`, `-uiFixtureLiveUpload`.
final class FixtureWorld: CloudAPI {
    static let shared = FixtureWorld()

    struct Project {
        var id: String
        var name: String
        var device: Bool
        var still: Bool
        var duration: Double
        var created: Date
        var updated: Date
        var bytes: Int64
        var isOwner: Bool
        var revision: Int
        var hue: CGFloat
    }

    let session = FixtureSession()
    let inbox = FixtureInbox()
    let capture = FixtureCapture()
    private(set) var projects: [Project] = []
    private var shares: [SharedVideo] = []
    private var extras: [String: ShareExtras] = [:]
    private var comments: [String: [VideoComment]] = [:]
    private var documents: [String: String] = [:]
    /// Projects whose NEXT save answers 409 (exercises the rebase path).
    private var conflictOnce: Set<String> = []
    private let prepared: Task<Void, Never>
    static let folder: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("CaptureCatFixtures-v2", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func has(_ flag: String) -> Bool { ProcessInfo.processInfo.arguments.contains(flag) }
    static func value(_ flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private init() {
        let now = Date()
        func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }
        func id(_ n: Int) -> String { String(format: "0F1C5A7E-0000-4000-8000-%012d", n) }
        if !Self.has("-uiFixtureEmpty") {
            projects = [
                Project(id: id(1), name: "Onboarding walkthrough", device: false, still: false, duration: 134, created: ago(30), updated: ago(2), bytes: 182_400_000, isOwner: true, revision: 7, hue: 0.62),
                Project(id: id(2), name: "Checkout bug repro", device: true, still: false, duration: 48, created: ago(6), updated: ago(5), bytes: 61_200_000, isOwner: true, revision: 2, hue: 0.08),
                Project(id: id(3), name: "Screenshot Nov 12 at 4.21.07 PM", device: true, still: true, duration: 8, created: ago(27), updated: ago(26), bytes: 2_100_000, isOwner: true, revision: 1, hue: 0.83),
                Project(id: id(4), name: "Q4 roadmap demo", device: false, still: false, duration: 362, created: ago(80), updated: ago(50), bytes: 512_000_000, isOwner: true, revision: 12, hue: 0.36),
                Project(id: id(5), name: "Settings redesign review", device: false, still: false, duration: 65, created: ago(90), updated: ago(74), bytes: 88_000_000, isOwner: false, revision: 4, hue: 0.52),
                Project(id: id(6), name: "Screenshot Nov 9 at 9.02.44 AM", device: false, still: true, duration: 8, created: ago(120), updated: ago(119), bytes: 3_400_000, isOwner: true, revision: 1, hue: 0.14),
                Project(id: id(7), name: "Login flow on iPhone", device: true, still: false, duration: 92, created: ago(170), updated: ago(168), bytes: 104_000_000, isOwner: true, revision: 3, hue: 0.95),
                Project(id: id(8), name: "Pricing page tour with the new annual plans and team seats", device: false, still: false, duration: 211, created: ago(340), updated: ago(330), bytes: 260_000_000, isOwner: true, revision: 5, hue: 0.72),
            ]
            let base = URL(string: "https://capturecat.so/share/")!
            func share(_ vid: String, _ file: String, project: String?, duration: Double, isPrivate: Bool, comments: Bool, created: Date, bytes: Int64) -> SharedVideo {
                SharedVideo(videoId: vid, fileName: file, contentType: "video/mp4", fileSizeBytes: bytes, durationSeconds: duration,
                            isPrivate: isPrivate, createdAt: created, url: base.appendingPathComponent(vid), projectId: project,
                            commentsEnabled: comments, thumbnailUrl: nil, removed: nil)
            }
            shares = [
                share("fxShareOnboard", "Onboarding walkthrough.mp4", project: id(1), duration: 118, isPrivate: false, comments: true, created: ago(3), bytes: 41_000_000),
                share("fxShareRoadmap", "Q4 roadmap demo.mp4", project: id(4), duration: 340, isPrivate: true, comments: false, created: ago(49), bytes: 120_000_000),
                share("fxShareRelease", "Release notes — November.mp4", project: nil, duration: 96, isPrivate: false, comments: true, created: ago(96), bytes: 33_000_000),
            ]
            extras = [
                "fxShareOnboard": ShareExtras(profileVisible: false, hasPassword: false),
                "fxShareRoadmap": ShareExtras(profileVisible: false, hasPassword: false),
                "fxShareRelease": ShareExtras(profileVisible: true, hasPassword: false),
            ]
            func comment(_ n: Int, _ parent: Int?, _ author: String, owner: Bool, _ body: String, at: Double?, _ hours: Double) -> VideoComment {
                VideoComment(commentId: "c\(n)", parentId: parent.map { "c\($0)" }, authorName: author, authorImage: nil, isOwner: owner,
                             body: body, videoTime: at, createdAt: ago(hours))
            }
            comments = [
                "fxShareOnboard": [
                    comment(1, nil, "Priya Natarajan", owner: false, "The empty state here is lovely. Could the import button be a little more prominent?", at: 14, 2.5),
                    comment(2, 1, "Alex Rivera", owner: true, "Good call — bumping it to a primary button in the next take.", at: nil, 2.2),
                    comment(3, nil, "Sam Okafor", owner: false, "Small typo in the second tooltip (“recieve”).", at: 47, 1.6),
                    comment(4, nil, "Jordan Lee", owner: false, "Love the pacing through the settings section.", at: 92, 0.4),
                ],
                "fxShareRelease": [
                    comment(5, nil, "Mina Park", owner: false, "Shipping this to the whole team today!", at: 31, 20),
                    comment(6, 5, "Alex Rivera", owner: true, "Thanks Mina 🙌", at: nil, 19),
                ],
            ]
            conflictOnce = [id(4)]
        }
        for project in projects { documents[project.id] = Self.document(for: project) }
        let projectsSnapshot = projects
        let sharesSnapshot = shares
        prepared = Task { @MainActor in
            for project in projectsSnapshot {
                await FixtureMovie.ensure(url: Self.movieURL(project.id), duration: project.duration, still: project.still) { t in
                    FixtureArt.frame(device: project.device, still: project.still, hue: project.hue, title: project.name, t: t, duration: project.duration)
                }
            }
            for share in sharesSnapshot {
                let project = projectsSnapshot.first { $0.id == share.projectId }
                let hue = project?.hue ?? 0.45
                let duration = share.durationSeconds ?? 60
                await FixtureMovie.ensure(url: Self.movieURL(share.videoId), duration: duration, still: false) { t in
                    FixtureArt.frame(device: false, still: false, hue: hue, title: (share.fileName as NSString).deletingPathExtension, t: t, duration: duration, exported: true)
                }
            }
        }
    }

    static func movieURL(_ id: String) -> URL { folder.appendingPathComponent("\(id).mp4") }

    private static func document(for project: Project) -> String {
        let data = (try? ProjectDocument.make(ProjectDocument.NewProject(
            id: project.id, name: project.name, createdAt: project.created, videoFileName: "recording.mp4",
            duration: project.duration, sourceKind: project.device ? "device" : "display",
            isStillCapture: project.still, showDeviceFrame: project.device
        ))) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Deterministic, short latency — spinners and skeletons get a beat.
    private func latency(_ ms: UInt64) async {
        try? await Task.sleep(nanoseconds: ms * 1_000_000)
    }

    private func notFound() -> APIError { .http(status: 404, code: "not_found", message: "That project isn't in your library.") }

    // MARK: - CloudAPI

    func me() async throws -> AccountInfo {
        await latency(250)
        return AccountInfo(json: [
            "uid": "fixture-user", "email": "alex@example.com", "tier": "pro",
            "plan": ["name": "pro", "displayName": "Pro"],
            "limits": ["maxTotalStorageBytes": NSNumber(value: Int64(50_000_000_000))],
        ])
    }

    func cloudProjects() async throws -> CloudProjectList {
        await prepared.value
        await latency(350)
        let rows = projects.map {
            CloudProjectSummary(projectId: $0.id, name: $0.name, revision: $0.revision, hasDocument: true, documentSha256: nil,
                                totalBytes: $0.bytes, orgId: $0.isOwner ? nil : "fixture-team", isOwner: $0.isOwner,
                                createdAt: $0.created, updatedAt: $0.updated)
        }
        let used = projects.reduce(Int64(0)) { $0 + $1.bytes } + 6_200_000_000
        return CloudProjectList(projects: rows, storage: StorageUsage(usedBytes: used, limitBytes: 50_000_000_000))
    }

    func cloudProject(_ id: String) async throws -> CloudProjectDetail {
        await prepared.value
        let index = projects.firstIndex { $0.id.caseInsensitiveCompare(id) == .orderedSame }
        await latency(UInt64(180 + 70 * ((index ?? 0) % 4)))
        guard let index else { throw notFound() }
        let project = projects[index]
        let file = CloudRemoteFile(path: "recording.mp4", sha256: "fixture", bytes: project.bytes, contentType: "video/mp4",
                                   source: nil, url: Self.movieURL(project.id))
        return CloudProjectDetail(projectId: project.id, name: project.name, revision: project.revision,
                                  access: project.isOwner ? "owner" : "member", document: documents[project.id],
                                  files: [file], urlsExpireAt: Date().addingTimeInterval(15 * 60), updatedAt: project.updated)
    }

    func deleteCloudProject(_ id: String) async throws {
        await latency(500)
        projects.removeAll { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }

    func saveProject(_ id: String, document: Data, baseRevision: Int) async throws -> SaveOutcome {
        await latency(450)
        guard let index = projects.firstIndex(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) else { throw notFound() }
        if conflictOnce.contains(projects[index].id) {
            // "Someone saved on the Mac first": bump the revision, change an
            // unrelated field, and hand the newer document back.
            conflictOnce.remove(projects[index].id)
            projects[index].revision += 1
            var theirs = (try? LosslessJSON.parse(Data(documents[projects[index].id]!.utf8))) ?? .object([])
            theirs["trimStart"] = .number(1.5)
            documents[projects[index].id] = String(decoding: theirs.serialized(), as: UTF8.self)
            return .conflict(revision: projects[index].revision, document: documents[projects[index].id])
        }
        guard baseRevision == projects[index].revision else {
            return .conflict(revision: projects[index].revision, document: documents[projects[index].id])
        }
        let text = String(decoding: document, as: UTF8.self)
        documents[projects[index].id] = text
        projects[index].revision += 1
        projects[index].updated = Date()
        if let facts = ProjectDocument.facts(document), let name = facts.name { projects[index].name = name }
        print("FIXTURE saved \(id) rev=\(projects[index].revision) trimStart=\(ProjectDocument.facts(document)?.trimStart ?? -1)")
        return .saved(revision: projects[index].revision)
    }

    func shares() async throws -> ShareListing {
        await prepared.value
        await latency(300)
        return ShareListing(videos: shares, extras: extras)
    }

    func comments(videoID: String) async throws -> [VideoComment] {
        await latency(400)
        return comments[videoID] ?? []
    }

    func postComment(videoID: String, body: String, videoTime: Double?, parentID: String?) async throws -> VideoComment {
        await latency(500)
        let comment = VideoComment(commentId: UUID().uuidString, parentId: parentID, authorName: "Alex Rivera", authorImage: nil,
                                   isOwner: true, body: body, videoTime: videoTime, createdAt: Date())
        comments[videoID, default: []].append(comment)
        return comment
    }

    func streamAsset(videoID: String) -> AVURLAsset {
        AVURLAsset(url: Self.movieURL(videoID))
    }

    func shareThumbnail(_ video: SharedVideo) async -> UIImage? { nil }

    func forgetDevices() async throws {
        await latency(700)
    }

    /// A finished fixture upload lands as a new project.
    func addProject(name: String, device: Bool, still: Bool) {
        let project = Project(id: UUID().uuidString, name: name, device: device, still: still, duration: still ? 8 : 37,
                              created: Date(), updated: Date(), bytes: 24_000_000, isOwner: true, revision: 1, hue: 0.28)
        projects.insert(project, at: 0)
        documents[project.id] = Self.document(for: project)
        Task {
            await FixtureMovie.ensure(url: Self.movieURL(project.id), duration: project.duration, still: still) { t in
                FixtureArt.frame(device: device, still: still, hue: project.hue, title: name, t: t, duration: project.duration)
            }
            NotificationCenter.default.post(name: .ccLibraryShouldRefresh, object: nil)
        }
    }
}

// MARK: - Session

final class FixtureSession: SessionGateway {
    private var signedIn = !FixtureWorld.has("-uiFixtureSignedOut")
    private let fixtureUser = AccountUser(id: "fixture-user", email: "alex@example.com", name: "Alex Rivera", image: nil)

    var user: AccountUser? { signedIn ? fixtureUser : nil }

    func signIn(from window: UIWindow?) async throws {
        try? await Task.sleep(nanoseconds: 900_000_000)
        if FixtureWorld.has("-uiFixtureSignInFails") {
            throw APIError.transport("Couldn't reach CaptureCat. Check your connection and try again.")
        }
        signedIn = true
        NotificationCenter.default.post(name: .ccSessionDidChange, object: nil)
    }

    func signOut() async {
        try? await Task.sleep(nanoseconds: 400_000_000)
        signedIn = false
        NotificationCenter.default.post(name: .ccSessionDidChange, object: nil)
    }
}

// MARK: - Inbox

@Observable
final class FixtureInbox: InboxFeed {
    private(set) var takes: [PendingTake] = []
    private(set) var progress: [String: PublishProgress] = [:]
    @ObservationIgnored private var timers: [String: Timer] = [:]

    init() {
        guard !FixtureWorld.has("-uiFixtureEmpty") else { return }
        let now = Date()
        takes = [
            PendingTake(id: "FIXTURE-TAKE-UPLOADING", kind: .screenRecording, name: "Screen Recording Nov 13 at 9.41.02 AM",
                        createdAt: now.addingTimeInterval(-300), mediaFile: "recording.mp4", contentType: "video/mp4",
                        duration: 74, pixelWidth: 1179, pixelHeight: 2556, state: .uploading, error: nil),
            PendingTake(id: "FIXTURE-TAKE-FAILED", kind: .screenshot, name: "Screenshot Nov 13 at 9.38.10 AM",
                        createdAt: now.addingTimeInterval(-600), mediaFile: "recording.mp4", contentType: "video/mp4",
                        duration: 8, pixelWidth: 1179, pixelHeight: 2556, state: .failed,
                        error: "The upload didn't finish (HTTP 503). Try again."),
        ]
        progress["FIXTURE-TAKE-UPLOADING"] = PublishProgress(phase: .uploading, fraction: 0.55, message: "Uploading…")
        if FixtureWorld.has("-uiFixtureLiveUpload") { simulate("FIXTURE-TAKE-UPLOADING", from: 0.55) }
    }

    func retry(_ id: String) {
        guard let index = takes.firstIndex(where: { $0.id == id }) else { return }
        takes[index].state = .uploading
        takes[index].error = nil
        progress[id] = PublishProgress(phase: .preparing, fraction: 0, message: "Preparing…")
        simulate(id, from: 0)
    }

    private func simulate(_ id: String, from start: Double) {
        var fraction = start
        timers[id]?.invalidate()
        timers[id] = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                fraction += 0.12
                if fraction >= 1 {
                    timer.invalidate()
                    self.timers[id] = nil
                    self.progress[id] = nil
                    if let take = self.takes.first(where: { $0.id == id }) {
                        self.takes.removeAll { $0.id == id }
                        FixtureWorld.shared.addProject(name: take.name, device: take.sourceKind == "device", still: take.kind == .screenshot)
                    }
                } else {
                    self.progress[id] = PublishProgress(phase: .uploading, fraction: fraction, message: "Uploading…")
                }
            }
        }
    }

    func discard(_ id: String) {
        timers[id]?.invalidate()
        takes.removeAll { $0.id == id }
        progress[id] = nil
    }

    func processPending() {}
    func reload() {}
}

// MARK: - Capture / presence

@Observable
final class FixtureCapture: CaptureFeed {
    private(set) var presenceStatus: MacPresence.Status
    private(set) var nearbyMacs: [(id: String, name: String)] = []
    private(set) var connectedMacID: String?
    private(set) var lastRequest: CaptureHubModel.Request?
    private(set) var importError: String?
    private(set) var isImporting = false

    init() {
        switch FixtureWorld.value("-uiFixturePresence") ?? "connected" {
        case "searching": presenceStatus = .searching
        case "unavailable": presenceStatus = .unavailable("Couldn't reach CaptureCat to link this iPhone. Check your connection.")
        case "signedOut": presenceStatus = .signedOut
        case "multi":
            presenceStatus = .connected(macName: "Studio Mac")
            nearbyMacs = [("mac-studio", "Studio Mac"), ("mac-air", "Alex's MacBook Air")]
            connectedMacID = "mac-studio"
        default:
            presenceStatus = .connected(macName: "Alex's MacBook Pro")
            nearbyMacs = [("mac-pro", "Alex's MacBook Pro")]
            connectedMacID = "mac-pro"
        }
        if FixtureWorld.has("-uiFixtureRequest") {
            lastRequest = CaptureHubModel.Request(macID: "mac-pro", macName: "Alex's MacBook Pro", at: Date())
        }
        if FixtureWorld.has("-uiFixtureImportError") { importError = "Some screenshots couldn't be imported." }
    }

    /// Fixture-only: drive the presence states (probes, demos).
    func setStatus(_ status: MacPresence.Status) { presenceStatus = status }

    func prefer(macID: String?) {
        connectedMacID = macID
        if let name = nearbyMacs.first(where: { $0.id == macID })?.name { presenceStatus = .connected(macName: name) }
    }

    func streamToMac(from view: UIView) {
        AppToaster.shared.show(title: "Start Broadcast", message: "The live app opens the system broadcast sheet here.", symbol: "wifi")
    }

    func recordOnPhone(from view: UIView) {
        AppToaster.shared.show(title: "Start Broadcast", message: "The live app opens the system broadcast sheet here.", symbol: "record")
    }

    func pickScreenshots(from presenter: UIViewController) { simulateImport() }
    func pickVideos(from presenter: UIViewController) { simulateImport() }

    private func simulateImport() {
        isImporting = true
        importError = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            self?.isImporting = false
            AppToaster.shared.show(title: "Imported", message: "Fixture mode doesn't open Photos.", variant: .success)
        }
    }

    func dismissRequest() { lastRequest = nil }
}
#endif
