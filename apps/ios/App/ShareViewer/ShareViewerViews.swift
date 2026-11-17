import AVFoundation
import UIKit

// The share viewer's pieces. Content (the video, its captions and the emoji
// floating over it) is never themed; everything on the page is house kit
// and follows light / dark like the rest of the app.

// MARK: - Player surface

/// The video: an AVPlayerLayer, the big play key, a spinner, captions from
/// the share's transcript, and the reaction floaters rising over the frame.
/// Tap the frame to play / pause.
final class ShareVideoSurface: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    let player = AVPlayer()
    var onTime: ((Double) -> Void)?
    var onPlayingChange: ((Bool) -> Void)?
    var onPresentationSize: ((CGSize) -> Void)?
    var onFailure: ((Error?) -> Void)?

    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    var isPlaying: Bool { player.timeControlStatus != .paused }

    let playButton = PlayerRoundButton()
    private let spinner = CCSpinner(diameter: 30)
    private let captionLabel = PaddedLabel()
    private let floaters = UIView()
    private var timeObserver: Any?
    private var observations: [NSKeyValueObservation] = []
    private var itemObservations: [NSKeyValueObservation] = []
    private var pendingSeek: Double?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        layer.cornerCurve = .continuous
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        player.actionAtItemEnd = .pause

        captionLabel.font = CCFont.scaled(16, .semibold, .body, max: 26)
        captionLabel.adjustsFontForContentSizeCategory = true
        captionLabel.textColor = .white
        captionLabel.numberOfLines = 3
        captionLabel.textAlignment = .center
        captionLabel.backgroundColor = UIColor.black.withAlphaComponent(0.62)
        captionLabel.layer.cornerRadius = 6
        captionLabel.clipsToBounds = true
        captionLabel.isHidden = true
        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        // Captions are the transcript drawn on the frame; VoiceOver reads the
        // Transcript tab (and the audio) instead of a label racing playback.
        captionLabel.isAccessibilityElement = false
        addSubview(captionLabel)

        floaters.isUserInteractionEnabled = false
        floaters.translatesAutoresizingMaskIntoConstraints = false
        addSubview(floaters)

        playButton.translatesAutoresizingMaskIntoConstraints = false
        playButton.addAction(UIAction { [weak self] _ in self?.togglePlay() }, for: .touchUpInside)
        addSubview(playButton)
        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)

        NSLayoutConstraint.activate([
            playButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            playButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            playButton.widthAnchor.constraint(equalToConstant: 60),
            playButton.heightAnchor.constraint(equalToConstant: 60),
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 30),
            spinner.heightAnchor.constraint(equalToConstant: 30),
            captionLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            captionLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -CCSpace.md),
            captionLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: CCSpace.md),
            floaters.leadingAnchor.constraint(equalTo: leadingAnchor),
            floaters.trailingAnchor.constraint(equalTo: trailingAnchor),
            floaters.topAnchor.constraint(equalTo: topAnchor),
            floaters.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
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
        accessibilityElements = [playButton]
        refreshPlayButton()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = CCTheme.radius(.lg)
    }

    func load(_ asset: AVURLAsset, startAt: Double, knownDuration: Double?) {
        let item = AVPlayerItem(asset: asset)
        if let knownDuration, knownDuration > 0 { duration = knownDuration }
        itemObservations = [
            item.observe(\.status, options: [.new]) { [weak self] item, _ in
                MainActor.assumeIsolated { self?.itemStatusChanged(item) }
            },
            item.observe(\.presentationSize, options: [.new]) { [weak self] item, _ in
                MainActor.assumeIsolated {
                    let size = item.presentationSize
                    if size.width > 0, size.height > 0 { self?.onPresentationSize?(size) }
                }
            },
        ]
        pendingSeek = startAt > 0.05 ? startAt : nil
        player.replaceCurrentItem(with: item)
        spinner.startAnimating()
        Task { [weak self] in
            if let seconds = try? await asset.load(.duration).seconds, seconds.isFinite, seconds > 0 {
                self?.duration = seconds
                self?.tick(self?.currentTime ?? 0)
            }
        }
    }

    private func itemStatusChanged(_ item: AVPlayerItem) {
        switch item.status {
        case .readyToPlay:
            spinner.stopAnimating()
            if let target = pendingSeek {
                pendingSeek = nil
                seek(to: target)
            }
        case .failed:
            spinner.stopAnimating()
            onFailure?(item.error)
        default:
            break
        }
    }

    func play() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        if duration > 0, currentTime >= duration - 0.1 { player.seek(to: .zero) }
        player.play()
    }

    func pause() { player.pause() }

    func togglePlay() {
        CCHaptics.light()
        if isPlaying { pause() } else { play() }
    }

    func seek(to seconds: Double) {
        let clamped = max(0, duration > 0 ? min(seconds, duration) : seconds)
        currentTime = clamped
        if player.currentItem?.status == .readyToPlay {
            player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            pendingSeek = clamped
        }
        tick(clamped, force: true)
    }

    private var scrubbing = false
    /// The scrubber holds the time while a finger drags it.
    func setScrubbing(_ on: Bool) { scrubbing = on }

    private func tick(_ seconds: Double, force: Bool = false) {
        guard seconds.isFinite else { return }
        if scrubbing, !force { return }
        currentTime = seconds
        onTime?(seconds)
    }

    private func statusChanged() {
        refreshPlayButton()
        if player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
            spinner.startAnimating()
        } else if player.currentItem?.status == .readyToPlay {
            spinner.stopAnimating()
        }
        onPlayingChange?(isPlaying)
    }

    private func refreshPlayButton() {
        let playing = player.timeControlStatus != .paused
        playButton.symbol = playing ? "pause-fill" : "play-fill"
        playButton.accessibilityLabel = playing ? "Pause" : "Play"
        // The big key steps aside while the video plays (the frame is the point).
        CCMotion.fadeAlpha(playButton, to: playing ? 0 : 1, duration: playing ? 0.3 : 0.18)
    }

    @objc private func tapped() { togglePlay() }

    // MARK: Captions

    func setCaption(_ text: String?) {
        let shown = text?.isEmpty == false
        if captionLabel.text != text { captionLabel.text = text }
        if captionLabel.isHidden == shown {
            captionLabel.isHidden = !shown
            if shown { CCMotion.fadeAlpha(captionLabel, to: 1, duration: 0.16, from: 0) }
        }
        captionLabel.accessibilityLabel = text
    }

    var captionText: String? { captionLabel.isHidden ? nil : captionLabel.text }

    // MARK: Floaters

    /// An emoji rises from the moment it marks (x = time along the frame) and
    /// fades out. Reduce Motion: it fades in place, nothing travels.
    @discardableResult
    func spawnFloater(_ emoji: String, ratio: CGFloat) -> UIView {
        let label = UIImageView(image: ShareGlyph.text(emoji, pointSize: 30))
        label.sizeToFit()
        let x = max(24, min(bounds.width - 24, bounds.width * ratio))
        label.center = CGPoint(x: x, y: bounds.height - 28)
        label.isAccessibilityElement = false
        floaters.addSubview(label)
        let rise = bounds.height * 0.62
        if CCMotion.reduceMotion {
            CCMotion.fade(label.layer, keyPath: "opacity", to: 0, duration: 1.2, delay: 0.4, from: 1)
        } else {
            CCMotion.spring(label.layer, keyPath: "transform.scale", from: 0.4, to: 1.0, .bouncy)
            let travel = CABasicAnimation(keyPath: "position.y")
            travel.fromValue = label.center.y
            travel.toValue = label.center.y - rise
            travel.duration = CCMotion.paced(1.6)
            travel.timingFunction = CCMotion.glide
            label.layer.position.y -= rise
            if !CCMotion.probeSnap { label.layer.add(travel, forKey: "rise") }
            CCMotion.fade(label.layer, keyPath: "opacity", to: 0, duration: 0.5, delay: 1.1, from: 1)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + CCMotion.paced(1.8)) { label.removeFromSuperview() }
        return label
    }

    var floaterViews: [UIView] { floaters.subviews }
}

extension ShareVideoSurface: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var view = touch.view
        while let v = view, v !== self {
            if v is UIControl { return false }
            view = v.superview
        }
        return true
    }
}

/// A label with breathing room (captions).
final class PaddedLabel: UILabel {
    var insets = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: insets)) }
    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right, height: size.height + insets.top + insets.bottom)
    }
    override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines n: Int) -> CGRect {
        let inner = super.textRect(forBounds: bounds.inset(by: insets), limitedToNumberOfLines: n)
        return inner.inset(by: UIEdgeInsets(top: -insets.top, left: -insets.left, bottom: -insets.bottom, right: -insets.right))
    }
}

// MARK: - Marker math (shared by the lane and the gate)

/// Commenter markers along the scrubber, the web's rule
/// (apps/web/src/lib/share/comments.ts groupMarkers): top-level comments
/// only, by time; a marker that would touch the previous group's anchor
/// joins it as a stack with a count.
enum ShareMarkerMath {
    struct Group: Equatable {
        var key: String
        var time: Double
        var ratio: Double
        var comments: [VideoComment]
    }

    static func ratio(_ time: Double, duration: Double) -> Double {
        duration > 0 ? min(1, max(0, time / duration)) : 0
    }

    static func groups(_ comments: [VideoComment], duration: Double, trackWidth: CGFloat, minGap: CGFloat) -> [Group] {
        let roots = comments.filter { $0.parentId == nil }
            .sorted { ($0.videoTime ?? 0, $0.commentId) < ($1.videoTime ?? 0, $1.commentId) }
        var out: [Group] = []
        for comment in roots {
            let time = comment.videoTime ?? 0
            let r = ratio(time, duration: duration)
            if let last = out.last, (r - last.ratio) * Double(max(0, trackWidth)) < Double(minGap) {
                out[out.count - 1].comments.append(comment)
            } else {
                out.append(Group(key: comment.commentId, time: time, ratio: r, comments: [comment]))
            }
        }
        return out
    }
}

// MARK: - Scrubber + markers

/// The page's transport: commenter avatars on a lane above the track (each
/// stem points at its exact moment), reaction emoji dotted under it, the
/// track itself (drag or tap to seek, adjustable for VoiceOver), and the
/// elapsed / remaining times.
final class ShareTimelineView: UIView {
    var onSeek: ((Double, Bool) -> Void)?
    var onJump: ((VideoComment) -> Void)?

    let lane = UIView()
    let scrubber = ShareScrubber()
    let elapsedLabel = ccLabel("0:00", font: CCFont.monoSmall, color: CCTheme.color.mutedForeground)
    let remainingLabel = ccLabel("-0:00", font: CCFont.monoSmall, color: CCTheme.color.mutedForeground)
    private(set) var markerViews: [ShareMarkerView] = []
    private var groups: [ShareMarkerMath.Group] = []
    private var comments: [VideoComment] = []
    private var reactions: [ShareReaction] = []
    private(set) var duration: Double = 0
    static let laneHeight: CGFloat = 30
    static let avatarSide: CGFloat = 20

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        lane.translatesAutoresizingMaskIntoConstraints = false
        addSubview(lane)
        scrubber.translatesAutoresizingMaskIntoConstraints = false
        scrubber.onScrub = { [weak self] fraction, ended in
            guard let self, self.duration > 0 else { return }
            self.onSeek?(Double(fraction) * self.duration, ended)
        }
        scrubber.onAccessibilityStep = { [weak self] delta in
            guard let self else { return }
            self.onSeek?(max(0, min(self.duration, self.scrubber.time + delta)), true)
        }
        addSubview(scrubber)
        for label in [elapsedLabel, remainingLabel] {
            label.isAccessibilityElement = false
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        NSLayoutConstraint.activate([
            lane.topAnchor.constraint(equalTo: topAnchor),
            lane.leadingAnchor.constraint(equalTo: scrubber.leadingAnchor),
            lane.trailingAnchor.constraint(equalTo: scrubber.trailingAnchor),
            lane.heightAnchor.constraint(equalToConstant: Self.laneHeight),
            scrubber.topAnchor.constraint(equalTo: lane.bottomAnchor),
            scrubber.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            scrubber.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            scrubber.heightAnchor.constraint(equalToConstant: 44),
            elapsedLabel.topAnchor.constraint(equalTo: scrubber.bottomAnchor, constant: -6),
            elapsedLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            remainingLabel.topAnchor.constraint(equalTo: elapsedLabel.topAnchor),
            remainingLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            elapsedLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setTime(_ time: Double, duration: Double) {
        let changedDuration = abs(duration - self.duration) > 0.01
        self.duration = duration
        scrubber.duration = duration
        scrubber.time = time
        elapsedLabel.text = Format.duration(time)
        remainingLabel.text = "-" + Format.duration(max(0, duration - time))
        if changedDuration { setNeedsLayout(); rebuildMarkers(animated: false) }
    }

    func setContent(comments: [VideoComment], reactions: [ShareReaction]) {
        let commentsChanged = comments != self.comments
        self.comments = comments
        self.reactions = reactions
        scrubber.reactions = reactions
        if commentsChanged { rebuildMarkers(animated: window != nil) }
    }

    /// x of `time` in this view's coordinates (the track's own geometry).
    func x(for time: Double) -> CGFloat {
        scrubber.frame.minX + scrubber.trackX(for: time)
    }

    override func layoutSubviews() {
        let width = lane.bounds.width
        super.layoutSubviews()
        if abs(width - lane.bounds.width) > 0.5 { rebuildMarkers(animated: false) } else { placeMarkers() }
    }

    private func rebuildMarkers(animated: Bool) {
        let width = scrubber.bounds.width
        let fresh = ShareMarkerMath.groups(comments, duration: duration, trackWidth: width, minGap: Self.avatarSide + 10)
        guard fresh != groups || markerViews.count != fresh.count else { placeMarkers(); return }
        let oldKeys = Set(groups.map(\.key))
        groups = fresh
        markerViews.forEach { $0.removeFromSuperview() }
        markerViews = fresh.map { group in
            let marker = ShareMarkerView(group: group, side: Self.avatarSide)
            marker.onTap = { [weak self] in self?.onJump?(group.comments[0]) }
            lane.addSubview(marker)
            return marker
        }
        placeMarkers()
        if animated {
            for marker in markerViews where !oldKeys.contains(marker.group.key) {
                // A new comment's face drops onto its moment on the bounce.
                CCMotion.spring(marker.layer, keyPath: "transform.translation.y", from: -10, to: 0, .bouncy)
                CCMotion.fade(marker.layer, keyPath: "opacity", to: 1, duration: 0.2, from: 0)
            }
        }
    }

    private func placeMarkers() {
        for marker in markerViews {
            var ratio = marker.group.ratio
            #if DEBUG
            if ShareViewerModel.probeInject == "marker-offset" { ratio = min(1, ratio * 1.12 + 0.02) }
            #endif
            let x = scrubber.trackInset + CGFloat(ratio) * (lane.bounds.width - scrubber.trackInset * 2)
            marker.bounds = CGRect(x: 0, y: 0, width: marker.intrinsicContentSize.width, height: Self.laneHeight)
            // The stem's foot (the marker's centre x) sits on the moment.
            marker.center = CGPoint(x: x + marker.stemOffset, y: Self.laneHeight / 2)
        }
    }
}

/// One marker: the earliest commenter's avatar (+ up to two peeking behind,
/// + a count), a stem down to the track. A data-sized element: VoiceOver
/// gets "Play from here" / "Show comment" actions instead of a 44 pt target.
final class ShareMarkerView: UIControl {
    let group: ShareMarkerMath.Group
    var onTap: (() -> Void)?
    private let side: CGFloat
    private static let peek: CGFloat = 5
    /// stem x minus the view's centre x (the stem sits under the FRONT avatar).
    var stemOffset: CGFloat { intrinsicContentSize.width / 2 - side / 2 }

    init(group: ShareMarkerMath.Group, side: CGFloat) {
        self.group = group
        self.side = side
        super.init(frame: .zero)
        let shown = Array(group.comments.prefix(3))
        for (i, comment) in shown.enumerated().reversed() {
            let avatar = UIImageView(image: ShareGlyph.avatar(comment.authorName, side: side))
            avatar.frame = CGRect(x: CGFloat(i) * Self.peek, y: 0, width: side, height: side)
            avatar.layer.cornerRadius = side / 2
            avatar.layer.borderWidth = 1.5
            avatar.layer.borderColor = CCTheme.color.background.resolvedColor(with: traitCollection).cgColor
            avatar.isUserInteractionEnabled = false
            addSubview(avatar)
        }
        let stem = UIView(frame: CGRect(x: side / 2 - 0.5, y: side, width: 1, height: ShareTimelineView.laneHeight - side))
        stem.backgroundColor = CCTheme.color.faintForeground
        stem.isUserInteractionEnabled = false
        addSubview(stem)
        if group.comments.count > 1 {
            let count = UIImageView(image: ShareGlyph.text("\(group.comments.count)", pointSize: 9, color: CCTheme.color.background.resolvedColor(with: traitCollection)))
            count.contentMode = .center
            count.backgroundColor = CCTheme.color.foreground
            count.layer.cornerRadius = 7
            count.clipsToBounds = true
            count.frame = CGRect(x: intrinsicContentSize.width - 10, y: -4, width: 14, height: 14)
            addSubview(count)
        }
        let first = group.comments[0]
        isAccessibilityElement = true
        accessibilityIdentifier = CCAccessibility.dataGeometryPrefix + "share-marker." + group.key
        accessibilityTraits = .button
        accessibilityLabel = group.comments.count == 1
            ? "Comment by \(first.authorName) at \(Format.duration(group.time))"
            : "\(group.comments.count) comments from \(Format.duration(group.time))"
        accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Play from here") { [weak self] _ in
            self?.onTap?()
            return true
        }]
        addAction(UIAction { [weak self] _ in
            CCHaptics.selection()
            self?.onTap?()
        }, for: .touchUpInside)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: side + CGFloat(min(3, group.comments.count) - 1) * Self.peek, height: ShareTimelineView.laneHeight)
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            CCMotion.spring(layer, keyPath: "transform.translation.y", to: isHighlighted ? -3 : 0, .snappy)
        }
    }
}

/// The track: played fill, knob, and this share's reactions as tiny emoji at
/// their moments (the web's density strip).
final class ShareScrubber: UIControl {
    var onScrub: ((CGFloat, Bool) -> Void)?
    var onAccessibilityStep: ((Double) -> Void)?
    var duration: Double = 0 { didSet { setNeedsLayout() } }
    var time: Double = 0 {
        didSet {
            setNeedsLayout()
            accessibilityValue = "\(Format.spokenDuration(time)) of \(Format.spokenDuration(duration))"
        }
    }
    var reactions: [ShareReaction] = [] {
        didSet { if reactions != oldValue { rebuildDots() } }
    }
    let trackInset: CGFloat = 8

    private let track = UIView()
    private let fill = UIView()
    private let knob = UIView()
    private var dots: [UIImageView] = []
    private var dragging = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        for view in [track, fill, knob] {
            view.isUserInteractionEnabled = false
            addSubview(view)
        }
        knob.layer.shadowColor = UIColor.black.cgColor
        knob.layer.shadowOpacity = 0.25
        knob.layer.shadowRadius = 2
        knob.layer.shadowOffset = CGSize(width: 0, height: 1)
        isAccessibilityElement = true
        accessibilityLabel = "Playback position"
        accessibilityTraits = .adjustable
        accessibilityValue = "0 seconds"
        ccOnThemeChange { [weak self] in self?.applyTheme() }
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func applyTheme() {
        track.backgroundColor = CCTheme.color.elevated
        fill.backgroundColor = CCTheme.color.foreground
        knob.backgroundColor = CCTheme.color.card
        knob.layer.borderColor = CCTheme.color.border.resolvedColor(with: traitCollection).cgColor
        knob.layer.borderWidth = 1
    }

    func trackX(for time: Double) -> CGFloat {
        trackInset + CGFloat(ShareMarkerMath.ratio(time, duration: duration)) * max(0, bounds.width - trackInset * 2)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h: CGFloat = 4
        let y = bounds.midY - h / 2 - 4
        let width = max(0, bounds.width - trackInset * 2)
        track.frame = CGRect(x: trackInset, y: y, width: width, height: h)
        track.layer.cornerRadius = h / 2
        let x = trackX(for: time)
        fill.frame = CGRect(x: trackInset, y: y, width: x - trackInset, height: h)
        fill.layer.cornerRadius = h / 2
        knob.bounds = CGRect(x: 0, y: 0, width: 14, height: 14)
        knob.center = CGPoint(x: x, y: y + h / 2)
        knob.layer.cornerRadius = 7
        for (dot, reaction) in zip(dots, reactions) {
            dot.sizeToFit()
            dot.center = CGPoint(x: trackX(for: reaction.videoTime), y: y + h + 9)
        }
    }

    private func rebuildDots() {
        dots.forEach { $0.removeFromSuperview() }
        dots = reactions.map { reaction in
            let dot = UIImageView(image: ShareGlyph.text(reaction.emoji, pointSize: 10))
            dot.isAccessibilityElement = false
            dot.isUserInteractionEnabled = false
            insertSubview(dot, belowSubview: knob)
            return dot
        }
        setNeedsLayout()
    }

    var dotViews: [UIImageView] { dots }

    private func fraction(for touch: UITouch) -> CGFloat {
        let width = max(1, bounds.width - trackInset * 2)
        return max(0, min(1, (touch.location(in: self).x - trackInset) / width))
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        dragging = true
        CCMotion.spring(knob.layer, keyPath: "transform.scale", to: 1.45, .bouncy)
        onScrub?(fraction(for: touch), false)
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        onScrub?(fraction(for: touch), false)
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        dragging = false
        CCMotion.spring(knob.layer, keyPath: "transform.scale", to: 1.0, .smooth)
        if let touch { onScrub?(fraction(for: touch), true) }
    }

    override func cancelTracking(with event: UIEvent?) {
        dragging = false
        CCMotion.spring(knob.layer, keyPath: "transform.scale", to: 1.0, .smooth)
    }

    override func accessibilityIncrement() { onAccessibilityStep?(5) }
    override func accessibilityDecrement() { onAccessibilityStep?(-5) }
}

// MARK: - Reactions

/// Six large round emoji keys: tap to drop that reaction at the current
/// moment (tap yours again to take it back); the tallies follow as chips.
final class ShareReactionBar: UIView {
    var onReact: ((String) -> Void)?
    private(set) var keys: [ShareReactionKey] = []
    private let tallies = UIStackView()
    private let row = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        keys = ShareReactions.all.map { emoji in
            let key = ShareReactionKey(emoji: emoji)
            key.addAction(UIAction { [weak self] _ in self?.onReact?(emoji) }, for: .touchUpInside)
            return key
        }
        row.axis = .horizontal
        row.distribution = .equalSpacing
        row.alignment = .center
        keys.forEach { row.addArrangedSubview($0) }
        tallies.axis = .horizontal
        tallies.spacing = CCSpace.xs + 2
        tallies.alignment = .center
        let talliesRow = UIStackView(arrangedSubviews: [tallies, UIView()])
        let stack = UIStackView(arrangedSubviews: [row, talliesRow])
        stack.axis = .vertical
        stack.spacing = CCSpace.sm
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func render(counts: [(emoji: String, count: Int)], mine: String?) {
        let map = Dictionary(uniqueKeysWithValues: counts.map { ($0.emoji, $0.count) })
        for key in keys {
            key.setSelected(key.emoji == mine)
            key.count = map[key.emoji] ?? 0
        }
        let wanted = counts.map { "\($0.emoji) \($0.count)" }
        let current = tallies.arrangedSubviews.compactMap { ($0 as? CCBadge)?.text }
        guard wanted != current else { return }
        tallies.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, text) in wanted.enumerated() {
            let chip = CCBadge(text, variant: counts[index].emoji == mine ? .primary : .subtle)
            chip.accessibilityLabel = "\(ShareReactions.spoken[counts[index].emoji] ?? counts[index].emoji): \(counts[index].count)"
            tallies.addArrangedSubview(chip)
        }
        tallies.isHidden = wanted.isEmpty
    }
}

final class ShareReactionKey: UIControl {
    let emoji: String
    private let label = UIImageView()
    private(set) var isChosen = false
    var count = 0 { didSet { refreshAccessibility() } }
    static let side: CGFloat = 48

    init(emoji: String) {
        self.emoji = emoji
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.image = ShareGlyph.text(emoji, pointSize: 24)
        label.isUserInteractionEnabled = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        layer.cornerCurve = .continuous
        isAccessibilityElement = true
        accessibilityTraits = .button
        ccOnThemeChange { [weak self] in self?.applyTheme() }
        applyTheme()
        refreshAccessibility()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        CCMaterial.refit(layer, radius: bounds.height / 2)
    }

    func setSelected(_ on: Bool) {
        guard on != isChosen else { return }
        isChosen = on
        applyTheme()
        refreshAccessibility()
    }

    private func refreshAccessibility() {
        accessibilityLabel = "React \(ShareReactions.spoken[emoji] ?? emoji)"
        accessibilityValue = count > 0 ? "\(count)" : nil
        accessibilityTraits = isChosen ? [.button, .selected] : .button
    }

    private func applyTheme() {
        CCMaterial.dress(layer, as: .raised(tint: isChosen ? CCTheme.color.elevated : CCTheme.color.card), radius: Self.side / 2, traits: traitCollection)
        // The chosen one wears the ink ring (and a check under
        // Differentiate Without Color, via the selected trait VoiceOver reads).
        layer.borderWidth = isChosen ? 2 : 0
        layer.borderColor = CCTheme.color.foreground.resolvedColor(with: traitCollection).cgColor
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            CCMotion.spring(layer, keyPath: "transform.scale", to: isHighlighted ? 0.9 : 1.0, isHighlighted ? .snappy : .bouncy)
        }
    }

    /// The landing pop (the reaction counted).
    func pop() {
        CCMotion.spring(layer, keyPath: "transform.scale", from: 1.22, to: 1.0, .bouncy)
    }
}

// MARK: - Comments

/// One comment: avatar, name (+ Owner), relative time, the timestamp chip
/// that seeks the video, the body, and Reply. Replies indent behind a rule.
final class ShareCommentRow: UIView {
    let comment: VideoComment
    var onSeek: ((Double) -> Void)?
    var onReply: ((VideoComment) -> Void)?
    private(set) var timeChip: CCButton?
    private(set) var replyButton: CCButton?

    init(comment: VideoComment, reply: Bool) {
        self.comment = comment
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let avatar = CCAvatar(name: comment.authorName, side: reply ? 26 : 34)
        let author = ccLabel(comment.authorName, font: CCFont.labelSemibold, color: CCTheme.color.foreground)
        author.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        author.ccWrapsAtAccessibilitySizes()
        let when = ccLabel(Format.relative(comment.createdAt), font: CCFont.caption, color: CCTheme.color.mutedForeground)
        when.setContentCompressionResistancePriority(.required, for: .horizontal)
        var topItems: [UIView] = [author]
        if comment.isOwner { topItems.append(CCBadge("Owner", variant: .outline)) }
        topItems.append(when)
        topItems.append(UIView())
        let top = UIStackView(arrangedSubviews: topItems)
        top.spacing = CCSpace.sm
        top.alignment = .center
        top.ccStacksAtAccessibilitySizes()
        let body = ccLabel(comment.body, font: CCFont.body, color: CCTheme.color.foreground, lines: 0)
        var actions: [UIView] = []
        if !reply {
            let time = comment.videoTime ?? 0
            let chip = CCButton(title: Format.duration(time), symbol: "play-fill", style: .secondary, size: .sm, radius: .full)
            chip.accessibilityLabelOverride = "Play from \(Format.spokenDuration(time))"
            chip.onTap = { [weak self] in self?.onSeek?(time) }
            timeChip = chip
            actions.append(chip)
            let replyKey = CCButton(title: "Reply", style: .ghost, size: .sm, radius: .full)
            replyKey.accessibilityLabelOverride = "Reply to \(comment.authorName)"
            replyKey.onTap = { [weak self] in
                guard let self else { return }
                self.onReply?(self.comment)
            }
            replyButton = replyKey
            actions.append(replyKey)
        }
        actions.append(UIView())
        let actionRow = UIStackView(arrangedSubviews: actions)
        actionRow.spacing = CCSpace.sm
        actionRow.alignment = .center
        let text = UIStackView(arrangedSubviews: [top, body] + (reply ? [] : [actionRow]))
        text.axis = .vertical
        text.spacing = CCSpace.xs
        text.setCustomSpacing(CCSpace.sm, after: body)
        let row = UIStackView(arrangedSubviews: [avatar, text])
        row.spacing = CCSpace.md
        row.alignment = .top
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        var leading: CGFloat = 0
        if reply {
            leading = 30
            let rule = UIView()
            rule.backgroundColor = CCTheme.color.border
            rule.translatesAutoresizingMaskIntoConstraints = false
            addSubview(rule)
            NSLayoutConstraint.activate([
                rule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                rule.widthAnchor.constraint(equalToConstant: 2),
                rule.topAnchor.constraint(equalTo: topAnchor),
                rule.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leading),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        let spokenTime = reply ? "" : ", at \(Format.spokenDuration(comment.videoTime ?? 0))"
        author.accessibilityLabel = "\(reply ? "Reply from" : "Comment from") \(comment.authorName)\(comment.isOwner ? ", owner" : ""), \(Format.relative(comment.createdAt))\(spokenTime)"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

// MARK: - Composer

/// Pinned above the keyboard: who is commenting (signed in) or a name field
/// plus "Sign in" (signed out — the web lets anyone comment, optionally
/// named), the reply strip, then the moment chip · "Add a comment…" · send.
final class ShareComposerView: UIView {
    let identityLabel = ccLabel("", font: CCFont.caption, color: CCTheme.color.mutedForeground, lines: 2)
    let nameField = CCField(placeholder: "Your name (optional)")
    let signInButton = CCButton(title: "Sign in", style: .link, size: .sm)
    let replyLabel = ccLabel("", font: CCFont.captionMedium, color: CCTheme.color.foreground)
    let cancelReply = CCButton(symbol: "close", style: .ghost, size: .sm, radius: .full)
    let timeChip = CCButton(title: "0:00", symbol: "timer", style: .secondary, size: .sm, radius: .full)
    let field = CCField(placeholder: "Add a comment…")
    let sendButton = CCButton(symbol: "arrow-up-line", style: .primary, size: .regular, radius: .full)
    let errorLabel = ccLabel("", font: CCFont.caption, color: CCTheme.color.destructive, lines: 0)
    private let identityRow = UIStackView()
    private let replyRow = UIStackView()
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = CCTheme.color.background
        let rule = CCDivider()
        rule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rule)
        nameField.autocapitalizationType = .words
        nameField.textContentType = .name
        nameField.accessibilityLabel = "Your name"
        signInButton.accessibilityHint = "Comment as yourself"
        signInButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        identityLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        identityRow.spacing = CCSpace.sm
        identityRow.alignment = .center
        identityRow.ccStacksAtAccessibilitySizes(rowAlignment: .center)
        cancelReply.accessibilityLabelOverride = "Cancel reply"
        replyRow.addArrangedSubview(CCIconView("text-bubble", pointSize: 13, weight: .medium, tint: CCTheme.color.mutedForeground))
        replyRow.addArrangedSubview(replyLabel)
        replyRow.addArrangedSubview(UIView())
        replyRow.addArrangedSubview(cancelReply)
        replyRow.spacing = CCSpace.sm
        replyRow.alignment = .center
        replyRow.isHidden = true
        field.returnKeyType = .send
        field.accessibilityLabel = "Comment"
        timeChip.setContentCompressionResistancePriority(.required, for: .horizontal)
        sendButton.accessibilityLabelOverride = "Post comment"
        sendButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let main = UIStackView(arrangedSubviews: [timeChip, field, sendButton])
        main.spacing = CCSpace.sm
        main.alignment = .center
        errorLabel.isHidden = true
        errorLabel.accessibilityTraits = .staticText
        stack.axis = .vertical
        stack.spacing = CCSpace.xs + 2
        for view in [identityRow, replyRow, main, errorLabel] as [UIView] { stack.addArrangedSubview(view) }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            rule.topAnchor.constraint(equalTo: topAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: CCSpace.sm),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -CCSpace.sm),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 720),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.leadingAnchor, constant: CCSpace.gutter),
        ])
        let fill = stack.widthAnchor.constraint(equalTo: safeAreaLayoutGuide.widthAnchor, constant: -CCSpace.gutter * 2)
        fill.priority = .required - 1
        fill.isActive = true
        ccOnThemeChange { [weak self] in self?.backgroundColor = CCTheme.color.background }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Signed in: "Commenting as Ana". Signed out: the optional name + Sign in.
    func setIdentity(signedInAs name: String?) {
        identityRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let name {
            identityLabel.text = "Commenting as \(name)"
            identityRow.addArrangedSubview(identityLabel)
        } else {
            identityRow.addArrangedSubview(nameField)
            identityRow.addArrangedSubview(signInButton)
        }
    }

    var isSignedOutLayout: Bool { nameField.superview === identityRow }

    /// The reply strip grows in at the composer's TOP edge (the pushed edge).
    func setReplying(to name: String?) {
        let show = name != nil
        if let name { replyLabel.text = "Replying to \(name)" }
        guard replyRow.isHidden == show else { return }
        if CCMotion.reduceMotion {
            CCMotion.crossFade(stack) { self.replyRow.isHidden = !show }
        } else {
            replyRow.isHidden = !show
            if show {
                CCMotion.spring(replyRow.layer, keyPath: "transform.translation.y", from: 8, to: 0, .bouncy)
                CCMotion.fade(replyRow.layer, keyPath: "opacity", to: 1, duration: 0.18, from: 0)
            }
        }
        timeChip.isHidden = show  // a reply carries its parent's moment
    }

    func showError(_ text: String?) {
        errorLabel.text = text
        errorLabel.isHidden = text == nil
        if let text { CCAccessibility.announce(text) }
    }
}

// MARK: - Glyphs

/// Emoji and marker faces drawn as IMAGES: they are pictures inside one
/// labelled control (a reaction key, a scrubber marker), not text — VoiceOver
/// reads the control's label, and Dynamic Type grows the page's words, not
/// the faces on a fixed-size track.
enum ShareGlyph {
    static func text(_ text: String, pointSize: CGFloat, color: UIColor = .label) -> UIImage {
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: pointSize, weight: .bold), .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attributes)
        let format = UIGraphicsImageRendererFormat.preferred()
        return UIGraphicsImageRenderer(size: CGSize(width: ceil(size.width), height: ceil(size.height)), format: format).image { _ in
            (text as NSString).draw(at: .zero, withAttributes: attributes)
        }
    }

    /// The commenter's face: CCAvatar's colour (same name → same hue) and initials.
    static func avatar(_ name: String, side: CGFloat) -> UIImage {
        var hash: UInt32 = 5381
        for byte in name.utf8 { hash = (hash &<< 5) &+ hash &+ UInt32(byte) }
        let fill = UIColor(hue: CGFloat(hash % 360) / 360, saturation: 0.45, brightness: 0.72, alpha: 1)
        let parts = name.split(whereSeparator: { $0 == " " || $0 == "@" || $0 == "." }).prefix(2)
        let initials = parts.compactMap { $0.first.map(String.init) }.joined().uppercased() as NSString
        let font = UIFont.systemFont(ofSize: side * 0.4, weight: .semibold)
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            fill.setFill()
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: side, height: side)).fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]
            let size = initials.size(withAttributes: attributes)
            initials.draw(at: CGPoint(x: (side - size.width) / 2, y: (side - size.height) / 2), withAttributes: attributes)
        }
    }
}
