import Foundation
import Observation
import UIKit

/// The library as the phone knows it: cloud projects, shares, and the facts
/// each project's document carries (kind, duration, still capture) — fetched
/// lazily for what's on screen, a few at a time, cached by
/// projectId + revision in memory AND on disk, so an unchanged revision is
/// never fetched twice. Refreshing re-lists projects and shares (that's how
/// edits made on the Mac or the web arrive): a project whose revision moved
/// simply misses the cache and is re-read when it's next on screen.
@Observable
final class LibraryStore {
    static let shared = LibraryStore()

    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private(set) var projects: [CloudProjectSummary] = []
    private(set) var shares: [SharedVideo] = []
    private(set) var shareExtras: [String: ShareExtras] = [:]
    private(set) var storage: StorageUsage?
    private(set) var phase: Phase = .idle
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?
    /// Facts by `id@revision` (only the current revision is ever looked up).
    private(set) var facts: [String: ProjectDocument.Facts] = [:]
    /// Revisions whose document is missing or unreadable (never refetched).
    private(set) var factsUnavailable: Set<String> = []

    @ObservationIgnored private var api: CloudAPI { AppEnvironment.shared.api }
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var details: [String: (detail: CloudProjectDetail, fetched: Date)] = [:]
    @ObservationIgnored private var detailTasks: [String: Task<CloudProjectDetail, Error>] = [:]
    @ObservationIgnored private var factsQueue: [CloudProjectSummary] = []
    @ObservationIgnored private var factsInFlight: Set<String> = []
    @ObservationIgnored private let factsConcurrency = 3
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored let cache = LibraryDiskCache()

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .ccLibraryShouldRefresh, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LibraryStore.shared.refresh() }
        })
    }

    // MARK: - Lookup

    func project(_ id: String) -> CloudProjectSummary? {
        projects.first { $0.projectId.caseInsensitiveCompare(id) == .orderedSame }
    }

    func share(_ videoID: String) -> SharedVideo? { shares.first { $0.videoId == videoID } }

    /// The newest share exported from this project.
    func share(linkedTo projectID: String) -> SharedVideo? {
        shares.filter { $0.projectId?.caseInsensitiveCompare(projectID) == .orderedSame && $0.removed == nil }
            .max { $0.createdAt < $1.createdAt }
    }

    /// Facts for the listed revision — or, while an edit made elsewhere (a
    /// rename on the Mac, a trim on the web) is being fetched, the newest
    /// facts known for that project, so the card never blanks out between
    /// two revisions. `factsKnown` stays exact, so the new revision is still
    /// requested.
    func facts(for project: CloudProjectSummary) -> ProjectDocument.Facts? {
        if let exact = facts[Self.key(project.projectId, project.revision)] { return exact }
        return Self.newest(in: facts, forProject: project.projectId)
    }

    /// The value with the highest revision among `id@revision` keys.
    static func newest<V>(in values: [String: V], forProject id: String, keyPrefix: String = "") -> V? {
        let prefix = keyPrefix + id.uppercased() + "@"
        var best: (Int, V)?
        for (key, value) in values where key.hasPrefix(prefix) {
            let revision = Int(key.dropFirst(prefix.count)) ?? -1
            if best == nil || revision > best!.0 { best = (revision, value) }
        }
        return best?.1
    }

    func factsKnown(for project: CloudProjectSummary) -> Bool {
        let key = Self.key(project.projectId, project.revision)
        return facts[key] != nil || factsUnavailable.contains(key)
    }

    static func key(_ id: String, _ revision: Int) -> String { "\(id.uppercased())@\(revision)" }

    /// Projects the phone can play, newest edit first.
    var sortedProjects: [CloudProjectSummary] { projects.sorted { $0.updatedAt > $1.updatedAt } }

    /// Shares not represented by a project card (no project, or not ours).
    var standaloneShares: [SharedVideo] {
        let ids = Set(projects.map { $0.projectId.uppercased() })
        return shares.filter { share in
            guard let pid = share.projectId else { return true }
            return !ids.contains(pid.uppercased())
        }
    }

    // MARK: - Refresh

    /// Re-list projects and shares. Coalesces: a refresh already running is
    /// joined, not duplicated.
    @discardableResult
    func refresh() -> Task<Void, Never> {
        if let refreshTask { return refreshTask }
        let task = Task { @MainActor in
            await self.performRefresh()
            self.refreshTask = nil
        }
        refreshTask = task
        return task
    }

    /// Refresh unless one landed in the last `seconds`.
    func refreshIfStale(_ seconds: TimeInterval = 5) {
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < seconds { return }
        refresh()
    }

    /// The last listing this account saw, shown at launch while the network
    /// refresh runs (measured on an iPhone: without it the library showed no
    /// projects — and so no thumbnails — for ~2 s after every launch).
    private func restoreSavedListing() {
        guard projects.isEmpty, shares.isEmpty, phase == .idle,
              let user = AppEnvironment.shared.session.user,
              let saved = cache.listing(forUser: user.id) else { return }
        projects = saved.projects
        storage = saved.storage
        shares = saved.shares
        shareExtras = saved.shareExtras
        phase = .loaded
        loadCachedFacts()
    }

    private func performRefresh() async {
        restoreSavedListing()
        isRefreshing = true
        if phase == .idle || (phase != .loaded && projects.isEmpty) { phase = .loading }
        defer { isRefreshing = false }
        do {
            async let projectList = api.cloudProjects()
            async let shareList = api.shares()
            let (list, listing) = try await (projectList, shareList)
            if list.projects != projects { projects = list.projects }
            if list.storage != storage { storage = list.storage }
            if listing.videos != shares { shares = listing.videos }
            if listing.extras != shareExtras { shareExtras = listing.extras }
            phase = .loaded
            lastRefresh = Date()
            if let user = AppEnvironment.shared.session.user {
                cache.storeListing(.init(userID: user.id, projects: projects, storage: storage,
                                         shares: shares, shareExtras: shareExtras))
            }
            loadCachedFacts()
            ThumbnailStore.shared.retryFailed()
            // Drop in-memory details whose revision moved (an edit landed).
            for (id, entry) in details where project(id)?.revision != entry.detail.revision {
                details[id] = nil
            }
        } catch {
            if case APIError.signedOut = error { return }
            let message = error.localizedDescription
            if projects.isEmpty && shares.isEmpty { phase = .failed(message) } else { AppToaster.shared.show(title: "Couldn't refresh", message: message, variant: .warning) }
        }
    }

    /// Fill memory from the disk cache for every listed revision.
    private func loadCachedFacts() {
        var additions: [String: ProjectDocument.Facts] = [:]
        for project in projects {
            let key = Self.key(project.projectId, project.revision)
            guard facts[key] == nil, let cached = cache.facts(key) else { continue }
            additions[key] = cached
        }
        if !additions.isEmpty { facts.merge(additions) { $1 } }
    }

    // MARK: - Facts (lazy, limited concurrency)

    /// Ask for facts of these projects (visible cards). Cached revisions are
    /// free; the rest queue up, `factsConcurrency` at a time.
    func requestFacts(for wanted: [CloudProjectSummary]) {
        for project in wanted {
            let key = Self.key(project.projectId, project.revision)
            guard facts[key] == nil, !factsUnavailable.contains(key), !factsInFlight.contains(key) else { continue }
            if let cached = cache.facts(key) {
                facts[key] = cached
                continue
            }
            guard !factsQueue.contains(where: { Self.key($0.projectId, $0.revision) == key }) else { continue }
            factsQueue.append(project)
        }
        pumpFacts()
    }

    /// How many projects still have no facts (for the filter's status line).
    var unknownFactsCount: Int { projects.filter { !factsKnown(for: $0) }.count }

    #if DEBUG
    var debugFactsState: String {
        "queue=\(factsQueue.count) inFlight=\(factsInFlight.sorted()) known=\(facts.count) unavailable=\(factsUnavailable.count) details=\(details.count) detailTasks=\(detailTasks.count)"
    }
    #endif

    private func pumpFacts() {
        while factsInFlight.count < factsConcurrency, !factsQueue.isEmpty {
            let project = factsQueue.removeFirst()
            let key = Self.key(project.projectId, project.revision)
            factsInFlight.insert(key)
            Task { @MainActor in
                defer {
                    self.factsInFlight.remove(key)
                    self.pumpFacts()
                }
                do {
                    _ = try await self.detail(for: project.projectId, fresh: false)
                } catch {
                    if case APIError.http(404, _, _) = error { self.factsUnavailable.insert(key) }
                }
            }
        }
    }

    private func absorb(_ detail: CloudProjectDetail) {
        let key = Self.key(detail.projectId, detail.revision)
        guard facts[key] == nil else { return }
        if let text = detail.document, let data = text.data(using: .utf8), let parsed = ProjectDocument.facts(data) {
            facts[key] = parsed
            cache.store(parsed, key: key)
        } else {
            factsUnavailable.insert(key)
        }
    }

    // MARK: - Details (presigned file URLs ≈ 15 min)

    /// The project's detail with file URLs good for at least another minute.
    /// Reuses the in-memory copy (and any in-flight fetch) unless `fresh`.
    func detail(for id: String, fresh: Bool) async throws -> CloudProjectDetail {
        let key = id.uppercased()
        if !fresh, let entry = details[key], entry.detail.urlsExpireAt.timeIntervalSinceNow > 60,
           project(key).map({ $0.revision == entry.detail.revision }) ?? true {
            return entry.detail
        }
        if !fresh, let running = detailTasks[key] { return try await running.value }
        let task = Task { @MainActor in try await self.api.cloudProject(key) }
        detailTasks[key] = task
        defer { detailTasks[key] = nil }
        let detail = try await task.value
        details[key] = (detail, Date())
        absorb(detail)
        return detail
    }

    // MARK: - Local edits (optimistic; a refresh follows)

    func didRename(_ id: String, to name: String, revision: Int) {
        guard let index = projects.firstIndex(where: { $0.projectId.caseInsensitiveCompare(id) == .orderedSame }) else { return }
        let old = projects[index]
        projects[index].name = name
        projects[index].revision = revision
        projects[index].updatedAt = Date()
        // The rename changed only the name: carry the facts to the new revision.
        if let known = facts[Self.key(id, old.revision)] {
            var renamed = known
            renamed.name = name
            facts[Self.key(id, revision)] = renamed
            cache.store(renamed, key: Self.key(id, revision))
        }
        details[id.uppercased()] = nil
    }

    func didDelete(_ id: String) {
        projects.removeAll { $0.projectId.caseInsensitiveCompare(id) == .orderedSame }
        details[id.uppercased()] = nil
    }

    func didPostComment() {}

    /// Signed out: forget everything (memory and disk) — the next account
    /// must never see this one's library.
    func reset() {
        refreshTask?.cancel()
        refreshTask = nil
        projects = []
        shares = []
        shareExtras = [:]
        storage = nil
        facts = [:]
        factsUnavailable = []
        details = [:]
        factsQueue = []
        phase = .idle
        lastRefresh = nil
        cache.clear()
        ThumbnailStore.shared.reset()
    }
}

// MARK: - Disk cache

/// Caches/CaptureCatLibrary/{facts,thumbs}/<id@revision>.{json,jpg}
final class LibraryDiskCache {
    let root: URL

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        #if DEBUG
        let folder = AppEnvironment.shared.isFixture ? "CaptureCatLibrary-Fixtures" : "CaptureCatLibrary"
        #else
        let folder = "CaptureCatLibrary"
        #endif
        root = caches.appendingPathComponent(folder, isDirectory: true)
        for sub in ["facts", "thumbs"] {
            try? FileManager.default.createDirectory(at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
    }

    private struct FactsRecord: Codable {
        var name: String?
        var duration: Double?
        var trimStart: Double
        var trimEnd: Double
        var sourceKind: String?
        var isStillCapture: Bool
        var hasCamera: Bool
        var videoFileName: String?
    }

    private func safe(_ key: String) -> String {
        key.replacingOccurrences(of: "/", with: "_")
    }

    func facts(_ key: String) -> ProjectDocument.Facts? {
        let url = root.appendingPathComponent("facts/\(safe(key)).json")
        guard let data = try? Data(contentsOf: url), let r = try? JSONDecoder().decode(FactsRecord.self, from: data) else { return nil }
        return ProjectDocument.Facts(name: r.name, duration: r.duration, trimStart: r.trimStart, trimEnd: r.trimEnd,
                                     sourceKind: r.sourceKind, isStillCapture: r.isStillCapture, hasCamera: r.hasCamera,
                                     videoFileName: r.videoFileName)
    }

    func store(_ f: ProjectDocument.Facts, key: String) {
        let record = FactsRecord(name: f.name, duration: f.duration, trimStart: f.trimStart, trimEnd: f.trimEnd,
                                 sourceKind: f.sourceKind, isStillCapture: f.isStillCapture, hasCamera: f.hasCamera,
                                 videoFileName: f.videoFileName)
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: root.appendingPathComponent("facts/\(safe(key)).json"), options: .atomic)
    }

    func thumbnailURL(_ key: String) -> URL {
        root.appendingPathComponent("thumbs/\(safe(key)).jpg")
    }

    /// The last project + share listing, tagged with the account it belongs
    /// to (another account never reads it; sign-out deletes it).
    struct Listing: Codable {
        var userID: String
        var projects: [CloudProjectSummary]
        var storage: StorageUsage?
        var shares: [SharedVideo]
        var shareExtras: [String: ShareExtras]
    }

    private var listingURL: URL { root.appendingPathComponent("listing.json") }

    func listing(forUser id: String) -> Listing? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let data = try? Data(contentsOf: listingURL),
              let listing = try? decoder.decode(Listing.self, from: data), listing.userID == id else { return nil }
        return listing
    }

    func storeListing(_ listing: Listing) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(listing) else { return }
        try? data.write(to: listingURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func clear() {
        try? FileManager.default.removeItem(at: listingURL)
        for sub in ["facts", "thumbs"] {
            let url = root.appendingPathComponent(sub)
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}
