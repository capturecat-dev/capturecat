import Foundation
import CoreGraphics

struct CursorSmoother: Sendable {
    static let freshnessThreshold: TimeInterval = 0.12

    let factor: Double

    init(factor: Double = 0.15) {
        self.factor = factor
    }

    /// Smooths the recorded path WITHOUT moving it.
    ///
    /// This was an exponential moving average — `smoothed = prev + factor *
    /// (raw - prev)` — where each output fed from the previous OUTPUT. That is
    /// a causal filter, so it can only ever trail the real pointer, and the
    /// error grows with speed rather than staying bounded. Measured against a
    /// real 57s recording at the shipped default (factor 0.15): mean lag 35px,
    /// worst 564px on a 1492px-wide video. The cursor visibly lagged the thing
    /// it was pointing at, which is the one thing it must never do.
    ///
    /// A recording is not a live stream: every sample is already known, so the
    /// filter can be SYMMETRIC — average each sample with its neighbours on
    /// both sides. That removes jitter with zero phase lag by construction,
    /// because the window is centred on the sample it is replacing.
    ///
    /// `factor` keeps its meaning (1 = no smoothing, smaller = smoother); it
    /// now sets the window width instead of an EMA coefficient.
    func smooth(events: [CursorEvent]) -> [CursorEvent] {
        guard events.count > 2, factor > 0, factor < 1 else { return events }

        // An EMA with coefficient `f` has a time constant of about 1/f samples.
        // Half that on each side gives comparable noise reduction with none of
        // the delay. Capped so a tiny factor cannot average the path flat.
        let half = min(15, max(1, Int(((1.0 / factor) - 1.0) / 2.0.rounded())))

        var out: [CursorEvent] = []
        out.reserveCapacity(events.count)
        for i in events.indices {
            let lo = max(0, i - half)
            let hi = min(events.count - 1, i + half)
            var sx = 0.0, sy = 0.0
            for j in lo...hi { sx += events[j].x; sy += events[j].y }
            let n = Double(hi - lo + 1)
            out.append(CursorEvent(
                timestamp: events[i].timestamp,
                x: events[i].isClick ? events[i].x : sx / n,
                y: events[i].isClick ? events[i].y : sy / n,
                // A click must stay on the sample it happened on: moving one
                // would put the ripple somewhere the user never clicked.
                isClick: events[i].isClick
            ))
        }
        return out
    }

    func interpolate(events: [CursorEvent], at time: TimeInterval) -> CGPoint {
        guard !events.isEmpty else { return .zero }
        guard events.count > 1 else { return events[0].point }

        // Binary search for the two bracketing events
        var lo = 0
        var hi = events.count - 1

        if time <= events[lo].timestamp { return events[lo].point }
        if time >= events[hi].timestamp { return events[hi].point }

        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if events[mid].timestamp <= time {
                lo = mid
            } else {
                hi = mid
            }
        }

        let a = events[lo]
        let b = events[hi]
        let dt = b.timestamp - a.timestamp
        guard dt > 0 else { return a.point }

        let t = (time - a.timestamp) / dt
        return CGPoint(
            x: a.x + (b.x - a.x) * t,
            y: a.y + (b.y - a.y) * t
        )
    }

    func interpolateIfFresh(
        events: [CursorEvent],
        at time: TimeInterval,
        freshnessThreshold: TimeInterval = CursorSmoother.freshnessThreshold
    ) -> CGPoint? {
        guard let first = events.first, let last = events.last else { return nil }
        guard time >= first.timestamp, time <= last.timestamp + freshnessThreshold else { return nil }

        if time >= last.timestamp {
            guard time - last.timestamp <= freshnessThreshold else { return nil }
            return last.point
        }

        return interpolate(events: events, at: time)
    }
}
