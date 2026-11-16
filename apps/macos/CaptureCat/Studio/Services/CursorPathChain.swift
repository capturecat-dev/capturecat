import Foundation

/// The recorded cursor path as the preview and the exporter draw it: the raw
/// events → smoothing (when on) → fluid movement → end behaviour. ONE chain,
/// consumed by the Mac editor's playback (`EditorPlaybackController
/// .applyCursorSmoothing`), the iOS editor's (`StudioPlaybackController`) and
/// the exporter (`VideoExporter`) — it used to be two copies "kept identical
/// by comment" (Studio 4b).
enum CursorPathChain {
    /// The path to draw for `raw` under `settings`.
    static func apply(
        _ raw: [CursorEvent], settings: ProjectSettings, trimEnd: TimeInterval
    ) -> [CursorEvent] {
        let smoothed = settings.smoothCursor
            ? CursorSmoother(factor: settings.smoothingFactor).smooth(events: raw)
            : raw
        // Fluid movement AFTER smoothing.
        let chained = CursorSpringMath.apply(events: smoothed, settings: settings)
        return CursorEndBehaviorMath.apply(
            events: chained,
            trimEnd: trimEnd,
            loopToStart: settings.cursorLoopToStart,
            stopAtEnd: settings.cursorStopAtEnd)
    }

    /// Every input `apply` reads besides the events — a cache key: the path
    /// only needs re-deriving when this changes.
    static func signature(settings: ProjectSettings, trimEnd: TimeInterval) -> String {
        [
            "\(settings.smoothCursor)", "\(settings.smoothingFactor)",
            "\(settings.cursorFluidEnabled)", "\(settings.cursorTension)",
            "\(settings.cursorFriction)", "\(settings.cursorMass)",
            "\(settings.cursorLoopToStart)", "\(settings.cursorStopAtEnd)",
            "\(trimEnd)",
        ].joined(separator: "|")
    }
}
