import AVFoundation
import UIKit

/// One cloud project: the ORIGINAL recording in the house player (the phone
/// doesn't render edits — they play on the Mac and the web), its share if it
/// has one (play the exported share instead, copy the link, share sheet),
/// facts, and Rename / Open in web editor / Delete.
final class ProjectDetailViewController: DetailPageViewController {
    enum Source {
        case original
        case share
    }

    let projectID: String
    private weak var coordinator: LibraryCoordinator?
    private let playerCard = PlayerCard()
    private let sourceSwitch = CCSegmented(segments: ["Original", "Shared video"], size: .sm, radius: .full)
    private let captionIcon = CCIconView("info-fill", pointSize: 12, weight: .semibold, tint: CCTheme.color.faintForeground)
    private let captionLabel = ccLabel("", font: CCFont.caption, color: CCTheme.color.mutedForeground, lines: 0)
    private let titleLabel = ccLabel("", font: CCFont.title, color: CCTheme.color.foreground, lines: 3)
    private let badges = UIStackView()
    private let infoCard = InfoCard()
    private let shareSection = UIStackView()
    private let shareCard = CCCard(radius: .lg)
    private let shareTitle = ccLabel("", font: CCFont.labelSemibold, color: CCTheme.color.foreground)
    private let shareURL = ccLabel("", font: CCFont.caption, color: CCTheme.color.mutedForeground)
    private let shareExplain = ccLabel("", font: CCFont.caption, color: CCTheme.color.mutedForeground, lines: 2)
    private let privacyBadge = CCBadge("Unlisted", symbol: "link")
    private let commentsButton = CCButton(title: "Comments on the shared video", symbol: "text-bubble", style: .ghost, size: .sm)
    private let actionsCard = ActionListCard()
    private var observation: SurfaceObservation?
    private var source: Source = .original
    private var retriedFreshURL = false
    private var loadedSource: Source?
    private var observers: [NSObjectProtocol] = []
    private var badgeKey = ""
    private var actionsKey = ""
    private var missingView: UIView?

    init(projectID: String, coordinator: LibraryCoordinator?) {
        self.projectID = projectID
        self.coordinator = coordinator
        super.init(title: LibraryStore.shared.project(projectID)?.name ?? "Recording")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        let web = CCButton(symbol: "globe", style: .ghost, size: .regular, radius: .full)
        web.accessibilityLabelOverride = "Open in web editor"
        web.onTap = { [weak self] in
            guard let self else { return }
            ProjectActions.openInWebEditor(projectID: self.projectID)
        }
        header.setTrailing([web])

        sourceSwitch.isHidden = true
        sourceSwitch.onChange = { [weak self] index in self?.switchSource(index == 0 ? .original : .share) }
        let switchRow = UIStackView(arrangedSubviews: [sourceSwitch, UIView()])
        switchRow.isHidden = true
        sourceSwitch.widthAnchor.constraint(lessThanOrEqualToConstant: 280).isActive = true
        let switchFill = sourceSwitch.widthAnchor.constraint(equalTo: switchRow.widthAnchor)
        switchFill.priority = .defaultLow
        switchFill.isActive = true

        let caption = UIStackView(arrangedSubviews: [captionIcon, captionLabel])
        caption.spacing = 6
        caption.alignment = .firstBaseline
        captionIcon.setContentHuggingPriority(.required, for: .horizontal)

        badges.spacing = CCSpace.xs
        badges.alignment = .center
        let titleBlock = UIStackView(arrangedSubviews: [titleLabel, badges])
        titleBlock.axis = .vertical
        titleBlock.spacing = CCSpace.sm
        titleBlock.alignment = .leading

        buildShareCard()
        shareSection.axis = .vertical
        shareSection.spacing = CCSpace.sm
        shareSection.addArrangedSubview(sectionLabel("Shared link"))
        shareSection.addArrangedSubview(shareCard)
        shareSection.isHidden = true

        let playerBlock = UIStackView(arrangedSubviews: [switchRow, playerCard, caption])
        playerBlock.axis = .vertical
        playerBlock.spacing = CCSpace.sm
        playerBlock.setCustomSpacing(CCSpace.md, after: switchRow)
        for view in [playerBlock, titleBlock, infoCard, shareSection, actionsCard] as [UIView] {
            column.addArrangedSubview(view)
        }
        column.setCustomSpacing(CCSpace.xl, after: titleBlock)
        self.switchRow = switchRow

        playerCard.player.onFailure = { [weak self] error in self?.playerFailed(error) }
        observation = SurfaceObservation { [weak self] in self?.render() }
        observers.append(NotificationCenter.default.addObserver(forName: .ccAppDidBecomeActive, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshURLsIfExpiring() }
        })
        loadPlayer(startAt: 0, autoplay: false)
    }

    private var switchRow: UIView?

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent || navigationController == nil { playerCard.player.pause() }
    }

    // MARK: - Render (observation loop)

    private func render() {
        let store = LibraryStore.shared
        guard let project = store.project(projectID) else {
            if store.phase == .loaded { showMissing() }
            return
        }
        let facts = store.facts(for: project)
        let share = store.share(linkedTo: projectID)
        header.title = project.name
        titleLabel.text = project.name

        var badgeItems: [(String, String)] = []
        if facts?.sourceKind == "device" { badgeItems.append(("iPhone", "iphone")) }
        if facts?.isStillCapture == true { badgeItems.append(("Screenshot", "photo")) }
        if share != nil { badgeItems.append(("Shared", "link")) }
        if !project.isOwner { badgeItems.append(("Team", "person-fill")) }
        let key = badgeItems.map(\.0).joined(separator: ",")
        if key != badgeKey {
            badgeKey = key
            badges.arrangedSubviews.forEach { $0.removeFromSuperview() }
            badgeItems.forEach { badges.addArrangedSubview(CCBadge($0.0, symbol: $0.1)) }
            badges.isHidden = badgeItems.isEmpty
        }

        var rows: [(String, String)] = []
        if facts?.isStillCapture == true {
            rows.append(("Kind", "Screenshot"))
        } else if let duration = facts?.trimmedDuration ?? facts?.duration {
            rows.append(("Length", Format.duration(duration)))
            if let full = facts?.duration, abs(full - duration) > 0.5 { rows.append(("Original length", Format.duration(full))) }
        }
        rows.append(("Size", Format.bytes(project.totalBytes)))
        rows.append(("Created", Format.dateTime(project.createdAt)))
        rows.append(("Last edited", Format.relative(project.updatedAt)))
        if let kind = facts?.sourceKind { rows.append(("Captured on", kind == "device" ? "iPhone" : "Mac or web")) }
        if !project.isOwner { rows.append(("Access", "Shared with your team")) }
        infoCard.setRows(rows)

        // Share section + source switch.
        if let share {
            let privacy = SharePrivacy(video: share, extras: store.shareExtras[share.videoId])
            shareTitle.text = (share.fileName as NSString).deletingPathExtension
            shareURL.text = share.url.absoluteString
            shareExplain.text = privacy.explanation
            privacyBadge.text = privacy.title
            privacyBadge.setSymbol(privacy.symbol)
            commentsButton.isHidden = share.commentsEnabled != true
            if shareSection.isHidden { shareSection.isHidden = false }
            if switchRow?.isHidden == true {
                switchRow?.isHidden = false
                sourceSwitch.isHidden = false
            }
        } else {
            shareSection.isHidden = true
            switchRow?.isHidden = true
            if source == .share { switchSource(.original) }
        }
        captionLabel.text = source == .original
            ? "Original recording — edits play on Mac and the web."
            : "The shared video, exactly as exported."

        var actions: [ActionListCard.Action] = [
            .init(title: "Rename", symbol: "pencil") { [weak self] _ in
                guard let self, let project = LibraryStore.shared.project(self.projectID) else { return }
                ProjectActions.promptRename(projectID: self.projectID, currentName: project.name, from: self)
            },
            .init(title: "Open in web editor", symbol: "globe") { [weak self] _ in
                guard let self else { return }
                ProjectActions.openInWebEditor(projectID: self.projectID)
            },
        ]
        if project.isOwner {
            actions.append(.init(title: "Delete project", symbol: "trash", destructive: true) { [weak self] _ in
                guard let self, let project = LibraryStore.shared.project(self.projectID) else { return }
                ProjectActions.confirmDelete(projectID: self.projectID, name: project.name, from: self) { [weak self] in
                    guard let self else { return }
                    self.playerCard.player.pause()
                    self.coordinator?.projectDeleted(self.projectID)
                }
            })
        }
        let newKey = actions.map(\.title).joined()
        if newKey != actionsKey {
            actionsKey = newKey
            actionsCard.setActions(actions)
        }
    }

    private func buildShareCard() {
        let icon = CCIconView("link", pointSize: 15, weight: .semibold, tint: CCTheme.color.mutedForeground)
        let top = UIStackView(arrangedSubviews: [icon, shareTitle, privacyBadge, UIView()])
        top.spacing = CCSpace.sm
        top.alignment = .center
        shareTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        shareURL.lineBreakMode = .byTruncatingMiddle
        let copy = CCButton(title: "Copy link", symbol: "link", style: .secondary, size: .sm)
        copy.onTap = { [weak self] in
            guard let self, let share = LibraryStore.shared.share(linkedTo: self.projectID) else { return }
            ProjectActions.copyLink(share)
        }
        let shareButton = CCButton(title: "Share…", symbol: "share", style: .secondary, size: .sm)
        shareButton.onTap = { [weak self, weak shareButton] in
            guard let self, let shareButton, let share = LibraryStore.shared.share(linkedTo: self.projectID) else { return }
            ProjectActions.shareSheet(share, from: self, source: shareButton)
        }
        commentsButton.onTap = { [weak self] in
            guard let self, let share = LibraryStore.shared.share(linkedTo: self.projectID) else { return }
            self.coordinator?.pushShare(share.videoId, from: self)
        }
        let pair = UIStackView(arrangedSubviews: [copy, shareButton])
        pair.spacing = CCSpace.sm
        pair.distribution = .fillEqually
        let buttons = UIStackView(arrangedSubviews: [pair, commentsButton])
        buttons.axis = .vertical
        buttons.spacing = CCSpace.sm
        let stack = UIStackView(arrangedSubviews: [top, shareURL, shareExplain, buttons])
        stack.axis = .vertical
        stack.spacing = CCSpace.xs + 2
        stack.setCustomSpacing(CCSpace.md, after: shareExplain)
        stack.translatesAutoresizingMaskIntoConstraints = false
        shareCard.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: shareCard.leadingAnchor, constant: CCSpace.lg),
            stack.trailingAnchor.constraint(equalTo: shareCard.trailingAnchor, constant: -CCSpace.lg),
            stack.topAnchor.constraint(equalTo: shareCard.topAnchor, constant: CCSpace.lg),
            stack.bottomAnchor.constraint(equalTo: shareCard.bottomAnchor, constant: -CCSpace.lg),
        ])
    }

    // MARK: - Playback

    private func switchSource(_ new: Source) {
        guard new != source else { return }
        let wasPlaying = playerCard.player.isPlaying
        source = new
        sourceSwitch.setSelectedIndex(new == .original ? 0 : 1)
        captionLabel.text = new == .original ? "Original recording — edits play on Mac and the web." : "The shared video, exactly as exported."
        loadPlayer(startAt: 0, autoplay: wasPlaying)
    }

    private func loadPlayer(startAt: Double, autoplay: Bool, fresh: Bool = false) {
        let player = playerCard.player
        switch source {
        case .share:
            guard let share = LibraryStore.shared.share(linkedTo: projectID) else { return }
            loadedSource = .share
            player.load(AppEnvironment.shared.api.streamAsset(videoID: share.videoId), startAt: startAt, autoplay: autoplay)
        case .original:
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let detail = try await LibraryStore.shared.detail(for: self.projectID, fresh: fresh)
                    guard self.source == .original else { return }
                    let facts = LibraryStore.shared.project(self.projectID).flatMap { LibraryStore.shared.facts(for: $0) }
                    guard let file = ThumbnailStore.recordingFile(in: detail, facts: facts) else {
                        player.showError("This project has no recording to play yet.")
                        return
                    }
                    self.loadedSource = .original
                    player.load(AVURLAsset(url: file.url), startAt: startAt, autoplay: autoplay)
                    self.urlsExpireAt = detail.urlsExpireAt
                } catch {
                    if case APIError.http(404, _, _) = error { self.showMissing(); return }
                    player.showError(error.localizedDescription)
                }
            }
        }
    }

    private var urlsExpireAt: Date?

    /// The presigned URL expired (or the network blinked): fetch fresh URLs
    /// once and resume where playback was.
    private func playerFailed(_ error: Error?) {
        let player = playerCard.player
        let resumeAt = player.currentTime
        if source == .original, !retriedFreshURL || error == nil {
            retriedFreshURL = error != nil
            loadPlayer(startAt: resumeAt, autoplay: error == nil ? true : player.isPlaying, fresh: true)
        } else if source == .share, error == nil {
            loadPlayer(startAt: resumeAt, autoplay: true)
        } else {
            player.showError("Couldn't play this video. Check your connection and try again.")
        }
    }

    private func refreshURLsIfExpiring() {
        guard source == .original, let expiry = urlsExpireAt, expiry.timeIntervalSinceNow < 60, !playerCard.player.isPlaying else { return }
        retriedFreshURL = false
        loadPlayer(startAt: playerCard.player.currentTime, autoplay: false, fresh: true)
    }

    private func showMissing() {
        guard missingView == nil else { return }
        playerCard.player.pause()
        let empty = CCEmptyState(symbol: "film", title: "This project isn't in your library anymore",
                                 message: "It may have been deleted on another device.",
                                 primary: CCButton(title: "Back to library", style: .primary) { [weak self] in
                                     guard let self else { return }
                                     self.coordinator?.projectDeleted(self.projectID)
                                 })
        column.arrangedSubviews.forEach { $0.isHidden = true }
        column.addArrangedSubview(empty)
        missingView = empty
    }

    // Probe seams.
    var probePlayerCard: PlayerCard { playerCard }
}
