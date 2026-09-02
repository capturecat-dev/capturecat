import Foundation
import CoreGraphics

enum RecordingSourceKind: String, Codable {
    case display
    case window
    case area
    case device // iPhone/iPad screen
}

/// One source segment inside a stitched multi-source take (desktop → iPhone
/// → …). `content*` is the segment's aspect-fit rect inside the stitched
/// frame, normalized 0…1 with a top-left origin — used to crop + bezel-frame
/// device segments at display time.
struct ProjectSourceSegment: Codable, Sendable {
    var startTime: TimeInterval
    var duration: TimeInterval
    var kind: RecordingSourceKind
    var contentX: Double
    var contentY: Double
    var contentWidth: Double
    var contentHeight: Double

    var endTime: TimeInterval { startTime + duration }

    var normalizedContentRect: CGRect {
        CGRect(x: contentX, y: contentY, width: contentWidth, height: contentHeight)
    }
}

/// How the editor treats a still capture (`isImageCapture`). Raw values are
/// persistence identity — never rename.
enum StillTreatment: String, Codable, Sendable {
    /// Timeless presentation: full-span video block, no playhead, ruler
    /// de-emphasized, timeline zoom pinned. Export offers PNG.
    case image
    /// Ordinary video editing/export, identical to a recording.
    case video
}

struct VideoClipSegment: Identifiable, Codable, Sendable {
    let id: UUID
    var startTime: TimeInterval
    var endTime: TimeInterval

    init(id: UUID = UUID(), startTime: TimeInterval, endTime: TimeInterval) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
    }
}

@Observable
final class Project: Identifiable, Codable {
    let id: UUID
    var name: String
    var createdAt: Date
    var videoURL: URL?
    var cursorDataURL: URL?
    var keystrokeDataURL: URL?
    var cameraVideoURL: URL?
    var cameraTimeOffset: TimeInterval
    var settings: ProjectSettings
    var zoomRegions: [ZoomRegion]
    var tiltRegions: [TiltRegion]
    var blurRegions: [BlurRegion]
    var highlightRegions: [HighlightRegion]
    /// Depth Focus regions — sharp inside, graduated blur outside (FocusMath).
    var focusRegions: [FocusRegion]
    /// Camera layout overrides — camera-full / side-by-side / hidden spans.
    /// Outside every region the camera is the classic floating bubble.
    var cameraLayoutRegions: [CameraLayoutRegion]
    var annotations: [Annotation]
    var voiceOverClips: [VoiceOverClip]
    var subtitles: [SubtitleSegment]
    var speedRegions: [VideoSpeedRegion]
    /// Source-time points where the clip is virtually sliced — purely visual
    /// boundaries that let the user target independent speeds per segment.
    var splitPoints: [TimeInterval]
    /// Independent source ranges for sliced video clips. Empty means the whole
    /// effective trim range is one clip, with legacy split points as boundaries.
    var videoClipSegments: [VideoClipSegment]
    var duration: TimeInterval
    var trimStart: TimeInterval
    var trimEnd: TimeInterval
    var recordingSourceKind: RecordingSourceKind
    /// Bundle identifier of the app whose window was recorded — set only for
    /// `.window` takes, so the shortcut overlay can drop shortcuts typed into
    /// OTHER apps mid-recording (KeystrokeOverlayMath.scopedEvents). Nil for
    /// display/area/device takes and recordings made before this existed.
    var recordedAppBundleID: String? = nil
    /// Non-empty only for stitched multi-source takes.
    var sourceSegments: [ProjectSourceSegment]
    /// "Remind me" date — a local notification is scheduled for it (see
    /// ReminderCenter; pending requests are re-derived from this on launch).
    var reminderDate: Date?
    /// True for still captures (screenshot / web-page capture) — they are
    /// encoded as short movies so the editor pipeline stays singular, but the
    /// browser classifies them as "Image". Older stills predate this flag;
    /// see `isImageCapture` for the legacy heuristic.
    var isStillCapture: Bool
    /// Image-vs-video treatment for still captures — drives the editor's
    /// Image | Video tab, the timeless timeline presentation and the export
    /// sheet's PNG option. Meaningless (and ignored) for real recordings.
    var stillTreatment: StillTreatment

    /// Set by PreviewView so the exporter can scale spatial settings to match.
    @ObservationIgnored var previewCanvasSize: CGSize = .zero

    /// Runtime-only save coordination — never persisted.
    ///
    /// `hasUnsavedChanges` flips on when the app mutates the project
    /// (EditorAutoSaveObserver / scheduleAutoSave) and off on every
    /// `ProjectStore.save`. Close/quit paths save only when this is set, so a
    /// clean in-memory copy can never clobber a `CaptureCat --mcp` process's
    /// disk edit.
    @ObservationIgnored var hasUnsavedChanges: Bool = false
    /// project.json's mtime the last time THIS instance touched disk
    /// (load or save). The external-change poll compares against it to tell
    /// an MCP process's write from our own.
    @ObservationIgnored var diskModificationDate: Date? = nil

    /// The effective duration after trimming.
    var trimmedDuration: TimeInterval {
        effectiveTrimEnd - effectiveTrimStart
    }

    /// Trim start clamped to valid range.
    var effectiveTrimStart: TimeInterval {
        max(0, min(trimStart, duration))
    }

    /// Trim end clamped to valid range, or full duration if not set.
    var effectiveTrimEnd: TimeInterval {
        let end = trimEnd > 0 ? trimEnd : duration
        return max(effectiveTrimStart, min(end, duration))
    }

    var effectiveVideoClipSegments: [VideoClipSegment] {
        let baseSegments: [VideoClipSegment]
        if videoClipSegments.isEmpty {
            let cuts = splitPoints
                .filter { $0 > effectiveTrimStart + 0.01 && $0 < effectiveTrimEnd - 0.01 }
                .sorted()
            let boundaries = [effectiveTrimStart] + cuts + [effectiveTrimEnd]
            baseSegments = (0..<(boundaries.count - 1)).map { index in
                VideoClipSegment(
                    id: Self.stableLegacyClipID(
                        projectID: id,
                        index: index,
                        startTime: boundaries[index],
                        endTime: boundaries[index + 1]
                    ),
                    startTime: boundaries[index],
                    endTime: boundaries[index + 1]
                )
            }
        } else {
            baseSegments = videoClipSegments
        }

        return baseSegments.compactMap { clip in
            let start = max(effectiveTrimStart, min(clip.startTime, duration))
            let end = max(start, min(clip.endTime, effectiveTrimEnd))
            guard end > start + 0.01 else { return nil }
            return VideoClipSegment(id: clip.id, startTime: start, endTime: end)
        }
        .sorted { $0.startTime < $1.startTime }
    }

    func visibleVideoClip(
        containing sourceTime: TimeInterval,
        tolerance: TimeInterval = 1.0 / 30.0
    ) -> VideoClipSegment? {
        effectiveVideoClipSegments.first { clip in
            sourceTime >= clip.startTime - tolerance
                && sourceTime <= clip.endTime + tolerance
        }
    }

    func hasVisibleVideo(at sourceTime: TimeInterval, tolerance: TimeInterval = 1.0 / 30.0) -> Bool {
        visibleVideoClip(containing: sourceTime, tolerance: tolerance) != nil
    }

    private static func stableLegacyClipID(
        projectID: UUID,
        index: Int,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) -> UUID {
        let key = "\(projectID.uuidString)|\(index)|\(String(format: "%.6f", startTime))|\(String(format: "%.6f", endTime))"
        let first = fnv1a64(key)
        let second = fnv1a64("clip|\(key)")
        var bytes: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)

        withUnsafeMutableBytes(of: &bytes) { buffer in
            for offset in 0..<8 {
                buffer[offset] = UInt8((first >> UInt64((7 - offset) * 8)) & 0xff)
                buffer[offset + 8] = UInt8((second >> UInt64((7 - offset) * 8)) & 0xff)
            }
            buffer[6] = (buffer[6] & 0x0f) | 0x50
            buffer[8] = (buffer[8] & 0x3f) | 0x80
        }

        return UUID(uuid: bytes)
    }

    private static func fnv1a64(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }

    var projectDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CaptureCat/Projects/\(id.uuidString)", isDirectory: true)
    }

    var thumbnailURL: URL? {
        let url = projectDirectory.appendingPathComponent("thumbnail.jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var cameraPosterURL: URL? {
        let url = projectDirectory.appendingPathComponent("camera_poster.png")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    init(
        id: UUID = UUID(),
        name: String = "Untitled Recording",
        videoURL: URL? = nil,
        cursorDataURL: URL? = nil,
        cameraVideoURL: URL? = nil,
        cameraTimeOffset: TimeInterval = 0,
        duration: TimeInterval = 0,
        recordingSourceKind: RecordingSourceKind = .display
    ) {
        let initialSettings = ProjectSettings()
        initialSettings.showCamera = cameraVideoURL != nil
        self.id = id
        self.name = name
        self.createdAt = Date()
        self.videoURL = videoURL
        self.cursorDataURL = cursorDataURL
        self.cameraVideoURL = cameraVideoURL
        self.cameraTimeOffset = cameraTimeOffset
        self.settings = initialSettings
        self.zoomRegions = []
        self.tiltRegions = []
        self.blurRegions = []
        self.highlightRegions = []
        self.focusRegions = []
        self.cameraLayoutRegions = []
        self.annotations = []
        self.voiceOverClips = []
        self.subtitles = []
        self.speedRegions = []
        self.splitPoints = []
        self.videoClipSegments = []
        self.duration = duration
        self.trimStart = 0
        self.trimEnd = 0
        self.recordingSourceKind = recordingSourceKind
        self.sourceSegments = []
        self.reminderDate = nil
        self.isStillCapture = false
        self.stillTreatment = .image
    }

    enum CodingKeys: String, CodingKey {
        case id, name, createdAt, videoURL, cursorDataURL, keystrokeDataURL, cameraVideoURL
        case cameraTimeOffset
        case settings, zoomRegions, tiltRegions, blurRegions, highlightRegions, annotations, voiceOverClips, subtitles, speedRegions, splitPoints, videoClipSegments, duration
        case focusRegions
        case cameraLayoutRegions
        case trimStart, trimEnd
        case recordingSourceKind
        case recordedAppBundleID
        case sourceSegments
        case reminderDate
        case isStillCapture
        case stillTreatment
    }

    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        videoURL = try c.decodeIfPresent(URL.self, forKey: .videoURL)
        cursorDataURL = try c.decodeIfPresent(URL.self, forKey: .cursorDataURL)
        keystrokeDataURL = try c.decodeIfPresent(URL.self, forKey: .keystrokeDataURL)
        let decodedCameraVideoURL = try c.decodeIfPresent(URL.self, forKey: .cameraVideoURL)
        cameraVideoURL = decodedCameraVideoURL
        cameraTimeOffset = try c.decodeIfPresent(TimeInterval.self, forKey: .cameraTimeOffset) ?? 0
        let decodedSettings = try c.decode(ProjectSettings.self, forKey: .settings)
        decodedSettings.showCamera = decodedCameraVideoURL != nil && decodedSettings.showCamera
        settings = decodedSettings
        zoomRegions = try c.decode([ZoomRegion].self, forKey: .zoomRegions)
        tiltRegions = try c.decodeIfPresent([TiltRegion].self, forKey: .tiltRegions) ?? []
        blurRegions = try c.decodeIfPresent([BlurRegion].self, forKey: .blurRegions) ?? []
        highlightRegions = try c.decodeIfPresent([HighlightRegion].self, forKey: .highlightRegions) ?? []
        focusRegions = try c.decodeIfPresent([FocusRegion].self, forKey: .focusRegions) ?? []
        cameraLayoutRegions = try c.decodeIfPresent([CameraLayoutRegion].self, forKey: .cameraLayoutRegions) ?? []
        annotations = try c.decodeIfPresent([Annotation].self, forKey: .annotations) ?? []
        voiceOverClips = try c.decodeIfPresent([VoiceOverClip].self, forKey: .voiceOverClips) ?? []
        subtitles = try c.decodeIfPresent([SubtitleSegment].self, forKey: .subtitles) ?? []
        speedRegions = try c.decodeIfPresent([VideoSpeedRegion].self, forKey: .speedRegions) ?? []
        splitPoints = try c.decodeIfPresent([TimeInterval].self, forKey: .splitPoints) ?? []
        videoClipSegments = try c.decodeIfPresent([VideoClipSegment].self, forKey: .videoClipSegments) ?? []
        duration = try c.decode(TimeInterval.self, forKey: .duration)
        trimStart = try c.decodeIfPresent(TimeInterval.self, forKey: .trimStart) ?? 0
        trimEnd = try c.decodeIfPresent(TimeInterval.self, forKey: .trimEnd) ?? 0
        recordingSourceKind = try c.decodeIfPresent(RecordingSourceKind.self, forKey: .recordingSourceKind) ?? .display
        recordedAppBundleID = try c.decodeIfPresent(String.self, forKey: .recordedAppBundleID)
        sourceSegments = try c.decodeIfPresent([ProjectSourceSegment].self, forKey: .sourceSegments) ?? []
        reminderDate = try c.decodeIfPresent(Date.self, forKey: .reminderDate)
        isStillCapture = try c.decodeIfPresent(Bool.self, forKey: .isStillCapture) ?? false
        stillTreatment = try c.decodeIfPresent(StillTreatment.self, forKey: .stillTreatment) ?? .image
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(videoURL, forKey: .videoURL)
        try c.encode(cursorDataURL, forKey: .cursorDataURL)
        try c.encodeIfPresent(keystrokeDataURL, forKey: .keystrokeDataURL)
        try c.encode(cameraVideoURL, forKey: .cameraVideoURL)
        try c.encode(cameraTimeOffset, forKey: .cameraTimeOffset)
        try c.encode(settings, forKey: .settings)
        try c.encode(zoomRegions, forKey: .zoomRegions)
        try c.encode(tiltRegions, forKey: .tiltRegions)
        try c.encode(blurRegions, forKey: .blurRegions)
        try c.encode(highlightRegions, forKey: .highlightRegions)
        try c.encode(focusRegions, forKey: .focusRegions)
        try c.encode(cameraLayoutRegions, forKey: .cameraLayoutRegions)
        try c.encode(annotations, forKey: .annotations)
        try c.encode(voiceOverClips, forKey: .voiceOverClips)
        try c.encode(subtitles, forKey: .subtitles)
        try c.encode(speedRegions, forKey: .speedRegions)
        try c.encode(splitPoints, forKey: .splitPoints)
        try c.encode(videoClipSegments, forKey: .videoClipSegments)
        try c.encode(duration, forKey: .duration)
        try c.encode(trimStart, forKey: .trimStart)
        try c.encode(trimEnd, forKey: .trimEnd)
        try c.encode(recordingSourceKind, forKey: .recordingSourceKind)
        try c.encodeIfPresent(recordedAppBundleID, forKey: .recordedAppBundleID)
        try c.encode(sourceSegments, forKey: .sourceSegments)
        try c.encodeIfPresent(reminderDate, forKey: .reminderDate)
        try c.encode(isStillCapture, forKey: .isStillCapture)
        try c.encode(stillTreatment, forKey: .stillTreatment)
    }
}

extension Project {
    /// Browser "Image" classification. New stills carry the persisted
    /// `isStillCapture` flag; stills saved before the flag existed are
    /// recognized by their signature — the exact StillMovieWriter default
    /// duration with no cursor track (device takes also lack cursor data,
    /// so they are excluded explicitly).
    var isImageCapture: Bool {
        if isStillCapture { return true }
        return cursorDataURL == nil
            && recordingSourceKind != .device
            && abs(duration - StillMovieWriter.defaultDuration) < 0.01
    }

    /// The timeline presents this project "timelessly": the still is in Image
    /// treatment, so the video block reads as one full-width slab with no
    /// playhead and a de-emphasized ruler. Time mapping underneath is
    /// UNCHANGED — only the presentation differs (see TimelineCanvasSnapshot
    /// .timelessVideo).
    var presentsTimelessTimeline: Bool {
        isImageCapture && stillTreatment == .image
    }

    /// The timeline hides the playhead and collapses the ruler: still capture,
    /// Image treatment, and NOTHING time-based to preview. Scrubbing still
    /// works (the line shows while interacting). The moment a timed effect
    /// exists, previewing it needs real scrubbing — the playhead auto-reveals
    /// and behaves exactly as in Video treatment.
    var hidesTimelinePlayhead: Bool {
        presentsTimelessTimeline && !hasTimedEffects
    }

    /// Any effect that only reads as motion over time — the signal the export
    /// sheet uses to default a still capture to Video (MP4) instead of PNG.
    /// Spatial dressing (background, padding, shadow, camera bubble, blur /
    /// focus / highlight regions, annotations) renders fine into one frame
    /// and is deliberately NOT counted.
    var hasTimedEffects: Bool {
        !zoomRegions.isEmpty
            || !tiltRegions.isEmpty
            || !speedRegions.isEmpty
            || !cameraLayoutRegions.isEmpty
            || !voiceOverClips.isEmpty
            || settings.introSlideStyle != .off
            || settings.curtainUnveilCorner != .off
            || annotations.contains { $0.type == .tap }
    }

    /// The watermark image inside the project folder (self-contained — the
    /// picked file is COPIED here). Shared by preview and exporter.
    ///
    /// Previously declared alongside the SwiftUI Brand pane; moved here when
    /// that view was deleted, since both render paths depend on it.
    var watermarkImageURL: URL? {
        guard let name = settings.watermarkFileName,
              let base = videoURL?.deletingLastPathComponent() else { return nil }
        return base.appendingPathComponent(name)
    }

    /// Curtain Unveil brand logo — same copy-into-project-folder storage as
    /// the watermark. Shared by preview and exporter.
    var curtainLogoImageURL: URL? {
        guard let name = settings.curtainLogoFileName,
              let base = videoURL?.deletingLastPathComponent() else { return nil }
        return base.appendingPathComponent(name)
    }
}
