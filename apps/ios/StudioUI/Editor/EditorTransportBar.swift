import UIKit

/// The editor's ONE transport row (the editor redesign):
///
///     [ 0:06.50 / 0:20.00 ]      [ ‹ ]  [ ▶ ]  [ › ]      [ ⤢ ]
///
/// the playhead time (VoiceOver's adjustable playhead — swipe up / down
/// moves a second; ← / → with a keyboard), frame step · play/pause · frame
/// step centred on the row, and the full-screen preview key. There is no
/// scrubber: the timeline under it IS the scrubber (its playhead is fixed at
/// the centre and dragging the content scrubs). Times are OUTPUT seconds
/// (after trim and speed, through the shared `SpeedTimeMap`); the playhead
/// itself stays in SOURCE seconds (the playback controller).
final class EditorTransportBar: UIView {
    var onTogglePlay: (() -> Void)?
    var onStep: ((Int) -> Void)?
    /// Move to an OUTPUT time (the readout's adjust: exact).
    var onScrub: ((TimeInterval, Bool) -> Void)?
    /// The full-screen preview key.
    var onToggleExpanded: (() -> Void)?

    let playButton = CCButton(symbol: "play-fill", style: .primary, size: .regular, radius: .full)
    let backButton = CCButton(symbol: "chevron-left", style: .ghost, size: .regular, radius: .full)
    let forwardButton = CCButton(symbol: "chevron-right", style: .ghost, size: .regular, radius: .full)
    let expandButton = CCButton(symbol: "display", style: .ghost, size: .regular, radius: .full)
    /// The time readout, VoiceOver's adjustable playhead.
    let playhead = EditorPlayheadReadout()

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        accessibilityIdentifier = "studio.transport"
        playButton.accessibilityLabelOverride = "Play"
        playButton.accessibilityIdentifier = "studio.play"
        backButton.accessibilityLabelOverride = "Previous frame"
        forwardButton.accessibilityLabelOverride = "Next frame"
        expandButton.accessibilityIdentifier = "studio.expand"
        setExpanded(false)
        playButton.onTap = { [weak self] in self?.onTogglePlay?() }
        backButton.onTap = { [weak self] in self?.onStep?(-1) }
        forwardButton.onTap = { [weak self] in self?.onStep?(1) }
        expandButton.onTap = { [weak self] in self?.onToggleExpanded?() }
        playhead.onScrub = { [weak self] t in self?.onScrub?(t, true) }
        // Play starts media (VoiceOver goes quiet).
        playButton.accessibilityTraits = [.button, .startsMediaSession]
        playButton.accessibilityHint = "Plays or pauses the recording."
        backButton.accessibilityHint = "Steps the playhead back one frame."
        forwardButton.accessibilityHint = "Steps the playhead forward one frame."

        let group = UIStackView(arrangedSubviews: [backButton, playButton, forwardButton])
        group.spacing = CCSpace.xs
        group.alignment = .center
        for v in [playhead, group, expandButton] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        let centred = group.centerXAnchor.constraint(equalTo: centerXAnchor)
        centred.priority = .defaultHigh
        playhead.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            playhead.leadingAnchor.constraint(equalTo: leadingAnchor),
            playhead.centerYAnchor.constraint(equalTo: centerYAnchor),
            playhead.heightAnchor.constraint(equalToConstant: 44),
            group.centerYAnchor.constraint(equalTo: centerYAnchor),
            centred,
            group.leadingAnchor.constraint(greaterThanOrEqualTo: playhead.trailingAnchor, constant: CCSpace.xs),
            expandButton.leadingAnchor.constraint(greaterThanOrEqualTo: group.trailingAnchor, constant: CCSpace.xs),
            expandButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            expandButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            playButton.widthAnchor.constraint(equalTo: playButton.heightAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(isPlaying: Bool, outputTime: TimeInterval, outputDuration: TimeInterval) {
        let symbol = isPlaying ? "pause-fill" : "play-fill"
        if playButton.symbol != symbol { playButton.symbol = symbol }
        let label = isPlaying ? "Pause" : "Play"
        if playButton.accessibilityLabelOverride != label {
            playButton.accessibilityLabelOverride = label
            playButton.accessibilityTraits = [.button, .startsMediaSession]
        }
        playhead.update(value: outputTime, duration: outputDuration)
    }

    /// The full-screen key's face: expand, or return to the editor.
    func setExpanded(_ expanded: Bool) {
        expandButton.symbol = expanded ? "arrow.down.right.and.arrow.up.left" : "display"
        expandButton.accessibilityLabelOverride = expanded ? "Exit full-screen preview" : "Full-screen preview"
        expandButton.accessibilityHint = expanded ? "Shows the timeline and tools again." : "Hides the timeline and tools; the preview takes the screen."
    }

    /// m:ss.cc (output time).
    static func format(_ t: TimeInterval) -> String {
        let clamped = max(0, t.isFinite ? t : 0)
        let centis = Int((clamped * 100).rounded(.down))
        return String(format: "%d:%02d.%02d", centis / 6000, (centis / 100) % 60, centis % 100)
    }
}

/// "0:06.50 / 0:20.00" — the playhead time, and VoiceOver's adjustable
/// playhead ("6.5 seconds of 20 seconds"; swipe up / down moves a second).
/// Focusable with a keyboard (← / → move a second, as VoiceOver's swipes).
final class EditorPlayheadReadout: UIControl {
    var onScrub: ((TimeInterval) -> Void)?

    private let current = ccLabel("0:00.00", font: CCFont.mono, color: CCTheme.color.foreground)
    private let total = ccLabel("/ 0:00.00", font: CCFont.monoSmall, color: CCTheme.color.mutedForeground)
    private(set) var value: TimeInterval = 0
    private(set) var duration: TimeInterval = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "studio.time"
        isAccessibilityElement = true
        accessibilityTraits = [.adjustable, .updatesFrequently]
        accessibilityLabel = "Playhead"
        accessibilityHint = "Swipe up or down to move a second."
        for label in [current, total] {
            label.adjustsFontForContentSizeCategory = true
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            label.setContentHuggingPriority(.required, for: .horizontal)
        }
        let row = UIStackView(arrangedSubviews: [current, total])
        row.spacing = 4
        row.alignment = .firstBaseline
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(value: TimeInterval, duration: TimeInterval) {
        self.value = value
        self.duration = duration
        let text = EditorTransportBar.format(value)
        if current.text != text { current.text = text }
        let totalText = "/ " + EditorTransportBar.format(duration)
        if total.text != totalText { total.text = totalText }
        accessibilityValue = Self.spoken(value, of: duration)
    }

    /// "6.5 seconds of 20 seconds" — what VoiceOver says for the playhead.
    static func spoken(_ value: TimeInterval, of duration: TimeInterval) -> String {
        "\(CCAccessibility.spokenTime(value)) of \(CCAccessibility.spokenTime(duration))"
    }

    override var canBecomeFocused: Bool { !isHidden }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if let step = ccArrowStep(presses) {
            if step > 0 { accessibilityIncrement() } else { accessibilityDecrement() }
            return
        }
        super.pressesBegan(presses, with: event)
    }

    private func scrub(to t: TimeInterval) {
        value = t
        accessibilityValue = Self.spoken(t, of: duration)
        onScrub?(t)
    }

    override func accessibilityIncrement() { scrub(to: min(duration, value + 1)) }
    override func accessibilityDecrement() { scrub(to: max(0, value - 1)) }
}
