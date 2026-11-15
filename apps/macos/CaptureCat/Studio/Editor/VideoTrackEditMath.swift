import Foundation
import CoreGraphics

/// Pure editing math for the VIDEO track — extracted verbatim from
/// `VideoTrackContent` so the SwiftUI row and the (upcoming) native canvas
/// row drive the IDENTICAL numbers. View-free: everything is parameters in,
/// times out, which is also what makes the `--videotrack-math-test` harness
/// possible.
///
/// All times are OUTPUT time (post speed-map) unless a name says otherwise.
struct VideoTrackEditMath {
    var duration: TimeInterval          // total output duration
    var trackWidth: CGFloat
    var snapCandidates: [TimeInterval]  // output time
    var regionStart: TimeInterval       // trim start in output time
    var regionEnd: TimeInterval         // trim end in output time
    var minDuration: TimeInterval = 0.5

    enum DragMode { case none, move, resizeLeft, resizeRight }
    enum Side { case left, right }

    // MARK: - Whole-track trim/slip drag (single-clip mode)

    /// Port of VideoTrackContent.resolvedTimes(for:) — the whole-track drag.
    /// resizeLeft/resizeRight deliberately do NOT clamp to [0, duration]:
    /// overshoot restores trimmed head/tail material on commit.
    func resolvedTimes(
        mode: DragMode,
        delta: TimeInterval,
        dragInitialStart: TimeInterval,
        dragInitialEnd: TimeInterval
    ) -> (start: TimeInterval, end: TimeInterval) {
        let snapEdge: (TimeInterval, [TimeInterval]) -> TimeInterval? = { time, excludedEdges in
            let candidates = snapCandidates.filter { candidate in
                !excludedEdges.contains(where: { abs($0 - candidate) < 0.0001 })
            }
            return TimelineSnap.nearestCandidate(
                to: time,
                candidates: candidates,
                duration: duration,
                trackWidth: trackWidth
            )
        }

        switch mode {
        case .resizeLeft:
            let snappedStart = snapEdge(dragInitialStart + delta, [dragInitialStart, dragInitialEnd]) ?? (dragInitialStart + delta)
            let newStart = min(dragInitialEnd - minDuration, snappedStart)
            return (newStart, dragInitialEnd)
        case .resizeRight:
            let snappedEnd = snapEdge(dragInitialEnd + delta, [dragInitialStart, dragInitialEnd]) ?? (dragInitialEnd + delta)
            let newEnd = max(dragInitialStart + minDuration, snappedEnd)
            return (dragInitialStart, newEnd)
        case .move:
            let clipDuration = dragInitialEnd - dragInitialStart
            let maxStart = max(0, duration - clipDuration)
            let proposedStart = dragInitialStart + delta
            let proposedEnd = proposedStart + clipDuration
            let candidates = snapCandidates.filter { candidate in
                abs(candidate - dragInitialStart) >= 0.0001 && abs(candidate - dragInitialEnd) >= 0.0001
            }
            let snappedStartCandidate = TimelineSnap.nearestCandidate(
                to: proposedStart,
                candidates: candidates,
                duration: duration,
                trackWidth: trackWidth
            )
            let snappedEndCandidate = TimelineSnap.nearestCandidate(
                to: proposedEnd,
                candidates: candidates,
                duration: duration,
                trackWidth: trackWidth
            )

            let adjustedStart: TimeInterval
            switch (snappedStartCandidate, snappedEndCandidate) {
            case let (start?, end?):
                adjustedStart = abs(start - proposedStart) <= abs(end - proposedEnd) ? start : (end - clipDuration)
            case let (start?, nil):
                adjustedStart = start
            case let (nil, end?):
                adjustedStart = end - clipDuration
            case (nil, nil):
                adjustedStart = proposedStart
            }

            let newStart = min(max(0, adjustedStart), maxStart)
            return (newStart, min(duration, newStart + clipDuration))
        case .none:
            return (regionStart, regionEnd)
        }
    }

    // MARK: - Multi-clip editing

    /// A clip span in output time — mirror of VideoTrackContent.ClipSegment's
    /// output fields (source fields stay with the caller).
    struct ClipSpan: Equatable {
        var id: UUID
        var outputStart: TimeInterval
        var outputEnd: TimeInterval
        var outputDuration: TimeInterval { outputEnd - outputStart }
    }

    /// Port of moveBounds(for:) — neighbors clamp a clip's travel.
    func moveBounds(for clip: ClipSpan, in clips: [ClipSpan]) -> (lower: TimeInterval, upper: TimeInterval) {
        let index = clips.firstIndex(where: { $0.id == clip.id })
        let previousEnd = index.flatMap { $0 > 0 ? clips[$0 - 1].outputEnd : nil } ?? 0
        let nextStart = index.flatMap { $0 < clips.count - 1 ? clips[$0 + 1].outputStart : nil } ?? duration
        return (previousEnd, nextStart - clip.outputDuration)
    }

    /// Port of resizeBounds(for:side:).
    func resizeBounds(for clip: ClipSpan, side: Side, in clips: [ClipSpan]) -> (lower: TimeInterval, upper: TimeInterval) {
        let index = clips.firstIndex(where: { $0.id == clip.id })
        switch side {
        case .left:
            let previousEnd = index.flatMap { $0 > 0 ? clips[$0 - 1].outputEnd : nil } ?? 0
            let lower = max(0, previousEnd)
            return (lower, clip.outputEnd - minDuration)
        case .right:
            let nextStart = index.flatMap { $0 < clips.count - 1 ? clips[$0 + 1].outputStart : nil } ?? duration
            let upper = min(duration, nextStart)
            return (clip.outputStart + minDuration, upper)
        }
    }

    /// Port of snapClipMoveStart(_:proposedOutputEnd:clipDuration:excluding:).
    func snapClipMoveStart(
        _ outputStart: TimeInterval,
        proposedOutputEnd: TimeInterval,
        clipDuration: TimeInterval,
        excluding excludedEdges: [TimeInterval]
    ) -> TimeInterval {
        let candidates = snapCandidates.filter { candidate in
            !excludedEdges.contains(where: { abs($0 - candidate) < 0.0001 })
        }
        let snappedStart = TimelineSnap.nearestCandidate(
            to: outputStart,
            candidates: candidates,
            duration: duration,
            trackWidth: trackWidth
        )
        let snappedEnd = TimelineSnap.nearestCandidate(
            to: proposedOutputEnd,
            candidates: candidates,
            duration: duration,
            trackWidth: trackWidth
        )

        switch (snappedStart, snappedEnd) {
        case let (start?, end?):
            return abs(start - outputStart) <= abs(end - proposedOutputEnd) ? start : end - clipDuration
        case let (start?, nil):
            return start
        case let (nil, end?):
            return end - clipDuration
        case (nil, nil):
            return outputStart
        }
    }

    /// Port of snapClipEdge(_:excluding:).
    func snapClipEdge(_ outputTime: TimeInterval, excluding excludedEdges: [TimeInterval]) -> TimeInterval {
        let candidates = snapCandidates.filter { candidate in
            !excludedEdges.contains(where: { abs($0 - candidate) < 0.0001 })
        }
        return TimelineSnap.nearestCandidate(
            to: outputTime,
            candidates: candidates,
            duration: duration,
            trackWidth: trackWidth
        ) ?? outputTime
    }

    /// Port of resolvedClipMoveOutputStart(_:proposedOutputStart:snapsToCandidates:).
    func resolvedClipMoveOutputStart(
        _ clip: ClipSpan,
        in clips: [ClipSpan],
        proposedOutputStart: TimeInterval,
        snapsToCandidates: Bool = true
    ) -> TimeInterval {
        let bounds = moveBounds(for: clip, in: clips)
        guard bounds.upper >= bounds.lower else { return clip.outputStart }

        let proposedEnd = proposedOutputStart + clip.outputDuration
        let resolved = snapsToCandidates
            ? snapClipMoveStart(
                proposedOutputStart,
                proposedOutputEnd: proposedEnd,
                clipDuration: clip.outputDuration,
                excluding: [clip.outputStart, clip.outputEnd]
            )
            : proposedOutputStart

        return min(max(resolved, bounds.lower), bounds.upper)
    }

    /// Port of resolvedClipEdgeOutput(_:side:proposedOutput:snapsToCandidates:).
    func resolvedClipEdgeOutput(
        _ clip: ClipSpan,
        in clips: [ClipSpan],
        side: Side,
        proposedOutput: TimeInterval,
        snapsToCandidates: Bool = true
    ) -> TimeInterval {
        let bounds = resizeBounds(for: clip, side: side, in: clips)
        let resolved = snapsToCandidates
            ? snapClipEdge(proposedOutput, excluding: [clip.outputStart, clip.outputEnd])
            : proposedOutput
        return min(max(resolved, bounds.lower), bounds.upper)
    }
}
