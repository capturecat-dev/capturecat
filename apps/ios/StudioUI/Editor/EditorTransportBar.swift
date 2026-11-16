import UIKit

/// The editor's transport: step back · play/pause · step forward, a scrubber
/// over the OUTPUT timeline (after trim and speed, the length the export
/// will have) and the time readout. Times convert through the shared
/// `SpeedTimeMap`; the playhead itself stays in SOURCE seconds (the
/// playback controller), like everything the edit tools write.
///
/// TODO(4a): swap `EditorScrubber` for the kit's scrubber/slider when Kit/
/// gains one; it is dressed with the kit's materials meanwhile.
final class EditorTransportBar: UIView {
    var onTogglePlay: (() -> Void)?
    var onStep: ((Int) -> Void)?
    /// Scrub to an OUTPUT time; `exact` on release.
    var onScrub: ((TimeInterval, Bool) -> Void)?

    let playButton = CCButton(symbol: "play-fill", style: .primary, size: .regular, radius: .full)
    let backButton = CCButton(symbol: "chevron-left", style: .ghost, size: .regular, radius: .full)
    let forwardButton = CCButton(symbol: "chevron-right", style: .ghost, size: .regular, radius: .full)
    let scrubber = EditorScrubber()
    let timeLabel = ccLabel("0:00.00 / 0:00.00", font: CCFont.monoSmall, color: CCTheme.color.mutedForeground)

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        playButton.accessibilityLabelOverride = "Play"
        playButton.accessibilityIdentifier = "studio.play"
        backButton.accessibilityLabelOverride = "Previous frame"
        forwardButton.accessibilityLabelOverride = "Next frame"
        playButton.onTap = { [weak self] in self?.onTogglePlay?() }
        backButton.onTap = { [weak self] in self?.onStep?(-1) }
        forwardButton.onTap = { [weak self] in self?.onStep?(1) }
        scrubber.onScrub = { [weak self] t, exact in self?.onScrub?(t, exact) }
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        timeLabel.accessibilityIdentifier = "studio.time"

        let row = UIStackView(arrangedSubviews: [backButton, playButton, forwardButton, scrubber, timeLabel])
        row.spacing = CCSpace.sm
        row.setCustomSpacing(CCSpace.md, after: forwardButton)
        row.setCustomSpacing(CCSpace.md, after: scrubber)
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            playButton.widthAnchor.constraint(equalTo: playButton.heightAnchor),
            scrubber.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(isPlaying: Bool, outputTime: TimeInterval, outputDuration: TimeInterval) {
        playButton.symbol = isPlaying ? "pause-fill" : "play-fill"
        playButton.accessibilityLabelOverride = isPlaying ? "Pause" : "Play"
        scrubber.update(value: outputTime, duration: outputDuration)
        timeLabel.text = "\(Self.format(outputTime)) / \(Self.format(outputDuration))"
    }

    /// m:ss.cc (output time).
    static func format(_ t: TimeInterval) -> String {
        let clamped = max(0, t.isFinite ? t : 0)
        let centis = Int((clamped * 100).rounded(.down))
        return String(format: "%d:%02d.%02d", centis / 6000, (centis / 100) % 60, centis % 100)
    }
}

/// A recessed track with a raised knob; drag or tap anywhere to scrub.
final class EditorScrubber: UIControl {
    var onScrub: ((TimeInterval, Bool) -> Void)?

    private let track = CCSurface(.recessed, tint: CCTheme.color.elevated, radius: .full)
    private let fill = UIView()
    private let knob = CCSurface(.raised, tint: .white, radius: .full)
    private var value: TimeInterval = 0
    private var duration: TimeInterval = 0
    private(set) var isTracking_ = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        accessibilityIdentifier = "studio.scrubber"
        isAccessibilityElement = true
        accessibilityTraits = .adjustable
        accessibilityLabel = "Playhead"
        track.isUserInteractionEnabled = false
        fill.isUserInteractionEnabled = false
        knob.isUserInteractionEnabled = false
        fill.backgroundColor = CCTheme.color.primary
        fill.layer.cornerCurve = .continuous
        addSubview(track)
        track.addSubview(fill)
        addSubview(knob)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h: CGFloat = 6
        track.frame = CGRect(x: 0, y: (bounds.height - h) / 2, width: bounds.width, height: h)
        let f = duration > 0 ? CGFloat(min(1, max(0, value / duration))) : 0
        fill.frame = CGRect(x: 0, y: 0, width: bounds.width * f, height: h)
        fill.layer.cornerRadius = h / 2
        let k: CGFloat = 18
        knob.frame = CGRect(x: f * (bounds.width - k), y: (bounds.height - k) / 2, width: k, height: k)
    }

    func update(value: TimeInterval, duration: TimeInterval) {
        guard !isTracking_ else { return }
        self.value = value
        self.duration = duration
        accessibilityValue = EditorTransportBar.format(value)
        setNeedsLayout()
    }

    private func time(at x: CGFloat) -> TimeInterval {
        guard duration > 0, bounds.width > 18 else { return 0 }
        let f = min(1, max(0, (x - 9) / (bounds.width - 18)))
        return Double(f) * duration
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        isTracking_ = true
        scrub(to: time(at: touch.location(in: self).x), exact: false)
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        scrub(to: time(at: touch.location(in: self).x), exact: false)
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        isTracking_ = false
        scrub(to: touch.map { time(at: $0.location(in: self).x) } ?? value, exact: true)
    }

    override func cancelTracking(with event: UIEvent?) {
        isTracking_ = false
        scrub(to: value, exact: true)
    }

    private func scrub(to t: TimeInterval, exact: Bool) {
        value = t
        setNeedsLayout()
        onScrub?(t, exact)
    }

    override func accessibilityIncrement() { scrub(to: min(duration, value + 1), exact: true) }
    override func accessibilityDecrement() { scrub(to: max(0, value - 1), exact: true) }
}
