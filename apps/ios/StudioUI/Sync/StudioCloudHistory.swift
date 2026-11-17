import Foundation

/// History over the CLOUD's versions (Phase 5) — the `ProjectHistoryService`
/// 4f left as the cloud seam, built on the Mac's `CloudHistoryClient`: the
/// same list, names, deletes, version documents and restore (the server's
/// restore as a new head, then a pull) the Mac's History pane uses.
///
/// Offline (or before the project's first upload) it lists the on-device
/// history instead (`LocalProjectHistory`, which keeps recording every save
/// either way) — the panel's footer says which it shows. Version ids tell the
/// two apart (the on-device log's start `local-`).
@available(iOS 26, *)
@MainActor
final class StudioCloudHistory: ProjectHistoryService {
    private weak var sync: StudioCloudSync?
    /// The last page came from the device, not the cloud.
    private(set) var servedLocally = false

    init(sync: StudioCloudSync) {
        self.sync = sync
    }

    var isLocal: Bool { servedLocally }

    enum HistoryError: LocalizedError {
        case unavailable
        case needsSync
        var errorDescription: String? {
            switch self {
            case .unavailable: return "History isn't available for this project right now."
            case .needsSync:
                return "This project has changes that couldn't be synced first. Sync, then restore."
            }
        }
    }

    private var local: LocalProjectHistory? {
        guard let sync else { return nil }
        return StudioHistory.store(for: sync.directory)
    }

    private static func isLocalID(_ id: String) -> Bool { id.hasPrefix("local-") }

    func page() async throws -> CloudVersionPage? {
        guard let sync else { throw HistoryError.unavailable }
        do {
            if let page = try await sync.history.page(projectID: sync.projectID) {
                servedLocally = false
                return page
            }
        } catch where StudioCloudSync.isOffline(error) || (error as? CloudSyncError) == .notSignedIn {
            StudioCloudSync.trace?("history: offline → the on-device versions")
        }
        servedLocally = true
        return local?.currentPage()
    }

    func document(versionID: String) async throws -> Data {
        if Self.isLocalID(versionID), let local { return try await local.document(versionID: versionID) }
        guard let sync else { throw HistoryError.unavailable }
        return try await sync.history.detail(projectID: sync.projectID, versionID: versionID).document
    }

    func rename(versionID: String, label: String?) async throws {
        if Self.isLocalID(versionID), let local { return try await local.rename(versionID: versionID, label: label) }
        guard let sync else { throw HistoryError.unavailable }
        _ = try await sync.history.rename(projectID: sync.projectID, versionID: versionID, label: label)
    }

    func delete(versionID: String) async throws {
        if Self.isLocalID(versionID), let local { return try await local.delete(versionID: versionID) }
        guard let sync else { throw HistoryError.unavailable }
        try await sync.history.delete(projectID: sync.projectID, versionID: versionID)
    }

    /// The Mac's restore: unsent edits are pushed first (so they are in
    /// History too), the server restores the version as a NEW head, and the
    /// restored revision (with the media it pins) is pulled here. Returns the
    /// document the project now holds; the panel applies it as one undo step.
    func restore(versionID: String) async throws -> Data {
        if Self.isLocalID(versionID), let local { return try await local.restore(versionID: versionID) }
        guard let sync else { throw HistoryError.unavailable }
        let project: Project
        if let live = sync.editor?.project { project = live } else { project = try StudioProjectFolder.open(sync.directory).project }
        let outcome = try await sync.exclusive { [sync] in
            try await sync.history.restore(versionID: versionID, project: project, projectDirectory: sync.directory)
        }
        StudioCloudSync.trace?("history restore → \(outcome)")
        sync.refreshStatus()
        guard case .restored = outcome else { throw HistoryError.needsSync }
        return try Data(contentsOf: sync.documentURL)
    }
}
