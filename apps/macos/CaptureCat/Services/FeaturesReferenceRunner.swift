import AppKit
import AVFoundation

/// `CaptureCat --features-reference <dir> [--speech <wav> --script <txt>]
///  [--whisper-base <dir> [--fetch-model]] [--speech-corpus <dir>] [--camera <mov>]
///  [--only autozoom,voiceover,transcription,cutout]`
///
/// `--whisper-base` is a WhisperKit download base holding `base.en` and its
/// tokenizer; `--fetch-model` lets WhisperKit download them there first
/// (~150 MB from Hugging Face — only with the owner's go-ahead).
///
/// The Mac half of the Studio 4e features gate (StudioHarness/FeaturesHarness):
/// writes each feature's fixture into <dir> and the Mac's own results beside
/// it (`mac-*.json`, the voice take, its mix, the person mask, the cutout's
/// preview / export frames). `apps/ios/scripts/ios-features.sh` then runs
/// StudioLab `--features` against <dir>. All inputs are synthetic or system
/// media (the speech is `say` output; the camera clip is iMovie's), never
/// user data. DEBUG tooling; never reached in a normal launch.
@MainActor
enum FeaturesReferenceRunner {
    static func run() -> Never {
        setbuf(stdout, nil)
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--features-reference"), args.indices.contains(i + 1) else {
            print("usage: CaptureCat --features-reference <dir> [--speech <wav> --script <txt>] [--whisper-base <dir> [--fetch-model]] [--camera <mov>] [--only …]")
            exit(2)
        }
        func value(_ name: String) -> String? {
            args.firstIndex(of: name).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }
        let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        let only = value("--only").map { Set($0.split(separator: ",").map(String.init)) }
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .darkAqua)
        Task { @MainActor in
            var failures = 0
            func wants(_ part: String) -> Bool { only?.contains(part) ?? true }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if wants("autozoom") { failures += await autoZoom(dir.appendingPathComponent("autozoom", isDirectory: true)) }
            if wants("voiceover") { failures += await voiceOver(dir.appendingPathComponent("voiceover", isDirectory: true)) }
            if wants("transcription") {
                if let speech = value("--speech"), let script = value("--script"), let models = value("--whisper-base") {
                    failures += await transcription(dir.appendingPathComponent("transcription", isDirectory: true),
                                                    speech: URL(fileURLWithPath: speech), script: URL(fileURLWithPath: script),
                                                    models: URL(fileURLWithPath: models, isDirectory: true),
                                                    fetch: args.contains("--fetch-model"),
                                                    corpus: value("--speech-corpus").map(corpusClips) ?? [])
                } else {
                    print("FEATURES-REFERENCE transcription SKIPPED (needs --speech, --script and --whisper-base)")
                }
            }
            if wants("cutout") {
                failures += await cutout(dir.appendingPathComponent("cutout", isDirectory: true),
                                         camera: URL(fileURLWithPath: value("--camera") ?? FeaturesHarness.CutoutFixture.defaultCamera))
            }
            print("FEATURES-REFERENCE \(failures == 0 ? "OK" : "FAILED (\(failures))") \(dir.path)")
            exit(failures == 0 ? 0 : 1)
        }
        RunLoop.main.run()
        fatalError("unreachable")
    }

    // MARK: - Auto Zoom

    private static func autoZoom(_ dir: URL) async -> Int {
        typealias F = FeaturesHarness.AutoZoomFixture
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try await writeMovie(dir.appendingPathComponent(F.recording), size: F.videoSize, duration: F.duration,
                                 fill: CGColor(srgbRed: 0.16, green: 0.18, blue: 0.22, alpha: 1), audio: nil)
            try JSONEncoder().encode(CursorRecording(version: 2, coordinateWidth: F.screen.width,
                                                     coordinateHeight: F.screen.height, events: F.cursorEvents()))
                .write(to: dir.appendingPathComponent(F.cursor))
            try JSONEncoder().encode(KeystrokeRecording(version: 1, events: F.keystrokeEvents()))
                .write(to: dir.appendingPathComponent(F.keystrokes))
        } catch {
            print("FEATURES-REFERENCE autozoom FAIL fixture: \(error)")
            return 1
        }
        var result: [String: Any] = [:]
        for (label, level) in [("default", nil), ("slider", F.sliderLevel)] as [(String, Double?)] {
            let project = F.project(in: dir)
            if let level { project.settings.autoZoomLevel = level }
            let undo = UndoManager()
            undo.groupsByEvent = false
            undo.beginUndoGrouping()
            let created = AutoZoomApplier.applyAsEdit(to: project, undoManager: undo)
            undo.endUndoGrouping()
            let lines = F.blockLines(project.zoomRegions)
            undo.undo()
            let restored = F.blockLines(project.zoomRegions) == F.blockLines(F.project(in: dir).zoomRegions)
            result[label] = ["created": created, "blocks": lines, "undoRestores": restored]
            print("FEATURES-REFERENCE autozoom \(label): \(created) auto block(s), \(lines.count) total, undo restores \(restored)")
        }
        FeaturesHarness.write(result, to: dir.appendingPathComponent("mac-autozoom.json"))
        return 0
    }

    // MARK: - Voice-over

    private static func voiceOver(_ dir: URL) async -> Int {
        typealias F = FeaturesHarness.VoiceFixture
        let fm = FileManager.default
        let projectDir = Project.directory(for: F.projectID)
        // The take lands in Project.projectDirectory (Application Support):
        // this fixture's own fixed-id folder, created and removed here —
        // never a folder that already exists.
        guard !fm.fileExists(atPath: projectDir.path) else {
            print("FEATURES-REFERENCE voiceover FAIL \(projectDir.path) already exists — refusing to touch it")
            return 1
        }
        defer { try? fm.removeItem(at: projectDir) }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let recording = dir.appendingPathComponent(F.recording)
            try await writeMovie(recording, size: CGSize(width: 640, height: 360), duration: F.duration,
                                 fill: CGColor(srgbRed: 0.1, green: 0.12, blue: 0.16, alpha: 1),
                                 audio: (channels: 2, sample: { t, c in Float(0.06 * sin(2 * .pi * (c == 0 ? 220 : 330) * t)) }))
            let project = F.project(recording: recording)
            let (clip, meter) = try await FeaturesHarness.scriptedTake(project: project)
            guard let clip else {
                print("FEATURES-REFERENCE voiceover FAIL the take made no clip")
                return 1
            }
            let voice = clip.resolvedURL(in: project.projectDirectory)
            try? fm.removeItem(at: dir.appendingPathComponent("mac-voice.m4a"))
            try fm.copyItem(at: voice, to: dir.appendingPathComponent("mac-voice.m4a"))
            let mix = try await FeaturesHarness.readMix(project: project)
            FeaturesHarness.writeFloats(mix, to: dir.appendingPathComponent("mac-mix.f32"))
            let decoded = FeaturesHarness.decodeVoice(voice) ?? []
            FeaturesHarness.writeFloats(decoded, to: dir.appendingPathComponent("mac-voice.f32"))
            FeaturesHarness.write([
                "entry": F.entry(clip),
                "fileName": clip.fileName,
                "meter": meter.map(Double.init),
                "mixSamples": mix.count,
                "voiceFrames": decoded.count,
            ], to: dir.appendingPathComponent("mac-voiceover.json"))
            print("FEATURES-REFERENCE voiceover entry \(F.entry(clip)) · mix \(mix.count) samples · meter \(meter.count) reads")
            return 0
        } catch {
            print("FEATURES-REFERENCE voiceover FAIL \(error)")
            return 1
        }
    }

    // MARK: - Transcription

    private static func transcription(_ dir: URL, speech: URL, script: URL, models: URL, fetch: Bool,
                                      corpus: [URL]) async -> Int {
        typealias F = FeaturesHarness.SpeechFixture
        let fm = FileManager.default
        do {
            let modelFolder = TranscriptionService.modelFolder(in: models)
            if !fm.fileExists(atPath: modelFolder.appendingPathComponent("config.json").path) {
                guard fetch else {
                    print("FEATURES-REFERENCE transcription FAIL no model at \(modelFolder.path) (pass --fetch-model to download it)")
                    return 1
                }
                print("FEATURES-REFERENCE transcription fetching \(TranscriptionService.model) into \(models.path)")
                _ = try await TranscriptionService.fetchModel(into: models)
            }
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let movie = dir.appendingPathComponent(F.movie)
            try await writeSpeechMovie(movie, speech: speech)
            try? fm.removeItem(at: dir.appendingPathComponent(F.script))
            try fm.copyItem(at: script, to: dir.appendingPathComponent(F.script))
            // Model and tokenizer from the one base (the tokenizer is fetched
            // there on the first load; StudioLab then needs no network).
            let service = TranscriptionService(modelFolder: modelFolder, downloadBase: models)
            let wav = fm.temporaryDirectory.appendingPathComponent("features-\(UUID().uuidString).wav")
            try await service.extractAudio(from: movie, to: wav)
            let wavSHA = FeaturesHarness.sha256(try Data(contentsOf: wav))
            // Kept: StudioLab also transcribes exactly this input (the
            // equal-input cross-check that isolates the engine).
            try? fm.removeItem(at: dir.appendingPathComponent(F.macInput))
            try fm.moveItem(at: wav, to: dir.appendingPathComponent(F.macInput))
            let started = Date()
            let segments = try await service.transcribe(videoURL: movie)
            let seconds = Date().timeIntervalSince(started)
            let transcript = FeaturesHarness.transcript(segments)
            let data = try JSONEncoder().encode(transcript)
            try data.write(to: dir.appendingPathComponent("mac-transcript.json"))
            // The Mac against itself: a second run of the same input.
            let again = FeaturesHarness.transcript(try await service.transcribe(videoURL: movie))
            let repeatDelta = FeaturesHarness.maxTimingDelta(mac: transcript, ios: again)
            let repeatSame = again.map(\.words.count) == transcript.map(\.words.count) && again.map(\.text) == transcript.map(\.text)
            print("FEATURES-REFERENCE transcription Mac rerun: structure+text \(repeatSame ? "identical" : "DIFFER"), max timing |Δ| \(repeatDelta) s")
            // Attribution: the same input with every model on the CPU (the
            // iOS Simulator's only compute path).
            let cpu = TranscriptionService(modelFolder: modelFolder, downloadBase: models, cpuOnly: true)
            let cpuTranscript = FeaturesHarness.transcript(try await cpu.transcribe(
                videoURL: dir.appendingPathComponent(F.macInput)))
            try JSONEncoder().encode(cpuTranscript).write(to: dir.appendingPathComponent("mac-transcript-cpu.json"))
            // The Mac's self-variance over a corpus: each clip on the default
            // compute units and on the CPU only, word boundaries pooled.
            var pairs: [(a: [FeaturesHarness.TranscriptSegment], b: [FeaturesHarness.TranscriptSegment])] = [(transcript, cpuTranscript)]
            for clip in corpus {
                let a = FeaturesHarness.transcript(try await service.transcribe(videoURL: clip))
                let b = FeaturesHarness.transcript(try await cpu.transcribe(videoURL: clip))
                let d = FeaturesHarness.timingDeltas(mac: a, ios: b)
                print(String(format: "FEATURES-REFERENCE transcription self-variance %@: %d words, max %.3f p90 %.3f%@",
                             clip.lastPathComponent, a.reduce(0) { $0 + $1.words.count }, d.max() ?? 0,
                             FeaturesHarness.percentile(d, 0.9),
                             a.map(\.words.count) == b.map(\.words.count) ? "" : " (ANE and CPU differ in words)"))
                pairs.append((a, b))
            }
            let spread = FeaturesHarness.selfSpread(pairs)
            print(String(format: "FEATURES-REFERENCE transcription Mac self-variance (ANE vs CPU, %d clips, %d boundaries): max %.3f p90 %.3f median %.3f, %d clip(s) differing in words",
                         spread.clips, spread.boundaries, spread.max, spread.p90, spread.median, spread.mismatches))
            FeaturesHarness.write(["wavSHA256": wavSHA, "seconds": seconds, "segments": segments.count,
                                   "words": segments.reduce(0) { $0 + $1.words.count },
                                   "repeatTimingDelta": repeatDelta, "repeatIdentical": repeatSame,
                                   "selfSpread": spread.json],
                                  to: dir.appendingPathComponent("mac-transcription.json"))
            print("FEATURES-REFERENCE transcription \(segments.count) segments, \(segments.reduce(0) { $0 + $1.words.count }) words in \(String(format: "%.1f", seconds)) s · wav \(wavSHA.prefix(12))")
            return segments.isEmpty ? 1 : 0
        } catch {
            print("FEATURES-REFERENCE transcription FAIL \(error)")
            return 1
        }
    }

    // MARK: - Background removal

    private static func cutout(_ dir: URL, camera source: URL) async -> Int {
        typealias F = FeaturesHarness.CutoutFixture
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            guard fm.fileExists(atPath: source.path) else {
                print("FEATURES-REFERENCE cutout FAIL no camera clip at \(source.path) (iMovie's bundled trailer clip; pass --camera)")
                return 1
            }
            let camera = dir.appendingPathComponent(F.camera)
            try? fm.removeItem(at: camera)
            try fm.copyItem(at: source, to: camera)
            let cameraDuration = try await AVURLAsset(url: camera).load(.duration).seconds
            let screen = dir.appendingPathComponent(F.screen)
            try await writeMovie(screen, size: CGSize(width: 1280, height: 720), duration: cameraDuration,
                                 fill: nil, audio: nil)

            // 1. Producer arithmetic.
            let synthetic = try FeaturesHarness.conditionedSyntheticTrack()
            let conditioningSHA = FeaturesHarness.sha256(synthetic)

            // 2. The real producer (Vision), with its progress sequence.
            var progress: [Double] = []
            let progressBox = ProgressBox()
            let started = Date()
            let mask = try await Task.detached(priority: .userInitiated) {
                try await CameraSegmenter.segment(cameraURL: camera, gate: CameraSegmentationGate()) { progressBox.add($0) }
            }.value
            progress = progressBox.values
            let segmentSeconds = Date().timeIntervalSince(started)
            try mask.write(to: dir.appendingPathComponent("mac-mask.ccmask"))
            let track = try CameraMaskTrack(data: mask)
            // Control for the Simulator path: the same pipeline with Vision
            // swapped for a replay of this matte re-encodes it byte for byte.
            let replayed = try await Task.detached(priority: .userInitiated) {
                try await CameraSegmenter.segment(cameraURL: camera, gate: CameraSegmentationGate(),
                                                  matte: FeaturesHarness.replayMatte(track, delay: 0)) { _ in }
            }.value
            let replayIdentical = replayed == mask
            print("FEATURES-REFERENCE cutout replayed matte re-encodes byte-identical: \(replayIdentical)")
            try mask.write(to: CameraMaskTrack.url(besideCamera: camera))

            // 3. Rendering with the Mac's mask.
            guard let posters = await FeaturesHarness.cutoutPosters(screen: screen, camera: camera) else {
                print("FEATURES-REFERENCE cutout FAIL cannot decode the posters")
                return 1
            }
            let stage = PreviewExportParityRunner.MacStage(canvas: F.canvas)
            let renders = dir.appendingPathComponent("mac", isDirectory: true)
            try fm.createDirectory(at: renders, withIntermediateDirectories: true)
            var results: [FeaturesHarness.RenderResult] = []
            var images: [String: (preview: CGImage, export: CGImage)] = [:]
            for (name, look) in F.looks {
                let project = F.project(screen: screen, camera: camera, cameraDuration: cameraDuration, look: look)
                let (result, preview, export) = await FeaturesHarness.renderCutout(
                    name: name, project: project, mask: track, stage: stage, screenPoster: posters.screen,
                    cameraPoster: posters.camera, cameraAspect: posters.aspect, out: renders)
                if let preview, let export { images[name] = (preview, export) }
                results.append(result)
            }
            FeaturesHarness.scoreCameraBoxes(&results, images: images)
            for result in results {
                print(String(format: "FEATURES-REFERENCE cutout %@ preview↔export mean %.3f over8 %.3f%% max %d · camera box %@ · look effect %@%@",
                             result.name, result.mean, result.over8 * 100, result.maxDelta,
                             result.cameraMean.map { String(format: "%.3f", $0) } ?? "–",
                             result.lookEffect.map { String(format: "%.1f", $0) } ?? "–",
                             result.error.map { " ERROR \($0)" } ?? ""))
            }
            try JSONEncoder().encode(results).write(to: dir.appendingPathComponent("mac-renders.json"))
            FeaturesHarness.write([
                "conditioningSHA256": conditioningSHA,
                "maskBytes": mask.count,
                "maskFrames": track.header.frameCount,
                "maskSize": "\(track.header.width)x\(track.header.height)",
                "segmentSeconds": segmentSeconds,
                "progress": progress,
                "cameraDuration": cameraDuration,
                "replayIdentical": replayIdentical,
            ], to: dir.appendingPathComponent("mac-cutout.json"))
            print("FEATURES-REFERENCE cutout mask \(track.header.width)×\(track.header.height) \(track.header.frameCount) frames in \(String(format: "%.1f", segmentSeconds)) s · conditioning \(conditioningSHA.prefix(12))")
            return results.contains { $0.error != nil } || !replayIdentical ? 1 : 0
        } catch {
            print("FEATURES-REFERENCE cutout FAIL \(error)")
            return 1
        }
    }

    /// The corpus clips (`*.aiff`, `*.wav`), in name order.
    private static func corpusClips(_ path: String) -> [URL] {
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["aiff", "wav"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private nonisolated final class ProgressBox: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [Double] = []
        func add(_ v: Double) { lock.withLock { list.append(v) } }
        var values: [Double] { lock.withLock { list } }
    }

    // MARK: - Media

    /// An H.264 movie (one frame every ~0.1 s: a flat `fill`, or a test
    /// pattern when nil) with an optional AAC audio track.
    private static func writeMovie(_ url: URL, size: CGSize, duration: TimeInterval, fill: CGColor?,
                                   audio: (channels: Int, sample: (Double, Int) -> Float)?) async throws {
        try? FileManager.default.removeItem(at: url)
        let fps: Int32 = 10
        let width = Int(size.width), height = Int(size.height)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: VideoColorTags.colorProperties(p3: false),
        ])
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(video)
        var audioInput: AVAssetWriterInput?
        if let audio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: audio.channels, AVEncoderBitRateKey: 192_000,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
        }
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        let frames = Int(duration * Double(fps))
        var frame = 0, audioFrame = 0
        let audioTotal = Int(duration * 48_000)
        var videoDone = false, audioDone = audioInput == nil
        while !videoDone || !audioDone {
            var progressed = false
            if !videoDone, video.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool {
                var out: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
                guard let buffer = out else { throw CocoaError(.fileWriteUnknown) }
                CVPixelBufferLockBaseAddress(buffer, [])
                if let ctx = CGContext(
                    data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                    if let fill {
                        ctx.setFillColor(fill)
                        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
                    } else {
                        drawPattern(ctx, width: width, height: height)
                    }
                }
                CVPixelBufferUnlockBaseAddress(buffer, [])
                guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps)) else {
                    throw writer.error ?? CocoaError(.fileWriteUnknown)
                }
                frame += 1
                progressed = true
                if frame >= frames { video.markAsFinished(); videoDone = true }
            }
            if !audioDone, let audioInput, let audio, audioInput.isReadyForMoreMediaData {
                let n = min(4096, audioTotal - audioFrame)
                var data = [Float](repeating: 0, count: n * audio.channels)
                for i in 0..<n {
                    let t = Double(audioFrame + i) / 48_000
                    for c in 0..<audio.channels { data[i * audio.channels + c] = audio.sample(t, c) }
                }
                guard audioInput.append(try WebAudioFixtures.pcmSampleBuffer(
                    data, channels: audio.channels, sampleRate: 48_000, startFrame: audioFrame)) else {
                    throw writer.error ?? CocoaError(.fileWriteUnknown)
                }
                audioFrame += n
                progressed = true
                if audioFrame >= audioTotal { audioInput.markAsFinished(); audioDone = true }
            }
            if !progressed { try await Task.sleep(nanoseconds: 2_000_000) }
        }
        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 600))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    /// Bars and a grid: enough structure that a misplaced cutout shows.
    private static func drawPattern(_ ctx: CGContext, width: Int, height: Int) {
        let colors: [CGColor] = [
            CGColor(srgbRed: 0.85, green: 0.3, blue: 0.3, alpha: 1), CGColor(srgbRed: 0.3, green: 0.75, blue: 0.4, alpha: 1),
            CGColor(srgbRed: 0.25, green: 0.45, blue: 0.9, alpha: 1), CGColor(srgbRed: 0.95, green: 0.8, blue: 0.3, alpha: 1),
            CGColor(srgbRed: 0.6, green: 0.35, blue: 0.85, alpha: 1), CGColor(srgbRed: 0.2, green: 0.2, blue: 0.24, alpha: 1),
        ]
        let bar = CGFloat(width) / CGFloat(colors.count)
        for (i, color) in colors.enumerated() {
            ctx.setFillColor(color)
            ctx.fill(CGRect(x: CGFloat(i) * bar, y: 0, width: bar + 1, height: CGFloat(height)))
        }
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.5))
        ctx.setLineWidth(2)
        for x in stride(from: 0, to: width, by: 80) { ctx.stroke(CGRect(x: x, y: -2, width: 0, height: height + 4)) }
        for y in stride(from: 0, to: height, by: 80) { ctx.stroke(CGRect(x: -2, y: y, width: width + 4, height: 0)) }
    }

    /// The speech as a recording: a flat video track and the speech as an
    /// AAC mono 48 kHz track (what a mic take carries).
    private static func writeSpeechMovie(_ url: URL, speech: URL) async throws {
        let file = try AVAudioFile(forReading: speech)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: format),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try file.read(into: input)
        let capacity = AVAudioFrameCount(Double(file.length) * 48_000 / file.processingFormat.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw CocoaError(.fileReadCorruptFile) }
        var consumed = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true
            status.pointee = .haveData
            return input
        }
        if let conversionError { throw conversionError }
        let samples = Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
        let duration = Double(samples.count) / 48_000 + 0.5
        try await writeMovie(url, size: CGSize(width: 640, height: 360), duration: duration,
                             fill: CGColor(srgbRed: 0.12, green: 0.12, blue: 0.14, alpha: 1),
                             audio: (channels: 1, sample: { t, _ in
                                 let i = Int(t * 48_000)
                                 return i < samples.count ? samples[i] : 0
                             }))
    }
}
