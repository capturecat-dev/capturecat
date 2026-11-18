import AppKit

/// The Motion tab — HOW animations feel, project-wide: transition speed
/// (with its live pad) and the default auto-zoom level. Effects themselves
/// live in the Effects tab.
@MainActor
final class MotionFeelPaneAppKit: NSView {
    private let settings: ProjectSettings
    private let stack = NSStackView()

    // Controls and copy: the shared MotionFeelPane spec.
    private let speedChips = InspectorChipsControl(MotionFeelPane.speed)
    private let speedPad = MotionSpeedPadControl()
    private let speedCaption = InspectorKitViews.captionLine(MotionFeelPane.speedCaption)
    private let zoomLevelSlider = InspectorSliderRow(MotionFeelPane.zoomLevel)
    private let zoomCaption = InspectorKitViews.captionLine(MotionFeelPane.zoomCaption)
    private let followSlider = InspectorSliderRow(MotionFeelPane.follow)
    private let followCaption = InspectorKitViews.captionLine(MotionFeelPane.followCaption)

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
        motionBox.addRow(speedChips)
        motionBox.addRow(speedPad, attached: true)
        speedPad.heightAnchor.constraint(equalToConstant: 84).isActive = true
        speedPad.inspectorSpecID = "motion.speedPad"
        motionBox.addRow(speedCaption, attached: true)
        motionBox.addRow(zoomLevelSlider)
        motionBox.addRow(zoomCaption, attached: true)
        motionBox.addRow(followSlider)
        motionBox.addRow(followCaption, attached: true)
        fullWidth(motionBox)

        let scope: () -> InspectorScope? = { [weak self] in self?.scope }
        speedChips.bind(MotionFeelPane.speed, scope)
        zoomLevelSlider.bind(MotionFeelPane.zoomLevel, scope)
        followSlider.bind(MotionFeelPane.follow, scope)

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
        let scope = self.scope
        speedChips.selectedIndex = MotionFeelPane.speed.read(scope) ?? 1
        speedPad.duration = settings.animationSpeed.duration
        zoomLevelSlider.setValue(MotionFeelPane.zoomLevel.read(scope))
        followSlider.setValue(MotionFeelPane.follow.read(scope))
    }
}
