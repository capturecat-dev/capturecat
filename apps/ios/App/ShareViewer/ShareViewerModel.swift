import Foundation
import Observation

/// One share being watched: what the web share page knows (meta, gate,
/// comments + the signed-in viewer, reactions + this viewer's own, transcript)
/// and what it does (unlock, post, react, count the view). The screen renders
/// it through a `SurfaceObservation` loop; actions come back as calls.
@Observable
final class ShareViewerModel {
    enum Phase: Equatable {
        case loading
        case open
        case gated(ShareGateState, fileName: String)
        case removed(String)
        case privateVideo
        case notFound
        case failed(String)
    }

    let videoID: String
    private(set) var phase: Phase = .loading
    private(set) var meta: ShareMeta?
    /// The password unlock token (rides as `?token=` on every gated call).
    private(set) var shareToken: String?
    /// The owner watching their own private share: playback only.
    private(set) var isOwnerPrivate = false

    private(set) var comments: [VideoComment] = []
    private(set) var commentViewer: ShareCommentViewer?
    private(set) var commentsLoaded = false
    private(set) var commentsError: String?

    private(set) var reactions: [ShareReaction] = []
    private(set) var myEmoji: String?
    /// Bumps on every reaction that LANDS (a floater rises for it).
    private(set) var reactionPulse: (emoji: String, time: Double, serial: Int)?

    private(set) var transcript: [ShareTranscriptSegment] = []
    private(set) var transcriptLoaded = false

    /// Changes when the device signs in or out (the composer's identity row).
    private(set) var signedInName: String?

    @ObservationIgnored let api: ShareViewerAPI
    @ObservationIgnored private let analyticsSession = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    @ObservationIgnored private var events: [[String: Any]] = []
    @ObservationIgnored private var seenSeconds = Set<Int>()
    @ObservationIgnored private var flushTimer: Timer?
    @ObservationIgnored private var reactionSerial = 0

    init(videoID: String, api: ShareViewerAPI = ShareViewerAPI()) {
        self.videoID = videoID
        self.api = api
        refreshSignedIn()
    }

    var commentsEnabled: Bool { meta?.commentsEnabled == true && !isOwnerPrivate }
    var hasTranscript: Bool { meta?.hasTranscript == true && !isOwnerPrivate }
    var summary: String? {
        guard let text = meta?.aiSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
    var hasSummaryTab: Bool {
        summary != nil || !(meta?.meaningfulChapters.isEmpty ?? true) || (!isOwnerPrivate && !(meta?.pillMarkers.isEmpty ?? true))
    }
    /// The owner's annotation markers (none on the owner's private view).
    var markers: [ShareAnnotationMarker] { isOwnerPrivate ? [] : meta?.markers ?? [] }
    var accent: String { meta?.accent ?? ShareAnnotationMath.defaultAccent }
    var reactionsEnabled: Bool { phase == .open && !isOwnerPrivate }

    /// Per-emoji totals for the tally chips.
    var reactionCounts: [(emoji: String, count: Int)] {
        ShareReactions.all.compactMap { emoji in
            let n = reactions.filter { $0.emoji == emoji }.count
            return n > 0 ? (emoji, n) : nil
        }
    }

    func refreshSignedIn() {
        let user = SessionStore.load()?.user
        signedInName = user.map { $0.name?.isEmpty == false ? $0.name! : ($0.email ?? "you") }
    }

    // MARK: - Load

    func load() async {
        phase = .loading
        do {
            switch try await api.lookup(videoID, token: shareToken) {
            case let .open(meta):
                self.meta = meta
                phase = .open
                startSocial()
            case let .gated(gate, fileName):
                phase = .gated(gate, fileName: fileName)
            case let .removed(message):
                phase = .removed(message)
            case .privateVideo:
                phase = .privateVideo
            case .ownerPrivate:
                isOwnerPrivate = true
                let library = LibraryStore.shared.share(videoID)
                meta = ShareMeta(videoId: videoID, fileName: library?.fileName ?? "Private video",
                                 durationSeconds: library?.durationSeconds, createdAt: library.map { ISO8601DateFormatter().string(from: $0.createdAt) })
                phase = .open
            case .notFound:
                phase = .notFound
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Password → token → the full meta with the token.
    func unlock(password: String) async throws {
        let token = try await api.unlock(videoID, password: password)
        #if DEBUG
        shareToken = Self.probeInject == "drop-token" ? nil : token
        #else
        shareToken = token
        #endif
        switch try await api.lookup(videoID, token: token) {
        case let .open(meta):
            self.meta = meta
            phase = .open
            startSocial()
        default:
            throw ShareViewerError.message("Could not load the video.")
        }
    }

    private func startSocial() {
        registerView()
        Task { await loadReactions() }
        if commentsEnabled { Task { await loadComments() } }
    }

    func loadComments() async {
        do {
            let result = try await api.comments(videoID, token: shareToken)
            comments = result.comments
            commentViewer = result.viewer
            commentsError = nil
        } catch {
            commentsError = error.localizedDescription
        }
        commentsLoaded = true
    }

    func loadReactions() async {
        guard let result = try? await api.reactions(videoID, session: Self.reactionSession) else { return }
        reactions = result.all
        myEmoji = result.mine
    }

    @ObservationIgnored private var transcriptRequested = false

    func loadTranscript() async {
        guard hasTranscript, !transcriptRequested else { return }
        transcriptRequested = true
        transcript = (try? await api.transcript(videoID)) ?? []
        transcriptLoaded = true
    }

    // MARK: - Reactions

    /// One reaction per viewer: the same emoji toggles off, another replaces.
    /// Optimistic — the tallies and the highlight change at once — and rolled
    /// back if the API refuses. Returns whether it landed.
    @discardableResult
    func react(_ emoji: String, at time: Double) async -> Bool {
        let before = (reactions, myEmoji)
        let unliking = myEmoji == emoji
        var next = reactions
        if let mine = myEmoji, let index = next.lastIndex(where: { $0.emoji == mine }) { next.remove(at: index) }
        if !unliking {
            next.append(ShareReaction(emoji: emoji, videoTime: (time * 10).rounded() / 10))
            reactionSerial += 1
            reactionPulse = (emoji, time, reactionSerial)
        }
        reactions = next.sorted { $0.videoTime < $1.videoTime }
        myEmoji = unliking ? nil : emoji
        #if DEBUG
        Self.probeOptimistic.append(myEmoji ?? "none")
        #endif
        do {
            let mine = try await api.react(videoID, emoji: emoji, at: time, session: Self.reactionSession)
            myEmoji = mine
            await loadReactions()  // re-sync: the previous reaction moved or vanished
            return true
        } catch {
            #if DEBUG
            if Self.probeInject == "no-rollback" { return false }
            #endif
            reactions = before.0
            myEmoji = before.1
            return false
        }
    }

    /// A stable per-install id, so "one reaction per viewer" survives relaunches
    /// (the web keeps the same in localStorage).
    static var reactionSession: String {
        let key = "so.capturecat.ios.reactionSession"
        if let id = UserDefaults.standard.string(forKey: key), id.count >= 8 { return id }
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    // MARK: - Comments

    func post(body: String, authorName: String?, at time: Double?, replyTo parentID: String?,
              annotation: String? = nil) async throws -> VideoComment {
        let comment = try await api.postComment(videoID, token: shareToken, body: body, authorName: authorName,
                                                videoTime: time, parentID: parentID, annotation: annotation)
        comments.append(comment)
        return comment
    }

    // MARK: - Views (the owner's analytics)

    /// The web registers the view at once, even if nobody presses play.
    private func registerView() {
        let id = videoID, token = shareToken, session = analyticsSession, api = api
        Task { await api.analytics(id, token: token, sessionID: session, events: []) }
        flushTimer?.invalidate()
        flushTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    func track(_ type: String, at time: Double) {
        guard phase == .open, !isOwnerPrivate else { return }
        events.append(["type": type, "videoTime": (time * 1000).rounded() / 1000])
    }

    /// Once per watched second (the owner's heatmap and drop-off).
    func tick(_ time: Double, playing: Bool) {
        guard playing, phase == .open, !isOwnerPrivate else { return }
        let second = Int(time)
        if seenSeconds.insert(second).inserted { events.append(["type": "tick", "videoTime": second]) }
    }

    func flush() {
        guard !events.isEmpty else { return }
        let batch = Array(events.prefix(50))
        events.removeFirst(batch.count)
        let id = videoID, token = shareToken, session = analyticsSession, api = api
        Task { await api.analytics(id, token: token, sessionID: session, events: batch) }
    }

    func close() {
        flushTimer?.invalidate()
        flushTimer = nil
        flush()
    }

    #if DEBUG
    /// `-shareViewerInject <defect>` (ShareViewerGate): a defect in the
    /// shipping path the gate must catch — `no-rollback`, `drop-token`,
    /// `marker-offset`, `seek-ignored`, `annotation-marker-offset`,
    /// `drawing-box-rect`, `drawing-ignores-fill`, `serializer-drift`,
    /// `toggle-no-rollback`.
    static var probeInject: String?
    /// What the highlight showed the instant a reaction was tapped (before the API answered).
    static var probeOptimistic: [String] = []
    #endif
}
