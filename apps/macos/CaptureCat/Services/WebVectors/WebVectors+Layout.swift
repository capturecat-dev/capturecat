import Foundation
import CoreGraphics

// Golden-vector units for the LAYOUT cluster (coordinator-owned): frame
// layout/placement, aspect ratio + output size, export frame cadence, and the
// shared CursorSmoother. TS ports: apps/web/src/editor/core/math/.
extension WebVectors {
    static var layoutUnits: [WebVectorUnit] {
        [
            WebVectorUnit(
                name: "cursorSmoother",
                notes: "Services/CursorSmoother.swift — smooth(events:), interpolate(events:at:), interpolateIfFresh(events:at:freshnessThreshold:)",
                build: cursorSmootherCases),
        ] + layoutMathUnits
    }

    /// Deterministic cursor path: random walk with click runs, occasional
    /// duplicate timestamps and pauses (the shapes real recordings have).
    static func randomCursorEvents(_ rng: inout WVRandom, count: Int, size: CGSize = CGSize(width: 1512, height: 982)) -> [CursorEvent] {
        var events: [CursorEvent] = []
        var t = rng.edgy(0, 2, edges: [0])
        var x = rng.double(0, Double(size.width)), y = rng.double(0, Double(size.height))
        var clickRun = 0
        for _ in 0..<count {
            let step = rng.pick([1.0 / 60, 1.0 / 60, 1.0 / 120, 0, 0.25, 1.0 / 30])
            t += step
            if rng.bool(0.85) {
                x += rng.double(-40, 40)
                y += rng.double(-40, 40)
            }
            if clickRun == 0, rng.bool(0.04) { clickRun = rng.int(1, 8) }
            let isClick = clickRun > 0
            if clickRun > 0 { clickRun -= 1 }
            events.append(CursorEvent(timestamp: t, x: CGFloat(x), y: CGFloat(y), isClick: isClick))
        }
        return events
    }

    private static func cursorSmootherCases() -> [WV] {
        var rng = WVRandom(seed: "cursorSmoother")
        var cases: [WV] = []
        for i in 0..<700 {
            let count = i % 50 == 0 ? rng.int(0, 2) : rng.int(3, 120)
            let events = randomCursorEvents(&rng, count: count)
            let factor = rng.edgy(0.02, 1.0, edges: [0.15, 0.5, 1, 0, 0.999, 0.0667, 0.03333])
            let smoother = CursorSmoother(factor: factor)
            let first = events.first?.timestamp ?? 0
            let last = events.last?.timestamp ?? 0
            let queries: [Double] = (0..<12).map { _ in
                rng.edgy(first - 0.5, last + 0.5, edges: [first, last, last + 0.12, last + 0.1200001] + events.prefix(3).map(\.timestamp))
            }
            let threshold: Double? = rng.bool(0.3) ? rng.edgy(0, 0.5, edges: [0]) : nil
            cases.append(vcase(
                [
                    "factor": factor.wv,
                    "events": .arr(events.map(WVModel.cursorEvent)),
                    "queries": queries.wv,
                    "freshnessThreshold": threshold.wv,
                ],
                [
                    "smoothed": .arr(smoother.smooth(events: events).map(WVModel.cursorEvent)),
                    "interpolate": .arr(queries.map { smoother.interpolate(events: events, at: $0).wv }),
                    "interpolateIfFresh": .arr(queries.map { q in
                        (threshold.map { smoother.interpolateIfFresh(events: events, at: q, freshnessThreshold: $0) }
                            ?? smoother.interpolateIfFresh(events: events, at: q)).wv
                    }),
                ]
            ))
        }
        return cases
    }
}
