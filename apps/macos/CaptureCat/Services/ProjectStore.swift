import Foundation
import AVFoundation
import AppKit
import os

private let logger = Logger(subsystem: "so.capturecat.CaptureCat", category: "ProjectStore")

@Observable
final class ProjectStore {
    private(set) var projects: [Project] = []

    private let fm = FileManager.default
    private var autoSaveTask: Task<Void, Never>?

    private var projectsRoot: URL {
        fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CaptureCat/Projects", isDirectory: true)
    }

    private var recordingsRoot: URL {
        fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CaptureCat/Recordings", isDirectory: true)
    }

    init() {
        try? fm.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
        // Only the GUI instance may adopt orphaned recordings. A headless
        // `--mcp`/`--export` process constructs a ProjectStore too, and one
        // spawned mid-recording would see the GUI's in-progress .mov in
        // Recordings and "migrate" it away — the finished take then saved with
        // no video. (This shipped: a stop_recording MCP call stole the very
        // take it was stopping.)
        if !MCPServer.isMCP && !HeadlessRunner.isHeadless {
            migrateOldProjects()
        }
        loadAll()
    }

    // MARK: - Load

    func loadAll() {
        guard let contents = try? fm.contentsOfDirectory(
            at: projectsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else {
            projects = []
            return
        }

        let decoder = JSONDecoder()
        var loaded: [Project] = []

        for dir in contents {
            let jsonURL = dir.appendingPathComponent("project.json")
            guard let data = try? Data(contentsOf: jsonURL),
                  let project = try? decoder.decode(Project.self, from: data) else {
                continue
            }
            project.diskModificationDate = Self.modificationDate(of: jsonURL)
            loaded.append(project)
        }

        projects = loaded.sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Save

    func save(_ project: Project) {
        let dir = project.projectDirectory
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(project) else { return }
        let jsonURL = dir.appendingPathComponent("project.json")
        try? data.write(to: jsonURL, options: .atomic)
        project.hasUnsavedChanges = false
        project.diskModificationDate = Self.modificationDate(of: jsonURL)

        // Update in-memory list
        if let idx = projects.firstIndex(where: { $0.id == project.id }) {
            projects[idx] = project
        } else {
            projects.insert(project, at: 0)
        }
    }

    /// Close/quit-path save: writes only when the project actually has unsaved
    /// in-memory changes. An unconditional save here is exactly how a stale
    /// in-memory copy used to clobber a `CaptureCat --mcp` process's disk edit.
    func saveIfDirty(_ project: Project) {
        guard project.hasUnsavedChanges else { return }
        save(project)
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    // MARK: - Delete

    func delete(_ project: Project) {
        // A deleted capture must never fire its reminder.
        let id = project.id
        Task { @MainActor in ReminderCenter.shared.cancelReminder(for: id) }
        try? fm.removeItem(at: project.projectDirectory)
        projects.removeAll { $0.id == project.id }
    }

    // MARK: - Rename

    func rename(_ project: Project, to newName: String) {
        project.name = newName
        save(project)
    }

    // MARK: - Duplicate

    func duplicate(_ project: Project) {
        let newID = UUID()
        let newDir = projectsRoot.appendingPathComponent(newID.uuidString, isDirectory: true)

        guard let _ = try? fm.copyItem(at: project.projectDirectory, to: newDir) else { return }

        // Load the copied project.json and update it
        let jsonURL = newDir.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: jsonURL),
              var copy = try? JSONDecoder().decode(Project.self, from: data) else {
            try? fm.removeItem(at: newDir)
            return
        }

        // We need a mutable copy with the new ID — re-create it
        let dup = Project(
            id: newID,
            name: "\(project.name) Copy",
            videoURL: copy.videoURL.map { _ in newDir.appendingPathComponent("recording.mov") },
            cursorDataURL: copy.cursorDataURL.map { _ in newDir.appendingPathComponent("cursor.json") },
            cameraVideoURL: copy.cameraVideoURL.map { _ in newDir.appendingPathComponent("camera.mov") },
            cameraTimeOffset: copy.cameraTimeOffset,
            duration: copy.duration,
            recordingSourceKind: copy.recordingSourceKind
        )
        dup.createdAt = copy.createdAt
        dup.settings = copy.settings
        dup.zoomRegions = copy.zoomRegions
        dup.blurRegions = copy.blurRegions
        dup.highlightRegions = copy.highlightRegions
        dup.voiceOverClips = copy.voiceOverClips
        dup.subtitles = copy.subtitles
        dup.annotations = copy.annotations
        dup.speedRegions = copy.speedRegions
        dup.splitPoints = copy.splitPoints
        dup.videoClipSegments = copy.videoClipSegments
        dup.trimStart = copy.trimStart
        dup.trimEnd = copy.trimEnd
        dup.sourceSegments = copy.sourceSegments

        save(dup)
    }

    // MARK: - Thumbnail

    func generateThumbnail(for project: Project) {
        guard let videoURL = project.videoURL else { return }

        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)

        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else { return }

        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let jpegData = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { return }

        let thumbURL = project.projectDirectory.appendingPathComponent("thumbnail.jpg")
        try? jpegData.write(to: thumbURL, options: .atomic)
    }

    // MARK: - Move media into project folder

    func moveMediaIntoProjectFolder(_ project: Project) {
        let dir = project.projectDirectory
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        if let videoURL = project.videoURL, videoURL.deletingLastPathComponent() != dir {
            let dest = dir.appendingPathComponent("recording.mov")
            if (try? fm.moveItem(at: videoURL, to: dest)) != nil {
                project.videoURL = dest
            }
        }

        if let cursorURL = project.cursorDataURL, cursorURL.deletingLastPathComponent() != dir {
            let dest = dir.appendingPathComponent("cursor.json")
            if (try? fm.moveItem(at: cursorURL, to: dest)) != nil {
                project.cursorDataURL = dest
            }
        }

        if let keysURL = project.keystrokeDataURL, keysURL.deletingLastPathComponent() != dir {
            let dest = dir.appendingPathComponent("keys.json")
            if (try? fm.moveItem(at: keysURL, to: dest)) != nil {
                project.keystrokeDataURL = dest
            }
        }

        if let originalCameraURL = project.cameraVideoURL, originalCameraURL.deletingLastPathComponent() != dir {
            let dest = dir.appendingPathComponent("camera.mov")
            if (try? fm.moveItem(at: originalCameraURL, to: dest)) != nil {
                project.cameraVideoURL = dest
            }

            let sourcePosterURL = originalCameraURL.deletingPathExtension().appendingPathExtension("png")
            let destPosterURL = dir.appendingPathComponent("camera_poster.png")
            if fm.fileExists(atPath: sourcePosterURL.path) {
                try? fm.removeItem(at: destPosterURL)
                try? fm.moveItem(at: sourcePosterURL, to: destPosterURL)
            }
        }
    }

    // MARK: - Migration

    private func migrateOldProjects() {
        guard fm.fileExists(atPath: recordingsRoot.path) else { return }

        guard let files = try? fm.contentsOfDirectory(
            at: recordingsRoot,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return }

        // Find .mov files that look like recordings. A file whose mtime is
        // fresh is an ACTIVE recording being written by another instance —
        // adopting it would rip the file out from under the writer.
        let recordings = files.filter { url in
            guard url.pathExtension == "mov",
                  url.lastPathComponent.hasPrefix("capturecat_recording_") else { return false }
            let mtime = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            return (mtime.map { Date().timeIntervalSince($0) } ?? .infinity) > 120
        }

        for videoURL in recordings {
            // Check if a project already exists for this video
            let alreadyMigrated = projects.contains { $0.videoURL == videoURL }
            if alreadyMigrated { continue }

            // Look for companion cursor JSON
            let cursorURL = videoURL.deletingPathExtension().appendingPathExtension("cursor.json")
            let hasCursor = fm.fileExists(atPath: cursorURL.path)

            // Look for companion camera file (same UUID)
            let videoName = videoURL.deletingPathExtension().lastPathComponent
            let uuid = videoName.replacingOccurrences(of: "capturecat_recording_", with: "")
            let cameraURL = recordingsRoot.appendingPathComponent("capturecat_camera_\(uuid).mov")
            let hasCamera = fm.fileExists(atPath: cameraURL.path)
            let cameraPosterURL = recordingsRoot.appendingPathComponent("capturecat_camera_\(uuid).png")

            // Get video duration synchronously via AVAssetReader
            let asset = AVURLAsset(url: videoURL)
            var duration: TimeInterval = 0
            if let track = asset.tracks(withMediaType: .video).first {
                duration = track.timeRange.duration.seconds
            }

            let project = Project(
                videoURL: videoURL,
                cursorDataURL: hasCursor ? cursorURL : nil,
                cameraVideoURL: hasCamera ? cameraURL : nil,
                duration: duration
            )

            moveMediaIntoProjectFolder(project)
            if hasCamera, fm.fileExists(atPath: cameraPosterURL.path) {
                let destPosterURL = project.projectDirectory.appendingPathComponent("camera_poster.png")
                try? fm.removeItem(at: destPosterURL)
                try? fm.moveItem(at: cameraPosterURL, to: destPosterURL)
            }
            save(project)
            generateThumbnail(for: project)

            logger.info("Migrated old recording to project: \(project.id)")
        }
    }

    // MARK: - Auto-save

    func scheduleAutoSave(for project: Project) {
        // Mark dirty immediately — a close before the debounce fires must
        // still know there is something to write (saveIfDirty).
        project.hasUnsavedChanges = true
        autoSaveTask?.cancel()
        autoSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            save(project)
        }
    }

    // MARK: - External edits (CaptureCat --mcp)

    /// Fired (GUI instance only) when a project.json changed on disk under us —
    /// an MCP tool edit — and the in-memory copy was clean and got replaced by
    /// the freshly decoded project. AppState uses it to refresh an open editor.
    var onExternalProjectChange: ((Project) -> Void)?

    private var externalChangeTimer: Timer?

    /// GUI instance only. `CaptureCat --mcp` runs as a separate headless
    /// process editing project.json directly; this poll notices those writes
    /// (mtime differs from the one recorded at our last load/save) and reloads
    /// the project from disk. A project with unsaved in-app changes is left
    /// alone — the editor wins that race, and the MCP tools warn about it.
    /// Polling mirrors AutomationBridge; both instances share the container so
    /// no FSEvents plumbing is needed for a handful of stat calls.
    func startWatchingForExternalChanges() {
        guard externalChangeTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollExternalChanges() }
        }
        RunLoop.main.add(timer, forMode: .common)
        externalChangeTimer = timer
    }

    private func pollExternalChanges() {
        for (idx, project) in projects.enumerated() {
            let jsonURL = project.projectDirectory.appendingPathComponent("project.json")
            guard let mtime = Self.modificationDate(of: jsonURL) else { continue }
            guard let known = project.diskModificationDate else {
                project.diskModificationDate = mtime
                continue
            }
            guard abs(mtime.timeIntervalSince(known)) > 0.001 else { continue }
            if project.hasUnsavedChanges {
                // In-app edits win; the disk edit is the MCP-warned case.
                continue
            }
            guard let data = try? Data(contentsOf: jsonURL),
                  let fresh = try? JSONDecoder().decode(Project.self, from: data) else { continue }
            fresh.diskModificationDate = mtime
            projects[idx] = fresh
            logger.info("Reloaded externally edited project: \(fresh.id)")
            onExternalProjectChange?(fresh)
        }
    }
}
