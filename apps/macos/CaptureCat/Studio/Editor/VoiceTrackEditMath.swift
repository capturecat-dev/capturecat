import CoreGraphics
import Foundation

// MARK: - Shared edit math (VOICE row)

/// The voice-over clip drag resolver, lifted verbatim out of
/// `VoiceOverClipBlockView.resolvedClip(from:delta:)` so the SwiftUI block and
/// the native canvas row cannot drift — the same pattern `VideoTrackEditMath`
/// applies to the VIDEO row. Every time here is OUTPUT time; the caller maps
/// back into source time at the commit boundary.
struct VoiceTrackEditMath {
    enum Mode {
        case none
        case move
        case resizeLeft
        case resizeRight
    }

    var totalDuration: TimeInterval
    var trackWidth: CGFloat
    var snapCandidates: [TimeInterval]
    var minDuration: TimeInterval = 0.25

    /// Output-time delta for a horizontal drag translation.
    func delta(forTranslation translationX: CGFloat) -> TimeInterval {
        guard trackWidth > 0 else { return 0 }
        return TimeInterval(translationX / trackWidth) * totalDuration
    }

    func resolvedClip(from initial: VoiceOverClip, mode: Mode, delta: TimeInterval) -> VoiceOverClip {
        let snapEdge: (TimeInterval, [TimeInterval]) -> TimeInterval? = { time, excludedEdges in
            let candidates = snapCandidates.filter { candidate in
                !excludedEdges.contains(where: { abs($0 - candidate) < 0.0001 })
            }
            return TimelineSnap.nearestCandidate(
                to: time,
                candidates: candidates,
                duration: totalDuration,
                trackWidth: trackWidth
            )
        }

        var next = initial

        switch mode {
        case .none:
            break
        case .move:
            let duration = initial.duration
            let proposedStart = initial.startTime + delta
            let proposedEnd = proposedStart + duration
            let candidates = snapCandidates.filter { candidate in
                abs(candidate - initial.startTime) >= 0.0001 && abs(candidate - initial.endTime) >= 0.0001
            }
            let snappedStartCandidate = TimelineSnap.nearestCandidate(
                to: proposedStart,
                candidates: candidates,
                duration: totalDuration,
                trackWidth: trackWidth
            )
            let snappedEndCandidate = TimelineSnap.nearestCandidate(
                to: proposedEnd,
                candidates: candidates,
                duration: totalDuration,
                trackWidth: trackWidth
            )

            let adjustedStart: TimeInterval
            switch (snappedStartCandidate, snappedEndCandidate) {
            case let (start?, end?):
                adjustedStart = abs(start - proposedStart) <= abs(end - proposedEnd) ? start : (end - duration)
            case let (start?, nil):
                adjustedStart = start
            case let (nil, end?):
                adjustedStart = end - duration
            case (nil, nil):
                adjustedStart = proposedStart
            }

            next.startTime = max(0, min(totalDuration - duration, adjustedStart))

        case .resizeLeft:
            let snappedStart = snapEdge(initial.startTime + delta, [initial.startTime, initial.endTime])
                ?? (initial.startTime + delta)
            let earliestStart = max(0, initial.startTime - initial.sourceStartTime)
            let latestStart = initial.endTime - minDuration
            let newStart = min(max(snappedStart, earliestStart), latestStart)
            let sourceDelta = newStart - initial.startTime
            next.startTime = newStart
            next.sourceStartTime = max(0, initial.sourceStartTime + sourceDelta)
            next.duration = max(minDuration, initial.endTime - newStart)

        case .resizeRight:
            let snappedEnd = snapEdge(initial.endTime + delta, [initial.startTime, initial.endTime])
                ?? (initial.endTime + delta)
            let maxEnd = min(
                totalDuration,
                initial.startTime + max(minDuration, initial.sourceDuration - initial.sourceStartTime)
            )
            let newEnd = max(initial.startTime + minDuration, min(maxEnd, snappedEnd))
            next.duration = max(minDuration, newEnd - initial.startTime)
        }

        next.clamp(to: totalDuration)
        return next
    }

}

// MARK: - Shared commit logic

/// The VOICE row's output→source mapping and model write, extracted from
/// `VoiceOverTrackContent.outputBinding(for:)` so the SwiftUI row and the
/// native canvas row commit IDENTICALLY.
///
/// The mapping + write only: the timeline's `commitVoiceClip` wraps it in the
/// drag's one undo step (the web vectors call it bare).
@MainActor
struct VoiceTrackCommits {
    let project: Project
    let timeMap: SpeedTimeMap

    /// Port of the binding's getter — the stored clip remapped into output time.
    func outputClip(for stored: VoiceOverClip) -> VoiceOverClip {
        var copy = stored
        let outStart = timeMap.outputTime(forSource: stored.startTime)
        let outEnd = timeMap.outputTime(forSource: stored.startTime + stored.duration)
        copy.startTime = outStart
        copy.duration = max(0.01, outEnd - outStart)
        return copy
    }

    /// Port of the binding's setter — an output-time clip value written back
    /// into `project.voiceOverClips` as source time.
    func commit(id: UUID, outputValue: VoiceOverClip) {
        guard let idx = project.voiceOverClips.firstIndex(where: { $0.id == id }) else { return }
        var stored = project.voiceOverClips[idx]
        let newSourceStart = timeMap.sourceTime(forOutput: outputValue.startTime)
        let newSourceEnd = timeMap.sourceTime(forOutput: outputValue.startTime + outputValue.duration)
        stored.startTime = newSourceStart
        stored.duration = max(0.01, newSourceEnd - newSourceStart)
        stored.sourceStartTime = outputValue.sourceStartTime
        stored.gain = outputValue.gain
        stored.label = outputValue.label
        project.voiceOverClips[idx] = stored
    }
}
