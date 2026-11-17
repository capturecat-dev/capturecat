import Foundation

/// The editor's playback as the timeline sees it (`StudioTimelinePlayback`).
///
/// The timeline pauses by setting `isPlaying` and moves the playhead by
/// setting `currentTime`, the Mac timeline's vocabulary. On
/// `StudioPlaybackController` those are plain stored values: setting them
/// alone would leave the players running, or parked on the old frame. This
/// routes every write through the controller's own play / scrub paths, the
/// ones the transport uses. Reads come straight from the controller, which is
/// `@Observable`, so the timeline's observation loop re-arms on them.
@available(iOS 26, *)
@MainActor
final class EditorTimelinePlayback: StudioTimelinePlayback {
    private let playback: StudioPlaybackController
    private let project: () -> Project

    init(playback: StudioPlaybackController, project: @escaping () -> Project) {
        self.playback = playback
        self.project = project
    }

    var currentTime: TimeInterval {
        get { playback.currentTime }
        set { playback.scrub(to: newValue, for: project(), exact: true) }
    }

    var isPlaying: Bool {
        get { playback.isPlaying }
        set {
            guard newValue != playback.isPlaying else { return }
            playback.setPlaying(newValue, for: project())
        }
    }

    var canPlay: Bool { playback.player != nil }

    var onDisplayTick: (() -> Void)? {
        get { playback.onDisplayTick }
        set { playback.onDisplayTick = newValue }
    }

    /// Voice-over recording state (Studio 4e forwards these to its session).
    var isRecordingVoiceOver: Bool { voiceOverState?().isRecording ?? false }
    var voiceOverRecordingStartTime: TimeInterval? { voiceOverState?().startTime }
    var liveVoiceOverSamples: [Float] { voiceOverState?().samples ?? [] }
    var voiceOverState: (() -> (isRecording: Bool, startTime: TimeInterval?, samples: [Float]))?

    func scrub(to sourceTime: TimeInterval, for project: Project, exact: Bool) {
        playback.scrub(to: sourceTime, for: project, exact: exact)
    }

    func seek(to sourceTime: TimeInterval) {
        playback.scrub(to: sourceTime, for: project(), exact: true)
    }
}
