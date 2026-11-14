import Foundation

/// A capture waiting to become a cloud project. The broadcast extension and
/// the share extension can only write files; the app (or the share extension
/// itself, when it can finish in time) publishes them. Each take is a folder
/// in the App Group: `Inbox/<ID>/take.json` + its media.
nonisolated struct PendingTake: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable {
        case screenRecording
        case screenshot
        case importedVideo
    }

    enum State: String, Codable, Sendable {
        /// Still being written (a broadcast in progress).
        case recording
        case pending
        case uploading
        case failed
    }

    /// Also the cloud project id (uppercase UUID).
    var id: String
    var kind: Kind
    var name: String
    var createdAt: Date
    /// Media file name inside the take folder ("recording.mp4").
    var mediaFile: String
    var contentType: String
    var duration: Double
    var pixelWidth: Int
    var pixelHeight: Int
    var state: State
    var error: String?

    /// "device" when the frame is iPhone-shaped (the Mac and web draw the
    /// bezel), "display" otherwise (iPad, or an imported landscape video).
    var sourceKind: String { Self.sourceKind(width: pixelWidth, height: pixelHeight) }

    static func sourceKind(width: Int, height: Int) -> String {
        guard width > 0, height > 0 else { return "display" }
        let long = Double(max(width, height)), short = Double(min(width, height))
        return long / short >= 1.9 ? "device" : "display"
    }
}

nonisolated enum TakeInbox {
    static var root: URL { AppGroup.directory("Inbox") }

    static func folder(for id: String) -> URL {
        root.appendingPathComponent(id.uppercased(), isDirectory: true)
    }

    /// Create the folder for a new take and return it (media goes inside).
    static func makeFolder(id: String) throws -> URL {
        let url = folder(for: id)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func save(_ take: PendingTake) throws {
        let url = try makeFolder(id: take.id).appendingPathComponent("take.json")
        try JSONEncoder.iso.encode(take).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func load(id: String) -> PendingTake? {
        let url = folder(for: id).appendingPathComponent("take.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.iso.decode(PendingTake.self, from: data)
    }

    /// Every take, newest first.
    static func all() -> [PendingTake] {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return ids.compactMap(load(id:)).sorted { $0.createdAt > $1.createdAt }
    }

    static func mediaURL(of take: PendingTake) -> URL {
        folder(for: take.id).appendingPathComponent(take.mediaFile)
    }

    static func update(_ id: String, _ change: (inout PendingTake) -> Void) {
        guard var take = load(id: id) else { return }
        change(&take)
        try? save(take)
    }

    static func remove(_ id: String) {
        try? FileManager.default.removeItem(at: folder(for: id))
    }

    /// Publish one take as a cloud project; removes it from the inbox on success.
    static func publish(
        _ take: PendingTake,
        api: APIClient = .shared,
        progress: @escaping @Sendable (PublishProgress) -> Void = { _ in }
    ) async throws {
        update(take.id) { $0.state = .uploading; $0.error = nil }
        do {
            let isPhone = take.sourceKind == "device"
            let document = try ProjectDocument.make(ProjectDocument.NewProject(
                id: take.id,
                name: take.name,
                createdAt: take.createdAt,
                videoFileName: take.mediaFile,
                duration: take.duration,
                sourceKind: take.sourceKind,
                isStillCapture: take.kind == .screenshot,
                showDeviceFrame: isPhone
            ))
            let file = LocalProjectFile(path: take.mediaFile, url: mediaURL(of: take), contentType: take.contentType)
            _ = try await CloudUploader.publish(projectID: take.id, name: take.name, files: [file], document: document, api: api, progress: progress)
            remove(take.id)
        } catch {
            update(take.id) { $0.state = .failed; $0.error = error.localizedDescription }
            throw error
        }
    }
}
