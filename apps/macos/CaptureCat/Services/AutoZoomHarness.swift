import Foundation
import CoreGraphics

/// Acceptance gate for the Auto Zoom generator (`CaptureCat --autozoom-test`).
/// Synthetic 60Hz cursor fixtures encode the exact failure modes the old
/// generator shipped: ping-pong on scattered clicks, re-zoom instead of pan
/// between nearby clusters, zooming at a lone stray click, letterbox crop at
/// screen edges, and clobbering the user's manual regions.
enum AutoZoomHarness {

    static let screen = CGSize(width: 1920, height: 1080)
    typealias T = AutoZoomGenerator.Tuning

    private static var failures = 0

    private static func expect(_ condition: Bool, _ label: String) {
        print("\(condition ? "PASS" : "FAIL") \(label)")
        if !condition { failures += 1 }
    }

    // MARK: - Fixture builders (60Hz samples, clicks = ~4 pressed frames)

    /// Events sampled at 60Hz along a path defined by (time, point) waypoints
    /// (linear interpolation), with 0.06s pressed runs at each click time.
    private static func events(
        duration: TimeInterval,
        waypoints: [(TimeInterval, CGPoint)],
        clicks: [TimeInterval]
    ) -> [CursorEvent] {
        var result: [CursorEvent] = []
        let sorted = waypoints.sorted { $0.0 < $1.0 }
        let frames = Int(duration * 60)
        for i in 0...frames {
            let t = Double(i) / 60
            let p: CGPoint
            if let first = sorted.first, t <= first.0 { p = first.1 }
            else if let last = sorted.last, t >= last.0 { p = last.1 }
            else {
                var point = sorted.last!.1
                for j in 1..<sorted.count where t <= sorted[j].0 {
                    let (t0, p0) = sorted[j - 1]
                    let (t1, p1) = sorted[j]
                    let f = t1 > t0 ? (t - t0) / (t1 - t0) : 0
                    point = CGPoint(x: p0.x + (p1.x - p0.x) * f, y: p0.y + (p1.y - p0.y) * f)
                    break
                }
                p = point
            }
            let pressed = clicks.contains { t >= $0 && t < $0 + 0.06 }
            result.append(CursorEvent(timestamp: t, x: p.x, y: p.y, isClick: pressed))
        }
        return result
    }

    /// Cursor parked at `point` for the whole duration, clicking at `clicks`.
    private static func parked(
        duration: TimeInterval, at point: CGPoint, clicks: [TimeInterval],
        arriveFrom: CGPoint? = nil
    ) -> [CursorEvent] {
        var waypoints: [(TimeInterval, CGPoint)] = [(0, point), (duration, point)]
        if let from = arriveFrom {
            waypoints = [(0, from), (min(0.5, duration), point), (duration, point)]
        }
        return events(duration: duration, waypoints: waypoints, clicks: clicks)
    }

    private static func generate(
        _ events: [CursorEvent], duration: TimeInterval,
        keystrokes: [KeystrokeEvent] = [], existing: [ZoomRegion] = []
    ) -> [ZoomRegion] {
        AutoZoomGenerator.generateZoomRegions(
            from: events, videoDuration: duration, screenSize: screen,
            zoomLevel: 2.0, keystrokes: keystrokes, existingRegions: existing)
    }

    private static func keys(_ times: [TimeInterval]) -> [KeystrokeEvent] {
        times.map { KeystrokeEvent(timestamp: $0, category: .key) }
    }

    /// Rhythm invariants every plan must satisfy: min duration, and separate
    /// regions either contiguous (a pan) or spaced by the cooldown.
    private static func assertRhythm(_ regions: [ZoomRegion], _ label: String) {
        for r in regions {
            expect(r.duration >= T.minDuration - 0.001,
                   "\(label): region \(String(format: "%.2f-%.2f", r.startTime, r.endTime)) ≥ min duration")
            expect(r.isAuto == true, "\(label): region carries isAuto")
        }
        let sorted = regions.sorted { $0.startTime < $1.startTime }
        for i in 1..<max(1, sorted.count) where i < sorted.count {
            let gap = sorted[i].startTime - sorted[i - 1].endTime
            expect(gap < 0.001 || gap >= T.cooldown - 0.001,
                   "\(label): gap \(String(format: "%.2f", gap)) is contiguous-pan or ≥ cooldown")
        }
    }

    // MARK: - Cases

    static func run() {
        rapidScatteredClicks()
        twoNearbyClusters()
        typingBurst()
        loneStrayClick()
        edgeActivity()
        manualRegionRespected()
        dwellAndIdle()
        codableFlag()

        print(failures == 0 ? "AUTOZOOM-TEST OK" : "AUTOZOOM-TEST FAILED (\(failures))")
        exit(failures == 0 ? 0 : 1)
    }

    /// Eight clicks all over the screen, 0.7s apart — the old generator made a
    /// sub-second region per click (ping-pong). The plan must be calm: few
    /// regions, each ≥ min duration, pan-or-cooldown between them.
    private static func rapidScatteredClicks() {
        let points: [CGPoint] = [
            CGPoint(x: 200, y: 200), CGPoint(x: 1700, y: 900), CGPoint(x: 300, y: 850),
            CGPoint(x: 1600, y: 150), CGPoint(x: 950, y: 550), CGPoint(x: 200, y: 900),
            CGPoint(x: 1750, y: 500), CGPoint(x: 500, y: 300),
        ]
        let clickTimes = (0..<8).map { 1.0 + Double($0) * 0.7 }
        // Real users STOP to click: hold each point through the pressed run,
        // else the drag-run exclusion (correctly) discards the click.
        var waypoints: [(TimeInterval, CGPoint)] = [(0, points[0])]
        for (t, p) in zip(clickTimes, points) {
            waypoints.append((t, p))
            waypoints.append((t + 0.2, p))
        }
        let evts = events(duration: 10, waypoints: waypoints, clicks: clickTimes)
        let regions = generate(evts, duration: 10)
        expect(!regions.isEmpty, "scattered: produces a plan")
        expect(regions.count <= 3, "scattered: ≤3 regions for 8 scattered clicks (got \(regions.count))")
        assertRhythm(regions, "scattered")
    }

    /// Two clusters ~15% of the frame apart with a 1.5s gap: hysteresis must
    /// PAN (contiguous regions, same depth) instead of zoom-out/zoom-in.
    private static func twoNearbyClusters() {
        let a = CGPoint(x: 700, y: 500)
        let b = CGPoint(x: 1050, y: 560)   // ~0.18 of width away
        let clicksA: [TimeInterval] = [1.0, 1.5]
        let clicksB: [TimeInterval] = [4.6, 5.1]
        let evts = events(
            duration: 9,
            waypoints: [(0, a), (2.0, a), (4.2, b), (9, b)],
            clicks: clicksA + clicksB)
        let regions = generate(evts, duration: 9).sorted { $0.startTime < $1.startTime }
        expect(regions.count == 2, "nearby: two regions (got \(regions.count))")
        if regions.count == 2 {
            expect(abs(regions[1].startTime - regions[0].endTime) < 0.001,
                   "nearby: contiguous — a pan, not an out-and-back-in")
            expect(regions[0].zoomLevel == regions[1].zoomLevel,
                   "nearby: matched depth (lateral pan, no pump)")
            expect(regions[1].focalPoint.x > regions[0].focalPoint.x,
                   "nearby: focal actually moved toward the second cluster")
        }
        assertRhythm(regions, "nearby")
    }

    /// Click into a field then a 10-key burst: one deep zoom held through the
    /// typing, starting before the click (lead-in).
    private static func typingBurst() {
        let field = CGPoint(x: 900, y: 400)
        let evts = parked(duration: 12, at: field, clicks: [2.0], arriveFrom: CGPoint(x: 100, y: 100))
        let keyTimes = (0..<10).map { 2.5 + Double($0) * 0.25 }
        let regions = generate(evts, duration: 12, keystrokes: keys(keyTimes))
        expect(regions.count == 1, "typing: one region (got \(regions.count))")
        if let r = regions.first {
            expect(r.zoomLevel > 2.0, "typing: deep zoom (\(r.zoomLevel) > base 2.0)")
            expect(r.startTime <= 2.0 - T.leadIn + 0.001, "typing: lead-in before the click")
            expect(r.endTime >= 4.75 + T.release - 0.3, "typing: held through the burst + release")
        }
        assertRhythm(regions, "typing")
    }

    /// One transient click on an otherwise moving cursor → NO zoom.
    private static func loneStrayClick() {
        let evts = events(
            duration: 8,
            waypoints: [(0, CGPoint(x: 100, y: 100)), (4, CGPoint(x: 1800, y: 950)),
                        (8, CGPoint(x: 200, y: 900))],
            clicks: [3.0])
        let regions = generate(evts, duration: 8)
        expect(regions.isEmpty, "lone click: no zoom (got \(regions.count))")
    }

    /// Two clicks tight against the top-left corner: the focal must be clamped
    /// so the zoomed viewport stays inside the frame (no letterbox crop).
    private static func edgeActivity() {
        let corner = CGPoint(x: 30, y: 25)
        let evts = parked(duration: 8, at: corner, clicks: [2.0, 2.6],
                          arriveFrom: CGPoint(x: 960, y: 540))
        let regions = generate(evts, duration: 8)
        expect(regions.count == 1, "edge: one region (got \(regions.count))")
        if let r = regions.first {
            let halfVisible = 0.5 / r.zoomLevel
            expect(Double(r.focalPoint.x) >= halfVisible - 0.001
                && Double(r.focalPoint.y) >= halfVisible - 0.001,
                   "edge: focal clamped inside viewport bounds "
                   + String(format: "(%.3f, %.3f) half=%.3f", r.focalPoint.x, r.focalPoint.y, halfVisible))
        }
        assertRhythm(regions, "edge")
    }

    /// A manual region sits over part of the activity: generated regions must
    /// never intersect it (with cooldown air on each side).
    private static func manualRegionRespected() {
        let spot = CGPoint(x: 900, y: 500)
        let clickTimes: [TimeInterval] = [1.0, 1.5, 5.0, 5.5, 9.0, 9.5]
        let evts = parked(duration: 14, at: spot, clicks: clickTimes,
                          arriveFrom: CGPoint(x: 100, y: 100))
        let manual = ZoomRegion(startTime: 4.0, endTime: 7.0, zoomLevel: 1.8,
                                focalPoint: CGPoint(x: 0.3, y: 0.3))
        let regions = generate(evts, duration: 14, existing: [manual])
        expect(!regions.isEmpty, "manual: still generates around the manual block")
        for r in regions {
            let clear = r.endTime <= manual.startTime - T.cooldown + 0.001
                || r.startTime >= manual.endTime + T.cooldown - 0.001
            expect(clear, "manual: region \(String(format: "%.2f-%.2f", r.startTime, r.endTime)) avoids manual span")
            expect(r.isAuto == true, "manual: generated region flagged isAuto")
        }
    }

    /// Cursor travels then hovers one spot 2s (no click) → dwell zoom.
    /// Cursor parked from t=0 for the whole take → idle, no zoom.
    private static func dwellAndIdle() {
        let hover = events(
            duration: 8,
            waypoints: [(0, CGPoint(x: 100, y: 900)), (2.0, CGPoint(x: 1200, y: 400)),
                        (4.0, CGPoint(x: 1200, y: 400)), (5.0, CGPoint(x: 1800, y: 1000)),
                        (8.0, CGPoint(x: 300, y: 100))],
            clicks: [])
        let hoverRegions = generate(hover, duration: 8)
        expect(hoverRegions.count == 1, "dwell: hovering after travel zooms (got \(hoverRegions.count))")

        let idle = parked(duration: 10, at: CGPoint(x: 960, y: 540), clicks: [])
        let idleRegions = generate(idle, duration: 10)
        expect(idleRegions.isEmpty, "idle: parked cursor never zooms (got \(idleRegions.count))")
    }

    /// isAuto round-trips through Codable; legacy JSON without the key loads
    /// with nil (old projects must always load).
    private static func codableFlag() {
        let region = ZoomRegion(startTime: 1, endTime: 3, zoomLevel: 2.2,
                                focalPoint: CGPoint(x: 0.4, y: 0.6), isAuto: true)
        if let data = try? JSONEncoder().encode(region),
           let back = try? JSONDecoder().decode(ZoomRegion.self, from: data) {
            expect(back.isAuto == true, "codable: isAuto round-trips")
        } else {
            expect(false, "codable: region encodes+decodes")
        }
        let legacy = ZoomRegion(startTime: 0, endTime: 2)
        if let data = try? JSONEncoder().encode(legacy),
           var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            json.removeValue(forKey: "isAuto")
            if let stripped = try? JSONSerialization.data(withJSONObject: json),
               let old = try? JSONDecoder().decode(ZoomRegion.self, from: stripped) {
                expect(old.isAuto == nil, "codable: legacy region without isAuto decodes nil")
            } else {
                expect(false, "codable: legacy region decodes")
            }
        }
    }
}
