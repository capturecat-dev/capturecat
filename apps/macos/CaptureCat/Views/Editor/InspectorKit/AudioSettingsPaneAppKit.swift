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
        // Titles, ranges, steps, readouts and icons: the shared AudioPane spec.
        systemRow = AudioVolumeRow(AudioPane.system)
        micRow = AudioVolumeRow(AudioPane.microphone)
        voiceRow = AudioVolumeRow(AudioPane.voiceOver)
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

        for (row, volume) in [(systemRow, AudioPane.system), (micRow, AudioPane.microphone),
                              (voiceRow, AudioPane.voiceOver)] {
            row.onChange = { [weak self] v in
                guard let self else { return }
                volume.slider.write(self.scope, v)
            }
        }

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

    private var scope: InspectorScope { InspectorScope(settings: settings) }

    private func apply() {
        systemRow.setValue(AudioPane.system.slider.read(scope))
        micRow.setValue(AudioPane.microphone.slider.read(scope))
        voiceRow.setValue(AudioPane.voiceOver.slider.read(scope))
    }
}

/// Volume row — one CCSlider pill: title + live speaker icon inside the
/// track, percent readout trailing (the icon flips to its muted variant at 0).
@MainActor
final class AudioVolumeRow: NSView {
    var onChange: ((Double) -> Void)?

    private let slider = CCSlider()
    private let volume: AudioPane.Volume

    override var isFlipped: Bool { true }

    init(_ volume: AudioPane.Volume) {
        self.volume = volume
        super.init(frame: .zero)
        slider.title = volume.slider.title
        slider.range = volume.slider.range
        slider.step = volume.slider.step
        slider.format = volume.slider.format
        inspectorSpecID = volume.slider.id
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
        slider.symbol = volume.symbol(for: v)
    }
}
