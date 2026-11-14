import AVFoundation
import Observation
import UIKit

/// Card thumbnails. Projects: ONE frame pulled from the presigned recording
/// URL with AVAssetImageGenerator (range requests — the file is never
/// downloaded whole), cached on disk by projectId + revision. Shares: the
/// custom `thumbnailUrl` when present, else a frame from the stream URL (with
/// the bearer header — private shares need it), cached by videoId.
@Observable
final class ThumbnailStore {
    static let shared = ThumbnailStore()

    /// Loaded images by cache key (`p:<id@rev>` / `s:<videoId>`).
    private(set) var images: [String: UIImage] = [:]
    /// Keys that failed (shown as a placeholder; retried on the next refresh).
    private(set) var failed: Set<String> = []

    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var queue: [(key: String, job: () async -> UIImage?)] = []
    @ObservationIgnored private var running = 0
    @ObservationIgnored private let concurrency = 2
    @ObservationIgnored private var cache: LibraryDiskCache { LibraryStore.shared.cache }

    static func key(for project: CloudProjectSummary) -> String {
        "p:" + LibraryStore.key(project.projectId, project.revision)
    }

    static func key(for share: SharedVideo) -> String { "s:" + share.videoId }

    /// The listed revision's frame, else the newest one known for the project
    /// (an edit elsewhere bumped the revision; the media is usually the same).
    func image(for project: CloudProjectSummary) -> UIImage? {
        images[Self.key(for: project)] ?? LibraryStore.newest(in: images, forProject: project.projectId, keyPrefix: "p:")
    }
    func image(for share: SharedVideo) -> UIImage? { images[Self.key(for: share)] }

    func request(_ project: CloudProjectSummary) {
        let key = Self.key(for: project)
        enqueue(key) {
            let store = LibraryStore.shared
            guard let detail = try? await store.detail(for: project.projectId, fresh: false) else { return nil }
            let facts = store.facts(for: project)
            guard let file = Self.recordingFile(in: detail, facts: facts) else { return nil }
            let duration = facts?.duration ?? 0
            let start = facts?.trimStart ?? 0
            // A frame a little in, so the first black frame never becomes the card.
            let time = (facts?.isStillCapture ?? false) ? 0.1 : min(start + max(0.6, duration * 0.12), max(duration - 0.1, 0.1))
            return await Self.frame(from: AVURLAsset(url: file.url), at: time)
        }
    }

    func request(_ share: SharedVideo) {
        let key = Self.key(for: share)
        enqueue(key) {
            let api = AppEnvironment.shared.api
            if share.thumbnailUrl != nil, let custom = await api.shareThumbnail(share) { return custom }
            let duration = share.durationSeconds ?? 0
            return await Self.frame(from: api.streamAsset(videoID: share.videoId), at: min(max(0.6, duration * 0.12), max(duration - 0.1, 0.1)))
        }
    }

    /// The main recording among the project's files.
    static func recordingFile(in detail: CloudProjectDetail, facts: ProjectDocument.Facts?) -> CloudRemoteFile? {
        if let name = facts?.videoFileName, let match = detail.files.first(where: { $0.path == name || $0.path.hasSuffix("/" + name) }) {
            return match
        }
        return detail.files.first { $0.contentType.hasPrefix("video/") && !$0.path.lowercased().contains("camera") }
            ?? detail.files.first { $0.contentType.hasPrefix("video/") }
    }

    private func enqueue(_ key: String, job: @escaping () async -> UIImage?) {
        guard images[key] == nil, !inFlight.contains(key), !failed.contains(key) else { return }
        inFlight.insert(key)
        // Disk first (off the main thread).
        let url = cache.thumbnailURL(key)
        Task { @MainActor in
            let cached = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { return nil }
                return image.preparingForDisplay() ?? image
            }.value
            if let cached {
                self.images[key] = cached
                self.inFlight.remove(key)
                return
            }
            self.queue.append((key, job))
            self.pump()
        }
    }

    private func pump() {
        while running < concurrency, !queue.isEmpty {
            let next = queue.removeFirst()
            running += 1
            Task { @MainActor in
                let image = await next.job()
                self.running -= 1
                self.inFlight.remove(next.key)
                if let image {
                    self.images[next.key] = image
                    self.failed.remove(next.key)
                    let url = self.cache.thumbnailURL(next.key)
                    Task.detached(priority: .utility) {
                        if let data = image.jpegData(compressionQuality: 0.82) { try? data.write(to: url, options: .atomic) }
                    }
                } else {
                    self.failed.insert(next.key)
                }
                self.pump()
            }
        }
    }

    /// One frame, max 720 px, transform applied. Never reads the whole file.
    nonisolated static func frame(from asset: AVURLAsset, at seconds: Double) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 720)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        do {
            let (cgImage, _) = try await generator.image(at: time)
            return UIImage(cgImage: cgImage)
        } catch {
            // Short clips: fall back to the very start.
            guard let (cgImage, _) = try? await generator.image(at: .zero) else { return nil }
            return UIImage(cgImage: cgImage)
        }
    }

    func retryFailed() { failed = [] }

    func reset() {
        images = [:]
        failed = []
        queue = []
    }
}
