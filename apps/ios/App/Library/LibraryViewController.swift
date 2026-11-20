import UIKit

/// The library grid — the Mac project browser on a phone: a header block
/// (sidebar toggle on iPad · "New Recording" record-red pill · the pill
/// filter with counts "All · N | Videos · N | Images · N | Shares · N" · the
/// "Search captures…" well · one hairline), then uploads still on this iPhone,
/// then cloud projects and shares as Mac-style cards.
/// Stays in sync with the Mac and the web by re-listing on appear, on
/// becoming active, on `.ccLibraryShouldRefresh`, on pull, and every 30 s
/// while visible.
final class LibraryViewController: UIViewController, UICollectionViewDelegate {
    enum Filter: Int, CaseIterable {
        case all, videos, images, shares
        var title: String { [String(localized: "All", comment: "Library filter segment: every item"), String(localized: "Videos", comment: "Library filter segment"), String(localized: "Images", comment: "Library filter segment: screenshots"), String(localized: "Shares", comment: "Library filter segment: shared video links")][rawValue] }
    }

    nonisolated private enum Section: Hashable, Sendable {
        case inbox
        case items
        case status
    }

    weak var coordinator: LibraryCoordinator?

    private let headerBlock = UIView()
    private let sidebarToggle = CCButton(symbol: "sidebar-left", style: .secondary, size: .regular)
    private let titleLabel = ccLabel(String(localized: "Library", comment: "Library screen title"), font: CCFont.largeTitle, color: CCTheme.color.foreground)
    /// Record-red capsule, like the Mac browser's — opens Capture.
    private let newRecording = CCButton(title: String(localized: "New Recording", comment: "Library header button: start a new recording"), symbol: "record", style: .destructive, size: .sm, radius: .full)
    private let filterBar = CCSegmented(segments: Filter.allCases.map(\.title), size: .regular, radius: .full)
    private let searchField = CCSearchField(placeholder: String(localized: "Search captures…", comment: "Library search field placeholder"))
    private var query = ""
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, LibraryRow>!
    private var pull: CCPullToRefresh!
    private var observation: SurfaceObservation?
    private var timer: Timer?
    private var hasAppliedOnce = false
    private var filter: Filter = .all
    private let backgroundHost = UIView()
    private var emptyKey: String?
    private var observers: [NSObjectProtocol] = []

    /// The row shown in the detail pane (two-pane only).
    var selectedRow: LibraryRow? {
        didSet { refreshSelection() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = CCTheme.color.background
        buildHeader()
        // A new text size re-measures the cards (columns, wrapped names).
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: LibraryViewController, _: UITraitCollection) in
            self.collectionView.collectionViewLayout.invalidateLayout()
        }

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .onDrag
        collectionView.register(LibraryCardCell.self, forCellWithReuseIdentifier: LibraryCardCell.reuse)
        collectionView.register(InboxTakeCell.self, forCellWithReuseIdentifier: InboxTakeCell.reuse)
        collectionView.register(LibraryStatusCell.self, forCellWithReuseIdentifier: LibraryStatusCell.reuse)
        collectionView.register(SkeletonCardCell.self, forCellWithReuseIdentifier: SkeletonCardCell.reuse)
        collectionView.register(LibrarySectionHeader.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: LibrarySectionHeader.reuse)
        collectionView.backgroundView = backgroundHost
        view.insertSubview(collectionView, belowSubview: headerBlock)

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: headerBlock.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        configureDataSource()
        pull = CCPullToRefresh(scrollView: collectionView) { [weak self] in
            Task { @MainActor in
                await LibraryStore.shared.refresh().value
                self?.pull.endRefreshing()
            }
        }
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        collectionView.addGestureRecognizer(longPress)

        observation = SurfaceObservation { [weak self] in self?.applySnapshot() }
        observers.append(NotificationCenter.default.addObserver(forName: .ccAppDidBecomeActive, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard self?.viewIfLoaded?.window != nil else { return }
                LibraryStore.shared.refresh()
            }
        })
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        LibraryStore.shared.refreshIfStale(5)
        AppEnvironment.shared.inbox.reload()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard self?.viewIfLoaded?.window != nil else { return }
                LibraryStore.shared.refresh()
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Header block (the Mac browser's two header rows)

    private var headerRow: UIStackView?
    /// The New Recording key's width WITH its label (measured while it shows one).
    private var labeledNewRecordingWidth: CGFloat = 0

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        fitNewRecording()
    }

    /// New Recording keeps its label only while the title still fits beside
    /// it whole (long titles in some languages, a narrow column, the largest
    /// text sizes); otherwise it is the red record key alone.
    private func fitNewRecording() {
        guard let row = headerRow, row.bounds.width > 0 else { return }
        let label = String(localized: "New Recording", comment: "Library header button: start a new recording")
        if !newRecording.title.isEmpty { labeledNewRecordingWidth = newRecording.intrinsicContentSize.width }
        if labeledNewRecordingWidth == 0 {
            newRecording.title = label
            labeledNewRecordingWidth = newRecording.intrinsicContentSize.width
        }
        let toggle = sidebarToggle.isHidden ? 0 : sidebarToggle.intrinsicContentSize.width + row.spacing
        let need = toggle + ceil(titleLabel.intrinsicContentSize.width) + row.spacing * 2 + labeledNewRecordingWidth
        let showLabel = !traitCollection.preferredContentSizeCategory.isAccessibilityCategory && need <= row.bounds.width
        let title = showLabel ? label : ""
        if newRecording.title != title { newRecording.title = title }
    }

    private func buildHeader() {
        headerBlock.translatesAutoresizingMaskIntoConstraints = false
        headerBlock.backgroundColor = CCTheme.color.background
        view.addSubview(headerBlock)
        sidebarToggle.accessibilityLabelOverride = String(localized: "Show or hide the sidebar")
        sidebarToggle.isHidden = true
        sidebarToggle.onTap = { [weak self] in
            guard let self, let visible = self.coordinator?.toggleSidebar?() else { return }
            self.setSidebarVisible(visible)
        }
        titleLabel.accessibilityTraits = .header
        newRecording.accessibilityHint = String(localized: "Opens Capture", comment: "Accessibility hint for the New Recording button; Capture is the tab name")
        newRecording.accessibilityLabelOverride = String(localized: "New Recording", comment: "Library header button: start a new recording")
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (vc: LibraryViewController, _: UITraitCollection) in
            vc.view.setNeedsLayout()
        }
        newRecording.onTap = { [weak self] in self?.coordinator?.openCapture?() }
        newRecording.setContentCompressionResistancePriority(.required, for: .horizontal)
        filterBar.onChange = { [weak self] index in
            guard let self, let filter = Filter(rawValue: index) else { return }
            self.filter = filter
            self.rearm()
            self.scrollToTop()
        }
        filterBar.accessibilityLabel = String(localized: "Filter", comment: "Accessibility label for the library filter segments")
        searchField.onQueryChange = { [weak self] text in
            self?.query = text.trimmingCharacters(in: .whitespaces)
            self?.rearm()
        }
        let row = UIStackView(arrangedSubviews: [sidebarToggle, titleLabel, UIView(), newRecording])
        headerRow = row
        row.spacing = CCSpace.sm + 2
        row.alignment = .center
        let hairline = CCDivider()
        for item in [row, filterBar, searchField, hairline] as [UIView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            headerBlock.addSubview(item)
        }
        let guide = headerBlock.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            headerBlock.topAnchor.constraint(equalTo: view.topAnchor),
            headerBlock.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerBlock.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            row.topAnchor.constraint(equalTo: guide.topAnchor, constant: CCSpace.sm),
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            row.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: CCSpace.gutter),
            row.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -CCSpace.gutter),
            filterBar.topAnchor.constraint(equalTo: row.bottomAnchor, constant: CCSpace.sm),
            filterBar.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: CCSpace.gutter),
            filterBar.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -CCSpace.gutter),
            searchField.topAnchor.constraint(equalTo: filterBar.bottomAnchor, constant: CCSpace.sm + 2),
            searchField.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: CCSpace.gutter),
            searchField.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -CCSpace.gutter),
            hairline.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: CCSpace.md),
            hairline.leadingAnchor.constraint(equalTo: headerBlock.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: headerBlock.trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: headerBlock.bottomAnchor),
        ])
    }

    /// iPad two-pane: the Mac's ghost sidebar toggle (a raised chip while the
    /// sidebar shows).
    func setSidebarToggleAvailable(_ available: Bool, sidebarVisible: Bool = true) {
        loadViewIfNeeded()
        sidebarToggle.isHidden = !available
        setSidebarVisible(sidebarVisible)
    }

    private func setSidebarVisible(_ visible: Bool) {
        sidebarToggle.style = visible ? .secondary : .ghost
    }

    /// Filter and search aren't observable state: re-arm the loop so it
    /// tracks what the current filter reads (Videos/Images read facts).
    private func rearm() {
        observation?.cancel()
        observation = SurfaceObservation { [weak self] in self?.applySnapshot() }
    }

    func scrollToTop() {
        collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: true)
    }


    // MARK: - Layout

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] index, environment in
            guard let self, let section = self.dataSource?.sectionIdentifier(for: index) else { return nil }
            let width = environment.container.effectiveContentSize.width
            let gutter = CCSpace.gutter - 6
            switch section {
            case .inbox:
                let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(84)))
                let group = NSCollectionLayoutGroup.vertical(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(84)), subitems: [item])
                let layout = NSCollectionLayoutSection(group: group)
                layout.interGroupSpacing = CCSpace.sm
                layout.contentInsets = .init(top: 0, leading: CCSpace.gutter, bottom: CCSpace.md, trailing: CCSpace.gutter)
                let header = NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(32)),
                    elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)
                layout.boundarySupplementaryItems = [header]
                return layout
            case .items:
                let available = width - gutter * 2
                // Accessibility text sizes: wider cards (fewer columns) so
                // names wrap into readable lines.
                let minCard: CGFloat = environment.traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 300 : 156
                let columns = max(1, min(6, Int((available + 4) / (minCard + 4))))
                let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1 / CGFloat(columns)), heightDimension: .estimated(220)))
                item.contentInsets = .init(top: 0, leading: 2, bottom: 0, trailing: 2)
                let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(220)), repeatingSubitem: item, count: columns)
                let layout = NSCollectionLayoutSection(group: group)
                layout.interGroupSpacing = CCSpace.xs
                layout.contentInsets = .init(top: CCSpace.xs, leading: gutter, bottom: CCSpace.md, trailing: gutter)
                return layout
            case .status:
                let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(44)))
                let group = NSCollectionLayoutGroup.vertical(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(44)), subitems: [item])
                let layout = NSCollectionLayoutSection(group: group)
                layout.contentInsets = .init(top: 0, leading: CCSpace.gutter, bottom: CCSpace.xl, trailing: CCSpace.gutter)
                return layout
            }
        }
    }

    private func configureDataSource() {
        dataSource = UICollectionViewDiffableDataSource<Section, LibraryRow>(collectionView: collectionView) { [weak self] collectionView, indexPath, row in
            switch row {
            case .take(let id):
                let cell = collectionView.dequeueReusableCell(withReuseIdentifier: InboxTakeCell.reuse, for: indexPath) as! InboxTakeCell
                cell.bind(takeID: id) { [weak self] take in self?.confirmDiscard(take) }
                return cell
            case .project, .share:
                let cell = collectionView.dequeueReusableCell(withReuseIdentifier: LibraryCardCell.reuse, for: indexPath) as! LibraryCardCell
                cell.bind(row)
                cell.isCurrent = self?.selectedRow == row
                return cell
            case .status(let text):
                let cell = collectionView.dequeueReusableCell(withReuseIdentifier: LibraryStatusCell.reuse, for: indexPath) as! LibraryStatusCell
                cell.configure(text, spinning: true)
                return cell
            case .skeleton:
                return collectionView.dequeueReusableCell(withReuseIdentifier: SkeletonCardCell.reuse, for: indexPath)
            }
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            let view = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: LibrarySectionHeader.reuse, for: indexPath) as! LibrarySectionHeader
            view.label.text = String(localized: "Uploading from this \(ThisDevice.noun)", comment: "Section header; argument is iPhone or iPad")
            return view
        }
    }

    // MARK: - Snapshot

    private var pendingSnapshot: (NSDiffableDataSourceSnapshot<Section, LibraryRow>, LibraryStore.Phase)?

    /// Read the stores (inside the observation loop) and schedule the apply
    /// for the next turn — OUTSIDE the tracking scope, so the cells' own
    /// observation loops (bound during apply) don't merge into this one.
    private func applySnapshot() {
        guard dataSource != nil else { return }
        let built = buildSnapshot()
        let scheduled = pendingSnapshot != nil
        pendingSnapshot = built
        guard !scheduled else { return }
        DispatchQueue.main.async { [weak self] in self?.flushSnapshot() }
    }

    private var pendingCounts: [Int] = []

    private func flushSnapshot() {
        guard let (snapshot, phase) = pendingSnapshot else { return }
        pendingSnapshot = nil
        for (index, count) in pendingCounts.enumerated() {
            let title = Filter(rawValue: index)?.title ?? ""
            filterBar.setTitle(count > 0 ? "\(title) · \(count)" : title, at: index)
        }
        dataSource.apply(snapshot, animatingDifferences: hasAppliedOnce && view.window != nil)
        hasAppliedOnce = true
        updateEmptyState(isEmpty: snapshot.numberOfItems == 0, phase: phase)
        refreshSelection()
        requestVisibleDetails()
    }

    /// `willDisplay` only fires for cells that come on screen. A card whose
    /// project changed elsewhere keeps its identity and is reconfigured in
    /// place, so ask again for every visible card after each apply (cached
    /// revisions cost nothing; a new revision is fetched once).
    private func requestVisibleDetails() {
        let store = LibraryStore.shared
        var projects: [CloudProjectSummary] = []
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard case .project(let id)? = dataSource.itemIdentifier(for: indexPath), let project = store.project(id) else { continue }
            projects.append(project)
        }
        guard !projects.isEmpty else { return }
        // Next turn: facts can land synchronously from the disk cache, and a
        // mutation made inside an observation pass never fires its onChange.
        DispatchQueue.main.async {
            store.requestFacts(for: projects)
            for project in projects { ThumbnailStore.shared.request(project) }
        }
    }

    private func buildSnapshot() -> (NSDiffableDataSourceSnapshot<Section, LibraryRow>, LibraryStore.Phase) {
        let store = LibraryStore.shared
        let inbox = AppEnvironment.shared.inbox
        let phase = store.phase
        var snapshot = NSDiffableDataSourceSnapshot<Section, LibraryRow>()

        let takes = inbox.takes
        if !takes.isEmpty, query.isEmpty, filter != .shares {
            let relevant = takes.filter { take in
                switch filter {
                case .images: return take.kind == .screenshot
                case .videos: return take.kind != .screenshot
                default: return true
                }
            }
            if !relevant.isEmpty {
                snapshot.appendSections([.inbox])
                snapshot.appendItems(relevant.map { .take($0.id) }, toSection: .inbox)
            }
        }

        var items: [LibraryRow] = []
        var status: String?
        let projects = store.sortedProjects
        switch filter {
        case .all:
            var dated: [(Date, LibraryRow)] = projects.map { ($0.updatedAt, .project($0.projectId)) }
            dated += store.standaloneShares.map { ($0.createdAt, .share($0.videoId)) }
            items = dated.sorted { $0.0 > $1.0 }.map(\.1)
        case .videos, .images:
            let wantStill = filter == .images
            let unknown = projects.filter { !store.factsKnown(for: $0) }
            if !unknown.isEmpty {
                // Next turn, NOT inside this tracking scope: facts that land
                // synchronously (disk cache) must re-run the loop, and a
                // mutation made during tracking never fires its onChange.
                DispatchQueue.main.async { store.requestFacts(for: unknown) }
                status = String(localized: "Sorting \(unknown.count) more…", comment: "Library status while classifying projects; argument is a count")
            }
            items = projects.filter { project in
                guard let facts = store.facts(for: project) else { return false }
                return facts.isStillCapture == wantStill
            }.map { .project($0.projectId) }
        case .shares:
            items = store.shares.sorted { $0.createdAt > $1.createdAt }.map { .share($0.videoId) }
        }
        // Search narrows whatever the filter shows (names, like the Mac's).
        if !query.isEmpty {
            items = items.filter { row in
                let name: String?
                switch row {
                case .project(let id): name = store.project(id)?.name
                case .share(let id): name = store.share(id).map { ($0.fileName as NSString).deletingPathExtension }
                default: name = nil
                }
                return name?.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
        // "Videos · 12" — counts fold into the filter titles, zero stays bare.
        // Videos/Images need every project's facts (lazy) — until they're all
        // known those titles stay bare rather than show a wrong number.
        let still = projects.compactMap { store.facts(for: $0)?.isStillCapture }
        let complete = still.count == projects.count || projects.allSatisfy { store.factsKnown(for: $0) }
        pendingCounts = [
            projects.count + store.standaloneShares.count,
            complete ? still.filter { !$0 }.count : 0,
            complete ? still.filter { $0 }.count : 0,
            store.shares.count,
        ]

        if phase == .loading, items.isEmpty {
            items = (0..<6).map { .skeleton($0) }
        }
        if !items.isEmpty {
            snapshot.appendSections([.items])
            snapshot.appendItems(items, toSection: .items)
        }
        if let status, phase == .loaded {
            snapshot.appendSections([.status])
            snapshot.appendItems([.status(status)], toSection: .status)
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uiSnapshotDebug") {
            print("SNAPSHOT filter=\(filter) items=\(snapshot.numberOfItems) status=\(status ?? "-") phase=\(phase)")
        }
        #endif
        return (snapshot, phase)
    }

    private func updateEmptyState(isEmpty: Bool, phase: LibraryStore.Phase) {
        var key: String?
        if isEmpty {
            switch phase {
            case .failed(let message): key = "failed:\(message)"
            case .loaded: key = query.isEmpty ? "empty:\(filter.rawValue)" : "search:\(query)"
            default: key = nil
            }
        }
        guard key != emptyKey else { return }
        emptyKey = key
        backgroundHost.subviews.forEach { $0.removeFromSuperview() }
        guard let key else { return }
        let empty: CCEmptyState
        if key.hasPrefix("search:") {
            empty = CCEmptyState(symbol: "search", title: String(localized: "No matches", comment: "Library empty state: search found nothing"), message: String(localized: "Nothing in your library is called “\(query)”.", comment: "Argument is the search text"))
        } else if case .failed(let message) = phase, key.hasPrefix("failed") {
            empty = CCEmptyState(symbol: "warning-fill", title: String(localized: "Couldn't load your library"), message: message,
                                 primary: CCButton(title: String(localized: "Try again", comment: "Button: retry loading the library"), style: .primary) { LibraryStore.shared.refresh() })
        } else {
            switch filter {
            case .all:
                empty = CCEmptyState(symbol: "film-stack", title: String(localized: "Nothing here yet", comment: "Library empty state title"),
                                     message: String(localized: "Recordings and screenshots from this \(ThisDevice.noun), your Mac and the web all land here.", comment: "Argument is iPhone or iPad"),
                                     primary: CCButton(title: String(localized: "Start capturing", comment: "Library empty state button: go to Capture"), symbol: "record", style: .primary) { [weak self] in self?.coordinator?.openCapture?() })
            case .videos:
                empty = CCEmptyState(symbol: "film", title: String(localized: "No videos yet"), message: String(localized: "Record on this \(ThisDevice.noun) or on your Mac — they show up here.", comment: "Argument is iPhone or iPad"))
            case .images:
                empty = CCEmptyState(symbol: "photo", title: String(localized: "No images yet"), message: String(localized: "Import screenshots from Photos in the Capture tab."))
            case .shares:
                empty = CCEmptyState(symbol: "link", title: String(localized: "No shared videos"), message: String(localized: "Share a recording from your Mac or the web to get a link you can send."))
            }
        }
        backgroundHost.addSubview(empty)
        NSLayoutConstraint.activate([
            empty.leadingAnchor.constraint(equalTo: backgroundHost.safeAreaLayoutGuide.leadingAnchor, constant: CCSpace.gutter),
            empty.trailingAnchor.constraint(equalTo: backgroundHost.safeAreaLayoutGuide.trailingAnchor, constant: -CCSpace.gutter),
            empty.topAnchor.constraint(equalTo: backgroundHost.topAnchor, constant: CCSpace.lg),
        ])
    }

    private func refreshSelection() {
        guard let collectionView else { return }
        for cell in collectionView.visibleCells {
            guard let card = cell as? LibraryCardCell, let indexPath = collectionView.indexPath(for: cell),
                  let row = dataSource.itemIdentifier(for: indexPath) else { continue }
            card.isCurrent = row == selectedRow
        }
    }

    // MARK: - Delegate

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard let row = dataSource.itemIdentifier(for: indexPath) else { return }
        let store = LibraryStore.shared
        switch row {
        case .project(let id):
            guard let project = store.project(id) else { return }
            store.requestFacts(for: [project])
            ThumbnailStore.shared.request(project)
        case .share(let id):
            guard let share = store.share(id) else { return }
            ThumbnailStore.shared.request(share)
        default:
            break
        }
    }

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .project, .share: return true
        default: return false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .project(let id): coordinator?.showProject(id)
        case .share(let id): coordinator?.showShare(id)
        default: break
        }
    }

    // MARK: - Long press → house action sheet

    @objc private func longPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        let point = gesture.location(in: collectionView)
        guard let indexPath = collectionView.indexPathForItem(at: point) else { return }
        showActions(at: indexPath)
    }

    /// The card's house action sheet (long press; the l10n gate's seam).
    func showActions(at indexPath: IndexPath) {
        guard let row = dataSource.itemIdentifier(for: indexPath),
              let cell = collectionView.cellForItem(at: indexPath) else { return }
        CCHaptics.light()
        let store = LibraryStore.shared
        switch row {
        case .project(let id):
            guard let project = store.project(id) else { return }
            let sheet = CCActionSheet(title: project.name)
            sheet.addAction(String(localized: "Open", comment: "Action sheet: open the project"), symbol: "play-fill") { [weak self] in self?.coordinator?.showProject(id) }
            sheet.addAction(String(localized: "Rename", comment: "Action sheet: rename the project"), symbol: "pencil") { [weak self] in
                guard let self else { return }
                ProjectActions.promptRename(projectID: id, currentName: project.name, from: self)
            }
            sheet.addAction(String(localized: "Open in web editor", comment: "Action sheet"), symbol: "globe") { ProjectActions.openInWebEditor(projectID: id) }
            if let share = store.share(linkedTo: id) {
                sheet.addAction(String(localized: "Copy share link", comment: "Action sheet"), symbol: "link") { ProjectActions.copyLink(share) }
            }
            if project.isOwner {
                sheet.addAction(String(localized: "Delete", comment: "Action sheet: delete the project"), symbol: "trash", destructive: true) { [weak self] in
                    guard let self else { return }
                    ProjectActions.confirmDelete(projectID: id, name: project.name, from: self) { [weak self] in
                        self?.coordinator?.projectDeleted(id)
                    }
                }
            }
            sheet.present(from: self, source: cell)
        case .share(let id):
            guard let share = store.share(id) else { return }
            let sheet = CCActionSheet(title: (share.fileName as NSString).deletingPathExtension)
            sheet.addAction(String(localized: "Open", comment: "Action sheet: open the shared video"), symbol: "play-fill") { [weak self] in self?.coordinator?.showShare(id) }
            sheet.addAction(String(localized: "Copy link", comment: "Action sheet: copy the share link"), symbol: "link") { ProjectActions.copyLink(share) }
            sheet.addAction(String(localized: "Share…", comment: "Action sheet: open the system share sheet for the link"), symbol: "share") { [weak self, weak cell] in
                guard let self, let cell else { return }
                ProjectActions.shareSheet(share, from: self, source: cell)
            }
            sheet.present(from: self, source: cell)
        default:
            break
        }
    }

    func confirmDiscard(_ take: PendingTake) {
        ProjectActions.confirmDiscard(take, from: self)
    }

    // Probe seams.
    var probeCollectionView: UICollectionView { collectionView }
    var probeFilter: CCSegmented { filterBar }
}
