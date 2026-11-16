import AVFoundation
import Foundation

/// The microphone capture behind a voice-over take (`VoiceOverRecorder
/// .makeCapture`). The recorder, its settings, the meter and the clip
/// placement are shared (`VoiceOverSession`); only how the app gets the mic
/// differs:
///
/// - macOS: `AVAudioRecorder` straight on the default input — the exact
///   object the Mac recorded with before Studio 4e.
/// - iOS: the same `AVAudioRecorder`, inside an `AVAudioSession` switched to
///   `.playAndRecord` for the take (the editor keeps playing the recording
///   while the narrator speaks over it, as on the Mac), and switched back to
///   the category it found when the take stops.
enum VoiceOverMic {
    static func makeRecorder(url: URL, settings: [String: Any]) throws -> VoiceOverCapture {
        #if canImport(AppKit)
        return try AVAudioRecorder(url: url, settings: settings)
        #else
        return try SessionRecorder(url: url, settings: settings)
        #endif
    }

    #if !canImport(AppKit)
    /// `AVAudioRecorder` that owns the audio session for the take.
    @MainActor
    private final class SessionRecorder: VoiceOverCapture {
        private let recorder: AVAudioRecorder
        private var restore: (category: AVAudioSession.Category, mode: AVAudioSession.Mode,
                              options: AVAudioSession.CategoryOptions)?

        init(url: URL, settings: [String: Any]) throws {
            let session = AVAudioSession.sharedInstance()
            let previous = (session.category, session.mode, session.categoryOptions)
            do {
                // Speaker, not the receiver: the narrator hears the recording.
                try session.setCategory(.playAndRecord, mode: .default,
                                        options: [.defaultToSpeaker, .allowBluetoothHFP])
                try session.setActive(true)
                recorder = try AVAudioRecorder(url: url, settings: settings)
            } catch {
                try? session.setCategory(previous.0, mode: previous.1, options: previous.2)
                throw error
            }
            restore = previous
        }

        var isRecording: Bool { recorder.isRecording }
        var currentTime: TimeInterval { recorder.currentTime }
        var isMeteringEnabled: Bool {
            get { recorder.isMeteringEnabled }
            set { recorder.isMeteringEnabled = newValue }
        }
        @discardableResult func prepareToRecord() -> Bool { recorder.prepareToRecord() }
        func record() -> Bool { recorder.record() }
        func updateMeters() { recorder.updateMeters() }
        func averagePower(forChannel channelNumber: Int) -> Float { recorder.averagePower(forChannel: channelNumber) }

        func stop() {
            recorder.stop()
            guard let restore else { return }
            self.restore = nil
            try? AVAudioSession.sharedInstance().setCategory(restore.category, mode: restore.mode,
                                                             options: restore.options)
        }
    }
    #endif
}
