import AppKit
import AVFoundation
import Foundation
import ImageIO
import Observation
import os
import UniformTypeIdentifiers

nonisolated private let libraryLogger = Logger(subsystem: "so.capturecat.CaptureCat", category: "CloudLibrary")

// MARK: - Listing (pure)

/// One project in the signed-in account's cloud library — a row of
/// `GET /api/cloud-projects` (`projectSummary` in
/// apps/api/src/routes/cloud-projects.ts). Projects recorded on the iPhone or
/// made in the web app live only here until this Mac clones one.
nonisolated struct CloudLibraryItem: Equatable, Sendable {
    let projectID: UUID
    let name: String
    let revision: Int
    /// false while the sender is still uploading (staged, never saved): there
    /// is no project.json to clone yet.
    let hasDocument: Bool
    let totalBytes: Int64
    let isOwner: Bool
    let orgID: String?
    let createdAt: Date?
    let updatedAt: Date?

    /// The card's date: when it last changed in the cloud.
    var date: Date? { updatedAt ?? createdAt }
}

/// What a cloud project is, read from its project.json — the card's tag and
/// the Videos / Images filter. Raw values are the thumbnail cache's
/// persistence identity (CloudThumbnailCache.Meta) — never rename one.
nonisolated enum CloudLibraryKind: String, Sendable {
    case recording
    /// `recordingSourceKind: "device"` — an iPhone/iPad screen take.
    case device
    /// `isStillCapture: true` — a screenshot (an iPhone screenshot included).
    case still

    var tag: String? {
        switch self {
        case .recording: return nil
        case .device: return "iPhone"
        case .still: return "Screenshot"
        }
    }

    var tagSymbol: String {
        switch self {
        case .still: return "photo"
        case .device, .recording: return "iphone"
        }
    }

    var isImage: Bool { self == .still }
}

/// The browser's cloud listing as pure functions, so `--cloud-sync-test` can
/// pin every rule without a network: parse the API's JSON, merge it against
/// what this Mac already holds, classify a document, pick the file to
/// thumbnail.
nonisolated enum CloudLibraryListing {
    /// `{ projects: [...], storage }` → items; nil when the body isn't that
    /// shape. A row without a valid UUID is skipped, not fatal.
    static func parse(_ data: Data) -> [CloudLibraryItem]? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = object["projects"] as? [[String: Any]] else { return nil }
        return rows.compactMap(item(from:))
    }

    static func item(from row: [String: Any]) -> CloudLibraryItem? {
        guard let raw = row["projectId"] as? String, let id = UUID(uuidString: raw) else { return nil }
        let revision = (row["revision"] as? NSNumber)?.intValue ?? 0
        let name = (row["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CloudLibraryItem(
            projectID: id,
            name: (name?.isEmpty == false ? name! : "Untitled"),
            revision: revision,
            hasDocument: (row["hasDocument"] as? Bool) ?? (revision > 0),
            totalBytes: (row["totalBytes"] as? NSNumber)?.int64Value ?? 0,
            isOwner: (row["isOwner"] as? Bool) ?? true,
            orgID: row["orgId"] as? String,
            createdAt: CloudAPIDate.parse(row["createdAt"]),
            updatedAt: CloudAPIDate.parse(row["updatedAt"])
        )
    }

    /// The cloud items the browser shows: signed in only; never one this Mac
    /// already has (`localIDs` — the store's projects plus any folder that
    /// holds a project.json), never one being cloned right now (`inFlight`),
    /// never one with no document yet (still uploading), each id once.
    /// Newest change first, then name, then id — a stable order.
    static func cloudOnly(
        _ cloud: [CloudLibraryItem],
        signedIn: Bool,
        localIDs: Set<UUID>,
        inFlight: Set<UUID>
    ) -> [CloudLibraryItem] {
        guard signedIn else { return [] }
        var seen = Set<UUID>()
        let kept = cloud.filter { item in
            item.hasDocument
                && !localIDs.contains(item.projectID)
                && !inFlight.contains(item.projectID)
                && seen.insert(item.projectID).inserted
        }
        return kept.sorted { lhs, rhs in
            let l = lhs.date ?? .distantPast
            let r = rhs.date ?? .distantPast
            if l != r { return l > r }
            if lhs.name != rhs.name { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
            return lhs.projectID.uuidString < rhs.projectID.uuidString
        }
    }

    /// Kind from project.json bytes. A still wins over a device take (an
    /// iPhone screenshot is a screenshot); anything unreadable is a recording.
    static func kind(ofDocument data: Data?) -> CloudLibraryKind {
        guard let object = documentObject(data) else { return .recording }
        if (object["isStillCapture"] as? Bool) == true { return .still }
        if (object["recordingSourceKind"] as? String) == "device" { return .device }
        return .recording
    }

    static func duration(ofDocument data: Data?) -> Double? {
        guard let value = (documentObject(data)?["duration"] as? NSNumber)?.doubleValue,
              value.isFinite, value > 0 else { return nil }
        return value
    }

    /// The committed file to draw the card from: the one the document's
    /// `videoURL` names (Mac: an absolute path; web/iPhone:
    /// `file:///CaptureCat/Projects/<id>/recording.mov`), else the first
    /// video that isn't the camera, else the first image.
    static func previewFile(in files: [CloudRemoteFile], document: Data?) -> CloudRemoteFile? {
        if let raw = documentObject(document)?["videoURL"] as? String {
            let name = URL(string: raw)?.lastPathComponent ?? (raw as NSString).lastPathComponent
            if !name.isEmpty, let named = files.first(where: { ($0.path as NSString).lastPathComponent == name }) {
                return named
            }
        }
        func isCamera(_ file: CloudRemoteFile) -> Bool {
            (file.path as NSString).lastPathComponent.lowercased().hasPrefix("camera")
        }
        if let video = files.first(where: { $0.contentType.hasPrefix("video/") && !isCamera($0) }) {
            return video
        }
        return files.first { $0.contentType.hasPrefix("image/") && !isCamera($0) }
    }

    private static func documentObject(_ data: Data?) -> [String: Any]? {
        guard let data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

// MARK: - Thumbnail cache

/// Card art for cloud projects, on disk, keyed by project id AND revision:
/// a new cloud revision is a new key (the old art is pruned when the new one
/// lands), so an edit made on the phone or the web redraws the card while
/// an unchanged project never costs another request.
///
///     <dir>/<id>-r<revision>.jpg   the frame (absent: nothing to draw)
///     <dir>/<id>-r<revision>.json  Meta — written LAST, so a hit is complete
nonisolated struct CloudThumbnailCache: Sendable {
    let directory: URL

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CaptureCat/CloudThumbnails", isDirectory: true)
    }

    struct Entry: Equatable, Sendable {
        let revision: Int
        let kind: CloudLibraryKind
        let duration: Double?
        let imageURL: URL?
    }

    /// Hand-rolled Codable (house rule): every key optional on decode.
    struct Meta: Codable, Equatable {
        var kind: String
        var duration: Double?
        var hasImage: Bool

        enum CodingKeys: String, CodingKey { case kind, duration, hasImage }

        init(kind: String, duration: Double?, hasImage: Bool) {
            self.kind = kind
            self.duration = duration
            self.hasImage = hasImage
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? CloudLibraryKind.recording.rawValue
            duration = try c.decodeIfPresent(Double.self, forKey: .duration)
            hasImage = try c.decodeIfPresent(Bool.self, forKey: .hasImage) ?? false
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(kind, forKey: .kind)
            try c.encodeIfPresent(duration, forKey: .duration)
            try c.encode(hasImage, forKey: .hasImage)
        }
    }

    static func baseName(projectID: UUID, revision: Int) -> String {
        "\(projectID.uuidString.lowercased())-r\(revision)"
    }

    func imageURL(projectID: UUID, revision: Int) -> URL {
        directory.appendingPathComponent(Self.baseName(projectID: projectID, revision: revision) + ".jpg")
    }

    func metaURL(projectID: UUID, revision: Int) -> URL {
        directory.appendingPathComponent(Self.baseName(projectID: projectID, revision: revision) + ".json")
    }

    /// The entry for exactly this id + revision (nil = never cached, or a
    /// different revision is).
    func lookup(projectID: UUID, revision: Int) -> Entry? {
        guard let data = try? Data(contentsOf: metaURL(projectID: projectID, revision: revision)),
              let meta = try? JSONDecoder().decode(Meta.self, from: data) else { return nil }
        let image = imageURL(projectID: projectID, revision: revision)
        let hasImage = meta.hasImage && FileManager.default.fileExists(atPath: image.path)
        return Entry(revision: revision, kind: CloudLibraryKind(rawValue: meta.kind) ?? .recording,
                     duration: meta.duration, imageURL: hasImage ? image : nil)
    }

    /// Writes the frame (if any) then the meta, and drops every other
    /// revision of this project.
    @discardableResult
    func store(projectID: UUID, revision: Int, kind: CloudLibraryKind, duration: Double?, image: CGImage?) throws -> Entry {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let imageURL = imageURL(projectID: projectID, revision: revision)
        var wroteImage = false
        if let image {
            guard let dest = CGImageDestinationCreateWithURL(imageURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
            wroteImage = true
        } else {
            try? fm.removeItem(at: imageURL)
        }
        let meta = Meta(kind: kind.rawValue, duration: duration, hasImage: wroteImage)
        try JSONEncoder().encode(meta).write(to: metaURL(projectID: projectID, revision: revision), options: .atomic)
        prune(projectID: projectID, keepingRevision: revision)
        return Entry(revision: revision, kind: kind, duration: duration, imageURL: wroteImage ? imageURL : nil)
    }

    /// Remove every cached revision of `projectID` except `keepingRevision`.
    func prune(projectID: UUID, keepingRevision: Int) {
        let prefix = projectID.uuidString.lowercased() + "-r"
        let keep = Self.baseName(projectID: projectID, revision: keepingRevision)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        where name.hasPrefix(prefix) && (name as NSString).deletingPathExtension != keep {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Drop art for projects no longer listed (deleted in the cloud, or now
    /// on this Mac with their own thumbnail).
    func prune(keeping projectIDs: Set<UUID>) {
        let keep = Set(projectIDs.map { $0.uuidString.lowercased() })
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] {
            guard let range = name.range(of: "-r") else { continue }
            if !keep.contains(String(name[..<range.lowerBound])) {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }
}

// MARK: - Thumbnailer

/// One frame of a cloud recording WITHOUT downloading it: AVFoundation reads
/// the presigned URL with byte-range requests (the movie header plus the
/// nearest sync frame), never the whole file. A still image is small and is
/// fetched whole (bounded).
nonisolated enum CloudThumbnailer {
    static let maxPixel: CGFloat = 640
    /// Images above this are not fetched for a thumbnail.
    static let maxImageBytes: Int64 = 25 * 1024 * 1024

    static func thumbnail(of file: CloudRemoteFile, duration: Double?) async -> CGImage? {
        guard let url = file.url else { return nil }
        if file.contentType.hasPrefix("image/") {
            return await imageThumbnail(url: url, bytes: file.bytes)
        }
        // R2 object keys carry no extension: say what the bytes are.
        let asset = AVURLAsset(url: url, options: [AVURLAssetOverrideMIMETypeKey: file.contentType])
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        // Any nearby sync frame will do — fewer bytes over the wire.
        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        // Same moment ProjectStore.generateThumbnail picks for local cards,
        // pulled in for very short clips.
        let seconds = min(0.5, max(0, (duration ?? 1) / 2))
        do {
            return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        } catch {
            libraryLogger.info("cloud thumbnail failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func imageThumbnail(url: URL, bytes: Int64) async -> CGImage? {
        guard bytes <= maxImageBytes else { return nil }
        let data: Data
        if url.isFileURL {
            guard let local = try? Data(contentsOf: url) else { return nil }
            data = local
        } else {
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            guard let (body, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
            data = body
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

// MARK: - Transport

/// The two reads the library needs. `HTTPCloudLibraryTransport` talks to the
/// API; `--cloud-sync-test` swaps in a stub.
protocol CloudLibraryTransport: AnyObject {
    func list() async throws -> [CloudLibraryItem]
    /// project.json + presigned GETs (nil = gone).
    func detail(projectID: UUID) async throws -> CloudRemoteProject?
}

final class HTTPCloudLibraryTransport: CloudLibraryTransport {
    private let projects: HTTPCloudProjectTransport

    init(baseURL: String = CaptureCatAPI.baseURL) {
        projects = HTTPCloudProjectTransport(baseURL: baseURL)
    }

    func list() async throws -> [CloudLibraryItem] {
        var request = try projects.request("GET", "")
        request.timeoutInterval = 20
        let (data, http) = try await projects.send(request)
        guard http.statusCode == 200 else { throw projects.apiError(data, http) }
        guard let items = CloudLibraryListing.parse(data) else { throw CloudSyncError.invalidResponse }
        return items
    }

    func detail(projectID: UUID) async throws -> CloudRemoteProject? {
        try await projects.fetch(projectID: projectID)
    }
}

// MARK: - Library (observable)

/// Card art + tag for one cloud project.
struct CloudLibraryPreview {
    let revision: Int
    let kind: CloudLibraryKind
    let duration: Double?
    let image: NSImage?
    /// false: the frame failed to draw this round (the tag is real; the art
    /// is retried after the next listing).
    var isComplete = true
}

/// The account's cloud projects for the project browser's Cloud section.
///
/// Quiet by design: signed out it holds nothing and never touches the
/// network; a failed listing (offline, expired session, a plan without
/// cloud storage) keeps what it had and says nothing. The browser observes
/// `items` / `cloning` / `previews` through its `withObservationTracking`
/// loop and refreshes on appear, on window focus and every 60 s while
/// visible. `cloning` is fed by `CloudSyncController.openFromCloud` — every
/// clone, whether a browser click or a deep link started it.
@MainActor
@Observable
final class CloudLibrary {
    static let shared = CloudLibrary()

    /// The account's cloud projects as last listed (empty signed out).
    private(set) var items: [CloudLibraryItem] = []
    /// Projects being cloned to this Mac right now.
    private(set) var cloning: Set<UUID> = []
    /// Card art + tag, filled lazily for the projects on screen.
    private(set) var previews: [UUID: CloudLibraryPreview] = [:]
    /// A listing succeeded for the current session.
    private(set) var hasListed = false
    /// Harness seam: overrides the browser's signed-in state (nil = the real
    /// AuthService). Observed, so flipping it re-renders the browser.
    var signedInOverride: Bool?

    @ObservationIgnored var transport: CloudLibraryTransport = HTTPCloudLibraryTransport()
    @ObservationIgnored var cache = CloudThumbnailCache(directory: CloudThumbnailCache.defaultDirectory)
    /// Whether a session exists to list with (the HTTP transport's bearer).
    @ObservationIgnored var hasSession: () -> Bool = { AuthKeychain.currentToken() != nil }
    /// Opening a cloud card. Default: the existing clone path with its
    /// progress dialog. Harness seam.
    @ObservationIgnored var opener: (UUID, AppState) -> Void = { id, appState in
        CloudSyncController.shared.openFromCloud(projectID: id, appState: appState, title: "Opening from the Cloud")
    }
    @ObservationIgnored var minimumRefreshInterval: TimeInterval = 15
    @ObservationIgnored var maxConcurrentPreviews = 3
    /// Counters for the gate (requests actually issued).
    @ObservationIgnored private(set) var listRequests = 0
    @ObservationIgnored private(set) var detailRequests = 0

    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var lastListed: Date?
    /// Bumped by `clear()`: results that belong to a previous session drop.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var previewQueue: [CloudLibraryItem] = []
    @ObservationIgnored private var previewLoading: Set<UUID> = []
    /// id → revision whose art failed this round (retried after the next listing).
    @ObservationIgnored private var previewFailures: [UUID: Int] = [:]

    init() {}

    var isRefreshing: Bool { refreshTask != nil }

    /// What the browser shows (see `CloudLibraryListing.cloudOnly`).
    func cloudOnly(signedIn: Bool, localIDs: Set<UUID>) -> [CloudLibraryItem] {
        CloudLibraryListing.cloudOnly(items, signedIn: signedIn, localIDs: localIDs, inFlight: cloning)
    }

    /// List again. `force` skips the throttle (appear, the 60 s tick);
    /// window focus refreshes no more than every `minimumRefreshInterval`.
    func refresh(force: Bool = false) {
        guard hasSession() else {
            clear()
            return
        }
        guard refreshTask == nil else { return }
        if !force, let lastListed, Date().timeIntervalSince(lastListed) < minimumRefreshInterval { return }
        let generation = self.generation
        listRequests += 1
        refreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let listed = try await self.transport.list()
                guard self.generation == generation else { return }
                self.refreshTask = nil
                self.lastListed = Date()
                if listed != self.items { self.items = listed }
                if !self.hasListed { self.hasListed = true }
                self.previewFailures = [:]
                let cache = self.cache
                let ids = Set(listed.map(\.projectID))
                Task.detached(priority: .utility) { cache.prune(keeping: ids) }
            } catch {
                guard self.generation == generation else { return }
                self.refreshTask = nil
                libraryLogger.info("cloud listing skipped: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Await the in-flight listing (gate helper).
    func waitForRefresh() async {
        await refreshTask?.value
    }

    /// Forget everything this session listed (sign-out, account switch).
    /// In-flight clones are kept — they finish on their own.
    func clear() {
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        lastListed = nil
        previewQueue = []
        previewLoading = []
        previewFailures = [:]
        if !items.isEmpty { items = [] }
        if !previews.isEmpty { previews = [:] }
        if hasListed { hasListed = false }
    }

    /// The account the listing belongs to (`bind`).
    @ObservationIgnored private(set) var boundAccount: String?

    /// Sign-in, sign-out or a different account: a listing never outlives
    /// the account it was made for.
    func bind(account: String?) {
        guard account != boundAccount else { return }
        boundAccount = account
        clear()
    }

    func setCloning(_ projectID: UUID, _ active: Bool) {
        if active {
            cloning.insert(projectID)
        } else {
            cloning.remove(projectID)
        }
    }

    func open(_ projectID: UUID, appState: AppState) {
        opener(projectID, appState)
    }

    /// Art + tag for these items: from the disk cache when this revision is
    /// there, else fetched (detail → one frame), a few at a time.
    func requestPreviews(for wanted: [CloudLibraryItem]) {
        for item in wanted {
            let id = item.projectID
            if let preview = previews[id], preview.isComplete, preview.revision >= item.revision { continue }
            if previewLoading.contains(id) || previewFailures[id] == item.revision { continue }
            if let entry = cache.lookup(projectID: id, revision: item.revision) {
                previews[id] = CloudLibraryPreview(
                    revision: entry.revision, kind: entry.kind, duration: entry.duration,
                    image: entry.imageURL.flatMap(NSImage.init(contentsOf:))
                )
                continue
            }
            if !previewQueue.contains(where: { $0.projectID == id }) { previewQueue.append(item) }
        }
        pumpPreviews()
    }

    private func pumpPreviews() {
        while previewLoading.count < maxConcurrentPreviews, !previewQueue.isEmpty {
            let item = previewQueue.removeFirst()
            previewLoading.insert(item.projectID)
            let generation = self.generation
            Task { [weak self] in
                guard let self else { return }
                let preview = await self.loadPreview(item)
                guard self.generation == generation else { return }
                self.previewLoading.remove(item.projectID)
                if let preview {
                    self.previews[item.projectID] = preview
                } else {
                    self.previewFailures[item.projectID] = item.revision
                }
                self.pumpPreviews()
            }
        }
    }

    /// nil = try again after the next listing (network or decode failure).
    private func loadPreview(_ item: CloudLibraryItem) async -> CloudLibraryPreview? {
        detailRequests += 1
        let remote: CloudRemoteProject
        do {
            guard let fetched = try await transport.detail(projectID: item.projectID) else { return nil }
            remote = fetched
        } catch {
            return nil
        }
        let kind = CloudLibraryListing.kind(ofDocument: remote.document)
        let duration = CloudLibraryListing.duration(ofDocument: remote.document)
        // Cache under the revision the detail reports — it may be newer
        // than the listing that asked.
        let revision = max(remote.revision, item.revision)
        let file = CloudLibraryListing.previewFile(in: remote.files, document: remote.document)
        var image: CGImage?
        if let file {
            image = await CloudThumbnailer.thumbnail(of: file, duration: duration)
            // A file to draw that wouldn't draw: show the tag now, retry the
            // frame later — never cache "no art" for it.
            if image == nil {
                previewFailures[item.projectID] = item.revision
                return CloudLibraryPreview(revision: revision, kind: kind, duration: duration, image: nil, isComplete: false)
            }
        }
        let cache = self.cache
        let id = item.projectID
        let frame = image
        let entry = await Task.detached(priority: .utility) {
            try? cache.store(projectID: id, revision: revision, kind: kind, duration: duration, image: frame)
        }.value
        let nsImage = image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        return CloudLibraryPreview(revision: entry?.revision ?? revision, kind: kind, duration: duration, image: nsImage)
    }
}
