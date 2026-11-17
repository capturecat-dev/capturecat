import Foundation

/// Phase 5c: a capture made on this device (an inbox take) becomes a studio
/// project folder — its media copied in (an APFS clone: no second copy on
/// disk) and the project.json its upload would have published, written LAST
/// so a half-made folder never opens. The studio's sync then uploads it as
/// the cloud project on its first push (checkpoint `upload`), exactly like
/// the Mac's first push of a recording.
nonisolated enum StudioInboxImport {
    enum ImportError: LocalizedError {
        case alreadyAProject
        case missingMedia(String)
        var errorDescription: String? {
            switch self {
            case .alreadyAProject: return "This capture is already a project on this device."
            case .missingMedia(let name): return "The capture's file (\(name)) is missing."
            }
        }
    }

    /// `media`: (file now, name inside the project). Any failure removes the
    /// folder it created.
    static func makeProject(in directory: URL, document: Data, media: [(source: URL, name: String)]) throws {
        let fm = FileManager.default
        let documentURL = directory.appendingPathComponent("project.json")
        guard !fm.fileExists(atPath: documentURL.path) else { throw ImportError.alreadyAProject }
        let created = !fm.fileExists(atPath: directory.path)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            for item in media {
                guard fm.fileExists(atPath: item.source.path) else { throw ImportError.missingMedia(item.name) }
                let target = directory.appendingPathComponent(item.name)
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.copyItem(at: item.source, to: target)
            }
            try document.write(to: documentURL, options: .atomic)
        } catch {
            if created { try? fm.removeItem(at: directory) }
            throw error
        }
    }
}
