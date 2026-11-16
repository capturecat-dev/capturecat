import CryptoKit
import UIKit

/// The companion app's way into the studio editor (Studio 4b): a cloud
/// project is copied into a local studio folder — project.json exactly as the
/// cloud holds it, plus its files — and opened in `EditorViewController`.
/// The studio needs iOS 26 (docs/ios-studio-plan.md, decision 2); the
/// companion stays iOS 18+, so every entry is `#available`-gated.
///
/// Local folders: Application Support/Studio/Projects/<ID>/. Edits save
/// there only — syncing them back is Phase 5 — so a reopen never silently
/// drops them: an untouched local copy refreshes from the cloud; an edited
/// one opens as is, unless the cloud moved on too, in which case the user
/// picks.
enum StudioEditorEntry {
    static var isAvailable: Bool {
        if #available(iOS 26, *) { return true }
        return false
    }

    static func directory(for projectID: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Studio/Projects/\(projectID.uppercased())", isDirectory: true)
    }

    /// What was downloaded last time (to tell local edits from a stale copy).
    private struct Marker: Codable {
        var revision: Int
        var documentSHA256: String
    }

    private static let markerName = ".studio-download.json"

    @available(iOS 26, *)
    @MainActor
    static func open(projectID: String, from presenter: UIViewController) {
        let progress = AppToaster.shared.show(title: "Preparing the editor…", symbol: "film")
        Task { @MainActor in
            do {
                let dir = try await prepareFolder(projectID: projectID, presenter: presenter)
                progress?.dismiss()
                let folder = try StudioProjectFolder.open(dir)
                let editor = EditorViewController(folder: folder)
                CCAlert.topmost(from: presenter).present(editor, animated: true)
            } catch is CancellationError {
                progress?.dismiss()
            } catch {
                progress?.dismiss()
                AppToaster.shared.show(title: "Couldn't open the editor", message: error.localizedDescription,
                                       variant: .destructive)
            }
        }
    }

    /// Downloads (or reuses) the local folder for `projectID`.
    @MainActor
    private static func prepareFolder(projectID: String, presenter: UIViewController) async throws -> URL {
        let fm = FileManager.default
        let dir = directory(for: projectID)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let detail = try await LibraryStore.shared.detail(for: projectID, fresh: true)
        guard let document = detail.document, let documentData = document.data(using: .utf8) else {
            throw StudioProjectFolder.OpenError.missingDocument
        }
        let documentURL = dir.appendingPathComponent(StudioProjectFolder.documentName)
        let markerURL = dir.appendingPathComponent(markerName)
        let marker = (try? Data(contentsOf: markerURL)).flatMap { try? JSONDecoder().decode(Marker.self, from: $0) }

        var useCloudDocument = true
        if let marker, let local = try? Data(contentsOf: documentURL), sha256(local) != marker.documentSHA256 {
            // Edited here since the download.
            if marker.revision == detail.revision {
                useCloudDocument = false
            } else {
                useCloudDocument = try await askCloudOrLocal(from: presenter)
            }
        }

        // Media: every committed file, skipped when the same size is already here.
        for file in detail.files {
            let target = dir.appendingPathComponent(file.path)
            if let size = (try? fm.attributesOfItem(atPath: target.path))?[.size] as? Int64, size == file.bytes { continue }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let (temp, response) = try await URLSession.shared.download(from: file.url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            try? fm.removeItem(at: target)
            try fm.moveItem(at: temp, to: target)
        }

        if useCloudDocument {
            try documentData.write(to: documentURL, options: .atomic)
            let fresh = Marker(revision: detail.revision, documentSHA256: sha256(documentData))
            try JSONEncoder().encode(fresh).write(to: markerURL, options: .atomic)
        }
        return dir
    }

    /// The cloud copy changed AND this device has unsynced edits.
    @MainActor
    private static func askCloudOrLocal(from presenter: UIViewController) async throws -> Bool {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            let alert = CCAlert(
                title: "This project changed elsewhere",
                message: "You have edits on this \(ThisDevice.noun) that aren't synced yet. Open them, or start again from the latest version?")
            alert.addButton("Open my edits", role: .primary)
            alert.addButton("Use the latest version", role: .destructive)
            alert.addButton("Cancel", role: .cancel)
            alert.present(from: presenter) { index in
                switch index {
                case 0: continuation.resume(returning: false)
                case 1: continuation.resume(returning: true)
                default: continuation.resume(throwing: CancellationError())
                }
            }
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
