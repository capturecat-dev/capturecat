import AVFoundation
import AppKit
import CoreMedia

/// Acceptance test for the AppKit-P6 playback extraction.
///
///     CaptureCat --playback-observer-test
///
/// Builds a synthetic project on disk (3 s screen video + 2 s camera video +
/// cursor clicks + keystrokes + a speed region), drives a real
/// `EditorPlaybackController` through play → trim-end stop, and asserts that
/// EVERY consumer the periodic time observer used to drive still fires:
///
///   1. currentTime publishes   → preview / timeline / inspector
///   2. click sounds            → ClickSoundPlayer
///   3. keyboard sounds         → KeySoundPlayer
///   4. live speed ramps        → player.rate follows the speed region
///   5. trim-end stop           → pause + rewind
///   6. camera sync             → syncCameraPlayer via the currentTime hook
///   7. rewind to trim start    → timeline/player reset
///   8. play-start anchoring    → stale decoder time cannot skip head effects
///   9. live scrub chase        → latest drag target publishes immediately
///
/// All sound volumes are pinned to 0 so a run is inaudible.
/// DEBUG tooling — never reached in a normal launch.
@MainActor
enum PlaybackObserverHarness {

    static func run() -> Never {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        Task { @MainActor in
            let ok = await execute()
            exit(ok ? 0 : 1)
        }
        app.run()
        exit(1)
    }

    private static func execute() async -> Bool {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("capturecat-playback-observer-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let screenURL = dir.appendingPathComponent("screen.mov")
        let cameraURL = dir.appendingPathComponent("camera.mov")
        guard await writeVideo(to: screenURL, seconds: 3.0, size: CGSize(width: 320, height: 240), tint: 0.25),
              await writeVideo(to: cameraURL, seconds: 2.0, size: CGSize(width: 160, height: 120), tint: 0.75) else {
            print("OBSERVER FAIL could not synthesize fixture video")
            return false
        }

        // Cursor: three discrete clicks (short stationary runs) at t = 0.5 /
        // 1.2 / 1.9, sampled at 60 Hz like the real tracker.
        var cursorEvents: [CursorEvent] = []
        let clickTimes: [TimeInterval] = [0.5, 1.2, 1.9]
        var t: TimeInterval = 0
        while t < 3.0 {
            let isClick = clickTimes.contains { t >= $0 && t < $0 + 0.05 }
            cursorEvents.append(CursorEvent(timestamp: t, x: 640, y: 400, isClick: isClick))
            t += 1.0 / 60.0
        }
        let cursorURL = dir.appendingPathComponent("cursor.json")
        let recording = CursorRecording(
            version: 2,
            coordinateWidth: 1440,
            coordinateHeight: 900,
            events: cursorEvents
        )
        guard let cursorData = try? JSONEncoder().encode(recording),
              (try? cursorData.write(to: cursorURL)) != nil else {
            print("OBSERVER FAIL could not write cursor fixture")
            return false
        }

        let keysURL = dir.appendingPathComponent("keys.json")
        let keyRecording = KeystrokeRecording(version: 1, events: [
            KeystrokeEvent(timestamp: 0.7, category: .key),
            KeystrokeEvent(timestamp: 0.9, category: .space),
            KeystrokeEvent(timestamp: 1.4, category: .key),
            KeystrokeEvent(timestamp: 2.1, category: .return),
        ])
        guard let keyData = try? JSONEncoder().encode(keyRecording),
              (try? keyData.write(to: keysURL)) != nil else {
            print("OBSERVER FAIL could not write keystroke fixture")
            return false
        }

        let project = Project(
            name: "observer-probe",
            videoURL: screenURL,
            cursorDataURL: cursorURL,
            cameraVideoURL: cameraURL,
            duration: 3.0
        )
        project.keystrokeDataURL = keysURL
        project.trimStart = 0.05
        project.trimEnd = 2.6
        project.settings.showCamera = true
        project.settings.muteRecordedAudio = true
        project.settings.clickSoundEnabled = true
        project.settings.clickSoundVolume = 0
        project.settings.keySoundEnabled = true
        project.settings.keySoundVolume = 0
        // Forces the observer's live-rate branch (rate 1.0 → 2.0 → 1.0).
        project.speedRegions = [VideoSpeedRegion(startTime: 1.0, endTime: 1.8, speed: 2.0)]

        let controller = EditorPlaybackController(appState: nil)
        await controller.setupPlayer(for: project)

        guard controller.player != nil else {
            print("OBSERVER FAIL player was not created")
            return false
        }

        // Two rapid drag targets followed by an exact mouse-up target. The
        // observable playhead must always publish the newest request even
        // while AVPlayer is still decoding an older seek.
        controller.scrub(to: 0.7, for: project, exact: false)
        controller.scrub(to: 1.35, for: project, exact: false)
        let liveScrubPublished = controller.isScrubbing
            && abs(controller.currentTime - 1.35) < 0.001
        controller.scrub(to: 0.82, for: project, exact: true)
        try? await Task.sleep(for: .milliseconds(250))
        let scrubSettledExactly = !controller.isScrubbing
            && abs(controller.currentTime - 0.82) < 0.001

        // Reproduce the editor race: the visible playhead is at trim start,
        // but an older asynchronous seek left AVPlayer at 1.4s. Play must seek
        // back to the visible head before rate becomes non-zero, otherwise a
        // tilt/effect beginning at 0:00 is skipped on the first frame.
        if let player = controller.player {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                player.seek(
                    to: CMTime(seconds: 1.4, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                ) { _ in continuation.resume() }
            }
            controller.currentTime = project.effectiveTrimStart
        }

        // Shell wiring: exactly the two onChange hooks EditorView installs.
        var lastTime = controller.currentTime
        let cameraHook = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard controller.currentTime != lastTime else { return }
                lastTime = controller.currentTime
                controller.syncCameraPlaybackIfNeeded(for: project)
            }
        }

        controller.isPlaying = true
        controller.updatePlaybackState(for: project, playing: true)

        var sawRate2x = false
        var maxTime = controller.currentTime
        let ticksBeforePlay = controller.observerCounters.ticks
        var firstPublishedPlayingTime: TimeInterval?
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(40))
            if firstPublishedPlayingTime == nil,
               controller.observerCounters.ticks > ticksBeforePlay {
                firstPublishedPlayingTime = controller.currentTime
            }
            maxTime = max(maxTime, controller.currentTime)
            if let rate = controller.player?.rate, rate > 1.5 { sawRate2x = true }
            if controller.observerCounters.trimEndStops > 0 { break }
        }
        cameraHook.invalidate()

        let c = controller.observerCounters
        print("OBSERVER counters ticks=\(c.ticks) publishes=\(c.currentTimePublishes) clicks=\(c.clickSounds) keys=\(c.keySounds) rateChanges=\(c.rateChanges) trimEndStops=\(c.trimEndStops) cameraSyncs=\(c.cameraSyncs) endOfItem=\(c.endOfItem)")
        print("OBSERVER maxTime=\(String(format: "%.3f", maxTime)) trimEnd=\(project.effectiveTrimEnd) sawRate2x=\(sawRate2x) isPlaying=\(controller.isPlaying) currentTime=\(String(format: "%.3f", controller.currentTime))")

        var failures: [String] = []
        func check(_ name: String, _ pass: Bool, _ detail: String) {
            print("OBSERVER \(pass ? "PASS" : "FAIL") \(name) — \(detail)")
            if !pass { failures.append(name) }
        }

        check("1.currentTime", c.currentTimePublishes > 30, "\(c.currentTimePublishes) publishes")
        check("2.clickSounds", c.clickSounds >= 2, "\(c.clickSounds) of 3 seeded clicks (trim window 0.05…2.6)")
        check("3.keySounds", c.keySounds >= 3, "\(c.keySounds) of 4 seeded keystrokes")
        check("4.speedRamp", c.rateChanges >= 2 && sawRate2x, "\(c.rateChanges) rate changes, saw 2× = \(sawRate2x)")
        check("5.trimEndStop", c.trimEndStops >= 1 && !controller.isPlaying, "stops=\(c.trimEndStops) isPlaying=\(controller.isPlaying)")
        check("6.cameraSync", c.cameraSyncs >= 1 && controller.cameraPlayer != nil, "\(c.cameraSyncs) syncs, cameraPlayer=\(controller.cameraPlayer != nil)")
        check(
            "7.rewindToTrimStart",
            abs(controller.currentTime - project.effectiveTrimStart) < 0.05,
            "currentTime=\(String(format: "%.3f", controller.currentTime)) trimStart=\(project.effectiveTrimStart)"
        )
        check(
            "8.playStartAnchor",
            (firstPublishedPlayingTime ?? .infinity) < 0.25,
            "stale decoder was 1.400s; first published play time=\(firstPublishedPlayingTime.map { String(format: "%.3f", $0) } ?? "none")"
        )
        check(
            "9.liveScrub",
            liveScrubPublished && scrubSettledExactly,
            "latest target published=\(liveScrubPublished), exact mouse-up settled=\(scrubSettledExactly)"
        )

        controller.teardown(saving: nil)
        try? FileManager.default.removeItem(at: dir)

        if failures.isEmpty {
            print("OBSERVER RESULT PASS — all playback consumers and play-start anchoring pass")
            return true
        }
        print("OBSERVER RESULT FAIL — \(failures.joined(separator: ", "))")
        return false
    }

    // MARK: - Fixture video

    /// Shared with `EditorShellProbeHarness` — a tiny, decodable fixture clip.
    static func writeVideo(
        to url: URL,
        seconds: Double,
        size: CGSize,
        tint: Double
    ) async -> Bool {
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { print("FIXTURE no writer for \(url.path)"); return false }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
            ]
        )
        guard writer.canAdd(input) else { print("FIXTURE canAdd false"); return false }
        writer.add(input)
        guard writer.startWriting() else { print("FIXTURE startWriting false error=\(String(describing: writer.error))"); return false }
        writer.startSession(atSourceTime: .zero)

        let fps: Int32 = 30
        let frames = Int(seconds * Double(fps))
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ] as CFDictionary, &pool)

        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData {
                try? await Task.sleep(for: .milliseconds(5))
            }
            var buffer: CVPixelBuffer?
            if let pool {
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            }
            guard let pixelBuffer = buffer ?? adaptor.pixelBufferPool.flatMap({ p -> CVPixelBuffer? in
                var b: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, p, &b)
                return b
            }) else { print("FIXTURE no pixel buffer"); return false }

            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
                let height = CVPixelBufferGetHeight(pixelBuffer)
                // Ramp the luminance per frame so successive frames differ (a
                // constant colour compresses to a single sample and breaks the
                // first-frame probes).
                let level = UInt8(min(255, max(0, (tint * 200) + Double(frame % 40) * 1.2)))
                memset(base, Int32(level), bytesPerRow * height)
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

            let time = CMTime(value: CMTimeValue(frame), timescale: fps)
            adaptor.append(pixelBuffer, withPresentationTime: time)
        }

        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            print("FIXTURE writer status=\(writer.status.rawValue) error=\(String(describing: writer.error))")
        }
        return writer.status == .completed
    }
}
