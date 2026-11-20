import UIKit

/// The History panel (Studio 4f) — the touch twin of the Mac's
/// `HistoryPaneAppKit`: one card per day of versions (`HistoryRowCell`:
/// avatar, time, badges, summary), newest first; a "Changed outside this
/// editor" row with [Review] when project.json moved under the editor; the
/// empty state for a project with no history yet; a footer.
///
/// A row's action sheet holds the Mac's row menu (Preview, Name, Compare
/// with Current, Restore, Delete) plus Compare with Previous / Compare with…
/// (two versions). Compare slides over the list inside the panel; Preview
/// shows the version on the live stage; Restore is one undo step.
///
/// Data comes through `ProjectHistoryService` (on-device today, the cloud in
/// Phase 5); every word, row, menu and Compare group is the shared Mac code.
@available(iOS 26, *)
@MainActor
final class HistoryPanelController: UIViewController {
    #if DEBUG
    /// INJECTED DEFECT (`--history --inject snap-compare`): Compare snaps in.
    static var debugSnapCompare = false
    #endif

    static let compareTravelFraction: CGFloat = 1.0

    let service: ProjectHistoryService
    weak var host: EditorViewController?
    let device: String
    /// Day and time words (the gate pins it).
    var clock: HistoryClock = .current
    weak var presentation: HistoryPresentation?

    private(set) var page: CloudVersionPage?
    private let titleLabel = ccLabel(String(localized: "History", comment: "Title of the project version-history panel"), font: CCFont.header, color: CCTheme.color.foreground)
    let closeButton = CCButton(symbol: "close", style: .ghost, size: .sm, radius: .full)
    private let content = UIView()
    private let listPage = UIView()
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private(set) var rows: [HistoryRowCell] = []
    private(set) var sections: [UIView] = []
    private(set) var sectionTitles: [String] = []
    private(set) var emptyState: CCEmptyState?
    private(set) var externalRow: HistoryExternalRow?
    private(set) var footerLabel: UILabel?
    private(set) var comparePage: HistoryComparePage?
    private var toaster: CCToaster?

    init(service: ProjectHistoryService, host: EditorViewController?, device: String) {
        self.service = service
        self.host = host
        self.device = device
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let root = UIView()
        root.backgroundColor = .clear
        view = root
        titleLabel.accessibilityTraits = .header
        closeButton.accessibilityLabelOverride = String(localized: "Close History", comment: "VoiceOver label of the History panel's close button")
        closeButton.onTap = { [weak self] in self?.close() }
        content.clipsToBounds = true
        stack.axis = .vertical
        stack.spacing = CCSpace.md
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        scroll.showsHorizontalScrollIndicator = false
        scroll.addSubview(stack)
        listPage.addSubview(scroll)
        for view in [titleLabel, closeButton, content] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        listPage.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(listPage)
        let pad = CCSpace.md
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: CCSpace.lg),
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: CCSpace.lg),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -CCSpace.sm),
            closeButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -CCSpace.sm),
            closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            content.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: CCSpace.sm),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            listPage.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            listPage.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            listPage.topAnchor.constraint(equalTo: content.topAnchor),
            listPage.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: listPage.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: listPage.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: listPage.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: listPage.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: pad),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -pad),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: CCSpace.xs),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -CCSpace.lg),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -pad * 2),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        toaster = CCToaster(host: view)
        reloadNow()
    }

    // MARK: - Data

    /// Re-reads the versions (local: synchronous) and re-renders.
    func reloadNow() {
        if let local = service as? LocalProjectHistory {
            render(local.currentPage())
        } else {
            Task { [weak self] in
                guard let self else { return }
                self.render(try? await self.service.page())
            }
        }
    }

    // MARK: - Render

    private func clear() {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        rows = []
        sections = []
        sectionTitles = []
        emptyState = nil
        externalRow = nil
        footerLabel = nil
    }

    private func render(_ next: CloudVersionPage?) {
        page = next
        clear()
        if let change = host?.historyExternalChange() {
            let row = HistoryExternalRow(summary: change.summary)
            row.onReview = { [weak self] in self?.reviewExternalChange() }
            externalRow = row
            stack.addArrangedSubview(row)
        }
        guard let page = next, !page.versions.isEmpty else {
            let empty = CCEmptyState(symbol: "history", title: String(localized: "No history yet", comment: "History panel empty state title"),
                                     message: String(localized: "Every save of this project on this \(device) is kept here, so you can preview, compare and restore earlier versions.", comment: "History panel empty state; the argument is iPhone or iPad"))
            emptyState = empty
            stack.addArrangedSubview(empty)
            return
        }
        let headID = HistoryWords.headID(of: page)
        for (day, versions) in HistoryWords.days(page.versions, clock: clock) {
            let title = HistoryWords.dayTitle(day, clock: clock)
            let header = ccLabel(title.uppercased(), font: CCFont.micro, color: CCTheme.color.mutedForeground)
            header.accessibilityTraits = .header
            header.accessibilityLabel = title
            let card = CCSurface(.recessed, tint: CCTheme.color.elevated, radius: .lg)
            card.translatesAutoresizingMaskIntoConstraints = false
            let list = UIStackView()
            list.axis = .vertical
            list.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(list)
            NSLayoutConstraint.activate([
                list.leadingAnchor.constraint(equalTo: card.leadingAnchor),
                list.trailingAnchor.constraint(equalTo: card.trailingAnchor),
                list.topAnchor.constraint(equalTo: card.topAnchor, constant: 2),
                list.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -2),
            ])
            for (index, version) in versions.enumerated() {
                if index > 0 { list.addArrangedSubview(CCDivider()) }
                let model = HistoryRowModel(version: version, isHead: version.id == headID,
                                            timeText: HistoryWords.timeText(version.date, clock: clock))
                let row = HistoryRowCell(version: version, model: model)
                row.onActivate = { [weak self] row in self?.showActions(for: row) }
                list.addArrangedSubview(row)
                rows.append(row)
            }
            let section = UIStackView(arrangedSubviews: [header, card])
            section.axis = .vertical
            section.spacing = CCSpace.xs + 2
            stack.addArrangedSubview(section)
            sections.append(section)
            sectionTitles.append(title)
        }
        let footer = ccLabel(footerText(page), font: CCFont.caption, color: CCTheme.color.mutedForeground, lines: 0)
        footerLabel = footer
        stack.addArrangedSubview(footer)
    }

    private func footerText(_ page: CloudVersionPage) -> String {
        var parts = [service.isLocal ? String(localized: "Kept on this \(device)", comment: "History footer: versions are stored on this device; the argument is iPhone or iPad") : String(localized: "Kept in your CaptureCat cloud", comment: "History footer: versions are stored in the cloud")]
        if let caption = HistoryWords.retentionCaption(page) { parts.append(caption) }
        let named = page.versions.filter(\.isNamed).count
        if named > 0, page.retention?.maxNamed == nil { parts.append(named == 1 ? String(localized: "1 named", comment: "History footer: one version has a name") : String(localized: "\(named) named", comment: "History footer: how many versions have names")) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Row actions

    /// What a row's action sheet offers, in order (the Mac menu + iOS's two-version compares).
    func actions(for row: HistoryRowCell) -> [(title: String, run: () -> Void)] {
        let version = row.version
        var out: [(String, () -> Void)] = []
        for action in HistoryRowAction.items(isHead: row.model.isHead, isNamed: version.isNamed, isOwner: page?.isOwner) {
            switch action {
            case .preview: out.append((action.title, { [weak self] in self?.preview(version) }))
            case .name: out.append((action.title, { [weak self] in self?.name(version) }))
            case .compareWithCurrent:
                out.append((action.title, { [weak self] in self?.compare(version, with: nil) }))
                if let previous = previousVersion(of: version) {
                    out.append((String(localized: "Compare with Previous", comment: "History row menu: compare this version with the one before it"), { [weak self] in self?.compare(previous, with: version) }))
                }
            case .restore: out.append((action.title, { [weak self] in self?.confirmRestore(version) }))
            case .delete: out.append((action.title, { [weak self] in self?.confirmDelete(version) }))
            }
        }
        // The head offers the two-version compares too (its menu has no "with Current").
        if row.model.isHead, let previous = previousVersion(of: version) {
            out.insert((String(localized: "Compare with Previous", comment: "History row menu: compare this version with the one before it"), { [weak self] in self?.compare(previous, with: version) }), at: min(1, out.count))
        }
        if (page?.versions.count ?? 0) > 1 {
            let index = out.firstIndex { $0.0 == HistoryRowAction.restore.title } ?? out.count
            out.insert((String(localized: "Compare with…", comment: "History row menu: pick another version to compare with"), { [weak self] in self?.pickCompare(for: version) }), at: index)
        }
        return out
    }

    private func previousVersion(of version: CloudVersion) -> CloudVersion? {
        guard let versions = page?.versions, let index = versions.firstIndex(where: { $0.id == version.id }),
              versions.indices.contains(index + 1) else { return nil }
        return versions[index + 1]
    }

    private(set) weak var activeRow: HistoryRowCell?

    func showActions(for row: HistoryRowCell) {
        activeRow?.setActive(false)
        activeRow = row
        row.setActive(true)
        let sheet = CCActionSheet(title: HistoryWords.stamp(row.version.date, clock: clock), message: row.model.summary)
        for (title, run) in actions(for: row) {
            let symbol: String?
            switch title {
            case HistoryRowAction.preview.title: symbol = "eye"
            case HistoryRowAction.restore.title: symbol = "clock.arrow.circlepath"
            case HistoryRowAction.delete.title: symbol = "trash"
            case HistoryRowAction.name(isNamed: true).title, HistoryRowAction.name(isNamed: false).title: symbol = "pencil"
            default: symbol = "split"
            }
            sheet.addAction(title, symbol: symbol, destructive: title == HistoryRowAction.delete.title) { [weak row] in
                row?.setActive(false)
                run()
            }
        }
        sheet.present(from: self, source: row)
    }

    // MARK: Preview

    func preview(_ version: CloudVersion) {
        guard let host else { return }
        let service = self.service
        let clock = self.clock
        Task { [weak self, weak host] in
            guard let self, let host else { return }
            do {
                let document = try await service.document(versionID: version.id)
                let begin = { [weak self, weak host] in
                    guard let host else { return }
                    do {
                        let session = try HistoryPreviewSession.begin(version: version, document: document, in: host, clock: clock)
                        // The panel may be gone (iPhone) — the banner restores on its own.
                        session.onRestore = { [weak self, weak host] session in
                            guard let host else { return }
                            Self.confirmRestore(session.version, service: service, host: host, clock: clock,
                                                after: { self?.reloadNow() })
                        }
                    } catch {
                        CCAlert(title: String(localized: "Couldn’t open that version", comment: "Alert title: a history version failed to load"), message: error.localizedDescription)
                            .addButton(String(localized: "OK", comment: "Alert button"), role: .primary).present(from: host)
                    }
                }
                // iPhone: the sheet steps aside so the stage shows the version.
                if self.presentation?.style == .sheet {
                    self.presentation?.dismiss(completion: begin)
                } else {
                    begin()
                }
            } catch {
                self.alert(String(localized: "Couldn’t open that version", comment: "Alert title: a history version failed to load"), error)
            }
        }
    }

    // MARK: Name

    func name(_ version: CloudVersion) {
        CCAlert.prompt(title: HistoryWords.nameTitle(isNamed: version.isNamed), message: HistoryWords.nameMessage,
                       placeholder: HistoryWords.namePlaceholder, initialValue: version.label ?? "",
                       confirmTitle: String(localized: "Save", comment: "Prompt button: save the version name"), from: self, action: { [weak self] label in
            guard let self else { return }
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            try await self.service.rename(versionID: version.id, label: trimmed.isEmpty ? nil : String(trimmed.prefix(80)))
        }, completion: { [weak self] label in
            if label != nil { self?.reloadNow() }
        })
    }

    // MARK: Compare

    /// Compare `from` → `to` (nil = the project now).
    func compare(_ from: CloudVersion, with to: CloudVersion?) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let a = try await self.service.document(versionID: from.id)
                let b: Data
                if let to { b = try await self.service.document(versionID: to.id) } else { b = self.host?.historyModelDocument() ?? Data() }
                let fromJSON = (try? JSONValue.parse(data: a)) ?? .object(JSONObject())
                let toJSON = (try? JSONValue.parse(data: b)) ?? .object(JSONObject())
                self.showCompare(HistoryComparePage(from: fromJSON, to: toJSON,
                                                    fromTitle: HistoryWords.stamp(from.date, clock: self.clock),
                                                    toTitle: to.map { HistoryWords.stamp($0.date, clock: self.clock) } ?? String(localized: "now", comment: "Version compare subtitle: the project as it is now, e.g. Sep 28, 3:42 PM → now")))
            } catch {
                self.alert(String(localized: "Couldn’t compare", comment: "Alert title: comparing two versions failed"), error)
            }
        }
    }

    private func pickCompare(for version: CloudVersion) {
        guard let versions = page?.versions else { return }
        let sheet = CCActionSheet(title: String(localized: "Compare with…", comment: "Title of the sheet to pick a version to compare with"), message: HistoryWords.stamp(version.date, clock: clock))
        for other in versions where other.id != version.id {
            let title = HistoryWords.stamp(other.date, clock: clock) + (other.label.map { " — \($0)" } ?? "")
            sheet.addAction(title, symbol: "split") { [weak self] in
                // Older → newer, whichever was picked first.
                let older = (other.date ?? .distantPast) < (version.date ?? .distantPast) ? other : version
                let newer = older.id == other.id ? version : other
                self?.compare(older, with: newer)
            }
        }
        sheet.present(from: self, source: activeRow)
    }

    /// Slides the compare page over the list (the list drifts left and fades).
    func showCompare(_ page: HistoryComparePage) {
        comparePage?.removeFromSuperview()
        page.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(page)
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            page.topAnchor.constraint(equalTo: content.topAnchor),
            page.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        page.onBack = { [weak self] in self?.hideCompare() }
        comparePage = page
        content.layoutIfNeeded()
        let width = content.bounds.width
        compareStartOffset = width * Self.compareTravelFraction
        UIAccessibility.post(notification: .screenChanged, argument: page.backButton)
        #if DEBUG
        if Self.debugSnapCompare {
            listPage.alpha = 0
            return
        }
        #endif
        if CCMotion.reduceMotion {
            CCMotion.fadeAlpha(page, to: 1, duration: 0.2, from: 0)
            listPage.alpha = 0
            return
        }
        CCMotion.spring(page.layer, keyPath: "transform.translation.x", from: compareStartOffset, to: 0, .arrive)
        CCMotion.fadeAlpha(listPage, to: 0, duration: 0.26)
        CCMotion.spring(listPage.layer, keyPath: "transform.translation.x", from: 0, to: -width * 0.3, .arrive)
    }

    func hideCompare() {
        guard let page = comparePage else { return }
        comparePage = nil
        let width = content.bounds.width
        listPage.layer.setValue(0, forKeyPath: "transform.translation.x")
        CCMotion.fadeAlpha(listPage, to: 1, duration: 0.22)
        CCMotion.spring(listPage.layer, keyPath: "transform.translation.x", from: -width * 0.3, to: 0, .arrive)
        if CCMotion.reduceMotion {
            // Reduce Motion: Compare fades away where it is.
            CCMotion.fadeAlpha(page, to: 0, duration: 0.2)
            DispatchQueue.main.asyncAfter(deadline: .now() + CCMotion.paced(0.22)) { page.removeFromSuperview() }
            return
        }
        CCMotion.run(duration: 0.24, curve: .glide, {
            page.transform = CGAffineTransform(translationX: width, y: 0)
        }, completion: { page.removeFromSuperview() })
    }

    private(set) var compareStartOffset: CGFloat = 0

    // MARK: Restore

    func confirmRestore(_ version: CloudVersion, from host: EditorViewController? = nil) {
        guard let editor = host ?? self.host else { return }
        Self.confirmRestore(version, service: service, host: editor, clock: clock, presenter: self, after: { [weak self] in
            self?.reloadNow()
        })
    }

    /// "Restore the version from …?" → restore as one undo step, then a toast.
    static func confirmRestore(_ version: CloudVersion, service: ProjectHistoryService, host: EditorViewController,
                               clock: HistoryClock, presenter: UIViewController? = nil, after: (() -> Void)? = nil) {
        CCAlert.confirm(title: HistoryWords.restoreTitle(version, clock: clock), message: HistoryWords.restoreMessage,
                        confirmTitle: String(localized: "Restore", comment: "Confirm button: restore this version"), symbol: "clock.arrow.circlepath",
                        presentation: .sheet, from: presenter ?? host, action: {
            try await restore(version, service: service, host: host)
        }, completion: { restored in
            guard restored else { return }
            StudioHistory.toast(in: host, title: HistoryWords.restoredToast(version, clock: clock),
                                message: HistoryWords.restoredToastMessage, variant: .success)
            after?()
        })
    }

    /// Restore = the version's document becomes the newest version AND the
    /// project — one undo step on the editor.
    static func restore(_ version: CloudVersion, service: ProjectHistoryService, host: EditorViewController) async throws {
        HistoryPreviewSession.current(in: host)?.end(animated: false)
        host.saveNow()
        let document = try await service.restore(versionID: version.id)
        try host.historyApply(document: document, actionName: String(localized: "Restore Version", comment: "Undo action name: restoring a history version"))
    }

    // MARK: Delete

    func confirmDelete(_ version: CloudVersion) {
        CCAlert.confirm(title: HistoryWords.deleteTitle, message: HistoryWords.deleteMessage(version, clock: clock),
                        confirmTitle: String(localized: "Delete", comment: "Confirm button: delete this version"), destructive: true, symbol: "trash", presentation: .sheet, from: self,
                        action: { [weak self] in
            try await self?.service.delete(versionID: version.id)
        }, completion: { [weak self] deleted in
            if deleted { self?.reloadNow() }
        })
    }

    // MARK: Changed outside this editor → Merge Review

    func reviewExternalChange() {
        guard let host, let change = host.historyExternalChange() else { return }
        let apply: (ProjectMergeSession) -> Void = { [weak self, weak host] resolved in
            guard let host else { return }
            do {
                try host.historyApplyMerge(resolved, theirs: change.theirs)
                StudioHistory.toast(in: host, title: String(localized: "Merged the changes made outside this editor", comment: "Toast after merging external changes"),
                                    message: String(localized: "Both versions before the merge are in History.", comment: "Toast after merging external changes"), variant: .success)
            } catch {
                self?.alert(String(localized: "Couldn’t merge", comment: "Alert title: merging external changes failed"), error)
            }
            self?.reloadNow()
        }
        if change.session.conflicts.isEmpty {
            apply(change.session)
        } else {
            StudioHistory.reviewMerge(from: host, session: change.session, onApply: apply)
        }
    }

    // MARK: - Close

    func close() {
        presentation?.dismiss()
    }

    /// The presentation is gone.
    func didClose() {}

    private func alert(_ title: String, _ error: Error) {
        CCAlert(title: title, message: error.localizedDescription).addButton(String(localized: "OK", comment: "Alert button"), role: .primary).present(from: self)
    }

    // MARK: - Probe seams

    var probeListPage: UIView { listPage }
    var probeScroll: UIScrollView { scroll }
}

// MARK: - Host: the editor's side of "changed outside this editor"

@available(iOS 26, *)
extension EditorViewController {
    struct HistoryExternalChange {
        let session: ProjectMergeSession
        let theirs: Data
        let summary: String
    }

    /// The model as it would be saved now — WITHOUT saving (a save would
    /// overwrite a change on disk before it is merged).
    func historyModelDocument() -> Data {
        guard let merged = try? folder.mergedDocument(),
              let data = try? JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return Data() }
        return data
    }

    /// project.json changed since History last kept it, and not by this
    /// editor: base = the last version kept, mine = this editor's model,
    /// theirs = the file. nil when the file is what History last kept.
    func historyExternalChange() -> HistoryExternalChange? {
        let store = StudioHistory.history(of: self)
        guard let head = store.head, let disk = try? Data(contentsOf: folder.documentURL), disk != head.document,
              let base = try? JSONValue.parse(data: head.document), let theirs = try? JSONValue.parse(data: disk),
              base != theirs, let mine = try? JSONValue.parse(data: historyModelDocument()) else { return nil }
        let modified = (try? FileManager.default.attributesOfItem(atPath: folder.documentURL.path))?[.modificationDate] as? Date
        let session = ProjectMergeSession(
            base: base, mine: mine, theirs: theirs,
            mineWins: ProjectMergeSession.mineWins(mineEdited: head.updatedAt, theirsSaved: modified, now: Date()),
            theirsFallback: String(localized: "Another window", comment: "Merge review: name for the other side when the change came from another app or window"))
        return HistoryExternalChange(session: session, theirs: disk,
                                     summary: ChangeSummary.format(ProjectDiff.diff(base, theirs), maxParts: 3))
    }

    /// Applies a reviewed merge: both inputs are kept as versions (the
    /// file's as it was found, this editor's as it was), then the merge is
    /// the project — one undo step — and a `merge` version.
    func historyApplyMerge(_ session: ProjectMergeSession, theirs: Data) throws {
        let store = StudioHistory.history(of: self)
        let mine = historyModelDocument()
        let external = ProjectHistoryIdentity(actorUID: "outside", actorName: "Another window", clientKind: "ios",
                                              clientID: "outside-editor")
        store.record(theirs, at: store.clock(), checkpoint: .push, as: external)
        let merged = session.merged
        let bytes: Data
        if merged == session.theirs { bytes = theirs } else if merged == session.mine { bytes = mine } else { bytes = Data(merged.canonical.utf8) }
        try historyApply(document: bytes, actionName: String(localized: "Merge Changes", comment: "Undo action name: merging external changes"))
        store.record(bytes, at: store.clock(), checkpoint: .merge)
    }
}
