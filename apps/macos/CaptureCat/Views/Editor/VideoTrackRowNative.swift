import AppKit

// MARK: - Snapshot model (VIDEO row)

/// A clip span in both source and output time — the value both the SwiftUI row
/// and the native row hand to `VideoTrackCommits`, so the two cannot drift.
struct VideoClipRef: Equatable {
    var id: UUID
    var sourceStart: TimeInterval
    var sourceEnd: TimeInterval
    var outputStart: TimeInterval
    var outputEnd: TimeInterval

    var outputDuration: TimeInterval { outputEnd - outputStart }

    var span: VideoTrackEditMath.ClipSpan {
        VideoTrackEditMath.ClipSpan(id: id, outputStart: outputStart, outputEnd: outputEnd)
    }
}

// MARK: - Slice tool math

/// Slice-tool geometry, shared by the SwiftUI overlay and the native canvas so
/// a click at a given x resolves to the SAME split time in both — the same
/// no-drift contract `VideoTrackEditMath` gives the drag gestures.
enum VideoSliceMath {
    /// A cut must leave at least this much on both sides.
    static let minSliceDuration: TimeInterval = 0.2
    /// Cursor distance within which the cut snaps onto the playhead.
    static let playheadSnapDistance: CGFloat = 12

    struct Target: Equatable {
        var outputTime: TimeInterval
        var x: CGFloat
        var snappedToPlayhead: Bool
    }

    /// Port of `TimelineView.resolvedSliceTarget`.
    static func resolvedTarget(
        atX x: CGFloat,
        trackWidth: CGFloat,
        outputDuration: TimeInterval,
        playheadOutputTime: TimeInterval
    ) -> Target {
        let clampedX = max(0, min(trackWidth, x))
        guard trackWidth > 0, outputDuration > 0 else {
            return Target(outputTime: 0, x: clampedX, snappedToPlayhead: false)
        }
        let rawOutputTime = max(0, min(1, clampedX / trackWidth)) * outputDuration
        let playheadX = trackWidth * CGFloat(playheadOutputTime / outputDuration)

        if abs(clampedX - playheadX) <= playheadSnapDistance {
            return Target(outputTime: playheadOutputTime, x: playheadX, snappedToPlayhead: true)
        }
        return Target(outputTime: rawOutputTime, x: clampedX, snappedToPlayhead: false)
    }

    /// Port of `TimelineView.isSliceableOutputTime`.
    static func isSliceable(
        _ outputTime: TimeInterval,
        trimStartOutput: TimeInterval,
        trimEndOutput: TimeInterval,
        clipSpans: [VideoTrackEditMath.ClipSpan]
    ) -> Bool {
        guard outputTime > trimStartOutput + minSliceDuration,
              outputTime < trimEndOutput - minSliceDuration else {
            return false
        }
        return clipSpans.contains { clip in
            outputTime - clip.outputStart >= minSliceDuration
                && clip.outputEnd - outputTime >= minSliceDuration
        }
    }
}

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

// MARK: - Shared commit logic

/// The VIDEO row's model mutations + undo registration, extracted so the
/// SwiftUI row and the native canvas row commit IDENTICALLY — the same pattern
/// `VideoTrackEditMath` applies to the geometry. Times in are OUTPUT time.
@MainActor
struct VideoTrackCommits {
    let project: Project
    let timeMap: SpeedTimeMap
    let undoManager: UndoManager?
    /// Output duration of the trimmed recording.
    let outputDuration: TimeInterval
    var minDuration: TimeInterval = 0.5
    var edgeAttachmentTolerance: TimeInterval = 1.0 / 15.0

    // MARK: Whole-track trim / slip

    /// Verbatim port of VideoTrackContent's whole-track drag `onEnded`.
    /// `resolvedStart`/`resolvedEnd` come from `VideoTrackEditMath.resolvedTimes`.
    func commitWholeDrag(
        mode: VideoTrackEditMath.DragMode,
        delta: TimeInterval,
        resolvedStart: TimeInterval,
        resolvedEnd: TimeInterval
    ) {
        guard mode != .none else { return }
        let prevStart = project.trimStart
        let prevEnd = project.trimEnd
        let sourceStart = project.effectiveTrimStart
        let sourceEnd = project.effectiveTrimEnd

        switch mode {
        case .move:
            // The clip fills the trimmed timeline, so dragging the body slips
            // the trim window through the source.
            let windowLength = max(minDuration, sourceEnd - sourceStart)
            let newStart = min(
                max(0, sourceStart + delta),
                max(0, project.duration - windowLength)
            )
            project.trimStart = newStart
            project.trimEnd = newStart + windowLength
        case .resizeLeft:
            // Negative output time reaches into the trimmed-off head — extend
            // the trim earlier (head plays at 1×).
            let newSourceStart = resolvedStart >= 0
                ? timeMap.sourceTime(forOutput: resolvedStart)
                : max(0, sourceStart + resolvedStart)
            project.trimStart = min(newSourceStart, sourceEnd - minDuration)
        case .resizeRight:
            let newSourceEnd = resolvedEnd <= outputDuration
                ? timeMap.sourceTime(forOutput: resolvedEnd)
                : min(project.duration, sourceEnd + (resolvedEnd - outputDuration))
            project.trimEnd = max(newSourceEnd, sourceStart + minDuration)
        case .none:
            return
        }

        undoManager?.registerUndo(withTarget: project) { p in
            p.trimStart = prevStart
            p.trimEnd = prevEnd
        }
        undoManager?.setActionName(mode == .move ? "Slip Clip" : "Trim")
    }

    // MARK: Per-clip move / edge resize

    /// Port of `commitClipMove` — `resolvedStart` is already math-resolved.
    func commitClipMove(_ clip: VideoClipRef, resolvedOutputStart: TimeInterval) {
        guard abs(resolvedOutputStart - clip.outputStart) > 0.001 else { return }
        let resolvedEnd = resolvedOutputStart + clip.outputDuration
        updateClip(clip, actionName: "Move Clip") { segment in
            segment.startTime = timeMap.sourceTime(forOutput: resolvedOutputStart)
            segment.endTime = timeMap.sourceTime(forOutput: resolvedEnd)
        }
    }

    /// Port of `commitClipEdgeResize` + `setClipStart` / `setClipEnd`.
    func commitClipEdge(
        _ clip: VideoClipRef,
        side: VideoTrackEditMath.Side,
        resolvedOutput: TimeInterval
    ) {
        let original = side == .left ? clip.outputStart : clip.outputEnd
        guard abs(resolvedOutput - original) > 0.001 else { return }
        switch side {
        case .left:
            let sourceStart = min(timeMap.sourceTime(forOutput: resolvedOutput), clip.sourceEnd - minDuration)
            updateClip(clip, edgeSide: .left) { $0.startTime = sourceStart }
        case .right:
            let sourceEnd = max(timeMap.sourceTime(forOutput: resolvedOutput), clip.sourceStart + minDuration)
            updateClip(clip, edgeSide: .right) { $0.endTime = sourceEnd }
        }
    }

    /// Port of `VideoTrackContent.updateClip` — the single mutation funnel.
    private func updateClip(
        _ clip: VideoClipRef,
        actionName: String = "Resize Clip",
        edgeSide: VideoTrackEditMath.Side? = nil,
        mutate: (inout VideoClipSegment) -> Void
    ) {
        let previousClips = project.videoClipSegments
        let previousSplits = project.splitPoints
        let previousSpeedRegions = project.speedRegions
        var clips = project.videoClipSegments.isEmpty ? project.effectiveVideoClipSegments : project.videoClipSegments
        guard let index = clips.firstIndex(where: {
            $0.id == clip.id
                || (abs($0.startTime - clip.sourceStart) < 0.01 && abs($0.endTime - clip.sourceEnd) < 0.01)
        }) else { return }

        mutate(&clips[index])
        clips[index].startTime = max(0, min(clips[index].startTime, project.duration))
        clips[index].endTime = max(clips[index].startTime + minDuration, min(clips[index].endTime, project.duration))
        project.videoClipSegments = clips
        if let edgeSide {
            updateSpeedRegionsAnchoredToClipEdge(
                originalClip: clip,
                updatedClip: clips[index],
                side: edgeSide
            )
        }

        project.splitPoints = clips.dropFirst().map(\.startTime).sorted()

        undoManager?.registerUndo(withTarget: project) { p in
            p.videoClipSegments = previousClips
            p.splitPoints = previousSplits
            p.speedRegions = previousSpeedRegions
        }
        undoManager?.setActionName(actionName)
    }

    /// Port of `updateSpeedRegionsAnchoredToClipEdge`.
    private func updateSpeedRegionsAnchoredToClipEdge(
        originalClip: VideoClipRef,
        updatedClip: VideoClipSegment,
        side: VideoTrackEditMath.Side
    ) {
        let overlappingIndices = project.speedRegions.indices.filter { index in
            let region = project.speedRegions[index]
            return region.startTime < originalClip.sourceEnd + edgeAttachmentTolerance
                && region.endTime > originalClip.sourceStart - edgeAttachmentTolerance
        }
        guard !overlappingIndices.isEmpty else { return }

        let onlySpeedRegionInClip = overlappingIndices.count == 1
        for index in overlappingIndices {
            let region = project.speedRegions[index]
            let startsAtClipStart = abs(region.startTime - originalClip.sourceStart) <= edgeAttachmentTolerance
            let endsAtClipEnd = abs(region.endTime - originalClip.sourceEnd) <= edgeAttachmentTolerance

            switch side {
            case .left:
                guard endsAtClipEnd || (onlySpeedRegionInClip && startsAtClipStart) else { continue }
                project.speedRegions[index].startTime = min(
                    updatedClip.startTime,
                    project.speedRegions[index].endTime - minDuration
                )
            case .right:
                guard startsAtClipStart || (onlySpeedRegionInClip && endsAtClipEnd) else { continue }
                project.speedRegions[index].endTime = max(
                    updatedClip.endTime,
                    project.speedRegions[index].startTime + minDuration
                )
            }
        }
    }
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

// MARK: - Geometry, hit testing, drawing

extension TimelineCanvasView {
    private typealias VM = TimelineCanvasMetrics

    /// The exact colours the hosted row fills with, resolved once. (Verified
    /// against a screenshot of both rows normalised to sRGB: flat slab fill
    /// matches within 10/255 on one channel, mean 2.6/255 over the whole row.)
    static let videoYellow = NSColor.systemYellow
    static let videoOrange = NSColor.systemOrange

    /// Outer hit zone of the whole-track resize handles (SwiftUI `handleWidth`).
    static let videoHandleWidth: CGFloat = 12
    /// SwiftUI `ClipEdgeHandle` frame width: hitWidth 18 + gripInset 5.
    static let videoClipHandleWidth: CGFloat = 23
    static let videoClipHandleHeight: CGFloat = 32
    static let videoBoundaryHitWidth: CGFloat = 30
    static let videoMuteTrailingInset: CGFloat = 18

    var videoLaneRect: CGRect {
        CGRect(x: 0, y: VM.videoLaneY, width: bounds.width, height: VM.trackHeight)
    }

    /// The math struct for the current model — identical inputs to the SwiftUI
    /// row's `editMath`.
    func videoEditMath(_ model: TimelineVideoRowModel) -> VideoTrackEditMath {
        VideoTrackEditMath(
            duration: snapshot.outputDuration,
            trackWidth: bounds.width,
            snapCandidates: model.snapCandidates,
            regionStart: model.regionStart,
            regionEnd: model.regionEnd,
            minDuration: VM.minDuration
        )
    }

    /// Output-time delta for the live drag translation.
    func videoDragDelta(_ translationX: CGFloat) -> TimeInterval {
        TimeInterval(translationX) * snapshot.outputDuration / TimeInterval(max(1, bounds.width))
    }

    // MARK: Block geometry (port of blockOffsetX / blockWidth)

    /// The yellow block's drawn origin+width. Mirrors `VideoTrackContent`'s
    /// `blockOffsetX` / `blockWidth` EXACTLY, including their deliberately
    /// unsnapped, clamped preview math (the committed edges get the snapped
    /// values from `VideoTrackEditMath` on mouse-up).
    func videoBlockGeometry(_ model: TimelineVideoRowModel, preview: Bool = true) -> (x: CGFloat, width: CGFloat) {
        let duration = snapshot.outputDuration
        let width = bounds.width
        guard duration > 0, width > 0 else { return (0, max(40, width)) }

        var mode = VideoTrackEditMath.DragMode.none
        var delta: TimeInterval = 0
        if preview, let drag = videoDrag, case .whole(let m) = drag.kind, m != .none {
            mode = m
            delta = videoDragDelta(drag.translationX)
        }

        let initialStart = model.regionStart
        let initialEnd = model.regionEnd
        let minDuration = VM.minDuration

        let start: TimeInterval
        let end: TimeInterval
        switch mode {
        case .resizeLeft:
            start = max(0, min(initialEnd - minDuration, initialStart + delta))
            end = initialEnd
        case .resizeRight:
            start = initialStart
            end = max(initialStart + minDuration, min(duration, initialEnd + delta))
        case .move:
            let clipDuration = initialEnd - initialStart
            let maxStart = max(0, duration - clipDuration)
            start = min(max(0, initialStart + delta), maxStart)
            end = min(duration, start + clipDuration)
        case .none:
            start = model.regionStart
            end = model.regionEnd
        }

        // blockOffsetX anchors at the initial start while resizing the right edge.
        let originTime = mode == .resizeRight ? initialStart : start
        return (
            x: width * CGFloat(originTime / duration),
            width: max(40, width * CGFloat((end - start) / duration))
        )
    }

    /// Rect of a clip inside the (possibly previewed) block — port of
    /// `clipOffset` / `clipWidth`.
    func videoClipRect(
        _ clip: VideoClipRef,
        model: TimelineVideoRowModel,
        block: (x: CGFloat, width: CGFloat)
    ) -> CGRect {
        let span = model.span
        let x = block.x + max(0, CGFloat((clip.outputStart - model.regionStart) / span) * block.width)
        let w = max(0, CGFloat(clip.outputDuration / span) * block.width)
        return CGRect(x: x, y: VM.videoLaneY, width: w, height: VM.trackHeight)
    }

    /// X of an output time inside the block — port of `outputOffset`.
    func videoOutputOffsetX(
        _ outputTime: TimeInterval,
        model: TimelineVideoRowModel,
        block: (x: CGFloat, width: CGFloat)
    ) -> CGFloat {
        block.x + max(0, CGFloat((outputTime - model.regionStart) / model.span) * block.width)
    }

    /// Live clip span during a per-clip drag — port of `displayClip(for:)`
    /// (`snapsToCandidates: false`, so the preview follows the cursor).
    func videoDisplayClip(_ clip: VideoClipRef, model: TimelineVideoRowModel) -> VideoClipRef {
        guard let drag = videoDrag, drag.didDrag, snapshot.outputDuration > 0 else { return clip }
        let math = videoEditMath(model)
        let spans = model.clipSpans
        let deltaOutput = videoDragDelta(drag.translationX)

        func edge(_ side: VideoTrackEditMath.Side) -> VideoClipRef {
            let original = side == .left ? clip.outputStart : clip.outputEnd
            let resolved = math.resolvedClipEdgeOutput(
                clip.span, in: spans, side: side,
                proposedOutput: original + deltaOutput,
                snapsToCandidates: false
            )
            var out = clip
            if side == .left { out.outputStart = resolved } else { out.outputEnd = resolved }
            return out
        }

        switch drag.kind {
        case .clipMove(let c) where c.id == clip.id:
            let start = math.resolvedClipMoveOutputStart(
                clip.span, in: spans,
                proposedOutputStart: clip.outputStart + deltaOutput,
                snapsToCandidates: false
            )
            var out = clip
            out.outputStart = start
            out.outputEnd = start + clip.outputDuration
            return out
        case .clipEdge(let c, let side) where c.id == clip.id:
            return edge(side)
        case .boundary:
            guard let target = drag.boundaryResolved, target.clip.id == clip.id else { return clip }
            return edge(target.side)
        default:
            return clip
        }
    }

    // MARK: Hit testing

    /// Mute button rect — top-trailing of the block, 18pt trailing inset.
    func videoMuteRect(_ model: TimelineVideoRowModel) -> CGRect? {
        guard model.hasAudio else { return nil }
        let block = videoBlockGeometry(model, preview: false)
        let size = Self.videoMuteSymbolSize(muted: model.isMuted)
        let w = size.width + 10
        let h = size.height + 10
        return CGRect(
            x: block.x + block.width - Self.videoMuteTrailingInset - w,
            y: VM.videoLaneY,
            width: w,
            height: h
        )
    }

    /// Clip whose committed body contains the point.
    func videoClip(at point: CGPoint, model: TimelineVideoRowModel) -> TimelineVideoClipItem? {
        let block = videoBlockGeometry(model, preview: false)
        return model.clips.first { clip in
            videoClipRect(clip.ref, model: model, block: block).contains(point)
        }
    }

    /// Mirrors the SwiftUI hit order: boundary hotspots (top of the ZStack and
    /// high-priority) → per-clip edge handles (high-priority overlays) → clip
    /// body → the whole-track block gesture.
    func videoDragKind(at point: CGPoint, model: TimelineVideoRowModel) -> VideoRowDrag.Kind? {
        guard videoLaneRect.contains(point) else { return nil }
        let block = videoBlockGeometry(model, preview: false)

        if model.usesWholeTrackDrag {
            // ≤1 clip: the block trims/slips as one. Per-clip gestures collapse
            // to no-ops here (move bounds are degenerate), so the whole-track
            // machine owns the lane — matching `guard usesWholeTrackDrag`.
            let rect = CGRect(x: block.x, y: VM.videoLaneY, width: block.width, height: VM.trackHeight)
            guard rect.contains(point) else { return nil }
            let localX = min(max(point.x - rect.minX, 0), rect.width)
            if localX < Self.videoHandleWidth { return .whole(.resizeLeft) }
            if localX > rect.width - Self.videoHandleWidth { return .whole(.resizeRight) }
            return .whole(.move)
        }

        // Joined-boundary hotspot: 30pt wide, full lane height.
        for boundary in model.boundaries {
            let bx = videoOutputOffsetX(boundary.outputTime, model: model, block: block)
            if abs(point.x - bx) <= Self.videoBoundaryHitWidth / 2 { return .boundary(boundary) }
        }

        // Per-clip edge handles: 23 × 32, vertically centred on the lane.
        let handleTop = VM.videoLaneY + (VM.trackHeight - Self.videoClipHandleHeight) / 2
        let handleBottom = handleTop + Self.videoClipHandleHeight
        for clip in model.clips {
            let rect = videoClipRect(clip.ref, model: model, block: block)
            guard point.x >= rect.minX, point.x <= rect.maxX else { continue }
            if point.y >= handleTop, point.y <= handleBottom {
                if point.x - rect.minX <= Self.videoClipHandleWidth { return .clipEdge(clip.ref, .left) }
                if rect.maxX - point.x <= Self.videoClipHandleWidth { return .clipEdge(clip.ref, .right) }
            }
            return .clipMove(clip.ref)
        }
        return nil
    }

    // MARK: Drag lifecycle (driven by the canvas mouse state machine)

    /// Returns true when the VIDEO lane consumed the event.
    @discardableResult
    func videoMouseDown(at point: CGPoint, model: TimelineVideoRowModel) -> Bool {
        guard videoLaneRect.contains(point), snapshot.outputDuration > 0 else { return false }

        if let mute = videoMuteRect(model), mute.contains(point) {
            videoCallbacks?.toggleMute()
            return true
        }

        guard let kind = videoDragKind(at: point, model: model) else {
            videoPendingDeselect = true
            return true
        }
        videoPendingDeselect = false
        videoDrag = VideoRowDrag(kind: kind, startPoint: point)
        return true
    }

    func videoMouseDragged(to point: CGPoint) {
        guard var drag = videoDrag else { return }
        drag.translationX = point.x - drag.startPoint.x
        if abs(drag.translationX) > drag.threshold { drag.didDrag = true }

        // Boundary: the first meaningful horizontal movement picks the side.
        if case .boundary(let boundary) = drag.kind,
           drag.boundaryResolved == nil,
           abs(drag.translationX) > 0.25,
           let model = videoModel {
            if drag.translationX < 0 {
                if let clip = model.clip(withID: boundary.leftClipID) {
                    drag.boundaryResolved = (clip.ref, .right)
                }
            } else if let clip = model.clip(withID: boundary.rightClipID) {
                drag.boundaryResolved = (clip.ref, .left)
            }
        }
        videoDrag = drag
        // Everything this row draws lives inside the lane rect, so a drag
        // repaint never has to touch the ruler or the other lanes.
        setNeedsDisplay(videoLaneRect)
    }

    func videoMouseUp(at point: CGPoint, model: TimelineVideoRowModel) {
        if videoPendingDeselect {
            videoPendingDeselect = false
            if videoDrag == nil {
                videoCallbacks?.selectClip(nil)
                return
            }
        }
        guard var drag = videoDrag else { return }
        drag.translationX = point.x - drag.startPoint.x
        if abs(drag.translationX) > drag.threshold { drag.didDrag = true }
        defer {
            videoDrag = nil
            setNeedsDisplay(videoLaneRect)
        }

        let delta = videoDragDelta(drag.translationX)
        let math = videoEditMath(model)
        let spans = model.clipSpans

        switch drag.kind {
        case .whole(let mode):
            guard drag.didDrag else {
                videoCallbacks?.selectClip(videoClip(at: point, model: model)?.id)
                return
            }
            let resolved = math.resolvedTimes(
                mode: mode,
                delta: delta,
                dragInitialStart: model.regionStart,
                dragInitialEnd: model.regionEnd
            )
            videoCallbacks?.commitWholeDrag(mode, delta, resolved.start, resolved.end)
        case .clipMove(let clip):
            guard drag.didDrag else {
                videoCallbacks?.selectClip(clip.id)
                return
            }
            let resolved = math.resolvedClipMoveOutputStart(
                clip.span, in: spans,
                proposedOutputStart: clip.outputStart + delta
            )
            videoCallbacks?.commitClipMove(clip, resolved)
        case .clipEdge(let clip, let side):
            guard drag.didDrag else {
                videoCallbacks?.selectClip(clip.id)
                return
            }
            let original = side == .left ? clip.outputStart : clip.outputEnd
            let resolved = math.resolvedClipEdgeOutput(
                clip.span, in: spans, side: side,
                proposedOutput: original + delta
            )
            videoCallbacks?.commitClipEdge(clip, side, resolved)
        case .boundary:
            guard drag.didDrag, let target = drag.boundaryResolved else { return }
            let clip = target.clip
            let original = target.side == .left ? clip.outputStart : clip.outputEnd
            let resolved = math.resolvedClipEdgeOutput(
                clip.span, in: spans, side: target.side,
                proposedOutput: original + delta
            )
            videoCallbacks?.commitClipEdge(clip, target.side, resolved)
        }
    }

    /// Hover cursor for the VIDEO lane, or nil to leave the cursor alone.
    func videoHoverCursor(at point: CGPoint, model: TimelineVideoRowModel) -> NSCursor? {
        guard videoLaneRect.contains(point) else { return nil }
        if let mute = videoMuteRect(model), mute.contains(point) { return .arrow }
        switch videoDragKind(at: point, model: model) {
        case .whole(.resizeLeft), .whole(.resizeRight), .clipEdge, .boundary:
            return .resizeLeftRight
        default:
            return .arrow
        }
    }

    // MARK: Context menu

    func videoSegment(at point: CGPoint, model: TimelineVideoRowModel) -> TimelineVideoSegmentItem? {
        guard let clip = videoClip(at: point, model: model) else { return nil }
        let block = videoBlockGeometry(model, preview: false)
        let rect = videoClipRect(clip.ref, model: model, block: block)
        guard rect.width > 0 else { return nil }
        let fraction = min(max((point.x - rect.minX) / rect.width, 0), 1)
        let time = clip.outputStart + TimeInterval(fraction) * clip.outputDuration
        let inClip = model.segments.filter { $0.clipID == clip.id }
        return inClip.first { time >= $0.outputStart && time <= $0.outputEnd } ?? inClip.last
    }

    func videoContextMenu(at point: CGPoint, model: TimelineVideoRowModel) -> NSMenu? {
        guard videoLaneRect.contains(point), let segment = videoSegment(at: point, model: model) else { return nil }

        let menu = NSMenu()
        if let regionID = segment.regionID {
            let change = NSMenuItem(title: "Change Speed", action: nil, keyEquivalent: "")
            let sub = NSMenu(title: "Change Speed")
            for level in TimelineVideoRowModel.speedPresets {
                sub.addItem(VideoRowMenuItem(title: TimelineVideoRowModel.formatSpeedLabel(level)) { [weak self] in
                    self?.videoCallbacks?.changeSpeed(regionID, level)
                })
            }
            change.submenu = sub
            menu.addItem(change)
            menu.addItem(.separator())
            menu.addItem(VideoRowMenuItem(title: "Remove Speed", destructive: true) { [weak self] in
                self?.videoCallbacks?.deleteSpeed(regionID)
            })
        } else {
            let set = NSMenuItem(title: "Set Speed", action: nil, keyEquivalent: "")
            let sub = NSMenu(title: "Set Speed")
            for level in TimelineVideoRowModel.speedPresets {
                sub.addItem(VideoRowMenuItem(title: TimelineVideoRowModel.formatSpeedLabel(level)) { [weak self] in
                    self?.videoCallbacks?.addSpeedRange(segment.sourceStart, segment.sourceEnd, level)
                })
            }
            set.submenu = sub
            menu.addItem(set)
        }
        if segment.startsAtSplit {
            menu.addItem(.separator())
            menu.addItem(VideoRowMenuItem(title: "Remove Split at Start", destructive: true) { [weak self] in
                self?.videoCallbacks?.deleteSplit(segment.outputStart)
            })
        }
        return menu
    }

    // MARK: - Drawing

    func drawVideoLane(in context: CGContext, model: TimelineVideoRowModel) {
        guard snapshot.outputDuration > 0, bounds.width > 0 else { return }
        let block = videoBlockGeometry(model)

        context.saveGState()
        // `.opacity(dragMode != .none && didDrag ? 0.8 : 1)` — whole-track only.
        if let drag = videoDrag, case .whole = drag.kind, drag.didDrag {
            context.setAlpha(0.8)
        }

        for clip in model.clips {
            let display = videoDisplayClip(clip.ref, model: model)
            drawVideoClip(clip, display: display, model: model, block: block, in: context)
        }

        drawVideoMuteButton(model, in: context)
        context.restoreGState()
    }

    private func drawVideoClip(
        _ clip: TimelineVideoClipItem,
        display: VideoClipRef,
        model: TimelineVideoRowModel,
        block: (x: CGFloat, width: CGFloat),
        in context: CGContext
    ) {
        let rect = videoClipRect(display, model: model, block: block)
        guard rect.width > 0.5 else { return }

        let hasFilmstrip = model.hasThumbnails && !videoAssets.thumbnails.isEmpty
        let hover = videoIsHovering
        let path = CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil)

        context.saveGState()
        context.addPath(path)
        context.clip()

        // Base slab: black wash under the filmstrip, yellow otherwise.
        let base = hasFilmstrip
            ? NSColor.black.withAlphaComponent(0.4)
            : Self.videoYellow.withAlphaComponent(hover ? 0.45 : 0.35)
        context.setFillColor(base.cgColor)
        context.fill(rect)

        if hasFilmstrip {
            drawVideoFilmstrip(in: context, rect: rect, sourceStart: display.sourceStart, sourceEnd: display.sourceEnd)
        }

        for segment in videoDisplaySegments(for: clip, display: display, model: model) {
            drawVideoSegment(segment, clip: display, clipRect: rect, hasFilmstrip: hasFilmstrip, in: context)
        }

        if model.hasAudio {
            drawVideoWaveform(in: context, rect: rect, clip: display, isMuted: model.isMuted, hasFilmstrip: hasFilmstrip)
        }

        if rect.width > 80 {
            drawVideoInfoPill(clip: clip, display: display, rect: rect, in: context)
        }
        context.restoreGState()

        // Hairline + selection border (SwiftUI strokeBorder ⇒ inside the shape).
        // These strokes separate the clip from the PANEL background, so they
        // follow the theme ink; everything drawn over the filmstrip/slab
        // (waveform, pill, labels, grips) keeps its fixed contrast.
        let ink: NSColor = CCTheme.isDark ? .white : .black
        strokeVideoRounded(rect, radius: 8, color: ink.withAlphaComponent(0.10), width: 1, in: context)
        if clip.isSelected {
            strokeVideoRounded(rect, radius: 8, color: ink.withAlphaComponent(0.85), width: 2, in: context)
        }

        drawVideoEdgeGrips(rect: rect, in: context)
    }

    /// Port of `clipDisplaySegments(in:committedClip:)` — a clip fully covered
    /// by one speed region renders as a single retimed slab; otherwise the
    /// committed sub-segments are mapped into the (possibly resized) slab.
    private func videoDisplaySegments(
        for clip: TimelineVideoClipItem,
        display: VideoClipRef,
        model: TimelineVideoRowModel
    ) -> [TimelineVideoSegmentItem] {
        if let speed = clip.fillSpeed {
            return [TimelineVideoSegmentItem(
                id: "\(clip.id)-fill",
                clipID: clip.id,
                sourceStart: display.sourceStart,
                sourceEnd: display.sourceEnd,
                outputStart: display.outputStart,
                outputEnd: display.outputEnd,
                speed: speed,
                regionID: clip.fillRegionID,
                label: TimelineVideoRowModel.segmentLabel(outputSpan: display.outputDuration, speed: speed),
                showsLeadingDivider: false,
                startsAtSplit: false
            )]
        }
        return model.segments.filter { $0.clipID == clip.id }
    }

    private func drawVideoSegment(
        _ segment: TimelineVideoSegmentItem,
        clip: VideoClipRef,
        clipRect: CGRect,
        hasFilmstrip: Bool,
        in context: CGContext
    ) {
        // Committed segments are mapped proportionally into the drawn slab —
        // during a live resize the sub-segments stretch with the clip.
        let clipSpan = max(0.0001, clip.outputDuration)
        let f0 = min(max((segment.outputStart - clip.outputStart) / clipSpan, 0), 1)
        let f1 = min(max((segment.outputEnd - clip.outputStart) / clipSpan, 0), 1)
        let rect = CGRect(
            x: clipRect.minX + clipRect.width * CGFloat(f0),
            y: clipRect.minY,
            width: clipRect.width * CGFloat(max(0, f1 - f0)),
            height: clipRect.height
        )
        guard rect.width > 0.5 else { return }

        let hover = videoIsHovering
        let isSpeed = segment.speed != 1.0
        if isSpeed {
            context.setFillColor(Self.videoYellow.withAlphaComponent(hover ? 0.65 : 0.55).cgColor)
            context.fill(rect)
        } else if !hasFilmstrip {
            context.setFillColor(Self.videoYellow.withAlphaComponent(hover ? 0.45 : 0.35).cgColor)
            context.fill(rect)
        }

        if segment.showsLeadingDivider {
            context.setFillColor(Self.videoOrange.withAlphaComponent(0.6).cgColor)
            context.fill(CGRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height))
        }

        guard isSpeed else { return }
        let color = NSColor.black.withAlphaComponent(0.85)
        let combined = NSMutableAttributedString()
        if let gauge = Self.tintedSymbol("gauge.with.needle", pointSize: 10, weight: .bold, color: color) {
            let attachment = NSTextAttachment()
            attachment.image = gauge
            attachment.bounds = CGRect(x: 0, y: -2, width: gauge.size.width, height: gauge.size.height)
            combined.append(NSAttributedString(attachment: attachment))
            combined.append(NSAttributedString(string: " "))
        }
        combined.append(NSAttributedString(string: segment.label, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold),
            .foregroundColor: color,
        ]))
        let size = combined.size()
        guard size.width <= rect.width - 12 else { return }
        combined.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }

    /// Port of `ClipFilmstripCanvas` — tiles cached CGImages across the clip.
    /// The thumbnails come straight from the existing timeline cache; nothing
    /// is decoded or regenerated here.
    private func drawVideoFilmstrip(
        in context: CGContext,
        rect: CGRect,
        sourceStart: TimeInterval,
        sourceEnd: TimeInterval
    ) {
        let thumbnails = videoAssets.thumbnails
        guard let first = thumbnails.first, rect.height > 0, rect.width > 0 else { return }
        let baseAspect = first.aspectRatio
        let span = max(0.0001, sourceEnd - sourceStart)

        var x: CGFloat = rect.minX
        while x < rect.maxX {
            let probeWidth = max(12, rect.height * baseAspect)
            let fraction = ((x - rect.minX) + probeWidth / 2) / rect.width
            let time = sourceStart + Double(fraction) * span

            guard let thumb = TimelineThumbnailer.thumbnail(at: time, in: thumbnails) else {
                x += probeWidth
                continue
            }

            var image = thumb.image
            var aspect = thumb.aspectRatio
            if let normalized = videoDeviceContentRect(at: time) {
                let pixelRect = CGRect(
                    x: normalized.minX * CGFloat(image.width),
                    y: normalized.minY * CGFloat(image.height),
                    width: normalized.width * CGFloat(image.width),
                    height: normalized.height * CGFloat(image.height)
                )
                if let cropped = image.cropping(to: pixelRect) {
                    image = cropped
                    aspect = pixelRect.height > 0 ? pixelRect.width / pixelRect.height : aspect
                }
            }

            let tileWidth = max(10, rect.height * aspect)
            // Flipped view: un-flip per tile so frames aren't upside down.
            context.saveGState()
            context.translateBy(x: x, y: rect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: tileWidth, height: rect.height))
            context.restoreGState()
            x += tileWidth
        }
    }

    private func videoDeviceContentRect(at time: TimeInterval) -> CGRect? {
        videoAssets.sourceSegments.first {
            $0.kind == .device && time >= $0.startTime && time <= $0.endTime
        }?.normalizedContentRect
    }

    /// Port of `ClipWaveformCanvas` + the padding its host applies.
    private func drawVideoWaveform(
        in context: CGContext,
        rect: CGRect,
        clip: VideoClipRef,
        isMuted: Bool,
        hasFilmstrip: Bool
    ) {
        let samples = videoClipAudioSamples(clip)
        guard !samples.isEmpty else { return }

        let waveHeight: CGFloat = hasFilmstrip ? 14 : 40
        let hPad: CGFloat = hasFilmstrip ? 4 : min(18, max(4, rect.width * 0.12))
        let bPad: CGFloat = hasFilmstrip ? 2 : 4
        let waveRect = CGRect(
            x: rect.minX + hPad,
            y: rect.maxY - bPad - waveHeight,
            width: rect.width - hPad * 2,
            height: waveHeight
        )
        guard waveRect.width > 1 else { return }

        let centerY = waveRect.midY
        let maxBarHeight = waveRect.height - 8
        let barWidth = max(1, waveRect.width / CGFloat(max(samples.count, 1)))
        context.setFillColor(NSColor.white.withAlphaComponent(isMuted ? 0.12 : 0.42).cgColor)

        for (index, sample) in samples.enumerated() {
            let amplitude = CGFloat(max(0, min(1, sample)))
            let height = amplitude * maxBarHeight
            guard height >= 1 else { continue }
            let bar = CGRect(
                x: waveRect.minX + CGFloat(index) * barWidth,
                y: centerY - height / 2,
                width: max(1, barWidth - 1),
                height: height
            )
            let radius = min(2, bar.width / 2)
            context.addPath(CGPath(roundedRect: bar, cornerWidth: radius, cornerHeight: radius, transform: nil))
        }
        context.fillPath()

        if isMuted {
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.4).cgColor)
            context.setLineWidth(1.5)
            context.move(to: CGPoint(x: waveRect.minX, y: centerY))
            context.addLine(to: CGPoint(x: waveRect.maxX, y: centerY))
            context.strokePath()
        }
    }

    /// Port of `clipAudioSamples(for:)` — the slice of the trim-window samples
    /// this clip covers.
    private func videoClipAudioSamples(_ clip: VideoClipRef) -> ArraySlice<Float> {
        let samples = videoAssets.audioSamples
        guard !samples.isEmpty else { return [] }
        let trimStart = videoAssets.trimSourceStart
        let trimDuration = videoAssets.trimSourceEnd - trimStart
        guard trimDuration > 0 else { return [] }

        let startFraction = max(0, min(1, (clip.sourceStart - trimStart) / trimDuration))
        let endFraction = max(0, min(1, (clip.sourceEnd - trimStart) / trimDuration))
        guard endFraction > startFraction else { return [] }

        let count = samples.count
        let startIndex = max(0, min(count - 1, Int((startFraction * Double(count)).rounded(.down))))
        let endIndex = max(startIndex + 1, min(count, Int((endFraction * Double(count)).rounded(.up))))
        return samples[startIndex..<endIndex]
    }

    /// Port of `clipInfoPill` — the live duration bubble (+ dominant speed).
    private func drawVideoInfoPill(
        clip: TimelineVideoClipItem,
        display: VideoClipRef,
        rect: CGRect,
        in context: CGContext
    ) {
        let seconds = max(0, display.outputDuration)
        let text = NSMutableAttributedString(
            string: String(format: "%.1fs", seconds),
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.85),
            ]
        )
        if let speed = clip.pillSpeedLabel {
            text.append(NSAttributedString(string: "  ×\(speed)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.7),
            ]))
        }
        let size = text.size()
        let pill = CGRect(
            x: rect.midX - size.width / 2 - 6,
            y: rect.midY - size.height / 2 - 2,
            width: size.width + 12,
            height: size.height + 4
        )
        context.setFillColor(NSColor.black.withAlphaComponent(0.38).cgColor)
        context.addPath(CGPath(
            roundedRect: pill,
            cornerWidth: pill.height / 2, cornerHeight: pill.height / 2,
            transform: nil
        ))
        context.fillPath()
        text.draw(at: CGPoint(x: pill.minX + 6, y: pill.minY + 2))
    }

    /// Port of `ClipEdgeHandle` — two 2×13 grips inset 5pt at each end.
    private func drawVideoEdgeGrips(rect: CGRect, in context: CGContext) {
        let tint = Self.videoYellow.withAlphaComponent(videoIsHovering ? 0.95 : 0.7)
        let alphas: [CGFloat] = [0.78, 0.64]
        for baseX in [rect.minX + 5, rect.maxX - 5 - 6] {
            for i in 0..<2 {
                let grip = CGRect(x: baseX + CGFloat(i) * 4, y: rect.midY - 6.5, width: 2, height: 13)
                context.setFillColor(tint.withAlphaComponent(tint.alphaComponent * alphas[i]).cgColor)
                context.addPath(CGPath(roundedRect: grip, cornerWidth: 1, cornerHeight: 1, transform: nil))
                context.fillPath()
            }
        }
    }

    private func drawVideoMuteButton(_ model: TimelineVideoRowModel, in context: CGContext) {
        guard let muteRect = videoMuteRect(model) else { return }
        let symbol = model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        let color = NSColor.white.withAlphaComponent(model.isMuted ? 0.4 : 0.75)
        guard let image = Self.tintedSymbol(symbol, pointSize: 9, weight: .semibold, color: color) else { return }
        image.draw(in: CGRect(
            x: muteRect.midX - image.size.width / 2,
            y: muteRect.midY - image.size.height / 2,
            width: image.size.width,
            height: image.size.height
        ))
    }

    static func videoMuteSymbolSize(muted: Bool) -> CGSize {
        let name = muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        return tintedSymbol(name, pointSize: 9, weight: .semibold, color: .white)?.size
            ?? CGSize(width: 14, height: 11)
    }

    private func strokeVideoRounded(
        _ rect: CGRect,
        radius: CGFloat,
        color: NSColor,
        width: CGFloat,
        in context: CGContext
    ) {
        let inset = rect.insetBy(dx: width / 2, dy: width / 2)
        guard inset.width > 0, inset.height > 0 else { return }
        context.addPath(CGPath(
            roundedRect: inset,
            cornerWidth: max(0, radius - width / 2), cornerHeight: max(0, radius - width / 2),
            transform: nil
        ))
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width)
        context.strokePath()
    }
}

// MARK: - Closure-driven menu item

/// Retains its handler; `CanvasMenuItem` is private to TimelineCanvasView.swift.
final class VideoRowMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, destructive: Bool = false, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
        if destructive {
            attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: NSColor.systemRed,
                .font: NSFont.menuFont(ofSize: 0),
            ])
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func invoke() { handler() }
}
