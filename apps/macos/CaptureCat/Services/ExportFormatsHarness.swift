import AppKit
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// `CaptureCat --export-formats-test [dir]` — acceptance gate for the export
/// formats, and the golden vectors that lock the web exporter to them.
///
/// 1. GIF policy (`GIFExportPolicy`): frame rate / delay / size / frame count
///    tables → `exportFormats.golden.json` → `gifPolicy`.
/// 2. Fast export (`StaticSpanCollapse`): cursor-motion timestamps, the quiet
///    window, span scans, key quantization, the camera-layout key string, the
///    hot spans of a synthetic project (written as `spans-project.json`) and a
///    stepped skip sequence → `collapse`.
/// 3. A synthetic VFR fixture (`vfr/`): a screen movie with STATIC stretches
///    (no samples, like ScreenCaptureKit), a cursor that rests, a zoom block and
///    a text annotation — exported by the REAL VideoExporter with fast export
///    on at 60 and 30 fps. The files' sample PTS / durations are read back and
///    asserted (collapsed, dense inside hot spans, first + last frame present,
///    gaps < maxStaticGap, file length = timeline) and written as
///    `vfr/expected-<fps>.json` for the web exporter to match.
/// 4. The same fixture exported to `.gif`: ImageIO reads back the type, frame
///    count, per-frame delay, loop count, pixel size and non-blank composed
///    pixels; the pre-fix defect (MP4 bytes in a `.gif`) must FAIL the same
///    check (proves the gate can fail).
///
/// Everything is synthetic (never user media). Sandboxed: an unwritable `dir`
/// lands in the container tmp (printed). Never reached in a normal launch.
enum ExportFormatsHarness {
    static func run() -> Never {
        let args = CommandLine.arguments
        var requested: String?
        if let i = args.firstIndex(of: "--export-formats-test"), args.indices.contains(i + 1),
           !args[i + 1].hasPrefix("--") {
            requested = (args[i + 1] as NSString).expandingTildeInPath
        }
        let dir = WebVectorsHarness.resolveOutputDirectory(requested, prefix: "capturecat-export-formats")
        print("EXPORT-FORMATS dir=\(dir.path)")
        Task { @MainActor in
            let failures = await runAll(dir: dir)
            print(failures == 0 ? "EXPORT-FORMATS PASS" : "EXPORT-FORMATS FAIL (\(failures))")
            exit(failures == 0 ? 0 : 1)
        }
        RunLoop.main.run()
        fatalError("unreachable")
    }

    @MainActor private static var failures = 0

    @MainActor
    private static func expect(_ condition: Bool, _ label: String) {
        print("\(condition ? "PASS" : "FAIL") \(label)")
        if !condition { failures += 1 }
    }

    @MainActor
    private static func runAll(dir: URL) async -> Int {
        failures = 0
        var golden: [String: Any] = [
            "generator": "CaptureCat --export-formats-test",
            "notes": "GIFExportPolicy + StaticSpanCollapse (Services/ExportFormats.swift), evaluated by the real Swift.",
        ]
        golden["gifPolicy"] = gifPolicyVectors()
        do {
            golden["collapse"] = try collapseVectors(dir: dir)
            try await vfrFixture(dir: dir.appendingPathComponent("vfr", isDirectory: true))
        } catch {
            expect(false, "harness error: \(error.localizedDescription)")
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: golden, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: dir.appendingPathComponent("exportFormats.golden.json"))
            print("EXPORT-FORMATS wrote \(dir.appendingPathComponent("exportFormats.golden.json").path)")
        } catch {
            expect(false, "write golden: \(error.localizedDescription)")
        }
        return failures
    }

    // MARK: - 1. GIF policy

    @MainActor
    private static func gifPolicyVectors() -> [String: Any] {
        let fpsCases = [-5, 0, 1, 2, 3, 4, 5, 6, 9, 10, 11, 15, 19, 20, 21, 24, 25, 29, 30, 48, 50, 59, 60, 120]
        let sizes: [CGSize] = [
            CGSize(width: 1280, height: 720), CGSize(width: 1920, height: 1080), CGSize(width: 3840, height: 2160),
            CGSize(width: 1080, height: 1920), CGSize(width: 800, height: 600), CGSize(width: 960, height: 540),
            CGSize(width: 961, height: 541), CGSize(width: 1000, height: 1000), CGSize(width: 2, height: 2),
            CGSize(width: 100, height: 3000), CGSize(width: 1366, height: 768), CGSize(width: 1920, height: 1200),
            CGSize(width: 2560, height: 1080), CGSize(width: 1921, height: 1081), CGSize(width: 1, height: 1),
            CGSize(width: 0, height: 0), CGSize(width: 1440, height: 1440),
        ]
        let durations: [Double] = [0, 0.01, 0.05, 0.2, 1, 4, 4.0001, 5.999, 6, 10.3, 61.25]
        let rates = fpsCases.map { fps -> [String: Any] in
            let rate = GIFExportPolicy.frameRate(forRequested: fps)
            return ["requested": fps, "frameRate": rate, "delayCentiseconds": GIFExportPolicy.delayCentiseconds(frameRate: rate)]
        }
        let sized = sizes.map { s -> [String: Any] in
            let out = GIFExportPolicy.frameSize(for: s)
            return ["width": Double(s.width), "height": Double(s.height), "outWidth": Double(out.width), "outHeight": Double(out.height)]
        }
        var counts: [[String: Any]] = []
        for d in durations {
            for rate in GIFExportPolicy.frameRates {
                counts.append(["duration": d, "frameRate": rate, "frameCount": GIFExportPolicy.frameCount(duration: d, frameRate: rate)])
            }
        }
        let captions = [(CGSize(width: 1920, height: 1080), 60), (CGSize(width: 1280, height: 720), 30), (CGSize(width: 800, height: 600), 15)]
            .map { size, fps -> [String: Any] in
                ["width": Double(size.width), "height": Double(size.height), "fps": fps,
                 "caption": GIFExportPolicy.caption(outputSize: size, requestedFPS: fps)]
            }
        expect(GIFExportPolicy.frameRate(forRequested: 60) == 20 && GIFExportPolicy.frameRate(forRequested: 30) == 20,
               "GIF policy: 30/60 fps export → 20 fps")
        expect(GIFExportPolicy.frameSize(for: CGSize(width: 1920, height: 1080)) == CGSize(width: 960, height: 540),
               "GIF policy: 1080p → 960x540")
        expect(GIFExportPolicy.frameRates.allSatisfy { 100 % $0 == 0 && 100 / $0 >= 2 },
               "GIF policy: every rate has a whole-centisecond delay ≥ 2 cs")
        return [
            "maxFrameRate": GIFExportPolicy.maxFrameRate,
            "maxLongEdge": GIFExportPolicy.maxLongEdge,
            "frameRates": GIFExportPolicy.frameRates,
            "rates": rates,
            "sizes": sized,
            "counts": counts,
            "captions": captions,
        ]
    }

    // MARK: - 2. Static-span collapse

    /// Deterministic LCG in [0, 1).
    private struct LCG {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(UInt64(1) << 53)
        }
    }

    private static func keyJSON(_ k: StaticSpanCollapse.FrameKey) -> [String: Any] {
        var out: [String: Any] = [
            "videoSampleSeconds": k.videoSampleSeconds, "cameraSampleSeconds": k.cameraSampleSeconds,
            "zoom": k.zoom, "focalX": k.focalX, "focalY": k.focalY, "offsetX": k.offsetX, "offsetY": k.offsetY,
            "tiltPitch": k.tiltPitch, "tiltYaw": k.tiltYaw, "tiltRoll": k.tiltRoll,
            "cursorHidden": k.cursorHidden, "dimAlpha": k.dimAlpha, "deviceSegment": k.deviceSegment,
            "cameraLayout": k.cameraLayout,
        ]
        if let p = k.cursorPosition { out["cursorPosition"] = ["x": Double(p.x), "y": Double(p.y)] }
        return out
    }

    private static func randomKey(_ r: inout LCG) -> StaticSpanCollapse.FrameKey {
        // Values straddle quantum boundaries (x.5 × 10^-6 etc.) on purpose.
        func v(_ scale: Double) -> Double { ((r.next() * 2 - 1) * scale * 1e6).rounded() / 1e6 + (r.next() < 0.3 ? 5e-7 : 0) }
        return StaticSpanCollapse.FrameKey(
            videoSampleSeconds: (r.next() * 10 * 600).rounded() / 600,
            cameraSampleSeconds: r.next() < 0.5 ? 0 : (r.next() * 10 * 600).rounded() / 600,
            zoom: 1 + abs(v(1.5)), focalX: 0.5 + v(0.4), focalY: 0.5 + v(0.4),
            offsetX: v(0.1), offsetY: v(0.1),
            tiltPitch: v(20) + (r.next() < 0.3 ? 5e-5 : 0), tiltYaw: v(20), tiltRoll: v(5),
            cursorPosition: r.next() < 0.2 ? nil : CGPoint(x: v(1000) + (r.next() < 0.3 ? 5e-4 : 0), y: v(800)),
            cursorHidden: r.next() < 0.2,
            dimAlpha: r.next() < 0.5 ? 0 : v(1) + (r.next() < 0.3 ? 5e-5 : 0),
            deviceSegment: r.next() < 0.1,
            cameraLayout: r.next() < 0.5 ? "-1,-1,-1,-1,1.000,1.000,1.0000,0.0" : "12,30,240,180,1.000,1.000,1.0000,0.0")
    }

    @MainActor
    private static func collapseVectors(dir: URL) throws -> [String: Any] {
        var r = LCG(state: 0x5eed_c011_a95e)

        // Cursor motion timestamps over a walk with rests, sub-threshold
        // jitter and press runs (the 30 Hz tracker shape).
        var events: [CursorEvent] = []
        var x = 400.0, y = 300.0
        var clickLeft = 0
        for i in 0..<420 {
            let t = Double(i) / 30
            // 6 s cycles: move 1 s, sub-threshold drift 1 s, rest 4 s.
            let phase = Int(t) % 6
            if phase == 0 { x += (r.next() - 0.5) * 30; y += (r.next() - 0.5) * 20 }
            else if phase == 1 { x += (r.next() - 0.5) * 0.8; y += (r.next() - 0.5) * 0.8 }
            if i % 97 == 40 { clickLeft = 4 }
            let isClick = clickLeft > 0
            if clickLeft > 0 { clickLeft -= 1 }
            events.append(CursorEvent(timestamp: t, x: CGFloat(x), y: CGFloat(y), isClick: isClick))
        }
        let timestamps = StaticSpanCollapse.cursorMotionTimestamps(events)
        let quietProbe = StaticSpanCollapse(enabled: true, animationHotSpans: [], outputHotSpans: [], cursorTimestamps: timestamps)
        let probeTimes = stride(from: -1.0, through: 15.0, by: 0.05).map { ($0 * 1000).rounded() / 1000 }
        let quiet = probeTimes.map { quietProbe.cursorQuiet(at: $0) }
        let emptyQuiet = StaticSpanCollapse(enabled: true, animationHotSpans: [], outputHotSpans: [], cursorTimestamps: [])
            .cursorQuiet(at: 3)

        // Span scans (start-sorted, overlapping, nested).
        let spans: [StaticSpanCollapse.Span] = [
            .init(start: -0.5, end: 0.2), .init(start: 0.1, end: 0.15), .init(start: 1, end: 3),
            .init(start: 1.5, end: 1.6), .init(start: 4, end: 4), .init(start: 6, end: 9),
        ]
        let spanProbe = stride(from: -1.0, through: 10.0, by: 0.05).map { ($0 * 1000).rounded() / 1000 }
        let inSpans = spanProbe.map { StaticSpanCollapse.inSpans(spans, $0) }

        // Key quantization + equality.
        var keys: [[String: Any]] = []
        var quantized: [[String: Any]] = []
        var equalPairs: [[String: Any]] = []
        for _ in 0..<60 {
            let k = randomKey(&r)
            keys.append(keyJSON(k))
            quantized.append(keyJSON(k.quantized()))
            var nudged = k
            nudged.zoom += r.next() < 0.5 ? 4e-7 : 6e-7
            if r.next() < 0.3 { nudged.cursorPosition = nudged.cursorPosition.map { CGPoint(x: $0.x + 0.0004, y: $0.y) } }
            equalPairs.append(["a": keyJSON(k), "b": keyJSON(nudged), "equal": k.quantized() == nudged.quantized()])
        }

        // The camera-layout key string (String(format:) rounding + "-0").
        func resolved(_ rect: CGRect?, _ camOp: Double, _ chrome: Double, _ scale: CGFloat, _ tx: CGFloat) -> CameraLayoutMath.Resolved {
            var l = CameraLayoutMath.resolve(
                at: 0, regions: [], videoRect: CGRect(x: 0, y: 0, width: 100, height: 100),
                bubbleRect: CGRect(x: 0, y: 0, width: 10, height: 10), bubbleCornerRadius: 0, cardCornerRadius: 0,
                hasCamera: false)
            l.cameraRect = rect
            l.cameraOpacity = camOp
            l.chromeOpacity = chrome
            l.cardScale = scale
            l.cardTranslationX = tx
            return l
        }
        let layouts = [
            resolved(nil, 1, 1, 1, 0),
            resolved(CGRect(x: 12.5, y: 30.49, width: 240.5, height: 179.5), 0.99949, 0.0005, 0.99995, -0.04),
            resolved(CGRect(x: -0.4, y: -0.6, width: 1.5, height: 2.5), 0.12345, 0.9876, 1.23456, 12.25),
            resolved(CGRect(x: 1919.5, y: 0.5, width: 0.5, height: 1080.5), 0.0015, 0.0025, 0.00005, -0.05),
        ]
        let layoutKeys = layouts.map { l -> [String: Any] in
            var rect: Any = NSNull()
            if let c = l.cameraRect { rect = ["x": Double(c.minX), "y": Double(c.minY), "width": Double(c.width), "height": Double(c.height)] }
            return ["cameraRect": rect, "cameraOpacity": l.cameraOpacity, "chromeOpacity": l.chromeOpacity,
                    "cardScale": Double(l.cardScale), "cardTranslationX": Double(l.cardTranslationX),
                    "key": StaticSpanCollapse.cameraLayoutKey(l)]
        }

        // Hot spans of a synthetic project (the web parses spans-project.json).
        let spansProject = Project(
            id: UUID(uuidString: "0E0F0A11-5A15-4C0E-8A11-000000000001")!, name: "spans",
            videoURL: dir.appendingPathComponent("none.mp4"), cursorDataURL: nil, cameraVideoURL: nil,
            duration: 20, recordingSourceKind: .display)
        spansProject.createdAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        spansProject.cameraLayoutRegions = [
            CameraLayoutRegion(startTime: 2, endTime: 4, mode: .cameraOnly),
            CameraLayoutRegion(startTime: 9, endTime: 11.5, mode: .sideBySide),
        ]
        spansProject.blurRegions = [BlurRegion(startTime: 5, endTime: 6)]
        spansProject.focusRegions = [FocusRegion(startTime: 12, endTime: 13.25)]
        spansProject.highlightRegions = [HighlightRegion(startTime: 7, endTime: 7.5)]
        spansProject.subtitles = [SubtitleSegment(startTime: 1, endTime: 2.5, text: "hello"),
                                  SubtitleSegment(startTime: 14, endTime: 15, text: "world")]
        spansProject.annotations = [Annotation(type: .text, startTime: 16, endTime: 17),
                                    Annotation(type: .arrow, startTime: 0.25, endTime: 0.75)]
        spansProject.settings.animationSpeed = .quick
        spansProject.settings.curtainUnveilCorner = .topLeft
        spansProject.settings.curtainUnveilStart = 3.5
        spansProject.settings.curtainUnveilDuration = 1.25
        spansProject.settings.introSlideStyle = .left
        spansProject.settings.introSlideStart = 0.5
        spansProject.settings.introSlideDuration = 0.75
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(spansProject).write(to: dir.appendingPathComponent("spans-project.json"))
        let keystrokeTimes: [TimeInterval] = [8.2, 18.5]
        let boundaries: [TimeInterval] = [3.3, 19]
        let transition = spansProject.settings.animationSpeed.duration
        let hot = StaticSpanCollapse.animationHotSpans(
            project: spansProject, transitionDuration: transition,
            keystrokeTimes: keystrokeTimes, deviceSegmentBoundaries: boundaries)
        let outHot = StaticSpanCollapse.outputHotSpans(settings: spansProject.settings)
        let spanJSON = { (s: [StaticSpanCollapse.Span]) in s.map { ["start": $0.start, "end": $0.end] } }

        // A stepped skip sequence against those spans + the cursor timestamps.
        var collapser = StaticSpanCollapse(enabled: true, animationHotSpans: hot, outputHotSpans: outHot,
                                           cursorTimestamps: timestamps)
        let fps = 10.0
        let frameCount = 300
        var base = randomKey(&r)
        var steps: [[String: Any]] = []
        for i in 0..<frameCount {
            let roll = r.next()
            // Mostly still after 20 s so the 5 s max-gap rule gets exercised.
            let changeRate = i < 200 ? 0.08 : 0.004
            if roll < changeRate { base = randomKey(&r) } // a real change
            else if roll < 0.3 { base.zoom += 3e-7 } // sub-quantum drift accumulates
            else if roll < 0.33 && i < 200 { base.videoSampleSeconds += 1.0 / 30 } // new source sample
            let outputSeconds = Double(i) / fps
            let sourceTime = outputSeconds
            let skip = collapser.shouldSkip(frameIndex: i, frameCount: frameCount, outputSeconds: outputSeconds,
                                            sourceTime: sourceTime, key: base)
            steps.append(["frameIndex": i, "outputSeconds": outputSeconds, "sourceTime": sourceTime,
                          "key": keyJSON(base), "skip": skip])
        }
        let skipped = steps.filter { $0["skip"] as? Bool == true }.count
        expect(skipped > 0 && skipped < frameCount - 2, "collapse sequence: skips some frames (\(skipped)/\(frameCount))")
        expect(collapser.collapsedFrameCount == skipped, "collapse sequence: collapsedFrameCount matches")

        return [
            "maxStaticGap": StaticSpanCollapse.maxStaticGap,
            "cursorQuietWindow": StaticSpanCollapse.cursorQuietWindow,
            "cursorEvents": events.map { ["timestamp": $0.timestamp, "x": Double($0.x), "y": Double($0.y), "isClick": $0.isClick] },
            "cursorTimestamps": timestamps,
            "quietProbe": ["times": probeTimes, "quiet": quiet, "emptyQuiet": emptyQuiet],
            "spanProbe": ["spans": spanJSON(spans), "times": spanProbe, "inSpans": inSpans],
            "keys": keys,
            "quantized": quantized,
            "equalPairs": equalPairs,
            "cameraLayoutKeys": layoutKeys,
            "hotSpans": [
                "project": "spans-project.json",
                "transitionDuration": transition,
                "keystrokeTimes": keystrokeTimes,
                "deviceSegmentBoundaries": boundaries,
                "animationHotSpans": spanJSON(hot),
                "outputHotSpans": spanJSON(outHot),
            ],
            "sequence": [
                "frameCount": frameCount,
                "steps": steps,
                "collapsedFrameCount": collapser.collapsedFrameCount,
            ],
        ]
    }

    // MARK: - 3 + 4. VFR fixture, MP4 fast export and GIF

    /// Source sample times: 30 fps inside active stretches, nothing between
    /// (ScreenCaptureKit writes a sample only when the screen changes).
    static let vfrDuration: Double = 10
    static let vfrSampleTimes: [Double] = {
        var times: [Double] = []
        for (start, end) in [(0.0, 1.0), (4.0, 4.5), (7.5, 8.0)] {
            var i = Int((start * 30).rounded())
            while Double(i) / 30 < end - 1e-9 { times.append(Double(i) / 30); i += 1 }
        }
        times.append(9.9)
        return times
    }()

    @MainActor
    private static func vfrFixture(dir: URL) async throws {
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let source = CGSize(width: 1280, height: 720)
        let videoURL = dir.appendingPathComponent("recording.mp4")
        try await writeVFRMovie(to: videoURL, size: source, times: vfrSampleTimes, duration: vfrDuration)

        // Cursor: moves in two stretches (one with a click run), rests between
        // — still sampled at 30 Hz, like the tracker.
        let coordinate = CGSize(width: 640, height: 360)
        var events: [CursorEvent] = []
        var clickLeft = 0
        for i in 0...Int(vfrDuration * 30) {
            let t = Double(i) / 30
            var px = 200.0, py = 150.0
            if t >= 0.2 && t < 0.9 { px += (t - 0.2) * 300; py += (t - 0.2) * 100 }
            else if t >= 0.9 { px += 210; py += 70 }
            if t >= 4.1 && t < 4.4 { px -= (t - 4.1) * 250 }
            else if t >= 4.4 { px -= 75 }
            if i == 126 { clickLeft = 3 }
            let isClick = clickLeft > 0
            if clickLeft > 0 { clickLeft -= 1 }
            events.append(CursorEvent(timestamp: t, x: CGFloat(px), y: CGFloat(py), isClick: isClick))
        }
        let cursorURL = dir.appendingPathComponent("cursor.json")
        try JSONEncoder().encode(CursorRecording(version: 2, coordinateWidth: coordinate.width,
                                                 coordinateHeight: coordinate.height, events: events))
            .write(to: cursorURL)

        let project = Project(
            id: UUID(uuidString: "0E0F0A11-5A15-4C0E-8A11-0000000000F5")!, name: "vfr-fast-export",
            videoURL: videoURL, cursorDataURL: cursorURL, cameraVideoURL: nil,
            duration: vfrDuration, recordingSourceKind: .display)
        project.createdAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        project.trimStart = 0
        project.trimEnd = vfrDuration
        let s = project.settings
        s.gradientStartColor = CodableColor(red: 0.42, green: 0.26, blue: 0.93)
        s.gradientEndColor = CodableColor(red: 0.13, green: 0.62, blue: 0.98)
        s.solidColor = CodableColor(red: 0.09, green: 0.1, blue: 0.13)
        s.subtitleHighlightColor = CodableColor(red: 1, green: 0.84, blue: 0.04)
        s.exportSettings.resolution = .hd720
        s.exportSettings.quality = 0.85
        s.exportSettings.collapseStaticSpans = true
        s.exportSettings.format = .mp4
        project.zoomRegions = [ZoomRegion(startTime: 1.2, endTime: 1.8, zoomLevel: 1.6,
                                          focalPoint: CGPoint(x: 0.45, y: 0.5), animationStyle: .smooth)]
        var note = Annotation(type: .text, startTime: 6.0, endTime: 6.3)
        note.text = "Fast export"
        project.annotations = [note]

        var summary: [String: Any] = ["sourceSampleTimes": vfrSampleTimes, "duration": vfrDuration]
        for fps in [60, 30] {
            s.exportSettings.fps = fps
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(project).write(to: dir.appendingPathComponent("project-\(fps).json"))
            let url = dir.appendingPathComponent("export-\(fps).mp4")
            try await VideoExporter().export(project: project, to: url)
            let timing = try await sampleTiming(of: url)
            let cfrCount = Int(ceil(vfrDuration * Double(fps)))
            let indices = timing.pts.map { Int(($0 * Double(fps)).rounded()) }
            // Frame i's PTS is CMTime(seconds: i / fps, preferredTimescale: 600),
            // which TRUNCATES (11/60 → 109/600).
            let onGrid = zip(timing.pts, indices).allSatisfy {
                abs($0 - CMTime(seconds: Double($1) / Double(fps), preferredTimescale: 600).seconds) < 1e-9
            }
            let gaps = zip(timing.pts.dropFirst(), timing.pts).map { $0 - $1 }
            let trackDuration = try await AVURLAsset(url: url).load(.duration).seconds
            expect(timing.pts.count < cfrCount, "fast export \(fps) fps: collapsed \(cfrCount) → \(timing.pts.count) samples")
            expect(indices.first == 0 && indices.last == cfrCount - 1, "fast export \(fps) fps: first + last frame present")
            expect(onGrid, "fast export \(fps) fps: every PTS is the exporter's frame time (CMTime 600, truncated)")
            expect((gaps.max() ?? 0) < StaticSpanCollapse.maxStaticGap + 1e-9, "fast export \(fps) fps: gaps < maxStaticGap")
            expect(abs(trackDuration - vfrDuration) < 0.002, "fast export \(fps) fps: file length = the timeline (\(trackDuration))")
            // Inside the annotation's hot span (source 5.0…7.3 = output, no
            // speed) every frame must be present.
            let hotFrames = Set(Int(ceil(5.0 * Double(fps)))...Int(floor(7.3 * Double(fps))))
            expect(hotFrames.isSubset(of: Set(indices)), "fast export \(fps) fps: dense inside the annotation hot span")
            let expected: [String: Any] = [
                "fps": fps, "totalSeconds": vfrDuration, "cfrFrameCount": cfrCount,
                "keptFrameIndices": indices, "pts": timing.pts, "durations": timing.durations,
            ]
            let data = try JSONSerialization.data(withJSONObject: expected, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: dir.appendingPathComponent("expected-\(fps).json"))
            summary["kept-\(fps)"] = indices.count
        }

        // Webcam variant: a 30 fps camera track + a side-by-side layout block,
        // so the key's camera sample + camera-layout string take part.
        let cameraURL = dir.appendingPathComponent("camera.mp4")
        try await SyntheticMovie.write(to: cameraURL, size: CGSize(width: 640, height: 480), duration: vfrDuration,
                                       fps: 30, style: .camera)
        let camProject = Project(
            id: UUID(uuidString: "0E0F0A11-5A15-4C0E-8A11-0000000000F7")!, name: "vfr-fast-export-camera",
            videoURL: videoURL, cursorDataURL: cursorURL, cameraVideoURL: cameraURL,
            duration: vfrDuration, recordingSourceKind: .display)
        camProject.createdAt = project.createdAt
        camProject.trimStart = 0
        camProject.trimEnd = vfrDuration
        let encoderCam = JSONEncoder()
        encoderCam.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Same settings as the screen-only project (Codable round trip), camera on.
        camProject.settings = try JSONDecoder().decode(ProjectSettings.self, from: encoderCam.encode(project.settings))
        camProject.settings.showCamera = true
        camProject.settings.exportSettings.fps = 60
        camProject.zoomRegions = project.zoomRegions
        camProject.annotations = project.annotations
        camProject.cameraLayoutRegions = [CameraLayoutRegion(startTime: 8.4, endTime: 9.2, mode: .sideBySide)]
        try encoderCam.encode(camProject).write(to: dir.appendingPathComponent("project-camera-60.json"))
        let camExport = dir.appendingPathComponent("export-camera-60.mp4")
        try await VideoExporter().export(project: camProject, to: camExport)
        let camTiming = try await sampleTiming(of: camExport)
        let camIndices = camTiming.pts.map { Int(($0 * 60).rounded()) }
        expect(camTiming.pts.count < 600 && camIndices.first == 0 && camIndices.last == 599,
               "fast export + camera 60 fps: collapsed 600 → \(camTiming.pts.count), first + last present")
        let camExpected: [String: Any] = [
            "fps": 60, "totalSeconds": vfrDuration, "cfrFrameCount": 600,
            "keptFrameIndices": camIndices, "pts": camTiming.pts, "durations": camTiming.durations,
        ]
        try JSONSerialization.data(withJSONObject: camExpected, options: [.prettyPrinted, .sortedKeys])
            .write(to: dir.appendingPathComponent("expected-camera-60.json"))
        summary["kept-camera-60"] = camIndices.count

        // GIF: same project (60 fps requested → 20 fps), 720p → 960x540.
        s.exportSettings.fps = 60
        s.exportSettings.format = .gif
        let gifURL = dir.appendingPathComponent("export.gif")
        try await VideoExporter().export(project: project, to: gifURL)
        let expectedCount = GIFExportPolicy.frameCount(duration: vfrDuration, frameRate: 20)
        let check = gifCheck(gifURL, expectedCount: expectedCount, delay: 0.05, size: CGSize(width: 960, height: 540))
        expect(check.ok, "GIF: \(check.detail)")
        summary["gif"] = ["frameCount": expectedCount, "delayCentiseconds": 5, "width": 960, "height": 540,
                          "bytes": (try? fm.attributesOfItem(atPath: gifURL.path)[.size] as? Int) ?? 0]
        // Composed pixels, not a blank canvas: frame 0 matches the MP4's first
        // frame on average colour and is not uniform.
        if let first = gifFrame(gifURL, index: 0), let movieFirst = try? await firstFrame(of: dir.appendingPathComponent("export-60.mp4")) {
            let a = meanAndSpread(first)
            let b = meanAndSpread(movieFirst)
            let delta = zip(a.mean, b.mean).map { abs($0 - $1) }.max() ?? 255
            expect(a.spread > 10 && delta < 14, "GIF: frame 0 is the composed frame (mean Δ \(String(format: "%.1f", delta)), spread \(String(format: "%.1f", a.spread)))")
        } else {
            expect(false, "GIF: could not decode frame 0 for the content check")
        }
        // Defect injection: the pre-fix exporter wrote MP4 bytes into `.gif`.
        let fake = dir.appendingPathComponent("defect-mp4-bytes.gif")
        try? fm.removeItem(at: fake)
        try fm.copyItem(at: dir.appendingPathComponent("export-60.mp4"), to: fake)
        let defect = gifCheck(fake, expectedCount: expectedCount, delay: 0.05, size: CGSize(width: 960, height: 540))
        expect(!defect.ok, "GIF: injected defect (MP4 bytes in .gif) is caught — \(defect.detail)")
        try? fm.removeItem(at: fake)

        let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: dir.appendingPathComponent("summary.json"))
    }

    private static func writeVFRMovie(to url: URL, size: CGSize, times: [Double], duration: Double) async throws {
        try? FileManager.default.removeItem(at: url)
        let width = Int(size.width), height = Int(size.height)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: VideoColorTags.colorProperties(p3: false),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000, AVVideoAllowFrameReorderingKey: false],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for (index, t) in times.enumerated() {
            while !input.isReadyForMoreMediaData { try? await Task.sleep(nanoseconds: 2_000_000) }
            guard let pool = adaptor.pixelBufferPool else { throw HarnessError("no pixel buffer pool") }
            var out: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
            guard let buffer = out else { throw HarnessError("no pixel buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let ctx = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) {
                // A window-ish screen: flat chrome, rows of "text", and a bar
                // that moves with the sample index.
                ctx.setFillColor(CGColor(srgbRed: 0.93, green: 0.94, blue: 0.96, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
                ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.22, blue: 0.27, alpha: 1))
                ctx.fill(CGRect(x: 0, y: height - 48, width: width, height: 48))
                for row in 0..<14 {
                    let w = 300 + (row * 97) % 600
                    ctx.setFillColor(CGColor(srgbRed: 0.35, green: 0.38, blue: 0.45, alpha: 1))
                    ctx.fill(CGRect(x: 80, y: height - 110 - row * 38, width: w, height: 14))
                }
                ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.45, blue: 0.95, alpha: 1))
                ctx.fill(CGRect(x: 40 + (index * 23) % (width - 200), y: 120, width: 160, height: 90))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(seconds: t, preferredTimescale: 600))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 600))
        await writer.finishWriting()
        if writer.status != .completed { throw HarnessError("VFR movie: \(writer.error?.localizedDescription ?? "failed")") }
    }

    private struct HarnessError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// Video sample PTS + durations (seconds), presentation order.
    private static func sampleTiming(of url: URL) async throws -> (pts: [Double], durations: [Double]) {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw HarnessError("no video track") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.startReading()
        var samples: [(Double, Double)] = []
        while let buffer = output.copyNextSampleBuffer() {
            // Skip the reader's marker buffers (no samples, zero duration).
            guard CMSampleBufferGetNumSamples(buffer) > 0, CMSampleBufferGetTotalSampleSize(buffer) > 0 else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
            let duration = CMSampleBufferGetDuration(buffer)
            if pts.isValid { samples.append((pts.seconds, duration.isValid ? duration.seconds : 0)) }
        }
        samples.sort { $0.0 < $1.0 }
        return (samples.map(\.0), samples.map(\.1))
    }

    private static func gifCheck(_ url: URL, expectedCount: Int, delay: Double, size: CGSize) -> (ok: Bool, detail: String) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return (false, "unreadable") }
        let type = CGImageSourceGetType(src) as String? ?? "?"
        guard type == UTType.gif.identifier else { return (false, "type \(type), not GIF") }
        let count = CGImageSourceGetCount(src)
        guard count == expectedCount else { return (false, "\(count) frames, expected \(expectedCount)") }
        let fileProps = CGImageSourceCopyProperties(src, nil) as? [CFString: Any]
        let loop = (fileProps?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount] as? Int
        guard loop == 0 else { return (false, "loop count \(loop.map(String.init) ?? "missing"), expected 0 (forever)") }
        for i in 0..<count {
            let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let d = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? -1
            guard abs(d - delay) < 1e-6 else { return (false, "frame \(i) delay \(d), expected \(delay)") }
            let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
            let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
            guard w == Int(size.width) && h == Int(size.height) else { return (false, "frame \(i) is \(w)x\(h)") }
        }
        return (true, "\(count) frames @ \(Int((delay * 100).rounded())) cs, \(Int(size.width))x\(Int(size.height)), loops forever")
    }

    private static func gifFrame(_ url: URL, index: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, index, nil)
    }

    private static func firstFrame(of url: URL) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var actual = CMTime.zero
        return try generator.copyCGImage(at: .zero, actualTime: &actual)
    }

    /// Mean sRGB colour (0…255) and the mean absolute deviation of luma, on
    /// a 64×36 sRGB thumbnail.
    private static func meanAndSpread(_ image: CGImage) -> (mean: [Double], spread: Double) {
        let w = 64, h = 36
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = ctx.data else { return ([0, 0, 0], 0) }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var sum = [0.0, 0.0, 0.0]
        var lumas: [Double] = []
        for i in 0..<(w * h) {
            let r = Double(px[i * 4]), g = Double(px[i * 4 + 1]), b = Double(px[i * 4 + 2])
            sum[0] += r; sum[1] += g; sum[2] += b
            lumas.append(0.2126 * r + 0.7152 * g + 0.0722 * b)
        }
        let n = Double(w * h)
        let meanLuma = lumas.reduce(0, +) / n
        let spread = lumas.map { abs($0 - meanLuma) }.reduce(0, +) / n
        return (sum.map { $0 / n }, spread)
    }
}
