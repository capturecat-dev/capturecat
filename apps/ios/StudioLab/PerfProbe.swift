import AVFoundation
import QuartzCore
import UIKit

/// `--perf-probe <outDir> [--seconds N] [--skip-export]` — what the editor
/// FEELS like on a device, measured, not eyeballed. A synthetic 1080p30
/// project (a zoom across most of it) opens in the shipping
/// `EditorViewController`, in this real window, and the probe times:
///
///   open      folder open → editor presented → first video frame on stage
///   play      5 s of playback: display-link frame pacing (hitches = a frame
///             interval > 1.5 × the display's), video frames delivered vs
///             the source's 30 fps, the compositor's render time per frame
///   scrub     20 paused seeks: request → the new video frame on stage
///   step      20 single-frame steps, same measure
///   export    the movie through `VideoExporter` at 1080p30 (fps)
///
/// Every line also goes to `<out>/result.txt` (`PERF …`). It measures; it
/// doesn't gate — targets live in docs/ios-studio-plan.md (perf rows).
@available(iOS 26, *)
@MainActor
enum PerfProbe {
    static var resultFile: URL?
    static func log(_ line: String) {
        Swift.print(line)
        guard let url = resultFile, let data = (line + "\n").data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() }
        else { try? data.write(to: url) }
    }

    static func start(_ arguments: [String], lab: LabViewController) -> Bool {
        guard let i = arguments.firstIndex(of: "--perf-probe"), arguments.indices.contains(i + 1) else { return false }
        let out = LabPath.url(arguments[i + 1])
        let seconds = arguments.firstIndex(of: "--seconds").flatMap { arguments.indices.contains($0 + 1) ? Double(arguments[$0 + 1]) : nil } ?? 60
        let skipExport = arguments.contains("--skip-export")
        lab.stage.isHidden = true
        UIApplication.shared.isIdleTimerDisabled = true
        Task { @MainActor in
            await run(lab: lab, out: out, seconds: seconds, skipExport: skipExport)
            log("PERF-PROBE DONE")
            exit(0)
        }
        return true
    }

    /// Frame pacing from a display link while something runs.
    final class Pacer: NSObject {
        private var link: CADisplayLink?
        private(set) var intervals: [CFTimeInterval] = []
        private(set) var expected: CFTimeInterval = 1.0 / 60
        private var last: CFTimeInterval = 0
        func start() {
            intervals = []; last = 0
            let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
            l.add(to: .main, forMode: .common)
            link = l
        }
        @objc private func tick(_ l: CADisplayLink) {
            expected = l.targetTimestamp - l.timestamp
            if last > 0 { intervals.append(l.timestamp - last) }
            last = l.timestamp
        }
        func stop() { link?.invalidate(); link = nil }
        var hitches: Int { intervals.filter { $0 > expected * 1.5 }.count }
        var worst: CFTimeInterval { intervals.max() ?? 0 }
    }

    static func ms(_ t: CFTimeInterval) -> String { String(format: "%.1f ms", t * 1000) }

    static func percentile(_ xs: [Double], _ p: Double) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
    }

    static func run(lab: LabViewController, out: URL, seconds: Double, skipExport: Bool) async {
        let fm = FileManager.default
        try? fm.removeItem(at: out)
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        resultFile = out.appendingPathComponent("result.txt")
        let screen = lab.view.window?.windowScene?.screen
        log("PERF device \(UIDevice.current.model) iOS \(UIDevice.current.systemVersion) screen max \(screen?.maximumFramesPerSecond ?? 0) Hz")

        // Fixture.
        let dir = out.appendingPathComponent("project", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let movie = dir.appendingPathComponent("video.mov")
        let total = Int(seconds * 30)
        do { try await BackgroundExportProbe.writeMovie(to: movie, frames: total) } catch {
            log("PERF FAIL fixture: \(error)"); return
        }
        let project = Project(id: UUID(), name: "Perf Probe", duration: seconds, recordingSourceKind: .display)
        project.adoptNewProjectReferenceCanvas()
        project.videoURL = movie
        var zoom = ZoomRegion(startTime: 2, endTime: max(3, seconds - 2))
        zoom.zoomLevel = 1.6
        project.zoomRegions = [zoom]
        do { try JSONEncoder().encode(project).write(to: dir.appendingPathComponent(StudioProjectFolder.documentName)) } catch {
            log("PERF FAIL fixture json: \(error)"); return
        }

        // ── open ──
        let t0 = CACurrentMediaTime()
        let folder: StudioProjectFolder
        do { folder = try StudioProjectFolder.open(dir) } catch { log("PERF FAIL open: \(error)"); return }
        let tOpened = CACurrentMediaTime()
        let editor = EditorViewController(folder: folder)
        editor.onClose = {}
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lab.present(editor, animated: true) { c.resume() }
        }
        let tPresented = CACurrentMediaTime()
        var deadline = Date().addingTimeInterval(20)
        while Date() < deadline, !(editor.playback.isReady && editor.stage.core.displayedVideoFrame != nil) {
            try? await Task.sleep(for: .milliseconds(2))
        }
        let tFirstFrame = CACurrentMediaTime()
        log("PERF open folder \(ms(tOpened - t0)) · presented \(ms(tPresented - t0)) · first video frame \(ms(tFirstFrame - t0))")
        try? await Task.sleep(for: .seconds(1.5))   // settle (entrance animations)

        // ── play ──
        func renderStats() -> (count: Int, total: CFTimeInterval, max: CFTimeInterval) {
            (PreviewCompositorCore.renderCount, PreviewCompositorCore.renderTotal, PreviewCompositorCore.renderMax)
        }
        func reset() {
            PreviewCompositorCore.renderCount = 0
            PreviewCompositorCore.renderTotal = 0
            PreviewCompositorCore.renderMax = 0
        }
        editor.playback.scrub(to: 1, for: editor.project, exact: true)
        try? await Task.sleep(for: .seconds(0.5))
        reset()
        let pacer = Pacer()
        var tokens = Set<Int>()
        pacer.start()
        editor.playback.setPlaying(true, for: editor.project)
        let playStart = CACurrentMediaTime()
        var firstAdvance: CFTimeInterval?
        let startTime = editor.playback.currentTime
        while CACurrentMediaTime() - playStart < 5 {
            tokens.insert(editor.stage.core.debugVideoFrameToken)
            if firstAdvance == nil, editor.playback.currentTime > startTime + 0.001 { firstAdvance = CACurrentMediaTime() - playStart }
            try? await Task.sleep(for: .milliseconds(4))
        }
        editor.playback.setPlaying(false, for: editor.project)
        pacer.stop()
        let played = editor.playback.currentTime - startTime
        let r = renderStats()
        let intervals = pacer.intervals
        log(String(format: "PERF play %.2f s of video in 5 s · start latency %@ · display %.0f Hz · %d frames, %d hitches (worst %@, p99 %@) · video frames %d (source 30 fps → %.0f expected) · compositor %d renders, mean %@, max %@",
                   played, ms(firstAdvance ?? -1), 1 / pacer.expected, intervals.count, pacer.hitches, ms(pacer.worst),
                   ms(percentile(intervals, 0.99)), tokens.count, played * 30, r.count,
                   ms(r.count > 0 ? r.total / Double(r.count) : 0), ms(r.max)))

        // ── scrub / step ──
        func waitNewFrame(from token: Int, timeout: Double = 3) async -> CFTimeInterval? {
            let s = CACurrentMediaTime()
            while CACurrentMediaTime() - s < timeout {
                if editor.stage.core.debugVideoFrameToken != token { return CACurrentMediaTime() - s }
                try? await Task.sleep(for: .milliseconds(1))
            }
            return nil
        }
        var scrubs: [Double] = [], missed = 0
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<20 {
            let target = Double.random(in: 1...(seconds - 1), using: &rng)
            let token = editor.stage.core.debugVideoFrameToken
            editor.playback.scrub(to: target, for: editor.project, exact: true)
            if let t = await waitNewFrame(from: token) { scrubs.append(t) } else { missed += 1 }
            try? await Task.sleep(for: .milliseconds(120))
        }
        log("PERF scrub 20 seeks · median \(ms(percentile(scrubs, 0.5))) · p90 \(ms(percentile(scrubs, 0.9))) · worst \(ms(scrubs.max() ?? 0)) · no new frame \(missed)")
        var steps: [Double] = []; missed = 0
        for _ in 0..<20 {
            let token = editor.stage.core.debugVideoFrameToken
            editor.playback.step(frames: 1, for: editor.project)
            if let t = await waitNewFrame(from: token) { steps.append(t) } else { missed += 1 }
            try? await Task.sleep(for: .milliseconds(60))
        }
        log("PERF step 20 frames · median \(ms(percentile(steps, 0.5))) · p90 \(ms(percentile(steps, 0.9))) · worst \(ms(steps.max() ?? 0)) · no new frame \(missed)")

        // ── close ──
        let tc = CACurrentMediaTime()
        editor.playback.teardown()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            editor.dismiss(animated: true) { c.resume() }
        }
        log("PERF close \(ms(CACurrentMediaTime() - tc))")

        // ── export ──
        guard !skipExport else { return }
        var settings = project.settings.exportSettings
        settings.format = .mp4; settings.resolution = .hd1080; settings.fps = 30
        project.settings.exportSettings = settings
        let dest = out.appendingPathComponent("export.mp4")
        let te = CACurrentMediaTime()
        do {
            try await VideoExporter().export(project: project, to: dest)
            let el = CACurrentMediaTime() - te
            log(String(format: "PERF export 1080p30 %.0f s video in %.1f s · %.0f fps · %.1f× realtime", seconds, el, Double(total) / el, seconds / el))
        } catch {
            log("PERF FAIL export: \(error)")
        }
    }
}
