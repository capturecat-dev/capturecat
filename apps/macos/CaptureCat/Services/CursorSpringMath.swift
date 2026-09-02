import Foundation
import CoreGraphics

/// Fluid cursor movement: a damped spring chases the recorded path.
///
/// Tension is how hard the spring pulls toward the recorded position
/// (acceleration), friction is the velocity damping (how quickly it settles),
/// and mass is inertia (momentum, overshoot, wiggle). The simulation is a
/// PURE function of the recorded events and the parameters — fixed-timestep
/// integration from the first sample — so the preview, scrubbing, and the
/// exporter all see the identical path (CLAUDE.md §2).
///
/// # Clicks stay put
///
/// The one thing cursor processing must never do is move a click off the
/// thing it clicked (see CursorSmoother's history). Every output sample
/// within the pin window of a click blends toward the RAW path, reaching an
/// exact pin at the click itself — the spring flows in and out of clicks, but
/// at the click instant the cursor is exactly where the user pressed.
enum CursorSpringMath {
    /// Integration step. Fixed so the result is bit-identical everywhere.
    static let simulationRate: Double = 240
    /// Output sample rate of the resimulated path.
    static let outputRate: Double = 120
    /// Seconds around a click over which the spring blends into the raw pin.
    static let clickPinWindow: TimeInterval = 0.12

    /// Parameter clamps — outside these the spring is a launch vehicle.
    static let tensionRange: ClosedRange<Double> = 20...600
    static let frictionRange: ClosedRange<Double> = 2...80
    static let massRange: ClosedRange<Double> = 0.2...6

    /// The pipeline entry point both renderers call after smoothing.
    static func apply(events: [CursorEvent], settings: ProjectSettings) -> [CursorEvent] {
        guard settings.cursorFluidEnabled else { return events }
        return simulate(
            events: events,
            tension: settings.cursorTension,
            friction: settings.cursorFriction,
            mass: settings.cursorMass
        )
    }

    static func simulate(
        events: [CursorEvent],
        tension: Double,
        friction: Double,
        mass: Double
    ) -> [CursorEvent] {
        guard events.count > 1,
              let first = events.first, let last = events.last,
              last.timestamp > first.timestamp else { return events }

        let k = min(tensionRange.upperBound, max(tensionRange.lowerBound, tension))
        let c = min(frictionRange.upperBound, max(frictionRange.lowerBound, friction))
        let m = min(massRange.upperBound, max(massRange.lowerBound, mass))

        let smoother = CursorSmoother()
        let dt = 1 / simulationRate
        let emitStep = 1 / outputRate

        var px = first.x, py = first.y
        var vx = 0.0, vy = 0.0
        var out: [CursorEvent] = []
        out.reserveCapacity(Int((last.timestamp - first.timestamp) * outputRate) + 2)

        var t = first.timestamp
        var nextEmit = first.timestamp
        while t <= last.timestamp + dt / 2 {
            let target = smoother.interpolate(events: events, at: t)
            // Semi-implicit Euler: a = (k·(target − p) − c·v) / m.
            vx += (k * (Double(target.x) - px) - c * vx) / m * dt
            vy += (k * (Double(target.y) - py) - c * vy) / m * dt
            px += vx * dt
            py += vy * dt
            if t >= nextEmit - dt / 2 {
                out.append(CursorEvent(timestamp: t, x: px, y: py, isClick: false))
                nextEmit += emitStep
            }
            t += dt
        }
        guard !out.isEmpty else { return events }

        // Click pinning over PRESSED INTERVALS, not individual samples. The
        // tracker flags every 60Hz sample while the button is down; resampling
        // at 120Hz against single samples fragmented a held drag into dozens
        // of one-sample "clicks" — a ripple storm on every text highlight,
        // and no drag-run for the highlight glow to find. An output sample
        // INSIDE a pressed interval is exactly the raw path and carries the
        // flag, so click runs survive resampling contiguously; samples near
        // an interval blend in and out over the pin window.
        var intervals: [(start: TimeInterval, end: TimeInterval)] = []
        var runStart: TimeInterval?
        var runEnd: TimeInterval?
        for event in events {
            if event.isClick {
                if runStart == nil { runStart = event.timestamp }
                runEnd = event.timestamp
            } else if let s = runStart, let e = runEnd {
                intervals.append((s, e))
                runStart = nil
                runEnd = nil
            }
        }
        if let s = runStart, let e = runEnd { intervals.append((s, e)) }
        guard !intervals.isEmpty else { return out }

        var intervalIndex = 0
        for i in out.indices {
            let sampleTime = out[i].timestamp
            while intervalIndex + 1 < intervals.count,
                  sampleTime > intervals[intervalIndex].end + clickPinWindow {
                intervalIndex += 1
            }
            let interval = intervals[intervalIndex]
            let distance: TimeInterval
            if sampleTime < interval.start {
                distance = interval.start - sampleTime
            } else if sampleTime > interval.end {
                distance = sampleTime - interval.end
            } else {
                distance = 0
            }
            guard distance < clickPinWindow else { continue }
            let raw = smoother.interpolate(events: events, at: sampleTime)
            // Half an output period of slack: the accumulated simulation clock
            // never lands EXACTLY on an event timestamp in floating point, and
            // a single-sample click has a zero-width interval.
            if distance <= emitStep / 2 {
                out[i] = CursorEvent(timestamp: sampleTime, x: raw.x, y: raw.y, isClick: true)
            } else {
                // Smoothstep 1 at the interval edge → 0 at the window edge.
                let u = 1 - distance / clickPinWindow
                let w = u * u * (3 - 2 * u)
                out[i] = CursorEvent(
                    timestamp: sampleTime,
                    x: out[i].x + (raw.x - out[i].x) * w,
                    y: out[i].y + (raw.y - out[i].y) * w,
                    isClick: false
                )
            }
        }
        return out
    }
}


/// End-of-clip cursor behaviors — Screen Studio's loop-to-start and
/// stop-at-end, applied to the event stream AFTER smoothing + fluid movement
/// so preview and export share the identical chain.
enum CursorEndBehaviorMath {
    /// `loopToStart`: over the final 0.8s the cursor glides back to its first
    /// position (seamless loops for social clips). `stopAtEnd`: the cursor
    /// freezes for the final 0.5s. Loop wins when both are on.
    static func apply(
        events: [CursorEvent],
        trimEnd: TimeInterval,
        loopToStart: Bool,
        stopAtEnd: Bool
    ) -> [CursorEvent] {
        guard loopToStart || stopAtEnd, let first = events.first else { return events }
        if loopToStart {
            let window: TimeInterval = 0.8
            let rampStart = trimEnd - window
            return events.map { event in
                guard event.timestamp > rampStart else { return event }
                let p = min(1, max(0, (event.timestamp - rampStart) / window))
                let eased = CGFloat(p * p * (3 - 2 * p))
                return CursorEvent(
                    timestamp: event.timestamp,
                    x: event.x + (first.x - event.x) * eased,
                    y: event.y + (first.y - event.y) * eased,
                    isClick: event.isClick)
            }
        }
        // stopAtEnd
        let freezeStart = trimEnd - 0.5
        guard let anchor = events.last(where: { $0.timestamp <= freezeStart }) else { return events }
        return events.map { event in
            guard event.timestamp > freezeStart else { return event }
            return CursorEvent(
                timestamp: event.timestamp, x: anchor.x, y: anchor.y,
                isClick: event.isClick)
        }
    }
}
