import Foundation

enum RecordingPhase: Sendable, Equatable {
    case idle
    case preparing
    case recording
    case paused
    case stopping
    case finished(URL)
    case failed(String)
}

@Observable
final class RecordingSession {
    var phase: RecordingPhase = .idle
    var elapsedTime: TimeInterval = 0
    var isMicEnabled = true
    var isCameraEnabled = false
    /// Opt-in: record shortcut identity (⌘⇧S etc.) for the on-screen overlay.
    /// Sticky across sessions — it's a privacy stance, not a per-take whim.
    var isShortcutCaptureEnabled = UserDefaults.standard.bool(forKey: "captureShortcutOverlay") {
        didSet { UserDefaults.standard.set(isShortcutCaptureEnabled, forKey: "captureShortcutOverlay") }
    }
    var isPaused: Bool { if case .paused = phase { return true } else { return false } }
    var isRecording: Bool { if case .recording = phase { return true } else { return false } }

    /// Maximum RECORDED duration for the take, or nil for no limit. Elapsed
    /// time already excludes paused wall time (`pauseAccumulated` bookkeeping
    /// below), so the limit naturally applies to recorded time, not wall time.
    var durationLimit: TimeInterval?
    /// Fired ONCE on the main actor when `elapsedTime` reaches
    /// `durationLimit`. AppState points this at `stopRecordingInProgress()` —
    /// the identical path the stop button takes; no forked shutdown logic.
    var onDurationLimitReached: (() -> Void)?

    private var timerTask: Task<Void, Never>?
    private var pauseAccumulated: TimeInterval = 0
    private var lastResumeDate: Date?
    private var didFireDurationLimit = false

    func startTimer() {
        elapsedTime = 0
        pauseAccumulated = 0
        didFireDurationLimit = false
        lastResumeDate = Date()
        timerTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let resumeDate = self.lastResumeDate else { continue }
                if case .recording = self.phase {
                    self.elapsedTime = self.pauseAccumulated + Date().timeIntervalSince(resumeDate)
                    self.enforceDurationLimit()
                }
            }
        }
    }

    private func enforceDurationLimit() {
        guard let limit = durationLimit, limit > 0,
              !didFireDurationLimit, elapsedTime >= limit else { return }
        didFireDurationLimit = true
        // Clamp so the timer never displays past the limit while stop lands.
        elapsedTime = limit
        onDurationLimitReached?()
    }

    func pause() {
        guard case .recording = phase else { return }
        if let resumeDate = lastResumeDate {
            pauseAccumulated += Date().timeIntervalSince(resumeDate)
        }
        lastResumeDate = nil
        phase = .paused
    }

    func resume() {
        guard case .paused = phase else { return }
        lastResumeDate = Date()
        phase = .recording
    }

    func stop() {
        timerTask?.cancel()
        timerTask = nil
        if case .recording = phase, let resumeDate = lastResumeDate {
            pauseAccumulated += Date().timeIntervalSince(resumeDate)
            elapsedTime = pauseAccumulated
        }
    }

    func reset() {
        timerTask?.cancel()
        timerTask = nil
        phase = .idle
        elapsedTime = 0
        pauseAccumulated = 0
        lastResumeDate = nil
        isCameraEnabled = false
    }

    func resetElapsedTimer() {
        elapsedTime = 0
        pauseAccumulated = 0
        didFireDurationLimit = false
        if case .recording = phase {
            lastResumeDate = Date()
        }
    }
}
