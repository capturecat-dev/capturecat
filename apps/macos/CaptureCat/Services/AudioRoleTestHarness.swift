import AVFoundation
import Foundation

/// Recorded-track volume roles: `CaptureCat --audio-role-test`.
///
/// Which slider a recorded audio track follows (`ProjectAudioMix
/// .recordedTrackRole`): system audio is written first (stereo), the mic
/// after it (mono). A take recorded with the mic but WITHOUT system audio has
/// one mono track at index 0 — the index sent it to System Audio, so the
/// Microphone slider did nothing. This gate writes real files of each layout
/// and reads the volumes the REAL `ProjectAudioMix.prepare` assigns, on both
/// its fast path and its composition (speed-region) path:
///   mono only → Microphone · stereo only → System Audio ·
///   stereo + mono → System Audio, Microphone (unchanged).
/// DEBUG tooling; never reached in a normal launch.
@MainActor
enum AudioRoleTestHarness {
    static func run() -> Never {
        setbuf(stdout, nil)
        Task { @MainActor in
            let failures = await execute()
            print("AUDIO-ROLE \(failures == 0 ? "PASS" : "FAIL (\(failures))")")
            exit(failures == 0 ? 0 : 1)
        }
        RunLoop.main.run()
        exit(0)
    }

    private static func execute() async -> Int {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("capturecat-audio-role-\(getpid())", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let system = 0.3, mic = 0.7
        let cases: [(String, [Int], [Double])] = [
            ("mic-only take (one mono track)", [1], [mic]),
            ("system-only take (one stereo track)", [2], [system]),
            ("system + mic take", [2, 1], [system, mic]),
        ]
        var failures = 0
        for (label, layout, expected) in cases {
            let url = dir.appendingPathComponent("\(layout.map(String.init).joined(separator: "-")).mov")
            do { try await write(url, channelLayout: layout) } catch {
                print("FAIL \(label): could not write fixture — \(error)"); failures += 1; continue
            }
            for speedPath in [false, true] {
                let project = Project(name: "audio-role", duration: 2)
                project.trimStart = 0
                project.trimEnd = 2
                project.settings.systemAudioVolume = system
                project.settings.microphoneVolume = mic
                if speedPath { project.speedRegions = [VideoSpeedRegion(startTime: 0.5, endTime: 1.5, speed: 2)] }
                let volumes: [Double]
                do {
                    let prepared = try await ProjectAudioMix.prepare(for: AVURLAsset(url: url), project: project)
                    volumes = (prepared.audioMix?.inputParameters ?? []).map { input in
                        var start: Float = -1, end: Float = -1
                        var range = CMTimeRange.zero
                        _ = input.getVolumeRamp(for: .zero, startVolume: &start, endVolume: &end, timeRange: &range)
                        return Double(start)
                    }
                } catch {
                    print("FAIL \(label): prepare threw \(error)"); failures += 1; continue
                }
                let pass = volumes.count == expected.count
                    && zip(volumes, expected).allSatisfy { abs($0 - $1) < 1e-6 }
                if !pass { failures += 1 }
                print("\(pass ? "PASS" : "FAIL") \(label) [\(speedPath ? "speed-region path" : "fast path")] — volumes \(volumes.map { String(format: "%.2f", $0) }), expected \(expected.map { String(format: "%.2f", $0) })")
            }
        }
        return failures
    }

    /// A 2 s movie with one AAC track per entry of `channelLayout` (its
    /// channel count), in that order — 48 kHz sine tones.
    private static func write(_ url: URL, channelLayout: [Int]) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let inputs = channelLayout.map { channels -> AVAssetWriterInput in
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: 128_000,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            return input
        }
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        let rate = 48_000, chunk = 4_800, total = rate * 2
        for (input, channels) in zip(inputs, channelLayout) {
            var frame = 0
            while frame < total {
                while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
                let count = min(chunk, total - frame)
                var data = [Float](repeating: 0, count: count * channels)
                for i in 0..<count {
                    let v = Float(sin(2 * Double.pi * 440 * Double(frame + i) / Double(rate)) * 0.25)
                    for c in 0..<channels { data[i * channels + c] = v }
                }
                guard input.append(try WebAudioFixtures.pcmSampleBuffer(data, channels: channels,
                                                                        sampleRate: Double(rate), startFrame: frame)) else {
                    throw writer.error ?? CocoaError(.fileWriteUnknown)
                }
                frame += count
            }
            input.markAsFinished()
        }
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
}
