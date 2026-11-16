import Observation
import UIKit

/// Transcription (Studio 4e): subtitles from the recording's speech, on
/// device. The engine is the Mac's — `TranscriptionService` (Studio/):
/// WhisperKit `base.en` with the same decoding options and the same word →
/// subtitle grouping, so a recording gets the same subtitle structure
/// whichever app transcribes it. (SpeechAnalyzer, allowed by the plan on
/// iOS 26, was not used: a second engine would give different words,
/// timings and grouping than the Mac.)
///
///     StudioTranscription.present(from: editor, project: project, undoManager: undo)
///
/// The result replaces `project.subtitles` in SOURCE time exactly as the
/// Mac's Generate does, as ONE undo step ("Generate Subtitles").
///
/// The model (~150 MB) downloads on first use into Application Support and
/// is loaded from there afterwards without the network (Phase 0 §3.7).
@MainActor
enum StudioTranscription {
    /// Where the model is kept on this device.
    static var downloadBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperKit", isDirectory: true)
    }

    /// The model folder once downloaded (WhisperKit's hub layout).
    static var storedModelFolder: URL? {
        let folder = TranscriptionService.modelFolder(in: downloadBase)
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent("config.json").path) ? folder : nil
    }

    #if DEBUG
    /// Probe seam: a download base holding the model AND its tokenizer (the
    /// gate shares the Mac's files; nothing is fetched).
    static var probeDownloadBase: URL?
    #endif

    /// One engine per app run (the loaded model is reused). The tokenizer is
    /// kept under the same base, so a stored model loads offline.
    static let service: TranscriptionService = {
        #if DEBUG
        if let base = probeDownloadBase {
            return TranscriptionService(modelFolder: TranscriptionService.modelFolder(in: base), downloadBase: base)
        }
        #endif
        if let folder = storedModelFolder { return TranscriptionService(modelFolder: folder, downloadBase: downloadBase) }
        return TranscriptionService(downloadBase: downloadBase)
    }()

    @discardableResult
    static func present(
        from presenter: UIViewController,
        project: Project,
        undoManager: UndoManager?,
        onApplied: (([SubtitleSegment]) -> Void)? = nil
    ) -> StudioTranscriptionController {
        let controller = StudioTranscriptionController(project: project, undoManager: undoManager, service: service)
        controller.onApplied = onApplied
        controller.present(from: presenter)
        return controller
    }

    /// Installs `segments` as the project's subtitles, one undo step.
    static func apply(_ segments: [SubtitleSegment], to project: Project, undoManager: UndoManager?) {
        let previous = project.subtitles
        project.subtitles = segments
        undoManager?.registerUndo(withTarget: project) { project in
            let redo = project.subtitles
            project.subtitles = previous
            undoManager?.registerUndo(withTarget: project) { project in
                apply(redo, to: project, undoManager: undoManager)
            }
        }
        undoManager?.setActionName("Generate Subtitles")
    }
}

@MainActor
final class StudioTranscriptionController {
    let project: Project
    let service: TranscriptionService
    private weak var undoManager: UndoManager?
    var onApplied: (([SubtitleSegment]) -> Void)?
    let status = StudioFeatureProgressRow()
    private(set) var alert: CCAlert?
    private var observation: SurfaceObservation?
    /// What the last Generate produced (probe).
    private(set) var lastSegments: [SubtitleSegment]?

    init(project: Project, undoManager: UndoManager?, service: TranscriptionService) {
        self.project = project
        self.undoManager = undoManager
        self.service = service
        status.accessibilityIdentifier = "studio.transcription.status"
    }

    func present(from presenter: UIViewController) {
        let existing = project.subtitles.count
        var message = "Turns the recording's speech into subtitles on this device. The first time, the speech model (about 150 MB) downloads."
        if existing > 0 { message += " This replaces the \(existing) subtitles you have now." }
        let alert = StudioFeatureSheet.make(title: "Generate Subtitles", message: message,
                                            symbol: "captions.bubble", content: [status])
        alert.addButton(existing > 0 ? "Replace Subtitles" : "Generate", role: .primary) { [weak self] in
            try await self?.generate()
        }
        alert.addButton("Cancel", role: .cancel)
        self.alert = alert
        alert.present(from: presenter) { [weak self] _ in self?.observation = nil }
        observation = SurfaceObservation { [weak self] in self?.apply() }
    }

    /// Generate — runs the shared service and installs its subtitles.
    func generate() async throws {
        guard let videoURL = project.videoURL else { throw StudioTranscriptionError.noRecording }
        do {
            let segments = try await service.transcribe(videoURL: videoURL)
            lastSegments = segments
            StudioTranscription.apply(segments, to: project, undoManager: undoManager)
            onApplied?(segments)
        } catch {
            service.error = error.localizedDescription
            throw error
        }
    }

    private func apply() {
        let busy = service.isTranscribing
        let text = service.progress
        let fraction = service.fraction
        if busy {
            status.update(text: text, value: text == "Loading model..." && fraction == 0 ? nil : fraction)
        } else if lastSegments != nil {
            status.update(text: text, value: 1)
        } else {
            status.update(text: "Ready", value: 0, showsBar: false)
        }
    }
}

enum StudioTranscriptionError: LocalizedError {
    case noRecording
    var errorDescription: String? { "This project has no recording to transcribe." }
}
