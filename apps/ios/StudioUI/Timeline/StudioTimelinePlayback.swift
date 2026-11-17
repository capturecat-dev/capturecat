import Foundation
import Observation

/// The playhead and transport the touch timeline reads and drives — the
/// editor shell supplies the real player (session 4b); standalone and in the
/// harness, `StudioTimelinePlayhead` stands in. Times are SOURCE seconds.
/// Conforming types should be `@Observable`: the timeline re-renders from an
/// observation loop that reads these properties.
@MainActor
protocol StudioTimelinePlayback: AnyObject {
    var currentTime: TimeInterval { get set }
    var isPlaying: Bool { get set }
    /// A player is loaded (the play key and space bar do nothing without one).
    var canPlay: Bool { get }
    var isRecordingVoiceOver: Bool { get }
    var voiceOverRecordingStartTime: TimeInterval? { get }
    var liveVoiceOverSamples: [Float] { get }
    /// Move the playhead: `exact: false` while scrubbing, `true` on release
    /// (clamped into the project's trim window; scrubbing pauses playback).
    func scrub(to sourceTime: TimeInterval, for project: Project, exact: Bool)
    /// Frame-exact jump (selecting an off-screen annotation, Home/End).
    func seek(to sourceTime: TimeInterval)
    /// Called once per display refresh while playing, right after the
    /// playhead advanced (the centred playhead's follow); nil = no player.
    var onDisplayTick: (() -> Void)? { get set }
}

/// A bare playhead with no player — the timeline on its own, and the gate.
@MainActor
@Observable
final class StudioTimelinePlayhead: StudioTimelinePlayback {
    var currentTime: TimeInterval = 0
    var isPlaying = false
    var canPlay: Bool { false }
    var isRecordingVoiceOver = false
    var voiceOverRecordingStartTime: TimeInterval?
    var liveVoiceOverSamples: [Float] = []
    @ObservationIgnored var onDisplayTick: (() -> Void)?

    init() {}

    func scrub(to sourceTime: TimeInterval, for project: Project, exact: Bool) {
        if isPlaying { isPlaying = false }
        currentTime = min(max(sourceTime, project.effectiveTrimStart), project.effectiveTrimEnd)
    }
    func seek(to sourceTime: TimeInterval) { currentTime = sourceTime }
}
