import AVFoundation
import UIKit

/// The in-app share viewer — what a CaptureCat share link opens on a phone or
/// iPad with the app. It does what the web share page does
/// (apps/web/src/routes/share.$videoId.tsx), by the API's rules:
///
///  • the video, with a captions toggle when the share has a transcript;
///    commenter avatars on the scrubber at their moments, reactions dotted
///    under it; elapsed / remaining;
///  • the title (AI title or the cleaned file name) and "date · length ·
///    Shared via CaptureCat";
///  • six reaction keys — one reaction per viewer at the current moment, the
///    same one again takes it back (optimistic, rolled back on failure) — and
///    the tallies as chips;
///  • Comments · Summary · Transcript tabs, each only when the share has it;
///    comments sort by video time (the web's order), oldest or newest;
///    timestamp chips seek; Reply threads one level deep;
///  • a composer pinned above the keyboard: the moment it will post at, the
///    field, send. Anyone may comment (the web's rule) — signed out with an
///    optional name, or signed in as yourself ("Sign in" reuses the app's flow);
///  • password-protected shares unlock here; expired / view-limit / paused /
///    private / removed / missing shares say so; comments-off hides the tab
///    and the composer;
///  • the share menu: Copy link, Share…, Open in browser, Download (when the
///    owner allows it), Report video;
///  • the view counts for the owner (the web's analytics beacon).
final class ShareViewerViewController: DetailPageViewController {
    let model: ShareViewerModel
    var videoID: String { model.videoID }
    private let startAt: Double?

    private let surface = ShareVideoSurface()
    private var surfaceHeight: NSLayoutConstraint!
    private var aspect: CGFloat = 9.0 / 16.0
    private let timeline = ShareTimelineView()
    private let playKey = CCButton(symbol: "play-fill", style: .ghost, size: .regular, radius: .full)
    private let captionsKey = CCButton(title: "Captions", symbol: "captions", style: .ghost, size: .sm, radius: .full)
    private let transportRow = UIStackView()
    private let stateHost = UIStackView()
    private let titleLabel: UILabel = {
        let label = ccLabel("", font: CCFont.title, color: CCTheme.color.foreground, lines: 3)
        label.ccWrapsAtAccessibilitySizes(otherwise: 3)
        label.accessibilityTraits = .header
        return label
    }()
    private let bylineLabel = ccLabel("", font: CCFont.caption, color: CCTheme.color.mutedForeground, lines: 0)
    private let ctaButton = CCButton(title: "", symbol: "arrow-up-right", style: .primary, size: .regular, radius: .full)
    private let reactionBar = ShareReactionBar()
    private var tabs: CCSegmented?
    private let tabsHost = UIStackView()
    private let panel = UIStackView()
    private let commentsCountLabel = ccLabel("", font: CCFont.labelSemibold, color: CCTheme.color.foreground)
    private let sortButton = CCButton(title: "Video order", symbol: "chevron-up-down", style: .ghost, size: .sm, radius: .full)
    private let commentsStack = UIStackView()
    private let summaryStack = UIStackView()
    private let transcriptStack = UIStackView()
    private let composer = ShareComposerView()
    private var scrollToComposer: NSLayoutConstraint!
    private let shareKey = CCButton(symbol: "share", style: .ghost, size: .regular, radius: .full)
    private let closeKey = CCButton(symbol: "close", style: .ghost, size: .regular, radius: .full)
    private lazy var toaster = CCToaster(host: view)

    enum Tab: String { case comments = "Comments", summary = "Summary", transcript = "Transcript" }
    enum Sort: String, CaseIterable { case videoTime = "Video order", oldest = "Oldest first", newest = "Newest first" }

    private(set) var tabOrder: [Tab] = []
    private(set) var selectedTab: Tab = .comments
    private(set) var sort: Sort = .videoTime
    private(set) var captionsOn = false
    private(set) var replyingTo: VideoComment?
    /// The moment the comment being written is anchored to (the web's draftTime).
    private(set) var draftTime: Double?
    private var observation: SurfaceObservation?
    private var loadedPlayerFor: String?
    private var renderedComments: [VideoComment] = []
    private var renderedSort: Sort?
    private var renderedTranscriptCount = -1
    private var activeTranscriptIndex: Int?
    private var lastSeenPulse = 0
    private var sessionObserver: NSObjectProtocol?
    private var ended = false

    init(link: ShareLink) {
        model = ShareViewerModel(videoID: link.videoID)
        startAt = link.startAt
        super.init(title: "CaptureCat")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        shareKey.accessibilityLabelOverride = "Share and more"
        shareKey.onTap = { [weak self] in self?.presentShareMenu() }
        closeKey.accessibilityLabelOverride = "Close"
        closeKey.onTap = { [weak self] in self?.close() }
        header.setTrailing([shareKey, closeKey])

        buildPlayer()
        buildDetails()
        buildComposer()
        column.spacing = CCSpace.md
        for view in [stateHost, surface, timeline, transportRow, titleLabel, bylineLabel, ctaButton, reactionBar, tabsHost, panel] as [UIView] {
            column.addArrangedSubview(view)
        }
        column.setCustomSpacing(CCSpace.xs, after: surface)
        column.setCustomSpacing(CCSpace.xs, after: titleLabel)
        column.setCustomSpacing(CCSpace.lg, after: transportRow)
        column.setCustomSpacing(CCSpace.lg, after: reactionBar)

        sessionObserver = NotificationCenter.default.addObserver(forName: .ccSessionDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.refreshSignedIn()
                if self.model.commentsEnabled { Task { await self.model.loadComments() } }
            }
        }
        observation = SurfaceObservation { [weak self] in self?.render() }
        Task { await model.load() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isBeingDismissed { surface.pause(); model.close() }
    }

    override var keyCommands: [UIKeyCommand]? {
        let space = UIKeyCommand(title: "Play / Pause", action: #selector(keyTogglePlay), input: " ")
        space.wantsPriorityOverSystemBehavior = true
        return [space, UIKeyCommand(title: "Close", action: #selector(keyClose), input: UIKeyCommand.inputEscape)]
    }

    @objc private func keyTogglePlay() {
        guard !composer.field.isFirstResponder, !composer.nameField.isFirstResponder else { return }
        surface.togglePlay()
    }

    @objc private func keyClose() { close() }

    func close() {
        surface.pause()
        model.close()
        dismiss(animated: !CCMotion.reduceMotion)
    }

    // MARK: - Build

    private func buildPlayer() {
        surface.translatesAutoresizingMaskIntoConstraints = false
        surfaceHeight = surface.heightAnchor.constraint(equalToConstant: 200)
        surfaceHeight.priority = .required - 1
        surfaceHeight.isActive = true
        surface.onTime = { [weak self] time in self?.timeChanged(time) }
        surface.onPlayingChange = { [weak self] playing in
            guard let self else { return }
            self.playKey.symbol = playing ? "pause-fill" : "play-fill"
            self.playKey.accessibilityLabelOverride = playing ? "Pause" : "Play"
            self.model.track(playing ? "play" : "pause", at: self.surface.currentTime)
            if !playing, self.surface.duration > 0, self.surface.currentTime >= self.surface.duration - 0.15, !self.ended {
                self.ended = true
                self.model.track("ended", at: self.surface.currentTime)
                self.model.flush()
            }
            if playing { self.ended = false }
        }
        surface.onPresentationSize = { [weak self] size in self?.setAspect(size.height / size.width) }
        surface.onFailure = { [weak self] _ in
            self?.toaster.show(title: "Couldn't play this video", message: "Check your connection and try again.", variant: .destructive)
        }
        timeline.onSeek = { [weak self] time, ended in
            guard let self else { return }
            self.surface.setScrubbing(!ended)
            self.surface.seek(to: time)
            if ended { self.model.track("seek", at: time) }
        }
        timeline.onJump = { [weak self] comment in self?.jump(to: comment) }
        playKey.accessibilityLabelOverride = "Play"
        playKey.onTap = { [weak self] in self?.surface.togglePlay() }
        captionsKey.accessibilityLabelOverride = "Captions"
        captionsKey.onTap = { [weak self] in self?.toggleCaptions() }
        transportRow.addArrangedSubview(playKey)
        transportRow.addArrangedSubview(UIView())
        transportRow.addArrangedSubview(captionsKey)
        transportRow.alignment = .center
        transportRow.spacing = CCSpace.sm
        stateHost.axis = .vertical
    }

    private func buildDetails() {
        ctaButton.onTap = { [weak self] in
            guard let self, let text = self.model.meta?.ctaUrl, let url = URL(string: text),
                  ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return }
            self.model.track("cta", at: self.surface.currentTime)
            self.model.flush()
            UIApplication.shared.open(url)
        }
        reactionBar.onReact = { [weak self] emoji in self?.react(emoji) }
        tabsHost.axis = .vertical
        panel.axis = .vertical
        panel.spacing = CCSpace.md
        for stack in [commentsStack, summaryStack, transcriptStack] {
            stack.axis = .vertical
            stack.spacing = CCSpace.md
        }
        transcriptStack.spacing = 0
        summaryStack.spacing = CCSpace.xs
        commentsCountLabel.accessibilityTraits = .header
        sortButton.symbolPlacement = .trailing
        sortButton.accessibilityLabelOverride = "Sort comments"
        sortButton.onTap = { [weak self] in self?.presentSortMenu() }
    }

    private func buildComposer() {
        view.addSubview(composer)
        scrollToComposer = scrollView.bottomAnchor.constraint(equalTo: composer.topAnchor)
        NSLayoutConstraint.activate([
            composer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        view.keyboardLayoutGuide.followsUndockedKeyboard = true
        composer.isHidden = true
        composer.field.onReturn = { [weak self] _ in self?.post() }
        composer.field.addAction(UIAction { [weak self] _ in self?.startDraft() }, for: .editingDidBegin)
        composer.sendButton.onTap = { [weak self] in self?.post() }
        composer.timeChip.onTap = { [weak self] in
            guard let self else { return }
            self.seek(to: self.draftTime ?? self.surface.currentTime, play: false)
        }
        composer.cancelReply.onTap = { [weak self] in self?.setReply(nil) }
        composer.signInButton.onTap = { [weak self] in self?.signIn() }
    }

    // MARK: - Render (state → views)

    private func render() {
        let model = self.model
        switch model.phase {
        case .loading:
            showState(nil, loading: true)
        case .open:
            showState(nil, loading: false)
            renderOpen()
        case let .gated(gate, fileName):
            showState(ShareStateCard.gate(gate, fileName: ShareMeta.prettyFileName(fileName), onUnlock: { [weak self] password in
                try await self?.model.unlock(password: password)
            }), loading: false)
        case let .removed(message):
            showState(ShareStateCard.removed(message), loading: false)
        case .privateVideo:
            showState(ShareStateCard.privateVideo(signedIn: model.signedInName != nil, onSignIn: { [weak self] in self?.signIn() }), loading: false)
        case .notFound:
            showState(ShareStateCard.notFound(), loading: false)
        case let .failed(message):
            showState(ShareStateCard.failed(message, retry: { [weak self] in
                guard let self else { return }
                Task { await self.model.load() }
            }), loading: false)
        }
        _ = model.signedInName
        _ = model.comments
        _ = model.reactions
        _ = model.myEmoji
        _ = model.transcript
        _ = model.transcriptLoaded
        _ = model.commentsLoaded
        _ = model.commentViewer
        _ = model.reactionPulse
    }

    private var currentState: ShareStateCard?

    private func showState(_ card: ShareStateCard?, loading: Bool) {
        let open = card == nil && !loading
        for view in [surface, timeline, transportRow, titleLabel, bylineLabel, reactionBar, tabsHost, panel] as [UIView] {
            view.isHidden = !open
        }
        ctaButton.isHidden = !open || model.meta?.ctaLabel?.isEmpty != false || model.meta?.ctaUrl == nil
        let showComposer = open && model.commentsEnabled
        if composer.isHidden == showComposer {
            composer.isHidden = !showComposer
            scrollBottom.isActive = !showComposer
            scrollToComposer.isActive = showComposer
        }
        if loading {
            if !(stateHost.arrangedSubviews.first is CCSpinnerCard) {
                stateHost.arrangedSubviews.forEach { $0.removeFromSuperview() }
                stateHost.addArrangedSubview(CCSpinnerCard())
            }
        } else if let card {
            if currentState?.kind != card.kind {
                stateHost.arrangedSubviews.forEach { $0.removeFromSuperview() }
                stateHost.addArrangedSubview(card)
                currentState = card
                CCMotion.dissolve(card.layer)
                UIAccessibility.post(notification: .layoutChanged, argument: card)
            }
        } else {
            stateHost.arrangedSubviews.forEach { $0.removeFromSuperview() }
            currentState = nil
        }
        stateHost.isHidden = stateHost.arrangedSubviews.isEmpty
    }

    private func renderOpen() {
        guard let meta = model.meta else { return }
        let title = model.isOwnerPrivate ? ShareMeta.prettyFileName(meta.fileName) : meta.displayTitle
        titleLabel.text = title
        var byline: [String] = []
        if let date = meta.createdDate { byline.append(date.formatted(date: .abbreviated, time: .omitted)) }
        if let duration = meta.durationSeconds, duration > 0 { byline.append(Format.duration(duration)) }
        byline.append(model.isOwnerPrivate ? "Private — only you can watch it" : "Shared via CaptureCat")
        bylineLabel.text = byline.joined(separator: " · ")
        if let label = meta.ctaLabel, !label.isEmpty { ctaButton.title = label }
        captionsKey.isHidden = !model.hasTranscript
        reactionBar.isHidden = !model.reactionsEnabled
        if loadedPlayerFor != model.videoID + (model.shareToken ?? "") {
            loadedPlayerFor = model.videoID + (model.shareToken ?? "")
            surface.load(model.api.streamAsset(model.videoID, token: model.shareToken, version: meta.currentVersion),
                         startAt: startAt ?? 0, knownDuration: meta.durationSeconds)
            if startAt != nil { surface.play() }
        }
        timeline.setTime(surface.currentTime, duration: surface.duration > 0 ? surface.duration : (meta.durationSeconds ?? 0))
        timeline.setContent(comments: model.comments, reactions: model.reactions)
        reactionBar.render(counts: model.reactionCounts, mine: model.myEmoji)
        if let pulse = model.reactionPulse, pulse.serial != lastSeenPulse {
            lastSeenPulse = pulse.serial
            let duration = max(surface.duration, meta.durationSeconds ?? 0)
            surface.spawnFloater(pulse.emoji, ratio: CGFloat(ShareMarkerMath.ratio(pulse.time, duration: duration)))
            reactionBar.keys.first { $0.emoji == pulse.emoji }?.pop()
        }
        composer.setIdentity(signedInAs: model.commentViewer?.name ?? model.signedInName)
        renderTabs()
        renderPanel()
    }

    private func renderTabs() {
        var order: [Tab] = []
        if model.commentsEnabled { order.append(.comments) }
        if model.hasSummaryTab { order.append(.summary) }
        if model.hasTranscript { order.append(.transcript) }
        let titles = order.map { tab -> String in
            tab == .comments && model.commentsLoaded ? "Comments \(model.comments.count)" : tab.rawValue
        }
        if order != tabOrder {
            tabOrder = order
            tabsHost.arrangedSubviews.forEach { $0.removeFromSuperview() }
            if !tabOrder.contains(selectedTab), let first = tabOrder.first { selectedTab = first }
            if order.count > 1 {
                let control = CCSegmented(segments: titles, selectedIndex: order.firstIndex(of: selectedTab) ?? 0) { [weak self] index in
                    self?.select(tab: self?.tabOrder[index] ?? .comments)
                }
                tabs = control
                tabsHost.addArrangedSubview(control)
            } else {
                tabs = nil
            }
        } else if let tabs {
            for (index, title) in titles.enumerated() { tabs.setTitle(title, at: index) }
        }
        tabsHost.isHidden = tabOrder.count < 2
    }

    func select(tab: Tab, animated: Bool = true) {
        guard tabOrder.contains(tab) else { return }
        if let index = tabOrder.firstIndex(of: tab) { tabs?.setSelectedIndex(index, animated: animated) }
        guard tab != selectedTab else { return }
        selectedTab = tab
        if tab == .transcript { Task { await model.loadTranscript() } }
        if animated {
            CCMotion.crossFade(panel) { self.renderPanel() }
        } else {
            renderPanel()
        }
    }

    private func renderPanel() {
        let wanted: UIView? = tabOrder.isEmpty ? nil : {
            switch selectedTab {
            case .comments: return commentsStack
            case .summary: return summaryStack
            case .transcript: return transcriptStack
            }
        }()
        if panel.arrangedSubviews.first !== wanted {
            panel.arrangedSubviews.forEach { $0.removeFromSuperview() }
            if let wanted { panel.addArrangedSubview(wanted) }
        }
        switch selectedTab {
        case .comments: renderComments()
        case .summary: renderSummary()
        case .transcript: renderTranscript()
        }
    }

    // MARK: Comments

    private func sortedThreads() -> [(VideoComment, [VideoComment])] {
        let comments = model.comments
        let roots = comments.filter { $0.parentId == nil }
        let rootIDs = Set(roots.map(\.commentId))
        // A reply whose parent is missing is promoted, never lost (the web's rule).
        let orphans = comments.filter { $0.parentId != nil && !rootIDs.contains($0.parentId!) }
        var threads = (roots + orphans).map { root in
            (root, comments.filter { $0.parentId == root.commentId && rootIDs.contains(root.commentId) }.sorted { $0.createdAt < $1.createdAt })
        }
        switch sort {
        case .videoTime: threads.sort { (($0.0.videoTime ?? 0), $0.0.createdAt) < (($1.0.videoTime ?? 0), $1.0.createdAt) }
        case .oldest: threads.sort { $0.0.createdAt < $1.0.createdAt }
        case .newest: threads.sort { $0.0.createdAt > $1.0.createdAt }
        }
        return threads
    }

    private func renderComments(newID: String? = nil) {
        let total = model.comments.count
        commentsCountLabel.text = total == 1 ? "1 comment" : "\(total) comments"
        sortButton.title = sort.rawValue
        guard model.comments != renderedComments || sort != renderedSort || commentsStack.arrangedSubviews.isEmpty || newID != nil else { return }
        renderedComments = model.comments
        renderedSort = sort
        commentsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let head = UIStackView(arrangedSubviews: [commentsCountLabel, UIView(), sortButton])
        head.alignment = .center
        commentsStack.addArrangedSubview(head)
        if let error = model.commentsError, model.comments.isEmpty {
            commentsStack.addArrangedSubview(ccLabel("Couldn't load comments. \(error)", font: CCFont.label, color: CCTheme.color.mutedForeground, lines: 0))
            return
        }
        if !model.commentsLoaded {
            let spinner = CCSpinner(diameter: 20)
            spinner.color = CCTheme.color.mutedForeground
            spinner.startAnimating()
            commentsStack.addArrangedSubview(spinner)
            return
        }
        if model.comments.isEmpty {
            commentsStack.addArrangedSubview(ccLabel("No comments yet. Pause on a moment and leave a note — it's pinned to that time.",
                                                     font: CCFont.label, color: CCTheme.color.mutedForeground, lines: 0))
            return
        }
        var fresh: [UIView] = []
        for (root, replies) in sortedThreads() {
            let row = makeRow(root, reply: false)
            commentsStack.addArrangedSubview(row)
            if root.commentId == newID { fresh.append(row) }
            for reply in replies {
                let replyRow = makeRow(reply, reply: true)
                commentsStack.addArrangedSubview(replyRow)
                if reply.commentId == newID { fresh.append(replyRow) }
            }
        }
        if !fresh.isEmpty { DispatchQueue.main.async { CCMotion.stagger(fresh, distance: 10) } }
    }

    private func makeRow(_ comment: VideoComment, reply: Bool) -> ShareCommentRow {
        let row = ShareCommentRow(comment: comment, reply: reply)
        row.onSeek = { [weak self] time in self?.seekFromChip(time) }
        row.onReply = { [weak self] comment in self?.setReply(comment) }
        return row
    }

    func commentRows() -> [ShareCommentRow] { commentsStack.arrangedSubviews.compactMap { $0 as? ShareCommentRow } }

    private func presentSortMenu() {
        let sheet = CCActionSheet(title: "Sort comments")
        for option in Sort.allCases {
            sheet.addAction(option.rawValue, checked: option == sort) { [weak self] in self?.setSort(option) }
        }
        sheet.present(from: self, source: sortButton)
    }

    func setSort(_ option: Sort) {
        guard option != sort else { return }
        sort = option
        CCMotion.crossFade(commentsStack) { self.renderComments() }
    }

    private func jump(to comment: VideoComment) {
        seek(to: comment.videoTime ?? 0, play: false)
        select(tab: .comments)
        if let row = commentRows().first(where: { $0.comment.commentId == comment.commentId }) {
            row.backgroundColor = CCTheme.color.active
            row.layer.cornerRadius = CCTheme.radius(.md)
            UIView.animate(withDuration: CCMotion.paced(1.4), delay: 0.4) { row.backgroundColor = .clear }
            UIAccessibility.post(notification: .layoutChanged, argument: row)
        }
    }

    // MARK: Summary + transcript

    private func renderSummary() {
        guard summaryStack.arrangedSubviews.isEmpty, let meta = model.meta else { return }
        if let summary = model.summary {
            summaryStack.addArrangedSubview(ccLabel(summary, font: CCFont.body, color: CCTheme.color.foreground, lines: 0))
            summaryStack.setCustomSpacing(CCSpace.md, after: summaryStack.arrangedSubviews.last!)
        }
        let chapters = meta.meaningfulChapters
        if !chapters.isEmpty {
            let heading = ccLabel("Chapters", font: CCFont.labelSemibold, color: CCTheme.color.mutedForeground)
            heading.accessibilityTraits = .header
            summaryStack.addArrangedSubview(heading)
            for chapter in chapters {
                let row = ShareTimedRow(time: chapter.start, text: chapter.label)
                row.onTap = { [weak self] in self?.seekFromChip(chapter.start) }
                summaryStack.addArrangedSubview(row)
            }
        }
    }

    private func renderTranscript() {
        let key = model.transcriptLoaded ? model.transcript.count : -1
        guard key != renderedTranscriptCount || transcriptStack.arrangedSubviews.isEmpty else { return }
        renderedTranscriptCount = key
        transcriptStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        activeTranscriptIndex = nil
        if !model.transcriptLoaded {
            let spinner = CCSpinner(diameter: 20)
            spinner.color = CCTheme.color.mutedForeground
            spinner.startAnimating()
            transcriptStack.addArrangedSubview(spinner)
            return
        }
        if model.transcript.isEmpty {
            transcriptStack.addArrangedSubview(ccLabel("No transcript yet.", font: CCFont.label, color: CCTheme.color.mutedForeground))
            return
        }
        for segment in model.transcript {
            let row = ShareTimedRow(time: segment.start, text: segment.text)
            row.onTap = { [weak self] in self?.seekFromChip(segment.start) }
            transcriptStack.addArrangedSubview(row)
        }
        highlightTranscript(at: surface.currentTime)
    }

    private func highlightTranscript(at time: Double) {
        guard selectedTab == .transcript else { return }
        let index = model.transcript.lastIndex { $0.start <= time + 0.05 }
        guard index != activeTranscriptIndex else { return }
        let rows = transcriptStack.arrangedSubviews.compactMap { $0 as? ShareTimedRow }
        if let old = activeTranscriptIndex, rows.indices.contains(old) { rows[old].setActive(false) }
        if let index, rows.indices.contains(index) { rows[index].setActive(true) }
        activeTranscriptIndex = index
    }

    // MARK: - Playback

    private func setAspect(_ ratio: CGFloat) {
        guard ratio.isFinite, ratio > 0 else { return }
        aspect = ratio
        let target = playerHeight(for: column.bounds.width)
        if view.window != nil, column.bounds.width > 0 {
            // The player's BOTTOM edge settles to the video's shape on the bounce.
            CCMotion.animate(surfaceHeight, to: target, in: scrollView, duration: 0.42, curve: .bounce)
        } else {
            surfaceHeight.constant = target
        }
    }

    private func playerHeight(for width: CGFloat) -> CGFloat {
        let screen = view.window?.windowScene?.screen.bounds.height ?? 800
        return min(max(width * aspect, 160), screen * 0.55)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if !CCMotion.isAnimating(surfaceHeight), column.bounds.width > 0 {
            let target = playerHeight(for: column.bounds.width)
            if abs(surfaceHeight.constant - target) > 0.5 { surfaceHeight.constant = target }
        }
    }

    private func timeChanged(_ time: Double) {
        let duration = surface.duration > 0 ? surface.duration : (model.meta?.durationSeconds ?? 0)
        timeline.setTime(time, duration: duration)
        model.tick(time, playing: surface.isPlaying)
        if draftTime == nil, replyingTo == nil { composer.timeChip.title = Format.duration(time) }
        composer.timeChip.accessibilityLabelOverride = "Posts at \(Format.spokenDuration(draftTime ?? time))"
        if captionsOn {
            surface.setCaption(model.transcript.last { $0.start <= time && time < $0.end }?.text)
        }
        highlightTranscript(at: time)
    }

    /// Seek (and optionally play) — the timestamp chips, chapters, transcript
    /// lines and scrubber markers all land here.
    func seek(to time: Double, play: Bool) {
        surface.seek(to: time)
        model.track("seek", at: time)
        if play { surface.play() }
    }

    private func seekFromChip(_ time: Double) {
        #if DEBUG
        if ShareViewerModel.probeInject == "seek-ignored" { return }
        #endif
        seek(to: time, play: true)
        // Bring the player back into view.
        scrollView.setContentOffset(CGPoint(x: 0, y: -scrollView.adjustedContentInset.top), animated: !CCMotion.reduceMotion)
        UIAccessibility.post(notification: .announcement, argument: "Playing from \(Format.spokenDuration(time))")
    }

    private func toggleCaptions() {
        captionsOn.toggle()
        captionsKey.symbol = captionsOn ? "captions-fill" : "captions"
        captionsKey.style = captionsOn ? .secondary : .ghost
        captionsKey.accessibilityValue = captionsOn ? "On" : "Off"
        if captionsOn {
            Task {
                await model.loadTranscript()
                self.timeChanged(self.surface.currentTime)
            }
        } else {
            surface.setCaption(nil)
        }
        CCAccessibility.announce(captionsOn ? "Captions on" : "Captions off")
    }

    // MARK: - Reactions

    private func react(_ emoji: String) {
        let time = surface.currentTime
        CCHaptics.selection()
        Task {
            let landed = await model.react(emoji, at: time)
            if !landed {
                toaster.show(title: "Couldn't react", message: "Check your connection and try again.", variant: .destructive)
            } else if model.myEmoji == emoji {
                CCAccessibility.announce("Reacted \(ShareReactions.spoken[emoji] ?? emoji) at \(Format.spokenDuration(time))")
            }
        }
    }

    // MARK: - Composing

    private func startDraft() {
        if draftTime == nil, replyingTo == nil {
            draftTime = surface.currentTime
            composer.timeChip.title = Format.duration(draftTime!)
        }
    }

    func setReply(_ comment: VideoComment?) {
        replyingTo = comment
        composer.setReplying(to: comment?.authorName)
        composer.field.placeholderText = comment.map { "Reply to \($0.authorName)…" } ?? "Add a comment…"
        if comment != nil {
            _ = composer.field.becomeFirstResponder()
        } else if draftTime == nil {
            composer.timeChip.title = Format.duration(surface.currentTime)
        }
    }

    func post() {
        let text = (composer.field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !composer.sendButton.isBusy else {
            if text.isEmpty { composer.field.isError = true; CCHaptics.warning() }
            return
        }
        guard text.count <= 500 else {
            composer.showError("Comments are 500 characters at most.")
            return
        }
        composer.field.isError = false
        composer.showError(nil)
        let parent = replyingTo
        let time = parent == nil ? (draftTime ?? surface.currentTime) : nil
        let name = model.signedInName == nil ? composer.nameField.text?.trimmingCharacters(in: .whitespaces) : nil
        composer.sendButton.isBusy = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.composer.sendButton.isBusy = false }
            do {
                let comment = try await self.model.post(body: text, authorName: name, at: time, replyTo: parent?.commentId)
                self.composer.field.text = ""
                self.draftTime = nil
                self.setReply(nil)
                _ = self.composer.field.resignFirstResponder()
                self.select(tab: .comments, animated: false)
                self.renderComments(newID: comment.commentId)
                CCHaptics.success()
                CCAccessibility.announce(parent == nil ? "Comment posted at \(Format.spokenDuration(time ?? 0))" : "Reply posted")
            } catch {
                self.composer.showError(error.localizedDescription)
            }
        }
    }

    // MARK: - Sign in

    #if DEBUG
    /// The gate stands in for the browser leg of sign-in.
    static var probeSignIn: ((ShareViewerViewController) -> Void)?
    #endif

    private func signIn() {
        #if DEBUG
        if let probe = Self.probeSignIn { probe(self); return }
        #endif
        composer.signInButton.isBusy = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.composer.signInButton.isBusy = false }
            do {
                try await AppEnvironment.shared.session.signIn(from: self.view.window)
                self.model.refreshSignedIn()
                if self.model.phase == .privateVideo { await self.model.load() }
            } catch {
                if case AuthService.AuthError.cancelled = error { return }
                self.toaster.show(title: "Couldn't sign in", message: error.localizedDescription, variant: .destructive)
            }
        }
    }

    // MARK: - Share menu

    private func presentShareMenu() {
        let link = ShareLink(videoID: videoID, startAt: nil)
        let sheet = CCActionSheet(title: model.meta?.displayTitle ?? "Shared video")
        sheet.addAction("Copy link", symbol: "link") { [weak self] in
            UIPasteboard.general.url = link.webURL
            self?.toaster.show(title: "Link copied", message: link.webURL.absoluteString, variant: .success, symbol: "link")
        }
        sheet.addAction("Share…", symbol: "share") { [weak self] in
            guard let self else { return }
            let activity = UIActivityViewController(activityItems: [link.webURL], applicationActivities: nil)
            activity.popoverPresentationController?.sourceView = self.shareKey
            self.present(activity, animated: true)
        }
        sheet.addAction("Open in browser", symbol: "globe") {
            UIApplication.shared.open(link.webURL)
        }
        if model.phase == .open, model.meta?.allowDownload == true {
            let url = model.api.downloadURL(videoID, token: model.shareToken)
            sheet.addAction("Download", symbol: "download-fill") { [weak self] in
                self?.model.track("download", at: self?.surface.currentTime ?? 0)
                UIApplication.shared.open(url)
            }
        }
        if model.phase == .open, !model.isOwnerPrivate {
            sheet.addAction("Report video", symbol: "warning-fill", destructive: true) { [weak self] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self?.presentReport() }
            }
        }
        sheet.present(from: self, source: shareKey)
    }

    private func presentReport() {
        let sheet = CCActionSheet(title: "Report this video", message: "What's wrong with it? Reports are anonymous.")
        for reason in ShareReportReason.allCases {
            sheet.addAction(reason.label) { [weak self] in self?.report(reason) }
        }
        sheet.present(from: self, source: shareKey)
    }

    private func report(_ reason: ShareReportReason) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.model.api.report(self.videoID, reason: reason)
                self.toaster.show(title: "Thanks for reporting", message: "We'll review this video. If it breaks our rules, we'll take it down.",
                                  variant: .success)
            } catch {
                self.toaster.show(title: "Couldn't send the report", message: error.localizedDescription, variant: .destructive)
            }
        }
    }

    // MARK: - Probe seams

    #if DEBUG
    var probeSurface: ShareVideoSurface { surface }
    var probeTimeline: ShareTimelineView { timeline }
    var probeReactionBar: ShareReactionBar { reactionBar }
    var probeComposer: ShareComposerView { composer }
    var probeTabs: CCSegmented? { tabs }
    var probeStateHost: UIStackView { stateHost }
    var probeCaptionsKey: CCButton { captionsKey }
    var probeTitle: String { titleLabel.text ?? "" }
    var probeByline: String { bylineLabel.text ?? "" }
    var probeTranscriptRows: [ShareTimedRow] { transcriptStack.arrangedSubviews.compactMap { $0 as? ShareTimedRow } }
    var probeSummaryText: [String] {
        summaryStack.arrangedSubviews.compactMap { ($0 as? UILabel)?.text ?? ($0 as? ShareTimedRow)?.text }
    }
    #endif
}

// MARK: - Pieces

/// A time + text line (chapters, transcript): the whole row seeks.
final class ShareTimedRow: UIControl {
    let time: Double
    let text: String
    var onTap: (() -> Void)?
    private let wash = UIView()
    private(set) var isActive = false

    init(time: Double, text: String) {
        self.time = time
        self.text = text
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wash.backgroundColor = CCTheme.color.active
        wash.alpha = 0
        wash.isUserInteractionEnabled = false
        wash.layer.cornerCurve = .continuous
        wash.layer.cornerRadius = CCTheme.radius(.md)
        wash.translatesAutoresizingMaskIntoConstraints = false
        addSubview(wash)
        let stamp = ccLabel(Format.duration(time), font: CCFont.monoSmall, color: CCTheme.color.mutedForeground)
        stamp.setContentHuggingPriority(.required, for: .horizontal)
        stamp.setContentCompressionResistancePriority(.required, for: .horizontal)
        let body = ccLabel(text, font: CCFont.label, color: CCTheme.color.foreground, lines: 0)
        let row = UIStackView(arrangedSubviews: [stamp, body])
        row.spacing = CCSpace.md
        row.alignment = .firstBaseline
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            wash.leadingAnchor.constraint(equalTo: leadingAnchor), wash.trailingAnchor.constraint(equalTo: trailingAnchor),
            wash.topAnchor.constraint(equalTo: topAnchor), wash.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CCSpace.sm),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CCSpace.sm),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "\(Format.spokenDuration(time)): \(text)"
        accessibilityHint = "Plays from here"
        addAction(UIAction { [weak self] _ in
            CCHaptics.selection()
            self?.onTap?()
        }, for: .touchUpInside)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setActive(_ on: Bool) {
        isActive = on
        CCMotion.fadeAlpha(wash, to: on ? 1 : 0, duration: 0.2)
        accessibilityTraits = on ? [.button, .selected] : .button
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue, !isActive else { return }
            CCMotion.fadeAlpha(wash, to: isHighlighted ? 1 : 0, duration: isHighlighted ? 0.06 : 0.22)
        }
    }
}

/// While the share loads.
final class CCSpinnerCard: CCCard {
    init() {
        super.init(radius: .lg)
        let spinner = CCSpinner(diameter: 28)
        spinner.color = CCTheme.color.mutedForeground
        spinner.startAnimating()
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 28),
            spinner.heightAnchor.constraint(equalToConstant: 28),
            heightAnchor.constraint(equalToConstant: 220),
        ])
        isAccessibilityElement = true
        accessibilityLabel = "Loading video"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// The player's footprint when the share can't play (yet): password,
/// expired, view limit, paused, private, removed, missing, failed.
final class ShareStateCard: CCCard {
    let kind: String
    private(set) var passwordField: CCField?
    private(set) var watchButton: CCButton?
    private(set) var errorLabel: UILabel?
    private(set) var titleText = ""
    private(set) var messageText = ""

    private init(kind: String, symbol: String, title: String, message: String) {
        self.kind = kind
        titleText = title
        messageText = message
        super.init(radius: .lg)
        let icon = CCIconTile(symbol: symbol, side: 48)
        let titleLabel = ccLabel(title, font: CCFont.header, color: CCTheme.color.foreground, lines: 0, alignment: .center)
        titleLabel.accessibilityTraits = .header
        let messageLabel = ccLabel(message, font: CCFont.label, color: CCTheme.color.mutedForeground, lines: 0, alignment: .center)
        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(messageLabel)
        stack.setCustomSpacing(CCSpace.md, after: icon)
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = CCSpace.xs + 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CCSpace.xl),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CCSpace.xl),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: CCSpace.xl),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -CCSpace.xl),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
    }

    private let stack = UIStackView()

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func addButton(_ button: CCButton) {
        stack.setCustomSpacing(CCSpace.lg, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(button)
    }

    static func gate(_ gate: ShareGateState, fileName: String, onUnlock: @escaping (String) async throws -> Void) -> ShareStateCard {
        switch gate {
        case .locked:
            let card = ShareStateCard(kind: "locked", symbol: "eye-off", title: fileName, message: "This video is password protected.")
            let field = CCField(placeholder: "Password")
            field.isSecureTextEntry = true
            field.textContentType = .password
            field.returnKeyType = .go
            field.accessibilityLabel = "Password"
            let watch = CCButton(title: "Watch", symbol: "play-fill", style: .primary, size: .regular)
            let error = ccLabel("", font: CCFont.caption, color: CCTheme.color.destructive, lines: 0, alignment: .center)
            error.isHidden = true
            let row = UIStackView(arrangedSubviews: [field, watch])
            row.spacing = CCSpace.sm
            row.alignment = .center
            row.ccStacksAtAccessibilitySizes()
            card.stack.setCustomSpacing(CCSpace.lg, after: card.stack.arrangedSubviews.last!)
            card.stack.addArrangedSubview(row)
            card.stack.addArrangedSubview(error)
            row.widthAnchor.constraint(equalTo: card.stack.widthAnchor).isActive = true
            card.passwordField = field
            card.watchButton = watch
            card.errorLabel = error
            let submit = { [weak card, weak field, weak watch, weak error] in
                guard let field, let watch, let password = field.text, !password.isEmpty, !watch.isBusy else { return }
                watch.isBusy = true
                error?.isHidden = true
                Task { @MainActor in
                    defer { watch.isBusy = false }
                    do {
                        try await onUnlock(password)
                    } catch {
                        guard let card, let label = card.errorLabel else { return }
                        label.text = error.localizedDescription
                        label.isHidden = false
                        field.isError = true
                        CCHaptics.warning()
                        CCAccessibility.announce(error.localizedDescription)
                    }
                }
            }
            field.onReturn = { _ in submit() }
            watch.onTap = submit
            return card
        case .expired:
            return ShareStateCard(kind: "expired", symbol: "timer", title: fileName, message: "This share link has expired.")
        case .viewLimit:
            return ShareStateCard(kind: "view_limit", symbol: "eye", title: fileName, message: "This video has reached its view limit.")
        case .paused:
            return ShareStateCard(kind: "paused", symbol: "pause-fill", title: fileName,
                                  message: "This share is paused — the owner’s plan no longer includes cloud sharing.")
        }
    }

    static func removed(_ message: String) -> ShareStateCard {
        let card = ShareStateCard(kind: "removed", symbol: "close-octagon-fill", title: "Video removed", message: message)
        card.stack.addArrangedSubview(ccLabel("If you uploaded it and think this is a mistake, contact us at capturecat.so/contact.",
                                              font: CCFont.caption, color: CCTheme.color.faintForeground, lines: 0, alignment: .center))
        return card
    }

    static func privateVideo(signedIn: Bool, onSignIn: @escaping () -> Void) -> ShareStateCard {
        let card = ShareStateCard(kind: signedIn ? "private-signed-in" : "private", symbol: "eye-off", title: "This video is private",
                                  message: signedIn ? "Only its owner can watch it." : "Only its owner can watch it. If it's yours, sign in to watch.")
        if !signedIn {
            let button = CCButton(title: "Sign in", style: .secondary, size: .regular)
            button.onTap = onSignIn
            card.addButton(button)
        }
        return card
    }

    static func notFound() -> ShareStateCard {
        ShareStateCard(kind: "not-found", symbol: "film", title: "Video not found",
                       message: "This link doesn't lead to a video anymore. It may have been deleted.")
    }

    static func failed(_ message: String, retry: @escaping () -> Void) -> ShareStateCard {
        let card = ShareStateCard(kind: "failed", symbol: "warning-fill", title: "Couldn't load this video", message: message)
        let button = CCButton(title: "Try again", symbol: "rotate-cw", style: .secondary, size: .regular)
        button.onTap = retry
        card.addButton(button)
        return card
    }
}
