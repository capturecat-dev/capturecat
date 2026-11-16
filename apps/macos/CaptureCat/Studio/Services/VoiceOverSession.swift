import AVFoundation
import Foundation
import Observation
import OSLog

#if DEBUG
private let voiceOverSessionLogger = Logger(subsystem: "so.capturecat.CaptureCat", category: "VoiceOverEditor")
#endif

/// Where a voice-over take lands — pure, shared by every recorder front end
/// (the Mac editor's playback controller, the iOS voice-over sheet, the gate).
enum VoiceOverTake {
    /// The take's file, beside the recording in the project folder.
    static func newFileURL(in project: Project) -> URL {
        project.projectDirectory.appendingPathComponent("voiceover-\(UUID().uuidString).m4a")
    }

    /// The playhead clamped into the trim window — where the clip starts
    /// (SOURCE time, like every clip in `project.voiceOverClips`).
    static func startTime(currentTime: Double, project: Project) -> Double {
        min(max(currentTime, project.effectiveTrimStart), project.effectiveTrimEnd)
    }

    /// The clip a finished take becomes, or nil when it is too short to keep
    /// (≤ 0.1 s once clamped to the recording's end).
    static func clip(fileName: String, clipStart: Double, finalizedDuration: Double,
                     project: Project) -> VoiceOverClip? {
        let clipDuration = min(finalizedDuration, max(0.1, project.duration - clipStart))
        guard clipDuration > 0.1 else { return nil }
        return VoiceOverClip(
            fileName: fileName,
            startTime: clipStart,
            duration: clipDuration,
            sourceDuration: finalizedDuration
        )
    }
}

/// One voice-over take from start to clip — the engine the Mac editor ran
/// inside `EditorPlaybackController` until Studio 4e, moved here verbatim so
/// the iOS studio records with the same code: permission, file, start-time
/// clamp, recorder, the 45 ms level meter (last 240 samples, what the VOICE
/// row draws while recording), the wait for the encoder to finalize the
/// file, and the clip appended to `project.voiceOverClips`.
///
/// What stays with each front end: playback (both start the player when a
/// take starts), the Mac's voice-refresh debounce, error presentation, and
/// undo (the Mac registers none for a recorded take; iOS registers one).
@MainActor
@Observable
final class VoiceOverSession {
    private(set) var isRecording = false
    /// The clip's start (SOURCE seconds) while recording.
    private(set) var recordingStartTime: Double?
    /// Recent meter levels, 0…1, one per 45 ms.
    private(set) var liveSamples: [Float] = []

    @ObservationIgnored let recorder = VoiceOverRecorder()
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    /// Called after each meter sample (the Mac's observer counter).
    @ObservationIgnored var onMeterSample: (() -> Void)?
    /// Microphone permission. A seam for the gate, whose synthetic capture
    /// never touches a microphone.
    @ObservationIgnored var requestPermission: () async throws -> Void = VoiceOverSession.ensureMicrophonePermission

    init() {}

    /// Permission and the project folder — before anything else changes.
    func prepare(for project: Project) async throws {
        try await requestPermission()
        try FileManager.default.createDirectory(at: project.projectDirectory, withIntermediateDirectories: true)
    }

    /// Starts recording at the (clamped) playhead. On a throw nothing changed
    /// but the recorder; call `abort()` to reset the published state.
    @discardableResult
    func begin(for project: Project, currentTime: Double) throws -> URL {
        let outputURL = VoiceOverTake.newFileURL(in: project)
        let recordingStart = VoiceOverTake.startTime(currentTime: currentTime, project: project)

        try recorder.startRecording(to: outputURL)
        recordingStartTime = recordingStart
        liveSamples = []
        isRecording = true
        startMetering()
#if DEBUG
        voiceOverSessionLogger.debug("begin start=\(recordingStart, privacy: .public) file=\(outputURL.lastPathComponent, privacy: .public)")
#endif
        return outputURL
    }

    /// A failed start: back to idle.
    func abort() {
        recordingStartTime = nil
        liveSamples = []
        isRecording = false
        meterTask?.cancel()
        meterTask = nil
    }

    /// Stops the take and, unless discarded or too short, appends its clip to
    /// `project.voiceOverClips` and returns it. `fallbackStart` is used only
    /// if the start time is somehow missing (the Mac passed its playhead).
    @discardableResult
    func finish(for project: Project, discard: Bool, fallbackStart: Double) async -> VoiceOverClip? {
        guard isRecording else { return nil }

        let clipStart = recordingStartTime ?? fallbackStart
        let result = recorder.stopRecording(discard: discard)
#if DEBUG
        voiceOverSessionLogger.debug("stop requested discard=\(discard, privacy: .public) clipStart=\(clipStart, privacy: .public) resultExists=\(result != nil, privacy: .public)")
#endif
        isRecording = false
        recordingStartTime = nil
        meterTask?.cancel()
        meterTask = nil
        liveSamples = []

        guard let result else { return nil }
        let finalizedDuration = await Self.waitForFileReady(
            at: result.fileURL,
            fallbackDuration: result.duration
        ) ?? result.duration
#if DEBUG
        voiceOverSessionLogger.debug("file ready file=\(result.fileURL.lastPathComponent, privacy: .public) fallback=\(result.duration, privacy: .public) finalized=\(finalizedDuration, privacy: .public)")
#endif
        if let clip = VoiceOverTake.clip(fileName: result.fileURL.lastPathComponent, clipStart: clipStart,
                                         finalizedDuration: finalizedDuration, project: project) {
            project.voiceOverClips.append(clip)
#if DEBUG
            voiceOverSessionLogger.debug("clip appended id=\(clip.id.uuidString, privacy: .public) start=\(clip.startTime, privacy: .public) duration=\(clip.duration, privacy: .public) sourceDuration=\(clip.sourceDuration, privacy: .public)")
#endif
            return clip
        }
        try? FileManager.default.removeItem(at: result.fileURL)
#if DEBUG
        voiceOverSessionLogger.debug("clip dropped finalized=\(finalizedDuration, privacy: .public) file=\(result.fileURL.lastPathComponent, privacy: .public)")
#endif
        return nil
    }

    /// Stops the meter loop (teardown runs this first).
    func stopMetering() {
        meterTask?.cancel()
        meterTask = nil
    }

    /// Teardown mid-take: the take is discarded, nothing is appended.
    func discardIfRecording() {
        guard isRecording else { return }
        _ = recorder.stopRecording(discard: true)
        isRecording = false
        recordingStartTime = nil
        liveSamples = []
    }

    private func startMetering() {
        meterTask?.cancel()
        meterTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.isRecording {
                self.liveSamples.append(self.recorder.currentMeterLevel())
                self.onMeterSample?()
                if self.liveSamples.count > 240 {
                    self.liveSamples.removeFirst(self.liveSamples.count - 240)
                }
                try? await Task.sleep(for: .milliseconds(45))
            }
        }
    }

    // MARK: - File and permission

    private static func waitForFileReady(
        at fileURL: URL,
        fallbackDuration: TimeInterval
    ) async -> TimeInterval? {
        for _ in 0..<10 {
            if let duration = measuredDuration(at: fileURL), duration > 0.1 {
                return duration
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        return fallbackDuration > 0.1 ? fallbackDuration : measuredDuration(at: fileURL)
    }

    static func measuredDuration(at fileURL: URL) -> TimeInterval? {
        guard let audioFile = try? AVAudioFile(forReading: fileURL) else {
            return nil
        }

        let sampleRate = audioFile.processingFormat.sampleRate
        guard sampleRate > 0 else {
            return nil
        }

        let duration = Double(audioFile.length) / sampleRate
        return duration.isFinite && duration > 0 ? duration : nil
    }

    static func ensureMicrophonePermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else {
                throw NSError(domain: "VoiceOverRecorder", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Microphone access is required to record a voice over."
                ])
            }
        default:
            throw NSError(domain: "VoiceOverRecorder", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Microphone access is required to record a voice over."
            ])
        }
    }
}
