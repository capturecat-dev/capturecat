import AVFoundation
import Foundation
import Observation

/// Background person segmentation for the camera LOOKS — produces
/// `camera-mask.ccmask` (docs/camera-cutout.md §6) and serves the fresh
/// tracks the preview draws from.
///
/// Thermal contract, modelled on `CaptureTextIndex`: one project at a time,
/// `.utility` priority, heavy work in a detached task, and the job PAUSES
/// (between frames) whenever the app is recording, exporting or sharing.
/// Writes are atomic, so a reader never sees a half-written mask.
///
/// Queued when a look is first applied to a project without a fresh mask
/// (the editor calls `ensureMask` whenever it renders a project that uses a
/// look) and after a recording whose project already uses one.
///
/// Shared by the Mac app and the iOS studio (Studio 4e): the host plugs in
/// through `projectLookup` and `isHostBusy` (the Mac's AppState in
/// `CameraSegmentation+AppState.swift`; the iOS editor's open project).
@Observable
@MainActor
final class CameraSegmentation {
    enum Status: Equatable {
        /// No look in use, or no camera — nothing to show.
        case notNeeded
        /// A fresh mask is on disk.
        case ready
        case queued
        case running(Double)
        /// Running, but held while the Mac records / exports / shares.
        case paused(Double)
        case failed(String)
    }

    /// Bumped whenever a mask file is written or a camera duration resolves —
    /// editors read it so they re-render with the new track.
    private(set) var revision = 0
    private(set) var pendingProjectIDs: [UUID] = []
    private(set) var runningProjectID: UUID?
    private(set) var runningProgress: Double = 0
    private(set) var runningPaused = false
    private(set) var failures: [UUID: String] = [:]

    /// Host seam: the project with this id, if the host still has it open
    /// or listed (nil drops it from the queue).
    @ObservationIgnored var projectLookup: @MainActor (UUID) -> Project? = { _ in nil }
    /// Host seam: true while capture, export or an upload owns the machine —
    /// the job never starts then and pauses between frames.
    @ObservationIgnored var isHostBusy: @MainActor () -> Bool = { false }
    /// Gate seam: a stand-in for Vision's matte (nil in the apps).
    @ObservationIgnored var matteSource: CameraSegmenter.Matte?
    @ObservationIgnored private var isWorking = false
    @ObservationIgnored private var gate: CameraSegmentationGate?
    /// Loaded tracks, keyed by mask path, valid for one file signature.
    @ObservationIgnored private var tracks: [String: (signature: String, track: CameraMaskTrack?)] = [:]
    /// Camera durations (AVAsset, async) keyed by "path|size".
    @ObservationIgnored private var cameraDurations: [String: Double] = [:]
    @ObservationIgnored private var durationLoads: Set<String> = []
    /// The camera signature a failure was for — a new camera retries.
    @ObservationIgnored private var failedSignatures: [UUID: String] = [:]

    /// Nonisolated so AppState (not a @MainActor type) can own one.
    nonisolated init() {}

    // MARK: - Fresh tracks

    private static func fileSignature(_ url: URL) -> (size: Int64, signature: String)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value else { return nil }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        return (size, "\(size)|\(mtime)")
    }

    /// The camera file's duration, or nil while it loads (the load bumps
    /// `revision` when it lands, so observers come back).
    private func cameraDuration(_ cameraURL: URL, size: Int64) -> Double? {
        let key = "\(cameraURL.path)|\(size)"
        if let known = cameraDurations[key] { return known }
        if durationLoads.insert(key).inserted {
            Task { @MainActor [weak self] in
                let seconds = (try? await AVURLAsset(url: cameraURL).load(.duration)).map(CMTimeGetSeconds) ?? 0
                guard let self else { return }
                self.cameraDurations[key] = seconds.isFinite ? seconds : 0
                self.durationLoads.remove(key)
                self.revision &+= 1
            }
        }
        return nil
    }

    /// The project's mask track when it is FRESH for its camera file (same
    /// byte size, duration within 0.05 s — `CameraMaskTrack.isFresh`), else
    /// nil. Cheap enough per frame: two stats and a dictionary lookup.
    func usableMask(for project: Project) -> CameraMaskTrack? {
        guard let cameraURL = project.cameraVideoURL, let maskURL = project.cameraMaskURL,
              let camera = Self.fileSignature(cameraURL),
              let mask = Self.fileSignature(maskURL),
              let duration = cameraDuration(cameraURL, size: camera.size) else { return nil }
        let signature = "\(mask.signature)|\(camera.signature)|\(duration)"
        if let cached = tracks[maskURL.path], cached.signature == signature { return cached.track }
        var track: CameraMaskTrack?
        if let loaded = try? CameraMaskTrack(contentsOf: maskURL),
           CameraMaskTrack.isFresh(loaded.header, cameraByteSize: camera.size, cameraDuration: duration) {
            track = loaded
        }
        tracks[maskURL.path] = (signature, track)
        return track
    }

    /// Whether a fresh mask exists — false while the camera duration loads.
    func hasFreshMask(for project: Project) -> Bool { usableMask(for: project) != nil }

    // MARK: - Status

    func status(for project: Project) -> Status {
        guard project.cameraVideoURL != nil, project.usesCameraLook else { return .notNeeded }
        if runningProjectID == project.id {
            return runningPaused ? .paused(runningProgress) : .running(runningProgress)
        }
        if pendingProjectIDs.contains(project.id) { return .queued }
        if let failure = failures[project.id] { return .failed(failure) }
        return hasFreshMask(for: project) ? .ready : .queued
    }

    // MARK: - Queue

    /// Queues segmentation when the project uses a look and has no fresh mask.
    /// Idempotent and cheap — the editor calls it on every render of a
    /// project that uses a look.
    func ensureMask(for project: Project) {
        guard project.usesCameraLook,
              let cameraURL = project.cameraVideoURL,
              let camera = Self.fileSignature(cameraURL),
              runningProjectID != project.id,
              !pendingProjectIDs.contains(project.id) else { return }
        // Undecided until the camera duration is known (fresh vs stale).
        guard cameraDuration(cameraURL, size: camera.size) != nil else { return }
        guard usableMask(for: project) == nil else { return }
        if let failed = failedSignatures[project.id], failed == camera.signature { return }
        failures[project.id] = nil
        pendingProjectIDs.append(project.id)
        kick()
    }

    /// After a recording lands: queue it when its project already uses a look.
    func scheduleAfterRecording(project: Project) {
        guard project.usesCameraLook else { return }
        ensureMask(for: project)
    }

    private func kick() {
        guard !isWorking, !pendingProjectIDs.isEmpty else { return }
        isWorking = true
        Task(priority: .utility) { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while !pendingProjectIDs.isEmpty {
            // Never START while capture/export owns the machine.
            while isBusy { try? await Task.sleep(nanoseconds: 5_000_000_000) }
            let projectID = pendingProjectIDs.removeFirst()
            guard let project = project(withID: projectID),
                  let cameraURL = project.cameraVideoURL, let maskURL = project.cameraMaskURL,
                  let camera = Self.fileSignature(cameraURL) else { continue }
            await run(projectID: projectID, cameraURL: cameraURL, maskURL: maskURL, cameraSignature: camera.signature)
        }
        isWorking = false
        if !pendingProjectIDs.isEmpty { kick() }
    }

    private func run(projectID: UUID, cameraURL: URL, maskURL: URL, cameraSignature: String) async {
        let gate = CameraSegmentationGate()
        self.gate = gate
        runningProjectID = projectID
        runningProgress = 0
        runningPaused = false
        // Hold the worker between frames while the Mac is busy.
        let monitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let busy = self.isBusy
                gate.isPaused = busy
                if self.runningPaused != busy { self.runningPaused = busy }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        defer {
            monitor.cancel()
            self.gate = nil
            runningProjectID = nil
            runningPaused = false
        }
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in
                guard let self, self.runningProjectID == projectID else { return }
                self.runningProgress = fraction
            }
        }
        do {
            let matte = matteSource
            let data = try await Task.detached(priority: .utility) {
                try await CameraSegmenter.segment(cameraURL: cameraURL, gate: gate, matte: matte, progress: report)
            }.value
            try data.write(to: maskURL, options: .atomic)
            failedSignatures[projectID] = nil
            tracks[maskURL.path] = nil
            revision &+= 1
        } catch is CancellationError {
            // Cancelled (project closed/deleted) — nothing to record.
        } catch {
            failures[projectID] = error.localizedDescription
            failedSignatures[projectID] = cameraSignature
        }
    }

    private func project(withID id: UUID) -> Project? {
        projectLookup(id)
    }

    /// True while capture, export or a share upload owns the machine.
    private var isBusy: Bool {
        isHostBusy()
    }
}

extension CameraSegmentation.Status {
    /// The status line the editors show under the camera looks (the Mac's
    /// Camera pane, the iOS background-removal sheet); nil when nothing is
    /// needed.
    var displayText: String? {
        switch self {
        case .notNeeded: return nil
        case .ready: return "Background removed — Cutout and Pop-out card are live."
        case .queued: return "Removing background — waiting to start…"
        case .running(let p): return "Removing background… \(Int((p * 100).rounded()))%"
        case .paused(let p): return "Paused while recording or exporting — \(Int((p * 100).rounded()))%"
        case .failed(let message): return "Couldn't remove the background: \(message)"
        }
    }

    /// The bar under the line: nil = indeterminate (queued); hidden when
    /// ready or failed.
    var barValue: Double? {
        switch self {
        case .queued: return nil
        case .running(let p), .paused(let p): return p
        case .ready: return 1
        case .notNeeded, .failed: return 0
        }
    }

    var showsBar: Bool {
        switch self {
        case .ready, .failed: return false
        default: return true
        }
    }
}
