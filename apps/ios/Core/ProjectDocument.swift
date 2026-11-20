import Foundation

/// project.json for projects made on the phone, and surgical edits to
/// existing ones. Never a model of its own — see `LosslessJSON`.
nonisolated enum ProjectDocument {
    /// The id/ref placeholder inside ProjectTemplate.json.
    static let templateID = "00000000-0000-0000-0000-000000000000"

    enum DocumentError: LocalizedError {
        case templateMissing
        case notAnObject

        var errorDescription: String? {
            switch self {
            case .templateMissing: return String(localized: "This copy of CaptureCat is missing its project template. Reinstall the app.")
            case .notAnObject: return String(localized: "This project's file is damaged.")
            }
        }
    }

    /// ProjectTemplate.json — generated from the web model's `newProject()`
    /// (apps/web/src/editor/core/vectors/iosProjectTemplate.test.ts locks it).
    static func template() throws -> LosslessJSON {
        guard let url = Bundle.main.url(forResource: "ProjectTemplate", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { throw DocumentError.templateMissing }
        return try LosslessJSON.parse(data)
    }

    /// `file:///CaptureCat/Projects/<UUID>/<name>` — the Mac-shaped reference
    /// the web recorder writes too; the Mac re-bases it onto its own project
    /// folder by file name when it clones the project.
    static func mediaRef(projectID: String, fileName: String) -> String {
        let encoded = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName
        return "file:///CaptureCat/Projects/\(projectID.uppercased())/\(encoded)"
    }

    struct NewProject: Sendable {
        var id: String
        var name: String
        var createdAt: Date
        /// File name inside the project (e.g. "recording.mp4").
        var videoFileName: String
        var duration: Double
        /// "device" draws the iPhone bezel on the Mac and web; "display" doesn't.
        var sourceKind: String
        var isStillCapture: Bool
        var showDeviceFrame: Bool
    }

    /// A new project.json from the template — what the Mac's
    /// `Project(videoURL:duration:recordingSourceKind:)` would write.
    static func make(_ p: NewProject) throws -> Data {
        var doc = try template()
        doc["id"] = .string(p.id.uppercased())
        doc["name"] = .string(p.name)
        // Swift's Date encodes as seconds since 2001-01-01 (JSONEncoder default).
        doc["createdAt"] = .number(p.createdAt.timeIntervalSinceReferenceDate)
        doc["videoURL"] = .string(mediaRef(projectID: p.id, fileName: p.videoFileName))
        doc["duration"] = .number(p.duration)
        doc["recordingSourceKind"] = .string(p.sourceKind)
        doc["isStillCapture"] = .bool(p.isStillCapture)
        if var settings = doc["settings"] {
            settings["showDeviceFrame"] = .bool(p.showDeviceFrame)
            settings["showCamera"] = .bool(false)
            doc["settings"] = settings
        }
        return doc.serialized()
    }

    /// The same document with only `name` changed.
    static func renamed(_ document: Data, to name: String) throws -> Data {
        var doc = try LosslessJSON.parse(document)
        guard case .object = doc else { throw DocumentError.notAnObject }
        doc["name"] = .string(name)
        return doc.serialized()
    }

    /// What the library shows about a project, read without a model.
    struct Facts: Sendable, Equatable {
        var name: String?
        var duration: Double?
        var trimStart: Double
        var trimEnd: Double
        var sourceKind: String?
        var isStillCapture: Bool
        var hasCamera: Bool
        /// Relative file name of the main recording inside the project.
        var videoFileName: String?

        /// Output length before speed regions (good enough for a badge).
        var trimmedDuration: Double? {
            guard let duration else { return nil }
            let end = trimEnd > 0 ? min(trimEnd, duration) : duration
            return max(0, end - trimStart)
        }
    }

    static func facts(_ document: Data) -> Facts? {
        guard let doc = try? LosslessJSON.parse(document) else { return nil }
        let video = doc["videoURL"]?.stringValue.flatMap { URL(string: $0)?.lastPathComponent }
        return Facts(
            name: doc["name"]?.stringValue,
            duration: doc["duration"]?.doubleValue,
            trimStart: doc["trimStart"]?.doubleValue ?? 0,
            trimEnd: doc["trimEnd"]?.doubleValue ?? 0,
            sourceKind: doc["recordingSourceKind"]?.stringValue,
            isStillCapture: doc["isStillCapture"]?.boolValue ?? false,
            hasCamera: doc["cameraVideoURL"]?.stringValue != nil,
            videoFileName: video?.removingPercentEncoding ?? video
        )
    }
}
