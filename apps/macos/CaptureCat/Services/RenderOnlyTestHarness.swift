import AVFoundation
import AppKit
import ImageIO

/// Render-only gate: `CaptureCat --render-only-test [<project.json>]`.
///
/// The agent's `render_frames` no longer exports the whole project to show a
/// few frames: `VideoExporter.renderOnlyOutputTimes` walks the timeline as a
/// full export does but composites and encodes only the requested frames.
/// This gate proves those frames are EXACTLY a full export's: the same
/// project is exported in full with the lossless frame tap on the same
/// frames, and every render-only frame must be byte-identical to its tap.
/// Default fixture: a moving synthetic recording with spring zooms (sampled
/// mid-transition), a blur region, a speed-up and a trim — the per-frame
/// state that would drift if skipping frames changed anything. With a
/// project.json it measures a real project too (read-only; never saved).
@MainActor
enum RenderOnlyTestHarness {
    private static var failures = 0

    static func run() -> Never {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            await execute()
            exit(failures == 0 ? 0 : 1)
        }
        app.run()
        exit(0)
    }

    private static func check(_ name: String, _ pass: Bool, _ detail: String = "") {
        if !pass { failures += 1 }
        print("\(pass ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    }

    private static func execute() async {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("capturecat-render-only-\(getpid())", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-only-test"), i + 1 < args.count, !args[i + 1].hasPrefix("-"),
           let data = try? Data(contentsOf: URL(fileURLWithPath: args[i + 1])),
           let project = try? JSONDecoder().decode(Project.self, from: data) {
            let duration = project.exportedOutputDuration(timeMap: SpeedTimeMap(trimmedOutputOf: project))
            let times = (0..<12).map { duration * Double($0) / 11 }
            await compare(project: project, times: times, label: project.name, root: root)
        } else {
            guard let project = await fixture(in: root) else {
                check("fixture", false, "could not build the synthetic recording"); return
            }
            // Mid zoom-in, settled, mid zoom-out, inside the speed-up, the very
            // first and last frames, and a duplicate time.
            let times = [0, 0.45, 0.9, 1.6, 2.35, 2.9, 3.3, 3.3, 4.1, 4.9, 5.6,
                         project.exportedOutputDuration(timeMap: SpeedTimeMap(trimmedOutputOf: project))]
            await compare(project: project, times: times, label: "fixture", root: root)
        }
        print("RENDER-ONLY \(failures == 0 ? "PASS" : "FAIL")")
    }

    private static func fixture(in root: URL) async -> Project? {
        let video = root.appendingPathComponent("source.mp4")
        do {
            try await SyntheticMovie.write(to: video, size: CGSize(width: 1920, height: 1080),
                                           duration: 8, fps: 30, style: .screen)
        } catch { return nil }
        let project = PreviewParityHarness.makeFixtureProject(duration: 8)
        project.videoURL = video
        project.trimStart = 0.4
        project.trimEnd = 7.6
        project.settings.exportSettings.resolution = .hd720
        project.settings.exportSettings.fps = 30
        project.settings.muteRecordedAudio = true
        project.zoomRegions = [
            ZoomRegion(startTime: 0.6, endTime: 2.6, zoomLevel: 1.8, focalPoint: CGPoint(x: 0.3, y: 0.35), isAuto: false),
            ZoomRegion(startTime: 3.2, endTime: 5.4, zoomLevel: 1.5, focalPoint: CGPoint(x: 0.7, y: 0.6), isAuto: false),
        ]
        var blur = BlurRegion(startTime: 0.4, endTime: 7.6)
        blur.rect = CGRect(x: 0, y: 0, width: 1, height: 0.08)
        project.blurRegions = [blur]
        project.speedRegions = [VideoSpeedRegion(startTime: 3.6, endTime: 4.8, speed: 2.0)]
        return project
    }

    private static func compare(project: Project, times: [Double], label: String, root: URL) async {
        let fm = FileManager.default
        // Full export, CFR (collapse off: then the k-th appended frame is
        // frame k, which is what the tap names), tapping the frames shown at
        // `times`.
        let fullTap = root.appendingPathComponent("\(label)-full-tap", isDirectory: true)
        try? fm.removeItem(at: fullTap)
        let collapse = project.settings.exportSettings.collapseStaticSpans
        project.settings.exportSettings.collapseStaticSpans = false
        defer { project.settings.exportSettings.collapseStaticSpans = collapse }

        // Render-only first: its report names the frame index of every time.
        let only = root.appendingPathComponent("\(label)-render-only", isDirectory: true)
        try? fm.removeItem(at: only)
        let renderOnly = VideoExporter()
        renderOnly.renderOnlyOutputTimes = times
        renderOnly.renderOnlyDirectory = only
        let t0 = CACurrentMediaTime()
        do {
            try await renderOnly.export(project: project, to: root.appendingPathComponent("\(label)-only.mp4"))
        } catch {
            check("\(label): render-only export", false, "\(error)"); return
        }
        let onlySeconds = CACurrentMediaTime() - t0
        let frames = renderOnly.renderedFrames
        check("\(label): render-only reports every requested time", frames.count == times.count,
              "\(frames.count)/\(times.count)")

        setenv("CAPTURECAT_EXPORT_FRAME_TAP", fullTap.path, 1)
        setenv("CAPTURECAT_EXPORT_FRAME_TAP_INDICES", Set(frames.map(\.frameIndex)).map(String.init).joined(separator: ","), 1)
        defer {
            unsetenv("CAPTURECAT_EXPORT_FRAME_TAP")
            unsetenv("CAPTURECAT_EXPORT_FRAME_TAP_INDICES")
        }
        let t1 = CACurrentMediaTime()
        do {
            try await VideoExporter().export(project: project, to: root.appendingPathComponent("\(label)-full.mp4"))
        } catch {
            check("\(label): full export", false, "\(error)"); return
        }
        let fullSeconds = CACurrentMediaTime() - t1

        var identical = 0
        for frame in frames {
            let tap = fullTap.appendingPathComponent(String(format: "%04d.png", frame.frameIndex))
            guard let a = rgba(frame.url), let b = rgba(tap) else {
                check("\(label): frame \(frame.frameIndex) at \(frame.requestedTime)s", false, "missing image")
                continue
            }
            if a == b {
                identical += 1
            } else {
                check("\(label): frame \(frame.frameIndex) at \(String(format: "%.3f", frame.requestedTime))s", false,
                      "differs from the full export's frame")
            }
        }
        check("\(label): every render-only frame is byte-identical to the full export's",
              identical == frames.count, "\(identical)/\(frames.count)")
        print(String(format: "RENDER-ONLY %@ timing: full export %.1fs, render-only %.1fs (%.1f× faster) for %d frames",
                     label, fullSeconds, onlySeconds, fullSeconds / max(0.001, onlySeconds), frames.count))
    }

    private static func rgba(_ url: URL) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? bytes : nil
    }
}
