import CryptoKit
import Foundation

// MARK: - The seam

/// What a History pane needs from wherever versions live. The iOS studio
/// has only the on-device `LocalProjectHistory` today; Phase 5 (sync) adds a
/// cloud implementation over `CloudHistoryClient` + `CloudProjectSync`
/// (docs/ios-studio-plan.md) — the pane, preview, restore, compare and merge
/// review stay as they are.
@MainActor
protocol ProjectHistoryService: AnyObject {
    /// "On this iPad" vs a cloud account's history (pane words, footer).
    var isLocal: Bool { get }
    /// Newest first; nil = no history for this project yet.
    func page() async throws -> CloudVersionPage?
    /// A version's project.json, byte-exact.
    func document(versionID: String) async throws -> Data
    /// nil / empty unnames.
    func rename(versionID: String, label: String?) async throws
    func delete(versionID: String) async throws
    /// Restores `versionID` as the NEWEST version (History keeps the
    /// current one) and returns the document the project now holds. Local:
    /// recorded here, applied by the caller (one undo step). Cloud: the
    /// server's restore + a pull.
    func restore(versionID: String) async throws -> Data
}

/// Who this device's saves are attributed to (`actor`, `X-CC-Client`,
/// `X-CC-Client-Id`). `clientID` is an opaque per-install id — never a
/// device or user name (it is a coalescing key, like the Mac's).
nonisolated struct ProjectHistoryIdentity: Equatable, Sendable {
    var actorUID: String
    var actorName: String
    var clientKind: String
    var clientID: String
    var source = "human"
}

nonisolated enum LocalHistoryError: LocalizedError, Equatable {
    case versionNotFound
    case headVersion
    case invalidLabel
    case documentMissing

    var errorDescription: String? {
        switch self {
        case .versionNotFound: return "That version no longer exists."
        case .headVersion: return "The current version can't be deleted."
        case .invalidLabel: return "Version names are up to 100 characters, without control characters."
        case .documentMissing: return "This version's document is no longer stored."
        }
    }
}

// MARK: - On-device history

/// A project's version history kept next to it, in `<project>/.history/`:
/// `index.json` (the log, oldest first) and one byte-exact `<id>.json`
/// snapshot per version. Versions are recorded through the SAME rules as the
/// API (`ProjectVersionLog`, with the API's coalescing windows): every save
/// of the editor extends the head or opens a version; restore and merge are
/// checkpoints. Unnamed versions beyond `maxUnnamed` are pruned oldest first
/// (named ones and the head never are).
///
/// Platform-neutral (Foundation + CryptoKit): the iOS studio uses it now;
/// the Mac's offline / Free local history (docs/project-history.md, owner
/// decision 4) can adopt it as is.
@MainActor
final class LocalProjectHistory: ProjectHistoryService {
    static let directoryName = ".history"
    static let indexName = "index.json"
    static let formatVersion = 1

    let projectDirectory: URL
    var identity: ProjectHistoryIdentity
    /// uid → display name for the rows' avatars (the device's own actor is
    /// always included).
    var displayNames: [String: String]
    var maxUnnamed = 200
    /// When a save happens (the gate pins it to replay a recorded history).
    var clock: () -> Date = { Date() }
    private(set) var log: ProjectVersionLog

    var isLocal: Bool { true }
    var historyDirectory: URL { projectDirectory.appendingPathComponent(Self.directoryName, isDirectory: true) }

    init(projectDirectory: URL, identity: ProjectHistoryIdentity, displayNames: [String: String] = [:],
         window: ProjectVersionLog.CoalescingWindow? = .api, idPrefix: String = "local-") {
        self.projectDirectory = projectDirectory
        self.identity = identity
        var names = displayNames
        names[identity.actorUID] = names[identity.actorUID] ?? identity.actorName
        self.displayNames = names
        log = Self.load(from: projectDirectory.appendingPathComponent(Self.directoryName, isDirectory: true), window: window)
            ?? ProjectVersionLog(idPrefix: idPrefix, window: window)
    }

    var head: ProjectVersionLog.Entry? { log.head }
    var entries: [ProjectVersionLog.Entry] { log.entries }

    // MARK: Recording

    /// Records that the project now holds `document` (the bytes just written
    /// to project.json). Returns nil when it is byte-identical to the head
    /// and no checkpoint was asked for (nothing to keep). `change` is a
    /// save's own change-set when it brought one (an imported history);
    /// otherwise it is derived from the head's document, as the API does.
    @discardableResult
    func record(
        _ document: Data, at date: Date = Date(), change: ChangeSet? = nil, checkpoint: ProjectVersionLog.Checkpoint? = nil,
        restoredFrom: String? = nil, mergedFrom: Int? = nil, as actor: ProjectHistoryIdentity? = nil
    ) -> ProjectVersionLog.Entry? {
        let who = actor ?? identity
        if checkpoint == nil, let head = log.head, head.document == document { return nil }
        let entry = log.record(
            previous: log.head?.document, document: document, revision: (log.head?.revision ?? 0) + 1,
            at: Self.milliseconds(date), actorUID: who.actorUID, clientKind: who.clientKind, clientID: who.clientID,
            source: who.source, change: change, checkpoint: checkpoint, mergedFrom: mergedFrom, restoredFrom: restoredFrom)
        prune()
        persist(writing: entry)
        return entry
    }

    /// Dates kept at the API's millisecond resolution (so a reload, a wire
    /// round trip and the live log agree).
    static func milliseconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded(.down) / 1000)
    }

    private func prune() {
        let headID = log.head?.id
        let unnamed = log.entries.filter { $0.label == nil && $0.id != headID }
        guard unnamed.count > maxUnnamed else { return }
        let doomed = Set(unnamed.prefix(unnamed.count - maxUnnamed).map(\.id))
        log.remove(doomed)
        for id in doomed { try? FileManager.default.removeItem(at: snapshotURL(id)) }
    }

    // MARK: ProjectHistoryService

    func page() async throws -> CloudVersionPage? { currentPage() }

    /// The versions as the API's `V` objects, newest first.
    func currentPage() -> CloudVersionPage? {
        guard !log.entries.isEmpty else { return nil }
        let headID = log.head?.id
        let versions = log.entries.reversed().map { version(of: $0, isHead: $0.id == headID) }
        return CloudVersionPage(
            versions: versions, nextBefore: nil,
            retention: CloudRetention(historyDays: nil, maxNamed: nil, namedCount: log.entries.filter { $0.label != nil }.count),
            pinnedMediaBytes: 0, freeableBytes: 0, headVersionID: headID, isOwner: true)
    }

    /// One entry as the wire's version object — what the API returns for
    /// the same entry (`StubCloudServer.versionJSON` parsed by
    /// `CloudHistoryParse.version`): named by the device's actor, `namedAt`
    /// = its last update.
    func version(of entry: ProjectVersionLog.Entry, isHead: Bool) -> CloudVersion {
        let namer = entry.label == nil ? nil : (displayNames[identity.actorUID] ?? identity.actorUID)
        return CloudVersion(
            id: entry.id, seq: entry.seq, revision: entry.revision, firstRevision: entry.firstRevision,
            kind: entry.kind, label: entry.label, namedBy: namer, namedAt: entry.label == nil ? nil : entry.updatedAt,
            actorUID: entry.actorUID, actorName: displayNames[entry.actorUID], clientKind: entry.clientKind,
            source: entry.source, change: entry.change, documentBytes: Int64(entry.document.count),
            documentSHA256: Self.sha256(entry.document), restoredFrom: entry.restoredFrom,
            mergedFromRevision: entry.mergedFrom, openedAt: entry.openedAt, updatedAt: entry.updatedAt, isHead: isHead)
    }

    func document(versionID: String) async throws -> Data {
        guard let entry = log.entry(versionID) else { throw LocalHistoryError.versionNotFound }
        return entry.document
    }

    func rename(versionID: String, label: String?) async throws {
        guard log.entry(versionID) != nil else { throw LocalHistoryError.versionNotFound }
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmed.count <= 100, !trimmed.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw LocalHistoryError.invalidLabel
        }
        log.name(versionID, trimmed.isEmpty ? nil : trimmed)
        persist(writing: nil)
    }

    func delete(versionID: String) async throws {
        guard log.entry(versionID) != nil else { throw LocalHistoryError.versionNotFound }
        guard log.head?.id != versionID else { throw LocalHistoryError.headVersion }
        log.remove([versionID])
        try? FileManager.default.removeItem(at: snapshotURL(versionID))
        persist(writing: nil)
    }

    func restore(versionID: String) async throws -> Data {
        restoreNow(versionID: versionID)?.document ?? Data()
    }

    /// The synchronous core of `restore`: the version's document becomes a
    /// NEW `restore` version (`restoredFrom` = it). nil = no such version.
    @discardableResult
    func restoreNow(versionID: String, at date: Date? = nil) -> ProjectVersionLog.Entry? {
        guard let old = log.entry(versionID) else { return nil }
        return record(old.document, at: date ?? clock(), checkpoint: .restore, restoredFrom: old.id)
    }

    // MARK: Persistence

    private func snapshotURL(_ id: String) -> URL {
        historyDirectory.appendingPathComponent("\(id).json")
    }

    private func persist(writing entry: ProjectVersionLog.Entry?) {
        let fm = FileManager.default
        try? fm.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        if let entry { try? entry.document.write(to: snapshotURL(entry.id), options: .atomic) }
        let index: [String: Any] = [
            "v": Self.formatVersion,
            "nextSeq": log.nextSeq,
            "idPrefix": log.idPrefix,
            "entries": log.entries.map(Self.json),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: index, options: [.sortedKeys]) else { return }
        try? data.write(to: historyDirectory.appendingPathComponent(Self.indexName), options: .atomic)
    }

    private static func json(_ e: ProjectVersionLog.Entry) -> [String: Any] {
        func orNull(_ value: Any?) -> Any { value ?? NSNull() }
        return [
            "id": e.id, "seq": e.seq, "firstRevision": e.firstRevision, "revision": e.revision,
            "kind": e.kind, "label": orNull(e.label), "actorUID": e.actorUID, "clientKind": e.clientKind,
            "clientID": orNull(e.clientID), "source": e.source,
            "change": orNull(e.change.map { $0.json.canonical }),
            "openedAt": ms(e.openedAt), "updatedAt": ms(e.updatedAt),
            "mergedFrom": orNull(e.mergedFrom), "restoredFrom": orNull(e.restoredFrom), "extended": e.extended,
        ]
    }

    private static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    private static func load(from dir: URL, window: ProjectVersionLog.CoalescingWindow?) -> ProjectVersionLog? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(indexName)),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (object["v"] as? Int) == formatVersion,
              let raw = object["entries"] as? [[String: Any]] else { return nil }
        func date(_ value: Any?) -> Date { Date(timeIntervalSince1970: Double((value as? NSNumber)?.int64Value ?? 0) / 1000) }
        func string(_ value: Any?) -> String? { value as? String }
        var entries: [ProjectVersionLog.Entry] = []
        for item in raw {
            guard let id = item["id"] as? String,
                  let document = try? Data(contentsOf: dir.appendingPathComponent("\(id).json")) else { continue }
            var entry = ProjectVersionLog.Entry(
                id: id, seq: (item["seq"] as? Int) ?? 0, firstRevision: (item["firstRevision"] as? Int) ?? 0,
                revision: (item["revision"] as? Int) ?? 0, document: document, kind: string(item["kind"]) ?? "edit",
                label: string(item["label"]), actorUID: string(item["actorUID"]) ?? "", clientKind: string(item["clientKind"]) ?? "unknown",
                clientID: string(item["clientID"]), source: string(item["source"]) ?? "human",
                change: string(item["change"]).flatMap { try? JSONValue.parse($0) }.flatMap(ProjectDiff.changeSet(from:)),
                openedAt: date(item["openedAt"]), updatedAt: date(item["updatedAt"]),
                mergedFrom: item["mergedFrom"] as? Int, restoredFrom: string(item["restoredFrom"]))
            entry.extended = (item["extended"] as? Bool) ?? false
            entries.append(entry)
        }
        return ProjectVersionLog(entries: entries, nextSeq: (object["nextSeq"] as? Int) ?? 1,
                                 idPrefix: string(object["idPrefix"]) ?? "local-", window: window)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
