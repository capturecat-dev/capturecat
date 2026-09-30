import Foundation

/// Maps between source time (original recording) and output time (after applying
/// per-segment playback speed). Assumes speed regions are non-overlapping and
/// all speeds are > 0.
struct SpeedTimeMap {
    struct Segment {
        let sourceStart: TimeInterval
        let sourceEnd: TimeInterval
        let outputStart: TimeInterval
        let outputEnd: TimeInterval
        let speed: Double
    }

    let segments: [Segment]
    let sourceStart: TimeInterval
    let sourceEnd: TimeInterval

    var outputDuration: TimeInterval {
        segments.last?.outputEnd ?? 0
    }

    init(
        sourceStart: TimeInterval,
        sourceEnd: TimeInterval,
        regions: [VideoSpeedRegion]
    ) {
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd

        // Clip and sort regions to [sourceStart, sourceEnd]
        let clipped: [(Double, Double, Double)] = regions
            .compactMap { region -> (Double, Double, Double)? in
                let start = max(region.startTime, sourceStart)
                let end = min(region.endTime, sourceEnd)
                guard end > start + 0.0001 else { return nil }
                let safeSpeed = max(0.1, region.speed)
                return (start, end, safeSpeed)
            }
            .sorted { $0.0 < $1.0 }

        // Build piecewise segments covering the full range, filling gaps with speed=1
        var result: [Segment] = []
        var cursor = sourceStart
        var outputCursor: TimeInterval = 0

        for (start, end, speed) in clipped {
            // Skip any overlap with previously consumed source range
            let safeStart = max(cursor, start)
            let safeEnd = max(safeStart, end)
            if safeEnd <= safeStart { continue }

            if safeStart > cursor {
                let gapDur = safeStart - cursor
                result.append(Segment(
                    sourceStart: cursor,
                    sourceEnd: safeStart,
                    outputStart: outputCursor,
                    outputEnd: outputCursor + gapDur,
                    speed: 1.0
                ))
                outputCursor += gapDur
            }

            let segDur = safeEnd - safeStart
            let outDur = segDur / speed
            result.append(Segment(
                sourceStart: safeStart,
                sourceEnd: safeEnd,
                outputStart: outputCursor,
                outputEnd: outputCursor + outDur,
                speed: speed
            ))
            outputCursor += outDur
            cursor = safeEnd
        }

        if cursor < sourceEnd {
            let gapDur = sourceEnd - cursor
            result.append(Segment(
                sourceStart: cursor,
                sourceEnd: sourceEnd,
                outputStart: outputCursor,
                outputEnd: outputCursor + gapDur,
                speed: 1.0
            ))
        }

        if result.isEmpty {
            result.append(Segment(
                sourceStart: sourceStart,
                sourceEnd: sourceEnd,
                outputStart: 0,
                outputEnd: max(0, sourceEnd - sourceStart),
                speed: 1.0
            ))
        }

        self.segments = result
    }

    /// Convert output (exported) time → source (original recording) time.
    func sourceTime(forOutput outputTime: TimeInterval) -> TimeInterval {
        guard !segments.isEmpty else { return sourceStart + outputTime }
        if outputTime <= segments.first!.outputStart { return segments.first!.sourceStart }
        if outputTime >= segments.last!.outputEnd { return segments.last!.sourceEnd }

        for seg in segments {
            if outputTime >= seg.outputStart && outputTime <= seg.outputEnd {
                let local = outputTime - seg.outputStart
                return seg.sourceStart + local * seg.speed
            }
        }
        return segments.last!.sourceEnd
    }

    /// Convert source → output time.
    func outputTime(forSource sourceTime: TimeInterval) -> TimeInterval {
        guard !segments.isEmpty else { return sourceTime - sourceStart }
        if sourceTime <= segments.first!.sourceStart { return segments.first!.outputStart }
        if sourceTime >= segments.last!.sourceEnd { return segments.last!.outputEnd }

        for seg in segments {
            if sourceTime >= seg.sourceStart && sourceTime <= seg.sourceEnd {
                let local = sourceTime - seg.sourceStart
                return seg.outputStart + local / seg.speed
            }
        }
        return segments.last!.outputEnd
    }

    /// Find the speed in effect at a given source time. Defaults to 1.0.
    func speed(atSource sourceTime: TimeInterval) -> Double {
        for seg in segments where sourceTime >= seg.sourceStart && sourceTime <= seg.sourceEnd {
            return seg.speed
        }
        return 1.0
    }
}

extension SpeedTimeMap {
    /// The trim + speed map every OUTPUT-time consumer builds — the project's
    /// effective trim window and its speed regions (the same construction the
    /// share transcript and search seek use inline). Used by the MCP server so
    /// agent-facing output times come from the one mapping, never a copy.
    init(trimmedOutputOf project: Project) {
        let trimStart = project.effectiveTrimStart
        self.init(
            sourceStart: trimStart,
            sourceEnd: max(trimStart, project.effectiveTrimEnd),
            regions: project.speedRegions
        )
    }
}

extension Project {
    /// Exported length in OUTPUT seconds for `timeMap`: the map's output
    /// duration, capped at the last visible clip's OUTPUT-time end. Resizing
    /// or moving a clip shorter than the trim range would otherwise pad the
    /// output with trailing BG-only frames. Output time (not source time)
    /// because a moved clip's source range may not be the rightmost clip on
    /// the timeline.
    ///
    /// SHARED by VideoExporter (the frame count it writes) and the MCP
    /// server's describe_project / edit results, so the length an agent is
    /// told is exactly the length export produces.
    func exportedOutputDuration(timeMap: SpeedTimeMap) -> TimeInterval {
        let lastVisibleOutput = effectiveVideoClipSegments
            .map { timeMap.outputTime(forSource: $0.endTime) }
            .max() ?? timeMap.outputDuration
        return max(0.0001, min(timeMap.outputDuration, lastVisibleOutput))
    }
}
