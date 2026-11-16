import UIKit

/// The playback half of `--editor-shell`: a real project played in the real
/// editor, captured as a SEQUENCE (CLAUDE.md §3 — a settled frame proves
/// nothing about motion).
///
/// The project is the Mac fixture with motion blur ON and a zoom block from
/// 4 s, opened at 1.0 s on its own reference canvas (no harness override).
/// While it plays, each capture of the stage (through the render server)
/// must show: the playhead later than the last capture, a NEW delivered
/// video frame, and the movie's lime marker further right — the frames
/// on screen advance. Through the zoom-in, no motion-blur still may be
/// shown while playing (the plan's playback exception) although the core's
/// blur is active there; paused on such a frame, the twin's still must be.
@available(iOS 26, *)
@MainActor
enum EditorPlaybackProbe {
    struct Sample {
        var time: Double
        var token: Int
        var playing: Bool
        var still: Bool
        var blurActive: Bool
        var markerX: CGFloat?
    }

    static func run(fixtureProject: Data, media: EditorLabMedia, out: URL, host: UIViewController) async -> [String] {
        var failures: [String] = []
        let fm = FileManager.default
        let dir = out.appendingPathComponent("projects/playback", isDirectory: true)
        let shots = out.appendingPathComponent("playback", isDirectory: true)
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: shots, withIntermediateDirectories: true)
        try? fm.copyItem(at: media.video, to: dir.appendingPathComponent("video.mov"))
        guard let project = try? JSONDecoder().decode(Project.self, from: fixtureProject) else {
            return ["playback: fixture project unreadable"]
        }
        project.videoURL = URL(fileURLWithPath: "/Users/mac-user/Movies/CaptureCat/\(project.id.uuidString)/video.mov")
        project.settings.motionBlur = true
        project.zoomRegions = [ZoomRegion(startTime: 4.0, endTime: 9, zoomLevel: 2.0,
                                          focalPoint: CGPoint(x: 0.5, y: 0.5))]
        let editor: EditorViewController
        do {
            try JSONEncoder().encode(project).write(to: dir.appendingPathComponent(StudioProjectFolder.documentName))
            editor = EditorViewController(folder: try StudioProjectFolder.open(dir), initialTime: 1.0)
        } catch {
            return ["playback: open failed: \(error)"]
        }
        editor.onClose = {}
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            host.present(editor, animated: false) { c.resume() }
        }
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, !(editor.playback.isReady && editor.stage.core.displayedVideoFrame != nil) {
            await LabTime.settle(0.05)
        }
        await LabTime.settle(0.3)
        let expectedCanvas = PreviewStageView.virtualCanvas(for: editor.project, sourceSize: editor.playback.videoSize)
        print("PLAYBACK canvas=\(editor.stage.virtualCanvasSize) (project's reference canvas \(expectedCanvas)) "
              + "magnification=\(String(format: "%.4f", editor.stage.magnification))")
        if editor.stage.virtualCanvasSize != expectedCanvas { failures.append("playback: canvas is not the project's") }

        func sample(_ index: Int, save: Bool) -> Sample {
            editor.renderStage()
            let image = LabCapture.view(editor.stage)
            if save, let image {
                try? LabCapture.png(image).write(to: shots.appendingPathComponent(String(format: "frame-%02d.png", index)))
            }
            return Sample(time: editor.playback.currentTime,
                          token: editor.stage.core.displayedVideoFrame?.token ?? -1,
                          playing: editor.playback.isPlaying,
                          still: editor.stage.core.hostZoomGroupStill != nil,
                          blurActive: editor.stage.core.appliedMotionBlur.active,
                          markerX: image.flatMap(markerCentroidX))
        }
        func line(_ s: Sample, _ i: Int) -> String {
            String(format: "   %02d t=%.3f token=%d playing=%@ still=%@ blur=%@ marker=%@", i, s.time, s.token,
                   "\(s.playing)", "\(s.still)", "\(s.blurActive)", s.markerX.map { String(format: "%.1f", $0) } ?? "-")
        }

        // Paused at 1.0 s.
        let paused = sample(0, save: true)
        print(line(paused, 0))
        if paused.markerX == nil { failures.append("playback: the marker is not on screen at 1.0 s (paused)") }

        // Idle while paused: no observation feedback loop may keep the stage
        // rendering (a render that wrote an observed value would loop).
        var idleRenders = 0
        let renderHook = editor.stage.onRender
        editor.stage.onRender = { frame in idleRenders += 1; renderHook?(frame) }
        await LabTime.settle(1.0)
        editor.stage.onRender = renderHook
        print("   idle (paused) renders in 1 s: \(idleRenders)")
        if idleRenders > 3 { failures.append("playback: the paused stage kept rendering (\(idleRenders) renders in 1 s)") }

        // Playing, before the zoom: frames must advance.
        editor.playback.setPlaying(true, for: editor.project)
        var run: [Sample] = []
        var i = 1
        while i < 40 {
            await LabTime.settle(0.1)
            let s = sample(i, save: true)
            print(line(s, i))
            if s.time >= 3.85 || !s.playing { break }
            run.append(s)
            i += 1
        }
        if run.count < 8 { failures.append("playback: only \(run.count) playing captures before the zoom (want ≥ 8)") }
        for (a, b) in zip(run, run.dropFirst()) {
            if !(b.time > a.time) { failures.append(String(format: "playback: playhead did not advance (%.3f → %.3f)", a.time, b.time)) }
            if !(b.token > a.token) { failures.append("playback: no new video frame between captures (token \(a.token) → \(b.token))") }
            if let ax = a.markerX, let bx = b.markerX {
                if !(bx > ax) { failures.append(String(format: "playback: the frame on screen did not advance (marker %.1f → %.1f)", ax, bx)) }
            } else {
                failures.append("playback: the marker left the screen while playing")
            }
        }
        if !run.allSatisfy(\.playing) { failures.append("playback: playback stopped early") }

        // Into the zoom-in: blur active in the core, but no still while playing.
        var zoomRun: [Sample] = []
        let zoomDeadline = Date().addingTimeInterval(4)
        while Date() < zoomDeadline, editor.playback.currentTime < 4.35 {
            await LabTime.settle(0.03)
            let s = sample(100 + zoomRun.count, save: false)
            zoomRun.append(s)
        }
        let blurFrames = zoomRun.filter { $0.playing && $0.blurActive }.count
        let stillWhilePlaying = zoomRun.filter { $0.playing && $0.still }.count
        print("   zoom-in while playing: \(zoomRun.count) captures, core blur active in \(blurFrames), still shown in \(stillWhilePlaying)")
        if stillWhilePlaying > 0 { failures.append("playback: a motion-blur still was shown while playing (\(stillWhilePlaying) frames)") }
        if blurFrames == 0 { failures.append("playback: the core's blur never became active in the zoom-in (the exception was not exercised)") }

        // Paused inside the transition: the twin's still (built from the
        // displayed frame) must stand in for the zoom group.
        editor.playback.setPlaying(false, for: editor.project)
        await LabTime.settle(0.2)
        var pausedBlur = sample(200, save: true)
        if !pausedBlur.blurActive {
            // A same-time render has no motion; step one frame inside the move.
            editor.playback.step(frames: 1, for: editor.project)
            await LabTime.settle(0.3)
            pausedBlur = sample(201, save: true)
        }
        print(line(pausedBlur, 200))
        if pausedBlur.blurActive && !pausedBlur.still {
            failures.append("playback: paused with the core's blur active, but no twin still was shown")
        } else if !pausedBlur.blurActive {
            print("   note: paused frame had no active blur — the paused-still path was not exercised here")
        }

        print("PLAYBACK \(failures.isEmpty ? "PASS" : "FAIL") (\(run.count) advancing captures, ticks=\(editor.playback.counters.ticks))")
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            editor.dismiss(animated: false) { c.resume() }
        }
        editor.playback.teardown()
        return failures
    }

    /// Mean x (pixels) of the movie's lime marker in a capture, or nil.
    static func markerCentroidX(_ image: CGImage) -> CGFloat? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var sum = 0.0, count = 0
        for y in 0..<h {
            for x in 0..<w {
                let o = (y * w + x) * 4
                if px[o] < 80, px[o + 1] > 200, px[o + 2] < 80 { sum += Double(x); count += 1 }
            }
        }
        return count > 20 ? CGFloat(sum / Double(count)) : nil
    }
}
