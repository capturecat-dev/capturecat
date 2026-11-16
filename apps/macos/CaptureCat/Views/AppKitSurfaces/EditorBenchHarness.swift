import AVFoundation
import AppKit

/// Editor playback benchmark: `CaptureCat --editor-bench <project.json> [--from s] [--seconds s] [--only a,b]`.
///
/// Plays a project in the REAL editor shell (the probe window topology the
/// shell gates use) and reports, per effect variant, how many video frames
/// the preview actually delivered per second, the main-thread cost of the
/// compositor's render, and how late a 60 Hz main-run-loop timer fired (the
/// stutter a user feels). Variants strip one feature each — blur regions,
/// the background look, zooms, speed regions — so the expensive one shows.
///
/// Works on an in-memory copy with a FRESH project id (never the original's
/// folder), reads the media read-only, and never saves. Off-screen probe
/// windows only. DEBUG tooling; never reached in a normal launch.
@MainActor
enum EditorBenchHarness {
    static func run() -> Never {
        setbuf(stdout, nil)
        MainActor.assumeIsolated { CCTheme.setMode(.dark, persist: false) }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            await execute()
            exit(0)
        }
        app.run()
        exit(0)
    }

    private struct Variant {
        let name: String
        let mutate: (Project) -> Void
    }

    private static let variants: [Variant] = [
        Variant(name: "as-is") { _ in },
        Variant(name: "no-blur-regions") { $0.blurRegions = [] },
        Variant(name: "no-background-look") { p in
            p.settings.backgroundBlur = 0
            p.settings.backgroundPixelate = 0
            p.settings.backgroundHalftone = 0
            p.settings.backgroundNoise = 0
        },
        Variant(name: "no-zooms") { $0.zoomRegions = [] },
        Variant(name: "no-speed-regions") { $0.speedRegions = [] },
        Variant(name: "bare") { p in
            p.blurRegions = []
            p.zoomRegions = []
            p.speedRegions = []
            p.settings.backgroundBlur = 0
        },
    ]

    private static func argument(_ flag: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private static func execute() async {
        guard let path = argument("--editor-bench"),
              var json = (try? Data(contentsOf: URL(fileURLWithPath: path)))
                .flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) else {
            print("EDITOR-BENCH FAIL usage: --editor-bench <project.json>")
            return
        }
        // A fresh id: anything that might persist goes to a new folder, never
        // the original project's.
        json["id"] = UUID().uuidString
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        let from = argument("--from").flatMap(Double.init) ?? 20
        let seconds = argument("--seconds").flatMap(Double.init) ?? 6
        let only = argument("--only").map { Set($0.split(separator: ",").map(String.init)) }

        for variant in variants where only?.contains(variant.name) ?? true {
            guard let project = try? JSONDecoder().decode(Project.self, from: data) else {
                print("EDITOR-BENCH FAIL project.json did not decode"); return
            }
            variant.mutate(project)
            await measure(project: project, name: variant.name, from: from, seconds: seconds)
        }
        print("EDITOR-BENCH done")
    }

    private static func measure(project: Project, name: String, from: Double, seconds: Double) async {
        let shell = EditorShellViewController(appState: nil, project: project)
        let container = EditorShellProbeHarness.ProbeContentViewController(shell: shell)
        let window = EditorShellProbeHarness.makeWindow(content: container, title: "bench \(name)", x: 40)
        defer {
            shell.playback.isPlaying = false
            shell.playback.updatePlaybackState(for: project, playing: false)
            window.orderOut(nil)
            window.close()
        }
        await settle(3.0)
        guard let compositor = findView(ofType: PreviewCompositorView.self, in: window.contentView!) else {
            print("BENCH \(name) FAIL no compositor"); return
        }
        shell.playback.scrub(to: from, for: project, exact: true)
        await settle(1.5)

        // A 60 Hz probe on the main run loop: its lateness is the main thread
        // being busy — what the user sees as stutter.
        var lateness: [Double] = []
        var last = CACurrentMediaTime()
        let probe = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
            let now = CACurrentMediaTime()
            lateness.append(max(0, (now - last) - 1.0 / 60.0) * 1000)
            last = now
        }
        RunLoop.main.add(probe, forMode: .common)

        PreviewCompositorCore.renderCount = 0
        PreviewCompositorCore.renderTotal = 0
        PreviewCompositorCore.renderMax = 0
        let token0 = compositor.debugVideoFrameToken
        let t0 = CACurrentMediaTime()
        shell.playback.isPlaying = true
        shell.playback.updatePlaybackState(for: project, playing: true)
        await settle(seconds)
        let elapsed = CACurrentMediaTime() - t0
        let frames = compositor.debugVideoFrameToken - token0
        probe.invalidate()
        let advanced = shell.playback.currentTime - from

        let renders = PreviewCompositorCore.renderCount
        let avg = renders > 0 ? PreviewCompositorCore.renderTotal / Double(renders) * 1000 : 0
        let sorted = lateness.sorted()
        let p95 = sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * 0.95)]
        print(String(format: "BENCH %-20@ fps %5.1f  renders/s %5.1f  render avg %6.2f ms  max %6.1f ms  main-thread lateness p95 %6.1f ms  max %6.1f ms  (played %.2fs of source)",
                     name as NSString, Double(frames) / elapsed, Double(renders) / elapsed, avg,
                     PreviewCompositorCore.renderMax * 1000, p95, sorted.last ?? 0, advanced))
    }

    private static func settle(_ seconds: Double) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            try? await Task.sleep(for: .milliseconds(20))
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
    }

    private static func findView<T: NSView>(ofType type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        for sub in root.subviews {
            if let found = findView(ofType: type, in: sub) { return found }
        }
        return nil
    }
}
