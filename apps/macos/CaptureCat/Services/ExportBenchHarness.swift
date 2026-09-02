import AppKit
import AVFoundation

/// `--export-bench [seconds]` — headless export throughput benchmark.
///
/// Builds a deterministic fixture (the parity harness's synthetic frame,
/// encoded to a real mp4 by StillMovieWriter, wrapped in the parity fixture
/// project plus a few zoom regions so the compositor actually works), runs a
/// full VideoExporter pass, and prints wall time / encoded fps / ×realtime.
///
/// This measures RELATIVE throughput between two builds on the same machine —
/// the still-frame source decodes cheaply, so absolute numbers flatter the
/// pipeline versus a real screen recording. Run it before and after a change;
/// never quote its fps as a product number. Never reached in a normal launch.
enum ExportBenchHarness {
    static func run() -> Never {
        // Optional trailing duration argument: `--export-bench 30`.
        let args = CommandLine.arguments
        var seconds: TimeInterval = 10
        if let flagIndex = args.firstIndex(of: "--export-bench"),
           args.indices.contains(flagIndex + 1),
           let value = TimeInterval(args[flagIndex + 1]), value > 0 {
            seconds = min(value, 120)
        }

        Task { @MainActor in
            let code = await bench(seconds: seconds)
            exit(code)
        }
        RunLoop.main.run()
        fatalError("unreachable")
    }

    @MainActor
    private static func bench(seconds: TimeInterval) async -> Int32 {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("capturecat-export-bench-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // CAPTURECAT_BENCH_KEEP=1 leaves the outputs on disk for pixel-level
        // A/B comparison between pipeline variants (e.g. BGRA vs NV12 handoff).
        let keep = ProcessInfo.processInfo.environment["CAPTURECAT_BENCH_KEEP"] != nil
        if keep { print("EXPORT-BENCH keeping outputs at \(dir.path)") }
        defer { if !keep { try? FileManager.default.removeItem(at: dir) } }

        // Fixture source: the parity harness's structured synthetic frame at
        // 1080p2x, encoded once into a real mp4 the exporter reads normally.
        let frameSize = CGSize(width: 3840, height: 2160)
        let frame = PreviewParityHarness.syntheticVideoFrame(size: frameSize)
        guard let cgFrame = frame.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            print("EXPORT-BENCH FAILED: could not rasterize fixture frame")
            return 1
        }
        let sourceURL = dir.appendingPathComponent("bench-source.mp4")
        do {
            _ = try await StillMovieWriter.write(image: cgFrame, to: sourceURL, duration: seconds)
        } catch {
            print("EXPORT-BENCH FAILED: fixture encode — \(error.localizedDescription)")
            return 1
        }

        // Same pinned project as the visual gates, driven through the real
        // moving parts: three zoom regions (spring in/out, pan) so per-frame
        // transforms, masks, and the shadow/background bake all execute.
        let project = PreviewParityHarness.makeFixtureProject(duration: seconds)
        project.videoURL = sourceURL
        // 4K OUTPUT canvas — the default 1080p would silently bench a 4× smaller
        // render target than the headline "4K export" claim.
        project.settings.exportSettings.resolution = .uhd4k
        let span = seconds / 4
        if CommandLine.arguments.contains("--bench-plain") {
            // Probe mode: near-empty effect graph, same output/encode load —
            // separates render cost from the encoder's throughput ceiling.
            project.zoomRegions = []
        } else {
        project.zoomRegions = [
            ZoomRegion(startTime: span * 0.3, endTime: span * 1.2, zoomLevel: 2.0,
                       focalPoint: CGPoint(x: 0.3, y: 0.35), isAuto: true),
            ZoomRegion(startTime: span * 1.5, endTime: span * 2.6, zoomLevel: 2.4,
                       focalPoint: CGPoint(x: 0.7, y: 0.6), isAuto: true),
            ZoomRegion(startTime: span * 2.9, endTime: span * 3.7, zoomLevel: 1.6,
                       focalPoint: CGPoint(x: 0.5, y: 0.5), isAuto: true),
        ]
        }

        // Two passes: CFR measures raw render/encode throughput; fast mode
        // shows the static-span collapse (the fixture is a still movie, so
        // fast mode is its best case — real recordings land in between).
        for (label, collapse) in [("cfr", false), ("fast", true)] {
            project.settings.exportSettings.collapseStaticSpans = collapse
            let outputURL = dir.appendingPathComponent("bench-output-\(label).mp4")
            let exporter = VideoExporter()
            let start = CMClockGetTime(CMClockGetHostTimeClock())
            do {
                try await exporter.export(project: project, to: outputURL, skipEntitlementCheck: true)
            } catch {
                print("EXPORT-BENCH FAILED: export (\(label)) — \(error.localizedDescription)")
                return 1
            }
            let wall = CMTimeGetSeconds(CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), start))

            let asset = AVURLAsset(url: outputURL)
            let exportedSeconds = (try? await asset.load(.duration).seconds) ?? seconds
            let fps = project.settings.exportSettings.fps
            let frames = exportedSeconds * Double(fps)
            print(String(
                format: "EXPORT-BENCH mode=%@ source=%.0fs@%dx%d out-res=%@ output=%.1fs wall=%.2fs encoded-fps=%.1f realtime=%.2fx",
                label, seconds, Int(frameSize.width), Int(frameSize.height),
                project.settings.exportSettings.resolution.rawValue,
                exportedSeconds, wall, frames / max(wall, 0.001), exportedSeconds / max(wall, 0.001)
            ))
            // Duration must survive the collapse — a fast export that comes
            // back short means the trailing span was dropped, not collapsed.
            if abs(exportedSeconds - seconds) > 0.5 {
                print("EXPORT-BENCH FAILED: \(label) duration \(exportedSeconds)s != \(seconds)s")
                return 1
            }
        }
        print("EXPORT-BENCH OK")
        return 0
    }
}
