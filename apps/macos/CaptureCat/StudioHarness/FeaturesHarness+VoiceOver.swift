import AVFoundation
import Foundation

/// Voice-over: a synthetic narration stands in for the microphone
/// (`VoiceOverRecorder.makeCapture`) — the SAME recorder settings, session,
/// meter, file-finalize wait and clip placement as a real take, but no mic is
/// ever opened (and no permission asked). Compared across platforms: the
/// voice-track entry (exact), the meter levels at fixed take times (the
/// shared dBFS → level mapping), and the exporter's audio mix with the clip.
extension FeaturesHarness {
    enum VoiceFixture {
        static let recording = "recording.mov"
        /// Fixed so both platforms' projects resolve the take in a folder
        /// named the same way (`Project.projectDirectory`).
        static let projectID = UUID(uuidString: "4E4E0000-0000-4000-8000-00000000A100")!
        static let duration: TimeInterval = 6
        /// The playhead when Record is pressed (SOURCE seconds).
        static let takeStart: TimeInterval = 1.25
        static let sampleRate = 48_000.0
        static let takeSeconds = 3.0
        /// Where the meter is read during the scripted take.
        static let meterTimes: [Double] = stride(from: 0.1, through: 2.9, by: 0.2).map { $0 }
        /// |Δ| allowed per mix sample: render-baseline's audio tolerance (the
        /// AVFoundation mix path is ±1 ULP run to run).
        static let mixTolerance: Float = 1e-6

        /// The narration: a voiced 180 Hz tone with harmonics under a
        /// syllable envelope (silences between "words" so the meter moves).
        static func sample(_ i: Int) -> Float {
            let t = Double(i) / sampleRate
            let syllable = 0.5 - 0.5 * cos(2 * .pi * t / 0.36)
            let word = t.truncatingRemainder(dividingBy: 0.9) < 0.66 ? 1.0 : 0.05
            let tone = sin(2 * .pi * 180 * t) + 0.45 * sin(2 * .pi * 360 * t) + 0.2 * sin(2 * .pi * 540 * t)
            return Float(0.32 * syllable * word * tone)
        }

        static let samples: [Float] = (0..<Int(sampleRate * takeSeconds)).map(sample)

        /// The project the take is recorded into (recording from the Mac's
        /// fixture dir: H.264 + a stereo system-audio track).
        static func project(recording url: URL) -> Project {
            let project = Project(id: projectID, name: "features-voiceover", videoURL: url, duration: duration)
            project.trimStart = 0
            project.trimEnd = duration
            return project
        }

        /// The entry, without its minted id and file UUID.
        static func entry(_ clip: VoiceOverClip) -> String {
            var copy = clip
            copy.fileName = clip.fileName.hasPrefix("voiceover-") && clip.fileName.hasSuffix(".m4a")
                ? "voiceover-<uuid>.m4a" : clip.fileName
            return FeaturesHarness.canonical(copy)
        }
    }

    /// The synthetic microphone. `record()` starts its clock; `stop()`
    /// encodes the whole narration with the recorder's own settings (AAC,
    /// 48 kHz mono, 192 kbps) — as a 3 s take would. The meter reports the
    /// RMS of the last 45 ms before the clock in dBFS, like AVAudioRecorder.
    @MainActor
    final class SyntheticVoiceCapture: VoiceOverCapture {
        /// Wall clock unless `manual` is set (the scripted meter reads).
        final class Clock {
            var manual: Double?
            private let origin = Date()
            var now: Double { manual ?? Date().timeIntervalSince(origin) }
        }

        let url: URL
        let settings: [String: Any]
        let clock: Clock
        private var startedAt: Double?
        private(set) var isRecording = false
        var isMeteringEnabled = false
        private(set) var writeError: Error?

        init(url: URL, settings: [String: Any], clock: Clock) {
            self.url = url
            self.settings = settings
            self.clock = clock
        }

        var takeDuration: Double { VoiceFixture.takeSeconds }
        var currentTime: TimeInterval {
            guard let startedAt else { return 0 }
            return min(max(0, clock.now - startedAt), takeDuration)
        }

        @discardableResult func prepareToRecord() -> Bool { true }
        func record() -> Bool {
            startedAt = clock.now
            isRecording = true
            return true
        }
        func updateMeters() {}

        func averagePower(forChannel channelNumber: Int) -> Float {
            let end = min(VoiceFixture.samples.count, Int(currentTime * VoiceFixture.sampleRate))
            let start = max(0, end - Int(0.045 * VoiceFixture.sampleRate))
            guard end > start else { return -160 }
            var sum = 0.0
            for i in start..<end { sum += Double(VoiceFixture.samples[i]) * Double(VoiceFixture.samples[i]) }
            let rms = (sum / Double(end - start)).squareRoot()
            return rms > 0 ? Float(20 * log10(rms)) : -160
        }

        func stop() {
            guard isRecording else { return }
            isRecording = false
            do {
                let format = AVAudioFormat(standardFormatWithSampleRate: VoiceFixture.sampleRate, channels: 1)!
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(VoiceFixture.samples.count))!
                buffer.frameLength = buffer.frameCapacity
                VoiceFixture.samples.withUnsafeBufferPointer { src in
                    buffer.floatChannelData![0].update(from: src.baseAddress!, count: src.count)
                }
                let file = try AVAudioFile(forWriting: url, settings: settings)
                try file.write(from: buffer)
            } catch {
                writeError = error
            }
        }
    }

    /// Points `session`'s recorder at the synthetic capture and skips the
    /// permission prompt. Returns the capture once the take starts.
    @MainActor
    static func installSyntheticVoice(on session: VoiceOverSession,
                                      clock: SyntheticVoiceCapture.Clock) -> () -> SyntheticVoiceCapture? {
        var made: SyntheticVoiceCapture?
        VoiceOverRecorder.makeCapture = { url, settings in
            let capture = SyntheticVoiceCapture(url: url, settings: settings, clock: clock)
            made = capture
            return capture
        }
        session.requestPermission = {}
        return { made }
    }

    /// The scripted take, no UI: prepare → begin at the fixture playhead →
    /// meter reads at `meterTimes` on a manual clock → finish.
    @MainActor
    static func scriptedTake(project: Project) async throws -> (clip: VoiceOverClip?, meter: [Float]) {
        let session = VoiceOverSession()
        let clock = SyntheticVoiceCapture.Clock()
        clock.manual = 0
        let capture = installSyntheticVoice(on: session, clock: clock)
        defer { VoiceOverRecorder.makeCapture = VoiceOverMic.makeRecorder }
        try await session.prepare(for: project)
        try session.begin(for: project, currentTime: VoiceFixture.takeStart)
        var meter: [Float] = []
        for t in VoiceFixture.meterTimes {
            clock.manual = t
            meter.append(session.recorder.currentMeterLevel())
        }
        clock.manual = VoiceFixture.takeSeconds
        let clip = await session.finish(for: project, discard: false, fallbackStart: VoiceFixture.takeStart)
        if let error = capture()?.writeError { throw error }
        return (clip, meter)
    }

    /// The exporter's audio mix for `project` — `ProjectAudioMix.prepare`
    /// read through `AVAssetReaderAudioMixOutput` exactly as VideoExporter's
    /// audio half reads it (fast path shifted by trimStart), as float32
    /// interleaved stereo 48 kHz (the Mac's `--web-audio-fixtures` reader,
    /// without clicks or keys).
    static func readMix(project: Project) async throws -> [Float] {
        guard let videoURL = project.videoURL else { return [] }
        let asset = AVURLAsset(url: videoURL)
        let fullDuration = try await asset.load(.duration).seconds
        let trimStart = project.effectiveTrimStart
        let trimEnd = project.effectiveTrimEnd > 0 ? project.effectiveTrimEnd : fullDuration
        let timeMap = SpeedTimeMap(sourceStart: trimStart, sourceEnd: trimEnd, regions: project.speedRegions)
        let totalSeconds = project.exportedOutputDuration(timeMap: timeMap)
        let prepared = try await ProjectAudioMix.prepare(for: asset, project: project)
        guard !prepared.tracks.isEmpty else { return [] }
        let reader = try AVAssetReader(asset: prepared.asset)
        let startCMTime: CMTime = prepared.asset === asset ? CMTime(seconds: trimStart, preferredTimescale: 600) : .zero
        reader.timeRange = CMTimeRange(start: startCMTime, duration: CMTime(seconds: totalSeconds, preferredTimescale: 600))
        var settings = ProjectAudioMix.readerOutputSettings
        settings[AVLinearPCMBitDepthKey] = 32
        settings[AVLinearPCMIsFloatKey] = true
        let output = AVAssetReaderAudioMixOutput(audioTracks: prepared.tracks, audioSettings: settings)
        output.audioMix = prepared.audioMix
        reader.add(output)
        guard reader.startReading() else {
            throw NSError(domain: "FeaturesHarness", code: 1, userInfo: [
                NSLocalizedDescriptionKey: reader.error?.localizedDescription ?? "mix reader failed"])
        }
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / 4)
            chunk.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            samples.append(contentsOf: chunk)
        }
        return samples
    }

    /// Decoded mono samples of a voice file (the take as encoded).
    static func decodeVoice(_ url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let channel = buffer.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    /// (max |Δ|, frames compared, length equal).
    static func compareSamples(_ a: [Float], _ b: [Float]) -> (maxDelta: Float, count: Int, sameLength: Bool) {
        let n = min(a.count, b.count)
        var worst: Float = 0
        for i in 0..<n { worst = max(worst, abs(a[i] - b[i])) }
        return (n == 0 ? .infinity : worst, n, a.count == b.count)
    }
}
