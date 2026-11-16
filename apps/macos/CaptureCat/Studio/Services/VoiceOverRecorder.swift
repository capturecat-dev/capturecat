import AVFoundation
import OSLog

#if DEBUG
private let voiceOverRecorderLogger = Logger(subsystem: "so.capturecat.CaptureCat", category: "VoiceOverRecorder")
#endif

/// What records a take: `AVAudioRecorder` on the mic in the apps
/// (`VoiceOverMic.makeRecorder`, Studio/Platform). A seam only so a gate can
/// feed a synthetic buffer through the same recorder, session and placement
/// code without touching a microphone (StudioHarness/FeaturesHarness).
@MainActor
protocol VoiceOverCapture: AnyObject {
    var isRecording: Bool { get }
    var currentTime: TimeInterval { get }
    var isMeteringEnabled: Bool { get set }
    @discardableResult func prepareToRecord() -> Bool
    func record() -> Bool
    func stop()
    func updateMeters()
    func averagePower(forChannel channelNumber: Int) -> Float
}

extension AVAudioRecorder: VoiceOverCapture {}

@MainActor
final class VoiceOverRecorder: NSObject {
    /// Makes the capture for a take. Default: the microphone.
    static var makeCapture: (URL, [String: Any]) throws -> VoiceOverCapture = VoiceOverMic.makeRecorder
    struct RecordingResult {
        let fileURL: URL
        let duration: TimeInterval
    }

    private var recorder: VoiceOverCapture?
    private var fileURL: URL?

    var isRecording: Bool {
        recorder?.isRecording == true
    }

    func startRecording(to url: URL) throws {
        stopRecording(discard: true)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 192_000,
        ]

        let recorder = try Self.makeCapture(url, settings)
        recorder.isMeteringEnabled = true
        recorder.prepareToRecord()
        guard recorder.record() else {
            throw NSError(domain: "VoiceOverRecorder", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Unable to start voice-over recording."
            ])
        }

        self.recorder = recorder
        self.fileURL = url
#if DEBUG
        voiceOverRecorderLogger.debug("start file=\(url.lastPathComponent, privacy: .public)")
#endif
    }

    @discardableResult
    func stopRecording(discard: Bool = false) -> RecordingResult? {
        guard let recorder, let fileURL else {
            return nil
        }

        let liveDuration = recorder.currentTime
        recorder.stop()
        let duration = measuredDuration(for: fileURL, fallback: liveDuration)

        self.recorder = nil
        self.fileURL = nil

        if discard || duration <= 0.1 {
            try? FileManager.default.removeItem(at: fileURL)
#if DEBUG
            voiceOverRecorderLogger.debug("stop discard=\(discard, privacy: .public) duration=\(duration, privacy: .public) removed=\(fileURL.lastPathComponent, privacy: .public)")
#endif
            return nil
        }

#if DEBUG
        voiceOverRecorderLogger.debug("stop discard=\(discard, privacy: .public) duration=\(duration, privacy: .public) file=\(fileURL.lastPathComponent, privacy: .public)")
#endif
        return RecordingResult(fileURL: fileURL, duration: duration)
    }

    func currentMeterLevel() -> Float {
        guard let recorder else { return 0 }
        recorder.updateMeters()
        let power = recorder.averagePower(forChannel: 0)
        let amplitude = pow(10, power / 20)
        return Float(max(0, min(1, amplitude)))
    }

    private func measuredDuration(for fileURL: URL, fallback: TimeInterval) -> TimeInterval {
        if let audioFile = try? AVAudioFile(forReading: fileURL) {
            let sampleRate = audioFile.processingFormat.sampleRate
            if sampleRate > 0 {
                let measured = Double(audioFile.length) / sampleRate
                if measured.isFinite, measured > 0 {
                    return measured
                }
            }
        }

        return fallback
    }
}
