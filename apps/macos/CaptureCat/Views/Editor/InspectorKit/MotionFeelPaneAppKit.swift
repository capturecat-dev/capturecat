import AppKit

/// The Motion tab — HOW animations feel, project-wide: transition speed
/// (with its live pad) and the default auto-zoom level. Effects themselves
/// live in the Effects tab.
@MainActor
final class MotionFeelPaneAppKit: NSView {
    private let settings: ProjectSettings
    private let stack = NSStackView()

    private let speedChips = InspectorChipsControl()
    private let speedPad = MotionSpeedPadControl()
    private let speedCaption = InspectorKitViews.captionLine(
        "How quickly zoom and tilt transitions animate.",
        full: "How quickly zoom and tilt transitions animate. Slower feels more cinematic."
    )
    private let zoomLevelSlider = InspectorSliderRow(label: "Zoom Level", range: 1.5...4.0, step: 0.1)
    private let zoomCaption = InspectorKitViews.captionLine(
        "Default zoom level for auto-generated zoom regions."
    )
    private let followSlider = InspectorSliderRow(label: "Follow Speed", range: 0...1, step: 0.05)
    private let followCaption = InspectorKitViews.captionLine(
        "How quickly the zoomed camera chases the cursor.",
        full: "How quickly the zoomed camera chases the cursor — slower feels weightier."
    )

    override var isFlipped: Bool { true }

    init(settings: ProjectSettings) {
        self.settings = settings
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

        func fullWidth(_ view: NSView) {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let motionBox = InspectorSectionBox("Motion")
        speedChips.items = ProjectSettings.AnimationSpeed.allCases.map(\.rawValue)
        motionBox.addRow(speedChips)
        motionBox.addRow(speedPad, attached: true)
        speedPad.heightAnchor.constraint(equalToConstant: 84).isActive = true
        motionBox.addRow(speedCaption, attached: true)
        zoomLevelSlider.format = { String(format: "%.1fx", $0) }
        motionBox.addRow(zoomLevelSlider)
        motionBox.addRow(zoomCaption, attached: true)
        followSlider.format = { "\(Int(($0 * 100).rounded()))%" }
        motionBox.addRow(followSlider)
        motionBox.addRow(followCaption, attached: true)
        fullWidth(motionBox)

        speedChips.onSelect = { [weak self] index in
            self?.settings.animationSpeed = ProjectSettings.AnimationSpeed.allCases[index]
        }
        zoomLevelSlider.onChange = { [weak self] v in self?.settings.autoZoomLevel = v }
        followSlider.onChange = { [weak self] v in self?.settings.cameraFollowSpeed = v }

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
        speedChips.selectedIndex = ProjectSettings.AnimationSpeed.allCases
            .firstIndex(of: settings.animationSpeed) ?? 1
        speedPad.duration = settings.animationSpeed.duration
        zoomLevelSlider.setValue(settings.autoZoomLevel)
        followSlider.setValue(settings.cameraFollowSpeed)
    }
}
