import UIKit

/// The Capture tab — drawn with the house kit from `CaptureHubModel`
/// (streaming to a Mac, recording on the phone, Photos imports, inbox), read
/// through `AppEnvironment.shared.capture` so fixture mode can fake presence.
///
/// Top to bottom: a transient "<Mac> asked for your screen" banner, the
/// "Stream to your Mac" hero (presence status, Mac picker, Start streaming),
/// "Record on iPhone", Photos import, and the uploads still on this iPhone.
final class CaptureHubViewController: UIViewController {
    let model = CaptureHubModel.shared
    private var feed: CaptureFeed { AppEnvironment.shared.capture }

    private let header = CCHeaderBar(title: "Capture", style: .large)
    private let scrollView = UIScrollView()
    private let column = UIStackView()

    // Request banner
    private let banner = CCCard(radius: .lg)
    private let bannerLabel = ccLabel("", font: CCFont.labelSemibold, color: CCTheme.color.foreground, lines: 2)
    private var bannerShownAt: Date?
    private var bannerWork: DispatchWorkItem?

    // Hero
    private let hero = CCCard(radius: .xl)
    private let linkStrip = PresenceStrip()
    private let statusDot = UIView()
    private let statusLabel = ccLabel("", font: CCFont.labelSemibold, color: CCTheme.color.foreground, lines: 2)
    private let statusDetail = ccLabel("", font: CCFont.caption, color: CCTheme.color.mutedForeground, lines: 0)
    private let statusSpinner = CCSpinner(diameter: 14)
    private let macPicker = CCSelect(options: [], symbol: "laptop")
    private let streamButton = CCButton(title: "Start streaming", symbol: "wifi", style: .primary, size: .lg, radius: .lg)
    private var macIDs: [String] = []

    // Import
    private let importSpinner = CCSpinner(diameter: 16)
    private let importStatus = ccLabel("Importing…", font: CCFont.caption, color: CCTheme.color.mutedForeground)
    private let importStatusRow = UIStackView()
    private let importError = CCCallout(message: "", variant: .destructive)

    // Inbox
    private let inboxSection = UIStackView()
    private let inboxList = UIStackView()
    private var inboxViews: [String: InboxTakeView] = [:]

    private var observation: SurfaceObservation?
    private var statusKey = ""

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = CCTheme.color.background
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        view.addSubview(scrollView)
        view.addSubview(header)
        column.axis = .vertical
        column.spacing = CCSpace.lg
        column.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(column)
        let width = column.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -CCSpace.gutter * 2)
        width.priority = .required - 1
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            column.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: CCSpace.sm),
            column.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -CCSpace.xl),
            column.centerXAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerXAnchor),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: 620),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: CCSpace.gutter),
            width,
        ])
        header.track(scrollView)

        buildBanner()
        buildHero()
        column.addArrangedSubview(banner)
        column.addArrangedSubview(hero)
        column.addArrangedSubview(buildRecordCard())
        column.addArrangedSubview(buildImport())
        buildInbox()
        column.addArrangedSubview(inboxSection)
        banner.isHidden = true

        observation = SurfaceObservation { [weak self] in self?.render() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if DEBUG
        if AppEnvironment.shared.isFixture { return }
        #endif
        model.activate()
    }

    // MARK: - Build

    private func buildBanner() {
        let icon = CCIconView("bell-badge-fill", pointSize: 17, weight: .medium, tint: CCTheme.color.primary)
        let detail = ccLabel("Tap Start Broadcast in the sheet to begin.", font: CCFont.caption, color: CCTheme.color.mutedForeground, lines: 2)
        let text = UIStackView(arrangedSubviews: [bannerLabel, detail])
        text.axis = .vertical
        text.spacing = 2
        let close = CCButton(symbol: "close", style: .ghost, size: .sm, radius: .full)
        close.accessibilityLabelOverride = "Dismiss"
        close.onTap = { [weak self] in self?.feed.dismissRequest() }
        let row = UIStackView(arrangedSubviews: [icon, text, close])
        row.spacing = CCSpace.md
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        banner.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: CCSpace.lg),
            row.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -CCSpace.sm),
            row.topAnchor.constraint(equalTo: banner.topAnchor, constant: CCSpace.md),
            row.bottomAnchor.constraint(equalTo: banner.bottomAnchor, constant: -CCSpace.md),
        ])
    }

    private func buildHero() {
        let eyebrow = ccLabel("\(ThisDevice.noun) over Wi-Fi", font: CCFont.captionMedium, color: CCTheme.color.mutedForeground)
        let title = ccLabel("Stream to your Mac", font: CCFont.title, color: CCTheme.color.foreground, lines: 2)
        title.accessibilityTraits = .header
        let pitch = ccLabel("Your Mac records this screen like a plugged-in \(ThisDevice.noun) — with the device frame. No cable.",
                            font: CCFont.label, color: CCTheme.color.mutedForeground, lines: 0)

        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.layer.cornerRadius = 4
        statusSpinner.color = CCTheme.color.mutedForeground
        let statusTop = UIStackView(arrangedSubviews: [statusDot, statusLabel, statusSpinner, UIView()])
        statusTop.spacing = CCSpace.sm
        statusTop.alignment = .center
        let statusStack = UIStackView(arrangedSubviews: [statusTop, statusDetail])
        statusStack.axis = .vertical
        statusStack.spacing = 4
        let statusWell = CCSurface(.recessed, tint: CCTheme.color.elevated, radius: .md)
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        statusWell.addSubview(statusStack)
        NSLayoutConstraint.activate([
            statusDot.widthAnchor.constraint(equalToConstant: 8),
            statusDot.heightAnchor.constraint(equalToConstant: 8),
            statusStack.leadingAnchor.constraint(equalTo: statusWell.leadingAnchor, constant: CCSpace.md),
            statusStack.trailingAnchor.constraint(equalTo: statusWell.trailingAnchor, constant: -CCSpace.md),
            statusStack.topAnchor.constraint(equalTo: statusWell.topAnchor, constant: CCSpace.md),
            statusStack.bottomAnchor.constraint(equalTo: statusWell.bottomAnchor, constant: -CCSpace.md),
        ])
        statusWell.accessibilityElements = [statusLabel, statusDetail]
        self.statusWell = statusWell

        macPicker.prompt = "Stream to which Mac?"
        macPicker.presenter = self
        macPicker.isHidden = true
        macPicker.onSelect = { [weak self] index in
            guard let self, self.macIDs.indices.contains(index) else { return }
            self.feed.prefer(macID: self.macIDs[index])
        }
        streamButton.onTap = { [weak self] in
            guard let self else { return }
            self.feed.streamToMac(from: self.streamButton)
        }
        streamButton.accessibilityHint = "Opens the system Start Broadcast sheet"

        let stack = UIStackView(arrangedSubviews: [linkStrip, eyebrow, title, pitch, statusWell, macPicker, streamButton])
        stack.axis = .vertical
        stack.spacing = CCSpace.xs
        stack.setCustomSpacing(CCSpace.lg, after: linkStrip)
        stack.setCustomSpacing(CCSpace.sm, after: title)
        stack.setCustomSpacing(CCSpace.lg, after: pitch)
        stack.setCustomSpacing(CCSpace.md, after: statusWell)
        stack.setCustomSpacing(CCSpace.md, after: macPicker)
        stack.translatesAutoresizingMaskIntoConstraints = false
        hero.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: hero.leadingAnchor, constant: CCSpace.xl - 4),
            stack.trailingAnchor.constraint(equalTo: hero.trailingAnchor, constant: -(CCSpace.xl - 4)),
            stack.topAnchor.constraint(equalTo: hero.topAnchor, constant: CCSpace.xl - 4),
            stack.bottomAnchor.constraint(equalTo: hero.bottomAnchor, constant: -(CCSpace.xl - 4)),
        ])
    }

    private var statusWell: UIView?

    private func buildRecordCard() -> UIView {
        let card = CCCard(radius: .lg)
        let tile = CCIconTile(symbol: "record")
        let title = ccLabel("Record on \(ThisDevice.noun)", font: CCFont.header, color: CCTheme.color.foreground, lines: 2)
        title.accessibilityTraits = .header
        let body = ccLabel("Saves to your library when you stop. Control Center's record button works too — pick CaptureCat in the list.",
                           font: CCFont.caption, color: CCTheme.color.mutedForeground, lines: 0)
        let text = UIStackView(arrangedSubviews: [title, body])
        text.axis = .vertical
        text.spacing = 3
        let top = UIStackView(arrangedSubviews: [tile, text])
        top.spacing = CCSpace.md
        top.alignment = .top
        let record = CCButton(title: "Record this screen", symbol: "record-fill", style: .secondary, size: .regular)
        record.onTap = { [weak self, weak record] in
            guard let self, let record else { return }
            self.feed.recordOnPhone(from: record)
        }
        record.accessibilityHint = "Opens the system Start Broadcast sheet"
        let stack = UIStackView(arrangedSubviews: [top, record])
        stack.axis = .vertical
        stack.spacing = CCSpace.md + 2
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

    private func buildImport() -> UIView {
        let label = ccLabel("Import from Photos", font: CCFont.labelSemibold, color: CCTheme.color.mutedForeground)
        label.accessibilityTraits = .header
        let screenshots = CCButton(title: "Screenshots", symbol: "photo-add", style: .secondary, size: .lg, radius: .lg)
        screenshots.onTap = { [weak self] in
            guard let self else { return }
            self.feed.pickScreenshots(from: self)
        }
        let videos = CCButton(title: "Videos", symbol: "film", style: .secondary, size: .lg, radius: .lg)
        videos.onTap = { [weak self] in
            guard let self else { return }
            self.feed.pickVideos(from: self)
        }
        let row = UIStackView(arrangedSubviews: [screenshots, videos])
        row.spacing = CCSpace.sm
        row.distribution = .fillEqually
        importSpinner.color = CCTheme.color.mutedForeground
        importStatusRow.addArrangedSubview(importSpinner)
        importStatusRow.addArrangedSubview(importStatus)
        importStatusRow.spacing = CCSpace.sm
        importStatusRow.alignment = .center
        importStatusRow.isHidden = true
        importError.isHidden = true
        let hint = ccLabel(ThisDevice.isPad ? "Screenshots open on your Mac and the web, ready to edit." : "Screenshots open on your Mac and the web with the iPhone frame around them.",
                           font: CCFont.caption, color: CCTheme.color.mutedForeground, lines: 0)
        let stack = UIStackView(arrangedSubviews: [label, row, importStatusRow, importError, hint])
        stack.axis = .vertical
        stack.spacing = CCSpace.sm
        return stack
    }

    private func buildInbox() {
        let label = ccLabel("Waiting to upload", font: CCFont.labelSemibold, color: CCTheme.color.mutedForeground)
        label.accessibilityTraits = .header
        inboxList.axis = .vertical
        inboxList.spacing = CCSpace.sm
        inboxSection.axis = .vertical
        inboxSection.spacing = CCSpace.sm
        inboxSection.addArrangedSubview(label)
        inboxSection.addArrangedSubview(inboxList)
        inboxSection.isHidden = true
    }

    // MARK: - Render (observation loop)

    private func render() {
        let feed = self.feed
        renderStatus(feed.presenceStatus, macs: feed.nearbyMacs, connected: feed.connectedMacID)
        renderRequest(feed.lastRequest)
        renderImport(importing: feed.isImporting, error: feed.importError)
        renderInbox(AppEnvironment.shared.inbox.takes)
    }

    private func renderStatus(_ status: MacPresence.Status, macs: [(id: String, name: String)], connected: String?) {
        let colors = CCTheme.color
        var dot = colors.faintForeground
        var title = ""
        var detail = ""
        var searching = false
        var canStream = true
        var linkState = PresenceStrip.State.idle
        switch status {
        case .signedOut:
            title = "Signed out"
            detail = "Sign in to stream this \(ThisDevice.noun) to your Mac."
            canStream = false
        case .unavailable(let message):
            dot = colors.destructive
            title = "Can't link this \(ThisDevice.noun)"
            detail = message
        case .searching:
            dot = colors.warning
            title = "Looking for your Mac…"
            detail = "Open CaptureCat on your Mac — same Wi-Fi, same account."
            searching = true
            linkState = .searching
        case .connected(let macName):
            dot = colors.success
            title = "Connected to \(macName)"
            detail = "Ready. Start streaming, then pick this \(ThisDevice.noun) as the source on your Mac."
            linkState = .connected
        }
        let key = "\(title)|\(detail)"
        if key != statusKey {
            let first = statusKey.isEmpty
            statusKey = key
            if !first, let well = statusWell {
                UIView.transition(with: well, duration: CCMotion.paced(0.2), options: [.transitionCrossDissolve, .allowUserInteraction]) {
                    self.statusLabel.text = title
                    self.statusDetail.text = detail
                }
                CCMotion.pop(statusDot, from: 0.5)
            } else {
                statusLabel.text = title
                statusDetail.text = detail
            }
            UIAccessibility.post(notification: .announcement, argument: title)
        }
        statusDot.backgroundColor = dot
        if searching { statusSpinner.startAnimating() } else { statusSpinner.stopAnimating() }
        linkStrip.state = linkState
        streamButton.isEnabled = canStream

        let showPicker = macs.count > 1
        macIDs = macs.map(\.id)
        if showPicker {
            macPicker.options = macs.map(\.name)
            let preferred = connected.flatMap { id in macs.firstIndex { $0.id == id } } ?? 0
            macPicker.setSelectedIndex(preferred)
        }
        if macPicker.isHidden == showPicker {
            CCMotion.run(duration: 0.38, curve: .bounce) {
                self.macPicker.isHidden = !showPicker
                self.column.layoutIfNeeded()
            }
        }
    }

    private func renderRequest(_ request: CaptureHubModel.Request?) {
        guard let request else {
            if !banner.isHidden {
                bannerWork?.cancel()
                CCMotion.fadeAlpha(banner, to: 0, duration: 0.16)
                CCMotion.run(duration: 0.3, curve: .settle) {
                    self.banner.isHidden = true
                    self.column.layoutIfNeeded()
                }
            }
            bannerShownAt = nil
            return
        }
        guard bannerShownAt != request.at else { return }
        bannerShownAt = request.at
        bannerLabel.text = "\(request.macName) asked for your screen"
        banner.accessibilityLabel = bannerLabel.text
        if banner.isHidden {
            banner.alpha = 0
            CCMotion.run(duration: 0.42, curve: .bounce) {
                self.banner.isHidden = false
                self.column.layoutIfNeeded()
            }
            CCMotion.fadeAlpha(banner, to: 1, duration: 0.2, delay: 0.06, from: 0)
            CCMotion.enter(banner.layer, .slideDown(distance: 12))
        } else {
            CCMotion.pop(banner, from: 0.97)
        }
        CCHaptics.light()
        UIAccessibility.post(notification: .announcement, argument: bannerLabel.text)
        bannerWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.feed.dismissRequest() }
        bannerWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    private func renderImport(importing: Bool, error: String?) {
        if importing { importSpinner.startAnimating() } else { importSpinner.stopAnimating() }
        if importStatusRow.isHidden == importing {
            CCMotion.run(duration: 0.38, curve: .bounce) {
                self.importStatusRow.isHidden = !importing
                self.column.layoutIfNeeded()
            }
        }
        let showError = error != nil
        if let error { importError.message = error }
        if importError.isHidden == showError {
            if showError { importError.alpha = 0; CCMotion.fadeAlpha(importError, to: 1, duration: 0.2, delay: 0.08, from: 0) }
            CCMotion.run(duration: 0.38, curve: .bounce) {
                self.importError.isHidden = !showError
                self.column.layoutIfNeeded()
            }
        }
    }

    private func renderInbox(_ takes: [PendingTake]) {
        let ids = takes.map(\.id)
        let current = inboxList.arrangedSubviews.compactMap { ($0 as? InboxTakeView)?.takeID }
        guard ids != current else { return }
        // Remove gone takes, add new ones (fading in), keep order.
        for (id, view) in inboxViews where !ids.contains(id) {
            view.bind(takeID: nil)
            view.removeFromSuperview()
            inboxViews[id] = nil
        }
        var added: [UIView] = []
        for (index, id) in ids.enumerated() {
            let view: InboxTakeView
            if let existing = inboxViews[id] {
                view = existing
            } else {
                view = InboxTakeView()
                view.onDiscard = { [weak self] take in
                    guard let self else { return }
                    ProjectActions.confirmDiscard(take, from: self)
                }
                view.bind(takeID: id)
                inboxViews[id] = view
                added.append(view)
            }
            inboxList.insertArrangedSubview(view, at: index)
        }
        let show = !ids.isEmpty
        if inboxSection.isHidden == show {
            CCMotion.run(duration: 0.38, curve: .bounce) {
                self.inboxSection.isHidden = !show
                self.column.layoutIfNeeded()
            }
        }
        if view.window != nil { CCMotion.stagger(added, distance: 8) }
    }

    // Probe seams.
    var probeBanner: UIView { banner }
}

/// The hero's little diagram: iPhone · · · Mac. The dots breathe in sequence
/// while searching and settle solid (success ink) once connected.
final class PresenceStrip: UIView {
    enum State {
        case idle
        case searching
        case connected
    }

    var state: State = .idle {
        didSet { if state != oldValue { refresh() } }
    }

    private let phone = CCIconTile(symbol: ThisDevice.isPad ? "ipad" : "iphone", side: 48)
    private let mac = CCIconTile(symbol: "laptop", side: 48)
    private var dots: [UIView] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        let dotRow = UIStackView()
        dotRow.spacing = 7
        dotRow.alignment = .center
        for _ in 0..<5 {
            let dot = UIView()
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.layer.cornerRadius = 3
            dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 6).isActive = true
            dots.append(dot)
            dotRow.addArrangedSubview(dot)
        }
        let row = UIStackView(arrangedSubviews: [phone, dotRow, mac])
        row.spacing = CCSpace.md
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
        isAccessibilityElement = false
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        refresh()
    }

    private func refresh() {
        for (index, dot) in dots.enumerated() {
            dot.layer.removeAnimation(forKey: "breathe")
            switch state {
            case .idle:
                dot.backgroundColor = CCTheme.color.faintForeground
                dot.alpha = 0.6
            case .connected:
                dot.backgroundColor = CCTheme.color.success
                dot.alpha = 1
            case .searching:
                dot.backgroundColor = CCTheme.color.mutedForeground
                dot.alpha = 1
                guard !CCMotion.reduceMotion else { continue }
                let breathe = CABasicAnimation(keyPath: "opacity")
                breathe.fromValue = 0.2
                breathe.toValue = 1
                breathe.duration = 0.6
                breathe.autoreverses = true
                breathe.repeatCount = .infinity
                breathe.isRemovedOnCompletion = false
                breathe.timingFunction = CCMotion.glide
                breathe.beginTime = dot.layer.convertTime(CACurrentMediaTime(), from: nil) + 0.12 * Double(index)
                breathe.fillMode = .backwards
                dot.layer.add(breathe, forKey: "breathe")
            }
        }
    }
}
