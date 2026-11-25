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

    private let header = CCHeaderBar(title: String(localized: "Capture", comment: "Capture tab screen title"), style: .large)
    private let scrollView = UIScrollView()
    private let column = UIStackView()

    // Request banner
    private let banner = CCCard(radius: .lg)
    private let bannerLabel = ccLabel("", font: CCFont.labelSemibold, color: CCTheme.color.foreground, lines: 2)
    private var bannerShownAt: Date?
    private var bannerWork: DispatchWorkItem?

    // Hero
    private let hero = CCCard(radius: .xl)
    private let linkStage = LinkStage()
    private let statusDot = UIView()
    private let statusLabel = ccLabel("", font: CCFont.labelSemibold, color: CCTheme.color.foreground, lines: 2)
    private let statusDetail = ccLabel("", font: CCFont.caption, color: CCTheme.color.mutedForeground, lines: 0)
    private let statusSpinner = CCSpinner(diameter: 14)
    private let macPicker = CCSelect(options: [], symbol: "laptop")
    private let streamButton = CCButton(title: String(localized: "Start streaming", comment: "Button: stream this device's screen to the Mac"), symbol: "wifi", style: .primary, size: .lg, radius: .lg)
    private let settingsButton = CCButton(title: String(localized: "Open Settings", comment: "Button: opens this app's page in the Settings app"), symbol: "gear", style: .primary, size: .lg, radius: .lg)
    private var macIDs: [String] = []

    // Import
    private let importSpinner = CCSpinner(diameter: 16)
    private let importStatus = ccLabel(String(localized: "Importing…", comment: "Status while importing from Photos"), font: CCFont.caption, color: CCTheme.color.mutedForeground)
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
        // The safe area, not the screen: a folded iPhone Duo's trailing strip
        // (status + tab bar) is an inset on one side only.
        let width = column.widthAnchor.constraint(equalTo: view.safeAreaLayoutGuide.widthAnchor, constant: -CCSpace.gutter * 2)
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
            column.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
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
        let detail = ccLabel(String(localized: "Tap Start Broadcast in the sheet to begin.", comment: "Start Broadcast is the system sheet's button name"), font: CCFont.caption, color: CCTheme.color.mutedForeground, lines: 2)
        let text = UIStackView(arrangedSubviews: [bannerLabel, detail])
        text.axis = .vertical
        text.spacing = 2
        let close = CCButton(symbol: "close", style: .ghost, size: .sm, radius: .full)
        close.accessibilityLabelOverride = String(localized: "Dismiss", comment: "Accessibility label: close the banner")
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
        let eyebrow = ccLabel(String(localized: "\(ThisDevice.noun) over Wi-Fi", comment: "Eyebrow label; argument is iPhone or iPad"), font: CCFont.captionMedium, color: CCTheme.color.mutedForeground)
        let title = ccLabel(String(localized: "Stream to your Mac"), font: CCFont.title, color: CCTheme.color.foreground, lines: 2)
        title.accessibilityTraits = .header
        let pitch = ccLabel(String(localized: "Your Mac records this screen like a plugged-in \(ThisDevice.noun) — with the device frame. No cable.", comment: "Argument is iPhone or iPad"),
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

        macPicker.prompt = String(localized: "Stream to which Mac?", comment: "Picker prompt")
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
        streamButton.accessibilityHint = String(localized: "Opens the system Start Broadcast sheet", comment: "Accessibility hint")

        settingsButton.isHidden = true
        settingsButton.onTap = {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        }

        let stack = UIStackView(arrangedSubviews: [linkStage, eyebrow, title, pitch, statusWell, macPicker, streamButton, settingsButton])
        stack.axis = .vertical
        stack.spacing = CCSpace.xs
        stack.setCustomSpacing(CCSpace.md, after: linkStage)
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
        let title = ccLabel(String(localized: "Record on \(ThisDevice.noun)", comment: "Card title; argument is iPhone or iPad"), font: CCFont.header, color: CCTheme.color.foreground, lines: 2)
        title.accessibilityTraits = .header
        let body = ccLabel(String(localized: "Saves to your library when you stop. Control Center's record button works too — pick CaptureCat in the list."),
                           font: CCFont.caption, color: CCTheme.color.mutedForeground, lines: 0)
        let text = UIStackView(arrangedSubviews: [title, body])
        text.axis = .vertical
        text.spacing = 3
        let top = UIStackView(arrangedSubviews: [tile, text])
        top.spacing = CCSpace.md
        top.alignment = .top
        let record = CCButton(title: String(localized: "Record this screen", comment: "Button"), symbol: "record-fill", style: .secondary, size: .regular)
        record.onTap = { [weak self, weak record] in
            guard let self, let record else { return }
            self.feed.recordOnPhone(from: record)
        }
        record.accessibilityHint = String(localized: "Opens the system Start Broadcast sheet", comment: "Accessibility hint")
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
        let label = ccLabel(String(localized: "Import from Photos", comment: "Section label"), font: CCFont.labelSemibold, color: CCTheme.color.mutedForeground)
        label.accessibilityTraits = .header
        let screenshots = CCButton(title: String(localized: "Screenshots", comment: "Button: import screenshots from Photos"), symbol: "photo-add", style: .secondary, size: .lg, radius: .lg)
        screenshots.onTap = { [weak self] in
            guard let self else { return }
            self.feed.pickScreenshots(from: self)
        }
        let videos = CCButton(title: String(localized: "Videos", comment: "Button: import videos from Photos"), symbol: "film", style: .secondary, size: .lg, radius: .lg)
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
        let hint = ccLabel(ThisDevice.isPad ? String(localized: "Screenshots open on your Mac and the web, ready to edit.") : String(localized: "Screenshots open on your Mac and the web with the iPhone frame around them."),
                           font: CCFont.caption, color: CCTheme.color.mutedForeground, lines: 0)
        let stack = UIStackView(arrangedSubviews: [label, row, importStatusRow, importError, hint])
        stack.axis = .vertical
        stack.spacing = CCSpace.sm
        return stack
    }

    private func buildInbox() {
        let label = ccLabel(String(localized: "Waiting to upload", comment: "Section label: recordings not uploaded yet"), font: CCFont.labelSemibold, color: CCTheme.color.mutedForeground)
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
        var linkState = LinkStage.State.idle
        var needsSettings = false
        switch status {
        case .signedOut:
            title = String(localized: "Signed out", comment: "Capture status title")
            detail = String(localized: "Sign in to stream this \(ThisDevice.noun) to your Mac.", comment: "Argument is iPhone or iPad")
            canStream = false
        case .unavailable(let message):
            dot = colors.destructive
            title = String(localized: "Can't link this \(ThisDevice.noun)", comment: "Argument is iPhone or iPad")
            detail = message
            linkState = .blocked
        case .localNetworkOff:
            dot = colors.warning
            title = String(localized: "Local Network is off", comment: "Capture status title: iOS permission")
            detail = String(localized: "Turn on Local Network for CaptureCat in Settings so this \(ThisDevice.noun) can find your Mac.", comment: "Argument is iPhone or iPad; Local Network is the iOS Settings switch")
            linkState = .blocked
            needsSettings = true
        case .otherAccount(let macName):
            dot = colors.warning
            title = String(localized: "Looking for your Mac…")
            detail = String(localized: "“\(macName)” is nearby but signed in to a different account. Use the same account on both.", comment: "Argument is a Mac's name")
            searching = true
            linkState = .searching
        case .connecting(let macName):
            dot = colors.primary
            title = String(localized: "Connecting to \(macName)…", comment: "Argument is the Mac's name")
            detail = String(localized: "Found your Mac. This takes a moment.")
            searching = true
            linkState = .connecting
        case .searching:
            dot = colors.warning
            title = String(localized: "Looking for your Mac…")
            detail = String(localized: "Open CaptureCat on your Mac — same Wi-Fi, same account.")
            searching = true
            linkState = .searching
        case .connected(let macName):
            dot = colors.success
            title = String(localized: "Connected to \(macName)", comment: "Argument is the Mac's name")
            detail = String(localized: "Ready. Start streaming, then pick this \(ThisDevice.noun) as the source on your Mac.", comment: "Argument is iPhone or iPad")
            linkState = .connected
        }
        let key = "\(title)|\(detail)"
        let first = statusKey.isEmpty
        if key != statusKey {
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
        if linkState == .connected, linkStage.state != .connected, !first, view.window != nil { CCHaptics.success() }
        linkStage.setState(linkState)
        streamButton.isEnabled = canStream
        if settingsButton.isHidden == needsSettings {
            CCMotion.run(duration: 0.3, curve: .settle) {
                self.settingsButton.isHidden = !needsSettings
                self.streamButton.isHidden = needsSettings
                self.column.layoutIfNeeded()
            }
        }

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
        bannerLabel.text = String(localized: "\(request.macName) asked for your screen", comment: "Banner; argument is the Mac's name (or 'your Mac')")
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
    #if DEBUG
    var probeLinkStage: LinkStage { linkStage }
    var probeScroll: UIScrollView { scrollView }
    #endif
}
