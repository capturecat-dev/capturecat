import UIKit

/// The timeline region's toolbar row — the Mac timeline panel's toolbar
/// (`TimelineViewController.toolbar`), at the top of the timeline region:
///
///   ⏮ ▶ ⏭ │ 0:05 / 0:07        ⟲ ⟳ │ 🗑 │ ✨ ◎ ✂ ◫ ✎ │ 🎙 │ ⊖ ━━○━━ ⊕ │ ⤢
///
/// The Mac's icons (the shared icon kit), its compact ghost keys and its
/// timecode type; on a phone the row scrolls sideways. Each key is its own
/// 44 pt target (a ghost key: only the icon draws), side by side, so a key
/// at the row's scrolled edge keeps its whole target. The commands are the timeline's own
/// (the editor wires `onCommand` to `StudioTimelineViewController`), never a
/// fork. Times are OUTPUT seconds (after trim and speed, through the shared
/// `SpeedTimeMap`); the playhead itself stays in SOURCE seconds.
final class EditorTransportBar: UIView {
    enum Command: Equatable {
        case toStart, toEnd, undo, redo, delete, effects, focus, slice, split, annotate, voice, zoomOut, zoomIn
        /// The timeline-zoom slider moved (0…1 along its log scale).
        case scale(Double)
    }

    var onTogglePlay: (() -> Void)?
    var onStep: ((Int) -> Void)?
    /// Move to an OUTPUT time (the readout's adjust: exact).
    var onScrub: ((TimeInterval, Bool) -> Void)?
    /// The full-screen preview key.
    var onToggleExpanded: (() -> Void)?
    /// A timeline command (the key anchors any menu it opens).
    var onCommand: ((Command, UIView) -> Void)?

    let playButton = EditorTransportBar.key("play-fill", "Play")
    let toStartButton = EditorTransportBar.key("backward.end.fill", "Go to Start")
    let toEndButton = EditorTransportBar.key("forward.end.fill", "Go to End")
    let undoButton = EditorTransportBar.key("arrow.uturn.backward", "Undo")
    let redoButton = EditorTransportBar.key("arrow.uturn.forward", "Redo")
    let deleteButton = EditorTransportBar.key("trash", "Delete Selected")
    let effectsButton = EditorTransportBar.key("sparkles", "Effects")
    let focusButton = EditorTransportBar.key("scope", "Focus & Blur")
    let sliceButton = EditorTransportBar.key("scissors", "Slice")
    let splitButton = EditorTransportBar.key("rectangle.split.2x1", "Split at Playhead")
    let annotateButton = EditorTransportBar.key("pencil.tip", "Add Annotation")
    let voiceButton = EditorTransportBar.key("mic.fill", "Record Voice Over")
    let zoomOutButton = EditorTransportBar.key("minus.magnifyingglass", "Zoom Out Timeline")
    let zoomInButton = EditorTransportBar.key("plus.magnifyingglass", "Zoom In Timeline")
    let scaleSlider = EditorScaleSlider()
    let expandButton = EditorTransportBar.key("display", "Full-screen preview")
    /// Kept for the keyboard and VoiceOver (frame steps): hidden keys.
    let backButton = EditorTransportBar.key("chevron-left", "Previous frame")
    let forwardButton = EditorTransportBar.key("chevron-right", "Next frame")
    /// The time readout, VoiceOver's adjustable playhead.
    let playhead = EditorPlayheadReadout()

    private let scroll = UIScrollView()
    private let row = UIStackView()
    private let hairline = UIView()

    /// The row's height (the Mac panel's 42 pt toolbar, at the touch rows' 44).
    static let height: CGFloat = 44

    static func key(_ symbol: String, _ label: String) -> CCButton {
        let b = CCButton(symbol: symbol, style: .ghost, size: .regular, radius: .md)
        b.accessibilityLabelOverride = label
        return b
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        accessibilityIdentifier = "studio.transport"
        playButton.accessibilityIdentifier = "studio.play"
        expandButton.accessibilityIdentifier = "studio.expand"
        setExpanded(false)
        playButton.onTap = { [weak self] in self?.onTogglePlay?() }
        backButton.onTap = { [weak self] in self?.onStep?(-1) }
        forwardButton.onTap = { [weak self] in self?.onStep?(1) }
        expandButton.onTap = { [weak self] in self?.onToggleExpanded?() }
        playhead.onScrub = { [weak self] t in self?.onScrub?(t, true) }
        let commands: [(CCButton, Command)] = [
            (toStartButton, .toStart), (toEndButton, .toEnd), (undoButton, .undo), (redoButton, .redo),
            (deleteButton, .delete), (effectsButton, .effects), (focusButton, .focus), (sliceButton, .slice),
            (splitButton, .split), (annotateButton, .annotate), (voiceButton, .voice), (zoomOutButton, .zoomOut),
            (zoomInButton, .zoomIn),
        ]
        for (button, command) in commands {
            button.onTap = { [weak self, weak button] in
                guard let self, let button else { return }
                self.onCommand?(command, button)
            }
        }
        scaleSlider.onChange = { [weak self] v in
            guard let self else { return }
            self.onCommand?(.scale(v), self.scaleSlider)
        }
        // Play starts media (VoiceOver goes quiet).
        playButton.accessibilityTraits = [.button, .startsMediaSession]
        playButton.accessibilityHint = "Plays or pauses the recording."
        backButton.accessibilityHint = "Steps the playhead back one frame."
        forwardButton.accessibilityHint = "Steps the playhead forward one frame."
        deleteButton.tintOverride = CCTheme.color.destructive

        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 0
        row.translatesAutoresizingMaskIntoConstraints = false
        func sep() -> UIView {
            let line = CCDivider(vertical: true)
            line.heightAnchor.constraint(equalToConstant: 16).isActive = true
            return line
        }
        let spacer = UIView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true
        for v in [toStartButton, playButton, toEndButton, sep(), playhead, spacer,
                  undoButton, redoButton, sep(), deleteButton, sep(),
                  effectsButton, focusButton, sliceButton, splitButton, annotateButton, sep(),
                  voiceButton, sep(), zoomOutButton, scaleSlider, zoomInButton, sep(), expandButton] as [UIView] {
            row.addArrangedSubview(v)
        }
        row.setCustomSpacing(14, after: playhead)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = false
        scroll.delaysContentTouches = false
        scroll.addSubview(row)
        addSubview(scroll)
        hairline.translatesAutoresizingMaskIntoConstraints = false
        hairline.isUserInteractionEnabled = false
        addSubview(hairline)
        playhead.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            row.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            // Wide enough: the spacer pushes the edit keys to the trailing end (the Mac's layout).
            row.widthAnchor.constraint(greaterThanOrEqualTo: scroll.frameLayoutGuide.widthAnchor, constant: -20),
            playhead.heightAnchor.constraint(equalToConstant: 44),
            scaleSlider.widthAnchor.constraint(equalToConstant: 72),
            scaleSlider.heightAnchor.constraint(equalToConstant: 34),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: bottomAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1),
        ])
        ccOnThemeChange { [weak self] in
            self?.backgroundColor = CCTheme.color.card
            self?.hairline.backgroundColor = CCTheme.color.border
        }
        backgroundColor = CCTheme.color.card
        hairline.backgroundColor = CCTheme.color.border
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

    /// The edit keys' availability (the timeline's command state).
    struct CommandState: Equatable {
        var canUndo = false, canRedo = false, canDelete = false, sliceArmed = false, recording = false
        var canZoomOut = false, canZoomIn = false, scale: Double = 0, hasVoice = true, editable = true
    }

    private(set) var commandState = CommandState()

    func setCommandState(_ s: CommandState) {
        guard s != commandState else { return }
        commandState = s
        func on(_ b: CCButton, _ enabled: Bool) { if b.isEnabled != enabled { b.isEnabled = enabled } }
        on(undoButton, s.canUndo && s.editable)
        on(redoButton, s.canRedo && s.editable)
        on(deleteButton, s.canDelete && s.editable)
        for b in [effectsButton, focusButton, sliceButton, splitButton, annotateButton] { on(b, s.editable) }
        on(voiceButton, s.editable)
        voiceButton.isHidden = !s.hasVoice
        let voice = s.recording ? "stop.fill" : "mic.fill"
        if voiceButton.symbol != voice { voiceButton.symbol = voice }
        // The armed slice tool reads as a pressed (filled) key.
        let sliceStyle: CCButton.Style = s.sliceArmed ? .secondary : .ghost
        if sliceButton.style != sliceStyle { sliceButton.style = sliceStyle }
        on(zoomOutButton, s.canZoomOut)
        on(zoomInButton, s.canZoomIn)
        scaleSlider.isEnabled = s.canZoomOut || s.canZoomIn
        scaleSlider.setValue(s.scale)
    }

    /// The full-screen key's face: expand, or return to the editor.
    func setExpanded(_ expanded: Bool) {
        expandButton.symbol = expanded ? "arrow.down.right.and.arrow.up.left" : "display"
        expandButton.accessibilityLabelOverride = expanded ? "Exit full-screen preview" : "Full-screen preview"
        expandButton.accessibilityHint = expanded ? "Shows the timeline and tools again." : "Hides the timeline and tools; the preview takes the screen."
    }

    /// m:ss (output time) — the Mac toolbar's `formattedTimecode`.
    static func format(_ t: TimeInterval) -> String {
        let clamped = max(0, t.isFinite ? t : 0)
        return clamped.formattedTimecode
    }
}

/// The Mac toolbar's bare timeline-zoom track: a hairline track and a white
/// knob (no pill, no label). VoiceOver: adjustable.
final class EditorScaleSlider: UIControl {
    var onChange: ((Double) -> Void)?
    private(set) var value: Double = 0
    private let track = CALayer()
    private let fill = CALayer()
    private let knob = CALayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        for l in [track, fill, knob] { layer.addSublayer(l) }
        knob.shadowColor = UIColor.black.cgColor
        knob.shadowOpacity = 0.3
        knob.shadowRadius = 1.5
        knob.shadowOffset = CGSize(width: 0, height: 0.5)
        isAccessibilityElement = true
        accessibilityLabel = "Timeline zoom"
        accessibilityTraits = .adjustable
        accessibilityValue = "0 percent"
        ccOnThemeChange { [weak self] in self?.restyle() }
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isEnabled: Bool { didSet { alpha = isEnabled ? 1 : CCTheme.disabledAlpha } }

    private func restyle() {
        track.backgroundColor = cc(CCTheme.color.elevated)
        fill.backgroundColor = cc(CCTheme.color.mutedForeground)
        knob.backgroundColor = UIColor.white.cgColor
    }

    func setValue(_ v: Double) {
        let c = min(1, max(0, v))
        guard abs(c - value) > 0.0005 else { return }
        value = c
        accessibilityValue = "\(Int((c * 100).rounded())) percent"
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let k: CGFloat = 12
        let w = bounds.width - k
        track.frame = CGRect(x: k / 2, y: bounds.midY - 1.5, width: w, height: 3)
        track.cornerRadius = 1.5
        fill.frame = CGRect(x: k / 2, y: bounds.midY - 1.5, width: w * CGFloat(value), height: 3)
        fill.cornerRadius = 1.5
        knob.frame = CGRect(x: w * CGFloat(value), y: bounds.midY - k / 2, width: k, height: k)
        knob.cornerRadius = k / 2
        CATransaction.commit()
    }

    private func track(_ touch: UITouch) {
        let w = max(1, bounds.width - 12)
        let v = Double(min(1, max(0, (touch.location(in: self).x - 6) / w)))
        setValue(v)
        onChange?(v)
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool { track(touch); return true }
    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool { track(touch); return true }

    /// A 44 pt tall target (the track draws thin).
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: 0, dy: -max(0, (44 - bounds.height) / 2)).contains(point)
    }

    override func accessibilityIncrement() { setValue(value + 0.1); onChange?(value) }
    override func accessibilityDecrement() { setValue(value - 0.1); onChange?(value) }
}

/// "0:05 / 0:07" — the playhead time in the Mac toolbar's type, and
/// VoiceOver's adjustable playhead ("6.5 seconds of 20 seconds"; swipe up /
/// down moves a second). Focusable with a keyboard (← / → move a second).
final class EditorPlayheadReadout: UIControl {
    var onScrub: ((TimeInterval) -> Void)?

    private static func font(_ size: CGFloat, _ weight: UIFont.Weight, max: CGFloat) -> UIFont {
        UIFontMetrics(forTextStyle: .footnote).scaledFont(
            for: .monospacedDigitSystemFont(ofSize: size, weight: CCFont.legible(weight)), maximumPointSize: max)
    }

    private let current = ccLabel("0:00", font: EditorPlayheadReadout.font(14, .semibold, max: 20), color: CCTheme.color.foreground)
    private let divider = ccLabel("/", font: EditorPlayheadReadout.font(12, .regular, max: 17), color: CCTheme.color.faintForeground)
    private let total = ccLabel("0:00", font: EditorPlayheadReadout.font(12, .medium, max: 17), color: CCTheme.color.mutedForeground)
    private(set) var value: TimeInterval = 0
    private(set) var duration: TimeInterval = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        accessibilityIdentifier = "studio.time"
        isAccessibilityElement = true
        accessibilityTraits = [.adjustable, .updatesFrequently]
        accessibilityLabel = "Playhead"
        accessibilityHint = "Swipe up or down to move a second."
        for label in [current, divider, total] {
            label.adjustsFontForContentSizeCategory = true
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            label.setContentHuggingPriority(.required, for: .horizontal)
        }
        let row = UIStackView(arrangedSubviews: [current, divider, total])
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
        let totalText = EditorTransportBar.format(duration)
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
