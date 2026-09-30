import AVFoundation
import Foundation

/// describe_project and the evidence digests an agent plans edits from:
/// click clusters + idle cursor spans (recorded cursor stream), silence spans
/// (RMS over the recording's audio), and their intersection — the quiet,
/// motionless stretches that are the strongest set_speed candidates.
/// Every span is SOURCE seconds.
extension MCPServer {
    // MARK: - Output clock

    /// Exported length (OUTPUT seconds) — the same trim+speed map and
    /// last-visible-clip cap VideoExporter uses. nil while the project's
    /// duration is unprobed (0).
    static func outputDuration(of project: Project) -> Double? {
        guard project.duration > 0 else { return nil }
        return project.exportedOutputDuration(timeMap: SpeedTimeMap(trimmedOutputOf: project))
    }

    // MARK: - describe_project

    static func describeProject(_ arguments: [String: Any]) throws -> [String: Any] {
        let ref = try requireProjectRef(arguments)
        let (url, project) = try loadProject(ref)
        let s = project.settings
        let projectDir = url.deletingLastPathComponent()

        var result: [String: Any] = [
            "id": project.id.uuidString,
            "name": project.name,
            "clock": "Every start/end/at here is SOURCE seconds (original recording) — the clock all edit "
                + "tools take. render_frames and get_transcript start/end use OUTPUT seconds (after trim + speed).",
            "duration": round3(project.duration),
            "trimStart": round3(project.trimStart),
            "trimEnd": round3(project.trimEnd),
            "trim": ["start": round3(project.effectiveTrimStart), "end": round3(project.effectiveTrimEnd)],
            "recordingSourceKind": project.recordingSourceKind.rawValue,
            "isImageCapture": project.isImageCapture,
            "clips": project.effectiveVideoClipSegments.map {
                ["id": $0.id.uuidString, "start": round3($0.startTime), "end": round3($0.endTime)]
            },
            "splitPoints": project.splitPoints.map(round3),
            "effects": [
                "zoomRegions": project.zoomRegions.sorted { $0.startTime < $1.startTime }.map { zoom -> [String: Any] in
                    var entry: [String: Any] = [
                        "id": zoom.id.uuidString,
                        "start": round3(zoom.startTime), "end": round3(zoom.endTime),
                        "zoomLevel": round3(zoom.zoomLevel),
                        "focalPoint": ["x": round3(zoom.focalPoint.x), "y": round3(zoom.focalPoint.y)],
                    ]
                    if let style = zoom.animationStyle { entry["animationStyle"] = style.rawValue }
                    if zoom.followsCursor == false { entry["followsCursor"] = false }
                    if let ox = zoom.cardOffsetX { entry["offsetX"] = round3(ox) }
                    if let oy = zoom.cardOffsetY { entry["offsetY"] = round3(oy) }
                    if zoom.isAuto == true { entry["auto"] = true }
                    return entry
                },
                "tiltRegions": project.tiltRegions.sorted { $0.startTime < $1.startTime }.map { tilt -> [String: Any] in
                    var entry: [String: Any] = [
                        "id": tilt.id.uuidString,
                        "start": round3(tilt.startTime), "end": round3(tilt.endTime),
                        "pitch": round3(tilt.pitch), "yaw": round3(tilt.yaw), "roll": round3(tilt.roll),
                    ]
                    if let style = tilt.animationStyle { entry["animationStyle"] = style.rawValue }
                    return entry
                },
            ],
            "annotations": project.annotations.sorted { $0.startTime < $1.startTime }.map(annotationPayload),
            "blurRegions": project.blurRegions.sorted { $0.startTime < $1.startTime }.map { blur -> [String: Any] in
                var entry: [String: Any] = [
                    "id": blur.id.uuidString,
                    "start": round3(blur.startTime), "end": round3(blur.endTime),
                    "rect": rectPayload(blur.rect),
                    "style": blur.style.rawValue,
                    "intensity": round3(blur.intensity),
                ]
                if blur.animated { entry["animated"] = true }
                return entry
            },
            "highlightRegions": project.highlightRegions.sorted { $0.startTime < $1.startTime }.map { highlight -> [String: Any] in
                [
                    "id": highlight.id.uuidString,
                    "start": round3(highlight.startTime), "end": round3(highlight.endTime),
                    "rect": rectPayload(highlight.rect),
                    "opacity": round3(highlight.opacity),
                    "label": highlight.label,
                ]
            },
            "speedRegions": project.speedRegions.sorted { $0.startTime < $1.startTime }.map {
                ["id": $0.id.uuidString, "start": round3($0.startTime), "end": round3($0.endTime), "speed": $0.speed]
            },
            "subtitles": [
                "count": project.subtitles.count,
                "showSubtitles": s.showSubtitles,
            ],
            "settings": [
                "aspectRatio": s.aspectRatio.rawValue,
                "backgroundType": s.backgroundType.rawValue,
                "backgroundPadding": s.backgroundPadding,
                "backgroundBlur": s.backgroundBlur,
                "videoPlacement": s.videoPlacement.rawValue,
                "cornerRadius": s.cornerRadius,
                "shadowRadius": s.shadowRadius,
                "cursorStyle": s.cursorStyle.rawValue,
                "cursorScale": s.cursorScale,
                "showCursor": s.showCursor,
                "showClickRipple": s.showClickRipple,
                "animationSpeed": s.animationSpeed.rawValue,
                "autoZoomLevel": s.autoZoomLevel,
                "menuBarReplacement": s.menuBarReplacement.rawValue,
                "showDeviceFrame": s.showDeviceFrame,
                "showCamera": s.showCamera,
                "muteRecordedAudio": s.muteRecordedAudio,
            ] as [String: Any],
            "settingsNote": "Key settings only — style_options lists every set_style key with its current value.",
        ]
        if let output = outputDuration(of: project) {
            result["outputDuration"] = round3(output)
        }
        // FOCUS-lane occupants the agent can't edit but must route around.
        let otherFocus: [[String: Any]] =
            project.focusRegions.map { ["kind": "depth-focus", "id": $0.id.uuidString,
                                        "start": round3($0.startTime), "end": round3($0.endTime)] }
            + project.cameraLayoutRegions.map { ["kind": "camera-layout:\($0.mode.rawValue)", "id": $0.id.uuidString,
                                                 "start": round3($0.startTime), "end": round3($0.endTime)] }
        if !otherFocus.isEmpty { result["otherFocusLaneRegions"] = otherFocus }
        if !project.voiceOverClips.isEmpty { result["voiceOverClips"] = project.voiceOverClips.count }

        let activity = cursorActivity(projectDir: projectDir, project: project)
        if let activity {
            result["interactionDigest"] = interactionDigest(activity)
        }
        result["pacing"] = pacingDigest(project: project, activity: activity)
        return result
    }

    static func rectPayload(_ rect: CGRect) -> [String: Any] {
        ["x": round3(rect.origin.x), "y": round3(rect.origin.y),
         "width": round3(rect.width), "height": round3(rect.height)]
    }

    static func annotationPayload(_ a: Annotation) -> [String: Any] {
        var entry: [String: Any] = [
            "id": a.id.uuidString,
            "type": a.type.rawValue,
            "start": round3(a.startTime), "end": round3(a.endTime),
            "x": round3(a.x), "y": round3(a.y),
            "color": hexString(a.color),
        ]
        switch a.type {
        case .arrow, .rectangle, .ellipse, .callout:
            entry["arrowEndX"] = round3(a.arrowEndX)
            entry["arrowEndY"] = round3(a.arrowEndY)
        default: break
        }
        if a.type == .text || a.type == .callout { entry["text"] = a.text }
        if a.type == .drawing { entry["strokes"] = a.drawingStrokes.count }
        if a.backdropOpacity > 0 { entry["backdropOpacity"] = round3(a.backdropOpacity) }
        return entry
    }

    // MARK: - Cursor activity

    struct CursorActivity {
        var events: [CursorEvent]
        var coordinateSize: CGSize
        var clicks: [CursorEvent]
        /// >3s without meaningful movement (5pt) or clicks.
        var idleSpans: [(start: Double, end: Double)]
    }

    /// Mirrors the discrete-click collapse in ClickRippleOverlay (mouse-down
    /// runs → one click; drags dropped) plus the idle-span scan.
    static func cursorActivity(projectDir: URL, project: Project) -> CursorActivity? {
        let fm = FileManager.default
        var cursorURL = projectDir.appendingPathComponent("cursor.json")
        if !fm.fileExists(atPath: cursorURL.path), let stored = project.cursorDataURL {
            cursorURL = stored
        }
        guard fm.fileExists(atPath: cursorURL.path),
              let recording = try? CursorTracker.loadRecording(from: cursorURL),
              !recording.events.isEmpty else { return nil }

        let events = recording.events
        let coordW = max(1, recording.coordinateWidth)
        let coordH = max(1, recording.coordinateHeight)

        let shortSide = min(coordW, coordH)
        let dragThreshold = max(10, min(24, shortSide * 0.006))
        var clicks: [CursorEvent] = []
        var runStart: CursorEvent?
        var maxDist: CGFloat = 0
        func finishRun() {
            if let start = runStart, maxDist <= dragThreshold { clicks.append(start) }
            runStart = nil
            maxDist = 0
        }
        for event in events {
            if event.isClick {
                if let start = runStart {
                    maxDist = max(maxDist, hypot(event.x - start.x, event.y - start.y))
                } else {
                    runStart = event
                    maxDist = 0
                }
            } else {
                finishRun()
            }
        }
        finishRun()

        var idleSpans: [(start: Double, end: Double)] = []
        var idleStart = events[0].timestamp
        var lastPos = events[0]
        for event in events {
            if hypot(event.x - lastPos.x, event.y - lastPos.y) > 5 || event.isClick {
                if event.timestamp - idleStart > 3.0 {
                    idleSpans.append((idleStart, event.timestamp))
                }
                idleStart = event.timestamp
                lastPos = event
            }
        }
        if let last = events.last, last.timestamp - idleStart > 3.0 {
            idleSpans.append((idleStart, last.timestamp))
        }
        return CursorActivity(
            events: events,
            coordinateSize: CGSize(width: coordW, height: coordH),
            clicks: clicks,
            idleSpans: idleSpans
        )
    }

    /// Click clusters (2s gaps) + idle spans — the evidence for WHERE zooms go.
    static func interactionDigest(_ activity: CursorActivity) -> [String: Any] {
        struct Cluster { var start, end: Double; var count: Int; var sumX, sumY: CGFloat }
        var clusters: [Cluster] = []
        for click in activity.clicks {
            if var last = clusters.last, click.timestamp - last.end <= 2.0 {
                last.end = click.timestamp
                last.count += 1
                last.sumX += click.x
                last.sumY += click.y
                clusters[clusters.count - 1] = last
            } else {
                clusters.append(Cluster(start: click.timestamp, end: click.timestamp,
                                        count: 1, sumX: click.x, sumY: click.y))
            }
        }
        let coordW = activity.coordinateSize.width, coordH = activity.coordinateSize.height
        return [
            "totalEvents": activity.events.count,
            "coordinateSize": ["width": Double(coordW), "height": Double(coordH)],
            "clickClusters": clusters.map {
                [
                    "start": round3($0.start),
                    "end": round3($0.end),
                    "clickCount": $0.count,
                    "meanPosition": [
                        "x": round3(Double($0.sumX / CGFloat($0.count) / coordW)),
                        "y": round3(Double($0.sumY / CGFloat($0.count) / coordH)),
                    ],
                ] as [String: Any]
            },
            "idleSpans": activity.idleSpans.map { ["start": round3($0.start), "end": round3($0.end)] },
        ]
    }

    // MARK: - Pacing

    /// Silence (audio) alongside idle cursor spans, clipped to the trim
    /// window, plus their intersection minus typing/scrolling: `quietSpans`,
    /// nothing moving, nothing said — the best set_speed candidates.
    static func pacingDigest(project: Project, activity: CursorActivity?) -> [String: Any] {
        let trimStart = project.effectiveTrimStart
        let trimEnd = project.duration > 0 ? project.effectiveTrimEnd : .infinity
        func clipped(_ spans: [(start: Double, end: Double)], minLength: Double) -> [(start: Double, end: Double)] {
            spans.compactMap { span in
                let start = max(span.start, trimStart), end = min(span.end, trimEnd)
                return end - start >= minLength ? (start, end) : nil
            }
        }
        func payload(_ spans: [(start: Double, end: Double)], seconds: Bool = false, limit: Int = 40) -> [[String: Any]] {
            spans.prefix(limit).map {
                var entry: [String: Any] = ["start": round3($0.start), "end": round3($0.end)]
                if seconds { entry["seconds"] = round3($0.end - $0.start) }
                return entry
            }
        }

        var result: [String: Any] = [:]
        var silence: [(start: Double, end: Double)]?
        if let videoURL = project.videoURL, FileManager.default.fileExists(atPath: videoURL.path) {
            switch silenceAnalysis(videoURL: videoURL) {
            case .noAudio:
                // No audio track at all: nothing is ever said.
                result["audio"] = ["tracks": 0, "note": "no audio track — the whole recording is silent"]
                if trimEnd.isFinite { silence = [(trimStart, trimEnd)] }
            case .failed(let reason):
                result["audio"] = ["note": "audio analysis failed: \(reason)"]
            case .analyzed(let analysis):
                let spans = clipped(analysis.spans, minLength: 1.0)
                silence = spans
                result["audio"] = [
                    "tracks": analysis.trackCount,
                    "silenceThresholdDb": round3(analysis.thresholdDb),
                    "noiseFloorDb": round3(analysis.noiseFloorDb),
                ]
                result["silenceSpans"] = payload(spans)
                if spans.count > 40 { result["silenceSpansTruncated"] = spans.count - 40 }
            }
        }

        if let activity {
            let idle = clipped(activity.idleSpans, minLength: 1.0)
            if let silence {
                // Keystrokes and scroll ticks are activity even when the mouse
                // is parked (typing into a field, scrolling a page).
                let keyTimes = keystrokeTimes(project: project)
                var quiet: [(start: Double, end: Double)] = []
                for a in idle {
                    for b in silence {
                        let start = max(a.start, b.start), end = min(a.end, b.end)
                        guard end - start >= 2.0 else { continue }
                        quiet.append(contentsOf: subtractActivity((start, end), keyTimes: keyTimes, pad: 0.5))
                    }
                }
                quiet = quiet.filter { $0.end - $0.start >= 2.0 }.sorted { $0.start < $1.start }
                result["quietSpans"] = payload(quiet, seconds: true)
                result["quietSeconds"] = round3(quiet.reduce(0) { $0 + ($1.end - $1.start) })
            }
        }
        result["hint"] = "quietSpans = no cursor movement, no clicks/keys/scrolls AND no sound — the safest "
            + "set_speed candidates (2–4×); still glance at them (a page may be loading). "
            + "interactionDigest.idleSpans are cursor-only and may contain speech. All SOURCE seconds, "
            + "clipped to the trim window."
        return result
    }

    private static func keystrokeTimes(project: Project) -> [Double] {
        guard let url = project.keystrokeDataURL,
              let recording = try? KeystrokeTracker.loadRecording(from: url) else { return [] }
        return recording.events.map(\.timestamp).sorted()
    }

    /// Splits `span` around keystroke/scroll moments (± pad).
    private static func subtractActivity(
        _ span: (start: Double, end: Double), keyTimes: [Double], pad: Double
    ) -> [(start: Double, end: Double)] {
        var pieces: [(start: Double, end: Double)] = []
        var cursor = span.start
        for t in keyTimes where t + pad > span.start && t - pad < span.end {
            if t - pad > cursor { pieces.append((cursor, t - pad)) }
            cursor = max(cursor, t + pad)
        }
        if span.end > cursor { pieces.append((cursor, span.end)) }
        return pieces
    }

    // MARK: - Audio silence (RMS)

    struct SilenceAnalysis {
        var spans: [(start: Double, end: Double)]
        var thresholdDb: Double
        var noiseFloorDb: Double
        var trackCount: Int
    }

    enum SilenceOutcome {
        case analyzed(SilenceAnalysis)
        case noAudio
        case failed(String)
    }

    /// Process-lifetime cache keyed on the media file's path + size + mtime —
    /// describe_project is called often, the recording never changes.
    nonisolated(unsafe) private static var silenceCache: [String: SilenceOutcome] = [:]
    private static let silenceCacheLock = NSLock()

    /// All audio tracks mixed to mono at 8 kHz, RMS per 50 ms window. The
    /// threshold adapts to the recording: 12 dB above its noise floor (10th
    /// percentile), clamped to −55…−40 dBFS so steady music never reads as
    /// silence and a dead-quiet mic still does. Spans ≥ 1 s.
    static func silenceAnalysis(videoURL: URL) -> SilenceOutcome {
        let attributes = try? FileManager.default.attributesOfItem(atPath: videoURL.path)
        let key = videoURL.path
            + "|\((attributes?[.size] as? NSNumber)?.int64Value ?? 0)"
            + "|\((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        silenceCacheLock.lock()
        if let cached = silenceCache[key] {
            silenceCacheLock.unlock()
            return cached
        }
        silenceCacheLock.unlock()
        let outcome = computeSilence(videoURL: videoURL)
        silenceCacheLock.lock()
        silenceCache[key] = outcome
        silenceCacheLock.unlock()
        return outcome
    }

    private static func computeSilence(videoURL: URL) -> SilenceOutcome {
        let asset = AVURLAsset(url: videoURL)
        let semaphore = DispatchSemaphore(value: 0)
        var tracks: [AVAssetTrack] = []
        var loadError: Error?
        Task {
            do { tracks = try await asset.loadTracks(withMediaType: .audio) } catch { loadError = error }
            semaphore.signal()
        }
        semaphore.wait()
        if let loadError { return .failed(loadError.localizedDescription) }
        guard !tracks.isEmpty else { return .noAudio }

        let sampleRate = 8000.0
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { return .failed(error.localizedDescription) }
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        guard reader.canAdd(output) else { return .failed("cannot read the audio tracks") }
        reader.add(output)
        guard reader.startReading() else {
            return .failed(reader.error?.localizedDescription ?? "reader failed to start")
        }

        let window = Int(sampleRate * 0.05)
        var windowDb: [Double] = []
        var sumSquares: Double = 0
        var count = 0
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                              totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
                  let pointer else { continue }
            let samples = length / MemoryLayout<Float>.size
            pointer.withMemoryRebound(to: Float.self, capacity: samples) { floats in
                for i in 0..<samples {
                    let v = Double(floats[i])
                    sumSquares += v * v
                    count += 1
                    if count == window {
                        let rms = (sumSquares / Double(count)).squareRoot()
                        windowDb.append(20 * log10(max(rms, 1e-9)))
                        sumSquares = 0
                        count = 0
                    }
                }
            }
        }
        if reader.status == .failed {
            return .failed(reader.error?.localizedDescription ?? "audio read failed")
        }
        guard !windowDb.isEmpty else { return .noAudio }

        let sorted = windowDb.sorted()
        let noiseFloor = sorted[min(sorted.count - 1, sorted.count / 10)]
        let threshold = min(-40, max(-55, noiseFloor + 12))
        let windowSeconds = Double(window) / sampleRate

        // A single loud 50 ms blip (a click, a breath) doesn't break silence.
        var spans: [(start: Double, end: Double)] = []
        var runStart: Int?
        var index = 0
        while index < windowDb.count {
            let loud = windowDb[index] > threshold
                && (index + 1 < windowDb.count ? windowDb[index + 1] > threshold : true)
            if !loud {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                let span = (Double(start) * windowSeconds, Double(index) * windowSeconds)
                if span.1 - span.0 >= 1.0 { spans.append(span) }
                runStart = nil
            }
            index += 1
        }
        if let start = runStart {
            let span = (Double(start) * windowSeconds, Double(windowDb.count) * windowSeconds)
            if span.1 - span.0 >= 1.0 { spans.append(span) }
        }
        return .analyzed(SilenceAnalysis(
            spans: spans, thresholdDb: threshold, noiseFloorDb: noiseFloor, trackCount: tracks.count))
    }
}
