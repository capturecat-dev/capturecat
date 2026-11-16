import Foundation

/// A local studio project: a folder holding `project.json` and its media
/// (docs/ios-studio-plan.md, "Storage"). Opening decodes the Mac's own
/// `Project` model (Studio/Models) from the document; saving merges the model
/// back ONTO the document, so keys this build does not know survive.
///
/// Media references: project.json stores absolute file URLs (the Mac's
/// project folder, or the web's `file:///CaptureCat/Projects/<id>/<name>`),
/// and an iOS container path changes on every reinstall. Opening re-points
/// each one to `<folder>/<lastPathComponent>` when that file is in the
/// folder — the Mac's clone rule (`CloudProjectSync`, same four keys and the
/// two settings image paths). Saving writes the ORIGINAL strings back for
/// re-pointed keys, so a save never stamps this device's paths into the
/// document.
@MainActor
final class StudioProjectFolder {
    static let documentName = "project.json"

    enum OpenError: LocalizedError {
        case missingDocument
        case notAnObject
        case noRecording

        var errorDescription: String? {
            switch self {
            case .missingDocument: return "This folder has no project.json."
            case .notAnObject: return "This project's file is damaged."
            case .noRecording: return "This project's recording isn't in its folder."
            }
        }
    }

    let directory: URL
    let project: Project
    /// The document as last read or written (unknown keys included).
    private var document: [String: Any]
    /// Top-level media keys re-pointed on open → the string the document had.
    private var originalMedia: [String: String] = [:]
    /// Settings image paths re-pointed on open → the document's path.
    private var originalSettingsPaths: [String: String] = [:]

    static let mediaKeys = ["videoURL", "cursorDataURL", "keystrokeDataURL", "cameraVideoURL"]
    static let settingsPathKeys = ["backgroundImagePath", "cameraCardImagePath"]

    private init(directory: URL, project: Project, document: [String: Any]) {
        self.directory = directory
        self.project = project
        self.document = document
    }

    var documentURL: URL { directory.appendingPathComponent(Self.documentName) }

    /// Opens `directory` (project.json + media).
    static func open(_ directory: URL) throws -> StudioProjectFolder {
        let url = directory.appendingPathComponent(documentName)
        guard let data = try? Data(contentsOf: url) else { throw OpenError.missingDocument }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenError.notAnObject
        }
        var resolved = object
        var originals: [String: String] = [:]
        var settingsOriginals: [String: String] = [:]
        let fm = FileManager.default
        for key in mediaKeys {
            guard let raw = object[key] as? String, let ref = URL(string: raw), ref.isFileURL else { continue }
            let local = directory.appendingPathComponent(ref.lastPathComponent)
            if ref.standardizedFileURL.path != local.standardizedFileURL.path, fm.fileExists(atPath: local.path) {
                resolved[key] = local.absoluteString
                originals[key] = raw
            }
        }
        if var settings = object["settings"] as? [String: Any] {
            for key in settingsPathKeys {
                guard let path = settings[key] as? String, !path.isEmpty else { continue }
                let local = directory.appendingPathComponent((path as NSString).lastPathComponent)
                if path != local.path, !fm.fileExists(atPath: path), fm.fileExists(atPath: local.path) {
                    settings[key] = local.path
                    settingsOriginals[key] = path
                }
            }
            resolved["settings"] = settings
        }
        let resolvedData = try JSONSerialization.data(withJSONObject: resolved)
        let project = try JSONDecoder().decode(Project.self, from: resolvedData)
        guard let video = project.videoURL, fm.fileExists(atPath: video.path) else { throw OpenError.noRecording }
        let folder = StudioProjectFolder(directory: directory, project: project, document: object)
        folder.originalMedia = originals
        folder.originalSettingsPaths = settingsOriginals
        return folder
    }

    /// The model merged onto the document (see the type comment), as written
    /// by `save()`.
    func mergedDocument() throws -> [String: Any] {
        let encoded = try JSONEncoder().encode(project)
        guard let model = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw OpenError.notAnObject
        }
        var merged = Self.merge(model, onto: document)
        for (key, raw) in originalMedia {
            let local = directory.appendingPathComponent(URL(string: raw)?.lastPathComponent ?? "")
            if merged[key] as? String == local.absoluteString { merged[key] = raw }
        }
        if var settings = merged["settings"] as? [String: Any] {
            for (key, path) in originalSettingsPaths {
                let local = directory.appendingPathComponent((path as NSString).lastPathComponent)
                if settings[key] as? String == local.path { settings[key] = path }
            }
            merged["settings"] = settings
        }
        return merged
    }

    /// Writes the project back to project.json (atomically).
    func save() throws {
        let merged = try mergedDocument()
        let data = try JSONSerialization.data(
            withJSONObject: merged, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: documentURL, options: .atomic)
        document = merged
    }

    /// The model's keys replace the document's; objects merge recursively,
    /// so a key only the document has (written by a newer build) survives.
    /// Arrays are the model's (their elements carry ids the model owns).
    static func merge(_ model: [String: Any], onto document: [String: Any]) -> [String: Any] {
        var out = document
        for (key, value) in model {
            if let child = value as? [String: Any], let existing = document[key] as? [String: Any] {
                out[key] = merge(child, onto: existing)
            } else {
                out[key] = value
            }
        }
        return out
    }
}
