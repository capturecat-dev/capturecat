import AppKit

/// The Audio tab as a native AppKit pane — twin of AudioSettingsView:
/// three volume rows, each "label — icon, track, percent".
@MainActor
final class AudioSettingsPaneAppKit: NSView {
    private let settings: ProjectSettings
    private let stack = NSStackView()

    private let systemRow: AudioVolumeRow
    private let micRow: AudioVolumeRow
    private let voiceRow: AudioVolumeRow

    override var isFlipped: Bool { true }

    init(settings: ProjectSettings) {
        self.settings = settings
        systemRow = AudioVolumeRow(
            label: "System Audio", range: 0...1,
            onIcon: "speaker.wave.2", offIcon: "speaker.slash", valueWidth: 35
        )
        micRow = AudioVolumeRow(
            label: "Microphone", range: 0...1,
            onIcon: "mic", offIcon: "mic.slash", valueWidth: 35
        )
        voiceRow = AudioVolumeRow(
            label: "Voice Over", range: 0...1.5,
            onIcon: "waveform.and.mic", offIcon: "mic.slash", valueWidth: 42
        )
        super.init(frame: .zero)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])

        let audioBox = InspectorSectionBox("Audio")
        for row in [systemRow, micRow, voiceRow] {
            audioBox.addRow(row)
        }
        stack.addArrangedSubview(audioBox)
        audioBox.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        systemRow.onChange = { [weak self] v in self?.settings.systemAudioVolume = v }
        micRow.onChange = { [weak self] v in self?.settings.microphoneVolume = v }
        voiceRow.onChange = { [weak self] v in self?.settings.voiceOverVolume = v }

        observe()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func observe() {
        withObservationTracking { [weak self] in
            self?.apply()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observe()
            }
        }
    }

    private func apply() {
        systemRow.setValue(settings.systemAudioVolume)
        micRow.setValue(settings.microphoneVolume)
        voiceRow.setValue(settings.voiceOverVolume)
    }
}

/// Volume row — one CCSlider pill: title + live speaker icon inside the
/// track, percent readout trailing (the icon flips to its muted variant at 0).
@MainActor
final class AudioVolumeRow: NSView {
    var onChange: ((Double) -> Void)?

    private let slider = CCSlider()
    private let onIcon: String
    private let offIcon: String

    override var isFlipped: Bool { true }

    init(label text: String, range: ClosedRange<Double>, onIcon: String, offIcon: String, valueWidth: CGFloat) {
        self.onIcon = onIcon
        self.offIcon = offIcon
        super.init(frame: .zero)
        slider.title = text
        slider.range = range
        slider.step = 0.05
        slider.format = { "\(Int(($0 * 100).rounded()))%" }
        slider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(slider)
        NSLayoutConstraint.activate([
            slider.leadingAnchor.constraint(equalTo: leadingAnchor),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor),
            slider.topAnchor.constraint(equalTo: topAnchor),
            slider.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        slider.onChange = { [weak self] v in
            self?.refresh(v)
            self?.onChange?(v)
        }
        refresh(slider.doubleValue)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setValue(_ v: Double) {
        slider.doubleValue = v
        refresh(v)
    }

    private func refresh(_ v: Double) {
        slider.symbol = v > 0 ? onIcon : offIcon
    }
}
