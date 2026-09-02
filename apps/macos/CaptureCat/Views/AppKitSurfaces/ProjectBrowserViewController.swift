import AppKit
import UniformTypeIdentifiers

/// Browser capture-type filter — narrows the mixed grid to one capture kind.
/// Raw values are the UserDefaults persistence identity; never rename one.
/// Pure predicate lives here (nonisolated) so the --notes-test harness can
/// assert it without booting the browser.
enum CaptureTypeFilter: String, CaseIterable {
    case all
    case videos
    case images
    case notes

    static let defaultsKey = "browserTypeFilter"

    var title: String {
        switch self {
        case .all: return "All"
        case .videos: return "Videos"
        case .images: return "Images"
        case .notes: return "Notes"
        }
    }

    /// Whether a capture belongs under this filter. `isImage` is only
    /// consulted for projects (`isNote == false`).
    func includes(isNote: Bool, isImage: Bool) -> Bool {
        switch self {
        case .all: return true
        case .notes: return isNote
        case .images: return !isNote && isImage
        case .videos: return !isNote && !isImage
        }
    }
}

/// Native project browser — liquid-glass sidebar (All Captures / Pinned /
/// Shared / user folders) beside an NSCollectionView grid of project cards.
/// The sidebar uses NSGlassEffectView on macOS 26+ and falls back to an
/// NSVisualEffectView sidebar material on earlier systems. Organization
/// (folders, pins, shared marks) lives in ProjectLibrary, never in the
/// project files themselves. Cards drag onto folder rows; the context menu
/// mirrors every drag affordance.
@MainActor
final class ProjectBrowserViewController: NSViewController {
    private let appState: AppState

    enum SidebarFilter: Equatable, Hashable {
        case all
        case pinned
        case shared
        case folder(UUID)
    }

    static let projectIDPasteboardType = NSPasteboard.PasteboardType("so.capturecat.project-id")

    /// One grid slot — video projects and text notes share the browser.
    enum BrowserEntry {
        case project(Project)
        case note(Note)
    }

    private var searchText = ""
    private var filter: SidebarFilter = .all
    /// Header type filter (All / Videos / Images / Notes) — composes with
    /// the sidebar filter and search text; persisted across launches.
    private var typeFilter: CaptureTypeFilter =
        UserDefaults.standard.string(forKey: CaptureTypeFilter.defaultsKey)
            .flatMap(CaptureTypeFilter.init(rawValue:)) ?? .all
    /// Header type filter control — the kit's segmented, counts folded into
    /// the segment titles ("Videos · 18").
    private var filterSegmented: CCSegmented!
    private var entries: [BrowserEntry] = []
    /// OCR-only search matches → the one-line "match: …" shown on the card.
    private var searchSnippets: [UUID: String] = [:]
    private var observation: SurfaceObservation?
    /// Retheme the browser chrome live; controls own their state colors,
    /// this covers the controller-level chrome plus a grid reload so
    /// configure-time colors (meta lines, snippets) re-resolve.
    private var themeObservation: CCThemeObservation?

    private let sidebar = BrowserSidebarView()
    private var sidebarWidthConstraint: NSLayoutConstraint!
    private var isSidebarCollapsed = false
    private let sidebarToggleButton = HoverPillButton(title: "", symbol: "sidebar.left")
    private let headerBar = HeaderChromeView()
    private let backButton = HoverPillButton(title: "Back to Editor", symbol: "chevron.left")
    /// Row 2 of the header: full-width pill search bar + suggestions panel.
    private let searchRow = HeaderChromeView()
    private let searchBar = CCSearchField(placeholder: "Search captures… (⌘K)")
    private let suggestionsPanel = SearchSuggestionsPanel()
    private var suggestionsTask: Task<Void, Never>?
    /// Record-red capsule — the one place the browser uses the destructive
    /// fill for its recording connotation, not for a destructive action.
    private let newRecordingButton = CCButton(
        title: "New Recording", symbol: "record.circle.fill", style: .destructive,
        radius: .full
    )
    private let scrollView = NSScrollView()
    private var collectionView: NSCollectionView!
    private let emptyStateView = NSView()
    private let emptyTitle = NSTextField(labelWithString: "No Captures Yet")
    private let emptySubtitle = NSTextField(
        wrappingLabelWithString: "Start a new recording from the menu bar to create your first capture."
    )
    private let headerHairline = NSView()
    private let emptyIcon = NSImageView()
    /// Width the grid was last laid out against — see `viewDidLayout`.
    private var lastGridWidth: CGFloat = 0

    init(appState: AppState) {
        self.appState = appState
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLayout() {
        super.viewDidLayout()
        // `sizeForItemAt` derives the card width from `collectionView.bounds.width`.
        // The first layout pass runs before the window has framed the scroll view,
        // so that width is 0 and every card clamps to the 1pt floor — and because
        // a flow layout only re-asks when it is invalidated, they STAY 1pt wide
        // for the life of the window. (Symptom: an all-black browser, and a flood
        // of "CardBackdropView.width == 1" constraint conflicts as each card's
        // 8/10pt internal padding fights its own 1pt frame.)
        guard let collectionView else { return }
        let width = collectionView.bounds.width
        guard abs(width - lastGridWidth) > 0.5 else { return }
        lastGridWidth = width
        collectionView.collectionViewLayout?.invalidateLayout()
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        view = root

        buildSidebar()
        buildHeader()
        buildGrid()
        buildEmptyState()
        buildSuggestionsOverlay()

        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }

        // Re-render whenever the store, library, search, or current project
        // changes. Reading the library fields here arms the observation on them.
        observation = SurfaceObservation { [weak self] in
            guard let self else { return }
            let projects = self.appState.projectStore.projects
            _ = self.appState.noteStore.notes
            let hasCurrent = self.appState.currentProject != nil
            let library = self.appState.library
            _ = library.folders
            _ = library.pinnedIDs
            _ = library.sharedURLs
            // Re-render as background share uploads progress.
            _ = self.appState.shareJobCenter.jobs
            // Re-run the search as the OCR text index fills in.
            _ = self.appState.captureTextIndex.records
            // Account row tracks sign-in state.
            _ = self.appState.authStateRevision
            let user = self.appState.authService.currentUser
            let stored = AuthKeychain.load()
            self.sidebar.accountRow.configure(
                name: user?.name ?? stored?.name ?? user?.email,
                imageURL: stored?.image.flatMap(URL.init(string:)),
                signedIn: user != nil
            )
            self.rebuildSidebarRows()
            self.applySnapshot(projects: projects, hasCurrentProject: hasCurrent)
        }
    }

    /// Controller-level chrome colors — one path for init and theme changes.
    /// (The type filter is a CCSegmented now; it themes itself.)
    private func applyTheme() {
        view.layer?.backgroundColor = EditorThemeKit.windowBackground.cgColor
        headerHairline.layer?.backgroundColor = EditorThemeKit.hairline.cgColor
        emptyIcon.contentTintColor = EditorThemeKit.textTertiary
        emptyTitle.textColor = EditorThemeKit.textPrimary
        emptySubtitle.textColor = EditorThemeKit.textSecondary
        // Cells own their chassis colors, but configure-time colors (meta
        // lines, snippets) re-resolve on a rebind.
        collectionView?.reloadData()
    }

    // MARK: - Sidebar

    private func buildSidebar() {
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sidebar)
        sidebarWidthConstraint = sidebar.widthAnchor.constraint(equalToConstant: 208)
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: view.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sidebarWidthConstraint,
        ])
        sidebar.onNewFolder = { [weak self] in self?.promptNewFolder() }
        sidebar.accountMenuProvider = { [weak self] in
            guard let self else { return nil }
            let menu = NSMenu()
            if let user = self.appState.authService.currentUser {
                if let email = user.email {
                    let info = NSMenuItem(title: email, action: nil, keyEquivalent: "")
                    info.isEnabled = false
                    menu.addItem(info)
                    menu.addItem(.separator())
                }
                menu.addItem(Self.closureItem("Manage Account…") {
                    NSWorkspace.shared.open(URL(string: "https://app.capturecat.so/settings")!)
                })
                menu.addItem(.separator())
                menu.addItem(Self.closureItem("Sign Out") { [weak self] in
                    try? self?.appState.signOut()
                })
            } else {
                menu.addItem(Self.closureItem("Sign In…") { [weak self] in
                    guard let self else { return }
                    Task { @MainActor in try? await self.appState.signIn() }
                })
            }
            return menu
        }
    }

    /// Apple-style "file it away" animation: a snapshot of the card flies
    /// from its grid position into the sidebar folder row, shrinking and
    /// fading as it lands; the row pulses on arrival. The library mutation
    /// happens immediately — the ghost is purely visual.
    private func animateCard(_ projectID: UUID, intoFolder folderID: UUID) {
        guard !isSidebarCollapsed,
              let index = entries.firstIndex(where: {
                  if case .project(let project) = $0 { return project.id == projectID }
                  return false
              }),
              let item = collectionView.item(at: IndexPath(item: index, section: 0)),
              let rowView = sidebar.rowView(for: .folder(folderID)) else { return }

        let cardView = item.view
        guard let rep = cardView.bitmapImageRepForCachingDisplay(in: cardView.bounds) else { return }
        cardView.cacheDisplay(in: cardView.bounds, to: rep)
        let snapshot = NSImage(size: cardView.bounds.size)
        snapshot.addRepresentation(rep)

        let startFrame = view.convert(cardView.bounds, from: cardView)
        let ghost = NSImageView(image: snapshot)
        ghost.imageScaling = .scaleAxesIndependently
        ghost.wantsLayer = true
        ghost.frame = startFrame
        view.addSubview(ghost)

        guard let layer = ghost.layer else { return }
        layer.cornerRadius = CCTheme.radius(.lg)
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        layer.shadowOpacity = 0.4
        layer.shadowRadius = 14
        layer.shadowOffset = CGSize(width: 0, height: -4)
        // Scale about the center, not the corner.
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: startFrame.midX, y: startFrame.midY)
        layer.frame = startFrame

        let rowRect = view.convert(rowView.bounds, from: rowView)
        let endCenter = CGPoint(x: rowRect.minX + 22, y: rowRect.midY)
        let startCenter = layer.position
        // The card lands at ~56pt wide — big enough to still read as the
        // project while it drops in.
        let endScale = 56 / max(startFrame.width, 1)

        // Keynote-style flight: quick pop up, then an arced sweep that eases
        // into the folder. The arc bows away from the straight line, toward
        // the top of the window (root view is unflipped: +y is up).
        let path = CGMutablePath()
        path.move(to: startCenter)
        let control = CGPoint(
            x: (startCenter.x + endCenter.x) / 2 - 40,
            y: max(startCenter.y, endCenter.y) + 90
        )
        path.addQuadCurve(to: endCenter, control: control)

        let position = CAKeyframeAnimation(keyPath: "position")
        position.path = path
        position.calculationMode = .paced
        position.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut)]

        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [1.0, 1.07, endScale]
        scale.keyTimes = [0, 0.22, 1]
        scale.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeIn),
        ]

        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1.0, 1.0, 0.25]
        fade.keyTimes = [0, 0.7, 1]

        let group = CAAnimationGroup()
        group.animations = [position, scale, fade]
        group.duration = 0.55
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            ghost.removeFromSuperview()
            self?.sidebar.pulseRow(for: .folder(folderID))
        }
        layer.add(group, forKey: "fly-to-folder")
        CATransaction.commit()
    }

    private func toggleSidebar() {
        isSidebarCollapsed.toggle()
        if !isSidebarCollapsed { sidebar.isHidden = false }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            context.allowsImplicitAnimation = true
            sidebarWidthConstraint.animator().constant = isSidebarCollapsed ? 0 : 208
            view.layoutSubtreeIfNeeded()
        }, completionHandler: { [weak self] in
            guard let self else { return }
            if self.isSidebarCollapsed { self.sidebar.isHidden = true }
        })
    }

    private func rebuildSidebarRows() {
        let library = appState.library
        var rows: [BrowserSidebarView.Row] = [
            .init(id: .all, title: "All Captures",
                  icon: SidebarIconRenderer.chip(
                    symbol: "square.grid.2x2.fill",
                    top: NSColor(calibratedRed: 0.47, green: 0.57, blue: 0.75, alpha: 1),
                    bottom: NSColor(calibratedRed: 0.27, green: 0.37, blue: 0.56, alpha: 1)),
                  isSelected: filter == .all),
            .init(id: .pinned, title: "Pinned",
                  icon: SidebarIconRenderer.chip(
                    symbol: "pin.fill",
                    top: NSColor(calibratedRed: 0.87, green: 0.69, blue: 0.47, alpha: 1),
                    bottom: NSColor(calibratedRed: 0.68, green: 0.47, blue: 0.26, alpha: 1)),
                  isSelected: filter == .pinned),
            .init(id: .shared, title: "Shared",
                  icon: SidebarIconRenderer.chip(
                    symbol: "link",
                    top: NSColor(calibratedRed: 0.52, green: 0.71, blue: 0.45, alpha: 1),
                    bottom: NSColor(calibratedRed: 0.30, green: 0.50, blue: 0.26, alpha: 1)),
                  isSelected: filter == .shared),
        ]
        for folder in library.folders {
            rows.append(.init(
                id: .folder(folder.id), title: folder.name,
                icon: SidebarIconRenderer.folder(),
                isSelected: filter == .folder(folder.id), isFolder: true
            ))
        }
        sidebar.setRows(rows)
        sidebar.onSelect = { [weak self] id in
            guard let self else { return }
            self.filter = id
            self.rebuildSidebarRows()
            self.applySnapshot(
                projects: self.appState.projectStore.projects,
                hasCurrentProject: self.appState.currentProject != nil
            )
        }
        sidebar.onDropProject = { [weak self] projectID, target in
            guard let self, case .folder(let folderID) = target else { return }
            self.appState.library.add(projectID, toFolder: folderID)
        }
        sidebar.folderMenuProvider = { [weak self] target in
            guard let self, case .folder(let folderID) = target,
                  let folder = self.appState.library.folders.first(where: { $0.id == folderID })
            else { return nil }
            let menu = NSMenu()
            menu.addItem(Self.closureItem("Rename Folder...") { [weak self] in
                self?.promptRenameFolder(folder)
            })
            let delete = Self.closureItem("Delete Folder") { [weak self] in
                guard let self else { return }
                if self.filter == .folder(folderID) { self.filter = .all }
                self.appState.library.deleteFolder(folderID)
            }
            delete.attributedTitle = NSAttributedString(
                string: "Delete Folder", attributes: [.foregroundColor: NSColor.systemRed])
            menu.addItem(delete)
            return menu
        }
    }

    private func promptNewFolder() {
        guard let window = view.window else { return }
        CCAlert.prompt(
            title: "New Folder",
            placeholder: "Folder name",
            confirmTitle: "Create",
            in: window
        ) { [weak self] name in
            guard let name else { return }
            let folder = self?.appState.library.createFolder(named: name)
            if let folder { self?.filter = .folder(folder.id) }
        }
    }

    private func promptRenameFolder(_ folder: LibraryFolder) {
        guard let window = view.window else { return }
        CCAlert.prompt(
            title: "Rename Folder",
            placeholder: "Folder name",
            initialValue: folder.name,
            confirmTitle: "Rename",
            in: window
        ) { [weak self] name in
            guard let name else { return }
            self?.appState.library.renameFolder(folder.id, to: name)
        }
    }

    // MARK: - Header

    private func buildHeader() {
        headerBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerBar)

        sidebarToggleButton.translatesAutoresizingMaskIntoConstraints = false
        sidebarToggleButton.toolTip = "Hide or show the sidebar"
        sidebarToggleButton.onClick = { [weak self] in self?.toggleSidebar() }
        headerBar.addSubview(sidebarToggleButton)

        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.onClick = { [weak self] in
            self?.appState.showProjectBrowser = false
        }
        headerBar.addSubview(backButton)

        // Type filter — the kit segmented (CCSegmented): one elevated well,
        // real padding, and the selection chip springs between segments.
        // Counts fold into the titles via setTitle on every snapshot.
        let segmented = CCSegmented(
            segments: CaptureTypeFilter.allCases.map(\.title),
            selectedIndex: CaptureTypeFilter.allCases.firstIndex(of: typeFilter) ?? 0,
            radius: .full,
            hoverWash: true
        ) { [weak self] index in
            self?.selectTypeFilter(CaptureTypeFilter.allCases[index])
        }
        filterSegmented = segmented
        segmented.translatesAutoresizingMaskIntoConstraints = false
        headerBar.addSubview(segmented)

        newRecordingButton.translatesAutoresizingMaskIntoConstraints = false
        newRecordingButton.onClick = { [weak self] in
            self?.appState.beginNewRecording()
        }
        headerBar.addSubview(newRecordingButton)

        // Row 2 — full-width pill search bar on its own 48pt band, then a
        // single hairline dividing the header block from the grid.
        searchRow.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(searchRow)

        searchBar.translatesAutoresizingMaskIntoConstraints = false
        searchBar.onQueryChange = { [weak self] query in self?.searchQueryChanged(query) }
        searchBar.onFocusChange = { [weak self] focused in
            guard let self else { return }
            if focused {
                self.refreshSuggestions()
            } else {
                self.hideSuggestions()
            }
        }
        searchBar.onCommand = { [weak self] command in
            self?.handleSearchCommand(command) ?? false
        }
        searchRow.addSubview(searchBar)

        let hairline = headerHairline
        hairline.translatesAutoresizingMaskIntoConstraints = false
        hairline.wantsLayer = true
        searchRow.addSubview(hairline)

        // Centering is a preference; the required ≥16pt gaps to both
        // neighbours win as space tightens, so nothing ever overlaps.
        let chipCenter = segmented.centerXAnchor.constraint(equalTo: headerBar.centerXAnchor)
        chipCenter.priority = NSLayoutConstraint.Priority(450)

        NSLayoutConstraint.activate([
            // Safe-area top keeps the header (and its Back button) clear of
            // the transparent title bar / traffic lights in the editor's
            // fullSizeContentView window.
            headerBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            headerBar.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            headerBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerBar.heightAnchor.constraint(equalToConstant: 52),

            sidebarToggleButton.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor, constant: 16),
            sidebarToggleButton.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),

            backButton.leadingAnchor.constraint(equalTo: sidebarToggleButton.trailingAnchor, constant: 8),
            backButton.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),

            chipCenter,
            segmented.leadingAnchor.constraint(
                greaterThanOrEqualTo: backButton.trailingAnchor, constant: 16),
            segmented.trailingAnchor.constraint(
                lessThanOrEqualTo: newRecordingButton.leadingAnchor, constant: -16),
            segmented.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),

            newRecordingButton.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor, constant: -16),
            newRecordingButton.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),

            searchRow.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            searchRow.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            searchRow.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            searchRow.heightAnchor.constraint(equalToConstant: 48),

            searchBar.leadingAnchor.constraint(equalTo: searchRow.leadingAnchor, constant: 16),
            searchBar.trailingAnchor.constraint(equalTo: searchRow.trailingAnchor, constant: -16),
            searchBar.centerYAnchor.constraint(equalTo: searchRow.centerYAnchor),

            hairline.leadingAnchor.constraint(equalTo: searchRow.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: searchRow.trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: searchRow.bottomAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    /// Suggestions overlay — added LAST in loadView so it sits ABOVE the
    /// grid in z-order (added earlier it rendered, invisibly, behind the
    /// scroll view). Hidden panels never hit-test, so card clicks are
    /// untouched while it's dismissed.
    private func buildSuggestionsOverlay() {
        suggestionsPanel.translatesAutoresizingMaskIntoConstraints = false
        suggestionsPanel.isHidden = true
        suggestionsPanel.onPick = { [weak self] suggestion in self?.pick(suggestion) }
        view.addSubview(suggestionsPanel)
        NSLayoutConstraint.activate([
            suggestionsPanel.topAnchor.constraint(equalTo: searchBar.bottomAnchor, constant: 6),
            suggestionsPanel.leadingAnchor.constraint(equalTo: searchBar.leadingAnchor),
            suggestionsPanel.trailingAnchor.constraint(equalTo: searchBar.trailingAnchor),
        ])
    }

    private func selectTypeFilter(_ kind: CaptureTypeFilter) {
        guard typeFilter != kind else { return }
        typeFilter = kind
        UserDefaults.standard.set(kind.rawValue, forKey: CaptureTypeFilter.defaultsKey)
        // Keyboard/menu selection must move the segmented's chip too; a click
        // on the control itself makes this a no-op (already selected).
        if let index = CaptureTypeFilter.allCases.firstIndex(of: kind) {
            filterSegmented.selectedIndex = index
        }
        applySnapshot(
            projects: appState.projectStore.projects,
            hasCurrentProject: appState.currentProject != nil
        )
    }

    // ⌘1–⌘4 via the View menu (targets the responder chain, so they only
    // fire while the browser is on screen).
    @objc func filterAllCaptures(_ sender: Any?) { selectTypeFilter(.all) }
    @objc func filterVideoCaptures(_ sender: Any?) { selectTypeFilter(.videos) }
    @objc func filterImageCaptures(_ sender: Any?) { selectTypeFilter(.images) }
    @objc func filterNoteCaptures(_ sender: Any?) { selectTypeFilter(.notes) }

    // MARK: - Search (row 2)

    /// ⌘K via the View menu (nil-targeted, resolves here while the browser
    /// is on screen).
    @objc func focusSearchField(_ sender: Any?) {
        searchBar.beginFocus()
    }

    private func searchQueryChanged(_ query: String) {
        searchText = query
        // Grid filters immediately (cheap); suggestions refresh on a short
        // debounce so OCR-snippet ranking never runs per keystroke.
        applySnapshot(
            projects: appState.projectStore.projects,
            hasCurrentProject: appState.currentProject != nil
        )
        suggestionsTask?.cancel()
        suggestionsTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.refreshSuggestions()
        }
    }

    private static let recentSearchesKey = "browserRecentSearches"

    private var recentSearches: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.recentSearchesKey) ?? [] }
        set { UserDefaults.standard.set(Array(newValue.prefix(5)), forKey: Self.recentSearchesKey) }
    }

    private func rememberSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var recents = recentSearches.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        recents.insert(trimmed, at: 0)
        recentSearches = recents
    }

    /// Suggestions for the current query: recents when empty, otherwise the
    /// plain-query row plus the top-5 ranked matches (titles + OCR/note text
    /// through the same CaptureSearchRanking the grid and MCP use).
    func currentSuggestions() -> [SearchSuggestion] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            return recentSearches.prefix(5).map { .recent($0) }
        }
        var suggestions: [SearchSuggestion] = [.query(query)]
        let index = appState.captureTextIndex
        let candidates = appState.projectStore.projects.map { project in
            CaptureSearchRanking.Candidate(
                id: project.id,
                title: project.name,
                text: index.record(for: project.id)?.fullText ?? "",
                frames: index.record(for: project.id)?.frames ?? [],
                kind: project.isImageCapture ? "image" : "video"
            )
        } + appState.noteStore.notes.map {
            CaptureSearchRanking.Candidate(id: $0.id, title: $0.title, text: $0.text, kind: "note")
        }
        for match in CaptureSearchRanking.rank(query: query, candidates: candidates).prefix(5) {
            // Video text matches carry the output-time landing spot.
            var seekTime: TimeInterval?
            if match.candidate.kind == "video", !match.candidate.frames.isEmpty,
               let project = appState.projectStore.projects
                   .first(where: { $0.id == match.candidate.id }) {
                seekTime = CaptureSearchSeek.seekOutputTime(
                    query: query, frames: match.candidate.frames, project: project
                )
            }
            suggestions.append(.capture(
                id: match.candidate.id,
                kind: match.candidate.kind,
                title: match.candidate.title,
                snippet: match.titleMatched ? nil : match.snippet,
                time: seekTime
            ))
        }
        return suggestions
    }

    /// Harness hook (--browser-shot): render the suggestions panel with
    /// fixture rows, bypassing focus. Not used by the app itself.
    func harnessShowSuggestions(_ suggestions: [SearchSuggestion]) {
        suggestionsPanel.show(suggestions)
    }

    /// Harness hooks (--browser-shot): drive the search pipeline exactly as
    /// typing does, and observe the grid + panel state.
    func harnessSetQuery(_ query: String) {
        searchBar.setQuery(query)
        searchQueryChanged(query)
    }

    var harnessEntryCount: Int { entries.count }
    var harnessSuggestionsPanelHidden: Bool { suggestionsPanel.isHidden }
    func harnessDismissSuggestions() { suggestionsPanel.dismiss() }
    var harnessCollectionView: NSCollectionView { collectionView }

    private func refreshSuggestions() {
        let suggestions = currentSuggestions()
        guard !suggestions.isEmpty, searchBar.isFocused else {
            hideSuggestions()
            return
        }
        suggestionsPanel.show(suggestions)
    }

    private func hideSuggestions() {
        suggestionsTask?.cancel()
        suggestionsPanel.dismiss()
    }

    /// Keyboard routed from the search field editor. Returns true when handled.
    private func handleSearchCommand(_ command: CCSearchField.Command) -> Bool {
        switch command {
        case .moveDown:
            guard !suggestionsPanel.isHidden else { refreshSuggestions(); return true }
            suggestionsPanel.moveSelection(1)
            return true
        case .moveUp:
            guard !suggestionsPanel.isHidden else { return false }
            suggestionsPanel.moveSelection(-1)
            return true
        case .commit:
            if !suggestionsPanel.isHidden, let selected = suggestionsPanel.selectedSuggestion {
                pick(selected)
            } else {
                rememberSearch(searchText)
                hideSuggestions()
            }
            return true
        case .cancel:
            if !suggestionsPanel.isHidden {
                hideSuggestions()
            } else if !searchText.isEmpty {
                searchBar.setQuery("")
                searchQueryChanged("")
            } else {
                view.window?.makeFirstResponder(collectionView)
            }
            return true
        }
    }

    private func pick(_ suggestion: SearchSuggestion) {
        switch suggestion {
        case .recent(let query), .query(let query):
            rememberSearch(query)
            searchBar.setQuery(query)
            searchQueryChanged(query)
            hideSuggestions()
        case .capture(let id, let kind, _, _, _):
            rememberSearch(searchText)
            hideSuggestions()
            if kind == "note" {
                if let note = appState.noteStore.notes.first(where: { $0.id == id }) {
                    NoteViewerWindowController.present(note: note, appState: appState)
                }
            } else if let project = appState.projectStore.projects.first(where: { $0.id == id }) {
                open(project)
            }
        }
    }

    // MARK: - Grid

    private func buildGrid() {
        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 20
        layout.minimumLineSpacing = 20
        layout.sectionInset = NSEdgeInsets(top: 20, left: 20, bottom: 24, right: 20)

        let grid = BrowserGridView()
        grid.onDeleteKey = { [weak self] in self?.deleteSelectedProjects() }
        collectionView = grid
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        // ⌘/⇧-click builds a selection for batch operations (delete);
        // a plain click still opens instantly (see didSelectItemsAt).
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.setDraggingSourceOperationMask(.copy, forLocal: true)
        collectionView.register(
            ProjectCardItem.self,
            forItemWithIdentifier: ProjectCardItem.identifier
        )
        collectionView.register(
            NoteCardItem.self,
            forItemWithIdentifier: NoteCardItem.identifier
        )

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: searchRow.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func buildEmptyState() {
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.isHidden = true

        let icon = emptyIcon
        icon.image = NSImage(
            systemSymbolName: "film.stack", accessibilityDescription: nil
        ) ?? NSImage()
        icon.symbolConfiguration = .init(pointSize: 34, weight: .regular)
        icon.translatesAutoresizingMaskIntoConstraints = false

        emptyTitle.font = .systemFont(ofSize: 16, weight: .semibold)
        emptyTitle.translatesAutoresizingMaskIntoConstraints = false

        emptySubtitle.font = .systemFont(ofSize: 12)
        emptySubtitle.alignment = .center
        emptySubtitle.translatesAutoresizingMaskIntoConstraints = false

        emptyStateView.addSubview(icon)
        emptyStateView.addSubview(emptyTitle)
        emptyStateView.addSubview(emptySubtitle)
        view.addSubview(emptyStateView)

        NSLayoutConstraint.activate([
            emptyStateView.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyStateView.widthAnchor.constraint(lessThanOrEqualToConstant: 320),

            icon.topAnchor.constraint(equalTo: emptyStateView.topAnchor),
            icon.centerXAnchor.constraint(equalTo: emptyStateView.centerXAnchor),
            emptyTitle.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 10),
            emptyTitle.centerXAnchor.constraint(equalTo: emptyStateView.centerXAnchor),
            emptySubtitle.topAnchor.constraint(equalTo: emptyTitle.bottomAnchor, constant: 6),
            emptySubtitle.leadingAnchor.constraint(equalTo: emptyStateView.leadingAnchor),
            emptySubtitle.trailingAnchor.constraint(equalTo: emptyStateView.trailingAnchor),
            emptySubtitle.bottomAnchor.constraint(equalTo: emptyStateView.bottomAnchor),
        ])
    }

    private func projects(matching filter: SidebarFilter, in projects: [Project]) -> [Project] {
        let library = appState.library
        switch filter {
        case .all:
            // Pinned first, store order within each group.
            return projects.filter { library.isPinned($0.id) }
                + projects.filter { !library.isPinned($0.id) }
        case .pinned:
            return projects.filter { library.isPinned($0.id) }
        case .shared:
            return projects.filter { library.isShared($0.id) }
        case .folder(let folderID):
            guard let folder = library.folders.first(where: { $0.id == folderID }) else { return [] }
            return folder.projectIDs.compactMap { id in projects.first { $0.id == id } }
        }
    }

    private func applySnapshot(projects: [Project], hasCurrentProject: Bool) {
        backButton.isHidden = !hasCurrentProject
        var scoped = self.projects(matching: filter, in: projects)

        // Notes live in "All Captures" (they have no pins/shares/folders),
        // merged with the unpinned projects by date; pinned projects stay
        // first, mirroring the project-only ordering.
        var notes: [Note] = []
        if filter == .all {
            notes = appState.noteStore.notes
        }

        // Search: token AND-matching over titles AND the OCR text index
        // ("stripe invoice" finds captures whose pixels contain both words).
        // Ranking — title matches first, then text-only matches by hit count
        // — is shared with the MCP search_captures tool (CaptureSearchRanking).
        searchSnippets = [:]
        var searchOrder: [UUID: Int] = [:]
        if !searchText.isEmpty {
            let index = appState.captureTextIndex
            var candidates = scoped.map { project in
                CaptureSearchRanking.Candidate(
                    id: project.id,
                    title: project.name,
                    text: index.record(for: project.id)?.fullText ?? "",
                    frames: index.record(for: project.id)?.frames ?? []
                )
            }
            candidates += notes.map {
                CaptureSearchRanking.Candidate(id: $0.id, title: $0.title, text: $0.text, kind: "note")
            }
            let ranked = CaptureSearchRanking.rank(query: searchText, candidates: candidates)
            for (position, match) in ranked.enumerated() {
                searchOrder[match.candidate.id] = position
                // Card shows WHY it matched only when the title alone didn't.
                if !match.titleMatched, let snippet = match.snippet {
                    searchSnippets[match.candidate.id] = snippet
                }
            }
            scoped = scoped.filter { searchOrder[$0.id] != nil }
            notes = notes.filter { searchOrder[$0.id] != nil }
        }
        // Per-type counts within the current sidebar scope + search, shown
        // on the chips; the type filter then narrows what the grid shows.
        let videoCount = scoped.filter { !$0.isImageCapture }.count
        let imageCount = scoped.count - videoCount
        updateTypeChipCounts(
            all: scoped.count + notes.count,
            videos: videoCount, images: imageCount, notes: notes.count
        )
        scoped = scoped.filter {
            typeFilter.includes(isNote: false, isImage: $0.isImageCapture)
        }
        if !typeFilter.includes(isNote: true, isImage: false) { notes = [] }

        let library = appState.library
        if !searchText.isEmpty {
            // Search results keep the ranking (title hits, then text hits by
            // hit count) rather than the pinned/date ordering.
            entries = (scoped.map(BrowserEntry.project) + notes.map(BrowserEntry.note))
                .sorted { entryRank($0, in: searchOrder) < entryRank($1, in: searchOrder) }
        } else {
            let pinned = scoped.filter { library.isPinned($0.id) }.map(BrowserEntry.project)
            let rest: [BrowserEntry] = (
                scoped.filter { !library.isPinned($0.id) }.map(BrowserEntry.project)
                    + notes.map(BrowserEntry.note)
            ).sorted { lhs, rhs in
                entryDate(lhs) > entryDate(rhs)
            }
            entries = pinned + rest
        }

        let noProjectsAtAll = projects.isEmpty && appState.noteStore.notes.isEmpty
        let filterEmpty = entries.isEmpty
        emptyStateView.isHidden = !filterEmpty
        if noProjectsAtAll {
            emptyTitle.stringValue = "No Captures Yet"
            emptySubtitle.stringValue =
                "Start a new recording from the menu bar to create your first capture."
        } else {
            switch filter {
            case .all:
                emptyTitle.stringValue = "No Matches"
                emptySubtitle.stringValue = "No captures match your search."
            case .pinned:
                emptyTitle.stringValue = "Nothing Pinned"
                emptySubtitle.stringValue = "Right-click a capture and choose Pin to keep it here."
            case .shared:
                emptyTitle.stringValue = "Nothing Shared"
                emptySubtitle.stringValue = "Captures appear here after you share them."
            case .folder:
                emptyTitle.stringValue = "Empty Folder"
                emptySubtitle.stringValue = "Drag captures here, or right-click one and choose Add to Folder."
            }
        }
        if filterEmpty, !noProjectsAtAll, typeFilter != .all {
            emptyTitle.stringValue = "No \(typeFilter.title)"
            emptySubtitle.stringValue = "No \(typeFilter.title.lowercased()) match the current filters."
        }
        searchRow.isHidden = noProjectsAtAll
        collectionView.reloadData()
    }

    private func updateTypeChipCounts(all: Int, videos: Int, images: Int, notes: Int) {
        // "Videos · 12" — count folds into the segment title, zero stays bare.
        func title(_ kind: CaptureTypeFilter, _ count: Int) -> String {
            count > 0 ? "\(kind.title) · \(count)" : kind.title
        }
        let counts: [CaptureTypeFilter: Int] = [
            .all: all, .videos: videos, .images: images, .notes: notes,
        ]
        for (index, kind) in CaptureTypeFilter.allCases.enumerated() {
            filterSegmented.setTitle(title(kind, counts[kind] ?? 0), at: index)
        }
    }

    private func entryRank(_ entry: BrowserEntry, in order: [UUID: Int]) -> Int {
        switch entry {
        case .project(let project): return order[project.id] ?? .max
        case .note(let note): return order[note.id] ?? .max
        }
    }

    private func entryDate(_ entry: BrowserEntry) -> Date {
        switch entry {
        case .project(let project): return project.createdAt
        case .note(let note): return note.createdAt
        }
    }

    // MARK: - Actions

    fileprivate func open(_ project: Project) {
        // Opening a video during an active search jumps the playhead to the
        // best-matching OCR frame — same one-shot pendingSeekOutputTime the
        // deep-link seeks use (the timeline consumes it in viewDidAppear,
        // after the player is ready). Notes/images unaffected.
        if !searchText.isEmpty, !project.isImageCapture,
           let frames = appState.captureTextIndex.record(for: project.id)?.frames,
           let seek = CaptureSearchSeek.seekOutputTime(
               query: searchText, frames: frames, project: project
           ) {
            appState.pendingSeekOutputTime = seek
        }
        appState.showProjectBrowser = false
        appState.openEditor(with: project)
    }

    fileprivate func promptRename(_ project: Project) {
        guard let window = view.window else { return }
        CCAlert.prompt(
            title: "Rename Capture",
            placeholder: "Capture name",
            initialValue: project.name,
            confirmTitle: "Rename",
            in: window
        ) { [weak self] name in
            guard let name else { return }
            self?.appState.projectStore.rename(project, to: name)
        }
    }

    fileprivate func promptDelete(_ project: Project) {
        guard let window = view.window else { return }
        let alert = CCAlert(
            title: "Delete Capture?",
            message: "Are you sure you want to delete \"\(project.name)\"? This cannot be undone."
        )
        alert.addButton("Delete", role: .destructive)
        alert.addButton("Cancel")
        alert.beginSheet(for: window) { [weak self] index in
            guard index == 0 else { return }
            self?.appState.library.forget(project.id)
            self?.appState.projectStore.delete(project)
        }
    }

    fileprivate func duplicate(_ project: Project) {
        appState.projectStore.duplicate(project)
    }

    static func closureItem(_ title: String, handler: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(ClosureMenuTarget.fire), keyEquivalent: "")
        let target = ClosureMenuTarget(handler: handler)
        item.target = target
        item.representedObject = target // retain
        return item
    }
}

// MARK: - Collection data source / delegate

extension ProjectBrowserViewController: NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        entries.count
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        guard indexPath.item < entries.count else {
            return collectionView.makeItem(withIdentifier: ProjectCardItem.identifier, for: indexPath)
        }
        switch entries[indexPath.item] {
        case .note(let note):
            return noteCardItem(for: note, at: indexPath)
        case .project(let project):
            return projectCardItem(for: project, at: indexPath)
        }
    }

    private func projectCardItem(for project: Project, at indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(
            withIdentifier: ProjectCardItem.identifier, for: indexPath
        )
        guard let card = item as? ProjectCardItem else { return item }
        let library = appState.library
        card.configure(
            with: project,
            isPinned: library.isPinned(project.id),
            isShared: library.isShared(project.id),
            uploadState: appState.shareJobCenter.job(for: project.id)?.state,
            searchSnippet: searchSnippets[project.id]
        )
        card.onOpen = { [weak self] in self?.open(project) }
        card.onShare = { [weak self] in
            guard let self else { return }
            self.appState.shareJobCenter.shareProject(
                projectID: project.id,
                projectName: project.name,
                durationSeconds: project.duration,
                annotationMarkers: ExportSheetController.annotationMarkers(for: project),
                transcript: ShareIntelligence.transcriptPayload(for: project)
            )
        }
        card.shareURLToCopy = library.sharedURLs[project.id]
        card.onRename = { [weak self] in self?.promptRename(project) }
        card.onDuplicate = { [weak self] in self?.duplicate(project) }
        card.onDelete = { [weak self] in self?.promptDelete(project) }
        card.organizeMenuItems = { [weak self] in
            guard let self else { return [] }
            var items: [NSMenuItem] = []
            let pinned = self.appState.library.isPinned(project.id)
            items.append(Self.closureItem(pinned ? "Unpin" : "Pin") { [weak self] in
                self?.appState.library.togglePin(project.id)
            })
            let folderMenu = NSMenu()
            for folder in self.appState.library.folders {
                let entry = Self.closureItem(folder.name) { [weak self] in
                    self?.animateCard(project.id, intoFolder: folder.id)
                    self?.appState.library.add(project.id, toFolder: folder.id)
                }
                if self.appState.library.folder(containing: project.id)?.id == folder.id {
                    entry.state = .on
                }
                folderMenu.addItem(entry)
            }
            if !self.appState.library.folders.isEmpty { folderMenu.addItem(.separator()) }
            folderMenu.addItem(Self.closureItem("New Folder...") { [weak self] in
                self?.promptNewFolderAndAdd(project)
            })
            let folderItem = NSMenuItem(title: "Add to Folder", action: nil, keyEquivalent: "")
            folderItem.submenu = folderMenu
            items.append(folderItem)
            if self.appState.library.folder(containing: project.id) != nil {
                items.append(Self.closureItem("Remove from Folder") { [weak self] in
                    self?.appState.library.removeFromFolder(project.id)
                })
            }
            return items
        }
        card.reminderMenuItems = { [weak self] in
            guard let self else { return [] }
            return ReminderCenter.reminderMenuItems(
                currentDate: project.reminderDate,
                makeItem: { Self.closureItem($0, handler: $1) },
                set: { [weak self] date in self?.setReminder(date, for: project) },
                pickCustom: { [weak self] in
                    guard let self else { return }
                    ReminderCenter.promptCustomDate(
                        in: self.view.window, current: project.reminderDate
                    ) { picked in
                        if let picked { self.setReminder(picked, for: project) }
                    }
                },
                clear: { [weak self] in
                    project.reminderDate = nil
                    self?.appState.projectStore.save(project)
                    ReminderCenter.shared.cancelReminder(for: project.id)
                }
            )
        }
        return card
    }

    private func setReminder(_ date: Date, for project: Project) {
        project.reminderDate = date
        appState.projectStore.save(project)
        ReminderCenter.shared.scheduleReminder(
            id: project.id, title: project.name, kind: .project, date: date
        ) { [weak self] granted in
            if !granted {
                NoteViewerWindowController.showNotificationsDeniedAlert(in: self?.view.window)
            }
        }
    }

    private func setReminder(_ date: Date, for note: Note) {
        note.reminderDate = date
        appState.noteStore.save(note)
        ReminderCenter.shared.scheduleReminder(
            id: note.id, title: note.title, kind: .note, date: date
        ) { [weak self] granted in
            if !granted {
                NoteViewerWindowController.showNotificationsDeniedAlert(in: self?.view.window)
            }
        }
    }

    private func noteCardItem(for note: Note, at indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(
            withIdentifier: NoteCardItem.identifier, for: indexPath
        )
        guard let card = item as? NoteCardItem else { return item }
        card.configure(with: note)
        card.onOpen = { [weak self] in
            guard let self else { return }
            NoteViewerWindowController.present(note: note, appState: self.appState)
        }
        card.onDelete = { [weak self] in self?.promptDelete(note) }
        card.reminderMenuItems = { [weak self] in
            guard let self else { return [] }
            return ReminderCenter.reminderMenuItems(
                currentDate: note.reminderDate,
                makeItem: { Self.closureItem($0, handler: $1) },
                set: { [weak self] date in self?.setReminder(date, for: note) },
                pickCustom: { [weak self] in
                    guard let self else { return }
                    ReminderCenter.promptCustomDate(
                        in: self.view.window, current: note.reminderDate
                    ) { picked in
                        if let picked { self.setReminder(picked, for: note) }
                    }
                },
                clear: { [weak self] in
                    note.reminderDate = nil
                    self?.appState.noteStore.save(note)
                    ReminderCenter.shared.cancelReminder(for: note.id)
                }
            )
        }
        return card
    }

    private func promptDelete(_ note: Note) {
        guard let window = view.window else { return }
        let alert = CCAlert(
            title: "Delete Note?",
            message: "Are you sure you want to delete \"\(note.title)\"? This cannot be undone."
        )
        alert.addButton("Delete", role: .destructive)
        alert.addButton("Cancel")
        alert.beginSheet(for: window) { [weak self] index in
            guard index == 0 else { return }
            self?.appState.noteStore.delete(note)
        }
    }

    private func promptNewFolderAndAdd(_ project: Project) {
        guard let window = view.window else { return }
        CCAlert.prompt(
            title: "New Folder",
            placeholder: "Folder name",
            confirmTitle: "Create",
            in: window
        ) { [weak self] name in
            guard let name else { return }
            guard let folder = self?.appState.library.createFolder(named: name) else { return }
            // Let the new row lay out before targeting the fly-in.
            DispatchQueue.main.async {
                self?.animateCard(project.id, intoFolder: folder.id)
                self?.appState.library.add(project.id, toFolder: folder.id)
            }
        }
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        layout collectionViewLayout: NSCollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> NSSize {
        // Fluid columns: fixed 220…320pt card range, flexible count, 20pt
        // gutters. Column count comes from the minimum width; the cards then
        // stretch to FILL the row exactly (capped at 320), so the grid never
        // leaves a huge ragged right margin.
        // The first layout pass can run at ~zero width (window still being
        // framed) — clamp everything positive or the flow layout throws
        // "negative sizes are not supported" and takes the app down.
        let gutter: CGFloat = 20
        let available = max(1, collectionView.bounds.width - 40)
        let columns = max(1, floor((available + gutter) / (220 + gutter)))
        let width = max(1, min(320, (available - (columns - 1) * gutter) / columns))
        return NSSize(width: width, height: width * 130 / 212 + 62)
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        // ⌘/⇧-click (or growing an existing multi-selection) SELECTS — for
        // batch delete via ⌫. A plain single click opens, as before.
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.command) || flags.contains(.shift)
            || collectionView.selectionIndexPaths.count > 1 {
            return
        }
        collectionView.deselectItems(at: indexPaths)
        guard let index = indexPaths.first?.item, index < entries.count else { return }
        switch entries[index] {
        case .project(let project):
            open(project)
        case .note(let note):
            NoteViewerWindowController.present(note: note, appState: appState)
        }
    }

    /// ⌫ with a selection — one confirm for the whole batch.
    private func deleteSelectedProjects() {
        let selected = collectionView.selectionIndexPaths
            .sorted()
            .compactMap { $0.item < entries.count ? entries[$0.item] : nil }
        var projects: [Project] = []
        var notes: [Note] = []
        for entry in selected {
            switch entry {
            case .project(let project): projects.append(project)
            case .note(let note): notes.append(note)
            }
        }
        let count = projects.count + notes.count
        let firstName = projects.first?.name ?? notes.first?.title ?? ""
        guard count > 0, let window = view.window else { return }
        let alert = CCAlert(
            title: count == 1 ? "Delete Capture?" : "Delete \(count) Captures?",
            message: count == 1
                ? "Are you sure you want to delete \"\(firstName)\"? This cannot be undone."
                : "Are you sure you want to delete these \(count) captures? This cannot be undone."
        )
        alert.addButton("Delete", role: .destructive)
        alert.addButton("Cancel")
        alert.beginSheet(for: window) { [weak self] index in
            guard index == 0, let self else { return }
            for project in projects {
                self.appState.library.forget(project.id)
                self.appState.projectStore.delete(project)
            }
            for note in notes {
                self.appState.noteStore.delete(note)
            }
        }
    }

    // Cards drag their project id — folder rows in the sidebar accept it.
    func collectionView(
        _ collectionView: NSCollectionView,
        pasteboardWriterForItemAt indexPath: IndexPath
    ) -> NSPasteboardWriting? {
        guard indexPath.item < entries.count,
              case .project(let project) = entries[indexPath.item] else { return nil }
        let item = NSPasteboardItem()
        item.setString(
            project.id.uuidString,
            forType: Self.projectIDPasteboardType
        )
        return item
    }
}

// MARK: - Window chrome behavior

/// Title-bar double-click, honoring the system "double-click a window's
/// title bar to…" preference — the fullSizeContentView chrome puts our views
/// where the title bar lives, so they forward the gesture here.
@MainActor
enum TitlebarDoubleClick {
    static func perform(on window: NSWindow?) {
        guard let window else { return }
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.performMiniaturize(nil)
        case "None": break
        default: window.performZoom(nil) // "Maximize" (the default) / "Fill"
        }
    }
}

/// Browser toolbar backdrop: empty areas drag the window, double-click zooms
/// — the standard Mac title-bar contract, restored for the transparent
/// title-bar window. Subviews (buttons, chips, search) still consume their
/// own events first.
@MainActor
final class HeaderChromeView: NSView {
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            TitlebarDoubleClick.perform(on: window)
        } else {
            window?.performDrag(with: event)
        }
    }
}

// MARK: - Search bar (row 2)

/// One search suggestion row: a recent query, the plain "search for …"
/// query, or a direct capture hit (with an OCR/note snippet when the match
/// came from indexed text).
enum SearchSuggestion {
    case recent(String)
    case query(String)
    /// `time` is the OUTPUT-time seek target for video matches ("you'll land
    /// at 2:41"); nil for notes, images, and title-only matches.
    case capture(id: UUID, kind: String, title: String, snippet: String?, time: TimeInterval?)
}


/// Flat dropdown under the search bar: recents / live top matches. Rows are
/// icon + title + dim OCR snippet; arrow-key selection highlights.
@MainActor
final class SearchSuggestionsPanel: NSView {
    var onPick: ((SearchSuggestion) -> Void)?

    private let stack = NSStackView()
    private var suggestions: [SearchSuggestion] = []
    private var rows: [SearchSuggestionRow] = []
    private var selectedIndex = -1
    private var hoverGlide: CCGlideHighlight?
    private var themeObservation: CCThemeObservation?

    var selectedSuggestion: SearchSuggestion? {
        suggestions.indices.contains(selectedIndex) ? suggestions[selectedIndex] : nil
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = CCTheme.radius(.lg)
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        themeObservation = CCThemeObservation { [weak self] in
            self?.layer?.backgroundColor = EditorThemeKit.panelElevated.cgColor
            self?.layer?.borderColor = EditorThemeKit.hairline.cgColor
        }
        layer?.shadowOpacity = 0.45
        layer?.shadowRadius = 18
        layer?.shadowOffset = CGSize(width: 0, height: -6)

        stack.orientation = .vertical
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        hoverGlide = CCGlideHighlight(host: stack, radius: .md)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ suggestions: [SearchSuggestion]) {
        self.suggestions = suggestions
        selectedIndex = -1
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        rows = suggestions.map { suggestion in
            let row = SearchSuggestionRow(suggestion: suggestion)
            row.onClick = { [weak self] in self?.onPick?(suggestion) }
            row.onHighlight = { [weak self] row, active in
                self?.hoverGlide?.update(row: row, active: active)
            }
            // Order matters: the row must be IN the hierarchy before a
            // cross-view constraint activates.
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            return row
        }
        isHidden = suggestions.isEmpty
    }

    func dismiss() {
        isHidden = true
        suggestions = []
        selectedIndex = -1
    }

    func moveSelection(_ delta: Int) {
        guard !suggestions.isEmpty else { return }
        if selectedIndex == -1 {
            selectedIndex = delta > 0 ? 0 : suggestions.count - 1
        } else {
            selectedIndex = (selectedIndex + delta + suggestions.count) % suggestions.count
        }
        for (index, row) in rows.enumerated() {
            row.isSelected = index == selectedIndex
        }
    }
}

/// One suggestion row — kind icon, title, dim snippet.
@MainActor
private final class SearchSuggestionRow: NSView {
    var onClick: (() -> Void)?
    var onHighlight: ((SearchSuggestionRow, Bool) -> Void)?
    var isSelected = false { didSet { refresh() } }
    private var isHovered = false { didSet { refresh() } }

    init(suggestion: SearchSuggestion) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = CCTheme.radius(.md)
        layer?.cornerCurve = .continuous

        let symbol: String
        let title: String
        var snippet: String?
        var timestamp: String?
        var titleColor = EditorThemeKit.textPrimary
        switch suggestion {
        case .recent(let query):
            symbol = "clock.arrow.circlepath"
            title = query
            titleColor = EditorThemeKit.textSecondary
        case .query(let query):
            symbol = "magnifyingglass"
            title = "Search for \u{201C}\(query)\u{201D}"
            titleColor = EditorThemeKit.textSecondary
        case .capture(_, let kind, let captureTitle, let captureSnippet, let time):
            switch kind {
            case "note": symbol = "note.text"
            case "image": symbol = "photo"
            default: symbol = "film"
            }
            title = captureTitle
            snippet = captureSnippet
            timestamp = time.map(CaptureSearchSeek.timestampLabel)
        }

        let icon = NSImageView(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        icon.contentTintColor = EditorThemeKit.textTertiary
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)

        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 12, weight: .medium)
        titleField.textColor = titleColor
        titleField.lineBreakMode = .byTruncatingTail
        titleField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleField)

        var constraints = [
            heightAnchor.constraint(equalToConstant: 30),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            titleField.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]

        // "You'll land at 2:41" — timestamp chip right after the title.
        var snippetLeadingAnchor = titleField.trailingAnchor
        if let timestamp {
            let timeField = NSTextField(labelWithString: timestamp)
            timeField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            timeField.textColor = NSColor.controlAccentColor.withAlphaComponent(0.9)
            timeField.translatesAutoresizingMaskIntoConstraints = false
            timeField.setContentCompressionResistancePriority(.required, for: .horizontal)
            addSubview(timeField)
            constraints += [
                timeField.leadingAnchor.constraint(equalTo: titleField.trailingAnchor, constant: 8),
                timeField.centerYAnchor.constraint(equalTo: centerYAnchor),
                timeField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            ]
            snippetLeadingAnchor = timeField.trailingAnchor
        }

        if let snippet {
            let snippetField = NSTextField(labelWithString: snippet)
            snippetField.font = .systemFont(ofSize: 11)
            snippetField.textColor = EditorThemeKit.textTertiary
            snippetField.lineBreakMode = .byTruncatingTail
            snippetField.translatesAutoresizingMaskIntoConstraints = false
            snippetField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addSubview(snippetField)
            constraints += [
                snippetField.leadingAnchor.constraint(equalTo: snippetLeadingAnchor, constant: 8),
                snippetField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
                snippetField.centerYAnchor.constraint(equalTo: centerYAnchor),
            ]
            titleField.setContentCompressionResistancePriority(.required, for: .horizontal)
        } else {
            constraints.append(
                titleField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10))
        }
        NSLayoutConstraint.activate(constraints)

        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func refresh() {
        onHighlight?(self, isHovered && !isSelected)
        let fill: NSColor = if isSelected {
            NSColor.controlAccentColor.withAlphaComponent(0.28)
        } else if isHovered && onHighlight == nil {
            EditorThemeKit.hoverFill
        } else {
            .clear
        }
        layer?.backgroundColor = fill.cgColor
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

// MARK: - Sidebar icons (skeuomorphic, drawn in code)

/// iOS 6-era skeuomorphic sidebar icons, drawn in code — textured rounded
/// "chips" (grain noise, vertical gradient, inner top highlight, dark outer
/// stroke) with the glyph ENGRAVED into the surface: a dark cutout with a
/// light edge below, like the leather-and-paper icons of that era. Cached;
/// no image assets involved.
@MainActor
enum SidebarIconRenderer {
    private static var cache: [String: NSImage] = [:]

    /// Deterministic grain so cached icons are stable frame to frame.
    private static func drawGrain(in rect: NSRect, seed: UInt64, alpha: CGFloat) {
        var state = seed
        func next() -> CGFloat {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((state >> 33) % 1000) / 1000
        }
        for _ in 0..<90 {
            let x = rect.minX + next() * rect.width
            let y = rect.minY + next() * rect.height
            let bright = next() > 0.5
            (bright ? NSColor.white : NSColor.black)
                .withAlphaComponent(alpha * (0.4 + next() * 0.6)).setFill()
            NSRect(x: x, y: y, width: 0.5, height: 0.5).fill()
        }
    }

    /// Textured chip with an engraved SF Symbol glyph.
    // 16pt exactly matches the row's icon slot — any mismatch rescales the
    // bitmap and blurs every hairline.
    static func chip(symbol: String, top: NSColor, bottom: NSColor, size: CGFloat = 16) -> NSImage {
        let key = "chip:\(symbol):\(top.description):\(size)"
        if let cached = cache[key] { return cached }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let plateRect = rect.insetBy(dx: 0.5, dy: 0.5)
            let plate = NSBezierPath(roundedRect: plateRect, xRadius: size * 0.24, yRadius: size * 0.24)

            // Base: vertical gradient + grain texture.
            ctx.saveGState()
            plate.addClip()
            NSGradient(starting: top, ending: bottom)?.draw(in: rect, angle: -90)
            drawGrain(in: rect, seed: UInt64(abs(symbol.hashValue)) | 1, alpha: 0.10)
            // Inner top highlight — stitched-leather edge light.
            NSColor.white.withAlphaComponent(0.28).setFill()
            NSRect(x: plateRect.minX, y: plateRect.maxY - 1, width: plateRect.width, height: 1).fill()
            ctx.restoreGState()

            // Outer dark stroke grounds the chip.
            bottom.blended(withFraction: 0.55, of: .black)?.setStroke()
            plate.lineWidth = 1
            plate.stroke()

            // Engraved glyph: light edge offset below, dark glyph on top.
            // Rasterize the glyph at 4x — cgImage(forProposedRect:) with no
            // hints returns a 1x bitmap, which reads soft on Retina once
            // masked. The CTM hint makes the vector symbol render dense.
            guard let symbolImage = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: size * 0.56, weight: .bold)),
                  let cg = symbolImage.cgImage(
                    forProposedRect: nil, context: nil,
                    hints: [.ctm: NSAffineTransform(transform: AffineTransform(scale: 4))]
                  )
            else { return true }
            let aspect = CGFloat(cg.width) / CGFloat(cg.height)
            var box = rect.insetBy(dx: size * 0.24, dy: size * 0.24)
            if aspect > 1 {
                let height = box.width / aspect
                box = NSRect(x: box.minX, y: box.midY - height / 2, width: box.width, height: height)
            } else {
                let width = box.height * aspect
                box = NSRect(x: box.midX - width / 2, y: box.minY, width: width, height: box.height)
            }
            ctx.saveGState()
            ctx.clip(to: box.offsetBy(dx: 0, dy: -0.75), mask: cg)
            NSColor.white.withAlphaComponent(0.30).setFill()
            rect.fill()
            ctx.restoreGState()
            ctx.saveGState()
            ctx.clip(to: box, mask: cg)
            NSColor.black.withAlphaComponent(0.52).setFill()
            rect.fill()
            ctx.restoreGState()
            return true
        }
        cache[key] = image
        return image
    }

    /// Textured manila-meets-blue folder with a tab — dimensional, outlined,
    /// grained like the era's Finder folders.
    static func folder(size: CGFloat = 16) -> NSImage {
        let key = "folder:\(size)"
        if let cached = cache[key] { return cached }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let w = rect.width, h = rect.height
            let outline = NSColor(calibratedRed: 0.18, green: 0.30, blue: 0.47, alpha: 1)

            // Tab.
            let tab = NSBezierPath(
                roundedRect: NSRect(x: w * 0.05, y: h * 0.66, width: w * 0.42, height: h * 0.22),
                xRadius: 1.5, yRadius: 1.5
            )
            NSGradient(
                starting: NSColor(calibratedRed: 0.55, green: 0.70, blue: 0.88, alpha: 1),
                ending: NSColor(calibratedRed: 0.38, green: 0.55, blue: 0.78, alpha: 1)
            )?.draw(in: tab, angle: -90)
            outline.setStroke()
            tab.lineWidth = 0.75
            tab.stroke()

            // Body with gradient, grain, and a bottom shadow line for depth.
            let bodyRect = NSRect(x: w * 0.03, y: h * 0.10, width: w * 0.94, height: h * 0.62)
            let body = NSBezierPath(roundedRect: bodyRect, xRadius: 2, yRadius: 2)
            ctx.saveGState()
            body.addClip()
            NSGradient(
                starting: NSColor(calibratedRed: 0.66, green: 0.79, blue: 0.93, alpha: 1),
                ending: NSColor(calibratedRed: 0.40, green: 0.58, blue: 0.81, alpha: 1)
            )?.draw(in: bodyRect, angle: -90)
            drawGrain(in: bodyRect, seed: 0xF01DE5, alpha: 0.09)
            // Inner top highlight.
            NSColor.white.withAlphaComponent(0.35).setFill()
            NSRect(x: bodyRect.minX, y: bodyRect.maxY - 1, width: bodyRect.width, height: 1).fill()
            // Inner bottom shade.
            NSColor.black.withAlphaComponent(0.18).setFill()
            NSRect(x: bodyRect.minX, y: bodyRect.minY, width: bodyRect.width, height: 1.5).fill()
            ctx.restoreGState()
            outline.setStroke()
            body.lineWidth = 0.75
            body.stroke()
            return true
        }
        cache[key] = image
        return image
    }
}

// MARK: - Sidebar view

/// Liquid-glass sidebar: NSGlassEffectView on macOS 26+, NSVisualEffectView
/// (.sidebar material) on older systems — same rows either way.
@MainActor
final class BrowserSidebarView: NSView {
    struct Row {
        let id: ProjectBrowserViewController.SidebarFilter
        let title: String
        let icon: NSImage
        var isSelected: Bool
        var isFolder: Bool = false
    }

    var onSelect: ((ProjectBrowserViewController.SidebarFilter) -> Void)?
    var onNewFolder: (() -> Void)?
    var onDropProject: ((UUID, ProjectBrowserViewController.SidebarFilter) -> Void)?
    var folderMenuProvider: ((ProjectBrowserViewController.SidebarFilter) -> NSMenu?)?
    /// Menu shown when the bottom account row is clicked (sign out, etc.).
    var accountMenuProvider: (() -> NSMenu?)?

    let accountRow = SidebarAccountControl()

    private let stack = NSStackView()
    private var rowControls: [ProjectBrowserViewController.SidebarFilter: SidebarRowControl] = [:]
    private var hoverGlide: CCGlideHighlight?
    private let foldersHeader = NSTextField(labelWithString: "FOLDERS")
    private let newFolderButton = SidebarRowControl(
        title: "New Folder...",
        icon: NSImage(systemSymbolName: "plus", accessibilityDescription: nil) ?? NSImage(),
        isAction: true)
    private let trailingHairline = NSView()
    private var themeObservation: CCThemeObservation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        // Glass backdrop — real glass on macOS 26, vibrant sidebar before it.
        let backdrop: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            backdrop = glass
        } else {
            let vibrancy = NSVisualEffectView()
            vibrancy.material = .sidebar
            vibrancy.blendingMode = .behindWindow
            vibrancy.state = .active
            backdrop = vibrancy
        }
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)

        let hairline = trailingHairline
        hairline.translatesAutoresizingMaskIntoConstraints = false
        hairline.wantsLayer = true
        addSubview(hairline)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        hoverGlide = CCGlideHighlight(host: stack, radius: .md)

        foldersHeader.font = .systemFont(ofSize: 10, weight: .semibold)
        // Glass/vibrancy backdrop retunes itself with NSAppearance; only the
        // chrome layered on top needs explicit retheming.
        themeObservation = CCThemeObservation { [weak self] in
            self?.trailingHairline.layer?.backgroundColor = EditorThemeKit.hairline.cgColor
            self?.foldersHeader.textColor = EditorThemeKit.textTertiary
        }

        newFolderButton.onClick = { [weak self] in self?.onNewFolder?() }
        newFolderButton.onHighlight = { [weak self] row, active in
            self?.hoverGlide?.update(row: row, active: active)
        }

        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),

            hairline.topAnchor.constraint(equalTo: topAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: bottomAnchor),
            hairline.widthAnchor.constraint(equalToConstant: 1),

            // 52pt top inset clears the traffic lights in the
            // fullSizeContentView window.
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 52),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])

        // Account row pinned to the bottom — avatar + name with a dropdown.
        accountRow.translatesAutoresizingMaskIntoConstraints = false
        accountRow.onClick = { [weak self] in
            guard let self, let menu = self.accountMenuProvider?() else { return }
            CaptureCatMenuPresenter.show(menu, from: self.accountRow, edge: .above)
        }
        addSubview(accountRow)
        NSLayoutConstraint.activate([
            accountRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            accountRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            accountRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Empty sidebar area behaves like the title bar it sits under:
    /// double-click zooms (per system pref), drag moves the window.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            TitlebarDoubleClick.perform(on: window)
        } else {
            window?.performDrag(with: event)
        }
    }

    /// The live row view for a filter — used to target the file-away animation.
    func rowView(for filter: ProjectBrowserViewController.SidebarFilter) -> NSView? {
        rowControls[filter]
    }

    func pulseRow(for filter: ProjectBrowserViewController.SidebarFilter) {
        rowControls[filter]?.pulse()
    }

    func setRows(_ rows: [Row]) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        rowControls.removeAll()
        var addedFolderHeader = false
        for row in rows {
            if row.isFolder, !addedFolderHeader {
                addedFolderHeader = true
                let spacer = NSView()
                spacer.translatesAutoresizingMaskIntoConstraints = false
                spacer.heightAnchor.constraint(equalToConstant: 14).isActive = true
                stack.addArrangedSubview(spacer)
                stack.addArrangedSubview(foldersHeader)
                stack.setCustomSpacing(6, after: foldersHeader)
            }
            let control = SidebarRowControl(title: row.title, icon: row.icon)
            control.isSelected = row.isSelected
            control.onHighlight = { [weak self] row, active in
                self?.hoverGlide?.update(row: row, active: active)
            }
            control.onClick = { [weak self] in self?.onSelect?(row.id) }
            if row.isFolder {
                control.acceptsProjectDrops = true
                control.onDropProjectID = { [weak self] id in
                    self?.onDropProject?(id, row.id)
                }
                control.menuProvider = { [weak self] in
                    self?.folderMenuProvider?(row.id)
                }
            }
            stack.addArrangedSubview(control)
            control.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            rowControls[row.id] = control
        }
        if !addedFolderHeader {
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.heightAnchor.constraint(equalToConstant: 14).isActive = true
            stack.addArrangedSubview(spacer)
            stack.addArrangedSubview(foldersHeader)
            stack.setCustomSpacing(6, after: foldersHeader)
        }
        stack.addArrangedSubview(newFolderButton)
        newFolderButton.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
}

/// One sidebar row — flat pill with hover/selection washes matching the
/// editor chrome; folder rows highlight while a project card hovers over
/// them and accept the drop.
@MainActor
private final class SidebarRowControl: NSView {
    var onClick: (() -> Void)?
    var onHighlight: ((SidebarRowControl, Bool) -> Void)?
    var onDropProjectID: ((UUID) -> Void)?
    var menuProvider: (() -> NSMenu?)?
    var acceptsProjectDrops = false {
        didSet {
            if acceptsProjectDrops {
                registerForDraggedTypes([ProjectBrowserViewController.projectIDPasteboardType])
            }
        }
    }
    var isSelected = false { didSet { refresh() } }

    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var isHovered = false { didSet { refresh() } }
    private var isDropTarget = false { didSet { refresh() } }
    private let isAction: Bool
    private var themeObservation: CCThemeObservation?

    init(title: String, icon: NSImage, isAction: Bool = false) {
        self.isAction = isAction
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = CCTheme.radius(.md)
        layer?.cornerCurve = .continuous

        iconView.image = icon
        if isAction {
            iconView.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        }
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        label.stringValue = title
        label.font = .systemFont(ofSize: 12, weight: isAction ? .regular : .medium)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        themeObservation = CCThemeObservation { [weak self] in self?.refresh() }

        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func refresh() {
        onHighlight?(self, isHovered && !isSelected && !isDropTarget)
        // Washes are ink-relative so they read on the light sidebar too.
        let ink: NSColor = CCTheme.isDark ? .white : .black
        let fill: NSColor = if isDropTarget {
            NSColor.controlAccentColor.withAlphaComponent(0.35)
        } else if isSelected {
            ink.withAlphaComponent(0.14)
        } else if isHovered && onHighlight == nil {
            ink.withAlphaComponent(0.07)
        } else {
            .clear
        }
        layer?.backgroundColor = fill.cgColor
        let tint = isAction ? EditorThemeKit.textSecondary
            : (isSelected ? EditorThemeKit.textPrimary : EditorThemeKit.textSecondary)
        iconView.contentTintColor = tint
        label.textColor = isAction ? EditorThemeKit.textSecondary : EditorThemeKit.textPrimary
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuProvider?() else {
            super.rightMouseDown(with: event)
            return
        }
        // House menu surface — never the stock NSMenu chrome.
        CaptureCatMenuPresenter.showContextMenu(menu, with: event, for: self)
    }

    /// Landing reaction: accent flash + a springy scale bounce, like a dock
    /// folder catching a dropped file.
    func pulse() {
        guard let layer else { return }
        // Scale about the row's center.
        let frame = layer.frame
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: frame.midX, y: frame.midY)
        layer.frame = frame

        let bounce = CAKeyframeAnimation(keyPath: "transform.scale")
        bounce.values = [1.0, 1.16, 0.96, 1.03, 1.0]
        bounce.keyTimes = [0, 0.3, 0.6, 0.8, 1]
        bounce.duration = 0.45
        bounce.timingFunctions = Array(
            repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 4)
        layer.add(bounce, forKey: "landing-bounce")

        let wash = NSColor.controlAccentColor.withAlphaComponent(0.35)
        layer.backgroundColor = wash.cgColor
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.45
            context.allowsImplicitAnimation = true
            refresh()
        }
    }

    // MARK: Drop target

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptsProjectDrops, projectID(from: sender) != nil else { return [] }
        isDropTarget = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDropTarget = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDropTarget = false
        guard let id = projectID(from: sender) else { return false }
        onDropProjectID?(id)
        return true
    }

    private func projectID(from sender: NSDraggingInfo) -> UUID? {
        guard let string = sender.draggingPasteboard.string(
            forType: ProjectBrowserViewController.projectIDPasteboardType
        ) else { return nil }
        return UUID(uuidString: string)
    }
}

// MARK: - Account row

/// Bottom-of-sidebar identity: circular avatar + display name + disclosure
/// chevron. Clicking pops the account menu (email, Sign Out). Signed-out it
/// reads "Sign In".
@MainActor
final class SidebarAccountControl: NSView {
    var onClick: (() -> Void)?

    private let avatarView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private var isHovered = false { didSet { refresh() } }
    private var avatarTask: Task<Void, Never>?
    private var loadedAvatarURL: URL?
    private var themeObservation: CCThemeObservation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = CCTheme.radius(.md)
        layer?.cornerCurve = .continuous

        avatarView.translatesAutoresizingMaskIntoConstraints = false
        avatarView.wantsLayer = true
        avatarView.imageScaling = .scaleProportionallyUpOrDown
        avatarView.layer?.cornerRadius = 12
        avatarView.layer?.masksToBounds = true
        addSubview(avatarView)

        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        chevron.image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)
        chevron.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        chevron.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevron)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 36),
            avatarView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            avatarView.centerYAnchor.constraint(equalTo: centerYAnchor),
            avatarView.widthAnchor.constraint(equalToConstant: 24),
            avatarView.heightAnchor.constraint(equalToConstant: 24),
            nameLabel.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 8),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 6),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }

        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(name: String?, imageURL: URL?, signedIn: Bool) {
        nameLabel.stringValue = signedIn ? (name ?? "Account") : "Sign In"
        chevron.isHidden = !signedIn

        guard signedIn else {
            avatarTask?.cancel()
            loadedAvatarURL = nil
            avatarView.image = Self.fallbackAvatar(for: nil)
            return
        }
        if let imageURL {
            guard imageURL != loadedAvatarURL else { return }
            loadedAvatarURL = imageURL
            avatarView.image = Self.fallbackAvatar(for: name)
            avatarTask?.cancel()
            avatarTask = Task { [weak self] in
                guard let (data, _) = try? await URLSession.shared.data(from: imageURL),
                      let image = NSImage(data: data), !Task.isCancelled else { return }
                self?.avatarView.image = image
            }
        } else {
            loadedAvatarURL = nil
            avatarView.image = Self.fallbackAvatar(for: name)
        }
    }

    /// Initials-in-a-circle fallback (or a person glyph with no name).
    private static func fallbackAvatar(for name: String?) -> NSImage {
        NSImage(size: NSSize(width: 24, height: 24), flipped: false) { rect in
            NSColor(calibratedRed: 0.35, green: 0.45, blue: 0.62, alpha: 1).setFill()
            NSBezierPath(ovalIn: rect).fill()
            let initials = name?
                .split(separator: " ").prefix(2)
                .compactMap { $0.first.map(String.init) }
                .joined().uppercased()
            let text = (initials?.isEmpty == false ? initials! : "?")
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            let size = text.size(withAttributes: attrs)
            text.draw(
                at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                withAttributes: attrs
            )
            return true
        }
    }

    private func applyTheme() {
        let ink: NSColor = CCTheme.isDark ? .white : .black
        avatarView.layer?.backgroundColor = ink.withAlphaComponent(0.10).cgColor
        nameLabel.textColor = EditorThemeKit.textPrimary
        chevron.contentTintColor = EditorThemeKit.textTertiary
        refresh()
    }

    private func refresh() {
        let ink: NSColor = CCTheme.isDark ? .white : .black
        layer?.backgroundColor = (isHovered
            ? ink.withAlphaComponent(0.07) : .clear).cgColor
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

// MARK: - Card item

@MainActor
/// Grid that turns ⌫ / forward-delete into a batch-delete of the selection.
private final class BrowserGridView: NSCollectionView {
    var onDeleteKey: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 51 || event.keyCode == 117), !selectionIndexPaths.isEmpty {
            onDeleteKey?()
            return
        }
        super.keyDown(with: event)
    }
}

private final class ProjectCardItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ProjectCardItem")

    var onOpen: (() -> Void)?
    var onShare: (() -> Void)?
    /// Set when the project already has a share link — enables "Copy Share Link".
    var shareURLToCopy: String?
    var onRename: (() -> Void)?
    var onDuplicate: (() -> Void)?
    var onDelete: (() -> Void)?
    /// Pin / Add to Folder / Remove from Folder rows, built by the browser
    /// (it owns the library).
    var organizeMenuItems: (() -> [NSMenuItem])?
    /// "Remind Me" submenu rows, built by the browser (it owns the stores).
    var reminderMenuItems: (() -> [NSMenuItem])?

    private let container = NSView()
    private let thumbView = NSImageView()
    private let placeholderIcon = NSImageView()
    private let pinBadge = NSImageView()
    private let reminderBadge = ReminderBadgeLabel()
    private let nameField = NSTextField(labelWithString: "")
    private let metaField = NSTextField(labelWithString: "")
    private let uploadTrack = NSView()
    private let uploadFill = NSView()
    private var uploadFillWidth: NSLayoutConstraint!
    private var trackingArea: NSTrackingArea?
    /// Cells recycle — chassis colors retheme in place; configure-time
    /// colors come back via the controller's reloadData on theme change.
    private var themeObservation: CCThemeObservation?

    /// Multi-selection ring (⌘/⇧-click) — same accent language as the editor.
    override var isSelected: Bool {
        didSet {
            container.layer?.borderWidth = isSelected ? 2 : 1
            container.layer?.borderColor = isSelected
                ? NSColor.controlAccentColor.cgColor
                : NSColor.clear.cgColor
        }
    }

    override func loadView() {
        view = CardBackdropView { [weak self] in self?.buildContextMenu() }
        view.wantsLayer = true
        buildLayout()
    }

    private func buildLayout() {
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.cornerRadius = CCTheme.radius(.lg)
        container.layer?.cornerCurve = .continuous
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.clear.cgColor
        view.addSubview(container)

        thumbView.translatesAutoresizingMaskIntoConstraints = false
        thumbView.wantsLayer = true
        thumbView.imageScaling = .scaleProportionallyUpOrDown
        thumbView.layer?.cornerRadius = CCTheme.radius(.md)
        thumbView.layer?.cornerCurve = .continuous
        thumbView.layer?.masksToBounds = true
        thumbView.layer?.borderWidth = 1
        container.addSubview(thumbView)

        placeholderIcon.translatesAutoresizingMaskIntoConstraints = false
        placeholderIcon.image = NSImage(systemSymbolName: "film", accessibilityDescription: nil)
        placeholderIcon.symbolConfiguration = .init(pointSize: 28, weight: .regular)
        container.addSubview(placeholderIcon)

        pinBadge.translatesAutoresizingMaskIntoConstraints = false
        pinBadge.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")
        pinBadge.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        pinBadge.contentTintColor = .white
        pinBadge.wantsLayer = true
        pinBadge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        pinBadge.layer?.cornerRadius = 9
        pinBadge.isHidden = true
        container.addSubview(pinBadge)

        reminderBadge.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(reminderBadge)

        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.font = .systemFont(ofSize: 12, weight: .medium)
        nameField.lineBreakMode = .byTruncatingTail
        container.addSubview(nameField)

        metaField.translatesAutoresizingMaskIntoConstraints = false
        metaField.font = .systemFont(ofSize: 10)
        metaField.textColor = EditorThemeKit.textSecondary
        container.addSubview(metaField)

        // Background-upload progress: a slim bar along the thumbnail's
        // bottom edge, hidden unless a share job is active for this project.
        uploadTrack.translatesAutoresizingMaskIntoConstraints = false
        uploadTrack.wantsLayer = true
        uploadTrack.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        uploadTrack.layer?.cornerRadius = 2
        uploadTrack.isHidden = true
        container.addSubview(uploadTrack)
        uploadFill.translatesAutoresizingMaskIntoConstraints = false
        uploadFill.wantsLayer = true
        uploadFill.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        uploadFill.layer?.cornerRadius = 2
        uploadTrack.addSubview(uploadFill)

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: view.topAnchor),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            thumbView.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            thumbView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            thumbView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            placeholderIcon.centerXAnchor.constraint(equalTo: thumbView.centerXAnchor),
            placeholderIcon.centerYAnchor.constraint(equalTo: thumbView.centerYAnchor),

            pinBadge.topAnchor.constraint(equalTo: thumbView.topAnchor, constant: 6),
            pinBadge.trailingAnchor.constraint(equalTo: thumbView.trailingAnchor, constant: -6),
            pinBadge.widthAnchor.constraint(equalToConstant: 18),
            pinBadge.heightAnchor.constraint(equalToConstant: 18),

            reminderBadge.topAnchor.constraint(equalTo: thumbView.topAnchor, constant: 6),
            reminderBadge.leadingAnchor.constraint(equalTo: thumbView.leadingAnchor, constant: 6),

            nameField.topAnchor.constraint(equalTo: thumbView.bottomAnchor, constant: 8),
            nameField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            nameField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),

            metaField.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 3),
            metaField.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            metaField.trailingAnchor.constraint(equalTo: nameField.trailingAnchor),

            uploadTrack.leadingAnchor.constraint(equalTo: thumbView.leadingAnchor, constant: 6),
            uploadTrack.trailingAnchor.constraint(equalTo: thumbView.trailingAnchor, constant: -6),
            uploadTrack.bottomAnchor.constraint(equalTo: thumbView.bottomAnchor, constant: -6),
            uploadTrack.heightAnchor.constraint(equalToConstant: 4),
            uploadFill.leadingAnchor.constraint(equalTo: uploadTrack.leadingAnchor),
            uploadFill.topAnchor.constraint(equalTo: uploadTrack.topAnchor),
            uploadFill.bottomAnchor.constraint(equalTo: uploadTrack.bottomAnchor),
        ])
        uploadFillWidth = uploadFill.widthAnchor.constraint(
            equalTo: uploadTrack.widthAnchor, multiplier: 0.001)
        uploadFillWidth.isActive = true
        // Thumbnail keeps the card's remaining height above the two labels.
        let thumbBottom = thumbView.bottomAnchor.constraint(
            equalTo: container.bottomAnchor, constant: -54)
        thumbBottom.priority = .defaultHigh
        thumbBottom.isActive = true

        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    private func applyTheme() {
        // Thumb chrome is ink-relative; badges keep their dark scrim (they
        // sit over the thumbnail's own pixels, not the window theme).
        let ink: NSColor = CCTheme.isDark ? .white : .black
        thumbView.layer?.borderColor = ink.withAlphaComponent(0.10).cgColor
        thumbView.layer?.backgroundColor = ink.withAlphaComponent(0.06).cgColor
        placeholderIcon.contentTintColor = EditorThemeKit.textSecondary
        nameField.textColor = EditorThemeKit.textPrimary
    }

    func configure(
        with project: Project, isPinned: Bool, isShared: Bool,
        uploadState: ShareService.ShareState? = nil,
        searchSnippet: String? = nil
    ) {
        nameField.stringValue = project.name
        pinBadge.isHidden = !isPinned
        reminderBadge.configure(text: ReminderCenter.badgeText(for: project.reminderDate))

        let total = Int(project.duration)
        let duration = String(format: "%d:%02d", total / 60, total % 60)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let date = formatter.localizedString(for: project.createdAt, relativeTo: Date())
        metaField.stringValue = isShared
            ? "\(duration) · \(date) · shared"
            : "\(duration) · \(date)"

        // Background share job state overrides the meta line while active.
        switch uploadState {
        case .exporting(let progress):
            uploadTrack.isHidden = false
            setUploadFraction(progress)
            metaField.stringValue = "Exporting \(Int((progress * 100).rounded()))%…"
            metaField.textColor = EditorThemeKit.textPrimary
        case .uploading(let progress):
            uploadTrack.isHidden = false
            setUploadFraction(progress)
            metaField.stringValue = "Uploading \(Int((progress * 100).rounded()))%…"
            metaField.textColor = EditorThemeKit.textPrimary
        case .completing:
            uploadTrack.isHidden = false
            setUploadFraction(1)
            metaField.stringValue = "Creating share link…"
            metaField.textColor = EditorThemeKit.textPrimary
        case .failed(let message):
            uploadTrack.isHidden = true
            metaField.stringValue = "Upload failed — \(message)"
            metaField.textColor = .systemRed
        case .done, .idle, nil:
            uploadTrack.isHidden = true
            metaField.textColor = EditorThemeKit.textSecondary
        }

        // OCR-only search hit: a quiet one-line "match: …snippet…" replaces
        // the meta line so the user sees WHY the card matched. Only while a
        // search is active and no upload state owns the line.
        let uploadOwnsMetaLine: Bool = switch uploadState {
        case .exporting, .uploading, .completing, .failed: true
        case .done, .idle, nil: false
        }
        if let searchSnippet, !uploadOwnsMetaLine {
            metaField.stringValue = "match: \(searchSnippet)"
            metaField.textColor = EditorThemeKit.textTertiary
        }

        if let thumbURL = project.thumbnailURL, let image = NSImage(contentsOf: thumbURL) {
            thumbView.image = image
            placeholderIcon.isHidden = true
        } else {
            thumbView.image = nil
            placeholderIcon.isHidden = false
        }
    }

    private func setUploadFraction(_ fraction: Double) {
        // A multiplier constraint can't be mutated — swap it.
        uploadFillWidth.isActive = false
        uploadFillWidth = uploadFill.widthAnchor.constraint(
            equalTo: uploadTrack.widthAnchor,
            multiplier: max(0.001, min(1, fraction)))
        uploadFillWidth.isActive = true
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(menuItem("Open") { [weak self] in self?.onOpen?() })
        menu.addItem(.separator())
        menu.addItem(menuItem("Share…") { [weak self] in self?.onShare?() })
        if let url = shareURLToCopy {
            menu.addItem(menuItem("Copy Share Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            })
        }
        menu.addItem(.separator())
        for item in organizeMenuItems?() ?? [] {
            menu.addItem(item)
        }
        for item in reminderMenuItems?() ?? [] {
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(menuItem("Rename...") { [weak self] in self?.onRename?() })
        menu.addItem(menuItem("Duplicate") { [weak self] in self?.onDuplicate?() })
        menu.addItem(.separator())
        let delete = menuItem("Delete...") { [weak self] in self?.onDelete?() }
        delete.attributedTitle = NSAttributedString(
            string: "Delete...",
            attributes: [.foregroundColor: NSColor.systemRed]
        )
        menu.addItem(delete)
        return menu
    }

    private func menuItem(_ title: String, handler: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(ClosureMenuTarget.fire), keyEquivalent: "")
        let target = ClosureMenuTarget(handler: handler)
        item.target = target
        item.representedObject = target // retain
        return item
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if let trackingArea { view.removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: view.bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self, userInfo: nil
        )
        view.addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        applyCardHover(container, hovered: true)
    }

    override func mouseExited(with event: NSEvent) {
        applyCardHover(container, hovered: false)
    }
}

// MARK: - Note card item

/// Grid card for a text capture — same flat card chassis as the project
/// card, but the "thumbnail" area is the note's text preview on a subtly
/// warm wash with a note glyph, so notes read differently at a glance.
private final class NoteCardItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("NoteCardItem")

    var onOpen: (() -> Void)?
    var onDelete: (() -> Void)?
    var reminderMenuItems: (() -> [NSMenuItem])?

    private let container = NSView()
    private let previewBox = NSView()
    private let previewLabel = NSTextField(wrappingLabelWithString: "")
    private let noteGlyph = NSImageView()
    private let reminderBadge = ReminderBadgeLabel()
    private let nameField = NSTextField(labelWithString: "")
    private let metaField = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?
    /// Cells recycle — chassis colors retheme in place.
    private var themeObservation: CCThemeObservation?

    override var isSelected: Bool {
        didSet {
            container.layer?.borderWidth = isSelected ? 2 : 1
            container.layer?.borderColor = isSelected
                ? NSColor.controlAccentColor.cgColor
                : NSColor.clear.cgColor
        }
    }

    override func loadView() {
        view = CardBackdropView { [weak self] in self?.buildContextMenu() }
        view.wantsLayer = true
        buildLayout()
    }

    private func buildLayout() {
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.cornerRadius = CCTheme.radius(.lg)
        container.layer?.cornerCurve = .continuous
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.clear.cgColor
        view.addSubview(container)

        previewBox.translatesAutoresizingMaskIntoConstraints = false
        previewBox.wantsLayer = true
        previewBox.layer?.cornerRadius = CCTheme.radius(.md)
        previewBox.layer?.cornerCurve = .continuous
        previewBox.layer?.masksToBounds = true
        previewBox.layer?.borderWidth = 1
        container.addSubview(previewBox)

        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        previewLabel.font = .systemFont(ofSize: 10)
        previewLabel.maximumNumberOfLines = 6
        previewLabel.cell?.truncatesLastVisibleLine = true
        previewBox.addSubview(previewLabel)

        noteGlyph.translatesAutoresizingMaskIntoConstraints = false
        noteGlyph.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "Note")
        noteGlyph.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        previewBox.addSubview(noteGlyph)

        reminderBadge.translatesAutoresizingMaskIntoConstraints = false
        previewBox.addSubview(reminderBadge)

        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.font = .systemFont(ofSize: 12, weight: .medium)
        nameField.lineBreakMode = .byTruncatingTail
        container.addSubview(nameField)

        metaField.translatesAutoresizingMaskIntoConstraints = false
        metaField.font = .systemFont(ofSize: 10)
        metaField.lineBreakMode = .byTruncatingTail
        container.addSubview(metaField)

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: view.topAnchor),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            previewBox.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            previewBox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            previewBox.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            previewLabel.topAnchor.constraint(equalTo: previewBox.topAnchor, constant: 8),
            previewLabel.leadingAnchor.constraint(equalTo: previewBox.leadingAnchor, constant: 10),
            previewLabel.trailingAnchor.constraint(equalTo: previewBox.trailingAnchor, constant: -10),
            previewLabel.bottomAnchor.constraint(lessThanOrEqualTo: previewBox.bottomAnchor, constant: -8),

            noteGlyph.bottomAnchor.constraint(equalTo: previewBox.bottomAnchor, constant: -6),
            noteGlyph.trailingAnchor.constraint(equalTo: previewBox.trailingAnchor, constant: -8),

            reminderBadge.topAnchor.constraint(equalTo: previewBox.topAnchor, constant: 6),
            reminderBadge.leadingAnchor.constraint(equalTo: previewBox.leadingAnchor, constant: 6),

            nameField.topAnchor.constraint(equalTo: previewBox.bottomAnchor, constant: 8),
            nameField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            nameField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),

            metaField.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 3),
            metaField.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            metaField.trailingAnchor.constraint(equalTo: nameField.trailingAnchor),
        ])
        let previewBottom = previewBox.bottomAnchor.constraint(
            equalTo: container.bottomAnchor, constant: -54)
        previewBottom.priority = .defaultHigh
        previewBottom.isActive = true
        // The badge sits above the preview text.
        reminderBadge.setContentCompressionResistancePriority(.required, for: .horizontal)

        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    private func applyTheme() {
        previewBox.layer?.borderColor =
            EditorThemeKit.effectBlockTop.withAlphaComponent(0.22).cgColor
        previewBox.layer?.backgroundColor =
            EditorThemeKit.effectBlockTop.withAlphaComponent(0.08).cgColor
        previewLabel.textColor = EditorThemeKit.textSecondary
        noteGlyph.contentTintColor = EditorThemeKit.effectBlockTop
        nameField.textColor = EditorThemeKit.textPrimary
        metaField.textColor = EditorThemeKit.textSecondary
    }

    func configure(with note: Note) {
        nameField.stringValue = note.title
        previewLabel.stringValue = note.text
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let date = formatter.localizedString(for: note.createdAt, relativeTo: Date())
        metaField.stringValue = note.sourceAppName.map { "Note · \($0) · \(date)" } ?? "Note · \(date)"
        reminderBadge.configure(text: ReminderCenter.badgeText(for: note.reminderDate))
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(cardMenuItem("Open") { [weak self] in self?.onOpen?() })
        menu.addItem(.separator())
        for item in reminderMenuItems?() ?? [] {
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let delete = cardMenuItem("Delete...") { [weak self] in self?.onDelete?() }
        delete.attributedTitle = NSAttributedString(
            string: "Delete...",
            attributes: [.foregroundColor: NSColor.systemRed]
        )
        menu.addItem(delete)
        return menu
    }

    private func cardMenuItem(_ title: String, handler: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(ClosureMenuTarget.fire), keyEquivalent: "")
        let target = ClosureMenuTarget(handler: handler)
        item.target = target
        item.representedObject = target // retain
        return item
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if let trackingArea { view.removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: view.bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self, userInfo: nil
        )
        view.addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        applyCardHover(container, hovered: true)
    }

    override func mouseExited(with event: NSEvent) {
        applyCardHover(container, hovered: false)
    }
}

/// Small "in 3d" pill shown on cards with an active reminder — bell glyph +
/// short countdown on a dark wash, mirroring the pin badge's language.
fileprivate final class ReminderBadgeLabel: NSView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous

        icon.image = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: "Reminder")
        icon.symbolConfiguration = .init(pointSize: 8, weight: .semibold)
        icon.contentTintColor = .white
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)

        label.font = .systemFont(ofSize: 9, weight: .semibold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 18),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 3),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(text: String?) {
        if let text {
            label.stringValue = text
            isHidden = false
        } else {
            isHidden = true
        }
    }
}

/// Shared card hover treatment: wash + hairline plus a subtle lift (1.02
/// scale, soft shadow) over 0.15s — identical for project and note cards.
@MainActor
private func applyCardHover(_ container: NSView, hovered: Bool) {
    // Ink-relative wash — reads on both the dark and light window ground.
    let ink: NSColor = CCTheme.isDark ? .white : .black
    container.layer?.backgroundColor = (hovered
        ? ink.withAlphaComponent(0.07) : .clear).cgColor
    if container.layer?.borderWidth == 1 { // leave the selection ring alone
        container.layer?.borderColor = (hovered
            ? ink.withAlphaComponent(0.14) : .clear).cgColor
    }

    guard let layer = container.layer else { return }
    // Scale about the center, not the corner.
    let frame = layer.frame
    layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
    layer.position = CGPoint(x: frame.midX, y: frame.midY)
    layer.frame = frame

    let scale: CGFloat = hovered ? 1.02 : 1.0
    let shadow: Float = hovered ? 0.30 : 0.0
    layer.shadowRadius = 10
    layer.shadowOffset = CGSize(width: 0, height: -3)

    let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
    scaleAnim.fromValue = (layer.presentation() ?? layer).value(forKeyPath: "transform.scale")
    scaleAnim.toValue = scale
    let shadowAnim = CABasicAnimation(keyPath: "shadowOpacity")
    shadowAnim.fromValue = layer.presentation()?.shadowOpacity ?? layer.shadowOpacity
    shadowAnim.toValue = shadow
    for anim in [scaleAnim, shadowAnim] {
        anim.duration = 0.15
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
    }
    layer.add(scaleAnim, forKey: "hover-scale")
    layer.add(shadowAnim, forKey: "hover-shadow")
    layer.setValue(scale, forKeyPath: "transform.scale")
    layer.shadowOpacity = shadow
}

/// Card root view — routes right-click to the item's context menu.
private final class CardBackdropView: NSView {
    private let menuProvider: () -> NSMenu?

    init(menuProvider: @escaping () -> NSMenu?) {
        self.menuProvider = menuProvider
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuProvider() else {
            super.rightMouseDown(with: event)
            return
        }
        CaptureCatMenuPresenter.showContextMenu(menu, with: event, for: self)
    }
}

private final class ClosureMenuTarget: NSObject {
    private let handler: () -> Void
    init(handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { handler() }
}

/// Flat hover-pill button used by the browser header (matches the editor's
/// toolbar chip look: hairline capsule, hover wash, 13pt medium).
@MainActor
final class HoverPillButton: NSControl {
    var onClick: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private var isHovered = false { didSet { needsLayout = true; refresh() } }
    private var themeObservation: CCThemeObservation?

    init(title: String, symbol: String?) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = CCTheme.radius(.md)
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        if let symbol {
            iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            iconView.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
            iconView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(iconView)
        }

        label.stringValue = title
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        let hasIcon = symbol != nil
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])
        if hasIcon {
            NSLayoutConstraint.activate([
                iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
                label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 5),
            ])
        } else {
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10).isActive = true
        }
        themeObservation = CCThemeObservation { [weak self] in self?.refresh() }

        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func refresh() {
        layer?.backgroundColor = (isHovered ? EditorThemeKit.hoverFill : .clear).cgColor
        layer?.borderColor = EditorThemeKit.hairline.cgColor
        iconView.contentTintColor = EditorThemeKit.textPrimary
        label.textColor = EditorThemeKit.textPrimary
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
