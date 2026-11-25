import AVFoundation
import UIKit

/// A shared video: the exported file in the house player (the stream URL
/// with the bearer header — private shares need it), its link (copy, system
/// share sheet), privacy, the "Allow comments" switch (PATCH /api/video/:id/
/// comments-enabled: the change shows at once, rolls back with a toast if the
/// API refuses; disabled with the reason when the plan has no comments), and
/// the comment thread: one-level threads, author, relative time, a timestamp
/// chip that seeks the player, and a composer that posts at the current
/// playhead (or a quiet note when comments are off).
final class ShareDetailViewController: DetailPageViewController {
    let videoID: String
    private weak var coordinator: LibraryCoordinator?
    private let playerCard = PlayerCard()
    private let titleLabel: UILabel = {
        let label = ccLabel("", font: CCFont.title, color: CCTheme.color.foreground, lines: 3)
        label.ccWrapsAtAccessibilitySizes(otherwise: 3)
        return label
    }()
    private let metaLabel = ccLabel("", font: CCFont.caption, color: CCTheme.color.mutedForeground, lines: 2)
    private let privacyBadge = CCBadge(String(localized: "Unlisted", comment: "Share privacy badge (initial value)"), symbol: "link")
    private let linkLabel = ccLabel("", font: CCFont.caption, color: CCTheme.color.mutedForeground)
    private let privacyExplain = ccLabel("", font: CCFont.caption, color: CCTheme.color.mutedForeground, lines: 2)
    private let openProjectButton = CCButton(title: String(localized: "Open the project", comment: "Button: open the project this share came from"), symbol: "film", style: .ghost, size: .sm)
    private let commentsHeader = ccLabel(String(localized: "Comments", comment: "Section heading above a share's comments"), font: CCFont.labelSemibold, color: CCTheme.color.mutedForeground)
    private let commentsStack = UIStackView()
    private let commentsSpinner = CCSpinner(diameter: 20)
    private let composer = UIView()
    private let composerField = CCField(placeholder: String(localized: "Add a comment…"))
    private let timeChip = CCBadge(String(localized: "at \("0:00")", comment: "Comment composer time chip; the value is a timestamp"), symbol: "timer")
    private let postButton = CCButton(title: String(localized: "Post", comment: "Button: post the comment"), style: .primary, size: .regular)
    private let offNote = CCCallout(message: String(localized: "Comments are off. Viewers of this link can't read or add comments."), variant: .info)
    private let commentsToggle = CCToggleRow(title: String(localized: "Allow comments", comment: "Toggle on the share page"), detail: ShareDetailViewController.commentsDetail)
    /// The plan includes viewer comments (GET /api/me); nil until known.
    private(set) var planAllowsComments: Bool?
    private var planName: String?
    /// A switch the API hasn't answered yet (the toggle shows it meanwhile).
    private var pendingComments: Bool?
    static let commentsDetail = String(localized: "Viewers can leave timestamped comments and drawings.")

    private var comments: [VideoComment] = []
    private var observation: SurfaceObservation?
    private var didLoadPlayer = false
    private var scrollToComposer: NSLayoutConstraint?

    init(videoID: String, coordinator: LibraryCoordinator?) {
        self.videoID = videoID
        self.coordinator = coordinator
        let name = LibraryStore.shared.share(videoID).map { ($0.fileName as NSString).deletingPathExtension } ?? String(localized: "Shared video", comment: "Title for a share whose file name is unknown")
        super.init(title: name)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        let shareButton = CCButton(symbol: "share", style: .ghost, size: .regular, radius: .full)
        shareButton.accessibilityLabelOverride = String(localized: "Share link", comment: "VoiceOver: share button on the share page")
        shareButton.onTap = { [weak self, weak shareButton] in
            guard let self, let shareButton, let share = LibraryStore.shared.share(self.videoID) else { return }
            ProjectActions.shareSheet(share, from: self, source: shareButton)
        }
        header.setTrailing([shareButton])

        let titleRow = UIStackView(arrangedSubviews: [titleLabel, metaLabel, privacyBadge])
        titleRow.axis = .vertical
        titleRow.spacing = CCSpace.xs + 2
        titleRow.alignment = .leading
        titleRow.setCustomSpacing(CCSpace.sm, after: metaLabel)

        let linkCard = makeLinkCard()

        commentsStack.axis = .vertical
        commentsStack.spacing = CCSpace.md
        commentsSpinner.color = CCTheme.color.mutedForeground
        commentsHeader.accessibilityTraits = .header
        let commentsTitle = UIStackView(arrangedSubviews: [commentsHeader, commentsSpinner, UIView()])
        commentsTitle.spacing = CCSpace.sm
        commentsTitle.alignment = .center
        let commentsCard = CCCard(radius: .lg)
        commentsStack.translatesAutoresizingMaskIntoConstraints = false
        commentsCard.addSubview(commentsStack)
        NSLayoutConstraint.activate([
            commentsStack.leadingAnchor.constraint(equalTo: commentsCard.leadingAnchor, constant: CCSpace.lg),
            commentsStack.trailingAnchor.constraint(equalTo: commentsCard.trailingAnchor, constant: -CCSpace.lg),
            commentsStack.topAnchor.constraint(equalTo: commentsCard.topAnchor, constant: CCSpace.lg),
            commentsStack.bottomAnchor.constraint(equalTo: commentsCard.bottomAnchor, constant: -CCSpace.lg),
        ])
        commentsToggle.onChange = { [weak self] on in self?.setComments(on) }
        let toggleCard = CCCard(radius: .lg)
        commentsToggle.translatesAutoresizingMaskIntoConstraints = false
        toggleCard.addSubview(commentsToggle)
        NSLayoutConstraint.activate([
            commentsToggle.leadingAnchor.constraint(equalTo: toggleCard.leadingAnchor, constant: CCSpace.lg),
            commentsToggle.trailingAnchor.constraint(equalTo: toggleCard.trailingAnchor, constant: -CCSpace.lg),
            commentsToggle.topAnchor.constraint(equalTo: toggleCard.topAnchor, constant: CCSpace.xs),
            commentsToggle.bottomAnchor.constraint(equalTo: toggleCard.bottomAnchor, constant: -CCSpace.xs),
        ])
        let commentsSection = UIStackView(arrangedSubviews: [commentsTitle, toggleCard, offNote, commentsCard])
        commentsSection.axis = .vertical
        commentsSection.spacing = CCSpace.sm
        offNote.isHidden = true

        for view in [playerCard, titleRow, linkCard, commentsSection] as [UIView] { column.addArrangedSubview(view) }
        column.setCustomSpacing(CCSpace.md, after: playerCard)
        buildComposer()

        playerCard.player.onTimeChange = { [weak self] time in
            self?.timeChip.text = String(localized: "at \(Format.duration(time))", comment: "Comment composer time chip; the value is a timestamp")
        }
        playerCard.player.onFailure = { [weak self] error in
            guard let self else { return }
            if error == nil {
                self.loadPlayer(startAt: self.playerCard.player.currentTime, autoplay: true)
            } else {
                self.playerCard.player.showError(String(localized: "Couldn't play this video. Check your connection and try again."))
            }
        }
        observation = SurfaceObservation { [weak self] in self?.render() }
        loadComments()
        loadPlan()
    }

    // MARK: - Allow comments

    /// Which plan governs the switch (turning comments ON needs `comments`).
    private func loadPlan() {
        Task { @MainActor [weak self] in
            guard let info = try? await AppEnvironment.shared.api.me() else { return }
            self?.planAllowsComments = info.features["comments"] == true && info.features["cloudShare"] != false
            self?.planName = info.planDisplayName
            self?.render()
        }
    }

    /// Optimistic: the thread opens / closes at once; a refusal puts it back
    /// and says why (a CCKit toast).
    func setComments(_ on: Bool) {
        guard pendingComments == nil, let share = LibraryStore.shared.share(videoID) else { return }
        let before = share.commentsEnabled == true
        guard on != before else { return }
        pendingComments = on
        LibraryStore.shared.setCommentsEnabled(videoID, on)
        render()  // at once: the thread opens / closes under the finger
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let stored = try await AppEnvironment.shared.api.setCommentsEnabled(videoID: self.videoID, enabled: on)
                self.pendingComments = nil
                LibraryStore.shared.setCommentsEnabled(self.videoID, stored)
                self.render()
                if stored { self.loadComments() }
                AppToaster.shared.show(title: stored ? String(localized: "Comments on", comment: "Toast after enabling comments") : String(localized: "Comments off", comment: "Toast after disabling comments"),
                                       message: stored ? String(localized: "Anyone with the link can comment.") : String(localized: "Viewers can't read or add comments."),
                                       variant: .success)
            } catch {
                #if DEBUG
                if ShareViewerModel.probeInject == "toggle-no-rollback" {
                    self.pendingComments = nil
                    return
                }
                #endif
                self.pendingComments = nil
                LibraryStore.shared.setCommentsEnabled(self.videoID, before)
                self.commentsToggle.setOn(before, animated: true)
                self.render()
                CCHaptics.warning()
                AppToaster.shared.show(title: on ? String(localized: "Couldn't turn comments on") : String(localized: "Couldn't turn comments off"),
                                       message: error.localizedDescription, variant: .destructive)
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent || navigationController == nil { playerCard.player.pause() }
    }

    private func makeLinkCard() -> UIView {
        let card = CCCard(radius: .lg)
        linkLabel.lineBreakMode = .byTruncatingMiddle
        // Accessibility text sizes: the whole link, wrapped.
        linkLabel.ccWrapsAtAccessibilitySizes()
        let copy = CCButton(title: String(localized: "Copy link", comment: "Button: copy the share link"), symbol: "link", style: .secondary, size: .regular)
        copy.onTap = { [weak self] in
            guard let self, let share = LibraryStore.shared.share(self.videoID) else { return }
            ProjectActions.copyLink(share)
        }
        let shareButton = CCButton(title: String(localized: "Share…", comment: "Button: open the system share sheet for the link"), symbol: "share", style: .secondary, size: .regular)
        shareButton.onTap = { [weak self, weak shareButton] in
            guard let self, let shareButton, let share = LibraryStore.shared.share(self.videoID) else { return }
            ProjectActions.shareSheet(share, from: self, source: shareButton)
        }
        openProjectButton.onTap = { [weak self] in
            guard let self, let id = LibraryStore.shared.share(self.videoID)?.projectId else { return }
            self.coordinator?.pushProject(id, from: self)
        }
        let pair = UIStackView(arrangedSubviews: [copy, shareButton])
        pair.spacing = CCSpace.sm
        pair.distribution = .fillEqually
        let buttons = UIStackView(arrangedSubviews: [pair, openProjectButton])
        buttons.axis = .vertical
        buttons.spacing = CCSpace.sm
        let stack = UIStackView(arrangedSubviews: [linkLabel, privacyExplain, buttons])
        stack.axis = .vertical
        stack.spacing = CCSpace.xs
        stack.setCustomSpacing(CCSpace.md, after: privacyExplain)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: CCSpace.lg),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -CCSpace.lg),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: CCSpace.lg),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -CCSpace.lg),
        ])
        return card
    }

    private func buildComposer() {
        composer.translatesAutoresizingMaskIntoConstraints = false
        composer.backgroundColor = CCTheme.color.background
        let rule = CCDivider()
        composerField.returnKeyType = .send
        composerField.onReturn = { [weak self] _ in self?.post() }
        composerField.accessibilityLabel = String(localized: "Comment", comment: "VoiceOver label of the comment text field")
        postButton.onTap = { [weak self] in self?.post() }
        postButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        timeChip.accessibilityLabel = String(localized: "Posts at the current playback time")
        let fieldRow = UIStackView(arrangedSubviews: [composerField, postButton])
        fieldRow.spacing = CCSpace.sm
        fieldRow.alignment = .center
        let stack = UIStackView(arrangedSubviews: [timeChip, fieldRow])
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = CCSpace.xs + 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        fieldRow.translatesAutoresizingMaskIntoConstraints = false
        composer.addSubview(rule)
        composer.addSubview(stack)
        view.addSubview(composer)
        // The composer rides the keyboard; the scroll view ends above it.
        scrollToComposer = scrollView.bottomAnchor.constraint(equalTo: composer.topAnchor)
        NSLayoutConstraint.activate([
            composer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            rule.topAnchor.constraint(equalTo: composer.topAnchor),
            rule.leadingAnchor.constraint(equalTo: composer.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: composer.trailingAnchor),
            stack.topAnchor.constraint(equalTo: composer.topAnchor, constant: CCSpace.sm + 2),
            stack.bottomAnchor.constraint(equalTo: composer.bottomAnchor, constant: -CCSpace.sm),
            stack.centerXAnchor.constraint(equalTo: composer.safeAreaLayoutGuide.centerXAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 720),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: composer.safeAreaLayoutGuide.leadingAnchor, constant: CCSpace.gutter),
            fieldRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        let fill = stack.widthAnchor.constraint(equalTo: composer.safeAreaLayoutGuide.widthAnchor, constant: -CCSpace.gutter * 2)
        fill.priority = .required - 1
        fill.isActive = true
        view.keyboardLayoutGuide.followsUndockedKeyboard = true
    }

    // MARK: - Render

    private func render() {
        let store = LibraryStore.shared
        guard let share = store.share(videoID) else { return }
        let privacy = SharePrivacy(video: share, extras: store.shareExtras[share.videoId])
        let name = (share.fileName as NSString).deletingPathExtension
        header.title = name
        titleLabel.text = name
        var meta = [String(localized: "Shared \(Format.relative(share.createdAt))", comment: "Share page meta line; the value is a relative date like 2 days ago")]
        if let duration = share.durationSeconds { meta.append(Format.duration(duration)) }
        if let bytes = share.fileSizeBytes { meta.append(Format.bytes(bytes)) }
        metaLabel.text = meta.joined(separator: " · ")
        privacyBadge.text = privacy.title
        privacyBadge.setSymbol(privacy.symbol)
        linkLabel.text = share.url.absoluteString
        privacyExplain.text = privacy.explanation
        openProjectButton.isHidden = share.projectId.flatMap { store.project($0) } == nil
        let enabled = pendingComments ?? (share.commentsEnabled == true)
        if commentsToggle.isOn != enabled { commentsToggle.setOn(enabled, animated: commentsToggle.window != nil) }
        // Off can always be switched; on needs a plan with comments.
        let blocked = planAllowsComments == false && !enabled
        commentsToggle.isEnabled = !blocked && pendingComments == nil
        let reason = planName.map { String(localized: "Your \($0) plan doesn't include viewer comments. Upgrade at app.capturecat.so/billing to turn them on.", comment: "The value is the plan name, e.g. Free") }
            ?? String(localized: "Your current plan doesn't include viewer comments. Upgrade at app.capturecat.so/billing to turn them on.")
        commentsToggle.accessibilityHint = blocked ? reason : Self.commentsDetail
        commentsToggle.setDetail(blocked ? reason : Self.commentsDetail)
        offNote.isHidden = enabled
        composer.isHidden = !enabled
        if enabled {
            scrollBottom.isActive = false
            scrollToComposer?.isActive = true
        } else {
            scrollToComposer?.isActive = false
            scrollBottom.isActive = true
        }
        if !didLoadPlayer {
            didLoadPlayer = true
            if let removed = share.removed {
                playerCard.player.showError(removed.reason.map { String(localized: "CaptureCat removed this video: \($0)", comment: "The value is the moderation reason from the server") } ?? String(localized: "CaptureCat removed this video."))
            } else {
                loadPlayer(startAt: 0, autoplay: false)
            }
        }
    }

    private func loadPlayer(startAt: Double, autoplay: Bool) {
        playerCard.player.load(AppEnvironment.shared.api.streamAsset(videoID: videoID), startAt: startAt, autoplay: autoplay)
    }

    // MARK: - Comments

    private func loadComments() {
        commentsSpinner.startAnimating()
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.commentsSpinner.stopAnimating() }
            do {
                self.comments = try await AppEnvironment.shared.api.comments(videoID: self.videoID)
                self.renderComments(animatedNewID: nil)
            } catch {
                self.renderComments(animatedNewID: nil, error: error.localizedDescription)
            }
        }
    }

    private func renderComments(animatedNewID: String?, error: String? = nil) {
        commentsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        commentsHeader.text = comments.isEmpty ? String(localized: "Comments", comment: "Section heading above a share's comments") : String(localized: "Comments · \(comments.count)", comment: "Section heading with the comment count")
        if let error {
            commentsStack.addArrangedSubview(ccLabel(String(localized: "Couldn't load comments. \(error)", comment: "The value is the error message"), font: CCFont.label, color: CCTheme.color.mutedForeground, lines: 0))
            return
        }
        if comments.isEmpty {
            let empty = ccLabel(String(localized: "No comments yet. Add one at any moment of the video — it's pinned to that time."),
                                font: CCFont.label, color: CCTheme.color.mutedForeground, lines: 0)
            commentsStack.addArrangedSubview(empty)
            return
        }
        let roots = comments.filter { $0.parentId == nil }.sorted { $0.createdAt < $1.createdAt }
        let replies = Dictionary(grouping: comments.filter { $0.parentId != nil }, by: { $0.parentId! })
        var first = true
        for root in roots {
            if !first { commentsStack.addArrangedSubview(CCDivider()) }
            first = false
            commentsStack.addArrangedSubview(row(for: root, reply: false, isNew: root.commentId == animatedNewID))
            for reply in (replies[root.commentId] ?? []).sorted(by: { $0.createdAt < $1.createdAt }) {
                commentsStack.addArrangedSubview(row(for: reply, reply: true, isNew: reply.commentId == animatedNewID))
            }
        }
        // Replies whose parent isn't in the list still show.
        let rootIDs = Set(roots.map(\.commentId))
        for orphan in comments where orphan.parentId != nil && !rootIDs.contains(orphan.parentId!) {
            commentsStack.addArrangedSubview(row(for: orphan, reply: false, isNew: false))
        }
    }

    private func row(for comment: VideoComment, reply: Bool, isNew: Bool) -> UIView {
        let view = CommentRowView(comment: comment, reply: reply)
        view.onSeek = { [weak self] time in
            guard let self else { return }
            self.playerCard.player.seek(to: time)
            self.playerCard.player.play()
            self.scrollView.setContentOffset(CGPoint(x: 0, y: -self.scrollView.adjustedContentInset.top), animated: true)
        }
        if isNew {
            DispatchQueue.main.async { CCMotion.stagger([view], distance: 10) }
        }
        return view
    }

    private func post() {
        let text = (composerField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !postButton.isBusy else {
            if text.isEmpty { composerField.isError = true; CCHaptics.warning() }
            return
        }
        composerField.isError = false
        let time = playerCard.player.currentTime
        postButton.isBusy = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.postButton.isBusy = false }
            do {
                let comment = try await AppEnvironment.shared.api.postComment(videoID: self.videoID, body: text, videoTime: time, parentID: nil)
                self.comments.append(comment)
                self.composerField.text = ""
                self.composerField.resignFirstResponder()
                self.renderComments(animatedNewID: comment.commentId)
                CCHaptics.success()
                AppToaster.shared.show(title: String(localized: "Comment posted"), message: String(localized: "At \(Format.duration(time))", comment: "Toast detail after posting a comment; the value is a timestamp"), variant: .success)
            } catch {
                AppToaster.shared.show(title: String(localized: "Couldn't post", comment: "Toast when posting a comment fails"), message: error.localizedDescription, variant: .destructive)
            }
        }
    }

    // Probe seams.
    var probePlayerCard: PlayerCard { playerCard }
    var probeComposerField: CCField { composerField }
    var probeCommentsToggle: CCToggleRow { commentsToggle }
    var probeComposer: UIView { composer }
    var probeOffNote: CCCallout { offNote }
}

/// One comment: avatar, author (+ "Owner"), relative time, timestamp chip
/// (seeks the player), body. Replies indent one level behind a rule.
final class CommentRowView: UIView {
    var onSeek: ((Double) -> Void)?

    init(comment: VideoComment, reply: Bool) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let avatar = CCAvatar(name: comment.authorName, side: reply ? 26 : 32)
        let author = ccLabel(comment.authorName, font: CCFont.labelSemibold, color: CCTheme.color.foreground)
        author.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        author.ccWrapsAtAccessibilitySizes()
        let time = ccLabel(Format.relative(comment.createdAt), font: CCFont.caption, color: CCTheme.color.mutedForeground)
        time.setContentCompressionResistancePriority(.required, for: .horizontal)
        var topItems: [UIView] = [author]
        if comment.isOwner { topItems.append(CCBadge(String(localized: "Owner", comment: "Badge on a comment written by the video's owner"), variant: .outline)) }
        topItems.append(time)
        topItems.append(UIView())
        let top = UIStackView(arrangedSubviews: topItems)
        top.spacing = CCSpace.sm
        top.alignment = .center
        let body = ccLabel(comment.body, font: CCFont.body, color: CCTheme.color.foreground, lines: 0)
        let textStack = UIStackView(arrangedSubviews: [top, body])
        textStack.axis = .vertical
        textStack.spacing = CCSpace.xs
        textStack.alignment = .fill
        if let videoTime = comment.videoTime {
            let chip = CCButton(title: Format.duration(videoTime), symbol: "play-fill", style: .secondary, size: .regular, radius: .full)
            chip.accessibilityLabelOverride = String(localized: "Play from \(Format.spokenDuration(videoTime))", comment: "VoiceOver: comment timestamp chip; the value is a spoken time")
            chip.onTap = { [weak self] in self?.onSeek?(videoTime) }
            let chipRow = UIStackView(arrangedSubviews: [chip, UIView()])
            textStack.insertArrangedSubview(chipRow, at: 1)
            textStack.setCustomSpacing(CCSpace.xs + 2, after: top)
        }
        let row = UIStackView(arrangedSubviews: [avatar, textStack])
        row.spacing = CCSpace.md
        row.alignment = .top
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        var leading: CGFloat = 0
        if reply {
            leading = 22
            let rule = UIView()
            rule.backgroundColor = CCTheme.color.border
            rule.translatesAutoresizingMaskIntoConstraints = false
            addSubview(rule)
            NSLayoutConstraint.activate([
                rule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15),
                rule.widthAnchor.constraint(equalToConstant: 2),
                rule.topAnchor.constraint(equalTo: topAnchor),
                rule.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            rule.layer.cornerRadius = 1
        }
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leading),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isAccessibilityElement = false
        let authorName = comment.authorName
        let when = Format.relative(comment.createdAt)
        if reply {
            author.accessibilityLabel = comment.isOwner
                ? String(localized: "Reply from \(authorName), owner, \(when)", comment: "VoiceOver: reply header by the video owner; values are the author and a relative date")
                : String(localized: "Reply from \(authorName), \(when)", comment: "VoiceOver: reply header; values are the author and a relative date")
        } else if let videoTime = comment.videoTime {
            let spokenTime = Format.spokenDuration(videoTime)
            author.accessibilityLabel = comment.isOwner
                ? String(localized: "Comment from \(authorName), owner, \(when), at \(spokenTime)", comment: "VoiceOver: comment header by the video owner; values are the author, a relative date and a spoken video time")
                : String(localized: "Comment from \(authorName), \(when), at \(spokenTime)", comment: "VoiceOver: comment header; values are the author, a relative date and a spoken video time")
        } else {
            author.accessibilityLabel = comment.isOwner
                ? String(localized: "Comment from \(authorName), owner, \(when)", comment: "VoiceOver: comment header by the video owner; values are the author and a relative date")
                : String(localized: "Comment from \(authorName), \(when)", comment: "VoiceOver: comment header; values are the author and a relative date")
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
