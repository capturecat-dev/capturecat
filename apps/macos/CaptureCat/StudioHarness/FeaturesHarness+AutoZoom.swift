import CoreGraphics
import Foundation

/// Auto Zoom: a synthetic Mac capture (recording, cursor.json, keystrokes)
/// through `AutoZoomApplier.applyAsEdit` — the command both editors run —
/// at the project's default level and at a level set on the slider. The
/// blocks must be IDENTICAL (every field but the minted id).
extension FeaturesHarness {
    enum AutoZoomFixture {
        static let recording = "recording.mov"
        static let cursor = "cursor.json"
        static let keystrokes = "keystrokes.json"
        /// 1920×1080 frames → AutoZoomApplier's screen size is natural / 2.
        static let videoSize = CGSize(width: 1920, height: 1080)
        static let screen = CGSize(width: 960, height: 540)
        static let duration: TimeInterval = 20
        /// The slider level of the second run (nil = the project's default).
        static let sliderLevel = 2.6
        /// A hand-placed block the generator must route around and keep
        /// (it covers the stray click at 15.0 s).
        static let manualBlock = (start: 14.6, end: 16.0)

        /// 60 Hz cursor, clicks as 0.06 s pressed runs: a cluster top-left,
        /// a quiet gap, a cluster bottom-right, typing with the cursor parked
        /// centre, a stray click under the manual block, and clicks hard
        /// against the bottom-left edge (the focal clamp).
        static func cursorEvents() -> [CursorEvent] {
            let waypoints: [(TimeInterval, CGPoint)] = [
                (0, CGPoint(x: 480, y: 270)), (1.2, CGPoint(x: 480, y: 270)),
                (1.6, CGPoint(x: 200, y: 150)), (2.2, CGPoint(x: 214, y: 158)),
                (2.8, CGPoint(x: 192, y: 144)), (3.4, CGPoint(x: 205, y: 152)),
                (6.6, CGPoint(x: 205, y: 152)), (7.2, CGPoint(x: 720, y: 400)),
                (7.9, CGPoint(x: 734, y: 412)), (8.7, CGPoint(x: 712, y: 394)),
                (11.0, CGPoint(x: 712, y: 394)), (11.5, CGPoint(x: 480, y: 300)),
                (14.6, CGPoint(x: 486, y: 304)), (14.9, CGPoint(x: 900, y: 520)),
                (16.4, CGPoint(x: 900, y: 520)), (16.9, CGPoint(x: 60, y: 500)),
                (19.0, CGPoint(x: 72, y: 506)), (duration, CGPoint(x: 72, y: 506)),
            ]
            let clicks: [TimeInterval] = [1.8, 2.4, 3.0, 7.4, 8.0, 8.6, 11.8, 15.0, 17.2, 17.8, 18.5]
            var events: [CursorEvent] = []
            let frames = Int(duration * 60)
            for i in 0...frames {
                let t = Double(i) / 60
                var point = waypoints.last!.1
                for j in 1..<waypoints.count where t <= waypoints[j].0 {
                    let (t0, p0) = waypoints[j - 1], (t1, p1) = waypoints[j]
                    let f = t1 > t0 ? (t - t0) / (t1 - t0) : 0
                    point = CGPoint(x: p0.x + (p1.x - p0.x) * f, y: p0.y + (p1.y - p0.y) * f)
                    break
                }
                let pressed = clicks.contains { t >= $0 && t < $0 + 0.06 }
                events.append(CursorEvent(timestamp: t, x: point.x, y: point.y, isClick: pressed))
            }
            return events
        }

        /// A typing burst while the cursor is parked (12.0 – 13.4 s).
        static func keystrokeEvents() -> [KeystrokeEvent] {
            stride(from: 12.0, through: 13.4, by: 0.12).map { KeystrokeEvent(timestamp: $0, category: .key) }
        }

        /// The project both sides run (files from the Mac's fixture dir).
        static func project(in dir: URL) -> Project {
            let project = Project(
                id: UUID(uuidString: "4E4E0000-0000-4000-8000-00000000A200")!,
                name: "features-autozoom",
                videoURL: dir.appendingPathComponent(recording),
                cursorDataURL: dir.appendingPathComponent(cursor),
                duration: duration)
            project.keystrokeDataURL = dir.appendingPathComponent(keystrokes)
            project.trimStart = 0
            project.trimEnd = duration
            project.zoomRegions = [ZoomRegion(startTime: manualBlock.start, endTime: manualBlock.end, zoomLevel: 1.8)]
            return project
        }

        /// One canonical line per block, in time order (id dropped).
        static func blockLines(_ regions: [ZoomRegion]) -> [String] {
            regions.sorted { $0.startTime < $1.startTime }.map { FeaturesHarness.canonical($0) }
        }
    }
}
