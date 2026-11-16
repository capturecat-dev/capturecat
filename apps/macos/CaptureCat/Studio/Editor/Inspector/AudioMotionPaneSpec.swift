import Foundation

/// Audio tab — three volume pills, each with a live speaker icon that flips
/// to its muted variant at 0. Moved from AudioSettingsPaneAppKit.
@MainActor
enum AudioPane {
    /// A volume row: the slider plus its on/off icons.
    struct Volume {
        let slider: InspectorSlider
        let onIcon: String
        let offIcon: String

        func symbol(for value: Double) -> String { value > 0 ? onIcon : offIcon }
    }

    static let system = Volume(
        slider: InspectorSlider(
            id: "audio.system", title: "System Audio", range: 0...1, step: 0.05,
            format: InspectorFormat.percent,
            read: { $0.settings.systemAudioVolume }, write: { $0.settings.systemAudioVolume = $1 }),
        onIcon: "speaker.wave.2", offIcon: "speaker.slash")
    static let microphone = Volume(
        slider: InspectorSlider(
            id: "audio.microphone", title: "Microphone", range: 0...1, step: 0.05,
            format: InspectorFormat.percent,
            read: { $0.settings.microphoneVolume }, write: { $0.settings.microphoneVolume = $1 }),
        onIcon: "mic", offIcon: "mic.slash")
    static let voiceOver = Volume(
        slider: InspectorSlider(
            id: "audio.voiceOver", title: "Voice Over", range: 0...1.5, step: 0.05,
            format: InspectorFormat.percent,
            read: { $0.settings.voiceOverVolume }, write: { $0.settings.voiceOverVolume = $1 }),
        onIcon: "waveform.and.mic", offIcon: "mic.slash")

    static let volumes = [system, microphone, voiceOver]

    static var sections: [InspectorSection] {
        [
            InspectorSection(id: "audio.section.audio", title: "Audio", rows: volumes.map { .slider($0.slider) }
                + [.feature(.recordVoiceOver, visible: { _ in true })]),
        ]
    }
}

/// Motion tab — HOW animations feel, project-wide: transition speed (with
/// its live pad), the default auto-zoom level and camera follow speed.
/// Moved from MotionFeelPaneAppKit.
@MainActor
enum MotionFeelPane {
    static let speed = InspectorChoice(
        id: "motion.speed", title: "Motion", style: .chips,
        items: ProjectSettings.AnimationSpeed.allCases.map(\.rawValue),
        read: { ProjectSettings.AnimationSpeed.allCases.firstIndex(of: $0.settings.animationSpeed) ?? 1 },
        write: { $0.settings.animationSpeed = ProjectSettings.AnimationSpeed.allCases[$1] })
    static let speedCaption = InspectorCaption(
        id: "motion.speedCaption", "How quickly zoom and tilt transitions animate.",
        full: "How quickly zoom and tilt transitions animate. Slower feels more cinematic.")
    static let zoomLevel = InspectorSlider(
        id: "motion.zoomLevel", title: "Zoom Level", range: 1.5...4.0, step: 0.1,
        format: InspectorFormat.multiplier1,
        read: { $0.settings.autoZoomLevel }, write: { $0.settings.autoZoomLevel = $1 })
    static let zoomCaption = InspectorCaption(
        id: "motion.zoomCaption", "Default zoom level for auto-generated zoom regions.")
    static let follow = InspectorSlider(
        id: "motion.follow", title: "Follow Speed", range: 0...1, step: 0.05,
        format: InspectorFormat.percent,
        read: { $0.settings.cameraFollowSpeed }, write: { $0.settings.cameraFollowSpeed = $1 })
    static let followCaption = InspectorCaption(
        id: "motion.followCaption", "How quickly the zoomed camera chases the cursor.",
        full: "How quickly the zoomed camera chases the cursor — slower feels weightier.")

    static var sections: [InspectorSection] {
        [
            InspectorSection(id: "motion.section.motion", title: "Motion", rows: [
                .choice(speed), .custom(id: "motion.speedPad", visible: { _ in true }), .caption(speedCaption),
                .slider(zoomLevel), .caption(zoomCaption),
                .feature(.autoZoom, visible: { _ in true }),
                .slider(follow), .caption(followCaption),
            ]),
        ]
    }
}
