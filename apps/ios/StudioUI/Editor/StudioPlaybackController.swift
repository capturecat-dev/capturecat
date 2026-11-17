import AVFoundation
import Observation
import UIKit

/// The iOS editor's playback: the AVPlayer (and the camera player), the
/// periodic time observer and every piece of state they drive — the UIKit
/// twin of the Mac's `EditorPlaybackController`, whose order, guards and
/// seeks it follows (same 60 Hz observer, same chase-time scrub, same
/// trim-end stop, same live speed rate, same click / key sounds).
///
/// Frames reach the stage through the shared compositor: `player` goes into
/// `PreviewCompositorCore.FrameInput`, whose `VideoFrameLayerDriver` pulls
/// the DISPLAYED pixel buffers into the card (IOSurface layer contents).
/// The plan's playback exception (owner-approved, Studio 2d): no motion blur
/// while playing — `isPlaying` goes into the frame input, and the stage's
/// twin skips the blur for a playing frame.
///
/// Not ported yet (later phases): voice-over recording / refresh (4e), the
/// Mac's video-clip rebuild on cut edits (the timeline, 4c, drives it).
@MainActor
@Observable
final class StudioPlaybackController {
    private(set) var player: AVPlayer?
    /// The playhead, SOURCE seconds.
    var currentTime: Double = 0
    var isPlaying = false {
        didSet { if isPlaying != oldValue { displayTicks?.isPaused = !isPlaying } }
    }
    private(set) var isScrubbing = false
    private(set) var videoSize: CGSize = .zero
    private(set) var cursorEvents: [CursorEvent] = []
    private(set) var keystrokeEvents: [KeystrokeEvent] = []
    private(set) var cursorCoordinateSize: CGSize = .zero
    /// The start frame, decoded directly — shown until the player delivers.
    private(set) var videoPosterImage: UIImage?
    /// Seconds per source frame (step buttons); 1/30 until the track says.
    private(set) var frameDuration: Double = 1.0 / 30.0
    private(set) var isReady = false

    private(set) var cameraPlayer: AVPlayer?
    private(set) var cameraPosterImage: UIImage?
    private(set) var cameraVideoAspect: CGFloat = 1
    private(set) var cameraSourceLeadIn: TimeInterval = 0
    @ObservationIgnored private var cameraDuration: TimeInterval = 0
    @ObservationIgnored private var effectiveCameraOffset: TimeInterval = 0
    @ObservationIgnored private var cameraSetupGeneration = 0

    @ObservationIgnored private var rawCursorEvents: [CursorEvent] = []
    @ObservationIgnored private var appliedSmoothing: String?
    @ObservationIgnored private var timeObserverToken: Any?
    /// While playing, the playhead advances once per DISPLAY refresh (120 Hz on
    /// ProMotion), so the stage's camera, cursor and overlays move at the
    /// screen's rate; the periodic observer (60 Hz, not vsync-aligned) only
    /// covers the paused / seeking states.
    @ObservationIgnored private var displayTicks: CADisplayLink?
    @ObservationIgnored private var displayTickTarget: DisplayTickTarget?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var pendingPlaybackStartTime: TimeInterval?
    @ObservationIgnored private var pendingScrubTime: TimeInterval?
    @ObservationIgnored private var pendingScrubExact = false
    @ObservationIgnored private var scrubSeekInFlight = false
    @ObservationIgnored private var scrubSeekGeneration = 0

    /// Per-observer-consumer counts (the gate's sequence proof reads ticks).
    struct Counters: Equatable {
        var ticks = 0
        var clickSounds = 0
        var keySounds = 0
        var rateChanges = 0
        var trimEndStops = 0
    }
    @ObservationIgnored private(set) var counters = Counters()

    init() {}

    // MARK: - Setup / teardown

    /// Loads `project`'s recording (and camera), parked at `initialTime`
    /// (default: the trim start). The Mac's `setupPlayer`, step for step.
    func setup(for project: Project, initialTime: TimeInterval? = nil) async {
        guard let url = project.videoURL else { return }
        teardown()

        let asset = AVURLAsset(url: url)
        // 1:1 source-time composition — speed is applied live via
        // `player.rate`, so the source-time playhead stays in sync.
        let preparedAudio = try? await ProjectAudioMix.prepare(for: asset, project: project, applySpeedScaling: false)
        let item = AVPlayerItem(asset: preparedAudio?.asset ?? asset)
        item.audioMix = preparedAudio?.audioMix
        item.audioTimePitchAlgorithm = .timeDomain
        let avPlayer = AVPlayer(playerItem: item)
        avPlayer.automaticallyWaitsToMinimizeStalling = false

        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            videoSize = (try? await track.load(.naturalSize)) ?? .zero
            if let rate = try? await track.load(.nominalFrameRate), rate > 1 {
                frameDuration = 1.0 / Double(rate)
            }
        }
        if let duration = try? await asset.load(.duration) {
            let seconds = duration.seconds
            if seconds.isFinite, seconds > 0, abs(project.duration - seconds) > (1.0 / 120.0) {
                project.duration = seconds
            }
        }
        effectiveCameraOffset = project.cameraTimeOffset

        keystrokeEvents = project.keystrokeDataURL.flatMap { try? KeystrokeRecording.load(from: $0).events } ?? []
        if let cursorURL = project.cursorDataURL, let recording = try? CursorRecording.load(from: cursorURL) {
            rawCursorEvents = recording.events
            cursorCoordinateSize = recording.hasValidCoordinateSpace ? recording.coordinateSize : .zero
        } else {
            rawCursorEvents = []
            cursorCoordinateSize = .zero
        }
        appliedSmoothing = nil
        applyCursorSmoothing(settings: project.settings, trimEnd: project.effectiveTrimEnd)

        installObservers(on: avPlayer, project: project)
        avPlayer.isMuted = project.settings.muteRecordedAudio
        player = avPlayer
        let startTime = min(
            max(initialTime ?? project.effectiveTrimStart, project.effectiveTrimStart),
            project.effectiveTrimEnd)
        currentTime = startTime
        await avPlayer.seek(to: CMTime(seconds: startTime, preferredTimescale: 600),
                            toleranceBefore: .zero, toleranceAfter: .zero)
        warmFirstFrame(avPlayer)

        let poster = await Self.frameImage(asset: asset, at: startTime)
        if player === avPlayer { videoPosterImage = poster }
        if project.settings.showCamera { setupCameraPlayer(for: project) }
        isReady = true
    }

    func teardown() {
        if let token = timeObserverToken { player?.removeTimeObserver(token) }
        timeObserverToken = nil
        displayTicks?.invalidate()
        displayTicks = nil
        displayTickTarget = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player?.pause()
        player = nil
        cameraSetupGeneration += 1
        cameraPlayer?.pause()
        cameraPlayer = nil
        isPlaying = false
        isReady = false
    }

    /// Re-derives `cursorEvents` from the raw path (the shared chain the
    /// exporter draws). No-op unless the settings changed.
    func applyCursorSmoothing(settings: ProjectSettings, trimEnd: TimeInterval) {
        let want = CursorPathChain.signature(settings: settings, trimEnd: trimEnd)
        if let applied = appliedSmoothing, applied == want { return }
        appliedSmoothing = want
        cursorEvents = CursorPathChain.apply(rawCursorEvents, settings: settings, trimEnd: trimEnd)
    }

    private func installObservers(on avPlayer: AVPlayer, project: Project) {
        let interval = CMTime(seconds: 1.0 / 60.0, preferredTimescale: 600)
        timeObserverToken = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) {
            [weak self, weak avPlayer] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Pinned to a requested frame until its exact seek completes.
                if let pending = self.pendingPlaybackStartTime { self.currentTime = pending; return }
                if let pending = self.pendingScrubTime { self.currentTime = pending; return }
                // Paused: editor operations publish their own time (a late
                // decoder timestamp would nudge the playhead after a seek).
                guard self.isPlaying else { return }
                // Playing: the display link advances the playhead.
                guard self.displayTicks == nil else { return }
                self.advance(to: time.seconds, project: project, player: avPlayer)
            }
        }
        let target = DisplayTickTarget()
        target.tick = { [weak self, weak avPlayer] in
            guard let self, let avPlayer, self.isPlaying,
                  self.pendingPlaybackStartTime == nil, self.pendingScrubTime == nil else { return }
            self.advance(to: avPlayer.currentTime().seconds, project: project, player: avPlayer)
        }
        let link = CADisplayLink(target: target, selector: #selector(DisplayTickTarget.step))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.isPaused = !isPlaying
        link.add(to: .main, forMode: .common)
        displayTicks = link
        displayTickTarget = target

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: avPlayer.currentItem, queue: .main
        ) { [weak self, weak avPlayer] _ in
            MainActor.assumeIsolated {
                guard let self, let avPlayer else { return }
                self.isPlaying = false
                self.currentTime = project.effectiveTrimStart
                avPlayer.seek(to: CMTime(seconds: project.effectiveTrimStart, preferredTimescale: 600),
                              toleranceBefore: .zero, toleranceAfter: .zero)
                self.cameraPlayer?.pause()
            }
        }
    }

    /// One playhead step while playing — from the display link (or the
    /// periodic observer when no link is installed).
    private func advance(to t: Double, project: Project, player avPlayer: AVPlayer?) {
        let previous = currentTime
        currentTime = t
        counters.ticks += 1

        // One tick per DISCRETE click crossed (edge-deduped like the ripple).
        if project.settings.clickSoundEnabled, t > previous, t - previous < 0.35 {
            let crossed = ClickRippleOverlay.discreteClickTimes(
                from: cursorEvents, coordinateSize: cursorCoordinateSize
            ).contains { $0 > previous && $0 <= t }
            if crossed {
                ClickSoundPlayer.shared.play(volume: project.settings.clickSoundVolume,
                                             style: project.settings.clickSoundStyle)
                counters.clickSounds += 1
            }
        }
        if project.settings.keySoundEnabled, t > previous, t - previous < 0.35 {
            let crossedKeys = keystrokeEvents.lazy
                .filter { $0.category != .scroll }
                .filter { $0.timestamp > previous && $0.timestamp <= t }
                .prefix(3)
            for key in crossedKeys {
                KeySoundPlayer.shared.play(timestamp: key.timestamp, category: key.category,
                                           volume: project.settings.keySoundVolume,
                                           style: project.settings.keySoundStyle)
                counters.keySounds += 1
            }
        }
        // Live speed: player.rate follows the speed region under the playhead.
        if let avPlayer, avPlayer.timeControlStatus != .paused {
            let targetRate = Float(Self.activeSpeed(for: project, at: t))
            if abs(avPlayer.rate - targetRate) > 0.01 {
                avPlayer.rate = targetRate
                counters.rateChanges += 1
                if let cam = cameraPlayer, cam.rate > 0 { cam.rate = targetRate }
            }
        }
        // Stop at the trim end, back to the trim start.
        if project.effectiveTrimEnd > 0, t >= project.effectiveTrimEnd {
            isPlaying = false
            currentTime = project.effectiveTrimStart
            avPlayer?.pause()
            avPlayer?.seek(to: CMTime(seconds: project.effectiveTrimStart, preferredTimescale: 600),
                           toleranceBefore: .zero, toleranceAfter: .zero)
            cameraPlayer?.pause()
            counters.trimEndStops += 1
        }
        syncCameraIfNeeded(project: project)
    }

    /// A paused seek on a fresh item may not hand the video output a frame
    /// until the item has played once: play muted for a turn, pause, and
    /// re-seek exactly (the Mac's warm-up).
    private func warmFirstFrame(_ avPlayer: AVPlayer) {
        Task { @MainActor [weak self, weak avPlayer] in
            guard let self, let avPlayer else { return }
            let deadline = Date().addingTimeInterval(5)
            while avPlayer.currentItem?.status != .readyToPlay, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard avPlayer.currentItem?.status == .readyToPlay, avPlayer.rate == 0,
                  self.player === avPlayer, !self.isPlaying else { return }
            let wasMuted = avPlayer.isMuted
            let anchor = self.currentTime
            avPlayer.isMuted = true
            avPlayer.play()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard !self.isPlaying else { avPlayer.isMuted = wasMuted; return }
                    avPlayer.pause()
                    avPlayer.seek(to: CMTime(seconds: anchor, preferredTimescale: 600),
                                  toleranceBefore: .zero, toleranceAfter: .zero)
                    self.currentTime = anchor
                    avPlayer.isMuted = wasMuted
                }
            }
        }
    }

    // MARK: - Transport

    func togglePlayback(for project: Project) {
        setPlaying(!isPlaying, for: project)
    }

    /// Play / pause — the Mac's `updatePlaybackState` (re-anchors at the
    /// head, past the end, or when the decoder is a frame off the playhead).
    func setPlaying(_ playing: Bool, for project: Project) {
        guard let mainPlayer = player else { return }
        isPlaying = playing
        if !playing {
            pendingPlaybackStartTime = nil
            mainPlayer.pause()
            cameraPlayer?.pause()
            syncCameraPlayer(for: project)
            return
        }
        if currentTime < project.effectiveTrimStart || !isWithinTrimRange(project, currentTime) {
            seekAndStartPlayback(at: project.effectiveTrimStart, for: project, player: mainPlayer)
            return
        }
        let effectiveEnd = project.effectiveTrimEnd > 0 ? project.effectiveTrimEnd : project.duration
        if currentTime >= max(0, effectiveEnd - 0.1) {
            seekAndStartPlayback(at: project.effectiveTrimStart, for: project, player: mainPlayer)
            return
        }
        let target = min(max(currentTime, project.effectiveTrimStart), effectiveEnd)
        let decoderTime = mainPlayer.currentTime().seconds
        let atHead = target <= project.effectiveTrimStart + (1.0 / 120.0)
        let stale = !decoderTime.isFinite || abs(decoderTime - target) > (1.0 / 60.0)
        if atHead || stale {
            seekAndStartPlayback(at: target, for: project, player: mainPlayer)
            return
        }
        startPlayback(for: project)
    }

    private func seekAndStartPlayback(at target: TimeInterval, for project: Project, player mainPlayer: AVPlayer) {
        pendingScrubTime = nil
        pendingScrubExact = false
        scrubSeekGeneration &+= 1
        scrubSeekInFlight = false
        isScrubbing = false
        mainPlayer.currentItem?.cancelPendingSeeks()
        pendingPlaybackStartTime = target
        currentTime = target
        mainPlayer.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak mainPlayer] finished in
            MainActor.assumeIsolated {
                guard let self, let mainPlayer, self.player === mainPlayer,
                      let pending = self.pendingPlaybackStartTime, abs(pending - target) < 0.001 else { return }
                self.pendingPlaybackStartTime = nil
                guard finished, self.isPlaying else {
                    if !finished { self.isPlaying = false }
                    return
                }
                self.currentTime = target
                self.startPlayback(for: project)
            }
        }
    }

    private func startPlayback(for project: Project) {
        guard let mainPlayer = player else { return }
        let rate = Float(Self.activeSpeed(for: project, at: currentTime))
        if project.settings.showCamera, let cam = cameraPlayer,
           currentTime >= effectiveCameraOffset, !hasPassedCameraEnd(currentTime) {
            let hostStart = CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()),
                                      CMTime(seconds: 0.03, preferredTimescale: 600))
            mainPlayer.setRate(rate, time: CMTime(seconds: max(0, currentTime), preferredTimescale: 600),
                               atHostTime: hostStart)
            cam.setRate(rate, time: CMTime(seconds: targetCameraTime(currentTime), preferredTimescale: 600),
                        atHostTime: hostStart)
            return
        }
        mainPlayer.rate = rate
    }

    /// Seeks for a scrub, publishing the target immediately. `exact` is false
    /// while the finger moves (responsive frames) and true on release.
    func scrub(to sourceTime: TimeInterval, for project: Project, exact: Bool) {
        let target = min(max(sourceTime, project.effectiveTrimStart), project.effectiveTrimEnd)
        pendingPlaybackStartTime = nil
        isScrubbing = !exact
        if isPlaying { isPlaying = false }
        guard let player else {
            currentTime = target
            return
        }
        player.pause()
        cameraPlayer?.pause()
        pendingScrubTime = target
        pendingScrubExact = exact
        currentTime = target
        startPendingScrubSeek(on: player, project: project)
    }

    /// One frame forward / back (paused, exact).
    func step(frames: Int, for project: Project) {
        scrub(to: currentTime + Double(frames) * frameDuration, for: project, exact: true)
    }

    /// Serial "chase time" seek: a new target never cancels the decoder's
    /// in-flight work; when a seek lands, the player chases the newest one.
    private func startPendingScrubSeek(on player: AVPlayer, project: Project) {
        guard !scrubSeekInFlight, let target = pendingScrubTime else { return }
        scrubSeekInFlight = true
        let exact = pendingScrubExact
        let generation = scrubSeekGeneration
        let tolerance = exact ? CMTime.zero : CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self, weak player] _ in
            MainActor.assumeIsolated {
                guard let self, let player, self.player === player,
                      self.scrubSeekGeneration == generation else { return }
                self.scrubSeekInFlight = false
                guard let pending = self.pendingScrubTime else { return }
                let reachedLatest = abs(pending - target) < 0.001
                let reachedPrecision = !self.pendingScrubExact || exact
                if reachedLatest && reachedPrecision {
                    self.pendingScrubTime = nil
                    self.pendingScrubExact = false
                    self.currentTime = target
                    self.syncCameraPlayer(for: project)
                } else {
                    self.startPendingScrubSeek(on: player, project: project)
                }
            }
        }
    }

    /// Keeps the playhead inside a changed trim range.
    func syncToTrimRange(for project: Project) {
        guard let player else { return }
        let clamped = min(max(currentTime, project.effectiveTrimStart), project.effectiveTrimEnd)
        guard abs(clamped - currentTime) > (1.0 / 240.0) else { return }
        currentTime = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func isWithinTrimRange(_ project: Project, _ time: TimeInterval) -> Bool {
        time >= project.effectiveTrimStart - (1.0 / 120.0) && time <= project.effectiveTrimEnd + (1.0 / 120.0)
    }

    /// Speed in effect at a source time (1 outside every speed region).
    static func activeSpeed(for project: Project, at time: TimeInterval) -> Double {
        for region in project.speedRegions where time >= region.startTime && time <= region.endTime {
            return max(0.1, region.speed)
        }
        return 1.0
    }

    // MARK: - Camera

    /// Whether the stage should draw the camera player this frame (the Mac's
    /// `showCameraOverlay`).
    func showsCameraPlayer(for project: Project) -> Bool {
        guard project.settings.showCamera, cameraPlayer != nil else { return false }
        if cameraDuration > 0 {
            guard currentTime + (1.0 / 120.0) >= max(0, effectiveCameraOffset),
                  currentTime <= project.duration + (1.0 / 30.0) else { return false }
        }
        return currentTime >= max(effectiveCameraOffset, 1.0 / 120.0)
    }

    func setCameraEnabled(_ show: Bool, for project: Project) {
        if show {
            if cameraPlayer == nil { setupCameraPlayer(for: project) }
        } else {
            cameraSetupGeneration += 1
            cameraPlayer?.pause()
            cameraPlayer = nil
            cameraPosterImage = nil
        }
    }

    private func setupCameraPlayer(for project: Project) {
        guard let url = project.cameraVideoURL else { return }
        cameraSetupGeneration += 1
        let generation = cameraSetupGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            let source = AVURLAsset(url: url)
            let (asset, leadIn) = await Self.normalizedCameraAsset(for: source)
            let item = AVPlayerItem(asset: asset)
            let cam = AVPlayer(playerItem: item)
            cam.isMuted = true
            cam.automaticallyWaitsToMinimizeStalling = false
            let duration = (try? await asset.load(.duration)).map(\.seconds) ?? 0
            let size = (try? await asset.loadTracks(withMediaType: .video).first?.load(.naturalSize)) ?? .zero
            let poster = await Self.frameImage(asset: asset, at: 0)
            guard generation == self.cameraSetupGeneration else { return }
            self.cameraDuration = duration.isFinite ? duration : 0
            self.cameraSourceLeadIn = leadIn
            if size.width > 0, size.height > 0 { self.cameraVideoAspect = size.width / size.height }
            self.cameraPosterImage = poster
            self.cameraPlayer = cam
            self.syncCameraPlayer(for: project)
        }
    }

    private func syncCameraIfNeeded(project: Project) {
        guard let cam = cameraPlayer, project.settings.showCamera else { return }
        let drift = abs(cam.currentTime().seconds - targetCameraTime(currentTime))
        if !isPlaying || currentTime < effectiveCameraOffset || hasPassedCameraEnd(currentTime) {
            if cam.rate != 0 { cam.pause() }
            if drift > (1.0 / 240.0) { syncCameraPlayer(for: project) }
            return
        }
        if cam.rate == 0 || drift > (1.0 / 45.0) {
            let rate = Float(Self.activeSpeed(for: project, at: currentTime))
            let hostStart = CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()),
                                      CMTime(seconds: 0.03, preferredTimescale: 600))
            cam.setRate(rate, time: CMTime(seconds: targetCameraTime(currentTime + 0.03), preferredTimescale: 600),
                        atHostTime: hostStart)
        }
    }

    private func syncCameraPlayer(for project: Project) {
        guard let player, let cam = cameraPlayer else { return }
        let target = targetCameraTime(player.currentTime().seconds)
        cam.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func targetCameraTime(_ timelineTime: TimeInterval) -> TimeInterval {
        let unclamped = max(0, timelineTime - effectiveCameraOffset)
        guard cameraDuration > 0 else { return unclamped }
        return min(unclamped, max(0, cameraDuration - (1.0 / 240.0)))
    }

    private func hasPassedCameraEnd(_ timelineTime: TimeInterval) -> Bool {
        guard cameraDuration > 0 else { return false }
        return timelineTime >= effectiveCameraOffset + cameraDuration - (1.0 / 120.0)
    }

    /// The camera asset re-anchored so content starts at PTS 0, plus the
    /// leading gap trimmed (the Mac's `normalizedCameraAsset`).
    private static func normalizedCameraAsset(for asset: AVAsset) async -> (AVAsset, TimeInterval) {
        let first = await firstVideoSampleTime(for: asset)
        guard first > (1.0 / 240.0),
              let duration = try? await asset.load(.duration), duration.seconds.isFinite, duration.seconds > first,
              let track = try? await asset.loadTracks(withMediaType: .video).first else { return (asset, 0) }
        let composition = AVMutableComposition()
        guard let compTrack = composition.addMutableTrack(withMediaType: .video,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return (asset, 0)
        }
        let scale = duration.timescale == 0 ? 600 : duration.timescale
        let start = CMTime(seconds: first, preferredTimescale: scale)
        do {
            try compTrack.insertTimeRange(CMTimeRange(start: start, duration: CMTimeSubtract(duration, start)),
                                          of: track, at: .zero)
            compTrack.preferredTransform = (try? await track.load(.preferredTransform)) ?? .identity
            return (composition, first)
        } catch {
            return (asset, 0)
        }
    }

    private static func firstVideoSampleTime(for asset: AVAsset) async -> TimeInterval {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else { return 0 }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { return 0 }
        reader.add(output)
        guard reader.startReading(), let sample = output.copyNextSampleBuffer() else { return 0 }
        let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        reader.cancelReading()
        return t.isFinite ? max(0, t) : 0
    }

    // MARK: - Frames

    /// One decoded frame at `time` (exact), for posters.
    static func frameImage(asset: AVAsset, at time: TimeInterval) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        guard let result = try? await generator.image(at: CMTime(seconds: max(0, time), preferredTimescale: 600))
        else { return nil }
        return UIImage(cgImage: result.image, scale: 1, orientation: .up)
    }
}

/// The display link's target (CADisplayLink retains its target; the
/// controller owns this, not the other way round).
private final class DisplayTickTarget: NSObject {
    var tick: (@MainActor () -> Void)?
    @objc func step(_ link: CADisplayLink) {
        MainActor.assumeIsolated { tick?() }
    }
}
