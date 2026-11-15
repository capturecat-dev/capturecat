import AVFoundation

enum ProjectAudioMix {
    struct PreparedAudio {
        let asset: AVAsset
        let tracks: [AVAssetTrack]
        let audioMix: AVAudioMix?
    }

    static let readerOutputSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]

    static let writerOutputSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 192_000,
    ]

    static func prepare(
        for asset: AVAsset,
        project: Project,
        applySpeedScaling: Bool = true,
        /// Source-time click timestamps to mix as synthesized ticks (export
        /// path; the preview plays ticks live instead).
        clickTimes: [TimeInterval] = [],
        /// Source-time keystrokes to mix as synthesized key sounds (export
        /// path; the preview plays them live instead).
        keystrokes: [KeystrokeEvent] = []
    ) async throws -> PreparedAudio {
        let mixClicks = project.settings.clickSoundEnabled && !clickTimes.isEmpty
        let mixKeys = project.settings.keySoundEnabled && !keystrokes.isEmpty
        let voiceOverClips = project.voiceOverClips.filter {
            FileManager.default.fileExists(atPath: $0.resolvedURL(in: project.projectDirectory).path)
        }
        let hasSpeedRegions = applySpeedScaling && !project.speedRegions.isEmpty
        let clipSegments = project.videoClipSegments.isEmpty ? [] : project.effectiveVideoClipSegments
        let hasIndependentVideoClips = !clipSegments.isEmpty

        // Fast path: no speed changes, voice overs, or click ticks — hand
        // back the source asset.
        if voiceOverClips.isEmpty && !hasSpeedRegions && !hasIndependentVideoClips && !mixClicks && !mixKeys {
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard !tracks.isEmpty else {
                return PreparedAudio(asset: asset, tracks: [], audioMix: nil)
            }

            let parameters = tracks.enumerated().map { index, track in
                let input = AVMutableAudioMixInputParameters(track: track)
                input.setVolume(baseVolume(for: index, settings: project.settings), at: .zero)
                return input
            }

            let mix = AVMutableAudioMix()
            mix.inputParameters = parameters

            return PreparedAudio(asset: asset, tracks: tracks, audioMix: mix)
        }

        // Compose piecewise so we can scale segments that have a custom playback speed.
        let composition = AVMutableComposition()
        let compositionDuration = try await asset.load(.duration)
        let sourceDurationSeconds = compositionDuration.seconds.isFinite ? compositionDuration.seconds : project.duration
        let mapSourceStart = applySpeedScaling ? project.effectiveTrimStart : 0
        let mapSourceEnd = applySpeedScaling ? project.effectiveTrimEnd : max(0, sourceDurationSeconds)
        let timeMap = SpeedTimeMap(
            sourceStart: mapSourceStart,
            sourceEnd: mapSourceEnd,
            regions: applySpeedScaling ? project.speedRegions : []
        )
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        var parameters: [AVAudioMixInputParameters] = []

        // Video — inserted segment by segment and scaled per speed region.
        for videoTrack in videoTracks {
            guard let compositionTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }
            try insertScaledSegments(
                from: videoTrack,
                into: compositionTrack,
                timeMap: timeMap,
                clipSegments: clipSegments
            )
            compositionTrack.preferredTransform = try await videoTrack.load(.preferredTransform)
        }

        // Audio — same piecewise insertion, with volume + pitch-preserving algorithm.
        for (index, audioTrack) in audioTracks.enumerated() {
            guard let compositionTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }
            try insertScaledSegments(
                from: audioTrack,
                into: compositionTrack,
                timeMap: timeMap,
                clipSegments: clipSegments
            )
            let input = AVMutableAudioMixInputParameters(track: compositionTrack)
            input.setVolume(baseVolume(for: index, settings: project.settings), at: .zero)
            if hasSpeedRegions {
                input.audioTimePitchAlgorithm = .timeDomain
            }
            parameters.append(input)
        }

        // Voice overs anchor to source-time on the timeline; convert to output-time
        // so they play at the moment the user placed them.
        for clip in voiceOverClips {
            let clipURL = clip.resolvedURL(in: project.projectDirectory)
            let clipAsset = AVURLAsset(url: clipURL)
            guard let clipTrack = try await clipAsset.loadTracks(withMediaType: .audio).first,
                  let compositionTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                  ) else {
                continue
            }

            let clipAssetDuration = try await clipAsset.load(.duration)
            let measuredSourceDuration = clipAssetDuration.seconds.isFinite ? clipAssetDuration.seconds : clip.sourceDuration
            let safeSourceStart = max(0, min(clip.sourceStartTime, max(0.1, measuredSourceDuration) - 0.1))
            let maxVisibleDuration = max(
                0.1,
                min(
                    measuredSourceDuration - safeSourceStart,
                    clip.sourceDuration - safeSourceStart
                )
            )
            let safeDuration = max(
                0.1,
                min(
                    clip.duration,
                    min(maxVisibleDuration, max(0.1, project.duration - clip.startTime))
                )
            )
            let outputStartSeconds = timeMap.outputTime(forSource: clip.startTime)
            try compositionTrack.insertTimeRange(
                CMTimeRange(
                    start: CMTime(seconds: safeSourceStart, preferredTimescale: 600),
                    duration: CMTime(seconds: safeDuration, preferredTimescale: 600)
                ),
                of: clipTrack,
                at: CMTime(seconds: outputStartSeconds, preferredTimescale: 600)
            )

            let input = AVMutableAudioMixInputParameters(track: compositionTrack)
            let mixedVolume = Float(max(0, min(2, project.settings.voiceOverVolume * clip.gain)))
            input.setVolume(mixedVolume, at: .zero)
            parameters.append(input)
        }

        // Click ticks — the synthesized tick WAV inserted at each click's
        // OUTPUT time (source clicks retimed through the speed map). Clicks
        // outside the trim/visible clips are dropped; near-simultaneous
        // clicks are throttled to one tick per 50ms.
        if mixClicks,
           let tickURL = try? ClickSoundPlayer.tickFileURL(style: project.settings.clickSoundStyle) {
            let tickAsset = AVURLAsset(url: tickURL)
            if let tickTrack = try await tickAsset.loadTracks(withMediaType: .audio).first,
               let clickCompTrack = composition.addMutableTrack(
                   withMediaType: .audio,
                   preferredTrackID: kCMPersistentTrackID_Invalid
               ) {
                let tickDuration = CMTime(seconds: ClickSoundPlayer.tickDuration, preferredTimescale: 600)
                let visible = clipSegments.isEmpty
                    ? [VideoClipSegment(startTime: mapSourceStart, endTime: mapSourceEnd)]
                    : clipSegments
                var lastOutput = -1.0
                for sourceTime in clickTimes.sorted() {
                    guard sourceTime >= mapSourceStart, sourceTime <= mapSourceEnd,
                          visible.contains(where: { sourceTime >= $0.startTime && sourceTime <= $0.endTime })
                    else { continue }
                    let outputTime = timeMap.outputTime(forSource: sourceTime)
                    guard outputTime - lastOutput >= 0.05 else { continue }
                    lastOutput = outputTime
                    try? clickCompTrack.insertTimeRange(
                        CMTimeRange(start: .zero, duration: tickDuration),
                        of: tickTrack,
                        at: CMTime(seconds: outputTime, preferredTimescale: 600)
                    )
                }
                let input = AVMutableAudioMixInputParameters(track: clickCompTrack)
                input.setVolume(Float(max(0, min(1, project.settings.clickSoundVolume))), at: .zero)
                parameters.append(input)
            }
        }

        // Keystroke sounds — the whole key track rendered as ONE WAV with the
        // exact per-event synthesis the preview plays (deterministic seeds),
        // then inserted once. Events are retimed through the speed map and
        // clipped to trim/visible ranges; density is capped in the renderer.
        if mixKeys {
            let visible = clipSegments.isEmpty
                ? [VideoClipSegment(startTime: mapSourceStart, endTime: mapSourceEnd)]
                : clipSegments
            let mapped: [(outputTime: TimeInterval, seedTimestamp: TimeInterval, category: KeystrokeEvent.Category)] =
                keystrokes.compactMap { event in
                    guard event.category != .scroll,
                          event.timestamp >= mapSourceStart, event.timestamp <= mapSourceEnd,
                          visible.contains(where: { event.timestamp >= $0.startTime && event.timestamp <= $0.endTime })
                    else { return nil }
                    return (timeMap.outputTime(forSource: event.timestamp), event.timestamp, event.category)
                }
            if !mapped.isEmpty,
               let trackURL = try? KeySoundPlayer.renderTrackWAV(
                   events: mapped,
                   duration: timeMap.outputDuration,
                   style: project.settings.keySoundStyle
               ) {
                let keyAsset = AVURLAsset(url: trackURL)
                if let keyTrack = try await keyAsset.loadTracks(withMediaType: .audio).first,
                   let keyCompTrack = composition.addMutableTrack(
                       withMediaType: .audio,
                       preferredTrackID: kCMPersistentTrackID_Invalid
                   ) {
                    let keyDuration = try await keyAsset.load(.duration)
                    try? keyCompTrack.insertTimeRange(
                        CMTimeRange(start: .zero, duration: keyDuration),
                        of: keyTrack,
                        at: .zero
                    )
                    let input = AVMutableAudioMixInputParameters(track: keyCompTrack)
                    input.setVolume(Float(max(0, min(1, project.settings.keySoundVolume))), at: .zero)
                    parameters.append(input)
                }
            }
        }

        let preparedTracks = try await composition.loadTracks(withMediaType: .audio)
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        return PreparedAudio(asset: composition, tracks: preparedTracks, audioMix: preparedTracks.isEmpty ? nil : mix)
    }

    private static func baseVolume(for trackIndex: Int, settings: ProjectSettings) -> Float {
        if settings.muteRecordedAudio { return 0 }
        let rawValue = trackIndex == 0 ? settings.systemAudioVolume : settings.microphoneVolume
        return Float(max(0, min(1, rawValue)))
    }

    /// Walks the time map's visible clip intersections, inserting each source
    /// range at its timeline position. Empty ranges between resized clips stay
    /// empty, so the preview/export audio matches the blank video gaps.
    private static func insertScaledSegments(
        from sourceTrack: AVAssetTrack,
        into compositionTrack: AVMutableCompositionTrack,
        timeMap: SpeedTimeMap,
        clipSegments: [VideoClipSegment]
    ) throws {
        let visibleRanges = clipSegments.isEmpty
            ? [VideoClipSegment(startTime: timeMap.sourceStart, endTime: timeMap.sourceEnd)]
            : clipSegments

        for seg in timeMap.segments {
            for clip in visibleRanges {
                let sourceStart = max(seg.sourceStart, clip.startTime)
                let sourceEnd = min(seg.sourceEnd, clip.endTime)
                let srcDurSeconds = max(0, sourceEnd - sourceStart)
                guard srcDurSeconds > 0.0001 else { continue }

                let outputStart = timeMap.outputTime(forSource: sourceStart)
                let outputEnd = timeMap.outputTime(forSource: sourceEnd)
                let outputDurSeconds = max(0.001, outputEnd - outputStart)
                let srcStart = CMTime(seconds: sourceStart, preferredTimescale: 600)
                let srcDur = CMTime(seconds: srcDurSeconds, preferredTimescale: 600)
                let at = CMTime(seconds: outputStart, preferredTimescale: 600)

                let trackEnd = compositionTrack.timeRange.end
                if CMTimeCompare(at, trackEnd) > 0 {
                    compositionTrack.insertEmptyTimeRange(
                        CMTimeRange(start: trackEnd, duration: CMTimeSubtract(at, trackEnd))
                    )
                }

                try compositionTrack.insertTimeRange(
                    CMTimeRange(start: srcStart, duration: srcDur),
                    of: sourceTrack,
                    at: at
                )

                if abs(outputDurSeconds - srcDurSeconds) > 0.0001 {
                    compositionTrack.scaleTimeRange(
                        CMTimeRange(start: at, duration: srcDur),
                        toDuration: CMTime(seconds: outputDurSeconds, preferredTimescale: 600)
                    )
                }
            }
        }
    }
}
