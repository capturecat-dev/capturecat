import Foundation
import Observation

/// Library-level organization of projects — folders, pins, and shared marks.
/// Lives OUTSIDE the per-project `project.json` files (organizing a project
/// must never rewrite the project itself) in a single
/// `CaptureCat/library.json`. Fields decode with defaults so an old file
/// always loads after new fields appear.
struct LibraryFolder: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var projectIDs: [UUID]

    init(id: UUID = UUID(), name: String, projectIDs: [UUID] = []) {
        self.id = id
        self.name = name
        self.projectIDs = projectIDs
    }
}

@Observable
final class ProjectLibrary {
    private(set) var folders: [LibraryFolder] = []
    private(set) var pinnedIDs: Set<UUID> = []
    /// projectID → share URL, recorded when a share upload completes.
    private(set) var sharedURLs: [UUID: String] = [:]
    /// projectID → remote videoId, so a re-share can REPLACE the cloud video
    /// in place (same link, new version) instead of minting a new link.
    private(set) var sharedVideoIDs: [UUID: String] = [:]

    private let fm = FileManager.default

    private var fileURL: URL {
        fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CaptureCat/library.json")
    }

    private struct Payload: Codable {
        var folders: [LibraryFolder]?
        var pinnedIDs: [UUID]?
        var sharedURLs: [String: String]?
        var sharedVideoIDs: [String: String]?
    }

    init() {
        load()
    }

    // MARK: - Queries

    func isPinned(_ id: UUID) -> Bool { pinnedIDs.contains(id) }
    func isShared(_ id: UUID) -> Bool { sharedURLs[id] != nil }
    func folder(containing id: UUID) -> LibraryFolder? {
        folders.first { $0.projectIDs.contains(id) }
    }

    // MARK: - Mutations (all persist immediately)

    @discardableResult
    func createFolder(named name: String) -> LibraryFolder {
        let folder = LibraryFolder(name: name)
        folders.append(folder)
        save()
        return folder
    }

    func renameFolder(_ id: UUID, to name: String) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].name = name
        save()
    }

    /// Deleting a folder never deletes projects — they fall back to All Captures.
    func deleteFolder(_ id: UUID) {
        folders.removeAll { $0.id == id }
        save()
    }

    /// A project lives in at most one folder — adding moves it.
    func add(_ projectID: UUID, toFolder folderID: UUID) {
        for index in folders.indices {
            folders[index].projectIDs.removeAll { $0 == projectID }
        }
        guard let index = folders.firstIndex(where: { $0.id == folderID }) else { return }
        folders[index].projectIDs.append(projectID)
        save()
    }

    func removeFromFolder(_ projectID: UUID) {
        for index in folders.indices {
            folders[index].projectIDs.removeAll { $0 == projectID }
        }
        save()
    }

    func togglePin(_ projectID: UUID) {
        if pinnedIDs.contains(projectID) {
            pinnedIDs.remove(projectID)
        } else {
            pinnedIDs.insert(projectID)
        }
        save()
    }

    func markShared(_ projectID: UUID, url: String, videoID: String? = nil) {
        sharedURLs[projectID] = url
        if let videoID { sharedVideoIDs[projectID] = videoID }
        save()
    }

    /// The remote videoId a re-share should replace. Older library files only
    /// recorded the URL — fall back to its `/share/{id}` tail so those
    /// projects replace-in-place too.
    func sharedVideoID(for projectID: UUID) -> String? {
        if let id = sharedVideoIDs[projectID] { return id }
        guard let url = sharedURLs[projectID],
              let tail = url.split(separator: "/").last,
              url.contains("/share/") else { return nil }
        let id = String(tail)
        // Remote ids are 10-char [a-z0-9] (see api lib/id.ts) — anything else
        // means an unexpected URL shape, so mint a fresh share instead.
        guard id.count == 10, id.allSatisfy({ $0.isLowercase || $0.isNumber }) else { return nil }
        return id
    }

    /// Called when a project is deleted — drop every reference to it.
    func forget(_ projectID: UUID) {
        for index in folders.indices {
            folders[index].projectIDs.removeAll { $0 == projectID }
        }
        pinnedIDs.remove(projectID)
        sharedURLs.removeValue(forKey: projectID)
        sharedVideoIDs.removeValue(forKey: projectID)
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        folders = payload.folders ?? []
        pinnedIDs = Set(payload.pinnedIDs ?? [])
        sharedURLs = (payload.sharedURLs ?? [:]).reduce(into: [:]) { result, entry in
            if let id = UUID(uuidString: entry.key) { result[id] = entry.value }
        }
        sharedVideoIDs = (payload.sharedVideoIDs ?? [:]).reduce(into: [:]) { result, entry in
            if let id = UUID(uuidString: entry.key) { result[id] = entry.value }
        }
    }

    private func save() {
        let payload = Payload(
            folders: folders,
            pinnedIDs: Array(pinnedIDs),
            sharedURLs: sharedURLs.reduce(into: [:]) { $0[$1.key.uuidString] = $1.value },
            sharedVideoIDs: sharedVideoIDs.reduce(into: [:]) { $0[$1.key.uuidString] = $1.value }
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? fm.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".library.json.tmp-\(getpid())")
        try? data.write(to: tmp)
        _ = try? fm.replaceItemAt(fileURL, withItemAt: tmp)
    }
}
