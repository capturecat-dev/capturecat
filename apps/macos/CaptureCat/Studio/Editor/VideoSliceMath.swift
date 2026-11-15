import CoreGraphics
import Foundation

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
