import Foundation

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
