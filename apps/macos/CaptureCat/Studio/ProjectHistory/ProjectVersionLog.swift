import Foundation

/// The version-recording rules of project history (docs/project-history.md
/// §6, "Coalescing" / "Kind of a NEW version" / "change of a version") as a
/// value: which save opens a new version, which extends the head, what kind
/// it is and what change-set it carries.
///
/// One Swift copy, used by the Mac's in-memory API stand-in
/// (`StubCloudServer`, which every Mac history gate drives) and by the iOS
/// studio's on-device history (`LocalProjectHistory`), so both produce the
/// same versions from the same saves. The API's TypeScript is the reference
/// (`apps/api/src/lib/project-history.ts`).
nonisolated struct ProjectVersionLog: Equatable, Sendable {
    /// `X-CC-Checkpoint` — raw values are the wire's.
    enum Checkpoint: String, Sendable { case merge, restore, push, upload, named }

    /// One retained version, as `cloud_project_versions` stores it (minus
    /// the media manifest, which only a server keeps).
    struct Entry: Equatable, Sendable {
        let id: String
        let seq: Int
        let firstRevision: Int
        var revision: Int
        var document: Data
        let kind: String
        var label: String?
        let actorUID: String
        let clientKind: String
        let clientID: String?
        let source: String
        var change: ChangeSet?
        let openedAt: Date
        var updatedAt: Date
        let mergedFrom: Int?
        let restoredFrom: String?
        /// The last save extended this version instead of opening one.
        var extended = false
    }

    /// The API's windows: a save extends the head only while the head was
    /// opened < 10 min and updated < 3 min ago. nil = no windows (the Mac's
    /// stub server, whose gates pin a clock that jumps days between saves).
    struct CoalescingWindow: Equatable, Sendable {
        var opened: TimeInterval
        var updated: TimeInterval
        static let api = CoalescingWindow(opened: 600, updated: 180)
    }

    /// Oldest first.
    private(set) var entries: [Entry] = []
    private(set) var nextSeq = 1
    var idPrefix = "ver-"
    var window: CoalescingWindow?

    init(idPrefix: String = "ver-", window: CoalescingWindow? = nil) {
        self.idPrefix = idPrefix
        self.window = window
    }

    /// Restores a persisted log.
    init(entries: [Entry], nextSeq: Int, idPrefix: String, window: CoalescingWindow?) {
        self.entries = entries
        self.nextSeq = max(nextSeq, (entries.map(\.seq).max() ?? 0) + 1)
        self.idPrefix = idPrefix
        self.window = window
    }

    var head: Entry? { entries.last }

    func entry(_ id: String) -> Entry? { entries.first { $0.id == id } }

    /// Records one save of `document` (revision `revision`, saved `at`).
    /// `previous` is the document before it (nil = the first save). A save
    /// EXTENDS the head when it is the same actor + client id + source, the
    /// head is an unnamed `edit`, no checkpoint was asked for (and, with a
    /// window, the head is young enough); otherwise it opens a new version.
    /// `change` is the save's own change-set (`X-CC-Change`); without one it
    /// is derived from `previous` → `document`.
    @discardableResult
    mutating func record(
        previous: Data?, document: Data, revision: Int, at now: Date,
        actorUID: String, clientKind: String, clientID: String?, source: String,
        change: ChangeSet?, checkpoint: Checkpoint?, mergedFrom: Int?, restoredFrom: String?
    ) -> Entry {
        let derivedChange = change ?? previous.flatMap { prev -> ChangeSet? in
            guard let a = try? JSONValue.parse(data: prev), let b = try? JSONValue.parse(data: document) else { return nil }
            return ProjectDiff.diff(a, b)
        }
        if checkpoint == nil, var head = entries.last, head.kind == "edit", head.label == nil,
           head.actorUID == actorUID, head.clientID == clientID, head.source == source,
           window.map({ now.timeIntervalSince(head.openedAt) < $0.opened && now.timeIntervalSince(head.updatedAt) < $0.updated }) ?? true {
            head.revision = revision
            head.document = document
            head.updatedAt = now
            head.change = head.change.map { prior in derivedChange.map { ProjectDiff.compose(prior, $0) } ?? prior } ?? derivedChange
            head.extended = true
            entries[entries.count - 1] = head
            return head
        }
        let kind: String
        switch checkpoint {
        case .merge: kind = "merge"
        case .restore: kind = "restore"
        case .upload: kind = "upload"
        default: kind = previous == nil ? "upload" : "edit"
        }
        let entry = Entry(
            id: "\(idPrefix)\(nextSeq)", seq: nextSeq, firstRevision: revision, revision: revision,
            document: document, kind: kind, label: nil,
            actorUID: actorUID, clientKind: clientKind, clientID: clientID, source: source,
            change: derivedChange, openedAt: now, updatedAt: now, mergedFrom: mergedFrom, restoredFrom: restoredFrom)
        nextSeq += 1
        entries.append(entry)
        return entry
    }

    /// Sets a version's label as given (nil unnames; callers trim and
    /// validate — the routes' rules).
    mutating func name(_ id: String, _ label: String?) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].label = label
    }

    /// Removes versions (never call it for the head — the routes refuse).
    mutating func remove(_ ids: Set<String>) {
        entries.removeAll { ids.contains($0.id) }
    }
}
