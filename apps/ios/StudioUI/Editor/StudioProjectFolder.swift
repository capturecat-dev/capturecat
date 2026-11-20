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
            case .missingDocument: return String(localized: "This folder has no project.json.", comment: "Error opening a project folder; project.json is a file name, don't translate it")
            case .notAnObject: return String(localized: "This project's file is damaged.")
            case .noRecording: return String(localized: "This project's recording isn't in its folder.")
            }
        }
    }

    let directory: URL
    let project: Project
    /// The document as last read or written (unknown keys included).
    private var document: [String: Any]
    /// After every save, with the bytes written (Studio 4f: the on-device
    /// History records them — `StudioHistory.attach`).
    var onDidSave: ((Data) -> Void)?
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
        let resolved = try resolve(data, in: directory)
        guard let video = resolved.project.videoURL, FileManager.default.fileExists(atPath: video.path) else {
            throw OpenError.noRecording
        }
        let folder = StudioProjectFolder(directory: directory, project: resolved.project, document: resolved.document)
        folder.originalMedia = resolved.originalMedia
        folder.originalSettingsPaths = resolved.originalSettingsPaths
        return folder
    }

    /// A document decoded the way `open` decodes it: media re-pointed into
    /// `directory`, with the strings it replaced.
    struct Resolved {
        let project: Project
        let document: [String: Any]
        let originalMedia: [String: String]
        let originalSettingsPaths: [String: String]
    }

    static func resolve(_ data: Data, in directory: URL) throws -> Resolved {
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
        return Resolved(project: project, document: object, originalMedia: originals, originalSettingsPaths: settingsOriginals)
    }

    /// Studio 4f (History restore / merge): makes `data` the project's
    /// document — written to project.json byte for byte (the Mac's pull
    /// writes a restored revision the same way), unknown keys and all — and
    /// returns it decoded, media re-pointed, for the editor's live model to
    /// adopt (`Project.adoptState(of:)`).
    @discardableResult
    func adoptDocument(_ data: Data) throws -> Project {
        let resolved = try Self.resolve(data, in: directory)
        try data.write(to: documentURL, options: .atomic)
        document = resolved.document
        originalMedia = resolved.originalMedia
        originalSettingsPaths = resolved.originalSettingsPaths
        return resolved.project
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
        // Phase 5: the same project in other bytes is not a change — keep
        // the file (a synced document stays byte-identical to the cloud's, so
        // adopting a pulled revision never pushes a re-spelled copy back).
        if let disk = try? Data(contentsOf: documentURL), disk != data,
           let a = try? JSONValue.parse(data: disk), let b = try? JSONValue.parse(data: data), a == b {
            document = merged
            return
        }
        try data.write(to: documentURL, options: .atomic)
        document = merged
        onDidSave?(data)
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
