import CoreGraphics
import Foundation
import ImageIO

/// Export parity (Studio Phase 3): the Mac's render-parity fixtures
/// (`CaptureCat --web-parity-fixtures <dir>`) exported again by THIS
/// platform's `VideoExporter` — the same `project.json`, the same media, the
/// same lossless pre-encode frame tap (`CAPTURECAT_EXPORT_FRAME_TAP`) and the
/// same camera-path dump (`CAPTURECAT_DUMP_CAMERA`) — and scored against the
/// frames and camera path the Mac's exporter recorded.
///
/// Shared by both platforms (StudioHarness/): StudioLab runs it on iOS
/// (`--ios-export-parity`, apps/ios/scripts/ios-export-parity.sh); the Mac runs
/// the SAME code (`--export-parity`) as the control — the Mac re-exporting its
/// own fixtures must be byte-identical, and with an injected defect
/// (`--inject padding`: every project's padding +2 pt) the gate must fail.
///
/// Inputs are exactly the Mac's: projects pin every system-dependent colour to
/// literal sRGB and export headless (canvas scale 1), media paths are absolute
/// (the Simulator reads host paths).
enum ExportParityHarness {
    /// Per-frame bar. A frame passes when its mean |Δ| over RGB is ≤ `meanBar`
    /// AND at most `over8Bar` of its pixels differ by > 8 in any channel.
    static let meanBar = 0.5
    static let over8Bar = 0.001

    struct FrameScore {
        var index: Int
        var mean: Double
        var maxDelta: Int
        var over8: Double
        var pass: Bool { mean <= ExportParityHarness.meanBar && over8 <= ExportParityHarness.over8Bar }
    }

    struct FixtureResult {
        var name: String
        var frames: [FrameScore] = []
        /// Largest |Δ| between this platform's camera path and the Mac's, in
        /// the dump's print precision; nil when either side had none.
        var cameraMaxDelta: Double?
        var cameraRows: (here: Int, mac: Int) = (0, 0)
        var error: String?
        var pass: Bool {
            error == nil && !frames.isEmpty && frames.allSatisfy(\.pass)
                && cameraRows.here == cameraRows.mac && (cameraMaxDelta ?? 0) == 0
        }
    }

    enum Inject: String { case padding }

    /// Runs every fixture in `fixtures` (or those named in `only`), writing this
    /// platform's taps under `out`. `log` receives one line per frame/fixture.
    @MainActor
    static func run(fixtures: URL, out: URL, only: Set<String>? = nil, inject: Inject? = nil,
                    log: (String) -> Void) async -> [FixtureResult] {
        let fm = FileManager.default
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        guard let manifestData = try? Data(contentsOf: fixtures.appendingPathComponent("manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
              let entries = manifest["fixtures"] as? [[String: Any]] else {
            log("EXPORT-PARITY FAIL no manifest.json in \(fixtures.path)")
            return []
        }
        var results: [FixtureResult] = []
        for entry in entries {
            guard let name = entry["name"] as? String, let dirName = entry["dir"] as? String else { continue }
            if let only, !only.contains(name) { continue }
            let result = await runFixture(name: name, dir: fixtures.appendingPathComponent(dirName),
                                          out: out.appendingPathComponent(dirName), inject: inject)
            for f in result.frames {
                log(String(format: "EXPORT %@ frame %04d mean %.3f max %d over8 %.3f%% %@",
                           name, f.index, f.mean, f.maxDelta, f.over8 * 100, f.pass ? "PASS" : "FAIL"))
            }
            if let error = result.error { log("EXPORT \(name) ERROR \(error)") }
            log(String(format: "CAMPATH %@ rows %d/%d maxDelta %@ %@", name, result.cameraRows.here,
                       result.cameraRows.mac, result.cameraMaxDelta.map { String($0) } ?? "–",
                       result.cameraRows.here == result.cameraRows.mac && (result.cameraMaxDelta ?? 0) == 0
                           ? "PASS" : "FAIL"))
            results.append(result)
        }
        let passed = results.filter(\.pass).count
        let worst = results.flatMap { r in r.frames.map { (r.name, $0) } }.max { $0.1.mean < $1.1.mean }
        if let worst {
            log(String(format: "WORST %@ frame %04d mean %.3f max %d over8 %.3f%%", worst.0, worst.1.index,
                       worst.1.mean, worst.1.maxDelta, worst.1.over8 * 100))
        }
        log("EXPORT-PARITY \(passed == results.count && !results.isEmpty ? "PASS" : "FAIL") \(passed)/\(results.count) fixtures")
        return results
    }

    @MainActor
    private static func runFixture(name: String, dir: URL, out: URL, inject: Inject?) async -> FixtureResult {
        var result = FixtureResult(name: name)
        let fm = FileManager.default
        try? fm.removeItem(at: out)
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        guard let fixtureData = try? Data(contentsOf: dir.appendingPathComponent("fixture.json")),
              let fixture = try? JSONSerialization.jsonObject(with: fixtureData) as? [String: Any],
              let frames = fixture["frames"] as? [[String: Any]],
              let projectData = try? Data(contentsOf: dir.appendingPathComponent("project.json")),
              let project = try? JSONDecoder().decode(Project.self, from: projectData) else {
            result.error = "fixture.json / project.json unreadable"
            return result
        }
        if inject == .padding { project.settings.backgroundPadding += 2 }
        let indices = frames.compactMap { $0["index"] as? Int }

        let tap = out.appendingPathComponent("tap", isDirectory: true)
        let cameraDump = out.appendingPathComponent("camera-path.txt")
        setenv("CAPTURECAT_EXPORT_FRAME_TAP", tap.path, 1)
        setenv("CAPTURECAT_EXPORT_FRAME_TAP_INDICES", indices.map(String.init).joined(separator: ","), 1)
        setenv("CAPTURECAT_DUMP_CAMERA", cameraDump.path, 1)
        defer {
            unsetenv("CAPTURECAT_EXPORT_FRAME_TAP")
            unsetenv("CAPTURECAT_EXPORT_FRAME_TAP_INDICES")
            unsetenv("CAPTURECAT_DUMP_CAMERA")
        }
        let movie = out.appendingPathComponent("export.mp4")
        do {
            try await VideoExporter().export(project: project, to: movie)
        } catch {
            result.error = "export failed: \(error)"
            return result
        }
        try? fm.removeItem(at: movie)

        for index in indices.sorted() {
            let file = String(format: "%04d.png", index)
            guard let here = loadRGBA(tap.appendingPathComponent(file)),
                  let mac = loadRGBA(dir.appendingPathComponent("frames").appendingPathComponent(file)) else {
                result.frames.append(FrameScore(index: index, mean: 255, maxDelta: 255, over8: 1))
                continue
            }
            defer { here.deallocate(); mac.deallocate() }
            result.frames.append(compare(here, mac, index: index))
        }

        let macPath = (fixture["exporterCameraPath"] as? [[String: Any]] ?? []).map { row in
            ["t", "zoom", "focalX", "focalY", "offsetX", "offsetY", "tiltPitch", "tiltYaw", "tiltRoll"]
                .map { (row[$0] as? Double) ?? .nan }
        }
        let herePath = parseCameraDump((try? String(contentsOf: cameraDump, encoding: .utf8)) ?? "")
        result.cameraRows = (herePath.count, macPath.count)
        if !herePath.isEmpty, herePath.count == macPath.count {
            var worst = 0.0
            for (a, b) in zip(herePath, macPath) {
                for (x, y) in zip(a, b) { worst = max(worst, abs(x - y)) }
            }
            result.cameraMaxDelta = worst
        }
        return result
    }

    /// `CAM t=… z=… fx=… fy=… ox=… oy=… p=… yw=… r=…` → 9 values, rounded the
    /// way the Mac stores them in fixture.json (4 decimals).
    static func parseCameraDump(_ text: String) -> [[Double]] {
        text.split(separator: "\n").compactMap { line -> [Double]? in
            guard line.hasPrefix("CAM ") else { return nil }
            let values = line.split(separator: " ").dropFirst().compactMap { part -> Double? in
                guard let eq = part.firstIndex(of: "=") else { return nil }
                return Double(part[part.index(after: eq)...])
            }
            return values.count == 9 ? values : nil
        }
    }

    private static func loadRGBA(_ url: URL) -> HarnessPixels.Pixels? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return HarnessPixels.rgba(image)
    }

    static func compare(_ a: HarnessPixels.Pixels, _ b: HarnessPixels.Pixels, index: Int) -> FrameScore {
        guard a.width == b.width, a.height == b.height else {
            return FrameScore(index: index, mean: 255, maxDelta: 255, over8: 1)
        }
        var total = 0
        var maxDelta = 0
        var over = 0
        for y in 0..<a.height {
            let ra = a.bytes + y * a.bytesPerRow
            let rb = b.bytes + y * b.bytesPerRow
            for x in 0..<a.width {
                var worst = 0
                for c in 0..<3 {
                    let d = abs(Int(ra[x * 4 + c]) - Int(rb[x * 4 + c]))
                    total += d
                    worst = max(worst, d)
                }
                maxDelta = max(maxDelta, worst)
                if worst > 8 { over += 1 }
            }
        }
        let px = a.width * a.height
        return FrameScore(index: index, mean: Double(total) / Double(px * 3), maxDelta: maxDelta,
                          over8: Double(over) / Double(px))
    }
}
