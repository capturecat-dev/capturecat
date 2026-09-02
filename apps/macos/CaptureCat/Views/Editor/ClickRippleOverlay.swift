import AppKit

/// Deterministic timing for the looping tap-indicator annotation: the same
/// (currentTime − startTime) always yields the same ripple phase, so preview
/// scrubbing and export render the identical frame.
enum TapRippleMath {
    /// One tap pulse every `period` seconds; the ripple is visible for
    /// `rippleDuration` at the start of each cycle.
    static let period: Double = 1.2
    static let rippleDuration: Double = 0.45

    /// Ripple progress 0…1 within the current cycle, or nil while resting.
    static func progress(elapsed: Double) -> Double? {
        guard elapsed >= 0 else { return nil }
        let phase = elapsed.truncatingRemainder(dividingBy: period)
        guard phase <= rippleDuration else { return nil }
        return phase / rippleDuration
    }
}

/// Click-ripple geometry shared by the preview compositor and the exporter.
/// This was a SwiftUI overlay; the drawing moved into `PreviewCompositorView`
/// and `VideoExporter`, and what remains is the frame math BOTH consume — the
/// single source of truth CLAUDE.md §2 requires.
enum ClickRippleOverlay {}

extension ClickRippleOverlay {
    /// Active ripples for a frame — exposed so the CA compositor renders the
    /// identical set the SwiftUI overlay computes.
    static func activeRipples(
        cursorEvents: [CursorEvent],
        currentTime: Double,
        coordinateSize: CGSize,
        videoRect: CGRect,
        rippleDuration: Double = 0.45
    ) -> [(position: CGPoint, progress: Double, id: Int)] {
        guard videoRect.width > 0, videoRect.height > 0,
              coordinateSize.width > 0, coordinateSize.height > 0 else { return [] }
        var ripples: [(position: CGPoint, progress: Double, id: Int)] = []
        for (index, event) in discreteClickEvents(from: cursorEvents, coordinateSize: coordinateSize) {
            let elapsed = currentTime - event.timestamp
            guard elapsed >= 0, elapsed <= rippleDuration else { continue }
            let progress = elapsed / rippleDuration
            let viewX = videoRect.minX + (event.x / coordinateSize.width) * videoRect.width
            let viewY = videoRect.minY + (event.y / coordinateSize.height) * videoRect.height
            ripples.append((CGPoint(x: viewX, y: viewY), progress, index))
        }
        return ripples
    }
}

// MARK: - Export rendering (CoreGraphics)

extension ClickRippleOverlay {
    /// Convert 60Hz "mouse is currently pressed" samples into click-down events.
    /// Drag gestures, including selecting text, can produce hundreds of pressed
    /// samples; those should not become a field of click ripples.
    /// Timestamps of discrete clicks (edge-deduped, drag runs excluded) —
    /// the click SOUND must fire once per click, exactly like the ripple.
    static func discreteClickTimes(
        from cursorEvents: [CursorEvent],
        coordinateSize: CGSize
    ) -> [TimeInterval] {
        discreteClickEvents(from: cursorEvents, coordinateSize: coordinateSize)
            .map { $0.event.timestamp }
    }

    /// Discrete clicks WITH their positions — same edge-dedup + drag-run
    /// exclusion as the ripple/sound paths. Auto Zoom clusters these, so a
    /// text-drag never reads as a burst of clicks to zoom at.
    static func discreteClicks(
        from cursorEvents: [CursorEvent],
        coordinateSize: CGSize
    ) -> [CursorEvent] {
        discreteClickEvents(from: cursorEvents, coordinateSize: coordinateSize)
            .map(\.event)
    }

    fileprivate static func discreteClickEvents(
        from cursorEvents: [CursorEvent],
        coordinateSize: CGSize
    ) -> [(index: Int, event: CursorEvent)] {
        var result: [(index: Int, event: CursorEvent)] = []
        var startIndex: Int?
        var startEvent: CursorEvent?
        var maxDistance: CGFloat = 0
        let dragThreshold = clickDragThreshold(for: coordinateSize)

        func finishRun() {
            guard let index = startIndex, let event = startEvent else { return }
            if maxDistance <= dragThreshold {
                result.append((index, event))
            }
            startIndex = nil
            startEvent = nil
            maxDistance = 0
        }

        for (index, event) in cursorEvents.enumerated() {
            if event.isClick {
                if startEvent == nil {
                    startIndex = index
                    startEvent = event
                    maxDistance = 0
                } else if let startEvent {
                    let distance = hypot(event.x - startEvent.x, event.y - startEvent.y)
                    maxDistance = max(maxDistance, distance)
                }
            } else {
                finishRun()
            }
        }

        finishRun()
        return result
    }

    /// Press-runs that are NOT discrete clicks — the pointer travelled past
    /// the drag threshold while held: text highlights, drag-selects. These
    /// get a sustained glow instead of a ripple, so highlighting reads on
    /// screen the way a click does.
    static func dragHighlightRuns(
        from cursorEvents: [CursorEvent],
        coordinateSize: CGSize
    ) -> [(start: TimeInterval, end: TimeInterval)] {
        var result: [(TimeInterval, TimeInterval)] = []
        var startEvent: CursorEvent?
        var lastClick: CursorEvent?
        var maxDistance: CGFloat = 0
        let dragThreshold = clickDragThreshold(for: coordinateSize)

        func finishRun() {
            if let start = startEvent, let end = lastClick, maxDistance > dragThreshold {
                result.append((start.timestamp, end.timestamp))
            }
            startEvent = nil
            lastClick = nil
            maxDistance = 0
        }

        for event in cursorEvents {
            if event.isClick {
                if let start = startEvent {
                    maxDistance = max(maxDistance, hypot(event.x - start.x, event.y - start.y))
                } else {
                    startEvent = event
                }
                lastClick = event
            } else {
                finishRun()
            }
        }
        finishRun()
        return result
    }

    /// Glow strength 0…1 at `time` — quick attack once the press starts
    /// moving, short fade after release. Pure function of the timeline clock,
    /// so scrubbing and export agree.
    static func dragHighlightStrength(
        runs: [(start: TimeInterval, end: TimeInterval)],
        at time: TimeInterval
    ) -> Double {
        let attack = 0.12, release = 0.25
        var strength = 0.0
        for run in runs {
            if time >= run.start, time <= run.end {
                strength = max(strength, min(1, (time - run.start) / attack))
            } else if time > run.end {
                strength = max(strength, min(1, max(0, 1 - (time - run.end) / release)))
            }
        }
        return strength
    }

    private static func clickDragThreshold(for coordinateSize: CGSize) -> CGFloat {
        let shortSide = min(coordinateSize.width, coordinateSize.height)
        guard shortSide > 0 else { return 12 }
        return max(10, min(24, shortSide * 0.006))
    }

    /// Render click ripples into a CGContext for export.
    static func renderForExport(
        into context: CGContext,
        cursorEvents: [CursorEvent],
        currentTime: Double,
        videoRect: CGRect,
        sourceSize: CGSize,
        rippleColor: CGColor,
        rippleSize: Double,
        rippleDuration: Double = 0.45
    ) {
        guard videoRect.width > 0, videoRect.height > 0,
              sourceSize.width > 0, sourceSize.height > 0 else { return }

        let clickEvents = discreteClickEvents(from: cursorEvents, coordinateSize: sourceSize)
        for (_, event) in clickEvents {
            let elapsed = currentTime - event.timestamp
            guard elapsed >= 0, elapsed <= rippleDuration else { continue }

            let progress = elapsed / rippleDuration

            let screenX = event.x / sourceSize.width
            let screenY = event.y / sourceSize.height

            // In CG coordinates, Y is flipped
            let cx = videoRect.minX + screenX * videoRect.width
            let cy = videoRect.maxY - screenY * videoRect.height

            let outerScale = CGFloat(0.2 + progress * 0.8)
            let outerOpacity = CGFloat(1.0 - progress)
            let radius = CGFloat(rippleSize) * outerScale / 2

            // Outer ring
            context.setStrokeColor(rippleColor.copy(alpha: outerOpacity * 0.7)!)
            context.setLineWidth(2.5)
            context.strokeEllipse(in: CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2))

            // Inner ring
            let innerProgress = max(0, progress - 0.1) / 0.9
            let innerScale = CGFloat(0.15 + innerProgress * 0.5)
            let innerOpacity = CGFloat(max(0, 1.0 - innerProgress * 1.5))
            let innerRadius = CGFloat(rippleSize) * 0.6 * innerScale / 2

            context.setStrokeColor(rippleColor.copy(alpha: innerOpacity * 0.5)!)
            context.setLineWidth(1.5)
            context.strokeEllipse(in: CGRect(x: cx - innerRadius, y: cy - innerRadius, width: innerRadius * 2, height: innerRadius * 2))

            // Center dot
            let dotOpacity = CGFloat(max(0, 1.0 - progress * 3))
            let dotRadius: CGFloat = 3
            context.setFillColor(rippleColor.copy(alpha: dotOpacity * 0.6)!)
            context.fillEllipse(in: CGRect(x: cx - dotRadius, y: cy - dotRadius, width: dotRadius * 2, height: dotRadius * 2))
        }

        // Drag-highlight glow — identical strength math to the preview, at
        // the interpolated cursor position, Y-flipped for CG space.
        let runs = dragHighlightRuns(from: cursorEvents, coordinateSize: sourceSize)
        let strength = dragHighlightStrength(runs: runs, at: currentTime)
        if strength > 0.01 {
            let pos = CursorSmoother().interpolate(events: cursorEvents, at: currentTime)
            let cx = videoRect.minX + (pos.x / sourceSize.width) * videoRect.width
            let cy = videoRect.maxY - (pos.y / sourceSize.height) * videoRect.height
            let ringD = CGFloat(rippleSize) * 0.33
            context.setStrokeColor(rippleColor.copy(alpha: 0.55 * strength)!)
            context.setLineWidth(2)
            context.strokeEllipse(in: CGRect(
                x: cx - ringD / 2, y: cy - ringD / 2, width: ringD, height: ringD))
            context.setFillColor(rippleColor.copy(alpha: 0.15 * strength)!)
            context.fillEllipse(in: CGRect(
                x: cx - ringD / 2, y: cy - ringD / 2, width: ringD, height: ringD))
        }
    }
}
