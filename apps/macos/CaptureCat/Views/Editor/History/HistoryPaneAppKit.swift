import AppKit

// MARK: - Environment

/// What the History pane needs from the app: the history client and the
/// app-level actions (sync, sign-in, preview). The editor builds `.live`
/// from its AppState; `--history-panel-shot` passes a stub-backed one, so
/// the probe drives the REAL pane inside the REAL editor shell.
@MainActor
final class EditorHistoryEnvironment {
    let client: CloudHistoryClient
    /// Where a project's files live (the app: `project.projectDirectory`).
    let directory: (Project) -> URL
    let isSignedIn: () -> Bool
    var signIn: ((NSWindow) -> Void)?
    /// "Sync now" (push without opening the browser).
    var syncNow: ((Project, NSWindow) -> Void)?
    /// Show `preview` (an earlier version, `isPreview`) in the editor.
    var preview: ((Project, CloudVersion, NSWindow?) -> Void)?

    init(client: CloudHistoryClient, directory: @escaping (Project) -> URL, isSignedIn: @escaping () -> Bool) {
        self.client = client
        self.directory = directory
        self.isSignedIn = isSignedIn
    }

    static func live(appState: AppState) -> EditorHistoryEnvironment {
        let env = EditorHistoryEnvironment(
            client: .live(),
            directory: { $0.projectDirectory },
            isSignedIn: { AuthKeychain.currentToken() != nil })
        env.signIn = { [weak appState] window in
            guard let appState else { return }
            Task { @MainActor in
                do { try await appState.signIn() } catch where AuthService.isUserCancellation(error) {} catch {
                    CCAlert(title: "Sign-in failed", message: error.localizedDescription).beginSheet(for: window)
                }
            }
        }
        env.syncNow = { [weak appState] project, window in
            guard let appState else { return }
            CloudSyncController.shared.syncNow(project: project, appState: appState, window: window)
        }
        env.preview = { [weak appState, weak env] preview, version, window in
            guard let appState, let env else { return }
            VersionPreviewController.shared.begin(preview: preview, version: version, appState: appState,
                                                  environment: env, window: window)
        }
        return env
    }
}

// MARK: - Pane

/// The inspector column's History pane (docs/project-history.md §1 Mac):
/// an "On this Mac — not synced" pseudo-row, then one `InspectorSectionBox`
/// per day of versions (`HistoryRowView`: CCAvatar + CCBadges, one
/// `CCGlideHighlight` wash gliding between rows), `CCSkeleton.lines` while
/// loading, `CCEmptyState` for a project never uploaded, and the footer
/// "History keeps X of removed media [Free up]".
///
/// State flows in through `reload()` (on show, after every sync — the
/// controller's `didSyncNotification` — and after each action); actions go
/// out through the environment's closures. All chrome is CCKit.
@MainActor
final class HistoryPaneAppKit: NSView {
    enum State: Equatable {
        case loading
        case signedOut
        case neverUploaded
        case loaded(CloudVersionPage)
        case failed(String)
    }

    var onClose: (() -> Void)?

    private let project: Project
    private let environment: EditorHistoryEnvironment
    private(set) var state: State = .loading
    private(set) var local: CloudLocalStatus?
    private var page: CloudVersionPage?

    private let titleField = NSTextField(labelWithString: "History")
    private let closeButton = CCButton(symbol: "xmark", style: .ghost, size: .sm)
    private let scroll = NSScrollView()
    private let document = FlippedView()
    private let stack = NSStackView()
    private var glide: CCGlideHighlight!
    private(set) var rows: [HistoryRowView] = []
    private(set) var sections: [InspectorSectionBox] = []
    private(set) var localRow: HistoryLocalRowView?
    private(set) var skeleton: NSView?
    private(set) var emptyState: CCEmptyState?
    private(set) var errorCallout: CCCallout?
    private(set) var footerLabel: NSTextField?
    private(set) var freeUpButton: CCButton?
    private var loadTask: Task<Void, Never>?
    private var generation = 0
    private var syncObserver: (any NSObjectProtocol)?
    private var localTimer: Timer?
    private var themeObservation: CCThemeObservation?
    private var busyDialog: CloudSyncProgressDialog?

    /// Defect injection for `--history-panel-shot` (proves the structural
    /// gate can fail): drop the last row of every day.
    static var debugDropLastRowPerDay = false

    override var isFlipped: Bool { true }

    init(project: Project, environment: EditorHistoryEnvironment) {
        self.project = project
        self.environment = environment
        super.init(frame: .zero)
        wantsLayer = true
        build()
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
        let projectID = project.id
        syncObserver = NotificationCenter.default.addObserver(
            forName: CloudSyncController.didSyncNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard (note.object as? UUID) == projectID else { return }
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        if let syncObserver { NotificationCenter.default.removeObserver(syncObserver) }
        localTimer?.invalidate()
        loadTask?.cancel()
    }

    private func build() {
        titleField.lineBreakMode = .byTruncatingTail
        closeButton.onClick = { [weak self] in self?.onClose?() }
        CCTooltip.attach(to: closeButton, text: "Back to Inspector")

        document.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = CCSpace.lg
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        // Hosted on the (unflipped) stack, never the flipped document: the
        // wash rides an unflipped subview, and a flipped host would mirror it.
        glide = CCGlideHighlight(host: stack, radius: .md)

        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 16, right: 0)

        for view in [titleField, closeButton, scroll] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            titleField.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -CCSpace.sm),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            closeButton.centerYAnchor.constraint(equalTo: titleField.centerYAnchor),

            scroll.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -8),
        ])
    }

    private func applyTheme() {
        titleField.font = CCTheme.font.header
        titleField.textColor = CCTheme.color.foreground
        footerLabel?.font = CCTheme.font.caption
        footerLabel?.textColor = CCTheme.color.mutedForeground
    }

    // MARK: - Lifecycle

    /// Called by the inspector when the pane is shown / hidden.
    func setActive(_ active: Bool) {
        localTimer?.invalidate()
        localTimer = nil
        guard active else { return }
        reload()
        // The pseudo-row follows edits made while the pane is open (the
        // autosave lands ~0.5 s after an edit).
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLocal() }
        }
        RunLoop.main.add(timer, forMode: .common)
        localTimer = timer
    }

    func reload() {
        generation += 1
        let token = generation
        loadTask?.cancel()
        local = environment.client.localStatus(projectID: project.id, projectDirectory: environment.directory(project))
        guard environment.isSignedIn() else {
            render(.signedOut)
            return
        }
        // Keep showing the loaded list during a refresh; skeleton only at first.
        if page == nil { render(.loading) }
        let client = environment.client
        let projectID = project.id
        loadTask = Task { [weak self] in
            do {
                let fetched = try await client.page(projectID: projectID)
                guard let self, token == self.generation, !Task.isCancelled else { return }
                if let fetched {
                    self.page = fetched
                    self.render(.loaded(fetched))
                } else {
                    self.page = nil
                    self.render(.neverUploaded)
                }
            } catch is CancellationError {
            } catch {
                guard let self, token == self.generation else { return }
                self.render(.failed(CloudSyncController.message(for: error)))
            }
        }
    }

    private func refreshLocal() {
        let fresh = environment.client.localStatus(projectID: project.id, projectDirectory: environment.directory(project))
        guard fresh != local else { return }
        local = fresh
        render(state)
    }

    // MARK: - Render

    private func clear() {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        rows = []
        sections = []
        localRow = nil
        skeleton = nil
        emptyState = nil
        errorCallout = nil
        footerLabel = nil
        freeUpButton = nil
    }

    private func add(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func render(_ next: State) {
        let previous = state
        state = next
        clear()

        if let local, local.kind == .unsynced {
            let row = HistoryLocalRowView(summary: local.summary)
            row.onSyncNow = { [weak self] in self?.syncNow() }
            localRow = row
            add(row)
        }

        switch next {
        case .loading:
            let placeholder = NSStackView()
            placeholder.orientation = .vertical
            placeholder.alignment = .leading
            placeholder.spacing = CCSpace.lg
            for _ in 0..<3 {
                let lines = CCSkeleton.lines(2, lineHeight: 11, spacing: 8)
                placeholder.addArrangedSubview(lines)
                lines.widthAnchor.constraint(equalTo: placeholder.widthAnchor).isActive = true
            }
            skeleton = placeholder
            add(placeholder)
        case .signedOut:
            let button = CCButton(title: "Sign In", style: .primary, size: .sm) { [weak self] in
                guard let self, let window = self.window else { return }
                self.environment.signIn?(window)
            }
            showEmpty(CCEmptyState(symbol: "person.crop.circle", title: "Sign in to see History",
                                   message: "Versions live with the project in your CaptureCat cloud.",
                                   primary: button))
        case .neverUploaded:
            let button = CCButton(title: "Sync now", style: .primary, size: .sm) { [weak self] in self?.syncNow() }
            showEmpty(CCEmptyState(symbol: "clock.arrow.circlepath", title: "No history yet",
                                   message: "History starts when this project is synced to your CaptureCat cloud. "
                                       + "Every sync, web edit and merge after that is kept here.",
                                   primary: button))
        case .failed(let message):
            let callout = CCCallout(title: "Couldn’t load History", message: message, variant: .destructive)
            callout.setActions([CCButton(title: "Try Again", style: .secondary, size: .sm) { [weak self] in self?.reload() }])
            errorCallout = callout
            add(callout)
        case .loaded(let page):
            renderVersions(page)
        }

        // A first arrival of the list rises in, staggered (never on refresh).
        if case .loaded = next, previous == .loading, window != nil {
            CCMotion.stagger(sections, distance: 6, interval: 0.04)
        }
    }

    private func showEmpty(_ empty: CCEmptyState) {
        emptyState = empty
        add(empty)
    }

    private func renderVersions(_ page: CloudVersionPage) {
        let headID = page.headVersionID ?? page.versions.first?.id
        let calendar = Calendar.current
        var days: [(Date, [CloudVersion])] = []
        for version in page.versions {
            let day = calendar.startOfDay(for: version.date ?? Date())
            if let last = days.last, last.0 == day {
                days[days.count - 1].1.append(version)
            } else {
                days.append((day, [version]))
            }
        }
        for (day, versions) in days {
            let section = InspectorSectionBox(Self.dayTitle(day))
            var shown = versions
            if Self.debugDropLastRowPerDay, shown.count > 0 { shown.removeLast() }
            for version in shown {
                let row = HistoryRowView(version: version, isHead: version.id == headID,
                                         timeText: Self.timeText(version.date))
                row.onHighlight = { [weak self] row, active in self?.glide.update(row: row, active: active) }
                row.onActivate = { [weak self] row, event in self?.showMenu(for: row, event: event) }
                section.addRow(row)
                rows.append(row)
            }
            sections.append(section)
            add(section)
        }
        if let next = page.nextBefore {
            let older = CCButton(title: "Show older versions", style: .ghost, size: .sm) { [weak self] in
                self?.loadOlder(before: next)
            }
            stack.addArrangedSubview(older)
        }
        addFooter(page)
    }

    private func addFooter(_ page: CloudVersionPage) {
        var parts: [String] = []
        if let days = page.retention?.historyDays, days > 0 { parts.append("Kept for \(days) days") }
        if let max = page.retention?.maxNamed, max > 0 {
            parts.append("\(page.retention?.namedCount ?? page.versions.filter(\.isNamed).count) of \(max) named")
        }
        let footer = NSStackView()
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = CCSpace.xs
        if page.pinnedMediaBytes > 0 {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = CCSpace.sm
            let label = NSTextField(labelWithString: "History keeps \(Self.bytes(page.pinnedMediaBytes)) of removed media")
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.init(200), for: .horizontal)
            footerLabel = label
            row.addArrangedSubview(label)
            // Only the owner frees media, and only when unnamed versions
            // alone hold some of it (`freeableBytes`).
            if page.isOwner != false, page.freeableBytes > 0 {
                let free = CCButton(title: "Free up", style: .link, size: .sm) { [weak self] in self?.confirmFreeUp() }
                freeUpButton = free
                row.addArrangedSubview(free)
            }
            footer.addArrangedSubview(row)
        }
        if !parts.isEmpty {
            let caption = NSTextField(labelWithString: parts.joined(separator: " · "))
            caption.font = CCTheme.font.caption
            caption.textColor = CCTheme.color.mutedForeground
            footer.addArrangedSubview(caption)
        }
        guard !footer.arrangedSubviews.isEmpty else { return }
        add(footer)
        applyTheme()
    }

    private func loadOlder(before: Int) {
        guard let current = page else { return }
        let client = environment.client
        let projectID = project.id
        Task { [weak self] in
            guard let older = try? await client.page(projectID: projectID, before: before) else { return }
            guard let self else { return }
            var merged = current
            merged.versions += older.versions
            merged.nextBefore = older.nextBefore
            self.page = merged
            self.render(.loaded(merged))
        }
    }

    // MARK: - Words

    static func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(
            calendar.isDate(day, equalTo: Date(), toGranularity: .year) ? "EEEEMMMd" : "MMMdyyyy")
        return formatter.string(from: day)
    }

    static func timeText(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    /// "Sep 28, 3:42 PM".
    static func stamp(_ date: Date?) -> String {
        guard let date else { return "an earlier version" }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMdjmm")
        return formatter.string(from: date)
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    // MARK: - Actions

    private func showMenu(for row: HistoryRowView, event: NSEvent?) {
        let version = row.version
        let menu = NSMenu()
        if !row.isHead {
            menu.addItem(CloudMenuTarget.item("Preview") { [weak self] in self?.preview(version) })
        }
        menu.addItem(CloudMenuTarget.item(version.isNamed ? "Rename Version…" : "Name This Version…") { [weak self] in
            self?.name(version)
        })
        if !row.isHead {
            menu.addItem(CloudMenuTarget.item("Compare with Current") { [weak self] in self?.compare(version) })
            menu.addItem(.separator())
            menu.addItem(CloudMenuTarget.item("Restore This Version…") { [weak self] in self?.confirmRestore(version) })
            if page?.isOwner != false {
                menu.addItem(CloudMenuTarget.item("Delete Version…") { [weak self] in self?.confirmDelete(version) })
            }
        }
        glide.update(row: row, active: true)
        if let event, event.type == .rightMouseDown {
            CaptureCatMenuPresenter.showContextMenu(menu, with: event, for: row)
        } else {
            CaptureCatMenuPresenter.show(menu, from: row, edge: .below)
        }
    }

    func syncNow() {
        guard let window else { return }
        environment.syncNow?(project, window)
    }

    func preview(_ version: CloudVersion) {
        let client = environment.client
        let projectID = project.id
        let directory = environment.directory(project)
        Task { [weak self] in
            do {
                let preview = try await client.previewProject(projectID: projectID, versionID: version.id,
                                                              projectDirectory: directory)
                guard let self else { return }
                self.environment.preview?(preview, version, self.window)
            } catch {
                self?.alert("Couldn’t open that version", error)
            }
        }
    }

    func name(_ version: CloudVersion) {
        guard let window else { return }
        let alert = CCAlert(
            title: version.isNamed ? "Rename this version" : "Name this version",
            message: "Named versions are kept beyond the history window, so you can always come back to them.")
        let field = CCField(placeholder: "e.g. Sent to client", value: version.label ?? "")
        alert.accessoryView = field
        alert.addButton("Save", role: .primary)
        alert.addButton("Cancel")
        let client = environment.client
        let projectID = project.id
        alert.beginSheet(for: window) { [weak self] choice in
            guard choice == 0 else { return }
            let label = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            Task { [weak self] in
                do {
                    _ = try await client.rename(projectID: projectID, versionID: version.id,
                                                label: label.isEmpty ? nil : String(label.prefix(80)))
                    self?.reload()
                } catch {
                    self?.alert("Couldn’t name that version", error)
                }
            }
        }
    }

    func compare(_ version: CloudVersion) {
        let client = environment.client
        let projectID = project.id
        let directory = environment.directory(project)
        Task { [weak self] in
            do {
                let detail = try await client.detail(projectID: projectID, versionID: version.id)
                let current = (try? Data(contentsOf: directory.appendingPathComponent("project.json"))) ?? Data()
                guard let self, let window = self.window else { return }
                let dialog = VersionCompareDialog(version: version, versionDocument: detail.document,
                                                  currentDocument: current, projectName: self.project.name)
                dialog.present(over: window)
            } catch {
                self?.alert("Couldn’t compare", error)
            }
        }
    }

    func confirmRestore(_ version: CloudVersion) {
        guard let window else { return }
        let alert = CCAlert(
            title: "Restore the version from \(Self.stamp(version.date))?",
            message: "Your current version stays in History — restoring adds this one as the newest version.")
        alert.addButton("Restore", role: .primary)
        alert.addButton("Cancel")
        alert.beginSheet(for: window) { [weak self] choice in
            if choice == 0 { self?.restore(version) }
        }
    }

    func restore(_ version: CloudVersion) {
        guard let window else { return }
        let dialog = CloudSyncProgressDialog(title: "Restoring", subtitle: Self.stamp(version.date))
        dialog.present(over: window)
        busyDialog = dialog
        let client = environment.client
        let project = project
        let directory = environment.directory(project)
        Task { [weak self] in
            do {
                let outcome = try await client.restore(versionID: version.id, project: project,
                                                       projectDirectory: directory) { step in
                    dialog.update(step, weights: CloudSyncController.pushWeights)
                }
                dialog.finish(message: "Restored")
                dialog.dismiss {
                    guard let self else { return }
                    self.busyDialog = nil
                    switch outcome {
                    case .restored:
                        CloudSyncController.shared.showToast(
                            title: "Restored the version from \(Self.stamp(version.date))",
                            message: "The version before it is still in History.",
                            symbol: "clock.arrow.circlepath", in: window)
                    case .needsSync:
                        CCAlert(title: "Sync first",
                                message: "This Mac has changes that conflict with the cloud. Sync them, then restore.")
                            .beginSheet(for: window)
                    }
                    NotificationCenter.default.post(name: CloudSyncController.didSyncNotification, object: project.id)
                }
            } catch {
                dialog.dismiss {
                    self?.busyDialog = nil
                    self?.alert("Couldn’t restore that version", error)
                }
            }
        }
    }

    func confirmDelete(_ version: CloudVersion) {
        guard let window else { return }
        let alert = CCAlert(title: "Delete this version?",
                            message: "The version from \(Self.stamp(version.date)) is removed from History for everyone.")
        alert.addButton("Delete", role: .destructive)
        alert.addButton("Cancel")
        let client = environment.client
        let projectID = project.id
        alert.beginSheet(for: window) { [weak self] choice in
            guard choice == 0 else { return }
            Task { [weak self] in
                do {
                    try await client.delete(projectID: projectID, versionID: version.id)
                    self?.reload()
                } catch {
                    self?.alert("Couldn’t delete that version", error)
                }
            }
        }
    }

    func confirmFreeUp() {
        guard let window, let page else { return }
        let alert = CCAlert(
            title: "Free up \(Self.bytes(page.freeableBytes))?",
            message: "This deletes the unnamed versions that keep media the project no longer uses. "
                + "Named versions and the current one are kept.")
        alert.addButton("Free Up", role: .destructive)
        alert.addButton("Cancel")
        let client = environment.client
        let projectID = project.id
        alert.beginSheet(for: window) { [weak self] choice in
            guard choice == 0 else { return }
            Task { [weak self] in
                do {
                    let result = try await client.freeUp(projectID: projectID)
                    guard let self, let window = self.window else { return }
                    CloudSyncController.shared.showToast(
                        title: "Freed \(Self.bytes(result.releasedBytes))",
                        message: result.deletedVersions.count == 1 ? "1 version removed from History"
                            : "\(result.deletedVersions.count) versions removed from History",
                        symbol: "externaldrive", in: window)
                    self.reload()
                } catch {
                    self?.alert("Couldn’t free up space", error)
                }
            }
        }
    }

    private func alert(_ title: String, _ error: Error) {
        guard let window else { return }
        CCAlert(title: title, message: CloudHistoryClient.message(for: error)).beginSheet(for: window)
    }

    // MARK: - Probe seams (`--history-panel-shot`)

    var probeGlide: CCGlideHighlight { glide }
    var probeScroll: NSScrollView { scroll }
    var probeCloseButton: CCButton { closeButton }
    var probeDocument: NSView { document }
    /// The glide wash's host (row frames convert into it).
    var probeList: NSView { stack }

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }
}
