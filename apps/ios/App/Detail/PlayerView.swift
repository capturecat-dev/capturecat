import AVFoundation
import UIKit

/// The house video player: an AVPlayerLayer in a UIView with our own
/// transport — play/pause, a scrubber, elapsed / remaining — never the system
/// player chrome (AVPlayerViewController's controls are system glass on iOS
/// 26+). Tap the video to show/hide the controls; they fade away 3 s into
/// playback. The controls sit OVER content, so they're fixed light-on-dark
/// (content is never themed).
final class PlayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    let player = AVPlayer()
    var onTimeChange: ((Double) -> Void)?
    /// The item failed (expired presigned URL, network): the owner refreshes
    /// the source and calls `load` again at `currentTime`.
    var onFailure: ((Error?) -> Void)?
    /// The video's natural size, once known.
    var onPresentationSize: ((CGSize) -> Void)?

    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    var isPlaying: Bool { player.timeControlStatus != .paused }

    private let controls = UIView()
    private let scrim = CAGradientLayer()
    private let playButton = PlayerRoundButton()
    private let elapsedLabel = UILabel()
    private let remainingLabel = UILabel()
    private let scrubber = PlayerScrubber()
    private let spinner = CCSpinner(diameter: 30)
    private let errorStack = UIStackView()
    private let errorLabel = UILabel()
    private var timeObserver: Any?
    private var observations: [NSKeyValueObservation] = []
    private var itemObservations: [NSKeyValueObservation] = []
    private var hideWork: DispatchWorkItem?
    private var controlsShown = true
    private var isScrubbing = false
    private var pendingSeek: Double?
    private var autoplayPending = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        player.actionAtItemEnd = .pause

        controls.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controls)
        scrim.colors = [UIColor.black.withAlphaComponent(0).cgColor, UIColor.black.withAlphaComponent(0.55).cgColor]
        scrim.locations = [0.6, 1]
        controls.layer.addSublayer(scrim)

        playButton.translatesAutoresizingMaskIntoConstraints = false
        playButton.addAction(UIAction { [weak self] _ in self?.togglePlay() }, for: .touchUpInside)
        controls.addSubview(playButton)

        for label in [elapsedLabel, remainingLabel] {
            label.font = CCFont.monoSmall
            label.adjustsFontForContentSizeCategory = true
            label.textColor = .white
            label.translatesAutoresizingMaskIntoConstraints = false
            label.isAccessibilityElement = false
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            controls.addSubview(label)
        }
        elapsedLabel.text = "0:00"
        remainingLabel.text = "-0:00"
        scrubber.translatesAutoresizingMaskIntoConstraints = false
        scrubber.onScrub = { [weak self] fraction, ended in self?.scrubbed(to: fraction, ended: ended) }
        scrubber.onAccessibilityStep = { [weak self] delta in
            guard let self else { return }
            self.seek(to: self.currentTime + delta)
        }
        controls.addSubview(scrubber)

        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)

        errorLabel.font = CCFont.labelMedium
        errorLabel.textColor = .white
        errorLabel.numberOfLines = 0
        errorLabel.textAlignment = .center
        let retry = CCButton(title: "Try again", symbol: "rotate-cw", style: .secondary, size: .sm)
        retry.onTap = { [weak self] in
            self?.errorStack.isHidden = true
            self?.onFailure?(nil)
        }
        errorStack.axis = .vertical
        errorStack.alignment = .center
        errorStack.spacing = CCSpace.md
        errorStack.addArrangedSubview(errorLabel)
        errorStack.addArrangedSubview(retry)
        errorStack.isHidden = true
        errorStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(errorStack)

        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor),
            controls.topAnchor.constraint(equalTo: topAnchor),
            controls.bottomAnchor.constraint(equalTo: bottomAnchor),
            playButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            playButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            playButton.widthAnchor.constraint(equalToConstant: 60),
            playButton.heightAnchor.constraint(equalToConstant: 60),
            elapsedLabel.leadingAnchor.constraint(equalTo: controls.leadingAnchor, constant: CCSpace.md),
            elapsedLabel.centerYAnchor.constraint(equalTo: scrubber.centerYAnchor),
            remainingLabel.trailingAnchor.constraint(equalTo: controls.trailingAnchor, constant: -CCSpace.md),
            remainingLabel.centerYAnchor.constraint(equalTo: scrubber.centerYAnchor),
            scrubber.leadingAnchor.constraint(equalTo: elapsedLabel.trailingAnchor, constant: CCSpace.sm),
            scrubber.trailingAnchor.constraint(equalTo: remainingLabel.leadingAnchor, constant: -CCSpace.sm),
            scrubber.bottomAnchor.constraint(equalTo: controls.bottomAnchor, constant: -4),
            scrubber.heightAnchor.constraint(equalToConstant: 40),
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 30),
            spinner.heightAnchor.constraint(equalToConstant: 30),
            errorStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            errorStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            errorStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: CCSpace.lg),
        ])

        // Tapping the video toggles the controls, but a tap ON a control
        // (play, scrubber) belongs to that control: a parent tap recognizer
        // otherwise cancels the custom UIControl's touch, and play never fires.
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.delegate = self
        addGestureRecognizer(tap)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.statusChanged() }
        })
        isAccessibilityElement = false
        accessibilityElements = [playButton, scrubber]
        refreshPlayButton()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrim.frame = bounds
        CATransaction.commit()
    }

    // MARK: - Loading

    /// Play `asset`, starting at `startAt` (a refreshed URL resumes in place).
    func load(_ asset: AVURLAsset, startAt: Double = 0, autoplay: Bool = false) {
        errorStack.isHidden = true
        let item = AVPlayerItem(asset: asset)
        itemObservations = []
        itemObservations.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
            MainActor.assumeIsolated { self?.itemStatusChanged(item) }
        })
        itemObservations.append(item.observe(\.presentationSize, options: [.new]) { [weak self] item, _ in
            MainActor.assumeIsolated {
                let size = item.presentationSize
                if size.width > 0, size.height > 0 { self?.onPresentationSize?(size) }
            }
        })
        pendingSeek = startAt > 0.05 ? startAt : nil
        autoplayPending = autoplay
        player.replaceCurrentItem(with: item)
        spinner.startAnimating()
        Task { [weak self] in
            if let seconds = try? await asset.load(.duration).seconds, seconds.isFinite {
                self?.duration = seconds
                self?.tick(self?.currentTime ?? 0)
            }
        }
    }

    private func itemStatusChanged(_ item: AVPlayerItem) {
        switch item.status {
        case .readyToPlay:
            spinner.stopAnimating()
            if let seek = pendingSeek {
                pendingSeek = nil
                player.seek(to: CMTime(seconds: seek, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            }
            if autoplayPending {
                autoplayPending = false
                play()
            }
        case .failed:
            spinner.stopAnimating()
            onFailure?(item.error)
        default:
            break
        }
    }

    func showError(_ message: String) {
        spinner.stopAnimating()
        errorLabel.text = message
        errorStack.isHidden = false
        controls.isHidden = true
    }

    // MARK: - Transport

    func play() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        if duration > 0, currentTime >= duration - 0.1 { player.seek(to: .zero) }
        player.play()
        scheduleHide()
    }

    func pause() {
        player.pause()
        showControls(true)
    }

    func seek(to seconds: Double) {
        let clamped = max(0, min(seconds, duration > 0 ? duration : seconds))
        currentTime = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        tick(clamped)
        showControls(true)
        scheduleHide()
    }

    private func togglePlay() {
        CCHaptics.light()
        if isPlaying { pause() } else { play() }
    }

    private func statusChanged() {
        refreshPlayButton()
        switch player.timeControlStatus {
        case .waitingToPlayAtSpecifiedRate:
            spinner.startAnimating()
        default:
            if player.currentItem?.status == .readyToPlay { spinner.stopAnimating() }
        }
        if player.timeControlStatus == .paused { showControls(true) }
    }

    private func refreshPlayButton() {
        let playing = player.timeControlStatus != .paused
        playButton.symbol = playing ? "pause-fill" : "play-fill"
        playButton.accessibilityLabel = playing ? "Pause" : "Play"
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        if !isScrubbing { currentTime = seconds }
        let shown = isScrubbing ? currentTime : seconds
        elapsedLabel.text = Format.duration(shown)
        remainingLabel.text = "-" + Format.duration(max(0, duration - shown))
        if !isScrubbing, duration > 0 { scrubber.fraction = CGFloat(shown / duration) }
        scrubber.accessibilityValue = "\(Format.spokenDuration(shown)) of \(Format.spokenDuration(duration))"
        onTimeChange?(shown)
    }

    private func scrubbed(to fraction: CGFloat, ended: Bool) {
        guard duration > 0 else { return }
        isScrubbing = !ended
        let target = Double(fraction) * duration
        currentTime = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        tick(target)
        hideWork?.cancel()
        if ended { scheduleHide() }
    }

    // MARK: - Controls visibility

    @objc private func tapped() {
        showControls(!controlsShown)
        if controlsShown { scheduleHide() }
    }

    private func showControls(_ show: Bool) {
        guard show != controlsShown || controls.alpha != (show ? 1 : 0) else { return }
        controlsShown = show
        controls.isHidden = false
        CCMotion.fadeAlpha(controls, to: show ? 1 : 0, duration: show ? 0.18 : 0.3)
        controls.isUserInteractionEnabled = show
        accessibilityElements = show ? [playButton, scrubber] : []
    }

    private func scheduleHide() {
        hideWork?.cancel()
        guard !UIAccessibility.isVoiceOverRunning else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isPlaying, !self.isScrubbing else { return }
            self.showControls(false)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }
}

/// The big round play/pause button over the video: a dark translucent disc
/// (content overlay, fixed colors); press tints it in place.
final class PlayerRoundButton: UIControl {
    private let icon = UIImageView()
    var symbol: String = "play-fill" {
        didSet {
            guard symbol != oldValue else { return }
            icon.image = CCIcon.image(symbol, pointSize: 22, weight: .semibold)
            CCMotion.pop(icon, from: 0.8)
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.42)
        layer.borderWidth = 0.5
        layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
        icon.tintColor = .white
        icon.contentMode = .center
        icon.image = CCIcon.image(symbol, pointSize: 22, weight: .semibold)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.isUserInteractionEnabled = false
        addSubview(icon)
        NSLayoutConstraint.activate([icon.centerXAnchor.constraint(equalTo: centerXAnchor), icon.centerYAnchor.constraint(equalTo: centerYAnchor)])
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = CCRadius.full.resolved(for: bounds.height)
    }

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: CCMotion.paced(isHighlighted ? 0.06 : 0.2)) {
                self.backgroundColor = UIColor.black.withAlphaComponent(self.isHighlighted ? 0.62 : 0.42)
            }
        }
    }
}

/// The scrubber: a thin track with a white fill and knob; the knob grows
/// while you drag (on the bounce) and shrinks back when you let go.
final class PlayerScrubber: UIControl {
    var onScrub: ((CGFloat, Bool) -> Void)?
    var onAccessibilityStep: ((Double) -> Void)?
    var fraction: CGFloat = 0 { didSet { setNeedsLayout() } }

    private let track = UIView()
    private let fill = UIView()
    private let knob = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        track.backgroundColor = UIColor.white.withAlphaComponent(0.28)
        fill.backgroundColor = .white
        knob.backgroundColor = .white
        knob.layer.shadowColor = UIColor.black.cgColor
        knob.layer.shadowOpacity = 0.3
        knob.layer.shadowRadius = 3
        knob.layer.shadowOffset = CGSize(width: 0, height: 1)
        for view in [track, fill, knob] {
            view.isUserInteractionEnabled = false
            addSubview(view)
        }
        isAccessibilityElement = true
        accessibilityLabel = "Playback position"
        accessibilityTraits = .adjustable
        // Before the player knows its duration it still speaks a position.
        accessibilityValue = "0 seconds"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h: CGFloat = 4
        let y = bounds.midY - h / 2
        track.frame = CGRect(x: 0, y: y, width: bounds.width, height: h)
        track.layer.cornerRadius = h / 2
        let x = bounds.width * max(0, min(1, fraction))
        fill.frame = CGRect(x: 0, y: y, width: x, height: h)
        fill.layer.cornerRadius = h / 2
        let side: CGFloat = 14
        knob.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        knob.center = CGPoint(x: x, y: bounds.midY)
        knob.layer.cornerRadius = side / 2
    }

    /// A 44 pt touch target around the thin track (Studio 6a).
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let dy = max(0, (44 - bounds.height) / 2)
        return bounds.insetBy(dx: 0, dy: -dy).contains(point)
    }

    private func fraction(for touch: UITouch) -> CGFloat {
        max(0, min(1, touch.location(in: self).x / max(bounds.width, 1)))
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        CCMotion.spring(knob.layer, keyPath: "transform.scale", to: 1.45, .bouncy)
        fraction = fraction(for: touch)
        onScrub?(fraction, false)
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        fraction = fraction(for: touch)
        onScrub?(fraction, false)
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        CCMotion.spring(knob.layer, keyPath: "transform.scale", to: 1.0, .smooth)
        if let touch { fraction = fraction(for: touch) }
        onScrub?(fraction, true)
    }

    override func cancelTracking(with event: UIEvent?) {
        CCMotion.spring(knob.layer, keyPath: "transform.scale", to: 1.0, .smooth)
        onScrub?(fraction, true)
    }

    override func accessibilityIncrement() { onAccessibilityStep?(5) }
    override func accessibilityDecrement() { onAccessibilityStep?(-5) }
}

extension PlayerView: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var view = touch.view
        while let v = view, v !== self {
            if v is UIControl { return false }
            view = v.superview
        }
        return true
    }
}
