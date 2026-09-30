import AVFoundation
import CoreGraphics

/// `CaptureCat --web-audio-fixtures <dir> [--only name1,name2]` — reference
/// AUDIO for the web exporter (the web twin of `ProjectAudioMix`).
///
/// Writes SYNTHETIC bundles (never user media): a recording.mp4 with a
/// flashing H.264 video track + a STEREO 48 kHz "system" AAC track + a MONO
/// 44.1 kHz "microphone" AAC track (distinct tones and burst markers, the
/// video flashes white on exactly the frames the system bursts start), a
/// voice-over m4a, cursor.json with clicks and keys.json with every keystroke
/// category. Each project is exported by the REAL `VideoExporter`; the
/// exporter's audio mix is ALSO read back losslessly (`ProjectAudioMix.prepare`
/// + `AVAssetReaderAudioMixOutput`, float32) into `mix.f32` so the web mix can
/// be compared sample-by-sample before AAC.
///
/// `sounds.json` locks the synthesized click / key sounds
/// (`ClickSoundPlayer.tickSamples`, `KeySoundPlayer.variation`,
/// `KeySoundPlayer.strokeSamples`) as golden vectors.
///
/// The voice-over must live in `project.projectDirectory` for the exporter to
/// use it; the harness creates that (fixture-UUID) folder, copies the file in
/// and removes the folder afterwards. Never reached in a normal launch.
enum WebAudioFixtures {
    static let duration: TimeInterval = 6
    static let videoSize = CGSize(width: 1280, height: 720)
    static let fps: Int32 = 30
    /// System-track burst starts (source seconds); the video flashes on these frames.
    static let systemBursts: [Double] = [0.5, 1.5, 2.5, 3.5, 4.5, 5.5]
    static let micBursts: [Double] = [0.8, 1.8, 2.8, 3.8, 4.8]

    struct Fixture {
        let name: String
        let description: String
        let configure: (Project) -> Void
    }

    static func run() -> Never {
        let args = CommandLine.arguments
        var requested: String?
        if let i = args.firstIndex(of: "--web-audio-fixtures"), args.indices.contains(i + 1),
           !args[i + 1].hasPrefix("--") {
            requested = (args[i + 1] as NSString).expandingTildeInPath
        }
        var only: Set<String>?
        if let i = args.firstIndex(of: "--only"), args.indices.contains(i + 1) {
            only = Set(args[i + 1].split(separator: ",").map { String($0) })
        }
        let dir = WebVectorsHarness.resolveOutputDirectory(requested, prefix: "capturecat-web-audio")
        print("WEB-AUDIO dir=\(dir.path)")
        Task { @MainActor in
            var failures = 0
            var written: [WV] = []
            do {
                try writeSounds(to: dir.appendingPathComponent("sounds.json"))
                let shared = dir.appendingPathComponent("media", isDirectory: true)
                try? FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
                try await writeRecording(to: shared.appendingPathComponent("recording.mp4"))
                try writeVoice(to: shared.appendingPathComponent("voice.m4a"))
                try writeCursor(to: shared.appendingPathComponent("cursor.json"))
                try writeKeys(to: shared.appendingPathComponent("keys.json"))
                for fixture in fixtures where only?.contains(fixture.name) ?? true {
                    do {
                        written.append(try await build(fixture, root: dir, media: shared))
                    } catch {
                        failures += 1
                        print("WEB-AUDIO FAIL \(fixture.name): \(error.localizedDescription)")
                    }
                }
            } catch {
                failures += 1
                print("WEB-AUDIO FAIL media: \(error.localizedDescription)")
            }
            let manifest: WV = [
                "generator": "CaptureCat --web-audio-fixtures",
                "notes": .str("mix.f32 = the exporter's ProjectAudioMix read back as float32 interleaved stereo 48 kHz from output time 0 (fast path: shifted by trimStart exactly like VideoExporter). export.mp4 = the REAL VideoExporter output (AAC 192 kbps)."),
                "systemBursts": systemBursts.wv,
                "micBursts": micBursts.wv,
                "fixtures": .arr(written),
            ]
            try? Data(manifest.serialized().utf8).write(to: dir.appendingPathComponent("manifest.json"))
            print("WEB-AUDIO \(failures == 0 ? "OK" : "FAILED") fixtures=\(written.count) dir=\(dir.path)")
            exit(failures == 0 ? 0 : 1)
        }
        RunLoop.main.run()
        fatalError("unreachable")
    }

    private static func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!
    }

    static let fixtures: [Fixture] = [
        Fixture(name: "a1-composed-mix", description: "Trim, system 0.8 + mic 0.5, Pop clicks 0.9, Typewriter keys 0.7 (composed path).") { p in
            p.trimStart = 0.4
            p.trimEnd = 5.6
            let s = p.settings
            s.systemAudioVolume = 0.8
            s.microphoneVolume = 0.5
            s.clickSoundEnabled = true
            s.clickSoundStyle = .pop
            s.clickSoundVolume = 0.9
            s.keySoundEnabled = true
            s.keySoundStyle = .typewriter
            s.keySoundVolume = 0.7
        },
        Fixture(name: "a2-speed-clips-voice", description: "Trim, 2x + 0.5x speed regions, split clips with a gap, a voice-over clip, Soft Tick clicks, Thock keys.") { p in
            p.trimStart = 0.5
            p.trimEnd = 5.6
            p.speedRegions = [
                VideoSpeedRegion(id: id(2201), startTime: 1.0, endTime: 2.0, speed: 2.0),
                VideoSpeedRegion(id: id(2202), startTime: 3.0, endTime: 3.5, speed: 0.5),
            ]
            p.videoClipSegments = [
                VideoClipSegment(id: id(2203), startTime: 0.5, endTime: 2.6),
                VideoClipSegment(id: id(2204), startTime: 3.1, endTime: 5.2),
            ]
            p.voiceOverClips = [
                VoiceOverClip(id: id(2205), fileName: "voice.m4a", startTime: 1.2, sourceStartTime: 0.3,
                              duration: 1.5, sourceDuration: 3.0, gain: 0.8),
            ]
            let s = p.settings
            s.voiceOverVolume = 1.2
            s.systemAudioVolume = 1.0
            s.microphoneVolume = 0.7
            s.clickSoundEnabled = true
            s.clickSoundStyle = .softTick
            s.clickSoundVolume = 0.7
            s.keySoundEnabled = true
            s.keySoundStyle = .thock
            s.keySoundVolume = 0.6
        },
        Fixture(name: "a3-fast-path", description: "Trim only, system 1.0 + mic 0.3 — the exporter's fast path (source asset read from trimStart).") { p in
            p.trimStart = 0.5
            p.trimEnd = 5.5
            let s = p.settings
            s.systemAudioVolume = 1.0
            s.microphoneVolume = 0.3
            s.clickSoundEnabled = false
            s.keySoundEnabled = false
        },
        Fixture(name: "a4-muted-dense", description: "Muted recording, voice-over only, Clicky clicks 1.0 incl. overlapping ticks, Blue Click keys 1.0 incl. sub-8ms chords.") { p in
            p.trimStart = 0
            p.trimEnd = 6
            p.voiceOverClips = [
                VoiceOverClip(id: id(2401), fileName: "voice.m4a", startTime: 0.2, sourceStartTime: 0,
                              duration: 2.5, sourceDuration: 3.0, gain: 1.0),
            ]
            let s = p.settings
            s.muteRecordedAudio = true
            s.voiceOverVolume = 0.9
            s.clickSoundEnabled = true
            s.clickSoundStyle = .clicky
            s.clickSoundVolume = 1.0
            s.keySoundEnabled = true
            s.keySoundStyle = .blueClick
            s.keySoundVolume = 1.0
        },
    ]

    // MARK: - Build one fixture

    @MainActor
    private static func build(_ f: Fixture, root: URL, media: URL) async throws -> WV {
        let fm = FileManager.default
        let dir = root.appendingPathComponent(f.name, isDirectory: true)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["recording.mp4", "voice.m4a", "cursor.json", "keys.json"] {
            try fm.copyItem(at: media.appendingPathComponent(name), to: dir.appendingPathComponent(name))
        }
        var rng = WVRandom(seed: "audio-fixture-\(f.name)")
        let project = Project(
            id: rng.uuid(), name: f.name, videoURL: dir.appendingPathComponent("recording.mp4"),
            cursorDataURL: dir.appendingPathComponent("cursor.json"), cameraVideoURL: nil,
            duration: duration, recordingSourceKind: .display)
        project.keystrokeDataURL = dir.appendingPathComponent("keys.json")
        project.createdAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let s = project.settings
        s.gradientStartColor = CodableColor(red: 0.42, green: 0.26, blue: 0.93)
        s.gradientEndColor = CodableColor(red: 0.13, green: 0.62, blue: 0.98)
        s.exportSettings.resolution = .custom
        s.exportSettings.customWidth = 640
        s.exportSettings.customHeight = 360
        s.exportSettings.fps = Int(fps)
        s.exportSettings.quality = 1.0
        s.exportSettings.collapseStaticSpans = false
        s.exportSettings.format = .mp4
        s.showCursor = false
        s.showKeystrokes = false
        f.configure(project)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(project).write(to: dir.appendingPathComponent("project.json"))

        // Voice-overs resolve against projectDirectory — stage them there.
        let projectDir = project.projectDirectory
        let stagedProjectDir = !project.voiceOverClips.isEmpty && !fm.fileExists(atPath: projectDir.path)
        if stagedProjectDir {
            try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)
            try fm.copyItem(at: dir.appendingPathComponent("voice.m4a"), to: projectDir.appendingPathComponent("voice.m4a"))
        }
        defer { if stagedProjectDir { try? fm.removeItem(at: projectDir) } }

        // 1) The REAL exporter.
        let exportURL = dir.appendingPathComponent("export.mp4")
        try await VideoExporter().export(project: project, to: exportURL)

        // 2) The exporter's audio mix, read back losslessly (same inputs, same
        //    reader range/offset as VideoExporter.export).
        let mix = try await readReferenceMix(project: project)
        var bytes = Data(capacity: mix.samples.count * 4)
        mix.samples.withUnsafeBufferPointer { bytes.append(Data(buffer: $0)) }
        try bytes.write(to: dir.appendingPathComponent("mix.f32"))

        let summary: WV = [
            "name": .str(f.name),
            "description": .str(f.description),
            "dir": .str(f.name),
            "project": "project.json",
            "media": ["video": "recording.mp4", "voice": "voice.m4a", "cursor": "cursor.json", "keys": "keys.json", "export": "export.mp4"],
            "mix": ["file": "mix.f32", "format": "f32le-interleaved", "channels": .int(2), "sampleRate": .int(48_000),
                    "frames": .int(mix.samples.count / 2), "firstPTS": mix.firstPTS.wv, "path": .str(mix.path),
                    "clickTimes": mix.clickTimes.wv, "keyCount": .int(mix.keyCount)],
            "totalSeconds": mix.totalSeconds.wv,
        ]
        try Data(summary.serialized().utf8).write(to: dir.appendingPathComponent("fixture.json"))
        print("WEB-AUDIO fixture=\(f.name) mixFrames=\(mix.samples.count / 2) path=\(mix.path) total=\(String(format: "%.3f", mix.totalSeconds))s clicks=\(mix.clickTimes.count) keys=\(mix.keyCount)")
        return summary
    }

    /// Mirrors VideoExporter.export's audio half exactly (lines "Audio mix" →
    /// the detached audio task), reading float32 instead of handing Int16 to
    /// the AAC writer.
    @MainActor
    private static func readReferenceMix(project: Project) async throws
        -> (samples: [Float], firstPTS: Double, path: String, totalSeconds: Double, clickTimes: [Double], keyCount: Int) {
        let settings = project.settings
        let asset = AVURLAsset(url: project.videoURL!)
        let fullDuration = try await asset.load(.duration).seconds
        let trimStart = project.effectiveTrimStart
        let trimEnd = project.effectiveTrimEnd > 0 ? project.effectiveTrimEnd : fullDuration
        let timeMap = SpeedTimeMap(sourceStart: trimStart, sourceEnd: trimEnd, regions: project.speedRegions)
        let totalSeconds = project.exportedOutputDuration(timeMap: timeMap)

        var cursorEvents: [CursorEvent] = []
        var cursorCoordinateSize: CGSize = .zero
        if let cursorURL = project.cursorDataURL {
            let recording = try? CursorTracker.loadRecording(from: cursorURL)
            cursorEvents = recording?.events ?? []
            cursorCoordinateSize = recording?.hasValidCoordinateSpace == true ? recording?.coordinateSize ?? .zero : .zero
            if settings.smoothCursor {
                cursorEvents = CursorSmoother(factor: settings.smoothingFactor).smooth(events: cursorEvents)
            }
            cursorEvents = CursorSpringMath.apply(events: cursorEvents, settings: settings)
            cursorEvents = CursorEndBehaviorMath.apply(
                events: cursorEvents, trimEnd: project.effectiveTrimEnd,
                loopToStart: settings.cursorLoopToStart, stopAtEnd: settings.cursorStopAtEnd)
        }
        let clickTimes = settings.clickSoundEnabled
            ? ClickRippleOverlay.discreteClickTimes(from: cursorEvents, coordinateSize: cursorCoordinateSize)
            : []
        let keystrokes: [KeystrokeEvent] = settings.keySoundEnabled
            ? (project.keystrokeDataURL.flatMap { try? KeystrokeTracker.loadRecording(from: $0).events } ?? [])
            : []
        let prepared = try await ProjectAudioMix.prepare(
            for: asset, project: project, clickTimes: clickTimes, keystrokes: keystrokes)
        guard !prepared.tracks.isEmpty else {
            return ([], 0, "none", totalSeconds, clickTimes, keystrokes.count)
        }
        let reader = try AVAssetReader(asset: prepared.asset)
        let startCMTime: CMTime = prepared.asset === asset
            ? CMTime(seconds: trimStart, preferredTimescale: 600) : .zero
        reader.timeRange = CMTimeRange(start: startCMTime, duration: CMTime(seconds: totalSeconds, preferredTimescale: 600))
        var floatSettings = ProjectAudioMix.readerOutputSettings
        floatSettings[AVLinearPCMBitDepthKey] = 32
        floatSettings[AVLinearPCMIsFloatKey] = true
        let output = AVAssetReaderAudioMixOutput(audioTracks: prepared.tracks, audioSettings: floatSettings)
        output.audioMix = prepared.audioMix
        reader.add(output)
        guard reader.startReading() else {
            throw WebParityFixtures.FixtureError(message: reader.error?.localizedDescription ?? "reader failed")
        }
        var samples: [Float] = []
        var firstPTS: Double?
        while let buffer = output.copyNextSampleBuffer() {
            if firstPTS == nil {
                firstPTS = CMSampleBufferGetPresentationTimeStamp(buffer).seconds - startCMTime.seconds
            }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / 4)
            chunk.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            samples.append(contentsOf: chunk)
        }
        return (samples, firstPTS ?? 0, prepared.asset === asset ? "fast" : "composed", totalSeconds, clickTimes, keystrokes.count)
    }

    // MARK: - Synthetic media

    private static func burst(_ t: Double, at start: Double, length: Double, freq: Double, amp: Double) -> Double {
        let u = t - start
        guard u >= 0, u < length else { return 0 }
        let w = 0.5 - 0.5 * cos(2 * .pi * u / length)
        return amp * w * sin(2 * .pi * freq * u)
    }

    static func systemSample(_ t: Double, channel: Int) -> Float {
        var v = 0.08 * sin(2 * .pi * (channel == 0 ? 220 : 330) * t)
        for b in systemBursts { v += burst(t, at: b, length: 0.06, freq: 1000, amp: 0.5) }
        return Float(v)
    }

    static func micSample(_ t: Double) -> Float {
        var v = 0.05 * sin(2 * .pi * 150 * t)
        for b in micBursts { v += burst(t, at: b, length: 0.04, freq: 2500, amp: 0.4) }
        return Float(v)
    }

    static func voiceSample(_ t: Double) -> Float {
        var v = 0.1 * sin(2 * .pi * 500 * t)
        var b = 0.1
        while b < 3 { v += burst(t, at: b, length: 0.05, freq: 4000, amp: 0.35); b += 0.4 }
        return Float(v)
    }

    private static func pcmSampleBuffer(_ interleaved: [Float], channels: Int, sampleRate: Double, startFrame: Int) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        let byteCount = interleaved.count * 4
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: 0,
                                           blockBufferOut: &block)
        guard let block, let format else { throw WebParityFixtures.FixtureError(message: "pcm buffer") }
        interleaved.withUnsafeBytes { raw in
            _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount)
        }
        var out: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format,
            sampleCount: interleaved.count / channels,
            presentationTimeStamp: CMTime(value: CMTimeValue(startFrame), timescale: CMTimeScale(sampleRate)),
            packetDescriptions: nil, sampleBufferOut: &out)
        guard let out else { throw WebParityFixtures.FixtureError(message: "sample buffer") }
        return out
    }

    /// H.264 video (dark, flashing white on each system-burst frame) + stereo
    /// 48 kHz system AAC + mono 44.1 kHz mic AAC.
    @MainActor
    static func writeRecording(to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let width = Int(videoSize.width), height = Int(videoSize.height)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: VideoColorTags.colorProperties(p3: false),
            // No B-frames, like ScreenRecorder's own writer (the web preview
            // decoder must not have to buffer a deep reorder window).
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000, AVVideoAllowFrameReorderingKey: false],
        ])
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        let system = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000,
        ])
        let mic = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000,
        ])
        system.expectsMediaDataInRealTime = false
        mic.expectsMediaDataInRealTime = false
        writer.add(video)
        writer.add(system)
        writer.add(mic)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let flashFrames = Set(systemBursts.map { Int(($0 * Double(fps)).rounded()) })
        let frameCount = Int(duration * Double(fps))
        var frame = 0
        var sysFrame = 0
        var micFrame = 0
        let sysTotal = Int(duration * 48_000)
        let micTotal = Int(duration * 44_100)
        let chunk = 4096
        var videoDone = false, systemDone = false, micDone = false
        while frame < frameCount || sysFrame < sysTotal || micFrame < micTotal {
            var progressed = false
            if frame < frameCount, video.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool {
                var out: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
                guard let buffer = out else { throw WebParityFixtures.FixtureError(message: "no buffer") }
                CVPixelBufferLockBaseAddress(buffer, [])
                if let ctx = CGContext(
                    data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                    let on = flashFrames.contains(frame)
                    ctx.setFillColor(on ? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
                                        : CGColor(srgbRed: 0.12, green: 0.12, blue: 0.14, alpha: 1))
                    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
                }
                CVPixelBufferUnlockBaseAddress(buffer, [])
                guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps)) else {
                    throw WebParityFixtures.FixtureError(message: writer.error?.localizedDescription ?? "video append")
                }
                frame += 1
                progressed = true
            }
            if sysFrame < sysTotal, system.isReadyForMoreMediaData {
                let n = min(chunk, sysTotal - sysFrame)
                var data = [Float](repeating: 0, count: n * 2)
                for i in 0..<n {
                    let t = Double(sysFrame + i) / 48_000
                    data[2 * i] = systemSample(t, channel: 0)
                    data[2 * i + 1] = systemSample(t, channel: 1)
                }
                guard system.append(try pcmSampleBuffer(data, channels: 2, sampleRate: 48_000, startFrame: sysFrame)) else {
                    throw WebParityFixtures.FixtureError(message: writer.error?.localizedDescription ?? "system append")
                }
                sysFrame += n
                progressed = true
            }
            if micFrame < micTotal, mic.isReadyForMoreMediaData {
                let n = min(chunk, micTotal - micFrame)
                var data = [Float](repeating: 0, count: n)
                for i in 0..<n { data[i] = micSample(Double(micFrame + i) / 44_100) }
                guard mic.append(try pcmSampleBuffer(data, channels: 1, sampleRate: 44_100, startFrame: micFrame)) else {
                    throw WebParityFixtures.FixtureError(message: writer.error?.localizedDescription ?? "mic append")
                }
                micFrame += n
                progressed = true
            }
            if frame >= frameCount, !videoDone { video.markAsFinished(); videoDone = true }
            if sysFrame >= sysTotal, !systemDone { system.markAsFinished(); systemDone = true }
            if micFrame >= micTotal, !micDone { mic.markAsFinished(); micDone = true }
            if !progressed { try? await Task.sleep(nanoseconds: 2_000_000) }
        }
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frameCount), timescale: fps))
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw WebParityFixtures.FixtureError(message: writer.error?.localizedDescription ?? "writer failed")
        }
    }

    /// 3 s mono 48 kHz AAC voice-over.
    static func writeVoice(to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let frames = 3 * 48_000
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buf.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames { buf.floatChannelData![0][i] = voiceSample(Double(i) / 48_000) }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000,
        ])
        try file.write(from: buf)
    }

    /// 60 Hz glide with click runs; two pairs sit < 70 ms apart (overlapping ticks).
    static func writeCursor(to url: URL) throws {
        let size = CGSize(width: 320, height: 180)
        var events: [CursorEvent] = []
        let clickStarts: [Double] = [0.3, 1.2, 1.3, 2.2, 2.26, 3.3, 3.36, 4.1, 4.95, 5.4]
        let clickFrames = Set(clickStarts.map { Int(($0 * 60).rounded()) })
        var clickLeft = 0
        for i in 0...Int(duration * 60) {
            let t = Double(i) / 60
            if clickFrames.contains(i) { clickLeft = 2 }
            let isClick = clickLeft > 0
            if clickLeft > 0 { clickLeft -= 1 }
            let x = 0.5 + 0.3 * sin(2 * .pi * t / duration)
            let y = 0.5 + 0.25 * sin(4 * .pi * t / duration)
            events.append(CursorEvent(timestamp: t, x: CGFloat(x) * size.width, y: CGFloat(y) * size.height, isClick: isClick))
        }
        let recording = CursorRecording(version: 2, coordinateWidth: size.width, coordinateHeight: size.height, events: events)
        try JSONEncoder().encode(recording).write(to: url)
    }

    /// Typing bursts over every category (incl. scroll, which never sounds) and
    /// sub-8 ms chords (merged by KeySoundPlayer.minInterval).
    static func writeKeys(to url: URL) throws {
        var events: [KeystrokeEvent] = []
        let cats: [KeystrokeEvent.Category] = [.key, .key, .space, .key, .delete, .key, .return, .modifier, .key, .scroll]
        var rng = WVRandom(seed: "audio-keys")
        var t = 0.55
        var i = 0
        while t < 5.9 {
            events.append(KeystrokeEvent(timestamp: (t * 1000).rounded() / 1000, category: cats[i % cats.count]))
            if i % 7 == 3 {
                events.append(KeystrokeEvent(timestamp: ((t + 0.004) * 1000).rounded() / 1000, category: .modifier))
            }
            t += rng.double(0.045, 0.16)
            if i % 15 == 14 { t += 0.4 }
            i += 1
        }
        try JSONEncoder().encode(KeystrokeRecording(version: 1, events: events)).write(to: url)
    }

    // MARK: - Golden vectors for the synthesized sounds

    static func writeSounds(to url: URL) throws {
        var ticks: [(String, WV)] = []
        for style in ClickSoundStyle.allCases {
            ticks.append((style.rawValue, ClickSoundPlayer.tickSamples(style: style).map { Double($0) }.wv))
        }
        var strokes: [WV] = []
        for style in KeySoundStyle.allCases {
            for pitch in [0.799, 0.94, 1.0, 1.06, 1.2] {
                strokes.append([
                    "style": .str(style.rawValue), "pitch": pitch.wv,
                    "samples": KeySoundPlayer.strokeSamples(style: style, pitch: pitch).map { Double($0) }.wv,
                ])
            }
        }
        var variations: [WV] = []
        var rng = WVRandom(seed: "audio-variation")
        let cats: [KeystrokeEvent.Category] = [.key, .space, .return, .delete, .modifier, .scroll]
        for n in 0..<300 {
            let ts = n < 20 ? Double(n) * 0.0375 + 0.0005 : rng.double(0, 4000)
            let cat = cats[n % cats.count]
            let v = KeySoundPlayer.variation(timestamp: ts, category: cat)
            variations.append(["timestamp": ts.wv, "category": .str(cat.rawValue), "pitch": v.pitch.wv, "level": v.level.wv])
        }
        let file: WV = [
            "unit": "audioSounds",
            "notes": .str("ClickSoundPlayer.tickSamples(style:), KeySoundPlayer.strokeSamples(style:pitch:), KeySoundPlayer.variation(timestamp:category:) — Float samples widened to Double."),
            "sampleRate": 48_000.0.wv,
            "tickDuration": ClickSoundPlayer.tickDuration.wv,
            "strokeDuration": KeySoundPlayer.strokeDuration.wv,
            "minInterval": KeySoundPlayer.minInterval.wv,
            "ticks": .obj(ticks),
            "strokes": .arr(strokes),
            "variations": .arr(variations),
        ]
        try Data(file.serialized().utf8).write(to: url)
    }
}
