import CoreGraphics
import Foundation

// Moved verbatim from the Mac VIDEO / VOICE lane rows (VideoTrackRowNative.swift,
// VoiceTrackRowNative.swift) in Studio 4c: the row snapshots, their builders,
// callbacks and drag state, shared with the iOS timeline.

// MARK: - Snapshot model (VIDEO row)

/// One clip slab on the VIDEO lane. Presentation-ready: TimelineView derives it,
/// the canvas only draws and hit-tests.
struct TimelineVideoClipItem: Equatable {
    var ref: VideoClipRef
    var isSelected: Bool
    /// Precomputed `dominantSpeed` readout for the info pill ("2x"), nil at 1×.
    var pillSpeedLabel: String?
    /// Port of `clipFillingSpeedRegion` — when one speed region covers the clip
    /// edge-to-edge the whole slab renders as a single retimed segment.
    var fillSpeed: Double?
    var fillRegionID: UUID?

    var id: UUID { ref.id }
    var outputStart: TimeInterval { ref.outputStart }
    var outputEnd: TimeInterval { ref.outputEnd }
    var outputDuration: TimeInterval { ref.outputDuration }
}

/// One visible sub-segment inside a clip, in output time.
struct TimelineVideoSegmentItem: Equatable {
    var id: String
    var clipID: UUID
    var sourceStart: TimeInterval
    var sourceEnd: TimeInterval
    var outputStart: TimeInterval
    var outputEnd: TimeInterval
    var speed: Double
    var regionID: UUID?
    /// "3s · 2x" caption, precomputed by the same formatter the SwiftUI row uses.
    var label: String
    /// Divider at the leading edge (speed boundary strictly inside the clip).
    var showsLeadingDivider: Bool
    /// A user split sits at this segment's start (enables "Remove Split").
    var startsAtSplit: Bool
}

/// Joined boundary between two touching clips — the two-sided resize hotspot.
struct TimelineVideoBoundaryItem: Equatable {
    var id: String
    var leftClipID: UUID
    var rightClipID: UUID
    var outputTime: TimeInterval
}

/// Everything the canvas needs to draw and edit the VIDEO row natively.
/// Thumbnails/waveform samples ride outside this Equatable value (heavy
/// arrays) — see `TimelineVideoAssets`.
struct TimelineVideoRowModel: Equatable {
    /// Trim window in output time — the yellow block's committed span.
    var regionStart: TimeInterval = 0
    var regionEnd: TimeInterval = 0
    /// Single-clip mode: the whole block trims/slips as one.
    var usesWholeTrackDrag: Bool = true
    var clips: [TimelineVideoClipItem] = []
    var segments: [TimelineVideoSegmentItem] = []
    var boundaries: [TimelineVideoBoundaryItem] = []
    var isMuted: Bool = false
    var hasAudio: Bool = false
    var hasThumbnails: Bool = false
    var snapCandidates: [TimeInterval] = []

    /// Speed presets shared with the SwiftUI row's context menu.
    static let speedPresets: [Double] = [0.5, 0.75, 1.2, 1.4, 1.6, 1.8, 2.0, 3.0, 4.0]

    var span: TimeInterval { max(0.0001, regionEnd - regionStart) }

    func clip(withID id: UUID) -> TimelineVideoClipItem? {
        clips.first { $0.id == id }
    }

    var clipSpans: [VideoTrackEditMath.ClipSpan] {
        clips.map(\.ref.span)
    }

    static func formatSpeedLabel(_ s: Double) -> String {
        if abs(s - s.rounded()) < 0.01 { return String(format: "%.0fx", s) }
        return String(format: "%.1fx", s)
    }

    /// Port of `VideoTrackContent.speedLabel(for:)`.
    static func segmentLabel(outputSpan: TimeInterval, speed: Double) -> String {
        let srcDur = outputSpan * speed
        let d = srcDur < 1 ? String(format: "%.1fs", srcDur) : "\(Int(srcDur.rounded()))s"
        return "\(d) · \(formatSpeedLabel(speed))"
    }

    /// Derives the whole row snapshot from the project. Every step below is a
    /// port of the matching `VideoTrackContent` computed property, so the two
    /// rows describe the same geometry. Lives here (not in TimelineView) so the
    /// screenshot harness renders exactly what ships.
    @MainActor
    static func make(
        project: Project,
        timeMap: SpeedTimeMap,
        selectedClipID: UUID?,
        hasAudio: Bool,
        hasThumbnails: Bool,
        snapCandidates: [TimeInterval]
    ) -> TimelineVideoRowModel {
        let tolerance: TimeInterval = 1.0 / 15.0
        let regionStart = timeMap.outputTime(forSource: project.effectiveTrimStart)
        let regionEnd = timeMap.outputTime(forSource: project.effectiveTrimEnd)
        let outputSplits = project.splitPoints.map { timeMap.outputTime(forSource: $0) }

        // Port of `clipSegments`.
        let refs: [VideoClipRef] = project.effectiveVideoClipSegments.compactMap { clip in
            let outputStart = timeMap.outputTime(forSource: clip.startTime)
            let outputEnd = timeMap.outputTime(forSource: clip.endTime)
            guard outputEnd > outputStart else { return nil }
            return VideoClipRef(
                id: clip.id,
                sourceStart: clip.startTime,
                sourceEnd: clip.endTime,
                outputStart: outputStart,
                outputEnd: outputEnd
            )
        }
        .sorted { $0.outputStart < $1.outputStart }

        // Port of `speedRegionsOverlapping` / `rangesOverlap`.
        func overlapping(_ clip: VideoClipRef) -> [VideoSpeedRegion] {
            project.speedRegions.filter { region in
                region.startTime < clip.sourceEnd + tolerance && region.endTime > clip.sourceStart - tolerance
            }
        }

        // Port of `dominantSpeed(for:)`.
        func dominantSpeed(_ clip: VideoClipRef) -> Double? {
            let span = clip.sourceEnd - clip.sourceStart
            guard span > 0.01 else { return nil }
            let covering = overlapping(clip)
                .map { region -> (Double, Double) in
                    let overlap = min(region.endTime, clip.sourceEnd) - max(region.startTime, clip.sourceStart)
                    return (region.speed, max(0, overlap) / span)
                }
                .max { $0.1 < $1.1 }
            guard let covering, covering.1 >= 0.6, abs(covering.0 - 1.0) > 0.01 else { return nil }
            return covering.0
        }

        // Port of `clipFillingSpeedRegion(for:)`.
        func fillingRegion(_ clip: VideoClipRef) -> VideoSpeedRegion? {
            let regions = overlapping(clip)
            guard regions.count == 1, let region = regions.first else { return nil }
            let startsAtClipStart = abs(region.startTime - clip.sourceStart) <= tolerance
            let endsAtClipEnd = abs(region.endTime - clip.sourceEnd) <= tolerance
            return startsAtClipStart || endsAtClipEnd ? region : nil
        }

        let clips: [TimelineVideoClipItem] = refs.map { clip in
            let fill = fillingRegion(clip)
            return TimelineVideoClipItem(
                ref: clip,
                isSelected: selectedClipID == clip.id,
                pillSpeedLabel: dominantSpeed(clip).map { formatSpeedLabel($0) },
                fillSpeed: fill?.speed,
                fillRegionID: fill?.id
            )
        }

        // Port of `segments(in:)`, per clip.
        var segments: [TimelineVideoSegmentItem] = []
        for clip in refs {
            for seg in timeMap.segments {
                let outputStart = max(seg.outputStart, clip.outputStart)
                let outputEnd = min(seg.outputEnd, clip.outputEnd)
                guard outputEnd > outputStart + 0.001 else { continue }
                let regionID: UUID? = seg.speed == 1.0 ? nil : project.speedRegions.first { region in
                    abs(region.startTime - seg.sourceStart) < 0.01 && abs(region.endTime - seg.sourceEnd) < 0.01
                }?.id
                segments.append(TimelineVideoSegmentItem(
                    id: "\(clip.id)-\(seg.sourceStart)-\(seg.sourceEnd)-\(outputStart)-\(outputEnd)",
                    clipID: clip.id,
                    sourceStart: timeMap.sourceTime(forOutput: outputStart),
                    sourceEnd: timeMap.sourceTime(forOutput: outputEnd),
                    outputStart: outputStart,
                    outputEnd: outputEnd,
                    speed: seg.speed,
                    regionID: regionID,
                    label: segmentLabel(outputSpan: outputEnd - outputStart, speed: seg.speed),
                    showsLeadingDivider: outputStart > clip.outputStart + 0.01,
                    startsAtSplit: outputSplits.contains { abs($0 - outputStart) < 0.05 }
                ))
            }
        }

        // Port of `joinedClipBoundaries`.
        var boundaries: [TimelineVideoBoundaryItem] = []
        if refs.count > 1 {
            for index in 0..<(refs.count - 1) {
                let left = refs[index]
                let right = refs[index + 1]
                guard abs(left.outputEnd - right.outputStart) <= 1.0 / 60.0 else { continue }
                boundaries.append(TimelineVideoBoundaryItem(
                    id: "\(left.id.uuidString)-\(right.id.uuidString)",
                    leftClipID: left.id,
                    rightClipID: right.id,
                    outputTime: (left.outputEnd + right.outputStart) / 2
                ))
            }
        }

        return TimelineVideoRowModel(
            regionStart: regionStart,
            regionEnd: regionEnd,
            usesWholeTrackDrag: refs.count <= 1,
            clips: clips,
            segments: segments,
            boundaries: boundaries,
            isMuted: project.settings.muteRecordedAudio,
            hasAudio: hasAudio,
            hasThumbnails: hasThumbnails,
            snapCandidates: snapCandidates
        )
    }
}

/// Heavy, non-Equatable render inputs (kept out of the diffed snapshot).
struct TimelineVideoAssets {
    var thumbnails: [TimelineThumbnail] = []
    var audioSamples: [Float] = []
    var sourceSegments: [ProjectSourceSegment] = []
    /// Source-time window the waveform samples cover (the trim window).
    var trimSourceStart: TimeInterval = 0
    var trimSourceEnd: TimeInterval = 0

    /// Cheap identity used to decide whether a redraw is needed.
    var renderKey: String {
        "\(thumbnails.count)/\(audioSamples.count)/\(sourceSegments.count)/\(trimSourceStart)/\(trimSourceEnd)"
    }
}

/// VIDEO-row mutations out of the canvas. Every entry lands in the SAME
/// undo-registering code the SwiftUI row uses (`VideoTrackCommits` for the
/// clip/trim edits, TimelineView's own functions for speed/split).
struct TimelineVideoCallbacks {
    var selectClip: (UUID?) -> Void = { _ in }
    /// Whole-track drag: (mode, delta, resolvedStart, resolvedEnd).
    var commitWholeDrag: (VideoTrackEditMath.DragMode, TimeInterval, TimeInterval, TimeInterval) -> Void = { _, _, _, _ in }
    var commitClipMove: (VideoClipRef, TimeInterval) -> Void = { _, _ in }
    var commitClipEdge: (VideoClipRef, VideoTrackEditMath.Side, TimeInterval) -> Void = { _, _, _ in }
    var toggleMute: () -> Void = {}
    /// (sourceStart, sourceEnd, speed)
    var addSpeedRange: (TimeInterval, TimeInterval, Double) -> Void = { _, _, _ in }
    var changeSpeed: (UUID, Double) -> Void = { _, _ in }
    var deleteSpeed: (UUID) -> Void = { _ in }
    /// Output time of the split to merge away.
    var deleteSplit: (TimeInterval) -> Void = { _ in }
    /// Slice tool commit — output time of the cut. Lands in TimelineView's
    /// undo-registered `splitVideoClip`, which also disarms the tool.
    var sliceAt: (TimeInterval) -> Void = { _ in }
}

// MARK: - Drag state

/// VIDEO-row drag state — separate from the generic block machine so the
/// EFFECTS/FOCUS/ANNOTATE lanes stay untouched.
struct VideoRowDrag {
    enum Kind: Equatable {
        case whole(VideoTrackEditMath.DragMode)
        case clipMove(VideoClipRef)
        case clipEdge(VideoClipRef, VideoTrackEditMath.Side)
        /// Joined boundary: the side is decided by the first horizontal
        /// movement, exactly like the SwiftUI hotspot.
        case boundary(TimelineVideoBoundaryItem)
    }

    var kind: Kind
    var startPoint: CGPoint
    var translationX: CGFloat = 0
    var didDrag = false
    /// Resolved boundary target once the direction is known.
    var boundaryResolved: (clip: VideoClipRef, side: VideoTrackEditMath.Side)?

    /// Per-gesture activation distance, mirroring each SwiftUI DragGesture's
    /// `minimumDistance` / guard.
    var threshold: CGFloat {
        switch kind {
        case .whole: return 3          // didDrag = |tx| > dragThreshold
        case .clipMove: return 3       // DragGesture(minimumDistance: 3)
        case .clipEdge: return 1       // highPriorityGesture(minimumDistance: 1)
        case .boundary: return 0.25    // guard abs(translation) > 0.25
        }
    }
}

// MARK: - Snapshot model (VOICE row)

/// One voice-over clip slab. `clip` carries OUTPUT time (already remapped by
/// `VoiceTrackCommits.outputClip`), which is exactly the value the SwiftUI
/// block view sees through its binding.
struct TimelineVoiceClipItem: Equatable {
    var clip: VoiceOverClip
    var isSelected: Bool

    var id: UUID { clip.id }
}

/// The live recording block. Its samples ride inside the Equatable model on
/// purpose: they arrive per meter update and every arrival must repaint.
struct TimelineVoiceLiveItem: Equatable {
    var startTime: TimeInterval
    var currentTime: TimeInterval
    var samples: [Float]
}

/// Everything the canvas needs to draw and edit the VOICE row natively.
/// Waveform sample arrays for committed clips ride outside (see
/// `TimelineVoiceAssets`); only the live recording samples live here.
struct TimelineVoiceRowModel: Equatable {
    var clips: [TimelineVoiceClipItem] = []
    var live: TimelineVoiceLiveItem?
    /// Output-time snap candidates. The dragged clip's own edges are filtered
    /// out by VALUE inside `VoiceTrackEditMath`, which is what the SwiftUI
    /// per-clip list did too — so one shared list is equivalent.
    var snapCandidates: [TimeInterval] = []

    func item(withID id: UUID) -> TimelineVoiceClipItem? {
        clips.first { $0.id == id }
    }

    /// Derives the row snapshot from the project. Every step is a port of the
    /// matching `VoiceOverTrackContent` expression, so the hosted row and the
    /// native row describe the same geometry. Lives here (not in TimelineView)
    /// so the screenshot harness renders exactly what ships.
    @MainActor
    static func make(
        project: Project,
        timeMap: SpeedTimeMap,
        outputDuration: TimeInterval,
        playheadTime: TimeInterval,
        selectedVoiceOverID: UUID?,
        isRecordingVoiceOver: Bool,
        recordingStartTime: TimeInterval?,
        recordingCurrentTime: TimeInterval,
        liveSamples: [Float]
    ) -> TimelineVoiceRowModel {
        let commits = VoiceTrackCommits(project: project, timeMap: timeMap)

        let clips = project.voiceOverClips.map { stored in
            TimelineVoiceClipItem(
                clip: commits.outputClip(for: stored),
                isSelected: selectedVoiceOverID == stored.id
            )
        }

        // Port of the `if isRecordingVoiceOver, let recordingStartTime, …` gate.
        var live: TimelineVoiceLiveItem?
        if isRecordingVoiceOver,
           let recordingStartTime,
           recordingCurrentTime > recordingStartTime,
           project.duration > 0 {
            live = TimelineVoiceLiveItem(
                startTime: timeMap.outputTime(forSource: recordingStartTime),
                currentTime: timeMap.outputTime(forSource: recordingCurrentTime),
                samples: liveSamples
            )
        }

        // Port of `snapCandidates(for:)`, minus the per-clip self-exclusion
        // (see `snapCandidates` above).
        var sources: [TimeInterval] = [
            project.effectiveTrimStart,
            project.effectiveTrimEnd,
            playheadTime,
        ]
        sources += project.zoomRegions.flatMap { [$0.startTime, $0.endTime] }
        sources += project.blurRegions.flatMap { [$0.startTime, $0.endTime] }
        sources += project.highlightRegions.flatMap { [$0.startTime, $0.endTime] }
        sources += project.voiceOverClips.flatMap { [$0.startTime, $0.endTime] }

        return TimelineVoiceRowModel(
            clips: clips,
            live: live,
            snapCandidates: sources.map { timeMap.outputTime(forSource: $0) }
        )
    }
}

/// Heavy, non-Equatable render inputs for the VOICE row (kept out of the
/// diffed snapshot): the per-clip waveforms the SwiftUI block loaded itself in
/// `.task(id: blockSignature)`. TimelineView owns the loading now; `signature`
/// is the same identity string the task keyed on.
nonisolated struct TimelineVoiceAssets {
    var waveforms: [UUID: [Float]] = [:]
    var signature: String = ""

    var renderKey: String { signature }

    /// Port of `VoiceOverClipBlockView.blockSignature`, per clip.
    static func signature(for clip: VoiceOverClip) -> String {
        "\(clip.fileName):\(clip.sourceStartTime):\(clip.duration):\(clip.sourceDuration):\(clip.gain)"
    }
}

/// VOICE-row mutations out of the canvas. Scrub/seek reuse the generic
/// `TimelineCanvasCallbacks`, exactly as the hosted row reused TimelineView's
/// `onScrub` / `onSeek`.
struct TimelineVoiceCallbacks {
    var selectClip: (UUID?) -> Void = { _ in }
    /// (clip id, resolved OUTPUT-time clip value) — lands in `VoiceTrackCommits`.
    var commitClip: (UUID, VoiceOverClip) -> Void = { _, _ in }
    var deleteClip: (UUID) -> Void = { _ in }
}

// MARK: - Drag state

/// VOICE-row drag state — its own machine so the VIDEO lane and the generic
/// block lanes stay untouched.
struct VoiceRowDrag {
    /// The clip value captured at mouse-down, in OUTPUT time.
    var initial: VoiceOverClip
    var mode: VoiceTrackEditMath.Mode
    var startPoint: CGPoint
    var translationX: CGFloat = 0
    var didDrag = false

    /// `VoiceOverClipBlockView.dragThreshold` — a 2D distance, not |dx|.
    static let threshold: CGFloat = 3
}

