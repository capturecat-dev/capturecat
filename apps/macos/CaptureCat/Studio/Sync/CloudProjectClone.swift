import Foundation
import os

private let cloneLogger = Logger(subsystem: "so.capturecat.CaptureCat", category: "CloudProjectSync")

// MARK: - Clone ("Continue on Mac")

extension CloudProjectSync {
    enum CloneOutcome: Equatable {
        /// The project now exists on this Mac, agreeing with cloud `revision`.
        case cloned(revision: Int)
        /// No cloud copy this account can read: nothing was created.
        case noCloudCopy
    }

    /// A project that lives only in the cloud — recorded or built in the web
    /// app — becomes a project on this Mac, with everything the cloud holds:
    /// the recording, camera, voice-overs, images and every web edit.
    ///
    /// Same guarantees as `pull`, for a folder that does not exist yet: the
    /// document is proven decodable by this build BEFORE any bytes move;
    /// every file it names is downloaded (verified, atomic) before it; web
    /// references (`file:///CaptureCat/Projects/<id>/…`) are re-pointed at the
    /// downloaded copies; and `project.json` is written LAST, so
    /// `ProjectStore` (which only lists folders holding one) never sees a
    /// half-downloaded project. Any failure removes the folder it created.
    /// The sync sidecar records the revision, so the next push or pull
    /// continues from here like any other synced project.
    func clone(
        projectID: UUID,
        into projectDirectory: URL,
        progress: @escaping (Progress) -> Void = { _ in }
    ) async throws -> CloneOutcome {
        let fm = FileManager.default
        let docURL = projectDirectory.appendingPathComponent("project.json")
        guard !fm.fileExists(atPath: docURL.path) else { throw CloudSyncError.alreadyOnThisMac }

        progress(Progress(phase: .fetching, fraction: 0, message: "Finding your project…"))
        guard let remote = try await transport.fetch(projectID: projectID),
              let document = remote.document else {
            return .noCloudCopy
        }
        try Self.checkedProject(document, projectID: projectID)

        let created = !fm.fileExists(atPath: projectDirectory.path)
        try fm.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        do {
            _ = try await syncMedia(remote.files, referencedBy: document, projectID: projectID,
                                    projectDirectory: projectDirectory, progress: progress)
            progress(Progress(phase: .writing, fraction: 0.5, message: "Opening on this Mac…"))
            let data = try Self.validatedDocument(document, projectID: projectID,
                                                  projectDirectory: projectDirectory, files: remote.files)
            // The recording is the one file a project cannot open without
            // (the web's upload may have failed after its document saved).
            let project = try Self.checkedProject(data, projectID: projectID)
            if let video = project.videoURL, video.isFileURL, !fm.fileExists(atPath: video.path) {
                throw CloudSyncError.downloadFailed(paths: [video.lastPathComponent],
                                                    detail: "the cloud copy has no recording")
            }
            try saveState(revision: remote.revision, base: data, in: projectDirectory, projectID: projectID)
            try ProjectFileIO.writeProjectData(data, to: docURL)
        } catch {
            if created { try? fm.removeItem(at: projectDirectory) }
            throw error
        }
        progress(Progress(phase: .writing, fraction: 1, message: "Ready"))
        cloneLogger.info("cloned cloud revision \(remote.revision) into \(projectID.uuidString, privacy: .public)")
        return .cloned(revision: remote.revision)
    }
}
