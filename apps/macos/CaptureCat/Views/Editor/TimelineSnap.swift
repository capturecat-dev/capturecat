import CoreGraphics
import Foundation

enum TimelineSnap {
    static func majorInterval(for pixelsPerSecond: CGFloat) -> TimeInterval {
        let candidates: [TimeInterval] = [0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300]
        for interval in candidates {
            if pixelsPerSecond * interval >= 72 {
                return interval
            }
        }
        return 300
    }

    static func minorInterval(duration: TimeInterval, trackWidth: CGFloat) -> TimeInterval {
        guard duration > 0, trackWidth > 0 else { return 0 }
        let pixelsPerSecond = trackWidth / duration
        return max(0.1, majorInterval(for: pixelsPerSecond) / 5)
    }

    static func snap(_ time: TimeInterval, duration: TimeInterval, trackWidth: CGFloat) -> TimeInterval {
        let interval = minorInterval(duration: duration, trackWidth: trackWidth)
        guard interval > 0 else { return time }
        return (time / interval).rounded() * interval
    }

    static func snapThreshold(duration: TimeInterval, trackWidth: CGFloat) -> TimeInterval {
        guard duration > 0, trackWidth > 0 else { return 0 }
        // 16px of grab — wide enough that edges actually land on candidates
        // (and the snap guide line becomes visible) during a normal drag.
        let pixelThresholdTime = duration * 16 / trackWidth
        return max(pixelThresholdTime, minorInterval(duration: duration, trackWidth: trackWidth) * 0.35)
    }

    static func nearestCandidate(
        to time: TimeInterval,
        candidates: [TimeInterval],
        duration: TimeInterval,
        trackWidth: CGFloat
    ) -> TimeInterval? {
        let threshold = snapThreshold(duration: duration, trackWidth: trackWidth)
        guard threshold > 0 else { return nil }

        return candidates
            .map { candidate in
                (candidate: clamp(candidate, duration: duration), distance: abs(candidate - time))
            }
            .filter { $0.distance <= threshold }
            .min { lhs, rhs in lhs.distance < rhs.distance }?
            .candidate
    }

    static func magneticSnap(
        time: TimeInterval,
        candidates: [TimeInterval],
        duration: TimeInterval,
        trackWidth: CGFloat
    ) -> TimeInterval {
        if let candidate = nearestCandidate(
            to: time,
            candidates: candidates,
            duration: duration,
            trackWidth: trackWidth
        ) {
            return candidate
        }
        return snap(time, duration: duration, trackWidth: trackWidth)
    }

    /// Which edge of a resolved block currently rests on a snap candidate — the
    /// time the timeline should draw its snap guide line at, or nil when the
    /// block is floating free.
    static func snappedEdge(
        start: TimeInterval,
        end: TimeInterval,
        candidates: [TimeInterval],
        checkStart: Bool,
        checkEnd: Bool
    ) -> TimeInterval? {
        let epsilon: TimeInterval = 0.0005
        if checkStart, candidates.contains(where: { abs($0 - start) < epsilon }) { return start }
        if checkEnd, candidates.contains(where: { abs($0 - end) < epsilon }) { return end }
        return nil
    }

    static func clamp(_ time: TimeInterval, duration: TimeInterval) -> TimeInterval {
        max(0, min(duration, time))
    }
}
