import AVFoundation
import AppKit
import Observation
import OSLog

#if DEBUG
private let voiceOverEditorLogger = Logger(subsystem: "so.capturecat.CaptureCat", category: "VoiceOverEditor")
#endif

/// Editor playback: the AVPlayer, the camera player, the periodic time
/// observer, and every piece of state they drive.
///
/// AppKit P6 extraction — this is a **mechanical** lift of the `@State` +
/// private methods that used to live in `EditorView`. Nothing about the logic
/// changed: same order inside the time-observer block, same guards, same
/// seeks. The only structural difference is that the state now lives in one
/// `@Observable` object so BOTH shells (the SwiftUI `EditorView` fallback and
/// the native `EditorShellViewController`) read the same instance instead of
/// SwiftUI-only `@State`.
///
/// The SwiftUI shell keeps driving side effects through its existing
/// `.onChange` modifiers — they are untouched. The native shell gets the same
/// wiring through `EditorPlaybackObserver`.
///
/// ### Time-observer consumers (P6 audit — every one must keep firing)
/// 1. `currentTime` publish — preview render (zoom/tilt springs, cursor,
///    ripples, annotations), timeline playhead, inspector `currentTime`.
/// 2. Click sounds — `ClickSoundPlayer` on each *discrete* click crossed.
/// 3. Keyboard sounds — `KeySoundPlayer` for up to 3 keystrokes crossed.
/// 4. Live speed ramps — `player.rate` (and camera rate) tracked to the
///    active speed region.
/// 5. Trim-end stop — pause, rewind to trim start, pause camera.
/// 6. Camera sync — driven off the `currentTime` change (`syncCameraPlaybackIfNeeded`).
/// 7. Voice-over refresh / metering — `liveVoiceOverSamples`, rebuild debounce.
///
/// `observerCounters` records 1–5 (and 6/7 where they are invoked) so the
/// `--playback-observer-test` harness can assert each still fires after the
/// extraction.
@MainActor
@Observable
final class EditorPlaybackController {

    // MARK: - Debug instrumentation

    /// Per-consumer fire counts for the extraction acceptance harness.
    struct ObserverCounters: Sendable, Equatable {
        var ticks = 0
        var currentTimePublishes = 0
        var clickSounds = 0
        var keySounds = 0
        var rateChanges = 0
        var trimEndStops = 0
        var cameraSyncs = 0
        var endOfItem = 0
        var voiceOverMeterSamples = 0
    }

    @ObservationIgnored var observerCounters = ObserverCounters()

    // MARK: - State (verbatim from EditorView's @State)

    var player: AVPlayer?
    var currentTime: Double = 0
    var isPlaying = false
    var cursorEvents: [CursorEvent] = []
    var keystrokeEvents: [KeystrokeEvent] = []
    var cursorCoordinateSize: CGSize = .zero

    /// Positions exactly as recorded. `cursorEvents` is derived from these, so
    /// a change to the smoothing settings can be re-applied without reloading
    /// the project — and so turning smoothing off restores the exact path
    /// rather than an approximation of it.
    private var rawCursorEvents: [CursorEvent] = []
    private var appliedSmoothing: String?


    /// Re-derives `cursorEvents` from the raw path. Cheap to call: it no-ops
    /// unless the settings actually changed.
    func applyCursorSmoothing(settings: ProjectSettings, trimEnd: TimeInterval = 0) {
        // Signature string (tuples cap == at 6 elements).
        let want = [
            "\(settings.smoothCursor)", "\(settings.smoothingFactor)",
            "\(settings.cursorFluidEnabled)", "\(settings.cursorTension)",
            "\(settings.cursorFriction)", "\(settings.cursorMass)",
            "\(settings.cursorLoopToStart)", "\(settings.cursorStopAtEnd)",
            "\(trimEnd)",
        ].joined(separator: "|")
        if let applied = appliedSmoothing, applied == want { return }
        appliedSmoothing = want
        let smoothed = settings.smoothCursor
            ? CursorSmoother(factor: settings.smoothingFactor).smooth(events: rawCursorEvents)
            : rawCursorEvents
        // Fluid movement AFTER smoothing — the exporter applies the identical
        // chain (see VideoExporter's cursor load).
        var chained = CursorSpringMath.apply(events: smoothed, settings: settings)
        chained = CursorEndBehaviorMath.apply(
            events: chained,
            trimEnd: trimEnd,
            loopToStart: settings.cursorLoopToStart,
            stopAtEnd: settings.cursorStopAtEnd)
        cursorEvents = chained
    }
    var videoSize: CGSize = .zero
    @ObservationIgnored private var timeObserverToken: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    /// While Play is waiting for an exact seek, periodic AVPlayer callbacks
    /// can still report the OLD decoder position. Publishing that stale time
    /// makes effects at the visible playhead (especially a tilt at 0:00)
    /// disappear before playback actually starts.
    @ObservationIgnored private var pendingPlaybackStartTime: TimeInterval?
    /// While the timeline is being dragged, AVPlayer can keep reporting the
    /// decoder's previous frame until its asynchronous seek catches up. Pin
    /// the observable playhead to the user's latest drag target so the
    /// compositor updates continuously instead of bouncing back to stale time.
    @ObservationIgnored private var pendingScrubTime: TimeInterval?
    @ObservationIgnored private var pendingScrubExact = false
    @ObservationIgnored private var scrubSeekInFlight = false
    @ObservationIgnored private var scrubSeekGeneration = 0
    var isScrubbing = false
    var cameraPlayer: AVPlayer?
    var cameraPosterImage: NSImage?
    var cameraDuration: TimeInterval = 0
    var effectiveCameraOffset: TimeInterval = 0
    var cameraHasDecodedFrame = false
    @ObservationIgnored private let voiceOverRecorder = VoiceOverRecorder()
    var isRecordingVoiceOver = false
    var voiceOverRecordingStartTime: Double?
    var liveVoiceOverSamples: [Float] = []
    @ObservationIgnored private var voiceOverRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var voiceOverMeterTask: Task<Void, Never>?
    @ObservationIgnored private var cameraSetupGeneration = 0
    var cameraVideoAspect: CGFloat = 1
    var videoPosterImage: NSImage?

    /// Owning app state — only used for `projectStore` autosave scheduling,
    /// exactly as the old `@Environment(AppState.self)` reads did.
    @ObservationIgnored private weak var appState: AppState?

    init(appState: AppState?) {
        self.appState = appState
    }

    func attach(appState: AppState) {
        self.appState = appState
    }

    private var projectStore: ProjectStore? { appState?.projectStore }

    // MARK: - Derived (verbatim from EditorView)

    func isWithinTrimRange(for project: Project, time: TimeInterval) -> Bool {
        time >= project.effectiveTrimStart - (1.0 / 120.0)
            && time <= project.effectiveTrimEnd + (1.0 / 120.0)
    }

    var shouldShowCameraPlayer: Bool {
        guard let _ = cameraPlayer else { return false }
        guard currentTime >= max(effectiveCameraOffset, 1.0 / 120.0) else { return false }
        return isPlaying || cameraHasDecodedFrame
    }

    var visibleCameraPosterImage: NSImage? {
        guard let cameraPosterImage else { return nil }
        let playerStartTime = max(effectiveCameraOffset, 1.0 / 120.0)
        if currentTime < playerStartTime {
            return cameraPosterImage
        }
        return shouldShowCameraPlayer ? nil : cameraPosterImage
    }

    /// The `showCameraOverlay` expression `EditorView.editorContent` computed.
    func showCameraOverlay(for project: Project) -> Bool {
        project.settings.showCamera
            && cameraTimeInRange(for: project)
            && shouldShowCameraPlayer
    }

    // MARK: - Setup / teardown

    func setupPlayer(
        for project: Project,
        initialTime: TimeInterval? = nil,
        resumePlayback: Bool = false
    ) async {
        guard let url = project.videoURL else { return }

        cleanupPlayer()

        let asset = AVURLAsset(url: url)
        // Preview keeps a 1:1 source-time composition — speed is applied live via
        // `player.rate` below so the timeline's source-time UI stays in sync.
        let preparedAudio = try? await ProjectAudioMix.prepare(for: asset, project: project, applySpeedScaling: false)
        let item = AVPlayerItem(asset: preparedAudio?.asset ?? asset)
        item.audioMix = preparedAudio?.audioMix
        item.audioTimePitchAlgorithm = .timeDomain

        let avPlayer = AVPlayer(playerItem: item)
        avPlayer.automaticallyWaitsToMinimizeStalling = false
        cameraPosterImage = nil
        cameraHasDecodedFrame = false

        // Get video dimensions
        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            videoSize = (try? await track.load(.naturalSize)) ?? .zero
            print("[Editor] Video naturalSize: \(videoSize)")
            if let cursorURL = project.cursorDataURL,
               let recording = try? CursorTracker.loadRecording(from: cursorURL) {
                print("[Editor] Cursor coordinateSize: \(recording.coordinateSize)")
                print("[Editor] Events count: \(recording.events.count)")
            }
        }
        if let duration = try? await asset.load(.duration) {
            let seconds = duration.seconds
            if seconds.isFinite, seconds > 0, abs(project.duration - seconds) > (1.0 / 120.0) {
                project.duration = seconds
                projectStore?.scheduleAutoSave(for: project)
            }
        }

        // Shared-origin recordings start with a PTS gap (capture spins up after
        // the origin is taken), so t=0 has no frame — the editor would open on
        // an empty background until playback reaches the first sample. Trim the
        // project to the first real frame, Screen Studio-style.
        if project.trimStart <= 0.001 {
            let firstSample = await firstVideoSampleTime(for: asset)
            if firstSample > (1.0 / 30.0), firstSample < max(0, project.duration - 0.5) {
                project.trimStart = firstSample
                projectStore?.scheduleAutoSave(for: project)
            }
        }
        effectiveCameraOffset = resolvedCameraOffset(for: project)

        // Load cursor data
        if let keysURL = project.keystrokeDataURL {
            keystrokeEvents = (try? KeystrokeTracker.loadRecording(from: keysURL).events) ?? []
        } else {
            keystrokeEvents = []
        }
        if let cursorURL = project.cursorDataURL {
            let recording = try? CursorTracker.loadRecording(from: cursorURL)
            // Keep the RAW events. Smoothing used to be baked in here, once, at
            // load — so toggling "Smooth cursor" (or moving its slider) changed
            // nothing until the project was closed and reopened. Someone
            // turning it off to fix a mis-positioned cursor saw no effect and
            // reasonably concluded the setting was broken.
            rawCursorEvents = recording?.events ?? []
            // Invalidate the derived cache: it is keyed only on the SETTINGS,
            // so loading a different project with identical settings would
            // otherwise early-return and leave `cursorEvents` holding the
            // previous project's path — or nothing at all on first load.
            appliedSmoothing = nil
            cursorCoordinateSize = recording?.hasValidCoordinateSpace == true ? recording?.coordinateSize ?? .zero : .zero
            applyCursorSmoothing(settings: project.settings, trimEnd: project.effectiveTrimEnd)
        } else {
            rawCursorEvents = []
            cursorEvents = []
            appliedSmoothing = nil
            cursorCoordinateSize = .zero
        }

        // Periodic time observer at ~30fps
        let interval = CMTime(seconds: 1.0 / 60.0, preferredTimescale: 600)
        timeObserverToken = avPlayer.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self, weak avPlayer] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let pending = self.pendingPlaybackStartTime {
                    // Keep the editor pinned to the requested frame until the
                    // exact seek completes; never leak the decoder's old time
                    // into the preview/timeline observation graph.
                    self.currentTime = pending
                    return
                }
                if let pending = self.pendingScrubTime {
                    self.currentTime = pending
                    return
                }
                // A paused player's periodic observer can emit one last
                // decoder timestamp after an exact seek completes. The
                // timeline already published the user's requested source
                // time, so accepting that callback would move the playhead to
                // a nearby sample (for example 0.820 -> 0.833) after mouse-up.
                // Only playback owns the clock once no explicit seek is
                // pending; paused editor operations publish their own time.
                guard self.isPlaying else { return }
                let t = time.seconds
                let previous = self.currentTime
                self.currentTime = t
                self.observerCounters.ticks += 1
                self.observerCounters.currentTimePublishes += 1

                // Click sound: one tick per DISCRETE click crossed this observer
                // tick (edge-deduped like the ripple — the tracker flags every
                // sample while the button is down, so raw isClick would machine-
                // gun hundreds of ticks per click).
                if self.isPlaying, project.settings.clickSoundEnabled,
                   t > previous, t - previous < 0.35 {
                    let crossed = ClickRippleOverlay.discreteClickTimes(
                        from: self.cursorEvents, coordinateSize: self.cursorCoordinateSize
                    ).contains { $0 > previous && $0 <= t }
                    if crossed {
                        ClickSoundPlayer.shared.play(volume: project.settings.clickSoundVolume, style: project.settings.clickSoundStyle)
                        self.observerCounters.clickSounds += 1
                    }
                }

                // Keyboard sounds: play each keystroke crossed this tick (capped
                // at 3 per tick; density is already capped at export).
                if self.isPlaying, project.settings.keySoundEnabled,
                   t > previous, t - previous < 0.35 {
                    let crossedKeys = self.keystrokeEvents.lazy
                        .filter { $0.category != .scroll }
                        .filter { $0.timestamp > previous && $0.timestamp <= t }
                        .prefix(3)
                    for key in crossedKeys {
                        KeySoundPlayer.shared.play(
                            timestamp: key.timestamp,
                            category: key.category,
                            volume: project.settings.keySoundVolume,
                            style: project.settings.keySoundStyle
                        )
                        self.observerCounters.keySounds += 1
                    }
                }

                // Live playback-speed: match player.rate to whichever speed region the
                // playhead is inside. Only touch rate when actively playing so pause
                // (rate == 0) is preserved.
                if let avPlayer, self.isPlaying, avPlayer.timeControlStatus != .paused {
                    let targetRate = Float(self.activeSpeed(for: project, at: t))
                    if abs(avPlayer.rate - targetRate) > 0.01 {
                        avPlayer.rate = targetRate
                        self.observerCounters.rateChanges += 1
                        if let cam = self.cameraPlayer, cam.rate > 0 {
                            cam.rate = targetRate
                        }
                    }
                }

                // Stop at trim end during playback
                if self.isPlaying, project.effectiveTrimEnd > 0, t >= project.effectiveTrimEnd {
                    self.isPlaying = false
                    self.currentTime = project.effectiveTrimStart
                    let seekTime = CMTime(seconds: project.effectiveTrimStart, preferredTimescale: 600)
                    avPlayer?.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
                    self.cameraPlayer?.pause()
                    self.observerCounters.trimEndStops += 1
                }
            }
        }

        // Handle end of playback
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: avPlayer.currentItem,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isPlaying = false
                let resetTime = project.effectiveTrimStart
                self.currentTime = resetTime
                let seekTime = CMTime(seconds: resetTime, preferredTimescale: 600)
                avPlayer.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
                self.cameraPlayer?.pause()
                if let camPlayer = self.cameraPlayer {
                    camPlayer.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                }
                self.observerCounters.endOfItem += 1
            }
        }

        avPlayer.isMuted = project.settings.muteRecordedAudio
        player = avPlayer
        let startTime = min(
            max(initialTime ?? project.effectiveTrimStart, project.effectiveTrimStart),
            project.effectiveTrimEnd
        )
        currentTime = startTime
        await avPlayer.seek(
            to: CMTime(seconds: startTime, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )

        // AVPlayerLayer on macOS doesn't reliably decode a frame for a paused
        // seek on a fresh item — the preview stays empty until the user presses
        // play. Same quirk the camera player works around: once the item is
        // ready, briefly play muted and pause, which forces the first frame to
        // render, then seek back to the exact start position.
        Task { @MainActor [weak self, weak avPlayer] in
            guard let self, let avPlayer else { return }
            let deadline = Date().addingTimeInterval(5)
            while avPlayer.currentItem?.status != .readyToPlay && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard avPlayer.currentItem?.status == .readyToPlay,
                  avPlayer.rate == 0,
                  self.player === avPlayer,
                  !self.isPlaying else { return }

            let wasMuted = avPlayer.isMuted
            let anchorTime = self.currentTime
            avPlayer.isMuted = true
            avPlayer.play()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard !self.isPlaying else {
                        avPlayer.isMuted = wasMuted
                        return
                    }
                    avPlayer.pause()
                    avPlayer.seek(
                        to: CMTime(seconds: anchorTime, preferredTimescale: 600),
                        toleranceBefore: .zero,
                        toleranceAfter: .zero
                    )
                    self.currentTime = anchorTime
                    avPlayer.isMuted = wasMuted
                }
            }
        }

        // Decode the start frame directly — shown by PreviewView until the
        // player layer reports isReadyForDisplay, so the editor never opens on
        // an empty background even when AVPlayerLayer stalls on a paused seek.
        print("[Preview] setupPlayer: start=\(startTime) trimStart=\(project.trimStart) trimEnd=\(project.trimEnd) duration=\(project.duration)")
        Task { @MainActor [weak self] in
            guard let self else { return }
            let poster = await self.generateVideoPoster(asset: asset, at: startTime)
            if let poster {
                print("[Preview] poster OK: requested t=\(startTime), decoded t=\(poster.actualTime), size=\(poster.image.size)")
            } else {
                print("[Preview] poster FAILED for t=\(startTime)")
            }
            self.videoPosterImage = poster?.image
            // Recordings with a damaged head decode their first real frame well
            // after t=0 — pull the trim up to it so the playhead never sits on
            // dead video (trim onChange re-seeks playback automatically).
            if let poster,
               project.trimStart <= 0.001,
               poster.actualTime > startTime + (1.0 / 30.0),
               poster.actualTime < max(0, project.duration - 0.5) {
                project.trimStart = poster.actualTime
                self.projectStore?.scheduleAutoSave(for: project)
            }
        }

        // Set up camera player if recorded footage exists and camera is enabled
        if project.settings.showCamera {
            setupCameraPlayer(for: project)
        }

        if resumePlayback {
            startPlayback(for: project)
        }
    }

    private func generateVideoPoster(
        asset: AVAsset,
        at time: TimeInterval
    ) async -> (image: NSImage, actualTime: TimeInterval)? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.75, preferredTimescale: 600)
        // Recordings from older builds can have a damaged head (duplicate PTS-0
        // B-frame samples) where generation fails outright — walk forward until
        // a frame decodes so the preview always has something to show.
        for offset in [0.0, 0.15, 0.4, 0.8, 1.5] {
            let target = CMTime(seconds: max(0, time + offset), preferredTimescale: 600)
            if let result = try? await generator.image(at: target) {
                let image = NSImage(
                    cgImage: result.image,
                    size: NSSize(width: result.image.width, height: result.image.height)
                )
                let actual = result.actualTime.seconds
                return (image, actual.isFinite ? max(0, actual) : time)
            }
        }
        // Device-mirroring recordings can carry bad data (VT -12909) well past
        // the fixed offsets above. Last resort: unlimited tolerance, so
        // AVFoundation returns the FIRST decodable frame wherever it is — its
        // actualTime then drives the caller's trim pull-up off the dead head.
        let fallback = AVAssetImageGenerator(asset: asset)
        fallback.appliesPreferredTrackTransform = true
        fallback.requestedTimeToleranceBefore = .positiveInfinity
        fallback.requestedTimeToleranceAfter = .positiveInfinity
        if let result = try? await fallback.image(
            at: CMTime(seconds: max(0, time), preferredTimescale: 600)
        ) {
            let image = NSImage(
                cgImage: result.image,
                size: NSSize(width: result.image.width, height: result.image.height)
            )
            let actual = result.actualTime.seconds
            return (image, actual.isFinite ? max(0, actual) : time)
        }
        return nil
    }

    func applyAudioMix(for project: Project) async {
        let requiresPlaybackRebuild = !project.voiceOverClips.isEmpty
            || !project.videoClipSegments.isEmpty
            || !project.speedRegions.isEmpty

        guard requiresPlaybackRebuild else {
            guard let item = player?.currentItem, let videoURL = project.videoURL else { return }
            let asset = AVURLAsset(url: videoURL)
            if let preparedAudio = try? await ProjectAudioMix.prepare(for: asset, project: project) {
                item.audioMix = preparedAudio.audioMix
            } else {
                item.audioMix = nil
            }
            return
        }

        await rebuildPlayback(for: project, preserveTime: currentTime, resumePlayback: isPlaying)
    }

    func setupCameraPlayer(for project: Project) {
        guard let cameraURL = project.cameraVideoURL else { return }
        guard cameraPlayer == nil else {
            // Already set up — just sync position
            syncCameraPlayer(for: project)
            return
        }

        let savedPosterImage = savedCameraPosterImage(for: project)
        cameraHasDecodedFrame = false
        cameraPosterImage = savedPosterImage

        cameraSetupGeneration += 1
        let generation = cameraSetupGeneration
        Task { [weak self] in
            guard let self else { return }
            let sourceAsset = AVURLAsset(url: cameraURL)
            async let normalizedAssetTask = self.normalizedCameraAsset(for: sourceAsset)
            let (normalizedAsset, trimmedLeadIn) = await normalizedAssetTask
            let item = AVPlayerItem(asset: normalizedAsset)
            item.seekingWaitsForVideoCompositionRendering = true
            let videoOutput = AVPlayerItemVideoOutput(
                pixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
            )
            item.add(videoOutput)

            let camPlayer = AVPlayer(playerItem: item)
            camPlayer.isMuted = true // Audio comes from main recording
            camPlayer.automaticallyWaitsToMinimizeStalling = false
            camPlayer.preventsDisplaySleepDuringVideoPlayback = false
            camPlayer.actionAtItemEnd = .pause

            let duration = (try? await normalizedAsset.load(.duration)).map(\.seconds) ?? 0
            let cameraSize = (try? await normalizedAsset.loadTracks(withMediaType: .video).first?.load(.naturalSize)) ?? .zero
            let decodedPosterImage = await self.warmCameraPlayer(camPlayer, videoOutput: videoOutput)
            item.remove(videoOutput)
            let normalizedPosterImage = await self.firstVideoFrameImage(for: normalizedAsset)
            let sourcePosterImage = normalizedPosterImage == nil
                ? await self.firstVideoFrameImage(for: sourceAsset)
                : nil
            let posterImage = savedPosterImage
                ?? decodedPosterImage
                ?? normalizedPosterImage
                ?? sourcePosterImage
            await MainActor.run {
                // A newer setup started, or the camera was switched off while we
                // were loading — don't resurrect a stale player.
                guard generation == self.cameraSetupGeneration, project.settings.showCamera else {
                    camPlayer.pause()
                    return
                }
                self.cameraPlayer = camPlayer
                self.cameraPosterImage = posterImage
                self.cameraHasDecodedFrame = decodedPosterImage != nil || savedPosterImage != nil
                self.cameraDuration = max(0, duration.isFinite ? duration : 0)
                if cameraSize.width > 0, cameraSize.height > 0 {
                    self.cameraVideoAspect = cameraSize.width / cameraSize.height
                }
                // Normalization trimmed `trimmedLeadIn` seconds of leading gap
                // off the camera asset — shift the offset by the same amount so
                // preview timing matches the raw-PTS math the exporter uses.
                self.effectiveCameraOffset = self.resolvedCameraOffset(for: project) + trimmedLeadIn
                self.persistCameraPosterImage(posterImage, for: project)
                self.syncCameraPlayer(for: project)
            }
        }
    }

    /// The `onChange(of: project.settings.showCamera)` body from `editorShell`.
    func setCameraEnabled(_ show: Bool, for project: Project) {
        if show {
            setupCameraPlayer(for: project)
        } else {
            cameraSetupGeneration += 1 // invalidate any in-flight setup task
            cameraPlayer?.pause(); cameraPlayer = nil; cameraPosterImage = nil; cameraHasDecodedFrame = false
        }
    }

    func updatePlaybackState(for project: Project, playing: Bool) {
        guard let mainPlayer = player else { return }

        if !playing {
            pendingPlaybackStartTime = nil
            mainPlayer.pause()
            if let camPlayer = cameraPlayer, project.settings.showCamera {
                camPlayer.pause()
                syncCameraPlayer(for: project)
            }
            return
        }

        if currentTime < project.effectiveTrimStart || !isWithinTrimRange(for: project, time: currentTime) {
            seekAndStartPlayback(at: project.effectiveTrimStart, for: project, player: mainPlayer)
            return
        }

        let effectiveEnd = project.effectiveTrimEnd > 0 ? project.effectiveTrimEnd : project.duration
        let restartThreshold = max(0, effectiveEnd - 0.1)
        if currentTime >= restartThreshold {
            seekAndStartPlayback(at: project.effectiveTrimStart, for: project, player: mainPlayer)
            return
        }

        // Timeline seeks are asynchronous. The observable playhead moves
        // immediately, but AVPlayer may still be at the previous location.
        // Always re-anchor at the project head, and re-anchor anywhere else
        // when the decoder differs from the visible playhead by a frame.
        let targetTime = min(max(currentTime, project.effectiveTrimStart), effectiveEnd)
        let decoderTime = mainPlayer.currentTime().seconds
        let atProjectHead = targetTime <= project.effectiveTrimStart + (1.0 / 120.0)
        let decoderIsStale = !decoderTime.isFinite || abs(decoderTime - targetTime) > (1.0 / 60.0)
        if atProjectHead || decoderIsStale {
            seekAndStartPlayback(at: targetTime, for: project, player: mainPlayer)
            return
        }

        startPlayback(for: project)
    }

    private func seekAndStartPlayback(
        at targetTime: TimeInterval,
        for project: Project,
        player mainPlayer: AVPlayer
    ) {
        pendingScrubTime = nil
        pendingScrubExact = false
        scrubSeekGeneration &+= 1
        scrubSeekInFlight = false
        isScrubbing = false
        mainPlayer.currentItem?.cancelPendingSeeks()
        pendingPlaybackStartTime = targetTime
        currentTime = targetTime
        mainPlayer.seek(
            to: CMTime(seconds: targetTime, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self, weak mainPlayer] finished in
            MainActor.assumeIsolated {
                guard let self,
                      let mainPlayer,
                      self.player === mainPlayer,
                      let pending = self.pendingPlaybackStartTime,
                      abs(pending - targetTime) < (1.0 / 1_000.0)
                else { return }

                self.pendingPlaybackStartTime = nil
                guard finished, self.isPlaying else {
                    if !finished { self.isPlaying = false }
                    return
                }
                self.currentTime = targetTime
                self.startPlayback(for: project)
            }
        }
    }

    /// Seeks from a timeline drag while publishing the target immediately.
    /// `exact` is false during mouse movement for responsive frame delivery and
    /// true on mouse-up so the settled playhead is frame-accurate.
    func scrub(
        to sourceTime: TimeInterval,
        for project: Project,
        exact: Bool
    ) {
        let target = min(
            max(sourceTime, project.effectiveTrimStart),
            project.effectiveTrimEnd
        )
        pendingPlaybackStartTime = nil
        isScrubbing = !exact
        if isPlaying { isPlaying = false }

        guard let player else {
            currentTime = target
            pendingScrubTime = nil
            pendingScrubExact = false
            return
        }

        player.pause()
        pendingScrubTime = target
        pendingScrubExact = exact
        currentTime = target
        startPendingScrubSeek(on: player)
    }

    /// Serial "chase time" seek. A new mouse event updates
    /// `pendingScrubTime` without cancelling the decoder's in-flight work; as
    /// soon as that frame arrives, the player seeks to the newest target. This
    /// produces useful frames throughout a drag instead of starving AVPlayer
    /// by cancelling every seek before it can finish.
    private func startPendingScrubSeek(on player: AVPlayer) {
        guard !scrubSeekInFlight, let target = pendingScrubTime else { return }
        scrubSeekInFlight = true
        let exact = pendingScrubExact
        let generation = scrubSeekGeneration
        let tolerance = exact
            ? CMTime.zero
            : CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        ) { [weak self, weak player] _ in
            MainActor.assumeIsolated {
                guard let self,
                      let player,
                      self.player === player,
                      self.scrubSeekGeneration == generation
                else { return }
                self.scrubSeekInFlight = false
                guard let pending = self.pendingScrubTime else { return }
                let reachedLatest = abs(pending - target) < (1.0 / 1_000.0)
                let reachedRequiredPrecision = !self.pendingScrubExact || exact
                if reachedLatest && reachedRequiredPrecision {
                    self.pendingScrubTime = nil
                    self.pendingScrubExact = false
                    self.currentTime = target
                } else {
                    self.startPendingScrubSeek(on: player)
                }
            }
        }
    }

    func syncPlaybackToTrimRange(for project: Project) {
        guard let player else { return }
        let clampedTime = min(max(currentTime, project.effectiveTrimStart), project.effectiveTrimEnd)
        guard abs(clampedTime - currentTime) > (1.0 / 240.0) else { return }
        currentTime = clampedTime
        player.seek(
            to: CMTime(seconds: clampedTime, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        if project.settings.showCamera {
            syncCameraPlayer(for: project)
        }
    }

    func startPlayback(for project: Project) {
        guard let mainPlayer = player else { return }
        let rate = Float(activeSpeed(for: project, at: currentTime))

        if project.settings.showCamera, let camPlayer = cameraPlayer {
            if currentTime < effectiveCameraOffset {
                camPlayer.pause()
                syncCameraPlayer(for: project)
                mainPlayer.rate = rate
                return
            }

            if hasPassedCameraEnd(for: currentTime) {
                camPlayer.pause()
                syncCameraPlayer(for: project)
                mainPlayer.rate = rate
                return
            }

            let hostClock = CMClockGetHostTimeClock()
            let hostStart = CMTimeAdd(
                CMClockGetTime(hostClock),
                CMTime(seconds: 0.03, preferredTimescale: 600)
            )
            let mainTime = CMTime(seconds: max(0, currentTime), preferredTimescale: 600)
            let cameraSeconds = targetCameraTime(for: currentTime, project: project)
            let cameraTime = CMTime(seconds: cameraSeconds, preferredTimescale: 600)

            mainPlayer.setRate(rate, time: mainTime, atHostTime: hostStart)
            camPlayer.setRate(rate, time: cameraTime, atHostTime: hostStart)
            return
        }

        mainPlayer.rate = rate
    }

    /// Speed in effect at a source-time — scans the project's speed regions;
    /// defaults to 1.0 when no region is active.
    private func activeSpeed(for project: Project, at time: TimeInterval) -> Double {
        for region in project.speedRegions where time >= region.startTime && time <= region.endTime {
            return max(0.1, region.speed)
        }
        return 1.0
    }

    func syncCameraPlayer(for project: Project) {
        guard let player, let camPlayer = cameraPlayer else { return }
        let targetSeconds = targetCameraTime(
            for: player.currentTime().seconds,
            project: project
        )
        let targetTime = CMTime(seconds: targetSeconds, preferredTimescale: 600)
        observerCounters.cameraSyncs += 1
        camPlayer.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak camPlayer, weak self] finished in
            guard finished, let camPlayer, let self else { return }
            Task { @MainActor in
                if !self.isPlaying || self.currentTime < self.effectiveCameraOffset {
                    // Force AVPlayerLayer to render the seeked frame when paused.
                    // AVPlayerLayer on macOS doesn't always decode frames during seek.
                    camPlayer.play()
                    DispatchQueue.main.async {
                        camPlayer.pause()
                    }
                }
            }
        }
    }

    func syncCameraPlaybackIfNeeded(for project: Project) {
        guard let camPlayer = cameraPlayer, project.settings.showCamera else { return }

        let camTime = CMTimeGetSeconds(camPlayer.currentTime())
        let targetTime = targetCameraTime(for: currentTime, project: project)
        let drift = abs(camTime - targetTime)
        let isBeforeCameraStart = currentTime < effectiveCameraOffset
        let isPastCameraEnd = hasPassedCameraEnd(for: currentTime)

        if !isPlaying || isBeforeCameraStart || isPastCameraEnd {
            if camPlayer.rate != 0 {
                camPlayer.pause()
            }
            if drift > (1.0 / 240.0) {
                syncCameraPlayer(for: project)
            }
            return
        }

        let shouldResync = drift > (1.0 / 45.0)
        if camPlayer.rate == 0 {
            let hostStart = CMTimeAdd(
                CMClockGetTime(CMClockGetHostTimeClock()),
                CMTime(seconds: 0.02, preferredTimescale: 600)
            )
            camPlayer.setRate(
                Float(activeSpeed(for: project, at: currentTime)),
                time: CMTime(seconds: targetTime, preferredTimescale: 600),
                atHostTime: hostStart
            )
        } else if shouldResync {
            camPlayer.seek(
                to: CMTime(seconds: targetTime, preferredTimescale: 600),
                toleranceBefore: isPlaying ? CMTime(seconds: 1.0 / 120.0, preferredTimescale: 600) : .zero,
                toleranceAfter: isPlaying ? CMTime(seconds: 1.0 / 120.0, preferredTimescale: 600) : .zero
            )
        }
    }

    private func targetCameraTime(for timelineTime: TimeInterval, project: Project) -> TimeInterval {
        let unclampedTime = max(0, timelineTime - effectiveCameraOffset)
        guard cameraDuration > 0 else { return unclampedTime }
        return min(unclampedTime, max(0, cameraDuration - (1.0 / 240.0)))
    }

    func cameraTimeInRange(for project: Project) -> Bool {
        guard cameraDuration > 0 else { return true }
        let cameraStart = max(0, effectiveCameraOffset)
        return currentTime + (1.0 / 120.0) >= cameraStart
            && currentTime <= project.duration + (1.0 / 30.0)
    }

    private func hasPassedCameraEnd(for timelineTime: TimeInterval) -> Bool {
        guard cameraDuration > 0 else { return false }
        let cameraTimelineEnd = effectiveCameraOffset + cameraDuration
        return timelineTime >= cameraTimelineEnd - (1.0 / 120.0)
    }

    private func resolvedCameraOffset(for project: Project) -> TimeInterval {
        project.cameraTimeOffset
    }

    /// Returns the camera asset re-anchored so content starts at PTS 0, plus
    /// how much leading gap was trimmed (0 when no normalization happened).
    private func normalizedCameraAsset(for asset: AVAsset) async -> (AVAsset, TimeInterval) {
        let firstSample = await firstVideoSampleTime(for: asset)
        guard firstSample > (1.0 / 240.0),
              let duration = try? await asset.load(.duration),
              duration.seconds.isFinite,
              duration.seconds > firstSample,
              let videoTrack = try? await asset.loadTracks(withMediaType: .video).first else {
            return (asset, 0)
        }

        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return (asset, 0)
        }

        do {
            let trimmedDuration = CMTimeSubtract(duration, CMTime(seconds: firstSample, preferredTimescale: duration.timescale == 0 ? 600 : duration.timescale))
            let timeRange = CMTimeRange(start: CMTime(seconds: firstSample, preferredTimescale: 600), duration: trimmedDuration)
            try compositionTrack.insertTimeRange(timeRange, of: videoTrack, at: .zero)
            compositionTrack.preferredTransform = try await videoTrack.load(.preferredTransform)
            return (composition, firstSample)
        } catch {
            return (asset, 0)
        }
    }

    private func firstVideoSampleTime(for asset: AVAsset) async -> TimeInterval {
        guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else {
            return 0
        }

        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        guard reader.canAdd(output) else { return 0 }
        reader.add(output)
        guard reader.startReading(),
              let sample = output.copyNextSampleBuffer() else {
            return 0
        }

        let firstTime = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        return firstTime.isFinite ? max(0, firstTime) : 0
    }

    private func firstVideoFrameImage(for asset: AVAsset) async -> NSImage? {
        guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else {
            return nil
        }

        let output = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        )
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading(),
              let sample = output.copyNextSampleBuffer(),
              let imageBuffer = CMSampleBufferGetImageBuffer(sample) else {
            return nil
        }

        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        let rep = NSCIImageRep(ciImage: ciImage)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    func cleanupPlayer() {
        if let token = timeObserverToken, let player {
            player.removeTimeObserver(token)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        player?.pause()
        pendingPlaybackStartTime = nil
        pendingScrubTime = nil
        pendingScrubExact = false
        scrubSeekGeneration &+= 1
        scrubSeekInFlight = false
        isScrubbing = false
        player = nil
        timeObserverToken = nil
        endObserver = nil
        cameraSetupGeneration += 1 // invalidate in-flight camera setup
        cameraPlayer?.pause()
        cameraPlayer = nil
        cameraPosterImage = nil
        cameraHasDecodedFrame = false
        videoPosterImage = nil
    }

    /// The `onDisappear` body from `EditorView.editorContent`.
    func teardown(saving project: Project?) {
        voiceOverRefreshTask?.cancel(); voiceOverRefreshTask = nil
        voiceOverMeterTask?.cancel(); voiceOverMeterTask = nil
        // Dirty-gated: an unconditional save here could write a stale
        // in-memory copy over an external (MCP) disk edit.
        if let project { projectStore?.saveIfDirty(project) }
        if isRecordingVoiceOver {
            _ = voiceOverRecorder.stopRecording(discard: true)
            isRecordingVoiceOver = false; voiceOverRecordingStartTime = nil; liveVoiceOverSamples = []
        }
        cleanupPlayer(); cameraPlayer?.pause(); cameraPlayer = nil
    }

    func rebuildPlayback(
        for project: Project,
        preserveTime: TimeInterval,
        resumePlayback: Bool
    ) async {
        let clampedTime = min(max(preserveTime, project.effectiveTrimStart), project.effectiveTrimEnd)
        let shouldResume = resumePlayback && !isRecordingVoiceOver
#if DEBUG
        voiceOverEditorLogger.debug(
            "rebuild begin preserve=\(preserveTime, privacy: .public) clamped=\(clampedTime, privacy: .public) resumeRequested=\(resumePlayback, privacy: .public) shouldResume=\(shouldResume, privacy: .public) recording=\(self.isRecordingVoiceOver, privacy: .public)"
        )
#endif
        if isPlaying && !shouldResume {
            isPlaying = false
        }
        await setupPlayer(for: project, initialTime: clampedTime, resumePlayback: shouldResume)
        isPlaying = shouldResume
#if DEBUG
        voiceOverEditorLogger.debug(
            "rebuild complete current=\(self.currentTime, privacy: .public) isPlaying=\(self.isPlaying, privacy: .public)"
        )
#endif
    }

    // MARK: - Voice over

    func toggleVoiceOverRecording(for project: Project) async {
        if isRecordingVoiceOver {
            await stopVoiceOverRecording(for: project, discard: false, resumePlayback: isPlaying)
        } else {
            await startVoiceOverRecording(for: project)
        }
    }

    func startVoiceOverRecording(for project: Project) async {
        guard project.videoURL != nil else { return }

        do {
            try await ensureMicrophonePermission()
            try FileManager.default.createDirectory(at: project.projectDirectory, withIntermediateDirectories: true)
            cancelVoiceOverRefresh(reason: "recording-start")

            let outputURL = project.projectDirectory.appendingPathComponent("voiceover-\(UUID().uuidString).m4a")
            let recordingStart = min(max(currentTime, project.effectiveTrimStart), project.effectiveTrimEnd)

            try voiceOverRecorder.startRecording(to: outputURL)
            voiceOverRecordingStartTime = recordingStart
            liveVoiceOverSamples = []
            isRecordingVoiceOver = true
            startVoiceOverMetering()
#if DEBUG
            voiceOverEditorLogger.debug("begin start=\(recordingStart, privacy: .public) file=\(outputURL.lastPathComponent, privacy: .public)")
#endif

            if !isPlaying {
                isPlaying = true
            }
        } catch {
            voiceOverRecordingStartTime = nil
            liveVoiceOverSamples = []
            isRecordingVoiceOver = false
            voiceOverMeterTask?.cancel()
            voiceOverMeterTask = nil
            presentVoiceOverError(error.localizedDescription)
        }
    }

    func stopVoiceOverRecording(
        for project: Project,
        discard: Bool,
        resumePlayback: Bool
    ) async {
        guard isRecordingVoiceOver else { return }

        let clipStart = voiceOverRecordingStartTime ?? currentTime
        let result = voiceOverRecorder.stopRecording(discard: discard)
#if DEBUG
        voiceOverEditorLogger.debug("stop requested discard=\(discard, privacy: .public) clipStart=\(clipStart, privacy: .public) resultExists=\(result != nil, privacy: .public)")
#endif
        isRecordingVoiceOver = false
        voiceOverRecordingStartTime = nil
        voiceOverMeterTask?.cancel()
        voiceOverMeterTask = nil
        liveVoiceOverSamples = []

        if let result {
            let finalizedDuration = await waitForVoiceOverFileReady(
                at: result.fileURL,
                fallbackDuration: result.duration
            ) ?? result.duration
#if DEBUG
            voiceOverEditorLogger.debug("file ready file=\(result.fileURL.lastPathComponent, privacy: .public) fallback=\(result.duration, privacy: .public) finalized=\(finalizedDuration, privacy: .public)")
#endif
            let clipDuration = min(finalizedDuration, max(0.1, project.duration - clipStart))
            if clipDuration > 0.1 {
                let clip = VoiceOverClip(
                    fileName: result.fileURL.lastPathComponent,
                    startTime: clipStart,
                    duration: clipDuration,
                    sourceDuration: finalizedDuration
                )
                project.voiceOverClips.append(clip)
#if DEBUG
                voiceOverEditorLogger.debug("clip appended id=\(clip.id.uuidString, privacy: .public) start=\(clip.startTime, privacy: .public) duration=\(clip.duration, privacy: .public) sourceDuration=\(clip.sourceDuration, privacy: .public)")
#endif
            } else {
                try? FileManager.default.removeItem(at: result.fileURL)
#if DEBUG
                voiceOverEditorLogger.debug("clip dropped shortDuration=\(clipDuration, privacy: .public) file=\(result.fileURL.lastPathComponent, privacy: .public)")
#endif
            }
        }
        if !resumePlayback {
            isPlaying = false
        }
    }

    func scheduleVoiceOverRefresh(for project: Project) {
        guard !isRecordingVoiceOver else { return }

        cancelVoiceOverRefresh(reason: "reschedule")
#if DEBUG
        voiceOverEditorLogger.debug(
            "refresh scheduled current=\(self.currentTime, privacy: .public) clips=\(project.voiceOverClips.count, privacy: .public) isPlaying=\(self.isPlaying, privacy: .public)"
        )
#endif
        voiceOverRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self else { return }
            guard !Task.isCancelled else {
#if DEBUG
                voiceOverEditorLogger.debug("refresh aborted cancelled=true")
#endif
                self.voiceOverRefreshTask = nil
                return
            }
            guard !self.isRecordingVoiceOver else {
#if DEBUG
                voiceOverEditorLogger.debug("refresh skipped recording=true")
#endif
                self.voiceOverRefreshTask = nil
                return
            }
#if DEBUG
            voiceOverEditorLogger.debug(
                "refresh firing current=\(self.currentTime, privacy: .public) isPlaying=\(self.isPlaying, privacy: .public)"
            )
#endif
            await self.rebuildPlayback(for: project, preserveTime: self.currentTime, resumePlayback: self.isPlaying)
            self.voiceOverRefreshTask = nil
        }
    }

    private func cancelVoiceOverRefresh(reason: String) {
        guard voiceOverRefreshTask != nil else { return }
        voiceOverRefreshTask?.cancel()
        voiceOverRefreshTask = nil
#if DEBUG
        voiceOverEditorLogger.debug("refresh cancelled reason=\(reason, privacy: .public)")
#endif
    }

    private func startVoiceOverMetering() {
        voiceOverMeterTask?.cancel()
        voiceOverMeterTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.isRecordingVoiceOver {
                self.liveVoiceOverSamples.append(self.voiceOverRecorder.currentMeterLevel())
                self.observerCounters.voiceOverMeterSamples += 1
                if self.liveVoiceOverSamples.count > 240 {
                    self.liveVoiceOverSamples.removeFirst(self.liveVoiceOverSamples.count - 240)
                }
                try? await Task.sleep(for: .milliseconds(45))
            }
        }
    }

    private func waitForVoiceOverFileReady(
        at fileURL: URL,
        fallbackDuration: TimeInterval
    ) async -> TimeInterval? {
        for _ in 0..<10 {
            if let duration = measuredVoiceOverDuration(at: fileURL), duration > 0.1 {
                return duration
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        return fallbackDuration > 0.1 ? fallbackDuration : measuredVoiceOverDuration(at: fileURL)
    }

    private func measuredVoiceOverDuration(at fileURL: URL) -> TimeInterval? {
        guard let audioFile = try? AVAudioFile(forReading: fileURL) else {
            return nil
        }

        let sampleRate = audioFile.processingFormat.sampleRate
        guard sampleRate > 0 else {
            return nil
        }

        let duration = Double(audioFile.length) / sampleRate
        return duration.isFinite && duration > 0 ? duration : nil
    }

    private func ensureMicrophonePermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else {
                throw NSError(domain: "VoiceOverRecorder", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Microphone access is required to record a voice over."
                ])
            }
        default:
            throw NSError(domain: "VoiceOverRecorder", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Microphone access is required to record a voice over."
            ])
        }
    }

    private func presentVoiceOverError(_ message: String) {
        let alert = CCAlert(title: "Voice Over", message: message)
        alert.addButton("OK", role: .primary)
        alert.runModal()
    }

    // MARK: - Change signatures (shared by both shells)

    func voiceOverSignature(for project: Project) -> String {
        project.voiceOverClips.map { clip in
            "\(clip.id.uuidString):\(clip.fileName):\(clip.startTime):\(clip.sourceStartTime):\(clip.duration):\(clip.sourceDuration):\(clip.gain)"
        }.joined(separator: "|")
    }

    func videoClipSignature(for project: Project) -> String {
        project.videoClipSegments.map { clip in
            "\(clip.id.uuidString):\(clip.startTime):\(clip.endTime)"
        }.joined(separator: "|")
    }

    private func savedCameraPosterImage(for project: Project) -> NSImage? {
        guard let posterURL = project.cameraPosterURL else { return nil }
        return NSImage(contentsOf: posterURL)
    }

    private func persistCameraPosterImage(_ image: NSImage?, for project: Project) {
        guard let image else { return }
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return
        }
        let url = project.projectDirectory.appendingPathComponent("camera_poster.png")
        try? pngData.write(to: url, options: .atomic)
    }

    private func warmCameraPlayer(
        _ player: AVPlayer,
        videoOutput: AVPlayerItemVideoOutput
    ) async -> NSImage? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                continuation.resume()
            }
        }

        player.play()
        defer {
            player.pause()
        }

        let probeTimes: [CMTime] = [
            .zero,
            CMTime(seconds: 1.0 / 120.0, preferredTimescale: 600),
            CMTime(seconds: 1.0 / 60.0, preferredTimescale: 600),
            CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600),
        ]

        for _ in 0..<24 {
            for probeTime in probeTimes {
                if let image = image(from: videoOutput.copyPixelBuffer(forItemTime: probeTime, itemTimeForDisplay: nil)) {
                    return image
                }
            }

            let currentTime = player.currentTime()
            if let image = image(from: videoOutput.copyPixelBuffer(forItemTime: currentTime, itemTimeForDisplay: nil)) {
                return image
            }

            try? await Task.sleep(for: .milliseconds(20))
        }

        return nil
    }

    private func image(from pixelBuffer: CVPixelBuffer?) -> NSImage? {
        guard let pixelBuffer else { return nil }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let rep = NSCIImageRep(ciImage: ciImage)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
