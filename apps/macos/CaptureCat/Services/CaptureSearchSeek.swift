import Foundation

/// Search-hit → playhead math: turns an OCR match into the exact editor
/// moment to land on. Pure functions, shared by the browser's ⌘K
/// suggestions and grid opens, and asserted directly by --notes-test.
///
/// Two timelines are involved: `CaptureIndexFrame.time` is SOURCE time
/// (frames are extracted from the raw video), while the editor's playhead /
/// pendingSeekOutputTime work in OUTPUT time (after trims + speed regions).
/// The conversion here is the same trim+speed `SpeedTimeMap` construction
/// the share upload and deep-link seeks use — never a bespoke fork.
enum CaptureSearchSeek {
    /// Source time of the indexed frame whose text has the MOST query-token
    /// hits; ties resolve to the earliest frame. nil when no frame matches.
    static func bestSourceTime(query: String, frames: [CaptureIndexFrame]) -> TimeInterval? {
        var best: (time: TimeInterval, hits: Int)?
        for frame in frames.sorted(by: { $0.time < $1.time }) {
            let hits = CaptureSearchRanking.hitCount(query: query, in: frame.text)
            guard hits > 0 else { continue }
            if best == nil || hits > best!.hits {
                best = (frame.time, hits)
            }
        }
        return best?.time
    }

    /// Map a SOURCE-time match into the editor's OUTPUT timeline: clamp into
    /// the trimmed range (a match inside a trimmed-away region lands at the
    /// nearest valid edge), then run the project's trim+speed map.
    static func outputTime(forSource sourceTime: TimeInterval, project: Project) -> TimeInterval {
        let trimStart = project.effectiveTrimStart
        let trimEnd = max(trimStart, project.effectiveTrimEnd)
        let clamped = min(max(sourceTime, trimStart), trimEnd)
        let map = SpeedTimeMap(
            sourceStart: trimStart,
            sourceEnd: trimEnd,
            regions: project.speedRegions
        )
        return map.outputTime(forSource: clamped)
    }

    /// Full pipeline: best matching frame → output-time seek target.
    static func seekOutputTime(
        query: String,
        frames: [CaptureIndexFrame],
        project: Project
    ) -> TimeInterval? {
        guard let source = bestSourceTime(query: query, frames: frames) else { return nil }
        return outputTime(forSource: source, project: project)
    }

    /// "2:41"-style label for suggestion rows.
    static func timestampLabel(_ time: TimeInterval) -> String {
        let total = Int(time.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
