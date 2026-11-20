import UIKit

/// A row in the library list.
nonisolated enum LibraryRow: Hashable, Sendable {
    case take(String)
    case project(String)
    case share(String)
    case status(String)
    case skeleton(Int)
}

// MARK: - Card (project or share)

/// A library card — the Mac browser's ProjectCardItem on a phone: a matte
/// thumbnail well (radius md, 1 pt border-token edge, film/photo glyph while
/// it loads), the name on one line (medium), and the Mac's meta line
/// "2:14 · 2 hr ago · shared". iPhone/Screenshot markers ride the thumbnail's
/// corner as dark content pills (like the Mac's pin badge). The card itself is
/// a ghost: press washes it in place; the current card (two-pane) lifts onto
/// a raised chip.
final class LibraryCardCell: UICollectionViewCell {
    static let reuse = "LibraryCardCell"
    static let thumbAspect: CGFloat = 10.0 / 16.0

    private let surface = CCSurface(.raised, tint: CCTheme.color.card, radius: .lg)
    private let wash = UIView()
    private let thumbHost = CCSurface(.raisedMatte, tint: CCTheme.color.card, radius: .md)
    private let thumb = UIImageView()
    private let placeholder = CCIconView("film", pointSize: 24, weight: .regular, tint: CCTheme.color.faintForeground)
    private let markers = UIStackView()
    private let titleLabel = ccLabel("", font: CCFont.labelMedium, color: CCTheme.color.foreground)
    private let metaLabel = ccLabel("", font: CCFont.caption, color: CCTheme.color.mutedForeground)
    private var observation: SurfaceObservation?
    private var row: LibraryRow?
    private var markerKey = ""

    var isCurrent = false {
        didSet {
            guard isCurrent != oldValue else { return }
            applyTheme(animated: true)
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Accessibility text sizes: name and details wrap instead of truncating.
        titleLabel.ccWrapsAtAccessibilitySizes()
        // Longer languages ("6:02 · há 2 dias · compartilhado") take a second line.
        metaLabel.ccWrapsAtAccessibilitySizes(otherwise: 2)
        surface.isUserInteractionEnabled = false
        surface.alpha = 0
        contentView.addSubview(surface)
        wash.isUserInteractionEnabled = false
        wash.layer.cornerCurve = .continuous
        wash.alpha = 0
        wash.backgroundColor = CCTheme.color.hover
        wash.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(wash)
        contentView.addSubview(thumbHost)
        thumbHost.ccOnThemeChange { [weak self] in self?.applyBorder() }
        thumb.clipsToBounds = true
        thumb.layer.cornerCurve = .continuous
        thumb.translatesAutoresizingMaskIntoConstraints = false
        thumbHost.addSubview(placeholder)
        thumbHost.addSubview(thumb)
        markers.spacing = 4
        markers.translatesAutoresizingMaskIntoConstraints = false
        thumbHost.addSubview(markers)
        for view in [titleLabel, metaLabel] as [UIView] { contentView.addSubview(view) }

        let inset: CGFloat = 6
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            surface.topAnchor.constraint(equalTo: contentView.topAnchor),
            surface.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            wash.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            wash.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            wash.topAnchor.constraint(equalTo: contentView.topAnchor),
            wash.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            thumbHost.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: inset),
            thumbHost.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -inset),
            thumbHost.topAnchor.constraint(equalTo: contentView.topAnchor, constant: inset),
            thumbHost.heightAnchor.constraint(equalTo: thumbHost.widthAnchor, multiplier: Self.thumbAspect),
            thumb.leadingAnchor.constraint(equalTo: thumbHost.leadingAnchor),
            thumb.trailingAnchor.constraint(equalTo: thumbHost.trailingAnchor),
            thumb.topAnchor.constraint(equalTo: thumbHost.topAnchor),
            thumb.bottomAnchor.constraint(equalTo: thumbHost.bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: thumbHost.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: thumbHost.centerYAnchor),
            markers.leadingAnchor.constraint(equalTo: thumbHost.leadingAnchor, constant: 6),
            markers.topAnchor.constraint(equalTo: thumbHost.topAnchor, constant: 6),
            markers.trailingAnchor.constraint(lessThanOrEqualTo: thumbHost.trailingAnchor, constant: -6),
            titleLabel.topAnchor.constraint(equalTo: thumbHost.bottomAnchor, constant: CCSpace.sm),
            titleLabel.leadingAnchor.constraint(equalTo: thumbHost.leadingAnchor, constant: 2),
            titleLabel.trailingAnchor.constraint(equalTo: thumbHost.trailingAnchor, constant: -2),
            metaLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            metaLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            metaLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            metaLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -(inset + 4)),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        applyTheme(animated: false)
        applyBorder()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func prepareForReuse() {
        super.prepareForReuse()
        observation?.cancel()
        observation = nil
        thumb.image = nil
        row = nil
        isCurrent = false
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        wash.layer.cornerRadius = CCTheme.radius(.lg)
        thumb.layer.cornerRadius = CCTheme.radius(.md)
    }

    private func applyBorder() {
        thumbHost.layer.borderWidth = 1
        thumbHost.layer.borderColor = thumbHost.cc(CCTheme.color.border)
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            applyTheme(animated: true)
        }
    }

    private func applyTheme(animated: Bool) {
        let surfaceAlpha: CGFloat = isCurrent ? 1 : 0
        let washAlpha: CGFloat = isHighlighted ? 1 : 0
        if animated, window != nil {
            CCMotion.fadeAlpha(surface, to: surfaceAlpha, duration: 0.22)
            CCMotion.fadeAlpha(wash, to: washAlpha, duration: isHighlighted ? 0.06 : 0.22)
        } else {
            surface.alpha = surfaceAlpha
            wash.alpha = washAlpha
        }
    }

    // MARK: - Binding

    func bind(_ row: LibraryRow) {
        self.row = row
        observation?.cancel()
        observation = SurfaceObservation { [weak self] in self?.render() }
    }

    /// The Mac's relative time ("1 wk ago").
    static func shortRelative(_ date: Date) -> String {
        if abs(date.timeIntervalSinceNow) < 60 { return String(localized: "just now", comment: "Short relative time on a library card, lowercase (less than a minute ago)") }
        let formatter = RelativeDateTimeFormatter()
        // French's abbreviated form is the bare "-3 h"; its short form reads
        // "il y a 3 h" (every other catalog language words both the same).
        formatter.unitsStyle = Locale.current.language.languageCode == .french ? .short : .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func render() {
        guard let row else { return }
        let store = LibraryStore.shared
        let thumbs = ThumbnailStore.shared
        switch row {
        case .project(let id):
            guard let project = store.project(id) else { return }
            let facts = store.facts(for: project)
            let shared = store.share(linkedTo: project.projectId) != nil
            let still = facts?.isStillCapture == true
            titleLabel.text = project.name
            var meta: [String] = []
            if !still, let duration = facts?.trimmedDuration ?? facts?.duration { meta.append(Format.duration(duration)) }
            meta.append(Self.shortRelative(project.updatedAt))
            if shared { meta.append(String(localized: "shared", comment: "Library card metadata: the project has a share link (lowercase, joined with ·)")) }
            if !project.isOwner { meta.append(String(localized: "team", comment: "Library card metadata: a team member's project (lowercase, joined with ·)")) }
            metaLabel.text = meta.joined(separator: " · ")
            // One marker per card (narrow cards can't fit two): a screenshot
            // says so; otherwise an iPhone take says that.
            if still {
                setMarkers([(String(localized: "Screenshot", comment: "Badge on a library card thumbnail"), "photo")])
            } else if facts?.sourceKind == "device" {
                setMarkers([("iPhone", "iphone")])
            } else {
                setMarkers([])
            }
            placeholder.iconName = still ? "photo" : "film"
            setThumbnail(thumbs.image(for: project))
            var spoken = [project.name, still ? String(localized: "Screenshot", comment: "VoiceOver: kind of library item") : String(localized: "Recording", comment: "VoiceOver: kind of library item")]
            if facts?.sourceKind == "device" { spoken.append(String(localized: "from iPhone", comment: "VoiceOver: library item was recorded on an iPhone")) }
            if !still, let duration = facts?.trimmedDuration ?? facts?.duration { spoken.append(Format.spokenDuration(duration)) }
            spoken.append(String(localized: "edited \(Format.relative(project.updatedAt))", comment: "VoiceOver: argument is a relative time like '2 hours ago'"))
            if shared { spoken.append(String(localized: "shared", comment: "VoiceOver: the project has a share link")) }
            if !project.isOwner { spoken.append(String(localized: "team project", comment: "VoiceOver: a team member's project")) }
            accessibilityLabel = spoken.joined(separator: ", ")
            accessibilityHint = String(localized: "Opens the recording. Touch and hold for more actions.")
        case .share(let id):
            guard let share = store.share(id) else { return }
            let privacy = SharePrivacy(video: share, extras: store.shareExtras[share.videoId])
            titleLabel.text = (share.fileName as NSString).deletingPathExtension
            var meta: [String] = []
            if let duration = share.durationSeconds { meta.append(Format.duration(duration)) }
            meta.append(Self.shortRelative(share.createdAt))
            meta.append(share.removed != nil ? String(localized: "removed", comment: "Library card metadata: the shared video was removed (lowercase, joined with ·)") : privacy.title.lowercased())
            metaLabel.text = meta.joined(separator: " · ")
            setMarkers([(String(localized: "Shared", comment: "Badge on a library card thumbnail: a shared video link"), "link")])
            placeholder.iconName = "film"
            setThumbnail(thumbs.image(for: share))
            accessibilityLabel = [titleLabel.text ?? "", String(localized: "Shared video", comment: "VoiceOver: kind of library item"), privacy.title, Format.spokenDuration(share.durationSeconds),
                                  String(localized: "shared \(Format.relative(share.createdAt))", comment: "VoiceOver: argument is a relative time like '2 hours ago'")].joined(separator: ", ")
            accessibilityHint = String(localized: "Opens the shared video and its comments.")
        default:
            break
        }
    }

    private func setMarkers(_ items: [(String, String)]) {
        let key = items.map(\.0).joined(separator: ",")
        guard key != markerKey else { return }
        markerKey = key
        markers.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for item in items {
            markers.addArrangedSubview(ContentPill(text: item.0, symbol: item.1))
        }
    }

    private func setThumbnail(_ image: UIImage?) {
        guard thumb.image !== image else { return }
        let portrait = (image?.size.width ?? 1) < (image?.size.height ?? 0)
        thumb.contentMode = portrait ? .scaleAspectFit : .scaleAspectFill
        if image != nil, thumb.image == nil, window != nil {
            thumb.image = image
            thumb.alpha = 0
            CCMotion.fadeAlpha(thumb, to: 1, duration: 0.25, from: 0)
        } else {
            thumb.image = image
        }
        placeholder.isHidden = image != nil
    }

    // Probe seams.
    var probeSurfaceLayer: CALayer { surface.layer }
}

/// A small dark pill OVER content (markers on thumbnails, like the Mac's pin
/// badge): fixed light-on-dark — content is never themed.
final class ContentPill: UIView {
    init(text: String, symbol: String? = nil) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = UIColor.black.withAlphaComponent(0.55)
        layer.cornerCurve = .continuous
        let label = UILabel()
        label.text = text
        label.font = CCFont.scaled(11, .semibold, .caption2, max: 14)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .white
        let views: [UIView] = [symbol.map { CCIconView($0, pointSize: 9.5, weight: .semibold, tint: .white) }, label].compactMap { $0 }
        let row = UIStackView(arrangedSubviews: views)
        row.spacing = 3
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 2.5),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2.5),
        ])
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = CCRadius.full.resolved(for: bounds.height)
    }
}

// MARK: - Inbox take

/// A take from this iPhone that hasn't reached the cloud yet: what it is,
/// where the upload stands (springing progress bar), Retry / Discard. Used
/// by the library (in a cell) and the Capture tab.
final class InboxTakeView: CCCard {
    private let tile = CCIconTile(symbol: "screen-record")
    private var icon: CCIconView { tile.icon }
    private let titleLabel = ccLabel("", font: CCFont.labelSemibold, color: CCTheme.color.foreground)
    private let statusLabel = ccLabel("", font: CCFont.caption, color: CCTheme.color.mutedForeground, lines: 2)
    private let progressBar = CCProgressBar()
    private let retryButton = CCButton(title: String(localized: "Retry", comment: "Button: retry a failed upload"), symbol: "sync", style: .secondary, size: .regular)
    private let discardButton = CCButton(symbol: "close", style: .ghost, size: .regular, radius: .full)
    /// Studio 5c: open the take in the editor (its upload then happens from there).
    private let editButton = CCButton(symbol: "scissors", style: .ghost, size: .regular, radius: .full)
    private var observation: SurfaceObservation?
    private(set) var takeID: String?
    var onDiscard: ((PendingTake) -> Void)?

    init() {
        super.init(radius: .lg)
        discardButton.accessibilityLabelOverride = String(localized: "Discard", comment: "Accessibility label: delete an un-uploaded recording")
        let text = UIStackView(arrangedSubviews: [titleLabel, statusLabel, progressBar])
        text.axis = .vertical
        text.spacing = 3
        text.setCustomSpacing(CCSpace.sm, after: statusLabel)
        let actions = UIStackView(arrangedSubviews: [editButton, retryButton, discardButton])
        actions.spacing = CCSpace.xs
        actions.alignment = .center
        let row = UIStackView(arrangedSubviews: [tile, text, actions])
        row.spacing = CCSpace.md
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        // Accessibility text sizes: icon, words and keys stack; the words wrap.
        row.ccStacksAtAccessibilitySizes()
        titleLabel.ccWrapsAtAccessibilitySizes()
        statusLabel.ccWrapsAtAccessibilitySizes(otherwise: 2)
        progressBar.accessibilityLabel = String(localized: "Upload progress")
        addSubview(row)
        actions.setContentCompressionResistancePriority(.required, for: .horizontal)
        actions.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CCSpace.md),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CCSpace.sm),
            row.topAnchor.constraint(equalTo: topAnchor, constant: CCSpace.md),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -CCSpace.md),
        ])
        retryButton.onTap = { [weak self] in
            guard let id = self?.takeID else { return }
            AppEnvironment.shared.inbox.retry(id)
        }
        editButton.accessibilityLabelOverride = String(localized: "Edit", comment: "Accessibility label: open the recording in the editor")
        editButton.onTap = { [weak self] in
            guard let self, let id = self.takeID, let take = AppEnvironment.shared.inbox.takes.first(where: { $0.id == id }) else { return }
            var responder: UIResponder? = self
            while let next = responder, !(next is UIViewController) { responder = next.next }
            guard #available(iOS 26, *), let presenter = responder as? UIViewController else { return }
            StudioEditorEntry.open(take: take, from: presenter)
        }
        discardButton.onTap = { [weak self] in
            guard let self, let id = self.takeID, let take = AppEnvironment.shared.inbox.takes.first(where: { $0.id == id }) else { return }
            self.onDiscard?(take)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func bind(takeID: String?) {
        self.takeID = takeID
        observation?.cancel()
        observation = takeID == nil ? nil : SurfaceObservation { [weak self] in self?.render() }
    }

    private func render() {
        let inbox = AppEnvironment.shared.inbox
        guard let takeID, let take = inbox.takes.first(where: { $0.id == takeID }) else { return }
        let progress = inbox.progress[takeID]
        titleLabel.text = take.name
        switch take.kind {
        case .screenRecording: icon.iconName = "screen-record"
        case .screenshot: icon.iconName = "photo"
        case .importedVideo: icon.iconName = "film"
        }
        var status: String
        var statusColor = CCTheme.color.mutedForeground
        var showsProgress = false
        switch take.state {
        case .recording:
            status = String(localized: "Recording…", comment: "Upload status: still recording")
        case .pending:
            status = String(localized: "Waiting to upload")
        case .uploading:
            let overall = Self.overall(progress)
            let message = progress?.message ?? String(localized: "Uploading…", comment: "Upload status")
            let percent = Int((overall * 100).rounded())
            status = String(localized: "\(message) \(percent)%", comment: "Upload status line: first argument is the phase (e.g. Uploading…), second is the percentage")
            showsProgress = true
            progressBar.value = overall
        case .failed:
            let reason = take.error ?? String(localized: "try again", comment: "Fallback reason after 'Upload failed —' (lowercase)")
            status = String(localized: "Upload failed — \(reason)", comment: "Upload status; argument is the error message")
            statusColor = CCTheme.color.destructive
        }
        if take.state == .pending, let progress {
            progressBar.value = Self.overall(progress)
            showsProgress = true
            status = progress.message
        }
        if take.openedInStudio == true, take.state == .pending {
            status = String(localized: "In the editor — uploads with your edits")
        }
        statusLabel.text = status
        statusLabel.textColor = statusColor
        if progressBar.isHidden == showsProgress { progressBar.isHidden = !showsProgress }
        retryButton.isHidden = take.state != .failed
        editButton.isHidden = !StudioEditorEntry.isAvailable || !(take.state == .pending || take.state == .failed)
        discardButton.isHidden = take.state == .uploading || take.state == .recording
        accessibilityElements = [titleLabel, statusLabel, progressBar, editButton, retryButton, discardButton].filter { !$0.isHidden }
    }

    /// One 0…1 across the publish phases.
    static func overall(_ progress: PublishProgress?) -> Double {
        guard let progress else { return 0 }
        let (start, span): (Double, Double)
        switch progress.phase {
        case .preparing: (start, span) = (0, 0.12)
        case .uploading: (start, span) = (0.12, 0.76)
        case .verifying: (start, span) = (0.88, 0.06)
        case .saving: (start, span) = (0.94, 0.05)
        case .done: (start, span) = (1, 0)
        }
        return min(1, start + span * max(0, min(1, progress.fraction)))
    }
}

final class InboxTakeCell: UICollectionViewCell {
    static let reuse = "InboxTakeCell"
    let takeView = InboxTakeView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(takeView)
        NSLayoutConstraint.activate([
            takeView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            takeView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            takeView.topAnchor.constraint(equalTo: contentView.topAnchor),
            takeView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func prepareForReuse() {
        super.prepareForReuse()
        takeView.bind(takeID: nil)
    }

    func bind(takeID: String, onDiscard: @escaping (PendingTake) -> Void) {
        takeView.onDiscard = onDiscard
        takeView.bind(takeID: takeID)
    }
}

// MARK: - Status line + skeleton + header

final class LibraryStatusCell: UICollectionViewCell {
    static let reuse = "LibraryStatusCell"
    private let spinner = CCSpinner(diameter: 16)
    private let label = ccLabel("", font: CCFont.caption, color: CCTheme.color.mutedForeground, lines: 2, alignment: .center)

    override init(frame: CGRect) {
        super.init(frame: frame)
        spinner.color = CCTheme.color.mutedForeground
        let row = UIStackView(arrangedSubviews: [spinner, label])
        row.spacing = CCSpace.sm
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            row.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: CCSpace.md),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -CCSpace.md),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ text: String, spinning: Bool) {
        label.text = text
        if spinning { spinner.startAnimating() } else { spinner.stopAnimating() }
    }
}

/// Loading placeholder card: the same geometry, pulsing softly (no sheen).
final class SkeletonCardCell: UICollectionViewCell {
    static let reuse = "SkeletonCardCell"
    private let block = UIView()
    private let line1 = UIView()
    private let line2 = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        for view in [block, line1, line2] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.layer.cornerCurve = .continuous
            view.backgroundColor = CCTheme.color.elevated
            contentView.addSubview(view)
        }
        NSLayoutConstraint.activate([
            block.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 6),
            block.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6),
            block.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            block.heightAnchor.constraint(equalTo: block.widthAnchor, multiplier: LibraryCardCell.thumbAspect),
            line1.topAnchor.constraint(equalTo: block.bottomAnchor, constant: 12),
            line1.leadingAnchor.constraint(equalTo: block.leadingAnchor, constant: 4),
            line1.widthAnchor.constraint(equalTo: block.widthAnchor, multiplier: 0.7),
            line1.heightAnchor.constraint(equalToConstant: 12),
            line2.topAnchor.constraint(equalTo: line1.bottomAnchor, constant: 8),
            line2.leadingAnchor.constraint(equalTo: line1.leadingAnchor),
            line2.widthAnchor.constraint(equalTo: block.widthAnchor, multiplier: 0.4),
            line2.heightAnchor.constraint(equalToConstant: 10),
            line2.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        block.layer.cornerRadius = CCTheme.radius(.md)
        line1.layer.cornerRadius = CCRadius.full.resolved(for: 12)
        line2.layer.cornerRadius = CCRadius.full.resolved(for: 10)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, contentView.layer.animation(forKey: "pulse") == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.45
        pulse.duration = 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CCMotion.glide
        pulse.isRemovedOnCompletion = false
        contentView.layer.add(pulse, forKey: "pulse")
    }
}

final class LibrarySectionHeader: UICollectionReusableView {
    static let reuse = "LibrarySectionHeader"
    let label = ccLabel("", font: CCFont.labelSemibold, color: CCTheme.color.mutedForeground)

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(label)
        label.accessibilityTraits = .header
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor, constant: CCSpace.sm),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -CCSpace.xs),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
