import Foundation
import AVFoundation
import CoreImage
import Metal
import AppKit
import VideoToolbox

/// Serialises PTS-ordered appends to the writer and provides async backpressure
/// when the encoder isn't ready for more samples. Frame Tasks complete their
/// GPU renders in ARBITRARY order, and actor reentrancy means even isolated
/// methods interleave at every await — so ordering must be explicit: each frame
/// carries its sequence index, arrivals are stashed, and only the next expected
/// index is ever appended. A non-monotonic PTS append kills the HEVC writer
/// (AVFoundationErrorDomain -11800, OSStatus -16364).
private actor SerialAppender {
    private var nextIndex = 0
    private var pending: [Int: (buffer: CVPixelBuffer, time: CMTime)] = [:]

    func append(
        buffer: CVPixelBuffer,
        at time: CMTime,
        index: Int,
        input: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        writer: AVAssetWriter
    ) async {
        pending[index] = (buffer, time)
        // Drain everything that is now in-order. Reentrancy note: after any
        // await another call may have drained `nextIndex` already, so re-fetch
        // after the readiness wait and only append when still present — the
        // fetch → append → increment section contains no suspension points.
        while pending[nextIndex] != nil {
            // Pull-style readiness flag. If the writer dies (disk full,
            // encoder error) it never flips, so bail on status — the export
            // loop surfaces `writer.error`.
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else { return }
                // 2 ms: long enough not to spin the cooperative pool while the
                // encoder is saturated (0.2 ms burned a core doing nothing),
                // short enough to never starve a ~16 ms/frame pipeline.
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
            guard writer.status == .writing else { return }
            guard let frame = pending[nextIndex] else { continue }
            adaptor.append(frame.buffer, withPresentationTime: frame.time)
            pending[nextIndex] = nil
            nextIndex += 1
        }
    }
}

@Observable
final class VideoExporter {
    var progress: Double = 0
    var isExporting = false
    private(set) var error: String?

    // NOTE: exports render through the per-export `exportCIContext`
    // (command-queue-backed, built in export(project:to:)). A second eager
    // Metal CIContext used to be allocated here per exporter and never read.

    // Per-export raster caches. The subtitle overlay changes only when the
    // segment / karaoke word set changes; a highlight's outside-dim mask is
    // constant while its hole rect is settled. Both were full-canvas CGContext
    // rasters per frame before caching.
    private var cachedSubtitleKey: String?
    private var cachedSubtitleOverlay: CIImage?
    private var cachedHighlightMasks: [String: CIImage] = [:]

    private struct CursorAsset {
        let cgImage: CGImage?
        let baseSize: CGSize
        let hotSpot: CGPoint
    }

    func export(
        project: Project,
        to outputURL: URL,
        skipEntitlementCheck: Bool = false
    ) async throws {
        // skipEntitlementCheck is for ExportBenchHarness ONLY: it exports a
        // synthetic fixture, so there is no user content to paywall and the
        // bench must run offline/CI. Every user-facing path keeps the check.
        if !skipEntitlementCheck {
            try await AuthService.assertCurrentUserCanExport()
        }

        // Raster caches are only valid within one export's settings/geometry.
        cachedSubtitleKey = nil
        cachedSubtitleOverlay = nil
        cachedHighlightMasks.removeAll()

        guard let videoURL = project.videoURL else {
            throw ExportError.noVideo
        }

        isExporting = true
        progress = 0
        error = nil

        defer { isExporting = false }

        // Remove existing file — AVAssetWriter requires output URL to not exist
        try? FileManager.default.removeItem(at: outputURL)

        let settings = project.settings
        let exportSettings = settings.exportSettings
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        let fullDuration = duration.seconds
        let trimStart = project.effectiveTrimStart
        let trimEnd = project.effectiveTrimEnd > 0 ? project.effectiveTrimEnd : fullDuration
        // Maps output-time (after speed applied) ↔ source-time (original recording)
        let timeMap = SpeedTimeMap(
            sourceStart: trimStart,
            sourceEnd: trimEnd,
            regions: project.speedRegions
        )
        // Cap export at the last visible clip's OUTPUT-time end. Resizing or
        // moving a clip shorter than the trim range would otherwise pad the
        // output with trailing BG-only frames. We use output time (not source
        // time) because a moved clip's source range may not be the rightmost
        // clip on the timeline.
        let lastVisibleOutput = project.effectiveVideoClipSegments
            .map { timeMap.outputTime(forSource: $0.endTime) }
            .max() ?? timeMap.outputDuration
        let totalSeconds = max(0.0001, min(timeMap.outputDuration, lastVisibleOutput))

        // Load cursor data
        var cursorEvents: [CursorEvent] = []
        var cursorCoordinateSize: CGSize = .zero
        if let cursorURL = project.cursorDataURL {
            let recording = try? CursorTracker.loadRecording(from: cursorURL)
            cursorEvents = recording?.events ?? []
            cursorCoordinateSize = recording?.hasValidCoordinateSpace == true ? recording?.coordinateSize ?? .zero : .zero
            if settings.smoothCursor {
                let smoother = CursorSmoother(factor: settings.smoothingFactor)
                cursorEvents = smoother.smooth(events: cursorEvents)
            }
            // Fluid movement after smoothing — identical chain to
            // EditorPlaybackController.applyCursorSmoothing.
            cursorEvents = CursorSpringMath.apply(events: cursorEvents, settings: settings)
            cursorEvents = CursorEndBehaviorMath.apply(
                events: cursorEvents,
                trimEnd: project.effectiveTrimEnd,
                loopToStart: settings.cursorLoopToStart,
                stopAtEnd: settings.cursorStopAtEnd)
        }

        // Audio mix — includes the synthesized click ticks (same waveform the
        // preview plays) when enabled.
        // Discrete clicks only — the tracker flags every sample while the
        // button is down; the sound must fire once per click like the ripple.
        let clickTimes = settings.clickSoundEnabled
            ? ClickRippleOverlay.discreteClickTimes(from: cursorEvents, coordinateSize: cursorCoordinateSize)
            : []
        let scrollTimes: [TimeInterval] = project.keystrokeDataURL
            .flatMap { try? KeystrokeTracker.loadRecording(from: $0).events }?
            .filter { $0.category == .scroll }.map(\.timestamp).sorted() ?? []
        let keystrokes: [KeystrokeEvent] = settings.keySoundEnabled
            ? (project.keystrokeDataURL.flatMap { try? KeystrokeTracker.loadRecording(from: $0).events } ?? [])
            : []
        // Shortcut-overlay display list (precomputed once; per-frame lookups
        // are pure functions of the timeline clock).
        let keystrokeDisplayEvents: [KeystrokeOverlayMath.DisplayEvent] = settings.showKeystrokes
            ? KeystrokeOverlayMath.displayEvents(
                from: project.keystrokeDataURL
                    .flatMap { try? KeystrokeTracker.loadRecording(from: $0).events } ?? [],
                scopedTo: project)
            : []
        let preparedAudio = try await ProjectAudioMix.prepare(
            for: asset, project: project, clickTimes: clickTimes, keystrokes: keystrokes
        )

        // Set up source video track
        let videoTrack = try await asset.loadTracks(withMediaType: .video).first
        guard let videoTrack else { throw ExportError.noVideoTrack }

        let readerOutputSettings: [String: Any] = [
            // Benchmarked Aug 2026: decoding to native 420v instead of BGRA
            // measured no throughput change on --export-bench and shifts the
            // YUV→RGB matrix from VideoToolbox into the CI graph, which risks
            // one-LSB color drift against the frozen goldens. BGRA stays.
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]

        // Match the source's color space instead of silently converting to
        // sRGB. New recordings are Display P3 (see ScreenRecorder /
        // VideoColorTags); older files are sRGB/709-primaries. The export
        // pipeline (CIContext working space, render destinations, writer tags)
        // follows the source so the exported file renders 1:1 with the
        // recording — forcing sRGB on a P3 source gamut-clipped saturated
        // colors and made exports look dull.
        let sourceIsP3 = VideoColorTags.isP3(
            formatDescription: (try? await videoTrack.load(.formatDescriptions))?.first
        )

        // Audio tracks
        var audioReaderOutput: AVAssetReaderOutput?
        var audioReader: AVAssetReader?
        // The fast audio path reads the untrimmed source from `trimStart`, but
        // reader buffers KEEP their source PTS — appended raw, the audio track
        // lands `trimStart` late and runs past the video (a black tail exactly
        // the length of the trimmed head). Every buffer is shifted by this.
        var audioPTSOffset = CMTime.zero
        if !preparedAudio.tracks.isEmpty {
            let aReader = try AVAssetReader(asset: preparedAudio.asset)
            // The composed path is OUTPUT-time based starting at 0. The fast path
            // hands back the untrimmed source asset (source-time timeline), so a
            // trimmed project must start reading at trimStart or audio desyncs.
            let startCMTime: CMTime = preparedAudio.asset === asset
                ? CMTime(seconds: trimStart, preferredTimescale: 600)
                : .zero
            let durationCMTime = CMTime(seconds: totalSeconds, preferredTimescale: 600)
            aReader.timeRange = CMTimeRange(start: startCMTime, duration: durationCMTime)
            audioPTSOffset = startCMTime
            let aOutput = AVAssetReaderAudioMixOutput(
                audioTracks: preparedAudio.tracks,
                audioSettings: ProjectAudioMix.readerOutputSettings
            )
            aOutput.audioMix = preparedAudio.audioMix
            aReader.add(aOutput)
            audioReader = aReader
            audioReaderOutput = aOutput
        }

        // Set up writer — match file type to export format. The output size
        // derives its `.auto` aspect from the SOURCE natural size, exactly
        // like the editor's letterboxed preview canvas (preview == export).
        let naturalSize = try await videoTrack.load(.naturalSize)
        let resolvedOutputSize = exportSettings.resolvedOutputSize(
            for: settings.aspectRatio, sourceSize: naturalSize)
        let outputWidth = Int(resolvedOutputSize.width)
        let outputHeight = Int(resolvedOutputSize.height)

        let fileType: AVFileType = exportSettings.format == .mov ? .mov : .mp4
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)
        // Faster finish: skip the moov-atom rewrite. We're writing to disk,
        // not streaming, so progressive layout isn't needed and saves several
        // seconds on a long file.
        writer.shouldOptimizeForNetworkUse = false

        // Tag output to match the SOURCE: P3-D65 primaries for P3 recordings,
        // 709 primaries for older sRGB files, sRGB transfer in both. Without
        // explicit tags the encoder defaults to Rec.709, and the player applies
        // the Rec.709 display transform on sRGB-gamma pixels → double
        // correction → grey; mis-tagging a P3 source as sRGB desaturates it.
        //
        // Note on hardware acceleration: AVAssetWriter does NOT accept the
        // `EnableHardwareAcceleratedVideoEncoder` *encoder specification* in
        // `AVVideoCompressionPropertiesKey` — it throws at init time. AVAssetWriter
        // auto-selects the hardware HEVC encoder on Apple Silicon (Media Engine)
        // and on Intel Macs with Quick Sync / T2 by default. The hint is only
        // needed when driving `VTCompressionSession` directly.
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: outputWidth,
            AVVideoHeightKey: outputHeight,
            // Shared with ScreenRecorder — the exported file must carry the
            // same tags as the source recording (see VideoColorTags).
            AVVideoColorPropertiesKey: VideoColorTags.colorProperties(p3: sourceIsP3),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: exportSettings.estimatedVideoBitRate(
                    for: settings.aspectRatio, sourceSize: naturalSize),
                AVVideoExpectedSourceFrameRateKey: exportSettings.fps,
                AVVideoAllowFrameReorderingKey: false,
            ] as [String: Any]
        ]

        let videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        // BGRA handoff to the encoder is the measured fast path on Apple
        // Silicon: VideoToolbox's RGB→YCbCr conversion runs in the Media
        // Engine's dedicated CSC hardware, so it costs nothing, while
        // rendering NV12 in CoreImage moves that conversion ONTO the GPU
        // (benchmarked Aug 2026: 100 fps BGRA vs 92 fps NV12 at 4K CFR).
        // `CAPTURECAT_EXPORT_NV12=1` opts into the NV12 path for machines
        // where the conversion may be CPU-side (older Intel) — same pixels
        // either way, the attachments below steer CI to the writer's exact
        // 709 matrix.
        let useBGRAOutput = ProcessInfo.processInfo.environment["CAPTURECAT_EXPORT_NV12"] == nil
        let outputPixelFormat: OSType = useBGRAOutput
            ? kCVPixelFormatType_32BGRA
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoWriterInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: outputPixelFormat,
                kCVPixelBufferWidthKey as String: outputWidth,
                kCVPixelBufferHeightKey as String: outputHeight,
                // Required for CVMetalTextureCache zero-copy wrapping of output buffers
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
        )
        writer.add(videoWriterInput)

        var audioWriterInput: AVAssetWriterInput?
        if !preparedAudio.tracks.isEmpty {
            let aInput = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: ProjectAudioMix.writerOutputSettings
            )
            aInput.expectsMediaDataInRealTime = false
            writer.add(aInput)
            audioWriterInput = aInput
        }

        audioReader?.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // Process audio in background — store handle so we can await it
        let audioTask: Task<Void, Error>? = if let audioReaderOutput, let audioWriterInput {
            Task.detached { [audioPTSOffset] in
                defer { audioWriterInput.markAsFinished() }
                while let buffer = audioReaderOutput.copyNextSampleBuffer() {
                    while !audioWriterInput.isReadyForMoreMediaData {
                        guard writer.status == .writing else {
                            throw ExportError.writeFailed(writer.error?.localizedDescription ?? "Writer stopped during audio")
                        }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    let toAppend = Self.shiftedAudioBuffer(buffer, by: audioPTSOffset) ?? buffer
                    guard audioWriterInput.append(toAppend) else {
                        throw ExportError.writeFailed(writer.error?.localizedDescription ?? "Audio append failed")
                    }
                }
            }
        } else {
            nil
        }

        // Pre-compute static resources
        let outputSize = CGSize(width: outputWidth, height: outputHeight)

        // Compute scale factor so spatial settings (padding, corner radius, shadow)
        // match the preview's proportions at the export resolution.
        // Headless exports (CLI/MCP) never had an editor window, so
        // previewCanvasSize is zero — the output canvas itself is then the
        // reference (scale 1). With a live editor the letterboxed canvas has
        // the SAME aspect as the output, so this min() is a uniform factor.
        let referenceCanvas: CGSize = {
            let previewSize = project.previewCanvasSize
            guard previewSize.width > 0, previewSize.height > 0 else { return outputSize }
            return previewSize
        }()
        let canvasScale = min(outputSize.width / referenceCanvas.width,
                              outputSize.height / referenceCanvas.height)

        // Needed both for cursor normalization and for choosing a cursor
        // raster large enough for the final export pixels.
        // (naturalSize is loaded above, before the writer setup.)
        let fullCursorCoordinateSize = CursorOverlayLayout.resolveCoordinateSize(
            recordedSize: cursorCoordinateSize,
            fallbackSourceSize: naturalSize
        )
        let sourceToOutputScale = min(
            outputSize.width / max(1, fullCursorCoordinateSize.width),
            outputSize.height / max(1, fullCursorCoordinateSize.height)
        )
        let maximumZoom = max(1, project.zoomRegions.map(\.zoomLevel).max() ?? 1)
        // Cursor is composited before the card zoom. Include the largest zoom
        // and perspective slack so CoreImage only ever downsamples the vector
        // raster in the completed frame.
        let cursorRasterScale = max(
            1,
            sourceToOutputScale * CGFloat(settings.cursorScale * maximumZoom) * 1.25
        )

        let transitionDuration = settings.animationSpeed.duration
        let cachedBackground = createBackground(size: outputSize, settings: settings)
        let cursorSmoother = CursorSmoother(factor: settings.smoothingFactor)
        let cursorAsset = makeCursorAsset(
            style: settings.cursorStyle,
            rasterScale: cursorRasterScale
        )

        // Render on a constant OUTPUT-time frame cadence. For each output frame we
        // compute the corresponding SOURCE time via the SpeedTimeMap so frames can
        // be read from the source video and effects (zoom, blur, highlight, etc.)
        // — all stored in source-time — are evaluated correctly.
        let outputFrameTimes = exportFrameTimes(duration: totalSeconds, fps: exportSettings.fps, startOffset: 0)
        let timelineSourceTimes = outputFrameTimes.map { timeMap.sourceTime(forOutput: $0.seconds) }
        let sourceFrameTimes: [CMTime?] = timelineSourceTimes.map { sourceTime in
            guard project.hasVisibleVideo(at: sourceTime) else { return nil }
            return CMTime(seconds: sourceTime, preferredTimescale: 600)
        }

        // Hidden-menu-bar crop (pure display recordings): the top strip of the
        // source is removed, so layout uses the shrunken size and all cursor
        // coordinates shift up by the strip (mirrors PreviewView).
        let menuBarCrop: CGFloat = {
            guard settings.menuBarReplacement == .hidden,
                  project.recordingSourceKind != .device,
                  !project.sourceSegments.contains(where: { $0.kind == .device }) else { return 0 }
            return min(0.12, max(0, settings.menuBarHeight / 100))
        }()
        let effectiveNaturalSize = CGSize(
            width: naturalSize.width,
            height: naturalSize.height * (1 - menuBarCrop)
        )

        let resolvedCursorCoordinateSize = CGSize(
            width: fullCursorCoordinateSize.width,
            height: fullCursorCoordinateSize.height * (1 - menuBarCrop)
        )
        if menuBarCrop > 0 {
            let shift = fullCursorCoordinateSize.height * menuBarCrop
            cursorEvents = cursorEvents.map {
                CursorEvent(timestamp: $0.timestamp, x: $0.x, y: $0.y - shift, isClick: $0.isClick)
            }
        }
        let displayWidth = resolvedCursorCoordinateSize.width
        let displayHeight = resolvedCursorCoordinateSize.height

        // Pre-compute the camera path using the same spring physics as PreviewView
        // so the exported video matches the editor preview exactly.
        let animDur = max(0.2, settings.animationSpeed.duration)
        var springZoom     = 1.0;  var springZoomVel  = 0.0
        var springOffsetX  = 0.0;  var springOffsetVelX = 0.0
        var springOffsetY  = 0.0;  var springOffsetVelY = 0.0
        var springFocalX   = 0.5;  var springFocalY   = 0.5
        var springRegionMemory = ZoomFocalMath.RegionMemory()
        var springFocalVelX = 0.0; var springFocalVelY = 0.0
        var lastSpringTime: TimeInterval? = nil

        // Screen skew — mirrors PreviewView: a sprung normalized 0…1 amount
        // for zoomed-out modes (scaling all three angles together), plus a
        // deterministic intro envelope keyed to OUTPUT time (t=0 = trim start).
        let tiltMode = settings.screenTiltMode
        let tiltPitch = settings.screenTiltAngle
        let tiltYaw = settings.screenTiltYaw
        let tiltRoll = settings.screenTiltRoll
        let tiltActive = (tiltMode != .off
            && max(abs(tiltPitch), abs(tiltYaw), abs(tiltRoll)) > 0.01)
            || !project.tiltRegions.isEmpty
        var springTilt = 0.0; var springTiltVel = 0.0
        // Timeline tilt-region springs (degrees per axis, matching PreviewView)
        var springRegionPitch = 0.0; var springRegionPitchVel = 0.0
        var springTiltStyleMemory: (omega: Double, damping: Double) = (1, 0.88)
        var springRegionYaw = 0.0; var springRegionYawVel = 0.0
        var springRegionRoll = 0.0; var springRegionRollVel = 0.0
        func tiltSpringTarget(forZoomTarget targetZoom: Double) -> Double {
            guard tiltMode == .zoomedOut || tiltMode == .both else { return 0 }
            return targetZoom > 1.0 ? 0 : 1
        }
        func tiltRegionTarget(at t: TimeInterval) -> (pitch: Double, yaw: Double, roll: Double) {
            for region in project.tiltRegions {
                if t >= region.startTime && t <= region.endTime {
                    // Same eased in-block ramp-out as the zoom (see
                    // PreviewMotionModel / TiltMath.rampOutScale).
                    let scale = TiltMath.rampOutScale(
                        time: t, blockStart: region.startTime,
                        blockEnd: region.endTime, animationDuration: animDur)
                    return (region.pitch * scale, region.yaw * scale, region.roll * scale)
                }
            }
            return (0, 0, 0)
        }
        func combinedTiltKey(zoom: Double, focalX: Double, focalY: Double, atOutputTime outputTime: Double) -> CameraKey {
            var amount = (tiltMode == .zoomedOut || tiltMode == .both) ? springTilt : 0
            if tiltMode == .intro || tiltMode == .both {
                amount = max(amount, TiltMath.introAmount(at: outputTime, animationDuration: animDur))
            }
            amount = max(0, min(1, amount))
            return CameraKey(
                zoom: zoom, focalX: focalX, focalY: focalY,
                offsetX: springOffsetX, offsetY: springOffsetY,
                tiltPitch: amount * tiltPitch + springRegionPitch,
                tiltYaw: amount * tiltYaw + springRegionYaw,
                tiltRoll: amount * tiltRoll + springRegionRoll
            )
        }

        let cameraPath = timelineSourceTimes.enumerated().map { frameIdx, t -> CameraKey in

            // Discrete zoom target — SHARED with PreviewMotionModel.targets
            // via ZoomFocalMath.regionTargets, including the held outgoing
            // focal that makes the zoom-out glide straight back to centre.
            let regionTargets = ZoomFocalMath.regionTargets(
                zoomRegions: project.zoomRegions,
                at: t,
                currentZoom: springZoom,
                animationDuration: animDur,
                memory: &springRegionMemory
            )
            let targetZoom = regionTargets.zoom

            // Cursor-blended focal target (spring provides all smoothing) —
            // held steady during scroll bursts, same rule as the preview.
            let scrolling = scrollTimes.isEmpty ? false : {
                var lo = 0, hi = scrollTimes.count - 1
                while lo < hi {
                    let mid = (lo + hi) / 2
                    if scrollTimes[mid] < t { lo = mid + 1 } else { hi = mid }
                }
                var best = abs(scrollTimes[lo] - t)
                if lo > 0 { best = min(best, abs(scrollTimes[lo - 1] - t)) }
                return best < 0.35
            }()
            let cursorPos: CGPoint? = (scrolling || cursorEvents.isEmpty) ? nil
                : cursorSmoother.interpolateIfFresh(events: cursorEvents, at: t)
            let focalTarget = ZoomFocalMath.blendedFocalPoint(
                regionFocal: regionTargets.focal,
                cursorPosition: cursorPos,
                displayWidth: displayWidth,
                displayHeight: displayHeight,
                zoom: springZoom,
                envelope: regionTargets.envelope,
                followCursor: regionTargets.cursorFollow
            )

            guard let lastTime = lastSpringTime else {
                springZoom   = targetZoom
                springOffsetX = regionTargets.offset.x
                springOffsetY = regionTargets.offset.y
                springFocalX = focalTarget.x
                springFocalY = focalTarget.y
                springTilt   = tiltSpringTarget(forZoomTarget: targetZoom)
                let regionTarget = tiltRegionTarget(at: t)
                springRegionPitch = regionTarget.pitch
                springRegionYaw = regionTarget.yaw
                springRegionRoll = regionTarget.roll
                lastSpringTime = t
                return combinedTiltKey(zoom: springZoom, focalX: springFocalX, focalY: springFocalY,
                                       atOutputTime: outputFrameTimes[frameIdx].seconds)
            }

            let dt = t - lastTime
            lastSpringTime = t

            if dt > 0 && dt <= 0.35 {
                // Zoom spring — per-block animation style sets response
                // and damping, identical to PreviewMotionModel.
                let zOmega = 2.5 / animDur * regionTargets.omegaMultiplier
                let zZeta  = regionTargets.damping
                let zAcc   = zOmega * zOmega * (targetZoom - springZoom)
                           - 2 * zZeta * zOmega * springZoomVel
                springZoomVel += zAcc * dt
                // Floor matches PreviewMotionModel's (scale-down effects go
                // to 0.3) — the old 0.85 clamped shrinks in EXPORT only.
                springZoom     = max(0.25, springZoom + springZoomVel * dt)
                // Smooth landing — see ZoomFocalMath.settleTowardRest.
                if targetZoom == 1,
                   abs(springZoom - 1) < ZoomFocalMath.restLandingBand {
                    ZoomFocalMath.settleTowardRest(
                        zoom: &springZoom, velocity: &springZoomVel, dt: dt)
                }

                // Card offset — same spring as the zoom, so the slide and the
                // push move as one gesture (identical to PreviewMotionModel).
                let oxAcc = zOmega * zOmega * (regionTargets.offset.x - springOffsetX)
                          - 2 * zZeta * zOmega * springOffsetVelX
                let oyAcc = zOmega * zOmega * (regionTargets.offset.y - springOffsetY)
                          - 2 * zZeta * zOmega * springOffsetVelY
                springOffsetVelX += oxAcc * dt
                springOffsetVelY += oyAcc * dt
                springOffsetX += springOffsetVelX * dt
                springOffsetY += springOffsetVelY * dt

                // Focal spring — overdamped, slow weighted-camera pan
                // Shared follow-speed formula with PreviewMotionModel.
                let fOmega = 5.5 * (0.4 + 1.2 * max(0, min(1, settings.cameraFollowSpeed)))
                let fZeta = 0.90
                let fxAcc  = fOmega * fOmega * (focalTarget.x - springFocalX)
                           - 2 * fZeta * fOmega * springFocalVelX
                let fyAcc  = fOmega * fOmega * (focalTarget.y - springFocalY)
                           - 2 * fZeta * fOmega * springFocalVelY
                springFocalVelX += fxAcc * dt
                springFocalVelY += fyAcc * dt
                springFocalX = max(0, min(1, springFocalX + springFocalVelX * dt))
                springFocalY = max(0, min(1, springFocalY + springFocalVelY * dt))

                // Tilt springs — same response as zoom, matching PreviewView
                let tiltTarget = tiltSpringTarget(forZoomTarget: targetZoom)
                let tAcc = zOmega * zOmega * (tiltTarget - springTilt)
                         - 2 * zZeta * zOmega * springTiltVel
                springTiltVel += tAcc * dt
                springTilt    += springTiltVel * dt

                let regionTarget = tiltRegionTarget(at: t)
                // Per-tilt-block animation style — identical resolution to
                // PreviewMotionModel via the ONE boundary-smooth resolver
                // (omega blends across the ramp-out to the exact post-block
                // floor; nothing steps the frame the block ends).
                let tiltParams = TiltMath.tiltReturnParams(
                    tiltRegions: project.tiltRegions, at: t,
                    animationDuration: animDur, memory: &springTiltStyleMemory)
                let tiltReturning = tiltParams.returning
                let rOmegaMult = tiltParams.omega
                let rZeta = tiltParams.damping
                let rOmega = 2.5 / animDur * rOmegaMult
                func springStep(_ value: inout Double, _ vel: inout Double, toward target: Double) {
                    let acc = rOmega * rOmega * (target - value) - 2 * rZeta * rOmega * vel
                    vel += acc * dt
                    value += vel * dt
                }
                springStep(&springRegionPitch, &springRegionPitchVel, toward: regionTarget.pitch)
                springStep(&springRegionYaw, &springRegionYawVel, toward: regionTarget.yaw)
                springStep(&springRegionRoll, &springRegionRollVel, toward: regionTarget.roll)
                if tiltReturning {
                    ZoomFocalMath.settleTowardZero(&springRegionPitch, &springRegionPitchVel, dt: dt, band: 1.5)
                    ZoomFocalMath.settleTowardZero(&springRegionYaw, &springRegionYawVel, dt: dt, band: 1.5)
                    ZoomFocalMath.settleTowardZero(&springRegionRoll, &springRegionRollVel, dt: dt, band: 1.5)
                }
            } else {
                // Large jump (trimmed segment boundary): snap
                springZoom = targetZoom; springZoomVel = 0
                springFocalX = focalTarget.x; springFocalVelX = 0
                springFocalY = focalTarget.y; springFocalVelY = 0
                springTilt = tiltSpringTarget(forZoomTarget: targetZoom); springTiltVel = 0
                let regionTarget = tiltRegionTarget(at: t)
                springRegionPitch = regionTarget.pitch; springRegionPitchVel = 0
                springRegionYaw = regionTarget.yaw; springRegionYawVel = 0
                springRegionRoll = regionTarget.roll; springRegionRollVel = 0
            }

            return combinedTiltKey(zoom: springZoom, focalX: springFocalX, focalY: springFocalY,
                                   atOutputTime: outputFrameTimes[frameIdx].seconds)
        }

        // Diagnostic: dump the full camera path (CAPTURECAT_DUMP_CAMERA=1) so
        // motion discontinuities can be measured in the numbers, not eyeballed.
        if ProcessInfo.processInfo.environment["CAPTURECAT_DUMP_CAMERA"] != nil {
            for (i, k) in cameraPath.enumerated() {
                print(String(
                    format: "CAM t=%.4f z=%.5f fx=%.4f fy=%.4f ox=%.4f oy=%.4f p=%.3f yw=%.3f r=%.3f",
                    outputFrameTimes[i].seconds, k.zoom, k.focalX, k.focalY,
                    k.offsetX, k.offsetY, k.tiltPitch, k.tiltYaw, k.tiltRoll))
            }
        }

        let reader2 = try AVAssetReader(asset: asset)
        let readerOutput2 = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: readerOutputSettings)
        // We consume each sample once and the next call replaces the buffer
        // reference, so no need for the reader to memcpy the pixel data first.
        readerOutput2.alwaysCopiesSampleData = false
        reader2.add(readerOutput2)
        reader2.startReading()

        guard let initialSampleBuffer = readerOutput2.copyNextSampleBuffer(),
              let initialPixelBuffer = CMSampleBufferGetImageBuffer(initialSampleBuffer) else {
            throw ExportError.writeFailed("Unable to read source video frames")
        }

        // ── Camera (webcam) asset reader ──────────────────────────────────────
        // The recorded camera footage is stored in a separate file. We read it
        // sequentially in lockstep with the main video timeline, advancing each
        // frame to the camera-time corresponding to the current source-time
        // (camera_time = source_time − cameraTimeOffset).
        var cameraReader: AVAssetReader?
        var cameraReaderOutput: AVAssetReaderTrackOutput?
        var cameraNaturalSize: CGSize = .zero
        var cameraDuration: TimeInterval = 0
        print("[Export Camera] showCamera=\(settings.showCamera) cameraVideoURL=\(project.cameraVideoURL?.path ?? "nil") cameraTimeOffset=\(project.cameraTimeOffset)")
        if settings.showCamera, let cameraURL = project.cameraVideoURL {
            let fileExists = FileManager.default.fileExists(atPath: cameraURL.path)
            print("[Export Camera] camera file exists at path: \(fileExists)")
            let cameraAsset = AVURLAsset(url: cameraURL)
            do {
                let camTrack = try await cameraAsset.loadTracks(withMediaType: .video).first
                guard let camTrack else {
                    print("[Export Camera] FAILED: no video track in camera asset")
                    throw ExportError.writeFailed("camera: no video track")
                }
                let camReader = try AVAssetReader(asset: cameraAsset)
                let camOutput = AVAssetReaderTrackOutput(track: camTrack, outputSettings: readerOutputSettings)
                camOutput.alwaysCopiesSampleData = false
                guard camReader.canAdd(camOutput) else {
                    print("[Export Camera] FAILED: reader cannot add output")
                    throw ExportError.writeFailed("camera: reader cannot add output")
                }
                camReader.add(camOutput)
                guard camReader.startReading() else {
                    print("[Export Camera] FAILED: reader.startReading returned false, status=\(camReader.status.rawValue) error=\(String(describing: camReader.error))")
                    throw ExportError.writeFailed("camera: reader failed to start")
                }
                cameraNaturalSize = (try? await camTrack.load(.naturalSize)) ?? .zero
                cameraDuration = (try? await cameraAsset.load(.duration))?.seconds ?? 0
                cameraReader = camReader
                cameraReaderOutput = camOutput
                print("[Export Camera] reader OK — naturalSize=\(cameraNaturalSize) duration=\(cameraDuration)s")
            } catch {
                print("[Export Camera] reader setup threw: \(error)")
            }
        } else {
            if !settings.showCamera { print("[Export Camera] disabled: showCamera=false") }
            if project.cameraVideoURL == nil { print("[Export Camera] disabled: cameraVideoURL is nil") }
        }

        // Working space MATCHES the source file (Display P3 for new
        // recordings, sRGB for older ones) — same non-linear transfer curve in
        // both, which avoids the lossy linearisation round-trip that the
        // default extended-linear working space causes, and keeps P3 sources
        // from being gamut-clipped through an sRGB intermediate. Synthetic
        // assets (cursor, curtain, posters, ripples) are still DRAWN in sRGB
        // CGContexts and tagged sRGB — CI converts them into the working space,
        // which is exactly what the OS does for the preview's CALayers on a P3
        // display, so preview==export holds for them too.
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let renderSpace = VideoColorTags.renderColorSpace(p3: sourceIsP3)
        // Build a shared Metal command queue and hand it to CIContext.
        // CIContext(mtlCommandQueue:) encodes CI work into OUR queue — all GPU work
        // is on the same Metal timeline with no inter-queue sync bubbles.
        // (WWDC20 "Optimize the Core Image Pipeline for Your Video App")
        let exportMetalDevice = MTLCreateSystemDefaultDevice()
        let exportCommandQueue = exportMetalDevice?.makeCommandQueue()
        var exportTextureCache: CVMetalTextureCache?
        if let device = exportMetalDevice {
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &exportTextureCache)
        }
        let exportCIContext: CIContext = {
            // Prefer shared-queue init so CI and our command buffers share the GPU timeline
            if let queue = exportCommandQueue {
                return CIContext(mtlCommandQueue: queue, options: [
                    .workingColorSpace: renderSpace,
                    .cacheIntermediates: false,  // each frame is unique; no caching benefit
                ])
            }
            if let device = exportMetalDevice {
                return CIContext(mtlDevice: device, options: [.workingColorSpace: renderSpace])
            }
            return CIContext(options: [.workingColorSpace: renderSpace, .useSoftwareRenderer: false])
        }()

        // Log color pipeline info once so we can verify the chain is correct.
        if let srcCS = CVImageBufferGetColorSpace(initialPixelBuffer) {
            print("[Export Color] Source pixel buffer color space: \(srcCS)")
        } else {
            print("[Export Color] Source pixel buffer color space: nil (no attachment)")
        }
        if let attachments = CVBufferCopyAttachments(initialPixelBuffer, .shouldPropagate) as? [String: Any] {
            let colorKeys = attachments.filter { $0.key.contains("ColorPrimaries") || $0.key.contains("TransferFunction") || $0.key.contains("YCbCrMatrix") }
            print("[Export Color] Source buffer color attachments: \(colorKeys)")
        }
        print("[Export Color] Source primaries P3: \(sourceIsP3)")
        print("[Export Color] CIContext working/render color space: \(renderSpace)")
        print("[Export Color] Output tags: primaries \(sourceIsP3 ? "P3_D65" : "ITU_R_709_2"), transfer IEC sRGB")

        // ─────────────────────────────────────────────────────────────────────
        // Static pre-computation — these values are identical for every frame.
        // Doing them once eliminates the two most expensive per-frame operations:
        //   • CGContext allocation + fill for the mask images
        //   • Gaussian blur evaluation for the drop shadow
        // ─────────────────────────────────────────────────────────────────────
        // Device recordings render inside a drawn iPhone/iPad bezel — the
        // screen corners come from the device geometry, not user settings, and
        // the outer frame clip is disabled (the bezel IS the frame).
        let deviceFrameActive = project.recordingSourceKind == .device && settings.showDeviceFrame

        let staticLayout: FrameLayout = {
            let layout = frameLayout(
                sourceSize: effectiveNaturalSize,
                outputSize: outputSize,
                settings: settings,
                canvasScale: canvasScale
            )
            guard deviceFrameActive else { return layout }
            // Reserve bezel room around the video so the frame is never
            // clipped — mirrors previewVideoRect's inset (kept centered on the
            // original rect so placement offsets are preserved).
            var scale: CGFloat = 1
            for _ in 0..<3 {
                let bezel = DeviceFrameLayout.bezelWidth(
                    forVideoWidth: layout.videoRect.width * scale
                )
                scale = min(
                    (layout.contentRect.width - 2 * bezel) / layout.videoRect.width,
                    (layout.contentRect.height - 2 * bezel) / layout.videoRect.height
                )
            }
            scale = max(0.01, min(1, scale))
            let newWidth = layout.videoRect.width * scale
            let newHeight = layout.videoRect.height * scale
            let shrunk = CGRect(
                x: layout.videoRect.midX - newWidth / 2,
                y: layout.videoRect.midY - newHeight / 2,
                width: newWidth,
                height: newHeight
            )
            return FrameLayout(
                contentRect: layout.contentRect,
                videoRect: shrunk,
                videoScale: layout.videoScale * scale
            )
        }()
        let outerCornerRadius: CGFloat = (deviceFrameActive || settings.frameShape == .rectangle)
            ? 0 : max(0, settings.cornerRadius * canvasScale)
        let innerCornerRadius: CGFloat = deviceFrameActive
            ? DeviceFrameLayout.screenCornerRadius(
                forVideoSize: staticLayout.videoRect.size)
            : max(0, settings.windowCornerRadius * canvasScale)

        // Window-clip mask (inner rounded rect) — same every frame
        let cachedWindowMask: CIImage? = innerCornerRadius > 0
            ? roundedRectangleMaskImage(
                extent: staticLayout.contentRect,
                rect: staticLayout.videoRect,
                cornerRadius: innerCornerRadius,
                inverted: false,
                // Phone screens have continuous ("squircle") corners.
                frameShape: deviceFrameActive ? .squircle : .roundedRect)
            : nil

        // Outer frame-clip mask — same every frame
        let cachedOuterMask: CIImage? = outerCornerRadius > 0
            ? roundedRectangleMaskImage(
                extent: staticLayout.contentRect,
                rect: staticLayout.videoRect,
                cornerRadius: outerCornerRadius,
                inverted: false,
                frameShape: settings.frameShape)
            : nil

        // Shadow + background baked into one Metal texture.
        // CIImage is lazy: without force-rendering, the Gaussian blur would be
        // recomputed on every frame. We commit one command buffer now so the GPU
        // evaluates it once and the result lives as a resident Metal texture.
        let outputRect = CGRect(origin: .zero, size: outputSize)

        // Force-render a lazy CIImage into a resident Metal texture so its
        // blur/gradient work happens once, not per frame.
        func bakeStatic(_ image: CIImage) -> CIImage {
            guard let device = exportMetalDevice, let queue = exportCommandQueue else {
                return image
            }
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: outputWidth, height: outputHeight,
                mipmapped: false
            )
            desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
            guard let tex = device.makeTexture(descriptor: desc) else { return image }
            let cmd = queue.makeCommandBuffer()!
            exportCIContext.render(image, to: tex, commandBuffer: cmd,
                                   bounds: outputRect, colorSpace: renderSpace)
            cmd.commit()
            cmd.waitUntilCompleted()
            // CIImage backed by a resident Metal texture — zero CPU work per frame
            return CIImage(mtlTexture: tex, options: [.colorSpace: renderSpace]) ?? image
        }

        // Shadow (+ device bezel) that belongs to the video CARD, over
        // transparency — kept separate from the background so screen tilt can
        // warp the card (shadow included) without warping the backdrop.
        let cardStaticOverlay: CIImage? = {
            // With a device frame, the shadow hugs the bezel, not the video.
            let shadowRect = deviceFrameActive
                ? DeviceFrameLayout.bezelRect(
                    forVideoRect: staticLayout.videoRect)
                : staticLayout.videoRect
            let shadowCornerRadius = deviceFrameActive
                ? DeviceFrameLayout.bezelCornerRadius(
                    forVideoSize: staticLayout.videoRect.size)
                : outerCornerRadius
            let shadow = makeFrameShadow(
                extent: outputRect,
                rect: shadowRect,
                cornerRadius: shadowCornerRadius,
                shadowRadius: max(0, settings.shadowRadius * canvasScale),
                shadowOpacity: max(0, settings.shadowOpacity),
                frameShape: deviceFrameActive ? .squircle : settings.frameShape
            )
            var overlay = shadow
            if deviceFrameActive,
               let bezel = DeviceFrameRenderer.makeDeviceBezelImage(
                   extent: outputRect,
                   videoRect: staticLayout.videoRect) {
                overlay = overlay.map { bezel.composited(over: $0) } ?? bezel
            }
            return overlay?.cropped(to: outputRect)
        }()

        let cachedBaseFrame: CIImage = bakeStatic(
            (cardStaticOverlay.map { $0.composited(over: cachedBackground) } ?? cachedBackground)
                .cropped(to: outputRect)
        )

        // Card path: the card's static layers over TRANSPARENCY, so the whole
        // card (shadow + bezel + video + overlays) can be perspective-warped
        // and/or zoomed and then set over the untouched background each frame.
        // Needed whenever tilt or zoom is in play — zoom scales ONLY the card,
        // never the background.
        // Camera layout regions need the card composited over TRANSPARENCY —
        // the side-by-side squeeze transforms the card with the background
        // staying put, exactly like the keynote dip.
        // Intro slide is in this list because its transform is applied INSIDE
        // the card-compositing branch below — a project with a slide but no
        // tilt/zoom/camera/device otherwise took the cheap whole-frame path
        // and exported without the entrance the preview showed (P0: preview
        // must equal export).
        let cachedCardStatics: CIImage? = (tiltActive || !project.zoomRegions.isEmpty
            || !project.cameraLayoutRegions.isEmpty
            || settings.introSlideStyle != .off
            || project.sourceSegments.contains { $0.kind == .device })
            ? bakeStatic(
                (cardStaticOverlay ?? CIImage(color: .clear).cropped(to: outputRect))
                    .cropped(to: outputRect)
              )
            : nil

        // Dynamic Island pill — static, composited above the video each frame.
        let cachedDeviceIsland: CIImage? = deviceFrameActive
            ? DeviceFrameRenderer.makeDeviceIslandImage(
                extent: outputRect,
                videoRect: staticLayout.videoRect)
            : nil

        // The device's side faces as a baked template: static in shape, moved
        // per frame by the tilt offset so the correct edges show (the bezel
        // itself stays cached). Per-frame cost is one transform + composite.
        let cachedDeviceSide: CIImage? = deviceFrameActive
            ? DeviceFrameRenderer.makeDeviceSideImage(
                extent: outputRect,
                videoRect: staticLayout.videoRect)
                .map { bakeStatic($0.cropped(to: outputRect)) }
            : nil

        // Device segments inside stitched multi-source takes get cropped to
        // their phone content and bezel-framed per frame (the whole-project
        // path above handles pure device takes).
        struct SegmentDeviceAssets {
            let screenMask: CIImage
            let bezel: CIImage
            /// Extruded side faces, offset per frame by the tilt (drawn under
            /// the bezel).
            let side: CIImage?
            let island: CIImage?
            let ranges: [(start: TimeInterval, end: TimeInterval)]
            /// Phone content rect + its screen corner radius, for morphing the
            /// crop from the full video rect across segment boundaries.
            let subRect: CGRect
            let screenCornerRadius: CGFloat
        }
        let segmentDeviceAssets: SegmentDeviceAssets? = {
            guard !deviceFrameActive, settings.showDeviceFrame else { return nil }
            let deviceSegments = project.sourceSegments.filter { $0.kind == .device }
            guard let first = deviceSegments.first else { return nil }
            let normalized = first.normalizedContentRect
            let vr = staticLayout.videoRect
            // Normalized top-left origin → CI y-up space
            let subRect = CGRect(
                x: vr.minX + normalized.minX * vr.width,
                y: vr.minY + (1 - normalized.minY - normalized.height) * vr.height,
                width: normalized.width * vr.width,
                height: normalized.height * vr.height
            )
            let screenRadius = DeviceFrameLayout.screenCornerRadius(
                forVideoSize: subRect.size)
            guard let mask = roundedRectangleMaskImage(
                extent: staticLayout.contentRect,
                rect: subRect,
                cornerRadius: screenRadius,
                inverted: false,
                frameShape: .squircle
            ), var bezel = DeviceFrameRenderer.makeDeviceBezelImage(
                extent: outputRect,
                videoRect: subRect) else { return nil }
            // The bezel casts its own tight shadow (like the preview's
            // DeviceBezelView) — the full-rect card shadow fades out during
            // device segments instead.
            if let bezelShadow = makeFrameShadow(
                extent: outputRect,
                rect: DeviceFrameLayout.bezelRect(forVideoRect: subRect),
                cornerRadius: DeviceFrameLayout.bezelCornerRadius(
                    forVideoSize: subRect.size),
                shadowRadius: max(0, settings.shadowRadius * canvasScale),
                shadowOpacity: max(0, settings.shadowOpacity),
                frameShape: .squircle
            ) {
                bezel = bezel.composited(over: bezelShadow).cropped(to: outputRect)
            }
            return SegmentDeviceAssets(
                screenMask: mask,
                bezel: bezel,
                side: DeviceFrameRenderer.makeDeviceSideImage(
                    extent: outputRect,
                    videoRect: subRect)
                    .map { bakeStatic($0.cropped(to: outputRect)) },
                island: DeviceFrameRenderer.makeDeviceIslandImage(
                    extent: outputRect,
                    videoRect: subRect),
                ranges: deviceSegments.map { ($0.startTime, $0.endTime) },
                subRect: subRect,
                screenCornerRadius: screenRadius
            )
        }()

        // Replacement menu bar — covers the recorded macOS menu bar with the
        // clean customizable one, positioned over the top strip of the video
        // rect. Built once (static per export); shares MenuBarRenderer with
        // the preview for a 1:1 match.
        let cachedMenuBar: CIImage? = {
            guard settings.menuBarReplacement == .dark || settings.menuBarReplacement == .light,
                  !deviceFrameActive else { return nil }
            let vr = staticLayout.videoRect
            let barH = max(4, vr.height * CGFloat(settings.menuBarHeight) / 100)
            guard let bar = MenuBarRenderer.image(for: .init(
                style: settings.menuBarReplacement,
                title: settings.menuBarTitle,
                titleAlignment: settings.menuBarTitleAlignment,
                showStatusIcons: settings.menuBarShowStatusIcons,
                clock: settings.menuBarClock,
                width: Int(vr.width.rounded()),
                height: Int(barH.rounded())
            )), let cg = bar.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            var ci = CIImage(cgImage: cg)
            // NSImage may rasterize at 2× — normalize to the exact target size.
            let sx = vr.width / max(1, ci.extent.width)
            let sy = barH / max(1, ci.extent.height)
            ci = ci.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            return ci.transformed(by: CGAffineTransform(
                translationX: vr.minX,
                y: vr.maxY - barH // CI Y-up: top strip
            ))
        }()

        // Keynote-style segment cut: the framing switches INSTANTLY at the
        // boundary (a mask morph would expose the source's pillarboxed
        // in-between frame), and the whole card does a quick dip — easing
        // down in scale and opacity across the cut and springing back — the
        // way Apple hides a hard content swap. Gaussian in time, so it's
        // symmetric, deterministic, and identical to the preview's dip.
        func deviceSegmentActive(_ time: TimeInterval) -> Bool {
            segmentDeviceAssets?.ranges.contains { time >= $0.start - 0.01 && time <= $0.end + 0.01 } ?? false
        }
        func deviceBoundaryDip(_ time: TimeInterval) -> Double {
            guard let assets = segmentDeviceAssets else { return 0 }
            return DeviceSegmentDip.phase(
                at: time,
                boundaries: assets.ranges.flatMap { [$0.start, $0.end] }
            )
        }

        // ── Camera overlay assets — baked once at a canonical base rect ─────
        // The on-canvas rect is computed *per frame* via ReactiveCameraLayout
        // so the bubble can shrink and slide away from the zoom focal point
        // (Screen Studio-style). The cached mask/stroke/shadow are built at a
        // canonical base rect and re-targeted per frame by a CIAffineTransform,
        // so we still avoid the CGContext + Gaussian-blur cost in the hot path.
        // The chosen base corner is arbitrary — only the rect's size and the
        // shape outline matter for the cached images.
        struct CameraStaticAssets {
            let baseRect: CGRect      // canonical rect in CIImage (Y-up) space
            let mask: CIImage?
            let stroke: CIImage?
            let shadow: CIImage?
            /// Ring-light glow (CameraStyleMath recipe), baked at baseRect.
            let ring: CIImage?
            /// Name-tag pill raster, positioned at its baseRect-relative spot.
            let tag: CIImage?
        }
        // Brand watermark — static for the whole export: scaled to size,
        // positioned by the same origin-interpolation the preview uses
        // (Y-down fraction flipped for CI), opacity via alpha matrix. Built
        // once here, composited over every frame after the camera.
        let watermarkStatic: CIImage? = {
            guard settings.showWatermark,
                  let url = project.watermarkImageURL,
                  let raw = CIImage(contentsOf: url) else { return nil }
            let edgePad = 20 * canvasScale
            let rawW = raw.extent.width, rawH = raw.extent.height
            guard rawW > 0, rawH > 0 else { return nil }
            let targetW = min(CGFloat(settings.watermarkSize) * canvasScale, max(1, outputSize.width - 2 * edgePad))
            let scale = targetW / rawW
            let targetH = rawH * scale
            let usableW = max(0, outputSize.width - 2 * edgePad - targetW)
            let usableH = max(0, outputSize.height - 2 * edgePad - targetH)
            let fx = CGFloat(min(1, max(0, settings.watermarkX)))
            let fy = CGFloat(min(1, max(0, settings.watermarkY)))
            let originX = edgePad + fx * usableW
            let originY = edgePad + (1 - fy) * usableH // Y-down → CI Y-up
            // Uniform RGBA multiply — premultiplied-alpha-correct fade.
            let faded = fadeImage(raw, alpha: settings.watermarkOpacity)
            return faded
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale)
                    .concatenating(CGAffineTransform(translationX: originX - raw.extent.minX * scale,
                                                     y: originY - raw.extent.minY * scale)))
                .cropped(to: CGRect(origin: .zero, size: outputSize))
        }()

        // Size is nominal-canvas points — apply the same canvas-fit factor
        // the preview uses so the bubble's relative footprint matches at any
        // window size, then scale to the export resolution.
        let cameraFit = ReactiveCameraLayout.canvasFitScale(for: referenceCanvas)
        let cameraBaseSize = max(1, settings.effectiveCameraSize * cameraFit * canvasScale)
        let cameraPadding: CGFloat = 12 * cameraFit * canvasScale
        // Bubble aspect is shape-gated: rounded-rect follows the camera video's
        // real aspect, every other shape is 1:1 with the video aspect-filled.
        let cameraAspect: Double = ReactiveCameraLayout.shapeAspect(
            shape: settings.cameraShape,
            videoAspect: cameraNaturalSize.width > 0 && cameraNaturalSize.height > 0
                ? Double(cameraNaturalSize.width / cameraNaturalSize.height)
                : 1,
            orientation: settings.cameraOrientation
        )
        let cameraStaticAssets: CameraStaticAssets? = {
            guard cameraReader != nil else {
                print("[Export Camera] layout skipped: cameraReader is nil")
                return nil
            }
            // Camera anchors to the FULL canvas corner (matches the preview) —
            // background padding must never squeeze the bubble inward.
            let cr = outputRect
            // Canonical bottom-right corner — values are scaled/translated to
            // wherever ReactiveCameraLayout puts the camera each frame.
            let baseBubble = ReactiveCameraLayout.bubbleSize(baseSize: Double(cameraBaseSize), aspect: cameraAspect)
            let baseRect = CGRect(
                x: cr.maxX - cameraPadding - baseBubble.width,
                y: cr.minY + cameraPadding,
                width: baseBubble.width, height: baseBubble.height
            )
            let shadowRadius = 6 * canvasScale
            let shadowSlack = shadowRadius * 4 + 4
            let shadowExtent = baseRect.insetBy(dx: -shadowSlack, dy: -shadowSlack)
            let mask = cameraShapeMaskImage(
                extent: baseRect, rect: baseRect,
                shape: settings.cameraShape,
                cornerRadius: settings.cameraCornerRadius, scale: canvasScale)
            let stroke = settings.cameraBorderWidth > 0 ? cameraShapeStrokeImage(
                extent: baseRect, rect: baseRect,
                shape: settings.cameraShape,
                cornerRadius: settings.cameraCornerRadius, scale: canvasScale,
                lineWidth: settings.cameraBorderWidth * canvasScale,
                strokeColor: CameraStyleMath.borderNSColor(settings)) : nil
            let shadow = cameraShapeShadowImage(
                extent: shadowExtent, rect: baseRect,
                shape: settings.cameraShape,
                cornerRadius: settings.cameraCornerRadius, scale: canvasScale,
                shadowRadius: shadowRadius)
            // Ring light — the SAME CameraStyleMath bitmap the preview shows.
            // The raster is PADDED by ringPadding on every side (the glow sits
            // OUTSIDE the bubble), so it is positioned at the outset of
            // baseRect (px units, so scale = 1 relative to rect; the corner
            // radius still needs the canvas scale).
            let ring: CIImage? = CameraStyleMath.ringImage(
                size: baseRect.size, shape: settings.cameraShape,
                customRadius: settings.cameraCornerRadius * Double(canvasScale),
                intensity: settings.cameraRingLight, scale: 1
            ).map {
                let pad = CameraStyleMath.ringPadding(for: baseRect.size)
                return CIImage(cgImage: $0)
                    .transformed(by: CGAffineTransform(
                        translationX: baseRect.minX - pad, y: baseRect.minY - pad))
                    .cropped(to: baseRect.insetBy(dx: -pad, dy: -pad))
            }
            // Name tag — shared measurement + placement from CameraStyleMath;
            // positioned relative to baseRect and re-targeted per frame by the
            // same affine transform as the other static assets.
            let tag: CIImage? = CameraStyleMath.tagBitmap(
                settings: settings, bubbleWidth: baseRect.width, scale: 1
            ).map { built in
                let tr = CameraStyleMath.tagRect(
                    bubbleRect: baseRect, pillSize: built.pillSize,
                    position: settings.cameraTagPosition, yAxisIsUp: true
                )
                return CIImage(cgImage: built.image)
                    .transformed(by: CGAffineTransform(translationX: tr.minX, y: tr.minY))
            }
            return CameraStaticAssets(baseRect: baseRect, mask: mask, stroke: stroke, shadow: shadow, ring: ring, tag: tag)
        }()

        // Cache the cursor CGImage as a CIImage at native pixel size.
        // renderCursorCI scales it to the layout's drawRect, which is in canvas-point
        // space and already bakes in cursorScale + cursorPointToViewScale.
        // Pre-scaling here was wrong: CIImage uses pixel dimensions (2× on Retina)
        // but CursorOverlayLayout uses point dimensions → cursor appeared 2× too large.
        let cachedCursorCI: CIImage? = {
            guard settings.showCursor, let cgImg = cursorAsset.cgImage else { return nil }
            return CIImage(cgImage: cgImg)
        }()

        // Process video frames with a deep pipeline. Each frame's GPU render +
        // writer append runs concurrently in its own Task; a serial actor
        // enforces PTS-ordered appends and writer backpressure. Depth=5 keeps
        // the Apple Silicon Media Engine (or Intel Quick Sync) HEVC encoder
        // fed at 4K where each Metal command is heavier and a shallow pipe
        // can starve the encoder.
        let pipelineDepth = 8
        let exportStartHostTime = CMClockGetTime(CMClockGetHostTimeClock())
        var lastLogHostTime = exportStartHostTime
        var lastProgressHostTime = exportStartHostTime
        var lastLogFrameIndex = 0
        FileHandle.standardOutput.write(
            Data(String(format: "[Export] start — %d frames @ %d×%d %dfps (source %.0f×%.0f, %.1fs timeline)\n",
                        outputFrameTimes.count, outputWidth, outputHeight, exportSettings.fps,
                        naturalSize.width, naturalSize.height, totalSeconds).utf8)
        )
        let appender = SerialAppender()
        var frameTasks: [Task<Void, Never>] = []
        // Appender sequence number. Distinct from `frameIndex`: a frame can be
        // skipped (pixel-buffer allocation failure) and a gap in the sequence
        // would stall the ordered appender forever.
        var appendIndex = 0
        var currentPixelBuffer = initialPixelBuffer
        var currentVideoSampleTime = CMSampleBufferGetPresentationTimeStamp(initialSampleBuffer)
        var nextSampleBuffer: CMSampleBuffer? = readerOutput2.copyNextSampleBuffer()

        // Camera frame state — advanced in lockstep with source-time below.
        var currentCameraPixelBuffer: CVPixelBuffer? = nil
        var currentCameraSampleTime: CMTime = .zero
        var nextCameraSampleBuffer: CMSampleBuffer? = cameraReaderOutput?.copyNextSampleBuffer()

        // Poster image (saved when recording starts, captured from the
        // already-warmed-up preview session — never a black sensor frame).
        // The preview uses this during the leading `cameraTimeOffset` gap,
        // so the export does the same to stay 1:1.
        // Curtain Unveil brand logo + cover style — loaded ONCE per export
        // session, never per frame. The style mapping is the shared
        // CurtainUnveilMath.coverStyle the preview also consumes.
        let curtainLogoCG: CGImage? = {
            guard settings.curtainUnveilCorner != .off,
                  let url = project.curtainLogoImageURL,
                  let nsImage = NSImage(contentsOf: url)
            else { return nil }
            return nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }()
        let curtainStyle = CurtainUnveilMath.coverStyle(settings: settings, logo: curtainLogoCG)

        // Depth Focus gradient masks (FocusMath.maskImage) — built once per
        // region parameters, reused across frames. Same mask, same sigma
        // mapping the preview's buildFocusPatch consumes.
        var exportFocusMasks: [UUID: (key: String, image: CIImage)] = [:]

        let cameraPosterCI: CIImage? = {
            guard cameraReader != nil,
                  let posterURL = project.cameraPosterURL,
                  let nsImage = NSImage(contentsOf: posterURL),
                  let tiff = nsImage.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let cgImage = bitmap.cgImage
            else {
                print("[Export Camera] poster: not available")
                return nil
            }
            print("[Export Camera] poster: loaded \(cgImage.width)x\(cgImage.height) from \(posterURL.lastPathComponent)")
            return CIImage(cgImage: cgImage, options: [.colorSpace: srgb])
        }()

        // ── Fast export: static-span collapse (VFR) ─────────────────────────
        //
        // When NOTHING that reaches the pixels changes between two output
        // frames, the second frame is not rendered or appended — the previous
        // sample simply lasts longer (mp4 sample durations come from PTS
        // deltas). Pixels at every presentation time are IDENTICAL to the CFR
        // output; only the sample count changes. Screen recordings are mostly
        // static, so this is the difference between encoding 60 copies of a
        // still second and encoding one.
        //
        // The skip predicate is deliberately conservative and built from the
        // same inputs the compositor consumes — a frame is skippable only if:
        //  • the decoded source sample did not advance (ScreenCaptureKit only
        //    emits frames on change, so this is the true "screen is static"
        //    signal — no pixel compare needed),
        //  • the camera (webcam) sample did not advance,
        //  • the precomputed CameraKey (zoom/focal/tilt springs) is equal,
        //  • the smoothed cursor position, hide-state, and backdrop dim are
        //    equal, and no cursor event fired in the trailing physics window
        //    (pose springs + click ripples are all driven by events),
        //  • the time is not inside/near any blur, focus, highlight, subtitle,
        //    or annotation span (their renders consume raw currentTime),
        //  • the device-segment flag is unchanged.
        // Any doubt = render the frame. GIF exports never collapse (the GIF
        // converter assumes dense frames), and a keyframe is forced at least
        // every `maxStaticGap` seconds so players seek precisely.
        let collapseStatic = exportSettings.collapseStaticSpans && exportSettings.format != .gif
        let maxStaticGap: Double = 5
        /// Trailing window in which a cursor MOVEMENT can still influence
        /// pixels (pose springs, click ripples, hide fades — the longest,
        /// ripples, run 0.45s; springs settle ~1s). 2s is still generous, and
        /// the frame key's quantized cursor position independently forces a
        /// render whenever the drawn cursor is actually mid-motion. Measured
        /// on a real 5-min recording: 5s left 4% of frames collapsible, 2s
        /// makes 21% collapsible.
        let cursorQuietWindow: Double = 2
        var animationHotSpans: [(start: Double, end: Double)] = []
        if collapseStatic {
            // Layout morphs run for `transitionDuration` after every edge.
            for r in project.cameraLayoutRegions {
                let d = CameraLayoutMath.transitionDuration
                animationHotSpans.append((r.startTime - 0.1, r.startTime + d + 0.1))
                animationHotSpans.append((r.endTime - 0.1, r.endTime + d + 0.1))
            }
            for r in project.blurRegions { animationHotSpans.append((r.startTime - 1, r.endTime + 1)) }
            for r in project.focusRegions { animationHotSpans.append((r.startTime - 1, r.endTime + 1)) }
            for r in project.highlightRegions {
                animationHotSpans.append((r.startTime - transitionDuration - 1, r.endTime + transitionDuration + 1))
            }
            for s in project.subtitles { animationHotSpans.append((s.startTime - 0.5, s.endTime + 0.5)) }
            for a in project.annotations { animationHotSpans.append((a.startTime - 1, a.endTime + 1)) }
            // Shortcut pills animate from keyboard events, which the cursor
            // quiet-window can't see — without a hot span a pill firing in a
            // static stretch would freeze mid-fade in the export.
            for e in keystrokeDisplayEvents {
                let pillLife = KeystrokeOverlayMath.fadeIn + KeystrokeOverlayMath.hold
                    + KeystrokeOverlayMath.fadeOut
                animationHotSpans.append((e.time - 0.1, e.time + pillLife + 0.1))
            }
            // Device-segment boundary dips (Gaussian, sigma 0.15s) animate on
            // the same source clock — without a span the ease halves collapse
            // into a hard pop the moment the cursor happens to be quiet.
            if let assets = segmentDeviceAssets {
                let dipHalf = DeviceSegmentDip.sigma * 4
                for boundary in assets.ranges.flatMap({ [$0.start, $0.end] }) {
                    animationHotSpans.append((boundary - dipHalf, boundary + dipHalf))
                }
            }
            animationHotSpans.sort { $0.start < $1.start }
        }
        // Curtain unveil and intro slide animate on the OUTPUT clock
        // (`outputTime.seconds`), so their guard spans live in a separate
        // output-time list — appending them to the source-time spans above
        // would misplace them inside any speed-ramped timeline.
        var outputHotSpans: [(start: Double, end: Double)] = []
        if collapseStatic {
            if settings.curtainUnveilCorner != .off {
                outputHotSpans.append((settings.curtainUnveilStart - 0.1,
                                       settings.curtainUnveilStart + settings.curtainUnveilDuration + 0.1))
            }
            if settings.introSlideStyle != .off {
                outputHotSpans.append((settings.introSlideStart - 0.1,
                                       settings.introSlideStart + settings.introSlideDuration + 0.1))
            }
            outputHotSpans.sort { $0.start < $1.start }
        }
        func inOutputHotSpan(_ t: Double) -> Bool {
            for span in outputHotSpans {
                if span.start > t { return false }
                if t <= span.end { return true }
            }
            return false
        }
        func inAnimationHotSpan(_ t: Double) -> Bool {
            // Spans are few (tens); linear scan with early exit is fine.
            for span in animationHotSpans {
                if span.start > t { return false }
                if t <= span.end { return true }
            }
            return false
        }
        // The tracker appends a sample every poll tick (30 Hz) even while the
        // mouse rests, so "any event in the window" kept whole recordings
        // collapse-free — the single biggest reason long static exports ran at
        // full rate. Pixels only move on actual MOTION or a click edge, so
        // quietness is measured from those. Slow sub-threshold drift is still
        // safe: the frame key's quantized cursorPosition forces a render the
        // moment the interpolated position moves a visible amount.
        var cursorTimestamps: [TimeInterval] = []
        var cursorAnchor: CursorEvent?
        for e in cursorEvents {
            if let a = cursorAnchor {
                if abs(e.x - a.x) > 0.5 || abs(e.y - a.y) > 0.5 || e.isClick != a.isClick {
                    cursorTimestamps.append(e.timestamp)
                    cursorAnchor = e
                }
            } else {
                cursorTimestamps.append(e.timestamp)
                cursorAnchor = e
            }
        }
        func cursorQuiet(at t: Double) -> Bool {
            guard !cursorTimestamps.isEmpty else { return true }
            // Index of first timestamp > t − window; quiet when nothing in
            // (t − window, t]. Future events flip the key when they arrive.
            var lo = 0, hi = cursorTimestamps.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if cursorTimestamps[mid] <= t - cursorQuietWindow { lo = mid + 1 } else { hi = mid }
            }
            return lo >= cursorTimestamps.count || cursorTimestamps[lo] > t
        }
        struct StaticFrameKey: Equatable {
            var videoSampleSeconds: Double
            var cameraSampleSeconds: Double
            var cam: CameraKey
            var cursorPosition: CGPoint?
            var cursorHidden: Bool
            var dimAlpha: Double
            var deviceSegment: Bool
            /// Interpolated camera-layout geometry — a morph must never be
            /// collapsed away. Quantized like the other continuous fields.
            var cameraLayout: String

            /// Springs asymptote — they never return to BIT-exact rest, so an
            /// exact compare collapses nothing after the first zoom. Quantized
            /// below visual resolution instead: 1e-6 of the canvas is ~1/250
            /// of a 4K pixel. Comparison is always against the LAST APPENDED
            /// key (not the previous frame), so sub-quantum drift accumulates
            /// until it crosses one quantum and then a frame is appended —
            /// total positional error is bounded by the quantum itself.
            func quantized() -> StaticFrameKey {
                func q(_ v: Double, _ s: Double) -> Double { (v * s).rounded() / s }
                var k = self
                k.videoSampleSeconds = q(videoSampleSeconds, 1e6)
                k.cameraSampleSeconds = q(cameraSampleSeconds, 1e6)
                k.cam.zoom = q(cam.zoom, 1e6)
                k.cam.focalX = q(cam.focalX, 1e6)
                k.cam.focalY = q(cam.focalY, 1e6)
                k.cam.offsetX = q(cam.offsetX, 1e6)
                k.cam.offsetY = q(cam.offsetY, 1e6)
                k.cam.tiltPitch = q(cam.tiltPitch, 1e4)
                k.cam.tiltYaw = q(cam.tiltYaw, 1e4)
                k.cam.tiltRoll = q(cam.tiltRoll, 1e4)
                if let p = cursorPosition {
                    k.cursorPosition = CGPoint(x: q(Double(p.x), 1e3), y: q(Double(p.y), 1e3))
                }
                k.dimAlpha = q(dimAlpha, 1e4)
                return k
            }
        }
        var lastAppendedKey: StaticFrameKey?
        var lastAppendedSeconds = -Double.greatestFiniteMagnitude
        var collapsedFrameCount = 0


        for (frameIndex, outputTime) in outputFrameTimes.enumerated() {
            let sourceCMTime = sourceFrameTimes[frameIndex]
            let currentTime = timelineSourceTimes[frameIndex]

            if let sourceCMTime {
                while let sampleBuffer = nextSampleBuffer,
                      CMSampleBufferGetPresentationTimeStamp(sampleBuffer) <= sourceCMTime {
                    if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                        currentPixelBuffer = pixelBuffer
                        currentVideoSampleTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    }
                    nextSampleBuffer = readerOutput2.copyNextSampleBuffer()
                }
            }

            // Advance the camera reader to the matching camera-time. We always
            // walk forward — when the source rewinds across a clip boundary the
            // camera simply stays on its last decoded frame.
            if cameraReaderOutput != nil {
                let cameraTargetTime = currentTime - project.cameraTimeOffset
                if cameraTargetTime >= 0 {
                    let camCMTime = CMTime(seconds: cameraTargetTime, preferredTimescale: 600)
                    while let sampleBuffer = nextCameraSampleBuffer,
                          CMSampleBufferGetPresentationTimeStamp(sampleBuffer) <= camCMTime {
                        if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                            currentCameraPixelBuffer = pixelBuffer
                            currentCameraSampleTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                        }
                        nextCameraSampleBuffer = cameraReaderOutput?.copyNextSampleBuffer()
                    }
                }
            }

            // Use pre-computed smoothed camera values
            let cam = cameraPath[frameIndex]

            // Dynamic camera layout, fully interpolated across mode
            // boundaries. Resolved BEFORE the card composite because the
            // side-by-side squeeze transforms the card itself.
            let bubbleRectNow = ReactiveCameraLayout.cameraRect(
                in: outputRect, // full canvas — padding-independent
                basePosition: settings.cameraPosition,
                customPosition: settings.cameraCustomX.flatMap { x in
                    settings.cameraCustomY.map { CGPoint(x: x, y: $0) }
                },
                baseSize: Double(cameraBaseSize),
                // RAW smoothed zoom, not the cover-compensated card zoom — the
                // preview's renderCamera feeds motion.zoom straight in, and the
                // bubble must shrink identically.
                zoom: Double(cam.zoom),
                padding: Double(cameraPadding),
                aspect: cameraAspect,
                yAxisIsUp: true
            )
            let camLayout = CameraLayoutMath.resolve(
                at: currentTime,
                regions: project.cameraLayoutRegions,
                videoRect: staticLayout.videoRect,
                bubbleRect: bubbleRectNow,
                bubbleCornerRadius: CameraLayoutMath.bubbleApproxCornerRadius(
                    shape: settings.cameraShape,
                    customRadius: CGFloat(settings.cameraCornerRadius) * canvasScale,
                    size: bubbleRectNow.size),
                cardCornerRadius: max(0, settings.cornerRadius * canvasScale),
                hasCamera: cameraStaticAssets != nil
            )
            // Cover-compensated like the preview — see TiltMath.effectiveCoverZoom.
            let zoom = Double(TiltMath.effectiveCoverZoom(
                zoom: CGFloat(cam.zoom),
                pitchDegrees: cam.tiltPitch,
                yawDegrees: cam.tiltYaw,
                rollDegrees: cam.tiltRoll,
                aspect: outputSize.width / max(1, outputSize.height)
            ))
            let effectiveFocal = CGPoint(x: cam.focalX, y: cam.focalY)

            let cursorPosition: CGPoint? = if !cursorEvents.isEmpty {
                cursorSmoother.interpolateIfFresh(events: cursorEvents, at: currentTime)
            } else {
                nil
            }

            // Canvas half of the annotation blackout: dim whatever the card
            // does not cover (mirrors the preview's backdropDimLayer — the
            // card dims itself via AnnotationRenderer's card-space backdrop).
            // Black-over-black source-over is order-independent, so dimming
            // the baked shadow+background composite matches the preview's
            // background→dim→shadow layer order exactly.
            let backdropDimAlpha = AnnotationRenderer.backdropAlpha(
                annotations: project.annotations, at: currentTime)
            func dimmedBackdrop(_ image: CIImage) -> CIImage {
                guard backdropDimAlpha > 0.001 else { return image }
                return CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: backdropDimAlpha))
                    .cropped(to: outputRect)
                    .composited(over: image)
                    .cropped(to: outputRect)
            }

            // Static-span collapse: identical inputs → the previous appended
            // sample keeps playing; nothing is rendered or encoded for this
            // output time. See the predicate rationale above the loop.
            if collapseStatic {
                let frameKey = StaticFrameKey(
                    videoSampleSeconds: CMTimeGetSeconds(currentVideoSampleTime),
                    cameraSampleSeconds: cameraReaderOutput != nil
                        ? CMTimeGetSeconds(currentCameraSampleTime) : 0,
                    cam: cam,
                    cursorPosition: cursorPosition,
                    cursorHidden: settings.showCursor && !cursorEvents.isEmpty
                        ? shouldHideCursor(at: currentTime, cursorEvents: cursorEvents, settings: settings)
                        : false,
                    dimAlpha: backdropDimAlpha,
                    deviceSegment: segmentDeviceAssets != nil && deviceSegmentActive(currentTime),
                    cameraLayout: String(
                        format: "%.0f,%.0f,%.0f,%.0f,%.3f,%.3f,%.4f,%.1f",
                        camLayout.cameraRect?.minX ?? -1, camLayout.cameraRect?.minY ?? -1,
                        camLayout.cameraRect?.width ?? -1, camLayout.cameraRect?.height ?? -1,
                        camLayout.cameraOpacity, camLayout.chromeOpacity,
                        camLayout.cardScale, camLayout.cardTranslationX)
                )
                let outputSeconds = CMTimeGetSeconds(outputTime)
                let quantizedKey = frameKey.quantized()
                let skippable = frameIndex > 0
                    && frameIndex < outputFrameTimes.count - 1
                    && quantizedKey == lastAppendedKey
                    && outputSeconds - lastAppendedSeconds < maxStaticGap
                    && cursorQuiet(at: currentTime)
                    && !inAnimationHotSpan(currentTime)
                    && !inOutputHotSpan(outputSeconds)
                if skippable {
                    collapsedFrameCount += 1
                    let p = Double(frameIndex + 1) / Double(outputFrameTimes.count)
                    let progressElapsed = CMTimeGetSeconds(CMTimeSubtract(
                        CMClockGetTime(CMClockGetHostTimeClock()), lastProgressHostTime))
                    if progressElapsed >= 0.1 {
                        lastProgressHostTime = CMClockGetTime(CMClockGetHostTimeClock())
                        Task { @MainActor in self.progress = max(self.progress, p) }
                    }
                    continue
                }
                lastAppendedKey = quantizedKey
                lastAppendedSeconds = outputSeconds
            }

            var composited = dimmedBackdrop(cachedBackground.cropped(to: outputRect))

            // Respect the first video sample PTS so audio cannot appear delayed
            // just because export showed frame 1 before it actually exists.
            if let sourceCMTime, currentVideoSampleTime <= sourceCMTime {
                // The device's side faces move with the tilt so the edges that
                // rotate toward the viewer are the ones that show. The slab is
                // baked once; only this translate happens per frame.
                //
                // TiltMath.deviceSideOffset is expressed in the preview's
                // Y-DOWN space, so the y component is NEGATED here for Core
                // Image's Y-UP space (x is the same in both).
                let sideVisible = max(abs(cam.tiltPitch), abs(cam.tiltYaw)) > 0.05
                func tiltedSide(_ image: CIImage, videoWidth: CGFloat) -> CIImage {
                    let off = TiltMath.deviceSideOffset(
                        pitchDegrees: cam.tiltPitch,
                        yawDegrees: cam.tiltYaw,
                        videoWidth: videoWidth
                    )
                    return image.transformed(
                        by: CGAffineTransform(translationX: off.width, y: -off.height)
                    )
                }

                // Tilt path builds the CARD over transparency first; the
                // background is composited underneath after the warp below.
                // Non-warp fallback bakes the background into the card base —
                // the dim rides under it there; the warp path's background is
                // dimmed where it composites after the warp instead.
                var cardStatics = cachedCardStatics ?? dimmedBackdrop(cachedBaseFrame)
                if deviceFrameActive, sideVisible, let side = cachedDeviceSide {
                    // Side slab UNDER the bezel-bearing layer (the card
                    // shadow above it is translucent, so it still reads).
                    cardStatics = cardStatics
                        .composited(over: tiltedSide(side, videoWidth: staticLayout.videoRect.width))
                        .cropped(to: outputRect)
                }
                composited = cardStatics

                // Honor the file's color tags — the preview (AVPlayerLayer) renders
                // by tag, so the export must interpret identically or the two look
                // different. New recordings are captured and tagged sRGB (straight
                // pass-through here); older 709-tagged files get a proper 709→sRGB
                // conversion instead of a silent re-label that dulled the export.
                let sourceImage = CIImage(cvPixelBuffer: currentPixelBuffer)
                let sourceExtent = sourceImage.extent

                let (layout, transformedVideo) = compositeFrame(
                    source: sourceImage,
                    sourceSize: effectiveNaturalSize,
                    outputSize: outputSize,
                    zoom: 1.0,              // zoom applied to full canvas below
                    focalPoint: effectiveFocal,
                    settings: settings,
                    canvasScale: canvasScale,
                    precomputedLayout: staticLayout,
                    precomputedWindowMask: cachedWindowMask
                )

                var videoLayer = transformedVideo
                let activeBlurs = project.blurRegions.filter { region in
                    currentTime >= region.startTime && currentTime <= region.endTime
                }
                for blurRegion in activeBlurs {
                    videoLayer = applyRegionBlur(
                        to: videoLayer,
                        region: blurRegion,
                        containerRect: layout.videoRect,
                        at: currentTime
                    )
                }

                // ── Depth Focus: sharp inside, graduated blur outside —
                // CIMaskedVariableBlur over the SHARED FocusMath mask with
                // the SHARED intensity→sigma mapping (preview twin:
                // buildFocusPatch).
                let activeFocusRegions = project.focusRegions.filter { region in
                    currentTime >= region.startTime && currentTime <= region.endTime
                }
                for region in activeFocusRegions {
                    let vr = layout.videoRect
                    let maskKey = "\(region.rect)|\(region.style.rawValue)|\(region.angle)|\(region.falloff)|\(region.cornerRadius)|\(Int(vr.width))x\(Int(vr.height))"
                    let maskCI: CIImage?
                    if let cached = exportFocusMasks[region.id], cached.key == maskKey {
                        maskCI = cached.image
                    } else if let cg = FocusMath.maskImage(
                        regionRect: region.rect, style: region.style,
                        angleDegrees: region.angle, falloff: region.falloff,
                        cornerRadius: region.cornerRadius,
                        videoSize: vr.size
                    ) {
                        let raw = CIImage(cgImage: cg)
                        let scaled = raw.transformed(by: CGAffineTransform(
                            scaleX: vr.width / raw.extent.width,
                            y: vr.height / raw.extent.height)
                            .concatenating(CGAffineTransform(translationX: vr.minX, y: vr.minY)))
                        exportFocusMasks[region.id] = (maskKey, scaled)
                        maskCI = scaled
                    } else { maskCI = nil }
                    if let maskCI {
                        let ext = videoLayer.extent
                        let sigma = FocusMath.blurSigma(
                            intensity: region.intensity, videoSize: vr.size)
                        videoLayer = videoLayer.clampedToExtent()
                            .applyingFilter("CIMaskedVariableBlur", parameters: [
                                "inputMask": maskCI,
                                kCIInputRadiusKey: sigma,
                            ])
                            .cropped(to: ext)
                    }
                }

                // Outer frame clip — use pre-baked mask (no CGContext per frame)
                if let outerMask = cachedOuterMask,
                   let clipped = CIFilter(
                       name: "CIBlendWithMask",
                       parameters: [
                           kCIInputImageKey: videoLayer,
                           kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: layout.contentRect),
                           kCIInputMaskImageKey: outerMask
                       ]
                   )?.outputImage?.cropped(to: layout.contentRect) {
                    videoLayer = clipped
                }

                // Segment-level device framing: crop the video to the phone's
                // content rect (removes pillarbox bars) and slot the bezel
                // behind. Framing snaps at the boundary — the keynote dip
                // below hides the swap.
                var baseForVideo = cardStatics
                var activeIsland = cachedDeviceIsland
                if let assets = segmentDeviceAssets, deviceSegmentActive(currentTime) {
                    if let clipped = CIFilter(
                        name: "CIBlendWithMask",
                        parameters: [
                            kCIInputImageKey: videoLayer,
                            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: layout.contentRect),
                            kCIInputMaskImageKey: assets.screenMask
                        ]
                    )?.outputImage?.cropped(to: layout.contentRect) {
                        videoLayer = clipped
                    }

                    // Extruded side faces, offset by the tilt, sandwiched
                    // between the bezel and the card base.
                    var sideLayer: CIImage?
                    if sideVisible, let side = assets.side {
                        sideLayer = tiltedSide(side, videoWidth: assets.subRect.width)
                    }
                    // No full-rect card shadow during device segments — the
                    // bezel carries its own (matches the preview).
                    let cardBase: CIImage = cachedCardStatics != nil
                        ? CIImage(color: .clear).cropped(to: outputRect)
                        : cachedBaseFrame
                    baseForVideo = assets.bezel
                        .composited(over: sideLayer.map { $0.composited(over: cardBase) } ?? cardBase)
                        .cropped(to: CGRect(origin: .zero, size: outputSize))
                    activeIsland = assets.island
                }

                // cachedBaseFrame is the shadow + background baked to a Metal texture.
                // Compositing over it is a single GPU texture sample — no blur per frame.
                composited = videoLayer
                    .composited(over: baseForVideo)
                    .cropped(to: CGRect(origin: .zero, size: outputSize))

                // Replacement menu bar over the video's top strip (desktop
                // portions only — hidden while a device segment fills the frame).
                if let bar = cachedMenuBar, !deviceSegmentActive(currentTime) {
                    composited = bar
                        .composited(over: composited)
                        .cropped(to: CGRect(origin: .zero, size: outputSize))
                }

                // Dynamic Island pill on top of the device screen.
                if let islandCI = activeIsland {
                    composited = islandCI
                        .composited(over: composited)
                        .cropped(to: CGRect(origin: .zero, size: outputSize))
                }

                // Burn cursor before highlights so it appears behind the dim,
                // matching the editor preview layer order.
                if settings.showCursor,
                   let cursorPosition,
                   sourceExtent.width > 0,
                   sourceExtent.height > 0 {
                    if let ciCursor = cachedCursorCI {
                        composited = renderCursorCI(
                            at: currentTime,
                            cursorPosition: cursorPosition,
                            cursorEvents: cursorEvents,
                            cursorAsset: cursorAsset,
                            scaledCursorCI: ciCursor,
                            cursorCoordinateSize: resolvedCursorCoordinateSize,
                            layout: layout,
                            onto: composited,
                            outputSize: outputSize,
                            settings: settings,
                            canvasScale: canvasScale
                        )
                    } else {
                        composited = renderCursor(
                            at: currentTime,
                            cursorPosition: cursorPosition,
                            cursorEvents: cursorEvents,
                            cursorAsset: cursorAsset,
                            cursorCoordinateSize: resolvedCursorCoordinateSize,
                            layout: layout,
                            onto: composited,
                            outputSize: outputSize,
                            settings: settings,
                            canvasScale: canvasScale
                        )
                    }

                    if settings.showClickRipple {
                        composited = renderClickRipple(
                            at: currentTime,
                            cursorEvents: cursorEvents,
                            cursorCoordinateSize: resolvedCursorCoordinateSize,
                            onto: composited,
                            outputSize: outputSize,
                            layout: layout,
                            settings: settings
                        )
                    }
                }

                let activeHighlights = project.highlightRegions.filter { region in
                    currentTime >= region.startTime && currentTime <= region.endTime
                }
                for highlightRegion in activeHighlights {
                    composited = applyRegionHighlight(
                        to: composited,
                        region: highlightRegion,
                        dimRect: layout.videoRect,
                        containerRect: layout.videoRect,
                        currentTime: currentTime,
                        transitionDuration: transitionDuration
                    )
                }

                // Burn subtitles
                if settings.showSubtitles {
                    let activeSubtitle = project.subtitles.first { sub in
                        currentTime >= sub.startTime && currentTime <= sub.endTime
                    }
                    if let subtitle = activeSubtitle {
                        composited = renderSubtitle(
                            subtitle: subtitle,
                            at: currentTime,
                            onto: composited,
                            outputSize: outputSize,
                            canvasScale: canvasScale,
                            settings: settings
                        )
                    }
                }

                // Burn the shortcut-overlay pill ("⌘⇧S"). Math + pixels come
                // from KeystrokeOverlayMath / KeystrokeOverlayRenderer, shared
                // verbatim with PreviewCompositorView.renderKeystrokes.
                if !keystrokeDisplayEvents.isEmpty {
                    if let overlay = KeystrokeOverlayRenderer.image(
                        canvasSize: outputSize,
                        displayEvents: keystrokeDisplayEvents,
                        currentTime: currentTime,
                        position: settings.keystrokeOverlayPosition,
                        size: settings.keystrokeOverlaySize,
                        scale: canvasScale,
                        rasterScale: 1,
                        animation: settings.keystrokeOverlayAnimation
                    ) {
                        composited = CIImage(cgImage: overlay)
                            .composited(over: composited)
                            .cropped(to: composited.extent)
                    }
                }

                // Burn annotations
                let activeAnnotations = project.annotations.filter {
                    currentTime >= $0.startTime && currentTime <= $0.endTime
                }
                if !activeAnnotations.isEmpty {
                    composited = renderAnnotations(
                        activeAnnotations,
                        onto: composited,
                        outputSize: outputSize,
                        videoRect: staticLayout.videoRect,
                        currentTime: currentTime,
                        // Same device-frame/shape-aware radius the card clip
                        // uses, so the blackout hugs the video's corners.
                        videoCornerRadius: outerCornerRadius
                    )
                }

                // Curtain Unveil — LAST card-space overlay (topmost sublayer of
                // the preview's contentGroup), composited right before the
                // tilt/zoom warp so it rides the warp exactly like the preview.
                // Same shared math state AND the same shared rasterizer the
                // preview shows; the raster is Y-up already (the single unit→
                // raster Y flip lives inside CurtainUnveilMath.draw), so it
                // drops straight into CI's Y-up space at the video rect.
                let curtain = CurtainUnveilMath.state(
                    corner: settings.curtainUnveilCorner,
                    at: outputTime.seconds,
                    startTime: settings.curtainUnveilStart,
                    duration: settings.curtainUnveilDuration)
                if curtain.active {
                    let vr = staticLayout.videoRect
                    // Confine the curtain to the card's silhouette — SAME
                    // sources as the card clip masks (device screen rect +
                    // radius, else frameShape + the canvasScale-scaled outer
                    // radius), through the one shared CardClip mapping. The
                    // device rect is converted to the mapping's Y-DOWN local
                    // space (CI here is Y-up).
                    let deviceScreen: (rect: CGRect, cornerRadius: CGFloat)? = {
                        if let assets = segmentDeviceAssets, deviceSegmentActive(currentTime) {
                            let local = CGRect(
                                x: assets.subRect.minX - vr.minX,
                                y: vr.maxY - assets.subRect.maxY,
                                width: assets.subRect.width,
                                height: assets.subRect.height)
                            return (local, DeviceFrameLayout.screenCornerRadius(
                                forVideoSize: assets.subRect.size))
                        }
                        if deviceFrameActive {
                            return (CGRect(origin: .zero, size: vr.size),
                                    DeviceFrameLayout.screenCornerRadius(forVideoSize: vr.size))
                        }
                        return nil
                    }()
                    var frameStyle = curtainStyle
                    frameStyle.cardClip = CurtainUnveilMath.cardClip(
                        frameShape: settings.frameShape,
                        cornerRadius: outerCornerRadius,
                        cardSize: vr.size,
                        deviceScreen: deviceScreen)
                    if let cg = CurtainUnveilMath.renderImage(
                        state: curtain,
                        size: CGSize(width: vr.width.rounded(), height: vr.height.rounded()),
                        style: frameStyle) {
                        let curtainCI = CIImage(cgImage: cg, options: [.colorSpace: srgb])
                        let sx = vr.width / CGFloat(cg.width)
                        let sy = vr.height / CGFloat(cg.height)
                        composited = curtainCI
                            .transformed(by: CGAffineTransform(scaleX: sx, y: sy)
                                .concatenating(CGAffineTransform(translationX: vr.minX, y: vr.minY)))
                            .composited(over: composited)
                            .cropped(to: outputRect)
                    }
                }

                // ── Screen tilt + zoom — warp/scale the card (shadow + video
                // + overlays) as one plane, then set it over the UNTOUCHED
                // background. Matches PreviewView: tilt homography first,
                // then card-only zoom about the (tilt-projected) focal point.
                // Camera layout override: the tile is composed onto a CLEAR
                // canvas and composited BEFORE the card transform stage, so
                // tilt, zoom and the keynote dip move the camera exactly as
                // they move the card — effects apply to whatever occupies the
                // card. (The side-by-side squeeze is applied before this
                // composite, so the camera tile itself is never squeezed.)
                // The classic bubble keeps its late, canvas-level composite.
                var overrideCameraOverlay: CIImage?
                if sourceCMTime != nil, let assets = cameraStaticAssets,
                   !camLayout.isPlainBubble, camLayout.cameraOpacity > 0.001,
                   let rect = camLayout.cameraRect {
                    let cameraTargetTime = currentTime - project.cameraTimeOffset
                    let cameraSource: CIImage? = {
                        let raw: CIImage?
                        if cameraTargetTime >= 0, let camBuffer = currentCameraPixelBuffer {
                            raw = CIImage(cvPixelBuffer: camBuffer)
                        } else {
                            raw = cameraPosterCI
                        }
                        let mirrored = settings.cameraMirrored ? raw?.oriented(.upMirrored) : raw
                        return mirrored.map {
                            CameraStyleMath.adjustedImage($0, adjustments: CameraStyleMath.Adjustments(settings: settings))
                        }
                    }()
                    if let cameraSource {
                        let radius = min(
                            camLayout.cameraCornerRadius,
                            min(rect.width, rect.height) / 2
                        )
                        let mask = CIFilter(
                            name: "CIRoundedRectangleGenerator",
                            parameters: [
                                "inputExtent": CIVector(cgRect: rect),
                                kCIInputRadiusKey: max(0, radius),
                                kCIInputColorKey: CIColor.white,
                            ]
                        )?.outputImage?.cropped(to: rect)

                        let chrome = camLayout.chromeOpacity
                        let baseRect = assets.baseRect
                        let sx = baseRect.width > 0 ? rect.width / baseRect.width : 1
                        let sy = baseRect.height > 0 ? rect.height / baseRect.height : 1
                        let assetXform = CGAffineTransform(scaleX: sx, y: sy)
                            .concatenating(CGAffineTransform(
                                translationX: rect.minX - baseRect.minX * sx,
                                y: rect.minY - baseRect.minY * sy))
                        func faded(_ image: CIImage?) -> CIImage? {
                            guard chrome > 0.01, let image else { return nil }
                            return fadeImage(image.transformed(by: assetXform), alpha: chrome)
                        }
                        let cardness = 1 - chrome
                        var shadowImage = faded(assets.shadow)
                        if cardness > 0.01, settings.shadowRadius > 0, settings.shadowOpacity > 0 {
                            let slack = ceil(settings.shadowRadius * canvasScale * 2 + 24)
                            if let cardShadow = makeFrameShadow(
                                extent: rect.insetBy(dx: -slack, dy: -slack),
                                rect: rect,
                                cornerRadius: radius,
                                shadowRadius: max(0, settings.shadowRadius * canvasScale),
                                shadowOpacity: max(0, settings.shadowOpacity) * cardness
                            ) {
                                shadowImage = shadowImage.map { cardShadow.composited(over: $0) } ?? cardShadow
                            }
                        }
                        overrideCameraOverlay = compositeCamera(
                            camera: cameraSource,
                            rect: rect,
                            mask: mask,
                            stroke: faded(assets.stroke),
                            shadow: shadowImage,
                            ring: faded(assets.ring),
                            tag: faded(assets.tag),
                            opacity: settings.cameraOpacity * camLayout.cameraOpacity,
                            tiltPitch: settings.cameraTiltPitch * chrome,
                            tiltYaw: settings.cameraTiltYaw * chrome,
                            onto: CIImage(color: .clear).cropped(to: outputRect),
                            outputRect: outputRect
                        )
                    }
                }

                if cachedCardStatics != nil {
                    // Side-by-side squeeze: the CARD scales toward the leading
                    // column while the background stays put. Applied here (card
                    // over transparency) so the cursor, annotations and window
                    // mask ride along — the same seam the dip uses.
                    let layoutXform = CameraLayoutMath.cardTransform(
                        camLayout, videoRect: staticLayout.videoRect)
                    if !layoutXform.isIdentity {
                        composited = composited
                            .transformed(by: layoutXform)
                            .cropped(to: outputRect)
                    }

                    // Camera tile rides every transform from here on.
                    if let overrideCameraOverlay {
                        composited = overrideCameraOverlay
                            .composited(over: composited)
                            .cropped(to: outputRect)
                    }

                    // Keynote dip across device-segment cuts: the whole card
                    // eases down in scale + opacity through the boundary.
                    let dip = deviceBoundaryDip(currentTime)
                    if dip > 0.01 {
                        let s = DeviceSegmentDip.scale(dip)
                        let c = CGPoint(x: staticLayout.videoRect.midX, y: staticLayout.videoRect.midY)
                        let t = CGAffineTransform.identity
                            .translatedBy(x: c.x, y: c.y)
                            .scaledBy(x: s, y: s)
                            .translatedBy(x: -c.x, y: -c.y)
                        composited = fadeImage(
                            composited.transformed(by: t).cropped(to: outputRect),
                            alpha: DeviceSegmentDip.opacity(dip)
                        )
                    }

                    var parallaxAnchor = CGPoint(x: outputSize.width / 2, y: outputSize.height / 2)
                    let tilted = max(abs(cam.tiltPitch), abs(cam.tiltYaw), abs(cam.tiltRoll)) > 0.05
                    if tilted {
                        composited = applyPerspectiveTilt(
                            to: composited.cropped(to: outputRect),
                            pitchDegrees: cam.tiltPitch,
                            yawDegrees: cam.tiltYaw,
                            rollDegrees: cam.tiltRoll,
                            videoRect: staticLayout.videoRect
                        )
                    }
                    if abs(zoom - 1.0) > 0.001 {
                        let vr = staticLayout.videoRect
                        var anchor = CGPoint(
                            x: vr.minX + effectiveFocal.x * vr.width,
                            y: vr.maxY - effectiveFocal.y * vr.height   // CIImage Y=0 at bottom
                        )
                        if tilted {
                            anchor = TiltMath.projectedPoint(
                                anchor,
                                center: CGPoint(x: vr.midX, y: vr.midY),
                                pitchDegrees: cam.tiltPitch,
                                yawDegrees: cam.tiltYaw,
                                rollDegrees: cam.tiltRoll,
                                distance: TiltMath.perspectiveDistance(for: vr.size),
                                yUp: true
                            )
                        }
                        parallaxAnchor = anchor
                        if zoom < 1,
                           let lanczos = CIFilter(name: "CILanczosScaleTransform", parameters: [
                               kCIInputImageKey: composited,
                               kCIInputScaleKey: zoom,
                               kCIInputAspectRatioKey: 1,
                           ])?.outputImage {
                            // Scale-down effect: Lanczos, re-anchored to the
                            // focal point — affine minification is mush.
                            composited = lanczos
                                .transformed(by: CGAffineTransform(
                                    translationX: anchor.x * (1 - CGFloat(zoom)),
                                    y: anchor.y * (1 - CGFloat(zoom))
                                ))
                                .cropped(to: outputRect)
                        } else {
                            let t = CGAffineTransform.identity
                                .translatedBy(x: anchor.x, y: anchor.y)
                                .scaledBy(x: CGFloat(zoom), y: CGFloat(zoom))
                                .translatedBy(x: -anchor.x, y: -anchor.y)
                            composited = composited
                                .transformed(by: t)
                                .cropped(to: outputRect)
                        }
                    }
                    // Background parallax — same drift the preview applies.
                    let parallax = ZoomFocalMath.parallaxScale(
                        zoom: zoom, strength: settings.parallaxStrength)
                    var frameBackground = cachedBackground.cropped(to: outputRect)
                    if parallax > 1.001 {
                        frameBackground = frameBackground
                            .transformed(by: CGAffineTransform(translationX: parallaxAnchor.x, y: parallaxAnchor.y)
                                .scaledBy(x: parallax, y: parallax)
                                .translatedBy(x: -parallaxAnchor.x, y: -parallaxAnchor.y))
                            .cropped(to: outputRect)
                    }
                    if abs(cam.offsetX) > 0.0005 || abs(cam.offsetY) > 0.0005 {
                        // Card offset excursion — Y-down fraction flipped for
                        // CI's Y-up space; mirrors the preview's zoomGroup
                        // translation.
                        composited = composited.transformed(by: CGAffineTransform(
                            translationX: CGFloat(cam.offsetX) * outputSize.width,
                            y: -CGFloat(cam.offsetY) * outputSize.height
                        ))
                    }
                    // Intro slide — shared IntroSlideMath, Y flipped for
                    // CI's Y-up space, scaled about the canvas centre exactly
                    // like the preview's zoomGroup intro transform.
                    let intro = IntroSlideMath.state(
                        style: settings.introSlideStyle,
                        at: outputTime.seconds,
                        startTime: settings.introSlideStart,
                        duration: settings.introSlideDuration,
                        bounce: settings.introSlideBounce,
                        depth: settings.introSlideDepth,
                        speed: settings.introSlideSpeed)
                    if intro.active {
                        let cx = outputRect.midX, cy = outputRect.midY
                        composited = composited.transformed(by:
                            CGAffineTransform(
                                translationX: cx + intro.offset.x * outputSize.width,
                                y: cy - intro.offset.y * outputSize.height)
                            .scaledBy(x: intro.scale, y: intro.scale)
                            .translatedBy(x: -cx, y: -cy))
                        // Rise entrance: 3D forward tip applied OUTERMOST about
                        // the output centre — the CIPerspectiveTransform twin of
                        // the preview's CATransform3D(projectionTransform).
                        if abs(intro.pitch) > 0.01 {
                            composited = applyPerspectiveTilt(
                                to: composited,
                                pitchDegrees: intro.pitch, yawDegrees: 0, rollDegrees: 0,
                                videoRect: outputRect)
                        }
                    }
                    // Motion blur — SHARED MotionBlurMath, fed the previous
                    // and current output-frame camera samples. Applied to the
                    // card AFTER zoom/offset/intro so the blur reflects the
                    // final on-screen motion, BEFORE compositing over the
                    // background (the backdrop stays crisp, like the preview's
                    // zoomGroup layer filter).
                    if settings.motionBlur, frameIndex > 0 {
                        let prev = cameraPath[frameIndex - 1]
                        let frameDT = outputTime.seconds - outputFrameTimes[frameIndex - 1].seconds
                        let blur = MotionBlurMath.blur(
                            previous: MotionBlurMath.CameraSample(
                                zoom: prev.zoom, focalX: prev.focalX, focalY: prev.focalY,
                                offsetX: prev.offsetX, offsetY: prev.offsetY),
                            current: MotionBlurMath.CameraSample(
                                zoom: cam.zoom, focalX: cam.focalX, focalY: cam.focalY,
                                offsetX: cam.offsetX, offsetY: cam.offsetY),
                            dt: frameDT,
                            strength: settings.motionBlurStrength
                        )
                        if blur.active, let blurred = CIFilter(
                            name: "CIMotionBlur",
                            parameters: [
                                // clampedToExtent: CIMotionBlur samples past the
                                // extent — without the clamp the card edges smear
                                // dark. Crop back to the frame afterwards.
                                kCIInputImageKey: composited.clampedToExtent(),
                                kCIInputRadiusKey: blur.radius * outputSize.width,
                                // MotionBlurMath's angle is Y-down (preview
                                // space); Core Image is Y-up — negate.
                                kCIInputAngleKey: -blur.angle,
                            ]
                        )?.outputImage {
                            composited = blurred.cropped(to: outputRect)
                        }
                    }
                    composited = composited
                        .composited(over: dimmedBackdrop(frameBackground))
                        .cropped(to: outputRect)
                }

            }

            // Zoom is applied CARD-ONLY inside the card-compositing block
            // above (the background never scales) — no whole-canvas zoom.

            // ── Camera (webcam) overlay — composited *after* the canvas zoom
            // so the bubble lives in canvas space, mirroring the preview.
            //
            // ReactiveCameraLayout picks a per-frame rect that shrinks and slides
            // away from the focal point as zoom increases (Screen Studio-style).
            // The cached mask/stroke/shadow are baked once at a canonical size
            // and re-targeted with a single CIAffineTransform here, so per-frame
            // work stays cheap.
            //
            // We only composite the camera inside the visible-clip block so it
            // hides during cut/removed sections, exactly like the preview.
            //
            // Source for the camera image:
            //   1. The decoded camera frame at `currentTime − cameraTimeOffset`
            //      (kept lip-sync-correct against the audio).
            //   2. During the leading `cameraTimeOffset` gap before the camera
            //      started recording, fall back to the poster — same thing the
            //      preview shows.
            // Gate on the clip being visible (`sourceCMTime != nil`) rather than
            // on the first decoded sample — the preview shows the bubble over
            // the poster frame during the pre-first-sample gap, so must we.
            if sourceCMTime != nil, let assets = cameraStaticAssets, camLayout.cameraOpacity > 0.001, camLayout.isPlainBubble {
                let cameraTargetTime = currentTime - project.cameraTimeOffset
                let cameraSource: CIImage? = {
                    let raw: CIImage?
                    if cameraTargetTime >= 0, let camBuffer = currentCameraPixelBuffer {
                        // Honor the camera file's own color tags (same rationale
                        // as the screen source above).
                        raw = CIImage(cvPixelBuffer: camBuffer)
                    } else {
                        raw = cameraPosterCI
                    }
                    // Mirror to match the preview's mirrored bubble.
                    let mirrored = settings.cameraMirrored ? raw?.oriented(.upMirrored) : raw
                    // Color adjustments + filter preset — the SAME shared
                    // CameraStyleMath pipeline the preview's frame driver
                    // runs, applied BEFORE mask/stroke.
                    return mirrored.map {
                        CameraStyleMath.adjustedImage($0, adjustments: CameraStyleMath.Adjustments(settings: settings))
                    }
                }()
                if let cameraSource {
                    // Plain bubble — the untouched original path, byte-for-byte.
                    let dynRect = bubbleRectNow
                    let baseRect = assets.baseRect
                    let sx = baseRect.width > 0 ? dynRect.width / baseRect.width : 1
                    let sy = baseRect.height > 0 ? dynRect.height / baseRect.height : 1
                    let tx = dynRect.minX - baseRect.minX * sx
                    let ty = dynRect.minY - baseRect.minY * sy
                    let assetXform = CGAffineTransform(scaleX: sx, y: sy)
                        .concatenating(CGAffineTransform(translationX: tx, y: ty))
                    composited = compositeCamera(
                        camera: cameraSource,
                        rect: dynRect,
                        mask: assets.mask?.transformed(by: assetXform),
                        stroke: assets.stroke?.transformed(by: assetXform),
                        shadow: assets.shadow?.transformed(by: assetXform),
                        ring: assets.ring?.transformed(by: assetXform),
                        tag: assets.tag?.transformed(by: assetXform),
                        opacity: settings.cameraOpacity,
                        tiltPitch: settings.cameraTiltPitch,
                        tiltYaw: settings.cameraTiltYaw,
                        onto: composited,
                        outputRect: outputRect
                    )
                }
            }

            // Brand watermark — topmost, matching the preview overlay order.
            if let watermarkStatic {
                composited = watermarkStatic.composited(over: composited)
            }

            // ── Pipelined GPU render + writer append ──────────────────────────
            // We submit per-frame work as Tasks and keep up to `pipelineDepth`
            // in flight. The main loop stays sequential for reader advancement
            // and CIImage graph construction; each task does the GPU encode
            // (Metal) and the PTS-ordered append (via the serial appender).
            //
            // This overlaps three stages that were previously serial:
            //   1. CPU graph build for frame N+1
            //   2. GPU Metal render of frame N
            //   3. VideoToolbox HEVC encode + writer append of frame N-1
            //
            // Works the same on Apple Silicon (Media Engine encoder) and Intel
            // (Quick Sync / T2). The non-Metal fallback path is preserved.
            // A dead writer or missing buffer pool means every subsequent frame
            // would be silently skipped — fail the export instead.
            guard writer.status == .writing else {
                for task in frameTasks { await task.value }
                throw ExportError.writeFailed(Self.detailedWriterError(writer, context: "mid-export"))
            }
            guard let pool = pixelBufferAdaptor.pixelBufferPool else {
                for task in frameTasks { await task.value }
                throw ExportError.writeFailed("Pixel buffer pool unavailable")
            }
            var outputBufferRef: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputBufferRef)
            guard let outputBuffer = outputBufferRef else { continue }

            // Snapshot per-frame state by value so the deferred task captures
            // a stable view (the main loop will mutate `composited` etc. for
            // subsequent frames before this task runs).
            let frameComposited = composited
            let frameOutputTime = outputTime
            let frameOutputBuffer = outputBuffer
            let frameAppendIndex = appendIndex
            appendIndex += 1

            // Backpressure: keep the inflight window bounded.
            if frameTasks.count >= pipelineDepth {
                await frameTasks.removeFirst().value
            }

            let task = Task<Void, Never> { [weak self] in
                _ = self
                // ── GPU render ──
                if !useBGRAOutput {
                    // NV12 destination. Attachments steer CoreImage's (and any
                    // downstream reader's) RGB→YCbCr conversion to the exact
                    // matrix/primaries the writer tags the file with — the
                    // same conversion VideoToolbox ran internally on BGRA.
                    CVBufferSetAttachment(
                        frameOutputBuffer, kCVImageBufferColorPrimariesKey,
                        sourceIsP3 ? kCVImageBufferColorPrimaries_P3_D65
                                   : kCVImageBufferColorPrimaries_ITU_R_709_2,
                        .shouldPropagate)
                    CVBufferSetAttachment(
                        frameOutputBuffer, kCVImageBufferTransferFunctionKey,
                        kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
                    CVBufferSetAttachment(
                        frameOutputBuffer, kCVImageBufferYCbCrMatrixKey,
                        kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
                    let dest = CIRenderDestination(pixelBuffer: frameOutputBuffer)
                    dest.colorSpace = renderSpace
                    if let renderTask = try? exportCIContext.startTask(
                        toRender: frameComposited, to: dest
                    ) {
                        // CIRenderTask has no completion callback; waiting
                        // inline would block a cooperative-pool thread and
                        // starve the pipeline (measured: 100→78 fps). Park
                        // the wait on GCD instead.
                        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                            DispatchQueue.global(qos: .userInitiated).async {
                                _ = try? renderTask.waitUntilCompleted()
                                cont.resume()
                            }
                        }
                    } else {
                        // Task submission failed (GPU pressure) — direct render.
                        exportCIContext.render(frameComposited, to: frameOutputBuffer,
                                               bounds: frameComposited.extent, colorSpace: renderSpace)
                    }
                } else if let queue = exportCommandQueue, let cache = exportTextureCache {
                    var cvTex: CVMetalTexture?
                    let texStatus = CVMetalTextureCacheCreateTextureFromImage(
                        kCFAllocatorDefault, cache, frameOutputBuffer, nil,
                        .bgra8Unorm, outputWidth, outputHeight, 0, &cvTex
                    )
                    if texStatus == kCVReturnSuccess,
                       let cvTex,
                       let mtlTex = CVMetalTextureGetTexture(cvTex) {
                        // CIImage origin is bottom-left; MTLTexture is top-left.
                        let h = frameComposited.extent.height
                        let flipped = frameComposited.transformed(by:
                            CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -h))
                        if let cmd = queue.makeCommandBuffer() {
                            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                                exportCIContext.render(flipped, to: mtlTex, commandBuffer: cmd,
                                                       bounds: flipped.extent, colorSpace: renderSpace)
                                cmd.addCompletedHandler { _ in cont.resume() }
                                cmd.commit()
                            }
                        } else {
                            // Command-buffer allocation can fail under GPU pressure —
                            // fall back to a direct CPU-driven render for this frame.
                            exportCIContext.render(frameComposited, to: frameOutputBuffer,
                                                   bounds: frameComposited.extent, colorSpace: renderSpace)
                        }
                    } else {
                        // Fallback: texture cache miss → direct render to CVPixelBuffer
                        exportCIContext.render(frameComposited, to: frameOutputBuffer,
                                               bounds: frameComposited.extent, colorSpace: renderSpace)
                    }
                } else {
                    // Fallback: no Metal device (very old Intel Mac).
                    exportCIContext.render(frameComposited, to: frameOutputBuffer,
                                           bounds: frameComposited.extent, colorSpace: renderSpace)
                }

                // ── Serial, PTS-ordered append with backpressure ──
                await appender.append(
                    buffer: frameOutputBuffer,
                    at: frameOutputTime,
                    index: frameAppendIndex,
                    input: videoWriterInput,
                    adaptor: pixelBufferAdaptor,
                    writer: writer
                )
            }
            frameTasks.append(task)

            // Progress is observed by a UI bar (and HeadlessRunner's 200 ms
            // poller) — a main-actor hop EVERY frame serialized the encode
            // loop against whatever the main thread was doing. ~10 Hz is
            // indistinguishable on screen and never blocks the loop.
            let p = Double(frameIndex + 1) / Double(outputFrameTimes.count)
            let progressElapsed = CMTimeGetSeconds(CMTimeSubtract(
                CMClockGetTime(CMClockGetHostTimeClock()), lastProgressHostTime))
            if progressElapsed >= 0.1 || frameIndex + 1 == outputFrameTimes.count {
                lastProgressHostTime = CMClockGetTime(CMClockGetHostTimeClock())
                // max(): detached hops are unordered — progress never regresses.
                Task { @MainActor in self.progress = max(self.progress, p) }
            }

            // Periodic FPS log so we can see real-time throughput without
            // waiting for the export to finish. First log at ~2 s, then every
            // 2 s afterwards.
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            let logElapsed = CMTimeGetSeconds(CMTimeSubtract(now, lastLogHostTime))
            if logElapsed >= 2.0 {
                let totalElapsed = CMTimeGetSeconds(CMTimeSubtract(now, exportStartHostTime))
                let recentFps = Double(frameIndex - lastLogFrameIndex) / logElapsed
                FileHandle.standardOutput.write(
                    Data(String(format: "[Export] %.0f%% — frame %d/%d, %.1f fps recent, %.0fs elapsed, eta %.0fs\n",
                                p * 100, frameIndex + 1, outputFrameTimes.count, recentFps, totalElapsed,
                                Double(outputFrameTimes.count - frameIndex - 1) / max(0.1, recentFps)).utf8)
                )
                lastLogHostTime = now
                lastLogFrameIndex = frameIndex
            }
        }

        // Drain any remaining frames before marking the input finished.
        for task in frameTasks { await task.value }
        frameTasks.removeAll()
        videoWriterInput.markAsFinished()

        // Pin the session end to the exact timeline length. Without this the
        // LAST sample's duration is inferred from the previous PTS delta —
        // harmless when appends are dense, but static-span collapse can leave
        // a long delta right before the final frame and the file would run
        // long by that amount.
        writer.endSession(atSourceTime: CMTime(seconds: totalSeconds, preferredTimescale: 600))

        // Wait for audio to finish before finalizing — a failed audio append
        // must fail the export, not silently truncate the soundtrack.
        try await audioTask?.value

        await writer.finishWriting()

        if writer.status == .failed {
            throw ExportError.writeFailed(Self.detailedWriterError(writer, context: "finish"))
        }

        let exportEndHostTime = CMClockGetTime(CMClockGetHostTimeClock())
        let wallClock = CMTimeGetSeconds(CMTimeSubtract(exportEndHostTime, exportStartHostTime))
        let frameCount = outputFrameTimes.count
        let fpsOut = Double(frameCount) / max(0.001, wallClock)
        FileHandle.standardOutput.write(
            Data(String(format: "[Export] done — %.1fs wall clock for %d frames @ %d×%d %dfps (%.1f fps encoded, %.2f× realtime, %d static frames collapsed)\n",
                        wallClock, frameCount, outputWidth, outputHeight, exportSettings.fps,
                        fpsOut, totalSeconds / max(0.001, wallClock), collapsedFrameCount).utf8)
        )

        progress = 1.0
    }


    private struct FrameLayout {
        let contentRect: CGRect
        let videoRect: CGRect
        let videoScale: CGFloat
    }

    private func frameLayout(
        sourceSize: CGSize,
        outputSize: CGSize,
        settings: ProjectSettings,
        canvasScale: CGFloat = 1
    ) -> FrameLayout {
        // Clamp so heavy padding can never collapse the video to a sliver —
        // at most 35% of the smaller canvas dimension per side (matches the
        // preview's clamp).
        let requested = max(0, settings.backgroundPadding * canvasScale)
        let padding = min(requested, min(outputSize.width, outputSize.height) * 0.35)
        let contentWidth = max(1, outputSize.width - padding * 2)
        let contentHeight = max(1, outputSize.height - padding * 2)
        // Placement redistributes HALF of each axis' padding so the card
        // visibly travels even along an axis the video fills, while keeping
        // at least half the padding as a gap on the near edges (matches the
        // preview's placementPaddingInsets; fractions here are Y-up).
        let alignment = alignmentFractions(for: settings)
        let contentRect = CGRect(
            x: padding * (0.5 + alignment.x),
            y: padding * (0.5 + alignment.y),
            width: contentWidth,
            height: contentHeight
        )

        let sourceWidth = max(1, sourceSize.width)
        let sourceHeight = max(1, sourceSize.height)
        let videoScale = min(contentRect.width / sourceWidth, contentRect.height / sourceHeight)

        let videoWidth = sourceWidth * videoScale
        let videoHeight = sourceHeight * videoScale

        var videoX = contentRect.minX + (contentRect.width - videoWidth) * alignment.x
        var videoY = contentRect.minY + (contentRect.height - videoHeight) * alignment.y
        // Freeform placement: centre-fraction over the whole canvas (may hang
        // off the edges) — the same PlacementMath.customOrigin the preview
        // uses, computed in its Y-down space and flipped once for this Y-up
        // function.
        if PlacementMath.isCustom(settings) {
            let f = PlacementMath.alignment(for: settings) // Y-down fractions
            let origin = PlacementMath.customOrigin(
                fraction: f,
                canvas: outputSize,
                video: CGSize(width: videoWidth, height: videoHeight)
            )
            videoX = origin.x
            videoY = outputSize.height - origin.y - videoHeight
        }
        let videoRect = CGRect(x: videoX, y: videoY, width: videoWidth, height: videoHeight)

        return FrameLayout(
            contentRect: contentRect,
            videoRect: videoRect,
            videoScale: videoScale
        )
    }

    private func exportFrameTimes(duration: TimeInterval, fps: Int, startOffset: TimeInterval = 0) -> [CMTime] {
        let safeFPS = max(1, fps)
        let timescale: Int32 = 600
        let totalFrames = max(1, Int(ceil(max(0, duration) * Double(safeFPS))))
        return (0..<totalFrames).map { index in
            let seconds = (Double(index) / Double(safeFPS)) + startOffset
            return CMTime(seconds: seconds, preferredTimescale: timescale)
        }
    }

    private func zoomAnchorPoint(focalPoint: CGPoint, videoRect: CGRect) -> CGPoint {
        let clampedX = max(0, min(1, focalPoint.x))
        let clampedY = max(0, min(1, focalPoint.y))
        return CGPoint(
            x: videoRect.minX + clampedX * videoRect.width,
            y: videoRect.maxY - clampedY * videoRect.height
        )
    }

    private func alignmentFractions(for settings: ProjectSettings) -> (x: CGFloat, y: CGFloat) {
        // PlacementMath is the single source (including the freeform
        // drag-anywhere override); its fractions are Y-DOWN like the preview,
        // and this function's callers work Y-UP — flip here, exactly once.
        let f = PlacementMath.alignment(for: settings)
        return (f.x, 1 - f.y)
    }

    private func compositeFrame(
        source: CIImage,
        sourceSize: CGSize,
        outputSize: CGSize,
        zoom: Double,
        focalPoint: CGPoint,
        settings: ProjectSettings,
        canvasScale: CGFloat = 1,
        precomputedLayout: FrameLayout? = nil,
        precomputedWindowMask: CIImage? = nil
    ) -> (layout: FrameLayout, image: CIImage) {
        let sourceExtent = source.extent
        // Use the pre-computed layout when available — skips frameLayout() recomputation
        let layout = precomputedLayout ?? frameLayout(
            sourceSize: sourceSize,
            outputSize: outputSize,
            settings: settings,
            canvasScale: canvasScale
        )
        let anchor = zoomAnchorPoint(focalPoint: focalPoint, videoRect: layout.videoRect)
        let safeZoom = max(zoom, 0.01)

        // Downscales go through Lanczos: a Retina window recording fitted to a
        // small card (and any scale-down effect on top) can decimate 3–4× —
        // plain affine sampling turns text to mush at that ratio. Lanczos
        // keeps it crystal; upscales keep the cheap affine (Lanczos only
        // helps shrinking).
        let atOrigin = source
            .transformed(by: CGAffineTransform(translationX: -sourceExtent.origin.x, y: -sourceExtent.origin.y))
        let fitted: CIImage
        if layout.videoScale < 0.999,
           let lanczos = CIFilter(name: "CILanczosScaleTransform", parameters: [
               kCIInputImageKey: atOrigin,
               kCIInputScaleKey: layout.videoScale,
               kCIInputAspectRatioKey: 1,
           ])?.outputImage {
            fitted = lanczos
        } else {
            fitted = atOrigin.transformed(by: CGAffineTransform(scaleX: layout.videoScale, y: layout.videoScale))
        }
        var transformed = fitted
            .transformed(by: CGAffineTransform(translationX: layout.videoRect.minX, y: layout.videoRect.minY))
            // Bottom-left aligned: with the Hidden-menu-bar crop the source is
            // taller than the layout rect and the excess (the menu bar strip)
            // spills above — cropping to the video rect removes it.
            .cropped(to: layout.videoRect)

        if abs(safeZoom - 1) > .ulpOfOne {
            if safeZoom < 1,
               let lanczos = CIFilter(name: "CILanczosScaleTransform", parameters: [
                   kCIInputImageKey: transformed,
                   kCIInputScaleKey: safeZoom,
                   kCIInputAspectRatioKey: 1,
               ])?.outputImage {
                // Lanczos scales about the ORIGIN; re-anchor to the focal
                // point with a plain translate (exactly equivalent to the
                // affine anchor sandwich, minus the mushy sampling).
                transformed = lanczos.transformed(by: CGAffineTransform(
                    translationX: anchor.x * (1 - safeZoom),
                    y: anchor.y * (1 - safeZoom)
                ))
            } else {
                var zoomTransform = CGAffineTransform.identity
                zoomTransform = zoomTransform.translatedBy(x: anchor.x, y: anchor.y)
                zoomTransform = zoomTransform.scaledBy(x: safeZoom, y: safeZoom)
                zoomTransform = zoomTransform.translatedBy(x: -anchor.x, y: -anchor.y)
                transformed = transformed.transformed(by: zoomTransform)
            }
        }

        transformed = transformed.cropped(to: layout.contentRect)

        // Use pre-computed window mask when available — avoids CGContext alloc per frame
        let windowMask: CIImage?
        if let pre = precomputedWindowMask {
            windowMask = pre
        } else {
            let r = max(0, settings.windowCornerRadius * canvasScale)
            windowMask = r > 0 ? roundedRectangleMaskImage(
                extent: layout.contentRect,
                rect: layout.videoRect,
                cornerRadius: r,
                inverted: false
            ) : nil
        }

        if let mask = windowMask,
           let masked = CIFilter(
               name: "CIBlendWithMask",
               parameters: [
                   kCIInputImageKey: transformed,
                   kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: layout.contentRect),
                   kCIInputMaskImageKey: mask
               ]
           )?.outputImage?.cropped(to: layout.contentRect) {
            transformed = masked
        }

        return (layout, transformed)
    }

    private func applyRegionBlur(
        to image: CIImage,
        region: BlurRegion,
        containerRect: CGRect,
        at currentTime: TimeInterval
    ) -> CIImage {
        let pixelRect = region.rectInImageSpace(in: containerRect)
        guard pixelRect.width > 0, pixelRect.height > 0 else {
            return image
        }

        let blurredImage: CIImage
        switch region.style {
        case .blur:
            let blurRadius = region.blurRadius(in: containerRect.size)
            guard let out = CIFilter(
                name: "CIGaussianBlur",
                parameters: [
                    kCIInputImageKey: image.clampedToExtent(),
                    kCIInputRadiusKey: blurRadius
                ]
            )?.outputImage?.cropped(to: image.extent) else {
                return image
            }
            blurredImage = out
        case .pixelate:
            // Mosaic censor look — SHARED BlurStyleMath block size and
            // per-step grid jitter, grid anchored to the region's origin
            // (pixelRect is already CI Y-up here).
            let block = BlurStyleMath.pixelScale(
                strength: region.intensity, regionSize: pixelRect.size)
            let jitter = BlurStyleMath.gridJitter(
                at: currentTime, animated: region.animated, blockSize: block)
            guard let out = CIFilter(
                name: "CIPixellate",
                parameters: [
                    kCIInputImageKey: image.clampedToExtent(),
                    kCIInputScaleKey: block,
                    kCIInputCenterKey: CIVector(
                        x: pixelRect.minX + jitter.x, y: pixelRect.minY + jitter.y)
                ]
            )?.outputImage?.cropped(to: image.extent) else {
                return image
            }
            blurredImage = out
        }

        let hardMask = CIImage(color: .white)
            .cropped(to: pixelRect)
            .composited(over: CIImage(color: .clear).cropped(to: image.extent))

        // Feathered edge, parity with PreviewView.blurPreviewLayers: the mask
        // rect stays exactly the user's rect and the MASK is blurred, so the
        // falloff straddles the boundary (≈0.5 on the edge, half in / half out)
        // rather than growing the blurred area.
        //
        // CIGaussianBlur's inputRadius IS the Gaussian sigma, while SwiftUI's
        // .blur(radius:) is a blur extent of roughly 2σ — the same relationship
        // the shadow parity fix uses above (`shadowRadius / 2`). `featherSigma`
        // is therefore the preview's feather radius halved.
        //
        // Clamping before the blur keeps a region flush against the frame edge
        // from fading away there — only the interior boundary should feather.
        let featherSigma = region.featherSigma(in: containerRect.size)
        var regionMask = hardMask
        if featherSigma > 0.01,
           let featheredMask = CIFilter(
               name: "CIGaussianBlur",
               parameters: [
                   kCIInputImageKey: hardMask.clampedToExtent(),
                   kCIInputRadiusKey: featherSigma
               ]
           )?.outputImage?.cropped(to: image.extent) {
            regionMask = featheredMask
        }

        guard let maskedBlur = CIFilter(
            name: "CIBlendWithMask",
            parameters: [
                kCIInputImageKey: blurredImage,
                kCIInputBackgroundImageKey: image,
                kCIInputMaskImageKey: regionMask
            ]
        )?.outputImage?.cropped(to: image.extent) else {
            return image
        }

        return maskedBlur
    }

    private func applyRegionHighlight(
        to image: CIImage,
        region: HighlightRegion,
        dimRect: CGRect,
        containerRect: CGRect,
        currentTime: TimeInterval,
        transitionDuration: Double
    ) -> CIImage {
        let pixelRect = region.rectInImageSpace(in: containerRect)
        guard pixelRect.width > 0, pixelRect.height > 0 else {
            return image
        }
        let cornerRadius = region.cornerRadius(in: containerRect)

        let envelope = Easing.regionEnvelope(
            at: currentTime,
            startTime: region.startTime,
            endTime: region.endTime,
            transitionDuration: transitionDuration
        )
        guard envelope > 0 else {
            return image
        }

        // Gamma-correct opacity to match SwiftUI's sRGB-space blending.
        // Core Image composites in linear light, so we convert:
        //   linear_opacity = 1 - (1 - srgb_opacity)^2.2
        let srgbOpacity = region.dimOpacity * envelope
        let linearOpacity = 1.0 - pow(1.0 - srgbOpacity, 2.2)

        HighlightRenderLogger.logExport(
            regionID: region.id,
            currentTime: currentTime,
            frameExtent: image.extent,
            dimRect: dimRect,
            videoRect: containerRect,
            highlightRect: pixelRect,
            opacity: linearOpacity
        )

        guard
            let highlightMask = highlightOutsideMaskImage(
                extent: image.extent,
                dimRect: dimRect,
                holeRect: pixelRect,
                cornerRadius: cornerRadius
            )
        else {
            return image
        }

        let darkOverlay = CIImage(
            color: CIColor(red: 0, green: 0, blue: 0, alpha: CGFloat(linearOpacity))
        )
        .cropped(to: image.extent)

        guard let outsideDarkening = CIFilter(
            name: "CIBlendWithMask",
            parameters: [
                kCIInputImageKey: darkOverlay,
                kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: image.extent),
                kCIInputMaskImageKey: highlightMask
            ]
        )?.outputImage?.cropped(to: image.extent) else {
            return image
        }

        guard let composited = CIFilter(
            name: "CISourceOverCompositing",
            parameters: [
                kCIInputImageKey: outsideDarkening,
                kCIInputBackgroundImageKey: image
            ]
        )?.outputImage?.cropped(to: image.extent) else {
            return image
        }

        return composited
    }

    private func highlightOutsideMaskImage(
        extent: CGRect,
        dimRect: CGRect,
        holeRect: CGRect,
        cornerRadius: CGFloat
    ) -> CIImage? {
        let width = Int(ceil(extent.width))
        let height = Int(ceil(extent.height))
        guard width > 0, height > 0 else { return nil }

        // Rects are stable while the highlight is settled and quantize cleanly
        // while it animates — round to a tenth of a pixel for the cache key.
        let key = String(
            format: "%.1f,%.1f,%.1f,%.1f|%.1f,%.1f,%.1f,%.1f|%.1f,%.1f,%.1f,%.1f|%.1f",
            extent.minX, extent.minY, extent.width, extent.height,
            dimRect.minX, dimRect.minY, dimRect.width, dimRect.height,
            holeRect.minX, holeRect.minY, holeRect.width, holeRect.height,
            cornerRadius
        )
        if let cached = cachedHighlightMasks[key] { return cached }

        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return nil
        }

        context.clear(CGRect(origin: .zero, size: CGSize(width: width, height: height)))

        let adjustedDimRect = CGRect(
            x: dimRect.minX - extent.minX,
            y: dimRect.minY - extent.minY,
            width: dimRect.width,
            height: dimRect.height
        )
        context.setFillColor(NSColor.white.cgColor)
        context.fill(adjustedDimRect)

        let adjustedHoleRect = CGRect(
            x: holeRect.minX - extent.minX,
            y: holeRect.minY - extent.minY,
            width: holeRect.width,
            height: holeRect.height
        )
        let holePath = CGPath(
            roundedRect: adjustedHoleRect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        context.addPath(holePath)
        context.setFillColor(NSColor.black.cgColor)
        context.fillPath()

        guard let cgImage = context.makeImage() else { return nil }
        let mask = CIImage(cgImage: cgImage)
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
        // Bounded: an animating hole sweeps a finite set of quantized rects.
        if cachedHighlightMasks.count > 64 { cachedHighlightMasks.removeAll() }
        cachedHighlightMasks[key] = mask
        return mask
    }

    private func frameShapeCGPath(
        rect: CGRect,
        cornerRadius: CGFloat,
        frameShape: ProjectSettings.FrameShape
    ) -> CGPath {
        switch frameShape {
        case .rectangle:
            return CGPath(rect: rect, transform: nil)
        case .roundedRect:
            return CGPath(
                roundedRect: rect,
                cornerWidth: cornerRadius,
                cornerHeight: cornerRadius,
                transform: nil
            )
        case .squircle:
            // Shared with the device bezel so screen + frame corners match.
            return DeviceFrameLayout.continuousRoundedPath(
                rect: rect,
                cornerRadius: cornerRadius
            )
        }
    }

    private func roundedRectangleMaskImage(
        extent: CGRect,
        rect: CGRect,
        cornerRadius: CGFloat,
        inverted: Bool,
        frameShape: ProjectSettings.FrameShape = .roundedRect
    ) -> CIImage? {
        let width = Int(ceil(extent.width))
        let height = Int(ceil(extent.height))
        guard width > 0, height > 0 else { return nil }

        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return nil
        }

        let baseColor: NSColor = inverted ? .white : .black
        let cutoutColor: NSColor = inverted ? .black : .white

        context.setFillColor(baseColor.cgColor)
        context.fill(CGRect(origin: .zero, size: CGSize(width: width, height: height)))

        let adjustedRect = CGRect(
            x: rect.minX - extent.minX,
            y: rect.minY - extent.minY,
            width: rect.width,
            height: rect.height
        )
        let path = frameShapeCGPath(
            rect: adjustedRect,
            cornerRadius: cornerRadius,
            frameShape: frameShape
        )
        context.addPath(path)
        context.setFillColor(cutoutColor.cgColor)
        context.fillPath()

        guard let cgImage = context.makeImage() else { return nil }
        // Translate so the mask aligns with extent.origin (e.g. padding offset),
        // then crop to the exact extent.
        return CIImage(cgImage: cgImage)
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
    }

    // MARK: - Camera overlay rendering

    /// Build the CGPath for the camera overlay shape inside `rect`.
    /// Mirrors PreviewView.cameraClipShapeView — circle / squircle / rounded
    /// rect (12pt radius) / square. `scale` is the canvas-points → output-px
    /// factor used by the rest of the exporter.
    private func cameraShapeCGPath(
        rect: CGRect,
        shape: ProjectSettings.CameraShape,
        cornerRadius: Double,
        scale: CGFloat
    ) -> CGPath {
        // Shared shape source of truth with the preview compositor.
        CameraStyleMath.clipPath(shape: shape, customRadius: cornerRadius, rect: rect, scale: scale)
    }

    /// Filled white-on-black mask for the camera shape — used as the alpha
    /// mask in CIBlendWithMask to clip the camera frame to its outline.
    private func cameraShapeMaskImage(
        extent: CGRect,
        rect: CGRect,
        shape: ProjectSettings.CameraShape,
        cornerRadius: Double,
        scale: CGFloat
    ) -> CIImage? {
        let width = Int(ceil(extent.width))
        let height = Int(ceil(extent.height))
        guard width > 0, height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height,
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(origin: .zero, size: CGSize(width: width, height: height)))

        let adjusted = CGRect(
            x: rect.minX - extent.minX,
            y: rect.minY - extent.minY,
            width: rect.width, height: rect.height
        )
        context.addPath(cameraShapeCGPath(rect: adjusted, shape: shape, cornerRadius: cornerRadius, scale: scale))
        context.setFillColor(NSColor.white.cgColor)
        context.fillPath()

        guard let cgImage = context.makeImage() else { return nil }
        return CIImage(cgImage: cgImage)
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
    }

    /// White, 30%-alpha stroke around the camera shape, ready to composite
    /// over the masked camera frame.
    private func cameraShapeStrokeImage(
        extent: CGRect,
        rect: CGRect,
        shape: ProjectSettings.CameraShape,
        cornerRadius: Double,
        scale: CGFloat,
        lineWidth: CGFloat,
        strokeColor: NSColor
    ) -> CIImage? {
        guard lineWidth > 0 else { return nil }
        let width = Int(ceil(extent.width))
        let height = Int(ceil(extent.height))
        guard width > 0, height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height,
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        context.clear(CGRect(origin: .zero, size: CGSize(width: width, height: height)))

        let adjusted = CGRect(
            x: rect.minX - extent.minX,
            y: rect.minY - extent.minY,
            width: rect.width, height: rect.height
        )
        context.addPath(cameraShapeCGPath(rect: adjusted, shape: shape, cornerRadius: cornerRadius, scale: scale))
        let srgbStroke = strokeColor.usingColorSpace(.sRGB) ?? strokeColor
        context.setStrokeColor(srgbStroke.cgColor)
        context.setLineWidth(lineWidth)
        context.strokePath()

        guard let cgImage = context.makeImage() else { return nil }
        return CIImage(cgImage: cgImage)
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
    }

    /// Soft, symmetric drop shadow under the camera shape (matches
    /// PreviewView's `.shadow(radius: 6)` — no Y offset).
    private func cameraShapeShadowImage(
        extent: CGRect,
        rect: CGRect,
        shape: ProjectSettings.CameraShape,
        cornerRadius: Double,
        scale: CGFloat,
        shadowRadius: CGFloat
    ) -> CIImage? {
        guard shadowRadius > 0,
              let mask = cameraShapeMaskImage(extent: extent, rect: rect, shape: shape, cornerRadius: cornerRadius, scale: scale)
        else { return nil }

        let shadowColor = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.45))
            .cropped(to: extent)
        guard let shaped = CIFilter(
            name: "CIBlendWithMask",
            parameters: [
                kCIInputImageKey: shadowColor,
                kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: extent),
                kCIInputMaskImageKey: mask
            ]
        )?.outputImage?.cropped(to: extent),
        let blurred = CIFilter(
            name: "CIGaussianBlur",
            parameters: [kCIInputImageKey: shaped, kCIInputRadiusKey: shadowRadius]
        )?.outputImage?.cropped(to: extent) else {
            return nil
        }
        return blurred
    }

    /// Composite the webcam frame into the canvas at the given layout —
    /// aspect-fill into the square, clip with the shape mask, then layer
    /// shadow (under) and stroke (over) and blend onto `image`.
    ///
    /// Filter work is bounded to the camera rect (or the shadow's expanded
    /// rect) so at 4K we don't waste GPU time scanning 8M pixels for a
    /// 511×511 overlay. The cached mask/stroke/shadow are baked at those
    /// same small extents.
    private func compositeCamera(
        camera: CIImage,
        rect: CGRect,
        mask: CIImage?,
        stroke: CIImage?,
        shadow: CIImage?,
        ring: CIImage? = nil,
        tag: CIImage? = nil,
        opacity: Double = 1,
        tiltPitch: Double = 0,
        tiltYaw: Double = 0,
        onto image: CIImage,
        outputRect: CGRect
    ) -> CIImage {
        // Aspect-fill the camera into the square (resizeAspectFill).
        let camExtent = camera.extent
        guard camExtent.width > 0, camExtent.height > 0 else { return image }
        let fillScale = max(rect.width / camExtent.width, rect.height / camExtent.height)
        let scaledW = camExtent.width * fillScale
        let scaledH = camExtent.height * fillScale
        let dx = rect.minX - (scaledW - rect.width) / 2 - camExtent.minX * fillScale
        let dy = rect.minY - (scaledH - rect.height) / 2 - camExtent.minY * fillScale
        let scaledCamera = camera
            .transformed(by: CGAffineTransform(scaleX: fillScale, y: fillScale))
            .transformed(by: CGAffineTransform(translationX: dx, y: dy))
            .cropped(to: rect)

        // Apply the shape mask so the camera takes the chosen outline. Bound
        // the filter to the camera rect — the background and output extents
        // are both `rect`, not the full canvas, so CoreImage only evaluates
        // pixels inside the small camera square.
        var clipped: CIImage = scaledCamera
        if let mask {
            if let blended = CIFilter(
                name: "CIBlendWithMask",
                parameters: [
                    kCIInputImageKey: scaledCamera,
                    kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: rect),
                    kCIInputMaskImageKey: mask
                ]
            )?.outputImage?.cropped(to: rect) {
                clipped = blended
            }
        }

        // Layer order matches the preview: shadow under, then masked camera,
        // ring light inside the clip, stroke, and the name tag on top. The
        // stack is composed over TRANSPARENT first so the whole-bubble
        // opacity fades it as one group (CALayer group-opacity semantics),
        // then blended onto the frame. Each `.composited(over:)` is lazy —
        // we only crop to outputRect at the very end so the lazy graph can
        // keep the small extents propagated through Core Image's tile planner.
        var overlay: CIImage = shadow ?? CIImage.empty()
        if let ring {
            // Outer ring-light glow: above the shadow, below the clipped
            // video — same stacking as the preview's layer order.
            overlay = ring.composited(over: overlay)
        }
        overlay = clipped.composited(over: overlay)
        if let stroke {
            overlay = stroke.composited(over: overlay)
        }
        if let tag {
            overlay = tag.composited(over: overlay)
        }
        // 3D bubble tilt — same TiltMath projection as the preview's
        // CATransform3D on the camera group, anchored at the bubble centre.
        if abs(tiltPitch) > 0.01 || abs(tiltYaw) > 0.01 {
            overlay = applyPerspectiveTilt(
                to: overlay,
                pitchDegrees: tiltPitch,
                yawDegrees: tiltYaw,
                rollDegrees: 0,
                videoRect: rect
            )
        }
        if opacity < 1 {
            overlay = fadeImage(overlay, alpha: opacity)
        }
        return overlay.composited(over: image).cropped(to: outputRect)
    }

    /// Uniformly scales an image's premultiplied RGBA by `alpha` — a fade
    /// that matches SwiftUI's opacity transitions.
    private func fadeImage(_ image: CIImage, alpha: Double) -> CIImage {
        let a = CGFloat(min(1, max(0, alpha)))
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: a, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: a, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: a, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: a),
        ])
    }

    private func makeFrameShadow(
        extent: CGRect,
        rect: CGRect,
        cornerRadius: CGFloat,
        shadowRadius: CGFloat,
        shadowOpacity: CGFloat,
        frameShape: ProjectSettings.FrameShape = .roundedRect
    ) -> CIImage? {
        guard shadowRadius > 0, shadowOpacity > 0 else { return nil }
        guard let mask = roundedRectangleMaskImage(
            extent: extent,
            rect: rect,
            cornerRadius: cornerRadius,
            inverted: false,
            frameShape: frameShape
        ) else {
            return nil
        }

        let shadowColor = CIImage(
            color: CIColor(red: 0, green: 0, blue: 0, alpha: shadowOpacity * 0.45)
        ).cropped(to: extent)

        guard let shapedShadow = CIFilter(
            name: "CIBlendWithMask",
            parameters: [
                kCIInputImageKey: shadowColor,
                kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: extent),
                kCIInputMaskImageKey: mask
            ]
        )?.outputImage?.cropped(to: extent),
        let blurred = CIFilter(
            name: "CIGaussianBlur",
            parameters: [
                kCIInputImageKey: shapedShadow,
                // CIGaussianBlur's radius is a sigma; SwiftUI's .shadow radius
                // is a blur extent (~2σ). Halve so export matches preview 1:1.
                kCIInputRadiusKey: shadowRadius / 2
            ]
        )?.outputImage?.cropped(to: extent) else {
            return nil
        }

        let offsetY = -(shadowRadius / 3)
        return blurred
            .transformed(by: CGAffineTransform(translationX: 0, y: offsetY))
            .cropped(to: extent)
    }

    private func shouldHideCursor(
        at currentTime: TimeInterval,
        cursorEvents: [CursorEvent],
        settings: ProjectSettings
    ) -> Bool {
        if !settings.autoHideCursor { return false }
        guard cursorEvents.count > 1 else { return false }

        let recentEvents = cursorEvents.filter {
            $0.timestamp >= currentTime - settings.autoHideDelay && $0.timestamp <= currentTime
        }
        guard recentEvents.count > 1,
              let first = recentEvents.first,
              let last = recentEvents.last else { return false }

        let dist = hypot(last.x - first.x, last.y - first.y)
        return dist < 5
    }

    /// Shifts every timing entry of an audio buffer earlier by `offset` —
    /// re-basing trim-ranged source reads onto the export's zero-based clock.
    nonisolated private static func shiftedAudioBuffer(
        _ buffer: CMSampleBuffer,
        by offset: CMTime
    ) -> CMSampleBuffer? {
        guard offset != .zero else { return buffer }
        var count = 0
        CMSampleBufferGetSampleTimingInfoArray(
            buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return buffer }
        var infos = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(
            buffer, entryCount: count, arrayToFill: &infos, entriesNeededOut: &count)
        for i in infos.indices {
            infos[i].presentationTimeStamp = CMTimeSubtract(infos[i].presentationTimeStamp, offset)
            if infos[i].decodeTimeStamp.isValid {
                infos[i].decodeTimeStamp = CMTimeSubtract(infos[i].decodeTimeStamp, offset)
            }
        }
        var shifted: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: buffer,
            sampleTimingEntryCount: count,
            sampleTimingArray: &infos,
            sampleBufferOut: &shifted
        )
        return shifted
    }

    private func renderClickRipple(
        at currentTime: TimeInterval,
        cursorEvents: [CursorEvent],
        cursorCoordinateSize: CGSize,
        onto image: CIImage,
        outputSize: CGSize,
        layout: FrameLayout,
        settings: ProjectSettings
    ) -> CIImage {
        // Most frames have neither a live ripple nor a drag glow — skip all
        // bitmap work for them. Both predicates are the ones renderForExport
        // itself draws from, so the skip can never drop a visible frame.
        let hasRipple = !ClickRippleOverlay.activeRipples(
            cursorEvents: cursorEvents,
            currentTime: currentTime,
            coordinateSize: cursorCoordinateSize,
            videoRect: layout.videoRect
        ).isEmpty
        let dragStrength = ClickRippleOverlay.dragHighlightStrength(
            runs: ClickRippleOverlay.dragHighlightRuns(
                from: cursorEvents, coordinateSize: cursorCoordinateSize),
            at: currentTime
        )
        guard hasRipple || dragStrength > 0.01 else { return image }

        let width = Int(outputSize.width)
        let height = Int(outputSize.height)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

        // Transparent overlay holding ONLY the ripples; composited over the
        // frame on the GPU. The old path flattened the whole composited frame
        // to a CPU bitmap (with a fresh CIContext) every frame — the single
        // biggest export hotspot.
        guard let cgContext = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return image }

        // Render ripples
        let rc = settings.clickRippleColor
        let rippleColor = CGColor(red: rc.red, green: rc.green, blue: rc.blue, alpha: rc.opacity)
        ClickRippleOverlay.renderForExport(
            into: cgContext,
            cursorEvents: cursorEvents,
            currentTime: currentTime,
            videoRect: layout.videoRect,
            sourceSize: cursorCoordinateSize,
            rippleColor: rippleColor,
            rippleSize: settings.clickRippleSize
        )

        guard let outputCGImage = cgContext.makeImage() else { return image }
        return CIImage(cgImage: outputCGImage)
            .composited(over: image)
            .cropped(to: CGRect(origin: .zero, size: outputSize))
    }

    /// CIImage-based cursor renderer — avoids allocating a full-resolution CGContext
    /// every frame. Uses CIDropShadow + CIImage compositing entirely on the GPU.
    private func renderCursorCI(
        at currentTime: TimeInterval,
        cursorPosition: CGPoint,
        cursorEvents: [CursorEvent],
        cursorAsset: CursorAsset,
        scaledCursorCI: CIImage,   // pre-scaled CIImage (pass cachedCursorCI)
        cursorCoordinateSize: CGSize,
        layout: FrameLayout,
        onto image: CIImage,
        outputSize: CGSize,
        settings: ProjectSettings,
        canvasScale: CGFloat
    ) -> CIImage {
        if shouldHideCursor(at: currentTime, cursorEvents: cursorEvents, settings: settings) {
            return image
        }
        // The coordinate size arrives pre-resolved (and menu-bar-cropped) from
        // the export setup, and the layout is the SAME bezel-adjusted layout the
        // video card renders with — the preview derives its cursor from the same
        // two inputs, so the sizes cannot diverge.
        let resolvedCursorSpace = cursorCoordinateSize
        guard resolvedCursorSpace.width > 0, resolvedCursorSpace.height > 0 else { return image }

        let videoRectInViewSpace = CursorOverlayLayout.viewRect(
            from: layout.videoRect,
            canvasHeight: outputSize.height
        )
        guard let cursorLayout = CursorOverlayLayout.make(
            cursorPosition: cursorPosition,
            coordinateSize: resolvedCursorSpace,
            videoRect: videoRectInViewSpace,
            cursorSize: cursorAsset.baseSize,
            hotSpot: cursorAsset.hotSpot,
            cursorScale: settings.cursorScale
        ) else { return image }

        let drawRect = cursorLayout.imageSpaceRect(in: outputSize.height)

        // Scale from native pixel size → drawRect size (which is in canvas-point space
        // and already encodes cursorScale × cursorPointToViewScale). This handles
        // Retina cursors where pixel size = 2× point size.
        let scaleX = drawRect.width  / max(1, scaledCursorCI.extent.width)
        let scaleY = drawRect.height / max(1, scaledCursorCI.extent.height)
        var positioned = scaledCursorCI
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .transformed(by: CGAffineTransform(translationX: drawRect.minX, y: drawRect.minY))

        // Motion physics — the identical pose the preview computes, Y-flipped
        // for CIImage space, pinned to the hotspot so the tip never moves.
        let pose = CursorPhysicsMath.pose(
            events: cursorEvents,
            at: currentTime,
            coordinateSize: resolvedCursorSpace,
            videoRect: videoRectInViewSpace,
            spriteHeight: cursorLayout.imageRect.height,
            tilt: settings.cursorTilt,
            stretch: settings.cursorStretch,
            drag: settings.cursorDrag,
            weight: settings.cursorWeight
        ).yFlipped()
        if !pose.isIdentity {
            let tipCI = CGPoint(
                x: cursorLayout.hotspotPoint.x,
                y: outputSize.height - cursorLayout.hotspotPoint.y
            )
            positioned = positioned.transformed(by: CursorPhysicsMath.affineTransform(
                pose: pose,
                tip: tipCI,
                spriteHeight: drawRect.height
            ))
        }

        // Apply drop shadow — no CGContext, runs entirely on GPU.
        // CIDropShadow is a macOS 26+ filter; `CIFilter(name:)` returns nil on
        // macOS 14/15, which previously dropped the shadow silently and made
        // the export diverge from the preview's CALayer shadow. Pre-26 we
        // build the identical shadow from primitives that exist since 10.4:
        // black-tinted alpha silhouette → gaussian blur → offset → under.
        //
        // The sprite MUST carry a transparent border before the shadow: both
        // CIDropShadow and the manual clamp+blur extend the input's EDGE
        // pixels outward, so a sprite whose opaque pixels touch its extent
        // edge smears into full-width/height hairline bands across the frame
        // (export-only — the preview's CALayer shadow never clamps).
        // Shadow constants are PREVIEW-CANVAS points (the preview's CALayer
        // uses them raw); every export-side spatial value multiplies by
        // canvasScale — an unscaled radius rendered the 4K cursor shadow ~3×
        // tighter than the preview showed it.
        let shadowPad = (CursorOverlayLayout.shadowBlurRadius
            + max(abs(CursorOverlayLayout.shadowOffset.width),
                  abs(CursorOverlayLayout.shadowOffset.height))) * canvasScale + 2
        let positionedPadded = positioned.composited(
            over: CIImage(color: .clear)
                .cropped(to: positioned.extent.insetBy(dx: -shadowPad, dy: -shadowPad))
        )
        let outputBounds = CGRect(origin: .zero, size: outputSize)
        let withShadow = CIFilter(name: "CIDropShadow", parameters: [
            kCIInputImageKey: positionedPadded,
            "inputRadius": CursorOverlayLayout.shadowBlurRadius * canvasScale,
            "inputOpacity": CursorOverlayLayout.shadowOpacity,
            "inputOffset": CIVector(
                x: CursorOverlayLayout.shadowOffset.width * canvasScale,
                y: -CursorOverlayLayout.shadowOffset.height * canvasScale
            ),
            "inputColor": CIColor(red: 0, green: 0, blue: 0)
        ])?.outputImage?.cropped(to: outputBounds)
            ?? Self.manualDropShadow(over: positionedPadded, bounds: outputBounds,
                                     canvasScale: canvasScale)

        return (withShadow ?? positioned).composited(over: image)
    }

    /// Pre-macOS 26 twin of CIDropShadow for the cursor sprite. Matches the
    /// preview's CALayer shadow: CIGaussianBlur takes a *sigma* ≈ half the
    /// CG/CALayer shadow radius (see CLAUDE.md), and CI space is Y-up so the
    /// offset's Y flips — same flip CIDropShadow's inputOffset uses above.
    private static func manualDropShadow(
        over positioned: CIImage, bounds: CGRect, canvasScale: CGFloat
    ) -> CIImage? {
        let silhouette = positioned.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CursorOverlayLayout.shadowOpacity),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ])
        let blurred = silhouette
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: CursorOverlayLayout.shadowBlurRadius * canvasScale * 0.5
            ])
            .transformed(by: CGAffineTransform(
                translationX: CursorOverlayLayout.shadowOffset.width * canvasScale,
                y: -CursorOverlayLayout.shadowOffset.height * canvasScale
            ))
        return positioned.composited(over: blurred).cropped(to: bounds)
    }

    private func renderCursor(
        at currentTime: TimeInterval,
        cursorPosition: CGPoint,
        cursorEvents: [CursorEvent],
        cursorAsset: CursorAsset,
        cursorCoordinateSize: CGSize,
        layout: FrameLayout,
        onto image: CIImage,
        outputSize: CGSize,
        settings: ProjectSettings,
        canvasScale: CGFloat
    ) -> CIImage {
        if shouldHideCursor(at: currentTime, cursorEvents: cursorEvents, settings: settings) {
            return image
        }

        // Same pre-resolved coordinate space and bezel-adjusted layout as the
        // video card — see renderCursorCI.
        let resolvedCursorSpace = cursorCoordinateSize
        guard resolvedCursorSpace.width > 0, resolvedCursorSpace.height > 0 else { return image }

        let videoRectInViewSpace = CursorOverlayLayout.viewRect(
            from: layout.videoRect,
            canvasHeight: outputSize.height
        )
        guard let cursorLayout = CursorOverlayLayout.make(
            cursorPosition: cursorPosition,
            coordinateSize: resolvedCursorSpace,
            videoRect: videoRectInViewSpace,
            cursorSize: cursorAsset.baseSize,
            hotSpot: cursorAsset.hotSpot,
            cursorScale: settings.cursorScale
        ) else {
            return image
        }
        let drawRect = cursorLayout.imageSpaceRect(in: outputSize.height)

        guard let ctx = CGContext(
            data: nil,
            width: Int(outputSize.width),
            height: Int(outputSize.height),
            bitsPerComponent: 8,
            bytesPerRow: Int(outputSize.width) * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return image }

        ctx.setShadow(
            offset: CGSize(
                width: CursorOverlayLayout.shadowOffset.width * canvasScale,
                height: -CursorOverlayLayout.shadowOffset.height * canvasScale
            ),
            blur: CursorOverlayLayout.shadowBlurRadius * canvasScale,
            color: NSColor.black.withAlphaComponent(CursorOverlayLayout.shadowOpacity).cgColor
        )
        if let cursorCGImage = cursorAsset.cgImage {
            ctx.draw(cursorCGImage, in: drawRect)
        } else {
            drawFallbackCursor(in: ctx, rect: drawRect)
        }

        guard let overlayCGImage = ctx.makeImage() else { return image }
        return CIImage(cgImage: overlayCGImage).composited(over: image)
    }

    private func makeCursorAsset(
        style: ProjectSettings.CursorStyle,
        rasterScale: CGFloat
    ) -> CursorAsset {
        let asset = CursorStyleProvider.asset(for: style)
        let cursorImage = asset.image
        let imageSize = cursorImage.size
        let hotSpot = asset.hotSpot
        if imageSize.width > 0,
           imageSize.height > 0,
           let cgImage = CursorStyleProvider.rasterizedCGImage(
               for: style,
               pixelSize: CGSize(
                   width: imageSize.width * rasterScale,
                   height: imageSize.height * rasterScale
               )
           ) {
            return CursorAsset(
                cgImage: cgImage,
                baseSize: imageSize,
                hotSpot: hotSpot
            )
        }

        // Rasterization failed — keep the provider's point size and hotspot so
        // the drawn fallback still occupies exactly the preview cursor's rect.
        return CursorAsset(
            cgImage: nil,
            baseSize: imageSize.width > 0 && imageSize.height > 0
                ? imageSize : CGSize(width: 20, height: 28),
            hotSpot: hotSpot
        )
    }

    private func drawFallbackCursor(in ctx: CGContext, rect: CGRect) {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.maxY - y * rect.height)
        }

        let path = CGMutablePath()
        path.move(to: point(0.00, 0.00))
        path.addLine(to: point(0.00, 1.00))
        path.addLine(to: point(0.35, 0.72))
        path.addLine(to: point(0.55, 1.00))
        path.addLine(to: point(0.72, 0.92))
        path.addLine(to: point(0.52, 0.65))
        path.addLine(to: point(1.00, 0.62))
        path.closeSubpath()

        ctx.addPath(path)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()

        ctx.addPath(path)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(max(1, rect.width * 0.08))
        ctx.strokePath()
    }

    private func createBackground(size: CGSize, settings: ProjectSettings) -> CIImage {
        // SHARED BackgroundLook: the preview sets this exact bitmap as its
        // backdrop layer's contents, so gradient angle, blur, tint, vignette
        // etc. cannot drift between the two.
        BackgroundLook.ciImage(for: BackgroundLook.Spec(settings), size: size)
    }

    /// Burns the active annotations onto `image`.
    ///
    /// Drawing lives in `AnnotationRenderer`, shared verbatim with the preview
    /// compositor, so the two cannot drift — that shared renderer is what the
    /// sacred preview==export invariant now rests on for annotations.
    ///
    /// `videoRect` arrives in CoreImage's y-UP space; the renderer works
    /// y-DOWN, so it is flipped within the output rect first.
    private func renderAnnotations(
        _ annotations: [Annotation],
        onto image: CIImage,
        outputSize: CGSize,
        videoRect: CGRect,
        currentTime: TimeInterval,
        videoCornerRadius: CGFloat = 0
    ) -> CIImage {
        let videoRectYDown = CGRect(
            x: videoRect.minX,
            y: outputSize.height - videoRect.maxY,
            width: videoRect.width,
            height: videoRect.height
        )
        guard let overlay = AnnotationRenderer.image(
            size: outputSize,
            annotations: annotations,
            currentTime: currentTime,
            videoRect: videoRectYDown,
            // Annotation sizes are authored in preview canvas points; this is
            // the long-standing export convention for converting them.
            scale: outputSize.width / 1920.0 * 2,
            chrome: nil,          // handles and selection rings never export
            rasterScale: 1,
            videoCornerRadius: videoCornerRadius
        ) else { return image }

        return CIImage(cgImage: overlay).composited(over: image).cropped(to: image.extent)
    }

    private func renderSubtitle(
        subtitle: SubtitleSegment,
        at currentTime: TimeInterval,
        onto image: CIImage,
        outputSize: CGSize,
        canvasScale: CGFloat,
        settings: ProjectSettings
    ) -> CIImage {
        // The rendered overlay only changes when the segment or the karaoke
        // active-word set changes — not per frame. Reuse the previous raster
        // (full-canvas CGContext + AppKit text draw + CI blur are the cost).
        let activeWordCount = settings.highlightWords && !subtitle.words.isEmpty
            ? subtitle.words.lazy.filter { currentTime >= $0.startTime }.count
            : -1
        let cacheKey = "\(subtitle.id)|\(activeWordCount)"
        if cacheKey == cachedSubtitleKey, let overlay = cachedSubtitleOverlay {
            let extent = CGRect(origin: .zero, size: outputSize)
            return overlay.composited(over: image).cropped(to: extent)
        }

        // 1:1 with PreviewView.subtitleOverlay:
        //   • Font size = subtitleFontSize (canvas pt) × canvasScale.
        //   • Pill: 12pt horiz / 6pt vert padding, 6pt corner radius.
        //   • Edge inset: 20pt from the canvas edge.
        //   • Outline style: SwiftUI .shadow(color: .black, radius: 2) —
        //     reproduced here as a 2pt Gaussian blur of the text alpha.
        //   • Karaoke spaces inherit the same font so kerning matches.
        let fontSize = max(1, settings.subtitleFontSize * canvasScale)
        let font = FontCatalog.font(named: settings.subtitleFontName, size: fontSize, weight: settings.subtitleWeight.nsWeight)
        // Uppercase style — must transform the SAME strings the preview does.
        let transform: (String) -> String = settings.subtitleUppercase ? { $0.uppercased() } : { $0 }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        let textColor = NSColor(
            red: settings.subtitleColor.red,
            green: settings.subtitleColor.green,
            blue: settings.subtitleColor.blue,
            alpha: settings.subtitleColor.opacity
        )

        let attrString: NSAttributedString
        if settings.highlightWords && !subtitle.words.isEmpty {
            let highlightColor = NSColor(
                red: settings.subtitleHighlightColor.red,
                green: settings.subtitleHighlightColor.green,
                blue: settings.subtitleHighlightColor.blue,
                alpha: settings.subtitleHighlightColor.opacity
            )
            let dimColor = NSColor(
                red: textColor.redComponent,
                green: textColor.greenComponent,
                blue: textColor.blueComponent,
                alpha: textColor.alphaComponent * 0.4
            )
            let spaceAttrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .paragraphStyle: paragraphStyle,
                .foregroundColor: textColor,
            ]
            let mutable = NSMutableAttributedString()
            for (i, word) in subtitle.words.enumerated() {
                if i > 0 {
                    mutable.append(NSAttributedString(string: " ", attributes: spaceAttrs))
                }
                let isActive = currentTime >= word.startTime
                let wordAttrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .paragraphStyle: paragraphStyle,
                    .foregroundColor: isActive ? highlightColor : dimColor,
                ]
                mutable.append(NSAttributedString(string: transform(word.text), attributes: wordAttrs))
            }
            attrString = mutable
        } else {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .paragraphStyle: paragraphStyle,
                .foregroundColor: textColor,
            ]
            attrString = NSAttributedString(string: transform(subtitle.text), attributes: attributes)
        }

        // Geometry — every constant matches PreviewView's modifiers.
        let pillHPad = 12 * canvasScale
        let pillVPad = 6 * canvasScale
        let pillCorner = 6 * canvasScale
        let outerEdgePad = 20 * canvasScale

        let textSize = attrString.boundingRect(
            with: CGSize(
                width: max(1, outputSize.width - 2 * (outerEdgePad + pillHPad)),
                height: .greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let bgWidth = textSize.width + pillHPad * 2
        let bgHeight = textSize.height + pillVPad * 2

        // Free placement mirrors PreviewView.subtitleOverlay exactly: the
        // origin interpolates across (canvas − 2×edgePad − pill), fractions
        // are Y-down so the Y flips for CI's Y-up space. nil = anchor enum.
        let fraction: CGPoint
        if let fx = settings.subtitleCustomX, let fy = settings.subtitleCustomY {
            fraction = CGPoint(x: min(1, max(0, fx)), y: min(1, max(0, fy)))
        } else {
            switch settings.subtitlePosition {
            case .top: fraction = CGPoint(x: 0.5, y: 0)
            case .center: fraction = CGPoint(x: 0.5, y: 0.5)
            case .bottom: fraction = CGPoint(x: 0.5, y: 1)
            }
        }
        let usableW = max(0, outputSize.width - 2 * outerEdgePad - bgWidth)
        let usableH = max(0, outputSize.height - 2 * outerEdgePad - bgHeight)
        let xPosition = outerEdgePad + fraction.x * usableW
        let yPosition = outerEdgePad + (1 - fraction.y) * usableH

        // Rasterise the (optional) pill + text into a full-canvas bitmap so we
        // can post-process it as a single CIImage (alpha shadow, blending).
        let bitmapWidth = Int(outputSize.width)
        let bitmapHeight = Int(outputSize.height)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil,
            width: bitmapWidth,
            height: bitmapHeight,
            bitsPerComponent: 8,
            bytesPerRow: bitmapWidth * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return image }

        if settings.subtitleStyle == .background {
            let bgColor = NSColor(
                red: settings.subtitleBackgroundColor.red,
                green: settings.subtitleBackgroundColor.green,
                blue: settings.subtitleBackgroundColor.blue,
                alpha: 0.75
            )
            ctx.setFillColor(bgColor.cgColor)
            let bgRect = CGRect(x: xPosition, y: yPosition, width: bgWidth, height: bgHeight)
            let bgPath = CGPath(
                roundedRect: bgRect,
                cornerWidth: pillCorner, cornerHeight: pillCorner,
                transform: nil
            )
            ctx.addPath(bgPath)
            ctx.fillPath()
        }

        let textRect = CGRect(
            x: xPosition + pillHPad,
            y: yPosition + pillVPad,
            width: textSize.width,
            height: textSize.height
        )
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.current = nsCtx
        attrString.draw(in: textRect)
        NSGraphicsContext.current = nil

        guard let cgImage = ctx.makeImage() else { return image }
        let subtitleImage = CIImage(cgImage: cgImage)

        // Outline → tight black drop shadow; Glow → wide halo in the text
        // color. Both mirror SwiftUI's `.shadow(color:radius:)` on the
        // preview (CI blur inputRadius ≈ SwiftUI radius, silhouette tinted).
        let extent = CGRect(origin: .zero, size: outputSize)
        switch settings.subtitleStyle {
        case .outline:
            if let shadow = subtitleDropShadow(source: subtitleImage, extent: extent, radius: 2 * canvasScale) {
                let layered = subtitleImage.composited(over: shadow).cropped(to: extent)
                cachedSubtitleKey = cacheKey
                cachedSubtitleOverlay = layered
                return layered.composited(over: image).cropped(to: extent)
            }
        case .glow:
            let glow = CIColor(
                red: settings.subtitleColor.red,
                green: settings.subtitleColor.green,
                blue: settings.subtitleColor.blue,
                alpha: settings.subtitleColor.opacity * 0.8
            )
            if let halo = subtitleDropShadow(source: subtitleImage, extent: extent, radius: 6 * canvasScale, color: glow) {
                let layered = subtitleImage.composited(over: halo).cropped(to: extent)
                cachedSubtitleKey = cacheKey
                cachedSubtitleOverlay = layered
                return layered.composited(over: image).cropped(to: extent)
            }
        case .background, .plain:
            break
        }
        cachedSubtitleKey = cacheKey
        cachedSubtitleOverlay = subtitleImage
        return subtitleImage.composited(over: image)
    }

    /// Soft shadow/halo for the subtitle text, matching SwiftUI's
    /// `.shadow(color:radius:)`: take the source alpha, tint it `color`
    /// (default solid black), Gaussian-blur, and composite under the source.
    private func subtitleDropShadow(
        source: CIImage,
        extent: CGRect,
        radius: CGFloat,
        color: CIColor = CIColor(red: 0, green: 0, blue: 0, alpha: 1)
    ) -> CIImage? {
        guard radius > 0 else { return nil }
        // Every output channel derives from the source ALPHA alone, so the
        // silhouette is exactly `color` where the text is and fully clear
        // elsewhere (premultiplied-correct — a bias would tint the whole frame).
        let matrix = CIFilter(name: "CIColorMatrix")
        matrix?.setValue(source, forKey: kCIInputImageKey)
        matrix?.setValue(CIVector(x: 0, y: 0, z: 0, w: color.red * color.alpha), forKey: "inputRVector")
        matrix?.setValue(CIVector(x: 0, y: 0, z: 0, w: color.green * color.alpha), forKey: "inputGVector")
        matrix?.setValue(CIVector(x: 0, y: 0, z: 0, w: color.blue * color.alpha), forKey: "inputBVector")
        matrix?.setValue(CIVector(x: 0, y: 0, z: 0, w: color.alpha), forKey: "inputAVector")
        guard let silhouette = matrix?.outputImage else { return nil }

        let blur = CIFilter(
            name: "CIGaussianBlur",
            parameters: [kCIInputImageKey: silhouette, kCIInputRadiusKey: radius]
        )
        return blur?.outputImage?.cropped(to: extent)
    }

    /// Perspective-warps `image` about the horizontal axis through the video
    /// rect's center. Mapping the extent's corners through the same pinhole
    /// projection as the preview's ProjectionTransform yields the identical
    /// homography (exact for every point, not just the corners).
    private func applyPerspectiveTilt(
        to image: CIImage,
        pitchDegrees: Double,
        yawDegrees: Double,
        rollDegrees: Double,
        videoRect: CGRect
    ) -> CIImage {
        let extent = image.extent
        let center = CGPoint(x: videoRect.midX, y: videoRect.midY)
        let distance = TiltMath.perspectiveDistance(for: videoRect.size)
        func proj(_ x: CGFloat, _ y: CGFloat) -> CIVector {
            let p = TiltMath.projectedPoint(
                CGPoint(x: x, y: y),
                center: center,
                pitchDegrees: pitchDegrees,
                yawDegrees: yawDegrees,
                rollDegrees: rollDegrees,
                distance: distance,
                yUp: true // Core Image Y=0 at bottom
            )
            return CIVector(x: p.x, y: p.y)
        }
        guard let filter = CIFilter(name: "CIPerspectiveTransform") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(proj(extent.minX, extent.maxY), forKey: "inputTopLeft")
        filter.setValue(proj(extent.maxX, extent.maxY), forKey: "inputTopRight")
        filter.setValue(proj(extent.minX, extent.minY), forKey: "inputBottomLeft")
        filter.setValue(proj(extent.maxX, extent.minY), forKey: "inputBottomRight")
        return filter.outputImage ?? image
    }

    private struct CameraKey: Equatable {
        var zoom: Double
        var focalX: Double
        var focalY: Double
        /// Card position excursion, canvas fractions, Y-down (preview space).
        var offsetX: Double = 0
        var offsetY: Double = 0
        // Final combined skew angles for the frame (mode skew + tilt regions).
        var tiltPitch: Double = 0
        var tiltYaw: Double = 0
        var tiltRoll: Double = 0
    }

    /// Writer failures surface as a bare "operation could not be completed" —
    /// include the NSError domain/code and any underlying error so headless
    /// callers can diagnose them.
    private static func detailedWriterError(_ writer: AVAssetWriter, context: String) -> String {
        guard let error = writer.error else { return "Writer stopped (\(context)), no error" }
        let ns = error as NSError
        var detail = "\(ns.localizedDescription) [\(ns.domain)#\(ns.code) \(context)]"
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            detail += " underlying=\(underlying.domain)#\(underlying.code) \(underlying.localizedDescription)"
        }
        return detail
    }

    enum ExportError: LocalizedError {
        case noVideo
        case noVideoTrack
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .noVideo: return "No video file found in project"
            case .noVideoTrack: return "No video track found in recording"
            case .writeFailed(let msg): return "Export failed: \(msg)"
            }
        }
    }
}
