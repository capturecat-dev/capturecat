import AppKit
import AVFoundation
import Vision

// MARK: - Persisted index record

/// One OCR'd frame of a capture — output-time seconds + recognized text.
nonisolated struct CaptureIndexFrame: Codable, Sendable {
    var time: TimeInterval
    var text: String

    init(time: TimeInterval, text: String) {
        self.time = time
        self.text = text
    }

    enum CodingKeys: String, CodingKey {
        case time, text
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time = try c.decodeIfPresent(TimeInterval.self, forKey: .time) ?? 0
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(time, forKey: .time)
        try c.encode(text, forKey: .text)
    }
}

/// Per-capture search-index record, persisted as
/// `Application Support/CaptureCat/SearchIndex/<uuid>.json`.
/// `embedding` is reserved for a future on-device semantic scorer — always
/// nil in phase 1, but the storage format already carries it so adding
/// embeddings later never invalidates existing index files.
nonisolated struct CaptureIndexRecord: Codable, Sendable {
    var id: UUID
    /// mtime of the source media (video file) or note text at index time —
    /// re-index only when this changes.
    var sourceModifiedAt: Date
    var frames: [CaptureIndexFrame]
    /// All frame text joined — the lexical match target.
    var fullText: String
    /// Reserved: semantic embedding of `fullText`. Unused in phase 1.
    var embedding: [Float]?

    init(
        id: UUID,
        sourceModifiedAt: Date,
        frames: [CaptureIndexFrame],
        fullText: String,
        embedding: [Float]? = nil
    ) {
        self.id = id
        self.sourceModifiedAt = sourceModifiedAt
        self.frames = frames
        self.fullText = fullText
        self.embedding = embedding
    }

    enum CodingKeys: String, CodingKey {
        case id, sourceModifiedAt, frames, fullText, embedding
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        sourceModifiedAt = try c.decodeIfPresent(Date.self, forKey: .sourceModifiedAt)
            ?? Date(timeIntervalSince1970: 0)
        frames = try c.decodeIfPresent([CaptureIndexFrame].self, forKey: .frames) ?? []
        fullText = try c.decodeIfPresent(String.self, forKey: .fullText) ?? ""
        embedding = try c.decodeIfPresent([Float].self, forKey: .embedding)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(sourceModifiedAt, forKey: .sourceModifiedAt)
        try c.encode(frames, forKey: .frames)
        try c.encode(fullText, forKey: .fullText)
        try c.encodeIfPresent(embedding, forKey: .embedding)
    }
}

// MARK: - Matching + ranking (pure, harness-testable)

/// Search ranking over capture candidates. Pure functions — the browser, the
/// MCP `search_captures` tool and the `--search-test` harness all consume the
/// SAME matcher, so ranking can never fork between surfaces.
enum CaptureSearchRanking {
    /// One searchable capture: its title plus whatever indexed text exists.
    struct Candidate {
        let id: UUID
        let title: String
        let text: String
        let frames: [CaptureIndexFrame]
        /// "project" | "note" — passthrough metadata for MCP results.
        let kind: String

        init(id: UUID, title: String, text: String,
             frames: [CaptureIndexFrame] = [], kind: String = "project") {
            self.id = id
            self.title = title
            self.text = text
            self.frames = frames
            self.kind = kind
        }
    }

    struct Match {
        let candidate: Candidate
        let titleMatched: Bool
        /// Total token occurrences across the indexed text.
        let hitCount: Int
        /// One-line context around the first query-token hit in the text.
        let snippet: String?
        /// Time of the frame with the most token hits (videos), nil otherwise.
        let bestFrameTime: TimeInterval?
    }

    /// Case- and diacritic-insensitive fold.
    static func normalize(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Whitespace-split query tokens, normalized.
    static func tokens(_ query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map { normalize(String($0)) }
    }

    /// Token AND-match: every query token must appear in the text.
    /// An empty query matches nothing (search-off is the caller's branch).
    static func matches(query: String, in text: String) -> Bool {
        let terms = tokens(query)
        guard !terms.isEmpty else { return false }
        let haystack = normalize(text)
        return terms.allSatisfy { haystack.contains($0) }
    }

    /// Total occurrences of all query tokens in the text.
    static func hitCount(query: String, in text: String) -> Int {
        let haystack = normalize(text)
        var count = 0
        for term in tokens(query) where !term.isEmpty {
            var searchRange = haystack.startIndex..<haystack.endIndex
            while let found = haystack.range(of: term, range: searchRange) {
                count += 1
                searchRange = found.upperBound..<haystack.endIndex
            }
        }
        return count
    }

    /// One-line context around the first hit of the first matching token,
    /// ellipsized on both sides, newlines flattened.
    static func snippet(query: String, in text: String, radius: Int = 28) -> String? {
        let haystack = normalize(text)
        for term in tokens(query) {
            guard let found = haystack.range(of: term) else { continue }
            // Index math on the normalized string transfers to the original
            // only approximately (folds can change lengths), so slice the
            // normalized text — it reads the same for display purposes.
            let start = haystack.index(
                found.lowerBound, offsetBy: -radius,
                limitedBy: haystack.startIndex) ?? haystack.startIndex
            let end = haystack.index(
                found.upperBound, offsetBy: radius,
                limitedBy: haystack.endIndex) ?? haystack.endIndex
            var piece = String(haystack[start..<end])
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            if start > haystack.startIndex { piece = "…" + piece }
            if end < haystack.endIndex { piece += "…" }
            return piece
        }
        return nil
    }

    /// Ranked matches: title matches first (caller order preserved), then
    /// text-only matches by descending hit count. Non-matches are dropped.
    static func rank(
        query: String,
        candidates: [Candidate],
        scorer: CaptureRelevanceScorer = TokenRelevanceScorer()
    ) -> [Match] {
        let matches = candidates.compactMap { scorer.score(query: query, candidate: $0) }
        let titleHits = matches.filter(\.titleMatched)
        let textHits = matches.filter { !$0.titleMatched }
            .enumerated()
            .sorted { lhs, rhs in
                lhs.element.hitCount != rhs.element.hitCount
                    ? lhs.element.hitCount > rhs.element.hitCount
                    : lhs.offset < rhs.offset // stable ties
            }
            .map(\.element)
        return titleHits + textHits
    }
}

/// Scoring strategy behind capture search. Phase 1 is lexical token matching
/// (`TokenRelevanceScorer`); an embedding-based semantic scorer can conform
/// later and slot into `CaptureSearchRanking.rank` without touching any call
/// site or the persisted index format (records already carry `embedding`).
protocol CaptureRelevanceScorer {
    /// nil = no match; otherwise the scored match for ranking.
    func score(
        query: String,
        candidate: CaptureSearchRanking.Candidate
    ) -> CaptureSearchRanking.Match?
}

/// Phase-1 scorer: diacritic/case-insensitive token AND-matching over the
/// title and the OCR/note text.
struct TokenRelevanceScorer: CaptureRelevanceScorer {
    func score(
        query: String,
        candidate: CaptureSearchRanking.Candidate
    ) -> CaptureSearchRanking.Match? {
        let titleMatched = CaptureSearchRanking.matches(query: query, in: candidate.title)
        let textMatched = CaptureSearchRanking.matches(query: query, in: candidate.text)
        guard titleMatched || textMatched else { return nil }
        let hits = textMatched ? CaptureSearchRanking.hitCount(query: query, in: candidate.text) : 0
        var bestTime: TimeInterval?
        if textMatched, !candidate.frames.isEmpty {
            bestTime = candidate.frames
                .max { CaptureSearchRanking.hitCount(query: query, in: $0.text)
                    < CaptureSearchRanking.hitCount(query: query, in: $1.text) }?
                .time
        }
        return CaptureSearchRanking.Match(
            candidate: candidate,
            titleMatched: titleMatched,
            hitCount: hits,
            snippet: textMatched ? CaptureSearchRanking.snippet(query: query, in: candidate.text) : nil,
            bestFrameTime: bestTime
        )
    }
}

// MARK: - Indexing service

/// On-device text index over captures: OCRs still captures and video
/// keyframes with Vision so the browser's search (and the MCP
/// `search_captures` tool) can find captures by what's VISIBLE in them.
/// Notes pass their text straight through, so search is uniform.
///
/// Thermal contract: one project at a time, `.utility` priority, frames
/// downscaled to ~1280px before OCR, and indexing PAUSES whenever the app is
/// recording or exporting — this app has had heat complaints, so the index
/// must never compete with capture or export for the machine.
@Observable
@MainActor
final class CaptureTextIndex {
    /// In-memory mirror of the persisted records, keyed by capture id.
    private(set) var records: [UUID: CaptureIndexRecord] = [:]
    /// Progress: captures indexed so far / total known captures.
    private(set) var indexedCount = 0
    private(set) var total = 0

    private weak var appState: AppState?
    private var pendingProjectIDs: [UUID] = []
    private var isWorking = false

    /// Nonisolated so AppState (not a @MainActor type) can own one as a
    /// stored property; all state access still happens on the main actor.
    nonisolated init() {}

    /// Max keyframes OCR'd per video project.
    private nonisolated static let maxFramesPerProject = 40
    /// Coarse keyframe interval (seconds of output).
    private nonisolated static let frameInterval: TimeInterval = 2
    /// Longest frame edge handed to Vision.
    private nonisolated static let ocrMaxDimension: CGFloat = 1280

    nonisolated static var indexRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CaptureCat/SearchIndex", isDirectory: true)
    }

    nonisolated static func recordURL(for id: UUID) -> URL {
        indexRoot.appendingPathComponent("\(id.uuidString).json")
    }

    // MARK: Lifecycle

    /// Load persisted records and, after a launch-settle delay, index
    /// whatever is new or changed.
    func start(appState: AppState, launchDelay: TimeInterval = 10) {
        self.appState = appState
        loadPersistedRecords()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(launchDelay * 1_000_000_000))
            self?.rescan()
        }
    }

    /// Queue one freshly-landed capture (called right after a recording or
    /// still capture is saved).
    func scheduleIndex(projectID: UUID) {
        guard !pendingProjectIDs.contains(projectID) else { return }
        pendingProjectIDs.append(projectID)
        total = max(total, records.count + pendingProjectIDs.count)
        kick()
    }

    /// Diff the library against the index: queue stale/missing projects and
    /// refresh note records inline (their text is already in memory).
    func rescan() {
        guard let appState else { return }
        let projects = appState.projectStore.projects
        let notes = appState.noteStore.notes
        total = projects.count + notes.count

        // Notes: trivial passthrough so search is uniform across capture kinds.
        for note in notes {
            if let existing = records[note.id],
               abs(existing.sourceModifiedAt.timeIntervalSince(note.modifiedAt)) < 1 { continue }
            let record = CaptureIndexRecord(
                id: note.id,
                sourceModifiedAt: note.modifiedAt,
                frames: [],
                fullText: note.text
            )
            store(record)
        }

        for project in projects {
            guard let videoURL = project.videoURL else { continue }
            let mtime = Self.modificationDate(of: videoURL)
            if let existing = records[project.id], let mtime,
               abs(existing.sourceModifiedAt.timeIntervalSince(mtime)) < 1 { continue }
            if !pendingProjectIDs.contains(project.id) {
                pendingProjectIDs.append(project.id)
            }
        }
        refreshProgress()
        kick()
    }

    /// The record for a capture, if indexed.
    func record(for id: UUID) -> CaptureIndexRecord? {
        records[id]
    }

    // MARK: Worker

    private func kick() {
        guard !isWorking, !pendingProjectIDs.isEmpty else { return }
        isWorking = true
        Task(priority: .utility) { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while !pendingProjectIDs.isEmpty {
            // Never index while recording or exporting — heat + contention.
            while isBusy {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
            let projectID = pendingProjectIDs.removeFirst()
            guard let project = appState?.projectStore.projects
                .first(where: { $0.id == projectID }),
                let videoURL = project.videoURL,
                FileManager.default.fileExists(atPath: videoURL.path) else {
                refreshProgress()
                continue
            }
            let mtime = Self.modificationDate(of: videoURL) ?? Date()
            let isImage = project.isImageCapture
            let duration = project.duration
            // Heavy lifting off the main actor, one project at a time.
            let frames = await Task.detached(priority: .utility) {
                Self.extractFrames(videoURL: videoURL, duration: duration, isImage: isImage)
            }.value
            let record = CaptureIndexRecord(
                id: projectID,
                sourceModifiedAt: mtime,
                frames: frames,
                fullText: frames.map(\.text).joined(separator: "\n")
            )
            store(record)
            refreshProgress()
        }
        isWorking = false
        // A schedule that raced the drain's tail re-kicks itself via kick().
        if !pendingProjectIDs.isEmpty { kick() }
    }

    /// True while capture or export work owns the machine.
    private var isBusy: Bool {
        guard let appState else { return false }
        return appState.recordingSession.isRecording
            || appState.recordingSession.isPaused
            || appState.showExport
            || appState.shareJobCenter.hasActiveJobs
    }

    private func refreshProgress() {
        indexedCount = records.count
        total = max(total, records.count + pendingProjectIDs.count)
    }

    // MARK: Persistence

    private func loadPersistedRecords() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.indexRoot, withIntermediateDirectories: true)
        guard let files = try? fm.contentsOfDirectory(
            at: Self.indexRoot, includingPropertiesForKeys: nil
        ) else { return }
        var loaded: [UUID: CaptureIndexRecord] = [:]
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let record = try? JSONDecoder().decode(CaptureIndexRecord.self, from: data)
            else { continue }
            loaded[record.id] = record
        }
        records = loaded
        indexedCount = loaded.count
    }

    private func store(_ record: CaptureIndexRecord) {
        records[record.id] = record
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.indexRoot, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(record) {
            try? data.write(to: Self.recordURL(for: record.id), options: .atomic)
        }
    }

    nonisolated static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    // MARK: Frame extraction + OCR (background)

    /// Stills → the one frame; videos → keyframes every ~2s, capped at 40,
    /// downscaled to ~1280px before OCR.
    nonisolated static func extractFrames(
        videoURL: URL, duration: TimeInterval, isImage: Bool
    ) -> [CaptureIndexFrame] {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: ocrMaxDimension, height: ocrMaxDimension)

        var times: [TimeInterval]
        if isImage || duration <= frameInterval {
            times = [min(0.5, max(0, duration / 2))]
        } else {
            let interval = max(frameInterval, duration / Double(maxFramesPerProject))
            times = Array(stride(from: 0.5, to: duration, by: interval))
            if times.count > maxFramesPerProject {
                times = Array(times.prefix(maxFramesPerProject))
            }
        }

        var frames: [CaptureIndexFrame] = []
        for time in times {
            let cmTime = CMTime(seconds: time, preferredTimescale: 600)
            guard let cgImage = try? generator.copyCGImage(at: cmTime, actualTime: nil)
            else { continue }
            let text = recognizeText(in: cgImage)
            if !text.isEmpty {
                frames.append(CaptureIndexFrame(time: time, text: text))
            }
        }
        return frames
    }

    /// Vision OCR of one frame — accurate recognition, top candidate per
    /// observation, newline-joined. Synchronous; call off the main actor
    /// (the harness calls it directly to prove OCR works headless).
    nonisolated static func recognizeText(in cgImage: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observations = request.results else { return "" }
        return observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}
